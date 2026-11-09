# Many sessions, few cards

Cards from the one session you talk to, and none from the background sessions it starts.

For: people who run many agent sessions at once, such as a lead that starts workers. This recipe has no snippet. It is one environment variable.

## How it works

`drip hook` skips a session nobody attends, as `claude -p` and the Agent SDK mark with
`CLAUDE_CODE_SESSION_ATTENDED=0`. drip cannot tell an interactive session that a script drives, nor
a Codex or Gemini worker. `DRIP_HOOK` says it for them:

- `off`: no card. Set it in the environment of each worker.
- `attention`: only the cards that need you. Set it for the session you talk to, which ends many turns an hour.
- `on`: every card, even from a session nobody attends.

Any other value is an error that exits 1.

## Install

1. Pick a notify recipe, such as [permission-cards](../permission-cards/), for each agent.
2. Start the session you talk to with `DRIP_HOOK=attention claude`.
3. Start each worker with `DRIP_HOOK=off`, as in `DRIP_HOOK=off codex exec "fix the flaky test"`.

## Change it

Use `DRIP_HOOK=on` on a worker you want to hear from. See the [reference](../../docs/agents.md#drip_hook).
