local M = {}
local K = require 'ext.keybind'

hs.window.animationDuration = 0.1
hs.ipc.cliInstall()

require 'ext.battery'
require 'ext.spoons'
require 'ext.volume'
require('ext.dockTime').start()
require('ext.infoDisplay').start()

local function reload()
  hs.reload()
  hs.alert.show('hammerspoon re-loaded')
end

local keybinds = {}
keybinds['h'] = hs.hints.windowHints
keybinds['t'] = require('ext.sysStats').toggle
keybinds['y'] = hs.toggleConsole
keybinds['R'] = reload
K.bind(keybinds)
