# image-check.sh — critical holes in container base images

apt keeps the server's own packages current — not the images the containers
run from. image-check looks at the **OS packages of each running container's
base image** (Debian, Alpine, Ubuntu, ...) with [Trivy](https://trivy.dev) and
reports the **CRITICAL** vulnerabilities that are **fixed in a newer package**
— i.e. "a newer base image would close it": rebuild the image, or pull a newer
tag.

It only reports. It never pulls, rebuilds or restarts anything. The
application's own libraries (npm, pip, Go modules, ...) are not part of it —
that is the business of the project that builds the image.

## Requirements

- Debian or Ubuntu, root rights, Docker running
- Trivy and jq — installed by `--setup` (Trivy from its apt repository; from
  then on auto-update.sh keeps it current as a safe update within its minor
  version)
- for mails: a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./image-check.sh --setup       # install Trivy, schedule nightly, first check
sudo ./image-check.sh --check       # check now and show the findings
sudo ./image-check.sh --status      # one line: last check, findings
sudo ./image-check.sh --uninstall   # remove schedule, configuration, findings
```

Presets (base-setup.sh sets them): `DEFAULT_MAIL_TO` (address(es), `-` = none),
`DEFAULT_TIME` (`HH:MM`, default `04:30` — after the update night window).
With `BATCH=1` nothing is asked.

Exit codes: `--check` 0 nothing found, 1 findings, 2 the check could not run;
`--status` 0 nothing found, 1 findings, 3 not set up.

## What a check does

1. every image a running container uses (`docker ps`), once
2. `trivy image --scanners vuln --pkg-types os --severity CRITICAL --ignore-unfixed`
3. compares with the findings of the last check (`var/image-check/findings`)
4. **mail only on a change:** new findings (`[ALERT]`), findings gone, or images
   that could not be checked (`[ERROR]`) — not every night the same list

```
Container base images on web1: 4 image(s) checked
(OS packages of the base image, CRITICAL, only with a fix available)

nginx:1.25 (debian 12.4) - 2 critical, fixed in newer packages:
  CVE-2024-xxxxx     libssl3                  3.0.11-1~deb12u2 -> 3.0.13-1~deb12u1
  CVE-2024-yyyyy     zlib1g                   1:1.2.13.dfsg-1  -> 1:1.2.13.dfsg-1+deb12u1
  -> rebuild the image, or pull a newer tag

Since the last check: 2 new, 0 gone.
```

The images are scanned locally. Trivy downloads its vulnerability database
(from `ghcr.io/aquasecurity`, cached in `var/image-check/trivy-cache`); nothing
is uploaded.

## Files

| Path | Contents |
|---|---|
| `image-check.conf` | recipient and time (next to the script) |
| `/etc/cron.d/image-check` | the nightly check |
| `var/image-check/findings` | the findings of the last check |
| `var/image-check/last` | time and counts of the last check |
| `var/image-check/trivy-cache` | Trivy's database |
| `/etc/apt/sources.list.d/trivy.list`, `/usr/share/keyrings/trivy.gpg` | the Trivy repository |

`--uninstall` removes schedule, configuration and findings; Trivy and its
repository stay (`apt purge trivy` and the two files, if wanted).

## In the overview

`base-setup.sh --check`, block 5:

```
  [x] Image check      recommended  nightly at 04:30, last 2026-11-12 04:30: 6 image(s), no critical base image findings
  [!] Image check      recommended  nightly at 04:30, last 2026-11-12 04:30: 2 of 6 image(s) with 5 critical fixable finding(s)
```
