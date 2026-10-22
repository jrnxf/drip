#!/bin/sh
# Plays a paced tour of every kind of drip card, start to finish on its own, for a screen
# recording: the presets, `drip run`, the chain and push stacks, the coding agents' hook cards, a
# button and a question, a card that `--id` updates in place, and the styles, positions and sizes
# away from the notch. Nothing waits for a click: every card counts down and goes. Run it on a Mac
# with drip installed.
#
#   scripts/demo-tour.sh                 # plays the tour; start Cmd+Shift+5 first to record it
#   scripts/demo-tour.sh --record FILE   # also records the screen to FILE.mov with screencapture
#
# Every card uses drip's built-in defaults, whatever the local config and DRIP_* variables say,
# and none goes in the history: the tour points XDG_CONFIG_HOME and XDG_STATE_HOME at a temporary
# directory it deletes on exit, so it never touches ~/.config/drip or ~/.local/state/drip.
set -eu

usage() {
    echo "usage: $0 [--record FILE.mov]" >&2
    exit 2
}

record=
case $# in
0) ;;
2) [ "$1" = --record ] || usage; record=$2 ;;
*) usage ;;
esac

if [ "$(uname -s)" != Darwin ]; then
    echo "demo-tour: run this on a Mac" >&2
    exit 1
fi
if ! command -v drip >/dev/null 2>&1; then
    echo "demo-tour: drip is not on PATH; install it with: brew install jrnxf/tap/drip" >&2
    exit 1
fi

work=$(mktemp -d)
recorder=
cleanup() {
    [ -z "$recorder" ] || kill "$recorder" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir "$work/config" "$work/state" "$work/my-app"
XDG_CONFIG_HOME="$work/config"
XDG_STATE_HOME="$work/state"
export XDG_CONFIG_HOME XDG_STATE_HOME
unset DRIP_SECONDS DRIP_POSITION DRIP_SIZE DRIP_SOUND DRIP_STYLE DRIP_MOTION DRIP_STACK DRIP_STACK_MAX

# The commands `drip run` wraps: a test run that passes and a deploy that fails, each taking a moment.
cat > "$work/test.sh" <<'SH'
#!/bin/sh
echo "running 246 tests"
sleep 1.2
echo "246 passed"
SH
cat > "$work/deploy.sh" <<'SH'
#!/bin/sh
echo "deploying to staging"
sleep 1
echo "health check timed out after 30s" >&2
exit 1
SH
chmod +x "$work/test.sh" "$work/deploy.sh"

step() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}
# A hook card, as a coding agent's hook sends it: the agent, then the hook's JSON payload.
hook() {
    printf '%s' "$2" | drip hook "$1" --seconds 2.5
}

# The tour takes about 75 seconds; the recording runs a little longer so it never cuts the end.
step "drip demo tour"
echo "Every card grows out of the notch, or out of the top edge on a screen without one,"
echo "until the last part, which shows the styles, positions and sizes away from the notch."
echo "Nothing needs a click: sit back."
if [ -n "$record" ]; then
    # Recording needs Screen Recording permission for this terminal, in System Settings >
    # Privacy & Security; macOS asks the first time.
    echo "Recording the screen to $record for 90 seconds, the pointer and clicks shown."
    screencapture -v -V 90 -k -C -x "$record" &
    recorder=$!
else
    echo "To record it, start a recording with Cmd+Shift+5 now; the tour starts in 5 seconds."
    sleep 2
fi
for n in 3 2 1; do
    printf '%s ' "$n"
    sleep 1
done
echo

step "1. The presets: ok, warn, fail, info and ask, each with its icon, colour and sound"
drip ok "build finished" -d "make test: 246 passed in 3.2s" -s 2
sleep 0.5
drip warn "disk almost full" -d "/: 92% used" -s 2
sleep 0.5
drip fail "backup failed" -d "restic: repository is locked" -s 2
sleep 0.5
drip info "pulled main" -d "3 new commits" -s 2
sleep 0.5
drip ask "drip needs you" -d "an ask card waits for you, or counts down" -s 2 --wait

step "2. drip run: a card when the command ends, with how long it took"
(cd "$work" && drip run -s 2 ./test.sh)
sleep 1
(cd "$work" && drip run -s 2.5 --wait ./deploy.sh) || true

step "3. Stacks: cards that come in together chain out of one another, or push down"
drip demo chain -s 1.5
drip demo push -s 1.5

step "4. Coding agents: their hooks send a card, and a session's newer card takes its place"
hook claude "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"message\":\"Claude needs your permission to use Bash\"}"
sleep 2
hook claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"last_assistant_message\":\"Fixed the flaky login test and pushed the branch.\"}"
sleep 1
hook codex "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"tool_input\":{\"command\":\"npm install\"}}"
sleep 1
hook gemini "{\"hook_event_name\":\"AfterAgent\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"prompt_response\":\"Updated the README with the new flags.\"}"
sleep 4

step "5. Buttons: one that opens a link, and a yes/no question that times out here"
drip info "CI passed" -d "main: 12 checks green" --open https://example.com --button "View run" -s 2.5
sleep 3.5
drip ask "Merge #42?" -d "Claude: checks are green, 1 approval" --icon mark:claude \
    --yes Merge --no Later -s 3 || true

step "6. --id: one deploy card, updated in place"
drip info "deploying api" -d "step 1 of 2 · building image" --id demo-tour-deploy
sleep 1.5
drip info "deploying api" -d "step 2 of 2 · pushing image" --id demo-tour-deploy
sleep 1.5
drip ok "api deployed" -d "v1.4.2 is live" --id demo-tour-deploy -s 2 --wait

step "7. Away from the notch: the styles, positions and sizes"
drip ok "hud" -d "--position top --style hud" --position top --style hud -s 1.8 --wait
drip info "glass" -d "--position top --style glass (macOS 26)" --position top --style glass -s 1.8 --wait
drip fail "wash" -d "--position top --style wash: a failure shakes" --position top --style wash -s 1.8 --wait
drip warn "terminal" -d "--position top --style terminal" --position top --style terminal -s 1.8 --wait
drip ok "center" -d "--position center" --position center -s 1.8 --wait
DRIP_SIZE=compact drip info "compact" -d "size = compact" --position bottom -s 1.8 --wait
DRIP_SIZE=large drip info "large" -d "size = large" --position bottom -s 1.8 --wait
drip ok "that's drip" -d "brew install jrnxf/tap/drip" -s 2.5 --wait

if [ -n "$recorder" ]; then
    echo
    echo "Waiting for the recording to finish..."
    wait "$recorder" || true
    recorder=
    echo "Saved $record"
fi
step "Done"
