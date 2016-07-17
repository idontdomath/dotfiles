alias postgres-local-start='pg_ctl -D /usr/local/var/postgres -l /usr/local/var/postgres/server.log start'
alias postgres-local-stop='pg_ctl -D /usr/local/var/postgres stop -s -m fast'
alias postgres-local-logs='tail -f /usr/local/var/postgres/server.log' 
