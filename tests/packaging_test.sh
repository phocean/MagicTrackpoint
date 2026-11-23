#!/bin/bash
# Packaging tests: install.sh, uninstall.sh, magictrackpointctl, launchd
# template and example config.
#
# Runs entirely in a temporary MTP_HOME with a stub launchctl that only logs
# its arguments. Never touches the real ~, the real launchd, TCC or the
# keychain, and does not need src/ (install.sh runs with MTP_SKIP_BUILD=1 and
# a dummy daemon).

# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LABEL=com.jcbaptiste.magictrackpoint
UID_NUM=$(id -u)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mtp-packaging.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check "description" command...
    local d=$1; shift
    if "$@"; then ok "$d"; else fail "$d"; fi
}
contains() { grep -qF -- "$2" "$1"; }

# --- Fake environment --------------------------------------------------------

# A home path with a space, "&" and "<": exercises XML escaping end to end.
FAKE_HOME="$WORK/home dir & <co>"
mkdir -p "$FAKE_HOME"
export HOME="$WORK/real-home-guard"   # anything that ignores MTP_HOME lands here
mkdir -p "$HOME"
export MTP_HOME="$FAKE_HOME"

STUB_DIR=$WORK/stub
mkdir -p "$STUB_DIR"
STUB_LOG=$STUB_DIR/launchctl.log
: > "$STUB_LOG"
# Stateful stub: bootstrap marks the service loaded, bootout unloads it,
# print succeeds only while loaded (like the real launchctl).
cat > "$STUB_DIR/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case ${1:-} in
    print)
        [ -e "$STUB_STATE" ] || { echo "Could not find service" >&2; exit 113; }
        printf '%s = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n\tendpoints = {\n\t\tstate = active\n\t}\n}\n' "$2" ;;
    bootstrap) : > "$STUB_STATE"
               # Like the daemon at startup: write the status file, if asked to.
               if [ -n "${STUB_PERM_SRC:-}" ]; then cp "$STUB_PERM_SRC" "$STUB_PERM_DST"; fi ;;
    bootout)   rm -f "$STUB_STATE" ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/launchctl"
export STUB_LOG STUB_STATE=$STUB_DIR/loaded
export MTP_LAUNCHCTL=$STUB_DIR/launchctl

# Stub open: only logs the URL.
cat > "$STUB_DIR/open" <<'EOF'
#!/bin/bash
printf 'open %s\n' "$*" >> "$STUB_LOG"
EOF
chmod +x "$STUB_DIR/open"
export MTP_OPEN=$STUB_DIR/open

# Dummy daemon: answers --version and --check-config, records its arguments.
PREBUILT_DIR=$WORK/prebuilt
mkdir -p "$PREBUILT_DIR"
cat > "$PREBUILT_DIR/magictrackpointd" <<'EOF'
#!/bin/bash
case ${1:-} in
    --version) echo "magictrackpointd 0.0.0-dummy" ;;
    --check-config) echo "dummy check-config ${2:-<default>}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$PREBUILT_DIR/magictrackpointd"
export MTP_SKIP_BUILD=1 MTP_PREBUILT=$PREBUILT_DIR/magictrackpointd

BIN=$MTP_HOME/.local/bin
DAEMON=$BIN/magictrackpointd
CTL=$BIN/magictrackpointctl
AGENT=$MTP_HOME/Library/LaunchAgents/$LABEL.plist
CONFIG=$MTP_HOME/.config/magictrackpoint/config.plist
CACHE=$MTP_HOME/Library/Caches/$LABEL
OUT=$WORK/out.txt

run_install()   { bash "$ROOT/scripts/install.sh" "$@" > "$OUT" 2>&1; }
run_uninstall() { bash "$ROOT/scripts/uninstall.sh" "$@" > "$OUT" 2>&1; }
run_ctl()       { bash "$ROOT/tools/magictrackpointctl" "$@" > "$OUT" 2>&1; }

# --- 1. Syntax and lint ------------------------------------------------------

for f in scripts/install.sh scripts/uninstall.sh tools/magictrackpointctl tests/packaging_test.sh; do
    check "bash -n $f" bash -n "$ROOT/$f"
done
check "magictrackpointctl is executable" test -x "$ROOT/tools/magictrackpointctl"
check "plutil -lint launchd template" plutil -lint -s "$ROOT/launchd/$LABEL.plist.in"
check "plutil -lint example config" plutil -lint -s "$ROOT/config/config.example.plist"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck" shellcheck "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" \
        "$ROOT/tools/magictrackpointctl" "$ROOT/tests/packaging_test.sh"
else
    printf 'skip shellcheck (not installed)\n'
fi

ex() { plutil -extract "$1" raw -o - "$ROOT/config/config.example.plist" 2>/dev/null; }
check "example config defaults" test \
    "$(ex trackpoint.sensitivity) $(ex scroll.enabled) $(ex scroll.speed) $(ex scroll.horizontal) $(ex scroll.threshold) $(ex middle_button.click_if_no_scroll) $(ex logging.level)" \
    = "7 true 1.000000 true 3 true error"

# --- 2. Uninstall on an empty home -------------------------------------------

check "uninstall on empty home succeeds" run_uninstall
check "uninstall --purge on empty home succeeds" run_uninstall --purge
check "uninstall did not call bootout when not loaded" sh -c "! grep -q '^bootout' '$STUB_LOG'"
check "uninstall prints the tccutil commands" contains "$OUT" "tccutil reset ListenEvent $LABEL"

# --- 3. --check installs nothing ---------------------------------------------

check "install --check succeeds" run_install --check
check "install --check installs nothing" test ! -e "$MTP_HOME/.local" -a ! -e "$MTP_HOME/Library"
check "install rejects unknown arguments" sh -c "! bash '$ROOT/scripts/install.sh' --bogus >/dev/null 2>&1"
check "install --prebuilt needs a file" sh -c "! bash '$ROOT/scripts/install.sh' --prebuilt >/dev/null 2>&1"
check "install --prebuilt refuses a missing file" \
    sh -c "! bash '$ROOT/scripts/install.sh' --prebuilt '$WORK/nope' >/dev/null 2>&1"
cp "$MTP_PREBUILT" "$WORK/unsigned-daemon"
check "install --prebuilt refuses an unsigned file" \
    sh -c "! (unset MTP_SKIP_BUILD; bash '$ROOT/scripts/install.sh' --prebuilt '$WORK/unsigned-daemon') >'$OUT' 2>&1"
check "install --prebuilt explains the refusal" contains "$OUT" "not signed with the Developer ID Application certificate of team"
cp /usr/bin/true "$WORK/adhoc-daemon" && codesign --force --sign - --identifier "$LABEL" "$WORK/adhoc-daemon" 2>/dev/null
check "install --prebuilt refuses an ad hoc signature, even with the right identifier" \
    sh -c "! (unset MTP_SKIP_BUILD; bash '$ROOT/scripts/install.sh' --prebuilt '$WORK/adhoc-daemon') >/dev/null 2>&1"
check "install --prebuilt refusals installed nothing" test ! -e "$MTP_HOME/.local"
check "install --prebuilt pins the release team" \
    contains "$ROOT/scripts/install.sh" 'certificate leaf[subject.OU] = \"$RELEASE_TEAM\"'
check "make-dmg writes its signing team into the packed installer" \
    contains "$ROOT/scripts/make-dmg.sh" 's/^RELEASE_TEAM=.*/RELEASE_TEAM=$TEAM/'
check "install --prebuilt verifies and installs a private copy" \
    contains "$ROOT/scripts/install.sh" 'BUILT=$PRIVATE_DIR/magictrackpointd'
check "install --prebuilt leaves no private copy behind" \
    sh -c "! ls -d '${TMPDIR:-/tmp}'/mtp-prebuilt.* >/dev/null 2>&1"
check "install rejects --check with --prebuilt" \
    sh -c "! bash '$ROOT/scripts/install.sh' --check --prebuilt /bin/ls >/dev/null 2>&1"

# Disk image applets: the AppleScript sources must compile, and they must call
# the scripts with the arguments those scripts accept.
for applet in Install Uninstall; do
    check "$applet applet compiles" \
        sh -c "osacompile -o '$WORK/$applet.app' '$ROOT/packaging/$applet.applescript' >/dev/null 2>&1"
done
check "Install applet runs install.sh --prebuilt" \
    contains "$ROOT/packaging/Install.applescript" "scripts/install.sh --prebuilt bin/magictrackpointd"
check "Install applet relies on ctl permissions exit status 3" \
    contains "$ROOT/tools/magictrackpointctl" "return 3"

# --- 4. Fresh install ---------------------------------------------------------

: > "$STUB_LOG"
if run_install; then ok "install succeeds"; else fail "install succeeds"; cat "$OUT"; fi
check "daemon installed and executable" test -x "$DAEMON"
check "ctl installed and executable" test -x "$CTL"
check "daemon content matches prebuilt" cmp -s "$DAEMON" "$MTP_PREBUILT"
check "no temp files left" sh -c "! ls -A '$BIN' '$MTP_HOME/Library/LaunchAgents' '$MTP_HOME/.config/magictrackpoint' | grep -q '^\.mtp-install'"
check "LaunchAgent lints" plutil -lint -s "$AGENT"
check "LaunchAgent has no placeholder left" sh -c "! grep -q '@DAEMON_PATH@' '$AGENT'"
check "LaunchAgent path is XML-escaped" contains "$AGENT" "home dir &amp; &lt;co&gt;/.local/bin/magictrackpointd"
check "LaunchAgent path round-trips exactly" \
    test "$(plutil -extract ProgramArguments.0 raw -o - "$AGENT")" = "$DAEMON"
check "LaunchAgent Label" test "$(plutil -extract Label raw -o - "$AGENT")" = "$LABEL"
check "LaunchAgent KeepAlive.SuccessfulExit false" \
    test "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$AGENT")" = false
check "LaunchAgent ThrottleInterval 30" test "$(plutil -extract ThrottleInterval raw -o - "$AGENT")" = 30
check "config created from example" cmp -s "$CONFIG" "$ROOT/config/config.example.plist"
check "install bootstrapped the agent" contains "$STUB_LOG" "bootstrap gui/$UID_NUM $AGENT"
check "install prints permission instructions" contains "$OUT" "Input Monitoring"

# --- 5. Reinstall never overwrites the config --------------------------------

printf '<!-- user edit -->\n' >> "$CONFIG"
cp "$CONFIG" "$WORK/config.before"
: > "$STUB_LOG"
check "reinstall succeeds" run_install
check "reinstall keeps the existing config" cmp -s "$CONFIG" "$WORK/config.before"
check "reinstall reports the config as kept" contains "$OUT" "Keeping existing config"
check "reinstall boots out the loaded agent first" \
    test "$(grep -E '^(bootout|bootstrap)' "$STUB_LOG" | cut -d' ' -f1 | tr '\n' ' ')" = "bootout bootstrap "

# --- 6. magictrackpointctl -----------------------------------------------------

mkdir -p "$CACHE"
printf 'state=connected\nsensitivity=7\n' > "$CACHE/status"
: > "$STUB_LOG"
check "ctl help" run_ctl help
check "ctl unknown command fails" sh -c "! bash '$ROOT/tools/magictrackpointctl' bogus >/dev/null 2>&1"
check "ctl status (running) exits 0" run_ctl status
check "ctl status parses pid" contains "$OUT" "pid:       4242"
check "ctl status parses top-level state only" contains "$OUT" "state:     running"
check "ctl status shows the status file" contains "$OUT" "  state=connected"
check "ctl status runs the config check on MTP_HOME" contains "$OUT" "dummy check-config $CONFIG"
check "ctl check PATH" run_ctl check /some/path.plist
check "ctl check passes PATH through" contains "$OUT" "dummy check-config /some/path.plist"
check "ctl reload" env MTP_RELOAD_WAIT=0 bash "$ROOT/tools/magictrackpointctl" reload
check "ctl reload sends SIGHUP" contains "$STUB_LOG" "kill SIGHUP gui/$UID_NUM/$LABEL"

PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_"
export STUB_PERM_DST=$CACHE/status STUB_PERM_SRC=$WORK/perm-status
cp "$CACHE/status" "$WORK/status.saved"
printf 'state=waiting\ninput_monitoring=MISSING\naccessibility=MISSING\n' > "$STUB_PERM_SRC"
: > "$STUB_LOG"
set +e; run_ctl permissions; rc=$?; set -e
check "ctl permissions (both missing) exits 3" test "$rc" = 3
check "ctl permissions restarts the agent (bootout then bootstrap)" \
    test "$(grep -E '^(bootout|bootstrap)' "$STUB_LOG" | cut -d' ' -f1 | tr '\n' ' ')" = "bootout bootstrap "
check "ctl permissions says to run it again" contains "$OUT" 'run "magictrackpointctl permissions" again'
check "ctl permissions opens Input Monitoring first, and only it" \
    test "$(grep '^open ' "$STUB_LOG")" = "open ${PANE}ListenEvent"
check "ctl permissions names the open pane" contains "$OUT" "System Settings is open on Input Monitoring"
check "ctl permissions shows the daemon path" contains "$OUT" "$DAEMON"
printf 'state=waiting\ninput_monitoring=granted\naccessibility=MISSING\n' > "$STUB_PERM_SRC"
: > "$STUB_LOG"
set +e; run_ctl permissions; rc=$?; set -e
check "ctl permissions (one missing) exits 3" test "$rc" = 3
check "ctl permissions opens only the missing pane" \
    test "$(grep '^open ' "$STUB_LOG")" = "open ${PANE}Accessibility"
printf 'state=running\ninput_monitoring=granted\naccessibility=not-needed\n' > "$STUB_PERM_SRC"
: > "$STUB_LOG"
check "ctl permissions (all granted) exits 0" run_ctl permissions
check "ctl permissions (all granted) opens nothing" sh -c "! grep -q '^open ' '$STUB_LOG'"
check "ctl permissions (all granted) says so" contains "$OUT" "All permissions granted."
unset STUB_PERM_SRC
check "ctl permissions fails when the daemon writes no status" \
    sh -c "! bash '$ROOT/tools/magictrackpointctl' permissions >/dev/null 2>&1"
check "ctl permissions takes no argument" \
    sh -c "! bash '$ROOT/tools/magictrackpointctl' permissions x >/dev/null 2>&1"
cp "$WORK/status.saved" "$CACHE/status"
check "ctl start when loaded" run_ctl start
check "ctl start kickstarts when loaded" contains "$STUB_LOG" "kickstart gui/$UID_NUM/$LABEL"
check "ctl stop" run_ctl stop
check "ctl stop boots out" contains "$STUB_LOG" "bootout gui/$UID_NUM/$LABEL"
check "ctl stop explains it stays stopped" contains "$OUT" "until your next login"
check "ctl stop when not loaded is a no-op" run_ctl stop
set +e; run_ctl status; rc=$?; set -e
check "ctl status (not loaded) exits 3" test "$rc" = 3
check "ctl reload when not loaded fails" sh -c "! bash '$ROOT/tools/magictrackpointctl' reload >/dev/null 2>&1"
export STUB_PERM_SRC=$WORK/perm-status
: > "$STUB_LOG"
check "ctl permissions when not loaded succeeds" run_ctl permissions
check "ctl permissions when not loaded starts the agent" \
    test "$(grep -E '^(bootout|bootstrap)' "$STUB_LOG" | cut -d' ' -f1)" = bootstrap
unset STUB_PERM_SRC
run_ctl stop
cp "$WORK/status.saved" "$CACHE/status"
check "ctl start when not loaded" run_ctl start
check "ctl start bootstraps when not loaded" contains "$STUB_LOG" "bootstrap gui/$UID_NUM $AGENT"
: > "$STUB_LOG"
check "ctl restart" run_ctl restart
check "ctl restart = bootout then bootstrap" \
    test "$(grep -E '^(bootout|bootstrap)' "$STUB_LOG" | cut -d' ' -f1 | tr '\n' ' ')" = "bootout bootstrap "

# --- 7. Uninstall --------------------------------------------------------------

: > "$STUB_LOG"
check "uninstall succeeds" run_uninstall
check "uninstall boots out" contains "$STUB_LOG" "bootout gui/$UID_NUM/$LABEL"
check "uninstall removes LaunchAgent" test ! -e "$AGENT"
check "uninstall removes daemon" test ! -e "$DAEMON"
check "uninstall removes ctl" test ! -e "$CTL"
check "uninstall removes status cache" test ! -e "$CACHE"
check "uninstall keeps config" cmp -s "$CONFIG" "$WORK/config.before"
check "uninstall again is idempotent" run_uninstall
check "uninstall --purge removes config" run_uninstall --purge
check "config dir gone after --purge" test ! -e "$MTP_HOME/.config/magictrackpoint"

# --- 8. Isolation --------------------------------------------------------------

check "nothing written to HOME guard" test -z "$(ls -A "$HOME")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
