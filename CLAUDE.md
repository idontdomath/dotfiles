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
vpnnat watch            # reconcile in a loop, in the foreground
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
  Nothing reapplies this automatically by design (see Security below): run
  `vpnnat up` after a reboot or a reconnect, or leave `vpnnat watch` running.
- **`net.inet.ip.forwarding` is host-wide.** There is no way to scope it to the
  vmnet bridge. `up` turns it on and nothing turns it back off, so a roaming
  laptop keeps IP forwarding enabled beyond the window where the VM actually
  needs it. The exposure is bounded by the NAT rules being scoped
  `from <vm subnet>`, so this is not an open relay, but it is worth knowing.
- **Only the *set* of tunnel interface names matters, not which profile is on
  which.** Rules are `nat on utunN ... -> (utunN)`, self-referential and
  interface-scoped, so a reconnect that reshuffles which profile owns which
  utun number needs no change as long as the same names are still tunnels.
  Observed in practice: over two days the three profiles rotated utun numbers
  completely while the anchor stayed correct.
- A rule pointing at a nonexistent utun loads without any error and is silently
  inert. That is why `doctor` exists.
- **Two zsh trap gotchas, both hit in `watch`.** A `trap ... INT` only runs the
  handler; it does *not* terminate the enclosing loop. The first version
  deleted the pidfile on Ctrl-C and left the reconcile loop running, orphaned
  and invisible to `doctor`. The loop now exits via a flag the handler sets.
  And `trap` inside a function is *global* in zsh unless `LOCAL_TRAPS` is set,
  so the handler leaked into the caller's interactive shell and re-ran on every
  later Ctrl-C; `watch` now sets `local_options local_traps`.

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
| `VPNNAT_POLL_INTERVAL` | `30` | Seconds between `watch` iterations. |
| `VPNNAT_BROAD_PREFIX` | `7` | `status`/`doctor` warn when a tunnel advertises a prefix this broad or broader, or an explicit default. Guards against a profile silently sending all VM traffic over the VPN while `VPNNAT_SCOPE=any`. `10.0.0.0/8` is a legitimate corporate route, hence 7 rather than 8. |

### Files

| Path | What |
|---|---|
| `/etc/pf.anchors/utm-vpn` | Generated NAT anchor. Do not edit; `up` overwrites it. |
| `/etc/pf.anchors/utm-vpn-block` | Generated filter anchor (empty unless `VPNNAT_BLOCK_WHEN_DOWN=1`). |
| `/etc/pf.conf.vpnnat-backup-*` | Backup taken by `setup` before touching `pf.conf`. |
| `/var/db/vpnnat/corp-nets` | Cached tunnel subnets, so `down` knows what to block once the routes are gone. |
| `/var/db/vpnnat/pf-token` | `pfctl -E` reference token, when vpnnat is the one that enabled pf. |
| `/var/db/vpnnat/watch.pid` | PID of a running `watch`, so `doctor` can report it. Removed on exit. A bare PID is not trusted on its own: the file survives reboots and `kill -9`, so it is rejected when its mtime predates `kern.boottime` or when the PID is not a live zsh. |
| `/var/log/vpnnat.log` | One line per applied change, `root:wheel 0640`. `vpnnat log [n]` reads it with sudo. |

### Security

- **There is deliberately no LaunchDaemon.** An earlier version installed one
  that ran as root and re-sourced `vpnnat.zsh` from the git checkout in `$HOME`
  every 30 seconds. Since that path is user-writable, anything that achieved
  code execution as the user — or any commit that landed in the repo and got
  pulled — would have gained unattended, passwordless, persistent root. That
  turns "the user account is compromised" into "root is compromised", a much
  larger blast radius than this tool needs. `watch` runs in the foreground
  under the operator's own control instead. If a daemon is ever wanted, copy
  the script to a root-owned path (e.g. `/Library/PrivilegedHelperTools/`) at
  install time and point the plist there, so root never trusts `$HOME`.
- The log is `root:wheel 0640` so the record of privileged actions is not
  rewritable by the user who invoked them. Hardening is idempotent, runs from
  both `setup` and `up`, warns when it fails instead of failing silently, and
  `doctor` section 11 audits the result — a control nobody checks is not a
  control.
- `chown`/`chmod`/`touch`/`tee` follow symlinks, so every privileged write
  refuses a path that is a symlink. The directories involved (`/etc/pf.anchors`,
  `/var/db/vpnnat`, `/var/log`) are root-owned, so an unprivileged user cannot
  plant the link; the guard covers `VPNNAT_LOG` or `VPNNAT_STATE_DIR` being
  pointed somewhere writable.
- Interface names interpolated into generated pf rules are constrained to
  `^utun[0-9]+$`, `^bridge[0-9]+$` and `^en[0-9]+$`, and gateways used in
  probes are validated as dotted quads, so neither a process inside the VM nor
  a hostile VPN/DHCP server can smuggle pf syntax into the anchor.

### Open items

- **Datapath confirmed on two of the three tunnels.** After testing from inside
  the VM, `pfctl -a utm-vpn -s nat -v` showed two of the three tunnel rules
  translating real traffic (1984 packets / 1.67 MB and 52 packets / 34 KB).
  Packets counted on a `nat on utunN` rule are direct proof that VM traffic left
  through that tunnel with the tunnel's address as source rather than leaking out
  `en0`. The third — the profile whose gateway is `10.250.40.1` — still read
  `Packets: 0`, most likely because nothing was addressed to its ranges rather
  than a fault, since its rule is identical to the other two. Identify profiles
  by **gateway**, not by utun number: the numbers rotate on reconnect, and these
  three swapped places entirely within two days. To close it, ping that profile's
  gateway from the VM and re-read the counters. `pfctl -a utm-vpn -s nat -v` is
  the right tool for this question in general.
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
