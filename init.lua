-- Make all our animations really fast
hs.window.animationDuration = 0.1
hs.ipc.cliInstall()

-- spaces = require('hs._asm.undocumented.spaces')

-- extensions, available in hammerspoon console
ext = {frame={}, win={}, app={}, utils={}, cache={}, watchers={}}

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

-- function ext.app.forceLaunchOrFocus(appName)
--   -- first focus with hammerspoon
--   hs.application.launchOrFocus(appName)
--
--   -- clear timer if exists
--   if ext.cache.launchTimer then ext.cache.launchTimer:stop() end
--
--   -- wait 500ms for window to appear and try hard to show the window
--   ext.cache.launchTimer = hs.timer.doAfter(0.5, function()
--     local frontmostApp = hs.application.frontmostApplication()
--     local frontmostWindows = hs.fnutils.filter(frontmostApp:allWindows(), function(win) return win:isStandard() end)
--
--     -- break if this app is not frontmost (when/why?)
--     if frontmostApp:title() ~= appName then
--       print('Expected app in front: ' .. appName .. ' got: ' .. frontmostApp:title())
--       return
--     end
--
--     if #frontmostWindows == 0 then
--       -- check if there's app name in window menu (Calendar, Messages, etc...)
--       if frontmostApp:findMenuItem({'Window', appName}) then
--         -- select it, usually moves to space with this window
--         frontmostApp:selectMenuItem({'Window', appName})
--       else
--         -- otherwise send cmd-n to create new window
--         hs.eventtap.keyStroke({'cmd'}, 'n')
--       end
--     end
--   end)
-- end
--
-- -- smart app launch or focus or cycle windows
-- function ext.app.smartLaunchOrFocus(launchApps)
--   local frontmostWindow = hs.window.frontmostWindow()
--   local runningApps = hs.application.runningApplications()
--   local runningWindows = {}
--
--   -- filter running applications by apps array
--   local runningApps = hs.fnutils.map(launchApps, function(launchApp) return hs.application.get(launchApp) end)
--
--   -- create table of sorted windows per application
--   hs.fnutils.each(runningApps, function(runningApp)
--     local standardWindows = hs.fnutils.filter(runningApp:allWindows(), function(win) return win:isStandard() end)
--
--     table.sort(standardWindows, function(a, b) return a:id() < b:id() end)
--
--     runningWindows = standardWindows
--   end)
--
--   if #runningApps == 0 then
--     -- if no apps are running then launch first one in list
--     ext.app.forceLaunchOrFocus(launchApps[1])
--   elseif #runningWindows == 0 then
--     -- if some apps are running, but no windows - force create one
--     ext.app.forceLaunchOrFocus(runningApps[1]:title())
--   else
--     -- check if one of windows is already focused
--     local currentIndex = hs.fnutils.indexOf(runningWindows, frontmostWindow)
--
--     if not currentIndex then
--       -- if none of them is selected focus the first one
--       runningWindows[1]:focus()
--     else
--       -- otherwise cycle through all the windows
--       local newIndex = currentIndex + 1
--       if newIndex > #runningWindows then newIndex = 1 end
--
--       runningWindows[newIndex]:focus()
--     end
--   end
-- end
--
-- -- keyboard modifiers for bindings
-- local mod = {cc={'cmd', 'ctrl'}, ca={'cmd', 'alt'}, cac={'cmd', 'alt', 'ctrl'}, cas={'cmd', 'alt', 'shift'}}
--
-- -- launch and focus applications
-- hs.fnutils.each({
--   {key='b', apps={'Safari', 'Google Chrome'}},
--   {key='f', apps={'Finder'}},
--   {key='m', apps={'Teams'}},
--   {key='t', apps={'WezTerm'}}
-- }, function(object) hs.hotkey.bind(mod.cac, object.key, function() ext.app.smartLaunchOrFocus(object.apps) end) end)
--
-- -- Toggle an application between being the frontmost app, and being hidden
-- function toggle_application(_app)
--   local app = hs.appfinder.appFromName(_app)
--   if not app then
--     -- FIXME: This should really launch _app
--     hs.notify.new({title='Toggle Application', informativeText=tostring(_app) .. ' not open'}):send()
--     return
--   end
--   local mainwin = app:mainWindow()
--   if mainwin then
--     if mainwin == hs.window.focusedWindow() then
--       mainwin:application():hide()
--     else
--       mainwin:application():activate(true)
--       mainwin:application():unhide()
--       mainwin:focus()
--     end
--   end
-- end

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
