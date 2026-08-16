# tailscale-setup.sh — Tailscale

Installs Tailscale from the official repo, logs the server into the tailnet and
manages the options you actually need on a server: Tailscale SSH, subnet routes,
exit node, DNS.

## Requirements

- Debian or Ubuntu with systemd, root rights
- a Tailscale account and access to the admin console
- outgoing UDP to the internet (port 41641 preferred; Tailscale can get through
  over DERP relays if it has to, which is slower)

## Usage

```bash
sudo ./tailscale-setup.sh              # menu
sudo ./tailscale-setup.sh --status     # status on stdout
sudo ./tailscale-setup.sh --uninstall  # log out and clean up
```

## Menu

| Item | Effect |
|---|---|
| 1 | Install and log in |
| 2 | Show status |
| 3 | Change settings |
| 4 | Firewall: allow access over the tailnet |
| 5 | Log out |
| 6 | Uninstall |
| 7 | Quit |

## Installation

Through the official repo, matching the detected distribution:

```
/usr/share/keyrings/tailscale-archive-keyring.gpg
/etc/apt/sources.list.d/tailscale.list
```

`ID` and `VERSION_CODENAME` come from `/etc/os-release`. If the codename is
missing (some container images), it is asked for. Then `apt install tailscale`
and `systemctl enable --now tailscaled`.

## Logging in

Two ways:

- **Interactive** — Tailscale shows a URL you open in a browser to approve the
  node. The call waits for that.
- **Auth key** — a key from the admin console (`tskey-auth-…`). It is passed
  through a temporary file (`--auth-key=file:…`, `0600`) so that it does not
  show up in the process list.

  **That file is deleted again as soon as `tailscale up` has finished with
  it** — a valid auth key must not stay behind in `/tmp`. So a `cat` of the
  path afterwards correctly reports "No such file or directory"; that is the
  cleanup having worked, not the key having been lost. An interrupt during the
  login removes it too.

## Settings

The complete set is always asked for:

| Option | Flag | Default here |
|---|---|---|
| Hostname in the tailnet | `--hostname` | the host's short name |
| Tailscale SSH | `--ssh` | off |
| Offer subnets | `--advertise-routes` | none |
| Offer an exit node | `--advertise-exit-node` | off |
| Accept foreign subnets | `--accept-routes` | off |
| Take over MagicDNS | `--accept-dns` | off |
| Shields up | `--shields-up` | off |
| Tags | `--advertise-tags` | none |

Why always all at once? **`tailscale up` resets options you do not pass to their
default** and demands a `--reset` for that. Adding individual flags afterwards
therefore leads to error messages or silent changes. That is why menu item 3
asks for everything and offers `--reset`.

The finished command is shown before it is run.

### Tags, and the refusal they cause

Tags are a property of the `tailscale up` call, not something the daemon
remembers on your behalf: they have to be given **again on every login**. A
node that carries `tag:strato` — from an earlier run, or because the auth key
was a tagged one — therefore makes an otherwise correct call fail:

```
Error: changing settings via 'tailscale up' requires mentioning all
non-default flags. To proceed, either re-run your command with --reset or …
        tailscale up … --advertise-tags=tag:strato
```

Two things keep that from being a dead end:

- **The tag question is pre-filled with what the node currently carries**,
  read from `tailscale debug prefs`. Pressing Enter keeps the tags; `-`
  removes them deliberately.
- **If the call is refused anyway, `--reset` is offered right there** and the
  run is repeated with it. That matters most for the auth-key login: the key
  that was just typed in is still in hand at that moment, whereas being sent
  off to another menu item would mean fetching and typing it again.

`--reset` applies exactly what was asked for and returns everything else to its
default — so if a tag has to be kept, decline and enter it at the tag question
instead.

### About the defaults

- **MagicDNS is off by default.** It writes the Tailscale nameservers into
  `/etc/resolv.conf`; on a server with its own DNS configuration you usually do
  not want that.
- **`--accept-routes` is off.** A server that suddenly routes foreign subnets
  through the tunnel surprises more than it helps.
- **Tailscale SSH is off.** It is a second, independent SSH route with its own
  access control through the tailnet ACLs. Handy, but a deliberate decision —
  the regular `sshd` is not affected by it.

### IP forwarding

As soon as subnet routes or an exit node are chosen, the script writes:

```
# /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

Without that the kernel forwards no foreign packets, and routes or an exit node
simply do not work.

Offering, by the way, is not the same as enabling: routes and exit nodes have to
be **approved in the admin console** as well.

## Firewall (item 4)

Creates ufw rules on the interface `tailscale0` — either for all traffic from
the tailnet or for a single port:

```
ufw allow in on tailscale0 comment 'Tailnet'
ufw allow in on tailscale0 to any port 8080 proto tcp comment 'Tailnet'
```

That lets tailnet nodes reach services without any port being publicly open.
Incoming Tailscale traffic itself needs **no** rule — those connections are
established from the inside.

If you want no incoming connections from the tailnet at all, use `--shields-up`
instead.

## Status

Shows the version, the state of `tailscaled`, whether it is logged in, the
tailnet IP, the node list from `tailscale status` and whether IP forwarding was
set by this tool.

## Logging out (item 5)

`tailscale logout` and `tailscale down`. The software stays installed, the node
disappears from the tailnet.

## State and data

Practically **entirely service-side**: login, keys and options live in
`/var/lib/tailscale` and in the tailnet respectively, and are read through
`tailscale status`. The only things of its own are
`/etc/sysctl.d/99-tailscale.conf` and — if created — the ufw rule on
`tailscale0`. Nothing sits next to the script.

It can be put on an existing Tailscale installation. Only one thing to note:
menu item 3 sets the node's options **completely anew**, because `tailscale up`
always expects the whole set and returns anything unnamed to its default. If the
node was set up by hand, a look at `tailscale debug prefs` beforehand is worth
it.

## Uninstall

1. Back up `/etc/sysctl.d/99-tailscale.conf` and `/var/lib/tailscale` to
   `/root/tailscale-uninstall-<time>.tar.gz`
2. `tailscale logout`, `tailscale down`
3. Stop and disable `tailscaled`
4. Remove the sysctl drop-in — **IP forwarding is not reset to 0**, because
   Docker, WireGuard or something else may need it too. It stays in effect until
   the next reboot.
5. If you say so: the ufw rules for `tailscale0` (deleted back to front, so the
   numbers do not shift)

The package and the state stay. To remove everything:

```bash
apt purge tailscale
rm -rf /var/lib/tailscale /etc/apt/sources.list.d/tailscale.list \
       /usr/share/keyrings/tailscale-archive-keyring.gpg
```

> The node stays registered in the **admin console** and has to be deleted there
> separately.

> If you reach the server only over Tailscale, logging out or uninstalling cuts
> off your own connection.

## Tailscale or WireGuard?

Both can run in parallel, they do not interfere with each other.

| | WireGuard (`wg-manager`) | Tailscale |
|---|---|---|
| Key management | yourself, per peer | centrally through the account |
| Reachability | the server needs an open UDP port | builds up from the inside, works through NAT |
| Topology | star onto this server | mesh between all nodes |
| Access control | routing and firewall | ACLs in the admin console |
| Dependency | none | Tailscale's coordination servers |

Rule of thumb: a handful of fixed peers and no wish for an external dependency →
WireGuard. Many changing devices, NAT on both sides, central rights management →
Tailscale.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Key for `<distro>/<codename>` cannot be fetched | The codename does not match the repo (with derivatives such as Linux Mint, for instance) — give the base distribution's one |
| `tailscale up` aborts with a pointer to `--reset` | The node carries a non-default setting that was not mentioned again — a tag, usually. The script offers `--reset` right there; accept it, or decline and enter the tag at the tag question |
| The auth key file in `/tmp` is gone afterwards | Intended: it is deleted as soon as `tailscale up` has read it. A valid key must not stay behind in `/tmp` |
| A subnet route is not used | Not approved in the admin console, or `--accept-routes` is missing on the other side |
| The exit node does not appear | Approval in the admin console as well; also check IP forwarding |
| DNS broken after logging in | `--accept-dns` took over `/etc/resolv.conf`; switch it off in menu item 3 |
| Connection only over a relay (`relay` in `tailscale status`) | No direct path possible; it works, but it is slower |
| Not connected after a reboot | Check `systemctl enable tailscaled` |
