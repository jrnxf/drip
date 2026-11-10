# Coding agents: the helpers

drip shows a card for a coding agent: Claude Code, Codex or Gemini CLI, from the notch, with no
Notifications permission. drip gives the helpers. A [recipe](../recipes/README.md) decides when to
notify. Nothing is installed until you pick a recipe, and no recipe is built into drip.

This page is the reference for the helpers. For the policy, read the recipes: they say what shows
a card, for whom, and how to change it.

## Hook snippets

drip has no hook set of its own and no installer. A [recipe](../recipes/README.md) is a snippet you
add to the agent's settings by hand, and it is the whole policy:

| Agent | Settings file |
| --- | --- |
| Claude Code | `~/.claude/settings.json` (`$CLAUDE_CONFIG_DIR/settings.json`) |
| Codex | `~/.codex/hooks.json` (`$CODEX_HOME/hooks.json`) |
| Gemini CLI | `~/.gemini/settings.json` |

A snippet is JSON of the shape `{ "hooks": { "<Event>": [group] } }`, as the agent's settings take
it. If the file has a `hooks` entry already, merge the events and keep your own hooks. Each handler
runs `drip hook <agent>`.

Codex runs a new hook only once you trust it: run `/hooks` in Codex. If your Codex `config.toml`
has an older `notify = ["drip", "hook", "codex"]` line, delete it, or every done card shows twice.
Claude Code can notify you itself, through your terminal: if each card comes with a second
notification, set Local notifications to disabled in its `/config`.

A settings file shared with machines without drip makes each hook fail there with "command not
found". Guard the command in the snippet:
`command -v drip >/dev/null && drip hook claude || true`.

For a machine that has no drip, write `drip-remote-hook claude` in place of `drip hook claude`. See
[remote.md](remote.md).

## drip hook

`drip hook claude`, `drip hook codex` or `drip hook gemini` is what the hooks run, with the hook's
JSON on stdin, or as an argument, as Codex's older `notify` passes it. Card options such as `--icon`
or `--seconds` work as usual. A payload it does not know prints an error.

What each event does:

| Agent | Event | Card |
| --- | --- | --- |
| Claude Code | `PermissionRequest`: Claude wants to run a tool | `info --stay`: `my-app needs you`, with what Claude wants |
| | `Notification` with the matcher `elicitation_dialog`: a question | `info --stay`, with Claude's message |
| | `Stop`: the turn is done | `ok`: `my-app is done`, with the last thing Claude wrote |
| | `StopFailure`: a rate limit, an outage or another API error ended the turn | `fail`: `my-app stopped`, with the error |
| | `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `ElicitationResult` | none: takes the waiting card away |
| Codex | `PermissionRequest` | `info --stay`, such as `Codex wants to run npm install` |
| | `Stop` | `ok`, with Codex's last message |
| | `PostToolUse`, `UserPromptSubmit` | none: takes the waiting card away |
| Gemini CLI | `Notification`: a tool permission | `info --stay`, with Gemini's message |
| | `AfterAgent` | `ok`, with Gemini's last response |
| | `AfterTool`, `BeforeAgent` | none: takes the waiting card away |

drip shows a card only for the events a snippet hooks. Claude's `Notification` matcher leaves out
`idle_prompt`: Claude Code sends it a minute after every finished turn, and its card would replace
the done card.

The title is the project, from the session's working directory. Two sessions in folders of the same
name, such as two worktrees of one repo, read apart: `1/drip needs you` and `2/drip needs you`. A
card that needs you stays, and the hook returns at once, unless `--approve` lets the card answer it.
It goes as soon as you answer in the terminal: the hook for the tool call it asked about, or for the
next prompt you send, takes it away. Otherwise it stays until you click it, the session's next card
replaces it, or 10 minutes pass. Each session's card has the id `<agent>:<session>`, so a session's
new card replaces its last one: the waiting card turns into the done card in place. drip keeps the
agent's Markdown out of the card.

### Flags

| Flag | What it does |
| --- | --- |
| `--approve` | The permission card for a short, single-line ASCII shell command shows the command, has Allow and Deny, and a click is the agent's answer. All other requests are asked in the terminal. Claude Code and Codex only, and local only |
| `--min-turn SECONDS` | No done card for a turn shorter than this, counted from the prompt you sent. 0 to 600. Cards that need you always show |
| `--only needs-you` | Only the cards that need you: a permission, a question, an error. No done card |
| `--on-click CMD` | A command to run on a click. See [recipes](../recipes/README.md) |

`--min-turn` and `--only` go through the [remote queue](remote.md), so `drip follow` applies them
to a card from another machine. `--approve` does not: drip answers only for an agent on this Mac.

### --approve

The hook waits on the card, and a click is the agent's answer: drip prints it on the hook's stdout,
and the tool runs, or does not, without the terminal. Nothing clicked in 9 minutes, a minute inside
the 10 both agents give a hook, prints nothing, and the terminal asks as it would without drip. So
does a click on the card itself, which brings the terminal forward, and the ×. It is a flag you add
by choice: a stray click allows a command.

With `--approve`, a permission card shows what the call would do, read from the tool's own input:
the command, else the file or the address, else the tool. It never shows only the agent's
description of the call, which can say anything, and `--detail` cannot replace it. This holds for
a card that only tells, too.

Allow appears only for a shell command (Bash) that is short, on one line, in plain ASCII, and has
no extra options. The card then shows the command character for character. Each line break on it
stands for exactly one space. A command given as words shows shell-quoted, so
`["rm","-rf","build /"]` shows as `rm -rf 'build /'`.

Every other request is asked in the terminal: the card only tells, and the hook returns at once.
This covers:

- any other tool, such as Write, Edit, WebFetch or an MCP tool
- a command too long for the card
- a command the card would break other than at a space, such as after a `/` or inside a long word
- a command with a line break, a tab, a run of spaces, or any character outside ASCII
- an option that can change what runs, such as `dangerouslyDisableSandbox`

Claude Code's `timeout` and `run_in_background` change nothing about what runs, so they still ask.

The buttons take a click only once the card has been still for 0.4 seconds. A click before that
does not count, and it holds the next click back for 0.4 seconds too. So a click, or a
double-click, meant for what was there before never answers the card.

| Agent | When the card asks | Answered in the terminal instead |
| --- | --- | --- |
| Claude Code | Always: Claude asks in its terminal at the same time, and the first answer counts | A deny takes the card away at once. An allow, once the tool ends |
| Codex | Only while you are not watching its terminal: Codex asks there only once the hook returns | Go to the terminal while the card waits, and the card goes |

A permission card that comes up while the screen is locked or `drip pause` holds cards only tells.
So does one from [another machine](remote.md), or from Gemini CLI.

### Clicks

A click on an agent's card brings back the terminal the agent runs in, and in tmux the agent's own
pane. For another multiplexer, give `drip hook` an `--on-click` command (the click recipes in
[recipes](../recipes/README.md)). The × that takes the icon's place while the pointer is on the card,
or a right-click, Control-click or Option-click anywhere on it, takes the card away and brings
nothing forward. `drip dismiss` does the same from the keyboard.

### While you watch

When one of the agent's terminal's windows is the topmost one on a screen (macOS keeps the app you
last clicked active after you swipe to another Space, so the active app alone does not count), its
done and stopped cards come without a sound and count down 1.5 seconds: you are likely watching it
already. `when_focused` in the [config](config.md), or `DRIP_WHEN_FOCUSED`, changes that: `quiet`,
the default; `show`, as any other card; or `skip`, no card at all, not even one that needs you, but
only when drip knows from tmux that the agent's own pane is the one in front. With `quiet`, a card
that needs you always shows. drip takes you to be watching only if you used the keyboard or mouse in
the last minute, or the `away_after` you set. drip cannot tell which pane shows on another machine,
so a card from an agent there always shows as if you were away. A card that needs you and was skipped
because you were watching comes back 30 seconds later, once, if the agent still waits and you are no
longer watching.

### DRIP_HOOK

A session nobody is at the terminal for raises no card: `claude -p`, the Claude Agent SDK, and the
pipelines that run them, which Claude Code marks with `CLAUDE_CODE_SESSION_ATTENDED=0`. There,
`drip hook` reads its payload, shows nothing, and exits 0. drip cannot tell a Codex or Gemini CLI
session nobody attends, nor an interactive Claude Code session an orchestrator drives. `DRIP_HOOK`
sets it per session:

| Value | What it does |
| --- | --- |
| `off` | No card from this session |
| `attention` | Only the cards that need you, from this session, even one nobody attends |
| `on` | Every card, even from a session nobody attends |

Any other value is an error that exits 1. See the [orchestrator](../recipes/orchestrator/) recipe.

```sh
DRIP_HOOK=off codex exec "fix the flaky test"   # no cards from this run
DRIP_HOOK=on claude -p "summarize the diff"      # cards even from print mode
DRIP_HOOK=attention claude                       # only the cards that need you
```

### Other behaviour

Without a GUI session, as when you run the agent over ssh, there is nothing to show: drip prints
nothing and exits 0, so the agent shows no hook error after every turn. Any failure, from a usage
error to a payload it cannot read or an invalid config, exits 1: Claude Code and Codex read exit 2
as "block", and Gemini CLI reads any code but 0 and 1 that way, which after a turn makes it run the
turn again. drip reads up to 4 MB of payload, and prints nothing on success but the answer a click
gives on a card that approves. A hook that takes a waiting card away reads one small file when no
card waits, so the hooks that run on every tool call cost next to nothing. drip keeps what each
session waits on, where it runs, and when its turn started, in `$XDG_STATE_HOME/drip/agents`, or
`~/.local/state/drip/agents`.

The card's icon is the agent's own app's, when it is installed: Claude.app for Claude Code
(`com.anthropic.claudefordesktop`), and the Codex app or ChatGPT.app for Codex (`com.openai.codex`,
`com.openai.chat`). Without one it is the maker's mark that drip bundles, `mark:claude`,
`mark:codex` or `mark:gemini` (see [Icons](usage.md#icons)). The right end of the card shows the
state: a white dot that sends out a soft ping while the agent waits on you, and a check in a ring
when it is done.

## drip watching

```sh
drip watching [--pane ID] [--app BUNDLE-ID]
```

Says by its exit status whether you are watching a terminal now. It uses the detection that
`when_focused` makes before a card shows.

| Exit | Meaning |
| --- | --- |
| 0 | Watching: the terminal is in front, its tmux pane shows when a pane is given, and you used the keyboard or mouse within `away_after` |
| 1 | Not watching, or drip cannot tell: no terminal app to look at, no GUI session, or an invalid config |
| 2 | Usage error |

`--pane` defaults to `$TMUX_PANE`, and `--app` to the app drip runs in. It prints nothing on stdout.
When drip cannot tell, it says why on stderr.

```sh
drip watching || drip ok "tests passed"   # a card only when you are away
```

## Other agents

Any agent or tool: wrap what it runs in `drip run`, or call drip from its hooks. The
[aider](../recipes/aider/) and [opencode](../recipes/opencode/) recipes show two.

The site has a guide for Claude Code: [Claude Code notifications on Mac, from the
notch](https://drip.jrnxf.co/claude-code-notifications).
