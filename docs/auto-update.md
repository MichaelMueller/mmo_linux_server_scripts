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
| **Excluded packages** | names or globs, space-separated | empty |
| autoremove | yes / no | yes |
| **Allow a reboot** | yes / no | no (only report it) |
| **Redeploy after an installation** | yes / no | no |
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

## Excluding packages

`EXCLUDE_PKGS` is a space-separated list of package names or shell globs, so
`docker*` covers the whole family:

```
EXCLUDE_PKGS="docker-ce docker-ce-cli containerd.io"
```

The case this exists for is the container engine: an apt run restarts it and
takes every container with it — at 04:17, unattended. Better done by hand at a
time of your choosing.

**The two scopes need different levers**, because they work differently:

- **Security updates only.** The package list is built here and handed to
  `apt-get install --only-upgrade`, so leaving names out of it is enough.
  Nothing about the system changes.
- **All packages.** `dist-upgrade` takes no package list at all — there the only
  reliable lever is `apt-mark hold`. The excluded packages are pinned before the
  run and released again afterwards.

Two things about those holds, because a leaked hold is worse than the problem
it solves — a package silently never updated again, security fixes included:

- **Only packages held by this tool are released.** A hold that was already
  there before the run belongs to someone else and is left alone.
- **The release is armed as a trap before the first hold is set**, so a failed
  run, a `Ctrl-C` or a kill in the middle cannot leave the system pinned.

What was skipped is named in the report (`Excluded, deliberately not installed`)
and marked in the pending list of menu item 3 — so the mail says plainly that
docker had an update available and did not get it.

> An excluded package gets **no security updates either**. Check now and then by
> hand: `apt list --upgradable`.

## Redeploy after an installation

With `POST_UPDATE_REDEPLOY=1`, a run that actually installed something calls

```bash
git-updater.sh --redeploy
```

afterwards, and puts its output into the report under `--- Redeploy ---`. That
brings the Docker Compose stacks back up (`compose up -d`) after a package
update restarted the container engine underneath them. No git operation is
involved — nothing is pulled, nothing about the working copies changes.

It runs after **any** run that installed packages, not only after docker ones:
`compose up -d` does nothing where nothing changed, so the extra call costs
nothing, and gating it on "was docker among the packages?" would never fire on
the setup that needs it most — the one that has docker on the exclusion list.

The question is only asked when `git-updater.sh` sits next to this script, and a
missing one at run time is noted in the report and skipped rather than failing
the update run. The tools stay independent of one another.

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
2. Determine the package list (see below) and split it into "to be installed"
   and "excluded"
3. Nothing to do → report "no updates", done
4. Otherwise: with "all packages" an `apt-get dist-upgrade` (the exclusions
   pinned with `apt-mark hold` for the duration of the run, and released again
   afterwards), with "security updates only" an
   `apt-get install --only-upgrade <list without the exclusions>`
5. `apt-get autoremove`, if switched on
6. Redeploy the compose stacks, if switched on and something was installed
7. Check `/var/run/reboot-required`
8. Write the report to the log, mail it if applicable
9. Reboot, if that was chosen (`shutdown -r +1`)

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
output and the note about a necessary reboot — plus, where they apply, the
`Excluded, deliberately not installed` block and the `--- Redeploy ---` section.

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
| An excluded package is updated anyway | The pattern does not match. Check with `apt list --upgradable` how the package is really called — `docker` is not `docker-ce` |
| A package stays on hold after a run | Should not happen; the release is armed as a trap. Check with `apt-mark showhold` and release with `apt-mark unhold <pkg>` |
| An excluded package never gets security fixes | That is what an exclusion is. Update it by hand now and then |
| The redeploy section is missing from the report | It only runs when something was actually installed and the run had no errors |
