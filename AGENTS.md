# Repository Guidelines

## Project Structure & Module Organization
- `init.sh` is the entry point that wires aliases, keybindings, PATH, and optional rbenv setup.
- `aliases.sh` holds cross-shell aliases (bash/zsh).
- `keybindings.zsh` contains zsh-only keybindings.
- `bin/` contains executable helper scripts (e.g., `brew-sync`, `setup-python`, `setup-ruby`) that are added to PATH.
- `Brewfile` lists Homebrew packages for macOS. There is no separate tests/ directory.

## Build, Test, and Development Commands
- `source ~/code/dotfiles/init.sh` loads the dotfiles into your current shell session.
- `brew-sync` installs/upgrades packages from `Brewfile` (macOS only).
- `brew bundle`, `brew bundle check`, `brew bundle cleanup` manage Brewfile packages directly.
- `bin/setup-python` and `bin/setup-ruby` bootstrap language runtimes via pyenv/rbenv.

## Coding Style & Naming Conventions
- Shell scripts target POSIX `sh` compatibility unless explicitly zsh-only (e.g., `keybindings.zsh`).
- Indentation uses 4 spaces in shell conditionals and blocks.
- Keep scripts in `bin/` executable with a portable shebang (e.g., `#!/bin/sh`).
- Use hyphenated, verb-based script names (e.g., `brew-sync`, `setup-python`).

## Testing Guidelines
- No automated test suite is defined. Validate changes manually by sourcing `init.sh` and running any affected scripts.
- When changing Homebrew configuration, run `brew bundle check` to confirm state.

## Commit & Pull Request Guidelines
- Commit messages follow a conventional style such as `feat: ...` or `fix: ...`.
- Prefer small, focused commits that map to a single change.
- Pull requests should include a concise summary, manual verification notes (commands run), and any platform-specific impact (macOS vs Linux). Screenshots are not expected.

## Security & Configuration Tips
- Avoid committing machine-specific secrets or tokens; keep personal overrides in local shell rc files.
- Keep macOS-only changes isolated to `Brewfile` or scripts that guard on platform checks.
