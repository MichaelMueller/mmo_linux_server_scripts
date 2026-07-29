#!/usr/bin/env bash
# lib/report.sh - Report sammeln (Konsole + Datei) und optional per Mail schicken.
# Genutzt von den Cron-Runnern in updates/health.

REPORT_FILE=""; REPORT_CHANGED=0; REPORT_ERRORS=0; _REPORT_TRAP=0

report_init() {
  [[ -n "$REPORT_FILE" ]] && rm -f "$REPORT_FILE"
  REPORT_FILE="$(mktemp)"; REPORT_CHANGED=0; REPORT_ERRORS=0
  # Genau EIN EXIT-Trap, sonst haengt bei mehreren Laeufen pro Sitzung (Menue!)
  # jedes Mal eine Tempdatei ohne Aufraeumen herum.
  if [[ $_REPORT_TRAP -eq 0 ]]; then
    trap 'rm -f "${REPORT_FILE:-}"' EXIT
    _REPORT_TRAP=1
  fi
}

rlog() { printf '%s\n' "$*" | tee -a "$REPORT_FILE"; }            # Konsole + Report
radd() { [[ -n "${1:-}" ]] && printf '%s\n' "$1" >> "$REPORT_FILE"; return 0; }
rchanged() { REPORT_CHANGED=1; }
rerror()   { REPORT_ERRORS=$((REPORT_ERRORS+1)); rlog "!! FEHLER: $*"; }

# rcapture "Label" kommando...  -> ausfuehren, Ausgabe in den Report, Fehler zaehlen.
# '|| rc=$?' macht die Zuweisung set -e-sicher: ein Runner soll weiterlaufen.
rcapture() {
  local label="$1"; shift; local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  radd "$out"
  [[ $rc -ne 0 ]] && rerror "$label (rc=$rc)"
  return 0
}

# report_send MODUS "Betreff"
#   always  -> immer mailen
#   changes -> nur bei Aenderung oder Fehler   (health nutzt dafuer 'warn')
#   warn    -> Alias fuer changes
#   never   -> nie mailen
report_send() {
  local mode="$1" subj="$2"
  case "$mode" in
    never)  return 0 ;;
    always) ;;
    *)      [[ $REPORT_CHANGED -eq 1 || $REPORT_ERRORS -gt 0 ]] || return 0 ;;
  esac
  notify "$subj" < "$REPORT_FILE" || warn "Mailversand fehlgeschlagen (siehe smtp status)."
}
