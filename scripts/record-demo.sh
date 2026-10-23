#!/bin/sh
# Records docs/demo.mp4 and docs/demo.gif: real drip cards at the notch, filmed with macOS's own
# screen recording at the screen's native pixels. Run it on a Mac with a clean wallpaper; the
# first run asks for Screen Recording permission for your terminal. Needs ffmpeg
# (`brew install ffmpeg`). Re-run it for a new take.
#
# Only the macOS-specific part is in "Record"; the encoding after it is plain ffmpeg.
set -eu

cd "$(dirname "$0")/.."

die() {
    echo "record-demo: $1" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || die "run this on a Mac: it films the real notch with screencapture"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is missing. Fix: brew install ffmpeg"

swift build -c release
drip=$(swift build -c release --show-bin-path)/drip

# The screen under the pointer, as "x y width height" in points, with the origin at the top left
# of the main display (what screencapture -R takes): 800 points wide around the screen's middle
# and 240 tall from its top edge, enough for the widest card with its shadow. Prints nothing and
# exits 3 when the terminal has no Screen Recording permission.
region=$(swift - <<'SWIFT'
import AppKit
guard CGPreflightScreenCaptureAccess() else { exit(3) }
let mouse = NSEvent.mouseLocation
let screens = NSScreen.screens
let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
let mainHeight = screens[0].frame.height
let width = min(800.0, screen.frame.width)
let x = screen.frame.midX - width / 2
let y = mainHeight - screen.frame.maxY
print(Int(x), Int(y), Int(width), 240)
SWIFT
) || {
    code=$?
    [ "$code" -eq 3 ] || die "could not read the screen layout"
    # Asks once, so the terminal shows up in the list.
    swift -e 'import AppKit; _ = CGRequestScreenCaptureAccess()' >/dev/null 2>&1 || true
    die "Screen Recording is not allowed for this terminal. Fix: System Settings > Privacy & Security > Screen & System Audio Recording, turn on your terminal, quit and reopen it, then run this again"
}
read -r x y w h <<EOF2
$region
EOF2
crop="$x,$y,$w,$h"

rec=
work=$(mktemp -d)
trap '[ -z "$rec" ] || kill "$rec" 2>/dev/null || true; rm -rf "$work"' EXIT

# The built-in look, whatever the local config and environment say: an empty config directory.
export XDG_CONFIG_HOME="$work"
unset DRIP_SECONDS DRIP_SIZE DRIP_SOUND DRIP_MOTION DRIP_STACK DRIP_STACK_MAX

# Record: -x mutes the shutter sound, -V films for that many seconds, -R is the region at native
# pixels. The take is the cards below with their sleeps, plus room for each card to grow and go.
take=20
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
screencapture -x -V "$take" -R "$crop" "$work/take.mov" &
rec=$!
start=$(now)
sleep 2

"$drip" ok "Build finished" -d "make test: 246 passed in 3.2s" --seconds 3 --wait
sleep 0.8
"$drip" info "Claude needs you" -d "Claude needs your permission to use Bash" --icon mark:claude --stay --id demo
sleep 3
# The same id replaces the agent's card in place.
"$drip" fail "Deploy failed" -d "staging: health check timed out after 30s" --seconds 3 --id demo --wait
sleep 0.8
# Nobody answers, so it times out after 3 seconds (exit 5).
"$drip" warn "Deploy to prod?" -d "v1.4.0" --yes Deploy --no Cancel --seconds 3 || true
# The demo ends 1.5 seconds after the last card times out, enough for it to go.
length=$(awk -v start="$start" -v end="$(now)" 'BEGIN { printf "%.2f", end - start + 1.5 }')

if ! kill -0 "$rec" 2>/dev/null; then
    wait "$rec" || die "screencapture failed. Check Screen Recording permission for this terminal"
    die "the cards ran past the $take second take. Fix: raise take in this script"
fi
wait "$rec" || true
rec=
[ -s "$work/take.mov" ] || die "the recording is empty. Check Screen Recording permission for this terminal"

# Encode, cut at the end of the demo.
ffmpeg -y -loglevel error -t "$length" -i "$work/take.mov" -an -c:v libx264 -crf 14 -preset slow \
    -pix_fmt yuv420p -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart docs/demo.mp4

# The README animation: a palette built from the whole demo, at 2x the 400 points it is shown at,
# stepped down in frame rate and then width until it is under 5 MB.
limit=5000000
for settings in 24:800 20:800 15:800 15:640 12:560; do
    fps=${settings%:*}
    width=${settings#*:}
    ffmpeg -y -loglevel error -t "$length" -i "$work/take.mov" -filter_complex \
        "fps=$fps,scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        -loop 0 docs/demo.gif
    size=$(wc -c <docs/demo.gif)
    [ "$size" -le "$limit" ] && break
done
[ "$size" -le "$limit" ] || echo "record-demo: docs/demo.gif is $size bytes, over 5 MB; shorten the take" >&2
echo "docs/demo.mp4 and docs/demo.gif written (gif: $fps fps, $width px, $size bytes)"
