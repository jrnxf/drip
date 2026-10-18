# blip

A HUD from the shell for macOS: one command shows a brief native card growing out of the camera
notch, or out of the top edge of a screen without one, with an icon, a title, an optional detail, a
colored accent and a system sound, then takes it away again. A glance tells you what finished and
how it went: a build, a deploy, a test run, a backup, a script, an agent. blip returns at once, so
it never slows the script that calls it.

```sh
blip "build finished"
blip ok "dotfiles up to date" -d "pulled 1 commit: feat(nvim): show hidden files"
blip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | blip ok
blip run -- make test
blip run --open "$CI_URL" --button "View run" -- ./deploy.sh
blip warn "staging is ready" --button "Promote" && ./promote.sh
blip ok "shipped" --position notch --style glass
blip info "deploying" --id deploy && blip ok "deployed" --id deploy
blip hook claude              # from a Claude Code hook: which project needs you, and why
blip demo                     # every style and the notch card, to pick by feel
blip history --missed         # what came up while you were away
```

Requires macOS 13 or newer.

## Install from source

```sh
git clone https://github.com/jrnxf/blip.git
cd blip
swift build -c release --arch arm64 --arch x86_64
cp .build/apple/Products/Release/blip /usr/local/bin/
```

## Usage

```
blip [KIND] [TITLE] [options]
blip run [options] -- <command> [args...]
blip hook claude|codex [options] [payload]
blip demo [options]
blip history [--missed] [--json | --replay]
blip --version | --help
```

| Part | Behavior | Default |
| --- | --- | --- |
| `KIND` | A preset: `ok`, `warn`, `fail`, `info`, or a custom preset from the config file. When the first argument is not a preset, it is the title. | `info` |
| `TITLE` | The bold text, up to 2 lines. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The gray text under the title, up to 3 lines. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. | the preset's |
| `--icon SYMBOL\|none` | An SF Symbol name. Unknown names fall back to the preset's icon with a warning. | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--position bottom\|center\|top\|notch` | Where the card sits. `notch` grows it out of the camera notch, or out of the middle of the top edge on a screen without one. | `notch` |
| `--size compact\|regular\|large` | Scales fonts, icon and padding by 0.85, 1.0 or 1.25. | `regular` |
| `--style hud\|glass\|wash\|terminal` | How the card is drawn; see [Styles](#styles). | `glass` on macOS 26, `hud` before |
| `--motion full\|subtle\|none` | `full` plays each style's entrance and exit, `subtle` only fades, `none` neither. Reduce Motion in System Settings caps it at `subtle`. | `full` |
| `--open URL\|PATH` | Adds a button that opens a URL or a file; see [Buttons](#buttons). | none |
| `--button LABEL` | The button's label, up to 24 characters. Without `--open`, blip waits for the card and reports the click in its exit status. | `Open` |
| `--id ID` | Names what the card is about, up to 200 characters; see [Replacing cards](#replacing-cards). | none |
| `--activate BUNDLE-ID\|none` | The app a click on the card brings forward, such as `com.apple.Terminal`; see [Clicks](#clicks). | the app blip was run from |
| `--wait` | Wait until the card has gone before exiting. | off |
| `--quiet` | Never print warnings. | off |

| Preset | Icon | Color | Sound |
| --- | --- | --- | --- |
| `ok` | `checkmark.circle.fill` | green | Glass |
| `warn` | `exclamationmark.circle.fill` | orange | Purr |
| `fail` | `xmark.circle.fill` | red | Basso |
| `info` | `info.circle.fill` | blue | Tink |

**stdin.** When no title is given and stdin is not a terminal, blip reads stdin (up to 64 KB): the
first non-empty line is the title and the remaining lines, joined with a space, are the detail,
unless `--detail` is given. With a title on the command line, stdin is left alone.

**Long text.** Whitespace runs collapse to one space, line breaks included. The title and the detail
have no length limit, and the history keeps them whole. The card is never wider than 640 points.
Text too wide for it wraps, at every position: the title to at most two lines and the detail to at
most three, breaking between words, between Japanese or Chinese characters, or inside a word too
long for a line. When text is still left over, the last line ends in an ellipsis. Text that fits on
one line looks as it always has. The card stays up for `--seconds` however many lines it has.

**blip demo** plays every style at your configured position (the bottom when that is the notch),
then the notch card, two seconds each unless `--seconds`, `BLIP_SECONDS`
or the config's `seconds` say otherwise, and silent unless `--sound` or `BLIP_SOUND` is given.
Options apply to every card, so `blip demo --style wash` shows only wash.

**Returning at once.** blip checks everything first (flags, config, stdin, sounds and icons), so a
mistake still prints its message and exit status. Then it hands the card to a background blip and
exits. Cards from every blip queue up and show one after another, in the order they were sent.
`--wait` keeps blip running until its card has gone, still in its turn.

### Replacing cards

`--id` names what a card is about, such as a deploy or an agent session. A newer card with the same
id replaces an older one that is still waiting its turn, so a burst of updates shows only the
latest. When the older card is already on screen, the newer one takes its place there: the text
changes, its sound plays, and its time starts again. A card that asks a question (`--button`
without `--open`) never changes in place, and neither does one that would sit somewhere else
(another `--position`); the newer card then waits its turn. A question replaced before it showed
exits 5.

### Clicks

A click on a card brings forward the app blip was run from, such as your terminal, and takes the
card away. macOS names that app in the `__CFBundleIdentifier` environment variable of everything it
starts, and blip uses it; `--activate` names another app by its bundle identifier, and
`--activate none` leaves the card click-through. A card you can click holds while the pointer is on
it, like a card with a button. The card itself never takes focus.

### Missed cards and history

A card that comes up while the screen is locked would play to nobody, so blip holds it until the
screen unlocks. Then one or two held cards show as they are, and three or more show as one card,
`5 cards while you were away`, with their titles newest first. It takes the look and sound of the
newest `fail` card among them, else the newest `warn` card, else the newest card, so a failure
still reads as one. Of held cards with the same `--id`, only the newest shows. A click on the
summary brings forward the app the held cards came from, or nothing when they came from different
apps. A blip that waits for its card, with `--wait` or a `--button` question, keeps
waiting until the unlock and then shows its card on its own.

Every card is also kept in `$XDG_STATE_HOME/blip/history.jsonl`, or
`~/.local/state/blip/history.jsonl`, one JSON object per line, readable only by you. blip keeps
the last 1000 cards. `blip demo` cards are not kept.

```sh
blip history                  # every kept card, oldest first
blip history --missed         # only those that came up while the screen was locked
blip history --json           # as stored: {"time", "missed", "card": {"kind", "title", "detail", ...}}
blip history --missed --replay   # show the missed cards again
```

A listed line reads `2026-10-18 14:02  fail  deploy failed - api 1.4.2  (missed)`. `--replay`
shows the cards again, in order, with any button that opens something; a question's button is
dropped, since nothing waits for its answer anymore. Replayed cards are held while the screen is
locked like any other, and are not added to the history again.

### Buttons

`--open` adds a button that opens a URL or a file, such as a CI run, a pull request or a log.
`--button` names it. Hovering over the card holds it, and the countdown ring of a notch card stops;
moving away gives it another 1.5 seconds. A click on the button opens the target and takes the card
away; a click anywhere else on the card brings the sending app forward (see [Clicks](#clicks)) and
takes the card away. Clicking the button never takes focus from the app you are in.

`--button` without `--open` asks a question: blip waits and exits 0 if the button was clicked and 5
if it was not, so the script decides what happens:

```sh
blip warn "staging is ready" -d "api 1.4.2" --button "Promote" --seconds 10 && ./promote.sh
```

**blip run** runs the command with blip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. Options before `--` apply as usual.

### Recipes

Builds and tests, with how long they took:

```sh
blip run -- make test
blip run --position notch -- npm run build
```

A deploy that links to its run, and a backup:

```sh
blip run --open "https://github.com/me/app/actions" --button "View run" -- ./deploy.sh
blip run -- restic backup ~/Documents
```

A git hook, such as `.git/hooks/post-merge`, which blip never slows down:

```sh
#!/bin/sh
blip info "pulled $(git log -1 --format='%h %s')"
```

**Coding agents.** Point an agent's hooks at `blip hook` to see a card when it needs you or has
finished. blip reads the hook's payload: the title is the project, from the session's working
directory, and whether the agent needs you or is done, such as `blip needs you`. The detail is what
the agent said: the notification's message, or the last thing it wrote before it stopped. A
permission prompt or a question is `warn`, an idle prompt `info`, and a finished turn `ok`. Each
session's card has the id `<agent>:<session>`, so a session's new card replaces its last one
instead of queuing behind it, and a click on the card brings back the terminal the agent runs in.
blip reads Claude Code's `Notification` and `Stop` events and Codex's `agent-turn-complete`; any
other payload prints an error. Card options such as `--position` or `--seconds` work as usual. On a
mistake, `blip hook` exits 1, never 2, which tells Claude Code to block the agent.

**Claude Code**, in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [{ "type": "command", "command": "blip hook claude" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "blip hook claude" }]
      }
    ]
  }
}
```

**Codex**, in `~/.codex/config.toml`. Codex adds the event payload as the last argument:

```toml
notify = ["blip", "hook", "codex"]
```

Any other agent or tool: wrap what it runs in `blip run`, or call blip from its hooks.

### Styles

| Style | Look |
| --- | --- |
| `hud` | The dark HUD material with a hairline in the accent color. |
| `glass` | The system glass, faintly tinted with the accent. Needs macOS 26; earlier versions draw `hud`. |
| `wash` | The whole card in the accent color, as a gradient, darkened just enough that the white text reaches WCAG AA contrast (4.5:1) for any color. A `fail` card shakes once. |
| `terminal` | A solid dark card with an accent stripe, the kind in small capitals above the title, and monospaced text. No icon. |

At `--position notch` the card is drawn as one black shape with the notch, with a countdown ring
draining over `--seconds`. A drop forms under the notch, stretches on a neck, breaks free and widens
into a capsule just below the menu bar. It leaves the same way, pulled back up into the notch. A card
whose text wraps grows into a taller capsule with rounded corners. On a screen without a notch the
drop forms above the screen and oozes out of the middle of its top edge instead, and goes back into
it the same way.

**Several cards at once (experimental).** Notch cards that come in while one is showing stack below
it, up to `BLIP_STACK_MAX` (3) at a time; the rest wait their turn. With `BLIP_STACK=chain`, the
default, each new card drops out of the bottom of the last one and the oldest goes back into the
notch first, the others moving up behind it. With `BLIP_STACK=push` a new card drops out of the
notch once the others have moved down out of its way. `BLIP_STACK=off` shows one card at a time.
While the pointer is on any card in the stack, nothing moves: every countdown stops, gaps stay open
and new cards wait. A click on a card dismisses it. Only the cards of blips that returned at once
stack; a card that waits (`--wait`, or a question) waits its turn.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown. |
| 1 | `blip hook` could not make a card: a usage error, or a payload it cannot read or does not know. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh. |
| 4 | The config file is invalid; the message names the key and line. |
| 5 | The card had a button and blip waited, but the button was not clicked. |

Without `--wait`, 0 means the card was handed off to be shown. `blip run` always exits with the
wrapped command's exit code, as soon as the command ends.

## Config

blip reads `$XDG_CONFIG_HOME/blip/config.toml`, or `~/.config/blip/config.toml`. Every key is
optional, and a missing file is fine.

```toml
seconds  = 4.5
position = "notch"           # bottom | center | top | notch
size     = "regular"         # compact | regular | large
sound    = true              # false mutes every preset
style    = "glass"           # hud | glass | wash | terminal (default: glass on macOS 26, hud before)
motion   = "full"            # full | subtle | none

[preset.ok]                  # override a built-in preset, any subset of keys
sound = "Hero"

[preset.fail]
style = "wash"               # a preset can have its own style: failures shout, the rest stay calm

[preset.deploy]              # a custom preset: blip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
seconds = 6
```

Each setting comes from the first of: flags, the environment (`BLIP_SECONDS`, `BLIP_POSITION`,
`BLIP_SIZE`, `BLIP_SOUND`, `BLIP_STYLE`, `BLIP_MOTION`; `BLIP_SOUND=none` mutes), the config file,
the built-in defaults. A preset's own `seconds` and `style` beat the top-level ones. A custom preset
starts from `info` and replaces what it sets. Its name must match `[a-z][a-z0-9-]*` and must not be
`run`, `hook`, `demo` or `history`. Unknown keys print a warning; wrong types exit 4. The `notch` key
of earlier versions also prints a warning and is ignored: the droplet is the only notch motion now.

The file uses a small subset of TOML: comments, `key = value` lines with bare keys, table headers
such as `[preset.ok]`, and values that are single-line strings, decimal integers, floats or
booleans. Any other TOML syntax, such as arrays, inline tables, dotted keys or multi-line strings,
exits 4 with the line.

## Development

```sh
swift build
swift test            # on Linux, or on a Mac with Xcode
scripts/mac-check.sh  # on any Mac
```

`swift test` runs the BlipCore unit tests anywhere Swift runs, including Linux CI. The snapshot
tests render cards with the hidden `blip __render --out card.png` command and compare them with the
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet. For a notch
card, `__render --at 0.2` draws its entrance 0.2 seconds in, to check a motion frame by frame.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, shows each preset on screen once, runs `blip demo`, then lists the last
cards in the history. It works with only the Command Line Tools installed; Xcode is not needed. It
never overwrites a reference: to regenerate one on purpose, delete its PNG and run the script again.

## License

MIT
