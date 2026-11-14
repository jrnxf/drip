# What scripts can rely on

This page lists what drip keeps stable for scripts and other tools. Before 1.0, a break comes only
in a new minor version, and the release notes say so. From 1.0, a break comes only in a new major
version. Everything else can change in any release.

## Public

**The command line.** The subcommands, flags and arguments that `drip --help` and `drip help
<subcommand>` list, with the meaning [usage.md](usage.md) gives them.

**Exit codes.**

| Code | Meaning |
| --- | --- |
| 0 | The card was shown, or handed off to be shown. A question was answered yes. |
| 1 | A question was answered no, or drip could not do its work, such as write its state directory. |
| 2 | Usage error: a mistake in the command line or a `DRIP_*` variable. |
| 3 | No GUI session, for example over ssh. |
| 4 | `drip doctor` only: the config file is invalid. A card command warns on stderr instead, and uses the defaults for the bad keys. |
| 5 | A `--yes` question went without a click on its buttons. A card with an `--open` button asks nothing, so it exits 0 with `--wait`, clicked or not. |

- `drip run` exits with the wrapped command's exit code instead, 127 when it is not found.
- `drip hook` exits 0 without a GUI session and 1 for any failure, never 2 or more.
- `drip watching` exits 0 when you are watching, 1 when you are not or drip cannot tell (it says why on stderr), and 2 for a usage error.
- `drip doctor` exits 2 for a bad `DRIP_*` variable, else 4 for an invalid config file, else 1 when something stops cards now (it says what), else 0.

[Exit codes](usage.md#exit-codes) shows the same table, and says when `drip run` and `--wait`
exit.

**`--result` output.** Once the card has gone, drip prints one line on stdout, one of four words:
`activate`, `dismiss`, `timeout` or `replaced`. [How a card ended](usage.md#how-a-card-ended) says
what each means. drip prints the word only when it exits 0, and prints nothing else on stdout:
errors and warnings stay on stderr. The exit codes stay as the table above gives them. A new word
comes only with a break.

**`drip history --json`.** One JSON object per line, oldest first, for the last 20 cards, or every card with `--all`: `time` (ISO 8601), `missed`
(true or false) and `card`. `card` writes each setting the way its flag takes it, and leaves out
`detail`, `button`, `open`, `id` and `activate` when the card had none. New keys can come in any
release, so ignore keys you do not know. [Missed cards and
history](usage.md#missed-cards-and-history) has an example.

**`drip doctor --json`.** One JSON object: `version`, `status` (the exit code), `stops_cards` (a
list of `bad_variable`, `no_gui_session`, `paused` and `screen_locked`, empty when cards show now),
`shows_cards` (false on Linux, where drip shows no cards), `gui_session`, `paused`, `pause_ends`
(ISO 8601, or null), `screen_locked`, `config` (`path`, `exists`, `valid`, `ignored` when drip
ignores the whole file, and `errors` and `warnings`, each a list of lines), `environment_errors`
(a line for each `DRIP_*` variable drip cannot read), `settings` (by the config file's keys,
`sound` null when each preset plays its own, and a preset the config gives a sound of its own
keeps it unless `DRIP_SOUND` is set or `sound` is `none`, and `contrast` true when the outline
shows, from `DRIP_CONTRAST`, the config or macOS Increase Contrast) and `state_directory` (`path` and `writable`). Every key is always there. New keys can come in any release, so
ignore keys you do not know. [Checking drip](usage.md#checking-drip) has the details.

**The `--on-click` payload.** The command reads one line of JSON on stdin, version 1:

| Field | What it holds |
| --- | --- |
| `v` | `1`. A new version comes only with a change that breaks a reader of this one. |
| `kind`, `title` | The card's kind and title, the title cut at 500 characters. |
| `id` | The card's `--id`, when it has one. |
| `app` | The bundle identifier the click brings forward, when there is one. |
| `machine` | For a card `drip follow` showed, the machine the agent runs on. |
| `env` | The variables `DRIP_FORWARD_ENV` names, read where the card came from. Always present, empty when there are none. |

New keys can come in version 1, so ignore keys you do not know. The command runs with `/bin/sh -c`
for up to 10 seconds. Treat each value as data, never as a command: a card from another machine
sets `env` and `machine` there.

**`DRIP_FORWARD_ENV`.** A space-separated list of variable names. drip passes on at most 16, each a
name of letters, digits and `_` up to 64 long, with a value of up to 256 characters and no control
characters. It leaves the rest out.

**The config file and `DRIP_*` variables**, as [config.md](config.md) lists them.

## Private

These are drip's own, and can change in any release without notice:

- the queue that `drip-remote-hook` writes on another machine (`remote.jsonl`) and its line format,
  and the script that `drip follow --hook-script` prints;
- the history file (`history.jsonl`), held cards (`held.jsonl`) and how drip stores a card in them:
  read the history with `drip history --all --json`;
- the other state files next to them, and the format of the [debug log](troubleshooting.md#debug-log);
- `drip __background`, the process that shows the cards, and how other drips hand cards to it.
