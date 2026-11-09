# Install

Homebrew installs drip as a prebuilt universal binary, for Apple silicon and Intel Macs, in a few
seconds: nothing to compile, and no Xcode. drip is still in development: until 0.1.0 is out, brew
installs the latest development build, a pre-release such as 0.1.0-pre.1, and `brew upgrade`
moves to the next one, then to 0.1.0. Install it with Homebrew rather than downloading the
archive from the release page: the binary is signed with drip's own certificate, not one from
Apple, and not notarized, so Gatekeeper blocks a copy downloaded in a browser, while brew's
download runs as it is. Every release is signed with that same certificate, so what you allow
drip in System Settings, such as access to the local network, holds across `brew upgrade`;
releases up to 0.1.0-pre.21 were signed ad hoc, so moving from one of them asks once more. To
build the latest `main` from source instead, run `brew install --HEAD jrnxf/tap/drip`; that build
is signed ad hoc, so macOS asks again after each one.

Without Homebrew, build it from source with the Swift in the Command Line Tools and put the binary
on your `PATH`:

```sh
xcode-select --install   # only if swift is not found; drip needs Swift 6.0 or newer
git clone https://github.com/jrnxf/drip.git
cd drip
swift build -c release
sudo mkdir -p /usr/local/bin
sudo cp .build/release/drip /usr/local/bin/
drip ok "drip works"
```

## Uninstall

```sh
brew uninstall drip                       # or: sudo rm /usr/local/bin/drip, for a build from source
rm -rf ~/.config/drip ~/.local/state/drip # the config and the history
```

Then take drip's hooks out of the agents' settings, if you added them: the entries whose
command is `drip hook claude`, `drip hook codex` or `drip hook gemini` in `~/.claude/settings.json`,
`~/.codex/hooks.json` (or `config.toml`) and `~/.gemini/settings.json`. If you set `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, the files
are there instead. drip installs nothing else: no daemon, no login item, no preferences. If you
[follow another machine](remote.md), stop and delete the launchd agents you saved
for it, and on the machine delete `drip-remote-hook`, its queue and the hooks that run it. If you ran
`drip setup zsh`, delete the block in `~/.zshrc` that starts with `# >>> drip` and ends with
`# <<< drip <<<`, and the `.zshrc.drip-backup-<date>-<time>` next to it.
