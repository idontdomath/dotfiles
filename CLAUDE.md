# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Dotfiles repository for macOS/Linux system configuration. Designed to be compatible with both bash and zsh.

## Setup

Add to your `~/.zshrc` or `~/.bashrc`:
```bash
source ~/code/dotfiles/init.sh
```

## Structure

- `Brewfile` - Homebrew packages (macOS only)
- `init.sh` - Main entry point, sources aliases/keybindings and adds bin/ to PATH
- `aliases.sh` - Shell aliases (bash/zsh compatible)
- `keybindings.zsh` - Zsh keybindings for word navigation (Alt+Arrow keys)
- `bin/` - Executable scripts (automatically added to PATH)
  - `brew-sync` - Install/upgrade Homebrew packages from Brewfile
  - `setup-python` - Install Python via pyenv and set as global version

## Adding Content

### Aliases
Add to `aliases.sh`. Use POSIX-compatible syntax for cross-shell support.

### Scripts
Add executable scripts to `bin/`. Use `#!/bin/sh` shebang for portability across Linux/macOS.

## Selfhosted Lab

A home lab server running at `192.168.86.25` on a secure local network. The project lives at `~/code/selfhosted` and is managed with Ansible. The `run-playbook-selfhosted` alias in `aliases.sh` runs the main playbook against this host.

## Homebrew Commands

```bash
brew bundle          # Install all packages
brew bundle check    # Check what would be installed
brew bundle cleanup  # Remove packages not in Brewfile
```
