#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# image-check.sh - alerts on critical vulnerabilities in the base images of
# the running containers, for which a fix exists.
#
# apt keeps the server's own packages current - not the images the containers
# run from. This check looks at the OS packages of each image's base layer
# (Debian, Alpine, Ubuntu, ...) with Trivy and reports the CRITICAL ones that
# are fixed in a newer package - i.e. "a newer base image would close it":
# rebuild the image, or pull a newer tag. It only reports; it never pulls,
# rebuilds or restarts anything. The application's own libraries are not part
# of it.
#
# Nightly by cron, a mail only when the findings change (new ones, or gone).
# The images are scanned locally; Trivy downloads its vulnerability database
# (ghcr.io/aquasecurity), nothing is uploaded.
#
# Usage: sudo ./image-check.sh --setup        install Trivy, schedule, first check
#        sudo ./image-check.sh --check        check now and show the findings
#        sudo ./image-check.sh --status       one line: last check, findings
#        sudo ./image-check.sh --uninstall    remove the schedule (Trivy stays)
#        sudo ./image-check.sh --version
#
# Presets (e.g. from base-setup.sh): DEFAULT_MAIL_TO (address(es), '-' = none),
# DEFAULT_TIME (HH:MM, default 04:30 - after the update night window). With
# BATCH=1 nothing is asked.
#
# Exit code: --check 0 nothing found, 1 findings, 2 the check could not run;
#            --status 0 nothing found, 1 findings, 3 not set up.
set -uo pipefail

VERSION="3.0.0"
if [[ "${1:-}" == "--version" ]]; then echo "$(basename "$0") $VERSION"; exit 0; fi
usage() { sed -n '/^# Usage:/,/^# Exit code/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; }
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Started from a version directory (<base>/<version>/, see build-bundle.sh):
# paths written into cron and systemd go through <base>/current, so an update
# or a rollback switches them along.
if [[ -L "$DIR/../current" && "$(readlink -f "$DIR/../current")" == "$(readlink -f "$DIR")" ]]; then
    DIR="$(cd "$DIR/../current" && pwd)"
fi
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")"
CONF="$DIR/image-check.conf"
DATA="$DIR/var/image-check"
FINDINGS="$DATA/findings"       # image|os|CVE|package|installed|fixed
LAST="$DATA/last"               # epoch images findings images-with errors
CACHE="$DATA/trivy-cache"
CRON_FILE=/etc/cron.d/image-check
LOCK_FILE=/run/image-check.lock
TRIVY_KEYRING=/usr/share/keyrings/trivy.gpg
TRIVY_LIST=/etc/apt/sources.list.d/trivy.list
TRIVY_REPO="https://aquasecurity.github.io/trivy-repo/deb"
SEVERITY=CRITICAL

MAIL_TO="" TIME="04:30"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"
[[ -n "${DEFAULT_MAIL_TO:-}" ]] && MAIL_TO=$DEFAULT_MAIL_TO
[[ "$MAIL_TO" == "-" ]] && MAIL_TO=""
[[ -n "${DEFAULT_TIME:-}" ]] && TIME=$DEFAULT_TIME

preset() { [[ -n "${1:-}" && -n "${!1:-}" ]]; }
# ask VAR "Question" [default] [DEFAULT_NAME] - the answer lands in VAR
ask() {
    local __v=$1 __q=$2 __d=${3:-} __p=${4:-} __a
    if preset "$__p"; then printf -v "$__v" '%s' "${!__p}"; echo "${__q}: ${!__p} (preset)"; return 0; fi
    if [[ -n "${BATCH:-}" ]]; then printf -v "$__v" '%s' "$__d"; echo "${__q}: ${__d:--}"; return 0; fi
    read -rp "${__q}${__d:+ [${__d}]}: " __a || return 1
    printf -v "$__v" '%s' "${__a:-$__d}"
}

is_setup() { [[ -f "$CRON_FILE" ]]; }
docker_up() { command -v docker &>/dev/null && systemctl is-active --quiet docker; }

# Trivy from its apt repository (auto-update treats it as a third-party
# source: new versions within the same minor are safe updates), jq for its
# JSON.
install_tools() {
    local need=()
    command -v jq &>/dev/null || need+=(jq)
    if ! command -v trivy &>/dev/null; then
        echo ">>> Adding the Trivy repository (${TRIVY_REPO})"
        command -v gpg &>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg </dev/null >/dev/null 2>&1
        command -v curl &>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl </dev/null >/dev/null 2>&1
        curl -fsSL "${TRIVY_REPO}/public.key" | gpg --dearmor --yes -o "$TRIVY_KEYRING" \
            || { echo "!!! the Trivy signing key could not be loaded." >&2; return 1; }
        echo "deb [signed-by=${TRIVY_KEYRING}] ${TRIVY_REPO} generic main" > "$TRIVY_LIST"
        need+=(trivy)
    fi
    (( ${#need[@]} == 0 )) && return 0
    echo ">>> Installing: ${need[*]}"
    apt-get update -qq </dev/null >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" </dev/null >/dev/null 2>&1 \
        || { echo "!!! could not install: ${need[*]}" >&2; return 1; }
}

write_cron() {
    local h=$((10#${TIME%%:*})) m=$((10#${TIME##*:}))
    {
        echo "# image-check - critical, fixable vulnerabilities in container base images (written by ${SELF})"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "${m} ${h} * * * root flock -n ${LOCK_FILE} ${SELF} --cron >/dev/null 2>&1"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
}

save_conf() {
    { echo "# image-check configuration (image-check.sh ${VERSION})"
      printf 'MAIL_TO="%s"\nTIME="%s"\n' "$MAIL_TO" "$TIME"; } > "$CONF"
    chmod 644 "$CONF"
}

# report <findings file> - per image: base OS, the findings, what to do
report() {
    local f=$1 img os
    [[ -s "$f" ]] || { echo "No critical vulnerabilities with a fix in the base images."; return 0; }
    cut -d'|' -f1,2 "$f" | sort -u | while IFS='|' read -r img os; do
        echo "${img} (${os}) - $(grep -c "^${img}|" "$f") critical, fixed in newer packages:"
        grep "^${img}|" "$f" | awk -F'|' '{printf "  %-18s %-24s %s -> %s\n", $3, $4, $5, $6}'
        echo "  -> rebuild the image, or pull a newer tag"
        echo
    done
}

# check [cron] - scan, compare with the last findings, mail on a change
check() {
    local mode=${1:-} img out err nimg=0 errs=() new tmp host added gone
    mkdir -p "$DATA" "$CACHE"
    if ! docker_up; then
        echo "Docker is not running - no containers to check."
        echo "$(date +%s) 0 0 0 0" > "$LAST"
        return 0
    fi
    command -v trivy &>/dev/null && command -v jq &>/dev/null \
        || { echo "!!! trivy or jq missing - run: sudo ${SELF} --setup" >&2; return 2; }
    new=$(mktemp); err=$(mktemp)
    while read -r img; do
        [[ -n "$img" ]] || continue
        nimg=$((nimg + 1))
        if ! out=$(trivy image --quiet --scanners vuln --pkg-types os --severity "$SEVERITY" \
                     --ignore-unfixed --format json --cache-dir "$CACHE" "$img" 2>"$err"); then
            errs+=("${img}: $(tail -1 "$err")")
            continue
        fi
        jq -r --arg img "$img" '
            (.Metadata.OS // {}) as $os
            | .Results[]? | .Vulnerabilities[]?
            | [$img, ((($os.Family // "?") + " " + ($os.Name // "")) | rtrimstr(" ")),
               .VulnerabilityID, .PkgName, .InstalledVersion, (.FixedVersion // "")]
            | join("|")' <<<"$out" >> "$new"
    done < <(docker ps --format '{{.Image}}' | sort -u)
    sort -u -o "$new" "$new"
    touch "$FINDINGS"
    added=$(comm -13 "$FINDINGS" "$new" | wc -l)
    gone=$(comm -23 "$FINDINGS" "$new" | wc -l)
    tmp=$(mktemp)
    {
        echo "Container base images on $(hostname -f 2>/dev/null || hostname): ${nimg} image(s) checked"
        echo "(OS packages of the base image, ${SEVERITY}, only with a fix available)"
        echo
        report "$new"
        if (( added + gone > 0 )); then echo "Since the last check: ${added} new, ${gone} gone."; fi
        if (( ${#errs[@]} > 0 )); then echo; echo "Could not be checked:"; printf '  %s\n' "${errs[@]}"; fi
    } > "$tmp"
    [[ "$mode" == cron ]] || cat "$tmp"
    if (( added + gone > 0 || ${#errs[@]} > 0 )) && [[ "$mode" == cron && -n "$MAIL_TO" ]] && command -v mail &>/dev/null; then
        host=$(hostname -f 2>/dev/null || hostname)
        if (( added > 0 )); then
            mail -s "[ALERT] image-check ${host}: ${added} new critical base image finding(s)" "$MAIL_TO" < "$tmp" || true
        elif (( ${#errs[@]} > 0 && added + gone == 0 )); then
            mail -s "[ERROR] image-check ${host}: ${#errs[@]} image(s) could not be checked" "$MAIL_TO" < "$tmp" || true
        else
            mail -s "image-check ${host}: ${gone} finding(s) gone, $(wc -l < "$new") left" "$MAIL_TO" < "$tmp" || true
        fi
    fi
    mv "$new" "$FINDINGS"
    echo "$(date +%s) ${nimg} $(wc -l < "$FINDINGS") $(cut -d'|' -f1 "$FINDINGS" | sort -u | grep -c .) ${#errs[@]}" > "$LAST"
    rm -f "$tmp" "$err"
    (( ${#errs[@]} > 0 && nimg == ${#errs[@]} )) && return 2
    [[ -s "$FINDINGS" ]] && return 1
    return 0
}

status() {
    is_setup || { echo "not set up"; return 3; }
    local t n f w e
    read -r t n f w e < "$LAST" 2>/dev/null || { echo "set up, nightly at ${TIME} - no check yet"; return 0; }
    local when; when=$(date -d "@${t}" '+%F %H:%M' 2>/dev/null)
    if (( f > 0 )); then
        echo "nightly at ${TIME}, last ${when}: ${w} of ${n} image(s) with ${f} critical fixable finding(s)$( (( e > 0 )) && echo ", ${e} not checked")"
        return 1
    fi
    echo "nightly at ${TIME}, last ${when}: ${n} image(s), no critical base image findings$( (( e > 0 )) && echo ", ${e} not checked")"
    return 0
}

setup() {
    echo ">>> Image check: critical vulnerabilities with a fix in the base images"
    echo "    of the running containers - nightly, a mail when the findings change."
    install_tools || return 1
    ask MAIL_TO "Mail findings to ('-' = none)" "$MAIL_TO" DEFAULT_MAIL_TO
    [[ "$MAIL_TO" == "-" ]] && MAIL_TO=""
    ask TIME "Time of the nightly check (HH:MM)" "$TIME" DEFAULT_TIME
    [[ "$TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "!!! '${TIME}' is no time HH:MM" >&2; return 1; }
    save_conf
    write_cron
    echo ">>> Scheduled: daily at ${TIME}$( [[ -n "$MAIL_TO" ]] && echo ", mail to ${MAIL_TO}")"
    echo ">>> First check (Trivy downloads its database first - this takes a while)"
    check; local rc=$?
    (( rc == 2 )) && return 1
    return 0
}

uninstall() {
    rm -f "$CRON_FILE" "$CONF"
    rm -rf "$DATA"
    echo "Removed: schedule, configuration, findings."
    echo "Trivy stays installed - to remove it: apt purge trivy && rm -f ${TRIVY_LIST} ${TRIVY_KEYRING}"
}

case "${1:-}" in
    --setup)     setup ;;
    --check)     check ;;
    --cron)      check cron ;;
    --status)    status ;;
    --uninstall) uninstall ;;
    *)           usage; exit 1 ;;
esac
