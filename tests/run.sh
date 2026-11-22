#!/bin/bash
# MagicTrackpoint test runner.
#
#   1. tests/core_test.m: unit tests of src/mtp_core.h, built with ASan/UBSan;
#   2. the real daemon, built universal with -Werror: architectures, --version,
#      embedded Info.plist, --check-config on generated files, CLI errors;
#   3. tests/packaging_test.sh, if present.
#
# Every build goes to a temporary directory. The daemon is only ever run with
# --version / --check-config PATH / bad arguments: never in its normal mode
# (it would request macOS permissions) and never on the real ~/.config file.
# All steps run even if one fails; the exit status is non-zero if any failed.

# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mtp-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check "description" command...
    local d=$1; shift
    if "$@"; then ok "$d"; else fail "$d"; fi
}
has() { grep -qF -- "$2" "$1"; }

# Runs a command, storing its exit status in $rc and its output in $out_file.
out_file=$tmp/out.txt
run() { rc=0; "$@" > "$out_file" 2>&1 || rc=$?; }

# ── 1. Unit tests ─────────────────────────────────────────────────────────────
echo "== core_test (ASan + UBSan)"
if clang -O0 -g -fobjc-arc -Wall -Wextra -fsanitize=address,undefined -I src \
        -o "$tmp/core_test" tests/core_test.m -framework Foundation; then
    ok "core_test builds"
    # UBSan aborts on the first undefined behaviour instead of just logging it.
    if UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 ASAN_OPTIONS=abort_on_error=0 \
            "$tmp/core_test"; then
        ok "core_test passes"
    else
        fail "core_test passes (see FAIL lines above)"
    fi
else
    fail "core_test builds"
fi

# ── 2. Daemon build ───────────────────────────────────────────────────────────
echo "== daemon"
VERSION_FILE=$(cat VERSION 2>/dev/null || echo dev)
D=$tmp/magictrackpointd
if clang -O2 -fobjc-arc -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 \
        -Wall -Wextra -Werror -DMTP_VERSION="\"$VERSION_FILE\"" \
        -sectcreate __TEXT __info_plist src/Info.plist \
        -o "$D" src/magictrackpointd.m \
        -framework Foundation -framework IOKit -framework ApplicationServices; then
    ok "daemon builds (universal, -Werror)"
else
    fail "daemon builds (universal, -Werror)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi

archs=$(lipo -archs "$D")
check "lipo: arm64 present ($archs)" grep -qw arm64 <<< "$archs"
check "lipo: x86_64 present ($archs)" grep -qw x86_64 <<< "$archs"

run "$D" --version
check "--version exits 0" test "$rc" = 0
got_version=$(cat "$out_file")
if [ -f VERSION ]; then
    check "--version ($got_version) = VERSION ($VERSION_FILE)" test "$got_version" = "$VERSION_FILE"
else
    printf 'skip --version vs VERSION (no VERSION file)\n'
fi

plist_version=$(plutil -extract CFBundleShortVersionString raw -o - src/Info.plist)
if [ -f VERSION ]; then
    check "src/Info.plist version ($plist_version) = VERSION ($VERSION_FILE)" \
        test "$plist_version" = "$VERSION_FILE"
fi
for arch in arm64 x86_64; do
    if lipo -thin "$arch" -output "$tmp/thin-$arch" "$D" &&
       segedit "$tmp/thin-$arch" -extract __TEXT __info_plist "$tmp/info-$arch.plist" 2>/dev/null; then
        emb=$(plutil -extract CFBundleShortVersionString raw -o - "$tmp/info-$arch.plist" || true)
        emb_id=$(plutil -extract CFBundleIdentifier raw -o - "$tmp/info-$arch.plist" || true)
        check "embedded Info.plist ($arch) version ($emb) = --version ($got_version)" \
            test "$emb" = "$got_version"
        check "embedded Info.plist ($arch) identifier ($emb_id)" \
            test "$emb_id" = com.jcbaptiste.magictrackpoint
    else
        fail "embedded Info.plist ($arch) extractable"
    fi
done

# ── 3. --check-config ─────────────────────────────────────────────────────────
echo "== --check-config"
run "$D" --check-config "$tmp/does-not-exist.plist"
check "nonexistent path exits 0 (got $rc)" test "$rc" = 0
check "nonexistent path reports defaults" has "$out_file" "(absent: defaults)"
check "nonexistent path prints default sensitivity" has "$out_file" "trackpoint.sensitivity = 7"
check "nonexistent path prints no error" sh -c "! grep -q '^error:' '$out_file'"

if [ -f config/config.example.plist ]; then
    run "$D" --check-config config/config.example.plist
    check "example config exits 0 (got $rc)" test "$rc" = 0
    check "example: sensitivity 7" has "$out_file" "trackpoint.sensitivity = 7"
    check "example: threshold 3" has "$out_file" "scroll.threshold = 3"
    check "example: speed 1" has "$out_file" "scroll.speed = 1"
    check "example: acceleration 1" has "$out_file" "scroll.acceleration = 1"
    check "example: no error line" sh -c "! grep -q '^error:' '$out_file'"
    check "example: not reported absent" sh -c "! grep -qF '(absent' '$out_file'"
    if [ "$rc" != 0 ]; then sed 's/^/    /' "$out_file"; fi
else
    printf 'skip example config (config/config.example.plist absent)\n'
fi

# Valid file with every key set (XML) and the same as a binary plist.
cat > "$tmp/valid.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>trackpoint</key><dict><key>sensitivity</key><integer>2</integer></dict>
	<key>scroll</key><dict>
		<key>enabled</key><false/>
		<key>speed</key><real>2.5</real>
		<key>acceleration</key><real>0.5</real>
		<key>horizontal</key><false/>
		<key>threshold</key><integer>0</integer>
	</dict>
	<key>middle_button</key><dict><key>click_if_no_scroll</key><false/></dict>
	<key>logging</key><dict><key>level</key><string>debug</string></dict>
</dict>
</plist>
EOF
cp "$tmp/valid.plist" "$tmp/valid.bin.plist"
plutil -convert binary1 "$tmp/valid.bin.plist"
for f in valid.plist valid.bin.plist; do
    run "$D" --check-config "$tmp/$f"
    check "$f exits 0 (got $rc)" test "$rc" = 0
    check "$f values printed" sh -c "grep -qx 'trackpoint.sensitivity = 2' '$out_file' &&
        grep -qx 'scroll.enabled = false' '$out_file' && grep -qx 'scroll.speed = 2.5' '$out_file' &&
        grep -qx 'scroll.acceleration = 0.5' '$out_file' &&
        grep -qx 'scroll.horizontal = false' '$out_file' && grep -qx 'scroll.threshold = 0' '$out_file' &&
        grep -qx 'middle_button.click_if_no_scroll = false' '$out_file' &&
        grep -qx 'logging.level = debug' '$out_file'"
done

# Invalid values: exit 1, one error line per problem, defaults kept.
cat > "$tmp/invalid.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>trackpoint</key><dict><key>sensitivity</key><integer>12</integer></dict>
	<key>scroll</key><dict>
		<key>speed</key><string>fast</string>
		<key>threshold</key><real>3.5</real>
		<key>enabled</key><integer>1</integer>
		<key>bogus</key><true/>
	</dict>
	<key>logging</key><dict><key>level</key><string>LOUD</string></dict>
	<key>extra</key><dict/>
</dict>
</plist>
EOF
run "$D" --check-config "$tmp/invalid.plist"
check "invalid config exits 1 (got $rc)" test "$rc" = 1
nerr=$(grep -c '^error: .*(default kept)$' "$out_file" || true)
check "invalid config: 7 error lines (got $nerr)" test "$nerr" = 7
for needle in trackpoint.sensitivity scroll.speed scroll.threshold scroll.enabled \
        "unknown key 'scroll.bogus'" logging.level "unknown section 'extra'"; do
    check "invalid config reports $needle" has "$out_file" "$needle"
done
check "invalid config keeps defaults, scrolling off (fail closed)" sh -c "grep -qx 'trackpoint.sensitivity = 7' '$out_file' &&
    grep -qx 'scroll.speed = 1' '$out_file' && grep -qx 'scroll.threshold = 3' '$out_file' &&
    grep -qx 'scroll.enabled = false' '$out_file' && grep -qx 'logging.level = error' '$out_file'"

head -c 4096 /dev/urandom > "$tmp/garbage.plist"
run "$D" --check-config "$tmp/garbage.plist"
check "garbage file exits 1 (got $rc)" test "$rc" = 1
check "garbage file: unreadable property list" has "$out_file" "unreadable property list"

mkdir "$tmp/dir.plist"
run "$D" --check-config "$tmp/dir.plist"
check "directory exits 1 (got $rc)" test "$rc" = 1
check "directory: not a regular file" has "$out_file" "not a regular file"

head -c 65537 /dev/zero | tr '\0' ' ' > "$tmp/big.plist"
run "$D" --check-config "$tmp/big.plist"
check "65537-byte file exits 1 (got $rc)" test "$rc" = 1

mkfifo "$tmp/fifo.plist"
# A FIFO must be rejected without blocking: run with a watchdog.
( r=0; "$D" --check-config "$tmp/fifo.plist" > "$tmp/fifo.out" 2>&1 || r=$?
  echo "$r" > "$tmp/fifo.rc" ) &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$tmp/fifo.rc" ] && break; sleep 0.5; done
if [ -e "$tmp/fifo.rc" ]; then
    check "FIFO exits 1 without blocking (got $(cat "$tmp/fifo.rc"))" test "$(cat "$tmp/fifo.rc")" = 1
else
    kill "$pid" 2>/dev/null || true
    pkill -f "$tmp/fifo.plist" 2>/dev/null || true
    fail "FIFO exits 1 without blocking (still running after 5 s)"
fi
wait "$pid" 2>/dev/null || true

# ── 4. Command-line errors (exit before doing anything) ───────────────────────
echo "== command line"
for args in "--bogus" "-h" "--version extra" "--check-config a b" "--check-confi" "version"; do
    # shellcheck disable=SC2086  # word splitting intended
    run "$D" $args
    check "'$args' exits 2 (got $rc)" test "$rc" = 2
    check "'$args' prints usage" has "$out_file" "usage: magictrackpointd"
done
run "$D" ""
check "empty argument exits 2 (got $rc)" test "$rc" = 2

# ── 5. Packaging ──────────────────────────────────────────────────────────────
if [ -f tests/packaging_test.sh ]; then
    echo "== packaging_test.sh"
    if bash tests/packaging_test.sh; then
        ok "packaging_test.sh"
    else
        fail "packaging_test.sh"
    fi
else
    printf 'skip packaging_test.sh (absent)\n'
fi

printf '\nrun.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
