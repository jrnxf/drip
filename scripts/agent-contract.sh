#!/bin/sh
# Checks drip's hooks against the latest Claude Code, Codex and Gemini CLI, live: one short session of
# each in a terminal of its own, through the hooks `drip setup` writes, so a change in what an agent's
# hooks send shows up here before it shows up as cards that never come or never go. Runs on a locked
# Mac too, and shows nothing at the notch.
#
#   scripts/agent-contract.sh                  every agent
#   scripts/agent-contract.sh --only codex     some of them: claude, codex, gemini
#   scripts/agent-contract.sh --keep           keeps each agent's scratch world (homes, state, sessions)
#   scripts/agent-contract.sh --setup          the one-time sign-ins, then a check
#   scripts/agent-contract.sh --drift DIR      the drift report alone, for the payloads a run kept
#
# Exits 0 when every agent passed, 1 when any failed, 2 when the only trouble is an agent that needs a
# login, which never prompts or opens a browser outside --setup, and 3 when there is no GUI session
# (over ssh, or from launchd outside the logged-in user's session), when it runs no agent at all. Each run keeps last.json, a
# summary and the payloads in ~/.cache/drip-agent-contract/runs/<time>/, and the latest last.json in
# ~/.cache/drip-agent-contract too.
#
# Everything lives in ~/.cache/drip-agent-contract: the agents, installed afresh with npm every run,
# drip's state and the agents' homes, and Gemini CLI's own Google sign-in. Your own agents, their
# settings and your PATH stay as they are. Claude Code's long-lived token is in the Keychain
# (service drip-agent-contract, account claude), and Codex uses your own login, through a link to
# ~/.codex/auth.json.
set -eu

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != Darwin ]; then
    echo "agent-contract: run this on a Mac" >&2
    exit 1
fi

# A launchd job starts with a short PATH: look where the tools usually are, after yours.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin"
for tool in node npm tmux swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "agent-contract: needs $tool on PATH" >&2
        exit 1
    fi
done

cache="${XDG_CACHE_HOME:-$HOME/.cache}/drip-agent-contract"
mkdir -p "$cache"

mode=run
drift=""
for argument in "$@"; do
    case $argument in
    --setup) mode=setup ;;
    --drift) drift=next ;;
    *) [ "$drift" = next ] && drift=$argument ;;
    esac
done

harness="$cache/harness"
source=scripts/agent-contract/Contract.swift
if [ ! -x "$harness" ] || [ "$(cat "$harness.source" 2>/dev/null)" != "$(shasum -a 256 "$source" | cut -d' ' -f1)" ]; then
    swiftc -O -o "$harness" "$source"
    shasum -a 256 "$source" | cut -d' ' -f1 >"$harness.source"
fi

# The drift report reads payloads a run kept: it needs no agent and no drip.
if [ -n "$drift" ]; then
    exec "$harness" drift --repo "$PWD" "$@"
fi

# drip records no card without a GUI session: then no agent runs, and last.json says why.
status=0
"$harness" session --repo "$PWD" --cache "$cache" || status=$?
[ "$status" -eq 0 ] || exit "$status"

echo "Installing the latest Claude Code, Codex and Gemini CLI"
tools="$cache/tools"
npm_config_cache="$cache/npm" npm_config_update_notifier=false npm install --prefix "$tools" --no-fund --no-audit \
    --loglevel=error @anthropic-ai/claude-code@latest @openai/codex@latest @google/gemini-cli@latest

# The hooks run drip as it is in this checkout.
swift build -c release

# Keeps the Mac awake while the agents work.
caffeinate -i -w $$ &

set -- --repo "$PWD" --cache "$cache" --tools "$tools/node_modules/.bin" --tmux "$(command -v tmux)" \
    --node-bin "$(dirname "$(command -v node)")" "$@"
if [ "$mode" = setup ]; then
    # Setup's own arguments, less --setup itself.
    for argument in "$@"; do
        shift
        [ "$argument" = --setup ] || set -- "$@" "$argument"
    done
    status=0
    "$harness" setup "$@" || status=$?
    [ "$status" -eq 1 ] && exit 1
    echo
    echo "Now the check itself, as the schedule runs it"
fi
exec "$harness" run "$@"
