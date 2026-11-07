# ssh-setup.sh — SSH hardening

Hardens SSH access through a drop-in: port, root login, keys instead of
passwords, an optional `AllowUsers` list and a few limits. It also creates a
personal admin user with sudo, so root does not have to log in at all. The `sshd_config` itself stays untouched.

The real substance of this tool is the precautions against locking yourself out
— the individual directives would be written by hand in two minutes.

## Requirements

- Debian or Ubuntu with systemd
- root rights
- **a second, open SSH session** for as long as you work on this

## Usage

```bash
sudo ./ssh-setup.sh              # menu
sudo ./ssh-setup.sh --status     # effective settings
sudo ./ssh-setup.sh --uninstall  # back to the distribution default
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / change settings |
| 2 | Status: `sshd -T`, drop-in, socket activation, keys on file, listening ports |
| 3 | Create an admin user: sudo + public key |
| 4 | Store a public key for an existing user |
| 5 | Close port 22 in ufw (after a successful test) |
| 6 | Uninstall |
| 7 | Quit |

## How the setup runs

First **all** the questions, then a summary, then **one** confirmation. Nothing
is touched before that.

| Question | Options | Default |
|---|---|---|
| Port | 1–65535 | current port |
| Root login | key only / forbid / password too | key only |
| Password login | switch off yes/no | switch off, if a key exists |
| AllowUsers | user names / `-` | current list, else the users with a key |
| MaxAuthTries | number | current value |
| LoginGraceTime | seconds | current value |
| X11 forwarding | yes/no | no |
| ClientAlive | yes/no | yes (300 s × 2) |

The only file written is `/etc/ssh/sshd_config.d/99-ssh-setup.conf`. In
addition, `KbdInteractiveAuthentication no` is set — otherwise, depending on the
PAM configuration, a password route stays open even with `PasswordAuthentication`
switched off.

## The guardrails

**Order ufw → sshd.** The new port is opened in ufw *before* sshd moves there.
Port 22 stays open alongside; menu item 5 closes it later and refuses as long as
sshd still listens on 22 itself.

**`sshd -t` before every apply.** If sshd rejects the configuration, the
previous drop-in is put back and nothing is restarted.

**`ssh.socket` is detected.** From Ubuntu 22.10 on, sshd starts through socket
activation and ignores the `Port` directive from the configuration entirely —
the port has to be set on `ssh.socket`. Without that distinction you move the
firewall to the new port while sshd keeps listening on 22. If the script detects
socket activation, it additionally writes:

```ini
# /etc/systemd/system/ssh.socket.d/10-ssh-setup-port.conf
[Socket]
ListenStream=
ListenStream=2222
```

The empty first line is necessary, otherwise systemd *adds* the port instead of
replacing it.

**Password login only with a key present.** The script searches
`/root/.ssh/authorized_keys` and `/home/*/.ssh/authorized_keys`. If it finds
nothing, password login stays on — with a pointer to menu items 3 and 4.

**AllowUsers cannot lock everyone out.** Users that do not exist are left out,
root is left out when root login is forbidden, and if nobody on the list could
still log in (no key and passwords off), the directive is not written at all.

**The combination "root forbidden + passwords off" is checked.** If only root
has a key, nobody would get in afterwards; the root login is then downgraded to
`prohibit-password`.

**Whether the drop-in actually arrives is verified.** With sshd the directive
read **first** wins. If the `sshd_config` already has `PasswordAuthentication
yes` above the `Include` line, the drop-in has no effect — and you usually
notice that only when it is too late. After writing, the script therefore
compares against `sshd -T` and offers to comment the conflicting lines out:

```
# disabled by ssh-setup: PasswordAuthentication yes
```

**A missing `Include` line** (older distributions) is added at the top of the
`sshd_config`, between `# >>> ssh-setup >>>` markers.

## Files changed

| Path | When |
|---|---|
| `/etc/ssh/sshd_config.d/99-ssh-setup.conf` | always |
| `/etc/ssh/sshd_config` | only when the `Include` line is missing or directives are commented out (backup: `.ssh-setup.bak`) |
| `/etc/systemd/system/ssh.socket.d/10-ssh-setup-port.conf` | only with socket activation |
| `/etc/sudoers.d/90-ssh-setup-<user>` | only for an admin user with sudo without password |
| users, group `sudo`, `~/.ssh/authorized_keys` | admin user / storing a key |
| ufw rules | the new port and 22 are opened |

## The admin user (menu item 3)

The usual layout for a server: root does not log in, a personal user does and
uses sudo. The menu item asks for the name, the public key and how sudo should
behave, shows a summary and applies it after one confirmation:

- installs `sudo` if it is missing (minimal Debian images)
- creates the user (`adduser --disabled-password`) — or takes an existing one
- adds it to the group `sudo` and stores the key as in menu item 4
- **sudo with password** (default): asks for a password right away if the user
  has none; with passwords off in SSH it is used for nothing but sudo
- **sudo without password**: writes `/etc/sudoers.d/90-ssh-setup-<user>`,
  checked with `visudo -c` before it goes live — whoever has the key is root at
  once. Choosing "with password" later removes the file again

If an `AllowUsers` list is active and the new user is not on it, the script
says so. The recommended order:

1. menu item 3 — create the admin user
2. second terminal: `ssh <user>@server`, then `sudo -v`
3. menu item 1 — new port, root login **forbid**, passwords off, `AllowUsers <user>`
4. second terminal: `ssh -p <port> <user>@server`
5. menu item 5 — close port 22

Users that only run things (e.g. a `deploy` user for `git-updater`, in the group
`docker`) do not need SSH at all: leave them out of `AllowUsers`.

## Storing a key (menu item 4)

Asks for the user and the public key (one line), checks the format roughly,
appends it to `~/.ssh/authorized_keys` and sets the permissions (`700` on
`.ssh`, `600` on the file) and the owner. A key that is already there is not
added twice.

## State and data

**Entirely service-side.** The only thing written is the drop-in
`/etc/ssh/sshd_config.d/99-ssh-setup.conf`; the *effective* state is read
through `sshd -T`, that is, from sshd itself. Nothing sits next to the script,
and there is no second set of books that could drift away from reality.

That is why the tool can be put on a running, hand-configured sshd: the existing
`sshd_config` stays as it is. It is touched in two cases only, both after asking
and both reversible on uninstall:

- the `Include` line is missing and gets added at the top (between markers)
- a directive above it defeats the drop-in and gets commented out

## Uninstall

1. Port 22 is opened in ufw — **before** sshd falls back to it
2. The drop-in is removed, the commented-out lines in the `sshd_config` are
   reactivated, the added `Include` line is cut out
3. `sshd -t`; if it fails, everything is rolled back
4. Socket drop-in gone, `daemon-reload`, restart

A backup is written to `/root/ssh-setup-uninstall-<time>.tar.gz` beforehand.
After that the distribution default applies again (port 22, password login
usually allowed). **Keys on file stay in place**, and so do admin users, their
group membership and sudoers files — accounts are not taken away by an
uninstall of the SSH settings.

The uninstall also recognises the German prefix `# von ssh-setup deaktiviert: `
that versions up to 1.0.0 wrote, so those lines are reactivated too.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Port changed, but sshd still listens on 22 | Socket activation; menu item 2 shows whether it was detected |
| A setting "does not arrive" | The directive sits above the `Include` line — the script offers to comment it out |
| No login possible after the restart | Call `--uninstall` from the second session that is still open; failing that, the hoster's console |
| `Permission denied` for a user with a key | Not on the `AllowUsers` list — menu item 2 shows it |
| `Permission denied (publickey)` despite a key | Permissions on `~/.ssh` and `authorized_keys`, or the key sits with the wrong user. Menu item 2 lists who has one |
| The connection drops after a few minutes | ClientAlive is off and something in between clears the session away — menu item 1, switch ClientAlive on |
