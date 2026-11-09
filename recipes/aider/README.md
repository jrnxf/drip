# Aider

A card when Aider is done and waits for you.

For: Aider users. Aider has no hooks, so this recipe uses its notification command and installs nothing in drip.

## How it works

Aider runs `--notifications-command` when it waits. The command runs `drip ok` with an id per
project, so a new card replaces the last one.

## Install

```sh
aider --notifications --notifications-command 'drip ok "$(basename "$PWD") is done" --id "aider:$PWD" --icon terminal.fill'
```

Or, in `.aider.conf.yml`: `notifications: true`, and `notifications-command:` with the same command.

## Change it

Change the title, the icon or the card options. See `drip --help`.
