# auto-update.sh — Automatische apt-Updates

Spielt apt-Updates per Cron ein und schickt einen Report per Mail. Wahlweise nur
Sicherheitsupdates oder alle Pakete.

## Voraussetzungen

- Debian oder Ubuntu (apt), root-Rechte
- für den Mail-Report: ein eingerichteter Mailer (`mail`-Kommando)

## Aufruf

```bash
sudo ./auto-update.sh              # Menü
sudo ./auto-update.sh --run        # ein Lauf, wie ihn Cron macht
sudo ./auto-update.sh --status     # Zeitplan und Umfang
sudo ./auto-update.sh --uninstall  # Cron und Konfiguration entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Einrichten / Einstellungen bearbeiten |
| 2 | Jetzt Updates einspielen (mit Ausgabe) |
| 3 | Ausstehende Updates anzeigen |
| 4 | Log anzeigen |
| 5 | Deinstallieren |
| 6 | Beenden |

## Einstellungen

| Einstellung | Optionen | Default |
|---|---|---|
| Zeitplan | täglich / wöchentlich | täglich |
| Wochentag | 0 = Sonntag … 6 = Samstag | Sonntag |
| Uhrzeit | HH:MM | 04:17 |
| Umfang | nur Sicherheitsupdates / alle Pakete | Sicherheitsupdates |
| autoremove | ja / nein | ja |
| Neustart bei Bedarf | automatisch / nur melden | nur melden |
| Report an | E-Mail-Adresse, leer = keine Mail | leer |
| Wann mailen | bei Änderungen und Fehlern / immer / nur bei Fehlern | bei Änderungen und Fehlern |

Gespeichert in `auto-update.conf` neben dem Skript.

## Cron

```
# /etc/cron.d/auto-update
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root /pfad/zu/auto-update.sh --run >/dev/null 2>&1
```

`/etc/cron.d` statt User-Crontab: explizites User-Feld (der Job läuft als root,
apt braucht also kein passwortloses `sudo`), eine Datei pro Job, und ein
setzbarer `PATH` — Cron startet sonst mit `/usr/bin:/bin`.

Der Pfad im Cron-Eintrag ist der beim Einrichten gültige. Verschiebt man das
Skript, muss man Menüpunkt 1 einmal erneut durchlaufen.

## Was ein Lauf macht

1. `apt-get update`
2. Paketliste ermitteln (siehe unten)
3. Nichts zu tun → Report „keine Updates", fertig
4. Sonst: bei „alle Pakete" ein `apt-get dist-upgrade`, bei
   „nur Sicherheitsupdates" ein `apt-get install --only-upgrade <liste>`
5. `apt-get autoremove`, falls eingeschaltet
6. `/var/run/reboot-required` prüfen
7. Report ins Log schreiben, ggf. mailen
8. Neustart, falls automatisch gewählt (`shutdown -r +1`)

### Wie Sicherheitsupdates erkannt werden

Über den Suite-Namen in `apt list --upgradable`, also `bookworm-security`,
`jammy-security` und so weiter. Eigene Repos ohne dieses Namensschema erwischt
der Modus nicht — wer solche einsetzt, nimmt „alle Pakete".

### Warum ohne `set -e`

Der Runner sammelt Fehler und meldet sie am Ende, statt mittendrin abzubrechen
und den Report zu verschlucken. Das Exit-Ergebnis ist trotzdem ≠ 0, wenn etwas
schiefging, und der Betreff beginnt dann mit `[FEHLER]`.

### dpkg-Konflikte

Aktualisierungen laufen mit

```
-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
```

Eine von Hand geänderte Konfigurationsdatei bleibt also, wie sie ist. Ein
unbeaufsichtigter Lauf darf nicht an einer Rückfrage hängen bleiben. Die neue
Fassung des Pakets liegt danach als `.dpkg-dist` daneben.

## Report

Betreffzeilen:

```
auto-update host: 7 Paket(e) aktualisiert
auto-update host: keine Updates
[FEHLER] auto-update host
```

Der Rumpf enthält Zeitstempel, Umfang, die Paketliste, die vollständige
apt-Ausgabe und den Hinweis auf einen nötigen Neustart.

Ohne eingerichteten Mailer landet alles nur im Log (`var/auto-update.log`,
begrenzt auf die letzten 2000 Zeilen).

## Angelegte Dateien

| Pfad | Inhalt |
|---|---|
| `auto-update.conf` | Konfiguration (neben dem Skript) |
| `var/auto-update.log` | Protokoll aller Läufe |
| `/etc/cron.d/auto-update` | Zeitplan |

## Deinstallation

Entfernt Cron-Eintrag und Konfiguration, fragt getrennt nach dem Log. Vorher
Sicherung nach `/root/auto-update-uninstall-<zeit>.tar.gz`. Bereits eingespielte
Updates bleiben selbstverständlich; es kommen nur keine neuen mehr automatisch.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Cron läuft nicht | Pfad im Cron-Eintrag stimmt nicht mehr (Skript verschoben) — Menüpunkt 1 erneut durchlaufen |
| „keine Updates", obwohl welche anstehen | Modus „nur Sicherheitsupdates" und die Pakete kommen aus einem Repo ohne `-security`-Suite |
| Keine Mail | `mail` fehlt oder kein Empfänger gesetzt; das Log sagt, welches von beidem |
| Report kommt jeden Tag, obwohl nichts passiert | „Wann mailen" steht auf „immer" |
| Neustart bleibt aus | Steht auf „nur melden" — der Hinweis steht im Report |
| `Could not get lock /var/lib/dpkg/lock` | Ein anderer apt-Vorgang lief gleichzeitig, etwa unattended-upgrades. Beides parallel zu betreiben ist nicht sinnvoll |
