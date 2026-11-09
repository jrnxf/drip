#!/bin/sh
# An interactive tour of everything drip ships with. For each feature it prints what the next card
# shows and the exact command, waits for you, then runs it, so you watch real cards at the notch.
# Run it on a Mac, in a terminal, with the notch in view:
#
#   scripts/tour.sh                  # the drip on your PATH
#   scripts/tour.sh --bin PATH       # another drip binary
#   scripts/tour.sh --build          # a fresh `swift build -c release` copy from this checkout
#   scripts/tour.sh --dry-run        # print every step and command, run nothing, wait for nothing
#
# At each step: Enter runs it, s skips it, q quits. Ctrl-C leaves at any time.
#
# It never edits your drip config or any agent's settings. Every command runs with an empty config
# folder, so cards have the built-in look, and with DRIP_WHEN_FOCUSED=show and DRIP_HOOK=on, so the
# terminal you run it in does not hide the agent cards. With --bin or --build it also runs in a
# world of its own (its own card queue, history, pause and agent state in a temporary folder,
# deleted on exit), so it never touches the drip you use. With the drip on your PATH its cards go
# through your own drip, and so do its history entries and its pause, which it ends on exit.
#
# --auto runs every step without asking. It is for trying the script against a stand-in --bin that
# only logs its arguments; do not use it for a real tour, where cards would pile up.
set -eu

cd "$(dirname "$0")/.."

die() {
    echo "tour: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: scripts/tour.sh [--bin PATH | --build] [--dry-run] [--auto]

  --bin PATH   use this drip binary (default: drip on PATH), in a world of its own
  --build      use a fresh swift build -c release copy of this checkout, in a world of its own
  --dry-run    print every step and command; run nothing and wait for nothing
  --auto       run every step without asking (for a stand-in --bin)
  -h, --help   this text
EOF
}

bin=
build=0
dry_run=0
auto=0
while [ $# -gt 0 ]; do
    case $1 in
        --bin)
            [ $# -ge 2 ] || die "--bin takes a path"
            bin=$2
            shift 2
            ;;
        --build) build=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --auto) auto=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done
[ -z "$bin" ] || [ "$build" -eq 0 ] || die "use --bin or --build, not both"

work=
paused=0
ran=0
installed=0
drip_bin=drip
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ "$dry_run" -eq 0 ] && [ -n "$work" ]; then
        # End a pause this tour began, and take away the cards it left waiting, by id: never
        # another card of yours.
        [ "$paused" -eq 0 ] || "$drip_bin" resume >/dev/null 2>&1 || true
        if [ "$ran" -eq 1 ]; then
            for id in tour-stay tour-click tour-deploy tour-a tour-b claude:tour-1 codex:tour-2 gemini:tour-3; do
                "$drip_bin" dismiss --id "$id" >/dev/null 2>&1 || true
            done
        fi
        rm -rf "$work"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$dry_run" -eq 0 ]; then
    [ "$(uname -s)" = Darwin ] || die "run this on a Mac: drip shows its cards at the notch"
    if [ "$auto" -eq 0 ]; then
        [ -t 0 ] && [ -t 1 ] || die "run this in a terminal: it asks before each step"
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/drip-tour.XXXXXX")
    if [ "$build" -eq 1 ]; then
        command -v swift >/dev/null 2>&1 || die "swift is missing. Fix: xcode-select --install"
        echo "tour: building drip (swift build -c release)..."
        swift build -c release
        bin=$(swift build -c release --show-bin-path)/drip
    elif [ -z "$bin" ]; then
        installed=1
        bin=$(command -v drip) || die "drip is not on your PATH. Fix: see docs/install.md, or use --build or --bin PATH"
    fi
    [ -x "$bin" ] || die "not an executable file: $bin"
    case $bin in /*) ;; *) bin=$PWD/$bin ;; esac
    drip_bin=$bin
    # This drip needs the commands the tour shows; an older one lacks some of them.
    for sub in run hook remote-hook watching history dismiss pause resume; do
        "$drip_bin" help "$sub" >/dev/null 2>&1 ||
            die "this drip has no 'drip $sub' (version: $("$drip_bin" --version 2>&1 || true)). Fix: update drip, or use --build"
    done
    # The built-in look, whatever the local config and environment say.
    mkdir "$work/config"
    export XDG_CONFIG_HOME="$work/config"
    unset DRIP_SECONDS DRIP_SIZE DRIP_SOUND DRIP_MOTION DRIP_STACK DRIP_STACK_MAX DRIP_ACTIVATE
    export DRIP_WHEN_FOCUSED=show DRIP_HOOK=on
    if [ "$installed" -eq 0 ]; then
        mkdir "$work/state" "$work/queue"
        export XDG_STATE_HOME="$work/state" DRIP_QUEUE_DIR="$work/queue"
    fi
fi

drip() {
    "$drip_bin" "$@"
}

queue_file=$work/remote.jsonl
click_log=$work/click.json
remote_hook=$work/drip-remote-hook
if [ "$dry_run" -eq 1 ]; then
    queue_file=/tmp/drip-tour/remote.jsonl
    click_log=/tmp/drip-tour/click.json
    remote_hook=/tmp/drip-tour/drip-remote-hook
fi

# Canned payloads, as Claude Code, Codex and Gemini CLI send them to their hooks.
claude_prompt='{"hook_event_name":"UserPromptSubmit","session_id":"tour-1","cwd":"/home/user/my-app","prompt":"split the parser out"}'
claude_permission='{"hook_event_name":"PermissionRequest","session_id":"tour-1","cwd":"/home/user/my-app","tool_name":"Bash","tool_input":{"command":"npm install"}}'
claude_stop='{"hook_event_name":"Stop","session_id":"tour-1","cwd":"/home/user/my-app","last_assistant_message":"Split the parser out of the CLI and added tests."}'
claude_failure='{"hook_event_name":"StopFailure","session_id":"tour-1","cwd":"/home/user/my-app","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}'
codex_permission='{"hook_event_name":"PermissionRequest","session_id":"tour-2","turn_id":"t1","cwd":"/home/user/api","tool_name":"Bash","tool_input":{"command":"cargo test"}}'
gemini_permission='{"hook_event_name":"Notification","notification_type":"ToolPermission","session_id":"tour-3","cwd":"/home/user/site","message":"Gemini wants to run npm test"}'

n=0
payload_note=

heading() {
    printf '\n== %s ==\n' "$1"
}

note() {
    printf '\n-- %s\n' "$1"
}

# step TITLE WATCH COMMAND [EXIT-HINT]: prints the step, asks, runs COMMAND with eval. The commands
# are written as you would type them; `drip` there is this tour's binary. EXIT-HINT names what the
# exit status means, and the status is then printed after the command.
step() {
    n=$((n + 1))
    printf '\n[%d] %s\n    Watch for: %s\n' "$n" "$1" "$2"
    if [ -n "$payload_note" ]; then
        printf '    Sample payload on stdin:\n'
        printf '%s\n' "$payload_note" | sed 's/^/      /'
    fi
    printf '%s\n' "$3" | sed -e '1s/^/    $ /' -e '2,$s/^/      /'
    payload_note=
    [ "$dry_run" -eq 0 ] || return 0
    if [ "$auto" -eq 0 ]; then
        printf '    [Enter] run  [s] skip  [q] quit: '
        answer=q
        read -r answer </dev/tty || true
        case $answer in
            [qQ]*) echo "tour: stopped at step $n"; exit 0 ;;
            [sS]*) echo "    skipped"; return 0 ;;
        esac
    fi
    ran=1
    rc=0
    eval "$3" || rc=$?
    if [ -n "${4-}" ]; then
        echo "    exit status: $rc ($4)"
    elif [ "$rc" -ne 0 ]; then
        echo "    exit status: $rc"
    fi
    return 0
}

if [ "$dry_run" -eq 1 ]; then
    echo "tour: dry run - nothing below runs. 'drip' is the binary the tour would use."
else
    echo "tour: using $drip_bin ($("$drip_bin" --version 2>&1 || true))"
    if [ "$installed" -eq 1 ]; then
        echo "tour: this is your own drip: its cards, history and pause are yours."
    else
        echo "tour: a world of its own in $work, deleted on exit."
    fi
    echo "tour: Enter runs a step, s skips it, q quits. Look at the notch after each step."
fi

heading "The four kinds"

step "ok" \
    "a green card with a check, a title and a gray detail line, and the Glass sound" \
    'drip ok "Build finished" -d "make test: 246 passed in 3.2s"'

step "warn" \
    "an orange card, and the Purr sound" \
    'drip warn "Disk almost full" -d "/ is 94% used"'

step "fail" \
    "a red card, and the Basso sound" \
    'drip fail "Deploy failed" -d "staging: health check timed out after 30s"'

step "info, also the default" \
    "a blue card with no kind named: the first word is the title" \
    'drip "Build finished"'

note "Custom presets live in the config file (see docs/config.md); the tour never edits it."

heading "How a card looks"

step "Detail and seconds" \
    "a card that stays fully visible for 8 seconds instead of 4.5" \
    'drip ok "Held longer" -d "This card stays fully visible for 8 seconds" --seconds 8'

step "Icons" \
    "three cards: an SF Symbol, Finder's own app icon, and Claude's bundled mark" \
    'drip info "SF Symbol" --icon bolt.fill --seconds 6
drip info "App icon" --icon app:com.apple.finder --seconds 6
drip info "Agent mark" --icon mark:claude --seconds 6'

step "Sounds" \
    "one card with the Hero sound, then one in silence" \
    'drip ok "Sound: Hero" --sound Hero
sleep 2
drip ok "Sound: none" --sound none'

step "Colors" \
    "a purple card, then one in a hex color" \
    'drip info "Purple" --color purple --seconds 5
drip info "Hex color" --color "#ff6b35" --seconds 5'

step "Title and detail from stdin" \
    "a card whose title is the first line and whose detail is the rest" \
    'printf "Title from stdin\nEvery other line becomes the detail.\n" | drip ok'

step "Several cards at once" \
    "five cards: three stack under the notch, and the rest wait in a small drop that counts them" \
    'for i in 1 2 3 4 5; do drip info "Card $i of 5" -d "Cards stack below the first" --seconds 6; done'

heading "Buttons and questions"

step "A link button: --open and --button" \
    "hover the card and a View PR button stands where the countdown ring was; a click opens example.com" \
    'drip info "Pull request ready" -d "Hover the card, then click the button" --open https://example.com --button "View PR" --seconds 10'

step "A question: --yes and --no" \
    "a card with Deploy and Cancel. Click one, or wait 20 seconds for no answer" \
    'drip warn "Deploy to prod?" -d "v1.4.0" --yes Deploy --no Cancel --seconds 20' \
    "0 Deploy, 1 Cancel, 5 no answer"

step "A question in an && chain" \
    "a card with a Merge button. Click it and the echo after && runs" \
    'drip info "Merge it?" -d "checks green, 1 approval" --yes Merge --seconds 15 && echo "merged"' \
    "0 Merge, 5 no answer"

heading "Replace, stay, click, wait"

step "Replace in place: --id" \
    "a card that stays, then, 3 seconds later, a green card taking its place on screen" \
    'drip info "Deploying" -d "api 1.4.2" --stay --id tour-deploy
sleep 3
drip ok "Deployed" -d "api 1.4.2" --id tour-deploy'

step "A card that waits: --stay" \
    "a red card with a pulsing white dot, no countdown. It stays until you click it" \
    'drip fail "Needs a look" -d "This card stays until you click it" --stay --id tour-stay'

step "Your own click: --on-click" \
    "a card that stays. Click it: the command receives the card as one line of JSON on stdin" \
    'drip info "Click me" -d "Your click runs a command" --stay --id tour-click --on-click "cat > \"$click_log\""'

step "What the click command received" \
    "no card: the JSON your click wrote, or a note that you did not click yet" \
    'if [ -s "$click_log" ]; then cat "$click_log"; else echo "(no click yet: click the card above first)"; fi'

step "Hold the script: --wait" \
    "a card, and the second echo only after it has gone" \
    'echo "before the card"; drip ok "Waited" -d "drip returns when this card is gone" --seconds 3 --wait; echo "after the card"'

heading "drip run"

step "drip run, a command that passes" \
    "after 2 seconds, a green card: sh finished, with how long it took" \
    'drip run --seconds 5 sh -c "sleep 2"' \
    "the command's own"

step "drip run, a command that fails" \
    "after 1 second, a red card: sh failed (exit 3)" \
    'drip run --seconds 5 sh -c "sleep 1; exit 3"' \
    "the command's own, 3"

heading "Clearing the notch"

step "drip dismiss" \
    "two cards that stay; Card A goes by id, then everything on screen goes" \
    'drip info "Card A" --stay --id tour-a
drip warn "Card B" --stay --id tour-b
sleep 3
drip dismiss --id tour-a
sleep 3
drip dismiss'

heading "Pause, missed cards and history"

step "drip pause" \
    "no card: drip says how long is left. Cards are held from now on" \
    'paused=1; drip pause 2m; drip pause'

step "A card while paused" \
    "nothing: the card is held, and shows when you resume" \
    'drip warn "Held while paused" -d "You see this after drip resume" --seconds 6'

step "drip history --missed" \
    "no card: a listing with the held card, marked missed" \
    'drip history --missed'

step "drip resume" \
    "the held card plays back now" \
    'drip resume; paused=0'

step "drip history" \
    "no card: the last cards, newest first, as they showed" \
    'drip history -n 6'

step "drip history --json" \
    "no card: the newest card as one line of JSON, for scripts" \
    'drip history --json -n 1'

step "drip history --replay" \
    "the last 2 cards again, in order" \
    'drip history -n 2 --replay'

heading "Coding agents: drip hook"

note "A recipe in recipes/ puts these hooks in an agent's settings. The tour never does: it feeds sample payloads to the hook by hand."

payload_note=$claude_permission
step "A permission request from Claude Code" \
    "an info card that stays: my-app needs you, with the command Claude wants to run" \
    'printf "%s\n" "$claude_permission" | drip hook claude'

payload_note=$claude_stop
step "The turn is done" \
    "the same session's card turns into a green done card in place" \
    'printf "%s\n" "$claude_stop" | drip hook claude'

payload_note=$claude_failure
step "A turn that ends on an error" \
    "a red card: my-app stopped, with the error" \
    'printf "%s\n" "$claude_failure" | drip hook claude'

payload_note=$codex_permission
step "Codex asks too" \
    "an info card that stays: api needs you, with the command Codex wants to run" \
    'printf "%s\n" "$codex_permission" | drip hook codex'

payload_note=$gemini_permission
step "Gemini CLI asks too" \
    "an info card that stays, with Gemini's message" \
    'printf "%s\n" "$gemini_permission" | drip hook gemini'

payload_note=$claude_permission
step "--approve: answer from the card" \
    "a permission card with Allow and Deny. Click one: drip prints the agent's answer on stdout. A click on the card body, or 9 minutes, prints nothing" \
    'printf "%s\n" "$claude_permission" | drip hook claude --approve' \
    "0, and the answer above"

note "--min-turn counts from the prompt you sent. The next three steps send the prompt, then a done event."

payload_note=$claude_prompt
step "A prompt starts the turn" \
    "no card: drip notes when the turn began" \
    'printf "%s\n" "$claude_prompt" | drip hook claude'

payload_note=$claude_stop
step "--min-turn 30: the turn was too short" \
    "no done card: the turn ran well under 30 seconds" \
    'printf "%s\n" "$claude_stop" | drip hook claude --min-turn 30'

payload_note=$claude_stop
step "--min-turn 2: the turn was long enough" \
    "after 3 seconds, a green done card: the turn ran longer than 2 seconds" \
    'sleep 3; printf "%s\n" "$claude_stop" | drip hook claude --min-turn 2'

payload_note=$claude_permission
step "--only needs-you" \
    "the permission card shows; 3 seconds later the done event takes it away and shows no done card" \
    'printf "%s\n" "$claude_permission" | drip hook claude --only needs-you
sleep 3
printf "%s\n" "$claude_stop" | drip hook claude --only needs-you'

payload_note=$claude_stop
step "DRIP_HOOK=off" \
    "no card: this session asked for none" \
    'printf "%s\n" "$claude_stop" | DRIP_HOOK=off drip hook claude'

heading "Watching and remote agents"

step "drip watching" \
    "no card: the exit status says whether you are watching this terminal now" \
    'drip watching' \
    "0 watching, 1 not watching, 2 cannot tell"

step "A card only when you are away" \
    "usually nothing, since you are at this terminal. Click another app, wait out away_after (see docs/config.md), and run it again to see the card" \
    'drip watching || drip ok "You were away" -d "This card shows only when you are not watching"'

step "drip remote-hook, the script" \
    "no card: the first lines of the script you save on a machine without drip" \
    'drip remote-hook | head -n 14'

payload_note=$claude_stop
step "drip-remote-hook queues an event" \
    "no card: the hook writes one line of JSON to a queue file here, standing in for the other machine" \
    'drip remote-hook > "$remote_hook" && chmod +x "$remote_hook"
printf "%s\n" "$claude_stop" | DRIP_QUEUE="$queue_file" DRIP_MACHINE=devbox "$remote_hook" claude --min-turn 30
cat "$queue_file"'

note "drip follow <ssh-target> shows those queued cards on this Mac. It needs ssh to another machine, so the tour skips it. See docs/remote.md."

heading "Done"
echo "That is every part of drip a card can show. The docs: docs/usage.md, docs/agents.md and recipes/README.md."
