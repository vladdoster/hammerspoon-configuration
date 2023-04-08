-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:

-- Make all our animations really fast
hs.window.animationDuration = 0.1
hs.ipc.cliInstall()
hs.logger.setGlobalLogLevel('verbose')

-- spaces = require('hs._asm.undocumented.spaces')

-- extensions, available in hammerspoon console

hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
Install = spoon.SpoonInstall

local K = require('ext.keybind')
-- require('ext.clipboard')
-- require('ext.infoDisplay').start()
require('ext.app-toggle')
require('ext.battery')
require('ext.dockTime').start()
require('ext.spoons')
require('ext.volume')

local function reload() hs.reload() end

local keymaps = {}
-- -- keymaps['t'] = require('ext.sysStats').toggle
keymaps['R'] = reload
-- keymaps['b'] = function() toggle_application('Safari') end
-- keymaps['h'] = hs.hints.windowHints
-- keymaps['t'] = function() toggle_application('WezTerm') end
-- keymaps['y'] = hs.toggleConsole
K.bind(keymaps)

--
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
