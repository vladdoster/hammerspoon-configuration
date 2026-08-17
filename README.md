# hammerspoon configuration

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/vladdoster/hammerspoon-configuration)
[![Release](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml)

My `~/.hammerspoon`. Seven self-contained Spoons, wired together in `init.lua`.

## Features

| Spoon              | What it does                                                                |
| ------------------ | --------------------------------------------------------------------------- |
| `BatteryMonitor`   | Menubar battery readout, plus spoken and dialog alerts on charge thresholds  |
| `ClipboardHistory` | Searchable clipboard history that survives a Hammerspoon restart             |
| `DeminimizeWindow` | Restores a minimized window onto the Space you are on, not the one it left   |
| `FocusBorder`      | Red border around the focused window, hidden while that window is fullscreen |
| `PinnedWindows`    | Menubar item for pinning windows: always on top, locked size and position    |
| `SummonWindow`     | Pulls a window from another Mission Control Space onto the current one       |
| `VolumeControl`    | Steps the default output device's volume, with an on-screen readout          |

## Hotkeys

Hyper is `cmd+alt+ctrl`, defined in `ext/keybind.lua`. Note that the window Spoons
below deliberately use `cmd+alt+shift` instead.

| Keys                | Action                              |
| ------------------- | ----------------------------------- |
| hyper + `R`         | Reload the config                   |
| hyper + `C`         | Show clipboard history              |
| hyper + `M`         | Restore a minimized window          |
| hyper + `Up`/`Down` | Raise / lower output volume         |
| `cmd+alt+shift`+`P` | Toggle pin on the focused window    |
| `cmd+alt+shift`+`S` | Summon a window from another Space   |

Every binding is assigned in `init.lua`. The Spoons only expose a `bindHotkeys(mapping)`
spec, so change a key here and nowhere else.

## Install

Requires [Hammerspoon](https://www.hammerspoon.org/). The window Spoons need the
Accessibility permission that Hammerspoon prompts for on first launch.

Clone into the path Hammerspoon actually reads:

```shell
git clone https://github.com/vladdoster/hammerspoon-configuration ~/.hammerspoon
```

Then reload the config with hyper + `R`, or `hs -c "hs.reload()"`.

## Makefile targets

| TARGET | DESCRIPTION                                                    |
| ------ | -------------------------------------------------------------- |
| clean  | Delete every `Spoons/*.spoon` not in `KEEP_SPOONS`. Destructive |
| docs   | Regenerate first-party `docs.json`. Needs Hammerspoon running   |
| format | Format all Lua in place via stylua                              |
| help   | Display all Makefile targets                                    |
