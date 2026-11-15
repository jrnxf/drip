#!/bin/sh
# Writes llms-full.txt: the summary from web/public/llms.txt, then drip's own Markdown (install,
# usage, the contract, config, coding agents, every recipe, remote, troubleshooting, comparison)
# in one plain file, so an agent needs no other fetch. Each file starts with "# Source: <path>"
# and its relative links become absolute GitHub URLs. Nothing is written by hand, so it cannot
# go stale. Usage: web/llms-full.sh [output file], default web/dist/llms-full.txt.
set -eu

web=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$web")
out=${1:-$web/dist/llms-full.txt}
repo=https://github.com/jrnxf/drip
mkdir -p "$(dirname "$out")"

# Copies a Markdown file under a Source heading. Relative links, resolved from the file's own
# directory, become absolute GitHub URLs: blob for files, tree for directories.
emit() {
    printf '\n\n---\n\n# Source: %s\n\n' "$1"
    awk -v dir="$(dirname "$1")" -v root="$root" -v repo="$repo" '
        function resolve(path,    n, parts, i, out, k) {
            n = split(dir == "." ? path : dir "/" path, parts, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "" || parts[i] == ".") continue
                if (parts[i] == "..") { if (k > 0) k--; continue }
                out[++k] = parts[i]
            }
            path = ""
            for (i = 1; i <= k; i++) path = path (i > 1 ? "/" : "") out[i]
            return path
        }
        function absolute(target,    anchor, path, isdir) {
            if (target ~ /^([a-z][a-z0-9+.-]*:|#|\/)/) return target
            anchor = ""
            if (match(target, /#.*/)) { anchor = substr(target, RSTART); target = substr(target, 1, RSTART - 1) }
            path = resolve(target)
            isdir = (system("test -d \"" root "/" path "\"") == 0)
            return repo "/" (isdir ? "tree" : "blob") "/main/" path anchor
        }
        {
            line = $0; result = ""
            while (match(line, /\]\([^)]*\)/)) {
                start = RSTART; length_ = RLENGTH   # absolute() runs match() too
                result = result substr(line, 1, start + 1) absolute(substr(line, start + 2, length_ - 3)) ")"
                line = substr(line, start + length_)
            }
            print result line
        }' "$root/$1"
}

{
    cat "$web/public/llms.txt"
    for file in \
        docs/install.md docs/usage.md docs/contract.md docs/config.md docs/coding-agents.md \
        recipes/README.md $(cd "$root" && ls recipes/*/README.md) \
        docs/remote.md docs/troubleshooting.md docs/comparison.md; do
        emit "$file"
    done
} > "$out"

wc -c < "$out" | awk '{ print "llms-full.txt: " $1 " bytes" }' >&2
