# Sabsh Init

This script prepares a fresh macOS environment for [sabsh](https://github.com/simonmittag/sabsh). 
It configures Homebrew, OpenSSH with YubiKey/FIDO support, and initializes dotfiles via `chezmoi`.

### Prerequisites

- **macOS**: Target system must be running macOS.
- **YubiKey**: A YubiKey configured for FIDO/SSH.
- **Internet**: Required for package downloads and dotfiles initialization.

### Quick Start

Run the following command in your terminal:

```bash
/bin/bash -c "$(curl -fsSL https://bit.ly/4dgccZQ)"
```
