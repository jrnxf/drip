#!/bin/sh
# Builds and tests blip on a Mac, records any missing snapshot references, then shows each preset
# card on screen once.
#
# Existing references are never overwritten: to regenerate one on purpose, delete its PNG in
# Tests/Snapshots and run this script again.
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "mac-check: run this on a Mac" >&2
    exit 1
fi

swift build
BLIP_RECORD_SNAPSHOTS=1 swift test

new=$(git status --porcelain --untracked-files=all -- Tests/Snapshots)
if [ -n "$new" ]; then
    echo
    echo "New snapshot references (look at each one, then commit them):"
    echo "$new"
fi

# Show the presets with the built-in defaults, whatever the local config says.
config=$(mktemp -d)
trap 'rm -rf "$config"' EXIT
for kind in ok warn fail info; do
    echo "Showing the $kind card"
    env -u BLIP_SECONDS -u BLIP_POSITION -u BLIP_SIZE -u BLIP_SOUND XDG_CONFIG_HOME="$config" \
        .build/debug/blip "$kind" "blip $kind" --detail "mac-check: the $kind preset"
done
