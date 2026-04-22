# Nora Init

This script prepares a fresh macOS environment for [nora](https://github.com/simonmittag/nora). 
It configures Homebrew, OpenSSH with YubiKey/FIDO support, and initializes nora via `chezmoi`.

### Prerequisites

- **macOS**: Target system must be running macOS.
- **YubiKey**: A YubiKey configured for FIDO/SSH.
- **Internet**: Required for package downloads and nora initialization.

### Quick Start

Run the following command in your terminal:

```bash
source <(curl -fsSL https://bit.ly/4dgccZQ)
```
or for older versions of bash

```bash
curl -fsSL https://bit.ly/4dgccZQ -o script.sh && source script.sh
```
