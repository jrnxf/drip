# approve-from-card

[permission-cards](../permission-cards/), and the permission card has Allow and Deny.

For: Claude Code and Codex users who want to answer without the terminal. Gemini has no such hook, so its snippet matches permission-cards.

## How it works

The `PermissionRequest` hook runs `drip hook <agent> --approve`. The hook waits on the card, and a
click is the agent's answer. Nothing clicked in 9 minutes prints nothing, and the terminal asks as
it would without drip. So does a click on the card itself, and the ×.
Off by default: a stray click allows a command, and a hook that waits is a change to choose.

The card shows the command, or the file or address the tool works on, never only the agent's
description of it. A command that does not fit the card whole, or that holds characters the card
does not draw, gets no Allow: the hook returns at once and the terminal asks. The buttons take a
click only once the card has been still for 0.4 seconds.

| Agent | When the card asks | Answered in the terminal instead |
| --- | --- | --- |
| Claude Code | Always: Claude asks in its terminal at the same time, and the first answer counts | A deny takes the card away at once. An allow, once the tool ends |
| Codex | Only while you are not watching its terminal: Codex asks there only once the hook returns | Go to the terminal while the card waits, and the card goes |

A card that comes up while the screen is locked or `drip pause` holds cards only tells. So does one
from [another machine](../../docs/remote.md): `--approve` is local only.

## Install

Add the `hooks` entry for your agent to its settings file. If the file has a `hooks` entry already, merge the events by hand and keep your own hooks. If it does not exist, create it with this content.

### Claude Code

File: `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json` if you set it)

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude --approve"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "elicitation_dialog",
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude"
          }
        ]
      }
    ],
    "ElicitationResult": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude"
          }
        ]
      }
    ]
  }
}
```

If each card comes with a second notification from Claude Code itself, set Local notifications to disabled in its `/config`.

### Codex

File: `~/.codex/hooks.json` (`$CODEX_HOME/hooks.json` if you set it)

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook codex --approve"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook codex"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook codex"
          }
        ]
      }
    ]
  }
}
```

Codex runs a new hook only after you trust it: run `/hooks` in Codex. If your `config.toml` has an older `notify = ["drip", "hook", "codex"]` line, delete it, or each done card shows twice.

### Gemini CLI

File: `~/.gemini/settings.json`

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "name": "drip",
            "type": "command",
            "command": "drip hook gemini"
          }
        ]
      }
    ],
    "AfterTool": [
      {
        "hooks": [
          {
            "name": "drip",
            "type": "command",
            "command": "drip hook gemini"
          }
        ]
      }
    ],
    "BeforeAgent": [
      {
        "hooks": [
          {
            "name": "drip",
            "type": "command",
            "command": "drip hook gemini"
          }
        ]
      }
    ]
  }
}
```

To switch to another recipe, replace drip's `hooks` entries with that recipe's. Every handler must run `drip hook <agent>`.
## Change it

Add `--approve` to any other `drip hook` command that can ask.
