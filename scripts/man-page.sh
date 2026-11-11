#!/bin/sh
# Writes drip.1 for a drip binary: scripts/man-page.sh <binary> <output-directory>
# Run from the repository root, with Swift. The release job and a source build both use it.
#
# The page comes from swift-argument-parser's generate-manual, run on the binary itself, so it
# documents what the binary does. Two things drip --help leaves out are also left out here:
# the hidden subcommands (__render, __background, __finished), and drip run's --version, which
# drip run rejects. The date is the commit's, so a rebuild of the same commit gives the same page.
set -eu

binary="$1"
out="$2"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

swift run -c release generate-manual "$binary" --output-directory "$raw" \
  --date "$(git log -1 --format=%cs)"

mkdir -p "$out"
awk '
  /^\.It Em __/ { hidden = 1; depth = 0; next }
  hidden && /^\.Bl/ { depth++; next }
  hidden && /^\.El/ { if (depth > 0) { depth--; next } hidden = 0 }
  hidden && /^\.It/ && depth == 0 { hidden = 0 }
  hidden { next }
  /^\.It Em run$/ { in_run = 1 }
  /^\.It Em / && !/^\.It Em run$/ { in_run = 0 }
  in_run && /^\.It Fl -version$/ { getline; next }
  { print }
' "$raw/drip.1" > "$out/drip.1"

# Fails the caller when the page still shows a hidden subcommand, or is not a man page.
if grep -q '__' "$out/drip.1"; then
  echo "drip.1 still lists a hidden subcommand" >&2
  exit 1
fi
grep -qx '\.Dt DRIP 1' "$out/drip.1"
grep -qx '\.Sh NAME' "$out/drip.1"
mandoc -T lint -W error "$out/drip.1"
