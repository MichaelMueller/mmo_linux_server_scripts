# resource-monitor.sh — CPU and RAM monitoring

Watches **sustained** CPU load and memory pressure and alerts on a state
change. The emphasis is on sustained: a build, a backup or a nightly import
pushes a server to 100 % without anything being wrong, and a monitor that pages
for that gets switched off within the week.

## Requirements

- Debian or Ubuntu, root rights
- Nothing else — everything is read from `/proc`. `mail` only if reports should
  be sent, `curl` only for a webhook.

## Usage

```bash
sudo ./resource-monitor.sh              # menu
sudo ./resource-monitor.sh --check      # one run (this is what cron calls)
sudo ./resource-monitor.sh --status     # current state on stdout
sudo ./resource-monitor.sh --uninstall  # remove cron entry, config and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit settings |
| 2 | Check now (verbose, shows what would be sent) |
| 3 | Show samples and statistics |
| 4 | Show alerts |
| 5 | Uninstall |
| 6 | Quit |

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `INTERVAL_MIN` | 5 | gap between checks |
| `CPU_WARN` / `CPU_CRIT` | 85 / 95 | busy % across the interval |
| `MEM_WARN` / `MEM_CRIT` | 85 / 95 | used % (`MemAvailable` against `MemTotal`) |
| `SWAP_RATE_WARN` | 200 | swapped pages per second, in + out; 0 = off |
| `N_CONSEC` | 3 | readings in a row above the threshold before an alert |
| `TOP_PROCS` | 1 | put the biggest processes into the alert |
| `RETENTION_DAYS` | 30 | how long samples are kept |
| `ALERT_MAIL`, `ALERT_WEBHOOK` | empty | where alerts go |

## Everything is a delta, and that is the point

`/proc/stat` counts jiffies since boot. The difference between two runs divided
by the time between them is the **average across the whole interval** — one
busy minute inside a quiet hour disappears in it, exactly as it should. A
momentary reading (what `top` shows in its first line) would answer a different
question: what the machine is doing in this instant.

The same applies to swapping: `/proc/vmstat` counts pages in and out since
boot, and the rate comes from the difference.

**The first run after setup records the counters and evaluates nothing** — a
delta needs two points. Nothing is missing after that; the run following it
covers the full interval.

A counter that went backwards means a reboot. The sample is then dropped and
only the baseline renewed, rather than a negative or absurd load being reported.

## The debounce gate

This is what separates this tool from the other monitors, which all flip on a
single sample:

- A reading above the threshold increments a counter, a reading back in range
  resets it to zero.
- The state only moves to `warn` / `crit` once the counter has reached
  `N_CONSEC`.
- At the defaults (5 min, 3 readings) that is **a quarter of an hour of
  genuinely sustained load** before anyone is told.

Everything else follows the pattern of the other monitors: an alert only on a
**state change**, so a machine that stays busy for a day sends one mail, not
288; the first reading in a normal state is never an incident; and a return
below the threshold sends exactly one recovery message.

## Swap: the rate matters, not the fill level

Swap occupancy on its own says little. A few hundred MB parked in swap and
never touched again costs nothing — that is the kernel having moved something
unused out of the way, which is what it is supposed to do.

What hurts is swap **traffic**: pages going in and out continuously means the
machine is short of memory *right now* and is spending its time moving pages
instead of working. That is why `SWAP_RATE_WARN` alerts on pages per second,
while the fill level is only reported alongside.

## What lands in an alert

Subject and change list first, then the current readings including the load
average, and only then the expensive part: the biggest processes, collected
with `ps` **and only for the axis that actually alerted** (`--sort=-pcpu` for
CPU, `--sort=-pmem` for RAM). That last part can be switched off with
`TOP_PROCS=0`.

CPU alerts additionally name the `iowait` share. High CPU that is mostly
iowait is not a CPU problem — it is a disk waiting, and you would otherwise
go looking in the wrong place.

## Files created

| Path | Contents |
|---|---|
| `resource-monitor.conf` | the configuration, next to the script |
| `/etc/cron.d/resource-monitor` | the cron entry |
| `var/resources/state/` | one state file per axis, plus the counter baseline |
| `var/resources/results/resources.csv` | samples: `timestamp,cpu_pct,iowait_pct,mem_pct,swap_rate` |
| `var/resources/log/alerts.log` | one line per state change |
| `var/resources/log/resources.log` | one line per run |

`DATA_DIR` is freely selectable. A **relative** path is resolved against the
script's directory, never against the current one — cron stands somewhere else
than you do, and state would otherwise be written in one place and looked for
in another. Changing the directory offers to move the existing data along.

## State and data

State of its own is needed: there is no service behind this that could hold it.
Two things live in `var/resources/state/`: one file per axis
(`STATE|timestamp|value|consec`) and the counter baseline of the last run.

The extra `consec` field is what makes the debounce survive between runs — cron
starts a new process every time, so a counter held in memory would be useless.

## Uninstall

Removes the cron entry and the configuration, and asks separately about the
data directory. A backup is written to
`/root/resource-monitor-uninstall-<time>.tar.gz` first. No packages were
installed, so none are removed.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `--check` reports nothing on the first run | Intended: the first run records the counter baseline. The next one evaluates. |
| No alert although the load is high | The debounce gate. `N_CONSEC` readings in a row are needed — check `consec` in `var/resources/state/cpu.state` |
| No alert although the state is `warn` | Alerts fire on a *change*. It already alerted when it entered `warn` |
| CPU 100 % but nothing is running | Look at `iowait` in the alert: a disk waiting, not a CPU under load |
| RAM permanently at 90 % without swapping | Normal on a server: the kernel uses free memory as cache. `MemAvailable` accounts for that, which is why it is the basis here rather than `MemFree` |
| Cron does not run | With `INTERVAL_MIN >= 60` the entry is written as an hour step; check `/etc/cron.d/resource-monitor` |
