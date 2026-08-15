# setup.sh — main menu

Entry point for all the tools. `setup.sh` manages nothing itself, it only calls
the individual scripts and shows a status line at the top. Every tool works
just as well when you start it directly.

## Requirements

- Debian or Ubuntu (tested base: apt, systemd, cron)
- root rights (`sudo`)
- the tool scripts sit in the same directory as `setup.sh`

## Usage

```bash
sudo ./setup.sh
```

If a script lacks the execute bit, `setup.sh` sets it itself (`chmod +x`). A
script that does not exist is reported and skipped — so you can delete the
individual tools you do not need.

## Status line

```
host: srv-260815-1432   |   sshd port: 22   |   ufw: active   |   routing: active
wg0: active   |   tailscale: active   |   nginx: inactive   |   caddy: active
Mailer: msmtp   |   auto-update: active   |   git-updater: -
tcp: active   |   http: active   |   disk: -   |   cpu/ram: active   |   net: -   |   clamav: -
```

| Field | Source |
|---|---|
| host | `hostname -s` |
| sshd port | `sshd -T` (the effective configuration, not the file) |
| ufw | `ufw status` |
| routing | the jump to `IPTR-FORWARD` in the `FORWARD` chain — that is what says whether the rules of `iptables-router` are in effect, rather than whether a configuration exists |
| wg0 / tailscale / nginx / caddy | `systemctl is-active` |
| Mailer | existence of `/etc/msmtprc` and `/etc/graph-mailer.conf` |
| the cron tools | existence of `/etc/cron.d/<tool>` |

## Menu

The menu is split into three groups, which are at the same time the setup
order: **first secure access, then establish the notification path, then put
applications on top.**

| Item | Tool | Purpose |
|---|---|---|
| | **Basic setup and secure access** | |
| 1 | `base-tools.sh` | nano, vim, screen, coloured shell |
| 2 | `hostname-setup.sh` | Hostname, typed or generated from the date |
| 3 | `root-password.sh` | Root password, typed or generated |
| 4 | `ssh-setup.sh` | SSH hardening |
| 5 | `wg-manager.sh` | WireGuard |
| 6 | `tailscale-setup.sh` | Tailscale |
| 7 | `ufw-manager.sh` | Firewall rules |
| | **Monitor operation** | |
| 8 | `mail-setup.sh` | SMTP sending through msmtp |
| 9 | `graph-mailer.sh` | Sending mail through Microsoft Graph |
| 10 | `auto-update.sh` | apt updates via cron, with exclusions |
| 11 | `tcp-monitor.sh` | Reachability of services |
| 12 | `http-monitor.sh` | HTTP status code, response time, certificate expiry |
| 13 | `disk-monitor.sh` | Disk space |
| 14 | `resource-monitor.sh` | Sustained CPU and RAM load, swapping |
| 15 | `net-monitor.sh` | Network throughput per interface |
| 16 | `clamav-scanner.sh` | Virus scan: signatures, daily scan, alerts |
| | **Applications** | |
| 17 | `iptables-router.sh` | Routing between networks: forwarding, NAT, port forwarding |
| 18 | `nginx-manager.sh` | TCP relay with SNI routing |
| 19 | `caddy-manager.sh` | vhosts with TLS termination |
| 20 | `docker-setup.sh` | Installing and configuring Docker |
| 21 | `git-updater.sh` | Keeping git working copies up to date via cron |
| | | |
| 22 | Uninstall | Submenu, see below |
| 23 | Quit | |

Group 1 is called **basic setup and secure access** because not all of it
secures anything: `base-tools` gives you an editor, `hostname-setup` and
`root-password` are what you do in the first five minutes on a new machine.
They still belong at the top — the hostname ends up in every alert mail the
later tools send, so setting it afterwards means the first reports carry the
provider's random name.

Within group 1, SSH comes before the firewall, because `ssh-setup` opens the
new port in ufw itself — and the two VPNs also come before the firewall,
because ufw-manager's recipe "SSH only over the VPN" needs a tunnel interface
that already exists. Group 2 starts with a mailer, because an update run or a
monitor whose message reaches nobody is unattended. `iptables-router` sits with
the applications: the tunnel itself is access, but passing traffic on between
the networks behind it is something the server *does* — and it needs a tunnel
that is already up.

Three pairs are alternatives, not additions:

| | Decision |
|---|---|
| **msmtp** or **Graph** | Both want to be `/usr/sbin/sendmail`. Graph only if Microsoft 365 has blocked SMTP AUTH. |
| **nginx** or **Caddy** | Both want port 443. nginx passes TLS through to the backend (the certificate lives there), Caddy terminates it here. |
| **WireGuard** or **Tailscale** | These two may also run side by side; the question is rather whether you want to manage keys yourself or centrally. |

## State and data

`setup.sh` holds no state at all — it only reads `systemctl is-active`,
`ufw status`, `sshd -T` and the existence of the cron files to fill the status
line.

For the individual tools the guiding idea is: **the service is the data store,
not the script.**

| State lives … | Tools |
|---|---|
| exclusively in the service | `ufw-manager`, `ssh-setup`, `tailscale-setup` |
| in the kernel, plus what it takes to write it back | `iptables-router` (its own three chains; the routes sit next to the script) |
| in the service's configuration | `mail-setup`, `docker-setup`, `nginx-manager`, `caddy-manager`, `wg-manager`, `base-tools` |
| next to the script, because there is no service | `auto-update`, `git-updater`, `tcp-monitor`, `http-monitor`, `disk-monitor`, `graph-mailer` |

That means: most tools can be put on top of an installation that already
exists. Two exceptions are described in their own files: `caddy-manager`
rewrites the Caddyfile during the first-time setup (with a backup), and
`wg-manager` expects its own layout under `/etc/wireguard`.

## Uninstall

Item 22 opens a submenu with the same tools plus "Everything". Every tool asks
separately, backs up to `/root/<tool>-uninstall-<time>.tar.gz` beforehand and
removes no packages.

**`hostname-setup` and `root-password` are not in the list.** They change the
system itself — a name, a password — and there is nothing that could be taken
back out again. Neither has an `--uninstall` either.

The "Everything" run keeps a fixed order:

```
clamav-scanner → net-monitor → resource-monitor → disk-monitor → http-monitor
               → tcp-monitor → git-updater → auto-update → docker → nginx
               → caddy → iptables-router → tailscale → wireguard → base-tools
               → ssh-setup → ufw-manager → graph-mailer → mail-setup
```

First what only observes goes, then what serves, then access.
`iptables-router` goes before the VPNs, so the routing is taken down while the
tunnel it refers to is still there. `ssh-setup` runs
before `ufw-manager`, so it can still open port 22 in a running firewall. The
mailers come last, so alerts keep going out until the end — `graph-mailer`
before `mail-setup`, so the sendmail redirection is undone before msmtp is
dismantled.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Script not found" | The tool script does not sit next to `setup.sh` |
| "(… exited with an error)" | The tool returned an exit code ≠ 0; the actual message was printed above |
| sshd port shows `?` | `sshd -T` is not executable — usually because the script is not running as root |
| The menu flickers after a wrong entry | Deliberate: an invalid choice waits one second and redraws |
