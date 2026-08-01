# Linux-Server von Hand einrichten

Anleitung ohne jedes Hilfsskript: nur Standardwerkzeuge, wie sie die
Distribution mitbringt oder wie sie ihre Hersteller dokumentieren. Alle Befehle
sind zum Kopieren gedacht und werden als `root` ausgeführt (sonst `sudo`
davorsetzen).

Grundlage: **Debian 12/13 oder Ubuntu 22.04/24.04** mit systemd.

## Reihenfolge

| | Abschnitt | |
|---|---|---|
| 1 | [Grundausstattung](#1-grundausstattung) | Zeitzone, Hostname, Pakete |
| 2 | [Benutzer und SSH-Schlüssel](#2-benutzer-und-ssh-schlüssel) | |
| 3 | [SSH härten](#3-ssh-härten) | Drop-in, Portwechsel, fail2ban |
| 4 | [Firewall mit ufw](#4-firewall-mit-ufw) | |
| 5 | [Mailversand](#5-mailversand) | msmtp |
| 6 | [Automatische Updates](#6-automatische-updates) | unattended-upgrades |
| 7 | [VPN: WireGuard](#7-vpn-wireguard) | **oder** |
| 8 | [VPN: Tailscale](#8-vpn-tailscale) | |
| 9 | [Reverse Proxy: Caddy](#9-reverse-proxy-caddy) | **oder** |
| 10 | [TCP-Relais mit nginx](#10-tcp-relais-mit-nginx) | |
| 11 | [Docker](#11-docker) | |

Die Reihenfolge ist nicht beliebig, sie folgt **erst Sicherheit, dann
Kommunikation, dann Aufbau**:

- **Sicherheit zuerst** (2–4): Zugang und Firewall stehen, bevor irgendein
  Dienst lauscht. SSH vor der Firewall, weil man erst wissen muss, welchen Port
  man freilässt.
- **Dann Kommunikation** (5): der Mailer, bevor etwas eingerichtet wird, das
  Berichte oder Fehler verschickt. Ein Update-Lauf, dessen Bericht niemanden
  erreicht, ist ein unbeaufsichtigter Lauf.
- **Dann der Aufbau** (6–11): Updates, VPN, Reverse Proxy, Container.

> **Vor jeder Änderung an SSH oder Firewall: eine zweite SSH-Sitzung offen
> lassen und offen halten.** Sperrt man sich aus, ist sie der einzige Weg
> zurück, der keine Konsole beim Hoster braucht.

---

## 1. Grundausstattung

```bash
apt update && apt upgrade -y

# Zeitzone und Zeitsynchronisation
timedatectl set-timezone Europe/Berlin
timedatectl set-ntp true
timedatectl        # Kontrolle: "System clock synchronized: yes"

# Hostname
hostnamectl set-hostname server.example.com
# in /etc/hosts sollte der Name auf 127.0.1.1 zeigen:
#   127.0.1.1   server.example.com server
```

Werkzeuge, die man erfahrungsgemäß sowieso nachinstalliert:

```bash
apt install -y nano vim screen tmux htop curl wget git unzip rsync tree ncdu \
               bash-completion ca-certificates dnsutils
```

### Locale

Wenn Programme über `Setting locale failed` meckern:

```bash
sed -i 's/^# *de_DE.UTF-8/de_DE.UTF-8/; s/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=de_DE.UTF-8
```

### Shell-Komfort (optional)

Farben und Aliase systemweit, ohne bestehende Dateien anzufassen:

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

`/etc/profile.d` liest allerdings nur eine **Login**-Shell. Damit `ssh host
befehl`, `su` und screen dasselbe bekommen, zusätzlich in `/etc/bash.bashrc`:

```bash
cat >> /etc/bash.bashrc <<'EOF'
[ -r /etc/profile.d/zz-local.sh ] && . /etc/profile.d/zz-local.sh
EOF
```

Für vim lohnt eine Zeile besonders — ab Version 8.2 ist die Maus per Default an,
und dann springt vim beim Markieren in den Visual-Modus, sodass man nicht mehr
aus dem Terminal kopieren kann:

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

## 2. Benutzer und SSH-Schlüssel

Auf dem **eigenen Rechner** (nicht auf dem Server) einen Schlüssel erzeugen,
falls noch keiner da ist:

```bash
ssh-keygen -t ed25519 -C "vorname@arbeitsplatz"
```

Auf dem Server einen Benutzer anlegen und den öffentlichen Schlüssel
hinterlegen:

```bash
adduser --gecos "" admin
usermod -aG sudo admin        # Debian: sudo, manche Systeme: wheel

install -d -m 700 -o admin -g admin /home/admin/.ssh
# den Inhalt von ~/.ssh/id_ed25519.pub einfügen:
nano /home/admin/.ssh/authorized_keys
chmod 600 /home/admin/.ssh/authorized_keys
chown admin:admin /home/admin/.ssh/authorized_keys
```

Bequemer vom eigenen Rechner aus, solange die Passwort-Anmeldung noch geht:

```bash
ssh-copy-id admin@server.example.com
```

**Jetzt testen**, ob die Anmeldung mit Schlüssel funktioniert — bevor im
nächsten Schritt die Passwort-Anmeldung abgeschaltet wird:

```bash
ssh admin@server.example.com
```

---

## 3. SSH härten

Nicht die `/etc/ssh/sshd_config` bearbeiten, sondern ein Drop-in anlegen. Das
überlebt Paket-Updates und ist mit einer Datei wieder rückgängig zu machen.

Zuerst prüfen, dass die Include-Zeile überhaupt existiert:

```bash
grep -n 'Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config
```

Kommt nichts zurück, muss sie ergänzt werden — **ganz oben**, denn bei sshd
gewinnt die *zuerst* gelesene Direktive:

```bash
sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
```

Dann das Drop-in:

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

Prüfen und übernehmen:

```bash
sshd -t                          # Syntaxprüfung, muss stumm bleiben
systemctl restart ssh            # auf manchen Systemen: sshd
```

**Kontrollieren, dass die Werte auch wirklich ankommen:**

```bash
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)'
```

Steht dort etwas anderes als im Drop-in, gibt es weiter oben in der
`sshd_config` eine Direktive, die gewinnt — diese Zeile auskommentieren.

### Port ändern

Zwei Fallstricke, beide führen sonst zur Aussperrung.

**Erstens: die Reihenfolge.** Immer erst die Firewall öffnen, dann sshd
umstellen:

```bash
ufw allow 2222/tcp               # NEUER Port zuerst
sed -i 's/^Port .*/Port 2222/' /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t && systemctl restart ssh
```

Port 22 bleibt zunächst zusätzlich offen. Erst nach erfolgreichem Test:

```bash
ssh -p 2222 admin@server.example.com      # in einem ZWEITEN Terminal
ufw delete allow 22/tcp                   # erst wenn das geklappt hat
```

**Zweitens: Socket-Aktivierung.** Ab Ubuntu 22.10 startet sshd über
`ssh.socket` und **ignoriert die `Port`-Direktive vollständig**. Prüfen:

```bash
systemctl is-enabled ssh.socket
```

Kommt `enabled`, muss der Port am Socket gesetzt werden:

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

Die leere erste `ListenStream=`-Zeile ist entscheidend — ohne sie *ergänzt*
systemd den neuen Port, statt Port 22 zu ersetzen.

Kontrolle, worauf tatsächlich gelauscht wird:

```bash
ss -tlnp | grep sshd
```

### fail2ban (optional)

Sperrt IP-Adressen nach mehreren Fehlversuchen. Bei reiner
Schlüssel-Anmeldung weniger dringend, hält aber das Log sauber.

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

## 4. Firewall mit ufw

```bash
apt install -y ufw

ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH'        # limit statt allow: bremst Brute-Force
ufw enable
```

> `ufw enable` **ohne** Regel für den SSH-Port sperrt die laufende Verbindung
> aus, sobald man sich neu verbindet. Die `limit`-Zeile gehört immer davor.

`limit` erlaubt maximal sechs Verbindungen in 30 Sekunden pro Quell-IP.

### Regeln verwalten

```bash
ufw status numbered                   # mit Nummern, die zum Löschen nötig sind
ufw status verbose                    # inklusive Vorgaben und Logging

ufw allow 443/tcp
ufw allow 6000:6010/tcp               # Portbereich braucht immer ein Protokoll
ufw allow from 10.10.0.0/24 to any port 5432 proto tcp comment 'Postgres intern'
ufw deny from 203.0.113.7
ufw allow in on wg0 to any port 22 proto tcp comment 'SSH nur über VPN'

ufw delete 3                          # nach Nummer aus 'status numbered'
ufw delete allow 443/tcp              # oder nach Regeltext
```

Die Nummern verschieben sich nach jedem Löschen — vor jedem `ufw delete <n>`
also erneut `ufw status numbered` ansehen.

Regeln lassen sich nicht ändern. „Ändern" heißt: neue Regel anlegen, dann die
alte löschen — in dieser Reihenfolge, damit keine Lücke entsteht.

### Anwendungsprofile

```bash
ufw app list
ufw app info OpenSSH
ufw allow OpenSSH
```

### Protokollierung

```bash
ufw logging low                       # off | low | medium | high
tail -f /var/log/ufw.log
```

### SSH nur über das VPN erreichbar machen

Erst die enge Regel dazu, dann testen, **dann** erst die offene entfernen:

```bash
ufw allow 51820/udp comment 'WireGuard'          # muss offen bleiben!
ufw allow in on wg0 to any port 22 proto tcp comment 'SSH via VPN'
# jetzt über den Tunnel anmelden und prüfen, dass es funktioniert
ufw delete allow 22/tcp
```

Der VPN-Port selbst muss offen bleiben — sonst kommt der Tunnel nicht zustande
und man erreicht gar nichts mehr.

---

## 5. Mailversand

Vor den automatischen Updates, nicht danach: ein Update-Lauf, dessen Bericht
niemanden erreicht, ist ein unbeaufsichtigter Lauf. Dasselbe gilt für
Cron-Fehler und alles andere, was der Server an `root` schickt.

`msmtp` ist dafür das schlankeste Werkzeug: kein Dienst, kein offener Port, nur
ein sendmail-Ersatz, der über einen fremden SMTP-Zugang verschickt.

```bash
apt install -y msmtp msmtp-mta bsd-mailx
```

`msmtp-mta` legt `/usr/sbin/sendmail` an, damit Cron und alles andere darüber
gehen. `bsd-mailx` liefert das `mail`-Kommando.

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
password       GEHEIM
EOF

chmod 600 /etc/msmtprc
chown root:root /etc/msmtprc
touch /var/log/msmtp.log && chmod 600 /var/log/msmtp.log
```

Port 465 statt 587 bedeutet implizites TLS — dann `tls_starttls off` setzen.

Systemmails an eine echte Adresse umleiten:

```bash
echo 'root: admin@example.com' >> /etc/aliases
newaliases
```

Testen:

```bash
printf 'Subject: Test von %s\n\nEs funktioniert.\n' "$(hostname -f)" \
  | sendmail -t admin@example.com

echo "Testtext" | mail -s "Test" admin@example.com
tail -n 20 /var/log/msmtp.log
```

**Erst weitergehen, wenn die Testmail angekommen ist.** Alles Folgende meldet
sich über diesen Weg.

Das Passwort steht im Klartext in `/etc/msmtprc` (nur für root lesbar). Beim
Provider besser ein App-Passwort mit reiner Versandberechtigung anlegen als die
Hauptzugangsdaten.

---

## 6. Automatische Updates

Mit `unattended-upgrades`, dem Standardweg auf Debian und Ubuntu.

```bash
apt install -y unattended-upgrades apt-listchanges
dpkg-reconfigure -plow unattended-upgrades      # legt 20auto-upgrades an
```

Alternativ von Hand:

```bash
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Verhalten in `/etc/apt/apt.conf.d/50unattended-upgrades` einstellen. Die
wichtigen Zeilen (jeweils vorhandene entkommentieren und anpassen):

```
// Nur Sicherheitsupdates - für "alles" die -updates-Zeile mit aufnehmen
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Mailversand: braucht den Mailer aus Abschnitt 5
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";     // always | on-change | only-on-error

// Neustart zulassen oder nicht
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

Auf Ubuntu heißt das Origin-Muster `${distro_id}ESMApps:${distro_codename}-apps-security`
und `${distro_id}:${distro_codename}-security` — die Datei bringt beides
auskommentiert schon mit.

Prüfen, ohne etwas zu installieren:

```bash
unattended-upgrade --dry-run --debug
```

Läufe nachlesen:

```bash
less /var/log/unattended-upgrades/unattended-upgrades.log
systemctl status apt-daily-upgrade.timer
systemctl list-timers apt-daily\*
```

Steht ein Neustart aus, legt apt `/var/run/reboot-required` an:

```bash
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```

---

## 7. VPN: WireGuard

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

### Client anlegen

Für jeden Client ein eigenes Schlüsselpaar:

```bash
umask 077
wg genkey | tee /etc/wireguard/laptop_private.key | wg pubkey > /etc/wireguard/laptop_public.key
```

Peer beim Server eintragen — im laufenden Betrieb, ohne bestehende Tunnel zu
unterbrechen:

```bash
wg set wg0 peer "$(cat /etc/wireguard/laptop_public.key)" allowed-ips 10.10.0.2/32
wg-quick save wg0          # schreibt den Peer dauerhaft in wg0.conf
```

Die Konfiguration für das Endgerät:

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

qrencode -t ansiutf8 < /root/laptop.conf     # fürs Handy
```

`AllowedIPs` im Client bestimmt, was durch den Tunnel geht: `10.10.0.0/24` nur
das Tunnelnetz, `0.0.0.0/0` der gesamte Verkehr. `PersistentKeepalive` hält
NAT-Zuordnungen offen.

### Ganze Subnetze über den Tunnel erreichbar machen

Nur dann nötig — sonst weglassen:

```bash
cat > /etc/sysctl.d/99-forwarding.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-forwarding.conf
```

### Nützliche Befehle

```bash
wg show                                 # Peers, Handshakes, Datenmengen
wg show wg0 latest-handshakes
systemctl restart wg-quick@wg0          # trennt alle Tunnel kurz
wg syncconf wg0 <(wg-quick strip wg0)   # Änderungen ohne Unterbrechung
```

---

## 8. VPN: Tailscale

Alternative zu WireGuard, wenn man Schlüssel nicht selbst verwalten will und
beide Seiten hinter NAT sitzen.

```bash
curl -fsSL https://pkgs.tailscale.com/stable/$(. /etc/os-release; echo "$ID")/$(. /etc/os-release; echo "$VERSION_CODENAME").noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/$(. /etc/os-release; echo "$ID")/$(. /etc/os-release; echo "$VERSION_CODENAME").tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt update && apt install -y tailscale
```

Anmelden — der Aufruf zeigt eine URL, die man im Browser öffnet:

```bash
tailscale up --hostname="$(hostname -s)" --accept-dns=false --ssh=false
```

`--accept-dns=false` ist auf einem Server meist richtig: sonst schreibt
Tailscale die eigenen Nameserver in `/etc/resolv.conf`.

> **`tailscale up` setzt jede Option, die man nicht mitgibt, auf ihren
> Default zurück.** Beim Ändern also immer den ganzen Satz angeben, notfalls mit
> `--reset`.

Häufige Zusatzoptionen:

```bash
tailscale up --advertise-routes=192.168.1.0/24     # Subnetz-Router
tailscale up --advertise-exit-node                 # als Exit-Node anbieten
tailscale up --accept-routes                       # fremde Subnetze annehmen
tailscale up --shields-up                          # keine eingehenden Verbindungen
```

Für Routen und Exit-Node braucht es IP-Forwarding (siehe Abschnitt 7) **und**
eine Freigabe in der Admin-Konsole.

```bash
tailscale status
tailscale ip -4
ufw allow in on tailscale0 comment 'Tailnet'   # Dienste nur übers Tailnet
tailscale logout                                # abmelden
```

---

## 9. Reverse Proxy: Caddy

TLS wird auf dem Server terminiert, Zertifikate holt Caddy selbst.

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

ufw allow 80/tcp && ufw allow 443/tcp
```

Damit nicht alles in einer Datei landet, das Caddyfile aufteilen:

```bash
mkdir -p /etc/caddy/sites.d
cat > /etc/caddy/Caddyfile <<'EOF'
{
    email admin@example.com
}

import /etc/caddy/sites.d/*.caddy
EOF
```

### Reverse Proxy

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

### Statische Dateien

```bash
cat > /etc/caddy/sites.d/www.example.com.caddy <<'EOF'
www.example.com {
    root * /var/www/www.example.com
    encode zstd gzip
    file_server
}
EOF

mkdir -p /var/www/www.example.com
echo '<h1>Hallo</h1>' > /var/www/www.example.com/index.html
chown -R caddy:caddy /var/www/www.example.com
```

### Weiterleitung

```bash
cat > /etc/caddy/sites.d/alt.example.com.caddy <<'EOF'
alt.example.com {
    redir https://neu.example.com{uri} permanent
}
EOF
```

### Übernehmen

```bash
mkdir -p /var/log/caddy && chown caddy:caddy /var/log/caddy
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
journalctl -u caddy -f
```

**Immer erst `caddy validate`, dann `reload`.** Ein Syntaxfehler beim Neustart
nimmt sonst alle anderen vHosts mit.

Weitere Bausteine:

```
# WebSockets/Streaming im reverse_proxy-Block:
flush_interval -1

# Backend spricht HTTPS mit selbstsigniertem Zertifikat:
transport http { tls tls_insecure_skip_verify }

# Basic-Auth (Hash mit: caddy hash-password):
basic_auth { benutzer $2a$14$... }
```

Wildcard-Zertifikate (`*.example.com`) brauchen die DNS-01-Challenge und dafür
ein DNS-Plugin, also einen eigenen Caddy-Build mit `xcaddy`. Ohne das jede
Subdomain einzeln eintragen — HTTP-01 erledigt das ohne Zusatzaufwand.

---

## 10. TCP-Relais mit nginx

Alternative zu Caddy, wenn TLS **nicht** hier terminiert werden soll, sondern
das Backend sein eigenes Zertifikat behält. nginx entscheidet dann anhand des
SNI, wohin die Verbindung geht, und reicht sie unentschlüsselt durch.

> Belegt ebenfalls Port 443 — parallel zu Caddy geht das nicht.

```bash
apt install -y nginx-extras      # 'stream' fehlt in nginx-light
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

Ein Host je Zeile in einer eigenen Datei:

```bash
echo 'default    "";'                        > /etc/nginx/stream-hosts.d/00-default.map
echo 'app.example.com    10.10.0.2:443;'     > /etc/nginx/stream-hosts.d/app.map
```

`default ""` verwirft Verbindungen ohne bekannten SNI; stattdessen kann dort
auch ein Auffang-Backend stehen.

Lauscht der http-Default-vHost auf 443, kollidiert er:

```bash
grep -l 'listen 443' /etc/nginx/sites-enabled/* 2>/dev/null
rm -f /etc/nginx/sites-enabled/default
```

```bash
ufw allow 443/tcp
nginx -t && systemctl reload nginx
```

Das Zertifikat für die Domain muss auf dem **Backend** liegen — dieser Server
sieht den Verkehr nie im Klartext.

---

## 11. Docker

```bash
# konkurrierende Pakete entfernen
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

### Zwei Einstellungen, die man sofort setzen sollte

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

**Log-Rotation.** Ohne `log-opts` wächst jede Container-Logdatei unter
`/var/lib/docker/containers/` unbegrenzt — die häufigste Ursache für eine volle
Platte auf einem Docker-Host. Die Einstellung wirkt nur auf **neu erstellte**
Container.

**`"ip": "127.0.0.1"`.** Der wichtige Punkt:

> **Docker umgeht ufw.** Veröffentlichte Ports (`-p 8080:80`) trägt Docker
> direkt in die `DOCKER`-Kette der iptables ein, und die wird **vor** den
> ufw-Regeln ausgewertet. `ufw deny 8080` schützt den Container **nicht** — er
> ist aus dem Internet erreichbar, obwohl die Firewall etwas anderes behauptet.

Mit `"ip": "127.0.0.1"` landen veröffentlichte Ports ohne ausdrückliche Adresse
auf der Loopback-Schnittstelle und sind nur noch über einen Reverse Proxy
erreichbar. Wer einen Port doch nach außen braucht, schreibt ihn explizit:

```bash
docker run -p 0.0.0.0:8080:80 ...
```

Wer stattdessen filtern will, muss das in der `DOCKER-USER`-Kette tun, denn nur
die wird vor Dockers eigenen Regeln ausgewertet:

```bash
iptables -I DOCKER-USER -i eth0 ! -s 10.0.0.0/8 -j DROP
```

Solche Regeln überleben keinen Neustart — dafür braucht es
`iptables-persistent` oder ein systemd-Unit.

### Benutzer ohne sudo

```bash
usermod -aG docker admin
```

> Wer in der Gruppe `docker` ist, kann über einen Container jede Datei des
> Systems als root lesen und schreiben (`docker run -v /:/host …`). Das ist
> gleichbedeutend mit root-Rechten, nur ohne sudo-Protokoll.

### Aufräumen

```bash
docker system df                                    # was belegt Platz?
docker system prune -f --filter "until=168h"        # Container, Netze, lose Images
docker system prune -af --filter "until=168h"       # zusätzlich getaggte Images
docker volume ls -qf dangling=true                  # ungenutzte Volumes NUR anzeigen
```

`docker volume prune` bleibt bewusst außen vor: dort liegen die Daten, und ein
Volume ohne laufenden Container ist noch lange kein überflüssiges Volume.

Wöchentlich automatisch:

```bash
cat > /etc/cron.d/docker-prune <<'EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root docker system prune -f --filter "until=168h" >/dev/null 2>&1
EOF
```

---

## Abschlusskontrolle

```bash
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication)'
ufw status verbose
systemctl list-timers apt-daily\*
unattended-upgrade --dry-run --debug 2>&1 | tail -5
echo "Test" | mail -s "Abschlusstest $(hostname -f)" admin@example.com
ss -tlnp                                  # was lauscht wirklich nach außen?
df -h && df -i                            # Platz UND Inodes
```

`ss -tlnp` ist die ehrlichste Prüfung: dort steht, was tatsächlich erreichbar
ist — unabhängig davon, was in Konfigurationsdateien behauptet wird.

Und die Probe aufs Exempel, solange die alte Sitzung noch offen ist:

```bash
ssh -p <port> admin@server.example.com
```

## Was hier bewusst fehlt

- **Backups.** Der wichtigste Punkt überhaupt, aber zu sehr vom Einsatzzweck
  abhängig für eine allgemeine Anleitung. Ansatzpunkte: `restic`, `borgbackup`.
- **Monitoring.** Was zu überwachen ist, hängt davon ab, was der Server tut.
  Bordmittel für den Anfang: `systemctl list-units --failed`, `df -h`,
  `journalctl -p err -b`.
- **Intrusion Detection, SELinux/AppArmor-Profile, Kernel-Härtung.** Eigene
  Themen mit eigenem Aufwand.
