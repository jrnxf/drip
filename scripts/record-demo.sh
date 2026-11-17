#!/bin/sh
# Records demo.mp4 and demo.webp: real drip cards at the notch, filmed with macOS's own
# screen recording at the screen's native pixels. Run it on a Mac with a clean wallpaper; the
# first run asks for Screen Recording permission for your terminal. Needs ffmpeg and img2webp
# (`brew install ffmpeg webp`). Re-run it for a new take.
#
# The files stay out of this repo, so the takes do not grow its history: the README shows
# drip/demo.webp from the jrnxf/assets repo, and a new take goes there by hand.
#
#   scripts/record-demo.sh          # the whole demo, into .build/record-demo/ and the README's image width
#   scripts/record-demo.sh --test   # one card, into .build/record-demo-test/, to check the look
#
# Only the macOS-specific part is in "Record"; the encoding after it is plain ffmpeg.
set -eu

cd "$(dirname "$0")/.."

test=
case "${1:-}" in
    "") ;;
    --test) test=1 ;;
    *) echo "usage: scripts/record-demo.sh [--test]" >&2; exit 2 ;;
esac
if [ -n "$test" ]; then
    out=.build/record-demo-test
else
    out=.build/record-demo
fi
mkdir -p "$out"

say() {
    echo "record-demo: $1"
}

die() {
    echo "record-demo: $1" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || die "run this on a Mac: it films the real notch with screencapture"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is missing. Fix: brew install ffmpeg"
command -v img2webp >/dev/null 2>&1 || die "img2webp is missing. Fix: brew install webp"

say "building drip"
swift build -c release
drip=$(swift build -c release --show-bin-path)/drip

# The screen under the pointer, as "x y width height" in points, with the origin at the top left
# of the main display (what screencapture -R takes), then the menu bar's height with a margin, then the notch's
# width, height and middle from the region's left edge (0 0 0 on a screen without one), as drip
# finds it. screencapture films what is drawn, never the notch, so the encode draws it in, at the
# same place and size. The region is 800 points wide around the notch, the width the demo keeps,
# and 306 tall: a full stack of three cards and the overflow drop under it end 274 points down,
# and a notch's height of space (32 points) is left under them. The encode trims the height to the
# cards with the same space under them, should they end higher.
# Prints nothing and exits 3 when the terminal has no Screen Recording permission.
region_width=800
region_height=306
region=$(swift - "$region_width" "$region_height" <<'SWIFT'
import AppKit
guard CGPreflightScreenCaptureAccess() else { exit(3) }
let mouse = NSEvent.mouseLocation
let screens = NSScreen.screens
let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
let mainHeight = screens[0].frame.height
let width = min(Double(CommandLine.arguments[1])!, screen.frame.width)
let x = (screen.frame.midX - width / 2).rounded(.down)
let y = mainHeight - screen.frame.maxY
let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
var notch = "0 0 0"
if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
   let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
    notch = "\(right.minX - left.maxX) \(screen.safeAreaInsets.top) \((left.maxX + right.minX) / 2 - x)"
}
print(Int(x), Int(y), Int(width), CommandLine.arguments[2], Int(max(menuBar, screen.safeAreaInsets.top, 24) + 6), notch)
SWIFT
) || {
    code=$?
    [ "$code" -eq 3 ] || die "could not read the screen layout"
    # Asks once, so the terminal shows up in the list.
    swift -e 'import AppKit; _ = CGRequestScreenCaptureAccess()' >/dev/null 2>&1 || true
    die "Screen Recording is not allowed for this terminal. Fix: System Settings > Privacy & Security > Screen & System Audio Recording, turn on your terminal, quit and reopen it, then run this again"
}
read -r x y w h menubar nw nh nmid <<EOF2
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
# screencapture cannot stop early (a signal loses the file), so the take is just longer than the
# cards: the demo runs about 24 seconds and the test about 6.
take=26
[ -z "$test" ] || take=8
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
say "recording for up to $take seconds: hands off until the cards are gone"
screencapture -x -V "$take" -R "$crop" "$work/take.mov" &
rec=$!
start=$(now)
sleep 1.5

if [ -n "$test" ]; then
    "$drip" ok "Deployed to staging" -d "v1.4.0 in 2m 41s" --open https://example.com --button View \
        --seconds 3 --wait
else
    # One story in four beats, each showing a different part of drip.
    # 1. A deploy reports progress on one card: the same --id updates it in place.
    "$drip" info "Deploying v1.4.0" -d "building" --id deploy --stay
    sleep 1.2
    "$drip" info "Deploying v1.4.0" -d "tests: 246 passed in 3.2s" --id deploy --stay
    sleep 1.2
    # 2. It ends green, with a button that opens a link.
    "$drip" ok "Deployed to staging" -d "v1.4.0 in 2m 41s" --id deploy --open https://example.com \
        --button View --seconds 7
    sleep 0.9
    # 3. A coding agent needs you, then a burst of cards: three show at once, and the two with no room
    # wait in a drop under the stack that counts them, then grow out of it as cards above leave.
    "$drip" info "Claude needs you" -d "Allow Bash: npm run migrate" --icon mark:claude --seconds 6
    sleep 0.4
    "$drip" ok "Lint passed" -d "0 warnings in 212 files" --seconds 3
    sleep 0.3
    "$drip" warn "Disk almost full" -d "92% used on /" --seconds 3
    sleep 0.3
    "$drip" fail "e2e failed" -d "checkout.spec.ts: 2 of 41" --seconds 3 --wait
    # 4. A question waits for a click. Nobody answers, so it times out after 3 seconds (exit 5).
    "$drip" warn "Ship v1.4.0 to prod?" -d "staging is healthy" --yes Ship --no Cancel --seconds 3 || true
fi
# The demo ends 1.5 seconds after the last card times out, enough for it to go.
length=$(awk -v start="$start" -v end="$(now)" 'BEGIN { printf "%.2f", end - start + 1.5 }')

if ! kill -0 "$rec" 2>/dev/null; then
    wait "$rec" || die "screencapture failed. Check Screen Recording permission for this terminal"
fi
awk -v l="$length" -v t="$take" 'BEGIN { exit !(l < t - 0.3) }' ||
    die "the cards ran past the $take second take. Fix: raise take in this script"
left=$(awk -v l="$length" -v t="$take" 'BEGIN { printf "%d", t - l + 1.5 + 0.5 }')
say "the cards are done. The recording stops by itself in about $left seconds"
wait "$rec" || true
rec=
[ -s "$work/take.mov" ] || die "the recording is empty. Check Screen Recording permission for this terminal"

say "recorded. Processing now, which can take a few minutes"
say "finding where the cards are"

# Trim to the cards: every pixel that differs from the first frame, before any card, below the
# menu bar (whose clock and icons can change), gives the largest area the cards cover. Both are
# blurred first, so a wallpaper's grain, which the recording redraws a little in every frame,
# averages out, and the first 0.3 seconds are left out, as the take can start on a stray frame.
# cropdetect with reset 0 keeps that largest area, and its last line is the answer. The crop keeps
# the full width and ends a notch's height (32 points without a notch) below the lowest card.
ffmpeg -y -loglevel error -ss 0.2 -i "$work/take.mov" -frames:v 1 "$work/empty.png"
px=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$work/take.mov")
pw=${px%,*}
ph=${px#*,}
scale=$(awk -v pw="$pw" -v w="$w" 'BEGIN { printf "%.4f", pw / w }')
skip=$(awk -v m="$menubar" -v s="$scale" 'BEGIN { printf "%d", m * s }')
found=$(ffmpeg -hide_banner -nostats -i "$work/take.mov" -loop 1 -i "$work/empty.png" \
    -filter_complex "[0:v]trim=start=0.3:end=$length,format=gray,boxblur=6:1[a];[1:v]format=gray,boxblur=6:1[b];[a][b]blend=all_mode=difference:shortest=1,lut=c0='if(gt(val,16),255,0)',crop=iw:ih-$skip:0:$skip,cropdetect=limit=0.02:round=2:reset=0:skip=0" \
    -f null - 2>&1 | sed -n 's/.*crop=\([0-9]*\):\([0-9]*\):\([0-9]*\):\([0-9]*\).*/\1 \2 \3 \4/p' | tail -n 1)
[ -n "$found" ] || die "no card showed in the recording. Check that drip runs and the pointer is on the notch screen"
read -r cw ch cx cy <<EOF3
$found
EOF3
# Something that reaches the region's bottom edge was cut off: a stack taller than the region, or
# a window that moved in.
[ $((skip + cy + ch)) -lt $((ph - 2)) ] ||
    die "something reached the bottom of the recording: a stack taller than the region, or a window that moved in. Fix: keep the top middle of the screen clear, or raise region_height in this script, then run this again"

# The notch, drawn black over the take: its sides straight down from the top edge, its bottom
# corners rounded as drip rounds them, and its top corners curving out into the top edge as the
# screen's do. On a screen without a notch it is a 1 pixel dot off to the side, so the filter
# stays the same.
flare=6
notchpng="$work/notch.png"
if [ "$nw" = 0 ]; then
    notchx=-10
    ffmpeg -y -loglevel error -f lavfi -i "color=c=black@0:s=2x2,format=rgba" -frames:v 1 "$notchpng"
else
    swift - "$nw" "$nh" "$flare" "$scale" "$notchpng" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
let (w, h, r, s) = (Double(a[1])!, Double(a[2])!, Double(a[3])!, Double(a[4])!)
let bottom = min(10, h / 3)
let size = (width: Int(((w + 2 * r) * s).rounded()), height: Int((h * s).rounded()))
let context = CGContext(
    data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: CGFloat(size.height))
context.scaleBy(x: CGFloat(s), y: -CGFloat(s))
let path = CGMutablePath()
path.move(to: CGPoint(x: 0, y: 0))
path.addArc(tangent1End: CGPoint(x: r, y: 0), tangent2End: CGPoint(x: r, y: h), radius: r)
path.addArc(tangent1End: CGPoint(x: r, y: h), tangent2End: CGPoint(x: r + w, y: h), radius: bottom)
path.addArc(tangent1End: CGPoint(x: r + w, y: h), tangent2End: CGPoint(x: r + w, y: 0), radius: bottom)
path.addArc(tangent1End: CGPoint(x: r + w, y: 0), tangent2End: CGPoint(x: 2 * r + w, y: 0), radius: r)
path.addLine(to: CGPoint(x: 2 * r + w, y: 0))
path.closeSubpath()
context.addPath(path)
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fillPath()
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[5]))
SWIFT
    notchx=$(awk -v m="$nmid" -v w="$nw" -v r="$flare" -v s="$scale" 'BEGIN { printf "%d", (m - w / 2 - r) * s + 0.5 }')
fi
cut=$(awk -v pw="$pw" -v ph="$ph" -v ch="$ch" -v cy="$cy" -v skip="$skip" -v s="$scale" -v nh="$nh" 'BEGIN {
    below = (nh > 0 ? nh : 32) * s
    width = 2 * int(pw / 2)
    height = skip + cy + ch + below
    if (height > ph) height = ph
    height = 2 * int(height / 2)
    printf "%d %d %d", width, height, int((pw - width) / 2)
}')
read -r tw th tx <<EOF4
$cut
EOF4
trim="[0:v][1:v]overlay=$notchx:0,crop=$tw:$th:$tx:0"

say "writing $out/demo.mp4"

# Encode, cut at the end of the demo.
ffmpeg -y -loglevel error -t "$length" -i "$work/take.mov" -i "$notchpng" -an -c:v libx264 -crf 14 \
    -preset slow -pix_fmt yuv420p -filter_complex "$trim" -movflags +faststart "$out/demo.mp4"

# The README animation: an animated WebP at 60 fps and 2x the points it is shown at, in full
# colour. ffmpeg writes the frames and img2webp joins them, as Homebrew's ffmpeg has no WebP
# encoder. WebP frame times are whole milliseconds, so they go 17, 17, 16: exactly 50 ms for
# every 3 frames, which keeps the demo at its real speed. The README shows it at its width in
# points, so the script sets that width on the README's image.
fps=60
points=$(awk -v tw="$tw" -v s="$scale" 'BEGIN { printf "%d", tw / s + 0.5 }')
width=$((points * 2))
say "writing the frames"
mkdir "$work/frames"
ffmpeg -y -loglevel error -t "$length" -i "$work/take.mov" -i "$notchpng" \
    -filter_complex "$trim,fps=$fps,scale=$width:-2:flags=lanczos" "$work/frames/%05d.png"
[ -n "$test" ] || sed -i '' "s|\(<img src=\"[^\"]*/drip/demo.webp\" width=\"\)[0-9]*\"|\1$points\"|" README.md
set --
n=0
for frame in "$work"/frames/*.png; do
    case $((n % 3)) in 2) ms=16 ;; *) ms=17 ;; esac
    set -- "$@" -d "$ms" "$frame"
    n=$((n + 1))
done
say "joining $n frames into $out/demo.webp, the slow part"
img2webp -loop 0 -min_size -lossy -q 90 -m 6 -sharp_yuv "$@" -o "$out/demo.webp" >/dev/null 2>&1
size=$(($(wc -c <"$out/demo.webp")))
limit=5000000
[ "$size" -le "$limit" ] || echo "record-demo: $out/demo.webp is $size bytes, over 5 MB; a plainer wallpaper makes it smaller" >&2
root=$(pwd)
say "done ($fps fps, $width px for $points points, $n frames, $size bytes). Saved to:"
echo "  $root/$out/demo.webp"
echo "  $root/$out/demo.mp4"
[ -n "$test" ] || {
    echo "  $root/README.md now shows it $points points wide"
    say "the README shows drip/demo.webp from the jrnxf/assets repo: put this take there to publish it"
}
