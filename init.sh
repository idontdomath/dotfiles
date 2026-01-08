#!/bin/sh
# Dotfiles initialization - compatible with bash and zsh
# Source this file from your .bashrc or .zshrc:
#   source ~/code/dotfiles/init.sh

# Determine the dotfiles directory (works even if symlinked)
if [ -n "$BASH_SOURCE" ]; then
    DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "$ZSH_VERSION" ]; then
    DOTFILES_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    DOTFILES_DIR="$HOME/code/dotfiles"
fi

export DOTFILES_DIR

# Source aliases
if [ -f "$DOTFILES_DIR/aliases.sh" ]; then
    . "$DOTFILES_DIR/aliases.sh"
fi

# Add bin directory to PATH
if [ -d "$DOTFILES_DIR/bin" ]; then
    export PATH="$DOTFILES_DIR/bin:$PATH"
fi

# Source zsh keybindings (zsh only)
if [ -n "$ZSH_VERSION" ] && [ -f "$DOTFILES_DIR/keybindings.zsh" ]; then
    . "$DOTFILES_DIR/keybindings.zsh"
fi
