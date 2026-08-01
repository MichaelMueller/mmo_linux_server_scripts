# base-tools.sh — Basis-Werkzeuge und Shell-Komfort

Installiert die Pakete, die man auf einem frischen Server sowieso als erstes
nachinstalliert, und legt systemweite Voreinstellungen für Shell, vim, nano und
screen an.

## Voraussetzungen

- Debian oder Ubuntu (apt)
- root-Rechte

## Aufruf

```bash
sudo ./base-tools.sh              # Menü
sudo ./base-tools.sh --status     # zeigt, was installiert und gesetzt ist
sudo ./base-tools.sh --uninstall  # Voreinstellungen entfernen
```

## Menü

| Punkt | Wirkung |
|---|---|
| 1 | Alles einrichten: Paketauswahl und danach alle Voreinstellungen |
| 2 | Nur Pakete installieren |
| 3 | Nur Voreinstellungen schreiben |
| 4 | Status: Häkchenliste über Pakete und Dateien |
| 5 | Deinstallieren |
| 6 | Beenden |

## Pakete

| Gruppe | Pakete | Default |
|---|---|---|
| **Grundlage** | `git ca-certificates` | **immer, keine Rückfrage** |
| Editoren | `nano vim` | ja |
| Terminal-Sessions | `screen tmux` | ja |
| Werkzeuge | `htop curl wget unzip rsync tree ncdu bash-completion` | ja |
| Netzwerk-Diagnose | `dnsutils net-tools mtr-tiny` | nein |

`git` und `ca-certificates` sind nicht abwählbar: ohne sie kommt man auf einem
Server nicht weit, `ca-certificates` braucht jedes `https`, und der Git-Updater
setzt git voraus. Sie stehen aus demselben Grund auch nicht in der
`apt purge`-Zeile, die die Deinstallation ausgibt.

Installiert wird **paketweise**, nicht in einem Aufruf: ein Paketname, den es
auf der jeweiligen Distribution nicht gibt, bricht damit nicht den ganzen Lauf
ab, sondern wird nur gemeldet. Bereits installierte Pakete werden übersprungen.

## Voreinstellungen

| Datei | Inhalt | Form |
|---|---|---|
| `/etc/profile.d/zz-base-tools.sh` | Farben, Aliase, History, Prompt | eigene Datei |
| `/etc/bash.bashrc` | lädt die Datei oben auch für Nicht-Login-Shells | markierter Block |
| `/etc/vim/vimrc.local` | Zeilennummern, Suche, 4er-Einrückung, `set mouse=` | eigene Datei |
| `/etc/nanorc` | Zeilennummern, Tabs, Syntax-Includes | markierter Block |
| `/etc/screenrc` | Scrollback 10000, Statuszeile, kein Startbanner | markierter Block |

Die Shell-Datei setzt unter anderem:

```sh
alias ll='ls -alFh'          HISTSIZE=5000
alias grep='grep --color=auto'   HISTCONTROL=ignoreboth
LESS='-R'                    HISTTIMEFORMAT='%F %T  '
PS1: root rot, normaler Benutzer grün, Pfad blau
```

Sie steigt sofort aus, wenn die Shell nicht interaktiv oder keine bash ist —
`/etc/profile.d/*.sh` wird auch von `dash` gelesen.

### Warum ein Verweis aus /etc/bash.bashrc?

`/etc/profile.d` liest nur eine **Login**-Shell. `ssh host befehl`, `su` und
screen starten aber Nicht-Login-Shells und bekämen sonst keine der
Einstellungen. `/etc/bash.bashrc` wird von interaktiven Nicht-Login-Shells
gelesen, deshalb steht dort der Verweis.

### Warum `set mouse=` in vim?

Ab vim 8.2 ist die Maus per Default aktiv. Beim Markieren mit der Maus springt
vim dann in den Visual-Modus, und das Kopieren über das Terminal funktioniert
nicht mehr. `set mouse=` stellt das alte Verhalten wieder her.

## Fremde Dateien

Nichts wird blind überschrieben:

- In `/etc/bash.bashrc`, `/etc/nanorc` und `/etc/screenrc` steht der eigene
  Inhalt zwischen `# >>> base-tools >>>` und `# <<< base-tools <<<`. Alles
  außerhalb bleibt unangetastet, und ein erneuter Lauf ersetzt nur den Block.
- Eine vorhandene `/etc/vim/vimrc.local`, die nicht von hier stammt, wird nach
  `/etc/vim/vimrc.local.orig` gesichert.

## Datenhaltung

Alles **system-seitig**, neben dem Skript liegt nichts — es gibt auch keine
Konfigurationsdatei, die gewählten Optionen stehen direkt in den erzeugten
Dateien.

In `/etc/nanorc`, `/etc/screenrc` und `/etc/bash.bashrc` steht der eigene Inhalt
in einem Marker-Block; fremder Inhalt in denselben Dateien bleibt unberührt und
ein erneuter Lauf ersetzt nur den Block. `/etc/profile.d/zz-base-tools.sh` und
`/etc/vim/vimrc.local` gehören dem Tool allein — eine vorgefundene `vimrc.local`
wird nach `.orig` gesichert und beim Deinstallieren zurückgeholt.

Damit lässt sich das Tool jederzeit auf ein eingerichtetes System setzen und
rückstandsfrei wieder abziehen.

## Deinstallation

Entfernt `/etc/profile.d/zz-base-tools.sh`, schneidet die markierten Blöcke
wieder heraus und stellt `vimrc.local` aus der `.orig`-Sicherung wieder her.
Dateien, die es vorher gar nicht gab (typisch `/etc/screenrc`) und die nach dem
Entfernen leer wären, werden gelöscht. Eine handgeschriebene `vimrc.local`, die
nicht von diesem Tool stammt, bleibt liegen.

Vorher wird nach `/root/base-tools-uninstall-<zeit>.tar.gz` gesichert.

**Pakete werden nicht entfernt.** Einem Server nano und vim wegzunehmen richtet
mehr Schaden an, als es aufräumt. Der passende Befehl wird ausgegeben:

```bash
apt purge nano vim screen tmux htop curl wget git unzip rsync tree ncdu \
    bash-completion ca-certificates dnsutils net-tools mtr-tiny
```

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Farben fehlen in der laufenden Shell | Die Einstellungen greifen erst in einer neuen Sitzung. Sofort: `. /etc/profile.d/zz-base-tools.sh` |
| Farben fehlen bei `ssh host befehl` | Beabsichtigt: die Datei steigt bei nicht-interaktiven Shells aus |
| nano meckert über `include` | `/usr/share/nano` fehlt. Die Zeile wird nur geschrieben, wenn das Verzeichnis existiert — nachträglich installiertes nano braucht einen erneuten Lauf von Menüpunkt 3 |
| Prompt ohne Farbe bei `su` | `su` ohne `-` behält die alte Umgebung. `su -` benutzen |
