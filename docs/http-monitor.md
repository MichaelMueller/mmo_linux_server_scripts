# http-monitor.sh — HTTP-Statuscode, Antwortzeit, Zertifikat

Ruft per Cron URLs ab, vergleicht den HTTP-Statuscode mit einem erwarteten Wert,
misst die Antwortzeit und überwacht die Restlaufzeit des TLS-Zertifikats.
Alarmiert bei Zustandswechsel.

## Abgrenzung zu tcp-monitor

`tcp-monitor` prüft, ob ein Port den Handshake annimmt — „lauscht da was?".
`http-monitor` prüft, ob die Anwendung dahinter antwortet, wie sie soll. Ein
nginx, der Port 443 annimmt und für jede Anfrage 502 liefert, ist für
`tcp-monitor` gesund und für `http-monitor` ausgefallen.

Der Preis dafür sind zwei echte Abhängigkeiten: `curl` und `openssl`.
`tcp-monitor` kommt bewusst ohne beide aus.

## Voraussetzungen

- `curl` (Pflicht — ohne curl bricht ein Lauf mit Meldung ab)
- `openssl` (nur für die Zertifikatsüberwachung; fehlt es, bleibt die Spalte `?`)
- root nur für den Cron-Eintrag
- für Mail-Alerts ein eingerichteter Mailer (`mail`-Kommando)

## Aufruf

```bash
sudo ./http-monitor.sh              # Menü
sudo ./http-monitor.sh --check      # ein Durchlauf, wie ihn Cron macht
sudo ./http-monitor.sh --status     # Zielliste auf stdout
sudo ./http-monitor.sh --uninstall  # Cron, Konfiguration und Daten entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Ziele verwalten (erstellen, bearbeiten, löschen) |
| 2 | Jetzt alle Ziele prüfen — derselbe Lauf wie per Cron, schreibt also Zustand und Messwerte fort und kann einen Alert auslösen |
| 3 | Ergebnisse und Statistik |
| 4 | Einstellungen |
| 5 | Deinstallieren |
| 6 | Beenden |

## Einstellungen

| Einstellung | Bedeutung | Default |
|---|---|---|
| Datenverzeichnis | wo Ziele, Messwerte und Zustand liegen | `var/http/` neben dem Skript |
| Prüfintervall | Minuten zwischen zwei Läufen | 5 |
| Standard-Timeout | Sekunden pro Anfrage | 10 |
| Standard-Statuscode | Vorgabe beim Anlegen eines Ziels | 200 |
| Zeitschwelle | ab wann ein Ziel als `SLOW` gilt, 0 = aus | 2000 ms |
| TLS-Warnung ab | Resttage, ab denen gewarnt wird, 0 = aus | 14 |
| Aufbewahrung | Tage, die Messwerte behalten werden | 30 |
| Webhook | URL, die bei Zustandswechsel ein JSON bekommt | leer |
| E-Mail | Adresse für Alerts | leer |

Gespeichert in `http-monitor.conf` neben dem Skript.

Das Datenverzeichnis liegt bewusst unter `var/http/` und nicht direkt in `var/`:
`tcp-monitor` und `disk-monitor` teilen sich bereits `var/`, und ein Ziel, das
in zwei Modulen denselben Namen trägt, würde sich sonst in `targets.d/` und
`state/` gegenseitig überschreiben.

## Ziele

Ein Ziel ist eine Datei in `var/http/targets.d/<name>.conf`:

```sh
NAME="webshop"
URL="https://shop.example.com/health"
EXPECT="200"
METHOD="GET"
TIMEOUT="10"
MAX_MS="2000"
FOLLOW="0"
INSECURE="0"
ENABLED="1"
NOTE="hinter dem Tunnel"
```

| Feld | Bedeutung |
|---|---|
| `EXPECT` | erwarteter Statuscode. Alles andere ist `DOWN` — auch ein 200, wenn 301 erwartet wurde |
| `METHOD` | `GET` (Default) oder `HEAD`. GET misst, was ein Besucher erlebt; der Body wird verworfen, es kostet nur Bandbreite. `HEAD` liefert bei manchen App-Servern und WAFs 405 oder 501 |
| `MAX_MS` | Schwelle für `SLOW`. `0` schaltet die Zeitmessung ab — dann verhält sich das Ziel wie bei `tcp-monitor` |
| `FOLLOW` | `0` = Weiterleitungen **nicht** folgen, der erwartete Code gilt für die erste Antwort. Nur so lässt sich ein 301 selbst als Sollzustand überwachen. `1` = folgen, dann zählt der Code der letzten Antwort |
| `INSECURE` | `1` schaltet curls Zertifikatsprüfung ab (selbstsigniert). Die Restlaufzeit wird trotzdem weiter überwacht — abgeschaltet wird die *Prüfung*, nicht die *Beobachtung* |

`ENABLED="0"` schaltet ein Ziel vorübergehend ab, ohne es zu löschen. Beim
Anlegen läuft sofort ein Testlauf — der schreibt den Zustand aber bewusst
**nicht** fort, damit ein von Anfang an kaputtes Ziel beim ersten Cron-Lauf
noch meldet.

Beim Löschen wird getrennt gefragt, ob auch die Messreihe verschwinden soll.

## Übersicht

```
NAME           URL                                AKTIV STATUS CODE  ZEIT    ZERT   LETZTE PRÜFUNG
-------------- ---------------------------------- ----- ------ ----- ------- ------ -------------------
webshop        https://shop.example.com/health    ja    UP     200   142ms   87d    2026-08-01 12:00:00
altdomain      http://alt.example.com             ja    UP     301   22ms    -      2026-08-01 12:00:01
api            https://api.example.com/health     ja    SLOW   200   2841ms  12d!   2026-08-01 12:00:03
tot            https://weg.example.com            ja    DOWN   000   3ms     ?      2026-08-01 12:00:13
```

In der Spalte `ZERT` steht die Restlaufzeit, `!` bei Warnung oder Ablauf, `?`
wenn das Zertifikat nicht abgefragt werden konnte, `-` bei `http://`.

## Zustandsmodell

Zwei Achsen, die getrennt alarmieren.

**Erreichbarkeit** — dreiwertig, geordnet:

| Status | Bedingung |
|---|---|
| `UP` | Antwort da, Code wie erwartet, innerhalb der Zeitschwelle |
| `SLOW` | Code wie erwartet, aber langsamer als `MAX_MS` |
| `DOWN` | curl-Fehler (Timeout, DNS, Verbindung, TLS) **oder** falscher Code |

`SLOW` ist ein eigener Zustand, kein Unterfall von `UP`. Wer erst degradiert und
dann ausfällt, sieht `UP → SLOW → DOWN` als drei einzelne Meldungen statt einer
späten.

**Zertifikat** — getrennt geführt:

| Status | Bedingung |
|---|---|
| `ok` | Restlaufzeit über der Schwelle |
| `warn` | Restlaufzeit unter der Schwelle, noch gültig |
| `expired` | Ablaufdatum überschritten |
| `unknown` | https, aber nicht abfragbar |
| `-` | kein https, oder Überwachung per `CERT_WARN_DAYS=0` aus |

Getrennt, weil ein bald ablaufendes Zertifikat **kein Ausfall** ist: Die Seite
liefert weiter ihren Code. Sie deswegen auf `DOWN` zu setzen wäre falsch, und
ein Ziel, das wochenlang in `WARN` steht, würde einen echten Ausfall in dieser
Zeit verschlucken.

`unknown` löst **nie** einen Alarm aus, weder hinein noch heraus. Sonst meldete
jeder Ausfall zusätzlich noch das Zertifikat, weil der Handshake mit
ausgefallen ist.

## Alarmierung

Gemeldet wird **nur der Zustandswechsel**:

| Übergang | Meldung |
|---|---|
| UP → SLOW → DOWN | ja, jeder Schritt einzeln |
| DOWN → DOWN | nein, kein Nachtreten |
| DOWN → UP | ja, Entwarnung |
| neu → UP | nein (Erstaufnahme im Normalzustand ist kein Vorfall) |
| neu → SLOW/DOWN | ja |
| Zertifikat ok → warn → expired | ja, je einmal |
| Zertifikat warn → ok | ja, Entwarnung mit neuer Restlaufzeit |

Deshalb kostet ein kürzeres Intervall **keine** zusätzlichen Mails — es
verkürzt nur die Erkennungszeit.

Alle Änderungen eines Laufs gehen in **eine** Mail. Fällt der Uplink aus, ist
sonst für jedes Ziel eine Mail unterwegs statt einer.

Jeder Wechsel geht zusätzlich nach `var/http/log/alerts.log`.

## Dateien

```
http-monitor.conf              Konfiguration
var/http/targets.d/*.conf      die Ziele
var/http/results/<name>.csv    timestamp,status,http_code,latency_ms,cert_days
var/http/state/<name>.state    status|zeit|code|ms|zertband|ablauf|geprüft
var/http/log/alerts.log        Zustandswechsel
var/http/.lock                 Sperre gegen überlappende Läufe
/etc/cron.d/http-monitor       Zeitplan
```

Die Trennung von Ziel und Zustand ist Absicht: das CRUD schreibt nur
`targets.d`, der Runner nur `state` und `results`. Ein gelöschtes Ziel
hinterlässt keine Karteileiche im Zustand.

## Zertifikatsprüfung

Über `openssl s_client`, nicht über curl: `--certinfo` ist nicht in jedem
curl-Build vorhanden, und das Ablaufdatum wird gerade dann gebraucht, wenn die
Kette *nicht* validiert — bei einem selbstsignierten Zertifikat bricht curl
vorher ab, `s_client` liefert es trotzdem.

Das Ablaufdatum wird nur alle 12 Stunden neu geholt und in der State-Datei als
Unix-Zeit gespeichert. Ein TLS-Handshake alle fünf Minuten wäre reine Last, das
Datum ändert sich nur bei einer Erneuerung. Die **Restlaufzeit in Tagen** wird
trotzdem bei jedem Lauf neu gerechnet, damit die Warnschwelle taggenau
anschlägt.

Schlägt die Abfrage fehl, bleibt das zuletzt bekannte Datum stehen: Ein Ausfall
darf die Ablaufüberwachung nicht zurücksetzen.

## Statistik (Menüpunkt 3)

Für ein Ziel: Anzahl Messungen, Aufteilung auf UP/SLOW/DOWN, Verfügbarkeit in
Prozent (UP und SLOW zählen als erreichbar), mittlere und maximale Antwortzeit,
die Verteilung der Statuscodes und die letzten 20 Messwerte. Ohne Angabe eines
Namens: die letzten 30 Zustandswechsel.

Messwerte älter als `RETENTION_DAYS` werden bei jedem Lauf abgeschnitten.

## Cron

```
# /etc/cron.d/http-monitor
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /pfad/zu/http-monitor.sh --check >/dev/null 2>&1
```

Der Pfad ist der beim Einrichten gültige. Nach dem Verschieben des Skripts
Menüpunkt 4 einmal durchlaufen.

Exit-Code von `--check` ist 1, solange ein Ziel nicht `UP` ist oder ein
Zertifikat sein Band gewechselt hat.

Ein Lauf braucht im schlimmsten Fall *Ziele × Timeout* Sekunden, weil jeder
Timeout nacheinander abgesessen wird. Damit sich Läufe nicht überholen, hält
`--check` eine Sperre über `var/http/.lock`; ein Lauf, der einen noch laufenden
antrifft, überspringt sich. Fehlt `flock` auf dem System, wird ohne Sperre
gearbeitet — lieber ein möglicher Überlapp als gar kein Lauf.

## Datenhaltung

**Eigener Zustand, unvermeidlich:** es gibt keinen Dienst, der Ziele und
Messreihe halten könnte. Alles liegt unter `DATA_DIR` — Default `var/http/`
neben dem Skript, beim Einrichten aber frei wählbar, etwa `/var/lib/mmo-http`.
Am System selbst wird nur der Cron-Eintrag angelegt.

Der Cron-Eintrag merkt sich den beim Einrichten gültigen Pfad. Verschiebt man
das Skript oder `DATA_DIR`, einmal durch die Einstellungen gehen.

## Deinstallation

Entfernt Cron-Eintrag und Konfiguration, fragt getrennt nach dem
Datenverzeichnis. Vorher Sicherung nach
`/root/http-monitor-uninstall-<zeit>.tar.gz`. Es wurden keine Pakete
installiert, es bleibt nichts zurück.

Weil `DATA_DIR` auf `var/http/` zeigt, trifft das Löschen nur die eigenen
Daten — `tcp-monitor` und `disk-monitor` in `var/` bleiben unangetastet.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| „Nicht eingerichtet" beim `--check` | `http-monitor.conf` fehlt — das Menü einmal durchlaufen |
| „curl ist nicht installiert" | `apt install curl`; ohne curl läuft keine Prüfung |
| Ziel meldet DOWN mit Code 000 | gar keine Antwort — DNS, Firewall oder Timeout, der Grund steht im Alert-Log |
| Ziel meldet DOWN mit Code 301 | Weiterleitung, aber `FOLLOW="0"` — entweder `EXPECT="301"` setzen oder `FOLLOW="1"` |
| Ziel meldet DOWN mit 405 oder 501 | `METHOD="HEAD"` gegen einen Server, der nur GET beantwortet |
| Alles ständig SLOW | `MAX_MS` zu knapp; `0` schaltet die Zeitmessung ab |
| Zertifikatsspalte zeigt `?` | `openssl` fehlt, oder der Handshake scheitert (Port, SNI, Firewall) |
| Keine Mail | Kein Empfänger gesetzt, oder `mail` fehlt; `var/http/log/alerts.log` zeigt den Wechsel trotzdem |
| Läufe werden übersprungen | Ein Lauf dauert länger als das Intervall — Timeout senken oder Intervall erhöhen |
| Status bleibt auf `-` | Für das Ziel gab es noch keinen Lauf; Menüpunkt 2 anstoßen |
| Cron läuft nicht | Pfad im Cron-Eintrag zeigt woandershin |
