-- Make all our animations really fast
hs.window.animationDuration = 0.1
hs.ipc.cliInstall()

hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
Install = spoon.SpoonInstall

local K = require('ext.keybind')
require('ext.battery')
require('ext.spoons')
require('ext.volume')
require('ext.clipboard')
require('ext.dockTime').start()
require('ext.infoDisplay').start()

local function reload() hs.reload() end

local keymaps = {}
-- keymaps['t'] = require('ext.sysStats').toggle
keymaps['R'] = reload
keymaps['b'] = function() toggle_application('Safari') end
keymaps['h'] = hs.hints.windowHints
keymaps['t'] = function() toggle_application('WezTerm') end
keymaps['y'] = hs.toggleConsole
K.bind(keymaps)

-- Toggle an application between being the frontmost app, and being hidden
function toggle_application(_app)
  local app = hs.appfinder.appFromName(_app)
  if not app then
    -- FIXME: This should really launch _app
        hs.notify.new({title='Toggle Application', informativeText=tostring(_app) .. ' not open'}):send()
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

-- Install:andUse('Seal', {
--   hotkeys={show={{'cmd'}, 'Space'}},
--   fn=function(s)
--     s:loadPlugins({
--       'apps',
--       'vpn',
--       'screencapture',
--       'safari_bookmarks',
--       'calc',
--       'useractions',
--       'pasteboard',
--       'filesearch'
--     })
--     s.plugins.pasteboard.historySize = 4000
--     s.plugins.useractions.actions = useractions_actions
--   end,
--   start=true
-- })

hs.notify.new({title='Hammerspoon', informativeText='Config loaded'}):send()
