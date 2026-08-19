# disk-monitor.sh — disk space monitoring

Checks the mounted filesystems via cron and alerts when one of them has **less
than X GB free**. The filesystems are found by themselves; what you configure is
which of them are big enough to be worth watching, and how much room each one
should keep.

## Requirements

- Linux with GNU coreutils (`df --output`), root rights
- for mail alerts, a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./disk-monitor.sh              # menu
sudo ./disk-monitor.sh --check      # one run, the way cron does it
sudo ./disk-monitor.sh --status     # usage and forecast on stdout
sudo ./disk-monitor.sh --uninstall  # remove cron, configuration and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit settings |
| 2 | Check now (also shows what would be mailed) |
| 3 | Manage exclusions |
| 4 | Show alerts |
| 5 | Uninstall |
| 6 | Quit |

The overview sits right in the main menu:

```
MOUNTPOINT                 FREE GB  TOTAL GB   ALERT<  STATE TREND
/                             28.1     100.0       10  ok    -0.50 GB/day, threshold in about 36 days
/boot                          1.0       4.0        -  not watched (below 20 GB total)
/mnt/scratch                  20.0      30.0        -  not watched (switched off in the setup)
/var                           4.2      50.0       10  low   -1.20 GB/day, already below the threshold
/backup                      600.0    1000.0      150  ok    stable

Default threshold 10 GB; filesystems are listed in the setup from 20 GB total size on.
Menu item 1 selects what is watched and sets the threshold per filesystem.
```

## What the setup asks

The filesystems themselves are **never** typed in: they come from `df`, so the
list is whatever is mounted at that moment. What you do is set a size limit,
pick from the list, and give each pick its threshold.

```
--- Which filesystems to consider ---
/ is always watched, whatever its size.
List filesystems from this total size on (GB) [20]: 20

--- Found ---
   1) /                            27.0 GB free of     60.0 GB
   2) /home                        88.0 GB free of    100.0 GB
   3) /srv/backup                 100.0 GB free of   2000.0 GB
   4) /mnt/scratch                 20.0 GB free of     30.0 GB

Which of these should be watched? Numbers separated by space or comma,
'a' or empty = all of them.
Selection [a]: 1 2 3

--- Threshold ---
Alert below how many GB free? [10]: 10

--- Per selected filesystem ---
Enter keeps the general 10 GB.
  / (60.0 GB total), alert below           [10] GB:
  /home (100.0 GB total), alert below      [10] GB: 20
  /srv/backup (2000.0 GB total), alert below [10] GB: 150
  /mnt/scratch: not watched
```

The four steps, and what each is for:

1. **The size limit (`MIN_FS_SIZE_GB`, default 20)** decides what even appears in
   the list. `/boot` has 2–4 GB in total and `/boot/efi` half of one, so any
   sensible threshold would mark them low for ever — and an alert that is always
   on is one nobody reads. Set it to 0 to see everything.
   **`/` is exempt and always watched**, whatever its size: a small VPS has a
   15 GB root, and that is precisely the filesystem whose running full takes the
   machine with it.
2. **The list** is numbered and shows free and total size, plus what is currently
   configured for each when you run the setup again.
3. **The selection** is authoritative. Numbers, space- or comma-separated;
   `a` or empty takes all of them. Anything listed but *not* picked is written
   down as `off` — a decision has to survive, and leaving no entry would hand the
   filesystem back to the size rule that put it on the list to begin with.
4. **The threshold per pick.** The general `FREE_MIN_GB` is offered as the
   default for each one; what you confirm is stored for that filesystem. A 2 TB
   backup disk wants 150 GB, a small root maybe 5 — which is the entire reason
   for doing this per mountpoint.

A filesystem mounted **later** is not in `MOUNT_MIN_GB` at all, and for those the
size rule applies with the general threshold. So a new disk is watched without
anyone having to remember it, and it shows up in the overview where you can give
it a value of its own.

| Setting | Meaning | Default |
|---|---|---|
| `MIN_FS_SIZE_GB` | only list/consider filesystems from this total size on; 0 = all. `/` is always watched | 20 |
| `FREE_MIN_GB` | general threshold, offered as the default per filesystem and used for ones appearing later | 10 |
| `MOUNT_MIN_GB` | bash array per mountpoint: a number = watched with that threshold, `off` = never watched | empty |

The rest has a default and is not asked for; it can be edited in
`disk-monitor.conf`:

| Setting | Meaning | Default |
|---|---|---|
| `INODE_WARN` | inodes % that also counts as full; 0 = off | 90 |
| `INTERVAL_MIN` | gap between checks in minutes | 60 |
| `RETENTION_DAYS` | retention of the sample history in days | 90 |
| `TOP_DIRS` | write the largest directories into the alert | 1 |
| `ALERT_MAIL` | recipient of the alerts | empty |
| `EXCLUDE` | mountpoints that are ignored (menu item 3) | empty |

### Why GB and not percent

Because a percentage does not answer the question. 5 % of a 4 TB disk is 200 GB
and perfectly comfortable; 5 % of a 20 GB root is one gigabyte and already too
late. The same percentage means opposite things on two filesystems of the same
machine, which is why the old `WARN_PCT` / `CRIT_PCT` pair needed a `MIN_FREE_GB`
next to it to be useful at all.

What you actually want to know is whether there is still room to work with —
and that is a number in GB. One general threshold covers most filesystems,
because "10 GB left" means the same thing everywhere, and the handful where it
does not get one of their own.

A 4 TB backup disk at 97 % use therefore stays quiet: it still has 120 GB free —
unless you gave it a threshold that says 120 GB is not enough on a disk that
size, which is exactly what `MOUNT_MIN_GB` is for.

### Why inodes are still checked

A filesystem can be full even though there is plenty of space left — then the
inodes are used up. Typical with millions of small files (session files,
maildirs, caches). `df -h` shows none of that, `df -i` does, and both come from
the same call here. It costs no question and catches a real failure, so it
stays on; `INODE_WARN=0` in the conf switches it off.

## Which filesystems are checked

Pseudo filesystems are skipped: `tmpfs`, `devtmpfs`, `squashfs`, `overlay`,
`proc`, `sysfs`, `cgroup`, and others. `tmpfs` never runs "full" in the sense of
a problem, and `squashfs` (every snap package) is 100 % used by definition —
without that filter the alert would consist of nothing but false alarms.

Further mountpoints can be excluded through menu item 3.

Reading happens with

```bash
df -B1K --output=fstype,pcent,ipcent,avail,size,target
```

That guarantees the mountpoint is at the end of the line — it may contain spaces
and would shift every field in the classic `df` output.

## Alerting

There are two states, `ok` and `low`, and the **change** between them is what
gets reported:

| Transition | Reported |
|---|---|
| ok → low | yes |
| low → low | no, no kicking while it is down |
| low → ok | yes, the all-clear |
| new → ok | no |
| new → low | yes |

One mail per run listing all the changes, not one per mountpoint.

### What the mail says

```
Disk space on server.example.com
As of: 2026-08-01 09:00:02

Changes:
  - LOW /var: only 4.2 GB free (below 10 GB)

Usage:
  <df -hT without pseudo filesystems>

/var
  Trend: -1.20 GB/day, already below the threshold
  Largest directories under /var (max. 2 levels, no other filesystems):
    ...
```

The directory list comes from `du -x -h --max-depth=2`. `-x` stays on the
filesystem, otherwise `du` on `/` would walk through every mount. On very large
filesystems that takes a while — hence it can be switched off (`TOP_DIRS=0`).

## The forecast

A linear extrapolation from the oldest and the newest sample in the history: how
many **GB per day** the filesystem is losing, and from that the days until it
reaches the threshold. It only appears once there is at least a day of history,
and says `stable` when nothing is being lost.

That is rough and assumes even growth — but it answers exactly the question you
have when the alert arrives: will it last until the maintenance window?

## Files

```
disk-monitor.conf            configuration
var/results/usage.csv        timestamp,mount,pct,inode_pct,free_gb
var/state/<slug>.state       state|time|free_gb|inodes
var/log/alerts.log           state changes
var/log/disk.log             run log (last 2000 lines)
/etc/cron.d/disk-monitor     schedule
```

The slug is the mountpoint with `/` replaced by `_`; `/` itself is called
`root`.

The exit code of `--check` is 1 for as long as a filesystem is above the
threshold.

## State and data

**Its own state, unavoidably:** there is no service that could hold the
threshold and the sample history. Everything lives under `DATA_DIR` — by
default `var/` next to the script, and changeable only as `DATA_DIR` in the
conf file. On the system itself only the cron entry is created; the
measurement is read-only, through `df` and `du`.

The cron entry remembers the path that was valid at setup time. If you move the
script, or change `DATA_DIR` in the conf, run the settings once so the cron
entry is rewritten — and move the existing directory yourself, otherwise the
sample history continues in two places and the forecast becomes useless.

## Uninstall

Removes the cron entry and the configuration, asks separately about the data
directory. Backup beforehand to `/root/disk-monitor-uninstall-<time>.tar.gz`. No
packages were installed, nothing is left behind.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `df: unrecognized option '--output'` | Not GNU coreutils (BusyBox, a very old system) |
| A mountpoint is missing from the list | A pseudo filesystem or in `EXCLUDE`; menu item 3 shows both |
| Inodes show 0 % | The filesystem has no fixed inode table (btrfs, zfs, xfs in part) — `df` returns `-` there |
| No forecast | Less than a day of history, or the filesystem has only just appeared |
| The check takes a long time | `du` for the largest directories; `TOP_DIRS=0` switches that off |
| Constant mail | The free space oscillates around the threshold — raise it a little or lengthen the interval |
| No mail | No recipient, or `mail` is missing; `var/log/alerts.log` has the change anyway |
| A disk at 97 % raises no alert | Intended: it still has more than `FREE_MIN_GB` free. The criterion is the room left, not the percentage |
| A small filesystem is permanently `low` | It was selected in the setup, so it has a number in `MOUNT_MIN_GB`. Run menu item 1 and leave it out of the selection, or give it a smaller threshold |
| A filesystem I selected is not watched | Its entry says `off`, or it fell below `MIN_FS_SIZE_GB` and never made the list. The overview names which of the two it is |
| A newly mounted disk is watched although I never picked it | Intended: filesystems with no entry follow the size rule, so a new disk is not silently unwatched. Set it to `off` in the setup if you do not want it |
| A filesystem is missing from the table | Below the size limit, in `EXCLUDE`, or a pseudo filesystem. The overview names the first case explicitly |
| A small `/` is not watched | It is: `/` is exempt from the size filter, whatever its size |
| The old percentage thresholds are gone | Deliberate, since 2.2.0. An existing `MIN_FREE_GB` was taken over as `FREE_MIN_GB`; `WARN_PCT`/`CRIT_PCT` in the conf are ignored and can be deleted |

## Alerting goes through the local mailer

There is **one** channel: the `mail` / sendmail on this machine, put there by
[mail-setup.sh](mail-setup.md) (SMTP) or [graph-mailer.sh](graph-mailer.md)
(Microsoft 365). The webhook option was removed — one path that is set up
properly and can be tested beats two half-configured ones, and every tool here
now reports the same way.

The setup therefore checks whether a mailer exists at all. If none is found it
says so, names the two scripts that install one, and asks whether to continue
regardless; declining writes no configuration, so the tool stays "not set up"
rather than quietly monitoring into a void. Without a recipient address, state
changes still go to the alert log under `var/`.
