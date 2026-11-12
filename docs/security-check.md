# security-check.sh

All-round check of a Debian/Ubuntu server: is the machine still clean? Standalone
— copy the single file to a server and run it; it needs nothing next to it.

```bash
sudo ./security-check.sh                 # run all checks (5-15 minutes)
sudo ./security-check.sh --mail a@b.de   # also mail the report
sudo ./security-check.sh --no-install    # only use what is installed
sudo ./security-check.sh --accept        # accept the current state as rkhunter baseline
sudo ./security-check.sh --schedule      # run it regularly by cron (monthly/weekly)
sudo ./security-check.sh --unschedule    # remove the regular run
```

**Regular run:** `--schedule` writes `/etc/cron.d/security-check` (monthly on
the 1st or weekly on Sunday, 04:40) and installs the packages right away. The
cron run (`--cron`) mails only when something is to check or a check could not
run, and keeps the last 12 reports. Settings in `security-check.conf`
(`SCHEDULE`, `SCHED_MAIL`); presets from a caller: `DEFAULT_SCHEDULE`,
`DEFAULT_MAIL_TO`.

## Presets and batch mode

A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default). A preset is a fixed value: its question in
`--schedule` is skipped - interactively and in batch mode - and the tool
prints one line instead, e.g. `Choice: weekly (preset)`. A preset wins over
the value stored in `security-check.conf`.

With `BATCH=1` (set by `base-setup.sh`) `--schedule` asks nothing: questions
without a preset take their default (stored or built-in) and print what they
took. `--accept` answers "no" in batch mode.

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_SCHEDULE` | `monthly`, `weekly`, `off` | `monthly` (`weekly` if that is stored) |
| `DEFAULT_MAIL_TO` | recipient of the findings; `-` = none | empty (report files only) |

An invalid `DEFAULT_SCHEDULE` stops `--schedule` with a message on stderr and
exit code 2; nothing is written.

## What it checks

| Check | Tool | Finding means |
|---|---|---|
| Package files | `debsums -s` | an installed program or library differs from its package |
| Rootkits | `rkhunter -c --rwo` | known rootkits, changed system binaries, hidden processes |
| Rootkits (second opinion) | `chkrootkit -q` | the same with an independent tool |
| Audit | `lynis audit system` | hardening score, warnings and suggestions |
| Failed services | systemd | units in state failed |
| Extra root accounts | `/etc/passwd` | an account besides root with UID 0 |
| Empty passwords | `/etc/shadow` | an account that logs in without a password |
| SUID outside packages | `find` + `dpkg -S` | a SUID/SGID file no package installed |
| Executables in tmp | `/proc`, `find` | programs running from or lying in `/tmp`, `/var/tmp`, `/dev/shm` |
| Listening ports, SSH keys, cron jobs, SSH logins | on-board | information only, listed in the report |

Missing packages (`debsums rkhunter chkrootkit lynis`, plus `lsof unhide`) are
installed without recommends, so no mail server is pulled in.

## Result

The screen shows a summary; the full report is written to
`var/security-check/<host>-<date>.txt` next to the script (mode 600).

| Status | Meaning |
|---|---|
| OK | nothing found |
| CHECK | look at it — not necessarily compromised |
| INFO | for reading, nothing judged automatically |
| ERROR | the check could not run |

Exit code: 0 nothing found, 1 something to check, 2 a check could not run.

## rkhunter

The packaged `/etc/rkhunter.conf` breaks on some systems (`WEB_CMD="/bin/false"`,
whitelist entries for files that do not exist). The script does not edit `/etc`;
it generates a cleaned copy at `/var/lib/rkhunter/security-check.conf` and uses
`PKGMGR=DPKG`, so package updates are no findings.

The first run creates the baseline of the system files — changes count from the
next run. After updates or after findings were checked: `--accept`.

## False alarms

- rkhunter after manual changes to system files (then `--accept`)
- chkrootkit `PACKET SNIFFER` for dhclient/systemd-networkd
- scripts in `/tmp` left by an installer
- in containers: no `/lib/modules`, no syslog daemon, no utmp

## On a real suspicion

Do not clean up on the machine. Take it off the network and escalate — a
compromised system can fool all of these tools. A check run on a machine that
is already compromised is of limited value.
