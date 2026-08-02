# Setting up a Linux server by hand

A guide without any helper script: nothing but standard tools, as the
distribution ships them or as their makers document them. All the commands are
meant to be copied and are run as `root` (otherwise put `sudo` in front).

Basis: **Debian 12/13 or Ubuntu 22.04/24.04** with systemd.

## Order

Three parts, and that is also the order: **first secure access, then establish
the notification path, then put applications on top.**

**Part 1 — Secure access**

| | Section | |
|---|---|---|
| 1 | [Base setup](#1-base-setup) | timezone, hostname, packages |
| 2 | [Users and SSH keys](#2-users-and-ssh-keys) | |
| 3 | [Hardening SSH](#3-hardening-ssh) | drop-in, port change, fail2ban |
| 4 | [Firewall with ufw](#4-firewall-with-ufw) | |
| 5 | [VPN: WireGuard](#5-vpn-wireguard) | **or** |
| 6 | [VPN: Tailscale](#6-vpn-tailscale) | |

**Part 2 — Monitor operation**

| | Section | |
|---|---|---|
| 7 | [Sending mail](#7-sending-mail) | msmtp |
| 8 | [Automatic updates](#8-automatic-updates) | unattended-upgrades |
| 9 | [Monitoring with built-in tools](#9-monitoring-with-built-in-tools) | journald, cron, df |

**Part 3 — Applications**

| | Section | |
|---|---|---|
| 10 | [Reverse proxy: Caddy](#10-reverse-proxy-caddy) | **or** |
| 11 | [TCP relay with nginx](#11-tcp-relay-with-nginx) | |
| 12 | [Docker](#12-docker) | |
| 13 | [Keeping working copies up to date with git](#13-keeping-working-copies-up-to-date-with-git) | |

Why this order:

- **Access first.** Login and firewall are in place before any service listens.
  SSH before the firewall, because you first have to know which port you are
  leaving open.
- **Then the notification path.** The mailer, before anything is set up that
  sends reports or errors. An update run whose report reaches nobody is an
  unattended run.
- **Then the applications.** Reverse proxy, containers, code — everything the
  server does towards the outside.

---

## Part 1 — Secure access

Who gets onto the machine and by which route. For everything in this part:
**keep a second SSH session open.**

---

## 1. Base setup

```bash
apt update && apt upgrade -y

# Timezone and time synchronisation
timedatectl set-timezone Europe/Berlin
timedatectl set-ntp true
timedatectl        # check: "System clock synchronized: yes"

# Hostname
hostnamectl set-hostname server.example.com
# in /etc/hosts the name should point at 127.0.1.1:
#   127.0.1.1   server.example.com server
```

Tools that experience says you install afterwards anyway:

```bash
apt install -y nano vim screen tmux htop curl wget git unzip rsync tree ncdu \
               bash-completion ca-certificates dnsutils
```

### Locale

When programs complain about `Setting locale failed`:

```bash
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
```

### Shell comfort (optional)

Colours and aliases system-wide, without touching existing files:

```bash
cat > /etc/profile.d/zz-local.sh <<'EOF'
case $- in *i*) ;; *) return 0 ;; esac
[ -z "${BASH_VERSION:-}" ] && return 0

command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b)"
alias ls='ls --color=auto'
alias ll='ls -alFh'
alias grep='grep --color=auto'
export HISTSIZE=5000 HISTCONTROL=ignoreboth HISTTIMEFORMAT='%F %T  '
shopt -s histappend checkwinsize 2>/dev/null

if [ "$(id -u)" -eq 0 ]; then
    PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
else
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
fi
EOF
```

`/etc/profile.d`, however, is only read by a **login** shell. So that
`ssh host command`, `su` and screen get the same, additionally in
`/etc/bash.bashrc`:

```bash
cat >> /etc/bash.bashrc <<'EOF'
[ -r /etc/profile.d/zz-local.sh ] && . /etc/profile.d/zz-local.sh
EOF
```

For vim one line is particularly worth it — from version 8.2 the mouse is on by
default, and vim then jumps into visual mode when you select, so you can no
longer copy out of the terminal:

```bash
cat > /etc/vim/vimrc.local <<'EOF'
syntax on
set number ruler hlsearch incsearch ignorecase smartcase
set tabstop=4 shiftwidth=4 expandtab
set background=dark
set mouse=
EOF
```

---

## 2. Users and SSH keys

On **your own machine** (not on the server) create a key, if there is none yet:

```bash
ssh-keygen -t ed25519 -C "firstname@workstation"
```

Create a user on the server and store the public key:

```bash
adduser --gecos "" admin
usermod -aG sudo admin        # Debian: sudo, some systems: wheel

install -d -m 700 -o admin -g admin /home/admin/.ssh
# paste the contents of ~/.ssh/id_ed25519.pub:
nano /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown admin:admin /home/admin/.ssh/authorized_keys
```

More convenient from your own machine, as long as password login still works:

```bash
ssh-copy-id admin@server.example.com
```

**Test now** whether logging in with the key works — before password login is
switched off in the next step:

```bash
ssh admin@server.example.com
```

---

## 3. Hardening SSH

Do not edit `/etc/ssh/sshd_config`, create a drop-in instead. That survives
package updates and can be undone by removing one file.

First check that the include line exists at all:

```bash
grep -n 'Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config
```

If nothing comes back, it has to be added — **right at the top**, because with
sshd the directive read *first* wins:

```bash
sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
```

Then the drop-in:

```bash
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
Port 22
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
```

Check and apply:

```bash
sshd -t                          # syntax check, has to stay silent
systemctl restart ssh            # on some systems: sshd
```

**Verify that the values really arrive:**

```bash
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)'
```

If something other than the drop-in shows up there, a directive further up in
the `sshd_config` wins — comment that line out.

### Changing the port

Two traps, both of which otherwise lead to a lockout.

**First: the order.** Always open the firewall first, then move sshd:

```bash
ufw allow 2222/tcp               # the NEW port first
sed -i 's/^Port .*/Port 2222/' /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t && systemctl restart ssh
```

Port 22 stays open alongside for now. Only after a successful test:

```bash
ssh -p 2222 admin@server.example.com      # in a SECOND terminal
ufw delete allow 22/tcp                   # only once that worked
```

**Second: socket activation.** From Ubuntu 22.10 on, sshd starts through
`ssh.socket` and **ignores the `Port` directive entirely**. Check:

```bash
systemctl is-enabled ssh.socket
```

If it says `enabled`, the port has to be set on the socket:

```bash
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/10-port.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=2222
EOF
systemctl daemon-reload
systemctl restart ssh.socket
```

The empty first `ListenStream=` line is crucial — without it systemd *adds* the
new port instead of replacing port 22.

Check what is actually being listened on:

```bash
ss -tlnp | grep sshd
```

### fail2ban (optional)

Blocks IP addresses after several failed attempts. With key-only login it is
less urgent, but it keeps the log clean.

```bash
apt install -y fail2ban
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl restart fail2ban
fail2ban-client status sshd
```

---

## 4. Firewall with ufw

```bash
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH'        # limit instead of allow: slows brute force
ufw enable
```

> `ufw enable` **without** a rule for the SSH port locks the running connection
> out as soon as you reconnect. The `limit` line always comes first.

`limit` allows at most six connections in 30 seconds per source IP.

### Managing rules

```bash
ufw status numbered                   # with the numbers you need for deleting
ufw status verbose                    # including defaults and logging

ufw allow 443/tcp
ufw allow 6000:6010/tcp               # a port range always needs a protocol
ufw allow from 10.10.0.0/24 to any port 5432 proto tcp comment 'Postgres internal'
ufw deny from 203.0.113.7
ufw allow in on wg0 to any port 22 proto tcp comment 'SSH over VPN only'

ufw delete 3                          # by the number from 'status numbered'
ufw delete allow 443/tcp              # or by the rule text
```

The numbers shift after every delete — so look at `ufw status numbered` again
before every `ufw delete <n>`.

Rules cannot be changed. "Changing" means: create the new rule, then delete the
old one — in that order, so that no gap opens up.

### Application profiles

```bash
ufw app list
ufw app info OpenSSH
ufw allow OpenSSH
```

### Logging

```bash
ufw logging low                       # off | low | medium | high
tail -f /var/log/ufw.log
```

### Making SSH reachable only over the VPN

First add the narrow rule, then test, and **only then** remove the open one:

```bash
ufw allow 51820/udp comment 'WireGuard'          # has to stay open!
ufw allow in on wg0 to any port 22 proto tcp comment 'SSH via VPN'
# now log in through the tunnel and check that it works
ufw delete allow 22/tcp
```

The VPN port itself has to stay open — otherwise the tunnel never comes up and
you reach nothing at all any more.

---

## 5. VPN: WireGuard

```bash
apt install -y wireguard qrencode
```

### Server

```bash
umask 077
mkdir -p /etc/wireguard && cd /etc/wireguard
wg genkey | tee server_private.key | wg pubkey > server_public.key

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server_private.key)
EOF

chmod 600 /etc/wireguard/wg0.conf
ufw allow 51820/udp
systemctl enable --now wg-quick@wg0
wg show
```

### Creating a client

A separate key pair for every client:

```bash
umask 077
wg genkey | tee /etc/wireguard/laptop_private.key | wg pubkey > /etc/wireguard/laptop_public.key
```

Register the peer with the server — while it runs, without interrupting
existing tunnels:

```bash
wg set wg0 peer "$(cat /etc/wireguard/laptop_public.key)" allowed-ips 10.10.0.2/32
wg-quick save wg0          # writes the peer permanently into wg0.conf
```

The configuration for the device:

```bash
cat > /root/laptop.conf <<EOF
[Interface]
Address = 10.10.0.2/24
PrivateKey = $(cat /etc/wireguard/laptop_private.key)

[Peer]
PublicKey = $(cat /etc/wireguard/server_public.key)
Endpoint = vpn.example.com:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

qrencode -t ansiutf8 < /root/laptop.conf     # for a phone
```

`AllowedIPs` in the client determines what goes through the tunnel:
`10.10.0.0/24` only the tunnel network, `0.0.0.0/0` all traffic.
`PersistentKeepalive` keeps NAT mappings open.

### Making whole subnets reachable through the tunnel

Only needed then — otherwise leave it out:

```bash
cat > /etc/sysctl.d/99-forwarding.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-forwarding.conf
```

### Useful commands

```bash
wg show                                 # peers, handshakes, data volumes
wg show wg0 latest-handshakes
systemctl restart wg-quick@wg0          # briefly drops all tunnels
wg syncconf wg0 <(wg-quick strip wg0)   # changes without an interruption
```

---

## 6. VPN: Tailscale

An alternative to WireGuard when you do not want to manage keys yourself and
both sides sit behind NAT.

```bash
curl -fsSL https://pkgs.tailscale.com/stable/$(. /etc/os-release; echo "$ID")/$(. /etc/os-release; echo "$VERSION_CODENAME").noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/$(. /etc/os-release; echo "$ID")/$(. /etc/os-release; echo "$VERSION_CODENAME").tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt update && apt install -y tailscale
```

Log in — the call shows a URL to open in a browser:

```bash
tailscale up --hostname="$(hostname -s)" --accept-dns=false --ssh=false
```

`--accept-dns=false` is usually right on a server: otherwise Tailscale writes
its own nameservers into `/etc/resolv.conf`.

> **`tailscale up` resets every option you do not pass to its default.** So when
> changing something, always give the whole set, with `--reset` if need be.

Common additional options:

```bash
tailscale up --advertise-routes=192.168.1.0/24     # subnet router
tailscale up --advertise-exit-node                 # offer as an exit node
tailscale up --accept-routes                       # accept foreign subnets
tailscale up --shields-up                          # no incoming connections
```

Routes and an exit node need IP forwarding (see section 5) **and** approval in
the admin console.

```bash
tailscale status
tailscale ip -4
ufw allow in on tailscale0 comment 'Tailnet'   # services over the tailnet only
tailscale logout                                # log out
```

---

## Part 2 — Monitor operation

The server should report on itself rather than making you go and look. So first
the notification path, then everything that uses it.

---

## 7. Sending mail

Before the automatic updates, not after: an update run whose report reaches
nobody is an unattended run. The same goes for cron errors and everything else
the server sends to `root`.

`msmtp` is the leanest tool for that: no service, no open port, just a sendmail
replacement that sends through somebody else's SMTP account.

```bash
apt install -y msmtp msmtp-mta bsd-mailx
```

`msmtp-mta` creates `/usr/sbin/sendmail`, so that cron and everything else goes
through it. `bsd-mailx` provides the `mail` command.

```bash
cat > /etc/msmtprc <<'EOF'
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
timeout        20

account        default
host           smtp.example.com
port           587
from           server@example.com
user           server@example.com
password       SECRET
EOF

chmod 600 /etc/msmtprc
chown root:root /etc/msmtprc
touch /var/log/msmtp.log && chmod 600 /var/log/msmtp.log
```

Port 465 instead of 587 means implicit TLS — then set `tls_starttls off`.

Redirect system mail to a real address:

```bash
echo 'root: admin@example.com' >> /etc/aliases
newaliases
```

Testing:

```bash
printf 'Subject: Test from %s\n\nIt works.\n' "$(hostname -f)" \
  | sendmail -t admin@example.com

echo "Test text" | mail -s "Test" admin@example.com
tail -n 20 /var/log/msmtp.log
```

**Only go on once the test mail has arrived.** Everything that follows reports
through this route.

The password sits in clear text in `/etc/msmtprc` (readable by root only).
Better to create an app password at the provider with sending rights only than
to use the main credentials.

---

## 8. Automatic updates

With `unattended-upgrades`, the standard route on Debian and Ubuntu.

```bash
apt install -y unattended-upgrades apt-listchanges
dpkg-reconfigure -plow unattended-upgrades      # creates 20auto-upgrades
```

Or by hand:

```bash
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Configure the behaviour in `/etc/apt/apt.conf.d/50unattended-upgrades`. The
important lines (uncomment the existing ones and adjust them):

```
// Security updates only - for "everything" include the -updates line as well
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Sending mail: needs the mailer from section 7
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";     // always | on-change | only-on-error

// Allow a reboot or not
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

On Ubuntu the origin pattern is
`${distro_id}ESMApps:${distro_codename}-apps-security` and
`${distro_id}:${distro_codename}-security` — the file already ships both,
commented out.

Check without installing anything:

```bash
unattended-upgrade --dry-run --debug
```

Read up on the runs:

```bash
less /var/log/unattended-upgrades/unattended-upgrades.log
systemctl status apt-daily-upgrade.timer
systemctl list-timers apt-daily\*
```

If a reboot is pending, apt creates `/var/run/reboot-required`:

```bash
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```

---

## 9. Monitoring with built-in tools

You get surprisingly far without extra software. Three things are worth doing
straight away.

**Make the journal persistent.** Without a persistent journal there is no way to
retrace what happened before a reboot:

```bash
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
sed -i 's/^#\?Storage=.*/Storage=persistent/; s/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' \
    /etc/systemd/journald.conf
systemctl restart systemd-journald
journalctl --disk-usage
```

**Report failed units.** A timer that looks every day and only mails when
something is broken:

```bash
cat > /etc/cron.d/failed-units <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 7 * * * root systemctl list-units --failed --no-legend --plain | grep -q . && \
  systemctl list-units --failed --no-pager | mail -s "[$(hostname -s)] failed units" root
EOF
```

**Keep an eye on disk space.** Warns once a day when a filesystem is above 85 %:

```bash
cat > /etc/cron.d/disk-warn <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 7 * * * root df -h -x tmpfs -x devtmpfs -x squashfs --output=pcent,target | \
  awk 'NR>1 && $1+0 >= 85 {print}' | grep -q . && \
  df -h -x tmpfs -x devtmpfs -x squashfs | mail -s "[$(hostname -s)] disk space" root
EOF
```

You should also check the **inodes** — a filesystem can be full even though
space is free, when millions of small files have used the inode table up.
`df -h` shows none of that:

```bash
df -i
```

Looking by hand:

```bash
systemctl list-units --failed        # what is broken?
systemctl list-timers --all          # what runs when?
journalctl -p err -b                 # errors since the boot
journalctl -u caddy --since -1h      # one service, the last hour
last -n 20                           # who was logged in?
lastb -n 20                          # failed logins
ss -tlnp                             # what listens to the outside?
```

Logrotate takes care of the files in `/var/log` — for your own logs create a
file in `/etc/logrotate.d/` and test it dry with `logrotate -d /etc/logrotate.d/…`.

---

## Part 3 — Applications

What the server actually serves.

---

## 10. Reverse proxy: Caddy

TLS is terminated on the server, and Caddy fetches the certificates itself.

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

ufw allow 80/tcp && ufw allow 443/tcp
```

So that everything does not end up in one file, split the Caddyfile up:

```bash
mkdir -p /etc/caddy/sites.d
cat > /etc/caddy/Caddyfile <<'EOF'
{
    email admin@example.com
}

import /etc/caddy/sites.d/*.caddy
EOF
```

### Reverse proxy

```bash
cat > /etc/caddy/sites.d/app.example.com.caddy <<'EOF'
app.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000 {
        header_up X-Real-IP {remote_host}
    }
    log {
        output file /var/log/caddy/app.example.com.log
    }
}
EOF
```

### Static files

```bash
cat > /etc/caddy/sites.d/www.example.com.caddy <<'EOF'
www.example.com {
    root * /var/www/www.example.com
    encode zstd gzip
    file_server
}
EOF

mkdir -p /var/www/www.example.com
echo '<h1>Hello</h1>' > /var/www/www.example.com/index.html
chown -R caddy:caddy /var/www/www.example.com
```

### Redirect

```bash
cat > /etc/caddy/sites.d/old.example.com.caddy <<'EOF'
old.example.com {
    redir https://new.example.com{uri} permanent
}
EOF
```

### Applying it

```bash
mkdir -p /var/log/caddy && chown caddy:caddy /var/log/caddy
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
journalctl -u caddy -f
```

**Always `caddy validate` first, then `reload`.** A syntax error on restart
otherwise takes all the other vhosts down with it.

More building blocks:

```
# WebSockets/streaming inside the reverse_proxy block:
flush_interval -1

# The backend speaks HTTPS with a self-signed certificate:
transport http { tls tls_insecure_skip_verify }

# Basic auth (hash with: caddy hash-password):
basic_auth { user $2a$14$... }
```

Wildcard certificates (`*.example.com`) need the DNS-01 challenge and therefore
a DNS plugin, that is a custom Caddy build with `xcaddy`. Without that, add
every subdomain individually — HTTP-01 handles that with no extra effort.

---

## 11. TCP relay with nginx

An alternative to Caddy when TLS should **not** be terminated here and the
backend keeps its own certificate instead. nginx then decides by the SNI where
the connection goes, and passes it through undecrypted.

> It occupies port 443 as well — running it alongside Caddy does not work.

```bash
apt install -y nginx-extras      # 'stream' is missing in nginx-light
```

```bash
mkdir -p /etc/nginx/stream-hosts.d

cat > /etc/nginx/stream.conf <<'EOF'
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
EOF

cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    include /etc/nginx/stream.conf;
}
EOF
```

One host per line in a file of its own:

```bash
echo 'default    "";'                        > /etc/nginx/stream-hosts.d/00-default.map
echo 'app.example.com    10.10.0.2:443;'     > /etc/nginx/stream-hosts.d/app.map
```

`default ""` drops connections without a known SNI; a catch-all backend can go
there instead.

If the http default vhost listens on 443, it clashes:

```bash
grep -l 'listen 443' /etc/nginx/sites-enabled/* 2>/dev/null
rm -f /etc/nginx/sites-enabled/default
```

```bash
ufw allow 443/tcp
nginx -t && systemctl reload nginx
```

The certificate for the domain has to live on the **backend** — this server
never sees the traffic in the clear.

---

## 12. Docker

```bash
# remove competing packages
apt remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null

apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt update && apt install -y docker-ce docker-ce-cli containerd.io \
                             docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
```

### Two settings to make right away

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "ip": "127.0.0.1"
}
EOF
systemctl restart docker
```

**Log rotation.** Without `log-opts` every container log file under
`/var/lib/docker/containers/` grows without bound — the most common cause of a
full disk on a Docker host. The setting only affects **newly created**
containers.

**`"ip": "127.0.0.1"`.** The important point:

> **Docker bypasses ufw.** Docker enters published ports (`-p 8080:80`) straight
> into the `DOCKER` chain of iptables, and that is evaluated **before** the ufw
> rules. `ufw deny 8080` does **not** protect the container — it is reachable
> from the internet even though the firewall claims otherwise.

With `"ip": "127.0.0.1"`, published ports without an explicit address end up on
the loopback interface and are only reachable through a reverse proxy. If you do
need a port on the outside, write it explicitly:

```bash
docker run -p 0.0.0.0:8080:80 ...
```

If you want to filter instead, you have to do it in the `DOCKER-USER` chain,
because only that one is evaluated before Docker's own rules:

```bash
iptables -I DOCKER-USER -i eth0 ! -s 10.0.0.0/8 -j DROP
```

Rules like that survive no reboot — for that you need `iptables-persistent` or a
systemd unit.

### Users without sudo

```bash
usermod -aG docker admin
```

> Whoever is in the group `docker` can read and write every file on the system
> as root through a container (`docker run -v /:/host …`). That is equivalent to
> root rights, only without the sudo log.

### Cleanup

```bash
docker system df                                    # what takes up space?
docker system prune -f --filter "until=168h"        # containers, networks, loose images
docker system prune -af --filter "until=168h"       # tagged images as well
docker volume ls -qf dangling=true                  # ONLY show unused volumes
```

`docker volume prune` is deliberately left out: that is where the data lives, and
a volume without a running container is by no means a superfluous volume.

Weekly and automatic:

```bash
cat > /etc/cron.d/docker-prune <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root docker system prune -f --filter "until=168h" >/dev/null 2>&1
EOF
```

---

## 13. Keeping working copies up to date with git

If an application's code sits on the server as a git working copy, a cron job
can keep it up to date. The one-liner for that is short, but it has four traps
you will hit every one of if you do not know them.

```bash
cat > /etc/cron.d/git-pull-webapp <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * deploy flock -n /tmp/.git-webapp.lock \
  env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
  timeout 120 git -C /srv/webapp pull --ff-only --quiet
EOF
```

One by one:

- **`--ff-only`.** Never merge or rebase automatically. If the working copy has
  diverged, the run should fail — not silently produce a merge commit nobody
  asked for.
- **Run as the owner** (in the example `deploy` in the user field of the cron.d
  file), not as root. Then that account's SSH keys apply, and git's protection
  `detected dubious ownership` never kicks in at all.
- **`GIT_TERMINAL_PROMPT=0` and `BatchMode=yes`.** A cron job waiting for a
  passphrase or a host key confirmation hangs until the timeout — and again on
  the next tick. Hence `timeout` on top.
- **`flock`**, so that several runs do not overlap at a short cadence.

Prepare this once by hand, otherwise the first run fails silently:

```bash
sudo -u deploy ssh -T git@github.com          # confirm the host key
sudo -u deploy git -C /srv/webapp status      # clean? upstream set?
sudo -u deploy git -C /srv/webapp branch -vv  # check the tracking branch
```

**Local changes are an error, not an invitation to tidy up.** If you are tempted
to put `git reset --hard` or `git stash` into the cron job: that is data loss on
a timer. Better to let it fail and go and see why the working copy is not clean
— usually the service itself writes something into the directory that belongs in
the `.gitignore`.

If something should happen after an update, comparing the commit ID helps:

```bash
cat > /usr/local/sbin/pull-webapp <<'EOF'
#!/bin/sh
set -e
cd /srv/webapp
before=$(git rev-parse HEAD)
git pull --ff-only --quiet
[ "$before" = "$(git rev-parse HEAD)" ] && exit 0
docker compose up -d
EOF
chmod 755 /usr/local/sbin/pull-webapp
```

---
## Final check

```bash
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication)'
ufw status verbose
systemctl list-timers apt-daily\*
unattended-upgrade --dry-run --debug 2>&1 | tail -5
echo "Test" | mail -s "Final test $(hostname -f)" admin@example.com
ss -tlnp                                  # what really listens to the outside?
df -h && df -i                            # space AND inodes
```

`ss -tlnp` is the most honest check: it says what is actually reachable —
regardless of what the configuration files claim.

And the proof of the pudding, while the old session is still open:

```bash
ssh -p <port> admin@server.example.com
```

## What is deliberately missing here

- **Backups.** The single most important point, but too dependent on the use
  case for a general guide. Starting points: `restic`, `borgbackup`.
- **Monitoring.** What to monitor depends on what the server does. Built-in
  tools to start with: `systemctl list-units --failed`, `df -h`,
  `journalctl -p err -b`.
- **Intrusion detection, SELinux/AppArmor profiles, kernel hardening.** Topics
  of their own with an effort of their own.
