# long-turns

Every card of [everything](../everything/), but no done card for a turn shorter than 30 seconds.

For: people who send many short prompts. A short turn's done card is noise.

## How it works

The done and failure hooks run `drip hook <agent> --min-turn 30`. drip counts from the prompt you
sent, which `UserPromptSubmit` records. Cards that need you always show. For an agent on another
machine, `drip follow` applies the same filter.

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
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude --min-turn 30"
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook claude --min-turn 30"
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
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "drip hook codex --min-turn 30"
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
    "AfterAgent": [
      {
        "hooks": [
          {
            "name": "drip",
            "type": "command",
            "command": "drip hook gemini --min-turn 30"
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

Change 30 to another number of seconds (0 to 600).
