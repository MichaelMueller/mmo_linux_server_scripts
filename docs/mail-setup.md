# mail-setup.sh — SMTP sending

Sets up `msmtp` as a sendmail replacement, so the server can send mail through
any SMTP account. The basis for the alerts of `auto-update`, `tcp-monitor` and
`disk-monitor` — and for cron and system mail.

## Requirements

- Debian or Ubuntu (apt), root rights
- the credentials of an SMTP server (host, port, user, password)

## Usage

```bash
sudo ./mail-setup.sh              # menu (sets things up right away on the first start)
sudo ./mail-setup.sh --test       # only send a test mail
sudo ./mail-setup.sh --uninstall  # remove the configuration
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit parameters |
| 2 | Send a test mail |
| 3 | Show the configuration (password masked) |
| 4 | Show the send log |
| 5 | Uninstall |
| 6 | Quit |

## Packages

`msmtp`, `msmtp-mta` and `bsd-mailx` are installed when needed.

- **`msmtp-mta`** creates `/usr/sbin/sendmail` as a reference to msmtp. That way
  cron mail and everything else that calls `sendmail` goes through the
  configured account as well.
- **`bsd-mailx`** provides the `mail` command that the monitoring tools use.

## Setup

| Question | Note |
|---|---|
| SMTP server | required |
| Encryption | STARTTLS (587) / TLS (465) / unencrypted (25) |
| Port | default matching the encryption |
| Authentication | if yes: user and password |
| Sender address | required, ends up as `From` |
| Default recipient | sets the `root:` alias in `/etc/aliases` |
| Certificate check | default yes (`/etc/ssl/certs/ca-certificates.crt`) |

A repeated run offers all previous values as defaults. For the password, an
empty entry means "keep the existing one".

What is produced is `/etc/msmtprc` with `0600` and owner root:

```
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
timeout        20

account        default
host           smtp.example.com
port           587
from           server@example.com
user           server@example.com
password       ...
```

## The root alias

If a default recipient is given, a line `root: address@example.com` is set (or
replaced) in `/etc/aliases` and `newaliases` is called. That way mail programs
send to `root` ends up in the mailbox too.

## The password

It sits in clear text in `/etc/msmtprc`, readable only by root. That is how
msmtp is meant to work. If you do not want that, get an app password from the
provider that is only allowed to send — then the damage on a compromised server
is limited to "can send mail".

## Test mail

Menu item 2 sends a mail with a subject, the hostname and a timestamp to a
freely chosen recipient (default: the root alias). If it fails, the last ten
lines of `/var/log/msmtp.log` are shown straight away.

## Files created

| Path | Contents |
|---|---|
| `/etc/msmtprc` | configuration including the password (`0600`) |
| `/etc/aliases` | the line `root: …` |
| `/var/log/msmtp.log` | send log (`0600`) |
| `/usr/sbin/sendmail` | reference to msmtp, comes from the `msmtp-mta` package |

## Interplay with the other tools

`auto-update`, `tcp-monitor` and `disk-monitor` simply call `mail`. If the
mailer is not set up, they carry on as normal and only write to their log — no
tool aborts because of it.

## State and data

**Service-side:** `/etc/msmtprc` is msmtp's own configuration, plus the `root:`
line in `/etc/aliases`. Nothing sits next to the script.

It can be put on an existing msmtp installation, with one restriction: the
existing values are read out and offered as defaults, but the file is
**rewritten completely** — with exactly one account (`account default`). A
hand-maintained configuration with several accounts, `account` selection by
sender or custom options should be backed up first.

## Uninstall

Removes `/etc/msmtprc`, asks separately about the `root:` alias and the send
log. Beforehand a backup is written to
`/root/mail-setup-uninstall-<time>.tar.gz` (it contains the password — the file
is `0600`).

The packages stay installed. Manually:

```bash
apt purge msmtp msmtp-mta bsd-mailx
```

Careful: that also removes `/usr/sbin/sendmail`, and cron and system mail then
fail **silently**.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `TLS handshake failed` | Wrong encryption type for the port — 587 wants STARTTLS, 465 wants TLS |
| `authentication failed` | With providers using 2FA, the normal password instead of an app password |
| The mail is accepted but never arrives | SPF/DKIM of the sender domain; `from` has to match the account |
| `mail: command not found` | `bsd-mailx` is missing — call menu item 1 again |
| Cron mail does not arrive | `msmtp-mta` is missing, there is no `/usr/sbin/sendmail` |
| Nothing in the log | On a successful handover msmtp writes only one line; `tail -f /var/log/msmtp.log` during the test |
