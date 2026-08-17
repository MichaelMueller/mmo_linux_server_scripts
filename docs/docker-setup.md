# docker-setup.sh — Docker

Installs Docker from the official repo and configures the three things that
otherwise start hurting on a server sooner or later: log rotation, the binding
of published ports, and cleanup.

## Requirements

- Debian or Ubuntu, root rights
- outgoing internet access for the repo and the images

## Usage

```bash
sudo ./docker-setup.sh              # menu
sudo ./docker-setup.sh --prune      # cleanup run, the way cron does it
sudo ./docker-setup.sh --status     # status on stdout
sudo ./docker-setup.sh --uninstall  # remove the settings (not Docker)
```

## Menu

| Item | Effect |
|---|---|
| 1 | Install |
| 2 | Show status |
| 3 | Settings (log rotation, port binding, live-restore) |
| 4 | Add a user to the `docker` group |
| 5 | Clean up |
| 6 | Uninstall |
| 7 | Quit |

## Installation

From the official repo, not from the distribution: `docker.io` is usually
several versions behind and does not ship the compose plugin.

What gets installed is `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin` and `docker-compose-plugin` (so `docker compose`, not the
old `docker-compose`).

Beforehand, competing packages are checked for — `docker.io`, `docker-compose`,
`podman-docker`, `containerd`, `runc` — and removing them is offered. Data under
`/var/lib/docker` survives that.

With derivatives (Linux Mint & co.) there is no Docker repo for their own
codename; the script then takes `UBUNTU_CODENAME` or `DEBIAN_CODENAME` from
`/etc/os-release` and asks if it has to.

## Settings

What is written is `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "ip": "127.0.0.1",
  "userland-proxy": true
}
```

**Nothing else may be in there.** `dockerd` validates `daemon.json` strictly and
refuses to start on any key it does not know:

```
unable to configure the Docker daemon with file /etc/docker/daemon.json:
the following directives don't match any configuration option: _comment
```

JSON has no comments, so there is no way to note inside the file where it came
from — up to 2.2.0 a `"_comment"` key tried to, and that is exactly what broke
the daemon. The provenance now sits **next to** it in
`/etc/docker/.daemon.json.docker-setup`, which is also what tells the uninstall
whether the file is one of ours.

An existing, foreign `daemon.json` is **not** merged but backed up to
`daemon.json.orig.<epoch>` and shown in plain text — mixing JSON in bash would
be guessing, not computing. You carry your own entries over by hand.

### Checked before it is applied, taken back if it fails

The same order the other tools use (`nginx -t`, `caddy validate`, `sshd -t`):

1. The previous `daemon.json` is kept aside.
2. Where Docker offers it (23 and newer), `dockerd --validate --config-file` is
   run first — the configuration is judged without touching the running daemon.
3. Only then is Docker restarted.
4. **If either step fails, the change is taken back**: the previous file is put
   back — or removed again, if there was none — and Docker is started again.

A settings change can therefore no longer leave the host without a container
engine. Before 2.2.0 a rejected file stayed in place and Docker stayed down.

The chosen values additionally live in `docker-setup.conf` next to the script,
so the file can be rewritten reproducibly at any time.

### Log rotation

Without `log-opts`, every container log file under
`/var/lib/docker/containers/<id>/` grows **without bound**. That is the most
common cause of a full disk on a Docker host: a talkative container silently
writes dozens of gigabytes over the months. The default here: 10 MB × 3 files
per container.

The setting only affects **newly created** containers. Existing ones keep their
log configuration until they are recreated.

### Port binding — the important point

**Docker bypasses ufw.** Docker enters published ports (`-p 8080:80`) straight
into the `DOCKER` chain of iptables, and that is evaluated before the ufw rules.
A rule `ufw deny 8080` does **not** protect the container — it is reachable from
the internet even though the firewall claims otherwise. That surprises people
regularly, experienced ones included.

The countermeasure here is `"ip": "127.0.0.1"`: with it, every published port
without an explicit address ends up on the loopback interface. They are then
only reachable locally — that is, through a reverse proxy (`caddy-manager` or
`nginx-manager`) that handles TLS and access. Which is exactly what you want on
a server that serves web services.

If you do need a port on the outside, give the address explicitly:
`-p 0.0.0.0:8080:80`. Then it is a deliberate decision rather than an oversight.

At the end, menu item 2 explicitly lists every running container whose ports are
bound to `0.0.0.0` or `::`.

### live-restore

Keeps containers running while the Docker service restarts — during a package
update by `auto-update`, for instance. Without the option, every daemon restart
briefly takes all containers down. Not combinable with swarm mode.

## The `docker` group (item 4)

> Whoever is in the group `docker` can read and write every file on the system
> as root through a container — with `docker run -v /:/host …`, say. That is
> equivalent to root rights, only without the sudo log.

The script says so clearly before adding anyone and shows who is already in it.
The membership only takes effect after the user's next login.

## Cleanup (item 5)

Shows `docker system df` and offers:

- **clean up now** — `docker system prune -f --filter until=<h>h`
- **a weekly automatic run** — cron entry `/etc/cron.d/docker-prune`, on Sundays
  at the chosen hour
- **show unused volumes** — only show them, do not delete them

Two deliberate decisions:

- **Volumes are never removed automatically.** That is where the data lives, and
  a volume without a running container is by no means a superfluous volume — a
  stopped database container is the normal case, not rubbish. They are only
  listed, deleting them stays manual work.
- **`-a` can be switched off and is off by default.** Without `-a` only untagged
  images go. With `-a`, tagged images that no container is currently using go
  too — those have to be pulled again on the next start, which is unpleasant
  without internet access or with large images.

The age filter (default 168 h = 7 days) prevents an image that was just built and
not started yet from disappearing again immediately.

## Files created

| Path | Contents |
|---|---|
| `/etc/docker/daemon.json` | the settings above |
| `docker-setup.conf` | the same values, next to the script |
| `/etc/cron.d/docker-prune` | weekly cleanup, if enabled |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.asc` | the repo |

## State and data

**Service-side:** what counts is `/etc/docker/daemon.json`, Docker's own
configuration. `docker-setup.conf` next to the script holds the same values once
more — purely as a convenience, so the file can be rewritten reproducibly. If it
differs, `daemon.json` wins.

It can be put on an existing Docker installation: a foreign `daemon.json` is
backed up to `.orig.<epoch>`, shown in plain text and only replaced after asking
— you carry your own entries over from it by hand. Containers, images and
volumes are never touched, not even by the uninstall.

## Uninstall

Removes the **settings**, not Docker: `daemon.json` (restored from the `.orig`
backup, otherwise deleted), `docker-setup.conf` and the cron entry. On request
Docker is restarted so the change takes effect. Backup beforehand to
`/root/docker-setup-uninstall-<time>.tar.gz`.

Running containers, images and **above all the volumes stay untouched**. To
remove everything:

```bash
apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
rm -rf /var/lib/docker /var/lib/containerd
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
```

> `rm -rf /var/lib/docker` deletes **every volume** and with it the data of all
> containers. That is not cleanup, that is announced data loss.

After the uninstall, container logs grow without bound again —
`disk-monitor.sh` notices that in time.

## Troubleshooting

| Symptom | Cause |
|---|---|
| A container is reachable from the network despite `ufw deny` | Docker bypasses ufw; bind the port to `127.0.0.1` (menu item 3) or explicitly `-p 127.0.0.1:…` |
| Docker does not start after a settings change | A syntax error or an unknown key in `daemon.json`. The script shows `journalctl -u docker` and takes the change back, so Docker comes up again on the old configuration |
| `directives don't match any configuration option: _comment` | A `daemon.json` written before 2.2.0. Delete the `"_comment"` line and `systemctl start docker`, or run menu item 3 once — the file is rewritten without it |
| `daemon.json` is not removed by the uninstall | It is only removed when it is one of ours, which is decided by `/etc/docker/.daemon.json.docker-setup` |
| `permission denied` on the Docker socket | The user is not in the `docker` group, or has not logged in again yet |
| Disk full despite rotation | Rotation only applies to newly created containers; recreate the old ones once |
| `docker compose` not found | `docker-compose` (v1) was expected — the plugin is called `docker compose`, without a hyphen |
| An image is gone after the cleanup | `-a` was active; switch the option off in menu item 5 |
| Repo error "no Release file" | The codename belongs to a derivative without a Docker repo of its own — take the base distribution's |
