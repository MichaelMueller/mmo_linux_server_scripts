# git-updater.sh — keeping working copies up to date

Keeps git working copies at the state of the remote via cron: one entry per
directory, by default a `git pull` every five minutes. On request it redeploys
Docker Compose after new commits and/or runs a command of your own.

## Requirements

- `git` (`base-tools.sh` always installs it)
- root for the cron entry; the pulls run as the respective owner
- for the compose deployment `docker compose` (or the old `docker-compose`), and
  the configured user has to be allowed at the Docker socket
- for mail notifications, a mailer that is set up (the `mail` command)

## Usage

```bash
sudo ./git-updater.sh              # menu
sudo ./git-updater.sh --run        # one run, the way cron does it
sudo ./git-updater.sh --status     # entries on stdout
sudo ./git-updater.sh --uninstall  # remove cron, configuration and data
```

## Menu

| Item | Effect |
|---|---|
| 1 | Manage repositories (create, edit, remove) |
| 2 | Update all now — the same run as via cron |
| 3 | Settings (interval, time limit, notification) |
| 4 | Show the log |
| 5 | Uninstall |
| 6 | Quit |

## Settings

| Setting | Meaning | Default |
|---|---|---|
| Data directory | where entries, state and logs live | `var/` next to the script |
| Check interval | minutes between two runs | 5 |
| Time limit | seconds per git call | 120 |
| Compose time limit | seconds per deployment — an image build takes minutes, not seconds | 900 |
| Mail on an update | when new commits were fetched | yes |
| Mail on an error | when a repo could not be updated | yes |
| Mail without a change | even when there was nothing to do | no |

Stored in `git-updater.conf` next to the script.

## One entry

A file in `var/repos.d/<name>.conf`:

```sh
NAME="webapp"
REPO_PATH="/srv/webapp"
BRANCH="main"                          # empty = whatever is checked out
RUN_USER="deploy"
COMPOSE="1"                            # redeploy after new commits
COMPOSE_DIR=""                         # relative to the repo, empty = root
COMPOSE_PULL="0"                       # 'docker compose pull' first
COMPOSE_BUILD="1"                      # 'up -d --build' instead of 'up -d'
POST_CMD="systemctl reload caddy"      # only on new commits, optional
ENABLED="1"
NOTE="production"
```

When creating an entry the script checks that there really is a `.git` under the
directory, and suggests the **owner of the directory** as the user — that is
almost always the right one. If there is a compose file in the repository, the
question about the deployment is preset to "yes". After that a test run happens
right away, so you do not have to wait for the next cron pass for the first bit
of feedback.

`ENABLED="0"` suspends an entry temporarily without deleting it. Removing an
entry leaves the working copy on disk.

Entries from earlier versions without the `COMPOSE_*` lines keep working
unchanged — if `COMPOSE` is missing, nothing is deployed.

## Overview

```
NAME             DIRECTORY                      BRANCH       USER      COMPOSE    ACTIVE  STATE
webapp           /srv/webapp                    main         deploy    pull+build yes     OK 2026-08-01 09:15:02
docs             /srv/docs                      (current)    www-data  -          yes     UPDATED 2026-08-01 09:10:01
oldproject       /srv/old                       main         deploy    up         no      -
```

The `COMPOSE` column summarises what is deployed: `-` (nothing), `up`, `build`
(`up -d --build`), `pull+up` or `pull+build`.

## How a run works

Per entry:

1. is there a git repository there?
2. are there **local changes**? Then an error — and that before anything is
   touched
3. if a branch is configured: `git checkout <branch>`
4. `git pull --ff-only`
5. if the commit changed and `COMPOSE="1"` is set: deploy
6. if the commit changed and a `POST_CMD` is set: run it
7. write the result into the state, collect the changes

At the end **one** mail goes out listing all the changes of the run — not one
per repository.

### The important decisions

**`--ff-only`, never merge or rebase.** If the working copy diverges, that
should show up rather than silently produce a merge commit nobody asked for. An
automatic process that rewrites history is not a good idea.

**Local changes are an error, not an invitation to tidy up.** The script
discards nothing and stashes nothing. Whoever changed something in the
production directory presumably had a reason — and a cron job that clears such
changes away is data loss on a timer.

**As the owner rather than as root.** If git runs as the owner, that account's
SSH keys and credential helpers apply, and git's protection against foreign
directories (`detected dubious ownership`) never kicks in at all. No
`safe.directory` patching needed.

**Never interactive.** `GIT_TERMINAL_PROMPT=0` and `ssh -o BatchMode=yes` make
sure a run aborts immediately instead of waiting for a passphrase or a host key
confirmation. On top of that, `timeout` caps every call. Without it a cron job
on a private repo hangs forever — and again on the next tick.

**A lock against overlap.** At a five-minute cadence a slow run can spill into
the next; `flock` prevents that. If `flock` is missing, work goes on without a
lock — better a possible overlap than no run at all.

### Errors are only reported on a change

As with the TCP monitoring, there is no kicking a service while it is down:

| Transition | Reported |
|---|---|
| OK → error | yes |
| error → error | **no** |
| error → OK | yes, the all-clear |
| new commits fetched | yes (if switched on) |

The exit code of `--run` is 1 for as long as any entry is in the error state —
even when no mail goes out because of it.

### Typical error messages

| Message | Meaning |
|---|---|
| `local changes in the working copy` | `git status` is not clean |
| `the working copy has diverged (no fast-forward)` | local commits that are not in the remote |
| `no upstream set for the branch` | `git branch --set-upstream-to=origin/<branch>` is missing |
| `no access to the remote (SSH key for …?)` | the user cannot reach the remote |
| `timed out after 120s` | the network or the remote is hanging |
| `but compose failed: …` | the deployment failed, with the last line of output appended |
| `but the compose directory … is missing` | `COMPOSE_DIR` points nowhere (a typo or it moved) |

## Deploying Docker Compose

With `COMPOSE="1"` the updater deploys after new commits itself — in the compose
directory and as the configured user:

```sh
docker compose pull            # only with COMPOSE_PULL="1"
docker compose up -d --build   # '--build' only with COMPOSE_BUILD="1"
```

| Field | Meaning |
|---|---|
| `COMPOSE` | `1` = deploy, `0` = do not |
| `COMPOSE_DIR` | directory of the compose file, **relative** to the repo; empty = root |
| `COMPOSE_PULL` | `docker compose pull` first |
| `COMPOSE_BUILD` | `up -d --build` instead of `up -d` |

**`pull` and `--build` are two different cases**, which is why they can be
switched separately:

- **The images come from a registry** (built externally, by a CI for instance):
  `COMPOSE_PULL="1"`, `COMPOSE_BUILD="0"`. Without `pull`, `up -d` otherwise
  starts the old image that is already there — the commit has arrived, the
  application has not.
- **The images are built locally from the repository:** `COMPOSE_PULL="0"`,
  `COMPOSE_BUILD="1"`. A `pull` is not just unnecessary here, it may well fail on
  services that do not exist in a registry at all.
- Both together is allowed and sensible when some services are built and others
  are pulled.

**`pull` runs before `up`, and with `&&`.** If the registry is unreachable or a
login is missing, the deployment aborts *before* running containers are
replaced. A half-updated stack is worse than an old one.

**The compose frontend is picked at runtime:** first `docker compose`, otherwise
`docker-compose`. Depending on the installation the CLI plugin lives under
`/usr/libexec` or in `~/.docker/cli-plugins` and cannot reliably be found from
outside — so the user's shell decides, not the script. If neither is found, that
is an error with a clear message.

**Its own time limit.** A `git pull` takes seconds, an image build minutes. So
`COMPOSE_TIMEOUT` (default 900 s) applies to the deployment instead of the
`TIMEOUT` for git calls.

**The user needs access to the Docker socket.** When creating an entry, the
script points out if the user is not in the `docker` group — with rootless
Docker that is fine, otherwise `usermod -aG docker <user>` is missing. The
deployment is **not** escalated to root: whoever may deploy by git commit does
not get root on the host along the way.

## The command after the update

`POST_CMD` runs **only** when new commits were actually fetched — in the
directory of the working copy and as the configured user, not as root. If it
fails, the entry counts as an error and the message contains the first line of
the output.

It runs **after** the compose deployment and only if that worked — running a
post step on a failed deployment tends to do damage.

Sensible examples:

```sh
POST_CMD="systemctl --user restart myapp"
POST_CMD="npm ci --omit=dev && systemctl restart myapp"
POST_CMD="docker compose exec -T app bin/migrate"
```

In the last example the user has to be allowed to run the `systemctl restart` as
well — otherwise through a sudo entry with `NOPASSWD` for exactly that command.

## State and data

**Its own state, unavoidably:** git itself does not know that it is supposed to
be pulled regularly. Everything lives under `DATA_DIR` — by default `var/` next
to the script, freely selectable at setup time.

```
git-updater.conf           configuration
var/repos.d/*.conf         the entries
var/state/<name>.state     result|time|detail
var/log/alerts.log         messages
var/log/git-updater.log    run log (last 2000 lines)
var/.lock                  lock against overlapping runs
/etc/cron.d/git-updater    schedule
```

**Nothing is changed about the working copies except the pull itself** — no git
configuration, no remotes, no branches are created. A repo that was cloned and
set up by hand keeps working unchanged, and you can work in it yourself at any
time.

## Uninstall

Removes the cron entry and the configuration, asks separately about the data
directory. Backup beforehand to `/root/git-updater-uninstall-<time>.tar.gz`.
**The working copies stay untouched** — they are simply no longer pulled
automatically.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Nothing happens, the log is empty | The cron entry is missing or points at an old path — run menu item 3 once |
| "A run is not finished yet" | The previous run is hanging; check the time limit and whether the remote is reachable |
| Always "no access" with private repos | The configured user has no matching SSH key. Test it by hand once: `sudo -u <user> ssh -T git@github.com` |
| Works by hand, but not through cron | Almost always a prompt (passphrase, host key) — in cron that is switched off, so deal with it by hand as the user first |
| `POST_CMD` does not run | It only runs on actually new commits; without a change nothing happens — and not if the compose deployment failed beforehand |
| `permission denied … docker.sock` | The configured user is not allowed at Docker: `usermod -aG docker <user>`, then log in again |
| `pull access denied` / `manifest unknown` | `COMPOSE_PULL` is set although the images are built locally — then `COMPOSE_PULL="0"` and `COMPOSE_BUILD="1"` |
| The commit is there, but the container runs old code | Neither `pull` nor `--build` set: `up -d` then just restarts the image that is already there |
| The deployment aborts in the middle of the build | `COMPOSE_TIMEOUT` is too tight for the build (menu item 3) |
| A repo stays at an old state, without an error | It is sitting on a different branch than expected — set the branch explicitly in the entry |
| Constant "local changes" | Often produced by the service itself (logs, caches inside the repo). Those paths belong in `.gitignore` or outside the working copy |
