# setup-wizard.sh — guided first setup

The counterpart of [setup.sh](setup.md) for the first hour on a fresh server:
`setup.sh` is the toolbox where every module is one menu entry, the wizard
walks the same modules in a safe order. Every step asks first and can be
skipped; components that are already set up are detected and only re-run on
explicit request. The modules stay usable on their own afterwards.

```bash
sudo ./setup-wizard.sh
```

Before anything runs, the wizard checks the OS: Ubuntu 24.04 or newer passes,
anything else requires an explicit "continue at your own risk".

## The four steps

### 1. Base tools

[base-tools.sh](base-tools.md) — editors, screen, shell defaults.

### 2. Secure the SSH access

The core of the wizard, and the reason it exists: on a Linux server SSH is the
admin channel **and** the thing being protected — the only fallback if this
goes wrong is the provider's console. The order is therefore fixed:

1. **Harden first, close nothing** — [ssh-setup.sh](ssh-setup.md): deposit a
   key, test a key login, only then switch passwords off.
2. **Choose the route** — Tailscale ([tailscale-setup.sh](tailscale-setup.md)),
   WireGuard ([wg-manager.sh](wg-manager.md)), or no tunnel (SSH stays public,
   hardened and rate-limited with `ufw limit`).
3. **Open before closing** — the ufw rules that must keep working are created
   first: SSH over the tunnel interface, the WireGuard UDP port (without it
   the tunnel itself never comes up), optionally 80/443 for web applications,
   and a temporary public SSH rule as the safety net. Only then is ufw enabled.
4. **Test gate** — the wizard waits until a login over the tunnel IP has
   worked in a second terminal, while the current session stays open.
5. **Only now close the public door** — the temporary public SSH rule is
   removed; SSH is tunnel-only. Verify once more in a new terminal before
   ending the session.

Aborting at the test gate leaves SSH publicly reachable — nothing is lost,
nothing is locked out.

### 3. Monitor the operation

A mailer first ([mail-setup.sh](mail-setup.md) or
[graph-mailer.sh](graph-mailer.md)) — a monitor whose message reaches nobody is
unattended. Then [auto-update.sh](auto-update.md),
[disk-monitor.sh](disk-monitor.md) and [clamav-scanner.sh](clamav-scanner.md).

### 4. Updates and virus scan now

`apt update` and, after showing the list, `apt upgrade` — with an explicit
question before a required reboot, never a silent one. Then optionally a
signature update and a first ClamAV scan.

At the end a summary table shows what was done, skipped or failed.
