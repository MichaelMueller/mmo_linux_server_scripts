# git-updater.sh — Arbeitskopien aktuell halten

Hält Git-Arbeitskopien per Cron auf dem Stand des Remotes: pro Verzeichnis ein
Eintrag, standardmäßig alle fünf Minuten ein `git pull`. Auf Wunsch läuft nach
einem Update ein Kommando, etwa `docker compose up -d`.

## Voraussetzungen

- `git` (installiert `base-tools.sh` immer mit)
- root für den Cron-Eintrag; die Pulls laufen als der jeweilige Eigentümer
- für Mail-Benachrichtigungen ein eingerichteter Mailer (`mail`-Kommando)

## Aufruf

```bash
sudo ./git-updater.sh              # Menü
sudo ./git-updater.sh --run        # ein Durchlauf, wie ihn Cron macht
sudo ./git-updater.sh --status     # Einträge auf stdout
sudo ./git-updater.sh --uninstall  # Cron, Konfiguration und Daten entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Repositories verwalten (anlegen, bearbeiten, entfernen) |
| 2 | Jetzt alle aktualisieren — derselbe Lauf wie per Cron |
| 3 | Einstellungen (Intervall, Zeitlimit, Benachrichtigung) |
| 4 | Log anzeigen |
| 5 | Deinstallieren |
| 6 | Beenden |

## Einstellungen

| Einstellung | Bedeutung | Default |
|---|---|---|
| Datenverzeichnis | wo Einträge, Zustand und Logs liegen | `var/` neben dem Skript |
| Prüfintervall | Minuten zwischen zwei Läufen | 5 |
| Zeitlimit | Sekunden je git-Aufruf | 120 |
| Mail bei Update | wenn neue Commits geholt wurden | ja |
| Mail bei Fehler | wenn ein Repo nicht aktualisiert werden konnte | ja |
| Mail ohne Änderung | auch wenn es nichts zu tun gab | nein |

Gespeichert in `git-updater.conf` neben dem Skript.

## Ein Eintrag

Eine Datei in `var/repos.d/<name>.conf`:

```sh
NAME="webapp"
REPO_PATH="/srv/webapp"
BRANCH="main"                          # leer = der gerade ausgecheckte
RUN_USER="deploy"
POST_CMD="docker compose up -d"        # nur bei neuen Commits, optional
ENABLED="1"
NOTE="Produktion"
```

Beim Anlegen prüft das Skript, dass unter dem Verzeichnis wirklich ein `.git`
liegt, und schlägt als Benutzer den **Eigentümer des Verzeichnisses** vor — das
ist fast immer der richtige. Danach läuft sofort ein Testlauf, damit man nicht
bis zum nächsten Cron-Durchgang auf die erste Rückmeldung wartet.

`ENABLED="0"` setzt einen Eintrag vorübergehend aus, ohne ihn zu löschen. Beim
Entfernen eines Eintrags bleibt die Arbeitskopie auf der Platte.

## Übersicht

```
NAME             VERZEICHNIS                        BRANCH       BENUTZER  AKTIV   STAND
webapp           /srv/webapp                        main         deploy    ja      OK 2026-08-01 09:15:02
doku             /srv/doku                          (aktueller)  www-data  ja      UPDATED 2026-08-01 09:10:01
altprojekt       /srv/alt                           main         deploy    nein    -
```

## Wie ein Lauf abläuft

Je Eintrag:

1. liegt dort ein Git-Repository?
2. gibt es **lokale Änderungen**? Dann Fehler — und zwar bevor irgendetwas
   angefasst wird
3. falls ein Branch eingetragen ist: `git checkout <branch>`
4. `git pull --ff-only`
5. hat sich der Commit geändert und ist ein `POST_CMD` gesetzt: ausführen
6. Ergebnis in den Zustand schreiben, Änderungen sammeln

Am Ende geht **eine** Mail raus, die alle Änderungen des Laufs auflistet — nicht
eine pro Repository.

### Die wichtigen Entscheidungen

**`--ff-only`, niemals mergen oder rebasen.** Läuft die Arbeitskopie
auseinander, soll das auffallen und nicht stillschweigend ein Merge-Commit
entstehen, den niemand angefordert hat. Ein automatischer Prozess, der Historie
umschreibt, ist keine gute Idee.

**Lokale Änderungen sind ein Fehler, kein Anlass zum Aufräumen.** Das Skript
verwirft nichts und stasht nichts. Wer im Produktionsverzeichnis etwas
geändert hat, hatte vermutlich einen Grund — und ein Cronjob, der solche
Änderungen wegräumt, ist ein Datenverlust mit Zeitschaltuhr.

**Als Eigentümer statt als root.** Läuft git als der Eigentümer, greifen dessen
SSH-Schlüssel und Credential-Helper, und gits Schutz gegen fremde Verzeichnisse
(`detected dubious ownership`) kommt gar nicht erst zum Tragen. Kein
`safe.directory`-Geflicke nötig.

**Niemals interaktiv.** `GIT_TERMINAL_PROMPT=0` und `ssh -o BatchMode=yes`
sorgen dafür, dass ein Lauf sofort abbricht, statt auf eine Passphrase oder eine
Host-Key-Bestätigung zu warten. Zusätzlich begrenzt `timeout` jeden Aufruf. Ohne
das hängt ein Cronjob bei einem privaten Repo bis in alle Ewigkeit — und beim
nächsten Takt noch einmal.

**Eine Sperre gegen Überlappung.** Bei fünf Minuten Takt kann ein langsamer Lauf
in den nächsten laufen; `flock` verhindert das. Fehlt `flock`, wird ohne Sperre
gearbeitet — lieber ein möglicher Überlapp als gar kein Lauf.

### Fehler werden nur beim Wechsel gemeldet

Wie beim TCP-Monitoring gibt es kein Nachtreten:

| Übergang | Meldung |
|---|---|
| OK → Fehler | ja |
| Fehler → Fehler | **nein** |
| Fehler → OK | ja, Entwarnung |
| neue Commits geholt | ja (falls eingeschaltet) |

Der Exit-Code von `--run` ist 1, solange irgendein Eintrag im Fehlerzustand ist —
auch wenn deswegen keine Mail rausgeht.

### Typische Fehlermeldungen

| Meldung | Bedeutung |
|---|---|
| `lokale Änderungen in der Arbeitskopie` | `git status` ist nicht sauber |
| `Arbeitskopie ist auseinandergelaufen (kein Fast-Forward)` | lokale Commits, die nicht im Remote sind |
| `kein Upstream für den Branch gesetzt` | `git branch --set-upstream-to=origin/<branch>` fehlt |
| `kein Zugriff auf das Remote (SSH-Schlüssel für …?)` | der Benutzer kommt nicht ans Remote |
| `Zeitüberschreitung nach 120s` | Netz oder Remote hängt |

## Das Kommando nach dem Update

`POST_CMD` läuft **nur**, wenn tatsächlich neue Commits geholt wurden — im
Verzeichnis der Arbeitskopie und als der eingetragene Benutzer, nicht als root.
Scheitert es, gilt der Eintrag als Fehler und die Meldung enthält die erste
Zeile der Ausgabe.

Sinnvolle Beispiele:

```sh
POST_CMD="docker compose up -d"
POST_CMD="systemctl --user restart meinapp"
POST_CMD="npm ci --omit=dev && systemctl restart meinapp"
```

Beim letzten Beispiel muss der Benutzer den `systemctl restart` auch dürfen —
sonst über einen sudo-Eintrag mit `NOPASSWD` für genau dieses Kommando.

## Datenhaltung

**Eigener Zustand, unvermeidlich:** git selbst weiß nicht, dass es regelmäßig
gepullt werden soll. Alles liegt unter `DATA_DIR` — Default `var/` neben dem
Skript, beim Einrichten frei wählbar.

```
git-updater.conf           Konfiguration
var/repos.d/*.conf         die Einträge
var/state/<name>.state     ergebnis|zeit|detail
var/log/alerts.log         Meldungen
var/log/git-updater.log    Lauf-Protokoll (letzte 2000 Zeilen)
var/.lock                  Sperre gegen überlappende Läufe
/etc/cron.d/git-updater    Zeitplan
```

**An den Arbeitskopien wird nichts verändert außer dem Pull selbst** — keine
git-Konfiguration, keine Remotes, keine Branches werden angelegt. Ein Repo, das
von Hand geklont und eingerichtet wurde, funktioniert unverändert weiter, und
man kann jederzeit selbst darin arbeiten.

## Deinstallation

Entfernt Cron-Eintrag und Konfiguration, fragt getrennt nach dem
Datenverzeichnis. Vorher Sicherung nach
`/root/git-updater-uninstall-<zeit>.tar.gz`. **Die Arbeitskopien bleiben
unangetastet** — es wird nur nicht mehr automatisch gepullt.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Nichts passiert, Log leer | Cron-Eintrag fehlt oder zeigt auf einen alten Pfad — Menüpunkt 3 einmal durchlaufen |
| „Ein Lauf ist noch nicht fertig" | Der vorige Lauf hängt; Zeitlimit prüfen und ob das Remote erreichbar ist |
| Bei privaten Repos immer „kein Zugriff" | Der eingetragene Benutzer hat keinen passenden SSH-Schlüssel. Einmal von Hand testen: `sudo -u <benutzer> ssh -T git@github.com` |
| Funktioniert von Hand, aber nicht per Cron | Fast immer ein Prompt (Passphrase, Host-Key) — im Cron ist das abgeschaltet, also erst von Hand als der Benutzer erledigen |
| `POST_CMD` läuft nicht | Es läuft nur bei tatsächlich neuen Commits; ohne Änderung passiert nichts |
| Repo bleibt auf altem Stand, ohne Fehler | Es hängt an einem anderen Branch als erwartet — Branch im Eintrag ausdrücklich setzen |
| Ständig „lokale Änderungen" | Oft erzeugt vom Dienst selbst (Logs, Caches im Repo). Diese Pfade gehören in `.gitignore` oder außerhalb der Arbeitskopie |
