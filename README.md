# blip

A HUD from the shell for macOS: one command shows a brief native card near the bottom of the
screen, or growing out of the camera notch, with an icon, a title, an optional detail line, a
colored accent and a system sound, then takes it away again.

```sh
blip "build finished"
blip ok "dotfiles up to date" -d "pulled 1 commit: feat(nvim): show hidden files"
blip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | blip ok
blip run -- make test
blip ok "shipped" --position notch --style glass
blip demo                     # every style and notch motion, to pick by feel
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
blip demo [options]
blip --version | --help
```

| Part | Behavior | Default |
| --- | --- | --- |
| `KIND` | A preset: `ok`, `warn`, `fail`, `info`, or a custom preset from the config file. When the first argument is not a preset, it is the title. | `info` |
| `TITLE` | The bold line. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The second, gray line. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. | the preset's |
| `--icon SYMBOL\|none` | An SF Symbol name. Unknown names fall back to the preset's icon with a warning. | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--position bottom\|center\|top\|notch` | Where the card sits. `notch` grows it out of the camera notch, and falls back to `top` on a screen without one. | `bottom` |
| `--size compact\|regular\|large` | Scales fonts, icon and padding by 0.85, 1.0 or 1.25. | `regular` |
| `--style hud\|glass\|wash\|terminal` | How the card is drawn; see [Styles](#styles). | `glass` on macOS 26, `hud` before |
| `--notch droplet\|snap\|ears` | How a `notch` card appears; see [Styles](#styles). | `droplet` |
| `--motion full\|subtle\|none` | `full` plays each style's entrance and exit, `subtle` only fades, `none` neither. Reduce Motion in System Settings caps it at `subtle`. | `full` |
| `--wait` | Block until the card has faded out. blip shows the card in its own process for now, so it always waits. | off |
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

**Long text.** Whitespace runs collapse to one space. The title keeps at most 80 characters and the
detail at most 120, counted as user-perceived characters so emoji are never split, and cut with a
single ellipsis. The card is never wider than 640 points.

**blip demo** plays every style at your configured position, then, on a screen with a notch, every
notch motion, two seconds each unless `--seconds`, `BLIP_SECONDS` or the config's `seconds` say
otherwise, and silent unless `--sound` or `BLIP_SOUND` is given. Options apply to every card, so
`blip demo --style wash` shows only wash, and `blip demo --notch ears` only that notch motion.

**blip run** runs the command with blip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. Options before `--` apply as usual.

### With coding agents

Point an agent's hooks at blip to see a card when it needs you or has finished.

**Claude Code**, in `~/.claude/settings.json` (`async` keeps Claude from waiting for the card):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
        "hooks": [{ "type": "command", "command": "blip warn 'Claude needs you' --position notch", "async": true }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "blip ok 'Claude is done' --position notch", "async": true }]
      }
    ]
  }
}
```

**Codex**, in `~/.codex/config.toml`. Codex adds an event payload to the command, which `sh -c` ignores:

```toml
notify = ["sh", "-c", "blip ok 'Codex is done' --position notch", "codex-notify"]
```

**Anything else**: wrap the command, and the card says how it ended and how long it took.

```sh
blip run -- ./scripts/agent-task.sh
```

### Styles

| Style | Look |
| --- | --- |
| `hud` | The dark HUD material with a hairline in the accent color. |
| `glass` | The system glass, faintly tinted with the accent. Needs macOS 26; earlier versions draw `hud`. |
| `wash` | The whole card in the accent color, as a gradient, darkened just enough that the white text reaches WCAG AA contrast (4.5:1) for any color. A `fail` card shakes once. |
| `terminal` | A solid dark card with an accent stripe, the kind in small capitals above the title, and monospaced text. No icon. |

At `--position notch` the card is drawn as one black shape with the notch, a countdown ring
draining over `--seconds`, and one of three motions:

| Notch motion | Behavior |
| --- | --- |
| `droplet` | A drop forms under the notch, stretches on a neck, breaks free and widens into a capsule just below the menu bar. It leaves the same way, pulled back up into the notch. |
| `snap` | One quick move from the notch into the card, without bounce. |
| `ears` | Ears grow either side of the notch, with the icon on the left and the title on the right, inside the menu bar so nothing is covered. No detail line. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh. |
| 4 | The config file is invalid; the message names the key and line. |

`blip run` always exits with the wrapped command's exit code.

## Config

blip reads `$XDG_CONFIG_HOME/blip/config.toml`, or `~/.config/blip/config.toml`. Every key is
optional, and a missing file is fine.

```toml
seconds  = 4.5
position = "bottom"          # bottom | center | top | notch
size     = "regular"         # compact | regular | large
sound    = true              # false mutes every preset
style    = "glass"           # hud | glass | wash | terminal (default: glass on macOS 26, hud before)
notch    = "droplet"         # droplet | snap | ears
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
`BLIP_SIZE`, `BLIP_SOUND`, `BLIP_STYLE`, `BLIP_NOTCH`, `BLIP_MOTION`; `BLIP_SOUND=none` mutes), the
config file, the built-in defaults. A preset's own `seconds` and `style` beat the top-level ones.
A custom preset starts from `info` and replaces what it sets. Its name must match `[a-z][a-z0-9-]*`
and must not be `run` or `demo`. Unknown keys print a warning; wrong types exit 4.

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
into `Tests/Snapshots`, shows each preset on screen once, then runs `blip demo`. It works with only
the Command Line Tools installed; Xcode is not needed. It never overwrites a reference: to
regenerate one on purpose, delete its PNG and run the script again.

## License

MIT
