-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2:
local M = {}
local alert = require('hs.alert')
local audio_device = require('hs.audiodevice')
local bind = require('hs.hotkey').bind
local hyper = {'cmd', 'alt', 'ctrl'}

M.changeVolume = function(diff)
  return function()
    local current = audio_device.defaultOutputDevice():volume()
    local new = math.min(100, math.max(0, math.floor(current + diff)))
    if new > 0 then audio_device.defaultOutputDevice():setMuted(false) end
    alert.closeAll(0.0)
    alert.show('Volume ' .. new .. '%', {}, 0.5)
    audio_device.defaultOutputDevice():setVolume(new)
  end
end

bind(hyper, 'Down', M.changeVolume(-2))
bind(hyper, 'Up', M.changeVolume(2))

return M
