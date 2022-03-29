local M = {}

local K = require("ext.keybind")

require("ext.spoons")
require("ext.battery")
require("ext.dockTime").start()
require("ext.infoDisplay").start()
require("ext.navigation")

hs.window.animationDuration = 0.1
hs.ipc.cliInstall()

M.windows = require("ext.windows")
M.windows.applicationToggle({
	e = "kitty",
	z = "Music",
	q = "Vivaldi",
})

local keybinds = {}
keybinds["h"] = hs.hints.windowHints
-- keybinds["t"] = require("ext.sysStats").toggle
keybinds["y"] = hs.toggleConsole
K.bind(keybinds)

hs.notify.new({ title = "Hammerspoon", informativeText = "Config loaded" }):send()
