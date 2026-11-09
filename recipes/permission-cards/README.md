# permission-cards (suggested)

A card when the agent needs you: a permission, or a question. Nothing else.

For: most people. It is the quiet start. You hear from the agent only when it is blocked.

## How it works

The snippet adds `drip hook <agent>` on the events where the agent waits for you:
`PermissionRequest` and Claude's `elicitation_dialog` notification (Gemini: `Notification`).
It adds the events that take the card away when you answer in the terminal (`PostToolUse`,
`UserPromptSubmit` and so on). There is no hook on turn end, so no done card.
The card stays until you answer, click it, or 10 minutes pass.

## Install

```sh
drip setup claude recipes/permission-cards/claude.json   # Claude Code, in ~/.claude/settings.json
drip setup codex recipes/permission-cards/codex.json     # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini recipes/permission-cards/gemini.json   # Gemini CLI, in ~/.gemini/settings.json
```

Or pipe a snippet: `curl -fsSL <raw-url> | drip setup claude -`. Read it first.

`drip setup` keeps every other hook, backs the old file up next to it, and replaces drip's own
earlier hooks. It never writes a file that is a symlink, read-only or not plain JSON: it says why
and exits 1. Run it again with another recipe to switch. See the [reference](../../docs/agents.md#drip-setup).

## Change it

Edit the JSON and run `drip setup` again. Add `Stop` for done cards (see [everything](../everything/)),
or add `--approve` to answer from the card (see [approve-from-card](../approve-from-card/)).
