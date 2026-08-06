# wg-manager.sh — WireGuard management

Sets up a WireGuard server and manages client configs. Server and clients live
in separate files, and `wg0.conf` is assembled from them.

## Requirements

- Debian or Ubuntu, root rights
- the `wireguard` package is installed when needed
- optionally `qrencode` for QR codes

## Usage

```bash
sudo ./wg-manager.sh              # menu
sudo ./wg-manager.sh --uninstall  # remove the interface and the configuration
```

## Menu

Without a server config there is only "Create the server config" and "Remove
leftovers". After that:

| Item | Effect |
|---|---|
| 1 | Edit the server config (address, port, endpoint) |
| 2 | Manage client configs |
| 3 | Status (`wg show`) |
| 4 | Restart the interface |
| 5 | Uninstall |
| 6 | Quit |

Client submenu: create, show, edit, delete.

## Layout

```
/etc/wireguard/
  wg0-interface.conf     the server's [Interface] part
  peers.d/<name>.conf    one [Peer] block per client
  clients/<name>.conf    the finished config for the device
  wg0.conf               assembled from interface + peers.d
  server_private.key     server key (0600)
  server_public.key
  server_endpoint.txt    public IP or hostname
```

Why separate? Creating or deleting a client this way means: write *one* file and
regenerate `wg0.conf`. No cutting around in one big configuration file, no
broken blocks if a run is interrupted.

## Creating the server

| Question | Default |
|---|---|
| Server tunnel IP | `10.10.0.1` |
| Listen port (UDP) | `51820` |
| Public IP or hostname | required |

After that: generate a key pair (if there is none yet), build `wg0.conf`,
`systemctl enable wg-quick@wg0`, bring the interface up and — if ufw is active —
open the UDP port.

## Clients

When creating one, the next free tunnel IP is suggested (derived from the
`AllowedIPs` of the existing peers). Two files are produced:

```ini
# peers.d/laptop.conf — goes into the server config
[Peer]
PublicKey = ...
AllowedIPs = 10.10.0.2/32

# clients/laptop.conf — goes onto the device
[Interface]
Address = 10.10.0.2/24
PrivateKey = ...
[Peer]
PublicKey = <server>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.10.0.1/32
PersistentKeepalive = 25
```

The finished config is displayed; if `qrencode` is installed, you can have it as
a QR code for a phone.

`AllowedIPs` in the client points at the server IP only — so **only** tunnel
traffic is routed, not the client's entire internet traffic. If you want a full
tunnel, change that on the device to `0.0.0.0/0`.

`PersistentKeepalive = 25` keeps connections open through NAT.

## Changes while running

`wg0.conf` is regenerated and applied with `wg syncconf` — existing tunnels do
**not** drop. Only "Restart the interface" and changing the server config really
bring the interface up again.

If you change the endpoint or the port, all files in `clients/` are updated
automatically (`Endpoint` and `AllowedIPs`). Configs already distributed to the
devices of course have to be renewed by you.

## Client list

```
NAME                   IP               HANDSHAKE
laptop                 10.10.0.2        34s ago
phone                  10.10.0.3        -
```

The handshake comes from `wg show wg0 latest-handshakes`. A `-` means: no
connection since the interface was last started.

## State and data

Everything lives under `/etc/wireguard`, that is, in the service's directory —
but in this tool's layout. Nothing sits next to the script.

**This is the one place where putting the tool on an existing installation does
not work without preparation:** `wg0-interface.conf` plus `peers.d/*.conf` are
assembled into `wg0.conf` on every change, **overwriting** it. A hand-written
`wg0.conf` does not survive that.

Moving over from an existing configuration:

```bash
cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.before
mkdir -p /etc/wireguard/peers.d /etc/wireguard/clients

# [Interface] block (Address, ListenPort, PrivateKey) into:
#   /etc/wireguard/wg0-interface.conf
# each [Peer] block separately into:
#   /etc/wireguard/peers.d/<name>.conf
# the server's public address into:
#   /etc/wireguard/server_endpoint.txt
# the server keys into:
#   /etc/wireguard/server_private.key  and  server_public.key
```

After that it fits, and from then on `wg0.conf` is generated rather than
maintained.

The reason for the split: creating or deleting a client this way means writing
*one* file instead of cutting blocks out of one big file. An interrupted run
therefore cannot leave the configuration half dismantled.

## Uninstall

1. `wg-quick down wg0`, `systemctl disable wg-quick@wg0`
2. Remove the ufw rule for the UDP port (asked; the port is read out **before**
   the config is deleted)
3. Remove `wg0.conf`, `wg0-interface.conf`, `server_endpoint.txt`
4. Client configs and peers if you say so
5. The server key pair if you say so
6. Delete `/etc/wireguard` only if it is empty afterwards

Beforehand the whole directory is backed up to
`/root/wireguard-uninstall-<time>.tar.gz`. **Other interfaces (`wg1` …) stay
untouched.** The `wireguard` package stays installed.

> **If you reach the server only over the tunnel, this cuts off your own
> connection.** Make sure of a second way in first.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No handshake | UDP port not open (firewall or router), or the wrong endpoint in the client config |
| Handshake there, but no traffic | `AllowedIPs` do not fit — they have to match each other on both sides |
| `wg-quick up` fails with "address in use" | The interface is already running; menu item 4 restarts it cleanly |
| A client does not come back after a server restart | `PersistentKeepalive` is missing in the client config |
| Two clients with the same IP | Assigned by hand while editing; check `AllowedIPs` in `peers.d/` |
| Other machines in the tunnel network are unreachable | That would need IP forwarding and matching routes — this tool deliberately does not set that up, [iptables-router.md](iptables-router.md) does |
