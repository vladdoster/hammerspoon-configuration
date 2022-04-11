local M = {}

M.hyper = {'cmd', 'alt', 'ctrl'}

M.bind = function(hyperfns) for key, fn in pairs(hyperfns) do hs.hotkey.bind(M.hyper, key, fn) end end

return M
