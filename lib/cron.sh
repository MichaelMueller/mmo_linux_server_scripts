#!/usr/bin/env bash
# lib/cron.sh - Cron-Eintraege verwalten (getaggt via "# tag").

install_cron() { # install_cron "zeitplan" "kommando" "tag"
  local line="$1 $2 # $3"
  ( crontab -l 2>/dev/null | grep -v "# $3\$" || true; echo "$line" ) | crontab -
  log "Cron gesetzt: $line"; }

remove_cron() { # remove_cron "tag"
  ( crontab -l 2>/dev/null | grep -v "# $1\$" || true ) | crontab -; }

has_cron() { crontab -l 2>/dev/null | grep -q "# $1\$"; }
