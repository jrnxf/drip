<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/drip-lockup-reversed.svg">
    <img src="docs/logo/drip-lockup.svg" width="240" alt="drip">
  </picture>
</h1>

<p align="center">
  <img src="docs/demo.gif" width="400" alt="drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, replaced in place by Deploy failed, with staging: health check timed out after 30s, then the question Deploy to prod?, with Deploy and Cancel buttons, until it times out">
</p>

drip shows a native card from your Mac's notch when a command or coding agent finishes or needs you.

A glance tells you what finished and how it went: a build, a deploy, a test run, or a coding agent
such as Claude Code, Codex or Gemini CLI. It is not Notification Center, so it needs no permissions,
and drip returns at once, so it never slows the script that calls it. On a Mac without a notch, the
card grows out of the top edge of the screen.

- **One command, any script.** `drip ok "deployed"` shows a green card with an icon, a sound and a countdown.
- **Wraps commands.** `drip run make test` shows how it went and how long it took, and keeps the exit code.
- **Coding agents.** One setup command and a card tells you which project needs you, and why.
- **Slow shell commands.** Any zsh command that takes 10 seconds or more gets a card, with nothing to type.
- **Remote machines.** Agents on a Linux box over ssh raise their cards on your Mac.
- **Questions.** `--yes Deploy --no Cancel` waits for a click and exits 0 or 1.
- **Nothing lost.** Cards that come up while the screen is locked play back when you return.

Requires macOS 13 or newer.

## Install

```sh
brew install jrnxf/tap/drip
drip ok "hello"
```

A green card grows out of the notch. Homebrew installs a prebuilt universal binary for Apple silicon
and Intel, with no Xcode needed. To build from source, or for notes on signing and pre-releases, see
[docs/install.md](docs/install.md).

## Quick start

```sh
drip "build finished"                                  # an info card
drip ok "tests passed" -d "246 passed in 3.2s"         # ok, warn, fail or info, with a detail line
drip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | drip ok                # first line is the title, the rest the detail
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh
drip info "deploying" --id deploy && drip ok "deployed" --id deploy   # replaces the card in place
```

## Alert when a command finishes

Put `drip run` in front of any command. It shows a green card on exit 0, or a red one with the exit
code, with the time it took as the detail, then exits with the command's own status, so scripts and
`&&` chains work as before.

```sh
drip run make test
drip run --open "$CI_URL" --button "View run" ./deploy.sh
```

Or skip typing it: `drip setup zsh` adds a block to `~/.zshrc` that gives a card to any command that
runs 10 seconds or more, only when you are not watching that terminal. A fast command runs no drip
at all. `DRIP_SLOW_AFTER` sets the threshold and `DRIP_SLOW_IGNORE` leaves commands out; see
[the zsh block](docs/usage.md#without-typing-drip-run).

## Coding agents

One command adds drip's hooks to the agent's own settings, keeps everything else in the file, and
backs the old one up next to it:

```sh
drip setup claude   # Claude Code, in ~/.claude/settings.json
drip setup codex    # Codex, in ~/.codex/hooks.json; then run /hooks in Codex to trust them
drip setup gemini   # Gemini CLI, in ~/.gemini/settings.json
```

The card's title is the project, such as `my-app needs you` with `Claude wants to run npm install`,
or `my-app is done` with the agent's last message. A card that needs you stays until you answer in
the terminal, and then turns into the done card in place. A click brings back the agent's terminal,
and its pane in tmux, herdr or WezTerm. While you watch the agent's terminal, its done card comes
without a sound.

Opt in with `approve = true` in the config, or `DRIP_APPROVE=1`, and a Claude Code or Codex
permission card has Allow and Deny: a click answers the agent, and no click leaves it to the
terminal. See [docs/agents.md](docs/agents.md).

Fewer cards: `agent_cards = "attention"` in the config shows only the cards that need you, and
`DRIP_HOOK=off` silences one agent, such as an orchestrator's background workers.

[docs/agents.md](docs/agents.md) has every event and card, the hooks to add by hand, and recipes for
Aider and opencode.

### Agents on another machine

An agent on a Linux box you reach over ssh, with no drip there, raises its cards on your Mac. A
small POSIX sh hook queues each event on the machine, and `drip follow` on the Mac reads that queue
over ssh. The Mac connects out; nothing connects in.

```sh
drip setup remote | ssh devbox 'mkdir -p ~/.local/bin && cat > ~/.local/bin/drip-remote-hook && chmod +x ~/.local/bin/drip-remote-hook'
drip setup claude --remote   # prints the hooks to add on the machine
drip follow devbox           # on the Mac; --launchd prints a launchd agent to keep it running
```

[docs/remote.md](docs/remote.md) has the setup step by step, the queue and how clicks reach herdr.

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

## Usage

```
drip [KIND] [TITLE] [options]
drip run [options] [--] <command> [args...]
drip setup claude|codex|gemini|zsh|remote
drip follow <ssh-target> [options]
drip history [--missed] [-n N | --all] [--json | --replay]
drip dismiss [--id ID]
drip pause [DURATION]
drip resume
drip --help | help <subcommand>
```

| Option | What it does |
| --- | --- |
| `-d`, `--detail TEXT` | Gray text under the title. |
| `-s`, `--seconds N` | Time on screen, 0.5 to 60. Default 4.5. |
| `--icon SYMBOL\|PATH\|app:ID` | An SF Symbol, an image file, or an app's own icon. |
| `--sound NAME\|none`, `--color HEX\|NAME` | Override the preset's sound or color. |
| `--open URL --button LABEL` | A button that opens a URL or a file. |
| `--yes LABEL`, `--no LABEL` | Ask a question: exits 0 for yes, 1 for no, 5 for no answer. |
| `--id ID` | A newer card with the same id replaces this one in place. |
| `--stay` | Stay until clicked, without holding the script. |
| `--wait` | Exit only once the card has gone. |

The kinds are `ok` (green), `warn` (orange), `fail` (red) and `info` (blue), plus any preset you
define. [docs/usage.md](docs/usage.md) has every flag, the exit codes, the history format, clicks,
stacking, and how cards move at the notch.

## Config

Every key is optional, in `~/.config/drip/config.toml`:

```toml
size        = "regular"   # compact | regular | large
stack       = "chain"     # chain | push | off: how cards stack
agent_cards = "all"       # all | attention: only the cards that need you

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
| Permission | none; Ghostty automation for clicks on cards from another machine, asked once | Notifications |
| Focus and Do Not Disturb | shows anyway; `drip pause` holds cards | follows Focus |
| Kept afterwards | `drip history` | Notification Center's list |
| Buttons and answers | `--yes`, `--no`: exits 0, 1 or 5 | terminal-notifier 3 and alerter: actions or a reply, printed |
| Wraps a command | `drip run`: status, exit code and time | no |
| Coding agents | `drip setup claude`, `codex`, `gemini` | a hook you write |

## More

- [Install, from source, and uninstall](docs/install.md)
- [Troubleshooting](docs/troubleshooting.md): no card, permissions, privacy and the debug log
- [Development](docs/development.md): tests, the live agent check, releases and the web page
- [drip.jrnxf.co](https://drip.jrnxf.co): guides for [Claude Code notifications](https://drip.jrnxf.co/claude-code-notifications) and [alerts when a command finishes](https://drip.jrnxf.co/notify-when-command-finishes)

**Privacy.** drip makes no network connections of its own and collects no analytics; the one
connection is the ssh that `drip follow` runs. Its history, in `~/.local/state/drip`, is readable
only by you.

## License

MIT
