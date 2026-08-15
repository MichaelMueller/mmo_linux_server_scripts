# root-password.sh — the root password

Sets the root password, either typed or generated, and can lock and unlock the
account. A small tool for the thing you do in the first five minutes on a new
machine and then never think about again.

## Requirements

- Debian or Ubuntu, root rights
- `chpasswd` and `passwd` (both from `passwd`, present everywhere)

## Usage

```bash
sudo ./root-password.sh            # menu
sudo ./root-password.sh --status   # state of the root account
```

**There is no `--uninstall`.** A password is not something that can be taken
back out again — the way back is to set another one. The tool therefore also
does not appear in the uninstall menu of `setup.sh`.

## Menu

| Item | Effect |
|---|---|
| 1 | Generate a password and set it |
| 2 | Type a password and set it (invisible, twice) |
| 3 | Lock the root password |
| 4 | Unlock the root password |
| 5 | Quit |

The status header shows three things: whether a password is set, when it was
last changed, and what `sshd -T` says about `PermitRootLogin` — because those
two together decide whether root can be logged into over the network at all.

## The generated password

24 characters by default, **letters and digits only**. That is deliberate: a
password with shell metacharacters in it gets mangled sooner or later — in a
copy-paste, in a config file, in a provider's web console — and 24 alphanumeric
characters are around 140 bits of entropy, far beyond anything that gets
brute-forced. Minimum length is 12.

Randomness comes from `/dev/urandom`. The password is shown **once**, in a
frame, with the reminder that it is not stored anywhere and cannot be shown
again — and that it is now in the scrollback of the session.

It is set only after a separate confirmation, so an accidental menu entry
changes nothing.

## Why `chpasswd` and not `passwd`

The password goes in through stdin:

```bash
chpasswd <<<"root:${pw}"
```

Anything passed as a command-line argument can be read out of `/proc` by every
user on the machine for as long as the process runs. Through stdin it never
appears in the process list.

## Locking

`passwd -l root` prevents logging in **as root with a password**. What keeps
working: `sudo`, key-based logins and the console in single-user mode. That is
the usual setup on a server — administration through a personal account with
sudo, root without a usable password.

Locked is not the same as "no password": the account stays, its password just
can no longer be used. `passwd -S` distinguishes the two, and so does the status
line here — `NP` (no password at all) is flagged as a problem, because anyone at
the console is then root.

Before locking, the tool points out the obvious risk: it only makes sense while
another account can log in and use sudo. Otherwise nobody gets in any more
except through the provider's rescue system.

## Files changed

| Path | by |
|---|---|
| `/etc/shadow` | the password hash, through `chpasswd` / `passwd` |

Nothing else. The tool writes no configuration of its own and creates no data.

## State and data

**No state of its own — the system is the data store.** Everything shown comes
from `passwd -S root` and `sshd -T`. The tool can therefore be used on any
existing installation without anything drifting apart, and doing the same by
hand (`passwd root`) changes nothing about how it behaves.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `!!! NO PASSWORD` in the status | The root account has an empty password. Set one, or lock the account |
| Password set, `su -` still refuses | Look at PAM (`/etc/pam.d/su`) — some setups only allow `su` for members of the `wheel` or `sudo` group |
| Root login over SSH still impossible | Intended if `PermitRootLogin` is `no`. That is `ssh-setup`'s business, not this tool's |
| Unlocking fails | An account that never had a password cannot be unlocked — set one first |
| The generated password is unusable in a script | It is alphanumeric precisely so that it is usable everywhere; if a tool still chokes, it is quoting the value wrongly |
