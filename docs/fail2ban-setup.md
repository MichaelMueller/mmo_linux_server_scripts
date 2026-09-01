# fail2ban-setup.sh — banning after failed attempts

Installs fail2ban and configures the jails that matter on this kind of server:
failed SSH logins, repeat offenders, and — where [caddy-manager](caddy-manager.md)
is in use — requests Caddy answered with 401 or 403.

[ssh-setup](ssh-setup.md) reduces the attack surface (no root login, keys instead
of passwords, a moved port). It does not stop anyone from trying: whoever wants
to knock ten thousand times may, and only fails ten thousand times. That is the
gap this fills.

## Requirements

- Debian or Ubuntu with systemd
- root
- `python3-systemd` for the journal backend — installed automatically

## Usage

```bash
sudo ./fail2ban-setup.sh              # menu
sudo ./fail2ban-setup.sh --status     # jails and bans on stdout
sudo ./fail2ban-setup.sh --uninstall  # remove jails, filter, package
```

## Menu

| Item | Effect |
|---|---|
| 1 | Settings (backend, durations, `ignoreip`) |
| 2 | Jails (switch on/off, thresholds per jail) |
| 3 | Status |
| 4 | Test a filter against the real log |
| 5 | Unban an IP address |
| 6 | Log (`journalctl -u fail2ban`) |
| 7 | Uninstall |
| 8 | Quit |

## What it writes

Nothing outside its own files. `jail.conf` is the package's, `jail.local` is
yours, and neither is touched:

```
/etc/fail2ban/jail.d/00-mmo-defaults.local   [DEFAULT]: bantime, findtime, ignoreip
/etc/fail2ban/jail.d/sshd-mmo.local          one file per jail
/etc/fail2ban/jail.d/recidive-mmo.local
/etc/fail2ban/jail.d/caddy-mmo.local
/etc/fail2ban/filter.d/caddy-mmo.conf        our own filter, see below
fail2ban-setup.conf                          next to the script
```

## The jails

| Jail | Watches | Why it is here |
|---|---|---|
| `sshd` | failed SSH logins | the one everybody needs |
| `recidive` | fail2ban's own log | bans whoever comes straight back after their ban expired |
| `caddy-mmo` | `/var/log/caddy/*.log` | 401 = failed basic auth, 403 = turned away by an access restriction |

**nginx is deliberately missing.** The nginx in this repo
([nginx-manager](nginx-manager.md)) is a pure TCP relay that passes TLS through.
It never sees an HTTP request, so it has nothing to write an HTTP log about and
nothing to match on. A jail for it would sit there looking healthy and ban
nobody, which is worse than not having one.

## The three ways this quietly does nothing

A jail that matches nothing looks exactly like a quiet server. All three of
these produce that picture, and the tool handles them.

**1. The log source.** Debian stopped installing a syslog daemon, so
`/var/log/auth.log` is often missing entirely — and the packaged default
(`backend = auto`) then reads a file that does not exist. The setup therefore
offers the **systemd journal** as the backend and writes no `logpath` into a
jail that uses it, because a `logpath` sends fail2ban back to the file.

**2. The missing Python module.** The systemd backend needs `python3-systemd`,
which the Debian package only *recommends*. Without it fail2ban starts happily
and every jail dies with `No module named 'systemd'`. The setup installs it and
says so if it still is not there.

**3. The moved SSH port.** If ssh-setup moved SSH to 2222 and the jail still
says `port = ssh`, the ban rule blocks port 22 while the attacker keeps knocking
on 2222. The sshd jail is written with the port `sshd -T` really reports.

For everything else there is **menu item 4**: it runs `fail2ban-regex` over the
real log with the real filter and shows how many lines matched. `Failregex: 0
total` on a busy server means the filter does not fit — the jail would never ban
anyone while looking perfectly fine.

## ignoreip — the list that decides whether a mistake costs you the server

Preset with loopback and the tailnet (`100.64.0.0/10`), and this is not a
formality: when a rule shuts the front door, the tunnel is how you get back in.
Tailscale hands out CGNAT addresses, which nothing else in that list covers.

## How the ban is enforced

If ufw is active, the setup offers `banaction = ufw`, so the ban shows up in
`ufw status` instead of in a chain of its own. Otherwise it writes no
`banaction` at all and leaves the distribution's default alone — Debian 13 bans
through nftables, Debian 12 through iptables, and each is right on its own
system.

If you use [iptables-router](iptables-router.md): its rules live in the
`IPTR-*` chains and are rebuilt as a unit, while fail2ban maintains chains of
its own. The two do not collide, but a ban only bites where the packet passes
through the chain that holds it — with `banaction = ufw` on a router that
forwards traffic, a banned address can still reach a forwarded backend.

## The Caddy filter is ours

fail2ban ships no filter for Caddy, and Caddy writes JSON. This one matches the
client address of a request answered with 401 or 403:

```
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403).*$
datepattern = {EPOCH}
```

`datepattern` is there because Caddy's `ts` is a UNIX timestamp with a fraction,
not a formatted date. The filter fits the access log that
[caddy-manager](caddy-manager.md) writes; if you log somewhere else or in
another format, test it with menu item 4 before relying on it.

Worth knowing before switching this jail on: a 403 from an access restriction is
often **your own** traffic from the wrong network, not an attack. Check what is
actually in the log first, and keep the threshold higher than the sshd one.

## Uninstall

Removes the jail files, the defaults, the Caddy filter and the configuration,
and asks separately about the package. Removing the package drops every active
ban with it — deliberately, so that nobody stays locked out by a tool that is no
longer installed. Keeping it leaves fail2ban running with whatever jails are not
ours.

A backup is written to `/root/fail2ban-uninstall-<timestamp>.tar.gz` first.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No module named 'systemd'` in the log | `python3-systemd` missing (setup installs it) |
| Jail runs, `Currently failed: 0` forever | filter does not match — menu item 4 |
| Bans appear, attacker keeps connecting | jail port ≠ real SSH port, or the ban action does not cover the path the packet takes |
| Locked yourself out | from the tailnet: `fail2ban-client set sshd unbanip <ip>`, or menu item 5 |
| `fail2ban.service` dead after a config change | `journalctl -u fail2ban -n 30` — a broken jail takes the daemon with it |
