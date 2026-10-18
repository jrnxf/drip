#!/bin/sh
# Builds and tests drip on a Mac, records any missing snapshot references, then shows each preset
# card on screen once, plays every style and the notch card with drip demo, shows a Claude hook
# card that a newer card from the same session replaces in place, and lists the history.
#
# Existing references are never overwritten: to regenerate one on purpose, delete its PNG in
# Tests/Snapshots and run this script again.
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "mac-check: run this on a Mac" >&2
    exit 1
fi

# Swift Testing is built for macOS 14, so the tests are too; drip itself targets macOS 13 below.
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
DRIP_RECORD_SNAPSHOTS=1 swift test "$@"
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
mkdir "$config/drip"
cat > "$config/drip/config.toml" <<'TOML'
[preset.deploy]
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
TOML
unset DRIP_SECONDS DRIP_POSITION DRIP_SIZE DRIP_SOUND DRIP_STYLE DRIP_MOTION
for kind in ok warn fail info deploy; do
    echo "Showing the $kind card"
    XDG_CONFIG_HOME="$config" .build/debug/drip "$kind" "drip $kind" --detail "mac-check: the $kind preset"
done

echo "Playing drip demo"
XDG_CONFIG_HOME="$config" .build/debug/drip demo

# The demo waits for its cards, so the queue is empty: the first hook card is on screen when the
# second arrives, and the second takes its place.
echo "Showing a Claude hook card, then a newer one from the same session in its place; click it to come back here"
hook() {
    XDG_CONFIG_HOME="$config" .build/debug/drip hook claude --seconds 8
}
printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"mac-check","cwd":"%s","message":"Claude needs your permission to use Bash"}' "$PWD" | hook
sleep 3
printf '{"hook_event_name":"Stop","session_id":"mac-check","cwd":"%s","last_assistant_message":"mac-check: this card took the place of the one before"}' "$PWD" | hook

echo "The last cards in the history"
.build/debug/drip history | tail -n 5
