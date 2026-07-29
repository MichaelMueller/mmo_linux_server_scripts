#!/usr/bin/env bash
# modules/health.sh - Health-Checks: Disk, Last, RAM, Dienste, Zertifikate, Traffic.
#   check   -> einmal ansehen
#   install -> per Cron regelmaessig laufen lassen und bei Warnungen mailen
#   run     -> der Cron-Runner

register health check   hl_check   "Health-Check jetzt ausfuehren"
register health install hl_install "Health-Check per Cron + Mail einrichten"
register health status  hl_status  "Status: Cron, Config, letzter Lauf"
register health remove  hl_remove  "Health-Check entfernen"
register health run     hl_run     "Ausfuehren + melden (Cron-Runner)" 0

HL_JOB="health"
HL_WARN=0

# Warnung: zaehlt hoch und markiert den Report als berichtenswert.
hl_warn() { HL_WARN=$((HL_WARN+1)); rlog "!! $*"; rchanged; }

_health_scan() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  conf_load "$(conf_file health)"
  : "${DISK_WARN:=85}"; : "${USAGE_WARN:=85}"; : "${USAGE_SAMPLES:=3}"
  : "${HEALTH_UNITS:=caddy fail2ban}"
  HL_WARN=0

  local HOST; HOST="$(hostname 2>/dev/null || echo host)"
  rlog "$APP_NAME Health-Check   $(date '+%F %T')   auf $HOST"
  rlog ""

  # --- Disk ---------------------------------------------------------------
  rlog "== Speicher =="
  # 'df --output=pcent,target' liefert genau zwei Spalten. Das alte Zaehlen von
  # awk-Feldern verrutscht, sobald ein Geraetename ein Leerzeichen enthaelt.
  local use mnt dfout
  # (-P und --output schliessen sich in coreutils gegenseitig aus.)
  if df --output=pcent,target / >/dev/null 2>&1; then
    dfout="$(df -x tmpfs -x devtmpfs -x overlay -x squashfs \
               --output=pcent,target 2>/dev/null | tail -n +2)"
  else
    # Fallback von RECHTS zaehlen: Capacity ist das vorletzte, Mountpoint das
    # letzte Feld - so verrutscht auch ein Geraetename mit Leerzeichen nichts.
    dfout="$(df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null \
               | awk 'NR>1{print $(NF-1)" "$NF}')"
  fi
  while read -r use mnt; do
    use="$(trim "${use%\%}")"
    [[ "$use" =~ ^[0-9]+$ && -n "$mnt" ]] || continue
    if [[ "$use" -ge "$DISK_WARN" ]]; then hl_warn "Disk $mnt bei ${use}% (Schwelle ${DISK_WARN}%)"
    else rlog "   ok   $mnt ${use}%"; fi
  done <<< "$dfout"
  rlog ""

  # --- Auslastung (CPU + RAM) ---------------------------------------------
  # Beides als Prozentwert gegen EINE Schwelle, und beides ueber einen Zeitraum
  # statt als Momentaufnahme:
  #   CPU  = load15 / Kerne * 100   -> echtes 15-Minuten-Mittel des Kernels,
  #          eine einzelne Lastspitze loest damit keine Mail aus
  #   RAM  = Mittel aus USAGE_SAMPLES Messungen im Abstand von 2 s, damit ein
  #          kurzer Ausschlag (Backup-Puffer o.ae.) nicht sofort warnt
  rlog "== Auslastung =="
  local cores load15 cpup
  cores="$(nproc 2>/dev/null || echo 1)"
  load15="$(awk '{print $3}' /proc/loadavg 2>/dev/null || echo 0)"
  cpup="$(awk -v l="$load15" -v c="$cores" 'BEGIN{printf "%d", (c>0 ? l/c*100 : 0)}')"
  if [[ "${cpup:-0}" -ge "$USAGE_WARN" ]]; then
    hl_warn "CPU ${cpup}% im 15-Min-Mittel (Schwelle ${USAGE_WARN}%, load15 $load15 auf $cores Kernen)"
  else
    rlog "   ok   CPU ${cpup}%  (load15 $load15 auf $cores Kernen)"
  fi

  if have free; then
    local i s sum=0 n=0 memp
    for (( i=0; i<${USAGE_SAMPLES:-3}; i++ )); do
      [[ $i -gt 0 ]] && sleep 2
      s="$(free | awk '/^Mem:/{printf "%d", ($2-$7)/$2*100}')"
      [[ "$s" =~ ^[0-9]+$ ]] || continue
      sum=$((sum+s)); n=$((n+1))
    done
    if [[ $n -gt 0 ]]; then
      memp=$((sum/n))
      if [[ "$memp" -ge "$USAGE_WARN" ]]; then
        hl_warn "RAM ${memp}% belegt (Schwelle ${USAGE_WARN}%, Mittel aus $n Messungen)"
      else
        rlog "   ok   RAM ${memp}%  (Mittel aus $n Messungen)"
      fi
    else
      rlog "   (RAM nicht messbar)"
    fi
  else
    rlog "   (free nicht verfuegbar - RAM nicht geprueft)"
  fi
  rlog ""

  # --- systemd ------------------------------------------------------------
  if have systemctl; then
    rlog "== Dienste =="
    local failed u
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    if [[ -n "$(trim "$failed")" ]]; then hl_warn "Fehlgeschlagene Units: $failed"
    else rlog "   ok   keine failed units"; fi
    for u in $HEALTH_UNITS; do
      unit_exists "$u.service" || continue
      if unit_active "$u.service"; then rlog "   ok   $u laeuft"
      else hl_warn "$u laeuft NICHT ($(unit_state "$u.service"))"; fi
    done
    rlog ""
  fi

  # --- Zertifikate --------------------------------------------------------
  if [[ -n "${HEALTH_CERT_DOMAINS:-}" ]] && have openssl; then
    rlog "== Zertifikate =="
    local d end days now
    now="$(date +%s)"
    for d in $HEALTH_CERT_DOMAINS; do
      end="$(echo | openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null \
              | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
      if [[ -z "$end" ]]; then rlog "   ?    $d (nicht erreichbar)"; continue; fi
      days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo "$now") - now ) / 86400 ))
      if [[ $days -lt 14 ]]; then hl_warn "Zertifikat $d laeuft in $days Tagen ab"
      else rlog "   ok   $d ($days Tage)"; fi
    done
    rlog ""
  fi

  # --- Traffic ------------------------------------------------------------
  rlog "== Traffic (kumuliert seit Boot) =="
  if [[ -r /proc/net/dev ]]; then
    local l
    while read -r l; do rlog "$l"; done < <(
      awk 'NR>2{gsub(/:/,"",$1); if($1!="lo" && ($2>0||$10>0))
             printf "   %-10s rx=%.1fMiB tx=%.1fMiB\n",$1,$2/1048576,$10/1048576}' /proc/net/dev)
  fi
  rlog ""
  rlog "Ergebnis: $HL_WARN Warnung(en)."
  [[ $_e -eq 1 ]] && set -e
  return 0
}

hl_check() { report_init; _health_scan; }

hl_install() {
  local cf logf; cf="$(conf_file health)"; conf_load "$cf"
  echo
  echo "Regelmaessigen Health-Check einrichten."
  echo
  ask DISK_WARN     "Disk-Warnschwelle in %"                     "${DISK_WARN:-85}"
  ask USAGE_WARN    "Auslastungs-Schwelle in % (CPU und RAM)"    "${USAGE_WARN:-85}"
  ask USAGE_SAMPLES "RAM-Messungen fuer den Mittelwert (je 2 s)" "${USAGE_SAMPLES:-3}"
  ask HEALTH_UNITS "Dienste, die laufen muessen (Leerzeichen)"  "${HEALTH_UNITS:-caddy fail2ban}"
  ask HEALTH_CERT_DOMAINS "Zertifikate pruefen fuer (Domains, leer = aus)" "${HEALTH_CERT_DOMAINS:-}"
  ask_choice HEALTH_MODE "E-Mail-Report" "${HEALTH_MODE:-warn}" always warn never
  ask HEALTH_SCHED "Cron-Zeitplan" "${HEALTH_SCHED:-0 7 * * *}"

  conf_save "$cf" DISK_WARN USAGE_WARN USAGE_SAMPLES HEALTH_UNITS HEALTH_CERT_DOMAINS \
                  HEALTH_MODE HEALTH_SCHED || return 1
  logf="$(log_prepare "$HL_JOB")"
  cron_install "$HL_JOB" "$HEALTH_SCHED" "$SETUP_SH health run >> $logf 2>&1" root || return 1

  if mailer_ready; then log "Mailer erkannt: Reports gehen raus (Modus: $HEALTH_MODE)."
  else warn "Kein Mailer - Reports nur im Log. Optional: ./setup.sh smtp install"; fi
  log "Testlauf: ./setup.sh health check"
}

hl_status() {
  echo "== Cron =="
  cron_show "$HL_JOB"
  echo; echo "== Konfiguration =="
  conf_show "$(conf_file health)"
  echo; echo "== Letzter Lauf =="
  log_tail "$HL_JOB" 25
}

hl_remove() {
  confirm "Health-Check entfernen (Cron-Eintrag loeschen)?" Y || { echo "Abbruch."; return 0; }
  cron_remove "$HL_JOB"
  if confirm "Auch die Konfiguration loeschen?"; then conf_remove "$(conf_file health)"; fi
}

# --- Cron-Runner -----------------------------------------------------------
hl_run() {
  local _e=0; case $- in *e*) _e=1;; esac; set +e
  conf_load "$(conf_file health)"
  : "${HEALTH_MODE:=warn}"
  report_init
  _health_scan
  local HOST subj rc=0
  HOST="$(hostname 2>/dev/null || echo host)"
  subj="$APP_NAME Health OK: $HOST"
  [[ $HL_WARN -gt 0 ]] && subj="$APP_NAME Health WARN ($HL_WARN): $HOST"
  report_send "$HEALTH_MODE" "$subj"
  [[ $HL_WARN -gt 0 ]] && rc=1
  [[ $_e -eq 1 ]] && set -e
  return $rc
}
