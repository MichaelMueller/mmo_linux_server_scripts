# tcp-monitor.sh — TCP-Erreichbarkeit

Prüft per Cron, ob Dienste auf ihrem TCP-Port antworten, hält eine Messreihe und
alarmiert bei Zustandswechsel.

## Voraussetzungen

- bash (der Verbindungstest läuft über `/dev/tcp`, keine externen Werkzeuge)
- root nur für den Cron-Eintrag
- für Mail-Alerts ein eingerichteter Mailer (`mail`-Kommando)

## Aufruf

```bash
sudo ./tcp-monitor.sh              # Menü
sudo ./tcp-monitor.sh --check      # ein Durchlauf, wie ihn Cron macht
sudo ./tcp-monitor.sh --status     # Zielliste auf stdout
sudo ./tcp-monitor.sh --uninstall  # Cron, Konfiguration und Daten entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Ziele verwalten (erstellen, bearbeiten, löschen) |
| 2 | Jetzt alle Ziele prüfen (mit Latenzen) — derselbe Lauf wie per Cron, schreibt also Zustand und Messwerte fort und kann einen Alert auslösen |
| 3 | Ergebnisse und Statistik |
| 4 | Einstellungen |
| 5 | Deinstallieren |
| 6 | Beenden |

## Einstellungen

| Einstellung | Bedeutung | Default |
|---|---|---|
| Datenverzeichnis | wo Ziele, Messwerte und Zustand liegen | `var/` neben dem Skript |
| Prüfintervall | Minuten zwischen zwei Läufen | 5 |
| Standard-Timeout | Sekunden pro Verbindungsversuch | 5 |
| Aufbewahrung | Tage, die Messwerte behalten werden | 30 |
| Webhook | URL, die bei Statuswechsel ein JSON bekommt | leer |
| E-Mail | Adresse für Alerts | leer |

Gespeichert in `tcp-monitor.conf` neben dem Skript.

## Ziele

Ein Ziel ist eine Datei in `var/targets.d/<name>.conf`:

```sh
NAME="nextcloud"
HOST="10.10.0.2"
PORT="8080"
TIMEOUT="5"
ENABLED="1"
NOTE="hinter dem Tunnel"
```

`ENABLED="0"` schaltet ein Ziel vorübergehend ab, ohne es zu löschen. Beim
Anlegen wird sofort ein Testlauf gemacht, damit man nicht bis zum nächsten
Cron-Durchgang wartet.

Beim Löschen wird getrennt gefragt, ob auch die Messreihe verschwinden soll.

## Übersicht

```
NAME                 ZIEL                         AKTIV  STATUS   LETZTE PRÜFUNG
nextcloud            10.10.0.2:8080               ja     UP       2026-08-01 09:15:02
mailserver           mx.example.com:25            ja     DOWN     2026-08-01 09:15:07
```

## Alarmierung

Gemeldet wird **nur der Zustandswechsel**:

| Übergang | Meldung |
|---|---|
| UP → DOWN | ja |
| DOWN → DOWN | nein, kein Nachtreten |
| DOWN → UP | ja, Entwarnung |
| neu → UP | nein (Erstaufnahme im Normalzustand ist kein Vorfall) |
| neu → DOWN | ja |

Deshalb kostet ein kürzeres Intervall **keine** zusätzlichen Mails — es
verkürzt nur die Erkennungszeit. `*/5` statt `*/60` heißt: Ausfall nach maximal
5 statt 60 Minuten bemerkt, bei gleicher Mailmenge.

Jeder Wechsel geht zusätzlich nach `var/log/alerts.log`.

## Dateien

```
tcp-monitor.conf          Konfiguration
var/targets.d/*.conf      die Ziele
var/results/<name>.csv    timestamp,status,latency_ms
var/state/<name>.state    status|zeit|latenz — nur vom Runner geschrieben
var/log/alerts.log        Zustandswechsel
/etc/cron.d/tcp-monitor   Zeitplan
```

Die Trennung von Ziel und Zustand ist Absicht: das CRUD schreibt nur
`targets.d`, der Runner nur `state` und `results`. Ein gelöschtes Ziel
hinterlässt keine Karteileiche im Zustand.

## Statistik (Menüpunkt 3)

Für ein Ziel: Anzahl Messungen, Verfügbarkeit in Prozent, mittlere und maximale
Latenz der UP-Messungen, dazu die letzten 20 Messwerte. Ohne Angabe eines
Namens: die letzten 30 Zustandswechsel.

Messwerte älter als `RETENTION_DAYS` werden bei jedem Lauf abgeschnitten.

## Verbindungstest

Über bash `/dev/tcp/<host>/<port>` mit `timeout`. Das braucht kein `nc`, kein
`curl` und keine erhöhten Rechte. Gemessen wird die Zeit bis zum aufgebauten
TCP-Handshake — ob der Dienst dahinter fachlich gesund ist, sagt das nicht.

## Cron

```
# /etc/cron.d/tcp-monitor
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /pfad/zu/tcp-monitor.sh --check >/dev/null 2>&1
```

Der Pfad ist der beim Einrichten gültige. Nach dem Verschieben des Skripts
Menüpunkt 4 einmal durchlaufen.

Exit-Code von `--check` ist 1, solange irgendein Ziel DOWN ist.

## Deinstallation

Entfernt Cron-Eintrag und Konfiguration, fragt getrennt nach dem
Datenverzeichnis. Vorher Sicherung nach
`/root/tcp-monitor-uninstall-<zeit>.tar.gz`. Es wurden keine Pakete
installiert, es bleibt nichts zurück.

Läuft das Skript ohne root, kann es die Cron-Datei nicht entfernen und nennt
stattdessen den Befehl.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| „Nicht eingerichtet" beim `--check` | `tcp-monitor.conf` fehlt — das Menü einmal durchlaufen |
| Ziel meldet DOWN, ist aber erreichbar | Timeout zu knapp, oder die Firewall verwirft Pakete vom Server aus |
| Keine Mail | Kein Empfänger gesetzt, oder `mail` fehlt; `var/log/alerts.log` zeigt den Wechsel trotzdem |
| Statistik leer | Es gibt noch keine Messwerte — erst ein Lauf, dann eine Statistik |
| Status bleibt auf `-` | Für das Ziel gab es noch keinen Lauf; Menüpunkt 2 anstoßen |
| Cron läuft nicht | Pfad im Cron-Eintrag zeigt woandershin |
