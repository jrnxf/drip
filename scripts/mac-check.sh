#!/bin/sh
# Builds and tests drip on a Mac, records any missing snapshot references, then shows each preset
# card on screen once, a card that stays until the next card needs the notch, a yes/no question and
# its exit status, the agent marks
# drip bundles, drops a few cards that stack under one another, shows a Claude hook card that a newer card from the same session replaces
# in place, turns a deploy card into its next step and then into ok and fail in place, and lists
# the history.
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
# The cards below are for looking at, so they come from a release build: a debug build samples the
# notch's springs too slowly to keep up, and the drop never oozes out of the notch.
swift build -c release

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
unset DRIP_SECONDS DRIP_SIZE DRIP_SOUND DRIP_MOTION
for kind in ok warn fail info deploy; do
    echo "Showing the $kind card"
    XDG_CONFIG_HOME="$config" .build/release/drip "$kind" "drip $kind" --detail "mac-check: the $kind preset"
done
# Terminal's own icon, untinted, with the waiting dot sending out its ping. It stays until it is clicked,
# or until the next card below waits for the notch: then it counts down like any other card.
echo "Showing a card that stays, with Terminal's icon; it waits for a click, or for the next card"
XDG_CONFIG_HOME="$config" .build/release/drip info "drip info --stay" --detail "mac-check: waits for you" \
    --icon app:com.apple.Terminal --stay

# A question never gives way: answer it, then check the exit status, 0 for yes and 1 for no.
echo "Asking a yes/no question; click Merge (exit 0) or Later (exit 1)"
status=0
XDG_CONFIG_HOME="$config" .build/release/drip warn "Merge drip #23?" --detail "mac-check: answer with a button" \
    --yes Merge --no Later || status=$?
echo "drip warn --yes exited $status"

# The agent marks drip bundles, for an agent with no app installed, each with its state in the ring.
for mark in claude codex gemini; do
    echo "Showing the $mark mark"
    XDG_CONFIG_HOME="$config" .build/release/drip info "drip info" --detail "mac-check: mark:$mark" \
        --icon "mark:$mark" --seconds 3
done

echo "Dropping a few cards at once; they stack under one another"
for kind in ok warn fail; do
    XDG_CONFIG_HOME="$config" .build/release/drip "$kind" "drip $kind" --detail "mac-check: stacked" --seconds 2
done
XDG_CONFIG_HOME="$config" .build/release/drip info "drip info" --detail "mac-check: after the stack" --seconds 2 --wait

# The last card waited for its turn and its exit, so the queue is empty: the first hook card is on
# screen when the second arrives, and the second takes its place. The first is an info card that stays, with Claude's app icon,
# or Claude's bundled mark without Claude.app; the second turns its waiting dot into a check.
echo "Showing a Claude hook card, then a newer one from the same session in its place; click it to come back here"
hook() {
    # Shown as any card, though this terminal is in front, which would make the done card quiet.
    DRIP_WHEN_FOCUSED=show XDG_CONFIG_HOME="$config" .build/release/drip hook claude --seconds 8
}
printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"mac-check","cwd":"%s","message":"Claude needs your permission to use Bash"}' "$PWD" | hook
sleep 3
printf '{"hook_event_name":"Stop","session_id":"mac-check","cwd":"%s","last_assistant_message":"mac-check: this card took the place of the one before"}' "$PWD" | hook

# A permission card goes once the tool it asked about has run, as when you approve in the terminal.
sleep 9
echo "Showing a Claude permission card, then taking it away as its tool runs"
printf '{"hook_event_name":"PermissionRequest","session_id":"mac-check-2","cwd":"%s","prompt_id":"mac-check-prompt","tool_name":"Bash","tool_input":{"command":"swift test"}}' "$PWD" | hook
sleep 4
printf '{"hook_event_name":"PostToolUse","session_id":"mac-check-2","prompt_id":"mac-check-prompt","tool_name":"Bash","tool_input":{"command":"swift test"},"tool_use_id":"toolu_mac_check"}' | hook

# drip dismiss takes cards away without bringing anything forward.
sleep 2
echo "Showing a card that stays, then dismissing it; hover it first to see the x and the arrow"
XDG_CONFIG_HOME="$config" .build/release/drip info "drip dismiss" --detail "mac-check: hover me, then wait" --stay
sleep 5
.build/release/drip dismiss

# Each newer card takes the place of the one on screen: the card springs to its size, and a new
# state's colour settles over the old one as its icon pops in.
echo "Turning a deploy card into its next step, then into ok, in place"
deploy() {
    XDG_CONFIG_HOME="$config" .build/release/drip "$@" --id mac-check-deploy
}
sleep 9
deploy info "deploying api" --detail "step 1 of 2 · building image"
sleep 1.5
deploy info "deploying api" --detail "step 2 of 2 · pushing image"
sleep 1.5
deploy ok "api deployed"
sleep 6
echo "Turning a deploy card into fail, in place"
deploy info "deploying api" --detail "./deploy.sh is running"
sleep 1.5
deploy fail "deploy failed" --detail "./deploy.sh exited with status 1"

echo "The last cards in the history"
.build/release/drip history | tail -n 5
