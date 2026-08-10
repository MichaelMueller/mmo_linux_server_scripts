# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), the versioning follows
[Semantic Versioning](https://semver.org/) — what counts as *breaking* here is
described in the [README](README.md#versioning).

## [Unreleased]

### Fixed

- **caddy-manager** — `is_setup()` was satisfied by `sites.d` plus the import
  line, so an installation that still carried Debian's stock Caddyfile kept its
  `:80 { root * /usr/share/caddy }` block: a site address without a host matcher
  that answers for every host and collides with the routes Caddy sets up on :80
  for the real domains. `is_setup()` now also requires `sites-meta.d` and the
  absence of a port-only site block, so the setup runs and repairs the file —
  keeping an existing `email` as the default and backing the old file up
  unconditionally (it used to skip the backup precisely when the import line was
  already present).
- **caddy-manager** — `/var/log/caddy` is created (and chowned to `caddy`) by
  `ensure_dirs()` before every reload, not only while a host is being created. A
  vhost whose `output file` cannot be opened does not fail that one site, it
  stops the whole service. The path is written quoted as well.
- **caddy-manager** — creating a host aborted with
  `/etc/caddy/sites-meta.d/….meta: No such file or directory` on installations
  set up before `sites-meta.d` existed: `is_setup()` is satisfied by `sites.d`
  plus the import line, so the `mkdir` in the setup never ran. Both directories
  are now ensured before a host is written, and the metadata of existing hosts
  is no longer shown as `?`.
- **caddy-manager** — `site_file()`/`meta_file()` turned `echo`'s trailing
  newline into a `_`, so every file was named `domain.tld_.caddy`. Legacy names
  are renamed once at startup.
- **caddy-manager** — the domain prompt now trims whitespace and rejects
  anything that is not a hostname; a pasted `michael muelleronline.de` used to
  become the file `michael_muelleronline.de_.caddy` and a vhost with two site
  addresses.
- **caddy-manager** — the host list read `head -1`, so a comment line appeared
  as a host named `#`; site blocks with several addresses now show all of them.
- **caddy-manager** — "Pass the original Host header to the backend?" did the
  opposite: Caddy forwards the original `Host` by default, and answering yes
  added the `header_up Host {upstream_hostport}` that replaces it. The directive
  is now written when the question is answered with *no*.

## [2.1.0] — 2026-08-06

### Added

- **iptables-router** — a sixteenth tool: routing between networks. Where the
  tunnel joins two machines, this passes traffic on to everything behind them.
  Four route types — `link` (site-to-site, optionally with NAT), `hub` (peers of
  one tunnel among each other), `exit` (internet through this server) and
  `publish` (a port of this server leads to a machine behind the tunnel) — each
  one file under `var/routes.d/`, each translated into one to three iptables
  rules.
  - Everything lands in **three chains of its own** (`IPTR-FORWARD`,
    `IPTR-PREROUTING`, `IPTR-POSTROUTING`), so a rebuild never touches foreign
    rules and `iptables -n -v -L IPTR-FORWARD` shows the whole tool in one
    screen. The jump is always inserted at position 1: ufw rejects forwarded
    packets at the end of its chains, and Docker puts rules of its own at the
    top of `FORWARD`.
  - **A recipe (menu item 2)** for the common case — a network behind a VPN peer
    — which checks the far network's presence in the peer's `AllowedIPs` and
    offers to add it, in the running interface and in
    `/etc/wireguard/peers.d/`, and which prints what the far side has to do.
  - **A check (menu item 4)** that tests the interface a route really goes out
    over instead of trusting that `ip route get` answered at all.
  - The rules do not survive a reboot; an optional systemd oneshot unit writes
    them back (`--apply` / `--clear`), ordered after `wg-quick@wg0` and `ufw`.
  - New flags: `--apply`, `--clear`, `--status`, `--uninstall`.
    IPv4 only, `ip6tables` is not touched.

### Changed

- `setup.sh`: the new tool is item 6 in "Secure access" — the items after it
  move up by one, uninstall is now 17 and quit 18, and the same in the uninstall
  submenu. The status line additionally shows whether routing rules are in
  effect (the jump in `FORWARD`, not the mere presence of a configuration).
- The documentation gains [docs/iptables-router.md](docs/iptables-router.md);
  the note in [docs/wg-manager.md](docs/wg-manager.md) that forwarding and
  routes are deliberately not set up now names the tool that does it.

## [2.0.1] — 2026-08-02

### Changed

- The README opens with a screenshot of the head of `setup.sh`
  (`docs/code_screen.png`) — strict mode, the `--version` query sitting before
  the root check, and the paths of the individual scripts. Documentation only;
  no script behaviour changed.

## [2.0.0] — 2026-08-02

The project language is now English: every script and every documentation file
was translated. Nothing about the functionality changed.

### Changed

- **All user-facing output is English** — menus, prompts, status lines, mail
  subjects and bodies, log lines, and the comments written into generated files
  (`/etc/cron.d/*`, the `*.conf` headers, the sshd and Docker provenance lines).
- **All documentation is English** — `README.md`, `docs/` including
  `docs/manual-setup.md`, and this changelog.
- **Confirmation prompts are now `[Y/n]` / `[y/N]`** instead of `[J/n]` /
  `[j/N]`. `j` is still accepted as a yes, so German-keyboard muscle memory keeps
  working.
- Source comments are English as well, and the output is ASCII throughout — no
  umlauts end up in `/etc/cron.d/`, in mail subjects or in webhook payloads any
  more.

### Breaking

- **An installation set up with 1.0.0 should be uninstalled with 1.0.0 first.**
  The 2.0.0 scripts write English text where the German version wrote German,
  so leftovers of the old version are not necessarily recognised — cron file and
  configuration headers, the generated comments, and the `caddy-zertifikate`
  backup name (now `caddy-certificates`).
- The one place where that would have been dangerous is handled: `ssh-setup`
  marks conflicting lines in `sshd_config` with `# disabled by ssh-setup: `
  instead of `# von ssh-setup deaktiviert: `, **and its uninstall recognises
  both**. So password login is not left permanently commented out on a server
  that ran 1.0.0.
- Unchanged and therefore uncritical: all configuration keys and their values,
  the state files and CSV columns, the marker blocks
  (`# >>> base-tools >>>` and friends), every command-line flag, and all file
  and directory names.

## [1.0.0] — 2026-08-02

First published version. Fifteen self-contained tools under one shared menu,
each runnable on its own and each removable on its own.

### Secure access

- **base-tools** — base packages (`git` and `ca-certificates` mandatory),
  coloured shell, defaults for vim, nano and screen; foreign files are extended
  through marked blocks rather than overwritten
- **ssh-setup** — hardening through a drop-in, with detection of `ssh.socket`, a
  check via `sshd -T` of whether the drop-in takes effect at all, and the order
  ufw → sshd against locking yourself out
- **ufw-manager** — CRUD on ufw rules without bookkeeping of its own, showing the
  generated command before it runs, and a two-stage recipe "SSH only over
  WireGuard"
- **wg-manager** — WireGuard server and client configs, split into
  `wg0-interface.conf` and `peers.d/`, changes applied with `wg syncconf`
  without dropping the tunnel
- **tailscale-setup** — installation, login interactively or by auth key, subnet
  routes and exit node including IP forwarding

### Monitor operation

- **mail-setup** — SMTP sending through msmtp as a sendmail replacement
- **graph-mailer** — sending mail through Microsoft Graph for tenants without
  SMTP AUTH, as MIME to the API, hooked in as sendmail through `dpkg-divert`
- **auto-update** — apt updates via cron, optionally security updates only, with
  separate switches for reboots and the mail report
- **tcp-monitor** — reachability of TCP services, an alert only on a state
  change
- **http-monitor** — HTTP status code, response time and certificate expiry
- **disk-monitor** — usage and inodes with an extrapolation of when it will get
  tight

### Applications

- **nginx-manager** — nginx as a TCP relay with SNI routing, TLS passed through
  to the backend
- **caddy-manager** — vhosts with TLS termination, validation and rollback after
  every change
- **docker-setup** — installation from the official repo, log rotation and
  binding published ports to `127.0.0.1`, because Docker otherwise publishes
  them to the network past ufw
- **git-updater** — keep working copies up to date via cron, `--ff-only`, as the
  owner, with an optional Docker Compose deployment

### Cross-cutting

- One uniform uninstall pattern: show what will go, ask with the default "no",
  back up to `/root/<tool>-uninstall-<time>.tar.gz`, remove no packages,
  repeatable
- Documentation per tool under [docs/](docs/), each file complete in itself and
  copyable on its own
- [docs/manual-setup.md](docs/manual-setup.md): the same setup by hand, without
  any script, using nothing but standard tools
- `--version` in every tool, without root as well
- MIT license, an SPDX identifier in every file

[Unreleased]: https://github.com/MichaelMueller/mmo_linux_server_scripts/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/MichaelMueller/mmo_linux_server_scripts/compare/v2.0.1...v2.1.0
[2.0.1]: https://github.com/MichaelMueller/mmo_linux_server_scripts/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/MichaelMueller/mmo_linux_server_scripts/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/MichaelMueller/mmo_linux_server_scripts/releases/tag/v1.0.0
