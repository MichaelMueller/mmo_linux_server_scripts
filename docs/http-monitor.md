# http-monitor.sh — HTTP status code, response time, certificate

Fetches URLs via cron, compares the HTTP status code against an expected value,
measures the response time and watches the remaining life of the TLS
certificate. Alerts on a state change.

## How this differs from tcp-monitor

`tcp-monitor` checks whether a port accepts the handshake — "is something
listening?". `http-monitor` checks whether the application behind it answers the
way it should. An nginx that accepts port 443 and returns 502 for every request
is healthy to `tcp-monitor` and down to `http-monitor`.

The price for that is two real dependencies: `curl` and `openssl`.
`tcp-monitor` deliberately does without both.

## Requirements

- `curl` (mandatory — without curl a run aborts with a message)
- `openssl` (only for the certificate monitoring; if it is missing, the column
  stays `?`)
- root only for the cron entry
- for mail alerts, a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./http-monitor.sh              # menu
sudo ./http-monitor.sh --check      # one run, the way cron does it
sudo ./http-monitor.sh --status     # target list on stdout
sudo ./http-monitor.sh --uninstall  # remove cron, configuration and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Manage targets (create, edit, delete) |
| 2 | Check all targets now — the same run as via cron, so it does carry state and samples forward and can trigger an alert |
| 3 | Results and statistics |
| 4 | Settings |
| 5 | Uninstall |
| 6 | Quit |

## Settings

| Setting | Meaning | Default |
|---|---|---|
| Data directory | where targets, samples and state live | `var/http/` next to the script |
| Check interval | minutes between two runs | 5 |
| Default timeout | seconds per request | 10 |
| Default status code | the default when creating a target | 200 |
| Time threshold | from when a target counts as `SLOW`, 0 = off | 2000 ms |
| TLS warning from | remaining days at which to warn, 0 = off | 14 |
| Retention | days the samples are kept | 30 |
| Webhook | URL that receives a JSON on a state change | empty |
| Mail | address for alerts | empty |

Stored in `http-monitor.conf` next to the script.

The data directory deliberately sits under `var/http/` rather than directly in
`var/`: `tcp-monitor` and `disk-monitor` already share `var/`, and a target
carrying the same name in two modules would otherwise overwrite itself in
`targets.d/` and `state/`.

## Targets

A target is a file in `var/http/targets.d/<name>.conf`:

```sh
NAME="webshop"
URL="https://shop.example.com/health"
EXPECT="200"
METHOD="GET"
TIMEOUT="10"
MAX_MS="2000"
FOLLOW="0"
INSECURE="0"
ENABLED="1"
NOTE="behind the tunnel"
```

| Field | Meaning |
|---|---|
| `EXPECT` | the expected status code. Anything else is `DOWN` — including a 200 when 301 was expected |
| `METHOD` | `GET` (default) or `HEAD`. GET measures what a visitor experiences; the body is discarded, it only costs bandwidth. `HEAD` returns 405 or 501 on some app servers and WAFs |
| `MAX_MS` | threshold for `SLOW`. `0` switches the timing off — the target then behaves like one in `tcp-monitor` |
| `FOLLOW` | `0` = do **not** follow redirects, the expected code applies to the first response. Only that way can a 301 be monitored as the desired state in its own right. `1` = follow, and then the code of the last response counts |
| `INSECURE` | `1` switches curl's certificate verification off (self-signed). The remaining life is still monitored — what is switched off is the *verification*, not the *observation* |

`ENABLED="0"` switches a target off temporarily without deleting it. When a
target is created, a test run happens right away — but it deliberately does
**not** carry the state forward, so that a target broken from the start still
reports on the first cron run.

When deleting, you are asked separately whether the sample history should go as
well.

## Overview

```
NAME           URL                                ACTIVE STATUS CODE  TIME    CERT   LAST CHECK
-------------- ---------------------------------- ------ ------ ----- ------- ------ -------------------
webshop        https://shop.example.com/health    yes    UP     200   142ms   87d    2026-08-01 12:00:00
olddomain      http://alt.example.com             yes    UP     301   22ms    -      2026-08-01 12:00:01
api            https://api.example.com/health     yes    SLOW   200   2841ms  12d!   2026-08-01 12:00:03
dead           https://gone.example.com           yes    DOWN   000   3ms     ?      2026-08-01 12:00:13
```

The `CERT` column holds the remaining life, `!` on a warning or an expiry, `?`
when the certificate could not be fetched, `-` for `http://`.

## The state model

Two axes that alert separately.

**Reachability** — three-valued, ordered:

| Status | Condition |
|---|---|
| `UP` | a response, the code as expected, within the time threshold |
| `SLOW` | the code as expected, but slower than `MAX_MS` |
| `DOWN` | a curl error (timeout, DNS, connection, TLS) **or** the wrong code |

`SLOW` is a state of its own, not a subcase of `UP`. Anyone who first degrades
and then fails sees `UP → SLOW → DOWN` as three separate messages instead of one
late one.

**Certificate** — tracked separately:

| Status | Condition |
|---|---|
| `ok` | remaining life above the threshold |
| `warn` | remaining life below the threshold, still valid |
| `expired` | past the expiry date |
| `unknown` | https, but not retrievable |
| `-` | no https, or monitoring switched off with `CERT_WARN_DAYS=0` |

Separately, because a certificate about to expire is **not an outage**: the site
keeps returning its code. Putting it on `DOWN` for that would be wrong, and a
target sitting in `WARN` for weeks would swallow a real outage during that time.

`unknown` **never** triggers an alert, neither into it nor out of it. Otherwise
every outage would additionally report the certificate, because the handshake
failed along with it.

## Alerting

Only the **state change** is reported:

| Transition | Reported |
|---|---|
| UP → SLOW → DOWN | yes, each step separately |
| DOWN → DOWN | no, no kicking a service while it is down |
| DOWN → UP | yes, the all-clear |
| new → UP | no (a first reading in the normal state is not an incident) |
| new → SLOW/DOWN | yes |
| Certificate ok → warn → expired | yes, once each |
| Certificate warn → ok | yes, the all-clear with the new remaining life |

A shorter interval therefore costs **no** additional mail — it only shortens the
detection time.

All changes of one run go into **one** mail. If the uplink goes down, otherwise
one mail per target is on its way instead of one in total.

Every change additionally goes to `var/http/log/alerts.log`.

## Files

```
http-monitor.conf              configuration
var/http/targets.d/*.conf      the targets
var/http/results/<name>.csv    timestamp,status,http_code,latency_ms,cert_days
var/http/state/<name>.state    status|time|code|ms|cert band|expiry|checked
var/http/log/alerts.log        state changes
var/http/.lock                 lock against overlapping runs
/etc/cron.d/http-monitor       schedule
```

Separating target and state is deliberate: the CRUD only writes `targets.d`, the
runner only `state` and `results`. A deleted target leaves no orphan behind in
the state.

## Checking the certificate

Through `openssl s_client`, not through curl: `--certinfo` is not present in
every curl build, and the expiry date is needed precisely when the chain does
*not* validate — with a self-signed certificate curl aborts beforehand,
`s_client` delivers it anyway.

The expiry date is only fetched again every 12 hours and stored in the state
file as unix time. A TLS handshake every five minutes would be pure load, and
the date only changes on a renewal. The **remaining days** are still
recalculated on every run, so the warning threshold fires on the right day.

If the query fails, the last known date stays: an outage must not reset the
expiry monitoring.

## Statistics (menu item 3)

For one target: number of samples, the split across UP/SLOW/DOWN, availability
as a percentage (UP and SLOW count as reachable), mean and maximum response
time, the distribution of the status codes and the last 20 samples. Without a
name: the last 30 state changes.

Samples older than `RETENTION_DAYS` are trimmed on every run.

## Cron

```
# /etc/cron.d/http-monitor
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /path/to/http-monitor.sh --check >/dev/null 2>&1
```

The path is the one that was valid at setup time. After moving the script, run
menu item 4 once.

The exit code of `--check` is 1 for as long as a target is not `UP` or a
certificate has changed its band.

In the worst case a run takes *targets × timeout* seconds, because every timeout
is sat out one after another. So that runs do not overtake each other, `--check`
holds a lock on `var/http/.lock`; a run that meets one still in progress skips
itself. If `flock` is missing on the system, work goes on without a lock —
better a possible overlap than no run at all.

## State and data

**Its own state, unavoidably:** there is no service that could hold the targets
and the sample history. Everything lives under `DATA_DIR` — by default
`var/http/` next to the script, but freely selectable at setup time,
`/var/lib/mmo-http` for instance. On the system itself only the cron entry is
created.

The cron entry remembers the path that was valid at setup time. If you move the
script or `DATA_DIR`, go through the settings once.

## Uninstall

Removes the cron entry and the configuration, asks separately about the data
directory. Backup beforehand to `/root/http-monitor-uninstall-<time>.tar.gz`. No
packages were installed, nothing is left behind.

Because `DATA_DIR` points at `var/http/`, the deletion only hits this tool's own
data — `tcp-monitor` and `disk-monitor` in `var/` stay untouched.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Not set up" on `--check` | `http-monitor.conf` is missing — go through the menu once |
| "curl is not installed" | `apt install curl`; without curl no check runs |
| A target reports DOWN with code 000 | no response at all — DNS, firewall or timeout, the reason is in the alert log |
| A target reports DOWN with code 301 | a redirect, but `FOLLOW="0"` — either set `EXPECT="301"` or `FOLLOW="1"` |
| A target reports DOWN with 405 or 501 | `METHOD="HEAD"` against a server that only answers GET |
| Everything is constantly SLOW | `MAX_MS` is too tight; `0` switches the timing off |
| The certificate column shows `?` | `openssl` is missing, or the handshake fails (port, SNI, firewall) |
| No mail | No recipient set, or `mail` is missing; `var/http/log/alerts.log` shows the change anyway |
| Runs are skipped | A run takes longer than the interval — lower the timeout or raise the interval |
| Status stays on `-` | There has been no run for that target yet; trigger menu item 2 |
| Cron does not run | The path in the cron entry points somewhere else |
