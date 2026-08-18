-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
local obj = {}
obj.__index = obj

obj.logger = hs.logger.new("SpoonInstall")

hs.loadSpoon("SpoonInstall")
local hyper = { "cmd", "alt", "ctrl" }

obj.repos = {
  HeadphoneAutoPause = { start = true },
  KSheet = { hotkeys = { toggle = { hyper, "/" } } },
  MouseCircle = {
    config = { color = hs.drawing.color.x11.red },
    disable = false,
    hotkeys = { show = { hyper, "m" } },
  },
  RoundedCorners = { start = true },
  SpeedMenu = {},
}

for k, v in pairs(obj.repos) do
  obj.logger.i("Installing " .. k)
  spoon.SpoonInstall:andUse(k, v)
end

return obj
