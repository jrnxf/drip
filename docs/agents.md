# Coding agents

drip shows a card when a coding agent needs you, when it is done, and when its turn dies on an
error: Claude Code, Codex and Gemini CLI notifications on a Mac, from the notch, with no
Notifications permission. One command adds drip's hooks to the agent's own settings:

```sh
drip setup claude   # Claude Code, in ~/.claude/settings.json
drip setup codex    # Codex, in ~/.codex/hooks.json
drip setup gemini   # Gemini CLI, in ~/.gemini/settings.json
```

`drip setup` keeps everything else in the file and its order, backs the old file up next to it as
`settings.json.drip-backup-<date>-<time>`, and says what it added. Running it again changes nothing.
`CLAUDE_CONFIG_DIR` and `CODEX_HOME` move the files, as they do for the agents. A settings file that
is a symlink or read-only, as home-manager and other dotfile managers make, is never written or
replaced, and neither is one that is not plain JSON, such as one with comments: drip says why,
prints the hooks to add where the file comes from, and exits 1. `drip setup claude --print` prints
the hooks without changing anything. Codex runs a new hook only once you trust it: run `/hooks` in
Codex after `drip setup codex`.

| Agent | Event | Card |
| --- | --- | --- |
| Claude Code | `PermissionRequest`: Claude wants to run a tool | `info --stay`: `my-app needs you`, with what Claude wants, such as `Claude wants to run npm install` |
| | `Notification`: a question | `info --stay`, with Claude's message |
| | `Stop`: the turn is done | `ok`: `my-app is done`, with the last thing Claude wrote |
| | `StopFailure`: a rate limit, an outage or another API error ended the turn | `fail`: `my-app stopped`, with the error, such as `API Error: Rate limit reached` |
| | `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `ElicitationResult` | none: takes the waiting card away |
| Codex | `PermissionRequest` | `info --stay`, such as `Codex wants to run npm install` |
| | `Stop` | `ok`, with Codex's last message |
| | `PostToolUse`, `UserPromptSubmit` | none: takes the waiting card away |
| Gemini CLI | `Notification`: a tool permission | `info --stay`, with Gemini's message |
| | `AfterAgent` | `ok`, with Gemini's last response |
| | `AfterTool`, `BeforeAgent` | none: takes the waiting card away |

The title is the project, from the session's working directory. Two sessions in folders of the same
name, such as two worktrees of one repo, read apart: `1/drip needs you` and `2/drip needs you`. A
card that needs you stays, as with `--stay`, and the agent's hook still returns at once. It goes as
soon as you answer in the terminal: the hook for the tool call it asked about, or for the next
prompt you send, takes it away and shows nothing. Otherwise it stays until you click it, the
session's next card replaces it, or 10 minutes pass. Each session's card has the id
`<agent>:<session>`, so a session's new card replaces its last one instead of queuing behind it:
the waiting card turns into the done card in place. drip keeps the agent's Markdown out of the
card: it shows the words, without code fences, heading or list markers, or emphasis marks.

**Clicks.** A click on an agent's card brings back the terminal the agent runs in, and in tmux,
herdr or WezTerm the agent's own pane. The × that takes the icon's place while the pointer is on the
card, or a right-click, Control-click or Option-click anywhere on it, takes the card away and brings
nothing forward, for when it is only in the way. `drip dismiss` does the same from the keyboard.

**While you watch.** When one of the agent's terminal's windows is the topmost one on a screen (macOS keeps the app you last clicked active after you swipe to another Space, so the active app alone does not count), its done and stopped cards come
without a sound and count down 1.5 seconds: you are likely watching it already. `when_focused` in
the [config](config.md), or `DRIP_WHEN_FOCUSED`, changes that: `quiet`, the default; `show`, as any
other card; or `skip`, no card at all, not even one that needs you, but only when drip knows from
tmux or herdr that the agent's own pane is the one in front, since several sessions often share one
terminal app. With `quiet`, a card that needs you always shows. Either way drip takes you to be
watching only if you used the keyboard or mouse in the last minute, or the `away_after` you set: a
terminal left in front while you are away raises its cards as usual. For an agent on another
machine, the pane showing there is not enough: your herdr window must show that machine too
(`herdr machine list` marks it `selected`), and if herdr cannot say, the card shows. A card that
needs you and was skipped because you were watching comes back 30 seconds later, once, if the
agent still waits and you are no longer watching.

**Fewer cards.** With many sessions at once, the done cards add up. `agent_cards = "attention"`
shows only the cards that need you, a permission, a question or an error, from every session you
attend, as `DRIP_HOOK=attention` does for one. `done_after = 30` keeps the done card of any turn
shorter than 30 seconds away, counted from the prompt you sent: you likely still have it in mind.
Both work the same for Claude Code, Codex and Gemini CLI.

**Only the session you talk to.** A session nobody is at the terminal for raises no card:
`claude -p`, the Claude Agent SDK, and the pipelines and agents that run them, which Claude Code
marks with `CLAUDE_CODE_SESSION_ATTENDED=0`. There, `drip hook` reads its payload, shows nothing,
and exits 0. drip cannot tell a Codex or Gemini CLI session nobody attends, nor an interactive Claude
Code session an orchestrator drives, so set `DRIP_HOOK=off` in the environment of any agent whose
cards you do not want, such as the background workers an orchestrator starts; only the session you
talk to then raises cards. An orchestrator's own session, which ends many background turns an hour,
wants `DRIP_HOOK=attention`: it shows the cards that need you (a permission, a question, an error)
and skips the done card of every turn. Like `on`, it shows cards even from a session nobody attends,
since you chose it. `DRIP_HOOK=on` shows every card even from a session nobody attends, and any other
value is an error that exits 1.

```sh
DRIP_HOOK=off codex exec "fix the flaky test"   # no cards from this run
DRIP_HOOK=on claude -p "summarize the diff"      # cards even from print mode
DRIP_HOOK=attention claude                       # only the cards that need you
```

The card's icon is the agent's own app's, when it is installed: Claude.app for Claude Code
(`com.anthropic.claudefordesktop`), and the Codex app or ChatGPT.app for Codex
(`com.openai.codex`, `com.openai.chat`). Without one it is the maker's mark that drip bundles,
`mark:claude`, `mark:codex` or `mark:gemini` (see [Icons](usage.md#icons)). Either way the right end of the
card shows the state: a white dot that sends out a soft ping while the agent waits on
you, and a check in a ring when it is done.

**drip hook** is what the hooks run: `drip hook claude`, `drip hook codex` or `drip hook gemini`,
with the hook's JSON on stdin, or as an argument, as Codex's older `notify` passes it. Card options
such as `--icon` or `--seconds` work as usual, as in
`drip hook claude --icon ~/.config/drip/claude.png`. A payload it does not know prints an error.
Without a GUI session, as when you run the agent over ssh, there is nothing to show: drip prints
nothing and exits 0, so the agent shows no hook error after every turn. Any failure, from a usage
error to a payload it cannot read or an invalid config, exits 1: Claude Code and Codex read exit 2
as "block", and Gemini CLI reads any code but 0 and 1 that way, which after a turn makes it run the
turn again. drip reads up to 4 MB of payload, and prints nothing on success, as Gemini CLI needs.
A hook that takes a waiting card away reads one small file when no card waits, and the config file
unless `DRIP_DEBUG` is set, to see whether `debug` is on, so the hooks that run on every tool call
cost next to nothing. drip keeps what each session waits on, where it runs, and
when its turn started, in `$XDG_STATE_HOME/drip/agents`, or `~/.local/state/drip/agents`.

**By hand.** These are the hooks `drip setup claude` adds to `~/.claude/settings.json`, and that
`drip setup claude --print` prints:

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

The Notification hook's matcher is only `elicitation_dialog`: the PermissionRequest hook shows a
permission prompt, with what Claude wants to do, and `drip setup claude` brings drip's older
`permission_prompt|elicitation_dialog` matcher up to date. It leaves out `idle_prompt`: Claude Code
sends it a minute after every finished turn, and its card would replace the done card that says
what Claude did. Claude Code can also notify you itself, through your terminal; if each card comes
with a second notification, set Local notifications to disabled in its `/config`.

Codex takes the same shape in `~/.codex/hooks.json`, with `PermissionRequest`, `Stop`,
`PostToolUse` and `UserPromptSubmit` running `drip hook codex`, or as `[[hooks.Stop]]` tables in
`~/.codex/config.toml`. Its older `notify =
["drip", "hook", "codex"]` still works, but only for done cards: keep one of the two, or every done
card shows twice. `drip setup codex` takes drip's `notify` out of `config.toml` for you. Gemini CLI
takes it in `~/.gemini/settings.json`, with `Notification`, `AfterAgent`, `AfterTool` and
`BeforeAgent` running `drip hook gemini`.

A settings file shared with machines without drip, as dotfiles often are, makes each hook fail
there with "command not found". Guard the command where that matters:
`command -v drip >/dev/null && drip hook claude || true`. drip then finds its own hook by the
words `drip hook claude` in it, and `drip setup` leaves it as it is.

**Aider** runs a command when it is done and waits for you:

```sh
aider --notifications --notifications-command 'drip ok "$(basename "$PWD") is done" --id "aider:$PWD" --icon terminal.fill'
```

or, in `.aider.conf.yml`, `notifications: true` and `notifications-command:` with the same command.

**opencode** loads plugins from `~/.config/opencode/plugins/`. This one, as `drip.js` there, shows
a card when opencode asks for a permission and when a session is done:

```js
export const Drip = async ({ $, directory }) => {
  const project = directory.split("/").pop()
  return {
    event: async ({ event }) => {
      const id = `opencode:${event.properties?.sessionID}`
      if (event.type === "permission.asked") {
        const detail = `opencode wants to use ${event.properties.permission}`
        await $`drip info ${`${project} needs you`} -d ${detail} --id ${id} --icon terminal.fill --stay`.quiet().nothrow()
      } else if (event.type === "session.idle") {
        await $`drip ok ${`${project} is done`} --id ${id} --icon terminal.fill`.quiet().nothrow()
      }
    },
  }
}
```

Any other agent or tool: wrap what it runs in `drip run`, or call drip from its hooks.

The site has the same as a guide: [Claude Code notifications on Mac, from the
notch](https://drip.jrnxf.co/claude-code-notifications).
