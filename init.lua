-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:
-- Make all our animations really fast
hs.window.animationDuration = 0.1
hs.ipc.cliInstall('/opt/hs')
hs.logger.setGlobalLogLevel('verbose')

-- spaces = require('hs._asm.undocumented.spaces')

-- extensions, available in hammerspoon console

hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
-- Install = spoon.SpoonInstall
require('_hs.hs.eventtap')

local K = require('ext.keybind')
require('ext.clipboard')
-- require('ext.infoDisplay').start()
require('ext.app-toggle')
require('ext.dockTime').start()
require('ext.spoons')
require('ext.volume')
require('ext.chooseApp')
-- PaperWM = hs.loadSpoon("PaperWM")
-- PaperWM:bindHotkeys({
--     -- switch to a new focused window in tiled grid
--     focus_left  = {{"ctrl", "alt", "cmd"}, "left"},
--     focus_right = {{"ctrl", "alt", "cmd"}, "right"},
--     focus_up    = {{"ctrl", "alt", "cmd"}, "up"},
--     focus_down  = {{"ctrl", "alt", "cmd"}, "down"},
--
--     -- move windows around in tiled grid
--     swap_left  = {{"ctrl", "alt", "cmd", "shift"}, "left"},
--     swap_right = {{"ctrl", "alt", "cmd", "shift"}, "right"},
--     swap_up    = {{"ctrl", "alt", "cmd", "shift"}, "up"},
--     swap_down  = {{"ctrl", "alt", "cmd", "shift"}, "down"},
--
--     -- position and resize focused window
--     center_window = {{"ctrl", "alt", "cmd"}, "c"},
--     full_width    = {{"ctrl", "alt", "cmd"}, "f"},
--     cycle_width   = {{"ctrl", "alt", "cmd"}, "r"},
--     cycle_height  = {{"ctrl", "alt", "cmd", "shift"}, "r"},
--
--     -- move focused window into / out of a column
--     slurp_in = {{"ctrl", "alt", "cmd"}, "i"},
--     barf_out = {{"ctrl", "alt", "cmd"}, "o"},
--
--     -- switch to a new Mission Control space
--     switch_space_1 = {{"ctrl", "alt", "cmd"}, "1"},
--     switch_space_2 = {{"ctrl", "alt", "cmd"}, "2"},
--     switch_space_3 = {{"ctrl", "alt", "cmd"}, "3"},
--     switch_space_4 = {{"ctrl", "alt", "cmd"}, "4"},
--     switch_space_5 = {{"ctrl", "alt", "cmd"}, "5"},
--     switch_space_6 = {{"ctrl", "alt", "cmd"}, "6"},
--     switch_space_7 = {{"ctrl", "alt", "cmd"}, "7"},
--     switch_space_8 = {{"ctrl", "alt", "cmd"}, "8"},
--     switch_space_9 = {{"ctrl", "alt", "cmd"}, "9"},
--
--     -- move focused window to a new space and tile
--     move_window_1 = {{"ctrl", "alt", "cmd", "shift"}, "1"},
--     move_window_2 = {{"ctrl", "alt", "cmd", "shift"}, "2"},
--     move_window_3 = {{"ctrl", "alt", "cmd", "shift"}, "3"},
--     move_window_4 = {{"ctrl", "alt", "cmd", "shift"}, "4"},
--     move_window_5 = {{"ctrl", "alt", "cmd", "shift"}, "5"},
--     move_window_6 = {{"ctrl", "alt", "cmd", "shift"}, "6"},
--     move_window_7 = {{"ctrl", "alt", "cmd", "shift"}, "7"},
--     move_window_8 = {{"ctrl", "alt", "cmd", "shift"}, "8"},
--     move_window_9 = {{"ctrl", "alt", "cmd", "shift"}, "9"}
-- })
-- PaperWM:start()

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
