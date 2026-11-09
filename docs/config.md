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
`DRIP_DEBUG`, and for the
[zsh block](usage.md#without-typing-drip-run) `DRIP_SLOW_AFTER` and `DRIP_SLOW_IGNORE`;
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
