# drip compared with notch apps, command notifiers and Notification Center tools

drip is a command-line tool. It shows its own card from the notch, for any command and for coding
agents. The tools below overlap with it in part. Each table groups tools of one kind. Every cell
comes from the tool's own README or site. "Not stated" means the source does not say.

Checked on Sunday 15 November 2026. These projects change, so check the source before you decide.

## Notification Center tools

| | drip | [terminal-notifier](https://github.com/julienXX/terminal-notifier) | [osascript](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/DisplayNotifications.html) | [alerter](https://github.com/vjeantet/alerter) |
| --- | --- | --- | --- | --- |
| Kind | CLI | CLI | built into macOS | CLI |
| Licence | MIT | MIT | part of macOS | MIT |
| Minimum macOS | 13 | 10.14 | not stated | 13.0 |
| Shows | its own card, from the notch | a Notification Center notification | a Notification Center notification, as an alert or banner by your settings | an alert that stays on screen until dismissed |
| Notifications permission | none for a card | asked once, on first use | not stated | not stated |
| Focus and Do Not Disturb | not followed; `drip pause` holds cards | Focus modes can suppress it | not stated | `--ignore-dnd` sends past Do Not Disturb |
| Answers | `--yes`, `--no`: exit 0, 1 or 5 | `-action`, `-reply`: waits for a response | not described | `--actions`, `--reply`: prints the result |
| Wraps a command | `drip run`: status, exit code and time | no | no | no |

## Notch apps for coding agents

| | drip | [Notchi](https://github.com/sk-ruban/notchi) | [Coucou](https://github.com/Louis-CFM/coucou) | [notch-so-good](https://github.com/deepshal99/notch-so-good) | [Vibe Island](https://vibeisland.app) |
| --- | --- | --- | --- | --- | --- |
| Kind | CLI | app | app | app | app |
| Licence and price | MIT | GPL-3.0, free and open source | code MIT, name and art all rights reserved; app price not stated | MIT; price not stated | closed; $19.99 for one Mac, one time, with a free trial |
| Minimum macOS | 13 | 15.0 | 15 | 14 | not stated |
| Needs a notch | no; the top edge of the screen instead | yes, "MacBook with notch" | no; a small bar without a notch | no; an island below the menu bar | no; a floating bar |
| Notifications permission | none for a card | not stated | not stated for the Mac app | not stated | not stated |
| Sets up agent hooks | no; recipes are snippets you paste | yes, on first launch | yes, with an Install hooks button that shows the diff | yes | "auto-configures" supported tools; how is not stated |
| Agents | Claude Code, Codex and Gemini CLI with recipes; other tools through `drip run` or their own hooks | Claude Code and Codex | Claude Code, Cursor, Codex, Gemini CLI and more | Claude Code and Codex; Gemini CLI is watch only (beta) | 30 listed, among them Claude Code, Codex, Gemini CLI and Cursor |
| Allow and Deny | optional, with the approve-from-card recipe: Claude Code and Codex, short one-line shell commands only | not stated | yes for Claude Code and Codex | yes, with "This session" and "Always allow" | yes for Claude Code |
| Any shell command | `drip run` | not stated | not stated | not stated | not stated |
| Documented exit codes | yes | not stated | not stated | not stated | not stated |
| Follows Focus | no | not stated | not stated for agent alerts | not stated | not stated |

## Command notifiers and hook helpers

| | drip | [noti](https://codeberg.org/roble/noti) | [ntfy](https://ntfy.sh) | [ccnotify](https://github.com/foxytanuki/ccnotify) |
| --- | --- | --- | --- | --- |
| Kind | CLI | CLI | service, apps and a server you can host | CLI that writes Claude Code Stop hooks |
| Licence and price | MIT | the archived GitHub copy lists MIT; its README states no licence | Apache 2.0 and GPLv2; free without sign-up, paid plans from $5 a month | MIT; price not stated |
| Platforms | macOS 13+ | macOS, Linux and Windows | Android, iOS, web, and a server | macOS, Linux and Windows |
| Delivers to | a card on this Mac | a macOS banner, or Slack, Telegram, ntfy and other services | phones and the web app, from a topic | Discord, ntfy or macOS notifications |
| Sets up agent hooks | no | not stated | no | yes, for Claude Code Stop hooks |
| Agents | Claude Code, Codex, Gemini CLI | not stated | not stated | Claude Code |
| Allow and Deny | optional, as above | not stated | not stated; action buttons are `view`, `broadcast`, `http` and `copy` | not stated |
| Any shell command | `drip run` | yes: put `noti` before or after a command | yes: send with `curl` or its CLI | not stated |
| Documented exit codes | yes | not stated | not stated | not stated |

noti moved to Codeberg, and its GitHub repository has been archived since 1 May 2026.

## Which to pick

- **drip** if you want to see at a glance how a build, deploy or agent turn went, to script what a
  card does, or to time any command with `drip run`.
- **A notch app for coding agents** (Notchi, Coucou, notch-so-good or Vibe Island) if you only
  want agent activity in the notch and want the app to set up the hooks for you. They are built
  for that, and drip asks you to paste a snippet.
- **Vibe Island, Coucou or notch-so-good** if you want Allow and Deny buttons in the notch without
  writing a recipe. drip offers them only for short one-line shell commands, from Claude Code and Codex.
- **ntfy** if you want a push on your phone, or an alert from a machine that is not your Mac.
- **terminal-notifier** if you want notifications that follow Focus and stay in Notification
  Center's list.
- **osascript** if you can install nothing, since it is already on every Mac.
- **alerter** if a script needs a typed reply or a choice from a dropdown in a system alert.
- **noti** if you want one command that can send to Slack, Telegram or other services. Check that
  it still suits you, as its GitHub copy is archived.
- **ccnotify** if you want a quick Claude Code Stop hook that posts to Discord or ntfy.

A script can call more than one of these tools.

[Back to the README](../README.md)
