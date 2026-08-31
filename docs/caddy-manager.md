# caddy-manager.sh — Caddy vhosts

Manages vhosts in Caddy: static files, redirects and reverse proxies. TLS is
terminated on this server, and Caddy fetches the certificates from Let's Encrypt
itself.

> Needs ports 80 and 443 and therefore rules out `nginx-manager`.

## Requirements

- Debian or Ubuntu, root rights
- Caddy — installed from the official repo when needed
- the domain has to point at this server in DNS, otherwise there is no
  certificate

## Usage

```bash
sudo ./caddy-manager.sh                 # menu
sudo ./caddy-manager.sh --check-plugin  # does the deSEC module still exist? (cron)
sudo ./caddy-manager.sh --uninstall     # remove the vhosts and the Caddyfile
```

The first-time setup happens automatically when the first host is created.

## Menu

| Item | Effect |
|---|---|
| 1 | Create a host |
| 2 | Show a host |
| 3 | Edit a host |
| 4 | Delete a host |
| 5 | TLS / DNS challenge (deSEC) |
| 6 | Check the config (`caddy validate`) |
| 7 | Logs (`journalctl -u caddy`) |
| 8 | Uninstall |
| 9 | Quit |

## Layout

```
/etc/caddy/Caddyfile                    global options + import
/etc/caddy/sites.d/<domain>.caddy       one file per vhost
/etc/caddy/sites-meta.d/<domain>.meta   TYPE= and TARGET= for the overview
/var/log/caddy/<domain>.log             access log per vhost
```

The Caddyfile contains only:

```
{
    email admin@example.com
}

import /etc/caddy/sites.d/*.caddy
```

The metadata file next to it stores the type and the target, so the overview can
show them without parsing Caddy syntax.

## The three types

### Static files

| Question | Default |
|---|---|
| Directory | `/var/www/<domain>` |
| Create it if it does not exist | yes (with a placeholder `index.html`) |
| Directory listing (`browse`) | no |
| Basic auth | no |

Produces `root`, `encode zstd gzip`, `file_server` and a log block.

### Redirect

| Question | Default |
|---|---|
| Target URL | required |
| 301 permanent / 302 temporary | 301 |
| Carry path and query over | yes (`{uri}`) |

### Reverse proxy

| Question | Note |
|---|---|
| Backend(s) | several space-separated |
| The backend speaks HTTPS | then `transport http { tls }` |
| Skip verification of the backend certificate | for self-signed backends |
| Path prefix | e.g. `/api`, empty = everything |
| WebSocket/streaming mode | sets `flush_interval -1` |
| Pass the original Host header | default yes |
| Health check | path and a 30 s interval |
| Load balancing | with several backends: round_robin / least_conn / ip_hash |
| Basic auth | the password is hashed with `caddy hash-password` |

`X-Real-IP` is always set.

## Access: whole host, single paths

Every host type asks who may reach it. Presets: everyone, the tailnet
(`100.64.0.0/10`), private networks (`private_ranges`), both, or a list of your
own — checked for being a valid CIDR before it is written, because a typo in a
network would only surface as a config Caddy refuses.

The own list is not an alternative to the presets, it contains them: the
keyword `private_ranges` may be mixed in with your own ranges
(`private_ranges 192.168.30.0/24`), and the list starts pre-filled with
`DEFAULT_ALLOW_CIDRS` from `caddy-manager.conf`, so the range you use most is
one Enter away. Editing a host offers that host's current list instead.

Restricting the **whole host**:

```
example.com {
    @denied not remote_ip 100.64.0.0/10
    respond @denied 403
    ...
}
```

Restricting **single paths** — the host stays public, the admin area does not.
This is the case the whole feature exists for:

```
example.com {
    @protected {
        path /admin* /metrics*
        not remote_ip 100.64.0.0/10
    }
    respond @protected 403
    ...
}
```

The conditions inside a named matcher are ANDed: these paths **and** coming from
outside. `respond` sorts ahead of `reverse_proxy` and `file_server` in Caddy's
default directive order, so it answers before the handler ever runs — no `route`
block needed. Paths are stored without a trailing `*` and always emitted with
one, so `/admin` also covers `/admin/users`.

Because a host-wide limit already covers every path, the wizard only offers the
path question while the host as a whole is open.

### Two ways this silently goes wrong

**`remote_ip` is the direct peer.** If something sits in front of this Caddy,
that peer is the proxy, not the client — the rule then locks out everyone or
nobody. With the SNI relay from [nginx-manager](nginx-manager.md) (TLS
passthrough) there is not even an `X-Forwarded-For` to fall back on, so the
restriction has to live on the relay, not here. On a Caddy that talks to the
network directly — what this tool assumes — `remote_ip` is right.

**Tailscale is not `private_ranges`.** The tailnet lives in the CGNAT range
`100.64.0.0/10`; Caddy's `private_ranges` shortcut covers RFC1918, loopback and
link-local, and none of that includes it. Hence the separate preset.

And one that does *not* go wrong, which is worth knowing: the restriction does
**not** block the ACME HTTP challenge. Caddy answers that ahead of the site
routes, so a restricted host still gets its certificate over HTTP — as long as
port 80 is reachable from the internet. If a *firewall* is what shuts the host
off, that is exactly when the DNS challenge below becomes necessary.

## The DNS challenge over deSEC

Menu item 5. Worth it for two things: a host that is not reachable from the
internet at all (no port 80, so no HTTP challenge), and **wildcard
certificates** — `*.example.com` cannot be proved by an HTTP request, only by a
DNS record.

Per host, not globally: the wizard asks, and the default stays the HTTP
challenge. A wildcard host has no choice and is set to DNS automatically; asked
for one before deSEC is set up, the wizard refuses instead of creating a host
that looks fine and never gets a certificate.

```
example.com {
    tls {
        dns desec {
            token {env.DESEC_TOKEN}
        }
    }
    ...
}
```

**The token is not in the Caddyfile.** That file is world-readable. It lives in
`/etc/caddy/desec.env` (0640, root:caddy) and reaches Caddy as an environment
variable through a systemd drop-in:

```
/etc/systemd/system/caddy.service.d/desec-env.conf
[Service]
EnvironmentFile=/etc/caddy/desec.env
```

Before it is stored, the token is tried against the deSEC API
(`GET /api/v1/domains/`). A wrong token would otherwise be noticed by nobody but
Let's Encrypt, and that costs rate limit budget.

### Why there is a cron job for this

The caddy package from the apt repo carries the standard modules only. The
provider is added to the binary with `caddy add-package`, and **an
`apt upgrade` of that package puts the standard build back** and takes the
module with it.

Nothing breaks on that day. The certificates are still valid; only the renewal,
weeks later, fails — which is the worst way for a problem to surface. So
`/etc/cron.d/caddy-manager` runs `--check-plugin` daily: if the module is gone
it is reinstalled, Caddy is restarted, and both facts land in
`var/caddy-manager.log`. While everything is in order the check says nothing.

The alternative would have been `apt-mark hold caddy` — rejected on purpose: it
freezes the security updates of the one service that is exposed to the
internet. If you would rather build the binary yourself,
`xcaddy build --with github.com/caddy-dns/desec` and a drop-in pointing at it
works as well; then the daily check has nothing to do.

Removing the DNS challenge (menu item 5 → 4) takes the token, the drop-in and
the cron entry with it, and says how many hosts still have `tls { dns desec }`
in their config — those would fail to renew until they are switched back.

## Certificates

Caddy requests them automatically as soon as the vhost is active and the domain
points at the server. The mail address you give ends up in the global options
and serves Let's Encrypt as the contact.

The certificates live under `/var/lib/caddy`. When a vhost is deleted they stay
there — deliberately, so that a host deleted by accident comes back without a
new request.

## Validation and rollback

After every write, `caddy validate` runs. If Caddy rejects the configuration,
the change is taken back (when editing, from `<file>.bak`; when creating, by
deleting) and reloaded. A typo never takes the other vhosts down with it.

Editing works either through the wizard (the type can be changed freely) or
directly in an editor (`$EDITOR`, otherwise nano).

## The first-time setup in detail

1. Install Caddy from the Cloudsmith repo, if it is not present
2. Create `sites.d/` and `sites-meta.d/`
3. Ask for the Let's Encrypt mail address
4. Back up **an existing Caddyfile that did not come from here** to
   `Caddyfile.orig.<epoch>`
5. Write the Caddyfile anew
6. ufw: open 80/tcp and 443/tcp
7. `enable` and `restart`

## State and data

The vhosts live **service-side**: Caddy reads `sites.d/*.caddy` directly through
the `import` glob. Hand-written files there keep working unchanged and show up
in the list. Nothing sits next to the script.

Alongside that there is a small secondary bookkeeping:
`sites-meta.d/<domain>.meta` holds type, target, challenge and the access
rules, so that the overview does not have to parse Caddy syntax — and so that
"Edit → Reconfigure" can offer the previous answers as defaults instead of
throwing them away. Losing it costs the columns (`?`) and those defaults; the
vhost itself runs perfectly normally, and the next pass through the wizard
writes it again.

```sh
TYPE=proxy
TARGET=127.0.0.1:8080
ACME=dns                       # http | dns
ALLOW_CIDRS=100.64.0.0/10      # empty = reachable by everyone
PROTECT_PATHS=/admin /metrics  # empty = no path is restricted
PROTECT_CIDRS=100.64.0.0/10
```

Files written by earlier versions carry `TYPE` and `TARGET` only; the missing
keys then read as empty, which is exactly a host without restrictions.

The settings of the tool itself (mail address, whether deSEC is set up, the
default network list) live in `caddy-manager.conf` next to the script, and the
log of the plugin check in `var/caddy-manager.log`.

### Putting it on an existing Caddy installation

One point matters here: **the first-time setup rewrites
`/etc/caddy/Caddyfile`.** An existing file is backed up to
`Caddyfile.orig.<epoch>` beforehand (and restored from it on uninstall), but
global options and vhosts that sit *in the Caddyfile itself* instead of in
`sites.d/` have to be carried over by hand.

If you want to avoid that, set the structure up yourself first:

```bash
mkdir -p /etc/caddy/sites.d /etc/caddy/sites-meta.d
echo 'import /etc/caddy/sites.d/*.caddy' >> /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

After that the tool considers the setup done and never touches the Caddyfile —
it then manages files in `sites.d/` exclusively.

## Uninstall

1. Back up the Caddyfile, `sites.d/` and `sites-meta.d/` to
   `/root/caddy-uninstall-<time>.tar.gz`
2. Stop and disable the service
3. Delete the vhosts and the metadata
4. Restore the Caddyfile from the newest `.orig.<epoch>` backup, otherwise
   delete it
5. If you say so, `/var/lib/caddy` — **it contains the certificates**, with its
   own backup beforehand
6. If you say so, `/var/log/caddy`
7. If you say so, the ufw rules 80 and 443 — with a note that 443 may also come
   from nginx

The package and the apt repo stay:

```bash
apt purge caddy
rm -f /etc/apt/sources.list.d/caddy-stable.list \
      /usr/share/keyrings/caddy-stable-archive-keyring.gpg
```

> Deleting the certificates means they are issued again. Let's Encrypt limits
> that to 5 certificates per domain per week — with many domains you can run
> into the limit.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No certificate | DNS does not point here, or port 80 is closed (the HTTP-01 challenge needs it) |
| 403 on static files | The user `caddy` may not read the directory — check the permissions on every level of the path |
| 502 on the reverse proxy | The backend is unreachable, or it speaks HTTPS and the option was not set |
| WebSocket drops | Enable the streaming mode (`flush_interval -1`) in the wizard |
| A wildcard domain does not work | `*.example.com` needs the DNS-01 challenge and therefore a DNS plugin (a custom build with `xcaddy`). Create every subdomain individually |
| A change has no effect | `caddy validate` in menu item 5; on errors it was rolled back automatically |
| The certificates are gone after `apt purge caddy` | They were in `/var/lib/caddy`; the uninstall's backup contains them |
