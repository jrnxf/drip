# Click: Ghostty across Spaces

A click on a card from another machine focuses the Ghostty terminal whose title holds the machine's
name, and Ghostty moves to its Space.

For: Ghostty users with agents on another machine, on a Mac with several Spaces. Needs [jq](https://jqlang.org).

## How it works

macOS keeps an app that is already active on its Space, so a plain click can leave you on the wrong
one. [drip-ghostty-focus](drip-ghostty-focus) reads `machine` from the card's JSON
([the payload](../../docs/contract.md)) and asks Ghostty, with AppleScript, to focus the terminal
whose name contains it. The machine's name goes to AppleScript as an argument, never as part of the
script. The first time it runs, macOS asks to let the app that runs `osascript` control Ghostty.

## Install

1. Put `drip-ghostty-focus` in your `PATH` and make it executable.
2. On the Mac: `drip follow devbox --on-click drip-ghostty-focus`

## Change it

Edit the script. Match on another part of the title, or on another app.
