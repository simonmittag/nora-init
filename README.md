# macOS Dotfiles Bootstrap

This repository provides a single bootstrap script to prepare a fresh macOS machine for [chezmoi](https://www.chezmoi.io/) dotfiles management using an SSH/YubiKey-backed GitHub identity.

## Up and Running

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/simonmittag/dotfiles-init/main/bootstrap.sh)"
```

## Prerequisites

- **macOS**: This script is specifically designed for macOS.
- **YubiKey**: A YubiKey configured for FIDO/SSH.
- **SSH Key**: The corresponding SSH public/private key material (or stubs for YubiKey). These are now bundled in the repository for convenience.
- **Internet Connection**: Required to download Homebrew, packages, and your dotfiles.

## What the Script Does

1.  **System Check**: Verifies that the OS is macOS and that `curl` and `git` are available.
2.  **Homebrew**: Installs Homebrew if it's missing.
3.  **Dependencies**: Installs or updates the following via Homebrew:
    - `openssh`: Latest OpenSSH with FIDO support.
    - `libfido2`: Library for FIDO2 devices.
    - `ykman`: YubiKey Manager CLI.
    - `chezmoi`: Dotfiles manager.
4.  **SSH Setup**:
    - Ensures `~/.ssh` exists with correct permissions (`700`).
    - Installs bundled SSH key stubs (`id_ed25519_sk_private_a`) if they are missing from `~/.ssh`. These can be copied from a local clone or downloaded directly from GitHub if the script is run via `curl`.
    - Validates that SSH key files are present.
    - Adds a managed SSH configuration entry for GitHub if not already present, preserving your existing `~/.ssh/config`.
5.  **YubiKey Validation**: Confirms a YubiKey is detected and that OpenSSH supports security keys (`sk` keys).
6.  **Dotfiles Initialization**: Runs `chezmoi init --apply git@github.com:simonmittag/dotfiles.git`.
7.  **Homebrew Bundle**: Installs additional packages from your `Brewfile` (if found in `~/.Brewfile` or `~/Brewfile`) after dotfiles are applied.
