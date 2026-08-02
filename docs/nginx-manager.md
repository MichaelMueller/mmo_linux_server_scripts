# nginx-manager.sh — TCP relay with SNI routing

nginx as a pure TCP relay: it reads the SNI out of the TLS handshake, looks up a
backend for it and passes the connection through **undecrypted**. TLS is not
terminated — the certificate lives on the backend.

> Needs port 443 and therefore rules out `caddy-manager`. Caddy terminates TLS
> on this server, nginx passes it through. If the backend should keep its own
> certificate: nginx. Otherwise Caddy.

## Requirements

- Debian or Ubuntu, root rights
- `nginx-extras` (contains the `stream` module) — installed when needed

## Usage

```bash
sudo ./nginx-manager.sh              # menu
sudo ./nginx-manager.sh --uninstall  # remove the relay
```

The first-time setup happens automatically when the first host is created.

## Menu

| Item | Effect |
|---|---|
| 1 | Create a host |
| 2 | Edit a host (change the backend) |
| 3 | Delete a host |
| 4 | Test the config (`nginx -t`) |
| 5 | Uninstall |
| 6 | Quit |

## Layout

```
/etc/nginx/stream.conf              map + server block on :443
/etc/nginx/stream-hosts.d/*.map     one line per host: domain  backend;
/etc/nginx/nginx.conf               contains the stream block (marked)
```

`stream.conf`:

```nginx
map $ssl_preread_server_name $backend {
    include /etc/nginx/stream-hosts.d/*.map;
}

server {
    listen 443;
    listen [::]:443;
    proxy_pass $backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 300s;
}
```

A host is exactly one line:

```
app.example.com    10.10.0.2:443;
```

## First-time setup

On the first host:

1. Install `nginx-extras`, if the `stream` module is missing
2. Ask for a fallback backend for connections with an unknown or missing SNI
   (empty = drop the connection) → `00-default.map`
3. Write `stream.conf`
4. Append the `stream` block to `nginx.conf`, between the markers
   `# >>> nginx-manager >>>` and `# <<< nginx-manager <<<`
5. Disable the http default vhost, **if** it listens on 443 — otherwise the port
   clashes
6. ufw: open 443/tcp
7. `nginx -t`, `enable`, `restart`

## Changes

After every write, `nginx -t` runs. If the test fails, the change is taken back
(when editing, from `<file>.bak`) and reloaded. So a typo never takes the other
hosts down with it.

## Important to understand

- **The certificate has to live on the backend.** This server never sees the
  encrypted traffic in the clear and therefore cannot issue one either.
- **Clients without SNI** (very old software, direct access by IP) end up at the
  fallback backend or are dropped.
- **The backend address is `IP:port`.** A hostname would be resolved on every
  connection; for a relay into the internal network the IP is the obvious
  choice.
- **No HTTP features.** No header rewriting, no compression, no access logs with
  URLs — at this level there are only bytes.

## State and data

**Service-side.** A host is a `.map` file that nginx reads directly through the
`include` glob — there is no database and no state file beside it, and nothing
sits next to the script. A `.map` created by hand is displayed and managed
exactly like a generated one.

It can be put on an existing nginx installation: the entire `http` part stays
untouched, all that is added is a marked `stream` block in `nginx.conf`. The one
exception is the default vhost — it is disabled if it listens on 443 itself
(otherwise the port clashes), and hooked back in on uninstall if you say so.

## Uninstall

1. Backup to `/root/nginx-uninstall-<time>.tar.gz`
2. Cut the `stream` block out of `nginx.conf`: primarily through the markers,
   failing that (installations from before the markers were introduced) through
   an awk pass that removes exactly the `stream` block containing *our* include
   line and leaves foreign `stream` blocks alone
3. `nginx -t`; if it fails, `nginx.conf` is restored from the backup and nothing
   else is touched
4. Delete `stream-hosts.d/` and `stream.conf`
5. If you say so: hook the http default vhost back in
6. If you say so: remove the ufw rule 443/tcp — **with a warning that port 443
   may also come from Caddy**
7. If you say so: stop and disable nginx

The `nginx-extras` package stays installed.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `nginx: [emerg] bind() to 0.0.0.0:443 failed` | Something else holds 443 — usually Caddy or the http default vhost |
| The connection always ends up at the fallback | The client sends no SNI, or the domain is not in `stream-hosts.d/` |
| Certificate error in the browser | The certificate on the backend does not match the domain — there is nothing to change here |
| `unknown directive "stream"` | `nginx-light`/`nginx-core` installed without the stream module; `nginx-extras` is needed |
| A change has no effect | Check `nginx -t` in menu item 4; on errors it was rolled back automatically |
| Long connections drop | Raise `proxy_timeout` in `stream.conf` (default 300 s) |
