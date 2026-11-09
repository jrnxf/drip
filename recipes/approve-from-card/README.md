# approve-from-card

[permission-cards](../permission-cards/), and the permission card has Allow and Deny.

For: Claude Code and Codex users who want to answer without the terminal. Gemini has no such hook, so its snippet matches permission-cards.

## How it works

The `PermissionRequest` hook runs `drip hook <agent> --approve`. The hook waits on the card, and a
click is the agent's answer. Nothing clicked in 9 minutes prints nothing, and the terminal asks as
it would without drip. So does a click on the card itself, and the ×.
Off by default: a stray click allows a command, and a hook that waits is a change to choose.

| Agent | When the card asks | Answered in the terminal instead |
| --- | --- | --- |
| Claude Code | Always: Claude asks in its terminal at the same time, and the first answer counts | A deny takes the card away at once. An allow, once the tool ends |
| Codex | Only while you are not watching its terminal: Codex asks there only once the hook returns | Go to the terminal while the card waits, and the card goes |

A card that comes up while the screen is locked or `drip pause` holds cards only tells. So does one
from [another machine](../../docs/remote.md): `--approve` is local only.

## Install

```sh
drip setup claude recipes/approve-from-card/claude.json   # Claude Code, in ~/.claude/settings.json
drip setup codex recipes/approve-from-card/codex.json     # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini recipes/approve-from-card/gemini.json   # Gemini CLI, in ~/.gemini/settings.json
```

Or pipe a snippet: `curl -fsSL <raw-url> | drip setup claude -`. Read it first.

`drip setup` keeps every other hook, backs the old file up next to it, and replaces drip's own
earlier hooks. It never writes a file that is a symlink, read-only or not plain JSON: it says why
and exits 1. Run it again with another recipe to switch. See the [reference](../../docs/agents.md#drip-setup).

## Change it

Edit the JSON and run `drip setup` again.
