# Click: herdr

A click on an agent's card focuses its herdr tab and pane.

For: herdr users, with agents here or on another machine. Needs [jq](https://jqlang.org).

## How it works

`drip hook --on-click CMD` runs `CMD` on a click, with the card's JSON on stdin ([the payload](../../docs/contract.md)).
`DRIP_FORWARD_ENV` names the variables that go in `env`. The script reads the herdr ids from `env`
and calls `herdr`. It drops a value that is not a plain id.

## Install

1. Save this as `drip-herdr-focus` in a folder on your `PATH`, and make it executable (`chmod +x`):

```sh
#!/bin/sh
payload=$(cat)
field() { printf '%s' "$payload" | jq -r "$1 // empty"; }
valid() { case $1 in '' | -* | *[!A-Za-z0-9:._-]*) return 1 ;; esac; }
pane=$(field .env.HERDR_PANE_ID)
tab=$(field .env.HERDR_TAB_ID)
workspace=$(field .env.HERDR_WORKSPACE_ID)
machine=$(field .machine)
if [ -n "$machine" ]; then
  # An agent on another machine: herdr names it as you saved it.
  valid "$machine" || exit 1
  valid "$workspace" && herdr --machine "$machine" workspace focus "$workspace"
  valid "$tab" && herdr --machine "$machine" tab focus "$tab"
else
  valid "$tab" && herdr tab focus "$tab"
  valid "$pane" && herdr agent focus "$pane"
fi
exit 0
```

2. In the shell the agent starts from:
   `export DRIP_FORWARD_ENV="HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID"`
3. Add `--on-click drip-herdr-focus` to each `drip hook` command in the agent's settings, as in
   `drip hook claude --on-click drip-herdr-focus`. Pick a [notify recipe](../README.md) first.

For an agent on another machine, set `DRIP_FORWARD_ENV` there. On the Mac that shows the cards, run
`drip follow <machine> --on-click drip-herdr-focus`. The name you give `drip follow` must be the name
herdr saved the machine as.

## Change it

Edit the script. Check each value before you use it, and quote it.
