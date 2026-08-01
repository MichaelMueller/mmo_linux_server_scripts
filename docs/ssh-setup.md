# ssh-setup.sh — SSH-Härtung

Härtet den SSH-Zugang über ein Drop-in: Port, Root-Login, Schlüssel statt
Passwort und ein paar Grenzwerte. Die `sshd_config` selbst bleibt unangetastet.

Der eigentliche Inhalt dieses Tools sind die Vorkehrungen gegen das Aussperren —
die einzelnen Direktiven wären in zwei Minuten von Hand geschrieben.

## Voraussetzungen

- Debian oder Ubuntu mit systemd
- root-Rechte
- **eine zweite, offene SSH-Sitzung**, solange man daran arbeitet

## Aufruf

```bash
sudo ./ssh-setup.sh              # Menü
sudo ./ssh-setup.sh --status     # wirksame Einstellungen
sudo ./ssh-setup.sh --uninstall  # zurück auf Distributions-Default
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Einrichten / Einstellungen ändern |
| 2 | Status: `sshd -T`, Drop-in, Socket-Aktivierung, hinterlegte Schlüssel, lauschende Ports |
| 3 | Öffentlichen Schlüssel für einen Benutzer hinterlegen |
| 4 | Port 22 in ufw schließen (nach erfolgreichem Test) |
| 5 | Deinstallieren |
| 6 | Beenden |

## Ablauf beim Einrichten

Erst **alle** Fragen, dann eine Zusammenfassung, dann **eine** Bestätigung.
Vorher wird nichts angefasst.

| Frage | Optionen | Default |
|---|---|---|
| Port | 1–65535 | aktueller Port |
| Root-Anmeldung | nur Schlüssel / verbieten / auch Passwort | nur Schlüssel |
| Passwort-Anmeldung | abschalten ja/nein | abschalten, falls ein Schlüssel existiert |
| MaxAuthTries | Zahl | aktueller Wert |
| LoginGraceTime | Sekunden | aktueller Wert |
| X11-Weiterleitung | ja/nein | nein |
| ClientAlive | ja/nein | ja (300 s × 2) |

Geschrieben wird ausschließlich
`/etc/ssh/sshd_config.d/99-ssh-setup.conf`. Zusätzlich wird
`KbdInteractiveAuthentication no` gesetzt — sonst bleibt bei abgeschaltetem
`PasswordAuthentication` je nach PAM-Konfiguration ein Passwort-Weg offen.

## Die Guardrails

**Reihenfolge ufw → sshd.** Der neue Port wird in ufw geöffnet, *bevor* sshd
dorthin wechselt. Port 22 bleibt zusätzlich offen; Menüpunkt 4 schließt ihn
später und weigert sich, solange sshd noch selbst auf 22 lauscht.

**`sshd -t` vor jedem Übernehmen.** Lehnt sshd die Konfiguration ab, wird das
vorherige Drop-in zurückgespielt und nichts neu gestartet.

**`ssh.socket` wird erkannt.** Ab Ubuntu 22.10 startet sshd per
Socket-Aktivierung und ignoriert die `Port`-Direktive aus der Konfiguration
vollständig — der Port muss an `ssh.socket` gesetzt werden. Ohne diese
Unterscheidung stellt man die Firewall auf den neuen Port um, während sshd
weiter auf 22 lauscht. Erkennt das Skript Socket-Aktivierung, schreibt es
zusätzlich:

```ini
# /etc/systemd/system/ssh.socket.d/10-ssh-setup-port.conf
[Socket]
ListenStream=
ListenStream=2222
```

Die leere erste Zeile ist nötig, sonst *ergänzt* systemd den Port, statt ihn zu
ersetzen.

**Passwort-Anmeldung nur bei vorhandenem Schlüssel.** Das Skript durchsucht
`/root/.ssh/authorized_keys` und `/home/*/.ssh/authorized_keys`. Findet es
nichts, bleibt die Passwort-Anmeldung an — mit Verweis auf Menüpunkt 3.

**Kombination „Root verboten + Passwort aus" wird geprüft.** Hat nur root einen
Schlüssel, käme danach niemand mehr rein; der Root-Login wird dann auf
`prohibit-password` zurückgestuft.

**Es wird nachgeprüft, ob das Drop-in ankommt.** Bei sshd gewinnt die **zuerst**
gelesene Direktive. Steht in der `sshd_config` oberhalb der `Include`-Zeile
schon `PasswordAuthentication yes`, läuft das Drop-in ins Leere — und das merkt
man sonst erst, wenn es zu spät ist. Nach dem Schreiben vergleicht das Skript
deshalb mit `sshd -T` und bietet an, die widersprechenden Zeilen
auszukommentieren:

```
# von ssh-setup deaktiviert: PasswordAuthentication yes
```

**Fehlende `Include`-Zeile** (ältere Distributionen) wird oben in der
`sshd_config` ergänzt, zwischen `# >>> ssh-setup >>>`-Markern.

## Geänderte Dateien

| Pfad | Wann |
|---|---|
| `/etc/ssh/sshd_config.d/99-ssh-setup.conf` | immer |
| `/etc/ssh/sshd_config` | nur wenn die `Include`-Zeile fehlt oder Direktiven auskommentiert werden (Sicherung: `.ssh-setup.bak`) |
| `/etc/systemd/system/ssh.socket.d/10-ssh-setup-port.conf` | nur bei Socket-Aktivierung |
| ufw-Regeln | neuer Port und 22 werden geöffnet |

## Schlüssel hinterlegen (Menüpunkt 3)

Fragt nach Benutzer und öffentlichem Schlüssel (eine Zeile), prüft grob das
Format, hängt ihn an `~/.ssh/authorized_keys` an und setzt Rechte
(`700` auf `.ssh`, `600` auf die Datei) und Eigentümer. Ein bereits vorhandener
Schlüssel wird nicht doppelt eingetragen.

## Datenhaltung

**Vollständig service-seitig.** Geschrieben wird nur das Drop-in
`/etc/ssh/sshd_config.d/99-ssh-setup.conf`; gelesen wird der *wirksame* Zustand
über `sshd -T`, also aus sshd selbst. Neben dem Skript liegt nichts, und es gibt
keine zweite Buchhaltung, die von der Wirklichkeit abweichen könnte.

Deshalb lässt sich das Tool auf einen laufenden, von Hand konfigurierten sshd
setzen: die bestehende `sshd_config` bleibt, wie sie ist. Angefasst wird sie nur
in zwei Fällen, beide mit Rückfrage und beim Deinstallieren umkehrbar:

- die `Include`-Zeile fehlt und wird oben ergänzt (zwischen Markern)
- eine Direktive oberhalb davon hebelt das Drop-in aus und wird auskommentiert

## Deinstallation

1. Port 22 wird in ufw geöffnet — **bevor** sshd dorthin zurückfällt
2. Drop-in wird entfernt, die auskommentierten Zeilen in der `sshd_config`
   werden reaktiviert, die ergänzte `Include`-Zeile herausgeschnitten
3. `sshd -t`; scheitert es, wird alles zurückgerollt
4. Socket-Drop-in weg, `daemon-reload`, Neustart

Vorher wird nach `/root/ssh-setup-uninstall-<zeit>.tar.gz` gesichert. Danach
gilt wieder der Distributions-Default (Port 22, Passwort-Anmeldung meist
erlaubt). **Hinterlegte Schlüssel bleiben liegen.**

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Port geändert, aber sshd lauscht weiter auf 22 | Socket-Aktivierung; Menüpunkt 2 zeigt, ob sie erkannt wurde |
| Einstellung „kommt nicht an" | Direktive steht oberhalb der `Include`-Zeile — das Skript bietet das Auskommentieren an |
| Nach dem Neustart keine Anmeldung mehr möglich | Über die noch offene zweite Sitzung `--uninstall` aufrufen; notfalls Konsole des Hosters |
| `Permission denied (publickey)` trotz Schlüssel | Rechte auf `~/.ssh` und `authorized_keys`, oder Schlüssel liegt beim falschen Benutzer. Menüpunkt 2 listet, wer einen hat |
| Verbindung bricht nach Minuten ab | ClientAlive ist aus und eine Zwischenstelle räumt die Sitzung weg — Menüpunkt 1, ClientAlive einschalten |
