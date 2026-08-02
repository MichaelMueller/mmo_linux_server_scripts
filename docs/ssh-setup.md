# ssh-setup.sh — SSH hardening

Hardens SSH access through a drop-in: port, root login, keys instead of
passwords and a few limits. The `sshd_config` itself stays untouched.

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
| 3 | Store a public key for a user |
| 4 | Close port 22 in ufw (after a successful test) |
| 5 | Uninstall |
| 6 | Quit |

## How the setup runs

First **all** the questions, then a summary, then **one** confirmation. Nothing
is touched before that.

| Question | Options | Default |
|---|---|---|
| Port | 1–65535 | current port |
| Root login | key only / forbid / password too | key only |
| Password login | switch off yes/no | switch off, if a key exists |
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
Port 22 stays open alongside; menu item 4 closes it later and refuses as long as
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
nothing, password login stays on — with a pointer to menu item 3.

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
| ufw rules | the new port and 22 are opened |

## Storing a key (menu item 3)

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
usually allowed). **Keys on file stay in place.**

The uninstall also recognises the German prefix `# von ssh-setup deaktiviert: `
that versions up to 1.0.0 wrote, so those lines are reactivated too.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Port changed, but sshd still listens on 22 | Socket activation; menu item 2 shows whether it was detected |
| A setting "does not arrive" | The directive sits above the `Include` line — the script offers to comment it out |
| No login possible after the restart | Call `--uninstall` from the second session that is still open; failing that, the hoster's console |
| `Permission denied (publickey)` despite a key | Permissions on `~/.ssh` and `authorized_keys`, or the key sits with the wrong user. Menu item 2 lists who has one |
| The connection drops after a few minutes | ClientAlive is off and something in between clears the session away — menu item 1, switch ClientAlive on |
