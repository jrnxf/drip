#!/bin/sh
# Writes drip.1 for a drip binary: scripts/man-page.sh <binary> <output-directory>
# Run from the repository root, with Swift. The release job and a source build both use it.
#
# The page comes from swift-argument-parser's generate-manual, run on the binary itself, so it
# documents what the binary does. Two things drip --help leaves out are also left out here: the
# subcommands the binary marks as hidden, and drip run's --version, which drip run rejects. The
# date is the commit's, so a rebuild of the same commit gives the same page.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: scripts/man-page.sh <binary> <output-directory>" >&2
  exit 2
fi
binary="$1"
out="$2"

date="$(git log -1 --format=%cs)" || date=""
if [ -z "$date" ]; then
  echo "scripts/man-page.sh: git log gave no commit date, so the page cannot be dated" >&2
  exit 1
fi

raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

# The subcommands the binary marks hidden, one per line, from its own help dump.
"$binary" --experimental-dump-help > "$raw/help.json"
python3 -I -c '
import json, sys
def hidden(command):
    for sub in command.get("subcommands") or []:
        if not sub.get("shouldDisplay", True):
            print(sub["commandName"])
        hidden(sub)
with open(sys.argv[1]) as f:
    hidden(json.load(f)["command"])
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
  in_run && /^\.It Fl -version$/ { getline; next }
  /^\.Ex -std$/ {
    print ".Bl -tag -width 6n"
    print ".It 0"
    print "Success, or a yes answer."
    print ".It 1"
    print "A no answer, or drip could not do its work. It says why on stderr."
    print ".It 2"
    print "A usage error, in the command line or in a DRIP_* variable."
    print ".It 3"
    print "No GUI session, for example over ssh."
    print ".It 4"
    print "drip doctor: the config file is invalid."
    print ".It 5"
    print "A --yes question waited, and no button was clicked."
    print ".El"
    print ".Pp"
    print "drip run exits with the wrapped command'\''s exit code, 127 when it is not found."
    print "The full table is in docs/contract.md in the drip repository."
    next
  }
  { print }
' "$raw/drip.1" > "$out/drip.1"

# Fails the caller when the page still lists a hidden subcommand as an entry.
for name in $names; do
  if grep -q "^\.It Em $name\$" "$out/drip.1"; then
    echo "drip.1 still lists the hidden subcommand $name" >&2
    exit 1
  fi
done
grep -qx '\.Dt DRIP 1' "$out/drip.1"
grep -qx '\.Sh NAME' "$out/drip.1"
mandoc -T lint -W error "$out/drip.1"
