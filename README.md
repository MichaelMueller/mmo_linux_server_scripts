# mmo_linux_server_scripts

Bash-Werkzeuge für die immer gleichen Aufgaben auf einem Linux-Webserver:
Grundausstattung, Zugang, Firewall, Mail, Updates, VPN, Reverse Proxy und
Monitoring. Zwölf Skripte, ein gemeinsames Menü, keine Abhängigkeit
untereinander.

Ausführliche Dokumentation je Werkzeug: **[docs/](docs/)** — eine Datei pro
Tool, jede für sich vollständig.

```bash
sudo ./setup.sh          # Menü über alle Tools
sudo ./caddy-manager.sh  # jedes Tool läuft auch für sich allein
```

Jedes Skript ist interaktiv und menügeführt, verlangt root und lässt sich
gefahrlos mehrfach aufrufen — bestehende Werte kommen als Default zurück.

## Tools

| Skript | Zweck | Nicht-interaktiv |
|---|---|---|
| [base-tools.sh](base-tools.sh)     | nano, vim, screen & Co. installieren, farbige Shell und Editor-Voreinstellungen | `--status` `--uninstall` |
| [ssh-setup.sh](ssh-setup.sh)       | SSH härten: Port, Root-Login, Schlüssel statt Passwort | `--status` `--uninstall` |
| [ufw-manager.sh](ufw-manager.sh)   | Firewall-Regeln anlegen, ändern, löschen | `--status` `--uninstall` |
| [mail-setup.sh](mail-setup.sh)     | SMTP-Versand über msmtp (Basis für alle Alerts) | `--test` `--uninstall` |
| [graph-mailer.sh](graph-mailer.sh) | Mailversand über Microsoft Graph, als sendmail eingehängt | `--sendmail` `--test` `--status` `--uninstall` |
| [auto-update.sh](auto-update.sh)   | apt-Updates per Cron, mit Mail-Report | `--run` `--status` `--uninstall` |
| [wg-manager.sh](wg-manager.sh)     | WireGuard-Server und Client-Configs | `--uninstall` |
| [tailscale-setup.sh](tailscale-setup.sh) | Tailscale installieren, anmelden, Routen und Exit-Node | `--status` `--uninstall` |
| [nginx-manager.sh](nginx-manager.sh) | nginx als TCP-Relais mit SNI-Routing, TLS zum Backend durchgereicht | `--uninstall` |
| [caddy-manager.sh](caddy-manager.sh) | Caddy-vHosts mit TLS-Terminierung am Server | `--uninstall` |
| [tcp-monitor.sh](tcp-monitor.sh)   | TCP-Erreichbarkeit prüfen, Alert bei Statuswechsel | `--check` `--status` `--uninstall` |
| [disk-monitor.sh](disk-monitor.sh) | Speicherplatz und Inodes, Alert bei Zustandswechsel, Prognose | `--check` `--status` `--uninstall` |

`--run` und `--check` sind die Cron-Runner und tauchen deshalb nicht im Menü auf.

## Reihenfolge auf einem frischen Server

```bash
sudo ./setup.sh
```

Von oben nach unten durchgehen. Die Menü-Reihenfolge ist die sinnvolle
Einrichtungsreihenfolge:

1. **Basis-Werkzeuge** — damit man auf dem Server arbeiten kann
2. **SSH-Härtung** — vor allem anderen, und mit zweiter offener Sitzung
3. **Firewall** — direkt danach, wenn der SSH-Port feststeht
4. **Ein Mailer** — msmtp *oder* Graph, damit Reports und Alerts rausgehen
5. **Automatische Updates** — bevor man Dienste draufstellt
6. **WireGuard oder Tailscale** — wenn Backends nur über einen Tunnel erreichbar
   sein sollen
7. **nginx** *oder* **Caddy** — siehe unten, das ist eine Entweder-oder-Frage
8. **TCP- und Speicherplatz-Monitoring** — zuletzt, wenn es etwas zu überwachen gibt

SSH vor der Firewall, weil `ssh-setup` den neuen Port selbst in ufw öffnet und
die Firewall dann schon weiß, welcher Port freibleiben muss.

## Drei Entweder-oder-Entscheidungen

| Frage | Nimm A, wenn … | Nimm B, wenn … |
|---|---|---|
| **msmtp** oder **Graph** | ein SMTP-Zugang mit Benutzer und Passwort funktioniert | Microsoft 365 SMTP AUTH gesperrt hat — dann geht nur noch Graph |
| **WireGuard** oder **Tailscale** | wenige feste Peers, keine externe Abhängigkeit gewünscht | viele wechselnde Geräte, NAT auf beiden Seiten, zentrale Rechteverwaltung |
| **nginx** oder **Caddy** | das Backend hat sein eigenes Zertifikat und soll es behalten | TLS hier terminieren, Zertifikate automatisch |

Bei den Mailern und den Reverse Proxys ist es wirklich ein Entweder-oder: beide
Mailer wollen `/usr/sbin/sendmail` sein, beide Proxys wollen Port 443.
WireGuard und Tailscale dagegen laufen problemlos nebeneinander.

## nginx oder Caddy?

Beide belegen Port 443, **gleichzeitig geht nicht**. Der Unterschied ist, wo TLS
terminiert wird:

| | nginx-manager | caddy-manager |
|---|---|---|
| TLS terminiert | beim Backend | auf diesem Server |
| Zertifikat liegt | auf dem Backend | hier (automatisch von Let's Encrypt) |
| Routing über | SNI (`ssl_preread`) | HTTP-Host |
| Backend sieht | die echte TLS-Verbindung | entschlüsselten HTTP-Verkehr |
| gut für | Weiterreichen an Appliances/VMs mit eigenem Zertifikat | normale Web-Apps hinter einem Reverse Proxy |

Faustregel: Wenn das Backend sein eigenes Zertifikat mitbringt und behalten soll,
nginx. Sonst Caddy — das erspart die gesamte Zertifikatsverwaltung.

## Basis-Werkzeuge (`base-tools`)

Pakete in vier Gruppen, jede einzeln abwählbar: Editoren (`nano vim`),
Terminal-Sessions (`screen tmux`), Werkzeuge (`htop curl wget git unzip rsync
tree ncdu bash-completion ca-certificates`) und optional Netzwerk-Diagnose
(`dnsutils net-tools mtr-tiny`). Installiert wird paketweise, ein auf der
Distribution unbekannter Paketname bricht den Lauf nicht ab.

Dazu vier Voreinstellungen:

| Datei | Inhalt |
|---|---|
| `/etc/profile.d/zz-base-tools.sh` | Farben (`dircolors`), Aliase, History-Einstellungen, Prompt (root rot, User grün) |
| `/etc/bash.bashrc` | markierter Block, der die Datei oben auch für Nicht-Login-Shells lädt |
| `/etc/vim/vimrc.local` | Zeilennummern, Suche, 4er-Einrückung, **`set mouse=`** |
| `/etc/nanorc`, `/etc/screenrc` | markierte Blöcke: Zeilennummern bzw. Scrollback und Statuszeile |

Zwei Details, die sonst regelmäßig nerven:

- **`/etc/profile.d` allein reicht nicht.** Das wird nur von Login-Shells
  gelesen. `ssh host befehl`, `su` und screen bekämen sonst nichts davon ab —
  deshalb der Verweis aus `/etc/bash.bashrc`.
- **`set mouse=` in vim.** Ab vim 8.2 ist die Maus per Default an, dann schaltet
  vim beim Markieren in den Visual-Modus und das Kopieren aus dem Terminal
  funktioniert nicht mehr.

Fremde Dateien werden nicht überschrieben: in `/etc/nanorc`, `/etc/screenrc` und
`/etc/bash.bashrc` steht der eigene Kram in einem `# >>> base-tools >>>`-Block,
eine vorhandene `vimrc.local` wird nach `.orig` gesichert.

## SSH-Härtung (`ssh-setup`)

Ein Durchlauf: erst alle Fragen (Port, Root-Login, Passwort-Anmeldung,
MaxAuthTries, LoginGraceTime, X11, ClientAlive), dann eine Zusammenfassung, dann
**eine** Bestätigung. Vorher wird nichts angefasst.

Geschrieben wird ausschließlich ein Drop-in in
`/etc/ssh/sshd_config.d/99-ssh-setup.conf` — die `sshd_config` selbst bleibt, wie
sie ist.

Guardrails gegen Aussperrung:

- **Reihenfolge ufw → sshd.** Der neue Port ist in der Firewall offen, *bevor*
  sshd dorthin wechselt. **Port 22 bleibt zunächst zusätzlich offen**;
  Menüpunkt 4 schließt ihn, wenn der Test über den neuen Port geklappt hat — und
  weigert sich, solange sshd noch selbst auf 22 lauscht.
- **`sshd -t` vor jedem Übernehmen**, mit Rollback auf das vorherige Drop-in,
  wenn die Prüfung fehlschlägt.
- **`ssh.socket` wird erkannt.** Ab Ubuntu 22.10 startet sshd per
  Socket-Aktivierung und ignoriert die `Port`-Direktive aus der Konfiguration
  komplett — der Port muss an `ssh.socket` gesetzt werden. Ohne diese Erkennung
  stellt man die Firewall auf den neuen Port um, während sshd weiter auf 22
  lauscht. In diesem Fall wird zusätzlich ein Socket-Drop-in geschrieben.
- **Passwort-Anmeldung wird nur abgeschaltet, wenn irgendwo ein
  `authorized_keys` liegt.** Gibt es keinen Schlüssel, bleibt sie an — mit
  Hinweis auf Menüpunkt 3, der einen Schlüssel hinterlegt.
- **Root-Login „no" plus Passwort „aus" wird abgefangen,** wenn nur root einen
  Schlüssel hat. Sonst käme niemand mehr rein.
- **Es wird nachgeprüft, ob das Drop-in überhaupt ankommt.** Bei sshd gewinnt
  die *zuerst* gelesene Direktive: steht in der `sshd_config` oberhalb der
  `Include`-Zeile schon ein `PasswordAuthentication yes`, läuft das Drop-in ins
  Leere. Nach dem Schreiben wird deshalb mit `sshd -T` gegengeprüft und
  angeboten, die widersprechenden Zeilen auszukommentieren.
- **Fehlt die `Include`-Zeile ganz** (ältere Distributionen), wird sie oben in
  der `sshd_config` ergänzt — zwischen Markern, damit die Deinstallation sie
  wieder herausnehmen kann.

Trotzdem: bei der Härtung immer eine **zweite SSH-Sitzung offen halten**.

## Firewall (`ufw-manager`)

CRUD auf ufw-Regeln — anlegen, ersetzen, löschen, dazu Anwendungsprofile,
Vorgaben und Protokollierung. Es gibt keine eigene Regeldatei: `ufw` selbst ist
der Datenspeicher, das Menü zeigt immer `ufw status numbered`.

Der Assistent zum Anlegen fragt Aktion (`allow` / `deny` / `reject` / `limit`),
Richtung, Ziel (Port, Portbereich, Anwendungsprofil oder alles), Protokoll,
Quelle, Ziel-IP und einen Kommentar — und **zeigt das fertige ufw-Kommando an,
bevor es ausgeführt wird**. Man sieht also genau, was passiert, und lernt
nebenbei die Syntax.

- **Vor dem Einschalten** wird geprüft, ob es für den SSH-Port überhaupt eine
  ALLOW- oder LIMIT-Regel gibt. Fehlt sie, wird `ufw limit <port>/tcp`
  angeboten; lehnt man ab und sitzt selbst auf einer SSH-Verbindung, kommt eine
  zweite, unmissverständliche Rückfrage. Mit `default deny incoming` ist ein
  `ufw enable` ohne SSH-Regel eine sichere Aussperrung.
- **Beim Löschen** wird die Regel im Klartext angezeigt, und wenn sie den Port
  der laufenden SSH-Sitzung betrifft, gewarnt.
- **Nummern verschieben sich.** Zwischen Anzeige und Löschen wird deshalb
  gegengeprüft, ob unter der Nummer noch dieselbe Regel steht — sonst passiert
  nichts.
- **Bearbeiten heißt: neue Regel anlegen, dann alte löschen** (ufw kann Regeln
  nicht ändern). In dieser Reihenfolge, damit nie eine Lücke entsteht; die
  Nummer der alten Regel wird danach über ihren Text neu aufgelöst.
- `limit` ist für SSH die bessere Wahl als `allow`: maximal sechs Verbindungen
  in 30 Sekunden pro IP, das bremst Brute-Force ohne Zusatzsoftware.
- **Schnittstellen-Regeln** (`allow in on wg0 …`) gehören zu den Fragen des
  Assistenten. Sobald eine Schnittstelle im Spiel ist, wird automatisch die
  ausführliche Syntax gebaut — die Kurzform versteht ufw dort nicht.

### SSH nur über WireGuard

Ein eigener Menüpunkt, weil die Reihenfolge das Schwierige daran ist. Er läuft
in zwei Stufen: beim ersten Aufruf prüft er, dass es die Schnittstelle gibt und
dass der **WireGuard-UDP-Port offen ist** (ohne den kommt der Tunnel nicht hoch
und damit gar nichts mehr), legt dann `allow in on wg0 … port <sshport>` an und
lässt die offene SSH-Regel bewusst stehen. Erst der zweite Aufruf — nach einem
erfolgreichen Login durch den Tunnel — bietet an, sie zu entfernen.

Interface statt Quell-CIDR deshalb, weil `in on wg0` an die Schnittstelle
bindet; eine Regel auf das Tunnel-Subnetz hinge an Absender-IPs, die sich
fälschen lassen, wenn kein Reverse-Path-Filter greift.

## Automatische Updates (`auto-update`)

Cron-Job in `/etc/cron.d/auto-update`, täglich oder wöchentlich zu einer
gewählten Uhrzeit.

| Einstellung | Optionen | Default |
|---|---|---|
| Umfang | nur Sicherheitsupdates / alle Pakete | Sicherheitsupdates |
| autoremove | ja/nein | ja |
| Neustart bei Bedarf | automatisch / nur melden | nur melden |
| Report | immer / nur bei Änderungen und Fehlern / nur bei Fehlern | bei Änderungen und Fehlern |

- **Sicherheitsupdates werden am Suite-Namen erkannt** (`bookworm-security`,
  `jammy-security`). Eigene Repos ohne dieses Namensschema erwischt der Modus
  nicht — wer solche einsetzt, nimmt „alle Pakete".
- **`--run` läuft bewusst ohne `set -e`**: der Lauf sammelt Fehler und meldet
  sie am Ende, statt mittendrin abzubrechen und den Report zu verschlucken.
- **dpkg-Konflikte** werden mit `--force-confold` entschieden: eine geänderte
  Konfigurationsdatei bleibt, wie sie ist. Ein unbeaufsichtigter Lauf darf nicht
  an einer Rückfrage hängen bleiben.
- **Neustart** wird an `/var/run/reboot-required` erkannt. Automatisch heißt
  `shutdown -r +1` direkt nach dem Lauf.
- Ohne eingerichteten Mailer ist der Versand ein No-op, der Report landet dann
  nur in `var/auto-update.log` (auf die letzten 2000 Zeilen begrenzt).

## Mail (`mail-setup`)

`msmtp` als sendmail-Ersatz, plus `bsd-mailx` für das `mail`-Kommando. STARTTLS
(587), TLS (465) oder unverschlüsselt (25); optional ein `root:`-Alias in
`/etc/aliases`, damit auch Cron- und Systemmails ankommen.

Das Passwort steht im Klartext in `/etc/msmtprc` (`0600`, nur root). Wer das
nicht will, hinterlegt bei seinem Provider ein App-Passwort mit
Versand-Berechtigung statt der Hauptzugangsdaten.

`auto-update` und `tcp-monitor` benutzen dasselbe `mail`-Kommando. Ist es nicht
da, laufen beide normal weiter und schreiben nur ins Log.

## Microsoft 365 über Graph (`graph-mailer`)

Für Tenants, in denen SMTP AUTH gesperrt ist — dann funktioniert msmtp nicht
mehr, und die Graph-API ist der vorgesehene Ersatz. Gebraucht wird eine
App-Registrierung in Entra ID mit der **Anwendungsberechtigung** `Mail.Send`
(nicht „delegiert") und Administrator-Zustimmung.

Das Tool hängt sich als `sendmail` ein, damit `mail`, Cron und alle
Monitoring-Tools unverändert weiterlaufen:

```
/usr/sbin/sendmail -> /usr/local/sbin/graph-sendmail -> graph-mailer.sh --sendmail
```

- **Die Mail geht als MIME an Graph**, base64-kodiert, nicht als JSON. Für einen
  sendmail-Ersatz ist das der einzig robuste Weg: Anhänge, Kodierungen,
  UTF-8-Betreffs und eigene Header gehen unverändert durch, statt dass man die
  Mail zerlegt und neu zusammenbaut. Grenze: 4 MB.
- **Ein vorhandenes `/usr/sbin/sendmail` wird per `dpkg-divert` beiseitegelegt**,
  nicht überschrieben. Sauber reversibel, und ein Paket-Update legt es nicht
  wieder darüber.
- **Weder Secret noch Token stehen je in der Kommandozeile** — beides geht über
  eine curl-Config auf stdin, damit nichts in der Prozessliste landet. Das Token
  wird in `/run` zwischengespeichert (tmpfs) und 60 s vor Ablauf erneuert.
- **`Mail.Send` als Anwendungsberechtigung gilt tenantweit.** Wer den Versand auf
  das eine Postfach begrenzen will, braucht in Exchange Online zusätzlich eine
  `New-ApplicationAccessPolicy`. Das ist der Teil, den man leicht vergisst.
- **Client-Secrets laufen ab.** Danach steht `AADSTS7000215` im Log.

## WireGuard (`wg-manager`)

Server-Config und Clients getrennt: `wg0-interface.conf` beschreibt das
Interface, jeder Client ist eine Datei in `peers.d/`, und `wg0.conf` wird aus
beidem zusammengesetzt. Ein Client anlegen oder löschen heißt also *eine* Datei
schreiben und neu generieren, nicht in einer großen Config herumschneiden.

- Änderungen gehen per `wg syncconf` ins laufende Interface, bestehende Tunnel
  brechen dabei nicht ab.
- Die nächste freie Tunnel-IP wird vorgeschlagen.
- Die fertige Client-Config wird angezeigt und liegt in `clients/`; ist
  `qrencode` installiert, gibt es sie auf Wunsch als QR-Code fürs Handy.
- Wird der Endpoint oder Port geändert, ziehen alle Client-Configs automatisch
  nach.

## Tailscale (`tailscale-setup`)

Installation aus dem offiziellen Repo, Anmeldung interaktiv oder per Auth-Key,
und die Optionen, die auf einem Server tatsächlich zur Debatte stehen:
Tailscale SSH, Subnetz-Routen, Exit-Node, MagicDNS, Shields-up, Tags.

- **`tailscale up` fragt immer den kompletten Satz ab.** Optionen, die man nicht
  mitgibt, setzt Tailscale auf ihren Default zurück und verlangt dafür
  `--reset`. Einzelne Flags nachzuschieben führt zu Fehlern oder stillen
  Änderungen — deshalb der volle Durchlauf, mit angezeigtem Kommando vor der
  Ausführung.
- **Defaults bewusst konservativ:** MagicDNS aus (es schreibt sonst
  `/etc/resolv.conf` um), `--accept-routes` aus, Tailscale SSH aus.
- **IP-Forwarding** (`/etc/sysctl.d/99-tailscale.conf`) wird nur gesetzt, wenn
  Routen oder Exit-Node gewählt sind — ohne das funktioniert beides schlicht
  nicht. Anbieten heißt übrigens nicht freigeben: beides muss in der
  Admin-Konsole zusätzlich genehmigt werden.
- **Der Auth-Key geht über eine Datei** (`--auth-key=file:…`), nicht über die
  Kommandozeile.
- **Firewall:** ein Menüpunkt legt `ufw allow in on tailscale0` an — damit
  erreichen Tailnet-Knoten Dienste, ohne dass ein Port öffentlich offen ist. Für
  Tailscale selbst braucht es keine eingehende Regel, die Verbindungen entstehen
  von innen.

Beim Deinstallieren wird IP-Forwarding **nicht** auf 0 zurückgesetzt — Docker
oder WireGuard-Routing können es ebenfalls brauchen. Der Knoten bleibt in der
Admin-Konsole eingetragen und muss dort separat gelöscht werden.

## nginx-Relais (`nginx-manager`)

Ein `stream`-Block mit `ssl_preread`: nginx liest den SNI aus dem TLS-Handshake,
schlägt in einer Map das Backend nach und reicht die Verbindung unentschlüsselt
durch. Ein Host ist eine Zeile in `/etc/nginx/stream-hosts.d/<domain>.map`.

- Braucht `nginx-extras` (das `stream`-Modul ist in `nginx-light` nicht drin).
- Das Zertifikat für die Domain muss auf dem **Backend** liegen, nicht hier.
- Der http-Default-vHost wird deaktiviert, wenn er auf 443 lauscht — sonst
  Portkonflikt. Die Deinstallation bietet an, ihn wieder einzuhängen.
- Nach jeder Änderung `nginx -t`; schlägt der Test fehl, wird zurückgerollt.
- Der Block in `nginx.conf` steht zwischen `# >>> nginx-manager >>>`-Markern,
  damit die Deinstallation ihn wieder exakt herausschneiden kann.

## Caddy-vHosts (`caddy-manager`)

Ein vHost ist eine Datei in `/etc/caddy/sites.d/<domain>.caddy`, eingebunden per
`import` aus dem Caddyfile. Drei Typen im Assistenten:

| Typ | fragt nach |
|---|---|
| statische Dateien | Verzeichnis, Directory-Listing, Basic-Auth |
| Weiterleitung | Ziel-URL, 301/302, Pfad+Query übernehmen |
| Reverse Proxy | Backend(s), TLS zum Backend, Pfad-Präfix, WebSocket/Streaming, Host-Header, Health-Check, Load-Balancing, Basic-Auth |

- **Zertifikate holt Caddy selbst**, sobald der DNS-Eintrag auf diesen Server
  zeigt. Nichts weiter zu tun.
- **Metadaten** (Typ und Ziel) liegen daneben in `sites-meta.d/`, damit `list`
  die Übersicht zeigen kann, ohne Caddy-Syntax zu parsen.
- **Validierung und Rollback** nach jedem Schreiben: lehnt `caddy validate` ab,
  wird die Änderung zurückgenommen. Ein Tippfehler nimmt nie die anderen vHosts
  mit.
- Ein vorhandenes Caddyfile, das nicht von hier stammt, wird beim Einrichten
  nach `Caddyfile.orig.<epoch>` gesichert — daraus stellt die Deinstallation es
  auch wieder her.

## TCP-Monitoring (`tcp-monitor`)

Prüft per Cron (Default alle 5 Minuten), ob Ziele auf ihrem TCP-Port antworten.
Jedes Ziel ist eine Datei in `var/targets.d/`, Messwerte landen als CSV in
`var/results/`.

- **Alert nur bei Statuswechsel** (`up` → `down` und zurück), nicht bei jedem
  Lauf. Ein kürzeres Intervall kostet damit keine zusätzlichen Meldungen, es
  verkürzt nur die Erkennungszeit.
- Alarmierung über Webhook, E-Mail oder beides; jeder Wechsel steht außerdem in
  `var/log/alerts.log`.
- Verbindungstest über bash `/dev/tcp`, keine externe Abhängigkeit.
- „Jetzt alle Ziele prüfen" zeigt Latenzen an, ohne die Zustandsmaschine zu
  stören.
- Messdaten werden nach `RETENTION_DAYS` (Default 30) beschnitten. Die Statistik
  zeigt Verfügbarkeit in Prozent sowie mittlere und maximale Latenz.

## Speicherplatz (`disk-monitor`)

Prüft per Cron (Default stündlich) alle echten Dateisysteme und meldet — wie
`tcp-monitor` — **nur den Zustandswechsel** zwischen `ok`, `warn` und `crit`.

| Schwelle | Default | Warum |
|---|---|---|
| Belegung Warnung | 85 % | eng, aber noch nichts kaputt |
| Belegung kritisch | 95 % | ab hier fallen Dienste aus |
| Inodes | 90 % | eigene Prüfung, siehe unten |
| Mindestens frei | aus | absolute Untergrenze zusätzlich zur Prozentschwelle |

- **Inodes werden mitgeprüft.** Ein Dateisystem kann voll sein, obwohl reichlich
  Platz frei ist — Millionen kleiner Dateien brauchen die Inodes auf, und `df -h`
  zeigt davon nichts.
- **Prozentwerte allein sind irreführend:** 5 % von 4 TB sind 200 GB, 5 % von
  20 GB sind eines. Deshalb optional `MIN_FREE_GB` als absolute Grenze.
- **Pseudo-Dateisysteme fliegen raus** (`tmpfs`, `squashfs`, `overlay` …). Jedes
  snap-Paket ist als squashfs zu 100 % belegt; ohne diesen Filter bestünde der
  Alert nur aus Fehlalarmen. Weitere Mountpoints lassen sich ausschließen.
- **Prognose:** aus der Messreihe wird linear hochgerechnet, wie viele Tage bis
  100 % bleiben — grob, aber genau die Frage, die man bei einer Warnung hat.
- **Der Alert nennt die größten Verzeichnisse** des betroffenen Mountpoints
  (`du -x --max-depth=2`), damit man nicht erst selbst suchen muss. Auf großen
  Dateisystemen dauert das, deshalb abschaltbar.

Eingelesen wird mit `df --output=…`, damit der Mountpoint garantiert am
Zeilenende steht — er darf Leerzeichen enthalten und würde in der klassischen
`df`-Ausgabe alle Felder verschieben.

## Deinstallation

Jedes Tool hat einen eigenen Deinstallations-Punkt im Menü und akzeptiert
`--uninstall`. `setup.sh` bündelt das unter Punkt 8, samt „Alles"-Durchlauf in
sinnvoller Reihenfolge (erst was nur beobachtet, dann was ausliefert, dann der
Zugang; Mail zuletzt, damit Alerts bis zum Schluss rausgehen).

Überall dasselbe Muster:

1. **Erst anzeigen, was wegfällt** — Dateien, Dienste, ufw-Regeln, Anzahl der
   betroffenen Hosts/Clients/Ziele.
2. **Dann eine Rückfrage** mit Default „nein".
3. **Backup vor dem Löschen**, immer, nach `/root/<tool>-uninstall-<zeit>.tar.gz`
   (`0600`). Scheitert das Backup, wird nichts entfernt.
4. **Zwei Stufen:** Konfiguration wird entfernt, alles mit Datencharakter
   (Schlüssel, Zertifikate, Messwerte, Logs) erst nach eigener Rückfrage.
5. **Pakete bleiben installiert.** Der passende `apt purge`-Befehl wird
   ausgegeben, ausgeführt wird er nicht — ein durchgeklicktes „ja" soll nicht
   nginx oder den Editor vom Server nehmen.
6. **Mehrfach ausführbar**, ein zweiter Lauf findet nichts mehr und bricht nicht
   ab.

Tools, die aus dem Muster fallen:

- **`ssh-setup`** nimmt das Drop-in zurück, öffnet dabei Port 22 in ufw *bevor*
  sshd dorthin zurückfällt, reaktiviert die auskommentierten Zeilen in der
  `sshd_config` und prüft mit `sshd -t`, bevor neu gestartet wird. Danach gilt
  wieder der Distributions-Default. Hinterlegte Schlüssel bleiben liegen.
- **`ufw-manager`** verwaltet nur ufw. „Deinstallation" heißt deshalb: Regeln
  zurücksetzen (`ufw reset`) und/oder die Firewall abschalten — beides einzeln
  abfragbar, mit deutlichem Hinweis, dass danach jeder lauschende Dienst offen
  erreichbar ist. Für einzelne Regeln ist der Löschen-Punkt im Menü gedacht.
- **`graph-mailer`** nimmt die sendmail-Umleitung per `dpkg-divert` zurück, so
  dass ein zuvor installierter MTA wieder zum Zug kommt. Die App-Registrierung
  in Entra ID bleibt bestehen.
- **`tailscale-setup`** meldet den Knoten ab und stoppt den Dienst; Paket und
  Zustand unter `/var/lib/tailscale` bleiben, und der Eintrag in der
  Admin-Konsole muss dort von Hand weg.

Worauf sonst besonders hingewiesen wird:

- **WireGuard:** Wer den Server nur über den Tunnel erreicht, kappt sich damit
  die Verbindung. Andere Interfaces (`wg1` …) bleiben unberührt.
- **Caddy:** `/var/lib/caddy` enthält die Let's-Encrypt-Zertifikate. Löschen
  heißt Neuausstellung — bei vielen Domains kann das ans Rate-Limit stoßen.
- **Port 443** kann von nginx *oder* Caddy stammen. Die ufw-Regel wird deshalb
  nur nach ausdrücklicher Rückfrage entfernt.
- **Mail:** Nach `apt purge msmtp-mta` gibt es kein `/usr/sbin/sendmail` mehr,
  Cron- und Systemmails fallen dann still aus.

## Ablage

```
setup.sh
base-tools.sh  ssh-setup.sh  ufw-manager.sh
mail-setup.sh  graph-mailer.sh  auto-update.sh
wg-manager.sh  tailscale-setup.sh  nginx-manager.sh  caddy-manager.sh
tcp-monitor.sh  disk-monitor.sh
docs/                     eine Doku-Datei je Werkzeug

auto-update.conf          Konfiguration auto-update
tcp-monitor.conf          Konfiguration tcp-monitor
disk-monitor.conf         Konfiguration disk-monitor
var/                      Laufzeitdaten: Ziele, Messwerte, Zustand, Logs
```

Systemweit angefasst wird:

| Pfad | von |
|---|---|
| `/etc/profile.d/zz-base-tools.sh`, Blöcke in `/etc/bash.bashrc`, `/etc/nanorc`, `/etc/screenrc`, `/etc/vim/vimrc.local` | `base-tools` |
| `/etc/ssh/sshd_config.d/99-ssh-setup.conf`, `Include`-Zeile in `/etc/ssh/sshd_config` | `ssh-setup` |
| `/etc/systemd/system/ssh.socket.d/10-ssh-setup-port.conf` | `ssh-setup` (nur bei Socket-Aktivierung) |
| `/etc/ufw/`, `/etc/default/ufw` | `ufw-manager` (und jedes Tool, das eine Regel öffnet) |
| `/etc/cron.d/auto-update`, `/etc/cron.d/tcp-monitor`, `/etc/cron.d/disk-monitor` | die drei Cron-Tools |
| `/etc/msmtprc`, `root:`-Zeile in `/etc/aliases`, `/var/log/msmtp.log` | `mail-setup` |
| `/etc/graph-mailer.conf`, `/usr/local/sbin/graph-sendmail`, `/usr/sbin/sendmail` (dpkg-divert), `/var/log/graph-mailer.log` | `graph-mailer` |
| `/etc/apt/sources.list.d/tailscale.list`, `/etc/sysctl.d/99-tailscale.conf`, `/var/lib/tailscale` | `tailscale-setup` |
| `/etc/wireguard/` (`wg0.conf`, `wg0-interface.conf`, `peers.d/`, `clients/`, Schlüssel) | `wg-manager` |
| `/etc/nginx/stream.conf`, `/etc/nginx/stream-hosts.d/`, Block in `/etc/nginx/nginx.conf` | `nginx-manager` |
| `/etc/caddy/Caddyfile`, `/etc/caddy/sites.d/`, `/etc/caddy/sites-meta.d/`, `/var/log/caddy/` | `caddy-manager` |

Cron-Jobs liegen in `/etc/cron.d/`, nicht in der User-Crontab: explizites
User-Feld (die Jobs laufen als root, apt braucht also kein passwortloses `sudo`),
eine Datei pro Job (anlegen und entfernen ohne Crontab-Parsing) und ein setzbarer
`PATH` — Cron startet sonst mit `/usr/bin:/bin`, dann fehlt `/usr/local/bin`.

## Entwicklung

Entwickelt wird unter Windows, ausgeführt unter Linux. `.gitattributes` erzwingt
LF für `*.sh` — mit CRLF scheitert schon der Shebang
(`bad interpreter: /usr/bin/env bash^M`).

Vor dem Commit:

```bash
for f in *.sh; do bash -n "$f"; done
shellcheck *.sh        # falls vorhanden
```

`./pull_push.sh` legt einen Checkpoint-Commit an und gleicht mit dem Remote ab
(`git pull --rebase && git push`).

Die Skripte lassen sich ohne Server testen, indem man die Pfadvariablen am
Dateikopf auf ein Sandbox-Verzeichnis umbiegt und die root-Prüfung entfernt —
alle Ziele stehen als eigene Variablen ganz oben.
