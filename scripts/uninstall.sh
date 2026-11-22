#!/bin/bash
# MagicTrackpoint uninstaller. Idempotent: safe when nothing is installed.
#
#   scripts/uninstall.sh           remove agent, binaries, status cache; keep config
#   scripts/uninstall.sh --purge   also remove ~/.config/magictrackpoint
#
# Environment (tests): MTP_HOME (default $HOME), MTP_LAUNCHCTL (default launchctl).

# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

LABEL=com.jcbaptiste.magictrackpoint
MTP_HOME=${MTP_HOME:-$HOME}
LAUNCHCTL=${MTP_LAUNCHCTL:-launchctl}

BIN_DIR=$MTP_HOME/.local/bin
AGENT=$MTP_HOME/Library/LaunchAgents/$LABEL.plist
CACHE_DIR=$MTP_HOME/Library/Caches/$LABEL
CONFIG_DIR=$MTP_HOME/.config/magictrackpoint

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

PURGE=0
for arg in "$@"; do
    case $arg in
        --purge) PURGE=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) die "unknown argument: $arg (see --help)" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "do not run as root: MagicTrackpoint is a per-user agent"
case $MTP_HOME in
    /?*) ;;
    *) die "MTP_HOME must be an absolute path other than /: $MTP_HOME" ;;
esac
SERVICE=gui/$(id -u)/$LABEL

is_loaded() { "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; }

if is_loaded; then
    say "Stopping $LABEL"
    "$LAUNCHCTL" bootout "$SERVICE" || die "launchctl bootout $SERVICE failed"
    n=0
    while is_loaded; do
        n=$((n + 1))
        [ "$n" -le 50 ] || die "$LABEL is still loaded after bootout"
        sleep 0.1
    done
else
    say "$LABEL is not loaded"
fi

remove() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        rm -rf "$1"
        say "Removed $1"
    fi
}

remove "$AGENT"
remove "$BIN_DIR/magictrackpointd"
remove "$BIN_DIR/magictrackpointctl"
remove "$CACHE_DIR"

if [ "$PURGE" = 1 ]; then
    remove "$CONFIG_DIR"
elif [ -e "$CONFIG_DIR/config.plist" ]; then
    say "Kept $CONFIG_DIR/config.plist (use --purge to remove it)"
fi

cat <<EOF

MagicTrackpoint is uninstalled.

The Privacy & Security permissions are not removed automatically. To remove them,
run these two commands yourself:
  tccutil reset Accessibility $LABEL
  tccutil reset ListenEvent $LABEL
If they find no entry (an entry added with "+" is recorded by path), remove
"magictrackpointd" with "-" in System Settings > Privacy & Security >
Accessibility, and in System Settings > Privacy & Security > Input Monitoring.

The daemon switched the keyboard back to its native mode when it stopped.
EOF
