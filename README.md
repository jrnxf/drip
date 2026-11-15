<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/drip-lockup-reversed.svg">
    <img src="docs/logo/drip-lockup.svg" width="300" alt="drip">
  </picture>
</p>

<h1 align="center">Notifications that work your way.</h1>

<p align="center">drip is a free, open-source macOS CLI that shows scriptable notification cards from the MacBook notch, for builds, deploys and coding agents like Claude Code, Codex and Gemini CLI.</p>

<p align="center">
  <a href="https://github.com/jrnxf/drip/releases"><img src="https://img.shields.io/github/v/release/jrnxf/drip?include_prereleases&sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/jrnxf/drip" alt="MIT license"></a>
  <a href="docs/install.md"><img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13 or newer"></a>
  <a href="https://github.com/jrnxf/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-jrnxf%2Ftap%2Fdrip-orange" alt="Homebrew tap jrnxf/tap/drip"></a>
</p>

<p align="center">
  <img src="docs/demo.gif" width="600" alt="drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, replaced in place by Deploy failed, with staging: health check timed out after 30s, then the question Deploy to prod?, with Deploy and Cancel buttons, until it times out">
</p>

<p align="center"><a href="https://drip.jrnxf.co">Interactive demo</a> · <a href="docs/usage.md">Documentation</a></p>

## Install

```sh
brew install jrnxf/tap/drip
drip ok "hello"
```

Requires macOS 13 or newer. Homebrew installs a prebuilt binary for Apple silicon and Intel, with no Xcode needed.
No Notifications permission: drip draws its own card. On a Mac without a notch, the card grows out of the top edge of the screen.
See [installation](docs/install.md) for source builds and uninstall instructions.

## Coding agents

When the agent needs you, a card comes from the notch. Click it to go back to the agent's terminal.
For Claude Code, add the [permission-cards](recipes/permission-cards/README.md) snippet to `~/.claude/settings.json`. If the file has `hooks` already, merge the events by hand:

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

This guarded command is safe to commit to a settings file you share, such as a project's `.claude/settings.json`: on a machine without drip it is silent.

- Codex: the [Codex snippet](recipes/permission-cards/README.md#codex) goes in `~/.codex/hooks.json`.
- Gemini CLI: the [Gemini CLI snippet](recipes/permission-cards/README.md#gemini-cli) goes in `~/.gemini/settings.json`.
- Allow and Deny on the card, for Claude Code and Codex: [approve-from-card](recipes/approve-from-card/README.md).
- More recipes, such as a done card for every turn: the [recipe catalog](recipes/README.md).

Or ask your agent:

```text
Install drip with Homebrew (brew install jrnxf/tap/drip) and add the permission-cards recipe from https://github.com/jrnxf/drip/blob/main/recipes/permission-cards/README.md to my Claude Code settings. Keep my other hooks.
```

## Compose it

Pipe text into a card, give it an action, or use an answer to decide what happens next.

```sh
# The first line becomes the title, the rest becomes the detail
git log -1 --format='%s%n%an' | drip ok

# Open a report from the card
drip ok "Report ready" --open ./report.html --button "View report"

# Continue only when you click Deploy
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh

# Show a command's result and duration, and keep its exit status
drip run make test
```

See [usage](docs/usage.md) for more examples and [the contract](docs/contract.md) for exit codes and scripting guarantees.

## Make it yours

Set the size, stacking and reusable presets in `~/.config/drip/config.toml`. Every key is optional.

```toml
size  = "regular"         # compact | regular | large
stack = "chain"           # chain | off

[preset.deploy]
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
```

Then `drip deploy "shipped"` uses the preset. [Configuration](docs/config.md) lists every setting and its `DRIP_*` environment variable.

Clicks can activate an app or run your own command. Cards wait while the screen is locked, and `drip history --missed` shows missed cards.
Use `drip pause 30m` for a meeting or screen share. Drip does not follow Focus or Do Not Disturb automatically.
See [click actions](docs/usage.md#clicks), [history](docs/usage.md#missed-cards-and-history), and [pausing](docs/usage.md#pausing).

## Recipes

Recipes are snippets you copy and adapt, such as [slow shell commands](recipes/zsh-slow-commands/README.md) or a custom click action. See the [recipe catalog](recipes/README.md).
To show cards from a Linux machine on your Mac, see [remote notifications](docs/remote.md).

## Why not ...

- terminal-notifier and other Notification Center tools: they need the Notifications permission and follow Focus. drip draws its own card, and `drip run` wraps a command.
- A notch app for coding agents: drip is a CLI. The same card comes from your builds, deploys, scripts and any agent with hooks.
- The agent's own terminal notification: a drip card names the project, goes when you answer in the terminal, and a click brings that terminal back.

See the [comparison](docs/comparison.md).

## Documentation

- [Usage](docs/usage.md) and [scripting contract](docs/contract.md)
- [Configuration](docs/config.md) and [recipes](recipes/README.md)
- [Coding agents](docs/coding-agents.md): every hook event and flag
- [Troubleshooting](docs/troubleshooting.md): permissions, privacy, and missing cards
- [Development](docs/development.md) and the [interactive card tour](scripts/tour.sh)

Drip collects no analytics. Its only network connection is the SSH connection used by `drip follow`.
See [privacy](docs/troubleshooting.md#privacy).

## License

MIT
