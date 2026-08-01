# caddy-manager.sh — Caddy-vHosts

Verwaltet vHosts in Caddy: statische Dateien, Weiterleitungen und Reverse Proxy.
TLS wird auf diesem Server terminiert, die Zertifikate holt Caddy selbst von
Let's Encrypt.

> Braucht Port 80 und 443 und schließt sich damit mit `nginx-manager` aus.

## Voraussetzungen

- Debian oder Ubuntu, root-Rechte
- Caddy — wird bei Bedarf aus dem offiziellen Repo installiert
- die Domain muss per DNS auf diesen Server zeigen, sonst gibt es kein
  Zertifikat

## Aufruf

```bash
sudo ./caddy-manager.sh              # Menü
sudo ./caddy-manager.sh --uninstall  # vHosts und Caddyfile entfernen
```

Die Ersteinrichtung passiert automatisch beim Anlegen des ersten Hosts.

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Host erstellen |
| 2 | Host anzeigen |
| 3 | Host bearbeiten |
| 4 | Host löschen |
| 5 | Config prüfen (`caddy validate`) |
| 6 | Logs (`journalctl -u caddy`) |
| 7 | Deinstallieren |
| 8 | Beenden |

## Aufbau

```
/etc/caddy/Caddyfile                globale Optionen + import
/etc/caddy/sites.d/<domain>.caddy   je vHost eine Datei
/etc/caddy/sites-meta.d/<domain>.meta   TYPE= und TARGET= für die Übersicht
/var/log/caddy/<domain>.log         Zugriffslog je vHost
```

Das Caddyfile enthält nur:

```
{
    email admin@example.com
}

import /etc/caddy/sites.d/*.caddy
```

Die Metadatei daneben speichert Typ und Ziel, damit die Übersicht das anzeigen
kann, ohne Caddy-Syntax zu parsen.

## Die drei Typen

### Statische Dateien

| Frage | Default |
|---|---|
| Verzeichnis | `/var/www/<domain>` |
| Anlegen, falls nicht vorhanden | ja (mit Platzhalter-`index.html`) |
| Directory-Listing (`browse`) | nein |
| Basic-Auth | nein |

Erzeugt `root`, `encode zstd gzip`, `file_server` und einen Log-Block.

### Weiterleitung

| Frage | Default |
|---|---|
| Ziel-URL | Pflicht |
| 301 permanent / 302 temporär | 301 |
| Pfad und Query übernehmen | ja (`{uri}`) |

### Reverse Proxy

| Frage | Bemerkung |
|---|---|
| Backend(s) | mehrere space-getrennt |
| Backend spricht HTTPS | dann `transport http { tls }` |
| Zertifikat des Backends nicht prüfen | für selbstsignierte Backends |
| Pfad-Präfix | z. B. `/api`, leer = alles |
| WebSocket-/Streaming-Modus | setzt `flush_interval -1` |
| Original-Host-Header weitergeben | Default ja |
| Health-Check | Pfad und Intervall 30 s |
| Load-Balancing | bei mehreren Backends: round_robin / least_conn / ip_hash |
| Basic-Auth | Passwort wird mit `caddy hash-password` gehasht |

`X-Real-IP` wird immer gesetzt.

## Zertifikate

Caddy beantragt sie automatisch, sobald der vHost aktiv ist und die Domain auf
den Server zeigt. Die angegebene E-Mail-Adresse landet in den globalen Optionen
und dient Let's Encrypt als Kontakt.

Die Zertifikate liegen unter `/var/lib/caddy`. Beim Löschen eines vHosts bleiben
sie dort liegen — absichtlich, damit ein versehentlich gelöschter Host ohne
neuen Antrag zurückkommt.

## Validierung und Rollback

Nach jedem Schreiben läuft `caddy validate`. Lehnt Caddy die Konfiguration ab,
wird die Änderung zurückgenommen (beim Bearbeiten aus `<datei>.bak`, beim
Anlegen durch Löschen) und neu geladen. Ein Tippfehler nimmt nie die anderen
vHosts mit.

Bearbeiten geht wahlweise über den Assistenten (Typ frei wählbar) oder direkt im
Editor (`$EDITOR`, sonst nano).

## Ersteinrichtung im Detail

1. Caddy aus dem Cloudsmith-Repo installieren, falls nicht vorhanden
2. `sites.d/` und `sites-meta.d/` anlegen
3. E-Mail für Let's Encrypt erfragen
4. ein **vorhandenes Caddyfile, das nicht von hier stammt**, nach
   `Caddyfile.orig.<epoch>` sichern
5. Caddyfile neu schreiben
6. ufw: 80/tcp und 443/tcp öffnen
7. `enable` und `restart`

## Deinstallation

1. Sicherung von Caddyfile, `sites.d/` und `sites-meta.d/` nach
   `/root/caddy-uninstall-<zeit>.tar.gz`
2. Dienst stoppen und deaktivieren
3. vHosts und Metadaten löschen
4. Caddyfile aus dem neuesten `.orig.<epoch>`-Backup wiederherstellen, sonst
   löschen
5. auf Rückfrage `/var/lib/caddy` — **enthält die Zertifikate**, eigene Sicherung
   davor
6. auf Rückfrage `/var/log/caddy`
7. auf Rückfrage die ufw-Regeln 80 und 443 — mit Hinweis, dass 443 auch von
   nginx stammen kann

Das Paket und das apt-Repo bleiben bestehen:

```bash
apt purge caddy
rm -f /etc/apt/sources.list.d/caddy-stable.list \
      /usr/share/keyrings/caddy-stable-archive-keyring.gpg
```

> Zertifikate zu löschen heißt Neuausstellung. Let's Encrypt begrenzt das auf 5
> Zertifikate pro Domain und Woche — bei vielen Domains kann man damit an das
> Limit stoßen.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Kein Zertifikat | DNS zeigt nicht hierher, oder Port 80 ist zu (HTTP-01-Challenge braucht ihn) |
| 403 bei statischen Dateien | Der Benutzer `caddy` darf das Verzeichnis nicht lesen — Rechte auf allen Ebenen des Pfads prüfen |
| 502 beim Reverse Proxy | Backend nicht erreichbar, oder es spricht HTTPS und die Option wurde nicht gesetzt |
| WebSocket bricht ab | Streaming-Modus (`flush_interval -1`) im Assistenten aktivieren |
| Wildcard-Domain funktioniert nicht | `*.example.com` braucht die DNS-01-Challenge und dafür ein DNS-Plugin (eigener Build mit `xcaddy`). Jede Subdomain einzeln anlegen |
| Änderung wirkt nicht | `caddy validate` in Menüpunkt 5; bei Fehlern wurde automatisch zurückgerollt |
| Nach `apt purge caddy` sind die Zertifikate weg | Sie lagen in `/var/lib/caddy`; das Backup der Deinstallation enthält sie |
