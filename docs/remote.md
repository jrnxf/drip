# Agents on another machine

An agent on a Linux box you reach over ssh, with no screen and no drip there, raises its cards on
your Mac by the same rules as one on the Mac: `DRIP_HOOK`, `agent_cards`, `done_after`,
`when_focused` and the rest of the [config](config.md). Its hooks run `drip-remote-hook`, a small
POSIX sh script that appends each event to a queue file there, and `drip follow` on the Mac reads
that queue over ssh and shows each event's card as `drip hook` would. The Mac connects out to the
machine; nothing connects in.

1. On the Mac, save the hook on the machine, here `devbox`, in a folder on its `PATH`:

   ```sh
   drip setup remote | ssh devbox 'mkdir -p ~/.local/bin && cat > ~/.local/bin/drip-remote-hook && chmod +x ~/.local/bin/drip-remote-hook'
   ```

2. Add the hooks that run it to the agent's settings on the machine. `drip setup claude --remote`
   prints them, the same hooks as `drip setup claude` adds on a Mac with `drip-remote-hook claude`
   as their command; likewise `codex` and `gemini`.

3. On the Mac, follow the machine, by any name `ssh` takes, a `Host` from `~/.ssh/config` too:

   ```sh
   drip follow devbox
   ```

   It needs to log in without a prompt, with a key or an agent: it runs ssh with `BatchMode=yes`.

4. To keep it running, have launchd start it at login. `drip follow devbox --launchd` prints the
   launchd agent, with the terminal you ran it from as the app a click brings forward, and the
   `PATH`, `DRIP_*` settings (all but `DRIP_HOOK`), `XDG_CONFIG_HOME` and `XDG_STATE_HOME` set
   where you run it, so remote cards follow the same settings, config and `drip pause` as the rest:

   ```sh
   drip follow devbox --launchd > ~/Library/LaunchAgents/co.jrnxf.drip.follow.devbox.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.jrnxf.drip.follow.devbox.plist
   ```

   It logs to `~/Library/Logs/co.jrnxf.drip.follow.devbox.log`. `launchctl bootout
   gui/$(id -u)/co.jrnxf.drip.follow.devbox` stops it; delete the plist to keep it stopped.

**The queue.** Each event is one line of JSON in `$XDG_STATE_HOME/drip/remote.jsonl` on the machine,
or `~/.local/state/drip/remote.jsonl`, or `$DRIP_QUEUE` when set there: the hook's payload, the
agent, the machine's name (`$DRIP_MACHINE`, or `uname -n`, in letters, digits, `.`, `_` and `-`,
starting with a letter or digit), the time, and the session's `DRIP_HOOK`,
Claude Code's attendance variables, and herdr's `HERDR_PANE_ID`, `HERDR_TAB_ID` and
`HERDR_WORKSPACE_ID`. The hook takes a lock, with `flock` when the machine has it and else with a
`remote.jsonl.lockdir` directory, so lines from sessions at once never mix, and once the queue
passes 8 MB it moves it to `remote.jsonl.1`,
replacing the one before: the two never take much more than 16 MB. The file is readable only by
you. The hook prints nothing and always exits 0, so it never fails or holds up a turn, even when
it cannot write the queue. `drip follow --queue <path>` reads another path.

`drip follow` reads the queue from a non-interactive shell on the machine, which skips most of
your shell's startup files: set `DRIP_QUEUE` or `XDG_STATE_HOME`, if you set them at all, where
such a shell sees them too (`~/.zshenv` for zsh, or `~/.bashrc` above its interactive check for
bash), or pass `--queue`. When there is no queue at the path it reads, `drip follow` says so in
its log, and again once there is. Anything that shell prints, such as a welcome line, is ignored.

**Following.** `drip follow` checks the queue every second, reconnects when the connection drops,
after 1 second and then up to a minute between tries, and takes up after the last event it
handled: it keeps its place in `$XDG_STATE_HOME/drip/follow` on the Mac, so a new connection
replays nothing it showed. The first time, it starts at the end of the queue. An event older than
5 minutes when it arrives, as one queued while the Mac slept, shows no card rather than one in a
burst of others, but still takes away the card its session waits on, as after you answered on the
machine: `--max-age 30m` sets another limit. Age is by the machine's own clock: its reader tells
`drip follow` the time there when it connects and every 15 seconds, so a clock that runs behind or
ahead of the Mac's, as in a VM or WSL2, hides no stale events and none that are new, and `drip follow`
says so in its log when it is a minute or more off. It reads the config with each event, so an edit
applies to the next, and says each of its warnings once.

One `drip follow` per machine runs at a time, counted by the name you give it: `drip follow devbox`
and `drip follow me@devbox`, or an ssh alias for the same machine, are two machines to drip, and
run together show every card twice, each with its sound. Follow a machine by one name. A second
`drip follow` of the same name waits, and says so in its log, until the first ends and then
takes over, so a launchd agent started at login while another is running does not restart in a loop.

**Its cards.** A card from the machine names it, as in `api on devbox is done`, and its id is
`<agent>:<session>@<machine>`, so it never replaces a card of a session on the Mac. When the agent
runs in herdr, `when_focused` and `away_after` apply as they do on the Mac: drip asks the machine's
herdr, with `herdr --machine <machine> pane get`, whether the agent's pane is the focused one there,
and takes the app `--activate` names for the terminal in front. herdr marks a pane focused for any
client attached to that machine, so drip cannot tell whether the herdr in front on the Mac shows
that machine or Local. When herdr does not answer within 3 seconds, or the agent runs outside herdr,
drip takes you not to be watching: its cards show, with their sound. The `DRIP_HOOK` and attendance
of the session on the machine decide whether it raises cards, not the variables `drip follow` runs
with. Its permission cards only tell, even with `approve` on: the answer stays in the terminal on
the machine, and its hook there returns at once.

**Clicks.** A click brings forward the terminal you ran `drip follow` from, or the app
`--activate` names. In Ghostty, when the agent runs in herdr, Ghostty itself brings forward the
terminal whose title herdr's default `window_title`, `{hostname}: {workspace}`, gives it: the one
showing the machine, else the one showing this Mac, on whichever Space it is. The first such click
asks you once to let drip control Ghostty. Then drip focuses the agent's workspace and tab on the
machine with `herdr --machine <machine> workspace focus` and `tab focus`. That is as close as herdr lets a
command get today: it cannot focus a pane on another machine by its id, nor switch the herdr on the
Mac from Local to that machine, so you see the tab once your herdr shows the machine. herdr names
the machine by the label you saved it under with `herdr machine`: by default, the one saved with the
ssh target, else the one labeled with its host, else the host itself; `--herdr-machine <label>`
names another. `drip follow`'s log says how each click went: the app brought forward, or macOS
refusing to, and any herdr command refused, with why.
