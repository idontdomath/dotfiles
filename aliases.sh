# Shell aliases - compatible with bash and zsh
# Source this file from your .bashrc or .zshrc:
#   source ~/code/dotfiles/aliases.sh

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# List files
alias ll='ls -lah'
alias la='ls -A'

# Git shortcuts
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'

# Safety nets
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# macOS WiFi controls
alias wifi-off='networksetup -setairportpower en0 off'
alias wifi-on='networksetup -setairportpower en0 on'
alias wifi-status='networksetup -getairportpower en0'

# macOS DNS
alias flush-dns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder && echo "DNS cache flushed"'
