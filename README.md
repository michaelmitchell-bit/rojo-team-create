<p align="center">
  <img src="assets/brand_images/team/logo-512.png" alt="Rojo Team Create" height="160">
</p>

# Rojo Team Create

An unofficial fork of [Rojo](https://github.com/rojo-rbx/rojo) that lets a whole team
live-sync into the same place at the same time without overwriting each other.

With regular Rojo, only one person can be connected in Team Create, and whoever syncs
last wins. With this fork everyone stays connected, and Rojo won't sync your copy of a
script over a newer version someone else synced.

## How it works

- Everyone can be connected at once. Edits to different scripts sync live, like normal.
- If a change of yours would overwrite a script someone else changed, that change is
  held back and Rojo tells you which script and who changed it. Everything else keeps
  syncing.
- Pull their change (git, or however you share code) and the held change clears on its
  own. Already merged by hand? Press **Sync anyway**.

It works with any version control, or none. The history lives in the place, in
`ServerStorage.RojoTeamSync`. More detail in [docs/team-sync.md](docs/team-sync.md).

## Setup

1. Add `"teamSync": true` to your project file.
2. Pin this build in `rokit.toml`, replacing any existing `rojo` line:
   ```toml
   rojo = "michaelmitchell-bit/rojo-team-create@7.7.0-team.5"
   ```
3. Install it and its Studio plugin:
   ```sh
   rokit install
   rojo plugin install
   ```
4. Restart Studio and remove the marketplace Rojo plugin if you have it. You should see
   a blue **Rojo Team** button.

No rokit? Grab a binary from [Releases](https://github.com/michaelmitchell-bit/rojo-team-create/releases)
and run `rojo plugin install` with it. If `rojo --version` doesn't end in `-team.5`
afterwards, see [SETUP.md](SETUP.md).

### AI setup

From your project folder, paste this into Claude Code, Codex, Cursor or whatever agent
you use:

```
Set up Rojo Team Create for this project by following
https://github.com/michaelmitchell-bit/rojo-team-create/blob/main/SETUP.md
```

[SETUP.md](SETUP.md) walks the agent through checking what's installed, fixing clashes
with an old Rojo on your PATH, and installing the plugin. It asks you before anything
like quitting Studio.

## Everything else

Besides team sync, this is regular Rojo, so the [Rojo docs](https://rojo.space/docs)
apply. Report team sync bugs here rather than upstream.

MPL-2.0. See [LICENSE.txt](LICENSE.txt).
