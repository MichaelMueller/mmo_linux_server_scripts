#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tailscale-setup.sh - install, log in to and configure Tailscale
# Modes: (no argument) = interactive menu
#        --status      = status on stdout
#        --login       = install and log in (used by ssh-setup.sh)
#        --uninstall   = uninstall
#
# Presets: a DEFAULT_* (and TS_LOGIN_SERVER) that is set (not empty) is taken
# without a question - interactively as well - and printed as
# "<question>: <value> (preset)". An invalid preset is an error, nothing is
# changed. Unset ones are asked (batch mode: their built-in default, in
# brackets below):
#   TS_LOGIN_SERVER          control server URL, e.g. https://hs.example.com
#                            (unset: asked - Tailscale's own, or the current one)
#   DEFAULT_TS_LOGIN         authkey|browser - how to log in (authkey)
#   DEFAULT_TS_HOSTNAME      name in the tailnet (short hostname)
#   DEFAULT_TS_ROUTES        subnets to offer, comma-separated, e.g.
#                            192.168.1.0/24 ('-' = no subnet router; unset:
#                            asked, default no)
#   DEFAULT_TS_EXIT_NODE     Y|N  offer this server as exit node (N)
#   DEFAULT_TS_ACCEPT_ROUTES Y|N  accept subnets of other nodes (N)
#   DEFAULT_TS_ACCEPT_DNS    Y|N  take over MagicDNS/DNS (Y)
#   DEFAULT_TS_SHIELDS_UP    Y|N  no incoming connections from the tailnet (N)
#   DEFAULT_TS_TAGS          tags, e.g. tag:server ('-' = none; default: the
#                            current ones, else none)
# IP forwarding follows from them: on when routes or the exit node are offered.
# Tailscale SSH is always off.
# Secret, from the environment only (never printed):
#   TS_AUTHKEY               auth key (tskey-auth-... / Headscale pre-auth key);
#                            batch mode with the auth key login: required
# Batch mode: BATCH=1 - no questions, every question takes its default and
# prints what it took.
set -uo pipefail

# --version must come before the root check so it answers without sudo.
# if-form instead of "[[ ]] &&": a false && would exit under set -e.
VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

SYSCTL_FILE=/etc/sysctl.d/99-tailscale.conf
REPO_LIST=/etc/apt/sources.list.d/tailscale.list
REPO_KEY=/usr/share/keyrings/tailscale-archive-keyring.gpg
IFACE=tailscale0

pause() { [[ -n "${BATCH:-}" ]] && return 0; read -rp "Press Enter to continue..." _; }

# yn_value VALUE - a yes/no value (Y, N, yes, no, j, ja, 1, 0, true, false)
# as Y or N; fails on anything else
yn_value() {
    case "${1,,}" in
        y|yes|j|ja|1|true)   echo Y ;;
        n|no|nein|0|false)   echo N ;;
        *)                   return 1 ;;
    esac
}
# yn VALUE [FALLBACK] - like yn_value, FALLBACK (N) for an empty/unknown value
yn() { yn_value "${1:-}" || echo "${2:-N}"; }

# preset NAME - 0 when the caller set the variable NAME (non-empty). Its
# question is then not asked, neither interactively nor in batch mode.
preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }

# confirm "Question" [default Y|N] [DEFAULT_NAME]
# A preset DEFAULT_NAME answers the question without asking it.
# Batch mode (BATCH=1, set by base-setup.sh): no questions. Every question
# takes its default - DEFAULT_* from the caller or the built-in one - and
# prints what it took. A required value without a default is an error.
confirm() {
    local q=$1 def=${2:-N} pre=${3:-} ans
    if preset "$pre"; then
        def=$(yn_value "${!pre}") || { echo "!!! ${q}: '${!pre}' is not yes/no (${pre})" >&2; exit 1; }
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
# ask VAR "Question" [default] [required] [DEFAULT_NAME] - the answer lands in
# VAR; a preset DEFAULT_NAME is taken without asking
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
# ask_secret VAR "Question" ENVNAME - from the environment variable ENVNAME if
# set, else asked hidden; in batch mode a missing secret is an error.
ask_secret() {
    local __v=$1 __q=$2 __e=$3 __a
    if [[ -n "${!__e:-}" ]]; then printf -v "$__v" '%s' "${!__e}"; echo "${__q}: (from \$${__e})"; return 0; fi
    if [[ -n "${BATCH:-}" ]]; then echo "!!! ${__q}: \$${__e} not set (batch mode)" >&2; return 1; fi
    read -rsp "${__q}: " __a; echo
    printf -v "$__v" '%s' "$__a"
}

make_backup() {
    local name=$1; shift
    local ts tgz p
    local -a existing=()
    for p in "$@"; do [[ -e "$p" ]] && existing+=("$p"); done
    if (( ${#existing[@]} == 0 )); then echo "(nothing to back up)"; return 0; fi
    mkdir -p /root 2>/dev/null || true
    ts=$(date +%Y%m%d-%H%M%S)
    tgz="/root/${name}-uninstall-${ts}.tar.gz"
    if tar czf "$tgz" --absolute-names "${existing[@]}"; then
        chmod 600 "$tgz"; echo "Backup: $tgz"
    else
        echo "!!! Backup failed - aborting, nothing is removed." >&2
        return 1
    fi
}

installed()  { command -v tailscale &>/dev/null; }
logged_in()  { tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; }
tailnet_ip() { tailscale ip -4 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
install_tailscale() {
    installed && return 0

    echo ">>> Installing Tailscale from the official repo..."

    # shellcheck disable=SC1091
    . /etc/os-release
    local id=${ID:-debian} code=${VERSION_CODENAME:-}

    if [[ -z "$code" ]]; then
        echo "!!! /etc/os-release does not name a VERSION_CODENAME."
        ask code "Codename of the distribution (e.g. bookworm, jammy)" "" "${BATCH:+required}" || return 1
        [[ -n "$code" ]] || return 1
    fi

    apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q </dev/null curl gnupg apt-transport-https >/dev/null

    if ! curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.noarmor.gpg" -o "$REPO_KEY"; then
        echo "!!! Key for ${id}/${code} cannot be fetched - is the codename right?"
        return 1
    fi
    curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${code}.tailscale-keyring.list" -o "$REPO_LIST" || return 1

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q </dev/null tailscale >/dev/null || return 1

    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    echo ">>> Installed: $(tailscale version 2>/dev/null | head -1)"
}

# IP forwarding is only needed when this node passes traffic on for others -
# that is, as a subnet router or exit node.
enable_forwarding() {
    cat > "$SYSCTL_FILE" <<'EOF'
# from tailscale-setup.sh - needed for subnet routers and exit nodes
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    echo "IP forwarding enabled ($SYSCTL_FILE)."
}

# ---------------------------------------------------------------------------
# Log in and configure
# ---------------------------------------------------------------------------
# The tags the node carries right now. Read from the daemon's own preferences,
# because they may come from an earlier run or from the auth key rather than
# from anything this script did.
#
# sed instead of jq: jq is not installed on a fresh server, and a tag list
# cannot contain quotes, commas or brackets, so the parse is safe here even
# though it would not be in general.
current_tags() {
    tailscale debug prefs 2>/dev/null \
        | tr -d ' \n' \
        | sed -n 's/.*"AdvertiseTags":\[\([^]]*\)\].*/\1/p' \
        | tr -d '"'
}

DEFAULT_CONTROL="https://controlplane.tailscale.com"
# A caller can fix the control server (Headscale), e.g.
# TS_LOGIN_SERVER=https://hs.example.com - a preset, not asked.

# The control server this node currently talks to. Anything other than
# Tailscale's own means a self-hosted control plane - Headscale, in practice.
current_control_url() {
    tailscale debug prefs 2>/dev/null \
        | tr -d ' \n' \
        | sed -n 's/.*"ControlURL":"\([^"]*\)".*/\1/p'
}

# check_presets - every preset is checked before anything is changed: an
# invalid one is an error, and nothing is written or run.
check_presets() {
    local v bad=0
    for v in DEFAULT_TS_EXIT_NODE DEFAULT_TS_ACCEPT_ROUTES DEFAULT_TS_ACCEPT_DNS DEFAULT_TS_SHIELDS_UP; do
        preset "$v" || continue
        yn_value "${!v}" >/dev/null || { echo "!!! ${v}='${!v}': yes or no expected." >&2; bad=1; }
    done
    if preset DEFAULT_TS_LOGIN && [[ ! "$DEFAULT_TS_LOGIN" =~ ^(authkey|browser)$ ]]; then
        echo "!!! DEFAULT_TS_LOGIN='${DEFAULT_TS_LOGIN}': authkey or browser expected." >&2; bad=1
    fi
    if preset TS_LOGIN_SERVER && [[ ! "$TS_LOGIN_SERVER" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "!!! TS_LOGIN_SERVER='${TS_LOGIN_SERVER}': a full URL is expected (https://...)." >&2; bad=1
    fi
    if preset DEFAULT_TS_HOSTNAME && [[ ! "$DEFAULT_TS_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
        echo "!!! DEFAULT_TS_HOSTNAME='${DEFAULT_TS_HOSTNAME}': letters, digits and '-' expected." >&2; bad=1
    fi
    if preset DEFAULT_TS_ROUTES && [[ "$DEFAULT_TS_ROUTES" != "-" \
        && ! "$DEFAULT_TS_ROUTES" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}(,[0-9A-Fa-f:.]+/[0-9]{1,3})*$ ]]; then
        echo "!!! DEFAULT_TS_ROUTES='${DEFAULT_TS_ROUTES}': comma-separated subnets (192.168.1.0/24) or '-' expected." >&2; bad=1
    fi
    if preset DEFAULT_TS_TAGS && [[ "$DEFAULT_TS_TAGS" != "-" \
        && ! "$DEFAULT_TS_TAGS" =~ ^tag:[A-Za-z0-9_-]+(,tag:[A-Za-z0-9_-]+)*$ ]]; then
        echo "!!! DEFAULT_TS_TAGS='${DEFAULT_TS_TAGS}': comma-separated tags (tag:server) or '-' expected." >&2; bad=1
    fi
    (( bad == 0 )) || { echo "Invalid preset - nothing changed." >&2; return 1; }
}

# 'tailscale up' resets options you do NOT pass to their default and demands
# --reset for that. So all managed flags are always asked for together and set
# together here.
build_up_args() {
    UP_ARGS=()
    local host exitnode routes tags
    local ctrl curctrl

    # --- control server -----------------------------------------------------
    # Without this, a self-hosted control plane is unreachable: the key is sent
    # to Tailscale's servers, which have never heard of it. The flag has to be
    # passed on every 'up', not just the first, because it is a preference like
    # any other.
    curctrl=$(current_control_url)
    echo "--- Control server ---"
    echo "Where this node registers. Tailscale's own service, or a self-hosted"
    echo "control plane such as Headscale."
    local C
    if preset TS_LOGIN_SERVER; then
        # The URL itself is the answer: Tailscale's own or a self-hosted one.
        ctrl=${TS_LOGIN_SERVER%/}
        echo "Control server: ${ctrl} (preset)"
        if [[ "$ctrl" != "$DEFAULT_CONTROL" ]]; then
            echo
            echo "Note for a self-hosted control plane: the auth key has to come from"
            echo "THAT server (Headscale: 'headscale preauthkeys create'), not from"
            echo "the Tailscale console. MagicDNS and exit nodes depend on what the"
            echo "server implements."
        fi
        C=preset
    else
        echo "  1) Tailscale     ${DEFAULT_CONTROL}"
        echo "  2) own server    e.g. https://headscale.example.com"
        if [[ -n "$curctrl" && "$curctrl" != "$DEFAULT_CONTROL" ]]; then
            echo "  (currently: ${curctrl})"
        fi
        ask C "Choice" "$( [[ -n "$curctrl" && "$curctrl" != "$DEFAULT_CONTROL" ]] && echo 2 || echo 1 )" || return 1
    fi
    if [[ "$C" == preset ]]; then
        :
    elif [[ "$C" == "2" ]]; then
        local d=$curctrl
        [[ "$d" == "$DEFAULT_CONTROL" ]] && d=""
        ask ctrl "URL" "$d" "${BATCH:+required}" || return 1
        while [[ ! "$ctrl" =~ ^https?:// ]]; do
            if [[ -n "${BATCH:-}" ]]; then
                echo "!!! Control server '${ctrl}' (TS_LOGIN_SERVER): a full URL is expected (https://...)." >&2
                return 1
            fi
            read -rp "  -> a full URL is expected (https://...): " ctrl
        done
        ctrl=${ctrl%/}
        echo
        echo "Note for a self-hosted control plane: the auth key has to come from"
        echo "THAT server (Headscale: 'headscale preauthkeys create'), not from"
        echo "the Tailscale console. MagicDNS and exit nodes depend on what the"
        echo "server implements."
    else
        ctrl=$DEFAULT_CONTROL
    fi
    UP_ARGS+=("--login-server=${ctrl}")

    # --- hostname -----------------------------------------------------------
    echo
    echo "--- Hostname ---"
    echo "The name this node appears under in the admin console and, with"
    echo "MagicDNS, the name other nodes can reach it by."
    ask host "Hostname in the tailnet" "${DEFAULT_TS_HOSTNAME:-$(hostname -s)}" "" DEFAULT_TS_HOSTNAME || return 1
    UP_ARGS+=("--hostname=${host:-$(hostname -s)}")

    # --- tailscale ssh ------------------------------------------------------
    # Always off, not asked: access goes through the regular sshd with keys.
    # Tailscale SSH would take over port 22 on the tailnet IP and decide by
    # tailnet ACLs instead ("tailnet policy does not permit you to SSH") -
    # a second door governed by rules kept somewhere else.
    UP_ARGS+=(--ssh=false)

    # --- advertise routes ---------------------------------------------------
    echo
    echo "--- Subnet router (--advertise-routes) ---"
    echo "Makes the networks BEHIND this server reachable for the other nodes,"
    echo "so they can talk to machines that have no Tailscale of their own - a"
    echo "printer, a NAS, a whole office LAN."
    echo "Two things besides this are needed: IP forwarding (offered below) and"
    echo "approval of the route in the admin console (Headscale:"
    echo "'headscale routes enable'). Until then it is advertised and unused."
    if preset DEFAULT_TS_ROUTES; then
        # '-' = no subnet router
        if [[ "$DEFAULT_TS_ROUTES" == "-" ]]; then
            echo "Offer local subnets to other nodes (subnet router)? -> no (preset)"
        else
            routes=$DEFAULT_TS_ROUTES
            echo "Subnets to offer (subnet router): ${routes} (preset)"
            UP_ARGS+=("--advertise-routes=${routes}")
        fi
    elif confirm "Offer local subnets to other nodes (subnet router)?" N; then
        if [[ -n "${BATCH:-}" ]]; then
            ask routes "  Subnets, comma-separated" ""
        else
            read -rp "  Subnets, comma-separated (e.g. 192.168.1.0/24): " routes
        fi
        [[ -n "$routes" ]] && UP_ARGS+=("--advertise-routes=${routes}")
    fi

    # --- exit node ----------------------------------------------------------
    echo
    echo "--- Exit node (--advertise-exit-node) ---"
    echo "Offers this server as the way out to the internet for other nodes."
    echo "A node that picks it sends ALL its traffic through here - useful on"
    echo "hostile Wi-Fi, and it means this machine's IP and its bandwidth bill."
    echo "It has to be approved in the admin console as well."
    if confirm "Offer this server as an exit node?" "$(yn "${DEFAULT_TS_EXIT_NODE:-}" N)" DEFAULT_TS_EXIT_NODE; then
        exitnode=1
        UP_ARGS+=(--advertise-exit-node)
    fi

    # --- accept routes ------------------------------------------------------
    echo
    echo "--- Accept foreign subnets (--accept-routes) ---"
    echo "The mirror image of the subnet router: whether THIS machine takes over"
    echo "the routes other nodes advertise. Say yes if this server has to reach"
    echo "a network sitting behind another node."
    echo "Off by default because it writes foreign routes into this machine's"
    echo "routing table. A remote 192.168.1.0/24 then shadows a local network of"
    echo "the same address range - and on a server, routing that silently"
    echo "changes underneath you is a bad afternoon."
    if confirm "Accept subnets offered by others (--accept-routes)?" "$(yn "${DEFAULT_TS_ACCEPT_ROUTES:-}" N)" DEFAULT_TS_ACCEPT_ROUTES; then
        UP_ARGS+=(--accept-routes)
    else
        UP_ARGS+=(--accept-routes=false)
    fi

    # --- accept dns ---------------------------------------------------------
    echo
    echo "--- MagicDNS (--accept-dns) ---"
    echo "Lets the tailnet supply the DNS: other nodes become reachable by name,"
    echo "and /etc/resolv.conf is rewritten to point at Tailscale's resolver."
    echo "Say no on a server with its own DNS configuration - a resolver, split"
    echo "horizon, a mail setup that depends on it - because having resolv.conf"
    echo "replaced is rarely what you want there."
    if confirm "Take over MagicDNS/DNS settings?" "$(yn "${DEFAULT_TS_ACCEPT_DNS:-}" Y)" DEFAULT_TS_ACCEPT_DNS; then
        UP_ARGS+=(--accept-dns)
    else
        UP_ARGS+=(--accept-dns=false)
    fi

    # --- shields up ---------------------------------------------------------
    echo
    echo "--- Shields up (--shields-up) ---"
    echo "This node accepts NO incoming connections from the tailnet at all,"
    echo "while its own outgoing connections keep working."
    echo "!!! That includes SSH over the tunnel. Do not switch this on if the"
    echo "!!! plan is to reach this server through Tailscale - it is for nodes"
    echo "!!! that only ever call out, never in."
    if confirm "Enable shields up?" "$(yn "${DEFAULT_TS_SHIELDS_UP:-}" N)" DEFAULT_TS_SHIELDS_UP; then UP_ARGS+=(--shields-up); fi

    # Tags have to be repeated on every 'tailscale up' - they are a property of
    # the call, not something the daemon remembers on your behalf. Leaving the
    # question empty on a tagged node is therefore the classic way to get the
    # "requires mentioning all non-default flags" refusal, so the current value
    # is offered as the default instead of an empty field.
    echo
    echo "--- Tags (--advertise-tags) ---"
    echo "Tags hand the node over to the ACLs: it then belongs to the tag rather"
    echo "than to the user who logged it in, which is what keeps a server from"
    echo "dropping out of the tailnet when that user's key expires. The tag has"
    echo "to exist in the ACL policy first, and the key or the user has to be"
    echo "allowed to apply it."
    local curtags; curtags=$(current_tags)
    if preset DEFAULT_TS_TAGS; then
        # '-' = none; wins over the current tags
        tags=$DEFAULT_TS_TAGS
        echo "Tags: ${tags} (preset)"
        [[ "$tags" == "-" ]] && tags=""
    elif [[ -n "${BATCH:-}" ]]; then
        ask tags "Tags" "$curtags"
        [[ "$tags" == "-" ]] && tags=""
    elif [[ -n "$curtags" ]]; then
        echo "This node currently carries: ${curtags}"
        echo "Tags have to be given again on every login - leaving this empty"
        echo "keeps them. Enter '-' to remove them."
        read -rp "Tags [${curtags}]: " tags
        if [[ "$tags" == "-" ]]; then tags=""; else tags=${tags:-$curtags}; fi
    else
        read -rp "Tags (e.g. tag:server, empty = none): " tags
    fi
    [[ -n "$tags" ]] && UP_ARGS+=("--advertise-tags=${tags}")

    if [[ -n "${routes:-}" || "${exitnode:-0}" == "1" ]]; then
        echo
        enable_forwarding
    fi
}

run_up() {
    local -a extra=("$@")
    local reset_tried=0 a
    for a in ${extra[@]+"${extra[@]}"}; do
        [[ "$a" == "--reset" ]] && reset_tried=1
    done

    echo
    echo "This will be run:"
    printf '    tailscale up'; printf ' %q' "${UP_ARGS[@]}" ${extra[@]+"${extra[@]}"}; echo
    echo
    confirm "Run it?" Y || { echo "Cancelled."; return 1; }

    # The output is shown live *and* captured. Swallowing it into a variable
    # would hide the very thing an interactive login is about: 'tailscale up'
    # prints the URL to open and then waits. Hence tee.
    local logf rc=0
    logf=$(mktemp)
    tailscale up "${UP_ARGS[@]}" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$logf" || rc=$?

    if (( rc == 0 )); then
        rm -f "$logf"
        echo
        echo ">>> Connected. Tailnet IP: $(tailnet_ip)"
        return 0
    fi

    # 'tailscale up' refuses the whole call when the node currently carries a
    # non-default setting that is not mentioned again - a tag from an earlier
    # run or from the auth key is the usual case, and it is not something the
    # questions above ask about. Offering --reset right here matters: at this
    # point the auth key that was just typed in is still available, whereas
    # sending the user off to another menu item means typing it again.
    if (( reset_tried == 0 )) && grep -q -- '--reset' "$logf"; then
        rm -f "$logf"
        echo
        echo "!!! Tailscale refuses this call: the node still carries settings that"
        echo "!!! were not asked for above - a tag from an earlier login, for"
        echo "!!! instance. Tailscale wants every non-default setting mentioned."
        echo
        echo "--reset applies exactly what was asked for here and returns"
        echo "everything else to its default. If you need to keep a tag, answer"
        echo "no and enter it at the tag question on the next run."
        echo
        if confirm "Run again with --reset?" Y; then
            run_up ${extra[@]+"${extra[@]}"} --reset
            return $?
        fi
        echo "Cancelled - nothing was changed."
        return 1
    fi

    rm -f "$logf"
    echo
    echo "!!! 'tailscale up' was not successful."
    return 1
}

first_setup() {
    check_presets || return 1
    install_tailscale || { echo "!!! Installation failed."; pause; return 1; }

    echo
    # Auth key by default: these are servers, usually without a browser at hand,
    # and the key can be limited to one use and a short lifetime.
    local M rc=0
    if preset DEFAULT_TS_LOGIN; then
        # authkey|browser -> menu choice 2|1 (checked in check_presets)
        [[ "$DEFAULT_TS_LOGIN" == browser ]] && M=1 || M=2
        echo "Login: ${DEFAULT_TS_LOGIN} (preset)"
    else
        echo "Login:"
        echo "  1) interactive - Tailscale shows a URL to open in a browser"
        echo "  2) with an auth key (tskey-auth-... / Headscale pre-auth key) - recommended for servers"
        ask M "Choice" 2 || return 1
    fi

    # Batch: the key must be there before anything is asked or changed.
    local key="" kf
    if [[ "${M:-2}" != "1" && -n "${BATCH:-}" ]]; then
        ask_secret key "Auth key" TS_AUTHKEY || return 1
    fi

    build_up_args || return 1

    if [[ "${M:-2}" != "1" ]]; then
        [[ -n "$key" ]] || ask_secret key "Auth key" TS_AUTHKEY
        if [[ -z "$key" ]]; then echo "No key given."; pause; return 1; fi
        # Through a file rather than the command line: otherwise the key would
        # show up in the process list.
        kf=$(mktemp); chmod 600 "$kf"; printf '%s' "$key" > "$kf"
        # The file is deleted again as soon as 'tailscale up' has read it - a
        # valid auth key must not stay behind in /tmp, and a Ctrl-C in the
        # middle of the login must not leave one there either.
        trap 'rm -f "$kf"; echo; echo "(auth key file removed)"; exit 130' INT TERM
        key=""
        run_up "--auth-key=file:${kf}" || rc=1
        rm -f "$kf"
        trap - INT TERM
    else
        echo
        echo "A URL will appear shortly. Open it in a browser and approve the node"
        echo "- after that things continue here."
        run_up || rc=1
    fi
    pause
    return "$rc"
}

change_settings() {
    installed || { echo "Tailscale is not installed."; pause; return; }
    check_presets || { pause; return; }
    build_up_args
    echo
    echo "Note: --reset returns every option not asked for here to its default."
    local -a extra=()
    confirm "Run with --reset?" Y && extra=(--reset)
    run_up "${extra[@]}" || true
    pause
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
firewall_rule() {
    if ! command -v ufw &>/dev/null; then
        echo "ufw is not installed - there is nothing to configure here."
        pause; return
    fi

    echo "With a rule on interface ${IFACE}, nodes from the tailnet can reach"
    echo "services on this server without any port being publicly open."
    echo
    echo "Existing rules for ${IFACE}:"
    ufw status 2>/dev/null | grep -E "on ${IFACE}" || echo "  (none)"
    echo
    echo "1) Allow all traffic from the tailnet  (allow in on ${IFACE})"
    echo "2) Allow one specific port only"
    echo "3) Back"
    local CH; read -rp "Choice: " CH || exit 0
    case "$CH" in
        1)
            confirm "Run ufw allow in on ${IFACE}?" Y \
                && ufw allow in on "$IFACE" comment 'Tailnet' || true
            ;;
        2)
            local p
            read -rp "Port: " p
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Not a number."; pause; return; }
            confirm "Run ufw allow in on ${IFACE} to any port ${p} proto tcp?" Y \
                && ufw allow in on "$IFACE" to any port "$p" proto tcp comment 'Tailnet' || true
            ;;
        *) return ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    if ! installed; then
        echo "Tailscale is not installed."
        return
    fi
    echo "--- Version ---"
    tailscale version 2>/dev/null | sed 's/^/  /'
    echo
    echo "--- Service ---"
    printf '  tailscaled: %s\n' "$(systemctl is-active tailscaled 2>/dev/null || echo '-')"
    printf '  login:      %s\n' "$(logged_in && echo 'logged in' || echo 'not logged in')"
    printf '  tailnet IP: %s\n' "$(tailnet_ip || echo '-')"
    echo
    echo "--- Nodes in the tailnet ---"
    tailscale status 2>/dev/null | sed 's/^/  /' || echo "  (no output)"
    echo
    echo "--- IP forwarding ---"
    if [[ -f "$SYSCTL_FILE" ]]; then
        echo "  enabled through $SYSCTL_FILE"
    else
        echo "  not set by this tool (currently: $(sysctl -n net.ipv4.ip_forward 2>/dev/null))"
    fi
}

do_logout() {
    echo "Logs the node out of the tailnet. The software stays installed."
    echo
    echo "!!! If you reach this server only over Tailscale, you are cutting off"
    echo "!!! your own connection."
    echo
    confirm "Really log out?" || { echo "Cancelled."; pause; return; }
    tailscale logout || true
    tailscale down 2>/dev/null || true
    echo "Logged out."
    pause
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
    echo ">>> Uninstall Tailscale"
    echo

    if ! installed; then
        echo "Tailscale is not installed."
        [[ -f "$SYSCTL_FILE" ]] || { pause; return; }
    fi

    echo "The following will be removed:"
    logged_in            && echo "  - logout from the tailnet (tailscale logout)"
    installed            && echo "  - the tailscaled service is stopped and disabled"
    [[ -f "$SYSCTL_FILE" ]] && echo "  - $SYSCTL_FILE (IP forwarding)"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}" \
        && echo "  - ufw rules for ${IFACE}                            [asked]"
    echo
    echo "The package stays installed, and so does the state under /var/lib/tailscale."
    echo "To remove it completely:"
    echo "    apt purge tailscale && rm -rf /var/lib/tailscale \\"
    echo "        ${REPO_LIST} ${REPO_KEY}"
    echo
    echo "!!! The node stays registered in the admin console and has to be deleted"
    echo "!!! there separately."
    echo
    echo "!!! If you reach this server only over Tailscale, you are cutting off"
    echo "!!! your own connection."
    echo

    confirm "Really remove?" || { echo "Cancelled."; pause; return; }

    make_backup tailscale "$SYSCTL_FILE" /var/lib/tailscale || { pause; return; }

    if installed; then
        tailscale logout 2>/dev/null || true
        tailscale down 2>/dev/null || true
        systemctl stop tailscaled    >/dev/null 2>&1 || true
        systemctl disable tailscaled >/dev/null 2>&1 || true
    fi

    if [[ -f "$SYSCTL_FILE" ]]; then
        rm -f "$SYSCTL_FILE"
        # Do not blindly set it back to 0: other services (Docker, WireGuard
        # routing) may need forwarding as well.
        echo "$SYSCTL_FILE removed. IP forwarding stays active until the next"
        echo "reboot; other services may need it too."
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "on ${IFACE}"; then
        if confirm "Remove the ufw rules for ${IFACE}?" Y; then
            # Delete from the back, so the numbers do not shift.
            local n
            for n in $(ufw status numbered 2>/dev/null | grep "on ${IFACE}" \
                       | grep -oE '^\[[ ]*[0-9]+\]' | grep -oE '[0-9]+' | sort -rn); do
                ufw --force delete "$n" >/dev/null 2>&1 || true
            done
            echo "Removed."
        fi
    fi

    echo
    echo "Done."
    pause
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "==========================================="
        echo " Tailscale"
        echo "==========================================="
        if installed; then
            echo "Version:    $(tailscale version 2>/dev/null | head -1)"
            echo "tailscaled: $(systemctl is-active tailscaled 2>/dev/null || echo '-')"
            if logged_in; then
                echo "Status:     logged in, IP $(tailnet_ip)"
            else
                echo "Status:     not logged in"
            fi
        else
            echo "Status: not installed"
        fi
        echo
        echo "1) Install and log in"
        echo "2) Show status"
        echo "3) Change settings (SSH, routes, exit node, DNS)"
        echo "4) Firewall: allow access over the tailnet"
        echo "5) Log out"
        echo "6) Uninstall"
        echo "7) Quit"
        read -rp "Choice: " CH || exit 0
        case "$CH" in
            1) first_setup ;;
            2) show_status; pause ;;
            3) change_settings ;;
            4) firewall_rule ;;
            5) do_logout ;;
            6) uninstall ;;
            7) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

case "${1:-}" in
    --status)    show_status ;;
    --login)     first_setup ;;
    --uninstall) uninstall ;;
    "")          main_menu ;;
    *)           echo "Usage: $0 [--status|--login|--uninstall|--version]"; exit 1 ;;
esac
