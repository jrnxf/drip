# Recipes

drip gives you building blocks: cards, `drip hook`, `drip watching`, `--on-click`. A recipe decides
when to notify. Recipes are examples. Read one, copy the part you want, and change it. Nothing is
installed for you, and no recipe is built into the drip binary.

Most recipes are a hook snippet for Claude Code, Codex and Gemini CLI. Each README has the snippet
in full, says which file it goes in, and says how to merge it by hand.

## Notify when

| Recipe | What it does |
| --- | --- |
| [permission-cards](permission-cards/) (suggested) | A card when the agent needs you, and nothing else |
| [attention](attention/) | Also a card when an error ends a turn |
| [everything](everything/) | Also a done card for every turn |
| [long-turns](long-turns/) | As everything, but no done card for a turn under 30 seconds |
| [approve-from-card](approve-from-card/) | permission-cards, with Allow and Deny on the card |
| [orchestrator](orchestrator/) | Many sessions at once: cards from the one you talk to, not its workers (no snippet) |

## Clicks and other tools

| Recipe | What it does |
| --- | --- |
| [click-herdr](click-herdr/) | A click focuses the herdr tab and pane |
| [click-wezterm](click-wezterm/) | A click focuses the WezTerm pane |
| [click-ghostty-spaces](click-ghostty-spaces/) | A click focuses the Ghostty terminal across Spaces |
| [quiet-while-watching](quiet-while-watching/) | Run a command only when you are not watching, with `drip watching` |
| [zsh-slow-commands](zsh-slow-commands/) | A card when a command in zsh runs 10 seconds or more |
| [aider](aider/) | A card when Aider is done |
| [opencode](opencode/) | A card for opencode's permissions and idle sessions |

Use one notify recipe per agent.
