# drip

<p align="center">
  <img src="docs/demo.gif" width="400" alt="Three drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, then Deploy failed, with staging: health check timed out after 30s">
</p>

A HUD from the shell for macOS: one command shows a brief native card growing out of the camera
notch, or out of the top edge of a screen without one, with an icon, a title, an optional detail, a
colored accent and a system sound, then takes it away again. A glance tells you what finished and
how it went: a build, a deploy, a test run, a backup, a script, an agent. drip returns at once, so
it never slows the script that calls it.

```sh
drip "build finished"
drip ok "dotfiles up to date" -d "pulled 1 commit: feat(nvim): show hidden files"
drip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | drip ok
drip run -- make test
drip run --open "$CI_URL" --button "View run" -- ./deploy.sh
drip warn "staging is ready" --button "Promote" && ./promote.sh
drip ok "shipped" --position top --style glass
drip info "deploying" --id deploy && drip ok "deployed" --id deploy
drip hook claude              # from a Claude Code hook: which project needs you, and why
drip demo                     # a few cards dropping from the notch, chained then pushed
drip history --missed         # what came up while you were away
```

Requires macOS 13 or newer.

## Install

```sh
brew install jrnxf/tap/drip
drip ok "drip works"
```

A green card grows out of the notch, or out of the top edge of a screen without one, and drip
prints nothing. `drip demo` then drops a few cards from the notch, stacking them under one another.

Homebrew builds drip from source with the Swift in the Command Line Tools, which Homebrew already
needs, in about a minute. Xcode is not needed.

Without Homebrew, build it the same way and put the binary on your `PATH`:

```sh
xcode-select --install   # only if swift is not found; drip needs Swift 5.9 or newer
git clone https://github.com/jrnxf/drip.git
cd drip
swift build -c release
sudo mkdir -p /usr/local/bin
sudo cp .build/release/drip /usr/local/bin/
drip ok "drip works"
```

**No card?** A card that comes up while the screen is locked waits for the unlock (see
[Missed cards](#missed-cards-and-history)), and `drip history --missed` lists them. Over ssh there is
no GUI session, so drip exits 3. drip does not follow Focus: cards show during Do Not Disturb, and in
screen shares and recordings.

## Usage

```
drip [KIND] [TITLE] [options]
drip run [options] -- <command> [args...]
drip hook claude|codex [options] [payload]
drip demo [chain|push] [options]
drip history [--missed] [--json | --replay]
drip --version | --help
```

| Part | Behavior | Default |
| --- | --- | --- |
| `KIND` | A preset: `ok`, `warn`, `fail`, `info`, or a custom preset from the config file. When the first argument is not a preset and no title follows it, it is the title; followed by a title, it is an unknown preset and exits 2. | `info` |
| `TITLE` | The bold text, up to 2 lines. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The gray text under the title, up to 3 lines. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. Unknown names print a warning and play nothing. | the preset's |
| `--icon SYMBOL\|none` | An SF Symbol name. Unknown names fall back to the preset's icon with a warning. | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--position bottom\|center\|top\|notch` | Where the card sits. `notch` grows it out of the camera notch, or out of the middle of the top edge on a screen without one. | `notch` |
| `--size compact\|regular\|large` | Scales fonts, icon and padding by 0.85, 1.0 or 1.25. | `regular` |
| `--style hud\|glass\|wash\|terminal` | How the card is drawn away from the notch; a notch card is always black. See [Styles](#styles). | `glass` on macOS 26, `hud` before |
| `--motion full\|subtle\|none` | `full` plays each style's entrance and exit, `subtle` only fades, `none` neither. Reduce Motion in System Settings caps it at `subtle`. | `full` |
| `--open URL\|PATH` | Adds a button that opens a URL or a file, a relative path from the directory drip runs in; see [Buttons](#buttons). Empty, as `--open "$CI_URL"` without a URL, it adds no button and warns. | none |
| `--button LABEL` | The button's label, up to 24 characters. Without `--open`, drip waits for the card and reports the click in its exit status. | `Open` |
| `--id ID` | Names what the card is about, up to 200 characters; see [Replacing cards](#replacing-cards). | none |
| `--activate BUNDLE-ID\|none` | The app a click on the card brings forward, such as `com.apple.Terminal`; see [Clicks](#clicks). | the app drip was run from |
| `--wait` | Wait until the card has gone before exiting. | off |
| `--quiet` | Never print warnings. | off |

| Preset | Icon | Color | Sound |
| --- | --- | --- | --- |
| `ok` | `checkmark.circle.fill` | green | Glass |
| `warn` | `exclamationmark.circle.fill` | orange | Purr |
| `fail` | `xmark.circle.fill` | red | Basso |
| `info` | `info.circle.fill` | blue | Tink |

**stdin.** When no title is given and stdin is not a terminal, drip reads stdin to the end, keeping
the first 64 KB, so the command writing it is never cut short: the first non-empty line is the title
and the remaining lines, joined with a space, are the detail, unless `--detail` is given. A writer
that never ends, such as `tail -f`, never shows a card. With a title on the command line, stdin is
left alone.

**Text that starts with a dash.** `-d`, `--button` and `--id` take their next argument whatever it
starts with, so `-d "$err"` works when the error reads `--- FAIL: TestFoo`, and `--id --wait` is an
id, not a missing value. A title that starts with
a dash goes after `--`: `drip fail -- "$line"`.

**Long text.** Whitespace runs collapse to one space, line breaks included. Terminal escape
sequences, such as the colors of piped output, other control characters and the bidi controls are
dropped. The title and the detail have no length limit, and the history keeps up to 16,384
characters of each, ending in an ellipsis when cut. The card is never wider than 640 points. Text
too wide for it wraps, at every position: the title to at most two lines and the detail to at most
three, breaking between words, between Japanese or Chinese characters, or inside a word too long
for a line. When text is still left over, the last line ends in an ellipsis. The card stays up for
`--seconds` however many lines it has.

**drip demo** drops four cards from the notch one after another, stacking the way queued cards do
(see [Styles](#styles)): ok, warn, fail, then an info card with an Open
button that opens drip's GitHub page. It plays them twice, chained and then pushed; `drip demo
chain` or `drip demo push` plays only that one, whatever `DRIP_STACK` says. Each stays two
seconds unless `--seconds`, `DRIP_SECONDS` or the config's `seconds` say otherwise, and each plays
its preset's sound, as a real card would; `--sound none` mutes them. Every card is a notch card, so `--position` and
`--style` do not apply. `--id` is ignored, so no card replaces another. Other options apply to
every card, and `--open` or `--button` replace the last card's button.

**Returning at once.** drip checks everything first (flags, config, stdin, sounds and icons), so a
mistake still prints its message and exit status. Then it hands the card to a background drip and
exits. Cards from every drip queue up and show one after another, in the order they were sent.
`--wait` keeps drip running until its card has gone, still in its turn.

### Replacing cards

`--id` names what a card is about, such as a deploy or an agent session. A newer card with the same
id replaces an older one that is still waiting its turn, so a burst of updates shows only the
latest. When the older card is already on screen, the newer one takes its place there: the card
springs to its new size, the text that changed crossfades, a new state's colour settles over the
old one as its icon pops in, its sound plays, and its time starts again. With reduced motion the
size changes at once and only the crossfade remains; with `--motion none` it all changes at once. A card that asks a question (`--button`
without `--open`) never changes in place, and neither does one that would sit somewhere else
(another `--position`); the newer card then waits its turn. A question replaced before it showed
exits 5.

### Clicks

A click on a card brings forward the app drip was run from, such as your terminal, and takes the
card away. macOS names that app in the `__CFBundleIdentifier` environment variable of everything it
starts, and drip uses it; `--activate` names another app by its bundle identifier, and
`--activate none` leaves a card without a button click-through; on a card with a button, a click off
the button only takes the card away. A card you can click holds while the pointer is on it, like a
card with a button. The card itself never takes focus.

### Missed cards and history

A card that comes up while the screen is locked would play to nobody, so drip holds it until the
screen unlocks. Then one or two held cards show as they are, and three or more show as one card,
`5 cards while you were away`, with their titles newest first. It takes the look and sound of the
newest `fail` card among them, else the newest `warn` card, else the newest card, so a failure
still reads as one. Of held cards with the same `--id`, only the newest shows. A click on the
summary brings forward the app the held cards came from, or nothing when they came from different
apps. A drip that waits for its card, with `--wait` or a `--button` question, warns that the
screen is locked, keeps waiting until the unlock and then shows its card on its own.

Every card is also kept in `$XDG_STATE_HOME/drip/history.jsonl`, or
`~/.local/state/drip/history.jsonl`, one JSON object per line, readable only by you. drip keeps
the last 1000 cards. `drip demo` cards are not kept.

```sh
drip history                  # every kept card, oldest first
drip history --missed         # only those that came up while the screen was locked
drip history --json           # one JSON object per line, for scripts
drip history --missed --replay   # show the missed cards again
```

A listed line reads `2026-10-18 14:02  fail  deploy failed - api 1.4.2  (missed)`. A `--json` line
writes each setting the way its flag takes it, and leaves out `detail`, `button`, `open`, `id` and
`activate` when the card had none:

```json
{"card":{"button":"View run","color":"red","detail":"api 1.4.2","icon":"xmark.circle.fill","id":"deploy","kind":"fail","motion":"full","open":"https://example.com/run/1","position":"notch","seconds":8,"size":"regular","sound":"Basso","style":"glass","title":"deploy failed"},"missed":true,"time":"2026-10-18T13:02:41Z"}
```

`--replay` shows the cards again, in order, with any button that opens something; a question's button is
dropped, since nothing waits for its answer anymore. Replayed cards are held while the screen is
locked like any other, and are not added to the history again.

### Buttons

`--open` adds a button that opens a URL or a file, such as a CI run, a pull request or a log.
`--button` names it. Hovering over the card holds it; moving away gives it another 1.5 seconds. At
the notch, the button stands where the countdown ring would be. A click on the button opens the target and takes the card
away; a click anywhere else on the card brings the sending app forward (see [Clicks](#clicks)) and
takes the card away. Clicking the button never takes focus from the app you are in.

`--button` without `--open` asks a question: drip waits and exits 0 if the button was clicked and 5
if it was not, so the script decides what happens:

```sh
drip warn "staging is ready" -d "api 1.4.2" --button "Promote" --seconds 10 && ./promote.sh
```

**drip run** runs the command with drip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. Options before `--` apply as usual.

### Recipes

Builds and tests, with how long they took:

```sh
drip run -- make test
drip run --position notch -- npm run build
```

A deploy that links to its run, and a backup:

```sh
drip run --open "https://github.com/me/app/actions" --button "View run" -- ./deploy.sh
drip run -- restic backup ~/Documents
```

A git hook, such as `.git/hooks/post-merge`, which drip never slows down:

```sh
#!/bin/sh
drip info "pulled $(git log -1 --format='%h %s')"
```

**Coding agents.** Point an agent's hooks at `drip hook` to see a card when it needs you or has
finished. drip reads the hook's payload: the title is the project, from the session's working
directory, and whether the agent needs you or is done, such as `drip needs you`. The detail is what
the agent said: the notification's message, or the last thing it wrote before it stopped. A
permission prompt or a question is `warn`, an idle prompt `info`, and a finished turn `ok`. Each
session's card has the id `<agent>:<session>`, so a session's new card replaces its last one
instead of queuing behind it, and a click on the card brings back the terminal the agent runs in.
drip reads Claude Code's `Notification` and `Stop` events and Codex's `agent-turn-complete`; any
other payload prints an error. Card options such as `--position` or `--seconds` work as usual. On a
mistake, such as a usage error or a payload it cannot read, `drip hook` exits 1, never 2, since exit
2 tells Claude Code to block the agent; an invalid config still exits 4, and no GUI session 3. drip
reads up to 4 MB of payload from stdin, and keeps the agent's Markdown out of the card: it shows the
words, without code fences, heading or list markers, or emphasis marks.

**Claude Code**, in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [{ "type": "command", "command": "drip hook claude" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "drip hook claude" }]
      }
    ]
  }
}
```

**Codex**, in `~/.codex/config.toml`. Codex adds the event payload as the last argument:

```toml
notify = ["drip", "hook", "codex"]
```

Any other agent or tool: wrap what it runs in `drip run`, or call drip from its hooks.

### Styles

| Style | Look |
| --- | --- |
| `hud` | The dark HUD material with a hairline in the accent color. |
| `glass` | The system glass, faintly tinted with the accent. Needs macOS 26; earlier versions draw `hud`. |
| `wash` | The whole card in the accent color, as a gradient, darkened just enough that the white text reaches WCAG AA contrast (4.5:1) for any color. A `fail` card shakes once. |
| `terminal` | A solid dark card with an accent stripe, the kind in small capitals above the title, and monospaced text. No icon. |

At `--position notch` the card is drawn as one black shape with the notch whatever `--style` says,
with a countdown ring draining over `--seconds` (with `--motion full`; a button takes its place).
Styles apply at the other positions. A drop forms under the notch, stretches on a neck, breaks free
and widens into a capsule just below the menu bar. It leaves the same way, pulled back up into the
notch. A card whose text wraps grows into a taller capsule with rounded corners. On a screen without
a notch the drop forms above the screen and oozes out of the middle of its top edge instead, and
goes back into it the same way.

**Several cards at once.** Notch cards that come in while one is showing stack below it, up to 3 at
a time (`stack_max` in the [config](#config), or `DRIP_STACK_MAX`); the rest wait their turn. With
`DRIP_STACK=chain`, the default, each new card drops out of the bottom of the last one and the
oldest goes back into the notch first, the others moving up behind it. With `DRIP_STACK=push` a new
card drops out of the notch once the others have moved down out of its way. `DRIP_STACK=off` shows
one card at a time. While the pointer is on any card in the stack, nothing moves: every countdown
stops, gaps stay open and new cards wait. A click on a card dismisses it. Only the cards of drips
that returned at once stack; a card that waits (`--wait`, or a question) waits its turn.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown. |
| 1 | `drip hook` could not make a card: a usage error, or a payload it cannot read or does not know. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh. |
| 4 | The config file is invalid; the message names the key and line. |
| 5 | The card had a button and drip waited, but the button was not clicked. |

Without `--wait`, 0 means the card was handed off to be shown. `drip run` exits with the wrapped
command's exit code (127 when it is not found) as soon as the command ends, or once its card has
gone with `--wait` or a `--button` question. When Ctrl-C ends the command, drip ends with the same
signal, so the script that ran it stops too. A usage error exits 2 before the command runs.

## Config

drip reads `$XDG_CONFIG_HOME/drip/config.toml`, or `~/.config/drip/config.toml`. Every key is
optional, and a missing file is fine.

```toml
seconds   = 4.5
position  = "notch"           # bottom | center | top | notch
size      = "regular"         # compact | regular | large
sound     = true              # false mutes every preset
style     = "glass"           # hud | glass | wash | terminal (default: glass on macOS 26, hud before)
motion    = "full"            # full | subtle | none
stack_max = 3                 # most notch cards on screen at once, 1 to 6

[preset.ok]                  # override a built-in preset, any subset of keys
sound = "Hero"

[preset.fail]
style = "wash"               # away from the notch, a preset can have its own style: failures shout

[preset.deploy]              # a custom preset: drip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
seconds = 6
```

Each setting comes from the first of: flags, the environment (`DRIP_SECONDS`, `DRIP_POSITION`,
`DRIP_SIZE`, `DRIP_SOUND`, `DRIP_STYLE`, `DRIP_MOTION`, `DRIP_STACK_MAX`; `DRIP_SOUND=none` mutes),
the config file, the built-in defaults. A preset's own `seconds` and `style` beat the top-level
ones. A custom preset starts from `info` and replaces what it sets. Its name must match
`[a-z][a-z0-9-]*` and must not be `run`, `hook`, `demo` or `history`. Unknown keys print a warning;
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
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet. For a notch
card, `__render --at 0.2` draws its entrance 0.2 seconds in, to check a motion frame by frame.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, shows each preset and a custom `deploy` preset on screen once, runs `drip
demo`, shows a Claude hook card that a newer card from the same session replaces in place, then
lists the last cards in the history. It works with only the Command Line Tools installed; Xcode is not needed. It
never overwrites a reference: to regenerate one on purpose, delete its PNG and run the script again.

`scripts/demo-gif.sh` draws the animation at the top of this file frame by frame with
`__render --at`, from the same layers the notch card shows, so it needs no screen recording.

## License

MIT
