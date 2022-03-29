local M = { log = hs.logger.new("spoons", "debug") }
local K = require("ext.keybind")

hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall.use_syncinstall = true

local function installLog(name)
	M.log.i("Installing " .. name)
end

M.Install = spoon.SpoonInstall

installLog("HeadphoneAutoPause")
M.Install:andUse("HeadphoneAutoPause", { start = true })

installLog("KSheet")
M.Install:andUse("KSheet", { hotkeys = { toggle = { K.hyper, "/" } } })

installLog("MouseCircle")
M.Install:andUse("MouseCircle", {
	config = { color = hs.drawing.color.x11.red },
	disable = false,
	hotkeys = { show = { K.hyper, "m" } },
})

installLog("RoundedCorners")
M.Install:andUse("RoundedCorners", { start = true })

installLog("SpeedMenu")
M.Install:andUse("SpeedMenu", {})

installLog("TextClipboardHistory")
M.Install:andUse("TextClipboardHistory", {
	config = { show_in_menubar = true },
	disable = false,
	hotkeys = { toggle_clipboard = { K.hyper, "v" } },
	start = true,
})

return M
