#!/bin/sh
# A tour of what drip ships with, run entirely through drip's own cards. Run it on a Mac, with the
# notch in view, from any terminal:
#
#   scripts/tour.sh                  # the drip on your PATH
#   scripts/tour.sh --bin PATH       # another drip binary
#   scripts/tour.sh --build          # a fresh `swift build -c release` copy from this checkout
#   scripts/tour.sh --dry-run        # print every step and its commands; show no cards
#
# --dry-run also fails when a card that needs no click shows for more than 3 seconds.
#
# After that one command you never type again. Before each of the 10 steps a question card says
# what the step shows. Click Next to run the step, or Stop to end the tour. A card nobody answers,
# or a click beside its buttons, asks again instead of moving on.
#
# It never edits your drip config or any agent's settings. Every command runs with an empty config
# folder, so cards have the built-in look, and with DRIP_WHEN_FOCUSED=show and DRIP_HOOK=on, so the
# terminal you run it in does not hide the agent card. With --bin or --build it also runs in a
# world of its own (its own card queue, history, pause and agent state in a temporary folder,
# deleted on exit), so it never touches the drip you use. With the drip on your PATH its cards go
# through your own drip, and so do its history entries and its pause, which it ends on exit.
set -eu

cd "$(dirname "$0")/.."

die() {
    echo "tour: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: scripts/tour.sh [--bin PATH | --build] [--dry-run]

  --bin PATH   use this drip binary (default: drip on PATH), in a world of its own
  --build      use a fresh swift build -c release copy of this checkout, in a world of its own
  --dry-run    print every step and its commands; show no cards
  -h, --help   this text
EOF
}

bin=
build=0
dry_run=0
while [ $# -gt 0 ]; do
    case $1 in
        --bin)
            [ $# -ge 2 ] || die "--bin takes a path"
            bin=$2
            shift 2
            ;;
        --build) build=1; shift ;;
        --dry-run) dry_run=1; shift ;;
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
            for id in tour-nav tour-stay tour-click tour-deploy claude:tour-1; do
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
    for sub in run hook history dismiss pause resume; do
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

# The sample payload Claude Code sends its PermissionRequest hook.
claude_permission='{"hook_event_name":"PermissionRequest","session_id":"tour-1","cwd":"/home/user/my-app","tool_name":"Bash","tool_input":{"command":"npm install"}}'

total=10
n=0

# ask TITLE DETAIL: a question card with Next and Stop. Returns 0 for Next and 1 for Stop. A card
# nobody answers (exit 5) is asked again; any other failure is the tour's.
ask() {
    while :; do
        code=0
        drip info "$1" -d "$2" --yes Next --no Stop --id tour-nav --activate none || code=$?
        case $code in
            0) return 0 ;;
            1) return 1 ;;
            5) sleep 1 ;;
            *) die "drip exited $code while asking; is a GUI session running?" ;;
        esac
    done
}

# step NAME DETAIL COMMANDS: asks, then runs COMMANDS with eval. The commands are written as you
# would type them; `drip` there is this tour's binary.
step() {
    n=$((n + 1))
    title="drip tour $n/$total: $1"
    if [ "$dry_run" -eq 1 ]; then
        printf '\n[%d/%d] %s\n    asks: drip info "%s" -d "%s" --yes Next --no Stop --id tour-nav --activate none\n' \
            "$n" "$total" "$1" "$title" "$2"
        printf '%s\n' "$3" | sed -e '1s/^/    runs: /' -e '2,$s/^/          /'
        return 0
    fi
    ran=1
    echo "tour: $title"
    if ! ask "$title" "$2"; then
        drip info "Tour stopped" -d "Run scripts/tour.sh again any time." --seconds 3 --wait
        exit 0
    fi
    eval "$3" || true
}

[ "$dry_run" -eq 0 ] || echo "tour: dry run - no cards. 'drip' is the binary the tour would use."

step "four kinds" \
    "ok, warn, fail and info, sent together to show as one stack. Each card names its kind." \
    'drip ok "ok" -d "green check, Glass sound" --seconds 3
drip warn "warn" -d "orange, Purr sound" --seconds 3
drip fail "fail" -d "red, Basso sound" --seconds 3
drip info "info" -d "blue, Tink sound" --seconds 3'

step "icon, color, sound" \
    "One card with Claude's bundled mark, a purple color and the Hero sound." \
    'drip ok "A custom look" -d "--icon mark:claude --color purple --sound Hero" --icon mark:claude --color purple --sound Hero --seconds 3'

step "--open and --button" \
    "A card with a View PR button. Hover the card, then click the button to open example.com." \
    'drip info "A link button" -d "Hover me, then click View PR" --open https://example.com --button "View PR" --seconds 10'

step "--yes and --no" \
    "A Deploy or Cancel question. The next card says which you clicked and the exit code drip returned." \
    'rc=0
drip warn "Deploy to prod?" -d "Click Deploy or Cancel" --yes Deploy --no Cancel --seconds 15 || rc=$?
case $rc in
    0) drip ok "You clicked Deploy" -d "drip exited 0" --seconds 3 ;;
    1) drip warn "You clicked Cancel" -d "drip exited 1" --seconds 3 ;;
    *) drip info "No answer" -d "drip exited $rc" --seconds 3 ;;
esac'

step "--id replace in place" \
    "One card with the same id, updated 3 times: it changes in place, it is not a new card." \
    'drip info "Deploying" -d "update 1 of 3: building" --id tour-deploy --seconds 3
sleep 1
drip info "Deploying" -d "update 2 of 3: testing" --id tour-deploy --seconds 3
sleep 1
drip ok "Deployed" -d "update 3 of 3: same card, same id" --id tour-deploy --seconds 3'

step "--stay and drip dismiss" \
    "A red card that stays with a pulsing dot. Two seconds later the tour runs drip dismiss." \
    'drip fail "Needs a look" -d "--stay: no countdown. drip dismiss clears me in 2 seconds" --stay --id tour-stay
sleep 2
drip dismiss --id tour-stay'

step "--on-click" \
    "Click the next card. Its --on-click command runs and a new card confirms it." \
    'drip info "Click me" -d "Your click runs a command" --id tour-click --seconds 15 --wait --on-click "cat >/dev/null; \"$drip_bin\" ok \"Click received\" -d \"Your --on-click command ran\" --seconds 3"'

step "drip run" \
    "Two commands: one that passes, a green card, and one that fails with exit 3, a red card." \
    'drip run --seconds 3 sh -c "sleep 1"
drip run --seconds 3 sh -c "sleep 1; exit 3"'

step "pause, resume, history" \
    "Two cards sent while paused are held. On resume they play back. Then a card sums up drip history --missed." \
    'paused=1
drip pause 2m >/dev/null 2>&1
drip ok "Held card 1" -d "sent while paused" --seconds 3
drip warn "Held card 2" -d "sent while paused" --seconds 3
sleep 1
drip resume >/dev/null 2>&1
paused=0
sleep 2
missed=$(drip history --missed -n 2 --json | sed -n "s/.*\"title\":\"\([^\"]*\)\".*/\1/p" | paste -sd, - | sed "s/,/, /g")
drip info "drip history --missed" -d "${missed:-nothing missed}" --seconds 3'

step "drip hook --approve" \
    "A permission card for npm install, from a sample Claude Code payload, with Allow and Deny. The next card shows what drip printed." \
    'answer=$(printf "%s\n" "$claude_permission" | drip hook claude --approve) || true
drip ok "Hook answered" -d "printed: ${answer:-nothing, so the terminal asks}" --seconds 3'

if [ "$n" -ne "$total" ]; then
    die "internal: $n steps, expected $total"
fi
if [ "$dry_run" -eq 1 ]; then
    echo
    echo "tour: after the last step: drip ok \"Tour done\""
    # A card that needs no click shows for 3 seconds at most, so the tour stays quick.
    slow=$(awk '/--seconds [0-9.]+/ && !/--yes|--open|--on-click/ {
        match($0, /--seconds [0-9.]+/)
        if (substr($0, RSTART + 10, RLENGTH - 10) + 0 > 3) print NR ": " $0
    }' "$0")
    if [ -n "$slow" ]; then
        echo "tour: FAIL - a card with no click shows for more than 3 seconds:" >&2
        echo "$slow" >&2
        exit 1
    fi
    echo "tour: ok - no card without a click shows for more than 3 seconds"
    exit 0
fi
drip ok "Tour done" -d "That is the tour. The docs: docs/usage.md, docs/agents.md and recipes/README.md." --seconds 3 --wait
