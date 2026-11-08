# Click recipes

A click on a card brings its app forward, and in tmux the agent's pane. For anything else, give
`--on-click` a command. It reads the card's JSON on stdin ([the payload](contract.md)), and
`DRIP_FORWARD_ENV` names the variables it gets in `env`.

For an agent, set `DRIP_FORWARD_ENV` in the shell the agent starts from, and add `--on-click CMD` to
each `drip hook` command in the agent's settings. For an agent on another machine, set
`DRIP_FORWARD_ENV` there, and run `drip follow <machine> --on-click CMD` on the Mac.

Each value in `env` comes from the agent's session, or from another machine. Check it before you
use it, and quote it. The commands below drop a value they do not expect.

These recipes use [jq](https://jqlang.org).

## herdr

Focus the agent's tab and pane. Save this as `drip-herdr-focus` in your `PATH`, and make it
executable:

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

```sh
export DRIP_FORWARD_ENV="HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID"   # where the agent runs
drip hook claude --on-click drip-herdr-focus                             # in the agent's hooks
drip follow devbox --on-click drip-herdr-focus                           # or, for another machine
```

For another machine, the name you give `drip follow` must be the name herdr saved the machine as.

## WezTerm

Focus the agent's pane:

```sh
export DRIP_FORWARD_ENV=WEZTERM_PANE
drip hook claude --on-click 'p=$(jq -r ".env.WEZTERM_PANE // empty"); case $p in "" | *[!0-9]*) exit 0 ;; esac; wezterm cli activate-pane --pane-id "$p"'
```

## Ghostty across Spaces

macOS keeps an app that is already active on its Space, so a click can leave you on the wrong one.
This command focuses the Ghostty terminal whose title holds the card's machine, and Ghostty moves to
its Space. The first time it runs, macOS asks to let the app that runs `osascript` control Ghostty.

```sh
#!/bin/sh
machine=$(jq -r '.machine // empty')
[ -n "$machine" ] || exit 0
osascript - "$machine" <<'EOF'
on run argv
  tell application id "com.mitchellh.ghostty"
    repeat with candidate in terminals
      if name of candidate contains (item 1 of argv) then
        activate
        focus candidate
        return
      end if
    end repeat
  end tell
end run
EOF
```

Save it as `drip-ghostty-focus`, and run `drip follow devbox --on-click drip-ghostty-focus`. The
machine's name goes to AppleScript as an argument, never as part of the script.
