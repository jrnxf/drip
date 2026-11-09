# everything

A card when the agent needs you, when a turn is done, and when it dies on an error.

For: one or two sessions at a time. With many sessions the done cards add up: use [long-turns](../long-turns/) or [attention](../attention/).

## How it works

[attention](../attention/) plus `Stop` (Gemini: `AfterAgent`). The done card shows the last thing the
agent wrote and replaces the waiting card of the session in place. This is the old default of drip.

## Install

```sh
drip setup claude recipes/everything/claude.json   # Claude Code, in ~/.claude/settings.json
drip setup codex recipes/everything/codex.json     # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini recipes/everything/gemini.json   # Gemini CLI, in ~/.gemini/settings.json
```

Or pipe a snippet: `curl -fsSL <raw-url> | drip setup claude -`. Read it first.

`drip setup` keeps every other hook, backs the old file up next to it, and replaces drip's own
earlier hooks. It never writes a file that is a symlink, read-only or not plain JSON: it says why
and exits 1. Run it again with another recipe to switch. See the [reference](../../docs/agents.md#drip-setup).

## Change it

Edit the JSON and run `drip setup` again. Add `--only needs-you` to a hook to skip its done card.
