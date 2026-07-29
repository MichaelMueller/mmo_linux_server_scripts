#!/usr/bin/env bash
# modules/caddy.sh - vHost-Verwaltung fuer natives Caddy (systemd).
#
# Ein vHost = eine Datei in /etc/caddy/sites.d/<slug>.caddy, eingebunden per
# 'import' aus /etc/caddy/Caddyfile. Drei Typen: proxy, static, redirect.
#
# Die erste Zeile jeder vHost-Datei ist eine Metazeile:
#   # <APP_NAME> vhost | type=proxy | domains=a.de, www.a.de | target=127.0.0.1:3000 | ...
# Daraus lesen list/show/edit die Struktur zurueck - kein Raten aus der Caddy-Syntax.
#
# Wildcards (*.example.com) werden abgelehnt: Let's Encrypt stellt Wildcard-
# Zertifikate nur ueber die DNS-01-Challenge aus, dafuer braeuchte Caddy ein
# DNS-Provider-Plugin (eigener Build). Jede Subdomain einzeln anlegen.

register caddy install caddy_install "Caddy installieren + Basis-Konfiguration"
register caddy list    caddy_list    "vHosts auflisten"
register caddy add     caddy_add     "vHost anlegen"
register caddy show    caddy_show    "vHost anzeigen"
register caddy edit    caddy_edit    "vHost aendern"
register caddy remove  caddy_remove  "vHost loeschen"
register caddy reload  caddy_reload  "Konfiguration pruefen + neu laden"
register caddy status  caddy_status  "Caddy-Status"

CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"
CADDY_SITES="${CADDY_SITES:-/etc/caddy/sites.d}"
CADDY_ROOT="${CADDY_ROOT:-/srv/sites}"
# Kommentar-Datei, damit der import-Glob auch ohne vHosts matcht.
CADDY_KEEP="000-readme.caddy"

# Von _caddy_norm_domains / _caddy_ask_type_target gesetzt:
CADDY_DOMAINS=""; CADDY_FIRST=""; CADDY_SLUG=""
CADDY_TYPE=""; CADDY_TARGET=""; CADDY_CODE=""; CADDY_STREAM="n"

# --- Helfer ----------------------------------------------------------------

_caddy_slug() { printf '%s' "$1" | tr -c 'a-zA-Z0-9.-' '_' | sed 's/_*$//'; }

_caddy_need() {
  have caddy || { err "Caddy ist nicht installiert - erst: ./setup.sh caddy install"; return 1; }
  $SUDO test -f "$CADDY_FILE" || { err "$CADDY_FILE fehlt - erst: ./setup.sh caddy install"; return 1; }
  ensure_tool envsubst gettext-base
}

# Domainliste pruefen und normalisieren -> CADDY_DOMAINS / CADDY_FIRST / CADDY_SLUG
_caddy_norm_domains() {
  local raw="$1" d out=""
  local -a list=()
  [[ -n "$(trim "$raw")" ]] || { err "Keine Domain angegeben."; return 1; }
  IFS=',' read -ra list <<< "$raw"
  for d in "${list[@]}"; do
    d="$(trim "$d")"
    [[ -n "$d" ]] || continue
    if [[ "$d" == *'*'* ]]; then
      err "Wildcard '$d' wird nicht unterstuetzt."
      warn "Let's Encrypt stellt Wildcard-Zertifikate nur ueber DNS-01 aus; Caddy"
      warn "braeuchte dafuer ein DNS-Provider-Plugin (eigener Build mit xcaddy)."
      warn "Bitte jede Subdomain einzeln als vHost anlegen."
      return 1
    fi
    if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
      err "Ungueltige Domain: '$d'"
      return 1
    fi
    out="${out:+$out, }$d"
    [[ -n "$CADDY_FIRST" ]] || CADDY_FIRST="$d"
  done
  [[ -n "$out" ]] || { err "Keine gueltige Domain in '$raw'."; return 1; }
  CADDY_DOMAINS="$out"
  CADDY_SLUG="$(_caddy_slug "$CADDY_FIRST")"
}

# Metazeile auslesen: _caddy_meta DATEI KEY
_caddy_meta() {
  local v
  v="$($SUDO sed -n "1s/.*| *$2=\\([^|]*\\).*/\\1/p" "$1" 2>/dev/null || true)"
  trim "$v"
}

_caddy_files() { $SUDO ls -1 "$CADDY_SITES"/*.caddy 2>/dev/null | grep -v "/$CADDY_KEEP\$" || true; }

# Domain (oder Slug) -> vHost-Datei
_caddy_file_for() {
  local q; q="$(trim "$1")"
  [[ -n "$q" ]] || return 1
  local f c
  f="$CADDY_SITES/$(_caddy_slug "$q").caddy"
  if $SUDO test -f "$f"; then printf '%s' "$f"; return 0; fi
  # zweiter Versuch: die Domain steht in der Metazeile eines vHosts
  while read -r c; do
    [[ -n "$c" ]] || continue
    if _caddy_meta "$c" domains | tr ',' '\n' | sed 's/ //g' | grep -qx -- "$q"; then
      printf '%s' "$c"; return 0
    fi
  done < <(_caddy_files)
  return 1
}

# Lese-/Durchlaufrecht fuer den caddy-User auf einem Verzeichnisbaum (haeufige 403-Ursache).
_caddy_grant_read() {
  local root="$1" d
  have setfacl || ensure_tool setfacl acl
  if ! $SUDO setfacl -R -m u:caddy:rX "$root" 2>/dev/null; then
    warn "ACL nicht moeglich - falls 403: '$root' fuer den User 'caddy' lesbar machen."
    return 0
  fi
  $SUDO setfacl -R -d -m u:caddy:rX "$root" 2>/dev/null || true
  d="$(dirname "$root")"
  while [[ "$d" != "/" && -n "$d" ]]; do
    $SUDO setfacl -m u:caddy:x "$d" 2>/dev/null || true
    d="$(dirname "$d")"
  done
}

_caddy_ask_type_target() {
  CADDY_TYPE="${1:-}"; CADDY_TARGET="${2:-}"; CADDY_STREAM="${CADDY_STREAM:-n}"
  if [[ -z "$CADDY_TYPE" ]]; then
    ask_choice CADDY_TYPE "Typ" "proxy" proxy static redirect
  fi
  case "$CADDY_TYPE" in
    proxy)
      if [[ -z "$CADDY_TARGET" ]]; then
        ask CADDY_TARGET "Ziel (host:port)" "127.0.0.1:8080"
      fi
      if [[ ! "$CADDY_TARGET" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
        err "Ziel muss host:port sein (z.B. 127.0.0.1:3000), nicht: '$CADDY_TARGET'"; return 1
      fi
      # Nicht-interaktiv (-y) bleibt es beim uebergebenen Wert (Default n) - sonst
      # wuerde confirm mit ASSUME_YES ungefragt Streaming einschalten.
      if [[ "$ASSUME_YES" != 1 ]]; then
        local sdef=N; yesish "$CADDY_STREAM" && sdef=Y
        echo "    WebSockets laufen in Caddy ohne Zusatzkonfiguration."
        if confirm "    Response-Buffering abschalten (Server-Sent-Events / Streaming)?" "$sdef"
          then CADDY_STREAM="j"; else CADDY_STREAM="n"; fi
      fi
      CADDY_CODE=""
      ;;
    static)
      if [[ -z "$CADDY_TARGET" ]]; then
        ask CADDY_TARGET "Verzeichnis" "$CADDY_ROOT/$CADDY_SLUG"
      fi
      if [[ "$CADDY_TARGET" != /* ]]; then
        err "Verzeichnis muss ein absoluter Pfad sein: '$CADDY_TARGET'"; return 1
      fi
      CADDY_CODE=""; CADDY_STREAM="n"
      ;;
    redirect)
      if [[ -z "$CADDY_TARGET" ]]; then
        ask CADDY_TARGET "Ziel-URL (z.B. https://neu.example.com)" ""
      fi
      if [[ ! "$CADDY_TARGET" =~ ^https?://[^[:space:]]+$ ]]; then
        err "Ziel-URL muss mit http:// oder https:// beginnen: '$CADDY_TARGET'"; return 1
      fi
      CADDY_TARGET="${CADDY_TARGET%/}"      # Slash weg, {uri} bringt ihn mit
      ask CADDY_CODE "Redirect-Code" "301"  # gesetzter Wert bleibt Default
      if [[ ! "$CADDY_CODE" =~ ^30[1278]$ ]]; then
        err "Code muss 301, 302, 307 oder 308 sein: '$CADDY_CODE'"; return 1
      fi
      CADDY_STREAM="n"
      ;;
    *)
      err "Unbekannter Typ: '$CADDY_TYPE' (erlaubt: proxy, static, redirect)"; return 1 ;;
  esac
}

# vHost-Datei schreiben (Metazeile + gerendertes Template).
_caddy_render() {
  local f="$1" tpl tmp
  case "$CADDY_TYPE" in
    proxy)
      tpl="vhost-proxy.caddy.tmpl"
      if yesish "$CADDY_STREAM"; then tpl="vhost-proxy-stream.caddy.tmpl"; fi
      ;;
    static)   tpl="vhost-static.caddy.tmpl" ;;
    redirect) tpl="vhost-redirect.caddy.tmpl" ;;
    *) err "interner Fehler: Typ '$CADDY_TYPE'"; return 1 ;;
  esac
  [[ -f "$TEMPLATE_DIR/$tpl" ]] || { err "Template fehlt: $TEMPLATE_DIR/$tpl"; return 1; }

  if [[ "$CADDY_TYPE" == static ]]; then
    $SUDO mkdir -p "$CADDY_TARGET"
    if ! $SUDO test -e "$CADDY_TARGET/index.html"; then
      printf '<!doctype html>\n<meta charset="utf-8">\n<title>%s</title>\n<h1>%s</h1>\n<p>Platzhalter. Inhalt nach %s kopieren.</p>\n' \
        "$CADDY_FIRST" "$CADDY_FIRST" "$CADDY_TARGET" | $SUDO tee "$CADDY_TARGET/index.html" >/dev/null
      log "Platzhalter-index.html angelegt."
    fi
    _caddy_grant_read "$CADDY_TARGET"
  fi

  tmp="$(mktemp)"
  {
    printf '# %s vhost | type=%s | domains=%s | target=%s | code=%s | stream=%s\n' \
      "$APP_NAME" "$CADDY_TYPE" "$CADDY_DOMAINS" "$CADDY_TARGET" "${CADDY_CODE:-}" "$CADDY_STREAM"
    printf '# Verwaltet von setup.sh - Aenderungen bitte ueber: setup.sh caddy edit %s\n' "$CADDY_FIRST"
    SITE_DOMAINS="$CADDY_DOMAINS" SITE_TARGET="$CADDY_TARGET" SITE_CODE="${CADDY_CODE:-301}" \
      envsubst '$SITE_DOMAINS $SITE_TARGET $SITE_CODE' < "$TEMPLATE_DIR/$tpl"
  } > "$tmp"
  $SUDO mkdir -p "$CADDY_SITES"
  $SUDO install -m 644 -o root -g root "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# Nach dem Schreiben pruefen; bei ungueltiger Konfiguration zurueckrollen.
_caddy_apply() { # _caddy_apply DATEI [BACKUP]
  local f="$1" bak="${2:-}"
  if caddy_reload; then return 0; fi
  err "Caddy hat die Konfiguration abgelehnt -> Rollback."
  if [[ -n "$bak" && -s "$bak" ]]; then $SUDO install -m 644 -o root -g root "$bak" "$f"
  else $SUDO rm -f "$f"; fi
  if caddy_reload >/dev/null 2>&1; then
    log "Rollback ok - der vorherige Stand ist wieder aktiv."
  else
    err "Caddy laeuft weiter mit der zuletzt geladenen Konfiguration - bitte manuell pruefen."
  fi
  return 1
}

# --- Verben ----------------------------------------------------------------

# caddy install [ACME-EMAIL]   (Argument macht den Lauf mit -y skriptbar)
caddy_install() {
  local cf tmp; cf="$(conf_file caddy)"; conf_load "$cf"
  [[ -n "${1:-}" ]] && ACME_EMAIL="$1"

  if have caddy; then
    log "Caddy ist installiert: $(caddy version 2>/dev/null | head -1)"
  else
    have apt-get || die "Kein apt - Caddy manuell installieren: https://caddyserver.com/docs/install"
    log "Installiere Caddy aus dem offiziellen Repo ..."
    ensure_tool curl curl; ensure_tool gpg gnupg
    $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | $SUDO gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    $SUDO chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    $SUDO apt-get update && $SUDO apt-get install -y caddy
  fi
  ensure_tool envsubst gettext-base

  ask ACME_EMAIL "E-Mail fuer Let's Encrypt (Ablauf-Warnungen)" "${ACME_EMAIL:-}"
  if [[ -z "$ACME_EMAIL" ]]; then
    err "Ohne E-Mail keine Basis-Konfiguration - Abbruch."
    warn "Nicht-interaktiv: ./setup.sh -y caddy install admin@example.com"
    return 1
  fi
  conf_save "$cf" ACME_EMAIL || return 1

  $SUDO mkdir -p "$CADDY_SITES" "$CADDY_ROOT"
  # Kommentar-Datei: der import-Glob muss auch ohne vHosts etwas finden.
  if ! $SUDO test -f "$CADDY_SITES/$CADDY_KEEP"; then
    tmp="$(mktemp)"
    {
      printf '# Platzhalter, damit "import %s/*.caddy" immer matcht.\n' "$CADDY_SITES"
      printf '# vHosts verwaltet setup.sh: caddy add | list | show | edit | remove\n'
      printf '# Diese Datei nicht loeschen.\n'
    } > "$tmp"
    $SUDO install -m 644 -o root -g root "$tmp" "$CADDY_SITES/$CADDY_KEEP"; rm -f "$tmp"
  fi

  # Eine fremde Caddyfile nicht kommentarlos ueberschreiben.
  if $SUDO test -f "$CADDY_FILE" && ! $SUDO grep -q "$APP_NAME" "$CADDY_FILE"; then
    warn "$CADDY_FILE existiert und stammt nicht von diesem Tool."
    confirm "Nach $CADDY_FILE.bak sichern und ueberschreiben?" || { echo "Abbruch."; return 0; }
    $SUDO cp -a "$CADDY_FILE" "$CADDY_FILE.bak"
    log "gesichert: $CADDY_FILE.bak"
  fi

  tmp="$(mktemp)"
  APP="$APP_NAME" ACME_EMAIL="$ACME_EMAIL" SITES_GLOB="$CADDY_SITES/*.caddy" \
    envsubst '$APP $ACME_EMAIL $SITES_GLOB' < "$TEMPLATE_DIR/Caddyfile.tmpl" > "$tmp"
  $SUDO install -m 644 -o root -g root "$tmp" "$CADDY_FILE"; rm -f "$tmp"
  log "$CADDY_FILE geschrieben."

  $SUDO systemctl enable caddy >/dev/null 2>&1 || true
  caddy_reload || return 1
  echo
  log "Bereit. Ersten vHost anlegen: ./setup.sh caddy add app.example.com proxy 127.0.0.1:3000"
}

caddy_list() {
  local -a files=()
  mapfile -t files < <(_caddy_files)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "(keine vHosts in $CADDY_SITES)"
    echo "Anlegen mit: ./setup.sh caddy add <domain>"
    return 0
  fi
  printf '%-38s %-9s %s\n' "DOMAIN(S)" "TYP" "ZIEL"
  hr
  local f t d g c
  for f in "${files[@]}"; do
    t="$(_caddy_meta "$f" type)"; d="$(_caddy_meta "$f" domains)"; g="$(_caddy_meta "$f" target)"
    if [[ -z "$t" ]]; then
      # Handgeschriebene Datei ohne Metazeile: erste Nutzzeile als Domain zeigen.
      t="manuell"
      d="$($SUDO awk '!/^[[:space:]]*(#|$)/{sub(/[[:space:]]*\{.*/,""); print; exit}' "$f")"
      g="$(basename "$f")"
    fi
    c="$(_caddy_meta "$f" code)"
    [[ -n "$c" ]] && g="$g  ($c)"
    printf '%-38s %-9s %s\n' "${d:-?}" "$t" "${g:-?}"
  done
  hr
  printf '%d vHost(s) in %s\n' "${#files[@]}" "$CADDY_SITES"
}

# caddy add [DOMAIN(S)] [TYP] [ZIEL] [CODE]
caddy_add() {
  _caddy_need || return 1
  local domains="${1:-}" f
  CADDY_DOMAINS=""; CADDY_FIRST=""; CADDY_SLUG=""; CADDY_CODE="${4:-}"; CADDY_STREAM="n"
  if [[ -z "$domains" ]]; then
    echo "Mehrere Domains fuer denselben vHost mit Komma trennen,"
    echo "z.B. example.com,www.example.com (Wildcards sind nicht moeglich)."
    read -rp "Domain(s): " domains || true
  fi
  _caddy_norm_domains "$domains" || return 1

  f="$CADDY_SITES/$CADDY_SLUG.caddy"
  if $SUDO test -f "$f"; then
    err "vHost existiert bereits: $f"
    warn "Aendern mit: ./setup.sh caddy edit $CADDY_FIRST"
    return 1
  fi
  _caddy_ask_type_target "${2:-}" "${3:-}" || return 1
  _caddy_render "$f" || return 1
  _caddy_apply "$f" || return 1

  log "vHost angelegt: $CADDY_DOMAINS  [$CADDY_TYPE -> $CADDY_TARGET]"
  warn "DNS fuer $CADDY_DOMAINS auf die Server-IP zeigen lassen."
  warn "Caddy holt das Zertifikat automatisch beim ersten Aufruf."
}

caddy_show() {
  _caddy_need || return 1
  local q="${1:-}" f
  if [[ -z "$q" ]]; then caddy_list; echo; read -rp "Domain: " q || true; fi
  f="$(_caddy_file_for "$q")" || { err "Kein vHost gefunden fuer: '$q'"; return 1; }
  printf '%s\n' "$f"
  hr
  $SUDO cat "$f"
  hr
}

caddy_edit() {
  _caddy_need || return 1
  local q="${1:-}" f bak
  if [[ -z "$q" ]]; then caddy_list; echo; read -rp "Zu aendernde Domain: " q || true; fi
  f="$(_caddy_file_for "$q")" || { err "Kein vHost gefunden fuer: '$q'"; return 1; }

  echo "Aktuell:"; $SUDO cat "$f" | indent; echo

  CADDY_DOMAINS=""; CADDY_FIRST=""; CADDY_SLUG=""
  CADDY_TYPE="$(_caddy_meta "$f" type)"
  CADDY_TARGET="$(_caddy_meta "$f" target)"
  CADDY_CODE="$(_caddy_meta "$f" code)"
  CADDY_STREAM="$(_caddy_meta "$f" stream)"; CADDY_STREAM="${CADDY_STREAM:-n}"
  local olddom; olddom="$(_caddy_meta "$f" domains)"
  if [[ -z "$CADDY_TYPE" ]]; then
    warn "Diese Datei hat keine Metazeile (handgeschrieben?) - sie wird neu aufgebaut."
    CADDY_TYPE=""; CADDY_TARGET=""
  fi

  local newdom="$olddom"
  ask newdom "Domain(s)" "${olddom:-$q}"
  _caddy_norm_domains "$newdom" || return 1

  # Typ/Ziel neu erfragen, aktueller Wert ist Default.
  local t="$CADDY_TYPE"
  ask_choice t "Typ" "${CADDY_TYPE:-proxy}" proxy static redirect
  if [[ "$t" != "$CADDY_TYPE" ]]; then CADDY_TARGET=""; CADDY_CODE=""; fi
  CADDY_TYPE="$t"
  local keep="$CADDY_TARGET"
  CADDY_TARGET=""
  if [[ -n "$keep" ]]; then ask CADDY_TARGET "Ziel" "$keep"; fi
  _caddy_ask_type_target "$CADDY_TYPE" "$CADDY_TARGET" || return 1

  bak="$(mktemp)"; $SUDO cat "$f" > "$bak"
  local newf="$CADDY_SITES/$CADDY_SLUG.caddy"
  if [[ "$newf" != "$f" ]]; then
    if $SUDO test -f "$newf"; then err "Es gibt schon einen vHost fuer $CADDY_FIRST ($newf)."; rm -f "$bak"; return 1; fi
    $SUDO rm -f "$f"
    log "Primaerdomain geaendert: $(basename "$f") -> $(basename "$newf")"
  fi
  if ! _caddy_render "$newf"; then
    $SUDO install -m 644 -o root -g root "$bak" "$f"; rm -f "$bak"
    err "Rendern fehlgeschlagen - alter Stand wiederhergestellt."
    return 1
  fi
  local applied=0
  if [[ "$newf" == "$f" ]]; then
    _caddy_apply "$newf" "$bak" && applied=1
  else
    # Primaerdomain geaendert: bei Fehler muss die NEUE Datei weg und die alte
    # zurueck - sonst liegen beide da und Caddy sieht doppelte Site-Adressen.
    if _caddy_apply "$newf"; then
      applied=1
    else
      $SUDO install -m 644 -o root -g root "$bak" "$f"
      caddy_reload >/dev/null 2>&1 || true
      warn "Alter vHost $(basename "$f") ist wieder da."
    fi
  fi
  rm -f "$bak"
  [[ $applied -eq 1 ]] || return 1
  log "vHost geaendert: $CADDY_DOMAINS  [$CADDY_TYPE -> $CADDY_TARGET]"
}

caddy_remove() {
  _caddy_need || return 1
  local q="${1:-}" f bak t target
  if [[ -z "$q" ]]; then caddy_list; echo; read -rp "Zu loeschende Domain: " q || true; fi
  f="$(_caddy_file_for "$q")" || { err "Kein vHost gefunden fuer: '$q'"; return 1; }
  t="$(_caddy_meta "$f" type)"; target="$(_caddy_meta "$f" target)"

  echo "Wird geloescht:"; $SUDO cat "$f" | indent; echo
  confirm "vHost $(basename "$f") wirklich loeschen?" || { echo "Abbruch."; return 0; }

  bak="$(mktemp)"; $SUDO cat "$f" > "$bak"
  $SUDO rm -f "$f"
  if ! caddy_reload; then
    $SUDO install -m 644 -o root -g root "$bak" "$f"; rm -f "$bak"
    err "Caddy meldet danach einen Fehler - vHost wiederhergestellt."
    return 1
  fi
  rm -f "$bak"
  log "vHost geloescht: $f"

  if [[ "$t" == static && -n "$target" ]] && $SUDO test -d "$target"; then
    warn "Die Dateien unter $target bleiben liegen."
    if confirm "Verzeichnis $target loeschen?"; then
      $SUDO rm -rf -- "$target"; log "geloescht: $target"
    fi
  fi
}

caddy_reload() {
  have caddy || { err "Caddy ist nicht installiert."; return 1; }
  if ! $SUDO caddy validate --adapter caddyfile --config "$CADDY_FILE" >/dev/null 2>&1; then
    err "Caddy-Konfiguration ist ungueltig:"
    $SUDO caddy validate --adapter caddyfile --config "$CADDY_FILE" 2>&1 | tail -20 | indent || true
    return 1
  fi
  if $SUDO systemctl reload caddy 2>/dev/null; then log "Caddy neu geladen."
  elif $SUDO systemctl restart caddy 2>/dev/null; then log "Caddy neu gestartet."
  else err "Caddy laesst sich nicht neu laden - pruefe: systemctl status caddy"; return 1; fi
}

caddy_status() {
  echo "== Caddy =="
  if have caddy; then
    printf '    %s\n' "$(caddy version 2>/dev/null | head -1)"
    printf '    Dienst: %s\n' "$(unit_state caddy.service)"
  else
    printf '    (nicht installiert)\n'; return 0
  fi
  printf '    Caddyfile: %s\n' "$CADDY_FILE"
  if $SUDO test -f "$CADDY_FILE"; then
    if $SUDO caddy validate --adapter caddyfile --config "$CADDY_FILE" >/dev/null 2>&1; then
      printf '    Konfiguration: gueltig\n'
    else
      printf '    Konfiguration: UNGUELTIG (Details: ./setup.sh caddy reload)\n'
    fi
  else
    printf '    Konfiguration: fehlt (./setup.sh caddy install)\n'
  fi
  echo; echo "== Konfiguration =="
  conf_show "$(conf_file caddy)"
  echo; echo "== vHosts =="
  caddy_list | indent
}
