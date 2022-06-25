hs.window.animationDuration = 0.1
hs.ipc.cliInstall()

local K = require('ext.keybind')
require 'ext.battery'
require 'ext.spoons'
require 'ext.volume'
require 'ext.clipboard'
require 'ext.dockTime'.start()
require 'ext.infoDisplay'.start()

local function reload()
  hs.reload()
  hs.alert.show('hammerspoon re-loaded')
end

local keymaps = {}
keymaps['h'] = hs.hints.windowHints
keymaps['t'] = require('ext.sysStats').toggle
keymaps['y'] = hs.toggleConsole
keymaps['R'] = reload
K.bind(keymaps)
