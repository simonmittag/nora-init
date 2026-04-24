#!/usr/bin/env bash

# prepare machine for nora bootstrap

set -euo pipefail

# --- Configuration ---
NORA_REPO="git@github.com:simonmittag/nora.git"
NORA_INIT_URL="https://raw.githubusercontent.com/simonmittag/nora-init/main"
BOOTSTRAP_SSH_KEY=""
BOOTSTRAP_SSH_KEY_IS_TEMP=false
BREW_PACKAGES=("openssh" "libfido2" "ykman" "chezmoi" "age" "age-plugin-yubikey")
# Ensure HOME is set (Bash -u safety)
export HOME="${HOME:-$(eval echo ~$(whoami))}"
SSH_DIR="${HOME}/.ssh"
NORA_DIR="${HOME}/.local/share/nora"
CHEZMOI_DEFAULT_DIR_INVALID="${HOME}/.local/share/chezmoi"
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
ask_user() {
    local message="$1"
    local default="${2:-n}" # default to 'n'
    local prompt_hint

    if [[ "$default" == "y" ]]; then
        prompt_hint="\033[1;32m>\033[0m \033[90my/n default: y\033[0m"
    else
        prompt_hint="\033[1;32m>\033[0m \033[90mn/y default: n\033[0m"
    fi

    warn "$message"
    local input=""
    local show_hint=true
    # Print the initial hint and move cursor back 14 chars to focus the default
    echo -ne "$prompt_hint\033[14D"

    while true; do
        if read -rsn 1 key; then
            # Handle Enter (key is empty string with read -n 1)
            if [[ -z "$key" ]]; then
                local final_val="${input:-$default}"
                # Delete the prompt line completely
                echo -ne "\r\033[K"
                if [[ "$final_val" =~ ^[Yy]$ ]]; then
                    return 0
                else
                    return 1
                fi
            fi

            # Handle Backspace
            if [[ $key == $'\x7f' || $key == $'\b' ]]; then
                if [[ -n "$input" ]]; then
                    input="${input%?}"
                    echo -ne "\r\033[K\033[1;32m>\033[0m $input"
                fi
                # If input becomes empty, restore the hint
                if [[ -z "$input" ]]; then
                    echo -ne "\r\033[K$prompt_hint\033[14D"
                    show_hint=true
                fi
                continue
            fi

            # Handle Valid Selection
            if [[ "$key" =~ ^[YyNn]$ ]]; then
                if [ "$show_hint" = true ]; then
                    # Clear the hint and start input
                    echo -ne "\r\033[K\033[1;32m>\033[0m "
                    show_hint=false
                fi
                input="$key"
                echo -ne "\r\033[K"
                if [[ "$key" =~ ^[Yy]$ ]]; then
                    return 0
                else
                    return 1
                fi
            fi
            # Ignore other keys (keep the prompt and hint)
        fi
    done
}

ask_to_continue() {
    # Skip prompt if not running in a terminal (e.g., CI or piped)
    if [[ ! -t 0 ]]; then
        info "Non-interactive environment detected. Proceeding automatically..."
        return 0
    fi

    if ! ask_user "This will overwrite your bash configuration. Do you want to continue?" "n"; then
        error "Setup aborted by user."
        exit 1
    fi
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

    # Identify or download the bootstrap key
    local bootstrap_filename="id_ed25519_sk_private_a"
    
    if [[ -f "$SCRIPT_DIR/ssh/$bootstrap_filename" ]]; then
        info "Using bundled SSH key stub from local repository..."
        BOOTSTRAP_SSH_KEY="$SCRIPT_DIR/ssh/$bootstrap_filename"
        chmod 600 "$BOOTSTRAP_SSH_KEY"
    elif [[ -f "$SSH_DIR/$bootstrap_filename" ]]; then
        info "Using existing SSH key stub in $SSH_DIR..."
        BOOTSTRAP_SSH_KEY="$SSH_DIR/$bootstrap_filename"
    else
        info "Bootstrap stub not found locally. Attempting to download..."
        local temp_ssh_dir
        temp_ssh_dir=$(mktemp -d)
        BOOTSTRAP_SSH_KEY="$temp_ssh_dir/$bootstrap_filename"
        if curl -fsSL "${NORA_INIT_URL}/ssh/$bootstrap_filename" -o "$BOOTSTRAP_SSH_KEY"; then
            chmod 600 "$BOOTSTRAP_SSH_KEY"
            info "Downloaded $bootstrap_filename to temporary location"
            BOOTSTRAP_SSH_KEY_IS_TEMP=true
        else
            warn "Failed to download $bootstrap_filename from GitHub."
            rm -rf "$temp_ssh_dir"
            BOOTSTRAP_SSH_KEY=""
        fi
    fi

    # Verify existing key material
    # We look for common FIDO/Security Key patterns
    local key_found=false
    if [[ -n "$BOOTSTRAP_SSH_KEY" && -f "$BOOTSTRAP_SSH_KEY" ]]; then
        key_found=true
    fi

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
        error "No SSH identity files found. Please ensure you have your SSH keys or stubs (e.g., $bootstrap_filename) available."
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
    warn "🔐 You might need to touch your YubiKey now..."
    local ssh_output
    ssh_output=$("$ssh_path" -v -T -o StrictHostKeyChecking=yes -i "$BOOTSTRAP_SSH_KEY" git@github.com 2>&1 || true)

    if echo "$ssh_output" | grep -q "Hi simonmittag!"; then
        success "GitHub SSH connectivity verified."
    else
        warn "SSH connectivity test to GitHub failed or returned unexpected output."
        echo "$ssh_output"
        error "Could not verify GitHub SSH access. Please ensure your YubiKey is registered with GitHub and the stub is correct."
    fi
}

# --- 6. nora Initialization ---
safe_cleanup() {
    local target="$1"
    local label="$2"

    [[ ! -d "$target" && ! -L "$target" ]] && return 0

    local creation_date
    creation_date=$(stat -f "%SB" "$target" 2>/dev/null || echo "unknown date")

    if [[ -L "$target" ]]; then
        local link_target
        link_target=$(readlink "$target")
        if ask_user "Existing $label is a symlink to $link_target (created: $creation_date). Deleting its target contents is recommended. Wipe target but keep symlink?" "y"; then
            info "Wiping target of $label symlink: $link_target..."
            local abs_target
            abs_target=$(readlink -f "$target")
            if [[ -n "$abs_target" && "$abs_target" != "$HOME" && "$abs_target" != "/" ]]; then
                rm -rf "$abs_target"
                mkdir -p "$abs_target"
            else
                error "Target path $abs_target is too dangerous to wipe automatically."
            fi
        else
            error "Setup aborted by user."
        fi
    else
        if ask_user "Existing $label directory found (created: $creation_date). Deleting it is recommended. Delete it?" "y"; then
            info "Removing existing $label directory $target..."
            rm -rf "$target"
        else
            error "Setup aborted by user."
        fi
    fi
}

init_nora() {
    info "Initializing nora with chezmoi from $NORA_REPO..."

    if command -v chezmoi >/dev/null 2>&1; then
        # Use the brew-installed chezmoi
        # Ensure we use the Homebrew SSH for the git clone
        local ssh_path
        ssh_path=$(brew --prefix openssh)/bin/ssh

        # Remove default chezmoi directory if it exists
        safe_cleanup "$CHEZMOI_DEFAULT_DIR_INVALID" "chezmoi"

        # 1. Clone the repository manually so we can place identities.json before chezmoi init
        safe_cleanup "$NORA_DIR" "nora"
        info "Cloning $NORA_REPO to $NORA_DIR..."
        GIT_SSH_COMMAND="$ssh_path -o IdentitiesOnly=yes -i $BOOTSTRAP_SSH_KEY" git clone "$NORA_REPO" "$NORA_DIR"

        # 2. Decrypt identities.json
        local age_file="$SCRIPT_DIR/identities/identities.json.age"
        local delete_age_file=false

        if [[ ! -f "$age_file" ]]; then
            info "identities.json.age not found locally. Attempting to download..."
            age_file=$(mktemp)
            if curl -fsSL "${NORA_INIT_URL}/identities/identities.json.age" -o "$age_file"; then
                delete_age_file=true
            else
                warn "Failed to download identities.json.age from GitHub."
                rm -f "$age_file"
                age_file=""
            fi
        fi

        if [[ -n "$age_file" && -f "$age_file" ]]; then
            info "Decrypting identities.json using age and YubiKey..."
            local temp_id
            temp_id=$(mktemp)
            # Try to get identity. If no slot specified, plugin usually picks the first one or prompts.
            if age-plugin-yubikey --identity > "$temp_id" 2>/dev/null && grep -q "age1" "$temp_id"; then
                age -d -i "$temp_id" -o "$NORA_DIR/identities.json" "$age_file"
                rm "$temp_id"
                success "Decrypted identities.json to $NORA_DIR/identities.json"
            else
                # Fallback to searching for a slot number if direct attempt failed
                local slot
                slot=$(age-plugin-yubikey --list 2>/dev/null | grep -i "Slot" | grep -oE '[0-9]+' | head -n 1 || true)
                if [[ -n "$slot" ]] && age-plugin-yubikey --identity --slot "$slot" > "$temp_id" 2>/dev/null && grep -q "age1" "$temp_id"; then
                    age -d -i "$temp_id" -o "$NORA_DIR/identities.json" "$age_file"
                    rm "$temp_id"
                    success "Decrypted identities.json to $NORA_DIR/identities.json"
                else
                    rm -f "$temp_id"
                    warn "No YubiKey found for decryption. Please ensure it is plugged in."
                fi
            fi

            if [[ "$delete_age_file" == true ]]; then
                rm "$age_file"
            fi
        else
            warn "No identities.json.age found or downloaded. Skipping decryption."
        fi

        warn "Applying nora... You might be prompted to touch your YubiKey."
        # 3. Initialize and apply chezmoi using the prepared source directory
        chezmoi init --apply --source "$NORA_DIR"

        # 4. Explicitly set chezmoi's source directory to NORA_DIR permanently in its config
        info "Persisting chezmoi source directory to $NORA_DIR..."
        local config_file="${HOME}/.config/chezmoi/chezmoi.toml"
        mkdir -p "$(dirname "$config_file")"
        if ! grep -q "^[[:space:]]*sourceDir[[:space:]]*=" "$config_file" 2>/dev/null; then
            if [[ -f "$config_file" ]]; then
                local tmp_config
                tmp_config=$(mktemp)
                { printf 'sourceDir = "%s"\n' "$NORA_DIR"; cat "$config_file"; } > "$tmp_config" || error "Failed to update chezmoi config."
                mv "$tmp_config" "$config_file" || error "Failed to update chezmoi config."
            else
                printf 'sourceDir = "%s"\n' "$NORA_DIR" > "$config_file" || error "Failed to create chezmoi config."
            fi
        else
            # Use sed with a pipe separator since $NORA_DIR is a path
            sed -i '' "s|^[[:space:]]*sourceDir[[:space:]]*=.*|sourceDir = \"$NORA_DIR\"|" "$config_file" || error "Failed to update chezmoi source directory."
        fi
        success "chezmoi source directory recorded."
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
verify_environment() {
    # Verify chezmoi directory is definitely not there
    if [[ -L "$CHEZMOI_DEFAULT_DIR_INVALID" ]]; then
        success "Verified $CHEZMOI_DEFAULT_DIR_INVALID exists as a symlink."
    elif [[ -d "$CHEZMOI_DEFAULT_DIR_INVALID" ]]; then
        error "$CHEZMOI_DEFAULT_DIR_INVALID still exists as a directory. This should not happen."
    else
        success "Verified $CHEZMOI_DEFAULT_DIR_INVALID does not exist."
    fi
}

# --- 9. Cleanup ---
ask_to_wipe_bootstrap_files() {
    # Skip prompt if not running in a terminal
    if [[ ! -t 0 ]]; then
        return 1
    fi

    ask_user "wipe the bootstrap files?" "y"
}

cleanup_bootstrap() {
    info "Wiping bootstrap files..."
    if [[ "$NORA_DIR" != "$HOME" && "$NORA_DIR" != "/" ]]; then
        warn "Wiping $NORA_DIR"
        rm -rf "$NORA_DIR/.git"
        rm -rf "$NORA_DIR"

        # Wipe temporary bootstrap key if it was downloaded
        if [[ "$BOOTSTRAP_SSH_KEY_IS_TEMP" == true && -n "$BOOTSTRAP_SSH_KEY" ]]; then
            local temp_dir
            temp_dir=$(dirname "$BOOTSTRAP_SSH_KEY")
            warn "Removing temporary SSH key at $BOOTSTRAP_SSH_KEY..."
            rm -rf "$temp_dir"
        fi

        # Additionally wipe the temporary subfolders in SCRIPT_DIR
            for dir in "identities" "json" "ssh"; do
                local target="$SCRIPT_DIR/$dir"
                if [[ -d "$target" && "$target" != "$HOME" && "$target" != "/" ]]; then
                    warn "Wiping $target..."
                    rm -rf "$target"
                fi
            done
    else
        warn "Safe guard: NORA_DIR is $NORA_DIR, skipping wipe."
    fi
}

# --- Main Flow ---
main() {
    echo "◉ nora bootstrap script."
    echo ""

    check_preflight
    ask_to_continue
    setup_ssh
    setup_homebrew
    validate_yubikey
    test_ssh_connection
    init_nora
    install_brew_bundle
    verify_environment

    if ask_to_wipe_bootstrap_files; then
        cleanup_bootstrap
    fi

    success "setup complete - check your new prompt below!"
    info "Handoff to fresh login shell..."
    exec bash -l || error "Failed to launch login shell."
}

main "$@"
