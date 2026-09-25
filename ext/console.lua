-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
local M = {}

M.font = { name = "ServerMono-Regular", size = 12 }

M.setup = function()
  hs.console.darkMode(true)
  hs.console.consoleFont(M.font)
  hs.console.windowBackgroundColor({ white = 0.1 })
  hs.console.outputBackgroundColor({ white = 0.1 })
  hs.console.inputBackgroundColor({ white = 0.15 })
  hs.console.consolePrintColor({ white = 0.85 })
  hs.console.consoleCommandColor({ white = 1 })
  hs.console.consoleResultColor({ red = 0.55, green = 0.8, blue = 1 })
end

M.bindHotkeys = function(mapping)
  hs.hotkey.bind(mapping.toggle[1], mapping.toggle[2], hs.toggleConsole)
end

return M
