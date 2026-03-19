#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Lambda Cloud Persistent Dev Environment — Bootstrap Script
# Run this on EVERY new instance to wire up the persistent environment.
# Can be called manually or via cloud-init.
#
# What it does:
#   - Symlinks .gitconfig, .ssh keys, configs from persistent FS to ~
#   - Appends persistent .bashrc sourcing to ~/.bashrc
#   - Installs apt dependencies (libfuse2 for Neovim AppImage)
#   - Fixes file ownership if running as root (cloud-init)
#
# Usage:
#   Manual:     bash /lambda/nfs/dev-env/setup/bootstrap.sh
#   Cloud-init: Runs automatically via cloud-init.yaml
#=============================================================================

FS_MOUNT="/lambda/nfs/dev-env"
UBUNTU_HOME="/home/ubuntu"

echo "============================================================"
echo " Lambda Persistent Dev Env: Bootstrapping"
echo "============================================================"

# --- Verify filesystem is mounted ---
if [[ ! -d "${FS_MOUNT}/tools" ]]; then
    echo "ERROR: Persistent filesystem not found at ${FS_MOUNT}"
    echo "Make sure the 'dev-env' filesystem is attached to this instance."
    exit 1
fi
echo "  Filesystem: ${FS_MOUNT} [OK]"

# --- Symlink .gitconfig ---
ln -sf "${FS_MOUNT}/home/.gitconfig" "${UBUNTU_HOME}/.gitconfig"
echo "  Linked: .gitconfig"

# --- Symlink .ssh contents (merge with existing) ---
mkdir -p "${UBUNTU_HOME}/.ssh"
# Symlink the persistent SSH key and config; keep Lambda's authorized_keys intact
for f in id_ed25519 id_ed25519.pub config allowed_signers; do
    if [[ -f "${FS_MOUNT}/home/.ssh/${f}" ]]; then
        ln -sf "${FS_MOUNT}/home/.ssh/${f}" "${UBUNTU_HOME}/.ssh/${f}"
        echo "  Linked: .ssh/${f}"
    fi
done

# Fix permissions (SSH is strict about these)
chmod 700 "${UBUNTU_HOME}/.ssh"
chmod 600 "${UBUNTU_HOME}/.ssh/id_ed25519" 2>/dev/null || true
chmod 644 "${UBUNTU_HOME}/.ssh/id_ed25519.pub" 2>/dev/null || true
chmod 600 "${UBUNTU_HOME}/.ssh/config" 2>/dev/null || true

# --- Source persistent bashrc ---
BASHRC_LINE="source ${FS_MOUNT}/home/.bashrc_persistent"
if ! grep -qF "${BASHRC_LINE}" "${UBUNTU_HOME}/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "# Lambda Persistent Dev Environment"
        echo "${BASHRC_LINE}"
    } >> "${UBUNTU_HOME}/.bashrc"
fi
echo "  Linked: .bashrc_persistent → ~/.bashrc"

# --- Persistent ~/.local/bin (Claude Code, user-local binaries) ---
# ln -sfn won't replace a real directory; when ~/.local/bin already exists
# (e.g. system-installed jupyter/pipx), symlink individual files from NFS
# to preserve existing entries.
if [[ -d "${FS_MOUNT}/home/.local/bin" ]]; then
    mkdir -p "${UBUNTU_HOME}/.local"
    if [[ -L "${UBUNTU_HOME}/.local/bin" ]]; then
        ln -sfn "${FS_MOUNT}/home/.local/bin" "${UBUNTU_HOME}/.local/bin"
    else
        mkdir -p "${UBUNTU_HOME}/.local/bin"
        for f in "${FS_MOUNT}/home/.local/bin/"*; do
            [[ -e "$f" ]] || continue
            base="$(basename "$f")"
            # Skip claude binaries — the wrapper in tools/bin handles version
            # resolution, and claude update manages ~/.local/bin/claude directly.
            # Symlinking here would override the updated version with a stale
            # NFS reference.
            [[ "$base" == claude || "$base" == claude-dev ]] && continue
            ln -sf "$f" "${UBUNTU_HOME}/.local/bin/${base}"
        done
    fi
    echo "  Linked: .local/bin"
fi

# --- Persistent ~/.local/share (Claude Code native installer data/versions) ---
if [[ -d "${FS_MOUNT}/home/.local/share" ]]; then
    mkdir -p "${UBUNTU_HOME}/.local"
    if [[ -L "${UBUNTU_HOME}/.local/share" ]]; then
        ln -sfn "${FS_MOUNT}/home/.local/share" "${UBUNTU_HOME}/.local/share"
    else
        mkdir -p "${UBUNTU_HOME}/.local/share"
        for f in "${FS_MOUNT}/home/.local/share/"*; do
            [[ -e "$f" ]] || continue
            dest="${UBUNTU_HOME}/.local/share/$(basename "$f")"
            # Avoid nested links when destination already exists as a real directory.
            [[ -L "${dest}" ]] || rm -rf "${dest}" 2>/dev/null || true
            ln -sfn "$f" "${dest}"
        done
    fi
    echo "  Linked: .local/share"
fi

# --- Codex config (~/.codex) ---
if [[ -d "${FS_MOUNT}/home/.codex" ]]; then
    if [[ -d "${UBUNTU_HOME}/.codex" && ! -L "${UBUNTU_HOME}/.codex" ]]; then
        rm -rf "${UBUNTU_HOME}/.codex"
    fi
    ln -sfn "${FS_MOUNT}/home/.codex" "${UBUNTU_HOME}/.codex"
    echo "  Linked: .codex"
fi

# --- Symlink XDG config directories ---
mkdir -p "${UBUNTU_HOME}/.config"

# Claude Code config (~/.config/claude-code)
if [[ -d "${FS_MOUNT}/home/.config/claude-code" ]]; then
    ln -sfn "${FS_MOUNT}/home/.config/claude-code" "${UBUNTU_HOME}/.config/claude-code"
    echo "  Linked: .config/claude-code"
fi

# Claude Code data directory (~/.claude)
if [[ -d "${FS_MOUNT}/home/.claude" ]]; then
    ln -sfn "${FS_MOUNT}/home/.claude" "${UBUNTU_HOME}/.claude"
    echo "  Linked: .claude"
fi

# Claude Code config file (~/.claude.json)
if [[ -f "${FS_MOUNT}/home/.claude.json" ]]; then
    ln -sf "${FS_MOUNT}/home/.claude.json" "${UBUNTU_HOME}/.claude.json"
    echo "  Linked: .claude.json"
fi

# Neovim config (~/.config/nvim)
if [[ -d "${FS_MOUNT}/home/.config/nvim" ]]; then
    ln -sfn "${FS_MOUNT}/home/.config/nvim" "${UBUNTU_HOME}/.config/nvim"
    echo "  Linked: .config/nvim"
fi

# --- tmux config ---
if [[ -f "${FS_MOUNT}/home/.tmux.conf" ]]; then
    ln -sf "${FS_MOUNT}/home/.tmux.conf" "${UBUNTU_HOME}/.tmux.conf"
    echo "  Linked: .tmux.conf"
fi

# --- HuggingFace token ---
if [[ -f "${FS_MOUNT}/home/.huggingface_token" ]]; then
    mkdir -p "${UBUNTU_HOME}/.cache/huggingface"
    ln -sf "${FS_MOUNT}/home/.huggingface_token" "${UBUNTU_HOME}/.cache/huggingface/token"
    echo "  Linked: .cache/huggingface/token"
fi

# --- Install apt packages needed as dependencies ---
echo "  Installing apt dependencies..."
if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update -qq
    apt-get install -y -qq libfuse2 > /dev/null 2>&1 || true
else
    sudo apt-get update -qq
    sudo apt-get install -y -qq libfuse2 > /dev/null 2>&1 || true
fi
echo "  Installed: libfuse2 (for Neovim AppImage)"

# --- Fix ownership if running as root (cloud-init runs as root) ---
if [[ "$(id -u)" -eq 0 ]]; then
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.gitconfig" 2>/dev/null || true
    chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.ssh" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.config/claude-code" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.config/nvim" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.claude" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.claude.json" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.codex" 2>/dev/null || true
    chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.local" 2>/dev/null || true
    chown -h ubuntu:ubuntu "${UBUNTU_HOME}/.tmux.conf" 2>/dev/null || true
    chown -R ubuntu:ubuntu "${UBUNTU_HOME}/.cache/huggingface" 2>/dev/null || true
    chown ubuntu:ubuntu "${UBUNTU_HOME}/.bashrc" 2>/dev/null || true
    echo "  Fixed: file ownership for ubuntu user"
fi

echo ""
echo "============================================================"
echo " Bootstrap Complete!"
echo "============================================================"
echo ""
echo "Run 'source ~/.bashrc' or start a new shell to activate."
echo ""
