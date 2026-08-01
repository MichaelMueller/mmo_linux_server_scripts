# nginx-manager.sh — TCP-Relais mit SNI-Routing

nginx als reines TCP-Relais: es liest den SNI aus dem TLS-Handshake, schlägt
dazu ein Backend nach und reicht die Verbindung **unentschlüsselt** durch. TLS
wird nicht terminiert — das Zertifikat liegt auf dem Backend.

> Braucht Port 443 und schließt sich damit mit `caddy-manager` aus. Caddy
> terminiert TLS auf diesem Server, nginx reicht es durch. Wenn das Backend sein
> eigenes Zertifikat behalten soll: nginx. Sonst Caddy.

## Voraussetzungen

- Debian oder Ubuntu, root-Rechte
- `nginx-extras` (enthält das `stream`-Modul) — wird bei Bedarf installiert

## Aufruf

```bash
sudo ./nginx-manager.sh              # Menü
sudo ./nginx-manager.sh --uninstall  # Relais entfernen
```

Die Ersteinrichtung passiert automatisch beim Anlegen des ersten Hosts.

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Host erstellen |
| 2 | Host bearbeiten (Backend ändern) |
| 3 | Host löschen |
| 4 | Config testen (`nginx -t`) |
| 5 | Deinstallieren |
| 6 | Beenden |

## Aufbau

```
/etc/nginx/stream.conf              map + server-Block auf :443
/etc/nginx/stream-hosts.d/*.map     je Host eine Zeile: domain  backend;
/etc/nginx/nginx.conf               enthält den stream-Block (markiert)
```

`stream.conf`:

```nginx
map $ssl_preread_server_name $backend {
    include /etc/nginx/stream-hosts.d/*.map;
}

server {
    listen 443;
    listen [::]:443;
    proxy_pass $backend;
    ssl_preread on;
    proxy_connect_timeout 5s;
    proxy_timeout 300s;
}
```

Ein Host ist genau eine Zeile:

```
app.example.com    10.10.0.2:443;
```

## Ersteinrichtung

Beim ersten Host:

1. `nginx-extras` installieren, falls das `stream`-Modul fehlt
2. Fallback-Backend erfragen für Verbindungen mit unbekanntem oder fehlendem SNI
   (leer = Verbindung verwerfen) → `00-default.map`
3. `stream.conf` schreiben
4. den `stream`-Block an `nginx.conf` anhängen, zwischen den Markern
   `# >>> nginx-manager >>>` und `# <<< nginx-manager <<<`
5. den http-Default-vHost deaktivieren, **falls** er auf 443 lauscht — sonst
   Portkonflikt
6. ufw: 443/tcp öffnen
7. `nginx -t`, `enable`, `restart`

## Änderungen

Nach jedem Schreiben läuft `nginx -t`. Schlägt der Test fehl, wird die Änderung
zurückgenommen (beim Bearbeiten aus `<datei>.bak`) und neu geladen. Ein
Tippfehler nimmt also nie die anderen Hosts mit.

## Wichtig zum Verständnis

- **Das Zertifikat muss auf dem Backend liegen.** Dieser Server sieht den
  verschlüsselten Verkehr nie im Klartext und kann daher auch keins ausstellen.
- **Clients ohne SNI** (sehr alte Software, direkter Zugriff über die IP) landen
  beim Fallback-Backend oder werden verworfen.
- **Die Backend-Adresse ist `IP:Port`.** Ein Hostname würde bei jedem
  Verbindungsaufbau aufgelöst; für ein Relais ins interne Netz ist die IP das
  Naheliegende.
- **Keine HTTP-Funktionen.** Kein Header-Rewriting, keine Kompression, keine
  Zugriffslogs mit URLs — auf dieser Ebene gibt es nur Bytes.

## Datenhaltung

**Service-seitig.** Ein Host ist eine `.map`-Datei, die nginx über den
`include`-Glob direkt liest — es gibt keine Datenbank und keine Zustandsdatei
daneben, und neben dem Skript liegt nichts. Eine von Hand angelegte `.map` wird
genauso angezeigt und verwaltet wie eine erzeugte.

Auf eine bestehende nginx-Installation aufsetzbar: der gesamte `http`-Teil
bleibt unberührt, ergänzt wird nur ein markierter `stream`-Block in
`nginx.conf`. Einzige Ausnahme ist der Default-vHost — er wird deaktiviert, wenn
er selbst auf 443 lauscht (sonst Portkonflikt), und beim Deinstallieren auf
Rückfrage wieder eingehängt.

## Deinstallation

1. Sicherung nach `/root/nginx-uninstall-<zeit>.tar.gz`
2. den `stream`-Block aus `nginx.conf` schneiden: primär über die Marker,
   ersatzweise (Installationen von vor der Marker-Einführung) über einen
   awk-Durchlauf, der genau den `stream`-Block mit *unserer* include-Zeile
   entfernt und fremde `stream`-Blöcke stehen lässt
3. `nginx -t`; scheitert es, wird `nginx.conf` aus der Sicherung zurückgeholt
   und nichts weiter angefasst
4. `stream-hosts.d/` und `stream.conf` löschen
5. auf Rückfrage: den http-Default-vHost wieder einhängen
6. auf Rückfrage: die ufw-Regel 443/tcp entfernen — **mit Warnung, dass Port 443
   auch von Caddy stammen kann**
7. auf Rückfrage: nginx stoppen und deaktivieren

Das Paket `nginx-extras` bleibt installiert.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| `nginx: [emerg] bind() to 0.0.0.0:443 failed` | Etwas anderes hält 443 — meist Caddy oder der http-Default-vHost |
| Verbindung landet immer beim Fallback | Der Client schickt keinen SNI, oder die Domain steht nicht in `stream-hosts.d/` |
| Zertifikatsfehler im Browser | Das Zertifikat auf dem Backend passt nicht zur Domain — hier ist nichts zu ändern |
| `unknown directive "stream"` | `nginx-light`/`nginx-core` ohne stream-Modul installiert; `nginx-extras` nötig |
| Änderung wirkt nicht | `nginx -t` in Menüpunkt 4 prüfen; bei Fehlern wurde automatisch zurückgerollt |
| Lange Verbindungen brechen ab | `proxy_timeout` in `stream.conf` erhöhen (Default 300 s) |
