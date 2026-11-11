# Development

```sh
swift build
swift test            # on Linux, or on a Mac with Xcode
scripts/mac-check.sh  # on a Mac nobody works at, such as a VM, with DRIP_LIVE_CHECKS=isolated
scripts/mac-e2e.sh    # the same, without a person; CI's live job runs it on every push
scripts/record-demo.sh  # films docs/demo.mp4 and docs/demo.gif on a Mac; needs ffmpeg
scripts/sim-overflow.sh  # replays the overflow drop at the notch on a Mac, to film or to watch
scripts/agent-contract.sh  # the agents' hooks, live, with the latest of each; needs node and tmux
```

`swift test` runs the DripCore unit tests anywhere Swift runs, including Linux CI. The snapshot
tests render cards with the hidden `drip __render --out card.png` command and compare them with the
PNGs in `Tests/Snapshots`; they run on macOS and skip cards that have no reference yet.
`__render --at 0.2` draws a card's entrance 0.2 seconds in, to check a motion frame by frame.
`__render` also takes `--size` and `--motion`, which the other commands take only from the config
or the environment.

On a Mac, `scripts/mac-check.sh` builds, runs every test, records any missing snapshot references
into `Tests/Snapshots`, shows each preset and a custom `deploy` preset on screen once, a card
with Terminal's icon that stays until the next card needs the notch, a few cards that stack
under one another, a Claude hook card that a newer card from the same session replaces in place, a
Claude permission card that its tool's run takes away, a card that stays for `drip dismiss` to take
away, then lists the last cards in the history. It works with only the Command Line Tools installed; Xcode is not needed. It
never overwrites a reference: to regenerate one on purpose, delete its PNG and run the script again.

`scripts/mac-check.sh` and `scripts/mac-e2e.sh` show real cards from a drip with its own queue and
state, which on a Mac in use come up beside the person's own cards, miss their history and ignore
their `drip pause`. So both refuse to run, and exit 2, unless `DRIP_LIVE_CHECKS=isolated` says the
Mac is one nobody works at: a CI runner, or a macOS VM of your own. `swift test` needs no screen and
runs anywhere.

`scripts/mac-e2e.sh` is the deep suite: the `live` job in `.github/workflows/ci.yml` runs it on
GitHub's macOS runner on every push, with Accessibility granted to its helper up front, and keeps
the screenshots as the `mac-e2e-screenshots` artifact. It checks what a person
would look for at the notch, and needs none: it shows cards
from a release build, runs the hooks the `everything` recipe shows for Claude Code and Codex with the
payloads Claude Code and Codex send, moves the pointer onto cards, clicks them and beside them, pauses and resumes,
and attaches tmux from Ghostty and Terminal. It prints `ok` or `FAIL` for each thing it expects, from
what drip records in its history, which windows it has on screen, which app is in front, what tmux
says, and pixels at the notch, and exits 1 on a failure. `--only 1,4` runs some checks. It runs drip
in a world of its own, with its own state, config, card queue (`DRIP_QUEUE_DIR`), Claude Code
settings and Codex home, all deleted afterwards, so it touches none in use, and it waits for any
other drip's card to go before each check. Keep your hands off the mouse while it runs. Clicks and
VoiceOver's actions go through a small helper app it builds in `~/.cache/drip-e2e`, which needs
Accessibility once: allow `drip e2e helper` when asked, or under System Settings > Privacy & Security
> Accessibility. Without it, those checks skip. It also keeps a screenshot of each card it shows,
with what it should look like, and a contact sheet of them all, for a person or a model to judge:
`judge.md` in the screenshots' folder says how, and `--judge-check` reads the verdicts.

`scripts/record-demo.sh` makes the animation at the top of the README by filming real cards: it plays
a fixed sequence at the notch of the screen under the pointer, records that strip with `screencapture`
at the screen's native pixels, and encodes `docs/demo.mp4` and `docs/demo.gif` with ffmpeg. Set a clean
wallpaper first, and allow your terminal under System Settings > Privacy & Security > Screen & System
Audio Recording the first time. Run it again for a new take.

`scripts/sim-overflow.sh` replays the overflow drop on a Mac: it sends more cards than the stack
shows, a gap apart, so a drop forms under the last card, counts the cards waiting and goes back in
once none waits. Start it with no drip card on screen. `--max`, `--count`, `--gap` and `--timeout`
set the stack and the cards, `--id` ends with a card that swaps into the first in place, and `--push`
stacks with push instead of chain; `--help` lists them. Nothing runs it for you: it is for filming
the drop or for looking at its motion after a change.

## The live agent check

The tests replay payloads recorded once, so they cannot see Claude Code, Codex or Gemini CLI change
what their hooks send. `scripts/agent-contract.sh` can: it installs the latest release of each with
npm, builds drip from the checkout, and runs one short interactive session of each agent in a
terminal of its own (tmux), through the hooks the `everything` recipe shows. Each session asks for a shell
command the agent must ask permission to run, approves it through the terminal, then sends a second
prompt while a card waits, and checks what a person would see: the waiting card appears, it goes
once approved, a prompt takes a waiting card away, each turn ends with a done card, and a session
never has two cards. It runs on a locked Mac too, and shows nothing at the notch: drip is paused in
its world, so the cards go to its history. A session that goes wrong is tried once more, unless what
the agent sent is a shape drip cannot read or the account's quota ran out. `--only codex` runs some agents, and `--keep` keeps each
agent's scratch world.

The one-time setup takes about 5 minutes: run `scripts/agent-contract.sh --setup` in a terminal. It
opens the browser once, to approve a long-lived Claude Code token from `claude setup-token`, which
goes straight into the Keychain (service `drip-agent-contract`, account `claude`) without being
shown. Gemini CLI needs an API key, because Google no longer serves it to free-tier Google accounts:
create one at <https://aistudio.google.com/apikey> and turn billing on for it, so Google does not use
the check's prompts to improve its products (a weekly check costs a few cents). Setup asks for it
with the terminal's echo off and saves it in the Keychain (same service, account `gemini`), or you
save it yourself with `security add-generic-password -s drip-agent-contract -a gemini -U -w`. Codex
uses your own login: run `codex login` first if you have none. Setup checks each login with a tiny
session, prints what is ready, then runs the check once. After that a check never prompts and never
opens a browser: an agent whose login is missing or no longer works is skipped with the one line
that fixes it. So is one whose API quota runs out mid-session, as when Gemini CLI stops at its
usage limit dialog, unless a check had already failed by then.

This repo ships the check only: no schedule and no alert. Running it, weekly say, and telling you
when it fails or needs a login are up to your own scheduler, which runs `scripts/agent-contract.sh`
and reads its exit status and `~/.cache/drip-agent-contract/last.json`, both described below.

drip shows and records no card without a GUI session, so a scheduler must run the check as a
LaunchAgent in the logged-in user's session, not as a LaunchDaemon or over ssh. Started anywhere
else, it runs no agent, writes `last.json` with the status `no-gui-session` and the reason, and
exits 3.

One check runs at a time: the lock comes before the agents are installed or drip is built, so a check
started while another runs changes nothing under it, exits 4 and leaves that check's `last.json`
alone.

It exits 0 when every agent passed, 1 when any failed or the check itself could not run (the status
`error`, with the reason), 2 when the only trouble is a login, 3 when there is no GUI session, and 4
when another check is running. `~/.cache/drip-agent-contract/last.json` is what a scheduler reads: it
says `running` while a check runs and then its result: `status` and `reason`, and for each agent its
`status`, `version`, `reason`, `fix`, `checks`, `drift` and `payloads`.
Each run also keeps its own `last.json`, `summary.txt`, the payloads of each try at each agent
(`payloads/codex-1`, and `payloads/codex-2` for a second try), and the screen of any check that
failed, in `~/.cache/drip-agent-contract/runs/<time>/`. The drift report holds every payload up against
`scripts/agent-contract/contract.json`, which names the fields drip reads from each event: a field
drip reads that is missing or of another type, an event the session should have sent, or a permission
request that does not match the tool call after it is drift, and a field never seen before is only
noted. `--drift DIR` prints the report for the payloads a run kept, each agent's last try. The kept payloads name your home
`/home/user`, so a fix can add them to the tests as they are; update `contract.json` with it.

Everything it uses lives in `~/.cache/drip-agent-contract`: the agents, drip's state, each agent's
home and settings. Your own agents, their settings and your PATH stay as
they are. The Codex session links your `~/.codex/auth.json` rather than copying it, and trusts drip's
hooks for that session alone (`--dangerously-bypass-hook-trust`), where you would trust them once in
`/hooks`. A refresh of that login in the check goes to your own file, through the link; if your own
Codex refreshes it at the same moment, Codex may ask you to run `codex login` again. Any program you
run can read the Claude Code token and the Gemini API key in the Keychain without asking, as an unattended check must.

## Running drip by hand

drip reads three places, and a scratch run must move all of them:

- `XDG_CONFIG_HOME` (else `~/.config`): `drip/config.toml`.
- `XDG_STATE_HOME` (else `~/.local/state`): `drip/history.jsonl`, `drip/debug.log`, the held cards and the pause.
- `DRIP_QUEUE_DIR` (an absolute path; else the user temp folder): the card queue that drips share.
  Only this variable moves the queue. `TMPDIR` does not.

Each `XDG_*` value must be an absolute path, or drip falls back to `HOME`. drip also writes under
`HOME`: `drip follow` writes `~/Library/LaunchAgents` and `~/Library/Logs`. Unset every inherited
`DRIP_*` variable, and `CLAUDE_CODE_SESSION_ATTENDED` and `CLAUDE_CODE_ENTRYPOINT` too, as the
example does, or they change what drip reads. The example unsets `TMUX` and `TMUX_PANE` too, so a
run inside tmux does not read the real pane. (`COLUMNS` and `NO_COLOR` only shape the output.)
A scratch run still reads the real Mac's live state, the GUI session and Focus, so those parts of
the `doctor` output describe the real Mac.

Run it from the repo root, after `swift build`:

```sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
env $(env | sed -n 's/^\(DRIP_[A-Za-z0-9_]*\)=.*/-u \1/p') \
  -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_ENTRYPOINT -u TMUX -u TMUX_PANE \
  XDG_CONFIG_HOME="$scratch/config" XDG_STATE_HOME="$scratch/state" DRIP_QUEUE_DIR="$scratch/queue" \
  .build/debug/drip doctor
```

Never point `XDG_STATE_HOME` or `XDG_CONFIG_HOME` at the real `~/.local/state` or `~/.config`. On a
Mac in use, run by hand only commands that show no card, such as `doctor`, `history` (not
`history --replay`, which shows the cards again) and `__render`: a drip with its own queue shows its
cards on top of the person's own and ignores their `drip pause`. Do not run `drip follow` by hand: it
installs a real LaunchAgent. Apart from `scripts/tour.sh`, which you run on purpose to watch cards,
commands that show cards belong on a Mac nobody works at, as `scripts/mac-check.sh` and
`scripts/mac-e2e.sh` run them with `DRIP_LIVE_CHECKS=isolated`.

## Releases

A pushed tag makes a release: `.github/workflows/release.yml` builds the universal archive,
publishes the tag's GitHub release with it, and points the formula in jrnxf/homebrew-tap at it.
It releases only a commit that is on main and that CI's `test` and `snapshots` jobs have passed;
tag after CI goes green, or run the failed job again once it has.

```sh
git tag v0.1.0-pre.1 && git push origin v0.1.0-pre.1   # a development build
```

While `Sources/DripCore/Version.swift` says `0.1.0-pre`, the tags are `v0.1.0-pre.1`,
`v0.1.0-pre.2` and so on: each is a pre-release, the build stamps its number into
`drip --version`, and none needs a commit. Homebrew reads `-pre.N` as a pre-release and orders it
before 0.1.0; it would read `-dev.N` as plain 0.1.0. For 0.1.0 itself, set `Version.swift` to
`0.1.0`, merge, and tag `v0.1.0`; then set it to the next version with `-pre`. The formula follows
pre-releases only until the first full release, so a pre-release never replaces a stable drip.

## The web page

[drip.jrnxf.co](https://drip.jrnxf.co) runs DripCore itself, compiled to WebAssembly, and paints
what it computes: the command line, the cards, their springs and outlines, and the stack. It lives
in `web`:

```sh
web/build.sh  # the page, its styles and the engine into web/dist
web/test.sh   # the DripCore tests, compiled to WebAssembly, under wasmtime
```

Both need Swift 6.4.1 with its matching Wasm SDK; `web/tools.sh` pins them and, on x86_64 Linux,
downloads what is missing. The downloads are shared by every checkout, checked against their pinned
checksums: they live once in `~/.cache/drip/web-tools` (under `$XDG_CACHE_HOME` when it is set, or
in `$DRIP_WEB_TOOLS`), while each checkout's builds stay in its own `.build`. The page's styles are
Tailwind CSS v4, in `web/styles/site.css`, on top of `web/styles/base.css`, which every page shares:
`web/build.sh` compiles them with Tailwind's standalone CLI, pinned the same way, and inlines them
into the page. Under WASI, DripCore builds against FoundationEssentials, and
`Sources/DripCore/WASICompat.swift` fills in the little it lacks. CI runs `web/test.sh`, and
Cloudflare's Workers Builds runs `web/build.sh` and deploys the `drip-web` Worker on every push to
main that touches `web`, `Sources/DripCore` or the package.

Next to the page, `web/public` holds three guides: one question each, answered in the first
paragraph, and listed in `sitemap.xml` and `llms.txt`. Their styles are `web/styles/guide.css`,
inlined by `web/build.sh` as the page's are. A guide at `web/public/vs.html` is served at `/vs`.
