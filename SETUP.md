# Setting up Rojo Team Create

This gets a machine from nothing (or stock Rojo) to a working Rojo Team Create setup
for one project. It's written so a person or a coding agent can follow it top to bottom.

You're done when:

- `rojo --version`, in a new terminal inside the project, prints the version pinned in
  `rokit.toml` (it ends in `-team.N`).
- `rojo serve` starts, and a plain request to it is refused (step 6).
- Everyone on the team is on the same version (the one in `rokit.toml`). Update together.
- Studio shows a blue **Rojo Team** toolbar button, and no red Rojo button.

## If you're an agent

- Ask the user before deleting a binary, editing a shell profile (`~/.zshrc`,
  PowerShell `$PROFILE`, ...) or quitting Studio. Say exactly what you'll run.
- Never make things work by removing `teamSync` from a project file, and don't install
  the marketplace Rojo plugin.
- Your shell may not load the user's profile, so `~/.rokit/bin` might not be on your
  PATH even when it is on theirs. Call tools as `~/.rokit/bin/<tool>`, or prefix a single
  command with `PATH="$HOME/.rokit/bin:$PATH"`, rather than changing their setup.
- Some steps only apply once per project (step 1) or once per machine (step 2). Check
  before redoing them.

## 1. Turn on team sync (once per project)

Add `"teamSync": true` at the top level of each project file people serve, usually
`default.project.json`:

```json
{
  "name": "MyGame",
  "teamSync": true,
  "tree": {}
}
```

If it's already there, skip this step.

## 2. Install rokit (once per machine)

Check first:

```sh
~/.rokit/bin/rokit --version
```

On Windows: `$env:USERPROFILE\.rokit\bin\rokit.exe --version`.

If that fails, install it from https://github.com/rojo-rbx/rokit#installation. Or
download the zip for your platform from the
[latest release](https://github.com/rojo-rbx/rokit/releases/latest), unzip it, and run
`rokit self-install`. Treat a half-finished install (a `~/.rokit` folder but no working
`rokit`) as missing.

Using Aftman instead? The same `rojo = "..."` line works in `aftman.toml`. Adapt the
commands below.

## 3. Pin and install this build

In the project's `rokit.toml` (create it with `rokit init` if needed), replace any
existing `rojo` line with:

```toml
rojo = "michaelmitchell-bit/rojo-team-create@7.7.0-team.5"
```

Use the [latest release](https://github.com/michaelmitchell-bit/rojo-team-create/releases/latest)
if it's newer. Then:

```sh
rokit install
```

rokit asks you to approve tools it hasn't seen before. An agent can't answer that
prompt, so approve it up front and tell the user you did:

```sh
rokit trust michaelmitchell-bit/rojo-team-create
```

## 4. Make sure the right `rojo` runs

Open a **new** terminal in the project and run:

```sh
rojo --version
```

It should end in `-team.N`. If it doesn't, another `rojo` is earlier on your PATH:

```sh
which -a rojo     # Windows: where.exe rojo
```

Usual suspects: Homebrew (`/opt/homebrew/bin/rojo`, which Homebrew's shell setup puts
ahead of rokit), an old Aftman or Foreman install, or `~/.cargo/bin/rojo` from
`cargo install`. Either remove that binary (`brew uninstall rojo` if Homebrew installed
it) or put rokit first by adding this line at the **end** of `~/.zshrc` (or your shell's
equivalent):

```sh
export PATH="$HOME/.rokit/bin:$PATH"
```

Agents: ask which option the user wants, then check again in a new shell.

## 5. Install the Studio plugin

```sh
rojo plugin install
```

This installs the plugin bundled inside this exact `rojo`, so plugin and server always
match. It goes to `~/Documents/Roblox/Plugins` on macOS or `%LOCALAPPDATA%\Roblox\Plugins`
on Windows.

Studio only loads plugins at startup, so restart it. Agents: ask first, since the user
may have unsaved work. To quit it from a terminal:

- macOS: `osascript -e 'tell application "RobloxStudio" to quit'`
- Windows: `Stop-Process -Name RobloxStudioBeta`

If the red marketplace Rojo plugin is also installed, remove it in
**Plugins → Manage Plugins** so only one Rojo is running.

## 6. Check it works

Start the server where you can see it:

```sh
rojo serve
```

Any `rojo serve` still running from stock Rojo has to be stopped first. It won't
understand the project.

Then, from another terminal:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:34872/api/rojo
curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:34872/api/rojo?teamSync=1"
```

The first should print `403` (stock plugins are turned away), the second `200`. Use
whatever port `rojo serve` printed if it isn't 34872.

Finally, open the place in Studio, click the blue **Rojo Team** button, and connect.

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `Error parsing Rojo project` / `unknown field teamSync` | A stock `rojo` is running | Step 4 |
| Studio: "this Rojo plugin doesn't support team sync" | Stock or marketplace plugin | Step 5, then restart Studio |
| `tool has not been marked as trusted` | rokit's approval prompt | `rokit trust ...` in step 3 |
| Plugin still red after installing | Studio wasn't restarted, or the marketplace plugin is still there | Restart Studio, remove the marketplace plugin |
| "Holding back changes that would overwrite someone else's work" | Not a setup problem: someone else changed the same scripts | Pull their changes, or merge and press Sync anyway. See [docs/team-sync.md](docs/team-sync.md) |

## Updating

When a new version comes out, change the version in `rokit.toml`, then run
`rokit install` and `rojo plugin install` again and restart Studio.
