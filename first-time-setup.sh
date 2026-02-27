#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Lambda Cloud Persistent Dev Environment — First-Time Setup
# Run this ONCE on your first instance with the persistent FS attached.
#
# Usage:
#   1. Copy this entire 'setup/' directory to /lambda/nfs/dev-env/setup/
#   2. Edit config.env with your settings
#   3. Run: bash /lambda/nfs/dev-env/setup/first-time-setup.sh
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_MOUNT="/lambda/nfs/dev-env"

# --- Load config ---
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
else
    echo "ERROR: config.env not found at ${SCRIPT_DIR}/config.env"
    echo "Create it from config.env and fill in your values."
    exit 1
fi

echo "============================================================"
echo " Lambda Persistent Dev Env: First-Time Setup"
echo " Filesystem mount: ${FS_MOUNT}"
echo "============================================================"
echo ""

# --- Verify filesystem is mounted ---
if [[ ! -d "${FS_MOUNT}" ]]; then
    echo "ERROR: Persistent filesystem not mounted at ${FS_MOUNT}"
    echo "Make sure the 'dev-env' filesystem is attached to this instance."
    exit 1
fi

# --- Create directory structure ---
echo "[1/8] Creating directory structure..."
mkdir -p "${FS_MOUNT}/home/.ssh"
mkdir -p "${FS_MOUNT}/home/.config/nvim"
mkdir -p "${FS_MOUNT}/home/.config/claude-code"
mkdir -p "${FS_MOUNT}/home/.claude"
mkdir -p "${FS_MOUNT}/home/.codex"
mkdir -p "${FS_MOUNT}/home/.local/share"
mkdir -p "${FS_MOUNT}/home/.local/bin"
mkdir -p "${FS_MOUNT}/tools/bin"
mkdir -p "${FS_MOUNT}/tools/nvm"
mkdir -p "${FS_MOUNT}/tools/node_globals"
mkdir -p "${FS_MOUNT}/repos"
mkdir -p "${FS_MOUNT}/data"
mkdir -p "${FS_MOUNT}/setup"
mkdir -p "${FS_MOUNT}/.cache/uv"
echo "  Done."

# --- Copy bash-completion to persistent FS ---
echo "[2/8] Installing bash-completion..."
if [[ -d "${FS_MOUNT}/tools/bash-completion/completions" ]]; then
    echo "  bash-completion already installed."
else
    if [[ ! -f /usr/share/bash-completion/bash_completion ]]; then
        sudo apt-get update -qq && sudo apt-get install -y -qq bash-completion
    fi
    cp -r /usr/share/bash-completion "${FS_MOUNT}/tools/bash-completion"
    echo "  bash-completion copied to ${FS_MOUNT}/tools/bash-completion"
fi

# --- Install Neovim (AppImage, standalone) ---
echo "[3/8] Installing Neovim AppImage..."
NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage"
if [[ -f "${FS_MOUNT}/tools/bin/nvim" ]]; then
    echo "  Neovim already installed, skipping. (Delete to reinstall)"
else
    curl -fLo "${FS_MOUNT}/tools/bin/nvim" "${NVIM_URL}"
    chmod +x "${FS_MOUNT}/tools/bin/nvim"
    echo "  Neovim installed: ${FS_MOUNT}/tools/bin/nvim"
fi

# --- Install uv (standalone binary) ---
echo "[4/8] Installing uv..."
if [[ -f "${FS_MOUNT}/tools/bin/uv" ]]; then
    echo "  uv already installed, skipping. (Delete to reinstall)"
else
    # uv installer respects UV_INSTALL_DIR; it creates a 'bin' subdirectory
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="${FS_MOUNT}/tools" sh
    # The installer may place it at tools/bin/uv or tools/uv depending on version
    if [[ -f "${FS_MOUNT}/tools/uv" ]] && [[ ! -f "${FS_MOUNT}/tools/bin/uv" ]]; then
        mv "${FS_MOUNT}/tools/uv" "${FS_MOUNT}/tools/bin/uv"
    fi
    chmod +x "${FS_MOUNT}/tools/bin/uv"
    echo "  uv installed: ${FS_MOUNT}/tools/bin/uv"
fi

# --- Install Node.js via nvm (persistent) ---
echo "[5/8] Installing nvm + Node.js ${NODE_VERSION}..."
export NVM_DIR="${FS_MOUNT}/tools/nvm"
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    echo "  nvm already installed."
else
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# Load nvm into current shell
[ -s "${NVM_DIR}/nvm.sh" ] && \. "${NVM_DIR}/nvm.sh"

# Install Node.js
if command -v node &>/dev/null && [[ "$(node --version)" == v${NODE_VERSION}.* ]]; then
    echo "  Node.js $(node --version) already installed."
else
    nvm install "${NODE_VERSION}"
    nvm alias default "${NODE_VERSION}"
    echo "  Node.js $(node --version) installed via nvm"
fi

# --- Install Claude Code (native installer with npm fallback) and Codex ---
echo "[6/8] Installing Claude Code and Codex..."

# Symlink ~/.local/bin and ~/.local/share to persistent FS so everything persists.
# The native installer writes to ~/.local/bin/claude + ~/.local/share/claude/versions/
# Remove real directories first — ln -sfn won't replace them.
mkdir -p "${HOME}/.local"
if [[ -d "${HOME}/.local/bin" && ! -L "${HOME}/.local/bin" ]]; then
    rm -rf "${HOME}/.local/bin"
fi
ln -sfn "${FS_MOUNT}/home/.local/bin" "${HOME}/.local/bin"
if [[ -d "${HOME}/.local/share" && ! -L "${HOME}/.local/share" ]]; then
    rm -rf "${HOME}/.local/share"
fi
ln -sfn "${FS_MOUNT}/home/.local/share" "${HOME}/.local/share"

if [[ -f "${FS_MOUNT}/home/.local/bin/claude" ]]; then
    echo "  Claude Code already installed."
else
    echo "  Attempting native install..."
    # Native installer may fail on ARM Neoverse-V2 CPUs or NFS noexec mounts.
    # Wrap in subshell so SIGABRT doesn't kill our script (set -e would exit).
    if (curl -fsSL https://claude.ai/install.sh | bash) 2>&1; then
        echo "  Claude Code installed (native)."
    else
        echo "  Native install failed (exit $?). Falling back to npm..."
        export npm_config_prefix="${FS_MOUNT}/tools/node_globals"
        npm install -g @anthropic-ai/claude-code
        # Symlink npm wrapper to .local/bin so PATH is consistent
        # (symlink instead of copy so npm update -g keeps it current)
        if [[ -f "${FS_MOUNT}/tools/node_globals/bin/claude" ]]; then
            ln -sf "${FS_MOUNT}/tools/node_globals/bin/claude" "${FS_MOUNT}/home/.local/bin/claude"
        fi
        echo "  Claude Code installed (npm fallback)."
    fi
fi

# Codex — npm only (no native installer available)
export npm_config_prefix="${FS_MOUNT}/tools/node_globals"
if [[ -f "${FS_MOUNT}/tools/node_globals/bin/codex" ]]; then
    echo "  Codex already installed."
else
    npm install -g @openai/codex
    echo "  Codex installed."
fi
echo "  Global npm packages: ${FS_MOUNT}/tools/node_globals"

# --- Configure Git with SSH signing ---
echo "[7/8] Configuring Git..."
cat > "${FS_MOUNT}/home/.gitconfig" << GITEOF
[user]
    name = ${GIT_USER_NAME}
    email = ${GIT_USER_EMAIL}
    signingkey = ${FS_MOUNT}/home/.ssh/id_ed25519.pub

[gpg]
    format = ssh

[gpg "ssh"]
    allowedSignersFile = ${FS_MOUNT}/home/.ssh/allowed_signers

[commit]
    gpgsign = true

[tag]
    gpgsign = true

[core]
    editor = nvim

[init]
    defaultBranch = main

[push]
    autoSetupRemote = true
GITEOF
echo "  Created: ${FS_MOUNT}/home/.gitconfig"

# --- Configure SSH for GitHub ---
cat > "${FS_MOUNT}/home/.ssh/config" << 'SSHEOF'
Host github.com
    HostName github.com
    User git
    IdentityFile /lambda/nfs/dev-env/home/.ssh/id_ed25519
    IdentitiesOnly yes
    AddKeysToAgent yes
SSHEOF
chmod 700 "${FS_MOUNT}/home/.ssh"
chmod 600 "${FS_MOUNT}/home/.ssh/config"
echo "  Created: ${FS_MOUNT}/home/.ssh/config"

# --- Create persistent .bashrc additions ---
echo "[8/8] Creating persistent bash profile..."
cat > "${FS_MOUNT}/home/.bashrc_persistent" << 'BASHEOF'
#=============================================================================
# Lambda Cloud Persistent Dev Environment — Bash Profile
# Sourced from ~/.bashrc on every instance boot
#=============================================================================

export LAMBDA_FS="/lambda/nfs/dev-env"

# --- Persistent tools PATH ---
# Use ~/.local/bin (bootstrap symlinks NFS files into it) so that
# 'claude update' and other installers can update in-place.
export PATH="${HOME}/.local/bin:${PATH}"
export PATH="${LAMBDA_FS}/tools/bin:${PATH}"
export PATH="${LAMBDA_FS}/tools/node_globals/bin:${PATH}"

# --- bash-completion (persisted from NFS) ---
if [[ $PS1 && ! ${BASH_COMPLETION_VERSINFO:-} && -f "${LAMBDA_FS}/tools/bash-completion/bash_completion" ]]; then
    . "${LAMBDA_FS}/tools/bash-completion/bash_completion"
fi

# --- nvm (Node Version Manager) ---
export NVM_DIR="${LAMBDA_FS}/tools/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# --- uv cache and link mode (NFS-compatible) ---
# Hardlinks can't cross filesystems; cache on same NFS FS as venvs avoids
# cross-filesystem copies and persists the cache across instances.
export UV_LINK_MODE=copy
export UV_CACHE_DIR="${LAMBDA_FS}/.cache/uv"

# --- uv shell completion ---
if command -v uv &>/dev/null; then
    eval "$(uv generate-shell-completion bash)"
fi

# --- Git SSH signing ---
export GIT_SSH_COMMAND="ssh -i ${LAMBDA_FS}/home/.ssh/id_ed25519 -o IdentitiesOnly=yes"

# --- HuggingFace authentication ---
if [[ -f "${LAMBDA_FS}/home/.huggingface_token" ]]; then
    export HF_TOKEN="$(cat "${LAMBDA_FS}/home/.huggingface_token")"
fi

# --- XDG directories on persistent FS ---
export XDG_CONFIG_HOME="${LAMBDA_FS}/home/.config"
export XDG_DATA_HOME="${LAMBDA_FS}/home/.local/share"

# --- Aliases ---
alias repos="cd ${LAMBDA_FS}/repos"
alias data="cd ${LAMBDA_FS}/data"
alias ll="ls -alFh"

# --- GPU info on login ---
if command -v nvidia-smi &>/dev/null; then
    echo "=== GPU Status ==="
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    echo ""
fi

echo "=== Lambda Persistent Dev Env loaded ==="
echo "Filesystem: ${LAMBDA_FS}"
echo "Tools: nvim, uv, node, claude, codex"
echo "Repos: ${LAMBDA_FS}/repos"

# --- Default working directory ---
cd "${LAMBDA_FS}/repos" 2>/dev/null || true
BASHEOF
echo "  Created: ${FS_MOUNT}/home/.bashrc_persistent"

# --- Copy setup scripts to persistent FS ---
if [[ "${SCRIPT_DIR}" != "${FS_MOUNT}/setup" ]]; then
    echo ""
    echo "Copying setup scripts to persistent filesystem..."
    cp -v "${SCRIPT_DIR}/config.env" "${FS_MOUNT}/setup/"
    cp -v "${SCRIPT_DIR}/first-time-setup.sh" "${FS_MOUNT}/setup/"
    cp -v "${SCRIPT_DIR}/bootstrap.sh" "${FS_MOUNT}/setup/"
    cp -v "${SCRIPT_DIR}/cloud-init.yaml" "${FS_MOUNT}/setup/"
    cp -v "${SCRIPT_DIR}/launch-instance.sh" "${FS_MOUNT}/setup/"
    cp -v "${SCRIPT_DIR}/migrate-region.sh" "${FS_MOUNT}/setup/" 2>/dev/null || true
    chmod +x "${FS_MOUNT}/setup/"*.sh
fi

# --- Clone git repos ---
echo ""
echo "[Post-setup] Cloning git repos..."

if [[ -d "${FS_MOUNT}/repos/vllm" ]]; then
    echo "  vllm already cloned, skipping."
else
    git clone git@github.com:sniper35/vllm.git "${FS_MOUNT}/repos/vllm"
    cd "${FS_MOUNT}/repos/vllm"
    git remote add upstream git@github.com:vllm-project/vllm.git
    echo "  Cloned: vllm (upstream: vllm-project/vllm)"
fi

echo ""
echo "============================================================"
echo " First-Time Setup Complete!"
echo "============================================================"
echo ""
echo "=== SSH Key Setup (REQUIRED) ==="
echo ""
echo "Copy your SSH private key to:"
echo "  ${FS_MOUNT}/home/.ssh/id_ed25519"
echo ""
echo "Copy your SSH public key to:"
echo "  ${FS_MOUNT}/home/.ssh/id_ed25519.pub"
echo ""
echo "Then run these commands:"
echo "  chmod 600 ${FS_MOUNT}/home/.ssh/id_ed25519"
echo "  chmod 644 ${FS_MOUNT}/home/.ssh/id_ed25519.pub"
echo ""
echo "Create the allowed_signers file (for git signature verification):"
echo "  echo \"${GIT_USER_EMAIL} \$(cat ${FS_MOUNT}/home/.ssh/id_ed25519.pub)\" > ${FS_MOUNT}/home/.ssh/allowed_signers"
echo ""
echo "=== HuggingFace Token (OPTIONAL) ==="
echo ""
echo "To persist your HuggingFace login across instances:"
echo "  echo \"hf_YOUR_TOKEN\" > ${FS_MOUNT}/home/.huggingface_token"
echo "  chmod 600 ${FS_MOUNT}/home/.huggingface_token"
echo ""
echo "Or after running 'huggingface-cli login':"
echo "  cp ~/.cache/huggingface/token ${FS_MOUNT}/home/.huggingface_token"
echo "  chmod 600 ${FS_MOUNT}/home/.huggingface_token"
echo ""
echo "=== Next Steps ==="
echo "1. Copy your SSH keys (see above)"
echo "2. Run: bash ${FS_MOUNT}/setup/bootstrap.sh"
echo "3. Run: source ~/.bashrc"
echo "4. Add your SSH public key to GitHub as both"
echo "   'Authentication Key' AND 'Signing Key':"
echo "   https://github.com/settings/keys"
echo "5. Test: ssh -T git@github.com"
echo "6. Test signed commits:"
echo "   cd ${FS_MOUNT}/repos && git init test-signing && cd test-signing"
echo "   git commit --allow-empty -m 'test signed commit'"
echo "   git log --show-signature"
echo ""
echo "For future instances, cloud-init runs bootstrap automatically (API)"
echo "or run manually: bash ${FS_MOUNT}/setup/bootstrap.sh && source ~/.bashrc"
