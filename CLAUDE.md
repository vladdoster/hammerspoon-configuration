<!-- vim: set expandtab filetype=markdown shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120: -->
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Hammerspoon configuration (`~/.hammerspoon`), published as `vladdoster/hammerspoon-configuration`. Everything is Lua running inside Hammerspoon: there is no build step and no test suite. The feedback loop is edit, reload the config (hyper+R or `hs -c "hs.reload()"`), then check the Hammerspoon console. "Hyper" is cmd+alt+ctrl, defined in `ext/keybind.lua`.

## Commands

- `make format` - format all Lua via stylua. The flags pinned in the `format` target are the only formatting authority; there is no stylua.toml or editorconfig. Read them there rather than trusting a copy.
- `make docs` - regenerate `docs.json` for first-party Spoons. Requires Hammerspoon running with the `hs` CLI available: `init.lua` loads `hs.ipc`, but the binary itself comes from a one-time `hs.ipc.cliInstall()`. Also needs python3, which sorts keys for stable diffs.
- `make clean` - destructive: deletes every `Spoons/*.spoon` directory not listed in `KEEP_SPOONS` (removes SpoonInstall downloads).
- `hs -c "<lua>"` - run Lua inside the live Hammerspoon instance.

Lint runs only as a job in the release workflow; there is no push/PR CI and nothing runs locally. Releases are manual `workflow_dispatch` runs of `.github/workflows/release.yml`, which calls reusable workflows from `vladdoster/.github`. `VERSION` and `CHANGELOG.md` are updated by that release flow (`ci:` commits); never bump them in feature commits.

## Architecture

`init.lua` is the entire wiring: it loads the vendored `SpoonInstall.spoon`, registers each first-party Spoon through `spoon.SpoonInstall:andUse(...)` with its hotkeys, and binds hyper+R to `hs.reload()`. Hotkey assignments live in `init.lua`, not inside Spoons; Spoons only expose `bindHotkeys(mapping)` specs.

### Spoons/ (the real code)

The first-party Spoons (BatteryMonitor, ClipboardHistory, DeminimizeWindow, FocusBorder, PinnedWindows, SummonWindow, VolumeControl, Yabai) plus `SpoonInstall.spoon`, which is vendored upstream: do not edit it by hand, and leave its `docs.json` as shipped. Each first-party Spoon follows the standard Spoon shape: an `obj` table with `name`/`version`/`author`/`license` metadata, `obj.logger`, documented config variables, and `start()`/`stop()`/`bindHotkeys()`.

- Spoons are deliberately self-contained. Duplication between them is intentional; do not extract shared modules.
- `make docs` skips SpoonInstall, but `make format` does not: `LUA_FILES` sweeps the whole tree, so the vendored source has already been reformatted and an upstream re-pull will conflict on it.
- LuaDoc `---` blocks are the source for the generated `docs.json`. After changing them or a Spoon's public API, run `make docs`; never hand-edit `docs.json`.
- Three places encode the first-party Spoon list and must stay in sync: `KEEP_SPOONS` in the Makefile, the `!Spoons/*.spoon` negations in `.gitignore`, and the `andUse` calls in `init.lua`. A Spoon missing from `KEEP_SPOONS` is a Spoon `make clean` deletes.

### yabai (optional)

`DeminimizeWindow`, `SummonWindow` and `Yabai` use `yabai` when it is installed and fall back to `hs.spaces` when it is not. Mind the split: yabai answers queries over its socket with no special privileges, but mutating Spaces goes through its scripting addition, a separate install. A machine can list Spaces through yabai and still fail to destroy one, so every mutation needs a fallback behind it, not just the absent-yabai case.

### ext/ (mostly dormant)

Only `ext/keybind.lua` is required from `init.lua` (hyper modifier plus a bind helper). `dockTime`, `infoDisplay`, `sysStats`, and `spoons` are kept but not loaded; `ext/spoons.lua` is an alternative loader that pulls third-party Spoons via SpoonInstall, and those downloads are what `.gitignore` and `make clean` account for.

## Conventions

### Git commits

- Conventional commits: `<type>(<scope>): <subject>`, 50-char imperative subject, atomic. Always commit with `--signoff`; never add a `Co-authored-by` trailer.

### Code comments

- Plain `--` comments: one line, no trailing period. LuaDoc `---` blocks are prose and exempt.
