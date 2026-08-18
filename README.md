<!-- vim: set expandtab filetype=markdown shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120: -->

# hammerspoon configuration

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/vladdoster/hammerspoon-configuration)
[![Release](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml)

My `~/.hammerspoon`. Eight self-contained Spoons, wired together in `init.lua`.

## Features

| Spoon              | What it does                                                                 |
| ------------------ | ---------------------------------------------------------------------------- |
| `BatteryMonitor`   | Menubar battery readout, plus spoken and on-screen alerts on charge levels   |
| `ClipboardHistory` | Searchable clipboard history that survives a Hammerspoon restart             |
| `DeleteSpace`      | Deletes a Mission Control Space, listed with its managed window count        |
| `DeminimizeWindow` | Restores a minimized window onto the Space you are on, not the one it left   |
| `FocusBorder`      | Red border around the focused window, hidden while that window is fullscreen |
| `PinnedWindows`    | Menubar item for pinning windows: always on top, locked size and position    |
| `SummonWindow`     | Pulls a window from another Mission Control Space onto the current one       |
| `VolumeControl`    | Steps the default output device's volume, with an on-screen readout          |

## Hotkeys

Hyper is `cmd+alt+ctrl`, defined in `ext/keybind.lua`. `PinnedWindows` and `SummonWindow` deliberately use
`cmd+alt+shift` instead.

| Keys                | Action                             |
| ------------------- | ---------------------------------- |
| hyper + `R`         | Reload the config                  |
| hyper + `C`         | Show clipboard history             |
| hyper + `M`         | Restore a minimized window         |
| hyper + `Up`/`Down` | Raise / lower output volume        |
| hyper + `S`         | Delete a Mission Control Space     |
| `cmd+alt+shift`+`P` | Toggle pin on the focused window   |
| `cmd+alt+shift`+`S` | Summon a window from another Space |

Every binding is assigned in `init.lua`. The Spoons only expose a `bindHotkeys(mapping)` spec, so change a key here and
nowhere else.

## Install

Requires [Hammerspoon](https://www.hammerspoon.org/). The window Spoons need the Accessibility permission that
Hammerspoon prompts for on first launch.

The menubar icons are SF Symbols, drawn as private-use codepoints from [SF Pro](https://developer.apple.com/fonts/),
which is an Apple download rather than part of macOS. Without that font installed, BatteryMonitor, ClipboardHistory,
PinnedWindows and SummonWindow show missing-glyph boxes in the menubar; set each Spoon's `menubarTitle` to a character
of your own if you would rather not install it.

That first launch also creates `~/.hammerspoon/init.lua`, so cloning straight into `~/.hammerspoon` fails on a non-empty
directory. Clone elsewhere and swap it in:

```shell
git clone https://github.com/vladdoster/hammerspoon-configuration /tmp/hammerspoon-configuration
mv ~/.hammerspoon ~/.hammerspoon.bak
mv /tmp/hammerspoon-configuration ~/.hammerspoon
```

Load it from the Hammerspoon menubar icon, via `Reload Config`. Hyper + `R` does not work yet, because `init.lua` is
what binds it; it works on every reload after this one.

`hs -c "hs.reload()"` needs one more step. The `require("hs.ipc")` at the top of `init.lua` loads the module the CLI
talks to, but the `hs` binary itself is a symlink into the app bundle that only `hs.ipc.cliInstall()` creates. Run that
once from the Hammerspoon console if you want the CLI.

## Makefile targets

| TARGET | DESCRIPTION                                                     |
| ------ | --------------------------------------------------------------- |
| clean  | Delete every `Spoons/*.spoon` not in `KEEP_SPOONS`. Destructive |
| docs   | Regenerate first-party `docs.json`. Needs Hammerspoon running   |
| format | Format all Lua in place via stylua                              |
| help   | Display all Makefile targets                                    |
