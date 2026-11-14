# everything

A card when the agent needs you, when a turn is done, and when it dies on an error.

For: one or two sessions at a time. With many sessions the done cards add up: use [long-turns](../long-turns/) or [attention](../attention/).

## How it works

[attention](../attention/) plus `Stop` (Gemini: `AfterAgent`). The done card shows the last thing the
agent wrote and replaces the waiting card of the session in place.

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
    "Stop": [
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
    "AfterAgent": [
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

Add `--needs-you-only` to a `drip hook` command to skip its done card.
