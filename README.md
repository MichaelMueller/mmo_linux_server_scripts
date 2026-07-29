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
| `health`  | `check` `install` `status` `remove` (`run`) | Disk/Last/RAM/Dienste/Zertifikate/Traffic |
| `caddy`   | `install` `list` `add` `show` `edit` `remove` `reload` `status` | vHost-Verwaltung |

`run` ist der Cron-Runner und taucht deshalb nicht im Menü auf.

## Reihenfolge auf einem frischen Server

```bash
./setup.sh server install     # 1. Härtung: fragt Port, Root-Login, Passwort-Login, Ports
./setup.sh smtp install       # 2. Mailer, damit die Reports rausgehen
./setup.sh updates install    # 3. apt-Updates per Cron
./setup.sh health install     # 4. Health-Check per Cron
./setup.sh caddy install      # 5. Caddy + Basis-Caddyfile
./setup.sh caddy add app.example.com proxy 127.0.0.1:3000
```

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

## Caddy-vHosts (`caddy`)

Ein vHost ist eine Datei in `/etc/caddy/sites.d/<slug>.caddy`, eingebunden per
`import` aus `/etc/caddy/Caddyfile`. Drei Typen:

```bash
./setup.sh caddy add app.example.com proxy 127.0.0.1:3000
./setup.sh caddy add example.com,www.example.com static /srv/sites/example
./setup.sh caddy add alt.example.com redirect https://neu.example.com 301
./setup.sh caddy list
./setup.sh caddy show app.example.com
./setup.sh caddy edit app.example.com      # Typ/Ziel/Domains ändern
./setup.sh caddy remove app.example.com
```

Ohne Argumente fragt jedes Verb interaktiv; `show`/`edit`/`remove` akzeptieren
jede Domain des vHosts, nicht nur die primäre.

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

## Konfiguration und Ablage

Alles unter `DEPLOY_DIR` (Default: `var/` neben `setup.sh`, per `.gitignore`
ausgeschlossen). Eine Config-Datei pro Modul, jeweils `0600`:

```
var/.server.env   var/.smtp.env   var/.updates.env   var/.health.env   var/.caddy.env
var/send-mail.sh  var/updates.log  var/health.log
```

Es gibt bewusst **keine** zentrale Sammel-Config: jedes Modul steht für sich.
Ein erneuter `install`-Lauf schlägt die bisherigen Werte als Default vor.

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
