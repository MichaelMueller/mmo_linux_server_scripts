# auto-update.sh — automatic apt updates

Applies apt updates via cron and sends a report by mail. Either security updates
only or all packages.

## Requirements

- Debian or Ubuntu (apt), root rights
- for the mail report: a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./auto-update.sh              # menu
sudo ./auto-update.sh --run        # one run, the way cron does it
sudo ./auto-update.sh --status     # schedule and scope
sudo ./auto-update.sh --uninstall  # remove cron and the configuration
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit settings |
| 2 | Apply updates now (with output) |
| 3 | Show pending updates |
| 4 | Show the log |
| 5 | Uninstall |
| 6 | Quit |

## Settings

| Setting | Options | Default |
|---|---|---|
| Schedule | daily / weekly | daily |
| Weekday | 0 = Sunday … 6 = Saturday | Sunday |
| Time | HH:MM | 04:17 |
| Scope | security updates only / all packages | security updates |
| autoremove | yes / no | yes |
| **Allow a reboot** | yes / no | no (only report it) |
| Report to | mail address, empty = no mail | empty |
| **Mail when packages were installed** | yes / no | yes |
| **Mail on errors** | yes / no | yes |
| **Mail even without a change** | yes / no | no |

Stored in `auto-update.conf` next to the script.

The three mail switches are independent of each other — so you can be told about
errors only, about actual installations only, or both. If all three are off,
nothing is ever mailed and everything only goes to the log.

**Allow a reboot** decides what happens after a kernel or libc update: with
"yes" the server comes back up a minute later (`shutdown -r +1`), with "no" the
note only appears in the report — the server then keeps running on the old
kernel until someone takes care of it.

> Older `auto-update.conf` files with the former single value `MAIL_WHEN` are
> translated to the three switches automatically when they are loaded; nothing
> has to be set up again.

## Cron

```
# /etc/cron.d/auto-update
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root /path/to/auto-update.sh --run >/dev/null 2>&1
```

`/etc/cron.d` instead of the user crontab: an explicit user field (the job runs
as root, so apt needs no passwordless `sudo`), one file per job, and a settable
`PATH` — cron otherwise starts with `/usr/bin:/bin`.

The path in the cron entry is the one that was valid at setup time. If you move
the script, you have to run menu item 1 once more.

## What a run does

1. `apt-get update`
2. Determine the package list (see below)
3. Nothing to do → report "no updates", done
4. Otherwise: with "all packages" an `apt-get dist-upgrade`, with "security
   updates only" an `apt-get install --only-upgrade <list>`
5. `apt-get autoremove`, if switched on
6. Check `/var/run/reboot-required`
7. Write the report to the log, mail it if applicable
8. Reboot, if that was chosen (`shutdown -r +1`)

### How security updates are recognised

Through the suite name in `apt list --upgradable`, that is `bookworm-security`,
`jammy-security` and so on. Custom repos without that naming scheme are not
caught by this mode — if you use such repos, take "all packages".

### Why without `set -e`

The runner collects errors and reports them at the end instead of aborting in
the middle and swallowing the report. The exit status is still ≠ 0 when
something went wrong, and the subject then starts with `[ERROR]`.

### dpkg conflicts

Updates run with

```
-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
```

So a configuration file changed by hand stays as it is. An unattended run must
not get stuck on a question. The package's new version then sits next to it as
`.dpkg-dist`.

## Report

Subject lines:

```
auto-update host: 7 package(s) updated
auto-update host: no updates
[ERROR] auto-update host
```

The body contains the timestamp, the scope, the package list, apt's complete
output and the note about a necessary reboot.

Without a mailer set up, everything only goes to the log
(`var/auto-update.log`, capped at the last 2000 lines).

## Files created

| Path | Contents |
|---|---|
| `auto-update.conf` | configuration (next to the script) |
| `var/auto-update.log` | log of all runs |
| `/etc/cron.d/auto-update` | schedule |

## State and data

**Its own state, unavoidably:** there is no service behind apt updates that
could hold a schedule. The settings live in `auto-update.conf` next to the
script, the schedule in `/etc/cron.d/auto-update`, the log in
`var/auto-update.log`.

Nothing is changed about apt itself: no extra sources, no pins, no `apt.conf`
snippets. The tool only calls `apt-get`, the way you would by hand. If
`unattended-upgrades` runs in parallel, you should decide on one of the two —
otherwise two runs fight over the dpkg lock.

## Uninstall

Removes the cron entry and the configuration, asks separately about the log.
Beforehand a backup is written to `/root/auto-update-uninstall-<time>.tar.gz`.
Updates already applied of course stay; it is only that no new ones arrive
automatically.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cron does not run | The path in the cron entry is no longer right (the script was moved) — run menu item 1 again |
| "no updates" although some are pending | Mode "security updates only" and the packages come from a repo without a `-security` suite |
| No mail | `mail` is missing or no recipient is set; the log says which of the two |
| The report arrives every day although nothing happens | "Mail even without a change" is on |
| No reboot happens | It is set to "only report it" — the note is in the report |
| `Could not get lock /var/lib/dpkg/lock` | Another apt operation was running at the same time, unattended-upgrades for instance. Running both in parallel makes no sense |
