-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === VolumeControl ===
---
--- Steps the default output device's volume from a hotkey, with an on-screen readout.
---
--- The readout is a single canvas, built once and then only re-textured, so holding the key down
--- costs one attribute write per repeat rather than a new window. It is the Spoon's own canvas
--- rather than an `hs.alert`, so it never disturbs messages other Spoons have put on screen.

local obj = {}
obj.__index = obj

obj.name = "VolumeControl"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- VolumeControl.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("VolumeControl", "info")

-- Configuration

--- VolumeControl.increment
--- Variable
--- Percentage points added or removed per keypress. Defaults to `2`.
obj.increment = 2

--- VolumeControl.hudDuration
--- Variable
--- Seconds the readout stays up after you stop adjusting. Defaults to `0.75`.
---
--- The countdown restarts on every change, from a held key's repeats and from separate presses alike, so a burst of adjustments shows one continuous readout. Read it as "how long after the LAST change", not "how long each change is shown": a value shorter than the gap between deliberate presses makes the readout drop out mid-adjustment.
obj.hudDuration = 0.75

--- VolumeControl.resyncAfter
--- Variable
--- Seconds after which the next step re-reads the device instead of trusting its own target. Defaults to `1`.
---
--- During a ramp the Spoon steps its own figure, which keeps the increments even on hardware that quantises volume to its own steps and reads back something other than what was written. Once you pause for longer than this, the device is authoritative again, so changes made with the media keys or in System Settings are picked up.
obj.resyncAfter = 1

--- VolumeControl.muteAtZero
--- Variable
--- Whether reaching 0% mutes the device, and anything above it unmutes. Defaults to `true`.
obj.muteAtZero = true

--- VolumeControl.hudStyle
--- Variable
--- Appearance of the readout, mirroring `hs.alert.defaultStyle` so it looks like the alert it replaces.
---
--- Baked into the canvas at build time. Change it before `VolumeControl:start()`, or call `VolumeControl:rebuild()` afterwards.
obj.hudStyle = {
  strokeWidth = 2,
  strokeColor = { white = 1, alpha = 1 },
  fillColor = { white = 0, alpha = 0.75 },
  textColor = { white = 1, alpha = 1 },
  textFont = ".AppleSystemUIFont",
  textSize = 27,
  radius = 27,
  fadeInDuration = 0.15,
  -- Zero on purpose. hs.canvas:hide(duration) schedules an orderOut for when its animation
  -- finishes and nothing cancels it, so a change arriving mid-fade is restored on screen and then
  -- yanked off again a moment later. An instant hide leaves nothing in flight to fight
  fadeOutDuration = 0,
  padding = nil, -- defaults to textSize / 2, as hs.alert does
}

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.hud = nil
obj.shown = false -- our own record; show() is makeKeyAndOrderFront, not free to repeat
obj.hideTimer = nil
obj.hotkeys = {}
obj.target = nil -- level we last set, trusted for resyncAfter seconds
obj.targetAt = nil
obj.running = false
obj.warned = {}

-- Small helpers

-- Log a given message only once, so a broken system API cannot spam the console
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- One long-lived timer whose :start() restarts the countdown, rather than an hs.timer.doAfter per
-- change; a held key repeats every few milliseconds, and each repeat would otherwise allocate one
function obj:ensureHideTimer()
  if not self.hideTimer then
    self.hideTimer = hs.timer.delayed.new(self.hudDuration, function()
      self:hideHUD()
    end)
  end
  -- Picks up a hudDuration changed from the Console since the timer was built
  self.hideTimer:setDelay(self.hudDuration)
  return self.hideTimer
end

-- The widest string the readout can show, so the canvas is sized once and never resized
function obj:hudText(level)
  return string.format("Volume %d%%", level)
end

-- The readout

-- Built once, then only re-textured: rebuilding per keypress is what made the old hs.alert costly
function obj:ensureCanvas()
  if self.hud then return self.hud end

  local style = self.hudStyle
  local padding = style.padding or style.textSize / 2
  local stroke = style.strokeWidth

  local textStyle = { font = style.textFont, size = style.textSize }
  local textSize = hs.drawing.getTextDrawingSize(self:hudText(100), textStyle)
  if not textSize then
    self:warnOnce("measure", "could not measure the readout text; falling back to a fixed size")
    textSize = { w = 200, h = style.textSize * 1.3 }
  end

  -- ceil(), since a fractional width clips the last character
  local textW, textH = math.ceil(textSize.w), math.ceil(textSize.h)
  local w = textW + padding * 2 + stroke
  local h = textH + padding * 2 + stroke

  local ok, canvas = pcall(hs.canvas.new, { x = 0, y = 0, w = w, h = h })
  if not ok or not canvas then
    self:warnOnce("canvas", "could not create the readout canvas: %s", tostring(canvas))
    return nil
  end

  canvas:appendElements({
    type = "rectangle",
    action = "strokeAndFill",
    strokeWidth = stroke,
    strokeColor = style.strokeColor,
    fillColor = style.fillColor,
    roundedRectRadii = { xRadius = style.radius, yRadius = style.radius },
    -- Inset by half the stroke, which straddles its path and would otherwise clip at the edge
    frame = { x = stroke / 2, y = stroke / 2, w = w - stroke, h = h - stroke },
  }, {
    type = "text",
    text = "",
    textFont = style.textFont,
    textSize = style.textSize,
    textColor = style.textColor,
    textAlignment = "center",
    -- Full width and centred, so the text never needs re-framing as the number's width changes
    frame = { x = 0, y = (h - textH) / 2, w = w, h = textH },
  })

  -- Above the Dock and the menubar; a readout that slides under them reads as a bug
  canvas:level(hs.canvas.windowLevels.overlay)
  -- Never own a Space, and hide under Expose
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "transient" })

  self.hud = canvas
  return canvas
end

-- Replicates hs.alert's geometry, so the readout lands where the alert it replaces used to
function obj:positionHUD(canvas)
  local screen = hs.screen.mainScreen()
  if not screen then return end
  local screenFrame = screen.fullFrame and screen:fullFrame() or screen:frame()
  local frame = canvas:frame()
  canvas:topLeft({
    x = screenFrame.x + (screenFrame.w - frame.w) / 2,
    y = screenFrame.y + (screenFrame.h * (1 - 1 / 1.55) + 55),
  })
end

function obj:hideHUD()
  if self.hud and self.shown then
    pcall(self.hud.hide, self.hud, self.hudStyle.fadeOutDuration)
    self.shown = false
  end
end

--- VolumeControl:showVolume(level) -> self
--- Method
--- Puts the readout on screen at the given level and starts its hide countdown.
---
--- Parameters:
---  * level - The percentage to display
---
--- Returns:
---  * The VolumeControl object
function obj:showVolume(level)
  local canvas = self:ensureCanvas()
  if not canvas then return self end

  -- One attribute write per step; nothing is allocated and no geometry is recomputed
  canvas:elementAttribute(2, "text", self:hudText(level))

  -- Both halves matter: `shown` is what we intend, isShowing() is what the window server did.
  -- They disagree after an interrupted fade, and trusting `shown` alone would leave the readout
  -- stranded off screen for the rest of the burst
  if not (self.shown and canvas:isShowing()) then
    -- Only at show time: the position cannot change while the readout is already visible
    self:positionHUD(canvas)
    -- alpha() first, in case a previous hide left the canvas transparent
    pcall(canvas.alpha, canvas, 1)
    pcall(canvas.show, canvas, self.hudStyle.fadeInDuration)
    self.shown = true
  end

  self:ensureHideTimer():start()
  return self
end

-- delete(), not hide(), so no NSWindow outlives a reload
function obj:discardCanvas()
  if self.hud then
    pcall(self.hud.delete, self.hud)
    self.hud = nil
  end
  self.shown = false
end

--- VolumeControl:rebuild() -> self
--- Method
--- Discards the readout canvas so the next change rebuilds it with the current `hudStyle`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VolumeControl object
function obj:rebuild()
  self:discardCanvas()
  return self
end

-- Changing the volume

-- Only the default OUTPUT device, so the output-specific accessors apply and skip the input/output probe volume() performs. Not every device implements them, hence the fallbacks
local function readLevel(device)
  return device:outputVolume() or device:volume()
end

local function writeLevel(device, level)
  return device:setOutputVolume(level) or device:setVolume(level)
end

--- VolumeControl:step(delta) -> self
--- Method
--- Adds `delta` percentage points to the output volume, clamped to 0-100.
---
--- Parameters:
---  * delta - Percentage points to add; negative lowers the volume
---
--- Returns:
---  * The VolumeControl object
---
--- Reads the device once per call. Within `VolumeControl.resyncAfter` seconds of the previous step it starts from its own figure rather than re-reading, which keeps a held ramp even.
function obj:step(delta)
  local device = hs.audiodevice.defaultOutputDevice()
  if not device then
    self:warnOnce("device", "no default output device")
    return self
  end

  local now = hs.timer.secondsSinceEpoch()
  local base = self.target
  if not base or (now - (self.targetAt or 0)) > self.resyncAfter then
    local current = readLevel(device)
    if not current then
      self:warnOnce("volume", "%s has no volume control", tostring(device:name()))
      return self
    end
    -- Round BEFORE stepping: CoreAudio volume is a float, and the fraction otherwise compounds
    base = math.floor(current + 0.5)
  end

  return self:setVolume(base + delta, device, now)
end

--- VolumeControl:setVolume(level, [device], [now]) -> self
--- Method
--- Sets the output volume to an absolute level, clamped to 0-100.
---
--- Parameters:
---  * level - The percentage to set
---  * device - An optional `hs.audiodevice` to act on; defaults to the current default output device
---  * now - An optional timestamp, used internally to stamp the ramp cache
---
--- Returns:
---  * The VolumeControl object
function obj:setVolume(level, device, now)
  device = device or hs.audiodevice.defaultOutputDevice()
  if not device then
    self:warnOnce("device", "no default output device")
    return self
  end

  level = math.max(0, math.min(100, math.floor((tonumber(level) or 0) + 0.5)))
  self.target, self.targetAt = level, now or hs.timer.secondsSinceEpoch()

  if not writeLevel(device, level) then
    self:warnOnce("setvolume", "%s refused a volume change", tostring(device:name()))
    return self
  end

  if self.muteAtZero then
    -- Write only on a real transition: setMuted broadcasts a CoreAudio notification system-wide
    local shouldMute = level == 0
    local muted = device:muted()
    if muted ~= nil and muted ~= shouldMute then device:setMuted(shouldMute) end
  end

  self:showVolume(level)
  return self
end

-- Spoon API

--- VolumeControl:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VolumeControl object
---
--- Deliberately starts nothing. The canvas is built lazily on the first volume change.
--- Deliberately empty rather than re-initialising state: `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load, so resetting here would clear state out from under a live canvas.
function obj:init()
  return self
end

--- VolumeControl:start() -> self
--- Method
--- Enables the Spoon's hotkeys.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VolumeControl object
function obj:start()
  self.running = true
  self:setHotkeysEnabled(true)
  self.logger.i("started")
  return self
end

--- VolumeControl:stop() -> self
--- Method
--- Disables the Spoon's hotkeys and removes the readout.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VolumeControl object
---
--- Safe to call more than once. Unlike the other Spoons here, this one disables its hotkeys rather than leaving them live, since a volume key that still changed the volume would mean `stop()` had stopped nothing. The bindings survive, so `start()` brings them back; use `VolumeControl:unbindHotkeys()` to remove them outright.
function obj:stop()
  self.running = false
  self:setHotkeysEnabled(false)

  -- Cancelled, not discarded: an hs.timer.delayed cannot be removed from the run loop once made,
  -- so the object is kept and reused by the next start()
  if self.hideTimer then self.hideTimer:stop() end

  self:discardCanvas()

  self.target, self.targetAt = nil, nil
  self.warned = {}
  self.logger.i("stopped")
  return self
end

function obj:setHotkeysEnabled(state)
  for _, hotkey in ipairs(self.hotkeys) do
    -- pcall: a hotkey deleted from elsewhere would otherwise take the whole loop down
    pcall(state and hotkey.enable or hotkey.disable, hotkey)
  end
end

--- VolumeControl:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for VolumeControl.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * up - Raise the volume by `VolumeControl.increment`
---    * down - Lower the volume by `VolumeControl.increment`
---
--- Returns:
---  * The VolumeControl object
---
--- For example: `spoon.VolumeControl:bindHotkeys({ up = { { "cmd", "alt", "ctrl" }, "Up" } })`
--- Bound directly with `hs.hotkey.bind` rather than through `hs.spoons.bindHotkeysToSpec`, which wires only a `pressedfn`; each key is given the same function as its `repeatfn` too, so holding it ramps the volume instead of moving it one step.
function obj:bindHotkeys(mapping)
  self:unbindHotkeys()

  local spec = {
    up = function()
      self:step(self.increment)
    end,
    down = function()
      self:step(-self.increment)
    end,
  }

  for name, key in pairs(mapping) do
    local fn = spec[name]
    if fn then
      local hotkey = hs.hotkey.bind(key[1], key[2], fn, nil, fn)
      if hotkey then
        self.hotkeys[#self.hotkeys + 1] = hotkey
      else
        self.logger.ef("could not bind the '%s' hotkey", tostring(name))
      end
    else
      self.logger.ef("hotkey requested for undefined action '%s'", tostring(name))
    end
  end

  -- Match the running state, so binding while stopped does not quietly arm the keys
  if not self.running then self:setHotkeysEnabled(false) end

  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

--- VolumeControl:unbindHotkeys() -> self
--- Method
--- Deletes every hotkey bound by `VolumeControl:bindHotkeys()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The VolumeControl object
function obj:unbindHotkeys()
  for _, hotkey in ipairs(self.hotkeys) do
    pcall(hotkey.delete, hotkey)
  end
  self.hotkeys = {}
  self.mapping = nil
  return self
end

--- VolumeControl:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `device`, `volume`, `muted`, `target`, `targetAge`, `shown` and `hotkeys` keys
---
--- `target` is the level this Spoon last set and `targetAge` how long ago; once `targetAge` exceeds `VolumeControl.resyncAfter`, the next step re-reads `volume` from the device instead.
function obj:status()
  local device = hs.audiodevice.defaultOutputDevice()
  return {
    running = self.running,
    device = device and device:name() or nil,
    volume = device and readLevel(device) or nil,
    muted = device and device:muted() or nil,
    target = self.target,
    targetAge = self.targetAt and (hs.timer.secondsSinceEpoch() - self.targetAt) or nil,
    shown = self.shown,
    hotkeys = #self.hotkeys,
  }
end

return obj
