local M = {}
local K = require 'ext.keybind'
hs.window.animationDuration = 0.1
-- Ensure the IPC command line client is available
hs.ipc.cliInstall()
require 'ext.spoons'
require 'ext.battery'
require 'ext.navigation'
require 'ext.volume'
require 'ext.border'
require('ext.dockTime').start()
require('ext.infoDisplay').start()
require('ext.isOnline'):start()
M.windows = require 'ext.windows'
M.windows.applicationToggle {e='kitty', z='Music', q='Vivaldi'}
local keybinds = {}
keybinds['h'] = hs.hints.windowHints
keybinds['t'] = require('ext.sysStats').toggle
keybinds['y'] = hs.toggleConsole
K.bind(keybinds)
local function reload()
  hs.reload()
  hs.alert.show('hammerspoon re-loaded')
end
hs.hotkey.bind({'ctrl', 'cmd'}, 'R', reload)
