# docker-setup.sh — Docker

Installiert Docker aus dem offiziellen Repo und stellt die drei Dinge ein, die
auf einem Server sonst irgendwann weh tun: Log-Rotation, die Bindung
veröffentlichter Ports und das Aufräumen.

## Voraussetzungen

- Debian oder Ubuntu, root-Rechte
- ausgehender Internetzugang für Repo und Images

## Aufruf

```bash
sudo ./docker-setup.sh              # Menü
sudo ./docker-setup.sh --prune      # Aufräumlauf, wie ihn Cron macht
sudo ./docker-setup.sh --status     # Status auf stdout
sudo ./docker-setup.sh --uninstall  # Einstellungen entfernen (nicht Docker)
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Installieren |
| 2 | Status anzeigen |
| 3 | Einstellungen (Log-Rotation, Port-Bindung, live-restore) |
| 4 | Benutzer zur Gruppe `docker` hinzufügen |
| 5 | Aufräumen |
| 6 | Deinstallieren |
| 7 | Beenden |

## Installation

Aus dem offiziellen Repo, nicht aus der Distribution: `docker.io` hinkt meist
mehrere Versionen hinterher und bringt das compose-Plugin nicht mit.

Installiert werden `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin` und `docker-compose-plugin` (also `docker compose`, nicht
das alte `docker-compose`).

Vorher wird auf konkurrierende Pakete geprüft — `docker.io`, `docker-compose`,
`podman-docker`, `containerd`, `runc` — und angeboten, sie zu entfernen. Daten
unter `/var/lib/docker` bleiben dabei erhalten.

Bei Derivaten (Linux Mint & Co.) gibt es für den eigenen Codenamen kein
Docker-Repo; das Skript nimmt dann `UBUNTU_CODENAME` bzw. `DEBIAN_CODENAME` aus
`/etc/os-release` und fragt notfalls nach.

## Einstellungen

Geschrieben wird `/etc/docker/daemon.json`:

```json
{
  "_comment": "erzeugt von docker-setup.sh",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "ip": "127.0.0.1",
  "userland-proxy": true
}
```

Eine vorhandene, fremde `daemon.json` wird **nicht** zusammengeführt, sondern
nach `daemon.json.orig.<epoch>` gesichert und im Klartext angezeigt — JSON in
bash zu mischen wäre geraten, nicht gerechnet. Die eigenen Einträge übernimmt
man von Hand.

Die gewählten Werte liegen zusätzlich in `docker-setup.conf` neben dem Skript,
damit die Datei jederzeit reproduzierbar neu geschrieben werden kann.

### Log-Rotation

Ohne `log-opts` wächst jede Container-Logdatei unter
`/var/lib/docker/containers/<id>/` **unbegrenzt**. Das ist die häufigste Ursache
für eine volle Platte auf einem Docker-Host: ein gesprächiger Container schreibt
über Monate stillschweigend Dutzende Gigabyte. Default hier: 10 MB × 3 Dateien
pro Container.

Die Einstellung wirkt nur auf **neu erstellte** Container. Bestehende behalten
ihre Log-Konfiguration, bis sie neu angelegt werden.

### Port-Bindung — der wichtige Punkt

**Docker umgeht ufw.** Veröffentlichte Ports (`-p 8080:80`) trägt Docker direkt
in die `DOCKER`-Kette der iptables ein, und die wird vor den ufw-Regeln
ausgewertet. Eine Regel `ufw deny 8080` schützt den Container **nicht** — er ist
aus dem Internet erreichbar, obwohl die Firewall etwas anderes behauptet. Das
überrascht regelmäßig, auch erfahrene Leute.

Die Gegenmaßnahme hier ist `"ip": "127.0.0.1"`: damit landen alle
veröffentlichten Ports ohne ausdrückliche Adresse auf der Loopback-Schnittstelle.
Erreichbar sind sie dann nur noch lokal — also über einen Reverse Proxy
(`caddy-manager` oder `nginx-manager`), der TLS und Zugriff regelt. Genau so will
man das auf einem Server, der Webdienste ausliefert.

Wer einen Port doch nach außen braucht, gibt die Adresse explizit an:
`-p 0.0.0.0:8080:80`. Dann ist es eine bewusste Entscheidung statt eines
Versehens.

Menüpunkt 2 zeigt am Ende ausdrücklich alle laufenden Container, deren Ports auf
`0.0.0.0` oder `::` gebunden sind.

### live-restore

Lässt Container weiterlaufen, während der Docker-Dienst neu startet — etwa bei
einem Paket-Update durch `auto-update`. Ohne die Option gehen bei jedem
Daemon-Neustart alle Container kurz aus. Nicht kombinierbar mit Swarm-Mode.

## Gruppe `docker` (Punkt 4)

> Wer in der Gruppe `docker` ist, kann über einen Container jede Datei des
> Systems als root lesen und schreiben — etwa mit
> `docker run -v /:/host …`. Das ist gleichbedeutend mit root-Rechten, nur ohne
> sudo-Protokoll.

Das Skript sagt das vor der Aufnahme deutlich und zeigt, wer schon drin ist. Die
Mitgliedschaft wirkt erst nach der nächsten Anmeldung des Benutzers.

## Aufräumen (Punkt 5)

Zeigt `docker system df` und bietet an:

- **jetzt aufräumen** — `docker system prune -f --filter until=<h>h`
- **wöchentliche Automatik** — Cron-Eintrag `/etc/cron.d/docker-prune`,
  sonntags zur gewählten Stunde
- **ungenutzte Volumes anzeigen** — nur anzeigen, nicht löschen

Zwei bewusste Entscheidungen:

- **Volumes werden nie automatisch entfernt.** Dort liegen die Daten, und ein
  Volume ohne laufenden Container ist noch lange kein überflüssiges Volume — ein
  gestoppter Datenbank-Container ist der Normalfall, kein Müll. Sie werden nur
  aufgelistet, das Löschen bleibt Handarbeit.
- **`-a` ist abschaltbar und standardmäßig aus.** Ohne `-a` fliegen nur Images
  ohne Tag raus. Mit `-a` auch getaggte Images, die gerade kein Container
  benutzt — die müssen beim nächsten Start neu geladen werden, was ohne
  Internetzugang oder bei großen Images unangenehm ist.

Der Altersfilter (Default 168 h = 7 Tage) verhindert, dass ein gerade gebautes,
noch nicht gestartetes Image sofort wieder verschwindet.

## Angelegte Dateien

| Pfad | Inhalt |
|---|---|
| `/etc/docker/daemon.json` | die Einstellungen oben |
| `docker-setup.conf` | dieselben Werte, neben dem Skript |
| `/etc/cron.d/docker-prune` | wöchentliches Aufräumen, falls aktiviert |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.asc` | das Repo |

## Datenhaltung

**Service-seitig:** maßgeblich ist `/etc/docker/daemon.json`, Dockers eigene
Konfiguration. `docker-setup.conf` neben dem Skript hält dieselben Werte noch
einmal — nur als Bequemlichkeit, damit die Datei reproduzierbar neu geschrieben
werden kann. Weicht sie ab, gilt `daemon.json`.

Auf eine bestehende Docker-Installation aufsetzbar: eine fremde `daemon.json`
wird nach `.orig.<epoch>` gesichert, im Klartext angezeigt und erst nach
Rückfrage ersetzt — eigene Einträge übernimmt man daraus von Hand. Container,
Images und Volumes werden nie angefasst, auch nicht bei der Deinstallation.

## Deinstallation

Entfernt die **Einstellungen**, nicht Docker: `daemon.json` (aus der
`.orig`-Sicherung wiederhergestellt, sonst gelöscht), `docker-setup.conf` und
den Cron-Eintrag. Auf Wunsch wird Docker neu gestartet, damit die Änderung
greift. Vorher Sicherung nach `/root/docker-setup-uninstall-<zeit>.tar.gz`.

Laufende Container, Images und **vor allem die Volumes bleiben unangetastet**.
Vollständig entfernen:

```bash
apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
rm -rf /var/lib/docker /var/lib/containerd
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
```

> `rm -rf /var/lib/docker` löscht **alle Volumes** und damit die Daten sämtlicher
> Container. Das ist kein Aufräumen, das ist ein Datenverlust mit Ansage.

Nach der Deinstallation wachsen Container-Logs wieder unbegrenzt — `disk-monitor.sh`
merkt das rechtzeitig.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Container trotz `ufw deny` aus dem Netz erreichbar | Docker umgeht ufw; Port an `127.0.0.1` binden (Menüpunkt 3) oder explizit `-p 127.0.0.1:…` |
| Docker startet nach Einstellungsänderung nicht | Syntaxfehler oder unbekannter Schlüssel in `daemon.json`; das Skript zeigt bei Fehlschlag `journalctl -u docker` |
| `permission denied` beim Docker-Socket | Benutzer nicht in der Gruppe `docker`, oder noch nicht neu angemeldet |
| Platte voll trotz Rotation | Rotation gilt nur für neu erstellte Container; die alten einmal neu anlegen |
| `docker compose` nicht gefunden | Es wurde `docker-compose` (v1) erwartet — das Plugin heißt `docker compose`, ohne Bindestrich |
| Image nach dem Aufräumen weg | `-a` war aktiv; die Option in Menüpunkt 5 abschalten |
| Repo-Fehler „no Release file" | Codename gehört zu einem Derivat ohne eigenes Docker-Repo — den der Basisdistribution nehmen |
