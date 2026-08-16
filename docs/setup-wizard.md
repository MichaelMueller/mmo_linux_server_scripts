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

### 1. Base tools and machine identity

[base-tools.sh](base-tools.md) — editors, screen, shell defaults. Then the two
things that are quickly done and annoying to retrofit:

- **Hostname** ([hostname-setup.sh](hostname-setup.md)). The current name is
  shown and the question defaults to **no** — every machine already has a name,
  and a wizard should not talk anyone into renaming a server that was named
  deliberately. It sits this early because the hostname ends up in every alert
  mail the tools in step 3 send; setting it afterwards means the first reports
  carry the provider's random name.
- **Root password** ([root-password.sh](root-password.md)). Here there is
  something to detect, and it matters — the wizard reads `passwd -S root`:

  | State | What the wizard does |
  |---|---|
  | `NP` (no password at all) | warns that anyone at the console is root, and offers to set one, defaulting to **yes** |
  | `L` (locked) | notes that this is the usual server setup — administration through sudo — and defaults to no |
  | `P` (set) | offers a change, defaulting to no |

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
unattended. Then, each detected by its cron file and each skippable:
[auto-update.sh](auto-update.md), [disk-monitor.sh](disk-monitor.md),
[resource-monitor.sh](resource-monitor.md),
[net-monitor.sh](net-monitor.md) and
[clamav-scanner.sh](clamav-scanner.md).

**`net-monitor` is the only one that is not finished after its setup**: it needs
at least one interface, added through its menu item 1. The wizard says so before
starting it, because a monitor with no interfaces measures nothing and reports
nothing — which looks exactly like a monitor that is working.

The two new monitors also take one interval before they say anything: both
measure deltas between runs, so the first run only records a baseline.

### 4. Updates and virus scan now

`apt update` and, after showing the list, `apt upgrade` — with an explicit
question before a required reboot, never a silent one. Then optionally a
signature update and a first ClamAV scan.

At the end a summary table shows what was done, skipped or failed.
