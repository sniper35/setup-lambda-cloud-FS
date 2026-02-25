#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Lambda Cloud — Cross-Region Filesystem Migration
#
# Lambda Cloud filesystems are region-locked. This script migrates your
# persistent dev environment to a new filesystem in a different region
# using rsync over SSH.
#
# PREREQUISITES:
#   - Source instance running with source "dev-env" FS attached
#   - Target instance running with a NEW "dev-env" FS attached (same name)
#   - SSH access between instances (or from local machine to both)
#
# MODES:
#   direct    — Run on the SOURCE instance, rsync directly to target
#   relay     — Run on your LOCAL machine, rsync source → local → target
#
# USAGE:
#   Direct (run on source instance):
#     ./migrate-region.sh direct ubuntu@<TARGET_IP>
#     ./migrate-region.sh direct ubuntu@<TARGET_IP> --data-only
#
#   Relay (run on local machine):
#     ./migrate-region.sh relay ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP>
#     ./migrate-region.sh relay ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP> --data-only
#
# OPTIONS:
#   --data-only   Skip tools/ directory (saves bandwidth; reinstall tools
#                 on target via first-time-setup.sh instead)
#   --dry-run     Show what would be transferred without actually copying
#
# EXAMPLES:
#   # Full migration (tools + data + configs + repos)
#   ./migrate-region.sh direct ubuntu@203.0.113.50
#
#   # Data-only (repos + data + home configs, skip tools — reinstall later)
#   ./migrate-region.sh direct ubuntu@203.0.113.50 --data-only
#
#   # Preview what would be transferred
#   ./migrate-region.sh direct ubuntu@203.0.113.50 --dry-run
#
#   # Relay through local machine
#   ./migrate-region.sh relay ubuntu@198.51.100.10 ubuntu@203.0.113.50
#=============================================================================

FS_PATH="/lambda/nfs/dev-env"
LOCAL_STAGING="/tmp/lambda-migrate-staging"

# --- Parse arguments ---
MODE="${1:?Usage: $0 <direct|relay> <args...> [--data-only] [--dry-run]}"
shift

DATA_ONLY=false
DRY_RUN=false
POSITIONAL_ARGS=()

for arg in "$@"; do
    case "${arg}" in
        --data-only) DATA_ONLY=true ;;
        --dry-run)   DRY_RUN=true ;;
        *)           POSITIONAL_ARGS+=("${arg}") ;;
    esac
done

# --- Common rsync options ---
RSYNC_OPTS=(
    -avz
    --info=progress2
    --human-readable
    --delete
    # Preserve permissions, ownership info, symlinks
    --links
    --perms
    --times
    # Exclude unnecessary files
    --exclude='.Trash-*'
    --exclude='*.swp'
    --exclude='*.swo'
    --exclude='__pycache__'
    --exclude='.cache'
    --exclude='node_modules'
)

if [[ "${DRY_RUN}" == true ]]; then
    RSYNC_OPTS+=("--dry-run")
    echo "*** DRY RUN MODE — no files will be transferred ***"
    echo ""
fi

# --- Build include/exclude list ---
build_rsync_paths() {
    local src="$1"
    local dst="$2"
    local -a paths=()

    if [[ "${DATA_ONLY}" == true ]]; then
        echo "Mode: DATA-ONLY (skipping tools/ — reinstall via first-time-setup.sh)"
        echo ""
        # Sync specific directories only
        paths=(
            "${src}/home/"
            "${src}/repos/"
            "${src}/data/"
            "${src}/setup/"
        )
    else
        echo "Mode: FULL MIGRATION (all directories including tools/)"
        echo ""
        paths=("${src}/")
    fi

    echo "${paths[@]}"
}

# --- Estimate transfer size ---
estimate_size() {
    local target="$1"
    echo "Estimating transfer size..."
    if [[ "${DATA_ONLY}" == true ]]; then
        du -sh "${target}/home" "${target}/repos" "${target}/data" "${target}/setup" 2>/dev/null || true
    else
        du -sh "${target}" 2>/dev/null || true
    fi
    echo ""
}

# =============================================================================
# DIRECT MODE: Run on source instance, rsync to target
# =============================================================================
direct_migrate() {
    local TARGET_HOST="${POSITIONAL_ARGS[0]:?Usage: $0 direct ubuntu@<TARGET_IP> [--data-only]}"

    echo "============================================================"
    echo " Lambda Cloud: Cross-Region Migration (Direct)"
    echo "============================================================"
    echo ""
    echo "Source: ${FS_PATH} (this instance)"
    echo "Target: ${TARGET_HOST}:${FS_PATH}"
    echo ""

    # Verify source filesystem exists
    if [[ ! -d "${FS_PATH}/tools" ]]; then
        echo "ERROR: Source filesystem not found at ${FS_PATH}"
        echo "Are you running this on the source instance with the FS attached?"
        exit 1
    fi

    # Verify SSH connectivity to target
    echo "Testing SSH connectivity to ${TARGET_HOST}..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${TARGET_HOST}" "echo 'SSH OK'" 2>/dev/null; then
        echo "ERROR: Cannot SSH to ${TARGET_HOST}"
        echo ""
        echo "Make sure:"
        echo "  1. Target instance is running"
        echo "  2. Your SSH key can reach the target"
        echo "  3. Try: ssh ${TARGET_HOST}"
        exit 1
    fi
    echo "  SSH connection OK."
    echo ""

    # Verify target filesystem mount exists
    echo "Verifying target filesystem mount..."
    if ! ssh "${TARGET_HOST}" "test -d ${FS_PATH}"; then
        echo "ERROR: Target filesystem not mounted at ${FS_PATH}"
        echo "Make sure the target instance has a 'dev-env' filesystem attached."
        exit 1
    fi
    echo "  Target filesystem mount OK."
    echo ""

    estimate_size "${FS_PATH}"

    if [[ "${DATA_ONLY}" == true ]]; then
        echo "Syncing: home/, repos/, data/, setup/"
        echo ""

        # Sync each directory separately for data-only mode
        for dir in home repos data setup; do
            if [[ -d "${FS_PATH}/${dir}" ]]; then
                echo "--- Syncing ${dir}/ ---"
                rsync "${RSYNC_OPTS[@]}" \
                    "${FS_PATH}/${dir}/" \
                    "${TARGET_HOST}:${FS_PATH}/${dir}/"
                echo ""
            fi
        done
    else
        echo "Syncing: entire filesystem"
        echo ""
        rsync "${RSYNC_OPTS[@]}" \
            "${FS_PATH}/" \
            "${TARGET_HOST}:${FS_PATH}/"
    fi

    echo ""
    echo "============================================================"
    echo " Migration Complete!"
    echo "============================================================"
    echo ""
    echo "Next steps on the TARGET instance (${TARGET_HOST}):"
    echo ""
    if [[ "${DATA_ONLY}" == true ]]; then
        echo "  # Reinstall tools on target (since --data-only was used)"
        echo "  bash ${FS_PATH}/setup/first-time-setup.sh"
        echo ""
    fi
    echo "  # Wire up the environment"
    echo "  bash ${FS_PATH}/setup/bootstrap.sh"
    echo "  source ~/.bashrc"
    echo ""
    echo "  # Update region in config (optional)"
    echo "  nano ${FS_PATH}/setup/config.env"
    echo ""
    echo "  # Verify"
    echo "  ssh -T git@github.com"
    echo "  nvim --version && uv --version && claude --version"
    echo "  ls ${FS_PATH}/repos"
}

# =============================================================================
# RELAY MODE: Run on local machine, rsync source → local → target
# =============================================================================
relay_migrate() {
    local SOURCE_HOST="${POSITIONAL_ARGS[0]:?Usage: $0 relay ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP> [--data-only]}"
    local TARGET_HOST="${POSITIONAL_ARGS[1]:?Usage: $0 relay ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP> [--data-only]}"

    echo "============================================================"
    echo " Lambda Cloud: Cross-Region Migration (Relay)"
    echo "============================================================"
    echo ""
    echo "Source: ${SOURCE_HOST}:${FS_PATH}"
    echo "Relay:  ${LOCAL_STAGING} (this machine)"
    echo "Target: ${TARGET_HOST}:${FS_PATH}"
    echo ""

    # Verify SSH connectivity to both
    echo "Testing SSH connectivity..."
    for host in "${SOURCE_HOST}" "${TARGET_HOST}"; do
        if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${host}" "echo 'OK'" 2>/dev/null; then
            echo "ERROR: Cannot SSH to ${host}"
            exit 1
        fi
        echo "  ${host}: OK"
    done
    echo ""

    # Verify source filesystem
    echo "Verifying source filesystem..."
    if ! ssh "${SOURCE_HOST}" "test -d ${FS_PATH}/tools"; then
        echo "ERROR: Source filesystem not found at ${SOURCE_HOST}:${FS_PATH}"
        exit 1
    fi
    echo "  Source filesystem OK."

    # Verify target filesystem mount
    echo "Verifying target filesystem..."
    if ! ssh "${TARGET_HOST}" "test -d ${FS_PATH}"; then
        echo "ERROR: Target filesystem not mounted at ${TARGET_HOST}:${FS_PATH}"
        exit 1
    fi
    echo "  Target filesystem OK."
    echo ""

    # Create local staging directory
    mkdir -p "${LOCAL_STAGING}"

    if [[ "${DATA_ONLY}" == true ]]; then
        echo "=== Phase 1/2: Source → Local (data-only) ==="
        echo ""

        for dir in home repos data setup; do
            echo "--- Pulling ${dir}/ ---"
            mkdir -p "${LOCAL_STAGING}/${dir}"
            rsync "${RSYNC_OPTS[@]}" \
                "${SOURCE_HOST}:${FS_PATH}/${dir}/" \
                "${LOCAL_STAGING}/${dir}/"
            echo ""
        done

        echo "=== Phase 2/2: Local → Target (data-only) ==="
        echo ""

        for dir in home repos data setup; do
            if [[ -d "${LOCAL_STAGING}/${dir}" ]]; then
                echo "--- Pushing ${dir}/ ---"
                rsync "${RSYNC_OPTS[@]}" \
                    "${LOCAL_STAGING}/${dir}/" \
                    "${TARGET_HOST}:${FS_PATH}/${dir}/"
                echo ""
            fi
        done
    else
        echo "=== Phase 1/2: Source → Local (full) ==="
        echo ""
        rsync "${RSYNC_OPTS[@]}" \
            "${SOURCE_HOST}:${FS_PATH}/" \
            "${LOCAL_STAGING}/"

        echo ""
        echo "=== Phase 2/2: Local → Target (full) ==="
        echo ""
        rsync "${RSYNC_OPTS[@]}" \
            "${LOCAL_STAGING}/" \
            "${TARGET_HOST}:${FS_PATH}/"
    fi

    echo ""
    echo "============================================================"
    echo " Migration Complete!"
    echo "============================================================"
    echo ""
    echo "Local staging data at: ${LOCAL_STAGING}"
    echo "  (You can delete it: rm -rf ${LOCAL_STAGING})"
    echo ""
    echo "Next steps on the TARGET instance (${TARGET_HOST}):"
    echo ""
    if [[ "${DATA_ONLY}" == true ]]; then
        echo "  # Reinstall tools on target (since --data-only was used)"
        echo "  bash ${FS_PATH}/setup/first-time-setup.sh"
        echo ""
    fi
    echo "  # Wire up the environment"
    echo "  bash ${FS_PATH}/setup/bootstrap.sh"
    echo "  source ~/.bashrc"
    echo ""
    echo "  # Update region in config (optional)"
    echo "  nano ${FS_PATH}/setup/config.env"
    echo ""
    echo "  # Verify"
    echo "  ssh -T git@github.com"
    echo "  nvim --version && uv --version && claude --version"
    echo "  ls ${FS_PATH}/repos"
}

# =============================================================================
# Main
# =============================================================================
case "${MODE}" in
    direct)
        direct_migrate
        ;;
    relay)
        relay_migrate
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'"
        echo ""
        echo "Usage:"
        echo "  $0 direct ubuntu@<TARGET_IP> [--data-only] [--dry-run]"
        echo "  $0 relay  ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP> [--data-only] [--dry-run]"
        exit 1
        ;;
esac
