-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
require("hs.ipc")

hs.window.animationDuration = 0.1

local console = require("ext.console")
local keybind = require("ext.keybind")
local hyper = keybind.hyper

console.setup()
console.bindHotkeys({ toggle = { { "ctrl", "alt", "shift" }, "H" } })

-- loginwindow ships only in ignoreInDefaultFilter, which gates windows and not app registration, so wfilter warns about its id-0 phantom window until it is ignored at the root
-- Must stay above the andUse calls: isGuiApp reads this while registering apps, which happens the first time a Spoon activates a window filter
hs.window.filter.ignoreAlways["loginwindow"] = true

-- Same layer, same reason: appWindowEvent resolves our own pid before it bails on Hammerspoon, and that lookup returns nil while the app's LaunchServices registration is in flux, which is what opening the Console does
-- rejectApp("Hammerspoon") cannot prevent it, since that filters windows only after the app has been registered and watched
hs.window.filter.ignoreAlways["Hammerspoon"] = true

hs.loadSpoon("SpoonInstall")

local function use(name, arg)
    arg = arg or {}
    arg.start = true
    spoon.SpoonInstall:andUse(name, arg)
end

use("BatteryMonitor")
use("ClipboardHistory", { hotkeys = { show = { hyper, "C" }, showAndType = { hyper, "V" } } })
use("DeminimizeWindow", { hotkeys = { restore = { hyper, "M" } } })
use("FocusBorder")
use("PictureInPicture", { hotkeys = { toggle = { hyper, "P" } } })
use("PinnedWindows", { hotkeys = { togglePin = { { "cmd", "alt", "shift" }, "P" } } })
use("SummonWindow", { hotkeys = { summon = { { "cmd", "alt", "shift" }, "S" } } })
use("VolumeControl", { hotkeys = { down = { hyper, "Down" }, up = { hyper, "Up" } } })
use("Yabai", { config = { confirmWhenWindows = false }, hotkeys = { modal = { hyper, "Y" } } })

keybind.bind({
    ["R"] = function()
        hs.reload()
    end,
})

hs.notify.new({ informativeText = "Config loaded", title = "Hammerspoon" }):send()
