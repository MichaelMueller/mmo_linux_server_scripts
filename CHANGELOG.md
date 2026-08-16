# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), the versioning follows
[Semantic Versioning](https://semver.org/) — what counts as *breaking* here is
described in the [README](README.md#versioning).

## [Unreleased]

### Added

- **resource-monitor** — a new tool for **sustained CPU and RAM load**:
  `resource-monitor.sh`. Everything is measured as a delta between two runs
  (`/proc/stat` jiffies, `/proc/vmstat` swap counters), so the value is the
  average across the whole interval rather than a momentary reading — a busy
  minute inside a quiet hour disappears in it, as it should. Its core is a
  **debounce gate that none of the older monitors has**: a per-axis counter of
  consecutive readings above the threshold, with the state only moving once
  `N_CONSEC` (default 3) is reached, so a build or a backup passes without a
  word while a quarter of an hour of real load alerts. After that gate the
  familiar rules apply — alert only on a state change, one recovery message,
  first reading in a normal state is never an incident. **Swap alerts on the
  paging rate, not on the fill level**: swap that merely sits there is
  harmless, swap traffic means the machine is short of memory right now.
  `iowait` is broken out in CPU alerts (high CPU that is mostly iowait is a
  disk waiting, not a CPU under load), and `ps` output is collected only for
  the axis that actually alerted. The first run records the counter baseline
  and evaluates nothing, since a delta needs two points; a counter that went
  backwards (reboot) drops the sample instead of reporting nonsense.
  Documentation: `docs/resource-monitor.md`.
- **net-monitor** — a new tool for **sustained network throughput**:
  `net-monitor.sh`. One entry per interface under `var/net/ifaces.d/`, because
  thresholds belong to the interface and not to the machine — a 10 Gbit uplink
  and a WireGuard tunnel have nothing in common. **RX and TX are independent
  axes** with their own thresholds, debounce counters and alerts, since a
  saturated downlink and a saturated uplink are different incidents. Rates come
  from the `/sys/class/net` byte counters divided by the time that really
  elapsed, not by the nominal interval, so a late cron run does not look like
  less traffic. **A negative delta is discarded rather than reported**: link
  down, driver reload or a 32-bit wrap would otherwise produce a fabricated
  multi-gigabit burst, the most convincing kind of false alarm. An interface
  that has disappeared entirely is reported once as `gone`. Where the interface
  reports a link speed, alerts also give the percentage of it.
  Documentation: `docs/net-monitor.md`.
- **hostname-setup** — a new mini tool: set the hostname, typed or **generated
  as `<prefix>-yymmdd-hhmm`** (`srv-260815-1432`), which sorts chronologically
  as a plain string. Underscores are refused (valid in DNS records, not in
  hostnames, and otherwise rejected much later by something that gives no hint
  why). Writes the Debian-style `127.0.1.1` line in `/etc/hosts` as well —
  without it every `sudo` waits for a DNS timeout first and mailers hang — and
  touches no other line in that file. `/etc/hostname` and `/etc/hosts` are
  backed up before every change. **No `--uninstall`:** a hostname cannot be
  removed, only replaced. Documentation: `docs/hostname-setup.md`.
- **root-password** — a new mini tool: set the root password, typed or
  **generated** (24 characters, letters and digits only — a password with shell
  metacharacters gets mangled sooner or later, and 24 alphanumeric characters
  are far beyond anything that gets brute-forced). It is shown once with the
  note that it is stored nowhere, and set through `chpasswd` on stdin so it
  never appears in the process list. Can also lock and unlock the account
  (`passwd -l`), with a warning about what that costs. **No `--uninstall`.**
  Documentation: `docs/root-password.md`.
- **auto-update** — **package exclusions** (`EXCLUDE_PKGS`, names or shell
  globs). The case they exist for is the container engine: an apt run restarts
  it at 04:17 and takes every container with it. The two scopes need different
  levers — in `security` mode the package list is built here anyway, so names
  are simply left out of it; in `all` mode `dist-upgrade` takes no list, so the
  exclusions are pinned with `apt-mark hold` for the duration of the run. Two
  safeguards, because a leaked hold means a package silently never updated
  again: only packages held by this run are released (a pre-existing hold
  belongs to someone else), and the release is armed as a `trap` before the
  first hold is set, so a failed or interrupted run cannot leave the system
  pinned. Skipped packages are named in the report and marked in the pending
  list.
- **auto-update** — **redeploy after an installation**
  (`POST_UPDATE_REDEPLOY`): a run that actually installed packages calls
  `git-updater.sh --redeploy` afterwards and puts its output into the report
  under `--- Redeploy ---`. It fires after any installation rather than only
  after docker ones — `compose up -d` does nothing where nothing changed, and
  gating on "was docker updated?" would never fire on the setup that needs it
  most, the one with docker on the exclusion list. The question is only asked
  where `git-updater.sh` sits next to the script, and a missing one at run time
  is logged and skipped rather than failing the update run.
- **git-updater** — **`--redeploy [name]`** plus menu item 3: runs the compose
  deployment for every enabled entry with `COMPOSE="1"` **without any git
  operation** — no fetch, no pull, no checkout. The normal deployment hangs off
  a new commit, and rightly so, but a package update that restarts the
  container engine stops the containers without a commit being involved.
  Reuses the existing `compose_script()` and `run_in_dir()`, so pull/build
  settings and `COMPOSE_TIMEOUT` behave exactly as on the update path.
  `POST_CMD` is deliberately **not** run: its contract is that it runs on new
  commits. Only failures send a message; the exit code is 1 if any stack
  failed. Later menu items move down by one (quit is now 7).

- **ufw-manager** — the recipe **"SSH only over WireGuard" now covers Tailscale
  as well** (menu item 4, "Make SSH reachable only over the VPN"): it first asks
  which tunnel should carry SSH, then runs the same two safe stages. The checks
  are tunnel-specific — WireGuard still requires its UDP listen port to be open
  (declining aborts, without it the tunnel never comes up), while Tailscale
  needs no inbound rule at all: connections are established from the inside,
  falling back to relays (DERP) where no direct path exists. Opening the
  Tailscale UDP port (default 41641) is therefore offered as an *option* for
  direct, faster connections — with the note that this is OK to do: the port
  speaks exclusively WireGuard, and packets not authenticated with a key of the
  tailnet are discarded.
- **ufw-manager** — **"Show all rules"** (new menu item 5): `ufw status` is
  silent while the firewall is off, so this view shows the stored rules via
  `ufw show added` in both states, under a header that says unmistakably
  whether they are currently enforced — and, while active, `ufw status verbose`
  on top. The items after it move up by one (quit is now 11).

- **setup-wizard** — new script `setup-wizard.sh`: guided first setup that
  walks the existing modules in a safe order (base tools → secure SSH →
  operations → updates and virus scan). The core is the SSH step: harden first
  via ssh-setup, bring up the tunnel (Tailscale or WireGuard), create every
  rule that must keep working (tunnel SSH, WireGuard UDP port, optionally
  80/443) *before* ufw is enabled, then wait at a test gate until a login over
  the tunnel has demonstrably worked — only after that is the temporary public
  SSH rule removed. Aborting the gate leaves SSH publicly reachable. Detects
  what is already set up and only re-runs it on request; OS check (Ubuntu
  24.04+, everything else needs an explicit confirmation); summary table at
  the end. Documentation: `docs/setup-wizard.md`.
- **clamav-scanner** — new tool `clamav-scanner.sh`: installs ClamAV, keeps
  signatures current through the clamav-freshclam service (a manual `--update`
  stops it first, otherwise freshclam only reports a locked log), runs a daily
  `clamscan` via cron with `nice`/`ionice`, keeps one report per run, and
  alerts by mail/webhook on findings or errors. Findings are reported, never
  deleted or moved automatically. Menu entry 16 in setup.sh, status line shows
  the cron state. Documentation: `docs/clamav-scanner.md`.

### Changed

- **setup-wizard** — step 1 becomes **"Base tools and machine identity"** and
  now also offers the hostname and the root password. The hostname question
  defaults to **no** (every machine already has a name, and a wizard should not
  talk anyone into renaming one that was chosen deliberately), but sits this
  early because the name ends up in every alert mail step 3 sets up. The root
  password branches on `passwd -S root`: **`NP` — no password at all — warns
  and defaults to yes**, `L` (locked) notes that this is the usual server setup
  and defaults to no, `P` offers a change defaulting to no. Step 3 gains the
  two new monitors, with a note before `net-monitor` that it still needs an
  interface added through its menu — a monitor with no interfaces reports
  nothing, which looks exactly like one that is working.
- **setup.sh** — group 1 is renamed **"Basic setup and secure access"** and
  gains the two new mini tools as items 2 and 3 (hostname, root password): not
  everything in that group secures something, and the hostname in particular
  belongs at the top because it ends up in every alert mail the later tools
  send. The two new monitors are items 14 and 15. Everything after those shifts
  accordingly — uninstall is now 22, quit 23. `hostname-setup` and
  `root-password` deliberately do **not** appear in the uninstall submenu, and
  the submenu says why. The status line gains the hostname and the cron state
  of the two new monitors.
- **setup.sh** — the menu was regrouped: **the firewall now sits below the two
  VPNs** (base tools → SSH → WireGuard → Tailscale → firewall), because
  ufw-manager's "SSH only over the VPN" recipe needs a tunnel interface that
  already exists — by the time you reach ufw, the tunnel is up and the lockdown
  can happen in the same sitting. **Routing (iptables-router) moved from
  "Secure access" to "Applications"** (now item 17): the tunnel is access, passing
  traffic on between the networks behind it is something the server does. The
  uninstall submenu mirrors the new order; the order of the "Everything" run is
  unchanged (it is functional, not cosmetic). README and docs follow suit.

- **git-updater** — **testing an entry** (menu item 1 → 3, or `--test [name]`):
  answers whether the next cron run would get through, without a `fetch`, a
  `pull`, a `checkout` or a deployment. It checks what the overview cannot show,
  because it belongs to the environment of the configured user rather than to the
  configuration: `sudo -n` into that account, the owner of the working copy
  (git's "dubious ownership"), `git ls-remote` with *his* key and credential
  helper, whether the configured branch exists on the remote at all,
  `docker compose config -q` and `docker info` as that user. The state of the
  remote is read via `ls-remote`, so nothing local is touched, and `POST_CMD` is
  printed instead of run. `WARN` means it runs but probably not as intended,
  `FAIL` that it would not get through; the exit code is 1 on the first `FAIL`,
  so it works as an external check.

### Fixed

- **tailscale-setup** — a login could not succeed on a node that already
  carried a **tag**. Tags are a property of the `tailscale up` call rather than
  something the daemon keeps on your behalf, so they have to be repeated every
  time; a node with `tag:…` therefore made every otherwise correct call fail
  with *"requires mentioning all non-default flags"*. The tag question is now
  **pre-filled with what the node currently carries** (read from `tailscale
  debug prefs`; Enter keeps them, `-` removes them), and if the call is refused
  anyway, **`--reset` is offered and the run repeated right there** instead of
  pointing at another menu item. That matters for the auth-key login in
  particular: the key just typed in is still in hand at that moment. A guard
  stops after one retry, so a genuinely broken call cannot loop.
- **tailscale-setup** — `tailscale up` output is now shown live *and* captured
  (via `tee`) so the refusal can be recognised. Capturing it into a variable
  would have hidden the login URL, which is the whole point of the interactive
  path.
- **tailscale-setup** — the temporary auth-key file is removed on `INT`/`TERM`
  as well, so a `Ctrl-C` during the login cannot leave a valid key behind in
  `/tmp`.
- **git-updater, tcp-monitor, http-monitor, disk-monitor, auto-update** — a
  **relative data directory** was taken over verbatim, so `repos.d/`, `state/`
  and `log/` were created wherever the caller happened to stand instead of under
  `var/`. Two consequences: cron stands somewhere else than you do, so state was
  written in one place and looked for in another — and inside a working copy
  those directories are untracked files, which makes `git status --porcelain`
  report local changes for good and stops git-updater from ever updating that
  repo again. A relative path is now resolved against the script's directory,
  never against `$PWD`, both when the configuration is read and when it is
  entered. Changing the directory offers to move the existing data along; before,
  the entries stayed behind silently and the overview was simply empty.
- **git-updater** — `repo_file()` turned `echo`'s trailing newline into a `_`, so
  every entry was stored as `name_.conf` and `--test <name>` could not find it.
  Legacy names are renamed once at startup.

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
