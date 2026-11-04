# Troubleshooting

## Permissions

**No permissions.** drip asks macOS for none, but one, and only to follow
[agents on another machine](remote.md) in Ghostty: the first click on such a card
asks to let drip control Ghostty, to bring forward the terminal that shows herdr. It needs no
Accessibility, Screen Recording or Notifications permission and adds no login item. Nothing runs in the background but the
drip that is showing queued cards.

**Which screen.** A card shows on the screen the pointer is on, with or without a notch, and falls
back to the main screen. It also shows over full-screen apps and on every Space.

**No card?** A card that comes up while the screen is locked, or while drip is paused, waits for the
unlock or the end of the pause (see [Missed cards](usage.md#missed-cards-and-history)), and `drip history
--missed` lists them. Over ssh there is no GUI session, so drip exits 3. drip does not follow Focus,
since reading it would take a permission: cards show during Do Not Disturb, and in screen shares and
recordings. Run `drip pause` for those instead (see [Pausing](usage.md#pausing)).

## Privacy

drip makes no network connections of its own, sends nothing anywhere and collects no analytics:
the one connection is the ssh that `drip follow` runs to the machine you name. It only reads and
writes your config, the agents' settings that `drip setup` edits, its history, and small state
files next to it: the opt-in [debug log](#debug-log), the pause, `drip dismiss`'s requests, which card each agent session waits on and
the folder it runs in, each forgotten after 10 minutes, and where `drip follow` is in each
machine's queue.
The history, `~/.local/state/drip/history.jsonl`, is readable only by you and keeps the last 1000
cards. It holds each card's title and detail, up to 16,384 characters of each, so a card from a
coding agent keeps the agent's last message. Delete the file to clear it.

## Debug log

A diagnostic aid for working out why a card showed, or did not, such as a card that came up while
its terminal was in front. It is off. Turn it on with `debug = true` in the config or `DRIP_DEBUG=1`
(`DRIP_DEBUG=0` turns it off again); then `drip hook`, `drip follow` and the drip that shows a card
add one line for each decision about an agent's card, and for each click on one:

```
2026-10-27T10:20:51.123+01:00 follow card show agent=claude machine=devbox kind=ok id=claude:1a2b3c4d reason=not_focused_or_away waits=false when_focused=skip away_after=60.0 idle_seconds=2.1 frontmost=com.mitchellh.ghostty activate=com.mitchellh.ghostty app_in_front=true pane=herdr:w1:p2 herdr_machine=devbox pane_showing=false query="herdr pane get w1:p2" answer=not_showing query_ms=412
```

`drip debug` prints the log and `drip debug --clear` empties it. It is `debug.log` next to the
history, in `$XDG_STATE_HOME/drip` or `~/.local/state/drip`, readable only by you, and keeps about
the last 1 MB. It is for you, or an agent you ask to look at it, and goes nowhere: drip sends it
to no one.

A line is `time process event decision key=value ...`. `process` is `hook`, `follow` or `cli`; the
`event` is `card` (shown or skipped, and `reason`), `clear` (a card an agent's next step took away)
or `click`. What it records, and nothing else:

- the agent (`claude`, `codex` or `gemini`), the machine it ran on, the card's kind (`ok`, `warn`, ...)
  and whether it waits for you;
- the first 8 characters of the session id;
- the settings that decided: `when_focused`, `away_after`, `agent_cards`, `done_after`, and `DRIP_HOOK`;
- what drip noticed: the bundle identifier of the frontmost app and of the app a click brings
  forward, seconds since the keyboard or mouse was last used (both on every card line, `unknown` when drip did not ask, and the frontmost `none` when no app is in front), `topmost_visible`, the terminal when its window is on top of a display, else `none`, whether the agent's pane is in front, and, for a remote agent, `machine_selected`, whether your herdr window shows its machine;
- the pane's id (`herdr:w1:p2`, `tmux:%3`), the herdr machine, the query run to ask whether it is in
  front (`herdr pane get w1:p2`, or `tmux display-message`), its answer and how long it took;
- for a click: what drip tried to bring forward, whether macOS refused it and why, and whether
  selecting the pane worked.

It never records a card's title or detail, an agent's message or prompt, a tool's name or input, a
command, a folder or file path from an agent, or a hook payload, and it holds no socket path or
other address.
