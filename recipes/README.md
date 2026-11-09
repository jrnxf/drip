# Recipes

drip gives you building blocks: cards, `drip hook`, `drip setup`, `drip watching`. A recipe decides
when to notify. Nothing is installed until you pick one. No recipe is built into the drip binary.

A recipe is a folder of plain files: a `README.md`, and one hook snippet per agent
(`claude.json`, `codex.json`, `gemini.json`). Read it, install it with
`drip setup <agent> recipes/<name>/<agent>.json`, and edit it as you like.

## Notify when

| Recipe | What it does |
| --- | --- |
| [permission-cards](permission-cards/) (suggested) | A card when the agent needs you, and nothing else |
| [attention](attention/) | Also a card when an error ends a turn |
| [everything](everything/) | Also a done card for every turn |
| [long-turns](long-turns/) | As everything, but no done card for a turn under 30 seconds |
| [approve-from-card](approve-from-card/) | permission-cards, with Allow and Deny on the card |
| [orchestrator](orchestrator/) | The lead session only, not its workers (no snippet) |

## Clicks and other tools

| Recipe | What it does |
| --- | --- |
| [click-herdr](click-herdr/) | A click focuses the herdr tab and pane |
| [click-wezterm](click-wezterm/) | A click focuses the WezTerm pane |
| [click-ghostty-spaces](click-ghostty-spaces/) | A click focuses the Ghostty terminal across Spaces |
| [quiet-while-watching](quiet-while-watching/) | Run a command only when you are not watching, with `drip watching` |
| [aider](aider/) | A card when Aider is done |
| [opencode](opencode/) | A card for opencode's permissions and idle sessions |

Install one notify recipe per agent. A new `drip setup` replaces the hooks of the last one.
