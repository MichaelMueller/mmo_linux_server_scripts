#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# debian-release-upgrade.sh - Debian release upgrade, one release per run
#
#   8 jessie -> 9 stretch -> 10 buster -> 11 bullseye -> 12 bookworm -> 13 trixie
#
# Standalone: needs nothing but bash and apt. Every run does exactly ONE step
# (the next release), then asks for a reboot; run it again after the reboot
# for the next step. Debian only supports upgrades from one release to the
# next - skipping one is not possible.
#
# Per step:
#   1. checks: OS, disk space, dpkg state, held packages, third-party sources,
#      terminal multiplexer (an SSH drop must not kill the upgrade)
#   2. brings the CURRENT release fully up to date first
#   3. writes the sources for the next release (old ones are backed up;
#      archived releases come from archive.debian.org automatically)
#   4. apt-get upgrade (minimal), then apt-get dist-upgrade
#   5. lists configuration files to review, asks for the reboot
#
# Usage: sudo ./debian-release-upgrade.sh            next step (interactive)
#        sudo ./debian-release-upgrade.sh --to 12    stop at release 12
#        sudo ./debian-release-upgrade.sh --status   current release, next step
#        sudo ./debian-release-upgrade.sh --version
#
# Written for bash 4.3 (jessie): no newer bash features on purpose.
set -uo pipefail

VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

CODENAMES=([8]=jessie [9]=stretch [10]=buster [11]=bullseye [12]=bookworm [13]=trixie)
LAST=13
TARGET=$LAST
STATE_DIR=/var/lib/debian-release-upgrade
LOG_DIR=/var/log/debian-release-upgrade
APT_ARCHIVE_CONF=/etc/apt/apt.conf.d/99-release-upgrade-archive
SOURCES=/etc/apt/sources.list
LOCK=/run/auto-update.lock     # same lock as auto-update.sh: no update run in between

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

die()  { echo "!!! $*" >&2; exit 1; }
info() { echo ">>> $*"; }
warn() { echo "!!! $*"; }

confirm() {
    local q=$1 def=${2:-N} ans
    if [[ "$def" == "Y" ]]; then
        read -rp "$q [Y/n]: " ans; ans=${ans:-Y}
    else
        read -rp "$q [y/N]: " ans; ans=${ans:-N}
    fi
    [[ "$ans" =~ ^[YyJj]$ ]]
}

# ---------------------------------------------------------------------------
# Release detection
# ---------------------------------------------------------------------------
current_major() {
    local v
    v=$(cat /etc/debian_version 2>/dev/null || true)
    if [[ "$v" =~ ^([0-9]+)(\.|$) ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    # testing/unstable: "trixie/sid" - not a release
    echo ""
}

os_id() { ( . /etc/os-release 2>/dev/null; echo "${ID:-}" ); }

# ---------------------------------------------------------------------------
# Mirrors: active releases on deb.debian.org, archived ones on
# archive.debian.org. Probed over plain HTTP with bash's /dev/tcp, so it works
# on a system whose apt sources are already broken and without curl/wget.
# ---------------------------------------------------------------------------
http_ok() {   # http_ok <host> <path>  -> 0 if HTTP 200/30x, 1 if 404 & co.
    local host=$1 path=$2 status _
    # Retried: a single timeout must not silently drop a source (security!).
    for _ in 1 2 3; do
        status=$(timeout 15 bash -c "
            exec 3<>/dev/tcp/${host}/80 || exit 1
            printf 'HEAD ${path} HTTP/1.0\r\nHost: ${host}\r\nUser-Agent: debian-release-upgrade\r\n\r\n' >&3
            head -1 <&3" 2>/dev/null)
        [[ "$status" =~ \ (200|301|302)\  ]] && return 0
        [[ "$status" =~ ^HTTP/ ]] && return 1     # a real answer (404) - no retry
        sleep 2
    done
    return 1
}

# mirror_for <suite> <main|security>  -> "url suite" or empty if none.
# archive.debian.org first: once a release is archived, that copy is the
# complete one - the live mirrors may still carry its Release file while its
# packages are already gone (seen with bullseye-security after its LTS end).
mirror_for() {
    local suite=$1 kind=$2
    if [[ "$kind" == "security" ]]; then
        local s
        for s in "${suite}-security" "${suite}/updates"; do
            http_ok archive.debian.org "/debian-security/dists/${s}/Release"                 && { echo "http://archive.debian.org/debian-security ${s}"; return; }
            http_ok security.debian.org "/debian-security/dists/${s}/Release"                 && { echo "http://security.debian.org/debian-security ${s}"; return; }
        done
        return
    fi
    http_ok archive.debian.org "/debian/dists/${suite}/Release"         && { echo "http://archive.debian.org/debian ${suite}"; return; }
    http_ok deb.debian.org "/debian/dists/${suite}/Release"         && { echo "http://deb.debian.org/debian ${suite}"; return; }
}

# Components in use today (main contrib non-free ...), from all Debian sources.
current_components() {
    local c
    c=$( { grep -hE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
              | grep -E 'debian\.org|debian-security' | awk '{for(i=4;i<=NF;i++) print $i}'
           grep -hE '^[[:space:]]*Components:' /etc/apt/sources.list.d/*.sources 2>/dev/null | cut -d: -f2 | tr ' ' '\n'
         } | grep -E '^(main|contrib|non-free|non-free-firmware)$' | sort -u | tr '\n' ' ')
    echo "${c:-main}"
}

# write_sources <major>  -> sources.list for that release; 1 if a mirror is missing
write_sources() {
    local major=$1 suite=${CODENAMES[$1]} comps main sec upd archived=0
    comps=$(current_components)
    comps=${comps//non-free-firmware/}
    if (( major >= 12 )) && [[ " $comps " == *" non-free "* ]]; then
        comps="$comps non-free-firmware"     # firmware moved there with bookworm
    fi
    comps=$(echo $comps)                     # squeeze spaces

    main=$(mirror_for "$suite" main)
    [[ -n "$main" ]] || { warn "No mirror has '${suite}' - network or DNS problem?"; return 1; }
    sec=$(mirror_for "$suite" security)
    upd=$(mirror_for "${suite}-updates" main)
    [[ "$main$sec$upd" == *archive.debian.org* ]] && archived=1

    {
        echo "# Written by debian-release-upgrade.sh for Debian ${major} (${suite}), $(date '+%F %T')"
        echo "deb ${main} ${comps}"
        [[ -n "$upd" ]] && echo "deb ${upd} ${comps}"
        [[ -n "$sec" ]] && echo "deb ${sec} ${comps}"
    } > "$SOURCES"

    # Archived releases: their Release files are expired on purpose.
    if (( archived == 1 )); then
        echo 'Acquire::Check-Valid-Until "false";' > "$APT_ARCHIVE_CONF"
    else
        rm -f "$APT_ARCHIVE_CONF"
    fi
    info "Sources for Debian ${major} (${suite}):"
    grep -v '^#' "$SOURCES" | sed 's/^/      /'
    (( archived == 1 )) && echo "      (archived release - signature expiry check disabled for it)"
    if [[ -z "$sec" ]]; then
        warn "No security suite found for ${suite} - end of life, or the mirror"
        warn "did not answer. Without it the system gets NO security updates."
        confirm "Continue without a security source?" || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Archive keys. archive.debian.org is signed with today's keys; the keyring of
# an old release (jessie, stretch) only has its own, by now expired ones - apt
# then rejects the next release as unauthenticated. Fix: the current keyring
# package, fetched over plain HTTP (old systems have neither curl nor wget,
# perl is always there) and accepted ONLY with the SHA256 pinned here, which
# was taken from the signed bookworm archive.
# ---------------------------------------------------------------------------
KEYRING_DEB="debian-archive-keyring_2023.3+deb12u2_all.deb"
KEYRING_SHA256="f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8"
KEYRING_URLS=(
    "deb.debian.org/debian/pool/main/d/debian-archive-keyring/${KEYRING_DEB}"
    "snapshot.debian.org/archive/debian/20250601T000000Z/pool/main/d/debian-archive-keyring/${KEYRING_DEB}"
)
KEYRING_TARGET=/etc/apt/trusted.gpg.d/zz-debian-release-upgrade.gpg

http_get() {   # http_get <host/path> <outfile>  (plain HTTP, body only, 200 only)
    perl -MIO::Socket::INET -e '
        my ($hp, $out) = @ARGV; my ($host, $path) = $hp =~ m{^([^/]+)(/.*)$} or exit 2;
        my $s = IO::Socket::INET->new(PeerAddr => $host, PeerPort => 80, Timeout => 30) or exit 3;
        print $s "GET $path HTTP/1.0\r\nHost: $host\r\nUser-Agent: debian-release-upgrade\r\n\r\n";
        binmode $s; local $/; my $r = <$s>;
        my ($head, $body) = split /\r\n\r\n/, $r, 2;
        exit 4 unless $head =~ m{^HTTP/\S+ 200};
        open my $f, ">", $out or exit 5; binmode $f; print $f $body; close $f;
    ' "$1" "$2"
}

install_current_keyring() {
    local tmp url ok=0
    [[ -f "$KEYRING_TARGET" && -f "${KEYRING_TARGET%.gpg}-removed.gpg" ]] && return 0
    tmp=$(mktemp -d)
    for url in "${KEYRING_URLS[@]}"; do
        if http_get "$url" "$tmp/k.deb" \
           && [[ "$(sha256sum "$tmp/k.deb" | cut -d' ' -f1)" == "$KEYRING_SHA256" ]]; then
            ok=1; break
        fi
    done
    if (( ok == 0 )); then
        rm -rf "$tmp"
        warn "Could not fetch ${KEYRING_DEB} with the expected checksum."
        return 1
    fi
    # Both keyrings of the package: the active keys, and the keys of ended
    # releases (buster ...) that still sign archive.debian.org - Debian keeps
    # those in debian-archive-removed-keys.gpg for exactly this purpose.
    dpkg -x "$tmp/k.deb" "$tmp/x" \
        && cp "$tmp/x/usr/share/keyrings/debian-archive-keyring.gpg" "$KEYRING_TARGET" \
        && cp "$tmp/x/usr/share/keyrings/debian-archive-removed-keys.gpg" "${KEYRING_TARGET%.gpg}-removed.gpg" \
        && chmod 644 "$KEYRING_TARGET" "${KEYRING_TARGET%.gpg}-removed.gpg"
    rm -rf "$tmp"
    [[ -f "$KEYRING_TARGET" ]] || { warn "Extracting the keyring failed."; return 1; }
    info "Current Debian archive keys added (${KEYRING_TARGET}, checksum verified)."
}

# apt-get update; on missing/expired archive keys add the current keyring and
# retry. Returns 2 when a source stays unverifiable ("GPG error") - an extra
# signature by an unknown key is only a warning and fine.
apt_update() {
    local out rc
    out=$(apt-get update 2>&1); rc=$?
    echo "$out" | tail -n 4
    if grep -qE 'GPG error|NO_PUBKEY|KEYEXPIRED|EXPKEYSIG|is not signed' <<<"$out"; then
        if [[ ! -f "${KEYRING_TARGET%.gpg}-removed.gpg" ]]; then
            info "Archive signature not verifiable with the installed keys - adding the current ones."
            install_current_keyring || return 2
            out=$(apt-get update 2>&1); rc=$?
            echo "$out" | tail -n 4
        fi
        if grep -qE 'GPG error|is not signed' <<<"$out"; then
            warn "Signatures not verifiable:"; grep -E 'GPG error|is not signed' <<<"$out"
            return 2
        fi
    fi
    return $rc
}

# Debian entries outside sources.list (deb822 debian.sources, old *.list) are
# moved aside so they do not pull the old release back in.
# Debian's own mirrors - in a .list or a deb822 .sources file (debian.sources,
# the default from bookworm on in images and cloud installs).
DEBIAN_SRC_RE='deb\.debian\.org|security\.debian\.org|ftp\.[a-z.]*debian\.org|archive\.debian\.org|/debian-security'

disable_other_debian_sources() {
    local f
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -qE "$DEBIAN_SRC_RE" "$f"; then
            mv -f "$f" "${f}.release-upgrade-disabled"
            info "Moved aside (Debian source, now in sources.list): ${f}"
        fi
    done
}

third_party_sources() {
    local f
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        grep -qE '^[[:space:]]*(deb|Types:)' "$f" || continue
        # Debian's own (debian.sources): not third-party - it is replaced by
        # sources.list in step 1, not switched off as foreign.
        grep -qE "$DEBIAN_SRC_RE" "$f" && continue
        echo "$f"
    done
}

# Third-party sources to switch off - chosen in preflight, done only after the
# final "Start the upgrade?", so that saying no there leaves apt untouched.
TP_DISABLE=""

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
preflight() {
    local cur=$1 ok=1 free_var free_boot
    echo
    echo "--- Checks ---"

    if [[ -z "${STY:-}${TMUX:-}" && -n "${SSH_CONNECTION:-}" ]]; then
        warn "Not inside screen/tmux. If the SSH connection drops, the upgrade"
        warn "dies halfway - that can leave the system unbootable. Start with:"
        warn "    screen -S upgrade   (or: tmux new -s upgrade)"
        confirm "Continue WITHOUT screen/tmux anyway?" || exit 1
    fi

    free_var=$(df -Pm /var 2>/dev/null | awk 'NR==2 {print $4}')
    free_boot=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')
    echo "  free space: /var ${free_var:-?} MB, /boot ${free_boot:-?} MB"
    (( ${free_var:-0} < 3000 )) && { warn "Less than 3 GB free in /var - the downloads may not fit."; ok=0; }
    (( ${free_boot:-1000} < 150 )) && { warn "Less than 150 MB free in /boot - the new kernel may not fit (apt autoremove helps)."; ok=0; }

    if dpkg --audit 2>/dev/null | grep -q .; then
        warn "dpkg reports half-installed packages ('dpkg --audit'). Fix that first:"
        warn "    dpkg --configure -a && apt-get -f install"
        ok=0
    fi

    local held; held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    if [[ -n "$held" ]]; then
        warn "Packages on hold (block the upgrade or stay old): ${held}"
        ok=0
    fi

    if ! dpkg -l 'linux-image-*' 2>/dev/null | awk '$1=="ii" {print $2}' | grep -qE '^linux-image-(amd64|arm64|686|686-pae|cloud-amd64|cloud-arm64|rt-amd64|armmp|marvell)$'; then
        if dpkg -l 'linux-image-*' 2>/dev/null | grep -q '^ii'; then
            warn "No kernel meta package (e.g. linux-image-amd64): the kernel would"
            warn "NOT be upgraded. Install it: apt-get install linux-image-amd64"
            ok=0
        else
            echo "  no kernel package (container/LXC) - fine, the host's kernel counts"
        fi
    fi

    # bookworm installs usrmerge, trixie requires a merged /usr. The conversion
    # runs on normal file systems, but refuses on overlayfs (containers).
    if (( cur + 1 >= 12 )) && [[ ! -L /bin ]]; then
        echo "  /usr is not merged yet - usrmerge converts it during this step"
        if [[ "$(stat -f -c %T / 2>/dev/null)" == "overlayfs" ]]; then
            warn "Root file system is overlayfs (container): usrmerge will refuse to"
            warn "convert it and the upgrade stops. Convert the image instead."
            ok=0
        fi
    fi

    local tp; tp=$(third_party_sources | grep -vE 'release-upgrade-disabled' || true)
    if [[ -n "$tp" ]]; then
        echo
        warn "Third-party sources (Docker, PHP, Node, ...):"
        echo "$tp" | sed 's/^/      /'
        warn "They still point to ${CODENAMES[$cur]} and can block or break the upgrade."
        if confirm "Disable them for the upgrade (renamed to .release-upgrade-disabled; re-enable with the new codename afterwards)?" Y; then
            TP_DISABLE=$tp
        else
            ok=0
        fi
    fi

    (( ok == 1 )) && echo "  ok" || { echo; confirm "Some checks failed. Continue anyway?" || exit 1; }
}

backup_state() {
    local ts=$1 dir="$STATE_DIR/backup-$1"
    mkdir -p "$dir"
    cp -a /etc/apt/sources.list /etc/apt/sources.list.d "$dir/" 2>/dev/null || true
    dpkg --get-selections > "$dir/dpkg-selections.txt" 2>/dev/null || true
    apt-mark showmanual > "$dir/apt-manual.txt" 2>/dev/null || true
    tar czf "$dir/etc.tar.gz" -C / etc 2>/dev/null || warn "Backup of /etc incomplete."
    info "Backup: ${dir} (sources, package selection, /etc)"
}

conf_files_to_review() {
    find /etc -xdev \( -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-dist' \) -newer "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# One step
# ---------------------------------------------------------------------------
apt_run() {   # apt_run <description> <apt-get args...>
    local what=$1; shift
    info "$what"
    if ! apt-get "${APT_OPTS[@]}" "$@"; then
        warn "'apt-get $*' failed."
        warn "Fix the cause, then: dpkg --configure -a && apt-get -f install,"
        warn "and run this script again - it continues where it stopped."
        return 1
    fi
}

do_step() {
    local cur=$1
    local next=$((cur + 1)) ts stamp
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    stamp="$STATE_DIR/started-${ts}"; touch "$stamp"

    echo
    echo "==========================================================="
    echo " Debian ${cur} (${CODENAMES[$cur]})  ->  Debian ${next} (${CODENAMES[$next]})"
    echo "==========================================================="
    echo "Read the release notes before every step:"
    echo "  https://www.debian.org/releases/${CODENAMES[$next]}/releasenotes"
    echo "Have a snapshot / backup and the provider's console at hand."
    echo "Services restart, the server needs a reboot afterwards."
    preflight "$cur"
    confirm "Start the upgrade to Debian ${next} now?" || exit 0

    backup_state "$ts"
    if [[ -n "$TP_DISABLE" ]]; then
        local f
        while read -r f; do
            mv -f "$f" "${f}.release-upgrade-disabled"
            info "Disabled for the upgrade: ${f}"
        done <<<"$TP_DISABLE"
    fi

    # 1. current release up to date (fixes broken sources of archived releases too)
    disable_other_debian_sources
    info "Step 1/3: bring Debian ${cur} fully up to date"
    write_sources "$cur" || return 1
    local urc=0
    apt_update || urc=$?
    if (( urc == 2 )); then
        # jessie: its archive is only signed with keys that expired years ago.
        # Its updates are skipped - the next release replaces those packages
        # anyway, and that one IS verifiable with the current keys.
        warn "Debian ${cur} is only signed with expired keys - its own updates are"
        warn "skipped; the upgrade to ${next} brings newer packages anyway."
    elif (( urc != 0 )); then
        warn "apt-get update failed (see above)."; return 1
    else
        apt_run "upgrade (current release)" dist-upgrade || return 1
    fi

    # 2. sources of the next release
    info "Step 2/3: switch the sources to Debian ${next}"
    write_sources "$next" || return 1
    apt_update || { warn "apt-get update for ${CODENAMES[$next]} failed."; return 1; }

    # 3. minimal upgrade first, then the full one (as the release notes say)
    info "Step 3/3: upgrade to Debian ${next}"
    apt_run "minimal upgrade" upgrade || return 1
    apt_run "full upgrade" dist-upgrade || return 1

    local now; now=$(current_major)
    if [[ "$now" != "$next" ]]; then
        warn "/etc/debian_version says '${now}' - expected ${next}. Check the output above."
        return 1
    fi
    echo "${next}|$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)|$(date '+%F %T')" > "$STATE_DIR/last-step"
    # From bookworm on the system's own keyring is current - drop the helper.
    if (( next >= 12 )) && [[ -f "$KEYRING_TARGET" ]]; then
        rm -f "$KEYRING_TARGET" "${KEYRING_TARGET%.gpg}-removed.gpg"; info "Temporary archive keyring removed (own keyring is current now)."
    fi

    echo
    info "Debian ${next} (${CODENAMES[$next]}) installed: $(cat /etc/debian_version)"
    local cf; cf=$(conf_files_to_review "$stamp")
    if [[ -n "$cf" ]]; then
        echo
        echo "Your configuration was kept; the package maintainers' new versions are"
        echo "next to it - compare and merge where it matters (sshd, nginx, php ...):"
        echo "$cf" | sed 's/^/      /'
    fi
    echo
    echo "Afterwards:"
    echo "  - re-enable third-party sources with the new codename '${CODENAMES[$next]}'"
    echo "    (files *.release-upgrade-disabled in /etc/apt/sources.list.d)"
    echo "  - remove obsolete packages: apt-get autoremove (after checking the list)"
    if (( next < TARGET )); then
        echo "  - REBOOT, then run this script again for Debian $((next + 1))"
    fi
    rm -f "$stamp"
    echo
    if confirm "Reboot now?" Y; then
        reboot
    else
        echo "Reboot before the next step - the new kernel and libc need it."
    fi
}

status() {
    local cur; cur=$(current_major)
    echo "OS:       $(os_id) $(cat /etc/debian_version 2>/dev/null)"
    echo "Kernel:   $(uname -r)"
    if [[ -z "$cur" ]]; then echo "Release:  testing/unstable - not supported"; return; fi
    echo "Release:  Debian ${cur} (${CODENAMES[$cur]:-unknown})"
    if (( cur >= TARGET )); then
        echo "Next:     nothing - target ${TARGET} reached"
    else
        echo "Next:     Debian $((cur + 1)) (${CODENAMES[$((cur + 1))]})$( (( cur + 1 < TARGET )) && echo ", then up to ${TARGET} - one step per run")"
    fi
    [[ -f "$STATE_DIR/last-step" ]] && echo "Last run: $(cut -d'|' -f1,3 "$STATE_DIR/last-step" | sed 's/|/ on /')"
    if [[ -f /var/run/reboot-required ]] || needs_reboot; then echo "!!! Reboot pending."; fi
}

# True when the last step finished in this boot (no reboot since).
needs_reboot() {
    [[ -f "$STATE_DIR/last-step" ]] || return 1
    local bid; bid=$(cut -d'|' -f2 "$STATE_DIR/last-step")
    [[ -n "$bid" && "$bid" == "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
REBOOT_CHECK=1
while (( $# > 0 )); do
    case "$1" in
        --to)       TARGET=${2:-}; shift 2
                    [[ "$TARGET" =~ ^(9|10|11|12|13)$ ]] || die "--to needs 9..13" ;;
        --status)   status; exit 0 ;;
        --no-reboot-check) REBOOT_CHECK=0; shift ;;   # for tests in containers
        *)          die "Usage: $0 [--to N] [--status] [--version]" ;;
    esac
done

[[ "$(os_id)" == "debian" ]] || die "Not Debian ($(os_id)). Ubuntu: do-release-upgrade."
CUR=$(current_major)
[[ -n "$CUR" ]] || die "testing/unstable ($(cat /etc/debian_version)) - not a release, not supported."
(( CUR >= 8 )) || die "Debian ${CUR} is older than 8 - not supported by this script."

status
echo
if (( CUR >= TARGET )); then
    echo "Nothing to do."
    exit 0
fi
if (( REBOOT_CHECK == 1 )) && needs_reboot; then
    die "The last step finished in this boot - reboot first, then run again."
fi

exec 9>"$LOCK"
flock -w 900 9 || die "auto-update is running (lock ${LOCK}) - try again later."

LOGFILE="$LOG_DIR/upgrade-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
echo "Log: ${LOGFILE}"
do_step "$CUR" 2>&1 | tee -a "$LOGFILE"
exit "${PIPESTATUS[0]}"
