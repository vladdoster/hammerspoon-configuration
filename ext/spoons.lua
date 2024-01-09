-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:
local obj = {}
obj.__index = obj

obj.logger = hs.logger.new('SpoonInstall')

hs.loadSpoon('SpoonInstall')
local hyper = {'cmd', 'alt', 'ctrl'}

obj.repos = {
  HeadphoneAutoPause={start=true},
  KSheet={hotkeys={toggle={hyper, '/'}}},
  MouseCircle={config={color=hs.drawing.color.x11.red}, disable=false, hotkeys={show={hyper, 'm'}}},
  RoundedCorners={start=true},
  SpeedMenu={},
  TextClipboardHistory={
    config={show_in_menubar=false},
    disable=false,
    hotkeys={toggle_clipboard={{'cmd', 'shift'}, 'v'}},
    start=true
  }
}

-- hs.loadSpoon('TilingWindowManager'):setLogLevel('debug'):bindHotkeys({
--   tile={hyper, 't'},
--   incMainRatio={hyper, 'p'},
--   decMainRatio={hyper, 'o'},
--   incMainWindows={hyper, 'i'},
--   decMainWindows={hyper, 'u'},
--   focusNext={hyper, 'k'},
--   focusPrev={hyper, 'j'},
--   swapNext={hyper, 'l'},
--   swapPrev={hyper, 'h'},
--   toggleFirst={hyper, 'return'},
--   tall={hyper, ','},
--   talltwo={hyper, 'm'},
--   fullscreen={hyper, '.'},
--   wide={hyper, '-'},
--   display={hyper, 'd'}
-- }):start({
--   menubar=true,
--   dynamic=true,
--   layouts={
--     spoon.TilingWindowManager.layouts.fullscreen,
--     spoon.TilingWindowManager.layouts.tall,
--     spoon.TilingWindowManager.layouts.talltwo,
--     spoon.TilingWindowManager.layouts.wide,
--     spoon.TilingWindowManager.layouts.floating
--   },
--   displayLayout=true,
--   floatApps={'com.apple.systempreferences', 'com.apple.ActivityMonitor', 'com.apple.Stickies'}
-- })

for k, v in pairs(obj.repos) do
  obj.logger.i('Installing ' .. k)
  spoon.SpoonInstall:andUse(k, v)
end
hs.loadSpoon('asmHammerspoon')

return M
