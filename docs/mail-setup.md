# mail-setup.sh — SMTP-Versand

Richtet `msmtp` als sendmail-Ersatz ein, damit der Server Mails über einen
beliebigen SMTP-Zugang verschicken kann. Grundlage für die Alerts von
`auto-update`, `tcp-monitor` und `disk-monitor` — und für Cron- und Systemmails.

## Voraussetzungen

- Debian oder Ubuntu (apt), root-Rechte
- Zugangsdaten eines SMTP-Servers (Host, Port, Benutzer, Passwort)

## Aufruf

```bash
sudo ./mail-setup.sh              # Menü (richtet beim ersten Start direkt ein)
sudo ./mail-setup.sh --test       # nur Testmail senden
sudo ./mail-setup.sh --uninstall  # Konfiguration entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Einrichten / Parameter bearbeiten |
| 2 | Testmail senden |
| 3 | Konfiguration anzeigen (Passwort maskiert) |
| 4 | Versand-Log anzeigen |
| 5 | Deinstallieren |
| 6 | Beenden |

## Pakete

`msmtp`, `msmtp-mta` und `bsd-mailx` werden bei Bedarf installiert.

- **`msmtp-mta`** legt `/usr/sbin/sendmail` als Verweis auf msmtp an. Dadurch
  gehen auch Cron-Mails und alles andere, was `sendmail` aufruft, über den
  konfigurierten Zugang.
- **`bsd-mailx`** liefert das `mail`-Kommando, das die Monitoring-Tools
  benutzen.

## Einrichtung

| Frage | Bemerkung |
|---|---|
| SMTP-Server | Pflicht |
| Verschlüsselung | STARTTLS (587) / TLS (465) / unverschlüsselt (25) |
| Port | Default passend zur Verschlüsselung |
| Authentifizierung | wenn ja: Benutzer und Passwort |
| Absenderadresse | Pflicht, landet als `From` |
| Standard-Empfänger | setzt den `root:`-Alias in `/etc/aliases` |
| Zertifikatsprüfung | Default ja (`/etc/ssl/certs/ca-certificates.crt`) |

Ein erneuter Lauf schlägt alle bisherigen Werte als Default vor. Beim Passwort
bedeutet eine leere Eingabe „bestehendes behalten".

Erzeugt wird `/etc/msmtprc` mit `0600` und Eigentümer root:

```
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log
timeout        20

account        default
host           smtp.example.com
port           587
from           server@example.com
user           server@example.com
password       ...
```

## Der root-Alias

Ist ein Standard-Empfänger angegeben, wird in `/etc/aliases` eine Zeile
`root: adresse@example.com` gesetzt (oder ersetzt) und `newaliases` aufgerufen.
Damit landen auch Mails, die Programme an `root` schicken, im Postfach.

## Das Passwort

Es steht im Klartext in `/etc/msmtprc`, lesbar nur für root. Das ist bei msmtp
so vorgesehen. Wer das nicht will, hinterlegt beim Provider ein App-Passwort mit
ausschließlich Versand-Berechtigung — dann ist der Schaden bei einem
kompromittierten Server auf „kann Mails verschicken" begrenzt.

## Testmail

Menüpunkt 2 verschickt eine Mail mit Betreff, Hostname und Zeitstempel an einen
frei wählbaren Empfänger (Default: der root-Alias). Schlägt es fehl, werden
direkt die letzten zehn Zeilen aus `/var/log/msmtp.log` angezeigt.

## Angelegte Dateien

| Pfad | Inhalt |
|---|---|
| `/etc/msmtprc` | Konfiguration inklusive Passwort (`0600`) |
| `/etc/aliases` | Zeile `root: …` |
| `/var/log/msmtp.log` | Versandprotokoll (`0600`) |
| `/usr/sbin/sendmail` | Verweis auf msmtp, kommt aus dem Paket `msmtp-mta` |

## Zusammenspiel mit den anderen Tools

`auto-update`, `tcp-monitor` und `disk-monitor` rufen schlicht `mail` auf. Ist
der Mailer nicht eingerichtet, laufen sie normal weiter und schreiben nur ins
Log — kein Tool bricht deswegen ab.

## Deinstallation

Entfernt `/etc/msmtprc`, fragt getrennt nach dem `root:`-Alias und dem
Versand-Log. Vorher wird nach `/root/mail-setup-uninstall-<zeit>.tar.gz`
gesichert (enthält das Passwort — Datei ist `0600`).

Die Pakete bleiben installiert. Manuell:

```bash
apt purge msmtp msmtp-mta bsd-mailx
```

Achtung: damit verschwindet auch `/usr/sbin/sendmail`, und Cron- sowie
Systemmails fallen anschließend **still** aus.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| `TLS handshake failed` | Falsche Verschlüsselungsart für den Port — 587 will STARTTLS, 465 will TLS |
| `authentication failed` | Bei Providern mit 2FA das normale Passwort statt eines App-Passworts |
| Mail wird angenommen, kommt aber nicht an | SPF/DKIM des Absenderdomains; `from` muss zum Zugang passen |
| `mail: command not found` | `bsd-mailx` fehlt — Menüpunkt 1 erneut aufrufen |
| Cron-Mails kommen nicht | `msmtp-mta` fehlt, es gibt kein `/usr/sbin/sendmail` |
| Nichts im Log | Bei erfolgreicher Übergabe schreibt msmtp nur eine Zeile; `tail -f /var/log/msmtp.log` während des Tests |
