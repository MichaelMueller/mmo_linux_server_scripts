# auto-update.sh — automatic apt updates

Applies apt updates via cron and mails when something needs attention. It
knows two kinds of updates:

| | Safe updates | Other updates |
|---|---|---|
| What | fixes that change nothing in behaviour: the security updates of the distribution, and of the known third-party repositories the versions their projects keep compatible | everything else — new versions that can change behaviour (`dist-upgrade`) |
| How | unattended; third-party versions are checked afterwards and rolled back when the check fails | by hand (default), or weekly/daily in the night window |
| When (default) | quick ones hourly, noticeable ones (Docker, Tailscale) in the night window | by hand — the overview and a mail say when some wait longer than 14 days |

A reboot that becomes necessary (new kernel) happens **in the night window,
after the updates** (default 03:00) — only when one is needed — or never (only
reported). Ubuntu leaves `/var/run/reboot-required` behind; Debian does not —
there `needrestart` reports an outdated running kernel. needrestart is
installed by the setup and restarts the services affected by an update.

Four things describe every update; three of them the script decides, one is
yours:

| Property | Decided by | Effect |
|---|---|---|
| Breaks nothing? | script, per source | safe: unattended; other: by hand or on a schedule |
| Quick? | script, per software | quick: may run hourly; noticeable: only in the night window |
| Needs a reboot? | script | never right away — in the night window, after the updates |
| Schedule | you | the four questions of the setup |

## What counts as safe

**The distribution:** only its security sources (`-security`, Ubuntu ESM),
installed by `unattended-upgrades`. Debian stable backports the fix into the
installed version — no new features, no changed behaviour.

**Third-party repositories** have no security channel; they ship new versions,
fixes and features mixed. A version counts as safe when it stays within the
range the project keeps compatible:

| Software | Repository | Safe range | Quick? | Why |
|---|---|---|---|---|
| Docker (+ containerd, plugins) | `download.docker.com` | same major (`28.x`; 0.x: same minor) | noticeable | SemVer since 23: breaking changes only in major versions, fixes only for the newest line. A minor update restarts the containers (live-restore covers patch versions only), and containers can take a while |
| Tailscale | `pkgs.tailscale.com` | every new version | noticeable | one compatible line, but the restart cuts every tailnet connection — the admin's SSH session included |
| Caddy | `dl.cloudsmith.io/public/caddy` | same minor (`2.9.x`) | quick | 2.x for years; minor versions now and then change config or behaviour. Back in about a second |
| Falco | `download.falco.org` | same minor | quick | minor versions can bring new rules, i.e. new alerts |
| nginx | `nginx.org/packages` | same minor (stable branch `1.26.x`) | quick | binary swap without dropping connections |
| Apache | `packages.sury.org/apache2` | same minor (`2.4.x`) | quick | graceful restart |
| Trivy | `aquasecurity.github.io/trivy-repo` | same minor (0.x) | quick | the scanner of image-check.sh |

The versions are chosen explicitly — per package the highest version within
its range (`apt-cache madison`) — there are no apt pins; the other updates
(`dist-upgrade`) take everything as before.

nginx and Apache from the distribution itself come with the security updates;
after such an update their configuration test and service are checked too
(there is no older fixed version to go back to — a failed check only mails).

**Any other repository** (a PPA, a vendor repository no heuristic knows): its
packages are "other updates" only, and `--pending` and `base-setup.sh --check`
name it ("not covered by the safe updates: packages from ...").

### Check after every third-party update, with rollback

1. Before: the installed versions and the running services are noted.
2. After: the services that ran before run again, and
   - Caddy: `caddy validate` with `/etc/caddy/Caddyfile`;
   - nginx: `nginx -t`; Apache: `apachectl configtest`;
   - Tailscale: connected again (when it was before);
   - Docker: the containers that ran before run again, those healthy before
     are healthy again — it waits up to 10 minutes.
3. If not: the previous versions are installed again (the repositories keep
   old versions), **held** (`apt-mark hold`), the run reports an error and
   mails. Held packages get no automatic updates until the cause is fixed and
   they are released: `apt-mark unhold <package>`. The overview shows them.

## Requirements

- Debian or Ubuntu (apt), root rights
- for mails: a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./auto-update.sh                 # menu
sudo ./auto-update.sh --setup         # guided setup: four questions
sudo ./auto-update.sh --pending       # what is waiting, and of which kind
sudo ./auto-update.sh --run safe      # all safe updates now
sudo ./auto-update.sh --run all       # the other updates now (dist-upgrade)
sudo ./auto-update.sh --upgrade-now   # full upgrade right now: list, ask, install
sudo ./auto-update.sh --status        # one line: the settings
sudo ./auto-update.sh --overview      # key=value lines for base-setup.sh --check
sudo ./auto-update.sh --uninstall     # remove cron and the configuration
```

`--run security` (hourly) and `--run night` (night window) are what cron
calls. `--upgrade-now` is the interactive full upgrade for a fresh server or
for "other updates by hand". It works without a setup. Exit codes: 0 done or
nothing to do, 2 declined, 3 a reboot is required, 1 failed.

## The setup: four questions

```
--- Safe updates ---
Fixes that change nothing in behaviour: the security updates of the
distribution, and of Docker, Caddy the versions their projects keep
compatible (checked afterwards, rolled back when the check fails).
  1) hourly    quick ones every hour; Docker and Tailscale, which restart
               containers or cut the tailnet, in the night window  (recommended)
  2) nightly   all in the night window
  3) off
Choice [1]:

--- Other updates ---
New versions that can change behaviour: Debian point releases, the next
major version of Docker, ... The overview and a mail say when some are
waiting longer than 14 days.
  1) by hand                                                  (recommended)
  2) weekly    Sunday, in the night window
  3) daily     in the night window
Choice [1]:

--- Reboot ---
When an update needs a reboot (new kernel):
  1) at night  in the night window, after the updates          (recommended)
  2) never     only reported (mail) - stays on the old kernel until someone acts
Choice [1]:

--- Night window ---
Night window (HH:MM) [03:00]:
```

Plus the mail recipient, when none is set. Not asked: restarting the affected
services (always on), the mail switches (errors, rollbacks and waiting other
updates), the exclusions — those are in the menu (2, 3) or presets.

## Presets and batch mode

A `DEFAULT_<KEY>` that is set is taken without a question; unset ones are
asked (batch mode: default). Such a preset is a fixed value: its question is
skipped — interactively and in batch mode — and the tool prints one line
instead, e.g. `Choice: interval (preset)`. A preset wins over the value stored
in `auto-update.conf`. Every preset is checked before the first question; an
invalid one stops the setup with a message on stderr and exit code 1, nothing
is written.

With `BATCH=1` (set by `base-setup.sh --yes`), `--setup` and `--upgrade-now`
ask nothing: every question without a preset takes its default — the stored
value, else the built-in one.

```bash
BATCH=1 DEFAULT_MAIL_TO=it@example.com DEFAULT_FULL_SCHEDULE=weekly ./auto-update.sh --setup
```

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_SEC_SCHEDULE` | safe updates: `interval` (hourly), `daily` (night window), `off` | `interval` |
| `DEFAULT_SEC_INTERVAL_MIN` | `10`, `15`, `20`, `30`, `60` | `60` |
| `DEFAULT_FULL_SCHEDULE` | other updates: `off` (by hand), `weekly`, `daily` | `off` |
| `DEFAULT_FULL_WEEKDAY` | `0`-`6`, 0 = Sunday | `0` |
| `DEFAULT_SEC_REBOOT` | `window`, `never` (`now`: right after the run) | `window` |
| `DEFAULT_FULL_REBOOT` | the same after other updates | as `SEC_REBOOT` |
| `DEFAULT_REBOOT_TIME` | the night window, `HH:MM` | `03:00` |
| `DEFAULT_SEC_RESTART`, `DEFAULT_FULL_RESTART` | `0`, `1` | `1` |
| `DEFAULT_MAIL_TO` | address(es), comma-separated; `-` = no mail | empty |
| `DEFAULT_MAIL_ON_ERROR` | `0`, `1` — errors and rollbacks | `1` |
| `DEFAULT_MAIL_ON_INSTALL` | `0`, `1` | `0` |
| `DEFAULT_MAIL_ON_NOOP` | `0`, `1` | `0` |
| `DEFAULT_ADVANCED` | `Y`, `N` - ask the advanced questions in the setup | `N` |
| `DEFAULT_EXCLUDE_PKGS` | package names/globs; `-` = none | empty |
| `DEFAULT_AUTOREMOVE` | `0`, `1` | `1` |
| `DEFAULT_RESTORE_CONTAINERS` | `0`, `1` | `1` |
| `DEFAULT_POST_UPDATE_REDEPLOY` | `0`, `1` (only where git-updater is set up) | `0` |
| `DEFAULT_LOG_FILE` | path | `var/auto-update.log` |
| `DEFAULT_UPGRADE_NOW` | `Y`, `N` - `--upgrade-now` installs | `Y` |

Still read from older configurations, no longer used — everything runs in
the night window: `SEC_TIME`, `SEC_WEEKDAY` (`SEC_SCHEDULE=weekly` runs the
security updates in the night window on that weekday), `FULL_TIME`.

## Menu

```
Safe updates:   unattended - quick ones every 60 min, Docker/Tailscale at 03:00
Other updates:  by hand
Reboot:         at 03:00, when needed
Mail:           it@example.com (on: errors and rollbacks; other updates waiting > 14 days)
Excluded:       (nothing)

1) Settings                   (safe, other updates, reboot, night window)
2) Mail report
3) Advanced                   (exclusions, autoremove, restarts, containers)
4) Install updates now ...    (safe / other / interactive full upgrade / pending)
5) Show pending updates
6) Show the log
7) Uninstall
q) Quit
```

Every change in 1–3 is saved and put into effect (cron) at once.

## Settings

| Key | Meaning | Default |
|---|---|---|
| `SEC_SCHEDULE` | safe updates: interval (hourly) / daily (night window) / off | interval |
| `SEC_INTERVAL_MIN` | minutes for "interval" | 60 |
| `SEC_RESTART` | restart affected services | 1 |
| `SEC_REBOOT` | window / never / now | window |
| `FULL_SCHEDULE` | other updates: off (by hand) / weekly / daily | off |
| `FULL_WEEKDAY` | for weekly | Sunday |
| `FULL_RESTART`, `FULL_REBOOT` | as above, for the other updates | 1, window |
| `REBOOT_TIME` | the night window | 03:00 |
| `EXCLUDE_PKGS` | names or globs never updated automatically | empty |
| `AUTOREMOVE` | apt autoremove after an installation | 1 |
| `RESTORE_CONTAINERS` | start containers again that ran before an update or a reboot by this tool | 1 |
| `POST_UPDATE_REDEPLOY` | after an installation: `git-updater.sh --redeploy` (only asked where git-updater is set up) | 0 |
| `MAIL_TO` | recipient(s), comma-separated; empty = no mail | empty |
| `MAIL_ON_ERROR` / `MAIL_ON_INSTALL` / `MAIL_ON_NOOP` | when to mail | 1 / 0 / 0 |

Stored in `auto-update.conf` next to the script.

The runs never overlap: they share one lock. An hourly run skips its turn
while another run is busy; the night run waits up to 30 minutes for a busy
hourly run.

**Mail on errors only is the default** (plus rollbacks, plus "other updates
waiting longer than 14 days" at most once a week). A successful update is the
expected outcome, and a "3 packages updated" mail is the kind of message that
gets filtered into a folder nobody reads — which is where the error mails
would then land too. What happened is in the log either way
(`var/auto-update.log`).

> **Older configurations are translated when they are loaded**, so nothing has
> to be set up again: 2.2 and earlier (`RESTART_SERVICES`, `AUTO_REBOOT`,
> `NIGHTLY_REBOOT`), a single schedule before 2.3 (`SCHEDULE` + `MODE`), the
> former `MAIL_WHEN`. Cron files without the night run are rewritten on the
> next run.

## Excluding packages

`EXCLUDE_PKGS` is a space-separated list of package names or shell globs, so
`docker*` covers the whole family:

```
EXCLUDE_PKGS="docker-ce docker-ce-cli containerd.io"
```

An excluded package is never updated automatically — not as a safe update,
not as an other update. The levers:

- **Distribution security updates:** the patterns go to unattended-upgrades as
  its `Package-Blacklist` (converted to regular expressions: `docker*` becomes
  `^docker.*$`), written into `/etc/apt/apt.conf.d/52auto-update`.
- **Third-party safe updates:** excluded packages are not picked.
- **Other updates:** `dist-upgrade` takes no package list — there the only
  reliable lever is `apt-mark hold`. The excluded packages are held before the
  run and released afterwards. Only holds set by this tool are released, and
  the release is armed as a trap before the first hold is set, so a failed
  run, a `Ctrl-C` or a kill cannot leave the system pinned.

What was skipped is named in the report and in `--pending`.

> An excluded package gets **no security updates either**. Check now and then
> by hand: `sudo ./auto-update.sh --pending`.

## Redeploy after an installation

With `POST_UPDATE_REDEPLOY=1`, a run that actually installed something calls
`git-updater.sh --redeploy` afterwards and puts its output into the report
under `--- Redeploy ---`. That brings the Docker Compose stacks back up
(`compose up -d`) after a package update restarted the container engine
underneath them. No git operation is involved. The question is only asked when
`git-updater.sh` sits next to this script.

## Cron

```
# /etc/cron.d/auto-update
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# safe updates, quick ones: every 60 min       (only with "hourly")
30 * * * * root flock -n /run/auto-update.lock /path/to/auto-update.sh --run security >/dev/null 2>&1
# night window 03:00: safe updates, other updates when due, reboot when needed
0 3 * * * root flock -w 1800 /run/auto-update.lock /path/to/auto-update.sh --run night >/dev/null 2>&1
# after a boot: containers that ran before a reboot by this tool, reboot marker
@reboot root /path/to/auto-update.sh --at-boot >/dev/null 2>&1
```

`/etc/cron.d` instead of the user crontab: an explicit user field (the job runs
as root), one file per job, and a settable `PATH`. Installed from a bundle, the
path is `/opt/server_admin_scripts/current/...` — an update or a rollback of
the tools switches the jobs along.

## What a run does

**Hourly run** (`--run security`, only with "hourly"):

1. `apt-get update`, classify what is pending
2. the distribution's security updates (unattended-upgrades), then needrestart
3. the quick third-party safe updates (Caddy, Falco, nginx.org, Apache, Trivy),
   each checked, rolled back on failure
4. a reboot needed? — marked for the night window

**Night run** (`--run night`):

1. `apt-get update`, classify what is pending
2. with "nightly": the distribution's security updates
3. all third-party safe updates, Docker and Tailscale included — checked,
   rolled back on failure
4. other updates, when they are due (daily, or weekly on that weekday):
   `apt-get dist-upgrade`, exclusions held
5. autoremove, redeploy (if switched on), containers started again
6. a reboot needed now, or marked by an earlier run? — reboot (`shutdown -r +1`)
7. other updates waiting longer than 14 days? — a reminder mail (at most weekly)

Every run writes its report to the log and mails it on an error or a rollback.

### How the distribution's security updates are recognised

By `unattended-upgrades`, the Debian/Ubuntu standard. It checks the origin of
every version and, when the newest candidate comes from elsewhere (a point
release, `-updates`), installs the newest version from a security source
instead. auto-update limits it to the security sources:

```
origin=Debian,codename=${distro_codename}-security,label=Debian-Security
origin=Debian,codename=${distro_codename},label=Debian-Security
origin=Ubuntu,archive=${distro_codename}-security
origin=UbuntuESM / UbuntuESMApps (Ubuntu Pro, where enabled)
```

Its own daily timer is switched off (`APT::Periodic::Unattended-Upgrade "0"`),
as are its reboot and its mails. Packages whose update would ask about a
changed configuration file are skipped by unattended-upgrades and named in the
report.

While unattended-upgrade runs, needrestart only lists (`NEEDRESTART_MODE=l`);
the restarts follow when it is done. Otherwise needrestart's apt hook would
restart `unattended-upgrades.service` in the middle of the run — whose stop
waits for that very run to end, and both wait for ever.

### Why without `set -e`

The runner collects errors and reports them at the end instead of aborting in
the middle and swallowing the report. The exit status is still ≠ 0 when
something went wrong, and the subject then starts with `[ERROR]`.

### dpkg conflicts

Updates run with `-o Dpkg::Options::=--force-confdef -o
Dpkg::Options::=--force-confold`: a configuration file changed by hand stays as
it is, an unattended run never gets stuck on a question. The package's new
version sits next to it as `.dpkg-dist`.

## What the overview shows

`base-setup.sh --check`, block 4 (from `--overview`):

```
  [x] Safe updates     required     unattended - quick ones every 60 min, Docker/Tailscale at 03:00
  [!] Other updates    recommended  by hand - 7 waiting, oldest 21 days (Docker 29.0.1, Caddy 2.10.0, 5 distribution package(s))
  [!] Other sources    recommended  not covered by the safe updates: repo.example.com
  [x] Reboot           recommended  not needed
```

`[!]` at "Other updates" once the oldest waits longer than 14 days; at "Safe
updates" when packages are held after a failed check.

## Files created

| Path | Contents |
|---|---|
| `auto-update.conf` | configuration (next to the script) |
| `/etc/apt/apt.conf.d/52auto-update` | settings for unattended-upgrades (security sources, no own timer, no reboot, no mail, exclusions) |
| `/etc/cron.d/auto-update` | schedule |
| `var/auto-update.log` | log of all runs (last 2000 lines) |
| `var/auto-update.pending` | since when each pending update waits |
| `var/auto-update.held` | packages held after a failed check |
| `var/auto-update.reminded` | the last "other updates waiting" mail |

## Uninstall

Removes the cron entry, the configuration, `52auto-update` (the daily timer of
unattended-upgrades then applies again) and the state files, asks separately
about the log. Packages held after a failed check are named — they stay held
until released by hand. Beforehand a backup is written to
`/root/auto-update-uninstall-<time>.tar.gz`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Cron does not run | The path in the cron entry is no longer right — run the setup again |
| An update stays pending although safe updates are on | It is an "other update" (point release, `-updates`, a version outside the safe range, an unknown repository) — `--pending` says which |
| A package is held | A check failed after its update and it was rolled back — the report says why. Fix the cause, then `apt-mark unhold <package>` |
| A security update is "kept back" | Its update would ask about a changed configuration file — install it by hand (`apt-get install --only-upgrade <pkg>`) |
| No mail | `mail` is missing or no recipient is set; the log says which of the two |
| No reboot happens | It is set to "never" — the note is in the report |
| `Could not get lock /var/lib/dpkg/lock` | Another apt operation was running; a run waits up to 10 minutes for it |
| An excluded package is updated anyway | The pattern does not match — `docker` is not `docker-ce` |
| Docker containers are down after the night run | They did not come back within 10 minutes — Docker was rolled back and held; the report lists the containers |
