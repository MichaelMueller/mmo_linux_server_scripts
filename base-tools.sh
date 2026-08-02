#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# base-tools.sh - Standardwerkzeuge und Shell-Komfort auf einem frischen Server
# Pakete (nano, vim, screen, ...) plus systemweite Voreinstellungen für
# Shell-Farben, Editoren und screen.
# Modi:  (ohne Argument) = interaktives Menü
#        --status        = Kurzstatus auf stdout
#        --uninstall     = Deinstallation
set -euo pipefail

# --version muss vor der root-Pruefung stehen, damit es ohne sudo antwortet.
# if-Form statt "[[ ]] &&": ein falsches && wuerde unter set -e beenden.
VERSION="1.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausführen (sudo)." >&2; exit 1; }

PROFILE_D=/etc/profile.d/zz-base-tools.sh
BASHRC=/etc/bash.bashrc
NANORC=/etc/nanorc
SCREENRC=/etc/screenrc
VIMRC=/etc/vim/vimrc.local

MARK_BEGIN='# >>> base-tools >>>'
MARK_END='# <<< base-tools <<<'

# Ohne diese geht auf einem Server nichts sinnvoll weiter - sie werden ohne
# Rückfrage installiert.
PKGS_ALWAYS=(git ca-certificates)

PKGS_EDITOR=(nano vim)
PKGS_SESSION=(screen tmux)
PKGS_TOOLS=(htop curl wget unzip rsync tree ncdu bash-completion)
PKGS_NET=(dnsutils net-tools mtr-tiny)

pause() { read -rp "Weiter mit Enter..." _; }

# confirm "Frage" [J]   -> Default J statt N
confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "J" ]]; then
        read -rp "$q [J/n]: " ans; ans=${ans:-J}
    else
        read -rp "$q [j/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[Jj]$ ]]
}

# make_backup <name> <pfad>...   -> /root/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nichts zu sichern)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup fehlgeschlagen - Abbruch, es wird nichts entfernt." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Markierte Blöcke in fremden Konfigurationsdateien
# ---------------------------------------------------------------------------
has_block() { grep -qF "$MARK_BEGIN" "$1" 2>/dev/null; }

remove_block() {
    local f=$1
    [[ -f "$f" ]] || return 0
    has_block "$f" || return 0
    sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$f"
}

# write_block <datei>   - Inhalt kommt von stdin
write_block() {
    local f=$1
    remove_block "$f"
    [[ -f "$f" ]] || touch "$f"
    { echo "$MARK_BEGIN"; cat; echo "$MARK_END"; } >> "$f"
}

is_setup() { [[ -f "$PROFILE_D" ]]; }

# ---------------------------------------------------------------------------
# Pakete
# ---------------------------------------------------------------------------
install_group() {
    local label=$1; shift
    local -a pkgs=("$@")
    local p
    echo
    echo "--- ${label}: ${pkgs[*]}"
    for p in "${pkgs[@]}"; do
        if dpkg -s "$p" &>/dev/null; then
            echo "    $p (bereits installiert)"
        elif DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1; then
            echo "    $p installiert"
        else
            echo "    !!! $p konnte nicht installiert werden (Paketname auf dieser Distribution unbekannt?)"
        fi
    done
}

install_packages() {
    echo ">>> Paketauswahl"
    echo
    echo "Immer installiert: ${PKGS_ALWAYS[*]}"
    echo
    local do_editor=0 do_session=0 do_tools=0 do_net=0
    if confirm "Editoren (${PKGS_EDITOR[*]})?"           J; then do_editor=1;  fi
    if confirm "Terminal-Sessions (${PKGS_SESSION[*]})?" J; then do_session=1; fi
    if confirm "Werkzeuge (${PKGS_TOOLS[*]})?"           J; then do_tools=1;   fi
    if confirm "Netzwerk-Diagnose (${PKGS_NET[*]})?"     N; then do_net=1;     fi

    echo
    echo ">>> Paketlisten werden aktualisiert..."
    apt-get update -qq || true

    install_group "Grundlage (immer)" "${PKGS_ALWAYS[@]}"

    (( do_editor  == 1 )) && install_group "Editoren"          "${PKGS_EDITOR[@]}"  || true
    (( do_session == 1 )) && install_group "Terminal-Sessions" "${PKGS_SESSION[@]}" || true
    (( do_tools   == 1 )) && install_group "Werkzeuge"         "${PKGS_TOOLS[@]}"   || true
    (( do_net     == 1 )) && install_group "Netzwerk-Diagnose" "${PKGS_NET[@]}"     || true

    echo
    echo ">>> Pakete fertig."
}

# ---------------------------------------------------------------------------
# Shell-, Editor- und screen-Voreinstellungen
# ---------------------------------------------------------------------------
write_shell_config() {
    # Eigene Datei, kein fremder Inhalt - wird komplett überschrieben.
    cat > "$PROFILE_D" <<'EOF'
# Farbige Shell und Komfort - erzeugt von base-tools.sh
# Wird sowohl von Login-Shells (/etc/profile) als auch über /etc/bash.bashrc
# von interaktiven Nicht-Login-Shells geladen.

case $- in *i*) ;; *) return 0 ;; esac
[ -z "${BASH_VERSION:-}" ] && return 0

if command -v dircolors >/dev/null 2>&1; then
    if [ -r "$HOME/.dircolors" ]; then
        eval "$(dircolors -b "$HOME/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi

alias ls='ls --color=auto'
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias df='df -h'
alias du='du -h'
alias ..='cd ..'

export LESS='-R'
export HISTSIZE=5000
export HISTFILESIZE=10000
export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT='%F %T  '
shopt -s histappend checkwinsize 2>/dev/null

# Prompt: root rot, normaler Benutzer grün, Pfad blau
if [ "$(id -u)" -eq 0 ]; then
    PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
else
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
fi
EOF
    chmod 644 "$PROFILE_D"

    # /etc/profile.d wird nur von Login-Shells gelesen. Damit 'ssh host cmd',
    # 'su' und screen dieselben Einstellungen bekommen, hier nachziehen.
    write_block "$BASHRC" <<EOF
[ -r ${PROFILE_D} ] && . ${PROFILE_D}
EOF
    echo "    ${PROFILE_D} geschrieben, ${BASHRC} verweist darauf"
}

write_vim_config() {
    mkdir -p "$(dirname "$VIMRC")"
    if [[ -f "$VIMRC" ]] && ! head -1 "$VIMRC" | grep -q 'base-tools'; then
        cp "$VIMRC" "$VIMRC.orig"
        echo "    vorhandene $VIMRC nach $VIMRC.orig gesichert"
    fi
    cat > "$VIMRC" <<'EOF'
" erzeugt von base-tools.sh
syntax on
set number
set ruler
set hlsearch
set incsearch
set ignorecase
set smartcase
set tabstop=4
set shiftwidth=4
set expandtab
set background=dark
set encoding=utf-8
" Maus aus: sonst schaltet vim beim Markieren in den Visual-Modus und
" das Kopieren aus dem Terminal funktioniert nicht mehr.
set mouse=
EOF
    chmod 644 "$VIMRC"
    echo "    $VIMRC geschrieben"
}

write_nano_config() {
    local inc=""
    [[ -d /usr/share/nano ]] && inc='include "/usr/share/nano/*.nanorc"' || true
    write_block "$NANORC" <<EOF
set linenumbers
set tabsize 4
set tabstospaces
set constantshow
set softwrap
${inc}
EOF
    echo "    Block in $NANORC gesetzt"
}

write_screen_config() {
    write_block "$SCREENRC" <<'EOF'
startup_message off
defscrollback 10000
altscreen on
hardstatus alwayslastline "%{= kG}[%H]%{= kw} %-w%{= KW}%n %t%{-}%+w %=%{= kG}%c  %Y-%m-%d"
EOF
    echo "    Block in $SCREENRC gesetzt"
}

write_configs() {
    echo ">>> Voreinstellungen"
    write_shell_config
    write_vim_config
    write_nano_config
    write_screen_config
    echo
    echo "Wirksam in jeder neuen Sitzung. Für die laufende Shell:"
    echo "    . ${PROFILE_D}"
}

setup_all() {
    install_packages
    echo
    write_configs
    echo
    pause
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
pkg_state() {
    local p
    for p in "$@"; do
        if dpkg -s "$p" &>/dev/null; then
            printf '  [x] %s\n' "$p"
        else
            printf '  [ ] %s\n' "$p"
        fi
    done
}

show_status() {
    echo "--- Pakete ---"
    pkg_state "${PKGS_ALWAYS[@]}" "${PKGS_EDITOR[@]}" "${PKGS_SESSION[@]}" \
              "${PKGS_TOOLS[@]}" "${PKGS_NET[@]}"
    echo
    echo "--- Voreinstellungen ---"
    printf '  [%s] %s\n' "$([[ -f "$PROFILE_D" ]] && echo x || echo ' ')" "$PROFILE_D"
    printf '  [%s] %s (Verweis auf die Shell-Konfiguration)\n' "$(has_block "$BASHRC" && echo x || echo ' ')" "$BASHRC"
    printf '  [%s] %s\n' "$([[ -f "$VIMRC" ]] && echo x || echo ' ')" "$VIMRC"
    printf '  [%s] %s\n' "$(has_block "$NANORC" && echo x || echo ' ')" "$NANORC"
    printf '  [%s] %s\n' "$(has_block "$SCREENRC" && echo x || echo ' ')" "$SCREENRC"
}

# ---------------------------------------------------------------------------
# Deinstallation
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Deinstallation base-tools"
    echo
    # Eine handgeschriebene vimrc.local, die nicht von hier stammt, bleibt liegen.
    local vim_ours=0 vimnote=""
    if [[ -f "$VIMRC.orig" ]]; then
        vim_ours=1; vimnote=" (vorherige Fassung wird zurückgeholt)"
    elif [[ -f "$VIMRC" ]] && head -1 "$VIMRC" | grep -q 'base-tools'; then
        vim_ours=1
    fi

    echo "Folgendes wird entfernt:"
    [[ -f "$PROFILE_D" ]] && echo "  - $PROFILE_D"                     || true
    has_block "$BASHRC"   && echo "  - markierter Block in $BASHRC"    || true
    (( vim_ours == 1 ))   && echo "  - ${VIMRC}${vimnote}"             || true
    has_block "$NANORC"   && echo "  - markierter Block in $NANORC"    || true
    has_block "$SCREENRC" && echo "  - markierter Block in $SCREENRC"  || true
    echo
    echo "Die installierten Pakete bleiben - einem Server nano und vim wegzunehmen"
    echo "richtet mehr Schaden an als es aufräumt. Falls doch gewünscht:"
    echo "    apt purge ${PKGS_EDITOR[*]} ${PKGS_SESSION[*]} ${PKGS_TOOLS[*]} ${PKGS_NET[*]}"
    echo "  (git und ca-certificates stehen bewusst nicht in dieser Zeile)"
    echo

    confirm "Wirklich entfernen?" || { echo "Abgebrochen."; pause; return; }

    make_backup base-tools "$PROFILE_D" "$BASHRC" "$VIMRC" "$NANORC" "$SCREENRC" || { pause; return; }

    rm -f "$PROFILE_D"
    remove_block "$BASHRC"
    # nanorc und screenrc hat es vorher eventuell gar nicht gegeben - dann bleibt
    # nach dem Entfernen eine leere Datei zurück, die auch weg kann.
    remove_block "$NANORC";   [[ -s "$NANORC" ]]   || rm -f "$NANORC"
    remove_block "$SCREENRC"; [[ -s "$SCREENRC" ]] || rm -f "$SCREENRC"

    if [[ -f "$VIMRC.orig" ]]; then
        mv "$VIMRC.orig" "$VIMRC"
        echo "$VIMRC aus $VIMRC.orig wiederhergestellt."
    elif (( vim_ours == 1 )); then
        rm -f "$VIMRC"
    fi

    echo
    echo "Entfernt. Neue Sitzungen bekommen wieder die Standard-Shell."
    pause
}

# ---------------------------------------------------------------------------
# Menü
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        echo "==========================================="
        echo " Basis-Werkzeuge und Shell-Komfort"
        echo "==========================================="
        if is_setup; then
            echo "Status: eingerichtet"
        else
            echo "Status: nicht eingerichtet"
        fi
        echo
        echo "1) Alles einrichten (Pakete + Voreinstellungen)"
        echo "2) Nur Pakete installieren"
        echo "3) Nur Voreinstellungen schreiben (Shell, vim, nano, screen)"
        echo "4) Status anzeigen"
        echo "5) Deinstallieren"
        echo "6) Beenden"
        read -rp "Auswahl: " CH
        case "$CH" in
            1) setup_all ;;
            2) install_packages; pause ;;
            3) write_configs; pause ;;
            4) show_status; pause ;;
            5) uninstall ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Verwendung: $0 [--status|--uninstall|--version]"; exit 1 ;;
esac
