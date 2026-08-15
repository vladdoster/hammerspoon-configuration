-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:
-- Make all our animations really fast
hs.window.animationDuration = 0.1
hs.ipc.cliInstall('/opt/homebrew')
hs.logger.setGlobalLogLevel('verbose')
require('hs.ipc')

hs.loadSpoon('SpoonInstall')
spoon.SpoonInstall.use_syncinstall = true
local K = require('ext.keybind')
require('ext.dockTime').start()
-- require('ext.spoons')
require('ext.volume')
require('ext.battery')
hs.loadSpoon('PinnedWindows')
spoon.PinnedWindows:bindHotkeys({ togglePin = { { 'cmd', 'alt', 'shift' }, 'P' } })
spoon.PinnedWindows:start()

hs.loadSpoon('FocusBorder')
spoon.FocusBorder:start()

hs.loadSpoon('SummonWindow')
spoon.SummonWindow:bindHotkeys({ summon = { { 'cmd', 'alt', 'shift' }, 'S' } })
spoon.SummonWindow:start()

hs.loadSpoon('DeminimizeWindow')
spoon.DeminimizeWindow:bindHotkeys({ restore = { { 'cmd', 'alt', 'ctrl' }, 'M' } })
spoon.DeminimizeWindow:start()

hs.loadSpoon('ClipboardHistory')
spoon.ClipboardHistory:bindHotkeys({ show = { { 'cmd', 'alt', 'ctrl' }, 'C' } })
spoon.ClipboardHistory:start()

local function reload() hs.reload() end
local keymaps = {}
keymaps['R'] = reload
K.bind(keymaps)

hs.notify.new({ title = 'Hammerspoon', informativeText = 'Config loaded' }):send()
