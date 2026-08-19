<!-- vim: set expandtab filetype=markdown shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120: -->

# hammerspoon configuration

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/vladdoster/hammerspoon-configuration)
[![Release](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml)

My `~/.hammerspoon`. Eight hand-written Spoons, wired together in `init.lua` by a vendored copy of
[SpoonInstall](https://www.hammerspoon.org/Spoons/SpoonInstall.html).

Three of them lean on [yabai](https://github.com/koekeishiya/yabai) for anything that crosses a Mission Control Space,
because `hs.spaces.moveWindowToSpace()` has been a silent no-op since macOS 15. See [Requirements](#requirements).

## Features

| Spoon              | What it does                                                                      |
| ------------------ | --------------------------------------------------------------------------------- |
| `BatteryMonitor`   | Menubar battery readout, plus spoken and on-screen alerts on charge and time left |
| `ClipboardHistory` | Searchable clipboard history that survives a Hammerspoon restart                  |
| `DeleteSpace`      | Deletes a Mission Control Space, listed with its window count                     |
| `DeminimizeWindow` | Restores a minimized window, onto the Space you are on when yabai is installed    |
| `FocusBorder`      | Red border around the focused window, hidden while that window is fullscreen      |
| `PinnedWindows`    | Menubar item for pinning windows: kept on top, locked size and position           |
| `SummonWindow`     | Pulls a window from another Mission Control Space onto the current one            |
| `VolumeControl`    | Steps the default output device's volume, with an on-screen readout               |

Five put an item in the menubar as shipped. `DeminimizeWindow` has one but leaves it off by default; `FocusBorder` and
`VolumeControl` have none.

## Hotkeys

| Keys                | Action                             |
| ------------------- | ---------------------------------- |
| hyper + `R`         | Reload the config                  |
| hyper + `C`         | Show clipboard history             |
| hyper + `M`         | Restore a minimized window         |
| hyper + `S`         | Delete a Mission Control Space     |
| hyper + `Up`/`Down` | Raise / lower output volume        |
| `cmd+alt+shift`+`P` | Toggle pin on the focused window   |
| `cmd+alt+shift`+`S` | Summon a window from another Space |

Hyper is `cmd+alt+ctrl`. `PinnedWindows` and `SummonWindow` deliberately use `cmd+alt+shift` instead, to stay clear of
the hyper chords.

Every binding is assigned in `init.lua`, so change a key there. Note that each Spoon line spells its modifiers out as a
literal table: `ext/keybind.lua` exports an `M.hyper`, but only the hyper + `R` reload binding reads it, so editing that
constant will not move the rest.

The Spoons expose more actions than are bound here. `BatteryMonitor.toggleAudio`, `ClipboardHistory.togglePause` and
`clear`, `DeminimizeWindow.show`, `FocusBorder.toggle` and `PinnedWindows.unpinAll` all ship unbound; add them to the
relevant `hotkeys` table in `init.lua` to reach them.

## Requirements

[Hammerspoon](https://www.hammerspoon.org/), running. Developed against Hammerspoon 1.1.1 on macOS 26.6.1. The window
Spoons need the Accessibility permission Hammerspoon prompts for on first launch.

### yabai, for anything crossing a Space

`SummonWindow`, `DeminimizeWindow` and `DeleteSpace` shell out to [yabai](https://github.com/koekeishiya/yabai) when it
is present. It is optional and its absence is never reported as an error, but the three degrade differently:

| Spoon              | Without yabai                                                                      |
| ------------------ | ---------------------------------------------------------------------------------- |
| `SummonWindow`     | Falls back to a slower rung that borrows the mouse pointer                         |
| `DeminimizeWindow` | Cannot place the window on your current Space; it reappears where it was minimized |
| `DeleteSpace`      | Loses its managed-window counts and its non-Mission-Control delete                 |

yabai's window-moving needs its scripting addition, which needs System Integrity Protection partially disabled:

```shell
# Requires Filesystem Protections, Debugging Restrictions and NVRAM Protection to be disabled
# (printed warning can be safely ignored)
csrutil disable --without fs --without debug --without nvram
```

On Apple Silicon, `yabai --load-sa` also wants a boot argument. If you see
`yabai: missing required nvram boot-arg '-arm64e_preview_abi'`:

```shell
sudo nvram boot-args=-arm64e_preview_abi
```

Both are done from Recovery, and both weaken macOS security guarantees. Everything here works without them; you lose the
Space-crossing behaviour in the table above and nothing else.

### SF Pro, for the menubar icons

The menubar glyphs are SF Symbols, drawn as private-use codepoints. They come from
[SF Pro](https://developer.apple.com/fonts/), which is a separate Apple download rather than part of macOS. Without it:

- `ClipboardHistory` and `SummonWindow` show a missing-glyph box. Set `menubarTitle` (and, for `ClipboardHistory`,
  `menubarTitlePaused`) to any character you like instead.
- `PinnedWindows` shows one too, but its glyphs are file-local constants, so changing them means editing the Spoon.
- `BatteryMonitor` is unaffected until you charge: its icon is a drawn battery, and only the bolt laid inside it while
  charging is an SF Symbol.

## Install

Hammerspoon's first launch creates `~/.hammerspoon/init.lua`, so cloning straight into `~/.hammerspoon` fails on a
non-empty directory. Clone elsewhere and swap it in:

```shell
git clone https://github.com/vladdoster/hammerspoon-configuration /tmp/hammerspoon-configuration
mv ~/.hammerspoon ~/.hammerspoon.bak
mv /tmp/hammerspoon-configuration ~/.hammerspoon
```

Load it from the Hammerspoon menubar icon, via `Reload Config`. Hyper + `R` does not work yet, because `init.lua` is
what binds it; it works on every reload after this one. A "Config loaded" notification on each reload is the only
success signal, so allow notifications for Hammerspoon.

`hs -c "hs.reload()"` needs one more step. The `require("hs.ipc")` at the top of `init.lua` loads the module the CLI
talks to, but the `hs` binary itself is a symlink into the app bundle. Create it with `hs.ipc.cliInstall()` from the
Hammerspoon console, which writes to `/usr/local` unless you pass a path, or symlink it somewhere on your `PATH`
yourself.

## Layout

| Path       | Purpose                                                                  |
| ---------- | ------------------------------------------------------------------------ |
| `init.lua` | The entire wiring: global settings, then one `andUse` call per Spoon     |
| `Spoons/`  | Eight first-party Spoons as source, plus a vendored `SpoonInstall.spoon` |
| `ext/`     | One live module and four dormant ones, see below                         |
| `Makefile` | Formatting, docs generation and a destructive `clean`                    |

Each Spoon carries a generated `docs.json`, registered with `hs.doc` at load. Between them the eight document about a
hundred configurable variables, which is the real reference for anything below.

`Spoons/SpoonInstall.spoon` is third-party, vendored from upstream. Leave it and its `docs.json` as shipped.

Only `ext/keybind.lua` is loaded, and only for the hyper + `R` binding. `dockTime.lua` (a Dock-tile clock),
`infoDisplay.lua` (Space indicator dots) and `sysStats.lua` (a floating CPU/RAM/battery HUD) are kept but unwired, as is
`spoons.lua`, an alternative loader that pulls third-party Spoons through SpoonInstall. Requiring `dockTime`,
`infoDisplay` or `spoons` starts them immediately as a side effect of the `require`; only `sysStats` waits to be told.

## Customising

Spoon variables are set through the `config` table in `init.lua`, before `start()` runs:

```lua
spoon.SpoonInstall:andUse("FocusBorder", {
  config = { borderColor = { red = 0, green = 1, blue = 0, alpha = 0.9 }, borderWidth = 4 },
  start = true,
})
```

`andUse` also takes `disable = true` to switch a Spoon off without deleting its line, and `loglevel = "debug"` to raise
one Spoon's verbosity. Errors and log output land in the Hammerspoon console, which is the only error surface: there is
no test suite and nothing runs on push.

## Adding a Spoon

Three places encode the first-party Spoon list, and they must agree:

1. `KEEP_SPOONS` in the `Makefile`
1. The matching `!Spoons/<Name>.spoon` negation in `.gitignore`
1. A `spoon.SpoonInstall:andUse("<Name>", ...)` call in `init.lua`

Miss the first and `make clean` deletes your Spoon, since it removes every `Spoons/*.spoon` not named there. Miss the
second and git ignores it. Then run `make docs` to generate its `docs.json`.

## Gotchas

- **Reload is not free.** Nothing sets `hs.shutdownCallback`, so hyper + `R` never calls a Spoon's `stop()`. Every
  `PinnedWindows` pin is dropped, because pins live only in memory, and any app-native "always on top" toggle it
  switched on is left on. `ClipboardHistory` coalesces writes behind a five second `saveDelay` that `stop()` would have
  flushed, so a copy made just before a reload can be lost.
- **"Always on top" is emulated.** macOS gives no public API for one app to raise another's window, so `PinnedWindows`
  re-raises on every focus change. It cannot hold a window above a *different* application; its `diagnose()` says so
  outright. Real always-on-top only happens where the app exposes its own menu toggle, which the Spoon hunts for via
  `floatHints`.
- **`FocusBorder` has no off switch as shipped.** No menubar item, and its `toggle` action is unbound. Stop it with
  `hs -c 'spoon.FocusBorder:stop()'` or bind `toggle` in `init.lua`.
- **The two `ignoreAlways` lines in `init.lua` must stay above the `andUse` calls.** They are read while
  `hs.window.filter` registers running applications, which happens the first time a Spoon activates a filter.
- **Hotkeys are global and always on.** There is no modal or per-app gating, so each chord shadows the focused
  application's own shortcut for as long as Hammerspoon runs.
- **`init.lua` sets `hs.window.animationDuration = 0.1` globally**, which is half Hammerspoon's default and applies to
  every window move any Spoon makes.
- **`make format` rewrites this README.** It runs `mdformat --wrap 120` over it as well as stylua over the Lua.

## Makefile targets

Run from the repository root; the Makefile uses zsh and relative paths.

| TARGET     | DESCRIPTION                                                        |
| ---------- | ------------------------------------------------------------------ |
| clean      | Delete every `Spoons/*.spoon` not in `KEEP_SPOONS`. Destructive    |
| docs       | Regenerate first-party `docs.json`. Needs the `hs` CLI and python3 |
| format     | Run `format-lua` and `format-md`                                   |
| format-lua | Format all Lua in place via stylua                                 |
| format-md  | Format `README.md` via mdformat. Needs `uvx`                       |
| help       | Display all Makefile targets                                       |

`VERSION` and `CHANGELOG.md` are written by the release workflow, which is `workflow_dispatch` only. The release badge
above therefore reports the last manually dispatched release, not the health of `main`.

## License

[MIT](LICENSE).
