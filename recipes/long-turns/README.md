# long-turns

Every card of [everything](../everything/), but no done card for a turn shorter than 30 seconds.

For: people who send many short prompts. You have a short turn in mind, so its done card is noise.

## How it works

The done and failure hooks run `drip hook <agent> --min-turn 30`. drip counts from the prompt you
sent, which `UserPromptSubmit` records. Cards that need you always show. For an agent on another
machine, `drip follow` applies the same filter.

## Install

```sh
drip setup claude recipes/long-turns/claude.json   # Claude Code, in ~/.claude/settings.json
drip setup codex recipes/long-turns/codex.json     # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini recipes/long-turns/gemini.json   # Gemini CLI, in ~/.gemini/settings.json
```

Or pipe a snippet: `curl -fsSL <raw-url> | drip setup claude -`. Read it first.

`drip setup` keeps every other hook, backs the old file up next to it, and replaces drip's own
earlier hooks. It never writes a file that is a symlink, read-only or not plain JSON: it says why
and exits 1. Run it again with another recipe to switch. See the [reference](../../docs/agents.md#drip-setup).

## Change it

Change 30 to another number of seconds (0 to 600) in the JSON, and run `drip setup` again.
