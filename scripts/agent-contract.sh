#!/bin/sh
# Checks drip's hooks against the latest Claude Code, Codex and Gemini CLI, live: one short session of
# each in a terminal of its own, through the hooks `drip setup` writes, so a change in what an agent's
# hooks send shows up here before it shows up as cards that never come or never go. Runs on a locked
# Mac too, and shows nothing at the notch.
#
#   scripts/agent-contract.sh                  every agent
#   scripts/agent-contract.sh --only codex     some of them: claude, codex, gemini
#   scripts/agent-contract.sh --keep           keeps each agent's scratch world (homes, state, sessions)
#   scripts/agent-contract.sh --setup          the one-time logins (a Claude Code token, a Gemini API key), then a check
#   scripts/agent-contract.sh --drift DIR      the drift report alone, for the payloads a run kept
#
# Exits 0 when every agent passed, 1 when any failed or the check itself could not run (last.json
# says error, and why), 2 when the only trouble is an agent that needs a login, which never prompts
# or opens a browser outside --setup, 3 when there is no GUI session (over ssh, or from launchd
# outside the logged-in user's session), when it runs no agent at all, and 4 when another check is
# running, which it leaves alone with its last.json. Each run keeps last.json, a summary and each
# try's payloads in ~/.cache/drip-agent-contract/runs/<time>/, and the latest last.json in
# ~/.cache/drip-agent-contract too: it says running while a check runs.
#
# Everything lives in ~/.cache/drip-agent-contract: the agents, installed afresh with npm every run,
# drip's state and the agents' homes. Your own agents, their settings and your PATH stay as they
# are. Claude Code's long-lived token and Gemini CLI's API key are in the Keychain (service
# drip-agent-contract, accounts claude and gemini), and Codex uses your own login, through a link
# to ~/.codex/auth.json.
set -eu

# --drift DIR is where you ran this from.
caller=$PWD
cd "$(dirname "$0")/.."

cache="${XDG_CACHE_HOME:-$HOME/.cache}/drip-agent-contract"
mkdir -p "$cache"

# Stops before the harness could start, saying why in last.json too, so a scheduler never reads an
# older check's result: only while no other check holds the lock, whose last.json stays as it is, and
# never for --drift, which leaves last.json alone.
stop() {
    echo "agent-contract: $1" >&2
    if [ -z "$drift" ]; then
        /usr/bin/lockf -k -s -t 0 "$cache/lock" /bin/sh -c '
            printf "{\n  \"version\" : 1,\n  \"status\" : \"error\",\n  \"exit\" : 1,\n  \"reason\" : \"%s\"\n}\n" "$1" >"$2/last.json.tmp" &&
                mv "$2/last.json.tmp" "$2/last.json"' sh "$1" "$cache" || true
    fi
    exit 1
}

if [ "$(uname -s)" != Darwin ]; then
    echo "agent-contract: run this on a Mac" >&2
    exit 1
fi

# The harness's own arguments: less --setup, which is its mode, and with --drift's folder whole.
mode=run
drift=""
for argument in "$@"; do
    shift
    case $argument in
    --setup)
        mode=setup
        continue
        ;;
    --drift) drift=next ;;
    *)
        if [ "$drift" = next ]; then
            case $argument in /*) ;; *) argument="$caller/$argument" ;; esac
            drift=$argument
        fi
        ;;
    esac
    set -- "$@" "$argument"
done

# A launchd job starts with a short PATH: look where the tools usually are, after yours.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin"
for tool in node npm tmux swift swiftc; do
    command -v "$tool" >/dev/null 2>&1 || stop "needs $tool on PATH"
done

# Built aside and moved into place, so a check that is running keeps the harness it started with.
harness="$cache/harness"
source=scripts/agent-contract/Contract.swift
digest=$(shasum -a 256 "$source" | cut -d' ' -f1)
if [ ! -x "$harness" ] || [ "$(cat "$harness.source" 2>/dev/null)" != "$digest" ]; then
    swiftc -O -o "$harness.new.$$" "$source" || stop "the harness did not build"
    mv "$harness.new.$$" "$harness"
    echo "$digest" >"$harness.source"
fi

# The drift report reads payloads a run kept: it needs no agent and no drip.
if [ -n "$drift" ]; then
    exec "$harness" drift --repo "$PWD" "$@"
fi

# Keeps the Mac awake while the agents work.
caffeinate -i -w $$ &

# The harness takes the lock, then installs the agents and builds drip: one check at a time.
exec "$harness" "$mode" --repo "$PWD" --cache "$cache" --tmux "$(command -v tmux)" --npm "$(command -v npm)" \
    --swift "$(command -v swift)" --node-bin "$(dirname "$(command -v node)")" "$@"
