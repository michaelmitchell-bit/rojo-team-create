# Rojo Team Create

An unofficial fork of [Rojo](https://github.com/rojo-rbx/rojo) that lets more than one
person sync into the same place (Team Create, or a shared place file) without
overwriting each other.

With regular Rojo, the last person to sync wins. If two people are running
`rojo serve` against the same Team Create place, each sync quietly replaces whatever
the other person pushed, and you usually find out when a change you made ten minutes
ago is just gone. The common advice is "only one person syncs" or "don't use Rojo with
Team Create". This fork tries to fix the actual problem instead.

## How it works

When you connect, Rojo already works out what it needs to change in the place to match
your files. This fork compares that with what other people have synced into the place
since your last sync.

- **Nothing overlaps** (you already have their changes, or you're only touching scripts
  they didn't): it syncs like normal Rojo.
- **You'd overwrite someone else's changes**: it doesn't sync. The plugin lists the
  scripts and who changed them. Get their changes into your files however your team
  normally does it (git pull, copying files, whatever), then reconnect.
- **You both edited the same script and already merged it by hand**: press
  **Sync anyway**. That gets recorded too.

It doesn't depend on git or any other version control. The record of who synced what
lives in the place itself, in `ServerStorage.RojoTeamSync`.

A few other things:

- If someone syncs while you're connected, your session stops so you don't keep
  writing over them. Reconnect and it checks again.
- A project with team sync turned on won't talk to the stock Rojo plugin, and this
  plugin won't sync a project without team sync into a place that uses it. Mixing
  versions fails loudly instead of silently.
- The plugin is blue and its toolbar button says **Rojo Team**, so you can tell which
  Rojo you have open.

## Setup

Turn it on in your project file:

```json
{
  "name": "MyGame",
  "teamSync": true,
  "tree": {}
}
```

Everyone on the team needs this build. With [rokit](https://github.com/rojo-rbx/rokit),
pin it in `rokit.toml`:

```toml
[tools]
rojo = "michaelmitchell-bit/rojo-team-create@7.7.0-team.3"
```

then run:

```sh
rokit install
rojo plugin install
```

You can also grab a binary from [Releases](https://github.com/michaelmitchell-bit/rojo-team-create/releases).
`rojo plugin install` installs the plugin bundled with that exact binary, so the plugin
and server always match. Restart Studio and remove the marketplace Rojo plugin if you
have it, so only one Rojo is running.

## Limitations

- Everyone has to be on this build. Stock Rojo can't read `teamSync`, and the stock
  plugin won't connect to a server that has it on.
- The sync record is a value in ServerStorage. Anyone can delete it, which resets
  tracking for that place.
- It tracks instances by path, so two scripts with the same name in the same folder
  count as one. That can cause an extra refusal, never a missed one.
- Edits made directly in Studio (not through Rojo) aren't tracked, same as regular
  Rojo.
- It's currently based on Rojo 7.7.0.

The details, including exactly what counts as overlapping, are in
[docs/team-sync.md](docs/team-sync.md).

## Everything else

Everything besides team sync is regular Rojo, so the [Rojo docs](https://rojo.space/docs)
apply. Please report team sync bugs here rather than on the upstream Rojo repo.

## License

MPL-2.0, same as Rojo. See [LICENSE.txt](LICENSE.txt).
