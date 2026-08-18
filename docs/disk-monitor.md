# disk-monitor.sh — disk space monitoring

Checks every real filesystem via cron and alerts when one of them has **less
than X GB free**. One number, the same for every filesystem, and that is the
whole configuration.

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
MOUNTPOINT                  FREE GB   TOTAL GB  STATE TREND
/                              28.1      100.0  ok    -0.50 GB/day, threshold in about 36 days
/var                            4.2       50.0  low   -1.20 GB/day, already below the threshold
/backup                       600.0     1000.0  ok    stable

Alert below 10 GB free.
```

## The setup asks two questions

```
Alert below how many GB free?  [10]
Mail address for alerts        (empty = none)
```

That is it. Everything else has a default that is right on almost every server
and is not asked for — it can still be edited in `disk-monitor.conf`:

| Setting | Meaning | Default |
|---|---|---|
| `FREE_MIN_GB` | **alert below this many GB free** | 10 |
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
and that is a number in GB. One threshold covers every filesystem, because "10
GB left" means the same thing everywhere.

A 4 TB backup disk at 97 % use therefore stays quiet: it still has 120 GB free.

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
| A small filesystem is permanently `low` | `/boot` in particular is often below 10 GB in total. Exclude it (menu item 3) or lower the threshold |
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
