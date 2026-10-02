# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Dotfiles repository for macOS/Linux system configuration. Designed to be compatible with both bash and zsh.

## Setup

Add to your `~/.zshrc` or `~/.bashrc`:
```bash
source ~/code/dotfiles/init.sh
```

## Structure

- `Brewfile` - Homebrew packages (macOS only)
- `init.sh` - Main entry point, sources aliases/keybindings and adds bin/ to PATH
- `aliases.sh` - Shell aliases (bash/zsh compatible)
- `keybindings.zsh` - Zsh keybindings for word navigation (Alt+Arrow keys)
- `vpnnat.zsh` - Zsh functions to NAT the UTM VM subnet through the Pritunl split tunnels (macOS only)
- `bin/` - Executable scripts (automatically added to PATH)
  - `brew-sync` - Install/upgrade Homebrew packages from Brewfile
  - `setup-python` - Install Python via pyenv and set as global version

## Adding Content

### Aliases
Add to `aliases.sh`. Use POSIX-compatible syntax for cross-shell support.

### Scripts
Add executable scripts to `bin/`. Use `#!/bin/sh` shebang for portability across Linux/macOS.

## Selfhosted Lab

A home lab server running at `192.168.86.25` on a secure local network. The project lives at `~/code/selfhosted` and is managed with Ansible. The `run-playbook-selfhosted` alias in `aliases.sh` runs the main playbook against this host.

## vpnnat (UTM VM through the VPN)

`vpnnat.zsh` makes the UTM VM (`vmnet-shared`, 192.168.64.0/24) reach the
corporate network through the Pritunl split tunnels running on the host.
vmnet's NAT does not consult the split-tunnel routes, so VM traffic leaves via
the physical interface untranslated and dies. The fix is a pf `nat` rule per
active tunnel, in a dedicated `utm-vpn` anchor.

```bash
vpnnat setup            # once: register the anchors in /etc/pf.conf
vpnnat up               # reconcile the anchor with the active tunnels
vpnnat status           # loaded rules vs rules that should be loaded
vpnnat doctor           # diagnose the known failure modes
vpnnat install-daemon   # LaunchDaemon that reconciles automatically
```

Key invariants, learned the hard way:

- **Never run `pfctl -f /etc/pf.conf` outside `setup`.** It flushes the main
  ruleset, and `nat-anchor "com.apple.internet-sharing"` — which vmnet installs
  at runtime and which is *not* in `pf.conf` — disappears with it, leaving the
  VM without internet. Everything else uses `pfctl -a utm-vpn -f <file>`, which
  replaces only that anchor.
- The `nat on <physical>` rule is the safety net for exactly that case, so it is
  always present, even with no tunnel up.
- utun numbers change on every reconnect. Tunnels are detected as the `utun*`
  interfaces that have an IPv4 address; macOS's own utun (iCloud Private Relay
  and friends) only have `fe80::` link-local.
- Nothing survives a reboot: `com.apple.pfctl.plist` runs `pfctl -f /etc/pf.conf`
  at boot but without `-e`, so pf ends up disabled and the anchor is loaded from
  disk with whatever utun was last written. `net.inet.ip.forwarding` resets to 0.
  The LaunchDaemon's `RunAtLoad` is what covers this.
- A rule pointing at a nonexistent utun loads without any error and is silently
  inert. That is why `doctor` exists.

### Configuration

All knobs live at the top of `vpnnat.zsh` and can be overridden in `~/.zshrc`
*after* the `source`:

| Variable | Default | Purpose |
|---|---|---|
| `VPNNAT_VM_SUBNETS` | auto | VM subnets. Empty = detect every `bridgeN` that has a `vmenet*` member. |
| `VPNNAT_EXPECTED_GATEWAYS` | empty | Whitelist of tunnel gateways. Empty = accept any `utun*` with IPv4. Use it to ignore non-Pritunl tunnels. |
| `VPNNAT_SCOPE` | `any` | `any` = `to any`; `routes` = one pf table per tunnel built from the routes it advertises; `config` = use `VPNNAT_ALLOWED_NETS`. |
| `VPNNAT_BLOCK_WHEN_DOWN` | `0` | With no tunnel up, `block return` the corporate subnets instead of leaking the attempts to the ISP. Needs the `utm-vpn-block` filter anchor (pf rejects `block` inside a `nat-anchor`), which `setup` registers empty and inert. |
| `VPNNAT_CORP_NETS` | cache | Subnets to block. Empty = the union of tunnel routes cached on the last `up`. |
| `VPNNAT_VM_SSH` | empty | e.g. `user@192.168.64.2`. Enables `doctor`'s "from inside the VM" connectivity probe. |
| `VPNNAT_POLL_INTERVAL` | `30` | `watch` loop and the daemon's `StartInterval`. |

### Files

| Path | What |
|---|---|
| `/etc/pf.anchors/utm-vpn` | Generated NAT anchor. Do not edit; `up` overwrites it. |
| `/etc/pf.anchors/utm-vpn-block` | Generated filter anchor (empty unless `VPNNAT_BLOCK_WHEN_DOWN=1`). |
| `/etc/pf.conf.vpnnat-backup-*` | Backup taken by `setup` before touching `pf.conf`. |
| `/var/db/vpnnat/corp-nets` | Cached tunnel subnets, so `down` knows what to block once the routes are gone. |
| `/var/db/vpnnat/pf-token` | `pfctl -E` reference token, when vpnnat is the one that enabled pf. |
| `/var/log/vpnnat.log` | One line per applied change. `vpnnat log [n]` tails it. |

### Open items

- **Datapath confirmed on two of the three tunnels.** After testing from inside
  the VM, `pfctl -a utm-vpn -s nat -v` showed `utun7` translating 1984 packets /
  1.67 MB and `utun8` 52 packets / 34 KB. Packets counted on a `nat on utunN`
  rule are direct proof that VM traffic left through that tunnel with the
  tunnel's address as source, rather than leaking out `en0`. `utun6` still reads
  `Packets: 0`; most likely nothing was addressed to its ranges (`10.100/16`,
  `10.0.13/24`, `10.60/20`, `10.140/14`, `192.168.20/24`, the `192.168.100.x`
  /32s) rather than a fault, since its rule is identical to the other two. To
  close it, ping `10.250.40.1` or `192.168.100.4` from the VM and re-read the
  counters. `pfctl -a utm-vpn -s nat -v` is the tool for this question in
  general: per-rule packet counts tell you which tunnel actually carried traffic.
- **Internal DNS.** The VM resolves against vmnet's resolver and does not resolve
  corporate names. `scutil --dns` shows resolver #1 as `192.168.100.4`,
  `192.168.100.21`, `192.168.100.44` with search domain `lan`, and all three are
  `/32` routes via the main tunnel. So nothing dynamic needs propagating: point
  the VM's resolver at those three and it should resolve, as long as the NAT rule
  for that tunnel is loaded. The fragile part is that a profile change can change
  those addresses — if that happens, derive them from `scutil --dns` instead of
  hardcoding.
- **MTU.** If large transfers hang, drop the VM's MTU to ~1380. Untested.
- **`setup` is optional on this machine**: `/etc/pf.conf` already carries
  `nat-anchor "utm-vpn"`. Running `setup` only adds the (inert) block anchor, and
  costs one full `pfctl -f` reload, which briefly drops the VM's internet. Run it
  when the VM can take the blip, or skip it unless you want
  `VPNNAT_BLOCK_WHEN_DOWN=1`.

## Homebrew Commands

```bash
brew bundle          # Install all packages
brew bundle check    # Check what would be installed
brew bundle cleanup  # Remove packages not in Brewfile
```
