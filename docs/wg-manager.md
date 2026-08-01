# wg-manager.sh — WireGuard-Verwaltung

Richtet einen WireGuard-Server ein und verwaltet Client-Configs. Server und
Clients liegen in getrennten Dateien, `wg0.conf` wird daraus zusammengesetzt.

## Voraussetzungen

- Debian oder Ubuntu, root-Rechte
- das Paket `wireguard` wird bei Bedarf installiert
- optional `qrencode` für QR-Codes

## Aufruf

```bash
sudo ./wg-manager.sh              # Menü
sudo ./wg-manager.sh --uninstall  # Interface und Konfiguration entfernen
```

## Menü

Ohne Server-Config gibt es nur „Server-Config anlegen" und „Reste entfernen".
Danach:

| Punkt | Wirkung |
|---|---|
| 1 | Server-Config bearbeiten (Adresse, Port, Endpoint) |
| 2 | Client-Configs verwalten |
| 3 | Status (`wg show`) |
| 4 | Interface neu starten |
| 5 | Deinstallieren |
| 6 | Beenden |

Untermenü Clients: erstellen, anzeigen, bearbeiten, löschen.

## Aufbau

```
/etc/wireguard/
  wg0-interface.conf     [Interface]-Teil des Servers
  peers.d/<name>.conf    je Client ein [Peer]-Block
  clients/<name>.conf    die fertige Config für das Endgerät
  wg0.conf               wird aus interface + peers.d zusammengesetzt
  server_private.key     Serverschlüssel (0600)
  server_public.key
  server_endpoint.txt    öffentliche IP oder Hostname
```

Warum getrennt? Einen Client anlegen oder löschen heißt so: *eine* Datei
schreiben und `wg0.conf` neu erzeugen. Kein Herumschneiden in einer großen
Konfigurationsdatei, keine kaputten Blöcke bei einem Abbruch.

## Server anlegen

| Frage | Default |
|---|---|
| Server-Tunnel-IP | `10.10.0.1` |
| Listen-Port (UDP) | `51820` |
| Öffentliche IP oder Hostname | Pflicht |

Danach: Schlüsselpaar erzeugen (falls noch keins da ist), `wg0.conf` bauen,
`systemctl enable wg-quick@wg0`, Interface hochfahren und — falls ufw aktiv ist
— den UDP-Port öffnen.

## Clients

Beim Anlegen wird die nächste freie Tunnel-IP vorgeschlagen (ermittelt aus den
`AllowedIPs` der vorhandenen Peers). Es entstehen zwei Dateien:

```ini
# peers.d/laptop.conf — kommt in die Server-Config
[Peer]
PublicKey = ...
AllowedIPs = 10.10.0.2/32

# clients/laptop.conf — kommt auf das Endgerät
[Interface]
Address = 10.10.0.2/24
PrivateKey = ...
[Peer]
PublicKey = <server>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.10.0.1/32
PersistentKeepalive = 25
```

Die fertige Config wird angezeigt; ist `qrencode` installiert, gibt es sie auf
Wunsch als QR-Code fürs Handy.

`AllowedIPs` im Client zeigt nur auf die Server-IP — es wird also **nur** der
Tunnelverkehr geroutet, nicht der gesamte Internetverkehr des Clients. Wer einen
Full-Tunnel will, ändert das auf dem Endgerät zu `0.0.0.0/0`.

`PersistentKeepalive = 25` hält Verbindungen durch NAT offen.

## Änderungen im laufenden Betrieb

`wg0.conf` wird neu erzeugt und per `wg syncconf` eingespielt — bestehende
Tunnel brechen dabei **nicht** ab. Nur „Interface neu starten" und die Änderung
der Server-Config fahren das Interface wirklich neu hoch.

Ändert man Endpoint oder Port, werden alle Dateien in `clients/` automatisch
nachgezogen (`Endpoint` und `AllowedIPs`). Bereits verteilte Configs auf den
Endgeräten muss man natürlich selbst erneuern.

## Client-Liste

```
NAME                   IP               HANDSHAKE
laptop                 10.10.0.2        vor 34s
handy                  10.10.0.3        -
```

Der Handshake kommt aus `wg show wg0 latest-handshakes`. Ein `-` heißt: seit dem
letzten Interface-Start keine Verbindung.

## Deinstallation

1. `wg-quick down wg0`, `systemctl disable wg-quick@wg0`
2. ufw-Regel für den UDP-Port entfernen (Rückfrage; der Port wird **vor** dem
   Löschen der Config ausgelesen)
3. `wg0.conf`, `wg0-interface.conf`, `server_endpoint.txt` entfernen
4. Client-Configs und Peers auf Rückfrage
5. Server-Schlüsselpaar auf Rückfrage
6. `/etc/wireguard` nur löschen, wenn es danach leer ist

Vorher wird das ganze Verzeichnis nach
`/root/wireguard-uninstall-<zeit>.tar.gz` gesichert. **Andere Interfaces
(`wg1` …) bleiben unberührt.** Das Paket `wireguard` bleibt installiert.

> **Wer den Server nur über den Tunnel erreicht, kappt sich damit die
> Verbindung.** Vorher einen zweiten Zugang sicherstellen.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Kein Handshake | UDP-Port nicht offen (Firewall oder Router), oder falscher Endpoint in der Client-Config |
| Handshake da, aber kein Verkehr | `AllowedIPs` passt nicht — sie müssen auf beiden Seiten zueinander passen |
| `wg-quick up` scheitert mit „address in use" | Interface läuft schon; Menüpunkt 4 startet es sauber neu |
| Client kommt nach Neustart des Servers nicht zurück | `PersistentKeepalive` fehlt in der Client-Config |
| Zwei Clients mit derselben IP | Beim Bearbeiten von Hand vergeben; `AllowedIPs` in `peers.d/` prüfen |
| Andere Rechner im Tunnel-Netz nicht erreichbar | Dafür bräuchte es IP-Forwarding und passende Routen — das richtet dieses Tool bewusst nicht ein |
