local M = {}
local K = require 'ext.keybind'

hs.window.animationDuration = 0.1
-- Capture the hostname, so we can make this config behave differently across my Macs
hostname = hs.host.localizedName()
-- Ensure the IPC command line client is available
hs.ipc.cliInstall()

require 'ext.spoons'
require 'ext.battery'
require 'ext.navigation'
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

function changeVolume(diff)
  return function()
    local current = hs.audiodevice.defaultOutputDevice():volume()
    local new = math.min(100, math.max(0, math.floor(current + diff)))
    if new > 0 then hs.audiodevice.defaultOutputDevice():setMuted(false) end
    hs.alert.closeAll(0.0)
    hs.alert.show('Volume ' .. new .. '%', {}, 0.5)
    hs.audiodevice.defaultOutputDevice():setVolume(new)
  end
end

function reload()
  local new = 'NIGGER'
  hs.reload()
  hs.alert.show('hammerspoon reloaded')
end

hs.hotkey.bind(K.hyper, 'Down', changeVolume(-3))
hs.hotkey.bind(K.hyper, 'Up', changeVolume(3))

-- Toggle a window between its normal size, and being maximized
function toggle_window_maximized()
  local win = hs.window.focusedWindow()
  if frameCache[win:id()] then
    win:setFrame(frameCache[win:id()])
    frameCache[win:id()] = nil
  else
    frameCache[win:id()] = win:frame()
    win:maximize()
  end
end

function center()
  local win = hs.window.focusedWindow()
  win:centerOnScreen()
end

-- Center of the screen
hs.hotkey.bind({'ctrl', 'cmd'}, 'C', center)
hs.hotkey.bind({'ctrl', 'cmd'}, 'M', toggle_window_maximized)
hs.hotkey.bind({'ctrl', 'cmd'}, 'R', reload)

hs.notify.new({title='hammerspoon', informativetext='config loaded', withdrawAfter=2.0}):send()
