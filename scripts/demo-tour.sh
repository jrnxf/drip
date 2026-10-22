#!/bin/sh
# Plays a slow tour of every kind of drip card, start to finish on its own, for a screen recording:
# the presets, `drip run`, the chain and push stacks, the coding agents' hook cards, a button and a
# question, and a card that `--id` updates in place. Every card is a notch card in the default
# style, as in `drip demo`, held long enough to read, with a pause before the next. Nothing waits
# for a click or a key, questions time out on their own, and the tour prints nothing: start a
# screen recording first, or pass --record. Run it on a Mac with drip installed.
#
#   scripts/demo-tour.sh                 # plays the tour, in a little over two minutes
#   scripts/demo-tour.sh --record FILE   # also records the screen to FILE.mov with screencapture
#
# Every card uses drip's built-in defaults, whatever the local config and DRIP_* variables say,
# and none goes in the history: the tour points XDG_CONFIG_HOME and XDG_STATE_HOME at a temporary
# directory it deletes on exit, so it never touches ~/.config/drip or ~/.local/state/drip.
set -eu

# All of it in one function, so sh has read the whole script before running any of it: piped in,
# as in `curl ... | sh`, sh reads the script from stdin, which the tour then closes.
main() {
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

    # From here on the tour reads nothing and prints nothing, drip's own output included.
    exec </dev/null >/dev/null 2>&1

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
    printf '#!/bin/sh\nsleep 1.5\n' > "$work/test.sh"
    printf '#!/bin/sh\nsleep 1.5\nexit 1\n' > "$work/deploy.sh"
    chmod +x "$work/test.sh" "$work/deploy.sh"

    # How long each card stays fully on screen, and the pause after it has gone.
    hold=4
    gap=1.2

    # Shows a card and waits until it has gone, then pauses.
    card() {
        drip "$@" -s "$hold" --wait || true
        sleep "$gap"
    }
    # A hook card, as a coding agent's hook sends it: the agent, then the hook's JSON payload.
    hook() {
        printf '%s' "$2" | drip hook "$1" --seconds "$hold" || true
    }

    if [ -n "$record" ]; then
        # Recording needs Screen Recording permission for this terminal, in System Settings >
        # Privacy & Security; macOS asks the first time. The tour takes a little over two minutes.
        screencapture -v -V 160 -k -C -x "$record" &
        recorder=$!
    fi
    sleep 2

    # 1. The presets, each with its icon, colour and sound.
    card ok "build finished" -d "make test: 246 passed in 3.2s"
    card warn "disk almost full" -d "/: 92% used"
    card fail "backup failed" -d "restic: repository is locked"
    card info "pulled main" -d "3 new commits"
    card ask "drip needs you" -d "an ask card waits for you, or counts down"

    # 2. drip run: a card when the command ends, with how long it took.
    (cd "$work" && drip run -s "$hold" --wait ./test.sh) || true
    sleep "$gap"
    (cd "$work" && drip run -s "$hold" --wait ./deploy.sh) || true
    sleep "$gap"

    # 3. Stacks: cards that come in together chain out of one another, then push down.
    drip demo chain -s "$hold" || true
    sleep "$gap"
    drip demo push -s "$hold" || true
    sleep "$gap"

    # 4. Coding agents: a session's newer card takes the place of its last one on screen.
    hook claude "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"message\":\"Claude needs your permission to use Bash\"}"
    sleep 4
    hook claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"last_assistant_message\":\"Fixed the flaky login test and pushed the branch.\"}"
    sleep 6
    hook codex "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"tool_input\":{\"command\":\"npm install\"}}"
    sleep 6
    hook gemini "{\"hook_event_name\":\"AfterAgent\",\"session_id\":\"demo-tour\",\"cwd\":\"$work/my-app\",\"prompt_response\":\"Updated the README with the new flags.\"}"
    sleep 6.5

    # 5. Buttons: one that opens a link, and a yes/no question that times out on its own.
    card info "CI passed" -d "main: 12 checks green" --open https://example.com --button "View run"
    drip ask "Merge #42?" -d "Claude: checks are green, 1 approval" --icon mark:claude \
        --yes Merge --no Later -s "$hold" || true
    sleep 2.5

    # 6. --id: one deploy card, updated in place.
    drip info "deploying api" -d "step 1 of 2 · building image" --id demo-tour-deploy -s "$hold"
    sleep 3.5
    drip info "deploying api" -d "step 2 of 2 · pushing image" --id demo-tour-deploy -s "$hold"
    sleep 3.5
    card ok "api deployed" -d "v1.4.2 is live" --id demo-tour-deploy

    card ok "that's drip" -d "brew install jrnxf/tap/drip"

    if [ -n "$recorder" ]; then
        wait "$recorder" || true
        recorder=
    fi
}

main "$@"
