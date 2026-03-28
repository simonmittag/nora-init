#!/usr/bin/env bash

# macOS Bootstrap Script
# Prepares a machine for chezmoi dotfiles management with SSH/YubiKey.

set -euo pipefail

# --- Configuration ---
DOTFILES_REPO="git@github.com:simonmittag/dotfiles.git"
BREW_PACKAGES=("openssh" "libfido2" "ykman" "chezmoi")
SSH_DIR="$HOME/.ssh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- UI Helpers ---
info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }
success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }

# --- 1. Preflight Checks ---
check_preflight() {
    info "Running preflight checks..."
    
    # OS Detection
    if [[ "$OSTYPE" != "darwin"* ]]; then
        error "This script is only supported on macOS."
    fi

    # Ensure curl and git
    command -v curl >/dev/null 2>&1 || error "curl is missing. Please install it."
    command -v git >/dev/null 2>&1 || error "git is missing. Please install it."

    success "Preflight checks passed."
}

# --- 2. Homebrew Setup ---
setup_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        info "Homebrew not found. Installing..."
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add brew to PATH for the current session (for M1/M2 Macs)
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    else
        info "Homebrew is already installed."
    fi

    info "Installing dependencies: ${BREW_PACKAGES[*]}"
    # brew update # Skip brew update to avoid potential git errors in non-standard envs during bootstrap
    for pkg in "${BREW_PACKAGES[@]}"; do
        if brew list "$pkg" >/dev/null 2>&1; then
            info "$pkg is already installed."
        else
            info "Installing $pkg..."
            brew install "$pkg"
        fi
    done
}

# --- 3. SSH Setup ---
setup_ssh() {
    info "Setting up SSH directory and permissions..."
    
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    # Install bundled SSH key stubs if they exist in the repository
    if [[ -d "$SCRIPT_DIR/ssh" ]]; then
        info "Installing bundled SSH key stubs from repository..."
        for stub in "$SCRIPT_DIR/ssh"/id_*_sk*; do
            if [[ -f "$stub" ]]; then
                filename=$(basename "$stub")
                if [[ ! -f "$SSH_DIR/$filename" ]]; then
                    cp "$stub" "$SSH_DIR/$filename"
                    chmod 600 "$SSH_DIR/$filename"
                    info "Installed $filename to $SSH_DIR"
                else
                    info "$filename already exists in $SSH_DIR. Skipping."
                fi
            fi
        done
    fi

    # Verify existing key material
    # We look for common FIDO/Security Key patterns
    local key_found=false
    for key in "$SSH_DIR"/id_*_sk "$SSH_DIR"/id_ed25519 "$SSH_DIR"/id_rsa; do
        if [[ -f "$key" ]]; then
            info "Found SSH key: $key"
            chmod 600 "$key"
            key_found=true
        fi
    done

    if [ "$key_found" = false ]; then
        error "No SSH identity files found in $SSH_DIR. Please place your SSH keys/stubs (e.g., id_ed25519_sk) in $SSH_DIR before running this script."
    fi

    # Optional: Manage ~/.ssh/config for GitHub
    if [[ ! -f "$SSH_DIR/config" ]] || ! grep -q "Host github.com" "$SSH_DIR/config"; then
        info "Appending GitHub host entry to $SSH_DIR/config..."
        cat >> "$SSH_DIR/config" <<EOF

Host github.com
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile ~/.ssh/id_ed25519_sk
EOF
        chmod 600 "$SSH_DIR/config"
    else
        info "GitHub entry already exists in SSH config. Preserving."
    fi
}

# --- 4. YubiKey/FIDO Validation ---
validate_yubikey() {
    info "Validating YubiKey/FIDO readiness..."

    # Check if ykman can see a device
    if ! ykman list >/dev/null 2>&1; then
        warn "No YubiKey detected by ykman. Please plug in your YubiKey."
        # Give one more chance or check via system_profiler
        if ! system_profiler SPUSBDataType | grep -iq "Yubico"; then
            error "No YubiKey detected via USB. Actionable fix: Insert your YubiKey and try again."
        fi
    fi

    # Check OpenSSH FIDO capability
    # Brew-installed openssh is usually at /opt/homebrew/bin/ssh (Silicon) or /usr/local/bin/ssh (Intel)
    local ssh_bin
    ssh_bin=$(brew --prefix openssh)/bin/ssh
    if ! "$ssh_bin" -Q key | grep -q "sk"; then
        error "OpenSSH ($ssh_bin) does not seem to support security keys (FIDO). Ensure you are using the Homebrew version of OpenSSH."
    fi

    success "YubiKey/FIDO readiness verified."
}

# --- 5. chezmoi Initialization ---
init_dotfiles() {
    info "Initializing dotfiles with chezmoi from $DOTFILES_REPO..."

    if command -v chezmoi >/dev/null 2>&1; then
        # Use the brew-installed chezmoi
        # Ensure we use the Homebrew SSH for the git clone within chezmoi
        local ssh_path
        ssh_path=$(brew --prefix openssh)/bin/ssh
        
        info "Applying dotfiles... You might be prompted to touch your YubiKey."
        GIT_SSH_COMMAND="$ssh_path" chezmoi init --apply "$DOTFILES_REPO"
    else
        error "chezmoi is not available even after attempted installation."
    fi
}

# --- 6. Homebrew Bundle ---
install_brew_bundle() {
    info "Looking for Brewfile to install additional packages..."
    
    # Common locations for Brewfile after chezmoi apply
    local brewfile=""
    if [[ -f "$HOME/.Brewfile" ]]; then
        brewfile="$HOME/.Brewfile"
    elif [[ -f "$HOME/Brewfile" ]]; then
        brewfile="$HOME/Brewfile"
    fi

    if [[ -n "$brewfile" ]]; then
        info "Installing packages from $brewfile..."
        brew bundle install --file="$brewfile"
        success "Homebrew bundle installation complete."
    else
        warn "No Brewfile found in $HOME/.Brewfile or $HOME/Brewfile. Skipping bundle installation."
    fi
}

# --- Main Flow ---
main() {
    echo "=========================================="
    echo "   macOS Dotfiles Bootstrap Script        "
    echo "=========================================="

    check_preflight
    setup_homebrew
    setup_ssh
    validate_yubikey
    init_dotfiles
    install_brew_bundle

    success "Bootstrap complete! Welcome to your new environment."
    info "Manual step: You may need to restart your shell or run 'source ~/.zshrc' (or equivalent) to see all changes."
}

main "$@"
