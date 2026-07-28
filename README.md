# home_stack v2 – modulares Server-Steuerungssystem

Zentrales Bash-Tool, um wiederkehrende Aufgaben auf Linux-Servern (die Webanwendungen
bereitstellen) zu bündeln: Server-Härtung, Mail, Auto-Updates, Health-Checks, Docker,
Caddy/Reverse-Proxy, Backups – und die einzelnen Anwendungen (Rauthy, Nextcloud,
Vaultwarden) mit je eigenen Optionen (Status, Update, …).

> v2 ist ein eigenständiger Neubau neben dem alten Top-Level (v1). Deploy-Ziel ist
> `v2/var/` (gitignored), überschreibbar via `DEPLOY_DIR`.

## Benutzung

```bash
cd v2
./setup.sh                     # interaktives, kategorisiertes Menue
./setup.sh <modul> <verb> ...  # Befehl direkt (-y = keine Rueckfragen)
./setup.sh <modul>             # Befehle eines Moduls anzeigen
./setup.sh --help              # alle Befehle
```

Beispiele:

```bash
./setup.sh stack all                       # Komplett-Setup (rendern+start+caddy+wire+office)
./setup.sh nextcloud update                # gestuftes Major-Upgrade (30->31->...)
./setup.sh caddy add-proxy app.ex.com 127.0.0.1:3000
./setup.sh caddy add-redirect alt.ex.com https://neu.ex.com 301
./setup.sh server harden                   # SSH + ufw + fail2ban (mit Guardrails)
./setup.sh health check                    # Disk/Last/RAM/Docker/systemd/Cert/Traffic
./setup.sh smtp setup                      # Mailer fuer Reports
```

## Aufbau

```
setup.sh          Entrypoint: laedt lib + module, baut Registry, Menue/Dispatch
lib/              Kernbibliothek (gesourct)
  core.sh         Rechte, Tool-Install, Logging, Secrets
  ui.sh           confirm/ask/ask_secret, yesish
  conf.sh         var/.setup.conf (conf_load/set, env_set, require_keys, sq)
  docker.sh       ensure_docker, dc(), need_docker, occ()
  cron.sh         install_cron/remove_cron/has_cron
  mail.sh         notify() ueber var/send-mail.sh (No-op ohne SMTP)
  report.sh       Report sammeln + report_send (always/changes/never)
  registry.sh     category/register + Menue/Dispatch/Help
modules/          je Modul registriert seine Befehle
  server-hardening.sh  smtp.sh  updates.sh  health.sh
  docker.sh  caddy.sh  stack.sh  backup.sh
  apps/rauthy.sh  apps/nextcloud.sh  apps/vaultwarden.sh
templates/        docker-compose.yml, env.tmpl, Caddyfile.native.tmpl, rauthy/,
                  site-{proxy,proxy-ws,static,redirect}.caddy.tmpl, send-mail.sh, website/
```

Cron-Läufe gehen über denselben Entrypoint (nicht-interaktive Verben), z. B.
`.../v2/setup.sh updates run`, `backup nightly-run`, `health run`, `vaultwarden export-run`.

## Konfiguration

- Stack-Werte (Domains, Image-Tags, Secrets) in `var/.setup.conf`, geschrieben von
  `stack config`. Gezielte Änderungen via `conf_set`/`env_set` (z. B. App-Updates).
- Feature-Module haben eigene Env-Dateien: `.smtp.env`, `.auto-update.env`,
  `.backup-nightly.env`, `.vw-export.env`, `.hardening.env`, `.health.env` (alle 0600).
- Allgemeine Module (hardening/smtp/health/docker/caddy) laufen auch **ohne** gerenderten
  Stack; nur stack-/app-Module verlangen die Stack-Keys (`require_keys`).

## Neues Modul hinzufügen

Datei in `modules/` (oder `modules/apps/`) anlegen, beim Sourcen Befehle registrieren:

```bash
register <modul> <verb> <funktion> "Label" [menu]   # menu=0 -> nur CLI, nicht im Menue
```

Die passende Kategorie-Reihenfolge/-Titel steht in `setup.sh` (`category …`). Neue
Verben erscheinen automatisch nummeriert im Menü und im `--help`.

## Sicherheit

- Secrets/Configs unter `var/` (0600, gitignored). Mailer `send-mail.sh`: TLS erzwungen,
  Passwort nie in der Prozessliste.
- Server-Härtung mit Aussperr-Guardrails: SSH-Änderungen als Drop-in
  (`/etc/ssh/sshd_config.d/99-hardening.conf`), `sshd -t` vor Reload, Passwort-Login wird
  nur mit vorhandenem `authorized_keys` deaktiviert; ufw erlaubt den SSH-Port **zuerst**.
  Trotzdem: bei Härtung immer eine **zweite SSH-Sitzung offen halten**.
- `nextcloud update` macht Major-Upgrades **einzeln** (nie überspringen), mit Backup-Angebot
  und Verifikation pro Schritt.
