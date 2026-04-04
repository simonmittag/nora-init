#!/usr/bin/env bash

# prepare machine for sabsh installation

set -euo pipefail

# --- Configuration ---
SABSH_REPO="git@github.com:simonmittag/sabsh.git"
STUB_REPO_URL="https://raw.githubusercontent.com/simonmittag/sabsh-init/main/ssh"
BREW_PACKAGES=("openssh" "libfido2" "ykman" "chezmoi")
# Ensure HOME is set (Bash -u safety)
export HOME="${HOME:-$(eval echo ~$(whoami))}"
SSH_DIR="${HOME}/.ssh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

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

# --- 2. User Confirmation ---
ask_to_continue() {
    # Skip prompt if not running in a terminal (e.g., CI or piped)
    if [[ ! -t 0 ]]; then
        info "Non-interactive environment detected. Proceeding automatically..."
        return 0
    fi

    echo -ne "\033[0;33m[WARN]\033[0m This will overwrite your bash configuration. Do you want to continue? "
    local prompt_hint="> n/y default: n"
    local input=""
    local show_hint=true
    # Print the initial hint (no newline, but we must avoid \033[1G for first call)
    echo -ne "\033[90m$prompt_hint\033[0m"

    while true; do
        # Read a single character, -s for silent (don't echo), -n 1 for one char
        # Use a timeout of 0.1 to avoid blocking forever and allow for state checks if needed, 
        # but standard read is fine here.
        if read -rsn 1 key; then
            # If any key is pressed, we clear the hint if it was showing
            if [ "$show_hint" = true ]; then
                # Move back to cover the hint and clear it
                echo -ne "\r\033[K\033[0;33m[WARN]\033[0m This will overwrite your bash configuration. Do you want to continue? > "
                show_hint=false
            fi

            # Handle backspace (ASCII 127 or 8)
            if [[ $key == $'\x7f' || $key == $'\b' ]]; then
                if [[ -n "$input" ]]; then
                    input="${input%?}"
                    echo -ne "\r\033[K\033[0;33m[WARN]\033[0m This will overwrite your bash configuration. Do you want to continue? > $input"
                fi
                # If input becomes empty, restore the hint
                if [[ -z "$input" ]]; then
                    echo -ne "\r\033[K\033[0;33m[WARN]\033[0m This will overwrite your bash configuration. Do you want to continue? \033[90m$prompt_hint\033[0m"
                    show_hint=true
                fi
                continue
            fi

            # Handle Enter (key is empty string with read -n 1)
            if [[ -z "$key" ]]; then
                local final_val="${input:-n}"
                # Delete the prompt line completely
                echo -ne "\r\033[K"
                if [[ "$final_val" =~ ^[Yy]$ ]]; then
                    return 0
                else
                    info "Setup aborted by user."
                    exit 0
                fi
            fi

            if [[ "$key" =~ ^[YyNn]$ ]]; then
                input="$key"
                echo -ne "\r\033[K"
                if [[ "$key" =~ ^[Yy]$ ]]; then
                    return 0
                else
                    info "Setup aborted by user."
                    exit 0
                fi
            fi
            # Ignore other keys (keep the prompt)
        fi
    done
}

# --- 3. Homebrew Setup ---
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

    # Install bundled SSH key stubs
    if [[ -d "$SCRIPT_DIR/ssh" ]]; then
        info "Installing bundled SSH key stubs from local repository..."
        for stub in "$SCRIPT_DIR/ssh"/id_*; do
            if [[ -f "$stub" ]]; then
                filename=$(basename "$stub")
                # Only process security key stubs (private or public)
                [[ "$filename" != *_sk* ]] && continue

                if [[ ! -f "$SSH_DIR/$filename" ]]; then
                    cp "$stub" "$SSH_DIR/$filename"
                    chmod 600 "$SSH_DIR/$filename"
                    info "Installed $filename to $SSH_DIR with safe permissions"
                else
                    info "$filename already exists in $SSH_DIR. Skipping."
                fi
            fi
        done
    else
        info "Local stubs not found. Attempting to download from GitHub..."
        local stubs=("id_ed25519_sk_private_a" "id_ed25519_sk_private_a.pub")
        for filename in "${stubs[@]}"; do
            if [[ ! -f "$SSH_DIR/$filename" ]]; then
                info "Downloading $filename..."
                if curl -fsSL "$STUB_REPO_URL/$filename" -o "$SSH_DIR/$filename"; then
                    chmod 600 "$SSH_DIR/$filename"
                    info "Downloaded $filename to $SSH_DIR with safe permissions"
                else
                    warn "Failed to download $filename from GitHub."
                fi
            else
                info "$filename already exists in $SSH_DIR. Skipping download."
            fi
        done
    fi

    # Verify existing key material
    # We look for common FIDO/Security Key patterns
    local key_found=false
    # Use a broad glob and filter in-script for better reliability across different shells/environments
    for key in "$SSH_DIR"/id_*; do
        # Skip if not a regular file or if it's a public key
        [[ ! -f "$key" ]] && continue
        [[ "$key" == *.pub ]] && continue

        filename=$(basename "$key")
        # Match security keys (typically contain _sk) or standard identity files
        if [[ "$filename" == *_sk* ]] || [[ "$filename" == "id_ed25519" ]] || [[ "$filename" == "id_rsa" ]]; then
            info "Found SSH key: $key"
            chmod 600 "$key"
            key_found=true
        fi
    done

    if [ "$key_found" = false ]; then
        error "No SSH identity files found in $SSH_DIR. Please place your SSH keys/stubs (e.g., id_ed25519_sk_private_a) in $SSH_DIR before running this script."
    fi

    # Optional: Manage ~/.ssh/config for GitHub
    if [[ ! -f "$SSH_DIR/config" ]] || ! grep -q "Host github.com" "$SSH_DIR/config"; then
        info "Appending GitHub host entry to $SSH_DIR/config..."
        cat >> "$SSH_DIR/config" <<EOF

Host github.com
    AddKeysToAgent yes
    UseKeychain yes
    IdentityFile ~/.ssh/id_ed25519_sk_private_a
    IdentitiesOnly yes
EOF
        chmod 600 "$SSH_DIR/config"
    else
        info "GitHub entry already exists in SSH config. Preserving."
    fi

    # Add github.com to known_hosts to avoid prompt
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
        info "Adding github.com to ~/.ssh/known_hosts..."
        ssh-keyscan -H github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
        chmod 600 "$SSH_DIR/known_hosts"
    fi
}

# --- 4. YubiKey/FIDO Validation ---
validate_yubikey() {
    info "Validating YubiKey/FIDO readiness..."

    # Check if ykman can see a device
    if ! ykman list >/dev/null 2>&1; then
        warn "🔐 No YubiKey detected by ykman. Please plug in your YubiKey."
        # Give one more chance or check via system_profiler
        if ! system_profiler SPUSBDataType | grep -iq "Yubico"; then
            error "🔐 No YubiKey detected via USB. Actionable fix: Insert your YubiKey and try again."
        fi
    fi

    # Check OpenSSH FIDO capability
    # Brew-installed openssh is usually at /opt/homebrew/bin/ssh (Silicon) or /usr/local/bin/ssh (Intel)
    local ssh_bin
    ssh_bin=$(brew --prefix openssh)/bin/ssh
    if ! "$ssh_bin" -Q key | grep -q "sk"; then
        error "🔐 OpenSSH ($ssh_bin) does not seem to support security keys (FIDO). Ensure you are using the Homebrew version of OpenSSH."
    fi

    success "YubiKey/FIDO readiness verified."
}

# --- 5. SSH Connectivity Test ---
test_ssh_connection() {
    info "Testing SSH connectivity to GitHub..."
    local ssh_path
    ssh_path=$(brew --prefix openssh)/bin/ssh

    # Try to connect to GitHub. Exit code 1 is expected for successful auth but no shell.
    # We use || true or an if check to ensure the script doesn't exit under set -e
    info "🔐 You might need to touch your YubiKey now..."
    local ssh_output
    ssh_output=$("$ssh_path" -v -T -o StrictHostKeyChecking=yes -i "$SSH_DIR/id_ed25519_sk_private_a" git@github.com 2>&1 || true)

    if echo "$ssh_output" | grep -q "Hi simonmittag!"; then
        success "GitHub SSH connectivity verified."
    else
        warn "SSH connectivity test to GitHub failed or returned unexpected output."
        echo "$ssh_output"
        error "Could not verify GitHub SSH access. Please ensure your YubiKey is registered with GitHub and the stub is correct."
    fi
}

# --- 6. sabsh Initialization ---
init_sabsh() {
    info "Initializing sabsh with chezmoi from $SABSH_REPO..."

    if command -v chezmoi >/dev/null 2>&1; then
        # Use the brew-installed chezmoi
        # Ensure we use the Homebrew SSH for the git clone within chezmoi
        local ssh_path
        ssh_path=$(brew --prefix openssh)/bin/ssh
        
        info "Applying sabsh... You might be prompted to touch your YubiKey."
        # Use explicit identity file in GIT_SSH_COMMAND to bypass any config issues
        GIT_SSH_COMMAND="$ssh_path -o IdentitiesOnly=yes -i $SSH_DIR/id_ed25519_sk_private_a" chezmoi init --apply "$SABSH_REPO"
    else
        error "chezmoi is not available even after attempted installation."
    fi
}

# --- 7. Homebrew Bundle ---
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

# --- 8. Final Environment Setup ---
source_bash_environment() {
    if [[ -f "$HOME/.bash_profile" ]]; then
        info "Sourcing ~/.bash_profile..."
        # Note: sourcing it within the script's subshell only affects the script,
        # but the user's manual step should still be encouraged.
        # However, the task specifically asked for sourcing.
        source "$HOME/.bash_profile" || warn "Failed to source ~/.bash_profile"
    fi
}

# --- Main Flow ---
main() {
    echo "=========================================="
    echo "  📋 sabsh bootstrap script               "
    echo "=========================================="

    check_preflight
    ask_to_continue
    setup_ssh
    setup_homebrew
    validate_yubikey
    test_ssh_connection
    init_sabsh
    install_brew_bundle
    source_bash_environment

    success "setup complete - check your new prompt below!"
}

main "$@"
