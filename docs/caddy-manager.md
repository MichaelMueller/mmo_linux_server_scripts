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
sudo ./caddy-manager.sh              # menu
sudo ./caddy-manager.sh --uninstall  # remove the vhosts and the Caddyfile
```

The first-time setup happens automatically when the first host is created.

## Menu

| Item | Effect |
|---|---|
| 1 | Create a host |
| 2 | Show a host |
| 3 | Edit a host |
| 4 | Delete a host |
| 5 | Check the config (`caddy validate`) |
| 6 | Logs (`journalctl -u caddy`) |
| 7 | Uninstall |
| 8 | Quit |

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
`sites-meta.d/<domain>.meta` holds the type and the target for the overview, so
that `list` does not have to parse Caddy syntax. It is purely cosmetic — if it
is missing, the type and target columns show a `?`, the vhost runs perfectly
normally, and the next edit through the wizard creates it.

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
