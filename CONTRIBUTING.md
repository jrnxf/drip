# Contributing to drip

Thanks for helping. This page says where to start and how to check your change.

## The easiest first PR is a recipe

A recipe is a short example of when drip shows a card, such as a card when an agent needs you.
Each recipe lives in its own folder: `recipes/<name>/README.md`. Read [recipes/README.md](recipes/README.md) first.

Follow the shape of the existing recipes:

- A title, and one line that says what the recipe does.
- A `For:` line that says who it suits.
- `How it works`, then `Install`, with the snippet in full and the file it goes in.
- `Change it`, with what to change next.

Add a row for your recipe to the table in [recipes/README.md](recipes/README.md).
A recipe without that row is not finished.

## Build and test

Run these from the repo root. The full list, with the Mac-only scripts, is in [docs/development.md](docs/development.md).

```sh
swift build
swift test            # on Linux, or on a Mac with Xcode
DRIP_FULL_SWEEP=1 swift test  # with every frame of the stack sweeps, as CI's test job runs them
```

## Never run drip against your real state

Never point `XDG_STATE_HOME` or `XDG_CONFIG_HOME` at your real `~/.local/state` or `~/.config`.
Use a scratch folder instead. The steps are in [Running drip by hand](docs/development.md#running-drip-by-hand).

## Bugs

Open an issue with the bug form. Include the output of `drip doctor --json`.
Check that output for your user name and folder paths first, and remove them.

## Security

Do not open a public issue for a vulnerability. Read [SECURITY.md](SECURITY.md) to report it in private.

## Commit style

Use conventional commits. The subject says what the user gets, not what the code changed.
Run `git log --oneline -15` to see the style. For example:

- `fix(drip): the drop's old number is gone before the new one shows`
- `docs(tour): shorten the last card's detail to two lines or fewer`
