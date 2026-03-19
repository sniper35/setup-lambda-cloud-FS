# Lambda Cloud Persistent Dev Environment

Scripts to set up a persistent development environment on Lambda Cloud GPU instances. All tools, configs, SSH keys, and git repos live on a persistent NFS filesystem and survive instance termination.

## What's Included

**Tools (persisted on NFS):**
- Neovim (AppImage)
- uv (Python package manager)
- nvm + Node.js 22
- Claude Code (native installer with npm fallback)
- Codex
- bash-completion

**Features:**
- Git SSH commit signing (verified commits on GitHub)
- HuggingFace token persistence
- uv configured for NFS (copy mode, persistent cache)
- Auto-cd to repos folder on login
- GPU status on login
- Cloud-init for automatic bootstrapping via API launches
- Cross-region filesystem migration

## Filesystem Layout

```
/lambda/nfs/dev-env/
├── home/
│   ├── .bashrc_persistent          # Sourced by ~/.bashrc on every boot
│   ├── .gitconfig                  # Git config with SSH signing
│   ├── .ssh/                       # SSH keys + config
│   │   ├── id_ed25519             # Private key (you provide)
│   │   ├── id_ed25519.pub         # Public key (you provide)
│   │   ├── allowed_signers        # Git signature verification
│   │   └── config                 # SSH config for GitHub
│   ├── .config/
│   │   ├── claude-code/
│   │   └── nvim/
│   ├── .claude/
│   ├── .local/
│   │   ├── bin/                   # Claude Code binary
│   │   └── share/                 # Claude Code data/versions
│   └── .huggingface_token         # Optional HF token
├── tools/
│   ├── bin/                       # nvim, uv
│   ├── nvm/                       # Node Version Manager + Node.js
│   ├── node_globals/              # Global npm packages (codex)
│   └── bash-completion/           # Persisted bash-completion framework
├── repos/                         # Git repositories
├── data/                          # Datasets and working data
├── .cache/uv/                     # uv package cache (NFS-local)
└── setup/                         # These scripts
```

## Prerequisites

1. **Lambda Cloud account** with API access
2. **Persistent filesystem** named `dev-env` created in your region
   - Lambda Console → File Systems → Create → Name: `dev-env`
3. **SSH key pair** (ed25519) for GitHub authentication and commit signing

## Quick Start (First-Time Setup)

Run these steps **once** on your very first Lambda instance with the `dev-env` filesystem attached.

### 1. Copy scripts to the persistent filesystem

```bash
# From this repo root on your local machine
scp -r ./* ubuntu@<INSTANCE_IP>:/lambda/nfs/dev-env/setup/
```

### 2. Edit configuration

```bash
ssh ubuntu@<INSTANCE_IP>
nano /lambda/nfs/dev-env/setup/config.env
```

Update `LAMBDA_REGION`, `GIT_USER_NAME`, and `GIT_USER_EMAIL` to your values.

### 3. Run first-time setup

```bash
bash /lambda/nfs/dev-env/setup/first-time-setup.sh
```

This installs all tools, creates the directory structure, configures git, and writes `.bashrc_persistent`. It also attempts to clone git repos defined in the script (and prints follow-up commands if SSH keys are not set yet).

> **Note:** If the Claude Code native installer fails (e.g., on ARM CPUs or NFS noexec mounts), it automatically falls back to npm install.

### 4. Copy your SSH keys

```bash
# Copy your keys to the persistent filesystem
cp ~/.ssh/id_ed25519 /lambda/nfs/dev-env/home/.ssh/id_ed25519
cp ~/.ssh/id_ed25519.pub /lambda/nfs/dev-env/home/.ssh/id_ed25519.pub
chmod 600 /lambda/nfs/dev-env/home/.ssh/id_ed25519
chmod 644 /lambda/nfs/dev-env/home/.ssh/id_ed25519.pub

# Create the allowed_signers file for git signature verification
echo "your-email@example.com $(cat /lambda/nfs/dev-env/home/.ssh/id_ed25519.pub)" \
    > /lambda/nfs/dev-env/home/.ssh/allowed_signers
```

### 5. Run bootstrap and activate

```bash
bash /lambda/nfs/dev-env/setup/bootstrap.sh
source ~/.bashrc
```

### 6. Add SSH key to GitHub

Add your public key to GitHub as **both** an Authentication Key and a Signing Key:

```bash
cat /lambda/nfs/dev-env/home/.ssh/id_ed25519.pub
# Copy the output, then go to: https://github.com/settings/keys
```

### 7. Verify

```bash
ssh -T git@github.com                      # "Hi <user>!"
nvim --version                             # Neovim works
uv --version                               # uv works
node --version                             # Node.js via nvm
claude --version                           # Claude Code
codex --version                            # Codex
git config user.name                       # Your name
git config user.signingkey                 # Your signing key path

# Test signed commits
cd /lambda/nfs/dev-env/repos
git init test-signing && cd test-signing
git commit --allow-empty -m "test signed commit"
git log --show-signature                   # "Good signature"
rm -rf ../test-signing
```

## Future Instance Launches

### Option A: Via API (automatic bootstrap)

Cloud-init runs `bootstrap.sh` automatically.

```bash
export LAMBDA_API_KEY="your-api-key"
bash /path/to/this-repo/launch-instance.sh gpu_1x_h100
```

After SSH-ing in, the environment is ready. Run `source ~/.bashrc` if needed.

### Option B: Via Console (manual bootstrap)

1. Launch an instance from the Lambda Console with `dev-env` filesystem attached
2. SSH in and run:

```bash
bash /lambda/nfs/dev-env/setup/bootstrap.sh
source ~/.bashrc
```

## Scripts Reference

| Script | Purpose | When to run |
|--------|---------|-------------|
| `config.env` | Configurable variables (region, git identity, Node version) | Edit before first-time setup |
| `first-time-setup.sh` | One-time initialization: installs all tools, creates configs | Once, on very first instance |
| `bootstrap.sh` | Symlinks configs from NFS to `~`, installs apt deps | Every new instance |
| `cloud-init.yaml` | Cloud-init template that runs bootstrap automatically | Used by `launch-instance.sh` |
| `launch-instance.sh` | Launch instances via Lambda API with filesystem + cloud-init | When launching via API |
| `migrate-region.sh` | Migrate filesystem contents to a new region via rsync | When changing regions |

## Adding New Tools

Tools in `tools/bin/` or `tools/node_globals/bin/` are automatically on PATH.

```bash
# Static binary
curl -LO https://example.com/tool.tar.gz
tar xzf tool.tar.gz
cp tool /lambda/nfs/dev-env/tools/bin/
chmod +x /lambda/nfs/dev-env/tools/bin/tool

# npm global package
export npm_config_prefix="/lambda/nfs/dev-env/tools/node_globals"
npm install -g <package-name>

# Bash completion for a new tool
<tool> completion bash > /lambda/nfs/dev-env/tools/bash-completion/completions/<tool>
```

## Cross-Region Migration

Lambda Cloud filesystems are region-locked. Use `migrate-region.sh` to copy your environment to a new filesystem in a different region.

### Prerequisites

- Source instance running with source `dev-env` FS attached
- Target instance running with a **new** `dev-env` FS attached in the target region

### Direct mode (run on source instance)

```bash
# Full migration (tools + data + configs + repos)
bash /lambda/nfs/dev-env/setup/migrate-region.sh direct ubuntu@<TARGET_IP>

# Data-only (skip tools — reinstall on target via first-time-setup.sh)
bash /lambda/nfs/dev-env/setup/migrate-region.sh direct ubuntu@<TARGET_IP> --data-only

# Dry run (preview only)
bash /lambda/nfs/dev-env/setup/migrate-region.sh direct ubuntu@<TARGET_IP> --dry-run
```

### Relay mode (run on local machine, when instances can't reach each other)

```bash
bash /path/to/this-repo/migrate-region.sh relay ubuntu@<SOURCE_IP> ubuntu@<TARGET_IP>
```

### After migration

On the target instance:

```bash
# If --data-only was used, reinstall tools first:
bash /lambda/nfs/dev-env/setup/first-time-setup.sh

# Wire up the environment
bash /lambda/nfs/dev-env/setup/bootstrap.sh
source ~/.bashrc

# Update region in config (optional)
nano /lambda/nfs/dev-env/setup/config.env
```

## Persisting HuggingFace Login

To persist your HuggingFace CLI login across instances:

```bash
# After running `huggingface-cli login` on any instance:
cp ~/.cache/huggingface/token /lambda/nfs/dev-env/home/.huggingface_token
chmod 600 /lambda/nfs/dev-env/home/.huggingface_token

# Or directly:
echo "hf_YOUR_TOKEN" > /lambda/nfs/dev-env/home/.huggingface_token
chmod 600 /lambda/nfs/dev-env/home/.huggingface_token
```

The `HF_TOKEN` environment variable is automatically set on login via `.bashrc_persistent`, and the token file is symlinked to `~/.cache/huggingface/token` by `bootstrap.sh`.

## Verification Checklist

Run on a **new instance** (not the one used for first-time setup) to confirm persistence:

- [ ] `nvim --version` — Neovim
- [ ] `uv --version` — uv
- [ ] `node --version` — Node.js via nvm
- [ ] `claude --version` — Claude Code
- [ ] `codex --version` — Codex
- [ ] `ssh -T git@github.com` — SSH auth to GitHub
- [ ] `git commit --allow-empty -m "test" && git log --show-signature` — Signed commits
- [ ] `ls /lambda/nfs/dev-env/repos` — Repos accessible
- [ ] `nvidia-smi` — GPU available
- [ ] `git config --list` — Correct name/email
- [ ] `pwd` — Auto-cd to repos folder
- [ ] `git ch<TAB>` — bash-completion works
