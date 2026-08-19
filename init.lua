-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
require("hs.ipc")

hs.window.animationDuration = 0.1

-- loginwindow ships only in ignoreInDefaultFilter, which gates windows and not app registration, so wfilter warns about its id-0 phantom window until it is ignored at the root
-- Must stay above the andUse calls: isGuiApp reads this while registering apps, which happens the first time a Spoon activates a window filter
hs.window.filter.ignoreAlways["loginwindow"] = true

-- Same layer, same reason: appWindowEvent resolves our own pid before it bails on Hammerspoon, and that lookup returns nil while the app's LaunchServices registration is in flux, which is what opening the Console does
-- rejectApp("Hammerspoon") cannot prevent it, since that filters windows only after the app has been registered and watched
hs.window.filter.ignoreAlways["Hammerspoon"] = true

hs.loadSpoon("SpoonInstall")

spoon.SpoonInstall:andUse("BatteryMonitor", { start = true })
spoon.SpoonInstall:andUse("ClipboardHistory", { hotkeys = { show = { { "cmd", "alt", "ctrl" }, "C" } }, start = true })
spoon.SpoonInstall:andUse(
    "DeminimizeWindow",
    { hotkeys = { restore = { { "cmd", "alt", "ctrl" }, "M" } }, start = true }
)
spoon.SpoonInstall:andUse("FocusBorder", { start = true })
spoon.SpoonInstall:andUse(
    "PictureInPicture",
    { hotkeys = { toggle = { { "cmd", "alt", "ctrl" }, "P" } }, start = true }
)
spoon.SpoonInstall:andUse(
    "PinnedWindows",
    { hotkeys = { togglePin = { { "cmd", "alt", "shift" }, "P" } }, start = true }
)
spoon.SpoonInstall:andUse("SummonWindow", { hotkeys = { summon = { { "cmd", "alt", "shift" }, "S" } }, start = true })
spoon.SpoonInstall:andUse(
    "VolumeControl",
    { hotkeys = { down = { { "cmd", "alt", "ctrl" }, "Down" }, up = { { "cmd", "alt", "ctrl" }, "Up" } }, start = true }
)
spoon.SpoonInstall:andUse(
    "Yabai",
    { config = { confirmWhenWindows = false }, hotkeys = { modal = { { "cmd", "alt", "ctrl" }, "Y" } }, start = true }
)

require("ext.keybind").bind({
    ["R"] = function()
        hs.reload()
    end,
})

hs.notify.new({ informativeText = "Config loaded", title = "Hammerspoon" }):send()
