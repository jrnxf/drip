#!/bin/sh
# TEMPORARY: remove once the overflow drop's motion is tuned.
#
# Replays the overflow drop on a Mac, for screen recordings: sends more cards than the stack shows,
# a gap apart, so a drop forms under the last card and counts the cards waiting, takes in the ones
# that come later, ticks down as each grows out of it, and goes back in once none waits. With --id,
# the first card has an id and one more card with that id comes last: it waits in the drop, then
# swaps into the first card in place, and the count goes down without a card growing out.
#
# Start it with no drip card on screen: cards sent while a stack shows join that stack, with its
# stack_max.
#
#   scripts/sim-overflow.sh                 # stack_max 3, 6 cards, 0.4 s apart, 3 s each
#   scripts/sim-overflow.sh --max 1 --count 4 --gap 0.8 --timeout 2 --id
#   scripts/sim-overflow.sh --push          # DRIP_STACK=push
set -eu

cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
usage: scripts/sim-overflow.sh [--max N] [--count N] [--gap SECONDS] [--timeout SECONDS] [--id] [--push] [--bin PATH]
  --max N            stack_max, 1 to 6 (default 3)
  --count N          cards to send (default stack_max + 3)
  --gap SECONDS      time between two sends (default 0.4)
  --timeout SECONDS  how long each card shows (default 3)
  --id               the first card has an id, and one more card with that id comes last
  --push             stack with push instead of chain
  --bin PATH         the drip to run (default: .build/release/drip, built if missing)
USAGE
}

max=3
count=
gap=0.4
timeout=3
swap=
mode=chain
drip=
while [ $# -gt 0 ]; do
    case $1 in
    --max) max=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    --gap) gap=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    --id) swap=1; shift ;;
    --push) mode=push; shift ;;
    --bin) drip=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
    esac
done
count=${count:-$((max + 3))}

if [ "$(uname -s)" != Darwin ]; then
    echo "sim-overflow: run this on a Mac" >&2
    exit 1
fi
if [ -z "$drip" ]; then
    # A release build: a debug build samples the springs too slowly to keep up.
    drip=.build/release/drip
    [ -x "$drip" ] || swift build -c release
fi

export DRIP_STACK=$mode DRIP_STACK_MAX=$max
unset DRIP_MOTION DRIP_SECONDS

kinds="ok warn fail info"
titles="Build finished|Lint: 3 warnings|Migration failed|Review requested|Tests passed|Disk 92% full|Deploy failed|Agent is done"
i=1
while [ "$i" -le "$count" ]; do
    kind=$(echo "$kinds" | cut -d ' ' -f $(((i - 1) % 4 + 1)))
    title=$(echo "$titles" | cut -d '|' -f $(((i - 1) % 8 + 1)))
    set -- "$kind" "$title" --detail "card $i of $count · sim-overflow" --seconds "$timeout"
    if [ "$i" -eq 1 ] && [ -n "$swap" ]; then
        # Still on screen when its update comes last, so the update swaps into it: the update waits
        # behind every other card past stack_max, and each of those grows out only as a card times out.
        set -- info "Deploying" --detail "card 1 of $count · --id sim-overflow" --id sim-overflow \
            --seconds "$(awk "BEGIN { q = $count - $max; if (q < 0) q = 0
                s = $timeout * (q + 2) + $count * $gap + 4; print (s > 60 ? 60 : s) }")"
    fi
    echo "drip $*"
    "$drip" "$@"
    i=$((i + 1))
    sleep "$gap"
done
if [ -n "$swap" ]; then
    echo "drip ok Deployed --id sim-overflow"
    "$drip" ok "Deployed" --detail "swapped in place · --id sim-overflow" --id sim-overflow --seconds "$timeout"
fi
