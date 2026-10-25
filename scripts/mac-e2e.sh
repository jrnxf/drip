#!/bin/sh
# Runs the Mac checks of drip's cards that a person used to run by hand, without one: it builds drip,
# shows cards at the notch, feeds them the hooks Claude Code and Codex run, moves the pointer and
# clicks, and prints ok or FAIL for each thing it expects. Exits 1 when any FAIL.
#
#   scripts/mac-e2e.sh                     every check
#   scripts/mac-e2e.sh --only 1,4          some of them, by the numbers in the output
#   scripts/mac-e2e.sh --out DIR           keeps the screenshots in DIR
#   scripts/mac-e2e.sh --judge-check DIR   checks the verdicts a model wrote for DIR's screenshots
#
# It runs drip in a world of its own, deleted afterwards: its own state, config, card queue, Claude
# Code settings and Codex home, so it never touches the drip, history or agent settings in use. Keep
# your hands off the mouse while it runs: it moves the pointer, and other agents' cards at the notch
# make it wait.
#
# Clicks and VoiceOver's actions need Accessibility, which a small helper app holds, not your
# terminal: the first run asks for it (System Settings > Privacy & Security > Accessibility, turn on
# "drip e2e helper"). The helper lives in ~/.cache/drip-e2e and is rebuilt only when its source
# changes, which asks again. Without the grant, those checks skip.
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "mac-e2e: run this on a Mac" >&2
    exit 1
fi

cache="${XDG_CACHE_HOME:-$HOME/.cache}/drip-e2e"
mkdir -p "$cache"

# The screenshots go here unless --out says otherwise.
out=""
for argument in "$@"; do
    case $argument in --out | --judge-check) out=next ;; *) [ "$out" = next ] && out=$argument ;; esac
done
if [ -z "$out" ] || [ "$out" = next ]; then
    out="${TMPDIR:-/tmp}/drip-e2e-$(date +%Y%m%d-%H%M%S)"
    set -- "$@" --out "$out"
fi
mkdir -p "$out"

# The cards come from a release build, as mac-check's do: a debug build samples the springs too slowly.
swift build -c release

# Builds `$2` from `$1` when the source changed since the last build.
stale() {
    [ ! -e "$2" ] || [ "$(cat "$2.source" 2>/dev/null)" != "$(shasum -a 256 "$1" | cut -d' ' -f1)" ]
}
built() {
    shasum -a 256 "$1" | cut -d' ' -f1 >"$2.source"
}

harness="$cache/harness"
if stale scripts/mac-e2e/Harness.swift "$harness"; then
    swiftc -O -o "$harness" scripts/mac-e2e/Harness.swift
    built scripts/mac-e2e/Harness.swift "$harness"
fi

# An app of its own, so the Accessibility grant is its own: macOS ties the grant to this exact
# build, so it is rebuilt only when Helper.swift changes.
helper="$cache/drip e2e helper.app"
if stale scripts/mac-e2e/Helper.swift "$helper/Contents/MacOS/helper"; then
    rm -rf "$helper"
    mkdir -p "$helper/Contents/MacOS"
    cat >"$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>co.jrnxf.drip.e2e-helper</string>
    <key>CFBundleName</key><string>drip e2e helper</string>
    <key>CFBundleExecutable</key><string>helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    swiftc -O -o "$helper/Contents/MacOS/helper" scripts/mac-e2e/Helper.swift
    codesign --force --sign - --identifier co.jrnxf.drip.e2e-helper "$helper"
    built scripts/mac-e2e/Helper.swift "$helper/Contents/MacOS/helper"
fi

# Keeps the display awake while the checks run.
caffeinate -d -i -w $$ &

exec "$harness" --repo "$PWD" --helper "$helper" "$@"
