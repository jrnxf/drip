#!/bin/sh
# Draws docs/demo.gif: the first three notch cards drip demo drops, in turn, frame by frame with the hidden
# `drip __render --at`, which draws the same layers the island shows. Needs ImageMagick (`magick`).
set -eu

cd "$(dirname "$0")/.."
swift build
drip=.build/debug/drip
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/config" "$work/frames"

frame=0
# Sets $out to the next frame's file.
next() {
    frame=$((frame + 1))
    out=$(printf '%s/frames/%04d.png' "$work" "$frame")
}
render() {
    next
    XDG_CONFIG_HOME="$work/config" "$drip" __render --out "$out" "$@"
}
# The entrance at 30 frames a second, the open card for 1.7 seconds, the exit, then a pause.
card() {
    for t in $(seq 0 0.0333 1.4); do render "$@" --at "$t"; done
    open=$out
    for _ in $(seq 50); do next; cp "$open" "$out"; done
    for t in $(seq 0 0.0333 0.9); do render "$@" --at "$t" --leaving; done
    closed=$out
    for _ in $(seq 12); do next; cp "$closed" "$out"; done
}
card ok "Build finished" --detail "make test: 246 passed in 3.2s" --position notch
card warn "Claude needs you" --detail "Claude needs your permission to use Bash" --position notch
card fail "Deploy failed" --detail "staging: health check timed out after 30s" --position notch

# Every frame on one canvas, wide enough for the widest card: the renderer's menu bar and desktop.
magick -size 800x64 xc:'rgb(199,199,199)' -size 800x174 xc:'rgb(230,230,230)' -append +repage \
    -colorspace sRGB -type TrueColorAlpha "PNG32:$work/canvas.png"
for f in "$work"/frames/*.png; do
    magick "$work/canvas.png" "$f" -gravity north -composite +repage -type TrueColorAlpha "PNG32:$f"
done
magick -delay 3.33 -loop 0 "$work"/frames/*.png -layers Optimize docs/demo.gif
echo "docs/demo.gif: $frame frames"
