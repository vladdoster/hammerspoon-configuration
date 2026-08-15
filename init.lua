-- vim: set expandtab filetype=lua:
require("hs.ipc")

require("ext.volume")

hs.window.animationDuration = 0.1

hs.loadSpoon("SpoonInstall")

spoon.SpoonInstall:andUse("BatteryMonitor", { start = true })
spoon.SpoonInstall:andUse("ClipboardHistory", { hotkeys = { show = { { "cmd", "alt", "ctrl" }, "C" } }, start = true })
spoon.SpoonInstall:andUse(
    "DeminimizeWindow",
    { hotkeys = { restore = { { "cmd", "alt", "ctrl" }, "M" } }, start = true }
)
spoon.SpoonInstall:andUse("FocusBorder", { start = true })
spoon.SpoonInstall:andUse(
    "PinnedWindows",
    { hotkeys = { togglePin = { { "cmd", "alt", "shift" }, "P" } }, start = true }
)
spoon.SpoonInstall:andUse("SummonWindow", { hotkeys = { summon = { { "cmd", "alt", "shift" }, "S" } }, start = true })

require("ext.keybind").bind({
    ["R"] = function()
        hs.reload()
    end,
})

hs.notify.new({ informativeText = "Config loaded", title = "Hammerspoon" }):send()
