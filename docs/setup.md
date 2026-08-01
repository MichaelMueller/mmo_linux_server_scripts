# setup.sh — Hauptmenü

Einstiegspunkt für alle Werkzeuge. `setup.sh` verwaltet selbst nichts, es ruft
nur die einzelnen Skripte auf und zeigt oben eine Statuszeile. Jedes Tool
funktioniert genauso gut, wenn man es direkt startet.

## Voraussetzungen

- Debian oder Ubuntu (getestete Grundlage: apt, systemd, cron)
- root-Rechte (`sudo`)
- die Tool-Skripte liegen im selben Verzeichnis wie `setup.sh`

## Aufruf

```bash
sudo ./setup.sh
```

Fehlt einem Skript das Ausführungsrecht, setzt `setup.sh` es selbst
(`chmod +x`). Ein Skript, das nicht existiert, wird gemeldet und übersprungen —
man kann also einzelne Tools löschen, die man nicht braucht.

## Statuszeile

```
sshd-Port: 22   |   ufw: active
wg0: active   |   tailscale: active   |   nginx: inactive   |   caddy: active
Mailer: msmtp   |   auto-update: aktiv   |   tcp-monitor: aktiv   |   disk-monitor: -
```

| Angabe | Quelle |
|---|---|
| sshd-Port | `sshd -T` (die wirksame Konfiguration, nicht die Datei) |
| ufw | `ufw status` |
| wg0 / tailscale / nginx / caddy | `systemctl is-active` |
| Mailer | Existenz von `/etc/msmtprc` und `/etc/graph-mailer.conf` |
| die Cron-Tools | Existenz von `/etc/cron.d/<tool>` |

## Menü

Das Menü ist in drei Gruppen geteilt, die zugleich die Einrichtungsreihenfolge
sind: **erst den Zugang sichern, dann den Meldeweg herstellen, dann Anwendungen
daraufstellen.**

| Punkt | Tool | Zweck |
|---|---|---|
| | **Zugang sichern** | |
| 1 | `base-tools.sh` | nano, vim, screen, farbige Shell |
| 2 | `ssh-setup.sh` | SSH härten |
| 3 | `ufw-manager.sh` | Firewall-Regeln |
| 4 | `wg-manager.sh` | WireGuard |
| 5 | `tailscale-setup.sh` | Tailscale |
| | **Betrieb überwachen** | |
| 6 | `mail-setup.sh` | SMTP-Versand über msmtp |
| 7 | `graph-mailer.sh` | Mailversand über Microsoft Graph |
| 8 | `auto-update.sh` | apt-Updates per Cron |
| 9 | `tcp-monitor.sh` | Erreichbarkeit von Diensten |
| 10 | `disk-monitor.sh` | Speicherplatz |
| | **Applikationen** | |
| 11 | `nginx-manager.sh` | TCP-Relais mit SNI-Routing |
| 12 | `caddy-manager.sh` | vHosts mit TLS-Terminierung |
| 13 | `docker-setup.sh` | Docker installieren und einstellen |
| 14 | `git-updater.sh` | Git-Arbeitskopien per Cron aktuell halten |
| | | |
| 15 | Deinstallation | Untermenü, siehe unten |
| 16 | Beenden | |

Innerhalb von Gruppe 1 steht SSH vor der Firewall, weil `ssh-setup` den neuen
Port selbst in ufw öffnet. Gruppe 2 beginnt mit einem Mailer, weil ein
Update-Lauf oder Monitor, dessen Meldung niemanden erreicht, unbeaufsichtigt
ist. `base-tools` sichert nichts, steht aber in Gruppe 1, weil es das erste ist,
was man tut, wenn man auf der Maschine ankommt.

Drei Paare sind Alternativen, keine Ergänzungen:

| | Entscheidung |
|---|---|
| **msmtp** oder **Graph** | Beide wollen `/usr/sbin/sendmail` sein. Graph nur, wenn Microsoft 365 SMTP AUTH gesperrt hat. |
| **nginx** oder **Caddy** | Beide wollen Port 443. nginx reicht TLS ans Backend durch (Zertifikat liegt dort), Caddy terminiert es hier. |
| **WireGuard** oder **Tailscale** | Diese beiden dürfen auch nebeneinander laufen; die Frage ist eher, ob man Schlüssel selbst verwalten will oder zentral. |

## Datenhaltung

`setup.sh` selbst hält keinerlei Zustand — es liest nur `systemctl is-active`,
`ufw status`, `sshd -T` und die Existenz der Cron-Dateien, um die Statuszeile zu
füllen.

Für die einzelnen Werkzeuge gilt als Leitgedanke: **der Dienst ist der
Datenspeicher, nicht das Skript.**

| Zustand liegt … | Werkzeuge |
|---|---|
| ausschließlich im Dienst | `ufw-manager`, `ssh-setup`, `tailscale-setup` |
| in der Konfiguration des Dienstes | `mail-setup`, `docker-setup`, `nginx-manager`, `caddy-manager`, `wg-manager`, `base-tools` |
| neben dem Skript, weil es keinen Dienst gibt | `auto-update`, `git-updater`, `tcp-monitor`, `disk-monitor`, `graph-mailer` |

Das heißt: die meisten Werkzeuge lassen sich auf eine bereits eingerichtete
Installation setzen. Zwei Ausnahmen stehen in den jeweiligen Dateien:
`caddy-manager` schreibt bei der Ersteinrichtung das Caddyfile neu (mit
Sicherung), und `wg-manager` erwartet seine eigene Aufteilung unter
`/etc/wireguard`.

## Deinstallation

Punkt 15 öffnet ein Untermenü mit denselben Tools plus „Alles". Jedes Tool fragt
einzeln nach, sichert vorher nach `/root/<tool>-uninstall-<zeit>.tar.gz` und
entfernt keine Pakete.

Der „Alles"-Durchlauf hält eine feste Reihenfolge ein:

```
disk-monitor → tcp-monitor → git-updater → auto-update → docker
             → nginx → caddy → tailscale → wireguard → base-tools
             → ssh-setup → ufw-manager → graph-mailer → mail-setup
```

Erst geht weg, was nur beobachtet, dann was ausliefert, dann der Zugang.
`ssh-setup` läuft vor `ufw-manager`, damit es Port 22 noch in einer laufenden
Firewall öffnen kann. Die Mailer kommen zuletzt, damit Alerts bis zum Schluss
rausgehen — `graph-mailer` vor `mail-setup`, damit die sendmail-Umleitung
zurückgenommen ist, bevor msmtp abgebaut wird.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| „Script nicht gefunden" | Das Tool-Skript liegt nicht neben `setup.sh` |
| „(… mit Fehler beendet)" | Das Tool hat einen Exit-Code ≠ 0 geliefert; die eigentliche Meldung stand darüber |
| sshd-Port zeigt `?` | `sshd -T` nicht ausführbar — meist, weil das Skript nicht als root läuft |
| Menü flackert nach falscher Eingabe | Beabsichtigt: eine ungültige Auswahl wartet eine Sekunde und zeichnet neu |
