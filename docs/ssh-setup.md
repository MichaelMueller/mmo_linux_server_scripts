# ssh-setup.sh — secure SSH access

Secures the SSH access in one of two ways and hardens sshd through a drop-in
(port, root login, keys instead of passwords, a few limits). The `sshd_config`
itself stays untouched.

| | Tailnet | Public |
|---|---|---|
| Reachable | only over the Tailscale tailnet (rule on `tailscale0`) | from the internet |
| Root login | allowed, also with password — the tailnet is the gate | forbidden |
| Password login | stays on | off (keys only) |
| Admin user | optional | a personal non-root user with sudo and key, created and tested |
| Port | kept | a random port 10000–29999 without "22" in it — does not look like SSH |
| Closed afterwards | the public SSH rules, after a tested login over the tailnet | the old port, after a tested login on the new one |
| fail2ban | not needed | offered (default yes) |

In the tailnet way, Tailscale SSH is switched off: it would take over port 22
on the tailnet IP and refuse with "tailnet policy does not permit you to SSH".
If the server is not in a tailnet yet, `tailscale-setup.sh --login` is offered.
Before the public rule goes, `ssh-keyscan` checks that sshd answers on the
tailnet IP. Afterwards, and in the status, a warning appears whenever passwords
are allowed while the SSH port is still open to the internet.

The real substance of this tool is the precautions against locking yourself out
— the individual directives would be written by hand in two minutes.

## Requirements

- Debian or Ubuntu with systemd
- root rights
- **a second, open SSH session** for as long as you work on this

## Usage

```bash
sudo ./ssh-setup.sh              # menu
sudo ./ssh-setup.sh --setup      # guided: tailnet or public, admin, port, lock
sudo ./ssh-setup.sh --harden     # only the hardening values
sudo ./ssh-setup.sh --add-key    # store a public key for a user
sudo ./ssh-setup.sh --status     # effective settings
sudo ./ssh-setup.sh --uninstall  # back to the distribution default
```

## Menu

| Item | Effect |
|---|---|
| 1 | Secure the access (guided: tailnet or public, admin user, port, lock) |
| 2 | Hardening values only |
| 3 | Status: `sshd -T`, drop-in, socket activation, keys on file, listening ports, exposure warning |
| 4 | Store a public key for a user |
| 5 | Create an admin user (sudo + key) |
| 6 | Close an old SSH port in ufw (after a successful test) |
| 7 | Uninstall |
| q | Quit |

Values fixed by a caller (`DEFAULT_SSH_ACCESS`, `DEFAULT_ADMIN_USER`,
`DEFAULT_SSH_PORT` …): see [Presets and batch mode](#presets-and-batch-mode).

**fail2ban** (public way, or menu `f`): bans an address for 1 hour after 5
failed logins within 10 minutes, on the actual SSH port; the tailnet
(100.64.0.0/10) is never banned. The source is the systemd journal - Debian 12
has no `/var/log/auth.log` without rsyslog. Jail: `/etc/fail2ban/jail.d/ssh-setup.local`.
Tested with real failed logins from a second host on Debian 12 and Ubuntu 24.04;
Debian 13's fail2ban also matches OpenSSH 10's `sshd-session`.
For more than that - other thresholds, your own `ignoreip`, repeat offenders,
Caddy - use [fail2ban-setup](fail2ban-setup.md). Its sshd jail
(`sshd-mmo.local`) is read after this one and wins; ssh-setup moves the `port`
line in both files along whenever it changes the SSH port.

Admin users are created with `useradd`: Debian's `adduser` rejects names with a
dot such as `jane.doe`.

## How the setup runs

First **all** the questions, then a summary, then **one** confirmation. Nothing
is touched before that. When every value of this screen is preset (`DEFAULT_SSH_PORT`
… `DEFAULT_CLIENT_ALIVE`), the confirmation is skipped as well.

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

## Presets and batch mode

**A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default).** A set (non-empty) variable is a fixed value, a
*preset*: its question is not asked — interactively neither — and the tool
prints one line instead, e.g. `Access: public (preset)`, `SSH port: 14873
(preset random)`, `Install fail2ban …? -> no (preset)`. `DEFAULT_SSH_ACCESS`
skips the access menu, `DEFAULT_ADMIN_USER` and `DEFAULT_ADMIN_KEY…` the name
and key questions. When all hardening values (`DEFAULT_SSH_PORT`,
`DEFAULT_ROOTLOGIN_CHOICE`, `DEFAULT_PASSWORD_OFF`, `DEFAULT_MAX_AUTH_TRIES`,
`DEFAULT_LOGIN_GRACE_TIME`, `DEFAULT_X11_FORWARDING`, `DEFAULT_CLIENT_ALIVE`)
are preset, "Apply like this?" is not asked either.

An invalid preset (`DEFAULT_SSH_PORT=abc`, `DEFAULT_ROOTLOGIN_CHOICE=5`, a key
`ssh-keygen -l` rejects …) is an error: message on stderr, exit 1, nothing
changed — all presets are checked before the first change.

`BATCH=1` (set by `base-setup.sh`) runs `--setup` (and `--harden`) without
ordinary questions: the questions without a preset take their default and the
tool prints one line saying what it took. A required value without a default
is an error (message on stderr, exit 1, nothing changed).

**Exception — the login tests are always asked for real**, with presets and in
batch mode, on the terminal (`/dev/tty` in batch mode):

- "Does the key login as '…' work, including sudo?" (public way) and its "Try again?"
- "Does the login on port N work?" (public way, new port) and its "Try again?"
- "Does SSH over the tailnet (…) work?" (tailnet way) and its "Try again?"

Without a terminal (cron, `ssh host cmd`, `</dev/null` with no tty) each of
them counts as **no**: in the public way sshd and the firewall stay unchanged,
after a port change the old port stays open in ufw, in the tailnet way the
public SSH rules stay. The tool says so.

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_SSH_ACCESS` | tailnet / public / keep | tailnet when in a tailnet, else public |
| `DEFAULT_TS_JOIN` | Y / N — join the tailnet (tailscale-setup.sh `--login`) when not in one | Y |
| `DEFAULT_CREATE_ADMIN` | Y / N — admin user also in the tailnet way | N |
| `DEFAULT_ADMIN_USER` | user name, e.g. `jane.doe` | none — required in the public way |
| `DEFAULT_ADMIN_KEY`, `DEFAULT_ADMIN_KEY_2` … `_9` | one full public key line each, `ssh-ed25519 AAAA… comment`; checked with `ssh-keygen -l` | none — at least one required for an admin user |
| `DEFAULT_SSH_PORT` | random / keep / a number | public: random, tailnet: keep |
| `DEFAULT_ROOTLOGIN_CHOICE` | 1 key only, 2 no, 3 yes | public: 2, tailnet: 3 |
| `DEFAULT_PASSWORD_OFF` | Y / N | public: Y, tailnet: N |
| `DEFAULT_MAX_AUTH_TRIES` | number | current value (sshd default 6) |
| `DEFAULT_LOGIN_GRACE_TIME` | seconds | current value (sshd default 120) |
| `DEFAULT_X11_FORWARDING` | Y / N | N |
| `DEFAULT_CLIENT_ALIVE` | Y / N — drop dead sessions after ~10 min | Y |
| `DEFAULT_FAIL2BAN` | Y / N (public way) | Y |
| `TS_LOGIN_SERVER` | control server URL, handed on to tailscale-setup | — |

Secret, read from the environment only and never printed or logged:

| Variable | Meaning |
|---|---|
| `ADMIN_PASSWORD` | password for the admin user (`chpasswd`). Without it, batch mode sets none — the user can log in with the key but needs a password for sudo (`passwd <user>`). |
| `TS_AUTHKEY` | auth key for joining the tailnet, see tailscale-setup.md |

Y / N also accept yes / no / j / ja / 1 / 0 / true / false. The admin keys
are checked before the user is created; with an invalid key nothing is created
and nothing is changed. Without a preset key the key is asked for (pasted).

```bash
BATCH=1 DEFAULT_SSH_ACCESS=public DEFAULT_ADMIN_USER=jane.doe \
    DEFAULT_ADMIN_KEY="$(cat jane.pub)" ./ssh-setup.sh --setup
# interactive: access, user and key fixed - the rest is asked, the login tests too
DEFAULT_SSH_ACCESS=public DEFAULT_ADMIN_USER=jane.doe \
    DEFAULT_ADMIN_KEY="$(cat jane.pub)" ./ssh-setup.sh --setup
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Port changed, but sshd still listens on 22 | Socket activation; menu item 2 shows whether it was detected |
| A setting "does not arrive" | The directive sits above the `Include` line — the script offers to comment it out |
| No login possible after the restart | Call `--uninstall` from the second session that is still open; failing that, the hoster's console |
| `Permission denied (publickey)` despite a key | Permissions on `~/.ssh` and `authorized_keys`, or the key sits with the wrong user. Menu item 2 lists who has one |
| The connection drops after a few minutes | ClientAlive is off and something in between clears the session away — menu item 1, switch ClientAlive on |
