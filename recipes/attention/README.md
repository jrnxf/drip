# attention

A card for everything that needs you: a permission, a question, and an error that ends a turn.

For: people who want to know when a turn dies, as with a rate limit or an outage, but not when it ends well.

## How it works

[permission-cards](../permission-cards/) plus Claude's `StopFailure`, which shows a `fail` card
with the error. Codex and Gemini have no such event, so their snippets match permission-cards.

## Install

```sh
drip setup claude recipes/attention/claude.json   # Claude Code, in ~/.claude/settings.json
drip setup codex recipes/attention/codex.json     # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini recipes/attention/gemini.json   # Gemini CLI, in ~/.gemini/settings.json
```

Or pipe a snippet: `curl -fsSL <raw-url> | drip setup claude -`. Read it first.

`drip setup` keeps every other hook, backs the old file up next to it, and replaces drip's own
earlier hooks. It never writes a file that is a symlink, read-only or not plain JSON: it says why
and exits 1. Run it again with another recipe to switch. See the [reference](../../docs/agents.md#drip-setup).

## Change it

Edit the JSON and run `drip setup` again.
