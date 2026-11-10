# Quiet while watching

Run any command only when you are not looking at the agent's terminal.

For: people who use `drip watching` in their own scripts. This recipe is a pattern. It has no snippet to install.

## How it works

`drip watching` exits 0 when you are watching the terminal (it is in front, its tmux pane shows, and
you used the keyboard or mouse within `away_after`). It exits 1 when you are not, and also when drip
cannot tell, for example without a GUI session: it then says why on stderr. It exits 2 only for a
usage error. It uses the same detection as `when_focused`. See the [reference](../../docs/agents.md#drip-watching).

## Example

Send a card from a long job only when you are away:

```sh
long-job; drip watching || drip ok "job is done"
```

When drip cannot tell, `||` shows the card, so you never miss one. To keep the reason off your
terminal, send stderr away:

```sh
long-job; drip watching 2>/dev/null || drip ok "job is done"
```

Add `--pane P` for a tmux pane other than the current one, and `--app ID` for another terminal app.

## Change it

Use the exit code in any hook, `--on-click` command or script.
