#!/usr/bin/env bash
# lib/report.sh - Report sammeln (Log + Datei) und optional per Mail schicken.
# Genutzt von updates/health/backup-Runnern. Braucht lib/mail.sh (notify).

REPORT_FILE=""; REPORT_CHANGED=0; REPORT_ERRORS=0

report_init() { REPORT_FILE="$(mktemp)"; REPORT_CHANGED=0; REPORT_ERRORS=0
  trap 'rm -f "$REPORT_FILE"' EXIT; }

rlog()  { printf '%s\n' "$*" | tee -a "$REPORT_FILE"; }          # auf Konsole + Report
radd()  { [[ -n "${1:-}" ]] && printf '%s\n' "$1" >> "$REPORT_FILE"; }  # nur Report
rchanged() { REPORT_CHANGED=1; }
rerror()   { REPORT_ERRORS=$((REPORT_ERRORS+1)); rlog ">> FEHLER: $*"; }

# rcapture "Label" cmd...  -> fuehrt aus, haengt Ausgabe an Report, zaehlt Fehler.
# Das '|| rc=$?' macht die Zuweisung set -e-sicher (Runner sollen nicht abbrechen).
rcapture() { local label="$1"; shift; local out rc=0
  out="$("$@" 2>&1)" || rc=$?; radd "$out"
  [[ $rc -ne 0 ]] && rerror "$label (rc=$rc)"; return 0; }

# report_send MODE SUBJECT   (MODE: always|changes|never)
report_send() {
  local mode="$1" subj="$2"
  case "$mode" in
    never)  return 0 ;;
    always) ;;
    *)      [[ $REPORT_CHANGED -eq 1 || $REPORT_ERRORS -gt 0 ]] || return 0 ;;
  esac
  notify "$subj" < "$REPORT_FILE"
}
