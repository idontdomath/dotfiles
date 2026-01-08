# Zsh keybindings for word navigation
# Alt/Option+Arrow keys to move cursor by word (macOS/iTerm2)
# Source: https://gist.github.com/knugie/fc9964695951b4c13ed3

bindkey -e

bindkey '\e[1;3C' forward-word
bindkey '\e[1;3D' backward-word
