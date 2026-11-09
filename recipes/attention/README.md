# attention

A card for everything that needs you: a permission, a question, and an error that ends a turn.

For: people who want to know when a turn dies, as with a rate limit or an outage, but not when it ends well.

## How it works

[permission-cards](../permission-cards/) plus Claude's `StopFailure`, which shows a `fail` card
with the error. Codex and Gemini have no such event, so their snippets match permission-cards.

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
    "StopFailure": [
      {
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

Add `Stop` to also get a done card (see [everything](../everything/)).
