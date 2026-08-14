# clamav-scanner.sh — virus scan (ClamAV)

Installs ClamAV, keeps the signatures current through the `clamav-freshclam`
service, runs a daily `clamscan` over the configured paths via cron, and alerts
by mail or webhook when something is found. Findings are **reported, never
deleted or moved automatically** — a virus scanner that quarantines on its own
can take an application down; a human assesses the report first.

## Requirements

- Ubuntu with apt, root rights; the packages `clamav` and `clamav-freshclam`
  are installed on first use (the initial signature download is ~300 MB)
- for mail alerts, a mailer that is set up (the `mail` command — see
  [mail-setup.md](mail-setup.md) or [graph-mailer.md](graph-mailer.md))

## Usage

```bash
sudo ./clamav-scanner.sh              # menu
sudo ./clamav-scanner.sh --check      # one scan run, the way cron does it
sudo ./clamav-scanner.sh --update     # update the signatures now
sudo ./clamav-scanner.sh --status     # signatures and last result on stdout
sudo ./clamav-scanner.sh --uninstall  # remove cron, configuration and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Set up / edit settings |
| 2 | Update the signatures now |
| 3 | Scan now |
| 4 | Show the last report |
| 5 | Uninstall |
| 6 | Quit |

## How it works

- **Signatures** — the `clamav-freshclam` service updates them on its own.
  A manual update (`--update`, menu item 2) stops the service first, runs
  `freshclam`, and starts it again; otherwise freshclam only reports that the
  log is locked by another process.
- **Scan** — `clamscan --recursive` over the configured paths, with
  `nice -n 19 ionice -c3`: the services on the machine matter more than the
  scan finishing fast. Default paths are the places where foreign files
  usually arrive (`/home /root /srv /opt /var/www /tmp`); `/` works but takes
  hours. Exit code 0 = clean, 1 = findings, anything else = error.
- **Reports** — one file per run under `var/clamav/reports/`, the newest
  `KEEP_REPORTS` (default 30) are kept. The alert mail contains the first 50
  findings and the path to the full report.
- **Alerting** — by default only on findings or errors; switchable to a mail
  after every scan. Same channel as the monitors: the `mail` command, plus an
  optional webhook.

## Uninstall

Removes the cron entry and the configuration; the report directory and the
clamav packages (~1 GB with signatures) are each removed only after a separate
question. A backup goes to `/root/clamav-scanner-uninstall-<timestamp>.tar.gz`
first.
