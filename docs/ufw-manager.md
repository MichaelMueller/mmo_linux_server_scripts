# ufw-manager.sh — Firewall-Verwaltung

CRUD auf ufw-Regeln: anlegen, ersetzen, löschen, dazu Anwendungsprofile,
Vorgaben und Protokollierung. Es gibt bewusst **keine eigene Regeldatei** — ufw
selbst ist der Datenspeicher, das Menü zeigt immer `ufw status numbered`.

## Voraussetzungen

- Debian oder Ubuntu, root-Rechte
- `ufw`; fehlt es, bietet das Skript beim Start die Installation an

## Aufruf

```bash
sudo ./ufw-manager.sh              # Menü
sudo ./ufw-manager.sh --status     # ufw status verbose
sudo ./ufw-manager.sh --uninstall  # Regeln zurücksetzen / Firewall abschalten
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Regel anlegen (Assistent) |
| 2 | Regel bearbeiten = ersetzen |
| 3 | Regel löschen |
| 4 | SSH nur über WireGuard erreichbar machen |
| 5 | Anwendungsprofile ansehen (`ufw app list/info`) |
| 6 | Firewall aktivieren oder deaktivieren |
| 7 | Vorgaben (`default incoming/outgoing`) |
| 8 | Protokollierung (off/low/medium/high) |
| 9 | Deinstallieren |
| 10 | Beenden |

## Regel anlegen

Der Assistent fragt der Reihe nach:

| Frage | Optionen |
|---|---|
| Aktion | `allow` / `deny` / `reject` / `limit` |
| Richtung | eingehend / ausgehend |
| Schnittstelle | z. B. `wg0`, leer = alle |
| Ziel | Port oder Bereich / Anwendungsprofil / alles |
| Protokoll | tcp / udp / beide |
| Quelle | IP oder CIDR, leer = überall |
| Ziel-IP | leer = alle Adressen dieses Hosts |
| Kommentar | erscheint in `ufw status` |

Danach wird **das fertige ufw-Kommando angezeigt und erst nach Bestätigung
ausgeführt**. Man sieht also genau, was passiert:

```
ufw allow 443/tcp
ufw limit 22/tcp comment SSH
ufw allow 6000:6010/tcp
ufw allow from 10.10.0.0/24 to any port 5432 proto tcp comment Postgres
ufw deny from 203.0.113.7 to any comment Spammer
ufw allow in on wg0 from any to any port 22 proto tcp
```

Zwei Eigenheiten von ufw, die das Skript abfängt:

- **Ein Portbereich braucht immer ein Protokoll.** Wählt man „beide", wird
  automatisch `tcp` genommen und das gesagt.
- **Mit Schnittstelle versteht ufw nur die ausführliche Form.** Sobald
  `in on <iface>` im Spiel ist, wird `from … to … port … proto …` gebaut statt
  der Kurzform.

`limit` ist für SSH die bessere Wahl als `allow`: maximal sechs Verbindungen in
30 Sekunden pro Quell-IP, das bremst Brute-Force ohne Zusatzsoftware.

## Regel bearbeiten und löschen

ufw kann Regeln nicht ändern. „Bearbeiten" heißt deshalb: **erst die neue Regel
anlegen, dann die alte löschen** — in dieser Reihenfolge, damit nie eine Lücke
entsteht. Weil sich die Nummerierung durch das Anlegen verschieben kann, wird
die alte Regel danach über ihren **Text** neu aufgelöst und nur dann gelöscht,
wenn sie eindeutig wiedergefunden wird.

Beim Löschen gilt dasselbe Misstrauen: die Regel wird im Klartext angezeigt, und
unmittelbar vor dem Löschen wird gegengeprüft, ob unter der Nummer noch
derselbe Text steht. Wenn nicht, passiert nichts.

Betrifft die Regel den Port der laufenden SSH-Sitzung, wird zusätzlich gewarnt.

## SSH nur über WireGuard (Punkt 4)

Zwei Stufen, damit man sich nicht aussperrt.

**Stufe 1** — beim ersten Aufruf:

1. WireGuard-Schnittstelle erfragen (Default `wg0`) und prüfen, dass es sie gibt
2. WireGuard-Port aus `/etc/wireguard/wg0-interface.conf` lesen und prüfen, dass
   er in ufw offen ist. Ist er es nicht, wird die Regel angeboten — **lehnt man
   ab, bricht das Rezept ab.** Ohne offenen UDP-Port kommt der Tunnel nicht
   zustande, und über ihn dann auch nichts mehr.
3. prüfen, ob überhaupt Peers konfiguriert sind
4. `ufw allow in on wg0 to any port <sshport> proto tcp` anlegen
5. **die bestehende offene SSH-Regel stehen lassen**

**Stufe 2** — beim zweiten Aufruf, nachdem die Anmeldung über den Tunnel
getestet wurde: das Rezept erkennt die vorhandene Interface-Regel und bietet an,
die offene SSH-Regel zu löschen.

Warum eine Interface-Regel und keine Quell-CIDR? `in on wg0` bindet an die
Schnittstelle. Eine Regel auf das Tunnel-Subnetz wäre auf Absender-IPs
angewiesen, die sich fälschen lassen, wenn kein Reverse-Path-Filter greift.

## Firewall einschalten (Punkt 6)

Vor `ufw enable` wird geprüft, ob es für den SSH-Port eine `ALLOW`- oder
`LIMIT`-Regel gibt (auch das Anwendungsprofil `OpenSSH` zählt). Fehlt sie, wird
`ufw limit <port>/tcp` angeboten. Lehnt man ab **und** sitzt selbst auf einer
SSH-Verbindung, kommt eine zweite, unmissverständliche Rückfrage — mit
`default deny incoming` ist ein `enable` ohne SSH-Regel eine sichere
Aussperrung.

Der SSH-Port wird aus `$SSH_CONNECTION` ermittelt, ersatzweise aus `sshd -T`,
im Zweifel 22.

## Geänderte Dateien

| Pfad | Inhalt |
|---|---|
| `/etc/ufw/` | die Regeln selbst (`user.rules`, `user6.rules`) |
| `/etc/default/ufw` | Vorgaben und Logging |
| `/var/log/ufw.log` | Protokoll, sofern eingeschaltet |

## Deinstallation

Dieses Tool legt nichts Eigenes an, es verwaltet ufw. „Deinstallation" heißt
deshalb, den Zustand von ufw zurückzunehmen — beides einzeln abfragbar:

- **Alle Regeln zurücksetzen** (`ufw --force reset`). ufw legt dabei selbst
  datierte Kopien der bisherigen Regeln in `/etc/ufw` ab und schaltet sich ab.
- **ufw deaktivieren**

Vorher wird `/etc/ufw` und `/etc/default/ufw` nach
`/root/ufw-uninstall-<zeit>.tar.gz` gesichert. Das Paket bleibt installiert.

Für einzelne Regeln ist Menüpunkt 3 der richtige Weg, nicht die Deinstallation.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Nach `enable` keine Verbindung mehr | Keine SSH-Regel. Über die Konsole des Hosters: `ufw disable` oder `ufw allow 22/tcp` |
| Regel angelegt, wirkt aber nicht | Reihenfolge: ufw wertet von oben nach unten aus, die erste passende Regel gewinnt. `ufw status numbered` prüfen |
| Gelöschte Nummer war die falsche Regel | Zwischen Anzeige und Löschen hat sich die Nummerierung geändert — das Skript fängt das ab und meldet es; Liste neu ansehen |
| Docker-Container trotz `deny` erreichbar | Docker schreibt eigene iptables-Regeln an ufw vorbei. Das ist ein bekanntes Docker-Verhalten und von ufw aus nicht zu beheben |
| IPv6-Regeln fehlen | `IPV6=yes` in `/etc/default/ufw` prüfen |
