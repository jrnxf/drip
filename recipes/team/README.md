# team

permission-cards in a project's committed settings, so the whole team gets it without an error.

For: a team that shares one repo. One person adds the snippet, and each teammate who wants cards installs drip.

## How it works

The snippet is the [permission-cards](../permission-cards/) snippet with a guard on each command:

```sh
command -v drip >/dev/null && drip hook claude || true
```

`command -v drip` checks that drip is on the `PATH`. If it is, the hook runs `drip hook claude`.
If it is not, the hook does nothing. The `|| true` makes the hook exit 0 in both cases.
Without the guard, a teammate without drip gets a hook error on each event. The same goes for a Mac without drip, Linux and CI.

- A teammate with drip sees a card when the agent needs them.
- A teammate without drip sees nothing.

The agent merges the hooks of the project file with the hooks of the personal file. A teammate who already has a drip snippet in their personal settings gets each card twice. They should keep only one: delete drip's hooks from their personal file, or skip the project ones.

## Install

One person adds the `hooks` entry to the project's settings file and commits it.
If the file has a `hooks` entry already, merge the events by hand and keep the other hooks. If it does not exist, create it with this content.

Then each teammate who wants cards installs drip:

```sh
brew install jrnxf/tap/drip
```

### Claude Code

File: `.claude/settings.json` in the project root, committed. Not `.claude/settings.local.json`, which is personal.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook claude || true"
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
            "command": "command -v drip >/dev/null && drip hook claude || true"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook claude || true"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook claude || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook claude || true"
          }
        ]
      }
    ],
    "ElicitationResult": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook claude || true"
          }
        ]
      }
    ]
  }
}
```

The personal file is `~/.claude/settings.json`.

### Codex

File: `.codex/hooks.json` in the project root, committed.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook codex || true"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook codex || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook codex || true"
          }
        ]
      }
    ]
  }
}
```

Codex loads project hooks only when the teammate trusts the project. Each teammate also trusts the hooks with `/hooks` in Codex. A changed hook needs that trust again. The personal file is `~/.codex/hooks.json`.

### Gemini CLI

File: `.gemini/settings.json` in the project root, committed.

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "name": "drip",
            "type": "command",
            "command": "command -v drip >/dev/null && drip hook gemini || true"
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
            "command": "command -v drip >/dev/null && drip hook gemini || true"
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
            "command": "command -v drip >/dev/null && drip hook gemini || true"
          }
        ]
      }
    ]
  }
}
```

Gemini CLI warns before it runs a project hook it has not seen, and again when the hook changes. The personal file is `~/.gemini/settings.json`.

## Change it

Start from another recipe, such as [everything](../everything/), and put the same guard on each command.
For a hook in a single personal file, the guard is not needed: use [permission-cards](../permission-cards/).
