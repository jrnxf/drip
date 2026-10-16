# blip

A HUD from the shell for macOS: one command shows a brief native card near the bottom of the
screen, with an icon, a title, an optional detail line, a colored accent and a system sound, then
fades it out.

```sh
blip "build finished"
blip ok "dotfiles up to date" -d "pulled 1 commit: feat(nvim): show hidden files"
blip fail "deploy failed" -d "$err" --seconds 8
git log -1 --format='%s%n%an' | blip ok
blip run -- make test
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
| `--position bottom\|center\|top` | Where the card sits. | `bottom` |
| `--size compact\|regular\|large` | Scales fonts, icon and padding by 0.85, 1.0 or 1.25. | `regular` |
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

**blip run** runs the command with blip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. Options before `--` apply as usual.

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
position = "bottom"          # bottom | center | top
size     = "regular"         # compact | regular | large
sound    = true              # false mutes every preset

[preset.ok]                  # override a built-in preset, any subset of keys
sound = "Hero"

[preset.deploy]              # a custom preset: blip deploy "shipped"
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
seconds = 6
```

Each setting comes from the first of: flags, the environment (`BLIP_SECONDS`, `BLIP_POSITION`,
`BLIP_SIZE`, `BLIP_SOUND`; `BLIP_SOUND=none` mutes), the config file, the built-in defaults.
A custom preset starts from `info` and replaces what it sets. Its name must match `[a-z][a-z0-9-]*`
and must not be `run`. Unknown keys print a warning; wrong types exit 4.

The file uses a small subset of TOML: comments, `key = value` lines with bare keys, table headers
such as `[preset.ok]`, and values that are single-line strings, decimal integers, floats or
booleans. Any other TOML syntax, such as arrays, inline tables, dotted keys or multi-line strings,
exits 4 with the line.

## Development

```sh
swift build
swift test
```

`swift test` runs the BlipCore unit tests anywhere Swift runs, including Linux CI. The snapshot
tests render cards with the hidden `blip __render --out card.png` command and compare them with the
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, and shows each preset on screen once. It never overwrites a reference: to
regenerate one on purpose, delete its PNG and run the script again.

## License

MIT
