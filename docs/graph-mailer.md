# graph-mailer.sh — Microsoft-365-Mailer über Graph

Verschickt Mail über die Microsoft-Graph-API und hängt sich als
`sendmail`-Ersatz ein. Gedacht für Umgebungen, in denen Exchange Online kein
SMTP AUTH mehr erlaubt — dann funktioniert der klassische Weg über msmtp nicht
mehr, und Graph ist der vorgesehene Ersatz.

> **Alternative zu `mail-setup.sh`, nicht Ergänzung.** Beide wollen
> `/usr/sbin/sendmail` sein. Man entscheidet sich für eines.

## Voraussetzungen

- root-Rechte, `curl`, `base64` (wird bei Bedarf installiert)
- eine **App-Registrierung in Entra ID** mit:
  - Anwendungs-ID (Client) und Verzeichnis-ID (Tenant)
  - einem Client-Secret
  - der **Anwendungsberechtigung** `Mail.Send` (nicht „delegiert"), mit
    Administrator-Zustimmung
- ein Postfach, aus dem gesendet wird (UPN, z. B. `server@firma.de`)

> `Mail.Send` als Anwendungsberechtigung erlaubt den Versand aus **jedem**
> Postfach des Tenants. Wer das einschränken will, richtet in Exchange Online
> eine Anwendungszugriffsrichtlinie (`New-ApplicationAccessPolicy`) für dieses
> eine Postfach ein. Das ist der Teil, den man nicht vergessen sollte.

## Aufruf

```bash
sudo ./graph-mailer.sh              # Menü
sudo ./graph-mailer.sh --test       # Testmail
sudo ./graph-mailer.sh --status     # Konfiguration und Integration
sudo ./graph-mailer.sh --uninstall  # entfernen
./graph-mailer.sh --sendmail -t     # sendmail-kompatibel, Mail von stdin
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Einrichten / Zugangsdaten bearbeiten |
| 2 | Testmail senden |
| 3 | Token prüfen (holt ein frisches Token und zeigt Fehler im Klartext) |
| 4 | Status anzeigen |
| 5 | sendmail-Integration ein- oder ausschalten |
| 6 | Log anzeigen |
| 7 | Deinstallieren |
| 8 | Beenden |

## Wie der Versand läuft

1. **Token holen** — `client_credentials` gegen
   `login.microsoftonline.com/<tenant>/oauth2/v2.0/token`, Scope
   `https://graph.microsoft.com/.default`. Das Token wird in
   `/run/graph-mailer/token` zwischengespeichert und 60 Sekunden vor Ablauf
   erneuert. `/run` liegt im tmpfs, ein Neustart räumt es also von selbst auf.
2. **Mail als MIME übergeben** — `POST /v1.0/users/<sender>/sendMail` mit
   `Content-Type: text/plain` und der base64-kodierten RFC-822-Nachricht im
   Rumpf. HTTP 202 heißt angenommen.

Warum MIME statt JSON? Für einen sendmail-Ersatz ist das der einzig robuste
Weg: Anhänge, Kodierungen, `Content-Type`, eigene Header und UTF-8-Betreffs
gehen unverändert durch. Bei der JSON-Variante müsste man die Mail
auseinandernehmen und neu zusammenbauen — und jedes Detail, das man dabei
übersieht, geht verloren.

Grenze: Graph nimmt so bis 4 MB entgegen.

## sendmail-Integration

```
/usr/local/sbin/graph-sendmail   -> exec graph-mailer.sh --sendmail "$@"
/usr/sbin/sendmail               -> Symlink auf graph-sendmail
```

Ein vorhandenes `/usr/sbin/sendmail` (etwa von `msmtp-mta` oder Postfix) wird
mit **`dpkg-divert --add --rename`** beiseitegelegt statt überschrieben. Das ist
sauber reversibel, und ein Paket-Update legt die Datei nicht wieder darüber.

Damit gehen auch `mail`, Cron-Mails und alles andere, was `sendmail` aufruft,
über Graph.

### Unterstützte sendmail-Optionen

| Option | Verhalten |
|---|---|
| `-t` | Empfänger stehen in den Headern (Standardfall) |
| `-f`, `-r` | Envelope-Absender; wird protokolliert, Graph sendet aber immer aus dem konfigurierten Postfach |
| `-i`, `-oi`, `-oem`, … | werden geschluckt |
| Argumente ohne `-` | Empfänger |

Fehlende Header werden ergänzt: `From`, `Date`, `Subject`, `Message-ID`,
`MIME-Version`, `Content-Type` und — bei Empfängern als Argument — `To`.
Beginnt die Eingabe nicht mit einem Header, gilt sie vollständig als Rumpf, wie
beim echten sendmail.

Exit-Codes: `0` erfolgreich, `75` (EX_TEMPFAIL) bei Versandfehler, `77` wenn
nicht als root aufgerufen, `78` wenn nicht eingerichtet.

### Nur root kann versenden

Die Konfiguration ist `0600`, und das Skript ist nicht setuid. Ein normaler
Benutzer kann also nicht über Graph versenden. Für einen Server, auf dem die
Mails von Cron und den Monitoring-Tools kommen, ist das richtig so — und msmtp
mit `0600 /etc/msmtprc` verhält sich genauso.

## Das Client-Secret

Standardmäßig im Klartext in `/etc/graph-mailer.conf` (`0600`, root). Alternativ
liefert ein Kommando es:

```sh
CLIENT_SECRET=""
CLIENT_SECRET_CMD="cat /root/.graph-secret"
```

Weder Secret noch Token stehen je in der Kommandozeile — beides geht über eine
curl-Config auf stdin, damit nichts in der Prozessliste landet.

Zertifikatsbasierte Authentifizierung wäre sicherer als ein Secret, verlangt
aber selbst signierte JWT-Assertions; das leistet dieses Skript nicht. Wer das
braucht, ist mit einem fertigen Client besser bedient.

**Client-Secrets laufen ab** (in Entra ID meist nach 6, 12 oder 24 Monaten).
Danach schlägt der Versand mit `AADSTS7000215` oder `AADSTS700082` fehl. Es
lohnt sich, das Ablaufdatum zu notieren.

## Angelegte Dateien

| Pfad | Inhalt |
|---|---|
| `/etc/graph-mailer.conf` | Tenant, Client, Secret, Absender (`0600`) |
| `/usr/local/sbin/graph-sendmail` | Shim für den sendmail-Aufruf |
| `/usr/sbin/sendmail` | Symlink, Original per dpkg-divert als `.distrib` |
| `/run/graph-mailer/token` | zwischengespeichertes Token (`0600`, tmpfs) |
| `/var/log/graph-mailer.log` | Versandprotokoll (`0600`) |

## Deinstallation

Nimmt die sendmail-Umleitung zurück (`dpkg-divert --remove --rename`), löscht
Shim, Konfiguration und Token, fragt getrennt nach dem Log. Vorher Sicherung
nach `/root/graph-mailer-uninstall-<zeit>.tar.gz` — **die enthält das
Client-Secret**, die Datei ist `0600`.

Ist danach noch `/etc/msmtprc` vorhanden, wird darauf hingewiesen: `mail-setup.sh`
kann den Versand wieder übernehmen.

Die App-Registrierung in Entra ID bleibt bestehen und muss dort gelöscht werden.

## Fehlersuche

| Meldung / Symptom | Ursache |
|---|---|
| `AADSTS7000215: Invalid client secret` | Secret falsch oder abgelaufen |
| `AADSTS700016: Application not found` | Falsche Client-ID, oder falscher Tenant |
| `AADSTS900023: Specified tenant identifier is not valid` | Tippfehler in der Tenant-ID |
| HTTP 403 `ErrorAccessDenied` | `Mail.Send` fehlt, ist nur delegiert statt Anwendung, oder die Admin-Zustimmung fehlt |
| HTTP 404 `ResourceNotFound` | Das Absender-Postfach gibt es nicht (UPN falsch), oder es ist kein Exchange-Postfach |
| HTTP 403 trotz korrekter Berechtigung | Eine Anwendungszugriffsrichtlinie in Exchange sperrt dieses Postfach aus |
| HTTP 413 | Nachricht größer als 4 MB |
| `nur root kann versenden` | Ein Dienst versucht als eigener Benutzer zu senden — siehe oben |
| Mail kommt an, steht aber nicht in „Gesendet" | Beim MIME-Versand entscheidet das Postfach; ein Schalter dafür existiert in dieser Variante nicht |
| Nach `apt install` eines MTA geht nichts mehr | Das Paket hat `/usr/sbin/sendmail` neu gesetzt; Menüpunkt 5 hängt die Umleitung wieder ein |
