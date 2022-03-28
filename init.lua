hs.window.animationDuration = 0.1
hs.ipc.cliInstall()
hyper = { 'cmd', 'alt', 'ctrl' }
hyperfns = {}
frameCache = {}

require('ext.battery')
require('ext.dockTime')
require('ext.infoDisplay')
require('ext.navigation')
require('spoons')

function toggle_application(_app)
  local app = hs.appfinder.appFromName(_app)
  if not app then
    -- FIXME: This should really launch _app
    return
  end
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
-- Application hotkeys
hyperfns['e'] = function()
  toggle_application('kitty')
end
hyperfns['f'] = toggle_window_maximized
hyperfns['h'] = hs.hints.windowHints
hyperfns['t'] = require('ext.sysStats').toggle
hyperfns['q'] = function()
  toggle_application('Vivaldi')
end
hyperfns['y'] = hs.toggleConsole
for _hotkey, _fn in pairs(hyperfns) do
  hs.hotkey.bind(hyper, _hotkey, _fn)
end
hs.notify.new({ title = 'Hammerspoon', informativeText = 'Config loaded' }):send()
