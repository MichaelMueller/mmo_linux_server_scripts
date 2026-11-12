# anomaly-monitor.sh — anomaly detection with Falco

Detects abnormal behaviour at runtime and mails it. The detection is
[Falco](https://falco.org) (CNCF): it watches the system calls of every process
through eBPF and matches them against a maintained rule set, for example:

- a shell started inside a container
- writes below `/etc` or into binary directories
- reading `/etc/shadow` or other sensitive files with an untrusted program
- privilege escalation, a new SUID file
- unexpected outbound connections

Falco runs with its **default rules** — there is nothing to configure. The rules
are updated automatically (`falcoctl`). This tool installs Falco, checks the
journal every 10 minutes and mails new events from priority **Warning** upward,
grouped by kind.

## Requirements

- Debian or Ubuntu on x86_64 or aarch64, root rights
- a kernel with BTF (`/sys/kernel/btf/vmlinux` — Debian 11+, Ubuntu 22.04+):
  the "modern eBPF" driver needs no kernel module and no headers
- not inside a container (LXC, OpenVZ, Docker): Falco needs the host kernel
- for the mail: a mailer (`mail-setup.sh`)

The setup checks all of this first and stops with a reason if something is
missing.

## Usage

```bash
sudo ./anomaly-monitor.sh              # menu
sudo ./anomaly-monitor.sh --setup      # install, asks only the mail recipient
sudo ./anomaly-monitor.sh --test       # trigger a harmless test event
sudo ./anomaly-monitor.sh --check      # mail new events now (what cron runs)
sudo ./anomaly-monitor.sh --status     # one line plus the last events
sudo ./anomaly-monitor.sh --uninstall  # cron, config; Falco itself on request
```

`--test` reads `/etc/shadow` with `cat` — Falco's rule "Read sensitive file
untrusted" reports that. The next check mails it.

## Settings

`anomaly-monitor.conf` next to the script:

| Key | Meaning | Default |
|---|---|---|
| `ALERT_MAIL` | recipient(s), comma-separated | empty (log only) |
| `MIN_PRIORITY` | Emergency / Alert / Critical / Error / Warning / Notice | Warning |
| `CHECK_INTERVAL_MIN` | minutes between checks | 10 |
| `IGNORE_RULES` | extended regex of event texts never mailed | empty |

## Presets and batch mode

A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default). A preset is a fixed value: the recipient question is
skipped - interactively and in batch mode - and the tool prints one line
instead, e.g. `Mail events to (comma-separated): it@example.com (preset)`. A
preset wins over the value stored in `anomaly-monitor.conf`. An invalid
priority, interval or ignore regex stops the setup before anything is
installed (message on stderr, exit code 1).

With `BATCH=1` (set by `base-setup.sh`) `--setup` asks nothing: without a
preset the recipient takes its default (stored or none) and the tool prints
what it took.

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_ALERT_MAIL` | recipient(s), comma-separated; `-` = none | empty (log only) |
| `DEFAULT_MIN_PRIORITY` | `Emergency`, `Alert`, `Critical`, `Error`, `Warning`, `Notice`, `Informational`, `Debug` | `Warning` |
| `DEFAULT_CHECK_INTERVAL_MIN` | `1`-`59` | `10` |
| `DEFAULT_IGNORE_RULES` | extended regex of event texts never mailed; `-` = none | empty |

The priority, the interval and the ignore list are not asked interactively
either; they come from the configuration file or from these presets.

## The mail

```
Subject: [anomaly] web01.example.com: 3 Falco event(s)

--- Grouped ---
      2 Warning Sensitive file opened for reading by non-trusted program
      1 Critical Terminal shell in container

--- Events ---
12:00:01.111: Warning Sensitive file opened for reading by non-trusted program (file=/etc/shadow ... command=cat /etc/shadow)
...
```

If Falco itself stops, the next check mails that too.

The events are read from the journal in each of Falco's output formats: the
default (`12:00:01.123: Warning ...`), ISO timestamps
(`time_format_iso_8601`) and JSON (`json_output`).

**What to do with an event:** check whether it was a known action (admin work,
a deployment, a backup job). If not, do not clean up on the machine — escalate
first. A known, recurring event goes into `IGNORE_RULES`, e.g.
`IGNORE_RULES='Read sensitive file.*backup\.sh'`.

## Files

| Path | Content |
|---|---|
| `/etc/apt/sources.list.d/falcosecurity.list`, `/usr/share/keyrings/falco-archive-keyring.gpg` | the Falco repository |
| `/etc/cron.d/anomaly-monitor` | the check every 10 minutes |
| `anomaly-monitor.conf` | settings |
| `var/anomaly-monitor/journal.cursor` | where the last check stopped in the journal |
| `var/anomaly-monitor.log` | every mailed event |

## Resources

Falco watches every system call, so it costs memory and CPU — more on hosts
with very many short-lived processes. On small machines check with `top` after
the setup.
