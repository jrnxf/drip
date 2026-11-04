# Usage

The full reference. `drip --help` lists the same options, and `drip help <subcommand>` one subcommand's.

```
drip [KIND] [TITLE] [options]
drip run [options] [--] <command> [args...]
drip hook claude|codex|gemini [options] [payload]
drip setup claude|codex|gemini [--print | --remote]
drip setup zsh [--print]
drip setup remote
drip follow <ssh-target> [options]
drip history [--missed] [-n N | --all] [--json | --replay]
drip debug [--clear]
drip dismiss [--id ID]
drip pause [DURATION]
drip resume
drip --version | --help
drip help <subcommand>
```

`drip --help` lists every option and subcommand, with examples; `drip help run`, or `drip run
--help`, shows one subcommand's. `drip show` names the first form, which drip runs when the first
word names no subcommand. A mistake prints `drip: ` and what is wrong, then where the help is, and
exits 2, or 1 for `drip hook`.

| Part | Behavior | Default |
| --- | --- | --- |
| `KIND` | A preset, which sets only the card's look, its icon, color and sound: `ok`, `warn`, `fail`, `info`, or a custom preset from the config file. When the first argument is not a preset and no title follows it, it is the title; followed by a title, it is an unknown preset and exits 2, saying how to quote a title of several words. | `info` |
| `TITLE` | The bold text, up to 2 lines. Required unless stdin provides it. | none |
| `-d`, `--detail TEXT` | The gray text under the title, up to 3 lines. | none |
| `-s`, `--seconds N` | Time fully visible, excluding fades: 0.5 to 60. A card that stays or a question given a time counts it down instead of waiting. | 4.5 |
| `--sound NAME\|none` | A sound from /System/Library/Sounds, a path to an .aiff or .wav file, or `none`. Unknown names print a warning and play nothing. | the preset's |
| `--icon SYMBOL\|PATH\|app:ID\|mark:NAME\|none` | An SF Symbol name; a path to an image, such as a `.png`, `.pdf` or `.icns` file, drawn as it is; `app:` and an app's bundle identifier, such as `app:com.openai.chat`, for that app's own icon; or `mark:claude`, `mark:codex` or `mark:gemini` for an agent's mark that drip bundles. An icon that cannot load falls back to the preset's with a warning. See [Icons](#icons). | the preset's |
| `--color HEX\|NAME` | `#rrggbb`, or `green`, `orange`, `red`, `blue`, `purple`, `pink`, `yellow` or `gray`. | the preset's |
| `--open URL\|PATH` | Adds a button that opens a URL or a file, a relative path from the directory drip runs in; see [Buttons](#buttons). Empty, as `--open "$CI_URL"` without a URL, it adds no button and warns. | none |
| `--button LABEL` | The `--open` button's label, up to 24 characters. Without `--open` it is a usage error. | `Open` |
| `--yes LABEL` | Asks a question with a yes button of this label, up to 24 characters: drip waits for the card, then exits 0 if the button was clicked and 5 if no button was. The card waits for its answer, whatever its look, unless it is given a time. Not for `drip run` or `drip hook`, which exit 2 or 1 instead, as nothing reads their answer. See [Buttons](#buttons). | none |
| `--no LABEL` | With `--yes`, a no button of this label to its left: drip exits 1 if it was clicked. | none |
| `--id ID` | Names what the card is about, up to 200 characters; see [Replacing cards](#replacing-cards). | none |
| `--activate BUNDLE-ID\|none` | The app a click on the card brings forward, such as `com.apple.Terminal`; see [Clicks](#clicks). | the app drip was run from |
| `--stay` | Keeps the card on screen until it is clicked, a newer card with the same `--id` replaces it, or 10 minutes pass, without holding the script: drip still returns at once. Works with any look; see Cards that wait below. | off |
| `--wait` | Wait until the card has gone before exiting. | off |
| `--quiet` | Never print warnings. | off |

The size and the motion are settings rather than flags: `size` (`compact`, `regular` or `large`,
scaling fonts, icon and padding by 0.85, 1.0 or 1.25) and `motion` (`full` drops the card out of
the notch on its springs and takes it back in, `subtle` only fades, `none` neither; Reduce Motion in System Settings caps it at
`subtle`) in the [config](config.md), or `DRIP_SIZE` and `DRIP_MOTION`.

| Preset | Icon | Color | Sound |
| --- | --- | --- | --- |
| `ok` | `checkmark.circle.fill` | green | Glass |
| `warn` | `exclamationmark.circle.fill` | orange | Purr |
| `fail` | `xmark.circle.fill` | red | Basso |
| `info` | `info.circle.fill` | blue | Tink |

The kind is the look; flags are the behavior. `--stay` keeps a card on screen, `--yes` and `--no`
wait for an answer, and `--open` adds a link button. Every card keeps its icon, a question too.

**Cards that wait.** `--stay` is for something waiting on you, such as an agent asking for
permission, on any look: `drip fail "deploy failed" --stay`. The card has no countdown: a white dot
stands where the ring would be, and every 2.4 seconds a soft halo grows out of it to about twice its
size and fades (with Reduce Motion, the dot alone). The card stays until you click it or a newer
card with the same `--id` replaces it, and drip returns at once, so the script goes on. It gives way
to other cards: when another card waits for its place and every card on screen waits too, the
oldest goes back into the overflow drop (in push, the pill), keeping what is left of its wait, and comes
back once there is room. It never stays longer than 10 minutes. A question (`--yes`), of any
look, waits too and never gives way: it stays until it is answered, replaced or its 10 minutes are
up, other cards stack around it, and a card with no room in the stack, or another question, waits
its turn. `--seconds`, `DRIP_SECONDS` or the preset's `seconds` in the config give a card that stays
or a question a countdown instead.

**stdin.** When no title is given and stdin is not a terminal, drip reads stdin to the end, keeping
the first 64 KB, so the command writing it is never cut short: the first non-empty line is the title
and the remaining lines, joined with a space, are the detail, unless `--detail` is given. A writer
that never ends, such as `tail -f`, never shows a card. With a title on the command line, stdin is
left alone.

## Icons

`--icon` takes an SF Symbol, an image file, an app's own icon or an agent's mark. A picture is drawn
as it is, never tinted, at the size of the preset's icon; an app's icon loses the margin around its
rounded square, so its mark fills the same place. When the icon is not the preset's own, the
card shows the state in its ring instead, around the state's mark: a check for `ok`, a cross for
`fail`, and so on. The icon then says who, and the ring what. A card that stays shows its waiting
dot there instead, and a card with buttons shows the buttons in place of the ring. Every card keeps
its icon, a question with `--yes` and `--no` buttons too:

```sh
drip info "my-app needs you" -d "Codex wants to run npm install" --icon app:com.openai.codex --stay
drip ok "backup done" --icon ~/Pictures/nas.png
```

A relative image path is taken from the directory drip runs in, or, in the config file, from the
config file's directory. An app's icon comes from the app installed on your Mac.

**Agent marks.** For a coding agent with no app installed, drip bundles three marks, drawn as
vectors in their own colours, so they are sharp at every size, bare on the island's black. `mark:claude`,
Claude's spark from [Anthropic's press kit](https://www.anthropic.com/press-kit); `mark:codex`,
OpenAI's Blossom from [OpenAI's brand page](https://openai.com/brand/); and `mark:gemini`, Gemini's
spark in its colours from [LobeHub's icons](https://lobehub.com/icons/gemini) (MIT, see
[THIRD_PARTY.md](../THIRD_PARTY.md)), since Google publishes no vector of it outside its partner hub.
The marks are their owners' trademarks, used unaltered to name the agent a card is about. drip is
not affiliated with Anthropic, OpenAI or Google, and none of them endorses it.

**Text that starts with a dash.** `-d`, `--button`, `--yes`, `--no` and `--id` take their next argument whatever it
starts with, so `-d "$err"` works when the error reads `--- FAIL: TestFoo`, and `--id --wait` is an
id, not a missing value. A title that starts with
a dash goes after `--`: `drip fail -- "$line"`.

**Long text.** Whitespace runs collapse to one space, line breaks included. Terminal escape
sequences, such as the colors of piped output, other control characters and the bidi controls are
dropped. The title and the detail have no length limit, and the history keeps up to 16,384
characters of each, ending in an ellipsis when cut. The card is never wider than 640 points. Text
too wide for it wraps: the title to at most two lines and the detail to at most
three, breaking between words, between Japanese or Chinese characters, or inside a word too long
for a line. When text is still left over, the last line ends in an ellipsis. The card stays up for
`--seconds` however many lines it has.

**Returning at once.** drip checks everything first (flags, config, stdin, sounds and icons), so a
mistake still prints its message and exit status. Then it hands the card to a background drip and
exits. Cards from every drip queue up and show one after another, in the order they were sent.
`--wait` keeps drip running until its card has gone, still in its turn.

## Replacing cards

`--id` names what a card is about, such as a deploy or an agent session. A newer card with the same
id replaces an older one that is still waiting its turn, so a burst of updates shows only the
latest. When the older card is already on screen, the newer one takes its place there: the card
springs to its new size, the text that changed crossfades, a new state's colour settles over the
old one as its icon pops in, its sound plays, and its time starts again. When the ring carries the
state and the icon stays, such as an agent's, the icon stays still and the state pops in the ring. With reduced motion the
size changes at once and only the crossfade remains; with motion `none` it all changes at once. A card that asks a question (`--yes`)
never changes in place; the newer card then waits its turn. A question replaced before it showed
exits 5.

## Clicks

A click on a card brings forward the app drip was run from, such as your terminal, and takes the
card away. macOS names that app in the `__CFBundleIdentifier` environment variable of everything it
starts, and drip uses it; `--activate` names another app by its bundle identifier, and
`--activate none` leaves a card without a button click-through; on a card with a button, a click off
the button only takes the card away. In tmux, a click also selects the pane drip ran in, in the
terminal that shows that tmux session now, which may not be the one that started tmux; in herdr, the
pane's tab and then its agent; in WezTerm, the pane. None of them needs a permission. A card you
can click holds while the pointer is on it, like a card with a button, for up to 5 seconds after
the pointer last moved, so a pointer left resting on it never keeps it there. A card that waits for
you is always clickable: a click takes it away, even with `--activate none`. The card itself never takes focus.
Only the cards themselves take the pointer: a click beside a card, at its height, or under it
reaches the window behind, as it would with no card showing.

**Out of the way.** While the pointer is on a card you can click, a × takes its icon's place, and a
card that brings an app forward shows an arrow where its ring was. A click on the ×, or a
right-click, Control-click or Option-click anywhere on the card, takes it away and brings nothing
forward; a question goes unanswered, as if it timed out. `drip dismiss` takes every card on
screen, and every card still waiting its turn, away the same way; `drip dismiss --id deploy` only
those with that id; `drip clear` is the same command. Bind it to a key in Shortcuts, Raycast or skhd
to clear the notch from the keyboard. VoiceOver offers each card's Open and Dismiss as its actions.

## Missed cards and history

A card that comes up while the screen is locked would play to nobody, so drip holds it until the
screen unlocks. Then the last five held cards play back as they came, newest first. When more
than five were held, the older ones follow as one card, `12 cards while you were away`, with their
titles newest first, or as they are when only one or two are left; `drip history` has them all.
Cards held while drip is paused (see [Pausing](#pausing)) play back the same way when the pause
ends. The summary takes the look and sound of the newest `fail` card among the cards it sums up,
else the newest card that stays, else the newest `warn` card, else the newest card, so a failure
still reads as one. The summary counts down, even when it takes the look of a card that stays. Of
held cards with the same `--id`, only the newest shows. A click on the summary brings forward the
app its cards came from, or nothing when they came from different apps. A drip that waits for its card, with `--wait` or a `--yes` question, warns that the
screen is locked, keeps waiting until the unlock and then shows its card on its own.

Every card is also kept in `$XDG_STATE_HOME/drip/history.jsonl`, or
`~/.local/state/drip/history.jsonl`, one JSON object per line, readable only by you. drip keeps
the last 1000 cards.

```sh
drip history                  # the last 20 cards, newest first, as they showed
drip history -n 50            # the last 50
drip history --all            # every kept card
drip history --missed         # only those that came up while the screen was locked or drip was paused
drip history --json           # every card, oldest first, one JSON object per line, for scripts
drip history --missed --replay   # show the missed cards again
```

The listing shows each card as it showed on screen, newest first: how long ago it came up, then a
bar in the color of its kind (green `ok`, yellow `warn`, red `fail`, blue `info`) on every line, the
title in bold and the lines of detail the card had room for, with a rule between cards. A card
that came up while the screen was locked or drip was paused has `missed` after its title.

```text
2m ago    ┃ drip is done
          ┃ Split it. Pane awareness for herdr belongs in drip. Your
          ┃ firstmate and worker rules belong in dotfiles. How your…
────────────────────────────────────────────────────────────────
20m ago   ┃ deploy failed  missed
          ┃ api 1.4.2
```

The lines are the ones the card wrapped to, measured as the card was recorded, so a long agent
message lists as the few lines you saw, not as all of it. Entries recorded by an earlier drip, or
whose recorded lines drip cannot read, are wrapped from their text the same way, by the width of an average character instead of measured.
Color is for a terminal and off when `NO_COLOR` is set and not empty; the layout is the same without it. `--json`
and `--replay` take every card in full, unless `-n` limits them. A `--json` line
writes each setting the way its flag takes it, and leaves out `detail`, `button`, `open`, `id` and
`activate` when the card had none:

```json
{"card":{"button":"View run","color":"red","detail":"api 1.4.2","icon":"xmark.circle.fill","id":"deploy","kind":"fail","motion":"full","open":"https://example.com/run/1","seconds":8,"size":"regular","sound":"Basso","title":"deploy failed"},"missed":true,"time":"2026-10-18T13:02:41Z"}
```

`--replay` shows the cards again, in order, with any button that opens something; a question's button is
dropped, since nothing waits for its answer anymore. Replayed cards are held while the screen is
locked or drip is paused like any other, and are not added to the history again.

## Pausing

`drip pause` holds every card for an hour, from every drip, as if the screen were locked: for a
meeting, a screen share or a call. Cards already on screen go too, within a second, and are held
with the others; a question stays, as its script waits on it. When the pause ends, the held cards
play back as missed cards do: the last five newest first, the older ones as one `N cards while you
were away` card, and `drip history --missed` lists them, all but those already shown before the
pause. A drip that waits for its card, with `--wait` or a `--yes` question, waits for the end of
the pause, and says so.

```sh
drip pause            # an hour; when drip is paused already, how long is left
drip pause 30m        # minutes or hours: 30m, 2h, 1h30m, up to 24h
drip resume           # end the pause now, and show what it held
```

`drip pause` alone does not change a running pause: it says how long is left. To extend or shorten
a running pause, pass a duration, such as `drip pause 1h`: it sets a new end from now, sooner or
later, in place of the old one. A pause always ends on its own; there is no pause without an end.
It is kept as its end time in `$XDG_STATE_HOME/drip/pause`, or `~/.local/state/drip/pause`, so it
holds across drips and restarts, and no drip keeps running for it but the one holding the cards.
While drip is paused, every drip run in a terminal prints a reminder to stderr, such as `drip is
paused, 23m left (drip resume to unpause)`. A drip whose stderr is not a terminal, such as one in a
script's log, and `drip hook`, print nothing about it, and `--quiet` keeps it quiet too.

## Buttons

`--open` adds a button that opens a URL or a file, such as a CI run, a pull request or a log.
`--button` names it. Hovering over the card holds it, for up to 5 seconds after the pointer last
moved; moving away gives it another 1.5 seconds. The
button stands where the countdown ring would be. A click on the button opens the target and takes the card
away; a click anywhere else on the card brings the sending app forward (see [Clicks](#clicks)) and
takes the card away. Clicking the button never takes focus from the app you are in.

`--yes` asks a question instead: the card has a button with that label and opens nothing, and drip
waits, then exits 0 if the button was clicked. `--no` adds a quieter button to its left that
answers no: drip exits 1 when it is clicked. drip exits as soon as a button is
clicked, while the card is still on its way out, so the command after it starts at once; a
background drip plays the card's exit, and any cards stacked with it, on from where they are.
With reduced motion, the card goes at once, with no exit, and drip exits with it. With either, drip exits 5 when
no button was clicked: the card timed out, a newer card with the same `--id` replaced it, or it was
clicked away from its buttons. A question waits for its answer for up to 10 minutes, whatever its
look; `--seconds` gives it a deadline instead. 0 and 1 read as yes and no, so the script decides what
happens:

```sh
drip warn "Deploy to prod?" -d "v1.4.0" --yes Deploy --no Cancel && ./deploy.sh
drip info "Merge drip #23?" -d "checks green, 1 approval" --yes Merge --seconds 10 && gh pr merge 23
```

The buttons stand where the ring would be, the yes button in the card's colour, darkened just
enough that white text on it reaches WCAG AA contrast (4.5:1), and the no button in white at 15 %. drip never takes focus, so the
keyboard answers nothing; VoiceOver offers each button as an action of the card, and reads a
question out before what it is reading. A card holds one link button or one question, never both:
`--yes` with `--open`, or `--button` without `--open`, exits 2. `drip run` and `drip hook` take no
`--yes` or `--no`, as nothing reads their answer.

**drip run** runs the command with drip's stdin, stdout and stderr, then shows `ok` with the title
`<command> finished` on exit 0, or `fail` with `<command> failed (exit N)` otherwise. The detail is
how long it took, such as `3m 12s`. drip's options come first, as for `time` or `nice`: the command
starts at the first argument that is not one of them, so `drip run -s 8 make test` runs `make test`.
`--` before the command also works, as in `drip run -- make test`.

## Recipes

Builds and tests, with how long they took:

```sh
drip run make test
drip run npm run build
```

A deploy that links to its run, and a backup:

```sh
drip run --open "https://github.com/me/app/actions" --button "View run" ./deploy.sh
drip run restic backup ~/Documents
```

A git hook, such as `.git/hooks/post-merge`, which drip never slows down:

```sh
#!/bin/sh
drip info "pulled $(git log -1 --format='%h %s')"
```

Coding agents have [a section of their own](agents.md).

## At the notch

Every card is drawn as one black shape with the notch, with a countdown ring draining over
`--seconds` (with motion `full`; buttons, or a card's waiting dot, take its place). A drop forms under the notch, stretches on a neck, breaks free
and widens into a capsule just below the menu bar. It leaves the same way, pulled back up into the
notch. A card whose text wraps grows into a taller capsule with rounded corners. On a screen without
a notch the drop forms above the screen and oozes out of the middle of its top edge instead, and
goes back into it the same way.

**Several cards at once.** Cards that come in while one is showing stack below it, up to 3 at
a time (`stack_max` in the [config](config.md), or `DRIP_STACK_MAX`, 1 to 6); the rest wait their
turn in a small drop under the last card, which counts them. A card that comes later drips into the
drop and the count goes up. A card that leaves gathers back into a round drop in place first, then
rises into the notch or the card above, as in the entrance reversed. As the drop starts to rise,
it all happens in one motion: the next card grows out of the drop into its place, the other cards
move up and the count goes down. Cards whose time runs out together leave one at a time, each once
the last one has gone and the others have settled into their places. Once none waits, the drop
goes back into the last card. With the pointer on the drop, it widens to list the waiting cards'
titles, newest first.
A click on the drop does nothing. How they stack is `stack` in the config, or `DRIP_STACK`. With `chain`, the default, each new
card drops out of the bottom of the last one and the oldest goes back into the notch first, the
others moving up behind it. With `push` a new card drops out of the notch once the others have
moved down out of its way, and the cards waiting wait in a small pill that drips out of the notch
and floats just under it instead, the stack moving down to make room. A card that comes later
drips from the notch into the pill. When a card leaves while cards wait, it sinks away as it fades, the other cards
move down, the next card grows out of the pill into the top place and the count goes down, again in
one motion; the last card waiting is the pill itself spreading into a card as the stack closes up
under the notch.
`off` shows one card at a time. While the pointer is on any card in the stack you can click, nothing moves: every countdown
stops, gaps stay open and new cards wait, though they still drip into the drop so its count stays
true. Once the pointer has rested for 5 seconds, the stack lets go, and moving it holds the stack
again. A click on a card you can click dismisses it; one `--activate none` leaves without a button
neither holds the stack nor is dismissed by a click. Clicks pass to the window below only while no
card in the stack takes clicks, as for a lone card. Only the cards of drips
that returned at once stack; a card that waits (`--wait`, or a question) waits its turn. While a
question shows, cards that count down stack around it; a card that waits, or another question,
waits for its answer. drip exits as soon as the question is answered, so the command after it
runs at once, and the cards still in the stack play out without it.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown; a question was answered yes, the moment it was clicked. |
| 1 | A question was answered no, the moment it was clicked; `drip hook` could not make a card, for any reason but no GUI session; `drip setup` left the agent's settings alone, or could not write them; `drip pause` or `drip resume` could not write the pause; `drip dismiss` could not write its request; or `drip follow` could not start, as when it cannot write its state directory. |
| 2 | Usage error. |
| 3 | No GUI session, for example over ssh; `drip hook` exits 0 then. |
| 4 | The config file is invalid; the message names the key and line. |
| 5 | drip asked with `--yes` and waited, but no button was clicked. |

Without `--wait`, 0 means the card was handed off to be shown. `drip run` exits with the wrapped
command's exit code (127 when it is not found) as soon as the command ends, once its card has
gone with `--wait`, or once a `--yes` question is answered or goes unanswered. When Ctrl-C ends the command, drip ends with the same
signal, so the script that ran it stops too. A usage error exits 2 before the command runs.

## Alert when a command finishes

Put `drip run` in front of any command: it runs it, times it, and shows a green card on exit 0, or
a red one with the exit code otherwise. drip then exits with the command's own status, so scripts
and `&&` chains work as before.

```sh
drip run make test
drip run --open "$CI_URL" --button "View run" ./deploy.sh
```

## Without typing `drip run`

`drip setup zsh` adds a block to `~/.zshrc` (`$ZDOTDIR/.zshrc` when that is set) that gives a card to
any command that ran 10 seconds or more, with nothing in front of it. The card is the one `drip run`
makes: green with `make test finished`, or red with `make test failed (exit 2)`, and the time as its
detail. It shows only when you are not watching that terminal, by the same rules as an agent's done
card: drip's [`when_focused` and `away_after`](config.md), and your tmux or herdr pane.

```sh
drip setup zsh          # adds the block; run it again to update it, and then: exec zsh
drip setup zsh --print  # prints the block without changing anything
```

The block costs a prompt nothing noticeable: zsh times the command itself and starts drip only for a
slow one, so a fast command runs no drip at all. It does nothing where drip is not installed.

| Setting | What it does | Default |
|---|---|---|
| `DRIP_SLOW_AFTER` | Seconds a command must run for a card. `0` turns the cards off. | `10` |
| `DRIP_SLOW_IGNORE` | More commands to leave out, space-separated, besides the editors (`vim`, `nvim`, `emacs`), pagers (`less`, `man`), `ssh`, `tmux`, `top` and REPLs (`python`, `node`) drip leaves out already. | none |
| `DRIP_HOOK=off` | No cards from this shell. | unset |
| `FM_TASK_ID` | Set by an orchestrator for the workers it starts: no cards from them. | unset |

Set them with `export` in `~/.zshrc`, or in a shell for as long as it lives. `sudo`, `env`, `time` and
variable assignments in front of a command are looked through, so `sudo vim` is left out as `vim`
is. A `DRIP_SLOW_AFTER` that is not a number leaves the cards off. fish is not supported yet.

The card's title is the command line as you typed it, and `drip history` keeps it, so any token on the
line, such as a `curl -H "Authorization: ..."` header, is in both. `drip run` does the same, but only
when you ask. Keep secrets out of command lines, or add the command to `DRIP_SLOW_IGNORE`.

[drip run](#buttons) has the details, and the site a guide: [Get an alert on Mac when a terminal
command finishes](https://drip.jrnxf.co/notify-when-command-finishes).

