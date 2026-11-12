#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# build-bundle.sh - builds dist/base-setup-bundle-<version>.sh: one
# self-extracting file with base-setup.sh and every tool it calls, for servers
# without a git checkout, plus its .sha256. Runs on Linux and in Git Bash on
# Windows, no root needed. Run it for every release (README: Cutting a
# release); dist/ is not committed.
#
# On the server the bundle installs every version into a directory of its own
# and points "current" at it:
#
#   /opt/server_admin_scripts/
#     3.0.0/              the scripts of that version + the tools' *.conf
#     3.1.0/
#     current -> 3.1.0    cron and systemd run the scripts through this link
#     var/                state, logs, reports - shared by all versions
#
# An update unpacks the new version, copies the tools' *.conf from the current
# one, switches "current" and keeps the last three versions; --rollback
# switches back. base-setup's own configuration (--conf FILE) lives outside.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLS=(base-setup base-tools docker-setup hostname-setup root-password tailscale-setup ssh-setup
       ufw-manager auto-update git-updater mail-setup graph-mailer
       disk-monitor node-exporter-setup anomaly-monitor port-scan-monitor security-check image-check)

cd "$DIR"
files=(VERSION LICENSE README.md base-setup.conf.example)
for t in "${TOOLS[@]}"; do
    files+=("$t.sh")
    [[ -f "docs/$t.md" ]] && files+=("docs/$t.md")
done
for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
    if grep -q $'\r' "$f"; then echo "CRLF line endings in $f - fix before bundling." >&2; exit 1; fi
done

version=$(tr -d '[:space:]' < VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION '${version}' is not X.Y.Z" >&2; exit 1; }
commit=$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$DIR" diff --quiet HEAD -- "${files[@]}" 2>/dev/null || commit="${commit}+changes"
name="base-setup-bundle-${version}.sh"
OUT="$DIR/dist/${name}"

mkdir -p "$DIR/dist"
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
tar --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
    -czf - "${files[@]}" | base64 -w 76 > "$payload"
sum=$(sha256sum "$payload" | cut -d' ' -f1)

{
cat <<EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ${name} - the server baseline in one file.
#
# Contains base-setup.sh and every tool it uses (base-tools, hostname,
# tailscale, ssh, ufw, auto-update, mail, disk-monitor, node exporter, ...),
# version ${version} (${commit}), built $(date -u '+%F %H:%M') UTC.
#
# Usage - download first, then run (not via a pipe, it reads itself):
#   sudo bash ${name} [--conf FILE]     install + guided setup
#   sudo bash ${name} --check           install + status only
#   sudo bash ${name} --extract-only    only install, start nothing
#   sudo bash ${name} --list            the installed versions
#   sudo bash ${name} --rollback [VER]  "current" back to the version before
#                                       (or VER) - nothing is installed
#   ... --dir /path                     other base directory
#
# Layout (base directory /opt/server_admin_scripts):
#   <version>/    the scripts of one version and the tools' *.conf
#   current ->    the version in use - cron and systemd run the scripts from here
#   var/          state, logs, reports - shared by all versions
# An update copies the tools' *.conf from the current version, switches
# "current" and keeps the last three versions.
set -euo pipefail

BUNDLE_VERSION="${version}"
BUNDLE_COMMIT="${commit}"
PAYLOAD_SHA256="${sum}"
EOF
cat <<'EOF'
BASE="/opt/server_admin_scripts"
KEEP=3
MODE=run
ROLL_TO=""
args=()
while (( $# > 0 )); do
    case "$1" in
        --dir)          BASE=${2:?--dir needs a path}; shift 2 ;;
        --extract-only) MODE=extract; shift ;;
        --list)         MODE=list; shift ;;
        --rollback)     MODE=rollback
                        if [[ "${2:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ROLL_TO=$2; shift; fi
                        shift ;;
        --bundle-version) echo "base-setup bundle ${BUNDLE_VERSION} (${BUNDLE_COMMIT})"; exit 0 ;;
        # the setup runs from the base directory - a relative path is made absolute
        --conf)         p=${2:?--conf needs a file}; [[ "$p" == /* ]] || p="$PWD/$p"
                        args+=(--conf "$p"); shift 2 ;;
        *)              args+=("$1"); shift ;;
    esac
done
[[ "$BASE" == /* ]] || BASE="$PWD/$BASE"

versions() {   # the installed versions, oldest first
    local d
    for d in "$BASE"/*/; do
        d=${d%/}; d=${d##*/}
        [[ "$d" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -f "$BASE/$d/base-setup.sh" ]] && echo "$d"
    done | sort -V
    return 0
}
current_version() { local c; c=$(readlink "$BASE/current" 2>/dev/null) || return 0; echo "${c##*/}"; }
switch_to() {   # atomic: a new link, renamed over the old one
    ln -sfn "$1" "$BASE/.current.new"
    mv -Tf "$BASE/.current.new" "$BASE/current"
}

case "$MODE" in
    list)
        cur=$(current_version)
        for v in $(versions); do echo "  ${v}$([[ "$v" == "$cur" ]] && echo "   <- current")"; done
        [[ -n "$(versions)" ]] || echo "  nothing installed in ${BASE}"
        exit 0 ;;
    rollback)
        [[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }
        cur=$(current_version)
        if [[ -z "$ROLL_TO" ]]; then
            ROLL_TO=$(versions | awk -v c="$cur" '$0 == c {print prev; exit} {prev = $0}')
        fi
        [[ -n "$ROLL_TO" && -d "$BASE/$ROLL_TO" ]] || { echo "No version to roll back to (installed: $(versions | tr '\n' ' '))." >&2; exit 1; }
        switch_to "$ROLL_TO"
        echo "current: ${cur:-none} -> ${ROLL_TO}. Cron and systemd run ${ROLL_TO} from now on."
        echo "Its *.conf are the copies from when it was installed - settings changed since stay with ${cur}."
        exit 0 ;;
esac

[[ $EUID -ne 0 ]] && { echo "Please run as root (sudo)." >&2; exit 1; }
SELF="${BASH_SOURCE[0]}"
[[ -f "$SELF" ]] || { echo "Download the bundle to a file first and run it from there (no pipe)." >&2; exit 1; }
for c in tar base64 sha256sum gzip readlink; do
    command -v "$c" &>/dev/null || { echo "Missing: $c" >&2; exit 1; }
done
if [[ -d "$BASE/.git" ]]; then
    echo "!!! $BASE is a git checkout - update it there and start the setup from it:" >&2
    echo "!!!     cd $BASE && git pull && sudo ./base-setup.sh" >&2
    exit 1
fi

line=$(awk '/^__PAYLOAD_BELOW__$/ {print NR + 1; exit}' "$SELF")
[[ -n "$line" ]] || { echo "Bundle damaged: no payload." >&2; exit 1; }
sum=$(tail -n +"$line" "$SELF" | sha256sum | cut -d' ' -f1)
[[ "$sum" == "$PAYLOAD_SHA256" ]] || { echo "Bundle damaged: checksum mismatch." >&2; exit 1; }

cur=$(current_version)
VDIR="$BASE/$BUNDLE_VERSION"
echo ">>> Installing the server tools ${BUNDLE_VERSION} (${BUNDLE_COMMIT}) to ${VDIR}"
[[ -n "$cur" ]] && echo "    current version: ${cur}"
mkdir -p "$BASE" "$BASE/var"
chmod 755 "$BASE"

# Unpack next to it, then rename: a half-unpacked version is never "current".
NEW="$BASE/.new-${BUNDLE_VERSION}"
rm -rf "$NEW"; mkdir -p "$NEW"
tail -n +"$line" "$SELF" | base64 -d | tar -xzf - -C "$NEW" --no-same-owner
chmod 755 "$NEW" "$NEW"/*.sh
ln -s ../var "$NEW/var"
# The tools' own settings (disk-monitor.conf, auto-update.conf, ...): from the
# same version when it is installed again, else from the current one.
for src in "$VDIR" "$BASE/current"; do
    [[ -d "$src" ]] || continue
    for f in "$src"/*.conf; do
        [[ -f "$f" && ! -e "$NEW/${f##*/}" ]] || continue
        cp -a "$f" "$NEW/" && echo "    kept: ${f##*/}"
    done
done
rm -rf "$VDIR"
mv "$NEW" "$VDIR"
switch_to "$BUNDLE_VERSION"
echo "    current -> ${BUNDLE_VERSION}"

# Older versions: the last KEEP stay for a rollback.
old=$(versions | grep -vxF "$BUNDLE_VERSION" | head -n -$((KEEP - 1)) || true)
for v in $old; do
    rm -rf "${BASE:?}/$v" && echo "    removed old version ${v}"
done

# Tools still installed from another directory (an older bundle in
# /opt/server-admin, a git checkout): base-setup.sh offers to take them over.
existing=$(grep -hoE '/[^ ]+/[a-z][a-z0-9-]*\.sh' /etc/cron.d/* 2>/dev/null \
           | xargs -r -n1 dirname | sort -u | grep -vxF "$BASE/current" || true)
if [[ -n "$existing" ]]; then
    echo ">>> Tools from another installation found: $(echo "$existing" | tr '\n' ' ')"
    echo "    The setup asks what to do with them (take over / uninstall / leave)."
fi

if [[ "$MODE" == extract ]]; then
    echo "Done. Start with: sudo ${BASE}/current/base-setup.sh"
    exit 0
fi
cd "$BASE/current"
exec "$BASE/current/base-setup.sh" "${args[@]}"
EOF
echo "exit 0"
echo "__PAYLOAD_BELOW__"
cat "$payload"
} > "$OUT"
chmod 755 "$OUT"
( cd "$DIR/dist" && sha256sum "$name" > "${name}.sha256" )

echo "Built: $OUT"
echo "  version ${version} (${commit}), $(wc -c < "$OUT") bytes, ${#files[@]} files"
echo "  checksum: dist/${name}.sha256"
