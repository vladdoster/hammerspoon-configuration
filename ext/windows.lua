local M = {frameCache={}}
local K = require('ext.keybind')
-- Toggle an application between being the frontmost app, and being hidden
M.toggle_application = function(_app)
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
M.toggle_window_maximized = function()
  local win = hs.window.focusedWindow()
  if M.frameCache[win:id()] then
    win:setFrame(M.frameCache[win:id()])
    M.frameCache[win:id()] = nil
  else
    M.frameCache[win:id()] = win:frame() and win:maximize()
  end
end
M.applicationToggle = function(toggles)
  for k, v in pairs(toggles) do K.bind({k=function() M.toggle_application(v) end}) end
end
M.fullscreenToggle = function() K.bind({f=hs.window.focusedWindow():toggleFullScreen()}) end
-- Toggle a window between its normal size, and being maximized
-- local function toggle_window_maximized()
--   local win = hs.window.focusedWindow()
--   if frameCache[win:id()] then
--     win:setFrame(frameCache[win:id()])
--     frameCache[win:id()] = nil
--   else
--     frameCache[win:id()] = win:frame()
--     win:maximize()
--   end
-- end
-- function center()
--   local win = hs.window.focusedWindow()
--   win:centerOnScreen()
-- end
-- Center of the screen
-- hs.hotkey.bind({'ctrl', 'cmd'}, 'C', center)
-- hs.hotkey.bind({'ctrl', 'cmd'}, 'M', toggle_window_maximized)
return M
