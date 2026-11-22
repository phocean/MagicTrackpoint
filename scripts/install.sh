#!/bin/bash
# MagicTrackpoint installer (per user, no root, no network, no certificates).
#
#   scripts/install.sh                  build, test, sign, install, start
#   scripts/install.sh --check          build, test, sign and verify into build/ only
#   scripts/install.sh --prebuilt FILE  install an already built daemon (release
#                                       DMG): no build, no Xcode tools needed; FILE
#                                       must carry a valid Developer ID signature
#
# Environment (all optional):
#   MTP_SIGN_IDENTITY  codesign identity (SHA-1 or name, "-" = ad hoc).
#                      Default: first "Developer ID Application:", else first
#                      "Apple Development:" identity of the keychain, else ad hoc.
#   MTP_HOME           install root instead of $HOME (tests)
#   MTP_LAUNCHCTL      launchctl command (tests)
#   MTP_SKIP_BUILD=1   skip build, tests and signing; install $MTP_PREBUILT (tests)
#   MTP_PREBUILT       path of the prebuilt daemon used with MTP_SKIP_BUILD=1

# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

LABEL=com.jcbaptiste.magictrackpoint
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MTP_HOME=${MTP_HOME:-$HOME}
LAUNCHCTL=${MTP_LAUNCHCTL:-launchctl}

BIN_DIR=$MTP_HOME/.local/bin
DAEMON=$BIN_DIR/magictrackpointd
CTL=$BIN_DIR/magictrackpointctl
AGENT_DIR=$MTP_HOME/Library/LaunchAgents
AGENT=$AGENT_DIR/$LABEL.plist
CONFIG_DIR=$MTP_HOME/.config/magictrackpoint
CONFIG=$CONFIG_DIR/config.plist

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

CHECK_ONLY=0
PREBUILT=""
while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK_ONLY=1 ;;
        --prebuilt)
            [ $# -ge 2 ] || die "--prebuilt needs a file (see --help)"
            PREBUILT=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[ -z "$PREBUILT" ] || [ "$CHECK_ONLY" = 0 ] || die "--check and --prebuilt cannot be combined"

[ "$(id -u)" -ne 0 ] || die "do not run as root: MagicTrackpoint is a per-user agent"
case $MTP_HOME in
    /*) ;;
    *) die "MTP_HOME must be an absolute path: $MTP_HOME" ;;
esac
case $MTP_HOME in
    *$'\n'*) die "MTP_HOME must not contain a newline" ;;
esac
UID_NUM=$(id -u)
DOMAIN=gui/$UID_NUM
SERVICE=$DOMAIN/$LABEL

TMP_FILES=()
PRIVATE_DIR=""
cleanup() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$f"; done
    [ -z "$PRIVATE_DIR" ] || rm -rf "$PRIVATE_DIR"
}
trap cleanup EXIT

# Sets TMPF to a new temp file in directory $1, so that the final mv is an
# atomic rename on the same file system. Removed on exit if still there.
tmp_in() {
    TMPF=$(mktemp "$1/.mtp-install.XXXXXX")
    TMP_FILES+=("$TMPF")
}

# Escape a string for use as XML character data.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# Replace every @DAEMON_PATH@ in template $1 with the literal string $2.
# awk + ENVIRON: no regex or backslash interpretation of the replacement.
render_template() {
    MTP_REPL=$2 awk '{
        out = ""; line = $0; key = "@DAEMON_PATH@"
        while ((i = index(line, key)) > 0) {
            out = out substr(line, 1, i - 1) ENVIRON["MTP_REPL"]
            line = substr(line, i + length(key))
        }
        print out line
    }' "$1"
}

is_loaded() { "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; }

# launchctl bootout returns before the job is fully gone; wait up to 5 s.
wait_unloaded() {
    local n=0
    while is_loaded; do
        n=$((n + 1))
        [ "$n" -le 50 ] || die "$LABEL is still loaded after bootout"
        sleep 0.1
    done
}

# Prints "<sha1>\t<name>" for the first valid codesigning identity whose name
# starts with $1, or nothing.
find_identity() {
    printf '%s\n' "$IDENTITIES" | awk -v p="\"$1" 'index($0, p) {
        n = $0; sub(/^[^"]*"/, "", n); sub(/"[^"]*$/, "", n)
        print $2 "\t" n; exit
    }'
}

choose_identity() {
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    local found=""
    if [ -n "${MTP_SIGN_IDENTITY:-}" ]; then
        SIGN_ID=$MTP_SIGN_IDENTITY
        if [ "$SIGN_ID" != "-" ]; then
            found=$(printf '%s\n' "$IDENTITIES" | grep -F -- "$SIGN_ID" | head -n 1 \
                    | awk '{ n = $0; sub(/^[^"]*"/, "", n); sub(/"[^"]*$/, "", n); print $2 "\t" n }' || true)
            if [ -n "$found" ]; then
                say "Signing identity (MTP_SIGN_IDENTITY): SHA-1 ${found%%$'\t'*}  ${found#*$'\t'}"
            else
                say "Signing identity (MTP_SIGN_IDENTITY): $SIGN_ID (not in the valid identity list; codesign will resolve it)"
            fi
            return
        fi
    else
        found=$(find_identity "Developer ID Application:")
        [ -n "$found" ] || found=$(find_identity "Apple Development:")
        if [ -n "$found" ]; then
            SIGN_ID=${found%%$'\t'*}
            say "Signing identity: SHA-1 $SIGN_ID  ${found#*$'\t'}"
            return
        fi
        SIGN_ID="-"
    fi
    say "Signing identity: ad hoc (-)"
    warn "ad hoc signature: macOS ties the Accessibility and Input Monitoring"
    warn "grants to this exact build. After EVERY reinstall you will have to"
    warn "grant them again (remove the old entry first). A \"Developer ID"
    warn "Application\" or \"Apple Development\" certificate in your keychain avoids it."
}

# A release binary must be signed with a Developer ID Application certificate
# (Apple anchor, Developer ID intermediate and leaf) of the release team, for
# this identifier: that is what keeps the macOS permissions across updates and
# what Gatekeeper and notarization accept. Anything else (ad hoc, Apple
# Development, another team or identifier, a modified file) is refused.
# RELEASE_TEAM is the official releases' team; scripts/make-dmg.sh writes the
# team of its own signing certificate here in the copy it packs.
RELEASE_TEAM=26N2RN6N67
DEVELOPER_ID_REQ="=anchor apple generic and identifier \"$LABEL\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$RELEASE_TEAM\""

verify_release_signature() {
    codesign --verify --strict -R "$DEVELOPER_ID_REQ" "$1" 2>/dev/null \
        || die "$1 is not signed with the Developer ID Application certificate of team $RELEASE_TEAM for $LABEL (or was modified)"
}

build_and_sign() {
    if [ -n "$PREBUILT" ]; then
        case $PREBUILT in /*) ;; *) PREBUILT=$PWD/$PREBUILT ;; esac
        [ -f "$PREBUILT" ] && [ -x "$PREBUILT" ] || die "not an executable file: $PREBUILT"
        # Verify, run and install one private copy, never the original path:
        # a file swapped after the check could otherwise be run or installed.
        PRIVATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mtp-prebuilt.XXXXXX")
        cp "$PREBUILT" "$PRIVATE_DIR/magictrackpointd"
        BUILT=$PRIVATE_DIR/magictrackpointd
        verify_release_signature "$BUILT"
        say "Prebuilt daemon $("$BUILT" --version 2>/dev/null || echo '?'), Developer ID team $RELEASE_TEAM"
        return
    fi
    if [ "${MTP_SKIP_BUILD:-0}" = 1 ]; then
        [ -n "${MTP_PREBUILT:-}" ] || die "MTP_SKIP_BUILD=1 requires MTP_PREBUILT=<path to the daemon>"
        [ -f "$MTP_PREBUILT" ] && [ -x "$MTP_PREBUILT" ] || die "not an executable file: $MTP_PREBUILT"
        BUILT=$MTP_PREBUILT
        say "MTP_SKIP_BUILD=1: using prebuilt $BUILT (no build, tests or signing)"
        return
    fi
    command -v clang >/dev/null 2>&1 || die "clang not found: install the Xcode Command Line Tools (xcode-select --install)"
    say "Building"
    make -C "$ROOT"
    say "Testing"
    make -C "$ROOT" test
    choose_identity
    say "Signing and verifying"
    make -C "$ROOT" sign SIGN_IDENTITY="$SIGN_ID"
    BUILT=$ROOT/build/magictrackpointd
}

# Copy $1 to $2 through a temp file in the same directory, then rename.
install_file() {
    local src=$1 dst=$2 mode=$3
    tmp_in "$(dirname "$dst")"
    cp "$src" "$TMPF"
    chmod "$mode" "$TMPF"
    mv -f "$TMPF" "$dst"
}

warn_legacy() {
    if pgrep -i -x trackpointd >/dev/null 2>&1; then
        warn "the legacy TrackPointD app (process \"trackpointd\") is running."
        warn "Two daemons driving the same keyboard conflict: quit TrackPointD and"
        warn "remove it from System Settings > General > Login Items."
    fi
}

# ---------------------------------------------------------------------------

build_and_sign

if [ "$CHECK_ONLY" = 1 ]; then
    say "Check OK: $BUILT is built, tested, signed and verified. Nothing installed."
    exit 0
fi

warn_legacy

for f in "$ROOT/tools/magictrackpointctl" "$ROOT/launchd/$LABEL.plist.in" "$ROOT/config/config.example.plist"; do
    [ -f "$f" ] || die "missing file: $f"
done

if is_loaded; then
    say "Stopping the running agent"
    "$LAUNCHCTL" bootout "$SERVICE" || die "launchctl bootout $SERVICE failed"
    wait_unloaded
fi

say "Installing $DAEMON and $CTL"
mkdir -p "$BIN_DIR" "$AGENT_DIR" "$CONFIG_DIR"
install_file "$BUILT" "$DAEMON" 755
if [ -n "$PREBUILT" ]; then
    verify_release_signature "$DAEMON"
elif [ "${MTP_SKIP_BUILD:-0}" != 1 ]; then
    codesign --verify --strict "$DAEMON" || die "installed daemon fails signature verification"
fi
install_file "$ROOT/tools/magictrackpointctl" "$CTL" 755

say "Writing $AGENT"
tmp_in "$AGENT_DIR"
render_template "$ROOT/launchd/$LABEL.plist.in" "$(xml_escape "$DAEMON")" > "$TMPF"
plutil -lint -s "$TMPF" || die "generated LaunchAgent does not lint"
got=$(plutil -extract ProgramArguments.0 raw -o - "$TMPF") || die "cannot read back ProgramArguments"
[ "$got" = "$DAEMON" ] || die "LaunchAgent path round-trip mismatch: '$got' != '$DAEMON'"
chmod 644 "$TMPF"
mv -f "$TMPF" "$AGENT"

if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    say "Keeping existing config $CONFIG"
else
    say "Creating config $CONFIG"
    tmp_in "$CONFIG_DIR"
    cp "$ROOT/config/config.example.plist" "$TMPF"
    chmod 644 "$TMPF"
    mv -n "$TMPF" "$CONFIG"   # -n: never clobber, even on a race
fi

say "Starting the agent"
"$LAUNCHCTL" bootstrap "$DOMAIN" "$AGENT" \
    || die "launchctl bootstrap $DOMAIN $AGENT failed (try: magictrackpointctl status)"

cat <<EOF

MagicTrackpoint is installed and started.

One-time permissions (the daemon cannot work without them):
  On first start the daemon asks macOS for both permissions, which usually
  adds "magictrackpointd" to the two lists below: just turn it on.
  1. System Settings > Privacy & Security > Input Monitoring: turn on
     magictrackpointd. If it is not listed, click "+", press Cmd+Shift+G, type
       $DAEMON
     and press Return, then Open. (Cmd+Shift+. shows hidden folders.)
  2. Same in System Settings > Privacy & Security > Accessibility.
  Simplest: run this command, turn on what it opens, and repeat until it
  answers "All permissions granted." (it restarts the daemon, which Input
  Monitoring needs before it takes effect):
       magictrackpointctl permissions

If an older "magictrackpointd" entry is already listed, remove it with "-"
before adding the new one.

Commands: magictrackpointctl status | reload | restart | log | check
Config:   $CONFIG
EOF

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        cat <<EOF

NOTE: $BIN_DIR is not in your PATH. Add this line to ~/.zshrc:
  export PATH="\$PATH:\$HOME/.local/bin"
EOF
        ;;
esac
