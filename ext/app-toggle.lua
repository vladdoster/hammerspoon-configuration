-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:

local obj={}
obj.__index = obj
-- Metadata
obj.name = "AppToggle"
obj.version = "0.5"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"
local spaces, fnutils = require('hs.spaces'), require('hs.fnutils')
local getSetting = function(label, default) return hs.settings.get(obj.name.."."..label) or default end
local setSetting = function(label, value)   hs.settings.set(obj.name.."."..label, value); return value end
obj.frequency = 0.8
obj.hist_size = 100
obj.honor_ignoredidentifiers = true
obj.paste_on_select = getSetting('paste_on_select', false)
obj.logger = hs.logger.new('AppToggler')
obj.logger.setLogLevel('info')

ext = {app={}, cache={}}
hs.spaces.MCwaitTime = 0.1

function ext.app.forceLaunchOrFocus(appName)
  hs.application.launchOrFocus(appName)
  if ext.cache.launchTimer then ext.cache.launchTimer:stop() end
  ext.cache.launchTimer = hs.timer.doAfter(0.5, function()
    local frontmostApp = hs.application.frontmostApplication()
    local frontmostWindows = fnutils.filter(frontmostApp:allWindows(), function(win) return win:isStandard() end)
    -- break if this app is not frontmost (when/why?)
    if frontmostApp:title() ~= appName then
      obj.logger.i("front most app " .. frontmostApp:title())
      return
    end
    if #frontmostWindows == 0 then
      -- check if there's app name in window menu (Calendar, Messages, etc...)
      if frontmostApp:findMenuItem({'Window', appName}) then
        -- select it, usually moves to space with this window
        frontmostApp:selectMenuItem({'Window', appName})
      else
        obj.logger.i("creating new window " .. appName)
        hs.eventtap.keyStroke({'cmd'}, 'n')
      end
    end
  end)
end

-- smart app launch or focus or cycle windows
function ext.app.smartLaunchOrFocus(launchApps)
  local frontmostWindow = hs.window.frontmostWindow()
  local runningApps = hs.application.runningApplications()
  local runningWindows = {}
  -- filter running applications by apps array
  local runningApps = fnutils.map(launchApps, function(launchApp) return hs.application.get(launchApp) end)
  -- create table of sorted windows per application
  fnutils.each(runningApps, function(runningApp)
    local standardWindows = fnutils.filter(runningApp:allWindows(), function(win) return win:isStandard() end)
    table.sort(standardWindows, function(a, b) return a:id() < b:id() end)
    runningWindows = standardWindows
  end)

  if #runningApps == 0 then
    -- if no apps are running then launch first one in list
    ext.app.forceLaunchOrFocus(launchApps[1])
  elseif #runningWindows == 0 then
    -- if some apps are running, but no windows - force create one
    ext.app.forceLaunchOrFocus(runningApps[1]:title())
  else
    -- check if one of windows is already focused
    local currentIndex = fnutils.indexOf(runningWindows, frontmostWindow)
    if not currentIndex then
      -- if none of them is selected focus the first one
      runningWindows[1]:focus()
    else
      -- otherwise cycle through all the windows
      local newIndex = currentIndex + 1
      if newIndex > #runningWindows then newIndex = 1 end
      local currentSpace = spaces.focusedSpace()
      local windowSpace = spaces.windowSpaces(runningWindows[newIndex])[newIndex]
      obj.logger.i("current space: " .. currentSpace .. " window space: " .. windowSpace)
      if runningWindows[newIndex]:isFullScreen() and windowSpace ~= currentSpace then
        obj.logger.i("focusing space: " .. windowSpace)
        spaces.gotoSpace(spaces.windowSpaces(runningWindows[newIndex])[newIndex])
        spaces.closeMissionControl()
      end
      runningWindows[newIndex]:focus()
      runningWindows[newIndex]:centerOnScreen()
    end
  end
end
-- keyboard modifiers for bindings
local mod = {cc={'cmd', 'ctrl'}, ca={'cmd', 'alt'}, cac={'cmd', 'alt', 'ctrl'}, cas={'cmd', 'alt', 'shift'}}
-- launch and focus applications
fnutils.each({
  {key='b', apps={'Safari', 'Google Chrome', 'Vivaldi'}},
  {key='f', apps={'Finder'}},
  {key='m', apps={'Teams'}},
  {key='s', apps={'System Settings'}},
  {key='y', apps={'Hammerspoon'}},
  {key='t', apps={'WezTerm'}}
}, function(object) hs.hotkey.bind(mod.cac, object.key, function() ext.app.smartLaunchOrFocus(object.apps) end) end)
