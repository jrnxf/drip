# Click: WezTerm

A click on an agent's card focuses its WezTerm pane.

For: WezTerm users. Needs [jq](https://jqlang.org).

## How it works

`--on-click` runs a command on a click and gives it the card's JSON on stdin
([the payload](../../docs/contract.md)). `DRIP_FORWARD_ENV` names the variables in `env`. The command
reads `WEZTERM_PANE`, checks that it is a number, and runs `wezterm cli activate-pane`.

## Install

1. In the shell the agent starts from: `export DRIP_FORWARD_ENV=WEZTERM_PANE`
2. Add this to each `drip hook` command in the agent's settings. Pick a [recipe](../README.md) first.

```sh
drip hook claude --on-click 'p=$(jq -r ".env.WEZTERM_PANE // empty"); case $p in "" | *[!0-9]*) exit 0 ;; esac; wezterm cli activate-pane --pane-id "$p"'
```

## Change it

Replace the command. It must read the card's JSON on stdin and treat every `env` value as data.
