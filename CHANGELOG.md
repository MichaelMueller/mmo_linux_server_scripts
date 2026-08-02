# Changelog

Alle nennenswerten Änderungen an diesem Projekt. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/) — was hier als *breaking*
gilt, steht in der [README](README.md#versionierung).

## [Unveröffentlicht]

## [1.0.0] — 2026-08-02

Erste veröffentlichte Fassung. Fünfzehn eigenständige Werkzeuge unter einem
gemeinsamen Menü, jedes einzeln lauffähig und einzeln wieder abbaubar.

### Zugang sichern

- **base-tools** — Grundpakete (`git` und `ca-certificates` verbindlich), farbige
  Shell, Voreinstellungen für vim, nano und screen; fremde Dateien werden über
  markierte Blöcke ergänzt statt überschrieben
- **ssh-setup** — Härtung über ein Drop-in, mit Erkennung von `ssh.socket`,
  Prüfung per `sshd -T`, ob das Drop-in überhaupt greift, und der Reihenfolge
  ufw → sshd gegen Aussperren
- **ufw-manager** — CRUD auf ufw-Regeln ohne eigene Buchhaltung, mit Anzeige des
  erzeugten Kommandos vor der Ausführung und einem zweistufigen Rezept
  „SSH nur über WireGuard"
- **wg-manager** — WireGuard-Server und Client-Configs, aufgeteilt in
  `wg0-interface.conf` und `peers.d/`, Änderungen per `wg syncconf` ohne
  Tunnelabbruch
- **tailscale-setup** — Installation, Anmeldung interaktiv oder per Auth-Key,
  Subnetz-Routen und Exit-Node inklusive IP-Forwarding

### Betrieb überwachen

- **mail-setup** — SMTP-Versand über msmtp als sendmail-Ersatz
- **graph-mailer** — Mailversand über Microsoft Graph für Tenants ohne SMTP AUTH,
  als MIME an die API, per `dpkg-divert` als sendmail eingehängt
- **auto-update** — apt-Updates per Cron, wahlweise nur Sicherheitsupdates, mit
  getrennten Schaltern für Neustart und Mail-Report
- **tcp-monitor** — Erreichbarkeit von TCP-Diensten, Alert nur bei
  Zustandswechsel
- **http-monitor** — HTTP-Statuscode, Antwortzeit und Zertifikatsablauf
- **disk-monitor** — Belegung und Inodes mit Hochrechnung, wann es eng wird

### Applikationen

- **nginx-manager** — nginx als TCP-Relais mit SNI-Routing, TLS zum Backend
  durchgereicht
- **caddy-manager** — vHosts mit TLS-Terminierung, Validierung und Rollback nach
  jeder Änderung
- **docker-setup** — Installation aus dem offiziellen Repo, Log-Rotation und
  Bindung veröffentlichter Ports an `127.0.0.1`, weil Docker sonst an ufw vorbei
  ins Netz publiziert
- **git-updater** — Arbeitskopien per Cron aktuell halten, `--ff-only`, als
  Eigentümer, mit optionaler Docker-Compose-Ausrollung

### Übergreifend

- Einheitliches Deinstallationsmuster: anzeigen, was wegfällt, Rückfrage mit
  Default „nein", Sicherung nach `/root/<tool>-uninstall-<zeit>.tar.gz`, keine
  Paketentfernung, mehrfach ausführbar
- Dokumentation je Werkzeug unter [docs/](docs/), jede Datei für sich
  vollständig und einzeln kopierbar
- [docs/manual-setup.md](docs/manual-setup.md): dieselbe Einrichtung von Hand,
  ohne jedes Skript, nur mit Standardwerkzeugen
- `--version` in jedem Werkzeug, auch ohne root
- MIT-Lizenz, SPDX-Kennung in jeder Datei

[Unveröffentlicht]: https://github.com/MichaelMueller/mmo_linux_server_scripts/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/MichaelMueller/mmo_linux_server_scripts/releases/tag/v1.0.0
