# iptables-router.sh — routing between networks

Passes traffic **through** this server: from the VPN tunnel into a network
behind a peer, from the tunnel out to the internet, or from outside to a machine
that only exists behind the tunnel. Everything it writes lives in three chains
of its own, so no foreign rule is ever touched.

The typical case: this server and a PC at home are joined by WireGuard. The two
of them can already reach each other — the tunnel does that on its own. What
does **not** work yet is everything one hop further: the printer in the home
network, the NAS, a second peer. That is what this tool is for.

```
  [this server] ==== wg0 ==== [PC B] ---- 192.168.178.0/24
   10.10.0.1              10.10.0.2       the machines behind it
```

## Requirements

- Debian or Ubuntu, root rights
- `iptables`; if it is missing, the script offers to install it at startup
  (the nftables backend, `iptables-nft`, works — the `iptables` command is what
  counts)
- a tunnel that is already up, e.g. from [wg-manager.md](wg-manager.md)
- IPv4. IPv6 (`ip6tables`) is deliberately not touched.

## Usage

```bash
sudo ./iptables-router.sh              # menu
sudo ./iptables-router.sh --apply      # rebuild the rules (what the boot unit runs)
sudo ./iptables-router.sh --clear      # remove the rules, keep the configuration
sudo ./iptables-router.sh --status     # settings, routes, counters
sudo ./iptables-router.sh --uninstall  # uninstall
```

`--apply` is idempotent: it flushes its own three chains and builds them again
from the configuration. It can be run at any time, as often as you like.

## Menu

| Item | Effect |
|---|---|
| 1 | Manage routes (create, edit, switch on/off, delete) |
| 2 | Recipe: reach a network behind a VPN peer |
| 3 | Apply rules now |
| 4 | Check |
| 5 | Show the rules (generated and active) |
| 6 | Settings (interfaces, forwarding, boot unit) |
| 7 | Remove the rules from the running system (keep the configuration) |
| 8 | Uninstall |
| 9 | Quit |

The header line shows what actually is: WAN and tunnel interface, whether
`net.ipv4.ip_forward` is on, whether the rules are hooked into `FORWARD` at all,
and whether the boot unit is installed.

## First-time setup

| Question | Default |
|---|---|
| Interface towards the internet | from the default route, e.g. `eth0` |
| Tunnel interface | the first `wg*`/`tun*`/`tap*`, e.g. `wg0` |
| Enable IP forwarding permanently | yes |
| Write the rules back after a reboot | yes |

## The four route types

A *route* here is one intent, stored in one file, translated into one to three
iptables rules.

### `link` — two networks may talk to each other

The site-to-site case. Network A on this side, network B on the far side.

```
iptables -t filter -A IPTR-FORWARD -o wg0 -s 10.10.0.0/24 -d 192.168.178.0/24 -j ACCEPT
iptables -t filter -A IPTR-FORWARD -i wg0 -s 192.168.178.0/24 -d 10.10.0.0/24 -j ACCEPT
```

**NAT towards B** is asked separately. With it, the packets arrive over there
with this server's address as the sender, so the far side does not need to know
the way back to A. Without it, the real source addresses survive — nicer in the
logs over there, but then the return route has to exist. If A is the tunnel
network itself, the peer knows it anyway and NAT is unnecessary; if A is a
second network of this server, NAT usually saves an argument with the far side's
router.

### `hub` — the peers of one tunnel may talk to each other

WireGuard passes nothing between two peers on its own: everything arrives on
`wg0` and would have to leave through `wg0` again, and that is forwarding.

```
iptables -t filter -A IPTR-FORWARD -i wg0 -o wg0 -j ACCEPT
```

Each peer also has to carry the whole tunnel network in its `AllowedIPs`, not
just the server address.

### `exit` — a network reaches the internet through this server

```
iptables -t filter -A IPTR-FORWARD -i wg0 -o eth0 -s 10.10.0.0/24 -j ACCEPT
iptables -t nat    -A IPTR-POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
```

On the client this only takes effect with `AllowedIPs = 0.0.0.0/0`.

### `publish` — a port of this server leads to a machine behind the tunnel

```
iptables -t nat    -A IPTR-PREROUTING  -i eth0 -p tcp --dport 8443 -j DNAT --to-destination 192.168.178.20:443
iptables -t filter -A IPTR-FORWARD -p tcp -d 192.168.178.20 --dport 443 -j ACCEPT
iptables -t nat    -A IPTR-POSTROUTING -p tcp -d 192.168.178.20 --dport 443 -j MASQUERADE
```

The masquerading in the third line is not optional in practice: without it the
target answers the client directly, past this server, and the connection never
comes up. The rule is nevertheless asked about, because in a setup where the
target routes everything back through the tunnel anyway you do not need it.

The port still has to be open in the firewall — `publish` writes nothing into
ufw. DNAT only applies to packets **arriving from outside**; a request from this
server to its own port 8443 does not go through `PREROUTING`.

## The recipe (menu item 2)

Menu item 2 walks through the case in the picture above and checks the three
things that have to fit together — the tool can only see two of them, and the
third is spelled out:

1. **The route.** Is the far network in the peer's `AllowedIPs`? Without it
   WireGuard drops the packets and there is no kernel route either. If it is
   missing, the script offers to add it: `wg set` for the running interface, and
   the line in `/etc/wireguard/peers.d/<name>.conf`, so it survives the next
   regeneration by `wg-manager`.
2. **Forwarding on this server.** `net.ipv4.ip_forward` and the `link` route.
3. **The way back on the far side.** That happens over there and is printed as
   concrete commands — see the next section.

## What the far side has to do

This server can only route as far as the peer. The last stretch — from the peer
into its LAN and back — is the peer's job:

```bash
# on the peer, if it is a Linux machine
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o <lan-if> -j MASQUERADE
```

With that, the machines in the LAN see the traffic as coming from the peer
itself and need no route of their own. Without that NAT the LAN router needs a
static route `10.10.0.0/24 via <the peer's LAN address>`.

And the peer's WireGuard config has to list the networks of this side under
`AllowedIPs`, otherwise it does not even send the replies into the tunnel.

**A Windows or macOS peer does not route by default.** Then only the peer itself
is reachable, not the machines behind it.

## Files created

```
iptables-router.conf          settings, next to the script
var/routes.d/<name>.conf      one file per route
/etc/systemd/system/iptables-router.service
/etc/sysctl.d/99-iptables-router.conf
```

A route file, one for every type, with the fields that do not apply left empty:

```ini
NAME="homeoffice"
TYPE="link"          # link | hub | exit | publish
NET_A="10.10.0.0/24"
NET_B="192.168.178.0/24"
IF_A=""
IF_B="wg0"
NAT="b"              # none | a | b | both
PROTO=""; LPORT=""; DEST=""; DPORT=""
ENABLED="1"
NOTE="via peer 10.10.0.2"
```

## The three chains

```
filter  IPTR-FORWARD       jumped to from FORWARD, position 1
nat     IPTR-PREROUTING    jumped to from PREROUTING, position 1
nat     IPTR-POSTROUTING   jumped to from POSTROUTING, position 1
```

Own chains for two reasons. A rebuild only has to flush these three — foreign
rules from ufw, Docker or `netfilter-persistent` cannot be hit by it. And
`iptables -n -v -L IPTR-FORWARD` shows in one screen what this tool has done,
with a packet counter per rule.

`IPTR-FORWARD` begins with one rule for all routes:

```
-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

Without it every rule would have to be written twice; a stateless `ACCEPT` in
one direction alone does not carry a single TCP connection.

**Position 1 is not decoration.** ufw rejects forwarded packets at the end of
its chains, and Docker puts rules of its own at the top of `FORWARD`. So
`--apply` removes an existing jump first and inserts it again in front.

## Alongside ufw and Docker

The tool works next to both, with one thing to know:

> **`ufw reload`, `ufw enable` and a Docker restart rebuild `FORWARD`** and
> throw the jump out with it. Afterwards: `systemctl restart iptables-router`
> (or menu item 3).

`DEFAULT_FORWARD_POLICY` in `/etc/default/ufw` does **not** have to be changed —
`IPTR-FORWARD` sits in front of ufw's chains and accepts before ufw gets to
decide. Menu item 4 shows whether it really is in front.

## State and data

Settings and routes sit next to the script (`iptables-router.conf`,
`var/routes.d/`), the rules themselves in the kernel. Nothing is written into
`/etc/iptables` and `netfilter-persistent` is not used: rules from a `.rules`
file and rules from this tool would be two sources for the same chains.

Instead a systemd unit:

```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/path/to/iptables-router.sh --apply
ExecStop=/path/to/iptables-router.sh --clear
```

`After=` includes `wg-quick@wg0.service` when the tunnel interface is a
WireGuard one, plus `ufw.service` — so this tool has the last word over the
`FORWARD` chain after a reboot.

The unit therefore has a real state: `systemctl stop iptables-router` removes
the rules, `start` writes them back. **The script must stay where it is** — the
unit calls it by its absolute path, like the cron entries of the monitors do.

## Uninstall

1. Remove the three chains and their jumps
2. Remove the boot unit (`disable`, delete the file, `daemon-reload`)
3. Switch IP forwarding off and delete `99-iptables-router.conf` (asked —
   careful, Docker and Tailscale may need forwarding as well)
4. Delete the configuration
5. Delete the routes (asked)

Beforehand everything is backed up to
`/root/iptables-router-uninstall-<time>.tar.gz`. Rules from other sources — ufw,
Docker, `netfilter-persistent` — stay untouched, no package is removed.

> **Afterwards nothing is routed through this server any more.** If you reach
> this machine over a path that runs through these rules, that path is gone.

## Troubleshooting

| Symptom | Cause |
|---|---|
| All counters at zero | Nothing arrives. This is a routing problem, not a rule problem — check `AllowedIPs` and menu item 4 |
| The peer answers, machines behind it do not | The way back is missing on the far side: NAT on the peer, or a static route in the LAN router |
| Worked, gone after `ufw reload` | The jump was thrown out of `FORWARD`. `systemctl restart iptables-router` |
| Worked, gone after a reboot | The boot unit is not installed — menu item 6 |
| Worked, gone after a Docker restart | Same as with ufw: Docker rebuilds `FORWARD` |
| Counters go up, still nothing arrives | `net.ipv4.ip_forward` is off, or the reply takes a different route back (asymmetric routing) |
| `publish`: the port is unreachable from outside | The port is not open in ufw, or the request comes from this server itself (`PREROUTING` does not see it) |
| Two peers cannot see each other | A `hub` route is missing, or the peers' `AllowedIPs` only carry the server address instead of the whole tunnel network |
| A rule is rejected on `--apply` | The interface or the address is wrong; the rejected command is printed in full |
| IPv6 does not work | Intended: only IPv4 is handled, `ip6tables` is not touched |
