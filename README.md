# mmo_linux_server_scripts

Ein Bash-Werkzeug für die immer gleichen Aufgaben auf einem Linux-Webserver:
Härtung, Mail, Auto-Updates, Health-Checks und Caddy-vHosts. Fünf Module, ein
Entrypoint, keine Abhängigkeit zwischen den Modulen.

```bash
./setup.sh                       # interaktives Menü
./setup.sh <modul> <verb> [...]  # Befehl direkt
./setup.sh <modul>               # Verben eines Moduls anzeigen
./setup.sh --help                # alles
```

Globale Flags: `-y`/`--yes` (keine Rückfragen, Defaults übernehmen) und `--`
(alles danach geht unverändert an das Verb).

## Module

| Modul | Verben | Zweck |
|---|---|---|
| `server`  | `install` `status` `remove` | SSH + ufw + fail2ban in einem Durchlauf |
| `smtp`    | `install` `status` `test` `remove` | SMTP-Zugang + Mailer für die Reports |
| `updates` | `install` `status` `remove` (`run`) | apt-Updates per Cron, mit Report |
| `health`  | `check` `install` `status` `remove` (`run`) | Disk/Auslastung/Dienste/Zertifikate/Traffic |
| `tcp`     | `install` `add` `list` `edit` `remove` `check` `status` `uninstall` (`run`) | TCP-Erreichbarkeit, Mail nur bei Zustandswechsel |
| `caddy`   | `install` `list` `add` `show` `edit` `remove` `reload` `status` | vHost-Verwaltung |

`run` ist der Cron-Runner und taucht deshalb nicht im Menü auf.

Bei `tcp` heißt der Modul-Abbau `uninstall` und nicht `remove`, weil `tcp remove`
schon einen überwachten Dienst entfernt — genau wie `caddy remove` einen vHost.

## Aufbau

```
setup.sh              Entrypoint: lädt lib + modules, baut Registry, Menü/Dispatch
lib/                  Kernbibliothek (wird gesourct, nicht ausgeführt)
  core.sh             sudo/Logging/Verzeichnisse/Tool-Installation/systemd/Logdateien
  ui.sh               confirm, ask, ask_choice, ask_port, ask_secret  (-y-fest)
  conf.sh             eine Config-Datei pro Modul: laden, speichern, maskiert anzeigen
  cron.sh             Jobs in /etc/cron.d anlegen, prüfen, entfernen
  mail.sh             notify() über var/send-mail.sh (No-op ohne SMTP)
  report.sh           Report sammeln, Fehler zählen, per Mail schicken
  registry.sh         category/register -> Menü, Dispatch, Hilfe
modules/              jedes Modul registriert beim Sourcen seine Verben
  server.sh  smtp.sh  updates.sh  health.sh  tcp.sh  caddy.sh
templates/            Caddyfile.tmpl, vhost-*.caddy.tmpl, send-mail.sh
var/                  Laufzeit: Configs (0600), Logs, Mailer   (gitignored)
```

Module kennen sich nicht gegenseitig und dürfen einzeln gelöscht werden — Menü
und Hilfe schrumpfen dann automatisch mit.

## Reihenfolge auf einem frischen Server

```bash
./setup.sh server install     # 1. Härtung: fragt Port, Root-Login, Passwort-Login, Ports
./setup.sh smtp install       # 2. Mailer, damit die Reports rausgehen
./setup.sh updates install    # 3. apt-Updates per Cron
./setup.sh health install     # 4. Health-Check per Cron
./setup.sh caddy install      # 5. Caddy + Basis-Caddyfile
./setup.sh caddy add app.example.com proxy 127.0.0.1:3000
```

Jedes `install` schlägt bei einem erneuten Lauf die bisherigen Werte als Default
vor, ist also gefahrlos wiederholbar.

## Härtung (`server`)

Ein Durchlauf: erst alle Fragen (SSH-Port, Root-Login, optional Public Key,
Passwort-Login, zusätzliche ufw-Ports, fail2ban-Schwellen), dann eine
Zusammenfassung, dann **eine** Bestätigung. Vorher wird nichts angefasst.

Guardrails gegen Aussperrung:

- **Reihenfolge ufw → sshd → fail2ban.** Der neue SSH-Port ist in der Firewall
  offen, *bevor* sshd dorthin wechselt.
- **Port 22 bleibt zunächst zusätzlich offen.** Das Skript nennt am Ende den
  Befehl, mit dem du ihn nach erfolgreichem Test schließt.
- **SSH-Änderungen nur als Drop-in** (`/etc/ssh/sshd_config.d/99-…conf`), mit
  `sshd -t` davor und Rollback, wenn die Prüfung fehlschlägt.
- **`ssh.socket` wird erkannt.** Auf Ubuntu ≥ 22.10 startet sshd per
  Socket-Aktivierung und ignoriert dann die `Port`-Direktive aus `sshd_config`
  komplett — der Port muss an `ssh.socket` gesetzt werden. Ohne diese Erkennung
  stellt man die Firewall auf den neuen Port um, während sshd weiter auf 22
  lauscht: Aussperrung. Das Skript schreibt in diesem Fall ein Socket-Drop-in.
- **Passwort-Login wird nur abgeschaltet, wenn ein `authorized_keys` existiert.**

Trotzdem: bei der Härtung immer eine **zweite SSH-Sitzung offen halten**.

`server remove` nimmt alles zurück — und öffnet Port 22 in ufw, *bevor* sshd
dorthin zurückfällt.

## Health-Checks (`health`)

Sechs Abschnitte, fünf davon mit Warnung, einer rein informativ:

| Check | Warnt wenn | Default | Config-Key |
|---|---|---|---|
| Speicher | Belegung ≥ Schwelle, pro Mountpoint | 85 % | `DISK_WARN` |
| Auslastung | CPU **oder** RAM ≥ Schwelle | 85 % | `USAGE_WARN` |
| Dienste | failed unit vorhanden, oder genannter Dienst läuft nicht | `caddy fail2ban` | `HEALTH_UNITS` |
| Zertifikate | Restlaufzeit < 14 Tage (fest) | aus | `HEALTH_CERT_DOMAINS` |
| Traffic | nie, nur Anzeige | — | — |

**Auslastung** fasst CPU und RAM in einer Schwelle zusammen und misst beides über
einen Zeitraum statt als Momentaufnahme:

- **CPU** = `load15 / Kerne × 100`. Der 15-Minuten-Mittelwert kommt direkt vom
  Kernel — eine einzelne Lastspitze löst damit keine Mail aus, gewarnt wird erst
  bei anhaltender Auslastung.
- **RAM** = Mittel aus `USAGE_SAMPLES` Messungen im Abstand von 2 s (Default 3,
  also ~4 s). Damit warnt ein kurzer Ausschlag nicht sofort. Gerechnet wird gegen
  `MemAvailable`, Caches und Buffer zählen also nicht als belegt.

Zu den Defaults: 85 % ist für beide Werte der Punkt, an dem es eng wird, aber noch
nichts ausfällt. Auf kleinen VPS mit 1–2 Kernen ist CPU eher bei **80** sinnvoll
(load15 von 1,7 auf 2 Kernen heißt schon, dass Requests warten); bei viel RAM und
konstanter Grundlast darf RAM ruhig auf **90**. Getrennte Schwellen für CPU und RAM
wären zwei Zeilen in [health.sh](modules/health.sh#L57) — sag Bescheid, wenn du das
brauchst.

Nicht enthalten: Swap, Inodes, offene Ports, Verzeichnisgrößen, HTTP-Statuscodes.

## TCP-Erreichbarkeit (`tcp`)

Überwacht, ob Dienste auf ihrem TCP-Port antworten, und mailt **nur bei
Zustandswechsel**:

| Übergang | Mail |
|---|---|
| `up` → `down` | ja, Fehlermeldung |
| `down` → `down` | **nein** — kein Nachtreten |
| `down` → `up` | ja, Entwarnung mit Ausfalldauer |
| neu → `up` | nein (Erstaufnahme im Normalzustand ist kein Vorfall) |
| neu → `down` | ja |

```bash
./setup.sh tcp install                          # Cron, Default stündlich (17 * * * *)
./setup.sh tcp add nextcloud 127.0.0.1 8080
./setup.sh tcp add mailserver mx.example.com 25
./setup.sh tcp list
./setup.sh tcp edit nextcloud                   # Name, Host und Port änderbar
./setup.sh tcp remove nextcloud
./setup.sh tcp check                            # jetzt prüfen, ohne Mail
./setup.sh tcp uninstall                        # Überwachung abschalten
```

Details:

- **Zwei Dateien:** `var/tcp-services` (`name|host|port`, vom CRUD gepflegt) und
  `var/tcp-state` (`name|up|down|epoch`, nur vom Runner geschrieben). Entfernte
  Dienste fallen beim nächsten Lauf automatisch aus dem Zustand heraus.
- **`check` ändert nichts.** Es prüft und zeigt an, ohne Zustand fortzuschreiben
  und ohne Mail — man kann also jederzeit nachsehen, ohne die Alarmlogik zu stören.
  Nur `tcp run` (der Cron-Runner) führt die Zustandsmaschine.
- **Eine Mail pro Lauf**, die alle Wechsel dieses Laufs auflistet — nicht eine Mail
  pro Dienst. Bei einem Netzausfall mit zehn betroffenen Diensten bekommst du also
  eine Mail mit zehn Zeilen, nicht zehn Mails. Der Zustand wird trotzdem je Dienst
  einzeln geführt.
- **Verbindungstest** über bash `/dev/tcp` (keine Abhängigkeit). Scheitert das und
  `nc` ist vorhanden, wird damit gegengeprüft — ein bash ohne Netz-Redirections
  führt so nicht zu falschen DOWN-Meldungen.
- **Wiederholungen:** `TCP_RETRIES` (Default 2) Versuche mit `TCP_TIMEOUT`
  (Default 3 s), damit ein einzelnes verlorenes Paket keinen Alarm auslöst.
- **Intervall:** stündlich als Default, wie gewünscht. Weil nur Wechsel mailen,
  kostet ein kürzeres Intervall **keine** zusätzlichen Mails — `*/10 * * * *`
  drückt die Erkennungszeit von bis zu 60 auf bis zu 10 Minuten, bei gleicher
  Mailmenge. Das ist die Einstellung, die ich empfehlen würde.
- Exit-Code von `tcp run` ist 1, solange irgendein Dienst down ist.

## Caddy-vHosts (`caddy`)

Ein vHost ist eine Datei in `/etc/caddy/sites.d/<slug>.caddy`, eingebunden per
`import` aus `/etc/caddy/Caddyfile`. Drei Typen: `proxy` (reverse_proxy auf
host:port), `static` (file_server auf ein Verzeichnis) und `redirect`.

```bash
./setup.sh caddy install admin@example.com    # E-Mail auch als Argument möglich
./setup.sh caddy add app.example.com proxy 127.0.0.1:3000
./setup.sh caddy add example.com,www.example.com static /srv/sites/example
./setup.sh caddy add alt.example.com redirect https://neu.example.com 301
./setup.sh caddy list
./setup.sh caddy show app.example.com
./setup.sh caddy edit app.example.com      # Typ/Ziel/Domains ändern
./setup.sh caddy remove app.example.com
./setup.sh caddy reload                    # validieren + neu laden
./setup.sh caddy status
```

Signatur: `caddy add [DOMAIN(S)] [TYP] [ZIEL] [CODE]` — jedes fehlende Argument
wird gefragt. `show`/`edit`/`remove` akzeptieren **jede** Domain des vHosts, nicht
nur die primäre (`show www.example.com` findet den vHost von `example.com`).

Nicht-interaktiv (`-y`) müssen Typ und Ziel als Argument kommen, und Streaming
bleibt aus — `confirm` würde mit `-y` sonst ungefragt `flush_interval -1` setzen.

Details:

- **Erste Zeile jeder vHost-Datei ist eine Metazeile** (`type=`, `domains=`,
  `target=`, `code=`, `stream=`). `list`, `show` und `edit` lesen daraus die
  Struktur zurück, statt Caddy-Syntax zu parsen. Handgeschriebene Dateien in
  `sites.d` bleiben funktionsfähig und erscheinen in `list` als `manuell`.
- **Validierung + Rollback.** Nach jedem Schreiben läuft `caddy validate`. Lehnt
  Caddy die Konfiguration ab, wird die Änderung zurückgenommen und neu geladen —
  ein Tippfehler nimmt nie alle anderen vHosts mit.
- **Keine Wildcards.** `*.example.com` wird abgelehnt: Let's Encrypt stellt
  Wildcard-Zertifikate nur über die DNS-01-Challenge aus, dafür bräuchte Caddy
  ein DNS-Provider-Plugin (eigener Build mit `xcaddy`). Jede Subdomain einzeln
  anlegen — HTTP-01 erledigt das ohne Zusatzaufwand.
- **Streaming/SSE** ist beim Typ `proxy` eine Rückfrage (`flush_interval -1`,
  ohne `encode`). WebSockets brauchen das nicht, die laufen in Caddy von selbst.
- **Statische Verzeichnisse** bekommen einen Platzhalter-`index.html` und per
  `setfacl` Lese-/Durchlaufrecht für den `caddy`-User — das ist die übliche
  Ursache für 403.
- **`sites.d/000-readme.caddy` nicht löschen.** Die Datei enthält nur Kommentare
  und sorgt dafür, dass der `import`-Glob auch dann etwas findet, wenn kein vHost
  angelegt ist. `list` blendet sie aus.
- **`caddy install` schreibt `/etc/caddy/Caddyfile` neu.** Eine vorhandene Datei,
  die nicht von diesem Tool stammt, wird vorher nach `Caddyfile.bak` gesichert
  (mit Rückfrage). vHosts in `sites.d` bleiben unberührt.

## Konfiguration und Ablage

Alles unter `DEPLOY_DIR` (Default: `var/` neben `setup.sh`, per `.gitignore`
ausgeschlossen). Eine Config-Datei pro Modul, jeweils `0600`:

```
var/.server.env  var/.smtp.env  var/.updates.env  var/.health.env
var/.tcp.env     var/.caddy.env
var/tcp-services  var/tcp-state              (0644, keine Geheimnisse)
var/send-mail.sh  var/updates.log  var/health.log  var/tcp.log
```

Es gibt bewusst **keine** zentrale Sammel-Config: jedes Modul steht für sich.
Kein Modul setzt voraus, dass ein anderes eingerichtet ist.

Ablage umbiegen: `DEPLOY_DIR=/etc/mmo ./setup.sh …`. Die Cron-Einträge merken sich
den beim Einrichten gültigen Pfad, ein Wechsel danach erfordert also ein erneutes
`updates install` / `health install`.

Außerhalb von `DEPLOY_DIR` wird angefasst:

| Pfad | von |
|---|---|
| `/etc/ssh/sshd_config.d/99-mmo_linux_server_scripts.conf` | `server` |
| `/etc/systemd/system/ssh.socket.d/10-…-port.conf` | `server` (nur bei Socket-Aktivierung) |
| `/etc/fail2ban/jail.d/mmo_linux_server_scripts-sshd.local` | `server` |
| `/etc/cron.d/mmo_linux_server_scripts-{updates,health,tcp}` | `updates`, `health`, `tcp` |
| `/etc/caddy/Caddyfile`, `/etc/caddy/sites.d/*.caddy` | `caddy` |
| `/srv/sites/<slug>` | `caddy add … static` (Default-Ziel) |

`server remove`, `updates remove`, `health remove` und `caddy remove` räumen ihre
jeweiligen Dateien wieder ab.

## Cron

Geplante Läufe liegen in `/etc/cron.d/mmo_linux_server_scripts-<job>` — nicht in
der User-Crontab. Gründe:

- explizites User-Feld: die Jobs laufen als `root`, apt braucht also kein
  passwortloses `sudo`
- eine Datei pro Job: anlegen, prüfen und entfernen ohne Crontab-Parsing
- `PATH` lässt sich setzen. Cron startet sonst mit `/usr/bin:/bin`, dann fehlt
  `/usr/local/bin` und selbst installierte Tools werden nicht gefunden

Die Runner (`updates run`, `health run`) laufen bewusst ohne `set -e`: sie
sammeln Fehler und melden sie am Ende, statt mitten im Lauf abzubrechen.

## Mail

`smtp install` legt `var/send-mail.sh` an — SMTP-Versand über `curl` mit
erzwungenem TLS, aktiver Zertifikatsprüfung und Zugangsdaten über eine
curl-Config auf stdin, damit `user:pass` nicht in der Prozessliste landet.
Nicht-ASCII-Betreffs werden nach RFC 2047 kodiert.

Ohne eingerichtetes SMTP ist der Mailversand ein No-op: `updates` und `health`
laufen normal und schreiben nur ins Log.

Statt des Klartext-Passworts kann in `var/.smtp.env` auch ein Kommando stehen,
das das Passwort ausgibt:

```bash
SMTP_PASS=''
SMTP_PASS_CMD='cat /root/.smtp-pass'
```

## Bewusst nicht enthalten

Die Vorgängerversion verwaltete zusätzlich einen kompletten Docker-Stack
(Nextcloud, Rauthy, Vaultwarden, Collabora, MariaDB, Redis), verschlüsselte
Backups und Docker selbst. Das ist alles entfernt — dieses Werkzeug macht
Serverbetrieb, keine Anwendungsbereitstellung.

Mitentfernt wurden dabei zwei Dinge, die vorher in anderen Modulen steckten und
ohne den Stack keinen Sinn ergaben:

- `updates` aktualisiert **keine** Docker-Images mehr, nur apt-Pakete
- `health` prüft **keine** Container-Healthchecks mehr

Falls das auf einem Server mit eigenen Compose-Projekten zurück soll, ist das ein
neues Modul `docker` mit `install`/`status`/`remove` — die Registry braucht dafür
keine Änderung.

## Neues Modul

Datei in `modules/` anlegen und beim Sourcen die Verben registrieren:

```bash
register <modul> <verb> <funktion> "Label" [menu]   # menu=0 -> nur CLI
```

Kategorie und Menü-Reihenfolge stehen in `setup.sh` (`category …`). Neue Verben
erscheinen automatisch nummeriert im Menü und in `--help`.

## Entwicklung

Entwickelt wird unter Windows, ausgeführt unter Linux. `.gitattributes` erzwingt
daher LF für `*.sh` und `*.tmpl` — mit CRLF scheitert schon der Shebang
(`bad interpreter: /usr/bin/env bash^M`).

Vor dem Commit:

```bash
for f in setup.sh lib/*.sh modules/*.sh templates/send-mail.sh; do bash -n "$f"; done
shellcheck setup.sh lib/*.sh modules/*.sh templates/send-mail.sh   # falls vorhanden
```

`./pull_push.sh` legt einen Checkpoint-Commit an und gleicht mit dem Remote ab
(`git pull --rebase && git push`). Secrets können dabei nicht mitgehen, `var/` ist
per `.gitignore` ausgeschlossen.

Das `caddy`-Modul lässt sich ohne Server trocken testen: `CADDY_FILE`,
`CADDY_SITES`, `CADDY_ROOT`, `CRON_D` und `DEPLOY_DIR` sind alle per Env
überschreibbar, `caddy`/`systemctl`/`sudo` lassen sich per PATH stubben.
