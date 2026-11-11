# Config

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
history = 1000                # most cards the history keeps, 0 to 1000; 0 stops recording (see drip history)
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
`DRIP_HISTORY`, `DRIP_DEBUG`, and for the
[zsh block](usage.md#without-typing-drip-run) `DRIP_SLOW_AFTER` and `DRIP_SLOW_IGNORE`;
`DRIP_SOUND=none` mutes), the config file, the built-in defaults. An invalid value in the
environment is a usage error, which exits 2, when drip makes a card and in `drip watching`.
`drip hook` exits 1 for it instead. `drip run` says so, still runs the command and shows its card
with the defaults, and exits with the command's code. `drip history`, `drip debug` and
`drip dismiss` never read it, and nor does a hook that shows nothing or only takes a card away. An
invalid `DRIP_DEBUG` counts as unset. A preset's own `seconds` and `sound` beat the top-level ones, except
that a top-level `sound = false` mutes every preset. A custom preset starts from `info` and replaces
what it sets. Its name must match `[a-z][a-z0-9-]*` and must not be one of drip's subcommands or a
name kept for them: `run`, `hook`, `history`, `show`, `help`, `version`, `remote-hook`,
`watching`, `follow`, `config`, `completion`, `completions`, `doctor`, `pause`, `resume`, `test`,
`dismiss`, `clear` or `debug`. A custom preset's ring shows no state's mark. Unknown keys print a warning;
a wrong type or an invalid value prints a warning too, and that key keeps its default, so the card still
shows. `drip doctor` lists every problem in the file at once, and exits 4 when there is one, unless a
`DRIP_*` variable is bad, which exits 2.

The file uses a small subset of TOML: comments, `key = value` lines with bare keys, table headers
of one or two keys such as `[preset.ok]`, and values that are single-line strings, decimal
integers, floats or booleans. Dotted keys and single-line inline tables work too. Each of these
reads as a `[preset.ci]` table with `sound = "Hero"`: `preset.ci.sound = "Hero"` at the top level,
and `ci.sound = "Hero"` or `ci = { sound = "Hero" }` under `[preset]`. Dotted keys and inline tables
go down at most 8 tables together. Defining a table twice, by a header, a dotted key or an inline
table, is an error. Such an error, and any other TOML syntax drip does not read, such as arrays or
multi-line strings, prints a warning with the line, and every key keeps its default. So does a file
larger than 1 MB.
