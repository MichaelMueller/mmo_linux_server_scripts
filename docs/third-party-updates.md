# Updates: safe and other - plan

Status: **implemented** (agreed and built 2026-11-12) - see
[auto-update.md](auto-update.md) and [image-check.md](image-check.md). This
file keeps the reasoning.

## The model

Every update is described by four things. Three of them the script decides,
one the user:

| Property | Decided by | Values | Effect |
|---|---|---|---|
| **Breaks nothing?** | script, per source | safe / other | safe: unattended; other: by hand (or on a schedule) |
| **Quick?** | script, per software | quick / noticeable | quick: may run hourly; noticeable: only in the night window |
| **Needs a reboot?** | script (new kernel, ...) | yes / no | never right away - at night, after the updates |
| **Schedule** | user | the settings below | when what runs |

|  | quick | noticeable |
|---|---|---|
| **safe** | hourly (`SEC_UPDATES=hourly`) | night window |
| **other** | by hand (or `FULL_UPDATES`) | by hand (or `FULL_UPDATES`, in the night window) |
| **+ reboot needed** | night window, after the updates | night window, after the updates |

## Settings and questions

Only these four, each preset by the `--conf` file (then not asked); `--yes`
takes the recommendation:

| Setting | Values | Default |
|---|---|---|
| `SEC_UPDATES` | `hourly` (quick ones hourly, noticeable ones at night), `daily` (all at night), `off` | `hourly` |
| `FULL_UPDATES` | `off` (by hand), `weekly`, `daily` | `off` |
| `REBOOT` | `window` (at night after the updates), `never` (only a mail) | `window` |
| `REBOOT_TIME` | the night window, also for the noticeable updates | `03:00` |

Block 4 in base-setup:

```
=== 4 Updates ===
[ ] Automatic updates: none
Updates (required) - set up now? [Y/n]:

Safe updates - fixes that change nothing (Debian security, Docker 28.x,
Tailscale, Caddy 2.9.x, Falco):
  1) hourly    quick ones every hour, the ones that restart containers
               or the tailnet at 03:00                         (recommended)
  2) nightly   all at 03:00
  3) off
Choice [1]:

Other updates - new versions, can change behaviour (Docker 29, Debian
point release, ...):
  1) by hand   the overview and a mail say when some are waiting   (recommended)
  2) weekly    Sunday 03:00
  3) daily     03:00
Choice [1]:

Reboot when an update needs it (new kernel):
  1) at night  after the updates                                (recommended)
  2) never     only a mail
Choice [1]:

Night window [03:00]:
```

No longer asked: restarting services (always on for safe updates - that is
their point), mail settings (always to `NOTIFY_TO`: errors, rollbacks, other
updates waiting too long), interval in minutes, weekday, excluded packages
(`FULL_DAY`, `EXCLUDE_PKGS` only in the file, or in the expert menu of
`auto-update.sh` run on its own). Today the block asks about ten questions.

Overview, block 4:

```
  [x] Safe updates     required     unattended - quick ones hourly, Docker/Tailscale at 03:00
  [!] Other updates    recommended  by hand - 7 pending, oldest 21 days (Docker 29.0, Caddy 2.10, point release 12.9)
  [x] Reboot           recommended  not needed
```

`[!]` when other updates have been waiting longer than 14 days - they also
carry the fixes the safe run cannot take (see below).

## Heuristics: safe, and quick

Third-party repositories have no security channel; they ship new versions,
fixes and features mixed. A version counts as safe when it stays within the
range the project keeps compatible (the highest version within the range is
installed explicitly - no apt pins; the next
range waits for "other updates").

| Software | Source | Safe range | Quick? | Why quick / not |
|---|---|---|---|---|
| Debian/Ubuntu packages | `-security`, ESM | every security update | quick | stable backports the fix; needrestart restarts the affected services in seconds |
| nginx, Apache from Debian | `-security` | every security update | quick | Debian's nginx swaps the binary without dropping connections; Apache restarts gracefully; needrestart covers library fixes (OpenSSL) |
| nginx from nginx.org | `nginx.org/packages` | same stable branch (`1.26.x`) | quick | even minor = stable branch, only fixes within it; binary swap without dropping connections |
| Apache from the Sury repository | `packages.sury.org/apache2` | same minor (`2.4.x`) | quick | 2.4 for years, graceful restart |
| Caddy | `dl.cloudsmith.io/public/caddy/stable` | same minor (`2.9.x`) | quick | restarts in about a second, certificates come from its storage; open connections are cut once |
| Falco | `download.falco.org` | same minor | quick | restarts in seconds - a monitoring gap of seconds |
| Tailscale | `pkgs.tailscale.com` | every new version | noticeable | tailscaled restarts: every tailnet connection drops - including the admin's SSH session when SSH runs over the tailnet |
| Docker (+ containerd) | `download.docker.com` | same major (`28.x`) | noticeable | a minor update restarts the containers (live-restore covers only patch versions), and containers can take a while to be up again |

Why the safe range differs: Docker follows SemVer since 23 (breaking changes
only in major versions, 3-4 a year, fixes only for the newest line); Caddy is
2.x for years and minor versions now and then change config or behaviour;
Falco minor versions can bring new rules, i.e. new alerts; Tailscale keeps one
compatible line.

Debian security in the hourly run never restarts containers: Debian does not
ship Docker; if needrestart restarts dockerd after a library fix, live-restore
keeps the containers running (same Docker version).

**Check after every unattended third-party update, with fallback:**

1. before: note the installed version;
2. after: Caddy - `caddy validate` with the own configuration, service
   active; nginx - `nginx -t`, service active; Apache - `apachectl
   configtest`, service active; Docker - daemon active, the containers running before run again
   (waits up to 10 minutes, for containers with a healthcheck until
   "healthy"); Tailscale - service active, connected; Falco - service active;
3. if not: install the previous version again (the repositories keep old
   versions), hold it, mail `NOTIFY_TO`. For packages from Debian's security
   repository there is no older fixed version to go back to - a failed check
   there only mails.

nginx and Apache are checked wherever they come from: nginx-manager installs
nginx from Debian; Apache has no manager here, but a server may have it -
and may have either from an upstream repository instead.

**Any other third-party repository** (a PPA, a vendor repository, ...): no
heuristic known - its packages count as "other updates" only, and the
overview names the repository ("not covered by the safe run: packages from
repo X").

Everything else the tools install comes from Debian itself (nginx, WireGuard,
ClamAV, node exporter, fail2ban, lynis, rkhunter, msmtp, ...). No tool
installs via `curl | sh` or loose binaries.

Debian has a `caddy` package of its own (since bookworm), but it is an old
version, and Debian gives Go packages only limited security support - their
fixes usually come with point releases, not through the security repository.
caddy-manager therefore uses the official repository.

## Only with "other updates" - named in the overview

- Debian packages outside `-security`: point releases, `stable-updates`
  (ClamAV engine, `tzdata`).
- Third-party versions outside the safe range (Docker 29, Caddy 2.10, ...).

## Container images: alerting (proposed)

apt does not update the images of the running containers - the applications
themselves. Proposed: a check that only alerts, never pulls or restarts.

- **What:** every image a container runs from, scanned with Trivy (or Grype)
  for vulnerabilities in the **base image's OS packages** only
  (`--pkg-types os`: the Debian/Alpine/Ubuntu layer, not the application's
  libraries), severity **CRITICAL**, and only those with a fix available
  (`--ignore-unfixed`) - i.e. "a newer base image would close it".
- **When:** once a night, after the updates.
- **Mail:** only on a change - a new critical finding, or one gone - like the
  other monitors; per image the base OS, the CVE, the fixed version, and the
  hint "rebuild / pull a newer tag".
- **Also:** "newer image for the same tag available" (registry digest
  differs from the local one) as an extra line, not as an alert.
- **Overview, block 5:** `[x] Image check  nightly - no critical base image
  findings` / `[!] 2 images with critical fixable vulnerabilities`.
  Recommended when Docker is installed, `[-]` otherwise.
- **Install:** the scanner as a container (`aquasec/trivy`) or from its apt
  repository - then it is one more third-party source (safe range, quick).
  Its vulnerability database is downloaded daily; the images are scanned
  locally, nothing is uploaded.

## Not covered at all - a note in the overview

- These scripts: only by bundle or `git pull`, on purpose (`build-bundle.sh`,
  `--check` shows the version).
