#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# base-tools.sh - standard tools and shell comfort on a fresh server
# Packages (nano, vim, screen, ...), system-wide defaults for shell colours,
# editors and screen, and the system basics: time synchronisation (NTP) and
# timezone, locale (UTF-8), conservative kernel hardening (sysctl), swap on
# small machines.
# Modes: (no argument) = interactive menu
#        --status      = short status on stdout
#        --setup       = set up everything once, without the menu
#        --time        = only time synchronisation and timezone
#        --locale      = only the locale
#        --sysctl      = only the kernel hardening
#        --swap        = only the swap file
#        --uninstall   = uninstall
# Presets from a caller: a DEFAULT_* that is set (not empty) is taken without
# a question and printed with "(preset)"; an invalid one is an error and
# nothing is written. Unset ones are asked (batch mode: built-in default).
#   DEFAULT_PKG_EDITORS, DEFAULT_PKG_SESSIONS, DEFAULT_PKG_TOOLS,
#   DEFAULT_PKG_NET (Y|N, default Y)             package groups
#   DEFAULT_TIME_SETUP (Y|N, default Y)          set up time sync and timezone
#   DEFAULT_TIMEZONE (default: the current one), DEFAULT_NTP_SERVERS (default:
#   the distribution's pool)
#   DEFAULT_LOCALE_SETUP (Y|N, default Y)        set the locale
#   DEFAULT_LANG (default C.UTF-8), DEFAULT_LOCALES (default
#   "de_DE.UTF-8 en_US.UTF-8", '-' = none)
#   DEFAULT_SYSCTL (Y|N, default Y)              kernel hardening
#   DEFAULT_SWAP (auto|no|<MB>, default auto)    swap file (auto: the RAM
#   decides whether and how large)
# Yes/no values: Y, yes, j, ja, 1, true / N, no, nein, 0, false.
# Batch mode: BATCH=1 asks nothing - every question takes its default and
# prints what it took; an invalid default is an error (exit code non-zero).
set -euo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

PROFILE_D=/etc/profile.d/zz-base-tools.sh
BASHRC=/etc/bash.bashrc
NANORC=/etc/nanorc
SCREENRC=/etc/screenrc
VIMRC=/etc/vim/vimrc.local

MARK_BEGIN='# >>> base-tools >>>'
MARK_END='# <<< base-tools <<<'

# Nothing useful happens on a server without these - they are installed
# without asking.
PKGS_ALWAYS=(git ca-certificates)

PKGS_EDITOR=(nano vim)
PKGS_SESSION=(screen tmux)
PKGS_TOOLS=(htop curl wget unzip rsync tree ncdu bash-completion)
PKGS_NET=(dnsutils net-tools mtr-tiny)

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# Presets: a DEFAULT_* that is set (not empty) is a fixed value - its
# question is not asked, neither interactively nor in batch mode; the tool
# prints "<question>: <value> (preset)" instead. Unset ones are asked.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# without a preset takes its built-in default and prints what it took. A
# required value without a default is an error.

# preset NAME -> 0 when the caller set that DEFAULT_* (non-empty)
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# yn_value VALUE -> Y or N; failure for anything that is not yes/no
yn_value() {
    local v=${1:-}
    case "${v,,}" in
        y|yes|j|ja|1|true)  echo Y ;;
        n|no|nein|0|false)  echo N ;;
        *) return 1 ;;
    esac
}
# yn VALUE [Y|N]  - a yes/no value as Y or N; empty takes the built-in
# default given second, anything unknown counts as N.
yn() { yn_value "${1:-${2:-N}}" || echo N; }

# confirm "Question" [default Y|N] [DEFAULT_NAME]
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (preset ${pre})" >&2; exit 1; }
        echo "$q -> $( [[ "$def" == Y ]] && echo yes || echo no) (preset)"
        [[ "$def" == Y ]]; return
    fi
    if [[ -n "${BATCH:-}" ]]; then
        echo "$q -> $( [[ "$def" =~ ^[YyJj]$ ]] && echo yes || echo no)"
        [[ "$def" =~ ^[YyJj]$ ]]; return
    fi
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}
# ask VAR "Question" [default] [required] [DEFAULT_NAME]  - the answer lands in VAR
ask() {
    local __v=$1 __q=$2 __d=${3:-} __r=${4:-} __p=${5:-} __a
    if preset "$__p"; then
        printf -v "$__v" '%s' "${!__p}"; echo "${__q}: ${!__p} (preset)"; return 0
    fi
    if [[ -n "${BATCH:-}" ]]; then
        if [[ -z "$__d" && -n "$__r" ]]; then echo "!!! ${__q}: no value given (batch mode)" >&2; return 1; fi
        printf -v "$__v" '%s' "$__d"; echo "${__q}: ${__d:--}"; return 0
    fi
    while true; do
        read -rp "${__q}${__d:+ [${__d}]}: " __a || return 1
        __a=${__a:-$__d}
        [[ -n "$__a" || -z "$__r" ]] && break
        echo "  -> required"
    done
    printf -v "$__v" '%s' "$__a"
}

# A UTF-8 locale name such as en_US.UTF-8 or C.UTF-8.
valid_locale() { [[ "$1" =~ ^[A-Za-z]+(_[A-Za-z]+)?\.[Uu][Tt][Ff]-?8(@[A-Za-z]+)?$ ]]; }

# Every preset is checked before anything is written: a bad value further down
# must not leave a half-done setup behind.
validate_presets() {
    local n l bad=0
    for n in DEFAULT_PKG_EDITORS DEFAULT_PKG_SESSIONS DEFAULT_PKG_TOOLS DEFAULT_PKG_NET \
             DEFAULT_TIME_SETUP DEFAULT_LOCALE_SETUP DEFAULT_SYSCTL; do
        if preset "$n" && ! yn_value "${!n}" >/dev/null; then
            echo "!!! ${n}='${!n}' - allowed: yes or no." >&2; bad=1
        fi
    done
    if preset DEFAULT_TIMEZONE && [[ "$DEFAULT_TIMEZONE" == *..* || ! -f "/usr/share/zoneinfo/${DEFAULT_TIMEZONE}" ]]; then
        echo "!!! DEFAULT_TIMEZONE='${DEFAULT_TIMEZONE}' - unknown timezone (e.g. Europe/Berlin, UTC)." >&2; bad=1
    fi
    if preset DEFAULT_LANG && ! valid_locale "$DEFAULT_LANG"; then
        echo "!!! DEFAULT_LANG='${DEFAULT_LANG}' - not a UTF-8 locale (e.g. en_US.UTF-8)." >&2; bad=1
    fi
    if preset DEFAULT_LOCALES && [[ "$DEFAULT_LOCALES" != "-" ]]; then
        for l in $DEFAULT_LOCALES; do
            valid_locale "$l" || { echo "!!! DEFAULT_LOCALES: '${l}' - not a UTF-8 locale (e.g. de_DE.UTF-8; '-' = none)." >&2; bad=1; }
        done
    fi
    if preset DEFAULT_SWAP && [[ ! "$DEFAULT_SWAP" =~ ^(auto|no|[1-9][0-9]*)$ ]]; then
        echo "!!! DEFAULT_SWAP='${DEFAULT_SWAP}' - allowed: auto, no or a size in MB." >&2; bad=1
    fi
    (( bad == 0 )) || exit 1
}

# make_backup <name> <path>...   -> /root/<name>-uninstall-<ts>.tar.gz
make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then
        echo "(nothing to back up)"
        return 0
    fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"
        echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Marked blocks in files owned by someone else
# ---------------------------------------------------------------------------
has_block() { grep -qF "$MARK_BEGIN" "$1" 2>/dev/null; }

remove_block() {
    local f=$1
    [[ -f "$f" ]] || return 0
    has_block "$f" || return 0
    sed -i "\|^${MARK_BEGIN}\$|,\|^${MARK_END}\$|d" "$f"
}

# write_block <file>   - content comes from stdin
write_block() {
    local f=$1
    remove_block "$f"
    [[ -f "$f" ]] || touch "$f"
    { echo "$MARK_BEGIN"; cat; echo "$MARK_END"; } >> "$f"
}

is_setup() { [[ -f "$PROFILE_D" ]]; }

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
install_group() {
    local label=$1; shift
    local -a pkgs=("$@")
    local p
    echo
    echo "--- ${label}: ${pkgs[*]}"
    for p in "${pkgs[@]}"; do
        if dpkg -s "$p" &>/dev/null; then
            echo "    $p (already installed)"
        elif DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null "$p" >/dev/null 2>&1; then
            echo "    $p installed"
        else
            echo "    !!! $p could not be installed (package name unknown on this distribution?)"
        fi
    done
}

install_packages() {
    echo ">>> Package selection"
    echo
    echo "Always installed: ${PKGS_ALWAYS[*]}"
    echo
    local do_editor=0 do_session=0 do_tools=0 do_net=0
    if confirm "Editors (${PKGS_EDITOR[*]})?"             "$(yn "${DEFAULT_PKG_EDITORS:-}"  Y)" DEFAULT_PKG_EDITORS;  then do_editor=1;  fi
    if confirm "Terminal sessions (${PKGS_SESSION[*]})?"  "$(yn "${DEFAULT_PKG_SESSIONS:-}" Y)" DEFAULT_PKG_SESSIONS; then do_session=1; fi
    if confirm "Tools (${PKGS_TOOLS[*]})?"                "$(yn "${DEFAULT_PKG_TOOLS:-}"    Y)" DEFAULT_PKG_TOOLS;    then do_tools=1;   fi
    if confirm "Network diagnostics (${PKGS_NET[*]})?"    "$(yn "${DEFAULT_PKG_NET:-}"      Y)" DEFAULT_PKG_NET;      then do_net=1;     fi

    echo
    echo ">>> Updating package lists..."
    apt-get update -qq || true

    install_group "Base (always)" "${PKGS_ALWAYS[@]}"

    (( do_editor  == 1 )) && install_group "Editors"             "${PKGS_EDITOR[@]}"  || true
    (( do_session == 1 )) && install_group "Terminal sessions"   "${PKGS_SESSION[@]}" || true
    (( do_tools   == 1 )) && install_group "Tools"               "${PKGS_TOOLS[@]}"   || true
    (( do_net     == 1 )) && install_group "Network diagnostics" "${PKGS_NET[@]}"     || true

    echo
    echo ">>> Packages done."
}

# ---------------------------------------------------------------------------
# Shell, editor and screen defaults
# ---------------------------------------------------------------------------
write_shell_config() {
    # Our own file, no foreign content - it is overwritten completely.
    cat > "$PROFILE_D" <<'EOF'
# Coloured shell and comfort - generated by base-tools.sh
# Loaded by login shells (/etc/profile) and, via /etc/bash.bashrc, by
# interactive non-login shells as well.

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
export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT='%F %T  '
shopt -s histappend checkwinsize 2>/dev/null

# Everything Debian's own ~/.bashrc also sets lives in here, because of the
# order things are read in:
#
#   login shell:        /etc/profile -> /etc/profile.d/*  -> ~/.profile -> ~/.bashrc
#   interactive shell:  /etc/bash.bashrc                  -> ~/.bashrc
#
# ~/.bashrc comes last in both cases, and the stock Debian/Ubuntu one sets PS1,
# HISTSIZE and the ll/la/l aliases itself - for root as well. A PS1 assigned
# here is therefore overwritten a moment later, which is why the coloured
# prompt was invisible for everyone who still has the distribution's file,
# which is everyone.
#
# Hence: apply them once more from PROMPT_COMMAND. That runs just before the
# first prompt is drawn, when every rc file has had its say. The hook then
# removes itself, so setting PS1 by hand afterwards keeps working.
_bt_apply() {
    # Prompt: root red, normal user green, path blue
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
    else
        PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
    fi
    HISTSIZE=5000
    HISTFILESIZE=10000
    alias ll='ls -alFh'
    alias la='ls -A'
    alias l='ls -CF'
}

_bt_first_prompt() {
    _bt_apply
    PROMPT_COMMAND="${PROMPT_COMMAND//_bt_first_prompt;/}"
    PROMPT_COMMAND="${PROMPT_COMMAND//_bt_first_prompt/}"
    unset -f _bt_first_prompt
}

# Once now, so a shell that reads no ~/.bashrc at all is covered too.
_bt_apply

case "${PROMPT_COMMAND:-}" in
    *_bt_first_prompt*) ;;
    "")  PROMPT_COMMAND='_bt_first_prompt' ;;
    *)   PROMPT_COMMAND="_bt_first_prompt;${PROMPT_COMMAND}" ;;
esac
EOF
    chmod 644 "$PROFILE_D"

    # /etc/profile.d is only read by login shells. So that 'ssh host cmd',
    # 'su' and screen get the same settings, pull it in here as well.
    write_block "$BASHRC" <<EOF
[ -r ${PROFILE_D} ] && . ${PROFILE_D}
EOF
    echo "    ${PROFILE_D} written, ${BASHRC} points at it"
}

write_vim_config() {
    mkdir -p "$(dirname "$VIMRC")"
    if [[ -f "$VIMRC" ]] && ! head -1 "$VIMRC" | grep -q 'base-tools'; then
        cp "$VIMRC" "$VIMRC.orig"
        echo "    existing $VIMRC backed up to $VIMRC.orig"
    fi
    cat > "$VIMRC" <<'EOF'
" generated by base-tools.sh
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
" Mouse off: otherwise vim switches to visual mode on selection and copying
" out of the terminal stops working.
set mouse=
EOF
    chmod 644 "$VIMRC"
    echo "    $VIMRC written"
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
    echo "    block placed in $NANORC"
}

write_screen_config() {
    write_block "$SCREENRC" <<'EOF'
startup_message off
defscrollback 10000
altscreen on
hardstatus alwayslastline "%{= kG}[%H]%{= kw} %-w%{= KW}%n %t%{-}%+w %=%{= kG}%c  %Y-%m-%d"
EOF
    echo "    block placed in $SCREENRC"
}

write_configs() {
    echo ">>> Defaults"
    write_shell_config
    write_vim_config
    write_nano_config
    write_screen_config
    echo
    echo "In effect in every new session. For the current shell:"
    echo "    . ${PROFILE_D}"
}

# ---------------------------------------------------------------------------
# Time: synchronisation and timezone
# ---------------------------------------------------------------------------
# Without a synchronised clock, TLS certificates fail, logs from different
# machines cannot be put side by side, TOTP codes are rejected and cron jobs
# drift. The timezone decides when "03:00" in a cron job is.
TIMESYNC_DROPIN=/etc/systemd/timesyncd.conf.d/50-base-tools.conf

in_container() {
    local v; v=$(systemd-detect-virt --container 2>/dev/null || true)
    [[ -n "$v" && "$v" != none ]]
}

time_synced() { [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; }

# The service that keeps the clock, if any.
time_service() {
    local s
    for s in chrony chronyd ntpsec ntp systemd-timesyncd; do
        systemctl is-active --quiet "$s" 2>/dev/null && { echo "$s"; return 0; }
    done
    return 0
}

time_status() {
    local tz svc
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "?")
    svc=$(time_service)
    if in_container; then
        echo "  time: from the host (container), timezone ${tz}"
    else
        echo "  time: ${svc:-NO sync service}, $(time_synced && echo synchronised || echo "NOT synchronised"), timezone ${tz}"
    fi
}

setup_time() {
    echo "--- Time: synchronisation and timezone ---"
    echo "Now: $(date '+%F %T %Z'), synchronised: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
    confirm "Set up time sync and timezone? (No: leave it as it is)" "$(yn "${DEFAULT_TIME_SETUP:-}" Y)" DEFAULT_TIME_SETUP \
        || { echo "Left as it is."; return 0; }
    if in_container; then
        echo "A container gets its clock from the host - nothing to synchronise here."
    else
        local svc; svc=$(time_service)
        if [[ -n "$svc" && "$svc" != systemd-timesyncd ]]; then
            echo "Time is kept by ${svc} - left as it is."
        else
            if ! dpkg -s systemd-timesyncd &>/dev/null; then
                echo ">>> Installing systemd-timesyncd..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null systemd-timesyncd >/dev/null 2>&1 \
                    || echo "!!! systemd-timesyncd could not be installed."
            fi
            # Own NTP servers only when a caller hands them in; otherwise the
            # distribution's pool (debian.pool.ntp.org / ntp.ubuntu.com).
            if [[ -n "${DEFAULT_NTP_SERVERS:-}" ]]; then
                mkdir -p "$(dirname "$TIMESYNC_DROPIN")"
                printf '%s\n' "# written by base-tools.sh" "[Time]" "NTP=${DEFAULT_NTP_SERVERS}" > "$TIMESYNC_DROPIN"
                echo "NTP servers: ${DEFAULT_NTP_SERVERS}"
            fi
            systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
            systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
            timedatectl set-ntp true >/dev/null 2>&1 || true
        fi

        for _ in $(seq 1 15); do time_synced && break; sleep 2; done
        if time_synced; then
            echo "Clock synchronised ($(time_service))."
        else
            echo "!!! The clock is not synchronised (yet). Outgoing NTP (123/udp) blocked?"
            echo "!!! Check: timedatectl timesync-status"
        fi
    fi

    echo
    local cur def tz
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
    def=${DEFAULT_TIMEZONE:-$cur}
    echo "Timezone: it decides when '03:00' in a cron job is (update windows, reboot"
    echo "window, reports). Current: ${cur}"
    ask tz "Timezone (e.g. Europe/Berlin, UTC)" "$def" "" DEFAULT_TIMEZONE || return 1
    if { [[ -n "${BATCH:-}" ]] || preset DEFAULT_TIMEZONE; } && [[ ! -e "/usr/share/zoneinfo/${tz}" ]]; then
        echo "!!! Unknown timezone '${tz}' (DEFAULT_TIMEZONE) - left at ${cur}." >&2
        return 1
    fi
    if [[ "$tz" != "$cur" ]]; then
        if [[ -e "/usr/share/zoneinfo/${tz}" ]]; then
            timedatectl set-timezone "$tz" 2>/dev/null || ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
            echo "$tz" > /etc/timezone 2>/dev/null || true
            # cron reads the timezone when it starts.
            systemctl restart cron >/dev/null 2>&1 || true
            echo "Timezone set: ${tz} (now $(date '+%F %T %Z'))."
        else
            echo "!!! Unknown timezone '${tz}' - left at ${cur}."
        fi
    else
        echo "Timezone stays ${cur} (now $(date '+%F %T %Z'))."
    fi
}

# ---------------------------------------------------------------------------
# Locale
# ---------------------------------------------------------------------------
# UTF-8 is what matters: with the plain POSIX/C locale, umlauts in file names,
# logs and scripts are mangled. C.UTF-8 is built into glibc (nothing to
# generate), English messages, UTF-8. Further locales such as de_DE.UTF-8 and
# en_US.UTF-8 are generated because SSH clients send their own LANG/LC_* -
# without them perl, apt and others warn "Setting locale failed" at every call.
locale_gen_one() {
    local l=$1
    if [[ -f /etc/locale.gen ]] && grep -qE "^#?[[:space:]]*${l//./\\.}[[:space:]]+UTF-8" /etc/locale.gen; then
        sed -i -E "s/^#[[:space:]]*(${l//./\\.}[[:space:]]+UTF-8)/\1/" /etc/locale.gen
    elif [[ -f /etc/locale.gen ]]; then
        echo "${l} UTF-8" >> /etc/locale.gen
    fi
}

locale_status() {
    local lang; lang=$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' || true)
    echo "  locale: LANG=${lang:-unset}, available: $(locale -a 2>/dev/null | grep -iE 'utf-?8' | grep -v '^C\.' | tr '\n' ' ' || true)"
}

setup_locale() {
    echo "--- Locale ---"
    locale_status
    confirm "Set the locale? (No: leave it as it is)" "$(yn "${DEFAULT_LOCALE_SETUP:-}" Y)" DEFAULT_LOCALE_SETUP \
        || { echo "Left as it is."; return 0; }
    local lang=${DEFAULT_LANG:-C.UTF-8} extra=${DEFAULT_LOCALES:-de_DE.UTF-8 en_US.UTF-8} r
    echo "System language (messages, logs): C.UTF-8 is recommended - built in,"
    echo "English, UTF-8. Further locales are only made available - for what SSH"
    echo "clients send (LANG/LC_*) and for applications that choose them."
    ask lang "System locale (LANG)" "$lang" "" DEFAULT_LANG || return 1
    ask r "Further locales to generate (space-separated, '-' = none)" "$extra" "" DEFAULT_LOCALES || return 1
    [[ "$r" == "-" ]] && extra="" || extra=$r
    if ! dpkg -s locales &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null locales >/dev/null 2>&1 \
            || { echo "!!! The package 'locales' could not be installed."; return 0; }
    fi
    local l
    # C.UTF-8 / POSIX are built in - nothing to generate
    for l in $lang $extra; do [[ "$l" =~ ^(C|POSIX)(\.|$) ]] || locale_gen_one "$l"; done
    if [[ -f /etc/locale.gen ]]; then
        locale-gen >/dev/null 2>&1 || echo "!!! locale-gen failed."
    else
        # Ubuntu without /etc/locale.gen: locale-gen takes the names directly
        # shellcheck disable=SC2086,SC2046
        locale-gen $(for l in $lang $extra; do [[ "$l" =~ ^(C|POSIX)(\.|$) ]] || echo "$l"; done) >/dev/null 2>&1 \
            || echo "!!! locale-gen failed."
    fi
    update-locale LANG="$lang" >/dev/null 2>&1 || echo "LANG=${lang}" > /etc/default/locale
    echo "LANG=${lang}; available: $(locale -a 2>/dev/null | grep -iE 'utf-?8' | grep -v '^C\.' | tr '\n' ' ')"
    echo "(takes effect for new logins)"
}

# ---------------------------------------------------------------------------
# Kernel hardening (sysctl)
# ---------------------------------------------------------------------------
# Conservative values that break nothing on a server with Docker or Tailscale:
# forwarding is NOT touched (Docker, Tailscale need it), and the reverse-path
# filter is "loose" (2) - "strict" (1) breaks Tailscale's routing.
SYSCTL_FILE=/etc/sysctl.d/90-base-tools-hardening.conf

write_sysctl() {
    cat > "$SYSCTL_FILE" <<'EOF'
# written by base-tools.sh - conservative hardening, forwarding untouched
# kernel: no addresses and no kernel log for ordinary users
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
# "-": not every kernel has these - skipped there instead of an error
-kernel.unprivileged_bpf_disabled = 1
-net.core.bpf_jit_harden = 2
# no core dumps of setuid programs
fs.suid_dumpable = 0
fs.protected_fifos = 1
fs.protected_regular = 2
# network: no ICMP redirects, no source routing, SYN cookies
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# reverse-path filter loose (2): strict (1) breaks Tailscale and multi-homing
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
EOF
    chmod 644 "$SYSCTL_FILE"
}

sysctl_status() {
    echo "  kernel hardening: $([[ -f "$SYSCTL_FILE" ]] && echo "$SYSCTL_FILE" || echo "not set")"
}

setup_sysctl() {
    echo "--- Kernel hardening (sysctl) ---"
    if in_container; then
        echo "A container shares the host kernel - set this on the host."
        return 0
    fi
    echo "Conservative values: no kernel addresses/log for ordinary users, no ICMP"
    echo "redirects or source routing, SYN cookies. Forwarding is not touched"
    echo "(Docker, Tailscale), the reverse-path filter stays loose (Tailscale)."
    confirm "Apply the kernel hardening?" "$(yn "${DEFAULT_SYSCTL:-}" Y)" DEFAULT_SYSCTL || return 0
    write_sysctl
    local bad
    bad=$(sysctl -p "$SYSCTL_FILE" 2>&1 >/dev/null | grep -v '^$' || true)
    [[ -n "$bad" ]] && echo "Not available on this kernel (ignored): $(wc -l <<<"$bad") value(s)"
    echo "Written: ${SYSCTL_FILE} (active now and after every boot)."
}

# ---------------------------------------------------------------------------
# Swap
# ---------------------------------------------------------------------------
# Small VMs without swap: one memory spike and the OOM killer takes a service
# down. A swap file gives slack; swappiness 10 keeps it for emergencies.
SWAPFILE=/swapfile
SWAP_SYSCTL=/etc/sysctl.d/91-base-tools-swap.conf

swap_status() {
    local s; s=$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')
    echo "  swap: ${s:-none}"
}

setup_swap() {
    echo "--- Swap ---"
    # DEFAULT_SWAP: auto (offer it below 8 GB RAM, size from the RAM),
    # no (default no), or a size in MB (default yes, that size).
    local want=${DEFAULT_SWAP:-auto}
    if [[ ! "$want" =~ ^(auto|no|[1-9][0-9]*)$ ]]; then
        echo "!!! DEFAULT_SWAP='${want}' - allowed: auto, no or a size in MB." >&2
        return 1
    fi
    if in_container; then echo "Container - swap is the host's business."; return 0; fi
    if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        echo "Swap is active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
        return 0
    fi
    local mem_mb size_mb def
    mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    size_mb=$(( mem_mb < 2048 ? 2048 : (mem_mb < 4096 ? mem_mb : 4096) ))
    def=$( (( mem_mb < 8192 )) && echo Y || echo N)
    case "$want" in
        auto) ;;
        no)   def=N ;;
        *)    def=Y; size_mb=$want ;;
    esac
    echo "No swap; RAM: ${mem_mb} MB. Without swap, one memory spike lets the OOM"
    echo "killer stop a service. A swap file of ${size_mb} MB gives slack (used only"
    echo "in an emergency: swappiness 10)."
    # A preset (auto included) decides without a question: auto applies the
    # RAM rule above, no declines, a number creates a file of that size.
    if preset DEFAULT_SWAP; then
        echo "Create ${SWAPFILE} (${size_mb} MB)? -> $( [[ "$def" == Y ]] && echo yes || echo no) (preset)"
        [[ "$def" == Y ]] || return 0
    else
        confirm "Create ${SWAPFILE} (${size_mb} MB)?" "$def" || return 0
    fi
    if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null)" == btrfs ]]; then
        echo "!!! The root filesystem is btrfs - a swap file needs special care there"
        echo "!!! (btrfs filesystem mkswapfile). Not created."
        return 0
    fi
    if preset DEFAULT_SWAP; then
        echo "Size in MB: ${size_mb} (preset)"
    else
        ask size_mb "Size in MB" "$size_mb" || return 1
    fi
    if [[ ! "$size_mb" =~ ^[1-9][0-9]*$ ]]; then
        echo "!!! Size '${size_mb}' is not a number of MB - no swap file created." >&2
        return 1
    fi
    if ! fallocate -l "${size_mb}M" "$SWAPFILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon "$SWAPFILE"
    grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    echo "vm.swappiness = 10" > "$SWAP_SYSCTL"
    sysctl -p "$SWAP_SYSCTL" >/dev/null 2>&1 || true
    echo "Swap active: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
}

setup_all() {
    install_packages
    echo
    write_configs
    echo
    setup_time
    echo
    setup_locale
    echo
    setup_sysctl
    echo
    setup_swap
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
    echo "--- Packages ---"
    pkg_state "${PKGS_ALWAYS[@]}" "${PKGS_EDITOR[@]}" "${PKGS_SESSION[@]}" \
              "${PKGS_TOOLS[@]}" "${PKGS_NET[@]}"
    echo
    echo "--- Defaults ---"
    printf '  [%s] %s\n' "$([[ -f "$PROFILE_D" ]] && echo x || echo ' ')" "$PROFILE_D"
    printf '  [%s] %s (points at the shell configuration)\n' "$(has_block "$BASHRC" && echo x || echo ' ')" "$BASHRC"
    printf '  [%s] %s\n' "$([[ -f "$VIMRC" ]] && echo x || echo ' ')" "$VIMRC"
    printf '  [%s] %s\n' "$(has_block "$NANORC" && echo x || echo ' ')" "$NANORC"
    printf '  [%s] %s\n' "$(has_block "$SCREENRC" && echo x || echo ' ')" "$SCREENRC"
    echo
    echo "--- System ---"
    time_status
    locale_status
    sysctl_status
    swap_status
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall base-tools"
    echo
    # A hand-written vimrc.local that did not come from here stays untouched.
    local vim_ours=0 vimnote=""
    if [[ -f "$VIMRC.orig" ]]; then
        vim_ours=1; vimnote=" (the previous version is restored)"
    elif [[ -f "$VIMRC" ]] && head -1 "$VIMRC" | grep -q 'base-tools'; then
        vim_ours=1
    fi

    echo "The following will be removed:"
    [[ -f "$PROFILE_D" ]] && echo "  - $PROFILE_D"                  || true
    has_block "$BASHRC"   && echo "  - marked block in $BASHRC"     || true
    (( vim_ours == 1 ))   && echo "  - ${VIMRC}${vimnote}"          || true
    has_block "$NANORC"   && echo "  - marked block in $NANORC"     || true
    has_block "$SCREENRC" && echo "  - marked block in $SCREENRC"   || true
    [[ -f "$SYSCTL_FILE" ]] && echo "  - $SYSCTL_FILE (kernel hardening)" || true
    echo
    echo "Time sync, timezone, locale and a swap file stay - they are not comfort"
    echo "but the system's state. Swap file by hand: swapoff ${SWAPFILE}, remove"
    echo "its line in /etc/fstab, rm ${SWAPFILE}."
    echo
    echo "The installed packages stay - taking nano and vim away from a server"
    echo "does more damage than it cleans up. If you want them gone anyway:"
    echo "    apt purge ${PKGS_EDITOR[*]} ${PKGS_SESSION[*]} ${PKGS_TOOLS[*]} ${PKGS_NET[*]}"
    echo "  (git and ca-certificates are deliberately not on that line)"
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup base-tools "$PROFILE_D" "$BASHRC" "$VIMRC" "$NANORC" "$SCREENRC" "$SYSCTL_FILE" || { pause; return; }

    rm -f "$PROFILE_D"
    if [[ -f "$SYSCTL_FILE" ]]; then rm -f "$SYSCTL_FILE"; sysctl --system >/dev/null 2>&1 || true; fi
    remove_block "$BASHRC"
    # nanorc and screenrc may not have existed before - then an empty file is
    # left behind after removing the block, and that can go too.
    remove_block "$NANORC";   [[ -s "$NANORC" ]]   || rm -f "$NANORC"
    remove_block "$SCREENRC"; [[ -s "$SCREENRC" ]] || rm -f "$SCREENRC"

    if [[ -f "$VIMRC.orig" ]]; then
        mv "$VIMRC.orig" "$VIMRC"
        echo "$VIMRC restored from $VIMRC.orig."
    elif (( vim_ours == 1 )); then
        rm -f "$VIMRC"
    fi

    echo
    echo "Removed. New sessions get the default shell again."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Base tools and shell comfort"
        echo "==========================================="
        if is_setup; then
            echo "Status: set up"
        else
            echo "Status: not set up"
        fi
        time_status
        locale_status
        swap_status
        echo
        echo "1) Set up everything (packages + defaults)"
        echo "2) Install packages only"
        echo "3) Write defaults only (shell, vim, nano, screen)"
        echo "4) Time: synchronisation and timezone"
        echo "5) Locale (UTF-8, further languages)"
        echo "6) Kernel hardening (sysctl)"
        echo "7) Swap file"
        echo "8) Show status"
        echo "9) Uninstall"
        echo "q) Quit"
        read -rp "Choice: " CH || exit 0
        case "$CH" in
            1) setup_all ;;
            2) install_packages; pause ;;
            3) write_configs; pause ;;
            4) setup_time; pause ;;
            5) setup_locale; pause ;;
            6) setup_sysctl; pause ;;
            7) setup_swap; pause ;;
            8) show_status; pause ;;
            9) uninstall ;;
            q|Q) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --setup)     validate_presets; setup_all ;;
    --packages)  validate_presets; install_packages ;;
    --shell)     validate_presets; write_configs ;;
    --time)      validate_presets; setup_time ;;
    --locale)    validate_presets; setup_locale ;;
    --sysctl)    validate_presets; setup_sysctl ;;
    --swap)      validate_presets; setup_swap ;;
    --uninstall) uninstall ;;
    "")          validate_presets; main_menu ;;
    *)           echo "Usage: $0 [--status|--setup|--packages|--shell|--time|--locale|--sysctl|--swap|--uninstall|--version]"; exit 1 ;;
esac
