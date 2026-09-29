# Team sync

Team sync lets several people stay connected to the same place and sync at the same
time, without anyone's sync overwriting someone else's changes. This page covers how
it decides what to hold back, and where it's strict on purpose.

## Turning it on

Add `"teamSync": true` to the project file everyone serves, then have everyone
install this build and its plugin:

```sh
rojo plugin install
```

Restart Studio after installing, and remove any other Rojo plugin. This build's
plugin is blue, with a toolbar button called "Rojo Team", so it's easy to spot a
stock (red) Rojo plugin that's still around. Everyone should be on the same version.

## What gets stored in the place

`ServerStorage.RojoTeamSync` is a Folder with one StringValue per machine that has
synced. Each one holds that machine's write log: the instance paths it synced, each
stamped with that machine's own counter. A plugin only ever writes its own value, so
two people syncing at the same moment can't erase each other's records.

A log keeps the most recent 500 paths. When older ones are dropped, the log
remembers the highest counter it dropped (its "floor").

Your plugin also remembers, in your local plugin settings, how far into each other
machine's log you've caught up.

## Deciding what to hold back

Every change Rojo wants to make in the place, whether from the catch-up sync when you
connect or from a file you just saved, goes through the same check. If it would touch
an instance another machine wrote that you haven't caught up to, it's held back. Your
copy is probably older than theirs. Anything that doesn't overlap is applied as usual.

You catch up on something someone else wrote when:

- your version turns out to be identical to what's in the place (you pulled their
  change, or it came in some other way), or
- you press **Sync anyway** and deliberately sync over it, or
- you connect and your catch-up sync doesn't touch it at all, which means your files
  already match.

When changes are held, the plugin shows which instances and who changed them, and the
toolbar button shows a warning until they clear. The warning is also written to the
output. Held changes clear on their own once your files match. If you merged by hand,
so your version deliberately differs, press **Sync anyway** in the notification, or run
the "Rojo: Sync held team changes anyway" plugin action.

If someone else already synced a script you're adding (you both pulled the same new
file), Rojo matches it up with the one in the place instead of creating a duplicate.

## What counts as overlapping

- The same instance, e.g. `ServerScriptService.Main` in both.
- Anything inside a subtree that was added, removed or renamed, in either direction.
  If you'd delete a folder and someone else edited a script inside it, that overlaps.
- A plain property change on a folder doesn't overlap with edits to things inside it.

## Where it's strict on purpose

- The stock Rojo plugin can't connect to a server that has `teamSync` on (it gets an
  HTTP 403 with an explanation).
- A project without `teamSync` can't sync into a place that has team sync logs. There's
  no override for this one; serve the right project.
- If another machine dropped writes you never caught up on, you can't know what they
  touched, so every change you make is held against that machine until you connect
  with nothing held.
- A log that can't be parsed is treated the same way.

## Known gaps

- Two people saving the same script within about a second of each other can both get
  through before either log reaches the other, and the last save wins.
- The logs live in the place, so anyone can edit or delete `ServerStorage.RojoTeamSync`.
  Deleting it resets team sync for that place.
- Paths use instance names, so siblings with the same name are treated as one instance.
  That only ever causes extra holds.
- Edits made directly in Studio aren't logged. Rojo overwrites them the same way it
  always has.
- A stock Rojo server with a stock plugin knows nothing about any of this.

## Tests

The decision rules are plain Luau with no Roblox dependencies
(`plugin/src/TeamSync/Policy.lua`). The second script runs two copies of the real
plugin code against one shared place, the way two people in Team Create would be. Both
run under [Lune](https://github.com/lune-org/lune), without Studio:

```sh
lune run scripts/test-team-sync-policy.luau
lune run scripts/test-team-sync-plugin.luau
```
