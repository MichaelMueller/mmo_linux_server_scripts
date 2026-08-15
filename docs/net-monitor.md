# net-monitor.sh — network throughput monitoring

Watches **sustained** throughput per interface and alerts on a state change.
Like `resource-monitor`, the emphasis is on sustained: an image pull or a
nightly backup saturates the line for a few minutes and is not an incident.

## Requirements

- Debian or Ubuntu, root rights
- Nothing else — the counters come from `/sys/class/net/`. `mail` only if
  reports should be sent, `curl` only for a webhook.

## Usage

```bash
sudo ./net-monitor.sh              # menu
sudo ./net-monitor.sh --check      # one run (this is what cron calls)
sudo ./net-monitor.sh --status     # interfaces and current rates
sudo ./net-monitor.sh --uninstall  # remove cron entry, config and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Manage interfaces (add / edit / delete) |
| 2 | Check all now (verbose) |
| 3 | Show samples and statistics |
| 4 | Show alerts |
| 5 | Settings |
| 6 | Uninstall |
| 7 | Quit |

## One entry per interface

Thresholds belong to the interface, not to the machine — a 10 Gbit uplink and a
WireGuard tunnel have nothing in common. Each entry is one file under
`var/net/ifaces.d/<name>.conf`:

| Field | Meaning |
|---|---|
| `NAME` | name of the entry, also the name of the state and sample files |
| `IFACE` | the interface, e.g. `eth0`, `wg0`, `tailscale0` |
| `MAX_RX_MBIT` | warn from this incoming rate; **0 = this direction is off** |
| `MAX_TX_MBIT` | warn from this outgoing rate; 0 = off |
| `ENABLED` | `1` or `0` |
| `NOTE` | free text |

The interfaces present on the machine are listed when an entry is created, so
nobody has to type them from memory. Where the interface reports a link speed
(`/sys/class/net/<if>/speed`, physical NICs do, tunnels do not), 80 % of it is
offered as a guide.

Global settings — `INTERVAL_MIN` (5), `N_CONSEC` (3), `RETENTION_DAYS` (30),
`ALERT_MAIL`, `ALERT_WEBHOOK` — sit in `net-monitor.conf`.

## RX and TX are separate axes

Each direction has its own threshold, its own debounce counter, its own state
file and its own alert. A saturated downlink and a saturated uplink are
different incidents with different causes — a backup pushing data out is not
the same as a flood coming in — and adding them into one number would hide
whichever of the two is smaller.

## The debounce gate

Same as in `resource-monitor`: a reading above the threshold increments a
counter, a reading back in range resets it, and the state only moves once
`N_CONSEC` readings in a row were above. At the defaults that is a quarter of
an hour of sustained traffic. Alerts then fire only on a **state change**, and
recovery sends exactly one message.

## Rate, not total

Throughput comes from the byte counters, as the difference between two runs
divided by **the time that really elapsed** — not by the nominal interval. Cron
can be late, and a stretched interval would otherwise look like less traffic
than there was.

**The first run for a new entry records the counters and measures nothing** — a
rate needs two points.

## Counter resets are discarded, not reported

The kernel counters restart when the link goes down, when the driver reloads,
and on a 32-bit wrap. The delta is then negative, and the naive conversion
would produce a fabricated multi-gigabit burst — the most convincing kind of
false alarm, because the number looks real.

So: a negative delta means the sample is **dropped**, the baseline renewed and
the debounce counter left untouched. Nothing is written to the CSV, nothing is
alerted.

An interface that has disappeared entirely is a different matter and *is*
reported, once, as a change to the state `gone`. Silently dropping it out of
the run would hide exactly the problem worth knowing about.

## Files created

| Path | Contents |
|---|---|
| `net-monitor.conf` | the configuration, next to the script |
| `/etc/cron.d/net-monitor` | the cron entry |
| `var/net/ifaces.d/` | one file per interface |
| `var/net/state/` | `<name>.rx.state`, `<name>.tx.state`, `<name>.counters` |
| `var/net/results/<name>.csv` | samples: `timestamp,rx_mbit,tx_mbit,rx_pct,tx_pct` |
| `var/net/log/alerts.log` | one line per state change |
| `var/net/log/net.log` | one line per run |

`DATA_DIR` is freely selectable; a relative path is resolved against the
script's directory, never against the current one. Its own subtree `var/net/`
keeps entries with the same name from colliding with those of the other
monitors.

## State and data

State of its own is needed — there is no service behind this. Per entry and
direction: `STATE|timestamp|mbit|consec`, plus one counter file holding the
byte counters and the timestamp of the last run.

## Uninstall

Removes the cron entry and the configuration, and asks separately about the
data directory (interfaces, samples, state). A backup is written to
`/root/net-monitor-uninstall-<time>.tar.gz` first. No packages were installed,
so none are removed.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `baseline recorded`, no values | Intended on the first run for that entry; the next one measures |
| `counter reset - sample discarded` | The link went down or the counter wrapped. Correct behaviour, not an error |
| Interface shows `gone` | `IFACE` no longer exists — renamed (`ens18` vs `eth0`), or the tunnel is down |
| No alert although the line is full | The debounce gate, or the threshold for that direction is `0` (off) |
| No percentage in the alert | The interface reports no link speed — normal for tunnels and bridges |
| Rates look too low | The counters cover the whole interval, so a two-minute burst inside a five-minute window shows as its average |
