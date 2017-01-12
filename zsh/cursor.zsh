# Use alt+arrow to move cursor by word
# https://gist.github.com/knugie/fc9964695951b4c13ed3
# Mac OS X El Capitan # iTerm2 # zsh
# ~/.zshrc  
bindkey -e
bindkey '\e\e[C' forward-word
bindkey '\e\e[D' backward-word
