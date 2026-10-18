#!/bin/sh
# Builds and tests blip on a Mac, records any missing snapshot references, then shows each preset
# card on screen once, plays every style and notch motion with blip demo, and lists the history.
#
# Existing references are never overwritten: to regenerate one on purpose, delete its PNG in
# Tests/Snapshots and run this script again.
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "mac-check: run this on a Mac" >&2
    exit 1
fi

# Swift Testing is built for macOS 14, so the tests are too; blip itself targets macOS 13 below.
set -- -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx14.0"
# With only the Command Line Tools, SwiftPM does not find Swift Testing on its own.
developer=$(xcode-select -p)
case $developer in
*/CommandLineTools)
    testing="$developer/Library/Developer"
    set -- "$@" -Xswiftc -F -Xswiftc "$testing/Frameworks" \
        -Xlinker -rpath -Xlinker "$testing/Frameworks" -Xlinker -rpath -Xlinker "$testing/usr/lib"
    ;;
esac
BLIP_RECORD_SNAPSHOTS=1 swift test "$@"
swift build

new=$(git status --porcelain --untracked-files=all -- Tests/Snapshots)
if [ -n "$new" ]; then
    echo
    echo "New snapshot references (look at each one, then commit them):"
    echo "$new"
fi

# Show the presets with the built-in defaults, whatever the local config says, plus a custom
# preset from a config file.
config=$(mktemp -d)
trap 'rm -rf "$config"' EXIT
mkdir "$config/blip"
cat > "$config/blip/config.toml" <<'TOML'
[preset.deploy]
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
TOML
unset BLIP_SECONDS BLIP_POSITION BLIP_SIZE BLIP_SOUND BLIP_STYLE BLIP_NOTCH BLIP_MOTION
for kind in ok warn fail info deploy; do
    echo "Showing the $kind card"
    XDG_CONFIG_HOME="$config" .build/debug/blip "$kind" "blip $kind" --detail "mac-check: the $kind preset"
done

echo "Playing blip demo"
XDG_CONFIG_HOME="$config" .build/debug/blip demo

echo "The last cards in the history"
.build/debug/blip history | tail -n 5
