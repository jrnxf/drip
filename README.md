<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/drip-lockup-reversed.svg">
    <img src="docs/logo/drip-lockup.svg" width="240" alt="drip">
  </picture>
</h1>

<p align="center">
  <img src="docs/demo.gif" width="400" alt="drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, replaced in place by Deploy failed, with staging: health check timed out after 30s, then the question Deploy to prod?, with Deploy and Cancel buttons, until it times out">
</p>


drip is a command that shows a card at your Mac's notch. Call it from a script, a build or a shell
hook to say that something finished, failed or needs an answer.

A card needs no macOS privacy grant, because drip does not use Notification Center. drip returns at
once, so it never slows the script that calls it. On a Mac without a notch, the card grows out of
the top edge of the screen.

- **One command, any script.** `drip ok "deployed"` shows a green card with an icon, a sound and a countdown.
- **Wraps commands.** `drip run make test` shows how it went and how long it took, and keeps the exit code.
- **Questions.** `--yes Deploy --no Cancel` waits for a click. It exits 0 for yes, 1 for no and 5 for no answer.
- **Slow shell commands.** A zsh recipe gives a card to any command that runs 10 seconds or more.
- **Coding agents.** Recipes for Claude Code, Codex and Gemini CLI call `drip hook` to show a card when the agent needs you.
- **Remote machines.** A Linux box you reach over ssh can raise its cards on your Mac.
- **Nothing lost.** Cards that come up while the screen is locked play back when you return.

Requires macOS 13 or newer.

## Install

```sh
brew install jrnxf/tap/drip
drip ok "hello"
```

A green card grows out of the notch. Homebrew installs a prebuilt universal binary for Apple silicon
and Intel, with no Xcode needed. To build from source, see [docs/install.md](docs/install.md).

## Quick start

```sh
drip "build finished"                                  # an info card
drip ok "tests passed" -d "246 passed in 3.2s"         # ok, warn, fail or info, with a detail line
git log -1 --format='%s%n%an' | drip ok                # first line is the title, the rest the detail
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh
drip info "deploying" --id deploy && drip ok "deployed" --id deploy   # replaces the card in place
```

`drip --help` lists every option. [docs/usage.md](docs/usage.md) is the full reference, and
[docs/contract.md](docs/contract.md) lists what scripts can rely on.

## Alert when a command finishes

Put `drip run` in front of any command. It shows a green card on exit 0, or a red one with the exit
code, then exits with the command's own status, so scripts and `&&` chains work as before.

```sh
drip run make test
drip run --open "$CI_URL" --button "View run" ./deploy.sh
```

To skip typing it, the [zsh-slow-commands recipe](recipes/zsh-slow-commands/README.md) is a block for
`~/.zshrc`. It gives a card to any command that runs 10 seconds or more, only when you are not
watching that terminal.

## Coding agents

drip has no built-in agent support. `drip hook` turns an agent's hook event into a card. A
[recipe](recipes/README.md) is a settings snippet that picks the events that show one. Copy a recipe
into the agent's settings and adapt it. Nothing is installed for you.

| Recipe | What it does |
| --- | --- |
| [permission-cards](recipes/permission-cards/) (suggested) | A card when the agent needs you, and nothing else |
| [attention](recipes/attention/) | Also a card when an error ends a turn |
| [everything](recipes/everything/) | Also a done card for every turn |
| [long-turns](recipes/long-turns/) | As everything, but no done card for a turn under 30 seconds |
| [approve-from-card](recipes/approve-from-card/) | permission-cards, with Allow and Deny on the card |
| [orchestrator](recipes/orchestrator/) | Many sessions at once: cards from the one you talk to, not its workers |

Start with [permission-cards](recipes/permission-cards/). It has the hooks for Claude Code, Codex
and Gemini CLI. [recipes/](recipes/README.md) also has click recipes for herdr, WezTerm and Ghostty,
and examples for Aider and opencode. [docs/agents.md](docs/agents.md) is the reference for
`drip hook`, `drip watching` and `DRIP_HOOK`.

To show the cards of an agent on a Linux box you reach over ssh, with no drip there, see
[docs/remote.md](docs/remote.md).

## Clicks

A click on a card brings its terminal forward. Add `--on-click CMD` to run a command on a click too.
The [click recipes](recipes/README.md) focus a pane in herdr or WezTerm, or a Ghostty window on
another Space.

## Away, paused and missed

Cards that come up while the screen is locked wait for the unlock, then the last five play back and
the rest sum up as one card. For a meeting or a screen share, hold them yourself:

```sh
drip pause 30m          # hold every card; drip resume ends it early
drip history --missed   # what came up while you were away
drip dismiss            # take the cards on screen away, without going to the terminal
```

drip does not follow Focus, since reading it would take a permission, so `drip pause` is how you
keep cards out of a screen share.

## Config

Every key is optional, in `~/.config/drip/config.toml`:

```toml
size  = "regular"         # compact | regular | large
stack = "chain"           # chain | push | off: how cards stack

[preset.deploy]           # a look of your own: drip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
```

[docs/config.md](docs/config.md) lists every key and its `DRIP_*` environment variable.

## Compared with terminal-notifier, osascript and alerter

| | drip | terminal-notifier, osascript, alerter |
| --- | --- | --- |
| Shows | its own card, from the notch | a Notification Center banner or alert |
| Permission | none for a card | Notifications |
| Focus and Do Not Disturb | shows anyway; `drip pause` holds cards | follows Focus |
| Kept afterwards | `drip history` | Notification Center's list |
| Wraps a command | `drip run`: status, exit code and time | no |

## More

- [Install, from source, and uninstall](docs/install.md)
- [Recipes](recipes/README.md): when agents notify, and clicks for herdr, WezTerm and Ghostty
- [Troubleshooting](docs/troubleshooting.md): no card, permissions, privacy and the debug log
- [Development](docs/development.md): tests, the live agent check, releases and the web page
- [drip.jrnxf.co](https://drip.jrnxf.co): guides for [Claude Code notifications](https://drip.jrnxf.co/claude-code-notifications) and [alerts when a command finishes](https://drip.jrnxf.co/notify-when-command-finishes)

drip makes no network connections of its own and collects no analytics. The one connection is the
ssh that `drip follow` runs. See [Privacy](docs/troubleshooting.md#privacy).

## License

MIT
