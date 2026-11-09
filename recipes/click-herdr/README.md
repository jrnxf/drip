# Click: herdr

A click on an agent's card focuses its herdr tab and pane.

For: herdr users, with agents here or on another machine. Needs [jq](https://jqlang.org).

## How it works

`drip hook --on-click CMD` runs `CMD` on a click, with the card's JSON on stdin ([the payload](../../docs/contract.md)).
`DRIP_FORWARD_ENV` names the variables that go in `env`. [drip-herdr-focus](drip-herdr-focus) reads
the herdr ids from `env` and calls `herdr`. It drops a value that is not a plain id.

## Install

1. Put `drip-herdr-focus` in your `PATH` and make it executable.
2. In the shell the agent starts from:
   `export DRIP_FORWARD_ENV="HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID"`
3. Add `--on-click drip-herdr-focus` to each `drip hook` command in the agent's settings.
   `drip hook claude --on-click drip-herdr-focus` is one example. Pick a [recipe](../README.md) first.

For an agent on another machine, set `DRIP_FORWARD_ENV` there. On the Mac, run
`drip follow devbox --on-click drip-herdr-focus`. The name you give `drip follow` must be the name
herdr saved the machine as.

## Change it

Edit the script. Check each value before you use it, and quote it.
