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

One command shows a brief card growing out of the camera notch, or out of the top edge of a screen
without one, with an icon, a title, an optional detail, a colored accent and a system sound, then
takes it away again. A glance tells you what finished and how it went: a build, a deploy, a test
run, a backup, a script, or a coding agent such as Claude Code, Codex or Gemini CLI. It is an alert
from the terminal, but not Notification Center, so it needs no permissions. drip returns at once,
so it never slows the script that calls it.

```sh
drip "build finished"
drip ok "dotfiles up to date" -d "pulled 1 commit: feat(nvim): show hidden files"
drip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | drip ok
drip run make test
drip run --open "$CI_URL" --button "View run" ./deploy.sh
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh
drip fail "deploy failed" --stay  # stays until you click it
drip info "my-app needs you" --stay --icon app:com.openai.chat
drip info "deploying" --id deploy && drip ok "deployed" --id deploy
drip setup claude             # Claude Code's hooks: which project needs you, and why
drip history --missed         # what came up while you were away
drip dismiss                  # take the cards on screen away, without going to the terminal
drip pause 30m                # hold cards for half an hour; drip resume ends it early
```

Requires macOS 13 or newer.

## Install

```sh
brew install jrnxf/tap/drip
drip ok "hello"               # try it
```

A green card grows out of the notch, or out of the top edge of a screen without one, and drip
prints nothing.

Homebrew installs drip as a prebuilt universal binary, for Apple silicon and Intel Macs, in a few
seconds: nothing to compile, and no Xcode. drip is still in development: until 0.1.0 is out, brew
installs the latest development build, a pre-release such as 0.1.0-pre.1, and `brew upgrade`
moves to the next one, then to 0.1.0. Install it with Homebrew rather than downloading the
archive from the release page: the binary is signed ad hoc, not notarized, so Gatekeeper blocks a
copy downloaded in a browser, while brew's download runs as it is. To build the latest `main` from
source instead, run `brew install --HEAD jrnxf/tap/drip`.

Without Homebrew, build it from source with the Swift in the Command Line Tools and put the binary
on your `PATH`:

```sh
xcode-select --install   # only if swift is not found; drip needs Swift 5.9 or newer
git clone https://github.com/jrnxf/drip.git
cd drip
swift build -c release
sudo mkdir -p /usr/local/bin
sudo cp .build/release/drip /usr/local/bin/
drip ok "drip works"
```

**No permissions.** drip asks macOS for none, but one, and only to follow
[agents on another machine](#agents-on-another-machine) in Ghostty: the first click on such a card
asks to let drip control Ghostty, to bring forward the terminal that shows herdr. It needs no
Accessibility, Screen Recording or Notifications permission and adds no login item. Nothing runs in the background but the
drip that is showing queued cards.

**Which screen.** A card shows on the screen the pointer is on, with or without a notch, and falls
back to the main screen. It also shows over full-screen apps and on every Space.

**No card?** A card that comes up while the screen is locked, or while drip is paused, waits for the
unlock or the end of the pause (see [Missed cards](#missed-cards-and-history)), and `drip history
--missed` lists them. Over ssh there is no GUI session, so drip exits 3. drip does not follow Focus,
since reading it would take a permission: cards show during Do Not Disturb, and in screen shares and
recordings. Run `drip pause` for those instead (see [Pausing](#pausing)).

## Coding agents

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
the [config](#config), or `DRIP_WHEN_FOCUSED`, changes that: `quiet`, the default; `show`, as any
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
`mark:claude`, `mark:codex` or `mark:gemini` (see [Icons](#icons)). Either way the right end of the
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

### Agents on another machine

An agent on a Linux box you reach over ssh, with no screen and no drip there, raises its cards on
your Mac by the same rules as one on the Mac: `DRIP_HOOK`, `agent_cards`, `done_after`,
`when_focused` and the rest of the [config](#config). Its hooks run `drip-remote-hook`, a small
POSIX sh script that appends each event to a queue file there, and `drip follow` on the Mac reads
that queue over ssh and shows each event's card as `drip hook` would. The Mac connects out to the
machine; nothing connects in.

1. On the Mac, save the hook on the machine, here `devbox`, in a folder on its `PATH`:

   ```sh
   drip setup remote | ssh devbox 'mkdir -p ~/.local/bin && cat > ~/.local/bin/drip-remote-hook && chmod +x ~/.local/bin/drip-remote-hook'
   ```

2. Add the hooks that run it to the agent's settings on the machine. `drip setup claude --remote`
   prints them, the same hooks as `drip setup claude` adds on a Mac with `drip-remote-hook claude`
   as their command; likewise `codex` and `gemini`.

3. On the Mac, follow the machine, by any name `ssh` takes, a `Host` from `~/.ssh/config` too:

   ```sh
   drip follow devbox
   ```

   It needs to log in without a prompt, with a key or an agent: it runs ssh with `BatchMode=yes`.

4. To keep it running, have launchd start it at login. `drip follow devbox --launchd` prints the
   launchd agent, with the terminal you ran it from as the app a click brings forward, and the
   `PATH`, `DRIP_*` settings (all but `DRIP_HOOK`), `XDG_CONFIG_HOME` and `XDG_STATE_HOME` set
   where you run it, so remote cards follow the same settings, config and `drip pause` as the rest:

   ```sh
   drip follow devbox --launchd > ~/Library/LaunchAgents/co.jrnxf.drip.follow.devbox.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.jrnxf.drip.follow.devbox.plist
   ```

   It logs to `~/Library/Logs/co.jrnxf.drip.follow.devbox.log`. `launchctl bootout
   gui/$(id -u)/co.jrnxf.drip.follow.devbox` stops it; delete the plist to keep it stopped.

**The queue.** Each event is one line of JSON in `$XDG_STATE_HOME/drip/remote.jsonl` on the machine,
or `~/.local/state/drip/remote.jsonl`, or `$DRIP_QUEUE` when set there: the hook's payload, the
agent, the machine's name (`$DRIP_MACHINE`, or `uname -n`, in letters, digits, `.`, `_` and `-`,
starting with a letter or digit), the time, and the session's `DRIP_HOOK`,
Claude Code's attendance variables, and herdr's `HERDR_PANE_ID`, `HERDR_TAB_ID` and
`HERDR_WORKSPACE_ID`. The hook takes a lock, with `flock` when the machine has it and else with a
`remote.jsonl.lockdir` directory, so lines from sessions at once never mix, and once the queue
passes 8 MB it moves it to `remote.jsonl.1`,
replacing the one before: the two never take much more than 16 MB. The file is readable only by
you. The hook prints nothing and always exits 0, so it never fails or holds up a turn, even when
it cannot write the queue. `drip follow --queue <path>` reads another path.

`drip follow` reads the queue from a non-interactive shell on the machine, which skips most of
your shell's startup files: set `DRIP_QUEUE` or `XDG_STATE_HOME`, if you set them at all, where
such a shell sees them too (`~/.zshenv` for zsh, or `~/.bashrc` above its interactive check for
bash), or pass `--queue`. When there is no queue at the path it reads, `drip follow` says so in
its log, and again once there is. Anything that shell prints, such as a welcome line, is ignored.

**Following.** `drip follow` checks the queue every second, reconnects when the connection drops,
after 1 second and then up to a minute between tries, and takes up after the last event it
handled: it keeps its place in `$XDG_STATE_HOME/drip/follow` on the Mac, so a new connection
replays nothing it showed. The first time, it starts at the end of the queue. An event older than
5 minutes when it arrives, as one queued while the Mac slept, shows no card rather than one in a
burst of others, but still takes away the card its session waits on, as after you answered on the
machine: `--max-age 30m` sets another limit. Age is by the machine's own clock: its reader tells
`drip follow` the time there when it connects and every 15 seconds, so a clock that runs behind or
ahead of the Mac's, as in a VM or WSL2, hides no stale events and none that are new, and `drip follow`
says so in its log when it is a minute or more off. It reads the config with each event, so an edit
applies to the next, and says each of its warnings once.

One `drip follow` per machine runs at a time, counted by the name you give it: `drip follow devbox`
and `drip follow me@devbox`, or an ssh alias for the same machine, are two machines to drip, and
run together show every card twice, each with its sound. Follow a machine by one name. A second
`drip follow` of the same name waits, and says so in its log, until the first ends and then
takes over, so a launchd agent started at login while another is running does not restart in a loop.

**Its cards.** A card from the machine names it, as in `api on devbox is done`, and its id is
`<agent>:<session>@<machine>`, so it never replaces a card of a session on the Mac. When the agent
runs in herdr, `when_focused` and `away_after` apply as they do on the Mac: drip asks the machine's
herdr, with `herdr --machine <machine> pane get`, whether the agent's pane is the focused one there,
and takes the app `--activate` names for the terminal in front. herdr marks a pane focused for any
client attached to that machine, so drip cannot tell whether the herdr in front on the Mac shows
that machine or Local. When herdr does not answer within 3 seconds, or the agent runs outside herdr,
drip takes you not to be watching: its cards show, with their sound. The `DRIP_HOOK` and attendance
of the session on the machine decide whether it raises cards, not the variables `drip follow` runs
with.

**Clicks.** A click brings forward the terminal you ran `drip follow` from, or the app
`--activate` names. In Ghostty, when the agent runs in herdr, Ghostty itself brings forward the
terminal whose title herdr's default `window_title`, `{hostname}: {workspace}`, gives it: the one
showing the machine, else the one showing this Mac, on whichever Space it is. The first such click
asks you once to let drip control Ghostty. Then drip focuses the agent's workspace and tab on the
machine with `herdr --machine <machine> workspace focus` and `tab focus`. That is as close as herdr lets a
command get today: it cannot focus a pane on another machine by its id, nor switch the herdr on the
Mac from Local to that machine, so you see the tab once your herdr shows the machine. herdr names
the machine by the label you saved it under with `herdr machine`: by default, the one saved with the
ssh target, else the one labeled with its host, else the host itself; `--herdr-machine <label>`
names another. `drip follow`'s log says how each click went: the app brought forward, or macOS
refusing to, and any herdr command refused, with why.

## Alert when a command finishes

Put `drip run` in front of any command: it runs it, times it, and shows a green card on exit 0, or
a red one with the exit code otherwise. drip then exits with the command's own status, so scripts
and `&&` chains work as before.

```sh
drip run make test
drip run --open "$CI_URL" --button "View run" ./deploy.sh
```

[drip run](#buttons) has the details, and the site a guide: [Get an alert on Mac when a terminal
command finishes](https://drip.jrnxf.co/notify-when-command-finishes).

## Compared with terminal-notifier, osascript and alerter

All four show something on a Mac from the shell. terminal-notifier, osascript and alerter post to
Notification Center, so they follow Focus and stay in its list; drip draws its own card from the
notch, needs no permission, times commands and comes with hooks for coding agents. None of them runs
on Linux.

| | drip | terminal-notifier | osascript | alerter |
| --- | --- | --- | --- | --- |
| Shows | its own card, from the notch or the top edge of the screen | a Notification Center banner | a Notification Center banner | a Notification Center alert that stays until dismissed |
| Permission | none; Automation of Ghostty for cards from another machine, asked once | Notifications, asked once | Notifications, for Script Editor | Notifications |
| Focus and Do Not Disturb | shows anyway; `drip pause` holds cards | follows Focus | follows Focus | follows Focus |
| Kept afterwards | `drip history` | Notification Center's list | Notification Center's list | Notification Center's list |
| Buttons and answers | `--yes`, `--no`: exits 0, 1 or 5 | `-action`, `-reply` (version 3): prints the answer | none in a notification | actions, a dropdown or a reply: prints the answer |
| Wraps a command | `drip run`: status, exit code and time | no | no | no |
| Coding agents | `drip setup claude`, `codex`, `gemini` | a hook you write | a hook you write | a hook you write |

## Uninstall

```sh
brew uninstall drip                       # or: sudo rm /usr/local/bin/drip, for a build from source
rm -rf ~/.config/drip ~/.local/state/drip # the config and the history
```

Then take drip's hooks out of the agents' settings, if you ran `drip setup`: the entries whose
command is `drip hook claude`, `drip hook codex` or `drip hook gemini` in `~/.claude/settings.json`,
`~/.codex/hooks.json` (or `config.toml`) and `~/.gemini/settings.json`. Delete the backups
`drip setup` left next to those files, named `<file>.drip-backup-<date>-<time>`, if you do not need
them. If you set `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, the files
are there instead. drip installs nothing else: no daemon, no login item, no preferences. If you
[follow another machine](#agents-on-another-machine), stop and delete the launchd agents you saved
for it, and on the machine delete `drip-remote-hook`, its queue and the hooks that run it.

## Privacy

drip makes no network connections of its own, sends nothing anywhere and collects no analytics:
the one connection is the ssh that `drip follow` runs to the machine you name. It only reads and
writes your config, the agents' settings that `drip setup` edits, its history, and small state
files next to it: the opt-in [debug log](#debug-log), the pause, `drip dismiss`'s requests, which card each agent session waits on and
the folder it runs in, each forgotten after 10 minutes, and where `drip follow` is in each
machine's queue.
The history, `~/.local/state/drip/history.jsonl`, is readable only by you and keeps the last 1000
cards. It holds each card's title and detail, up to 16,384 characters of each, so a card from a
coding agent keeps the agent's last message. Delete the file to clear it.

## Debug log

A diagnostic aid for working out why a card showed, or did not, such as a card that came up while
its terminal was in front. It is off. Turn it on with `debug = true` in the config or `DRIP_DEBUG=1`
(`DRIP_DEBUG=0` turns it off again); then `drip hook`, `drip follow` and the drip that shows a card
add one line for each decision about an agent's card, and for each click on one:

```
2026-10-27T10:20:51.123+01:00 follow card show agent=claude machine=devbox kind=ok id=claude:1a2b3c4d reason=not_focused_or_away waits=false when_focused=skip away_after=60.0 idle_seconds=2.1 frontmost=com.mitchellh.ghostty activate=com.mitchellh.ghostty app_in_front=true pane=herdr:w1:p2 herdr_machine=devbox pane_showing=false query="herdr pane get w1:p2" answer=not_showing query_ms=412
```

`drip debug` prints the log and `drip debug --clear` empties it. It is `debug.log` next to the
history, in `$XDG_STATE_HOME/drip` or `~/.local/state/drip`, readable only by you, and keeps about
the last 1 MB. It is for you, or an agent you ask to look at it, and goes nowhere: drip sends it
to no one.

A line is `time process event decision key=value ...`. `process` is `hook`, `follow` or `cli`; the
`event` is `card` (shown or skipped, and `reason`), `clear` (a card an agent's next step took away)
or `click`. What it records, and nothing else:

- the agent (`claude`, `codex` or `gemini`), the machine it ran on, the card's kind (`ok`, `warn`, ...)
  and whether it waits for you;
- the first 8 characters of the session id;
- the settings that decided: `when_focused`, `away_after`, `agent_cards`, `done_after`, and `DRIP_HOOK`;
- what drip noticed: the bundle identifier of the frontmost app and of the app a click brings
  forward, seconds since the keyboard or mouse was last used (both on every card line, `unknown` when drip did not ask, and the frontmost `none` when no app is in front), `topmost_visible`, the terminal when its window is on top of a display, else `none`, whether the agent's pane is in front, and, for a remote agent, `machine_selected`, whether your herdr window shows its machine;
- the pane's id (`herdr:w1:p2`, `tmux:%3`), the herdr machine, the query run to ask whether it is in
  front (`herdr pane get w1:p2`, or `tmux display-message`), its answer and how long it took;
- for a click: what drip tried to bring forward, whether macOS refused it and why, and whether
  selecting the pane worked.

It never records a card's title or detail, an agent's message or prompt, a tool's name or input, a
command, a folder or file path from an agent, or a hook payload, and it holds no socket path or
other address.

## Usage

```
drip [KIND] [TITLE] [options]
drip run [options] [--] <command> [args...]
drip hook claude|codex|gemini [options] [payload]
drip setup claude|codex|gemini [--print | --remote]
drip setup remote
drip follow <ssh-target> [options]
drip history [--missed] [-n N | --all] [--json | --replay]
drip debug [--clear]
drip dismiss [--id ID]
drip pause [DURATION]
drip resume
drip --version | --help
drip help <subcommand>
```

`drip --help` lists every option and subcommand, with examples; `drip help run`, or `drip run
--help`, shows one subcommand's. `drip show` names the first form, which drip runs when the first
word names no subcommand. A mistake prints `drip: ` and what is wrong, then where the help is, and
exits 2, or 1 for `drip hook`.

| Part | Behavior | Default |
| --- | --- | --- |
| `KIND` | A preset, which sets only the card's look, its icon, color and sound: `ok`, `warn`, `fail`, `info`, or a custom preset from the config file. When the first argument is not a preset and no title follows it, it is the title; followed by a title, it is an unknown preset and exits 2, saying how to quote a title of several words. | `info` |
| `TITLE` | The bold text, up to 2 lines. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The gray text under the title, up to 3 lines. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. A card that stays or a question given a time counts it down instead of waiting. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. Unknown names print a warning and play nothing. | the preset's |
| `--icon SYMBOL\|PATH\|app:ID\|mark:NAME\|none` | An SF Symbol name; a path to an image, such as a `.png`, `.pdf` or `.icns` file, drawn as it is; `app:` and an app's bundle identifier, such as `app:com.openai.chat`, for that app's own icon; or `mark:claude`, `mark:codex` or `mark:gemini` for an agent's mark that drip bundles. An icon that cannot load falls back to the preset's with a warning. See [Icons](#icons). | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--open URL\|PATH` | Adds a button that opens a URL or a file, a relative path from the directory drip runs in; see [Buttons](#buttons). Empty, as `--open "$CI_URL"` without a URL, it adds no button and warns. | none |
| `--button LABEL` | The `--open` button's label, up to 24 characters. Without `--open` it is a usage error. | `Open` |
| `--yes LABEL` | Asks a question with a yes button of this label, up to 24 characters: drip waits for the card, then exits 0 if the button was clicked and 5 if no button was. The card waits for its answer, whatever its look, unless it is given a time. Not for `drip run` or `drip hook`, which exit 2 or 1 instead, as nothing reads their answer. See [Buttons](#buttons). | none |
| `--no LABEL` | With `--yes`, a no button of this label to its left: drip exits 1 if it was clicked. | none |
| `--id ID` | Names what the card is about, up to 200 characters; see [Replacing cards](#replacing-cards). | none |
| `--activate BUNDLE-ID\|none` | The app a click on the card brings forward, such as `com.apple.Terminal`; see [Clicks](#clicks). | the app drip was run from |
| `--stay` | Keeps the card on screen until it is clicked, a newer card with the same `--id` replaces it, or 10 minutes pass, without holding the script: drip still returns at once. Works with any look; see Cards that wait below. | off |
| `--wait` | Wait until the card has gone before exiting. | off |
| `--quiet` | Never print warnings. | off |

The size and the motion are settings rather than flags: `size` (`compact`, `regular` or `large`,
scaling fonts, icon and padding by 0.85, 1.0 or 1.25) and `motion` (`full` drops the card out of
the notch on its springs and takes it back in, `subtle` only fades, `none` neither; Reduce Motion in System Settings caps it at
`subtle`) in the [config](#config), or `DRIP_SIZE` and `DRIP_MOTION`.

| Preset | Icon | Color | Sound |
| --- | --- | --- | --- |
| `ok` | `checkmark.circle.fill` | green | Glass |
| `warn` | `exclamationmark.circle.fill` | orange | Purr |
| `fail` | `xmark.circle.fill` | red | Basso |
| `info` | `info.circle.fill` | blue | Tink |

The kind is the look; flags are the behavior. `--stay` keeps a card on screen, `--yes` and `--no`
wait for an answer, and `--open` adds a link button. Every card keeps its icon, a question too.

**Cards that wait.** `--stay` is for something waiting on you, such as an agent asking for
permission, on any look: `drip fail "deploy failed" --stay`. The card has no countdown: a white dot
stands where the ring would be, and every 2.4 seconds a soft halo grows out of it to about twice its
size and fades (with Reduce Motion, the dot alone). The card stays until you click it or a newer
card with the same `--id` replaces it, and drip returns at once, so the script goes on. It gives way
to other cards: when another card waits for its place and every card on screen waits too, the
oldest goes back into the overflow drop under the stack, keeping what is left of its wait, and comes
back once there is room. It never stays longer than 10 minutes. A question (`--yes`), of any
look, waits too and never gives way: it stays until it is answered, replaced or its 10 minutes are
up, other cards stack around it, and a card with no room in the stack, or another question, waits
its turn. `--seconds`, `DRIP_SECONDS` or the preset's `seconds` in the config give a card that stays
or a question a countdown instead.

**stdin.** When no title is given and stdin is not a terminal, drip reads stdin to the end, keeping
the first 64 KB, so the command writing it is never cut short: the first non-empty line is the title
and the remaining lines, joined with a space, are the detail, unless `--detail` is given. A writer
that never ends, such as `tail -f`, never shows a card. With a title on the command line, stdin is
left alone.

### Icons

`--icon` takes an SF Symbol, an image file, an app's own icon or an agent's mark. A picture is drawn
as it is, never tinted, at the size of the preset's icon; an app's icon loses the margin around its
rounded square, so its mark fills the same place. When the icon is not the preset's own, the
card shows the state in its ring instead, around the state's mark: a check for `ok`, a cross for
`fail`, and so on. The icon then says who, and the ring what. A card that stays shows its waiting
dot there instead, and a card with buttons shows the buttons in place of the ring. Every card keeps
its icon, a question with `--yes` and `--no` buttons too:

```sh
drip info "my-app needs you" -d "Codex wants to run npm install" --icon app:com.openai.codex --stay
drip ok "backup done" --icon ~/Pictures/nas.png
```

A relative image path is taken from the directory drip runs in, or, in the config file, from the
config file's directory. An app's icon comes from the app installed on your Mac.

**Agent marks.** For a coding agent with no app installed, drip bundles three marks, drawn as
vectors in their own colours, so they are sharp at every size, bare on the island's black. `mark:claude`,
Claude's spark from [Anthropic's press kit](https://www.anthropic.com/press-kit); `mark:codex`,
OpenAI's Blossom from [OpenAI's brand page](https://openai.com/brand/); and `mark:gemini`, Gemini's
spark in its colours from [LobeHub's icons](https://lobehub.com/icons/gemini) (MIT, see
[THIRD_PARTY.md](THIRD_PARTY.md)), since Google publishes no vector of it outside its partner hub.
The marks are their owners' trademarks, used unaltered to name the agent a card is about. drip is
not affiliated with Anthropic, OpenAI or Google, and none of them endorses it.

**Text that starts with a dash.** `-d`, `--button`, `--yes`, `--no` and `--id` take their next argument whatever it
starts with, so `-d "$err"` works when the error reads `--- FAIL: TestFoo`, and `--id --wait` is an
id, not a missing value. A title that starts with
a dash goes after `--`: `drip fail -- "$line"`.

**Long text.** Whitespace runs collapse to one space, line breaks included. Terminal escape
sequences, such as the colors of piped output, other control characters and the bidi controls are
dropped. The title and the detail have no length limit, and the history keeps up to 16,384
characters of each, ending in an ellipsis when cut. The card is never wider than 640 points. Text
too wide for it wraps: the title to at most two lines and the detail to at most
three, breaking between words, between Japanese or Chinese characters, or inside a word too long
for a line. When text is still left over, the last line ends in an ellipsis. The card stays up for
`--seconds` however many lines it has.

**Returning at once.** drip checks everything first (flags, config, stdin, sounds and icons), so a
mistake still prints its message and exit status. Then it hands the card to a background drip and
exits. Cards from every drip queue up and show one after another, in the order they were sent.
`--wait` keeps drip running until its card has gone, still in its turn.

### Replacing cards

`--id` names what a card is about, such as a deploy or an agent session. A newer card with the same
id replaces an older one that is still waiting its turn, so a burst of updates shows only the
latest. When the older card is already on screen, the newer one takes its place there: the card
springs to its new size, the text that changed crossfades, a new state's colour settles over the
old one as its icon pops in, its sound plays, and its time starts again. When the ring carries the
state and the icon stays, such as an agent's, the icon stays still and the state pops in the ring. With reduced motion the
size changes at once and only the crossfade remains; with motion `none` it all changes at once. A card that asks a question (`--yes`)
never changes in place; the newer card then waits its turn. A question replaced before it showed
exits 5.

### Clicks

A click on a card brings forward the app drip was run from, such as your terminal, and takes the
card away. macOS names that app in the `__CFBundleIdentifier` environment variable of everything it
starts, and drip uses it; `--activate` names another app by its bundle identifier, and
`--activate none` leaves a card without a button click-through; on a card with a button, a click off
the button only takes the card away. In tmux, a click also selects the pane drip ran in, in the
terminal that shows that tmux session now, which may not be the one that started tmux; in herdr, the
pane's tab and then its agent; in WezTerm, the pane. None of them needs a permission. A card you
can click holds while the pointer is on it, like a card with a button, for up to 5 seconds after
the pointer last moved, so a pointer left resting on it never keeps it there. A card that waits for
you is always clickable: a click takes it away, even with `--activate none`. The card itself never takes focus.

**Out of the way.** While the pointer is on a card you can click, a × takes its icon's place, and a
card that brings an app forward shows an arrow where its ring was. A click on the ×, or a
right-click, Control-click or Option-click anywhere on the card, takes it away and brings nothing
forward; a question goes unanswered, as if it timed out. `drip dismiss` takes every card on
screen, and every card still waiting its turn, away the same way; `drip dismiss --id deploy` only
those with that id; `drip clear` is the same command. Bind it to a key in Shortcuts, Raycast or skhd
to clear the notch from the keyboard. VoiceOver offers each card's Open and Dismiss as its actions.

### Missed cards and history

A card that comes up while the screen is locked would play to nobody, so drip holds it until the
screen unlocks. Then one or two held cards show as they are, and three or more show as one card,
`5 cards while you were away`, with their titles newest first. Cards held while drip is paused
(see [Pausing](#pausing)) show the same way when the pause ends. It takes the look and sound of the
newest `fail` card among them, else the newest card that stays, else the newest `warn` card, else
the newest card, so a failure still reads as one. The summary counts down, even when it takes the
look of a card that stays. Of held cards with the same `--id`, only the newest shows. A click on the
summary brings forward the app the held cards came from, or nothing when they came from different
apps. A drip that waits for its card, with `--wait` or a `--yes` question, warns that the
screen is locked, keeps waiting until the unlock and then shows its card on its own.

Every card is also kept in `$XDG_STATE_HOME/drip/history.jsonl`, or
`~/.local/state/drip/history.jsonl`, one JSON object per line, readable only by you. drip keeps
the last 1000 cards.

```sh
drip history                  # the last 20 cards, newest first, as they showed
drip history -n 50            # the last 50
drip history --all            # every kept card
drip history --missed         # only those that came up while the screen was locked or drip was paused
drip history --json           # every card, oldest first, one JSON object per line, for scripts
drip history --missed --replay   # show the missed cards again
```

The listing shows each card as it showed on screen, newest first: how long ago it came up, then a
bar in the color of its kind (green `ok`, yellow `warn`, red `fail`, blue `info`) on every line, the
title in bold and the lines of detail the card had room for, with a rule between cards. A card
that came up while the screen was locked or drip was paused has `missed` after its title.

```text
2m ago    ┃ drip is done
          ┃ Split it. Pane awareness for herdr belongs in drip. Your
          ┃ firstmate and worker rules belong in dotfiles. How your…
────────────────────────────────────────────────────────────────
20m ago   ┃ deploy failed  missed
          ┃ api 1.4.2
```

The lines are the ones the card wrapped to, measured as the card was recorded, so a long agent
message lists as the few lines you saw, not as all of it. Entries recorded by an earlier drip, or
whose recorded lines drip cannot read, are wrapped from their text the same way, by the width of an average character instead of measured.
Color is for a terminal and off when `NO_COLOR` is set and not empty; the layout is the same without it. `--json`
and `--replay` take every card in full, unless `-n` limits them. A `--json` line
writes each setting the way its flag takes it, and leaves out `detail`, `button`, `open`, `id` and
`activate` when the card had none:

```json
{"card":{"button":"View run","color":"red","detail":"api 1.4.2","icon":"xmark.circle.fill","id":"deploy","kind":"fail","motion":"full","open":"https://example.com/run/1","seconds":8,"size":"regular","sound":"Basso","title":"deploy failed"},"missed":true,"time":"2026-10-18T13:02:41Z"}
```

`--replay` shows the cards again, in order, with any button that opens something; a question's button is
dropped, since nothing waits for its answer anymore. Replayed cards are held while the screen is
locked or drip is paused like any other, and are not added to the history again.

### Pausing

`drip pause` holds every card for an hour, from every drip, as if the screen were locked: for a
meeting, a screen share or a call. Cards already on screen go too, within a second, and are held
with the others; a question stays, as its script waits on it. When the pause ends, the held cards
show as missed cards do: one or two as they are, three or more as one `N cards while you were away`
card, and `drip history --missed` lists them, all but those already shown before the pause. A drip that waits for its card, with `--wait` or a `--yes` question, waits for
the end of the pause, and says so.

```sh
drip pause            # an hour; when drip is paused already, how long is left
drip pause 30m        # minutes or hours: 30m, 2h, 1h30m, up to 24h
drip resume           # end the pause now, and show what it held
```

`drip pause` alone does not change a running pause: it says how long is left. To extend or shorten
a running pause, pass a duration, such as `drip pause 1h`: it sets a new end from now, sooner or
later, in place of the old one. A pause always ends on its own; there is no pause without an end.
It is kept as its end time in `$XDG_STATE_HOME/drip/pause`, or `~/.local/state/drip/pause`, so it
holds across drips and restarts, and no drip keeps running for it but the one holding the cards.
While drip is paused, every drip run in a terminal prints a reminder to stderr, such as `drip is
paused, 23m left (drip resume to unpause)`. A drip whose stderr is not a terminal, such as one in a
script's log, and `drip hook`, print nothing about it, and `--quiet` keeps it quiet too.

### Buttons

`--open` adds a button that opens a URL or a file, such as a CI run, a pull request or a log.
`--button` names it. Hovering over the card holds it, for up to 5 seconds after the pointer last
moved; moving away gives it another 1.5 seconds. The
button stands where the countdown ring would be. A click on the button opens the target and takes the card
away; a click anywhere else on the card brings the sending app forward (see [Clicks](#clicks)) and
takes the card away. Clicking the button never takes focus from the app you are in.

`--yes` asks a question instead: the card has a button with that label and opens nothing, and drip
waits, then exits 0 if the button was clicked. `--no` adds a quieter button to its left that
answers no: drip exits 1 when it is clicked. drip exits as soon as a button is
clicked, while the card is still on its way out, so the command after it starts at once; a
background drip plays the card's exit, and any cards stacked with it, on from where they are.
With reduced motion, the card goes at once, with no exit, and drip exits with it. With either, drip exits 5 when
no button was clicked: the card timed out, a newer card with the same `--id` replaced it, or it was
clicked away from its buttons. A question waits for its answer for up to 10 minutes, whatever its
look; `--seconds` gives it a deadline instead. 0 and 1 read as yes and no, so the script decides what
happens:

```sh
drip warn "Deploy to prod?" -d "v1.4.0" --yes Deploy --no Cancel && ./deploy.sh
drip info "Merge drip #23?" -d "checks green, 1 approval" --yes Merge --seconds 10 && gh pr merge 23
```

The buttons stand where the ring would be, the yes button in the card's colour, darkened just
enough that white text on it reaches WCAG AA contrast (4.5:1), and the no button in white at 15 %. drip never takes focus, so the
keyboard answers nothing; VoiceOver offers each button as an action of the card, and reads a
question out before what it is reading. A card holds one link button or one question, never both:
`--yes` with `--open`, or `--button` without `--open`, exits 2. `drip run` and `drip hook` take no
`--yes` or `--no`, as nothing reads their answer.

**drip run** runs the command with drip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. drip's options come first, as for `time` or `nice`: the command
starts at the first argument that is not one of them, so `drip run -s 8 make test` runs `make test`.
`--` before the command also works, as in `drip run -- make test`.

### Recipes

Builds and tests, with how long they took:

```sh
drip run make test
drip run npm run build
```

A deploy that links to its run, and a backup:

```sh
drip run --open "https://github.com/me/app/actions" --button "View run" ./deploy.sh
drip run restic backup ~/Documents
```

A git hook, such as `.git/hooks/post-merge`, which drip never slows down:

```sh
#!/bin/sh
drip info "pulled $(git log -1 --format='%h %s')"
```

Coding agents have [a section of their own](#coding-agents).

### At the notch

Every card is drawn as one black shape with the notch, with a countdown ring draining over
`--seconds` (with motion `full`; buttons, or a card's waiting dot, take its place). A drop forms under the notch, stretches on a neck, breaks free
and widens into a capsule just below the menu bar. It leaves the same way, pulled back up into the
notch. A card whose text wraps grows into a taller capsule with rounded corners. On a screen without
a notch the drop forms above the screen and oozes out of the middle of its top edge instead, and
goes back into it the same way.

**Several cards at once.** Cards that come in while one is showing stack below it, up to 3 at
a time (`stack_max` in the [config](#config), or `DRIP_STACK_MAX`, 1 to 6); the rest wait their
turn in a small drop under the last card, which counts them. A card that comes later drips into the
drop and the count goes up. When a card leaves, it all happens in one motion: the card rises away,
the next card grows out of the drop into its place, the other cards move up and the count goes
down. Once none waits, the drop goes back into the
last card. With the pointer on the drop, it widens to list the waiting cards' titles, newest first.
A click on the drop does nothing. How they stack is `stack` in the config, or `DRIP_STACK`. With `chain`, the default, each new
card drops out of the bottom of the last one and the oldest goes back into the notch first, the
others moving up behind it. With `push` a new card drops out of the notch once the others have
moved down out of its way. `off` shows one card at a time. While the pointer is on any card in the stack, nothing moves: every countdown
stops, gaps stay open and new cards wait, though they still drip into the drop so its count stays
true. Once the pointer has rested for 5 seconds, the stack lets go, and moving it holds the stack
again. A click on a card dismisses it. Only the cards of drips
that returned at once stack; a card that waits (`--wait`, or a question) waits its turn. While a
question shows, cards that count down stack around it; a card that waits, or another question,
waits for its answer. drip exits as soon as the question is answered, so the command after it
runs at once, and the cards still in the stack play out without it.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown; a question was answered yes, the moment it was clicked. |
| 1 | A question was answered no, the moment it was clicked; `drip hook` could not make a card, for any reason but no GUI session; `drip setup` left the agent's settings alone, or could not write them; `drip pause` or `drip resume` could not write the pause; `drip dismiss` could not write its request; or `drip follow` could not start, as when it cannot write its state directory. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh; `drip hook` exits 0 then. |
| 4 | The config file is invalid; the message names the key and line. |
| 5 | drip asked with `--yes` and waited, but no button was clicked. |

Without `--wait`, 0 means the card was handed off to be shown. `drip run` exits with the wrapped
command's exit code (127 when it is not found) as soon as the command ends, once its card has
gone with `--wait`, or once a `--yes` question is answered or goes unanswered. When Ctrl-C ends the command, drip ends with the same
signal, so the script that ran it stops too. A usage error exits 2 before the command runs.

## Config

drip reads `$XDG_CONFIG_HOME/drip/config.toml`, or `~/.config/drip/config.toml`. Every key is
optional, and a missing file is fine.

```toml
seconds   = 4.5
size      = "regular"         # compact | regular | large
sound     = true              # a sound for every preset, such as "Hero"; false or "none" mutes them
motion    = "full"            # full | subtle | none
stack     = "chain"           # chain | push | off: how cards stack
stack_max = 3                 # most cards on screen at once, 1 to 6
when_focused = "quiet"        # quiet | show | skip: an agent's card while you watch its terminal
away_after = 60               # seconds without keyboard or mouse before you count as away; 0: always away
agent_cards = "all"           # all | attention: only the cards that need you, and no done cards
done_after = 0                # seconds: no done card for a turn shorter than this; 0 shows them all
debug = false                 # true: keep the debug log, a diagnostic aid (see Debug log)

[preset.ok]                  # override a built-in preset, any subset of keys
sound = "Hero"

[preset.deploy]              # a custom preset: drip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
seconds = 6

[preset.agent]               # a look of your own: drip agent "my-app needs you" --stay
icon = "app:com.apple.Terminal"   # an app's icon, or an image path from this file's directory
```

Each setting comes from the first of: flags, the environment (`DRIP_SECONDS`, `DRIP_SIZE`,
`DRIP_SOUND`, `DRIP_MOTION`, `DRIP_STACK`, `DRIP_STACK_MAX`, `DRIP_WHEN_FOCUSED`, `DRIP_AWAY_AFTER`,
`DRIP_AGENT_CARDS`, `DRIP_DONE_AFTER`, `DRIP_DEBUG`;
`DRIP_SOUND=none` mutes), the config file, the built-in defaults. An invalid value in the
environment exits 2 when drip makes a card from it (1 for `drip hook`); a command that makes none,
such as `drip history`, `drip debug` or `drip dismiss`, or a hook that shows nothing or only takes a
card away, never reads it. An invalid `DRIP_DEBUG` counts as unset. A preset's own `seconds` and `sound` beat the top-level ones, except
that a top-level `sound = false` mutes every preset. A custom preset starts from `info` and replaces
what it sets. Its name must match `[a-z][a-z0-9-]*` and must not be one of drip's subcommands or a
name kept for them: `run`, `hook`, `history`, `show`, `help`, `version`, `setup`,
`config`, `init`, `install`, `uninstall`, `completion`, `completions`, `doctor`, `mute`, `pause`,
`resume`, `listen`, `test`, `dismiss`, `clear` or `debug`. A custom preset's ring shows no state's mark. Unknown keys print a warning;
wrong types exit 4.

The file uses a small subset of TOML: comments, `key = value` lines with bare keys, table headers
of one or two keys such as `[preset.ok]`, and values that are single-line strings, decimal
integers, floats or booleans. Any other TOML syntax, such as arrays, inline tables, dotted keys or
multi-line strings, exits 4 with the line, and so does a file larger than 1 MB.

## Development

```sh
swift build
swift test            # on Linux, or on a Mac with Xcode
scripts/mac-check.sh  # on any Mac
scripts/mac-e2e.sh    # on any Mac, without a person
scripts/record-demo.sh  # films docs/demo.mp4 and docs/demo.gif on a Mac; needs ffmpeg
scripts/agent-contract.sh  # the agents' hooks, live, with the latest of each; needs node and tmux
```

`swift test` runs the DripCore unit tests anywhere Swift runs, including Linux CI. The snapshot
tests render cards with the hidden `drip __render --out card.png` command and compare them with the
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet.
`__render --at 0.2` draws a card's entrance 0.2 seconds in, to check a motion frame by frame.
`__render` also takes `--size` and `--motion`, which the other commands take only from the config
or the environment.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, shows each preset and a custom `deploy` preset on screen once, a card
with Terminal's icon that stays until the next card needs the notch, a few cards that stack
under one another, a Claude hook card that a newer card from the same session replaces in place, a
Claude permission card that its tool's run takes away, a card that stays for `drip dismiss` to take
away, then lists the last cards in the history. It works with only the Command Line Tools installed; Xcode is not needed. It
never overwrites a reference: to regenerate one on purpose, delete its PNG and run the script again.

`scripts/mac-e2e.sh` is the deep suite: run it on a Mac before merging a change to cards or to the
agents' hooks, as CI has no screen at the notch and no agent to run hooks. It checks what a person
would look for at the notch, and needs none: it shows cards
from a release build, runs the hooks `drip setup claude` and `drip setup codex` write with the
payloads Claude Code and Codex send, moves the pointer onto cards, clicks them, pauses and resumes,
and attaches tmux from Ghostty and Terminal. It prints `ok` or `FAIL` for each thing it expects, from
what drip records in its history, which windows it has on screen, which app is in front, what tmux
says, and pixels at the notch, and exits 1 on a failure. `--only 1,4` runs some checks. It runs drip
in a world of its own, with its own state, config, card queue (`DRIP_QUEUE_DIR`), Claude Code
settings and Codex home, all deleted afterwards, so it touches none in use, and it waits for any
other drip's card to go before each check. Keep your hands off the mouse while it runs. Clicks and
VoiceOver's actions go through a small helper app it builds in `~/.cache/drip-e2e`, which needs
Accessibility once: allow `drip e2e helper` when asked, or under System Settings > Privacy & Security
> Accessibility. Without it, those checks skip. It also keeps a screenshot of each card it shows,
with what it should look like, and a contact sheet of them all, for a person or a model to judge:
`judge.md` in the screenshots' folder says how, and `--judge-check` reads the verdicts.

`scripts/record-demo.sh` makes the animation at the top of this file by filming real cards: it plays
a fixed sequence at the notch of the screen under the pointer, records that strip with `screencapture`
at the screen's native pixels, and encodes `docs/demo.mp4` and `docs/demo.gif` with ffmpeg. Set a clean
wallpaper first, and allow your terminal under System Settings > Privacy & Security > Screen & System
Audio Recording the first time. Run it again for a new take.

### The live agent check

The tests replay payloads recorded once, so they cannot see Claude Code, Codex or Gemini CLI change
what their hooks send. `scripts/agent-contract.sh` can: it installs the latest release of each with
npm, builds drip from the checkout, and runs one short interactive session of each agent in a
terminal of its own (tmux), through the hooks `drip setup` writes. Each session asks for a shell
command the agent must ask permission to run, approves it through the terminal, then sends a second
prompt while a card waits, and checks what a person would see: the waiting card appears, it goes
once approved, a prompt takes a waiting card away, each turn ends with a done card, and a session
never has two cards. It runs on a locked Mac too, and shows nothing at the notch: drip is paused in
its world, so the cards go to its history. A session that goes wrong is tried once more, unless what
the agent sent is a shape drip cannot read or the account's quota ran out. `--only codex` runs some agents, and `--keep` keeps each
agent's scratch world.

The one-time setup takes about 5 minutes: run `scripts/agent-contract.sh --setup` in a terminal. It
opens the browser once, to approve a long-lived Claude Code token from `claude setup-token`, which
goes straight into the Keychain (service `drip-agent-contract`, account `claude`) without being
shown. Gemini CLI needs an API key, because Google no longer serves it to free-tier Google accounts:
create one at <https://aistudio.google.com/apikey> and turn billing on for it, so Google does not use
the check's prompts to improve its products (a weekly check costs a few cents). Setup asks for it
with the terminal's echo off and saves it in the Keychain (same service, account `gemini`), or you
save it yourself with `security add-generic-password -s drip-agent-contract -a gemini -U -w`. Codex
uses your own login: run `codex login` first if you have none. Setup checks each login with a tiny
session, prints what is ready, then runs the check once. After that a check never prompts and never
opens a browser: an agent whose login is missing or no longer works is skipped with the one line
that fixes it. So is one whose API quota runs out mid-session, as when Gemini CLI stops at its
usage limit dialog, unless a check had already failed by then.

This repo ships the check only: no schedule and no alert. Running it, weekly say, and telling you
when it fails or needs a login are up to your own scheduler, which runs `scripts/agent-contract.sh`
and reads its exit status and `~/.cache/drip-agent-contract/last.json`, both described below.

drip shows and records no card without a GUI session, so a scheduler must run the check as a
LaunchAgent in the logged-in user's session, not as a LaunchDaemon or over ssh. Started anywhere
else, it runs no agent, writes `last.json` with the status `no-gui-session` and the reason, and
exits 3.

One check runs at a time: the lock comes before the agents are installed or drip is built, so a check
started while another runs changes nothing under it, exits 4 and leaves that check's `last.json`
alone.

It exits 0 when every agent passed, 1 when any failed or the check itself could not run (the status
`error`, with the reason), 2 when the only trouble is a login, 3 when there is no GUI session, and 4
when another check is running. `~/.cache/drip-agent-contract/last.json` is what a scheduler reads: it
says `running` while a check runs and then its result: `status` and `reason`, and for each agent its
`status`, `version`, `reason`, `fix`, `checks`, `drift` and `payloads`.
Each run also keeps its own `last.json`, `summary.txt`, the payloads of each try at each agent
(`payloads/codex-1`, and `payloads/codex-2` for a second try), and the screen of any check that
failed, in `~/.cache/drip-agent-contract/runs/<time>/`. The drift report holds every payload up against
`scripts/agent-contract/contract.json`, which names the fields drip reads from each event: a field
drip reads that is missing or of another type, an event the session should have sent, or a permission
request that does not match the tool call after it is drift, and a field never seen before is only
noted. `--drift DIR` prints the report for the payloads a run kept, each agent's last try. The kept payloads name your home
`/home/user`, so a fix can add them to the tests as they are; update `contract.json` with it.

Everything it uses lives in `~/.cache/drip-agent-contract`: the agents, drip's state, each agent's
home and settings. Your own agents, their settings and your PATH stay as
they are. The Codex session links your `~/.codex/auth.json` rather than copying it, and trusts drip's
hooks for that session alone (`--dangerously-bypass-hook-trust`), where you would trust them once in
`/hooks`. A refresh of that login in the check goes to your own file, through the link; if your own
Codex refreshes it at the same moment, Codex may ask you to run `codex login` again. Any program you
run can read the Claude Code token and the Gemini API key in the Keychain without asking, as an unattended check must.

### Releases

A pushed tag makes a release: `.github/workflows/release.yml` builds the universal archive,
publishes the tag's GitHub release with it, and points the formula in jrnxf/homebrew-tap at it.

```sh
git tag v0.1.0-pre.1 && git push origin v0.1.0-pre.1   # a development build
```

While `Sources/DripCore/Version.swift` says `0.1.0-pre`, the tags are `v0.1.0-pre.1`,
`v0.1.0-pre.2` and so on: each is a pre-release, the build stamps its number into
`drip --version`, and none needs a commit. Homebrew reads `-pre.N` as a pre-release and orders it
before 0.1.0; it would read `-dev.N` as plain 0.1.0. For 0.1.0 itself, set `Version.swift` to
`0.1.0`, merge, and tag `v0.1.0`; then set it to the next version with `-pre`. The formula follows
pre-releases only until the first full release, so a pre-release never replaces a stable drip.

### The web page

[drip.jrnxf.co](https://drip.jrnxf.co) runs DripCore itself, compiled to WebAssembly, and paints
what it computes: the command line, the cards, their springs and outlines, and the stack. It lives
in `web`:

```sh
web/build.sh  # the page, its styles and the engine into web/dist
web/test.sh   # the DripCore tests, compiled to WebAssembly, under wasmtime
```

Both need Swift 6.4.1 with its matching Wasm SDK; `web/tools.sh` pins them and, on x86_64 Linux,
downloads what is missing. The downloads are shared by every checkout, checked against their pinned
checksums: they live once in `~/.cache/drip/web-tools` (under `$XDG_CACHE_HOME` when it is set, or
in `$DRIP_WEB_TOOLS`), while each checkout's builds stay in its own `.build`. The page's styles are
Tailwind CSS v4, in `web/styles/site.css`, on top of `web/styles/base.css`, which every page shares:
`web/build.sh` compiles them with Tailwind's standalone CLI, pinned the same way, and inlines them
into the page. Under WASI, DripCore builds against FoundationEssentials, and
`Sources/DripCore/WASICompat.swift` fills in the little it lacks. CI runs `web/test.sh`, and
Cloudflare's Workers Builds runs `web/build.sh` and deploys the `drip-web` Worker on every push to
main that touches `web`, `Sources/DripCore` or the package.

Next to the page, `web/public` holds three guides: one question each, answered in the first
paragraph, and listed in `sitemap.xml` and `llms.txt`. Their styles are `web/styles/guide.css`,
inlined by `web/build.sh` as the page's are. A guide at `web/public/vs.html` is served at `/vs`.

## License

MIT
