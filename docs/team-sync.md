# Team sync

Team sync stops people who share a place from overwriting each other's synced
changes. This page covers how it decides, and where it's strict on purpose.

## Turning it on

Add `"teamSync": true` to the project file everyone serves, then have everyone
install this build and its plugin:

```sh
rojo plugin install
```

Restart Studio after installing, and remove any other Rojo plugin. This build's
plugin is blue, with a toolbar button called "Rojo Team", so it's easy to spot a
stock (red) Rojo plugin that's still around.

## The sync log

Every place that's been synced with team sync has a StringValue at
`ServerStorage.RojoTeamSync` holding a small JSON log. Each sync session adds one
entry: who synced, when, and which instances that session changed. The plugin
also remembers, per machine, the last entry you wrote. That's your "base".

It keeps the last 40 sessions. Older entries get dropped, and the log remembers
that it was trimmed.

## Deciding whether to sync

When you connect, Rojo computes the patch it needs to apply to bring the place in
line with your files. Team sync turns that patch into a list of instance paths and
compares it with every log entry written after your base:

| Situation | Result |
|---|---|
| Nobody else synced since you did | Sync |
| Others synced, but nothing overlaps with what you'd change | Sync |
| You already have their changes exactly | Sync (those instances aren't in your patch at all) |
| Your patch would change something someone else changed | Refused |

When it refuses, the Rojo panel lists the instances and who changed each one. Get
their changes into your files, then reconnect. If you merged their changes by hand
(so your version deliberately differs from theirs), press **Sync anyway**. The
override is written to the log like any other sync.

While you're connected, the plugin checks the log about once a second. As soon as
someone else's entry shows up after yours, it stops syncing for you. Reconnect to
re-check.

## What counts as overlapping

- The same instance, e.g. `ServerScriptService.Main` in both.
- Anything inside a subtree that was added, removed or renamed, in either
  direction. If you'd delete a folder and someone else edited a script inside it,
  that overlaps.
- A plain property change on a folder doesn't overlap with edits to things inside
  it.
- A session that changed more than 50 instances is logged as "changed everything",
  so it overlaps with anything until people reconcile.

## Where it's strict on purpose

- The stock Rojo plugin can't connect to a server that has `teamSync` on (it gets
  an HTTP 403 with an explanation).
- A project without `teamSync` can't sync into a place that has a sync log. There's
  no override for this one; serve the right project.
- If you've never synced a place from your machine, every entry in the log counts
  against you. If the log has also been trimmed, every change you'd make counts as a
  conflict, because there's history it can't see.
- A log that can't be parsed is treated as unknown history, same as above.

## Known gaps

- The log lives in the place, so anyone can edit or delete
  `ServerStorage.RojoTeamSync`. Deleting it resets team sync for that place.
- Paths use instance names, so siblings with the same name are treated as one
  instance. That only ever causes extra refusals.
- Edits made directly in Studio aren't logged. Rojo overwrites them the same way it
  always has.
- A stock Rojo server with a stock plugin knows nothing about any of this. Make sure
  everyone is on this build.

## Tests

The decision rules are plain Luau with no Roblox dependencies
(`plugin/src/TeamSync/Policy.lua`). Run their specs without Studio:

```sh
lune run scripts/test-team-sync-policy.luau
```
