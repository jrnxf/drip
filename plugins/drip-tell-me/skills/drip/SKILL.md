---
name: drip
description: Show the user a card from the MacBook notch with drip. Use when the user asks to be told, pinged or asked something "with drip", or "on the notch", such as "tell me with drip when the tests are done".
---

# drip

drip shows a card from the MacBook notch. Use it only when the user asks for it. First check that
it is installed: `command -v drip`. If it is not, say so, and do not install it.

## Commands

A card that tells. The first word is the look: `ok`, `warn`, `fail` or `info`.

```sh
drip ok "tests passed" -d "142 tests, 3m 12s"
drip fail "build failed" -d "exit 2"
```

A command that shows a card when it ends: `ok` on exit 0, `fail` otherwise, with how long it took.

```sh
drip run make test
```

A question. drip waits for a click. Give it `--seconds` (up to 60), so it ends before your tool
call times out.

```sh
drip warn "Deploy to prod?" --yes Deploy --no Cancel --seconds 60
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The card was shown. A question was answered yes |
| 1 | A question was answered no, or drip could not do its work |
| 2 | Usage error |
| 3 | No GUI session, for example over ssh: no card shows |
| 5 | A question went without a click on its buttons |

`drip run` exits with the command's own exit code instead, 127 when it is not found.

Treat 5 as no answer, not as yes. Quote every title and detail. Keep secrets out of them.
