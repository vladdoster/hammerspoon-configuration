-- vim: set expandtab filetype=lua:
require("hs.ipc")

require("ext.battery")
require("ext.volume")

hs.window.animationDuration = 0.1

hs.loadSpoon("PinnedWindows")
spoon.PinnedWindows:bindHotkeys({ togglePin = { { "cmd", "alt", "shift" }, "P" } })
spoon.PinnedWindows:start()

hs.loadSpoon("SummonWindow")
spoon.SummonWindow:bindHotkeys({ summon = { { "cmd", "alt", "shift" }, "S" } })
spoon.SummonWindow:start()

hs.loadSpoon("DeminimizeWindow")
spoon.DeminimizeWindow:bindHotkeys({ restore = { { "cmd", "alt", "ctrl" }, "M" } })
spoon.DeminimizeWindow:start()

hs.loadSpoon("ClipboardHistory")
spoon.ClipboardHistory:bindHotkeys({ show = { { "cmd", "alt", "ctrl" }, "C" } })
spoon.ClipboardHistory:start()

require("ext.keybind").bind({
    ["R"] = function()
        hs.reload()
    end,
})

hs.notify.new({ informativeText = "Config loaded", title = "Hammerspoon" }):send()
