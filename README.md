<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/drip-lockup-reversed.svg">
    <img src="docs/logo/drip-lockup.svg" width="240" alt="drip">
  </picture>
</h1>

<p align="center">
  <img src="docs/demo.gif" width="400" alt="Three drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, then Deploy failed, with staging: health check timed out after 30s">
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
drip warn "staging is ready" --confirm "Promote" && ./promote.sh
drip ask "Merge drip #23?" --yes Merge --no Later && gh pr merge 23
drip ask "my-app needs you" --icon app:com.openai.chat
drip info "deploying" --id deploy && drip ok "deployed" --id deploy
drip setup claude             # Claude Code's hooks: which project needs you, and why
drip history --missed         # what came up while you were away
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

**No permissions.** drip asks macOS for none. It needs no Accessibility, Screen Recording,
Notifications or Automation permission and adds no login item. Nothing runs in the background but the
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
error. One command adds drip's hooks to the agent's own settings:

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
| Claude Code | `Notification`: a permission prompt or a question | `ask`: `my-app needs you`, with Claude's message |
| | `Stop`: the turn is done | `ok`: `my-app is done`, with the last thing Claude wrote |
| | `StopFailure`: a rate limit, an outage or another API error ended the turn | `fail`: `my-app stopped`, with the error, such as `API Error: Rate limit reached` |
| Codex | `PermissionRequest` | `ask`, such as `Codex wants to run npm install` |
| | `Stop` | `ok`, with Codex's last message |
| Gemini CLI | `Notification`: a tool permission | `ask`, with Gemini's message |
| | `AfterAgent` | `ok`, with Gemini's last response |

The title is the project, from the session's working directory. An `ask` card waits for you. Each
session's card has the id `<agent>:<session>`, so a session's new card replaces its last one
instead of queuing behind it: the waiting card turns into the done card in place, and a click on
the card brings back the terminal the agent runs in. drip keeps the agent's Markdown out of the
card: it shows the words, without code fences, heading or list markers, or emphasis marks.

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
Any failure, from a usage error to a payload it cannot read, an invalid config or no GUI session,
exits 1: Claude Code and Codex read exit 2 as "block", and Gemini CLI reads any code but 0
and 1 that way, which after a turn makes it run the turn again. drip reads up to 4 MB of payload,
and prints nothing on success, as Gemini CLI needs.

**By hand.** These are the hooks `drip setup claude` adds to `~/.claude/settings.json`, and that
`drip setup claude --print` prints:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|elicitation_dialog",
        "hooks": [{ "type": "command", "command": "drip hook claude" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "drip hook claude" }]
      }
    ],
    "StopFailure": [
      {
        "hooks": [{ "type": "command", "command": "drip hook claude" }]
      }
    ]
  }
}
```

The matcher leaves out `idle_prompt`: Claude Code sends it a minute after every finished turn, and
its card would replace the done card that says what Claude did.

Codex takes the same shape in `~/.codex/hooks.json`, with `PermissionRequest` and `Stop` running
`drip hook codex`, or as `[[hooks.Stop]]` tables in `~/.codex/config.toml`. Its older `notify =
["drip", "hook", "codex"]` still works, but only for done cards: keep one of the two, or every done
card shows twice. `drip setup codex` takes drip's `notify` out of `config.toml` for you. Gemini CLI
takes it in `~/.gemini/settings.json`, with `Notification` and `AfterAgent` running `drip hook
gemini`.

**Aider** runs a command when it is done and waits for you:

```sh
aider --notifications --notifications-command 'drip ok "$(basename "$PWD") is done" --id "aider:$PWD"'
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
        await $`drip ask ${`${project} needs you`} -d ${detail} --id ${id}`.quiet().nothrow()
      } else if (event.type === "session.idle") {
        await $`drip ok ${`${project} is done`} --id ${id}`.quiet().nothrow()
      }
    },
  }
}
```

Any other agent or tool: wrap what it runs in `drip run`, or call drip from its hooks.

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
are there instead. drip installs nothing else: no daemon, no login item, no preferences.

## Privacy

drip makes no network connections, sends nothing anywhere and collects no analytics. It only
reads and writes your config, the agents' settings that `drip setup` edits, and its history.
The history, `~/.local/state/drip/history.jsonl`, is readable only by you and keeps the last 1000
cards. It holds each card's title and detail, up to 16,384 characters of each, so a card from a
coding agent keeps the agent's last message. Delete the file to clear it.

## Usage

```
drip [KIND] [TITLE] [options]
drip run [options] [--] <command> [args...]
drip hook claude|codex|gemini [options] [payload]
drip setup claude|codex|gemini [--print]
drip history [--missed] [--json | --replay]
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
| `KIND` | A preset: `ok`, `warn`, `fail`, `info`, `ask`, or a custom preset from the config file. When the first argument is not a preset and no title follows it, it is the title; followed by a title, it is an unknown preset and exits 2, saying how to quote a title of several words. | `info` |
| `TITLE` | The bold text, up to 2 lines. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The gray text under the title, up to 3 lines. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. An `ask` card given a time counts it down instead of waiting. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. Unknown names print a warning and play nothing. | the preset's |
| `--icon SYMBOL\|PATH\|app:ID\|mark:NAME\|none` | An SF Symbol name; a path to an image, such as a `.png`, `.pdf` or `.icns` file, drawn as it is; `app:` and an app's bundle identifier, such as `app:com.openai.chat`, for that app's own icon; or `mark:claude`, `mark:codex` or `mark:gemini` for an agent's mark that drip bundles. An icon that cannot load falls back to the preset's with a warning. See [Icons](#icons). | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--open URL\|PATH` | Adds a button that opens a URL or a file, a relative path from the directory drip runs in; see [Buttons](#buttons). Empty, as `--open "$CI_URL"` without a URL, it adds no button and warns. | none |
| `--button LABEL` | The `--open` button's label, up to 24 characters. | `Open` |
| `--yes LABEL` | Asks a question with a yes button of this label, up to 24 characters: drip waits for the card, then exits 0 if the button was clicked and 5 if no button was. See [Buttons](#buttons). | none |
| `--no LABEL` | With `--yes`, a no button of this label to its left: drip exits 1 if it was clicked. | none |
| `--confirm LABEL` | The same as `--yes`. | none |
| `--id ID` | Names what the card is about, up to 200 characters; see [Replacing cards](#replacing-cards). | none |
| `--activate BUNDLE-ID\|none` | The app a click on the card brings forward, such as `com.apple.Terminal`; see [Clicks](#clicks). | the app drip was run from |
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
| `ask` | `questionmark.circle.fill` | purple | Ping |

**Cards that wait.** `ask` is for something waiting on you, such as an agent asking for
permission. Its card has no countdown: a white dot stands where the ring would be, and
every 2.4 seconds a soft halo grows out of it to about twice its size and fades (with Reduce Motion,
the dot alone). The card stays until you click it or a newer card with the same `--id` replaces it.
It gives way to other cards: when another card waits for its place, the card counts down its
`--seconds` from then like any other card, and it never stays longer than 10 minutes. A question
(`--yes`) never gives way: it stays until it is answered, replaced or its 10 minutes are up, other
cards stack around it, and a card with no room in the stack, or another question, waits its turn.
`--seconds`, `DRIP_SECONDS` or the preset's `seconds` in the config give an `ask` card a countdown
instead.

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
`fail`, and so on. The icon then says who, and the ring what. An `ask` card that waits shows its
waiting dot there instead, and such a card with the preset's own icon shows no icon,
nor does a question with `--yes` and `--no` buttons: the text starts at the left, and the right end
says it waits for you. A card with one button shows the button in place of the ring, so it keeps its
icon:

```sh
drip ask "my-app needs you" -d "Codex wants to run npm install" --icon app:com.openai.codex
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

**Text that starts with a dash.** `-d`, `--button`, `--confirm`, `--yes`, `--no` and `--id` take their next argument whatever it
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
the button only takes the card away. A card you can click holds while the pointer is on it, like a
card with a button. A card that waits for you is always clickable: a click takes it away, even
with `--activate none`. The card itself never takes focus.

### Missed cards and history

A card that comes up while the screen is locked would play to nobody, so drip holds it until the
screen unlocks. Then one or two held cards show as they are, and three or more show as one card,
`5 cards while you were away`, with their titles newest first. Cards held while drip is paused
(see [Pausing](#pausing)) show the same way when the pause ends. It takes the look and sound of the
newest `fail` card among them, else the newest `ask` card, else the newest `warn` card, else the
newest card, so a failure still reads as one. The summary counts down, even when it looks like an
`ask` card. Of held cards with the same `--id`, only the newest shows. A click on the
summary brings forward the app the held cards came from, or nothing when they came from different
apps. A drip that waits for its card, with `--wait` or a `--yes` question, warns that the
screen is locked, keeps waiting until the unlock and then shows its card on its own.

Every card is also kept in `$XDG_STATE_HOME/drip/history.jsonl`, or
`~/.local/state/drip/history.jsonl`, one JSON object per line, readable only by you. drip keeps
the last 1000 cards.

```sh
drip history                  # every kept card, oldest first
drip history --missed         # only those that came up while the screen was locked or drip was paused
drip history --json           # one JSON object per line, for scripts
drip history --missed --replay   # show the missed cards again
```

A listed line reads `2026-10-18 14:02  fail  deploy failed - api 1.4.2  (missed)`. A `--json` line
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
meeting, a screen share or a call. When the pause ends, the held cards show as missed cards do: one
or two as they are, three or more as one `N cards while you were away` card, and `drip history
--missed` lists them. A drip that waits for its card, with `--wait` or a `--yes` question, waits for
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
`--button` names it. Hovering over the card holds it; moving away gives it another 1.5 seconds. The
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
clicked away from its buttons. 0 and 1 read as yes and no, so the script decides what happens:

```sh
drip ask "Merge drip #23?" -d "checks green, 1 approval" --yes Merge --no Later && gh pr merge 23
drip warn "staging is ready" -d "api 1.4.2" --confirm "Promote" --seconds 10 && ./promote.sh
```

The buttons stand where the ring would be, the yes button in the card's colour, darkened just
enough that white text on it reaches WCAG AA contrast (4.5:1), and the no button in white at 15 %. drip never takes focus, so the
keyboard answers nothing; VoiceOver offers each button as an action of the card. `--confirm` is
another spelling of `--yes`. Before 0.2, `--button` without `--open` still asks as `--confirm`
does, with a warning.

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
turn. How they stack is `stack` in the config, or `DRIP_STACK`. With `chain`, the default, each new
card drops out of the bottom of the last one and the oldest goes back into the notch first, the
others moving up behind it. With `push` a new card drops out of the notch once the others have
moved down out of its way. `off` shows one card at a time. While the pointer is on any card in the stack, nothing moves: every countdown
stops, gaps stay open and new cards wait. A click on a card dismisses it. Only the cards of drips
that returned at once stack; a card that waits (`--wait`, or a question) waits its turn. While a
question shows, cards that count down stack around it; a card that waits, or another question,
waits for its answer. drip exits as soon as the question is answered, so the command after it
runs at once, and the cards still in the stack play out without it.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown; a question was answered yes, the moment it was clicked. |
| 1 | A question was answered no, the moment it was clicked; `drip hook` could not make a card, for any reason; `drip setup` left the agent's settings alone, or could not write them; or `drip pause` or `drip resume` could not write the pause. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh. |
| 4 | The config file is invalid; the message names the key and line. |
| 5 | drip asked with `--yes` or `--confirm` and waited, but no button was clicked. |

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

[preset.ok]                  # override a built-in preset, any subset of keys
sound = "Hero"

[preset.deploy]              # a custom preset: drip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
seconds = 6

[preset.ask]
icon = "app:com.apple.Terminal"   # an app's icon, or an image path from this file's directory
```

Each setting comes from the first of: flags, the environment (`DRIP_SECONDS`, `DRIP_SIZE`,
`DRIP_SOUND`, `DRIP_MOTION`, `DRIP_STACK`, `DRIP_STACK_MAX`; `DRIP_SOUND=none` mutes), the config file, the built-in defaults. An invalid value in the
environment exits 2. A preset's own `seconds` and `sound` beat the top-level ones, except
that a top-level `sound = false` mutes every preset. A custom preset starts from `info` and replaces
what it sets. Its name must match `[a-z][a-z0-9-]*` and must not be one of drip's subcommands or a
name kept for them: `run`, `hook`, `history`, `show`, `help`, `version`, `setup`,
`config`, `init`, `install`, `uninstall`, `completion`, `completions`, `doctor`, `mute`, `pause`,
`resume`, `listen` or `test`. A custom preset never waits,
and its ring shows no state's mark. Unknown keys print a warning;
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
scripts/demo-gif.sh   # redraws docs/demo.gif; needs ImageMagick
```

`swift test` runs the DripCore unit tests anywhere Swift runs, including Linux CI. The snapshot
tests render cards with the hidden `drip __render --out card.png` command and compare them with the
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet.
`__render --at 0.2` draws a card's entrance 0.2 seconds in, to check a motion frame by frame.
`__render` also takes `--size` and `--motion`, which the other commands take only from the config
or the environment.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, shows each preset and a custom `deploy` preset on screen once, an `ask`
card with Terminal's icon that waits until the next card needs the notch, a few cards that stack
under one another, a Claude hook card that a newer card from the same session replaces in place,
then lists the last cards in the history. It works with only the Command Line Tools installed; Xcode is not needed. It
never overwrites a reference: to regenerate one on purpose, delete its PNG and run the script again.

`scripts/demo-gif.sh` draws the animation at the top of this file frame by frame with
`__render --at`, from the same layers the notch card shows, so it needs no screen recording.

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
web/build.sh  # the page and the engine into web/dist
web/test.sh   # the DripCore tests, compiled to WebAssembly, under wasmtime
```

Both need Swift 6.4.1 with its matching Wasm SDK; `web/tools.sh` pins them and, on x86_64 Linux,
downloads what is missing. The downloads are shared by every checkout, checked against their
pinned checksums: they live once in `~/.cache/drip/web-tools` (under `$XDG_CACHE_HOME` when it is
set, or in `$DRIP_WEB_TOOLS`), while each checkout's builds stay in its own `.build`. Under WASI, DripCore builds against FoundationEssentials, and
`Sources/DripCore/WASICompat.swift` fills in the little it lacks. CI runs `web/test.sh`, and Cloudflare's
Workers Builds runs `web/build.sh` and deploys the `drip-web` Worker on every push to main that
touches `web`, `Sources/DripCore` or the package.

## License

MIT
