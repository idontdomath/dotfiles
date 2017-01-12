alias wifi-up="networksetup -setairportpower en0 on"
alias wifi-down="networksetup -setairportpower en0 off"
alias trash-empty='rm -R ~/.Trash/*'
alias flush-dns="sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
