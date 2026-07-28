#!/usr/bin/env bash
# modules/health.sh - Health-Checks (Disk/Last/RAM/Docker/systemd/Cert/Traffic).
# 'check' zeigt an, 'run' ist der Cron-Runner (Mail je nach Modus), 'cron' richtet ein.

register health check hl_check "Health-Check jetzt anzeigen"
register health cron  hl_cron  "Health-Check per Cron + Mail einrichten"
register health run   hl_run   "Health-Check ausfuehren (Cron-Runner)" 0

HL_WARN=0
hl_warn() { HL_WARN=$((HL_WARN+1)); rlog "!! $*"; }

# Sammelt den Report (rlog druckt + haengt an REPORT_FILE). set -e hier aus.
_health_scan() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  local envf="$DEPLOY_DIR/.health.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  : "${DISK_WARN:=85}"; : "${MEM_WARN:=90}"; : "${LOAD_FACTOR:=2}"
  HL_WARN=0
  local HOST; HOST="$(hostname 2>/dev/null || echo host)"
  rlog "Health-Check  $(date '+%F %T')  auf $HOST"; rlog ""

  rlog "== Speicher (Disk) =="
  local use mnt
  while read -r use mnt; do
    [[ -z "$use" ]] && continue
    if [[ "$use" -ge "$DISK_WARN" ]]; then hl_warn "Disk $mnt bei ${use}% (>= ${DISK_WARN}%)"
    else rlog "   ok  $mnt ${use}%"; fi
  done < <(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1{gsub(/%/,"",$5); print $5" "$6}')
  rlog ""

  rlog "== Last =="
  local cores load1 thr
  cores="$(nproc 2>/dev/null || echo 1)"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
  thr="$(awk -v c="$cores" -v f="$LOAD_FACTOR" 'BEGIN{printf "%.2f", c*f}')"
  if awk -v l="$load1" -v t="$thr" 'BEGIN{exit !(l>t)}'; then hl_warn "Load1 $load1 > $thr ($cores Kerne x $LOAD_FACTOR)"
  else rlog "   ok  Load1 $load1 (Schwelle $thr, $cores Kerne)"; fi
  rlog ""

  rlog "== RAM =="
  if command -v free >/dev/null 2>&1; then
    local memp; memp="$(free | awk '/^Mem:/{printf "%d", ($2-$7)/$2*100}')"
    if [[ "${memp:-0}" -ge "$MEM_WARN" ]]; then hl_warn "RAM-Nutzung ${memp}% (>= ${MEM_WARN}%)"
    else rlog "   ok  RAM ${memp}%"; fi
  else rlog "   (free nicht verfuegbar)"; fi
  rlog ""

  if command -v docker >/dev/null 2>&1; then
    rlog "== Docker =="; docker_wrap
    local bad exited
    bad="$($DOCKER ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null || true)"
    [[ -n "$bad" ]] && hl_warn "Ungesunde Container: $(echo "$bad" | tr '\n' ' ')" || rlog "   ok  keine ungesunden Container"
    exited="$($DOCKER ps -a --filter status=exited --filter status=dead --format '{{.Names}}' 2>/dev/null || true)"
    [[ -n "$exited" ]] && rlog "   Hinweis: gestoppte Container: $(echo "$exited" | tr '\n' ' ')"
    rlog ""
  fi

  if command -v systemctl >/dev/null 2>&1; then
    rlog "== systemd =="
    local failed; failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    [[ -n "$failed" ]] && hl_warn "Fehlgeschlagene Units: $failed" || rlog "   ok  keine failed units"
    rlog ""
  fi

  if [[ -n "${HEALTH_CERT_DOMAINS:-}" ]] && command -v openssl >/dev/null 2>&1; then
    rlog "== Zertifikate =="
    local d end days now
    now="$(date +%s)"
    for d in $HEALTH_CERT_DOMAINS; do
      end="$(echo | openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
      [[ -z "$end" ]] && { rlog "   ?   $d (nicht erreichbar)"; continue; }
      days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo "$now") - now ) / 86400 ))
      if [[ $days -lt 14 ]]; then hl_warn "Cert $d laeuft in $days Tagen ab"; else rlog "   ok  $d ($days Tage)"; fi
    done
    rlog ""
  fi

  rlog "== Traffic (kumuliert seit Boot) =="
  if [[ -r /proc/net/dev ]]; then
    while read -r l; do rlog "$l"; done < <(awk 'NR>2{gsub(/:/,"",$1); if($1!="lo"&&($2>0||$10>0)) printf "   %-8s rx=%.1fMiB tx=%.1fMiB\n",$1,$2/1048576,$10/1048576}' /proc/net/dev)
  fi
  rlog ""
  rlog "Ergebnis: $HL_WARN Warnung(en)."
  [[ $_e -eq 1 ]] && set -e; return 0
}

hl_check() { report_init; _health_scan; }

hl_run() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  local envf="$DEPLOY_DIR/.health.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  : "${HEALTH_MODE:=warn}"
  report_init; _health_scan
  local HOST; HOST="$(hostname 2>/dev/null || echo host)"
  local subj="home_stack Health OK: $HOST"
  [[ $HL_WARN -gt 0 ]] && subj="home_stack Health WARN ($HL_WARN): $HOST"
  case "$HEALTH_MODE" in
    never) ;;
    always) notify "$subj" < "$REPORT_FILE" ;;
    *) [[ $HL_WARN -gt 0 ]] && notify "$subj" < "$REPORT_FILE" ;;
  esac
  local rc=0; [[ $HL_WARN -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e; return $rc
}

hl_cron() {
  ensure_tool crontab cron
  local envf="$DEPLOY_DIR/.health.env"
  # shellcheck disable=SC1090
  [[ -f "$envf" ]] && source "$envf"
  echo; echo "Regelmaessigen Health-Check per Cron einrichten."
  ask DISK_WARN         "Disk-Warnschwelle in %"                 "${DISK_WARN:-85}"
  ask MEM_WARN          "RAM-Warnschwelle in %"                  "${MEM_WARN:-90}"
  ask LOAD_FACTOR       "Last-Faktor (x Kerne)"                  "${LOAD_FACTOR:-2}"
  ask HEALTH_CERT_DOMAINS "Cert-Check Domains (Leerz.-getrennt, leer=aus)" "${HEALTH_CERT_DOMAINS:-}"
  ask HEALTH_MODE       "E-Mail-Report (always/warn/never)"      "${HEALTH_MODE:-warn}"
  ask HEALTH_SCHED      "Cron-Zeitplan"                          "${HEALTH_SCHED:-0 7 * * *}"
  umask 077
  cat > "$envf" <<EOF
DISK_WARN='$DISK_WARN'
MEM_WARN='$MEM_WARN'
LOAD_FACTOR='$LOAD_FACTOR'
HEALTH_CERT_DOMAINS='$HEALTH_CERT_DOMAINS'
HEALTH_MODE='$HEALTH_MODE'
HEALTH_SCHED='$HEALTH_SCHED'
EOF
  chmod 600 "$envf"
  install_cron "$HEALTH_SCHED" "$SCRIPT_DIR/setup.sh health run >> $DEPLOY_DIR/health.log 2>&1" "home_stack-health"
  if mailer_ready; then log "Mailer erkannt: Reports Modus $HEALTH_MODE."
  else warn "Kein Mailer - nur Log. Optional: ./setup.sh smtp setup"; fi
  log "Health-Cron aktiv ($HEALTH_SCHED). Testlauf: ./setup.sh health run"
}
