#!/bin/sh
# Plays a paced tour of drip, about 20 seconds long, for a screen recording: a `drip run` card, a
# chained stack of cards, a Claude yes/no question with a Merge button, and a deploy card that its
# `--id` turns into its next step and then into ok in place. Run it on a Mac with drip installed.
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
mkdir "$work/config" "$work/state"
XDG_CONFIG_HOME="$work/config"
XDG_STATE_HOME="$work/state"
export XDG_CONFIG_HOME XDG_STATE_HOME
unset DRIP_SECONDS DRIP_POSITION DRIP_SIZE DRIP_SOUND DRIP_STYLE DRIP_MOTION DRIP_STACK_MAX
DRIP_STACK=chain
export DRIP_STACK

# The command `drip run` wraps: a test run that takes a moment.
cat > "$work/test.sh" <<'SH'
#!/bin/sh
echo "running 246 tests"
sleep 1.6
echo "246 passed"
SH
chmod +x "$work/test.sh"

step() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}

step "drip demo tour"
echo "Each card grows out of the notch, or out of the top edge on a screen without one."
echo "When the yes/no card comes up, click Merge: it is the one card that waits for you."
if [ -n "$record" ]; then
    # Recording needs Screen Recording permission for this terminal, in System Settings >
    # Privacy & Security; macOS asks the first time.
    echo "Recording the screen to $record for 32 seconds, clicks shown."
    screencapture -v -V 32 -k -C -x "$record" &
    recorder=$!
else
    echo "To record it: press Cmd+Shift+5, choose Record Entire Screen and click Record,"
    echo "then come back here. Stop the recording from the menu bar when the tour ends."
    printf 'Press Return to start. '
    read -r _
fi
for n in 3 2 1; do
    printf '%s ' "$n"
    sleep 1
done
echo

step "1. drip run: a card when the command ends, with how long it took"
(cd "$work" && drip run ./test.sh)
sleep 3.5

step "2. A chained stack: cards that come in together drop out of one another"
drip info "pulled main" -d "3 commits from origin" -s 3
sleep 0.4
drip warn "lint: 2 warnings" -d "src/api.ts: unused import" -s 3
sleep 0.4
drip ok "preview deployed" -d "pr-42.example.com" -s 3
sleep 4.5

step "3. A question from Claude: click Merge"
answer=0
drip ask "Merge #42?" -d "Claude: checks are green, 1 approval" --icon mark:claude \
    --yes Merge --no Later || answer=$?
case $answer in
0) echo "Merge clicked: drip exited 0, so a script would run gh pr merge 42 now" ;;
1) echo "Later clicked: drip exited 1" ;;
*) echo "No button clicked: drip exited $answer" ;;
esac
sleep 0.6

step "4. --id: one deploy card, updated in place"
drip info "deploying api" -d "step 1 of 2 · building image" --id demo-tour-deploy
sleep 1.6
drip info "deploying api" -d "step 2 of 2 · pushing image" --id demo-tour-deploy
sleep 1.6
drip ok "api deployed" -d "v1.4.2 is live" --id demo-tour-deploy -s 3 --wait

if [ -n "$recorder" ]; then
    echo
    echo "Waiting for the recording to finish..."
    wait "$recorder" || true
    recorder=
    echo "Saved $record"
fi
step "Done"
