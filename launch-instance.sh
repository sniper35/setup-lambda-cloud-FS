#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Lambda Cloud — Launch Instance with Persistent Dev Environment
#
# Usage:
#   ./launch-instance.sh <instance_type> [region] [quantity]
#
# Examples:
#   ./launch-instance.sh gpu_1x_a10
#   ./launch-instance.sh gpu_8x_h100 us-east-1
#   ./launch-instance.sh gpu_1x_a6000 us-west-1 2
#
# Environment variables:
#   LAMBDA_API_KEY       (required) Your Lambda Cloud API key
#   LAMBDA_SSH_KEY_NAME  (optional) SSH key name; prompted if not set
#
# Common instance types:
#   gpu_1x_a10, gpu_1x_a6000, gpu_1x_a100, gpu_1x_h100
#   gpu_8x_a100, gpu_8x_h100, gpu_1x_gh200, gpu_8x_b200
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load config ---
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
else
    echo "ERROR: config.env not found at ${SCRIPT_DIR}/config.env"
    exit 1
fi

# --- Parameters ---
INSTANCE_TYPE="${1:?Usage: $0 <instance_type> [region] [quantity]}"
REGION="${2:-${LAMBDA_REGION}}"
QUANTITY="${3:-1}"

# --- API Key ---
if [[ -z "${LAMBDA_API_KEY:-}" ]]; then
    echo "ERROR: LAMBDA_API_KEY environment variable not set."
    echo ""
    echo "Set it with:"
    echo "  export LAMBDA_API_KEY='your-api-key-here'"
    echo ""
    echo "Get your API key from: https://cloud.lambda.ai/api-keys"
    exit 1
fi

API_BASE="https://cloud.lambda.ai/api/v1"

# --- SSH Key Name ---
SSH_KEY_NAME="${LAMBDA_SSH_KEY_NAME:-}"
if [[ -z "${SSH_KEY_NAME}" ]]; then
    echo "Fetching SSH key names from API..."
    SSH_KEYS_JSON=$(curl -s -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
        "${API_BASE}/ssh-keys")

    SSH_KEY_NAMES=$(echo "${SSH_KEYS_JSON}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for k in data.get('data', []):
        print(k['name'])
except Exception as e:
    print(f'Error parsing SSH keys: {e}', file=sys.stderr)
    sys.exit(1)
")

    if [[ -z "${SSH_KEY_NAMES}" ]]; then
        echo "ERROR: No SSH keys found. Add one at: https://cloud.lambda.ai/ssh-keys"
        exit 1
    fi

    echo "Available SSH keys:"
    echo "${SSH_KEY_NAMES}" | while read -r name; do echo "  - ${name}"; done
    echo ""
    read -rp "Enter SSH key name: " SSH_KEY_NAME
fi

# --- Read cloud-init user_data ---
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init.yaml"
if [[ -f "${CLOUD_INIT_FILE}" ]]; then
    CLOUD_INIT=$(cat "${CLOUD_INIT_FILE}")
else
    echo "WARNING: cloud-init.yaml not found. Launching without cloud-init."
    CLOUD_INIT=""
fi

# --- Build launch payload ---
echo ""
echo "============================================================"
echo " Launching Lambda Cloud Instance"
echo "============================================================"
echo "  Type:       ${INSTANCE_TYPE}"
echo "  Region:     ${REGION}"
echo "  Quantity:   ${QUANTITY}"
echo "  Filesystem: ${LAMBDA_FS_NAME}"
echo "  SSH Key:    ${SSH_KEY_NAME}"
echo "  Cloud-init: $([ -n "${CLOUD_INIT}" ] && echo 'yes' || echo 'no')"
echo ""

# Build JSON payload with Python for proper escaping
PAYLOAD=$(python3 -c "
import json
payload = {
    'region_name': '${REGION}',
    'instance_type_name': '${INSTANCE_TYPE}',
    'ssh_key_names': ['${SSH_KEY_NAME}'],
    'file_system_names': ['${LAMBDA_FS_NAME}'],
    'quantity': ${QUANTITY},
}
user_data = '''${CLOUD_INIT}'''
if user_data.strip():
    payload['user_data'] = user_data
print(json.dumps(payload))
")

# --- Launch ---
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${LAMBDA_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "${API_BASE}/instance-operations/launch")

# Split response body and HTTP status code
HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" -ge 200 ]] && [[ "${HTTP_CODE}" -lt 300 ]]; then
    echo "Launch successful! (HTTP ${HTTP_CODE})"
    echo ""
    echo "${BODY}" | python3 -m json.tool 2>/dev/null || echo "${BODY}"

    # Extract instance IDs
    INSTANCE_IDS=$(echo "${BODY}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get('data', {}).get('instance_ids', [])
    for i in ids:
        print(i)
except:
    pass
" 2>/dev/null || true)

    if [[ -n "${INSTANCE_IDS}" ]]; then
        echo ""
        echo "Instance ID(s):"
        echo "${INSTANCE_IDS}" | while read -r id; do echo "  ${id}"; done
        echo ""
        echo "Wait 3-5 min (single-GPU) or 10-15 min (multi-GPU) for instance to be ready."
        echo ""
        echo "Check status:"
        echo "  curl -s -H 'Authorization: Bearer \${LAMBDA_API_KEY}' ${API_BASE}/instances | python3 -m json.tool"
        echo ""
        echo "Then SSH in:"
        echo "  ssh ubuntu@<instance-ip>"
        echo ""
        echo "If launched via console (no cloud-init), run:"
        echo "  bash /lambda/nfs/dev-env/setup/bootstrap.sh && source ~/.bashrc"
    fi
else
    echo "ERROR: Launch failed (HTTP ${HTTP_CODE})"
    echo ""
    echo "${BODY}" | python3 -m json.tool 2>/dev/null || echo "${BODY}"
    exit 1
fi
