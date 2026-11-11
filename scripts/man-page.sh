#!/bin/sh
# Writes drip.1 for a drip binary:
#   scripts/man-page.sh [--check] <binary> <output-directory>
#
# Run it from anywhere; it moves to the repository root itself. The release job calls it with
# --check, which also lints the page with mandoc and fails on any error. A source build leaves
# --check out.
#
# Needs: python3 (reads the binary's help dump) and git (dates the page with the commit).
#
# The page comes from swift-argument-parser's generate-manual, run on the binary itself, so it
# documents what the binary does. Two things drip --help leaves out are also left out here: the
# top-level subcommands the binary marks hidden, and drip run's --version, which drip run rejects.
# The date is the commit's, so a rebuild of the same commit gives the same page.
set -eu

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
fi
if [ "$#" -ne 2 ]; then
  echo "usage: scripts/man-page.sh [--check] <binary> <output-directory>" >&2
  exit 2
fi

# The paths are the caller's, so make them absolute before moving to the repository root.
case "$1" in
  /*) binary="$1" ;;
  *) binary="$PWD/$1" ;;
esac
case "$2" in
  /*) out="$2" ;;
  *) out="$PWD/$2" ;;
esac
cd "$(dirname "$0")/.."

date="$(git log -1 --format=%cs)" || date=""
if [ -z "$date" ]; then
  echo "scripts/man-page.sh: git log gave no commit date, so the page cannot be dated" >&2
  exit 1
fi

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

# The top-level subcommands the binary marks hidden, one per line. A hidden subcommand nested
# under another is an error: this script drops top-level blocks only.
"$binary" --experimental-dump-help > "$raw/help.json"
python3 -I -c '
import json, sys
with open(sys.argv[1]) as f:
    top = json.load(f)["command"]
nested = []
for sub in top.get("subcommands") or []:
    for inner in sub.get("subcommands") or []:
        if not inner.get("shouldDisplay", True):
            nested.append(inner["commandName"])
if nested:
    sys.exit("scripts/man-page.sh: nested hidden subcommands are not handled: " + " ".join(nested))
for sub in top.get("subcommands") or []:
    if not sub.get("shouldDisplay", True):
        print(sub["commandName"])
' "$raw/help.json" > "$raw/hidden"
names="$(tr '\n' ' ' < "$raw/hidden")"

swift run -c release generate-manual "$binary" --output-directory "$raw" --date "$date"

mkdir -p "$out"
awk -v names="$names" '
  BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) hidden_name[list[i]] = 1 }
  /^\.It Em / && ($3 in hidden_name) { hiding = 1; depth = 0; next }
  hiding && /^\.Bl/ { depth++; next }
  hiding && /^\.El/ { if (depth > 0) { depth--; next } hiding = 0 }
  hiding && /^\.It/ && depth == 0 { hiding = 0 }
  hiding { next }
  /^\.It Em run$/ { in_run = 1 }
  /^\.It Em / && !/^\.It Em run$/ { in_run = 0 }
  in_run && /^\.It Fl -version$/ { dropping = 1; next }
  dropping && /^\.(It|El)/ { dropping = 0 }
  dropping { next }
  /^\.Ex -std$/ {
    print ".Pp"
    print "drip exits with a code that says how it ended. The EXIT CODES section of drip --help"
    print "lists them, and docs/contract.md in the drip repository has the full table."
    print ".Pp"
    print "drip run exits with the wrapped command'\''s exit code, 127 when it is not found."
    next
  }
  { print }
' "$raw/drip.1" > "$out/drip.1"

# Fails the caller when the page does not hold what it must.
for name in $names; do
  if grep -qxF ".It Em $name" "$out/drip.1"; then
    echo "scripts/man-page.sh: drip.1 still lists the hidden subcommand $name" >&2
    exit 1
  fi
done
if awk '/^\.It Em run$/ { r = 1; next } /^\.It Em / { r = 0 } r && /^\.It Fl -version$/ { f = 1 } END { exit !f }' "$out/drip.1"; then
  echo "scripts/man-page.sh: drip.1 still lists --version under drip run" >&2
  exit 1
fi
grep -qx '\.Dt DRIP 1' "$out/drip.1"
grep -qx '\.Sh NAME' "$out/drip.1"
grep -qx '\.Sh "EXIT STATUS"' "$out/drip.1"
if grep -q '\.Ex -std' "$out/drip.1"; then
  echo "scripts/man-page.sh: drip.1 still has the generic EXIT STATUS" >&2
  exit 1
fi
if [ "$check" -eq 1 ]; then
  mandoc -T lint -W error "$out/drip.1"
fi
