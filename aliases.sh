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

# PostgreSQL (Homebrew)
alias pg-start='brew services start postgresql'
alias pg-stop='brew services stop postgresql'

# Network
alias ports='lsof -i -P -n | grep LISTEN'

# Google Chrome Canary with remote debug at port 9222
alias chrome-canary-debug='/Applications/Google\ Chrome\ Canary.app/Contents/MacOS/Google\ Chrome\ Canary --remote-debugging-port=9222 &'
alias run-playbook-selfhosted='HOME=/Users/ak/code/selfhosted ANSIBLE_CONFIG=/Users/ak/code/selfhosted/ansible.cfg ansible-playbook -i /Users/ak/code/selfhosted/deploy/ansible/inventory/hosts.ini /Users/ak/code/selfhosted/deploy/ansible/site.yml --private-key ~/.ssh/selfhosted_ansible --ask-become-pass'

# Selfhosted SSHFS mount/unmount
alias mount-selfhosted='mkdir -p /Users/ak/Selfhosted-Data && sshfs ak@192.168.86.25:/opt/selfhosted/data /Users/ak/Selfhosted-Data'
alias umount-selfhosted='diskutil unmount /Users/ak/Selfhosted-Data'
