# hammerspoon configuration

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/vladdoster/hammerspoon-configuration)
[![Release](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml/badge.svg?branch=master)](https://github.com/vladdoster/hammerspoon-configuration/actions/workflows/release.yml)

## Features

- Battery watcher
- Spaces navigation
- Clipboard history

## Install

### Clone repository

```shell
git clone https://github.com/vladdoster/hammerspoon-configuration
```

## Makefile targets

| TARGET               | DESCRIPTION |
| -------------------- | ------------------------------------------- |
| clean                | Remove artifacts                            |
| format               | Format Lua files in-place via lua-formatter |
| help                 | Display all Makfile targets                 |
| install-luaformatter | Install luaformatter via luarocks           | 
| install              | Install dependencies (i.e., asm modules)    |
