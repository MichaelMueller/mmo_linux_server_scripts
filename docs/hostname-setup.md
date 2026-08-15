# hostname-setup.sh — the hostname

Sets the hostname, either typed or generated from the date, and keeps
`/etc/hosts` consistent with it. The second half is the part that is usually
forgotten and the reason this is a tool rather than a one-liner.

## Requirements

- Debian or Ubuntu, root rights
- `hostnamectl` where systemd is present; without it the tool falls back to
  `/etc/hostname` plus `hostname`

## Usage

```bash
sudo ./hostname-setup.sh            # menu
sudo ./hostname-setup.sh --status   # hostname, FQDN, /etc/hostname
```

**There is no `--uninstall`.** A hostname cannot be removed, only replaced. The
previous values are in the backup that every change writes, and the tool
therefore does not appear in the uninstall menu of `setup.sh`.

## Menu

| Item | Effect |
|---|---|
| 1 | Set a hostname (typed) |
| 2 | Generate a hostname from the date and set it |
| 3 | Quit |

## The generated name

```
<prefix>-yymmdd-hhmm      e.g.  srv-260815-1432
```

The prefix is free (default `srv`). The point of putting the date in the name
is that it **sorts chronologically as a plain string** — useful where machines
are created and thrown away often, and where the interesting question about a
box is usually "when was this one built?".

## Validation

Letters, digits and hyphens, not starting or ending with a hyphen, at most 63
characters — RFC 1123. The classic mistake is the **underscore**: valid in DNS
records, not valid in hostnames, and some tools only reject it much later, in a
place that gives no hint where the problem came from. It is refused here right
away.

## Why `/etc/hosts` is written too

Without a line resolving the new name, every `sudo` waits for a DNS timeout
first, and programs that look up their own name — mailers above all — hang or
fail. The symptom (`sudo: unable to resolve host`) is famous and the cause is
always this.

Debian keeps that line at **`127.0.1.1`**, deliberately not `127.0.0.1`, so
that the machine's own name does not collide with localhost:

```
127.0.1.1	srv-260815-1432.example.com srv-260815-1432
```

If the line exists it is replaced; if not, it is inserted after the localhost
line. **Only that one line is touched** — everything else in `/etc/hosts` can
be anything at all and is none of this tool's business.

## Before every change

`/etc/hostname` and `/etc/hosts` are copied to `*.bak-<timestamp>` next to
themselves. Both old and new name are shown together with what the change
affects, and only then does the confirmation follow.

What it affects, concretely: the shell prompt, the mail subjects and log lines
of every monitoring tool here (they all use `hostname -f`), and anything that
identifies this machine by name. Existing SSH connections keep running; a
monitoring system that keys on the name will see a new host.

**The prompt of the running session keeps showing the old name** — it was set
when the session started. A new login shows the new one. The tool says so, so
nobody concludes the change failed.

## Files changed

| Path | Contents |
|---|---|
| `/etc/hostname` | the name itself |
| `/etc/hosts` | the `127.0.1.1` line |
| `/etc/hostname.bak-<time>`, `/etc/hosts.bak-<time>` | the backup before each change |

## State and data

**No state of its own — the system is the data store.** Everything shown is
read live from `hostname`, `hostnamectl` and `/etc/hostname`. Setting the name
by hand afterwards changes nothing about how the tool behaves.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `sudo: unable to resolve host` | The `/etc/hosts` line is missing or still names the old host — run the tool again, it repairs the line |
| The prompt still shows the old name | The session was started before the change; a new login fixes it |
| `hostname -f` gives only the short name | No domain was entered, so there is no FQDN to give. Run again and supply one |
| The name is back after a reboot | Something else sets it: cloud-init (`preserve_hostname: false` in `/etc/cloud/cloud.cfg`) or the DHCP server |
| Mails still carry the old name | The mailer caches it; restart the service, or wait for the next run of the cron tools |
