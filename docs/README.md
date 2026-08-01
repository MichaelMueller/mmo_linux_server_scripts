# Dokumentation

Eine Datei je Werkzeug. Jede ist für sich vollständig und lässt sich einzeln
kopieren — etwa in ein Wiki, eine Übergabe oder ein Betriebshandbuch. Keine
Datei setzt voraus, dass man die anderen gelesen hat.

| Datei | Werkzeug |
|---|---|
| [manual-setup.md](manual-setup.md) | **Ohne diese Skripte:** Server von Hand einrichten, nur mit Standardwerkzeugen |
| [setup.md](setup.md) | Hauptmenü und Deinstallations-Untermenü |
| [base-tools.md](base-tools.md) | Basis-Pakete, farbige Shell, Editor-Voreinstellungen |
| [ssh-setup.md](ssh-setup.md) | SSH-Härtung |
| [ufw-manager.md](ufw-manager.md) | Firewall-Regeln |
| [mail-setup.md](mail-setup.md) | SMTP-Versand über msmtp |
| [graph-mailer.md](graph-mailer.md) | Mailversand über Microsoft Graph (Microsoft 365) |
| [auto-update.md](auto-update.md) | apt-Updates per Cron |
| [wg-manager.md](wg-manager.md) | WireGuard |
| [tailscale-setup.md](tailscale-setup.md) | Tailscale |
| [nginx-manager.md](nginx-manager.md) | TCP-Relais mit SNI-Routing |
| [caddy-manager.md](caddy-manager.md) | vHosts mit TLS-Terminierung |
| [docker-setup.md](docker-setup.md) | Docker installieren und einstellen |
| [tcp-monitor.md](tcp-monitor.md) | Erreichbarkeit von Diensten |
| [disk-monitor.md](disk-monitor.md) | Speicherplatz |

Jede Werkzeug-Datei folgt demselben Aufbau: Voraussetzungen, Aufruf, Menü,
Einstellungen, angelegte Dateien, die Besonderheiten des Werkzeugs,
Datenhaltung, Deinstallation und eine Tabelle zur Fehlersuche.

**[manual-setup.md](manual-setup.md) fällt aus der Reihe**: dort steht, wie man
denselben Server ganz ohne diese Skripte einrichtet — nur mit `ufw`, `sshd`,
`wireguard`, `msmtp`, `caddy`, `docker` und den übrigen Standardwerkzeugen. Kein
Verweis auf dieses Repository, alles zum Kopieren. Nützlich zum Nachvollziehen,
was die Skripte tun, für Systeme, auf denen sie nicht laufen sollen, und als
Notfallanleitung, wenn man die Werkzeuge nicht zur Hand hat.
