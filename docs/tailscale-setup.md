# tailscale-setup.sh — Tailscale

Installiert Tailscale aus dem offiziellen Repo, meldet den Server im Tailnet an
und verwaltet die Optionen, die man auf einem Server tatsächlich braucht:
Tailscale SSH, Subnetz-Routen, Exit-Node, DNS.

## Voraussetzungen

- Debian oder Ubuntu mit systemd, root-Rechte
- ein Tailscale-Konto und Zugang zur Admin-Konsole
- ausgehendes UDP ins Internet (Port 41641 bevorzugt; Tailscale kommt notfalls
  auch über DERP-Relays durch, dann langsamer)

## Aufruf

```bash
sudo ./tailscale-setup.sh              # Menü
sudo ./tailscale-setup.sh --status     # Status auf stdout
sudo ./tailscale-setup.sh --uninstall  # abmelden und aufräumen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Installieren und anmelden |
| 2 | Status anzeigen |
| 3 | Einstellungen ändern |
| 4 | Firewall: Zugriff über das Tailnet erlauben |
| 5 | Abmelden |
| 6 | Deinstallieren |
| 7 | Beenden |

## Installation

Über das offizielle Repo, passend zur erkannten Distribution:

```
/usr/share/keyrings/tailscale-archive-keyring.gpg
/etc/apt/sources.list.d/tailscale.list
```

`ID` und `VERSION_CODENAME` kommen aus `/etc/os-release`. Fehlt der Codename
(manche Container-Images), wird er erfragt. Danach `apt install tailscale` und
`systemctl enable --now tailscaled`.

## Anmelden

Zwei Wege:

- **Interaktiv** — Tailscale zeigt eine URL, die man im Browser öffnet und den
  Knoten freigibt. Der Aufruf wartet so lange.
- **Auth-Key** — ein Schlüssel aus der Admin-Konsole (`tskey-auth-…`). Er wird
  über eine temporäre Datei (`--auth-key=file:…`, `0600`) übergeben, damit er
  nicht in der Prozessliste steht.

## Einstellungen

Gefragt wird immer der komplette Satz:

| Option | Flag | Default hier |
|---|---|---|
| Hostname im Tailnet | `--hostname` | Kurzname des Hosts |
| Tailscale SSH | `--ssh` | aus |
| Subnetze anbieten | `--advertise-routes` | keine |
| Exit-Node anbieten | `--advertise-exit-node` | aus |
| Fremde Subnetze annehmen | `--accept-routes` | aus |
| MagicDNS übernehmen | `--accept-dns` | aus |
| Shields up | `--shields-up` | aus |
| Tags | `--advertise-tags` | keine |

Warum immer alle auf einmal? **`tailscale up` setzt Optionen, die man nicht
mitgibt, auf ihren Default zurück** und verlangt dafür ein `--reset`. Einzelne
Flags nachzuschieben führt daher zu Fehlermeldungen oder stillen Änderungen.
Menüpunkt 3 fragt deshalb alles ab und bietet `--reset` an.

Das fertige Kommando wird vor der Ausführung angezeigt.

### Zu den Defaults

- **MagicDNS ist standardmäßig aus.** Es trägt die Tailscale-Nameserver in
  `/etc/resolv.conf` ein; auf einem Server mit eigener DNS-Konfiguration will
  man das meistens nicht.
- **`--accept-routes` ist aus.** Ein Server, der plötzlich fremde Subnetze über
  den Tunnel routet, überrascht mehr, als er nützt.
- **Tailscale SSH ist aus.** Es ist ein zweiter, unabhängiger SSH-Weg mit
  eigener Zugriffssteuerung über die Tailnet-ACLs. Praktisch, aber eine
  bewusste Entscheidung — der normale `sshd` bleibt davon unberührt.

### IP-Forwarding

Sobald Subnetz-Routen oder Exit-Node gewählt werden, schreibt das Skript:

```
# /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

Ohne das leitet der Kernel keine fremden Pakete weiter, und Routen oder
Exit-Node funktionieren schlicht nicht.

Anbieten heißt übrigens nicht freigeben: Routen und Exit-Node müssen in der
**Admin-Konsole zusätzlich genehmigt** werden.

## Firewall (Punkt 4)

Legt ufw-Regeln auf die Schnittstelle `tailscale0` an — entweder für allen
Verkehr aus dem Tailnet oder für einen einzelnen Port:

```
ufw allow in on tailscale0 comment 'Tailnet'
ufw allow in on tailscale0 to any port 8080 proto tcp comment 'Tailnet'
```

Damit erreichen Tailnet-Knoten Dienste, ohne dass ein Port öffentlich offen sein
muss. Für eingehenden Tailscale-Verkehr selbst braucht es **keine** Regel — die
Verbindungen werden von innen aufgebaut.

Wer gar keine eingehenden Verbindungen aus dem Tailnet will, nimmt stattdessen
`--shields-up`.

## Status

Zeigt Version, Zustand von `tailscaled`, ob angemeldet, die Tailnet-IP, die
Knotenliste aus `tailscale status` und ob IP-Forwarding von diesem Tool gesetzt
wurde.

## Abmelden (Punkt 5)

`tailscale logout` und `tailscale down`. Die Software bleibt installiert, der
Knoten verschwindet aus dem Tailnet.

## Deinstallation

1. Sicherung von `/etc/sysctl.d/99-tailscale.conf` und `/var/lib/tailscale`
   nach `/root/tailscale-uninstall-<zeit>.tar.gz`
2. `tailscale logout`, `tailscale down`
3. `tailscaled` stoppen und deaktivieren
4. sysctl-Drop-in entfernen — **IP-Forwarding wird nicht auf 0 zurückgesetzt**,
   weil Docker, WireGuard oder anderes es ebenfalls brauchen können. Es gilt bis
   zum nächsten Neustart weiter.
5. auf Rückfrage: die ufw-Regeln für `tailscale0` (von hinten nach vorn
   gelöscht, damit sich die Nummern nicht verschieben)

Paket und Zustand bleiben. Vollständig entfernen:

```bash
apt purge tailscale
rm -rf /var/lib/tailscale /etc/apt/sources.list.d/tailscale.list \
       /usr/share/keyrings/tailscale-archive-keyring.gpg
```

> Der Knoten bleibt in der **Admin-Konsole** eingetragen und muss dort separat
> gelöscht werden.

> Wer den Server nur über Tailscale erreicht, kappt sich mit Abmelden oder
> Deinstallieren die Verbindung.

## Tailscale oder WireGuard?

Beides kann parallel laufen, sie stören sich nicht.

| | WireGuard (`wg-manager`) | Tailscale |
|---|---|---|
| Schlüsselverwaltung | selbst, pro Peer | zentral über das Konto |
| Erreichbarkeit | Server braucht offenen UDP-Port | baut von innen auf, NAT-gängig |
| Topologie | Stern auf diesen Server | Mesh zwischen allen Knoten |
| Zugriffssteuerung | Routing und Firewall | ACLs in der Admin-Konsole |
| Abhängigkeit | keine | Koordinationsserver von Tailscale |

Faustregel: eine Handvoll fester Peers und kein Wunsch nach externer
Abhängigkeit → WireGuard. Viele wechselnde Geräte, NAT auf beiden Seiten,
zentrale Rechteverwaltung → Tailscale.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Schlüssel für `<distro>/<codename>` nicht abrufbar | Codename passt nicht zum Repo (etwa bei Derivaten wie Linux Mint) — den der Basisdistribution angeben |
| `tailscale up` bricht mit Hinweis auf `--reset` ab | Eine vorher gesetzte Option wurde nicht mitgegeben; Menüpunkt 3 mit `--reset` |
| Subnetz-Route wird nicht genutzt | In der Admin-Konsole nicht genehmigt, oder auf der Gegenseite fehlt `--accept-routes` |
| Exit-Node erscheint nicht | Ebenfalls Genehmigung in der Admin-Konsole; zusätzlich IP-Forwarding prüfen |
| DNS kaputt nach dem Anmelden | `--accept-dns` hat `/etc/resolv.conf` übernommen; in Menüpunkt 3 abschalten |
| Verbindung nur über Relay (`relay` in `tailscale status`) | Kein direkter Pfad möglich; funktioniert, ist aber langsamer |
| Nach Neustart nicht verbunden | `systemctl enable tailscaled` prüfen |
