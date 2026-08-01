# disk-monitor.sh — Speicherplatz-Überwachung

Prüft per Cron die Belegung aller echten Dateisysteme, hält eine Messreihe,
rechnet hoch, wann es eng wird, und alarmiert bei Zustandswechsel.

## Voraussetzungen

- Linux mit GNU coreutils (`df --output`), root-Rechte
- für Mail-Alerts ein eingerichteter Mailer (`mail`-Kommando)

## Aufruf

```bash
sudo ./disk-monitor.sh              # Menü
sudo ./disk-monitor.sh --check      # ein Durchlauf, wie ihn Cron macht
sudo ./disk-monitor.sh --status     # Belegung und Prognose auf stdout
sudo ./disk-monitor.sh --uninstall  # Cron, Konfiguration und Daten entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Einrichten / Einstellungen bearbeiten |
| 2 | Jetzt prüfen (zeigt auch, was gemailt würde) |
| 3 | Ausschlüsse verwalten |
| 4 | Alerts anzeigen |
| 5 | Deinstallieren |
| 6 | Beenden |

Die Übersicht steht direkt im Hauptmenü:

```
MOUNTPOINT                BELEGT   INODES    FREI GB  GESAMT GB  STAND TREND
/                            72%      12%       28.1      100.0  ok    +0.50 %/Tag, voll in ca. 56 Tagen
/var                         91%       8%        4.2       50.0  warn  +1.20 %/Tag, voll in ca. 7 Tagen
/backup                      40%       2%      600.0     1000.0  ok    stabil oder rückläufig (-0.10 %/Tag)
```

## Schwellen

| Einstellung | Bedeutung | Default |
|---|---|---|
| `WARN_PCT` | Warnung ab Belegung in % | 85 |
| `CRIT_PCT` | kritisch ab Belegung in % | 95 |
| `INODE_WARN` | Warnung ab Inode-Belegung in % | 90 |
| `MIN_FREE_GB` | zusätzlich warnen, wenn weniger frei ist (0 = aus) | 0 |
| `INTERVAL_MIN` | Prüfabstand in Minuten | 60 |
| `RETENTION_DAYS` | Aufbewahrung der Messreihe in Tagen | 90 |
| `TOP_DIRS` | größte Verzeichnisse in den Alert schreiben | 1 |
| `ALERT_MODE` | `change` oder `always` | `change` |
| `ALERT_MAIL`, `ALERT_WEBHOOK` | Ziele für Alerts | leer |
| `EXCLUDE` | Mountpoints, die ignoriert werden | leer |

Gespeichert in `disk-monitor.conf` neben dem Skript. Liegt `CRIT_PCT` nicht über
`WARN_PCT`, wird es automatisch korrigiert.

### Warum eine Inode-Prüfung?

Ein Dateisystem kann voll sein, obwohl reichlich Platz frei ist — dann sind die
Inodes aufgebraucht. Typisch bei Millionen kleiner Dateien (Session-Dateien,
Maildirs, Cache). `df -h` zeigt davon nichts, `df -i` schon. Beides kommt hier
aus demselben Aufruf.

### Warum `MIN_FREE_GB`?

Prozentwerte sind auf großen Platten irreführend: 5 % von 4 TB sind 200 GB, 5 %
von 20 GB sind ein Gigabyte. Wer eine absolute Untergrenze braucht, setzt sie
zusätzlich.

## Welche Dateisysteme geprüft werden

Pseudo-Dateisysteme werden übersprungen: `tmpfs`, `devtmpfs`, `squashfs`,
`overlay`, `proc`, `sysfs`, `cgroup`, und weitere. `tmpfs` läuft nie „voll" im
Sinne eines Problems, und `squashfs` (jedes snap-Paket) ist per Definition zu
100 % belegt — ohne diesen Filter bestünde der Alert nur aus Fehlalarmen.

Weitere Mountpoints lassen sich über Menüpunkt 3 ausschließen.

Eingelesen wird mit

```bash
df -B1K --output=fstype,pcent,ipcent,avail,size,target
```

Damit steht der Mountpoint garantiert am Zeilenende — er darf Leerzeichen
enthalten und würde in der klassischen `df`-Ausgabe alle Felder verschieben.

## Alarmierung

Gemeldet wird der **Zustandswechsel** zwischen `ok`, `warn` und `crit`:

| Übergang | Meldung |
|---|---|
| ok → warn / warn → crit | ja |
| warn → warn | nein, kein Nachtreten |
| crit → ok | ja, Entwarnung |
| neu → ok | nein |
| neu → warn/crit | ja |

`ALERT_MODE="always"` meldet stattdessen bei jedem Lauf, solange etwas über der
Schwelle liegt — für den Fall, dass eine tägliche Erinnerung gewünscht ist.

Eine Mail pro Lauf, die alle Änderungen auflistet, nicht eine pro Mountpoint.

### Was in der Mail steht

```
Speicherplatz auf server.example.com
Stand: 2026-08-01 09:00:02

Änderungen:
  - WARN /var: Belegung 91% >= 85%

Belegung:
  <df -hT ohne Pseudo-Dateisysteme>

/var
  Trend: +1.20 %/Tag, voll in ca. 7 Tagen
  Größte Verzeichnisse unter /var (max. 2 Ebenen, ohne andere Dateisysteme):
    ...
```

Die Verzeichnisliste kommt aus `du -x -h --max-depth=2`. `-x` bleibt auf dem
Dateisystem, sonst würde `du` auf `/` durch alle Mounts laufen. Auf sehr großen
Dateisystemen dauert das — deshalb abschaltbar (`TOP_DIRS=0`).

## Die Prognose

Lineare Hochrechnung aus der ältesten und der jüngsten Messung in der
Messreihe: Rate in Prozentpunkten pro Tag, daraus die Tage bis 100 %. Sie
erscheint erst, wenn mindestens ein Tag Historie vorliegt, und meldet bei
Rückgang „stabil oder rückläufig".

Das ist grob und unterstellt gleichmäßiges Wachstum — beantwortet aber genau die
Frage, die man bei einer Warnung hat: reicht es noch bis zum Wartungsfenster?

## Dateien

```
disk-monitor.conf            Konfiguration
var/results/usage.csv        timestamp,mount,pct,inode_pct,free_gb
var/state/<slug>.state       zustand|zeit|belegt|inodes
var/log/alerts.log           Zustandswechsel
var/log/disk.log             Laufprotokoll (letzte 2000 Zeilen)
/etc/cron.d/disk-monitor     Zeitplan
```

Der Slug ist der Mountpoint mit `/` als `_`, `/` selbst heißt `root`.

Exit-Code von `--check` ist 1, solange ein Dateisystem über der Schwelle liegt.

## Deinstallation

Entfernt Cron-Eintrag und Konfiguration, fragt getrennt nach dem
Datenverzeichnis. Vorher Sicherung nach
`/root/disk-monitor-uninstall-<zeit>.tar.gz`. Es wurden keine Pakete
installiert, es bleibt nichts zurück.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| `df: unrecognized option '--output'` | Kein GNU coreutils (BusyBox, sehr altes System) |
| Ein Mountpoint fehlt in der Liste | Pseudo-Dateisystem oder in `EXCLUDE`; Menüpunkt 3 zeigt beides |
| Inodes stehen auf 0 % | Das Dateisystem kennt keine feste Inode-Tabelle (btrfs, zfs, xfs teils) — `df` liefert dort `-` |
| Keine Prognose | Weniger als ein Tag Messreihe, oder das Dateisystem ist erst neu dazugekommen |
| Prüfung dauert lange | `du` für die größten Verzeichnisse; `TOP_DIRS=0` schaltet das ab |
| Ständig Mails trotz `change` | Die Belegung pendelt um die Schwelle — Schwelle etwas anheben oder Intervall verlängern |
| Keine Mail | Kein Empfänger, oder `mail` fehlt; `var/log/alerts.log` hat den Wechsel trotzdem |
