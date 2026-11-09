# opencode

A card when opencode asks for a permission, and when a session is done.

For: opencode users. opencode has plugins instead of hooks, so this recipe is a plugin and installs nothing in drip.

## How it works

opencode loads plugins from `~/.config/opencode/plugins/`. The plugin calls `drip info --stay` for a
permission and `drip ok` for an idle session. Both use the id `opencode:<session>`, so the done card
replaces the waiting one.

## Install

Save this as `~/.config/opencode/plugins/drip.js`:

```js
export const Drip = async ({ $, directory }) => {
  const project = directory.split("/").pop()
  return {
    event: async ({ event }) => {
      const id = `opencode:${event.properties?.sessionID}`
      if (event.type === "permission.asked") {
        const detail = `opencode wants to use ${event.properties.permission}`
        await $`drip info ${`${project} needs you`} -d ${detail} --id ${id} --icon terminal.fill --stay`.quiet().nothrow()
      } else if (event.type === "session.idle") {
        await $`drip ok ${`${project} is done`} --id ${id} --icon terminal.fill`.quiet().nothrow()
      }
    },
  }
}
```

## Change it

Drop the `session.idle` branch for permission cards only.
