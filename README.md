<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/drip-lockup-reversed.svg">
    <img src="docs/logo/drip-lockup.svg" width="300" alt="drip">
  </picture>
</p>

<h1 align="center">Notifications that work your way.</h1>

<p align="center">
  <img src="docs/demo.gif" width="400" alt="drip cards growing out of the camera notch in turn: Build finished, with make test: 246 passed in 3.2s, then Claude needs you, with Claude needs your permission to use Bash, replaced in place by Deploy failed, with staging: health check timed out after 30s, then the question Deploy to prod?, with Deploy and Cancel buttons, until it times out">
</p>


<p align="center">Small, scriptable cards that drip from your Mac’s notch. Connect them to your tools and control what deserves your attention.</p>


<p align="center"><a href="https://drip.jrnxf.co">Interactive demo</a> · <a href="docs/usage.md">Documentation</a></p>


## Install

```sh
brew install jrnxf/tap/drip
drip ok "hello"
```

Requires macOS 13 or newer. Tested on macOS 15 and 26.
Homebrew installs a prebuilt binary for Apple silicon and Intel, with no Xcode needed.
See [installation](docs/install.md) for source builds and uninstall instructions.

No Notifications permission: drip draws its own card, not a Notification Center banner.
On a Mac without a notch, the card grows out of the top edge of the screen.

## Compose it

Pipe text into a card, give it an action, or use an answer to decide what happens next.

```sh
# The first line becomes the title, the rest becomes the detail
git log -1 --format='%s%n%an' | drip ok

# Open a report from the card
drip ok "Report ready" --open ./report.html --button "View report"

# Continue only when you click Deploy
drip warn "Deploy to prod?" --yes Deploy --no Cancel && ./deploy.sh
```

Put `drip run` before a command to show its result and duration:

```sh
drip run make test
```

It preserves the command's exit status, so scripts and `&&` chains work as before.
See [usage](docs/usage.md) for more examples and [the contract](docs/contract.md) for exit codes and scripting guarantees.

## Make it yours

Choose the size, stacking behavior, and reusable presets in `~/.config/drip/config.toml`. Every key is optional.

```toml
size  = "regular"         # compact | regular | large
stack = "chain"           # chain | off

[preset.deploy]
icon  = "paperplane.fill"
color = "#a78bfa"
sound = "Submarine"
```

Use your preset like any other command:

```sh
drip deploy "shipped"
```

[Configuration](docs/config.md) lists every setting and its `DRIP_*` environment variable.

Clicks can activate an app or run your own command. Cards wait while the screen is locked,
and `drip history --missed` shows missed cards. Use `drip pause 30m` for a meeting or screen share.
Drip does not follow Focus or Do Not Disturb automatically.
See [click actions](docs/usage.md#clicks), [history](docs/usage.md#missed-cards-and-history), and [pausing](docs/usage.md#pausing).

## Recipes

Recipes are snippets you can copy and adapt. Start with
[slow shell commands](recipes/zsh-slow-commands/README.md),
[coding-agent permission cards](recipes/permission-cards/README.md), or a custom click action.
The [recipe catalog](recipes/README.md) has more starting points.

To show cards from a Linux machine on your Mac, see [remote notifications](docs/remote.md).

## Documentation

- [Usage](docs/usage.md) and [scripting contract](docs/contract.md)
- [Configuration](docs/config.md) and [recipes](recipes/README.md)
- [Troubleshooting](docs/troubleshooting.md): permissions, privacy, and missing cards
- [Comparison with other notification tools](docs/comparison.md)
- [Development](docs/development.md) and the [interactive card tour](scripts/tour.sh)

Drip collects no analytics. Its only network connection is the SSH connection used by `drip follow`.
See [privacy](docs/troubleshooting.md#privacy).

## License

MIT
