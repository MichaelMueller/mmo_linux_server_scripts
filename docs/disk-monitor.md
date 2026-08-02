# disk-monitor.sh — disk space monitoring

Checks the usage of all real filesystems via cron, keeps a sample history,
extrapolates when things will get tight, and alerts on a state change.

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
MOUNTPOINT                  USED   INODES    FREE GB   TOTAL GB  STATE TREND
/                            72%      12%       28.1      100.0  ok    +0.50 %/day, full in about 56 days
/var                         91%       8%        4.2       50.0  warn  +1.20 %/day, full in about 7 days
/backup                      40%       2%      600.0     1000.0  ok    stable or falling (-0.10 %/day)
```

## Thresholds

| Setting | Meaning | Default |
|---|---|---|
| `WARN_PCT` | warn from a usage of % | 85 |
| `CRIT_PCT` | critical from a usage of % | 95 |
| `INODE_WARN` | warn from an inode usage of % | 90 |
| `MIN_FREE_GB` | additionally warn when less is free (0 = off) | 0 |
| `INTERVAL_MIN` | gap between checks in minutes | 60 |
| `RETENTION_DAYS` | retention of the sample history in days | 90 |
| `TOP_DIRS` | write the largest directories into the alert | 1 |
| `ALERT_MODE` | `change` or `always` | `change` |
| `ALERT_MAIL`, `ALERT_WEBHOOK` | destinations for alerts | empty |
| `EXCLUDE` | mountpoints that are ignored | empty |

Stored in `disk-monitor.conf` next to the script. If `CRIT_PCT` is not above
`WARN_PCT`, it is corrected automatically.

### Why check inodes?

A filesystem can be full even though there is plenty of space left — then the
inodes are used up. Typical with millions of small files (session files,
maildirs, caches). `df -h` shows none of that, `df -i` does. Both come from the
same call here.

### Why `MIN_FREE_GB`?

Percentages are misleading on large disks: 5 % of 4 TB is 200 GB, 5 % of 20 GB
is one gigabyte. If you need an absolute lower bound, set it in addition.

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

The **state change** between `ok`, `warn` and `crit` is reported:

| Transition | Reported |
|---|---|
| ok → warn / warn → crit | yes |
| warn → warn | no, no kicking while it is down |
| crit → ok | yes, the all-clear |
| new → ok | no |
| new → warn/crit | yes |

`ALERT_MODE="always"` instead reports on every run as long as something is above
the threshold — in case a daily reminder is what you want.

One mail per run listing all the changes, not one per mountpoint.

### What the mail says

```
Disk space on server.example.com
As of: 2026-08-01 09:00:02

Changes:
  - WARN /var: usage 91% >= 85%

Usage:
  <df -hT without pseudo filesystems>

/var
  Trend: +1.20 %/day, full in about 7 days
  Largest directories under /var (max. 2 levels, no other filesystems):
    ...
```

The directory list comes from `du -x -h --max-depth=2`. `-x` stays on the
filesystem, otherwise `du` on `/` would walk through every mount. On very large
filesystems that takes a while — hence it can be switched off (`TOP_DIRS=0`).

## The forecast

A linear extrapolation from the oldest and the newest sample in the history: the
rate in percentage points per day, and from that the days until 100 %. It only
appears once there is at least a day of history, and reports "stable or falling"
when usage goes down.

That is rough and assumes even growth — but it answers exactly the question you
have when a warning arrives: will it last until the maintenance window?

## Files

```
disk-monitor.conf            configuration
var/results/usage.csv        timestamp,mount,pct,inode_pct,free_gb
var/state/<slug>.state       state|time|used|inodes
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
thresholds and the sample history. Everything lives under `DATA_DIR` — by
default `var/` next to the script, freely selectable at setup time, `/var/lib/mmo`
for instance. On the system itself only the cron entry is created; the
measurement is read-only, through `df` and `du`.

The cron entry remembers the path that was valid at setup time. If you move the
script or `DATA_DIR`, go through the settings once — otherwise the sample
history continues in two places and the forecast becomes useless.

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
| Constant mail despite `change` | The usage oscillates around the threshold — raise the threshold a little or lengthen the interval |
| No mail | No recipient, or `mail` is missing; `var/log/alerts.log` has the change anyway |
