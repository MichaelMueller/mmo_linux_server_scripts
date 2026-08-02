# tcp-monitor.sh — TCP reachability

Checks via cron whether services answer on their TCP port, keeps a sample
history and alerts on a state change.

## Requirements

- bash (the connection test goes through `/dev/tcp`, no external tools)
- root only for the cron entry
- for mail alerts, a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./tcp-monitor.sh              # menu
sudo ./tcp-monitor.sh --check      # one run, the way cron does it
sudo ./tcp-monitor.sh --status     # target list on stdout
sudo ./tcp-monitor.sh --uninstall  # remove cron, configuration and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Manage targets (create, edit, delete) |
| 2 | Check all targets now (with latencies) — the same run as via cron, so it does carry state and samples forward and can trigger an alert |
| 3 | Results and statistics |
| 4 | Settings |
| 5 | Uninstall |
| 6 | Quit |

## Settings

| Setting | Meaning | Default |
|---|---|---|
| Data directory | where targets, samples and state live | `var/` next to the script |
| Check interval | minutes between two runs | 5 |
| Default timeout | seconds per connection attempt | 5 |
| Retention | days the samples are kept | 30 |
| Webhook | URL that receives a JSON on a state change | empty |
| Mail | address for alerts | empty |

Stored in `tcp-monitor.conf` next to the script.

## Targets

A target is a file in `var/targets.d/<name>.conf`:

```sh
NAME="nextcloud"
HOST="10.10.0.2"
PORT="8080"
TIMEOUT="5"
ENABLED="1"
NOTE="behind the tunnel"
```

`ENABLED="0"` switches a target off temporarily without deleting it. When a
target is created, a test run happens right away, so you do not have to wait for
the next cron pass.

When deleting, you are asked separately whether the sample history should go as
well.

## Overview

```
NAME                 TARGET                       ACTIVE STATUS   LAST CHECK
nextcloud            10.10.0.2:8080               yes    UP       2026-08-01 09:15:02
mailserver           mx.example.com:25            yes    DOWN     2026-08-01 09:15:07
```

## Alerting

Only the **state change** is reported:

| Transition | Reported |
|---|---|
| UP → DOWN | yes |
| DOWN → DOWN | no, no kicking a service while it is down |
| DOWN → UP | yes, the all-clear |
| new → UP | no (a first reading in the normal state is not an incident) |
| new → DOWN | yes |

A shorter interval therefore costs **no** additional mail — it only shortens the
detection time. `*/5` instead of `*/60` means: an outage noticed after at most 5
instead of 60 minutes, for the same amount of mail.

Every change additionally goes to `var/log/alerts.log`.

## Files

```
tcp-monitor.conf          configuration
var/targets.d/*.conf      the targets
var/results/<name>.csv    timestamp,status,latency_ms
var/state/<name>.state    status|time|latency — written by the runner only
var/log/alerts.log        state changes
/etc/cron.d/tcp-monitor   schedule
```

Separating target and state is deliberate: the CRUD only writes `targets.d`, the
runner only `state` and `results`. A deleted target leaves no orphan behind in
the state.

## Statistics (menu item 3)

For one target: number of samples, availability as a percentage, mean and
maximum latency of the UP samples, plus the last 20 samples. Without a name: the
last 30 state changes.

Samples older than `RETENTION_DAYS` are trimmed on every run.

## Connection test

Through bash `/dev/tcp/<host>/<port>` with `timeout`. That needs no `nc`, no
`curl` and no elevated rights. What is measured is the time until the TCP
handshake is up — it says nothing about whether the service behind it is
healthy in a functional sense.

## Cron

```
# /etc/cron.d/tcp-monitor
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /path/to/tcp-monitor.sh --check >/dev/null 2>&1
```

The path is the one that was valid at setup time. After moving the script, run
menu item 4 once.

The exit code of `--check` is 1 for as long as any target is DOWN.

## State and data

**Its own state, unavoidably:** there is no service that could hold the targets
and the sample history. Everything lives under `DATA_DIR` — by default `var/`
next to the script, but freely selectable at setup time, `/var/lib/mmo` for
instance. On the system itself only the cron entry is created.

Inside `DATA_DIR` the separation is strict: `targets.d/` is written only by the
CRUD, `state/` and `results/` only by the runner. A deleted target therefore
leaves no orphan behind in the state.

The cron entry remembers the path that was valid at setup time. If you move the
script or `DATA_DIR`, go through the settings once.

## Uninstall

Removes the cron entry and the configuration, asks separately about the data
directory. Backup beforehand to `/root/tcp-monitor-uninstall-<time>.tar.gz`. No
packages were installed, nothing is left behind.

If the script runs without root, it cannot remove the cron file and names the
command instead.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Not set up" on `--check` | `tcp-monitor.conf` is missing — go through the menu once |
| A target reports DOWN but is reachable | The timeout is too tight, or the firewall drops packets coming from the server |
| No mail | No recipient set, or `mail` is missing; `var/log/alerts.log` shows the change anyway |
| Statistics empty | There are no samples yet — first a run, then a statistic |
| Status stays on `-` | There has been no run for that target yet; trigger menu item 2 |
| Cron does not run | The path in the cron entry points somewhere else |
