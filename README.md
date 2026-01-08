# Dotfiles

Personal idontdomath's dotfiles for macOS/Linux. Compatible with bash and zsh.

## What's Included

- **Shell aliases** - Common shortcuts for git, navigation, and system tasks
- **Zsh keybindings** - Alt+Arrow keys for word navigation in terminal
- **Homebrew packages** - Curated list of CLI tools and applications (macOS)
- **Utility scripts** - `brew-sync` for package management, `setup-python` for pyenv setup

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/dotfiles.git ~/code/dotfiles
   ```

2. Add to your `~/.zshrc` or `~/.bashrc`:
   ```bash
   source ~/code/dotfiles/init.sh
   ```

3. Install Homebrew packages (macOS):
   ```bash
   brew-sync
   ```
