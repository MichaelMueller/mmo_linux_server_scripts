# Documentation

One file per tool. Each is complete in itself and can be copied on its own —
into a wiki, a handover, an operations manual. No file assumes you have read
the others.

| Cross-cutting | |
|---|---|
| [manual-setup.md](manual-setup.md) | **Without these scripts:** setting up a server by hand, with standard tools only |
| [setup.md](setup.md) | Main menu and uninstall submenu |

| 1. Secure access | |
|---|---|
| [base-tools.md](base-tools.md) | Base packages, coloured shell, editor defaults |
| [ssh-setup.md](ssh-setup.md) | SSH hardening |
| [ufw-manager.md](ufw-manager.md) | Firewall rules |
| [wg-manager.md](wg-manager.md) | WireGuard |
| [tailscale-setup.md](tailscale-setup.md) | Tailscale |

| 2. Monitor operation | |
|---|---|
| [mail-setup.md](mail-setup.md) | SMTP sending through msmtp |
| [graph-mailer.md](graph-mailer.md) | Sending mail through Microsoft Graph (Microsoft 365) |
| [auto-update.md](auto-update.md) | apt updates via cron |
| [tcp-monitor.md](tcp-monitor.md) | Reachability of services |
| [http-monitor.md](http-monitor.md) | HTTP status code, response time, certificate expiry |
| [disk-monitor.md](disk-monitor.md) | Disk space |

| 3. Applications | |
|---|---|
| [nginx-manager.md](nginx-manager.md) | TCP relay with SNI routing |
| [caddy-manager.md](caddy-manager.md) | vhosts with TLS termination |
| [docker-setup.md](docker-setup.md) | Installing and configuring Docker |
| [git-updater.md](git-updater.md) | Keeping git working copies up to date via cron |

Every tool file follows the same layout: requirements, usage, menu, settings,
files created, the particulars of the tool, state and data, uninstall, and a
troubleshooting table.

**[manual-setup.md](manual-setup.md) is the odd one out**: it describes how to
set up the same server entirely without these scripts — with nothing but `ufw`,
`sshd`, `wireguard`, `msmtp`, `caddy`, `docker` and the other standard tools. No
reference to this repository, everything ready to copy. Useful for
understanding what the scripts do, for systems they should not run on, and as
an emergency guide when the tools are not at hand.
