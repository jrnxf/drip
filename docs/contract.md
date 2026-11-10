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
| 0 | The card was shown, or handed off to be shown without `--wait`. A question was answered yes. `drip watching`: you are watching. |
| 1 | A question was answered no. `drip watching`: you are not watching, or drip cannot tell (it says why on stderr). Any other command: drip could not do its work, such as write its state directory. `drip hook` exits 1 for any failure. |
| 2 | Usage error: a mistake in the command line or a `DRIP_*` variable. `drip hook` never exits 2. |
| 3 | No GUI session, for example over ssh. `drip hook` exits 0 then, and `drip watching` 1. |
| 4 | The config file is invalid. `drip hook` and `drip watching` exit 1 then. |
| 5 | drip asked a `--yes` question and waited, but no button was clicked. Only a question exits 5: a card with an `--open` button exits 0 with `--wait`, clicked or not. |

`drip run` exits with the wrapped command's exit code instead, 127 when it is not found.

[Exit codes](usage.md#exit-codes) shows the same table, and says when `drip run` and `--wait`
exit.

**`drip history --json`.** One JSON object per line, oldest first: `time` (ISO 8601), `missed`
(true or false) and `card`. `card` writes each setting the way its flag takes it, and leaves out
`detail`, `button`, `open`, `id` and `activate` when the card had none. New keys can come in any
release, so ignore keys you do not know. [Missed cards and
history](usage.md#missed-cards-and-history) has an example.

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
  and the script that `drip remote-hook` prints;
- the history file (`history.jsonl`), held cards (`held.jsonl`) and how drip stores a card in them:
  read the history with `drip history --json`;
- the other state files next to them, and the format of the [debug log](troubleshooting.md#debug-log);
- `drip __background`, the process that shows the cards, and how other drips hand cards to it.
