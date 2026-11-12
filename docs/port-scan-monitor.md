# port-scan-monitor.sh — external port scan

Scans the servers **from outside** with nmap. It compares the open ports with
the expected ones and sends a mail when the result changes:

- **unexpected open:** something listens publicly that should not. Typical
  causes are a firewall gap, a Docker port mapping (`-p` bypasses ufw) or a
  forgotten service.
- **expected closed:** an application port is not reachable. Either the
  service is down or the firewall is too strict.

## Where it runs

On **one separate scanner host**, not on the servers it checks. A server that
scans its own public IP goes over loopback and sees past its own firewall, so
the result means nothing. Ideally the scanner sits in a different network
(another provider or location), so it sees what the internet sees.

Scanning your own servers is fine. Some providers flag outgoing port scans
from their VMs, though. With a few targets once a day this rarely matters; if
it does, tell the provider about the scanner or use `TCP_SCOPE="top1000"`.

## Usage

```bash
sudo ./port-scan-monitor.sh                                   # menu
sudo ./port-scan-monitor.sh --setup                           # settings
sudo ./port-scan-monitor.sh --add web01 203.0.113.10 80,443   # add a target
sudo ./port-scan-monitor.sh --add vpn01 203.0.113.11 - 51820  # UDP only
sudo ./port-scan-monitor.sh --list                            # targets + last result
sudo ./port-scan-monitor.sh --check                           # scan all now (also cron)
sudo ./port-scan-monitor.sh --check web01                     # scan one
sudo ./port-scan-monitor.sh --remove web01
sudo ./port-scan-monitor.sh --uninstall
```

**Expected ports** are comma-separated; `-` means none, and ranges
(`8000:8010`) are allowed. The default is TCP `80,443` and no UDP. A server
with both IPv4 and IPv6 is added twice under the same name. The firewall has to
hold on both addresses.

`base-setup.sh` prints the ready-made `--add` command for each server at
the end of the firewall step, and puts it into the documentation entry. The
expected ports are taken from the public ufw rules (rules on `tailscale0` or
limited to a source IP are left out).

## Settings

Stored in `port-scan-monitor.conf`; the targets are in `var/port-scan/targets.txt`.

| Setting | Default | Meaning |
|---|---|---|
| `SCHEDULE` | `daily` | `daily`, `hourly` or `off` |
| `SCAN_TIME` | `04:30` | After the update (02:00) and reboot (03:00) windows, so a reboot does not show up as "expected closed" |
| `TCP_SCOPE` | `all` | `all` scans ports 1–65535; `top1000` is much faster |
| `UDP_SCAN` | `1` | Also scans the 50 most common UDP ports |
| `NMAP_OPTS` | `-T4 --max-retries 2` | Further nmap options |
| `ALERT_MAIL` | empty | Recipient(s), comma-separated |
| `REMIND_DAYS` | `7` | Repeats an unresolved alert after N days; `0` = never |

## Alerts

- **A mail goes out only when the result changes:** a new port, a port gone,
  or back to OK. It does not repeat on every scan; an unresolved problem is
  reminded after `REMIND_DAYS`.
- **The first scan of a target** only sends a mail when the result is not OK.
- **Only ports that answer count as open.** `open|filtered` (typical for UDP
  behind a firewall) is not counted as open.
- **An unreachable or unresolvable address** is reported as `SCAN FAILED`.

## Cron

```
30 4 * * * root flock -n /run/port-scan-monitor.lock /path/to/port-scan-monitor.sh --check >/dev/null 2>&1
```
