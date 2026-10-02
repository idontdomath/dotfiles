# Dotfiles

Personal idontdomath's dotfiles for macOS/Linux. Compatible with bash and zsh.

## What's Included

- **Shell aliases** - Common shortcuts for git, navigation, and system tasks
- **Zsh keybindings** - Alt+Arrow keys for word navigation in terminal
- **Homebrew packages** - Curated list of CLI tools and applications (macOS)
- **Utility scripts** - `brew-sync` for package management, `setup-python` for pyenv setup
- **vpnnat** - Routes a UTM VM through the host's Pritunl split tunnels via pf NAT (macOS)

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

## vpnnat

Lets a UTM VM on *Shared Network* reach the corporate network through the
Pritunl split tunnels connected on the host. One pf NAT rule per active tunnel,
regenerated automatically as tunnels come and go.

```bash
vpnnat setup            # once: register the pf anchors
vpnnat up               # reconcile with the currently active tunnels
vpnnat status           # what is loaded vs what should be
vpnnat doctor           # diagnose pf, forwarding, stale rules, connectivity
vpnnat install-daemon   # reconcile automatically on network changes and at boot
```

Configuration lives at the top of `vpnnat.zsh` and can be overridden in
`~/.zshrc` after the `source`: `VPNNAT_VM_SUBNETS`, `VPNNAT_EXPECTED_GATEWAYS`,
`VPNNAT_SCOPE`, `VPNNAT_ALLOWED_NETS`, `VPNNAT_BLOCK_WHEN_DOWN`,
`VPNNAT_CORP_NETS`, `VPNNAT_VM_SSH`, `VPNNAT_POLL_INTERVAL`. Run `vpnnat help`
for the short version.

Logs go to `/var/log/vpnnat.log` (`vpnnat log`). See the vpnnat section in
`CLAUDE.md` for the design constraints, file layout, and open items (internal
DNS, MTU, end-to-end verification).
