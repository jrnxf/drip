# Quiet while watching

Run any command only when you are not looking at the agent's terminal.

For: people who use `drip watching` in their own scripts. This recipe is a pattern. It has no snippet to install.

## How it works

`drip watching` exits 0 when you are watching the terminal (it is in front, its tmux pane shows, and
you used the keyboard or mouse within `away_after`), 1 when you are not, and 2 when drip cannot tell.
It uses the same detection as `when_focused`. See the [reference](../../docs/agents.md#drip-watching).

## Example

Send a card from a long job only when you are away:

```sh
long-job; drip watching || drip ok "job is done"
```

Exit 2 means drip cannot tell, and `||` then shows the card. To stay quiet on 2 as well:

```sh
long-job; drip watching; [ $? -eq 1 ] && drip ok "job is done"
```

Add `--pane P` for a tmux pane other than the current one, and `--app ID` for another terminal app.

## Change it

Use the exit code in any hook, `--on-click` command or script.
