# ufw-manager.sh — firewall management

CRUD on ufw rules: create, replace, delete, plus application profiles, defaults
and logging. There is deliberately **no rule file of its own** — ufw itself is
the data store, and the menu always shows `ufw status numbered`.

## Requirements

- Debian or Ubuntu, root rights
- `ufw`; if it is missing, the script offers to install it at startup

## Usage

```bash
sudo ./ufw-manager.sh              # menu
sudo ./ufw-manager.sh --setup      # baseline (see below)
sudo ./ufw-manager.sh --status     # ufw status verbose
sudo ./ufw-manager.sh --uninstall  # reset rules / switch the firewall off
```

## Menu

| Item | Effect |
|---|---|
| 0 | Baseline setup (see below) |
| 1 | Create a rule (wizard) |
| 2 | Edit a rule = replace it |
| 3 | Delete a rule |
| 4 | Make SSH reachable only over the VPN (WireGuard or Tailscale) |
| 5 | Show all rules — stored, and whether they are enforced |
| 6 | Show application profiles (`ufw app list/info`) |
| 7 | Activate or deactivate the firewall |
| 8 | Defaults (`default incoming/outgoing`) |
| 9 | Logging (off/low/medium/high) |
| 10 | Uninstall |
| 11 | Quit |

## Baseline (`--setup`)

The firewall for a fresh server in one pass:

1. Warns when firewalld or nftables is active (two rule sets would clash) and
   when Docker is installed (published container ports bypass ufw).
2. Lists every service listening on the network (not only on loopback).
3. Sets `default deny incoming`, `allow outgoing`.
4. **SSH first:** the port of this session gets a rate-limited rule (`limit`)
   before anything is enabled. An existing SSH rule — also a tailnet-only one
   on `tailscale0` — is left as it is.
5. Offers 80/tcp and 443/tcp (web server, HTTPS certificates); the default is
   yes when something listens on 80 or 443.
6. Lists the listening services that are not allowed yet and asks which of
   them have to be reachable from the whole internet (numbers). Admin and
   monitoring ports belong on the VPN, not here.
7. Further ports for services set up later (`8443/tcp 51820/udp ...`).
8. Optionally 41641/udp for direct Tailscale connections.
9. Enables ufw.

Running it again changes nothing that is already allowed. Values fixed by a
caller: see [Presets and batch mode](#presets-and-batch-mode).

Locking SSH to the tailnet is part of `ssh-setup.sh --setup`; menu item 4 here
stays for WireGuard or a manual two-step lock.

## Creating a rule

The wizard asks, in order:

| Question | Options |
|---|---|
| Action | `allow` / `deny` / `reject` / `limit` |
| Direction | incoming / outgoing |
| Interface | e.g. `wg0`, empty = all |
| Target | port or range / application profile / everything |
| Protocol | tcp / udp / both |
| Source | IP or CIDR, empty = from anywhere |
| Destination IP | empty = all addresses of this host |
| Comment | shows up in `ufw status` |

After that **the finished ufw command is shown and only run once confirmed**. So
you see exactly what happens:

```
ufw allow 443/tcp
ufw limit 22/tcp comment SSH
ufw allow 6000:6010/tcp
ufw allow from 10.10.0.0/24 to any port 5432 proto tcp comment Postgres
ufw deny from 203.0.113.7 to any comment Spammer
ufw allow in on wg0 from any to any port 22 proto tcp
```

Two peculiarities of ufw that the script catches:

- **A port range always needs a protocol.** If you pick "both", `tcp` is used
  automatically and you are told so.
- **With an interface, ufw only understands the long form.** As soon as
  `in on <iface>` is involved, `from … to … port … proto …` is built instead of
  the short form.

For SSH, `limit` is the better choice than `allow`: at most six connections in
30 seconds per source IP, which slows brute force down without extra software.

## Editing and deleting a rule

ufw cannot change rules. "Editing" therefore means: **create the new rule first,
then delete the old one** — in that order, so that no gap ever opens up. Because
creating the new rule can shift the numbering, the old rule is afterwards
resolved again by its **text** and only deleted when it is unambiguously found.

Deleting carries the same distrust: the rule is shown in plain text, and
immediately before deleting it is checked again whether the same text still sits
under that number. If not, nothing happens.

If the rule concerns the port of the running SSH session, there is an extra
warning.

## SSH only over the VPN (item 4)

Works with **WireGuard or Tailscale** — the recipe first asks which tunnel
should carry SSH, then runs in two stages, so that you do not lock yourself
out.

**Stage 1** — on the first call:

1. Ask for the tunnel (WireGuard → `wg0`, Tailscale → `tailscale0`, interface
   changeable) and check that the interface exists
2. Tunnel-specific checks, see below
3. Create `ufw allow in on <iface> to any port <sshport> proto tcp`
4. **Leave the existing open SSH rule in place**

**Stage 2** — on the second call, after the login through the tunnel has been
tested: the recipe recognises the existing interface rule and offers to delete
the open SSH rule.

The tunnel-specific checks in stage 1:

- **WireGuard:** the WireGuard port is read from
  `/etc/wireguard/wg0-interface.conf` and checked to be open in ufw. If it is
  not, the rule is offered — **if you decline, the recipe aborts.** Without an
  open UDP port the tunnel never comes up, and with it nothing else does
  either. It is also checked whether any peers are configured at all.
- **Tailscale:** checked are `tailscaled` running and other devices in the
  tailnet. Tailscale needs **no open inbound port** — connections are
  established from the inside, falling back to Tailscale's relays (DERP) where
  no direct path exists. Reachable, just slower. The recipe therefore
  **offers** to open the Tailscale UDP port (default 41641) so that peers
  connect directly instead of via relay — noticeably faster. Opening it is OK:
  the port speaks exclusively WireGuard, and packets that are not
  authenticated with a key of your tailnet are discarded. Declining does not
  abort — SSH over the tunnel works either way, at relay speed where no direct
  path exists.

Why an interface rule and not a source CIDR? `in on wg0` binds to the interface.
A rule on the tunnel subnet would depend on sender IPs, which can be forged if
no reverse path filter is in effect.

## Show all rules (item 5)

`ufw status` is silent while the firewall is off — the stored rules only show
through `ufw show added`. This view puts both side by side:

- a header stating clearly whether the firewall is **active** (the rules are
  enforced) or **not active** (rules are stored, but not one of them is in
  effect and every listening service is openly reachable)
- the **stored rules** from `ufw show added` — visible in both states
- while active, additionally `ufw status verbose` — what is enforced right
  now, including defaults and logging

## Switching the firewall on (item 7)

Before `ufw enable` it is checked whether there is an `ALLOW` or `LIMIT` rule
for the SSH port (the application profile `OpenSSH` counts as well). If it is
missing, `ufw limit <port>/tcp` is offered. If you decline **and** are sitting on
an SSH connection yourself, a second, unmistakable question follows — with
`default deny incoming`, an `enable` without an SSH rule is a guaranteed
lockout.

The SSH port is taken from `$SSH_CONNECTION`, failing that from `sshd -T`, and
in case of doubt 22.

## Files changed

| Path | Contents |
|---|---|
| `/etc/ufw/` | the rules themselves (`user.rules`, `user6.rules`) |
| `/etc/default/ufw` | defaults and logging |
| `/var/log/ufw.log` | the log, if switched on |

## State and data

**No state of its own — ufw is the data store.** The menu shows
`ufw status numbered`, changes go out as `ufw` commands, and there is neither a
configuration file next to the script nor a rule list beside it.

That makes the tool freely usable on top of an existing firewall: rules that are
already there show up in the list immediately, no matter who created them, and
you can go back to working with `ufw` by hand at any time without anything
drifting apart. A second window issuing `ufw` calls does no harm either — before
every delete the script checks whether the same rule still sits under that
number.

## Uninstall

This tool creates nothing of its own, it manages ufw. "Uninstalling" therefore
means undoing ufw's state — both parts asked for separately:

- **Reset all rules** (`ufw --force reset`). ufw itself leaves dated copies of
  the previous rules in `/etc/ufw` and switches itself off in the process.
- **Deactivate ufw**

Beforehand, `/etc/ufw` and `/etc/default/ufw` are backed up to
`/root/ufw-uninstall-<time>.tar.gz`. The package stays installed.

For individual rules, menu item 3 is the right way, not the uninstall.

## Presets and batch mode

**A `DEFAULT_*` that is set is taken without a question; unset ones are asked
(batch mode: default).** A set (non-empty) variable is a fixed value, a
*preset*: its question is not asked — interactively neither — and the tool
prints one line instead, e.g. `Open 80/tcp and 443/tcp ...? -> yes (preset)`.
An invalid preset (`DEFAULT_OPEN_WEB=maybe`, `DEFAULT_APP_PORTS="80/xyz"`) is
an error: message on stderr, exit 1, nothing changed — all presets are checked
before the first rule is touched.

`BATCH=1` (set by `base-setup.sh`) runs `--setup` without a single question:
the questions without a preset take their built-in default and the tool prints
one line saying what it took. Nothing waits for input. The SSH rule for the
current port is always created before ufw is switched on, so the baseline
cannot lock you out.

| Variable | Values | Built-in default |
|---|---|---|
| `DEFAULT_SETUP_FIREWALL` | Y / N — set up the firewall when ufw is not active | Y |
| `DEFAULT_IGNORE_OTHER_FW` | Y / N — set up ufw although firewalld/nftables runs | N (abort) |
| `DEFAULT_OPEN_WEB` | Y / N — open 80/tcp and 443/tcp | Y when something listens there, else N |
| `DEFAULT_ALLOW_LISTENERS` | listening services to allow publicly, space-separated `port/proto`, e.g. `"25/tcp 51820/udp"`; `-` = none | none |
| `DEFAULT_APP_PORTS` | further public ports, e.g. `"8443/tcp 6000:6010/tcp"`; `-` = none | none |
| `DEFAULT_OPEN_TS_PORT` | Y / N — open 41641/udp when `tailscale0` exists | Y in batch mode, N interactively |

Y / N also accept yes / no / j / ja / 1 / 0 / true / false. An entry of
`DEFAULT_ALLOW_LISTENERS` that is not listening (or is already allowed) is
skipped with a note — ports for services set up later belong in
`DEFAULT_APP_PORTS`.

```bash
BATCH=1 DEFAULT_OPEN_WEB=Y DEFAULT_APP_PORTS="51820/udp" ./ufw-manager.sh --setup
DEFAULT_OPEN_WEB=Y DEFAULT_APP_PORTS=- ./ufw-manager.sh --setup   # asks only the rest
```

Exit codes: 0 done, 2 left as it is, 1 failed.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No connection after `enable` | No SSH rule. Through the hoster's console: `ufw disable` or `ufw allow 22/tcp` |
| Rule created, but has no effect | Order: ufw evaluates from top to bottom, the first matching rule wins. Check `ufw status numbered` |
| The number deleted was the wrong rule | The numbering changed between display and deletion — the script catches that and says so; look at the list again |
| Docker container reachable despite `deny` | Docker writes its own iptables rules, bypassing ufw. That is known Docker behaviour and cannot be fixed from ufw's side |
| IPv6 rules missing | Check `IPV6=yes` in `/etc/default/ufw` |
