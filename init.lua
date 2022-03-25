local hyper, shift_hyper = {'cmd', 'alt', 'ctrl'}, {'cmd', 'alt', 'ctrl', 'shift'}

require('ext.battery')
require('ext.dockTime').start()
require('ext.infoDisplay').start()
require('ext.navigation')
require('spoons')

-- Toggle an application between being the frontmost app, and being hidden
local function toggle_application(_app)
  local app = hs.appfinder.appFromName(_app)
  if not app then return end
  local mainwin = app:mainWindow()
  if mainwin then
    if mainwin == hs.window.focusedWindow() then
      mainwin:application():hide()
    else
      mainwin:application():activate(true)
      mainwin:application():unhide()
      mainwin:focus()
    end
  end
end
-- Toggle a window between its normal size, and being maximized
frameCache = {}
local function toggle_window_maximized()
  local win = hs.window.focusedWindow()
  if frameCache[win:id()] then
    win:setFrame(frameCache[win:id()])
    frameCache[win:id()] = nil
  else
    frameCache[win:id()] = win:frame() and win:maximize()
  end
end

local hyperfns = {}
hyperfns['e'] = function() toggle_application('kitty') end
hyperfns['f'] = toggle_window_maximized
hyperfns['h'] = hs.hints.windowHints
hyperfns['q'] = function() toggle_application('Vivaldi') end
hyperfns['r'] = function() hs.window.focusedWindow():toggleFullScreen() end
hyperfns['t'] = function() require('ext.sysStats').toggle() end
hyperfns['y'] = hs.toggleConsole
hyperfns['z'] = function() toggle_application('Music') end
for _hotkey, _fn in pairs(hyperfns) do hs.hotkey.bind(hyper, _hotkey, _fn) end

hs.notify.new({title='Hammerspoon', informativeText='Config loaded'}):send()
