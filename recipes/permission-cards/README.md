# permission-cards (suggested)

A card when the agent needs you: a permission, or a question. Nothing else.

For: most people. It is the quiet start. You hear from the agent only when it is blocked.

## How it works

The snippet adds `drip hook <agent>` on the events where the agent waits for you:
`PermissionRequest` and Claude's `elicitation_dialog` notification (Gemini: `Notification`).
It also adds the events that take the card away when you answer in the terminal (`PostToolUse`,
`UserPromptSubmit` and so on). There is no hook on turn end, so no done card.
The card stays until you answer, click it, or 10 minutes pass.

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
            "command": "drip hook claude"
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
            "command": "drip hook codex"
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

Add a `Stop` hook for done cards (see [everything](../everything/)), or add `--approve` to answer
from the card (see [approve-from-card](../approve-from-card/)).
