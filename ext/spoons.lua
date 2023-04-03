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

for k, v in pairs(obj.repos) do
  obj.logger.i('Installing ' .. k)
  spoon.SpoonInstall:andUse(k, v)
end

return M
