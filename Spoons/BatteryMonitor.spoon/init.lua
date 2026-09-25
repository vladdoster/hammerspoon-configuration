-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === BatteryMonitor ===
---
--- Menubar battery readout, plus spoken and on-screen alerts driven by charge thresholds.
---
--- The menubar item copies the system battery beside it. Each update draws an `hs.canvas` battery
--- with the percentage printed inside its solid body, and passes the image to `setIcon`. The fill
--- follows the charge and turns from green to orange to red as the charge drops. While the battery
--- charges, a bolt follows the digits.
---
--- Wakes on `hs.battery.watcher` rather than a stopwatch, and keeps a slow fallback timer only so the
--- time-remaining figure keeps counting down between IOKit notifications.
---
--- Each rule in `BatteryMonitor.rules` fires on the RISING EDGE of its threshold and, optionally,
--- repeats while the threshold stays crossed. A rule whose threshold is not currently met can never
--- fire, whatever its repeat cadence.

local obj = {}
obj.__index = obj

obj.name = "BatteryMonitor"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- BatteryMonitor.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("BatteryMonitor", "info")

local GLYPH_AC = utf8.char(0x1F50C)
local GLYPH_BATTERY = utf8.char(0x1F50B)
local GLYPH_CHARGE = utf8.char(0x26A1)
local GLYPH_CLOCK = utf8.char(0x1F552)
local GLYPH_HEALTH = utf8.char(0x1F340)
local GLYPH_CYCLES = utf8.char(0x1F300)

local SUPPRESS_AUDIO_KEY = "_asm.battery.suppressAudio"

-- Configuration

--- BatteryMonitor.updateInterval
--- Variable
--- Seconds between fallback updates. Defaults to `60`.
---
--- This is NOT the polling rate. `hs.battery.watcher` reports power-source and charge changes as they happen; this timer exists only because the time-remaining estimate drifts without any IOKit notification to announce it. Read before `BatteryMonitor:start()`.
obj.updateInterval = 60

--- BatteryMonitor.voice
--- Variable
--- Name of the `hs.speech` voice used for spoken alerts. Defaults to `"Zarvox"`.
obj.voice = "Zarvox"

--- BatteryMonitor.brightnessOnPowerChange
--- Variable
--- Display brightness, 0-100, applied whenever the power source changes. Defaults to `100`.
---
--- Set to `nil` to leave brightness alone.
obj.brightnessOnPowerChange = 100

--- BatteryMonitor.iconStyle
--- Variable
--- Geometry, colours and font of the drawn menubar battery. Sizes are in points.
---
--- Baked into the canvas at build time. Change it before `BatteryMonitor:start()`, or call `BatteryMonitor:rebuild()` afterwards.
---
--- The defaults come from captures of the macOS 27 battery beside this one, at four pixels to the point. The captures show a solid 23x12 body and a 1.5pt tip one point clear of it. The percentage is centred inside the body, and while the battery charges, a bolt follows the digits. So the icon has the same width whether the battery charges or not, as the system icon does.
---
--- Each grey matches the luminance of the system icon: body 116, tip 138, digits and bolt 13. Each part has its own grey because the system icon uses a different grey for each part.
---
--- None of these greys follows the system appearance. They suit a dark menubar and look heavy on a light one. The percentage is part of the image, so it does not follow the appearance either.
obj.iconStyle = {
  width = 27.5,
  height = 22,
  -- The visible edge, with 1pt of clear canvas on each side of the battery
  body = { x = 1, y = 5, w = 23, h = 12 },
  bodyRadius = 4,
  -- Renders at luminance 116, like the system body
  bodyColor = { white = 0.379 },
  -- Renders at luminance 138 like the system tip, a shade brighter than the body
  tipColor = { white = 0.465 },
  tipWidth = 1.5,
  tipHeight = 4,
  tipGap = 1,
  -- The closest match to the system digits in width, height and spacing among the system font's faces and weights
  font = { name = ".AppleSystemUIFontCondensed-Semibold", size = 10.5 },
  -- Renders at luminance 13, like the system digits and bolt
  textColor = { white = 0.047 },
  textBaseline = 3.5, -- the digits' baseline sits this far below the body's centre line
  -- Only the height: the bolt is a glyph, so its width follows from the glyph's own aspect. This is the ink height exactly
  boltHeight = 7.6,
  boltGap = 0.4, -- from the digits' advance box to the bolt's ink
}

--- BatteryMonitor.iconLevels
--- Variable
--- Charge thresholds that colour the icon's fill, evaluated in order.
---
--- Each entry is a table with `percentage` and `color`. The first entry whose `percentage` is at or above the current charge wins, so the list must run from the lowest threshold up. An entry with no `percentage` matches anything and is how the list ends.
---
--- `color` is an `hs.drawing.color` table. Note that there is no `orange` or `yellow` key: a colour is specified with `red`/`green`/`blue`, `white`, `hue`/`saturation`/`brightness`, `list`+`name` or `hex`, and any component left out defaults to `0`, so `{ orange = 1 }` is opaque black rather than an error.
obj.iconLevels = {
  { percentage = 20, color = { red = 1 } },
  { percentage = 50, color = { red = 1, green = 0.6 } },
  { color = { green = 1 } },
}

--- BatteryMonitor.iconChargingColor
--- Variable
--- Fill colour used while the battery is charging, overriding `BatteryMonitor.iconLevels`. Defaults to green.
obj.iconChargingColor = { green = 1 }

--- BatteryMonitor.suppressAudio
--- Variable
--- Whether spoken alerts are silenced. Persisted across reloads via `hs.settings`.
---
--- Toggle it from the menubar item or with `BatteryMonitor:setSuppressAudio()`; assigning to it directly changes this session only.
obj.suppressAudio = hs.settings.get(SUPPRESS_AUDIO_KEY) or false

--- BatteryMonitor.alertDuration
--- Variable
--- Seconds an alert raised by `BatteryMonitor:showAlert()` stays up before it fades. Defaults to `10`.
---
--- An alert takes no click to dismiss, so this is the only thing deciding whether a warning is still on screen by the time the machine is looked at again.
obj.alertDuration = 10

--- BatteryMonitor.rules
--- Variable
--- The alert rules, evaluated in order on every update.
---
--- Each entry is a table:
---  * onBattery - Boolean; the rule is inert unless the power source matches
---  * percentage - Charge threshold. On battery it is a floor (fires at or below); on AC a ceiling (fires at or above)
---  * timeRemaining - Minutes-remaining threshold, fires at or below. Mutually exclusive with `percentage`
---  * repeatEvery - Seconds between repeats while the threshold stays crossed, or `false` to fire once per crossing
---  * fn - Called as `fn(BatteryMonitor, snapshot)` when the rule fires
---
--- A rule is only ever consulted while its threshold is met, so `repeatEvery` cannot nag about a battery that has since recovered.
obj.rules = {
  {
    onBattery = true,
    percentage = 10,
    repeatEvery = false,
    fn = function(self)
      self:speak("LOW BATTERY", 25)
      self:showAlert("Low Battery", "Battery at 10%")
    end,
  },
  {
    onBattery = true,
    percentage = 5,
    repeatEvery = 60,
    fn = function(self)
      self:speak("PLUG ME IN NOW", 50)
      self:showAlert("Low Battery", "Connect computer to charger")
    end,
  },
  {
    onBattery = true,
    timeRemaining = 30,
    repeatEvery = 300,
    -- ruleMet() has already rejected the -1 and -2 sentinels, so this is a real minute count
    fn = function(self, snapshot)
      self:showAlert(string.format("Battery has %d minutes left...", math.floor(snapshot.timeRemaining)))
    end,
  },
  {
    onBattery = false,
    percentage = 10,
    repeatEvery = false,
    fn = function(self)
      self:speak("Feeling returning to my circuits")
    end,
  },
  {
    onBattery = false,
    percentage = 90,
    repeatEvery = false,
    fn = function(self)
      self:speak("I'm feeling [[inpt PHON; rate 80]]+mUXC[[inpt TEXT; rset 0]] better [[emph +]]now")
    end,
  },
}

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.menubarItem = nil
obj.batteryWatcher = nil
obj.updateTimer = nil
obj.synthesizer = nil -- held for the duration of an utterance; a collected synthesizer stops mid-word
obj.ruleState = {} -- per rule: { met = boolean, lastFired = number }
obj.currentSource = nil -- last seen power source, so a transition can be told from a plain update
obj.iconCanvas = nil -- built once and only re-textured; rebuilding per update would allocate an NSView each time
obj.iconKey = nil -- last drawn state, so an unchanged update costs neither a raster nor an AppKit write
obj.running = false
obj.warned = {}

-- Small helpers

-- Log a given message only once, so a broken system API cannot spam the console
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- Returns true, false, or nil for a rule that tests nothing the snapshot can answer
local function ruleMet(rule, snapshot)
  if rule.percentage then
    if not snapshot.percentage then return false end
    if rule.onBattery then return snapshot.percentage <= rule.percentage end
    return snapshot.percentage >= rule.percentage
  end
  if rule.timeRemaining then
    -- nil, -1 ("still calculating") and -2 ("unlimited, on AC") are not minute counts
    if not snapshot.timeRemaining or snapshot.timeRemaining <= 0 then return false end
    return snapshot.timeRemaining <= rule.timeRemaining
  end
  return nil
end

-- Reading the battery

-- One pass per update: every hs.battery accessor takes its own IOKit snapshot internally, and percentage() takes two, so each reading here is a real round trip
function obj:snapshot()
  local source = hs.battery.powerSource() or "no battery"
  local onBattery = source == "Battery Power"
  local snapshot = { source = source, onBattery = onBattery, percentage = hs.battery.percentage() }
  -- Its own round trip, and the reason the icon can tell a topped-up charger from a charging one: on AC at 100% this goes false while the source stays "AC Power"
  snapshot.charging = hs.battery.isCharging() and true or false
  -- Only the figure the current source can produce; the other one is a sentinel either way
  if onBattery then
    snapshot.timeRemaining = hs.battery.timeRemaining()
  else
    snapshot.timeToFull = hs.battery.timeToFullCharge()
  end
  return snapshot
end

-- Alerting

--- BatteryMonitor:speak(text, [volume]) -> self
--- Method
--- Speaks a line through `hs.speech`, unducking and restoring the output device around it.
---
--- Parameters:
---  * text - The text to speak
---  * volume - An optional output volume, 0-100, for the duration of the utterance
---
--- Returns:
---  * The BatteryMonitor object
---
--- Does nothing while `BatteryMonitor.suppressAudio` is set. Only one utterance runs at a time; a second call cuts the first one off.
function obj:speak(text, volume)
  if self.suppressAudio then return self end

  local audio = hs.audiodevice.defaultOutputDevice()
  local priorVolume, priorMuted
  if audio then
    -- Some devices report neither a volume nor a mute state, hence the per-reading guards
    priorVolume, priorMuted = audio:volume(), audio:muted()
    if volume and priorVolume then audio:setVolume(volume) end
    if priorMuted then audio:setMuted(false) end
  end

  local ok, synthesizer = pcall(hs.speech.new, self.voice)
  if not ok or not synthesizer then
    self:warnOnce("speech", "could not create the %s voice (%s)", tostring(self.voice), tostring(synthesizer))
    return self
  end

  if self.synthesizer then pcall(self.synthesizer.stop, self.synthesizer) end
  self.synthesizer = synthesizer

  synthesizer:setCallback(function(_, why)
    if why ~= "didFinish" then return end
    if audio then
      if priorVolume then audio:setVolume(priorVolume) end
      if priorMuted then audio:setMuted(true) end
    end
    if self.synthesizer == synthesizer then self.synthesizer = nil end
  end)
  synthesizer:speak(text)
  return self
end

--- BatteryMonitor:showAlert(message[, informativeText]) -> self
--- Method
--- Shows a transient on-screen alert that fades out on its own.
---
--- Parameters:
---  * message - The headline of the alert
---  * informativeText - Optional body text, shown on a second line beneath the headline
---
--- Returns:
---  * The BatteryMonitor object
---
--- Stays up for `BatteryMonitor.alertDuration` seconds. Deliberately `hs.alert` and not `hs.dialog.alert`, which is a trade: a dialog waits to be acknowledged, but it waits forever, and nothing acknowledges it on the unattended machine these warnings are for. Under `repeatEvery` it also stacked a fresh panel every cycle.
function obj:showAlert(message, informativeText)
  -- hs.alert falls back to hs.screen.mainScreen() and then indexes it unguarded, so a machine with no active display throws rather than going quiet
  local screen = hs.screen.mainScreen()
  if not screen then
    self:warnOnce("screen", "no screen to raise an alert on")
    return self
  end
  hs.alert.show(informativeText and (message .. "\n" .. informativeText) or message, screen, self.alertDuration)
  return self
end

-- The menubar item

-- The indices of the elements updateMenubar() changes, in the order ensureCanvas() appends them. The other elements do not change after the build
local FILL, TEXT, BOLT = 3, 5, 6

-- U+1002E6 is the system's own `bolt.fill` glyph in the SF Symbols private use area, and CoreText takes it from SF Pro. A traced polygon cannot match its rounded corners and slightly bowed edges
-- Not U+26A1: that character renders as a colour emoji and ignores the text colour, so it would show a yellow bolt beside dark digits
local BOLT_GLYPH = utf8.char(0x1002E6)

-- The glyph's ink within its text box as ratios of the font size, measured at 96pt, so code can turn a target ink rectangle into a font size and a frame
-- Except GLYPH_INK_Y, measured at the 6.95pt that boltHeight 7.6 gives: SF Pro sets symbols lower at text sizes, and this value puts the baseline on a whole pixel
local GLYPH_INK_W, GLYPH_INK_H = 0.69271, 1.09375
local GLYPH_INK_X, GLYPH_INK_Y = 0.13542, 0.132
local GLYPH_BOX_W, GLYPH_BOX_H = 0.96143, 1.17708

-- Font size and frame that put the glyph's ink at inkX, centred vertically on the body and exactly boltHeight tall
local function boltLayout(style, inkX)
  local body = style.body
  local size = style.boltHeight / GLYPH_INK_H
  local inkY = body.y + body.h / 2 - style.boltHeight / 2
  return size,
    {
      x = inkX - GLYPH_INK_X * size,
      y = inkY - GLYPH_INK_Y * size,
      w = GLYPH_BOX_W * size,
      h = GLYPH_BOX_H * size,
    }
end

-- The ink width, which follows from the glyph's own aspect
local function boltInkWidth(style)
  return style.boltHeight * GLYPH_INK_W / GLYPH_INK_H
end

-- Built once, then only re-textured: an update runs on every IOKit notification, and rebuilding would allocate an NSView each time
function obj:ensureCanvas()
  if self.iconCanvas then return self.iconCanvas end

  local style = self.iconStyle
  local body = style.body

  local ok, canvas = pcall(hs.canvas.new, { x = 0, y = 0, w = style.width, h = style.height })
  if not ok or not canvas then
    self:warnOnce("canvas", "could not create the icon canvas: %s", tostring(canvas))
    return nil
  end

  local bodyRadii = { xRadius = style.bodyRadius, yRadius = style.bodyRadius }
  local tip = {
    x = body.x + body.w + style.tipGap,
    y = body.y + (body.h - style.tipHeight) / 2,
    w = style.tipWidth,
    h = style.tipHeight,
  }
  -- Only the size is final here, because updateMenubar() moves the frame to follow the digits
  local boltSize, boltFrame = boltLayout(style, body.x)

  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = style.bodyColor,
    roundedRectRadii = bodyRadii,
    frame = body,
  }, {
    -- The fill has square corners, so this clip rounds its left end to match the body
    type = "rectangle",
    action = "clip",
    roundedRectRadii = bodyRadii,
    frame = body,
  }, {
    type = "rectangle",
    action = "fill",
    fillColor = self.iconChargingColor,
    frame = { x = body.x, y = body.y, w = 0, h = body.h },
  }, {
    type = "resetClip",
  }, {
    type = "text",
    action = "skip",
    text = "",
    frame = body,
  }, {
    type = "text",
    action = "skip",
    text = hs.styledtext.new(BOLT_GLYPH, {
      font = { name = hs.styledtext.defaultFonts.menuBar.name, size = boltSize },
      color = style.textColor,
    }),
    frame = boltFrame,
  }, {
    -- The tip is flat against the body and round away from it: the right half of an oval twice its width
    type = "rectangle",
    action = "clip",
    frame = tip,
  }, {
    type = "oval",
    action = "fill",
    fillColor = style.tipColor,
    frame = { x = tip.x - tip.w, y = tip.y, w = tip.w * 2, h = tip.h },
  }, {
    type = "resetClip",
  })

  self.iconCanvas = canvas
  return canvas
end

-- delete(), not hide(), so no NSWindow outlives a reload
function obj:discardCanvas()
  if self.iconCanvas then
    pcall(self.iconCanvas.delete, self.iconCanvas)
    self.iconCanvas = nil
  end
  self.iconKey = nil
end

-- First entry at or above the charge wins, so iconLevels reads low to high and ends with a thresholdless catch-all
function obj:fillColorFor(percentage, charging)
  if charging then return self.iconChargingColor end
  for _, level in ipairs(self.iconLevels) do
    if not level.percentage or percentage <= level.percentage then return level.color end
  end
  return self.iconStyle.textColor
end

function obj:updateMenubar(snapshot)
  if not self.menubarItem then return end

  local hasBattery = snapshot.source ~= "no battery" and snapshot.percentage ~= nil
  -- floor(), since percentage() is a ratio of capacities and %d rejects a fractional float
  local percentage = hasBattery and math.floor(snapshot.percentage) or nil
  local key = string.format("%s/%s/%s", tostring(percentage), tostring(snapshot.charging), snapshot.source)

  -- Without this check, each update costs a raster and an AppKit write, and on an idle machine most updates change nothing
  if key == self.iconKey then return end

  local canvas = self:ensureCanvas()
  if not canvas then return end

  local style = self.iconStyle
  local body = style.body
  -- Rounded to the half point, as the system snaps its fill to whole pixels: 22% of 23pt fills 5pt, not 5.06
  local width = hasBattery and math.floor(body.w * percentage / 100 * 2 + 0.5) / 2 or 0

  canvas[FILL].action = width > 0 and "fill" or "skip"
  if width > 0 then
    canvas[FILL].fillColor = self:fillColorFor(percentage, snapshot.charging)
    canvas[FILL].frame.w = width
  end

  local charging = hasBattery and snapshot.charging
  canvas[TEXT].action = hasBattery and "fill" or "skip"
  canvas[BOLT].action = charging and "fill" or "skip"
  if hasBattery then
    local text = hs.styledtext.new(string.format("%d", percentage), { font = style.font, color = style.textColor })
    local size = canvas:minimumTextSize(text)
    -- Centred as the system centres them: the digits' advance box plus the bolt's ink, without the gap between them
    local groupWidth = size.w + (charging and boltInkWidth(style) or 0)
    local x = body.x + (body.w - groupWidth) / 2
    local ascender = hs.styledtext.fontInfo(style.font).ascender
    canvas[TEXT].text = text
    canvas[TEXT].frame = { x = x, y = body.y + body.h / 2 + style.textBaseline - ascender, w = size.w, h = size.h }
    if charging then
      local _, boltFrame = boltLayout(style, x + size.w + style.boltGap)
      canvas[BOLT].frame = boltFrame
    end
  end

  -- `false`, or AppKit takes the image as a template mask and throws away every colour in it
  self.menubarItem:setIcon(canvas:imageFromCanvas(), false)
  self.iconKey = key
end

-- The readings behind "Raw Battery Data...", gathered WITHOUT hs.battery.getAll(), whose privateBluetoothBatteryInfo() and otherBatteryInfo() block the main thread on a semaphore when the Bluetooth daemon does not answer -- a native deadlock that pcall cannot catch
local SAFE_BATTERY_KEYS = {
  "adapterSerialNumber",
  "amperage",
  "batterySerialNumber",
  "batteryType",
  "capacity",
  "cycles",
  "designCapacity",
  "health",
  "healthCondition",
  "isCharged",
  "isCharging",
  "isFinishingCharge",
  "maxCapacity",
  "name",
  "percentage",
  "powerSource",
  "powerSourceType",
  "timeRemaining",
  "timeToFullCharge",
  "voltage",
  "warningLevel",
  "watts",
}

local function safeBatteryData()
  local data = {}
  for _, key in ipairs(SAFE_BATTERY_KEYS) do
    local fn = hs.battery[key]
    -- Per-key pcall, so one unavailable IOKit reading costs its own row, not the submenu
    if type(fn) == "function" then
      local ok, value = pcall(fn)
      data[key] = (ok and value ~= nil) and value or "n/a"
    end
  end
  return data
end

-- Keys are stringified and sorted as strings: styledtext.new() throws on a number, and sortByKeys' comparator throws on mixed number/string keys
local rawBatteryData
rawBatteryData = function(tbl)
  local data = {}
  local rawStyle = { font = { name = "Menlo", size = 10 }, color = { blue = 0.5, green = 0.5, red = 0.5 } }
  local byName = function(a, b)
    return tostring(a) < tostring(b)
  end
  for key, value in hs.fnutils.sortByKeys(tbl, byName) do
    local label = tostring(key)
    if type(value) ~= "table" then
      table.insert(data, { title = hs.styledtext.new(label .. " = " .. tostring(value), rawStyle), disabled = true })
    elseif next(value) then
      table.insert(data, { title = hs.styledtext.new(label, rawStyle), menu = rawBatteryData(value), disabled = false })
    end
  end
  return data
end

-- Private API, and only reachable from the menu, so a failure degrades one row rather than the icon
local function chargingState()
  if hs.battery.isCharged() then return "Fully Charged" end
  if hs.battery.isCharging() then return hs.battery.isFinishingCharge() and "Finishing Charge" or "Charging" end
  local ok, sources = pcall(hs.battery._powerSources)
  if ok and sources and sources[1] and sources[1]["Optimized Battery Charging Engaged"] then return "On Hold" end
  return "On Battery"
end

-- Minutes as h:mm, or the reason there is no figure to show
local function formatMinutes(value)
  if not value then return "n/a" end
  if value < 0 then return "...calculating..." end
  return string.format("%2d:%02d", math.floor(value / 60), value % 60)
end

function obj:buildMenu()
  local snapshot = self:snapshot()
  local menu = {}

  if snapshot.source == "no battery" then
    table.insert(menu, { title = GLYPH_AC .. "  No Battery" })
  else
    local glyph = (snapshot.source == "AC Power") and GLYPH_AC or GLYPH_BATTERY
    table.insert(menu, { title = glyph .. "  " .. chargingState() })
  end
  table.insert(menu, { title = "-" })

  -- The fallback replaces the whole formatted value: string.format('%.2f%%', 'n/a') throws
  table.insert(menu, {
    title = GLYPH_CHARGE
      .. "  Current Charge: "
      .. (snapshot.percentage and string.format("%.2f%%", snapshot.percentage) or "n/a"),
  })

  if snapshot.onBattery then
    table.insert(menu, { title = GLYPH_CLOCK .. "  Time Remaining: " .. formatMinutes(snapshot.timeRemaining) })
  else
    table.insert(menu, { title = GLYPH_CLOCK .. "  Time to Full: " .. formatMinutes(snapshot.timeToFull) })
  end

  local maxCapacity, designCapacity = hs.battery.maxCapacity(), hs.battery.designCapacity()
  table.insert(menu, {
    title = GLYPH_HEALTH
      .. "  Battery Health: "
      .. (maxCapacity and designCapacity and string.format("%.2f%%", 100 * maxCapacity / designCapacity) or "n/a"),
  })
  table.insert(menu, { title = GLYPH_CYCLES .. "  Cycles: " .. (hs.battery.cycles() or "n/a") })

  table.insert(menu, { title = "-" })
  table.insert(menu, { title = "Raw Battery Data...", menu = rawBatteryData(safeBatteryData()) })
  table.insert(menu, { title = "-" })
  table.insert(menu, {
    title = "Suppress Audio",
    checked = self.suppressAudio,
    fn = function()
      self:setSuppressAudio(not self.suppressAudio)
    end,
  })
  return menu
end

-- The rule engine

-- pcall: a rule body reaches audio, alerts and speech, and one that throws must not skip the rest
function obj:fire(index, rule, snapshot)
  self.logger.i(string.format("rule %d fired", index))
  local ok, err = pcall(rule.fn, self, snapshot)
  if not ok then self.logger.ef("rule %d failed: %s", index, tostring(err)) end
end

-- `arming` records a crossing without announcing it, for rules already true at start() or at the instant the power source changes. It is a parameter and never inferred from state, which is what let the old module confuse "suppressed" with "already fired" and nag about a battery that was fine
function obj:evaluateRules(snapshot, arming)
  local now = hs.timer.secondsSinceEpoch()

  for index, rule in ipairs(self.rules) do
    local state = self.ruleState[index]
    if not state then
      state = {}
      self.ruleState[index] = state
    end

    if rule.onBattery ~= snapshot.onBattery then
      -- The other source's rules are inert, and must not carry state across a transition
      state.met, state.lastFired = false, nil
    else
      local met = ruleMet(rule, snapshot)
      if met == nil then
        state.met = false
        self:warnOnce("rule" .. index, "rule %d tests neither percentage nor timeRemaining", index)
      elseif not met then
        -- Every firing path below is nested under `met`, so a recovered battery goes quiet
        state.met = false
      elseif not state.met then
        state.met = true
        state.lastFired = now
        if not arming then self:fire(index, rule, snapshot) end
      elseif rule.repeatEvery and (now - (state.lastFired or 0)) >= rule.repeatEvery then
        state.lastFired = now
        self:fire(index, rule, snapshot)
      end
    end
  end
end

--- BatteryMonitor:update([arming]) -> self
--- Method
--- Reads the battery once and brings the menubar title and the rules up to date.
---
--- Parameters:
---  * arming - An optional boolean. When true, rules whose threshold is already crossed are recorded as crossed without firing
---
--- Returns:
---  * The BatteryMonitor object
---
--- Called for you by the battery watcher and the fallback timer; exposed for prodding from the Console.
function obj:update(arming)
  local snapshot = self:snapshot()
  self:updateMenubar(snapshot)

  if snapshot.source == "no battery" then return self end

  if snapshot.source ~= self.currentSource then
    local previous = self.currentSource
    self.currentSource = snapshot.source
    -- Only a real transition, not the first reading: start() observes the source, it does not change it, and a reload is no reason to touch the display
    if previous then
      if self.brightnessOnPowerChange then hs.brightness.set(self.brightnessOnPowerChange) end
      -- Arm rather than fire: right after a transition the readings are still settling, and timeRemaining() in particular reports -1 for the first half-minute
      arming = true
      self.logger.i("power source is now " .. snapshot.source)
    end
  end

  self:evaluateRules(snapshot, arming)
  return self
end

-- Every entry point goes through here: a throw inside a watcher callback is otherwise invisible, and one inside a timer callback stops the timer for good
function obj:safeUpdate(arming)
  local ok, err = pcall(self.update, self, arming)
  if not ok then self.logger.ef("update failed: %s", tostring(err)) end
end

-- Spoon API

--- BatteryMonitor:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The BatteryMonitor object
---
--- Deliberately starts nothing. The menubar item, the battery watcher and the timer all belong to `BatteryMonitor:start()`.
--- Deliberately empty rather than re-initialising state: `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load, so resetting here would clear state out from under running watchers.
function obj:init()
  return self
end

--- BatteryMonitor:start() -> self
--- Method
--- Adds the menubar item and starts watching the battery.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The BatteryMonitor object
---
--- Calling this on an already-started Spoon restarts it cleanly. Rules whose threshold is already crossed at this point are recorded silently, so a reload on a nearly-flat battery does not announce itself.
function obj:start()
  if self.running then self:stop() end

  self.ruleState = {}
  self.currentSource = nil
  self.iconKey = nil

  self.menubarItem = hs.menubar.new()
  if self.menubarItem then
    -- Wrapped: hs.menubar builds this synchronously, so a throw here leaves a dead icon
    self.menubarItem:setMenu(function()
      local ok, menu = pcall(self.buildMenu, self)
      if ok then return menu end
      self.logger.ef("menu build failed: %s", tostring(menu))
      return { { title = "Battery menu failed - see console", disabled = true } }
    end)
  else
    self:warnOnce("menubar", "could not create the menubar item")
  end

  -- IOKit posts on power-source and charge changes, so this carries almost every update
  self.batteryWatcher = hs.battery.watcher.new(function()
    self:safeUpdate(false)
  end)
  self.batteryWatcher:start()

  -- Fallback only, for the time-remaining estimate, which drifts with nothing to announce it. continueOnError, so one bad reading cannot silently stop the module forever
  self.updateTimer = hs.timer.new(self.updateInterval, function()
    self:safeUpdate(false)
  end, true)
  self.updateTimer:start()

  self.running = true
  self:safeUpdate(true)

  self.logger.i("started")
  return self
end

--- BatteryMonitor:stop() -> self
--- Method
--- Removes the menubar item and every watcher and timer the Spoon owns.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The BatteryMonitor object
---
--- Safe to call more than once. Any hotkeys bound with `BatteryMonitor:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- Field NAMES, not handles: ipairs over handles halts at the first nil and skips the rest
  for _, name in ipairs({ "batteryWatcher", "updateTimer" }) do
    local handle = self[name]
    -- pcall: stop() reaches into a framework that may already be tearing down
    if handle then pcall(handle.stop, handle) end
    self[name] = nil
  end

  if self.synthesizer then
    pcall(self.synthesizer.stop, self.synthesizer)
    self.synthesizer = nil
  end

  if self.menubarItem then
    pcall(self.menubarItem.delete, self.menubarItem)
    self.menubarItem = nil
  end

  self:discardCanvas()

  self.ruleState = {}
  self.currentSource = nil
  self.warned = {}
  self.running = false
  self.logger.i("stopped")
  return self
end

--- BatteryMonitor:setSuppressAudio([state]) -> self
--- Method
--- Silences or restores spoken alerts, and remembers the choice across reloads.
---
--- Parameters:
---  * state - An optional boolean. `true` silences speech, `false` restores it. If omitted, the current setting is flipped
---
--- Returns:
---  * The BatteryMonitor object
---
--- On-screen alerts are unaffected; only speech is silenced.
function obj:setSuppressAudio(state)
  if state == nil then
    self.suppressAudio = not self.suppressAudio
  else
    self.suppressAudio = state and true or false
  end
  hs.settings.set(SUPPRESS_AUDIO_KEY, self.suppressAudio)
  if self.suppressAudio and self.synthesizer then
    pcall(self.synthesizer.stop, self.synthesizer)
    self.synthesizer = nil
  end
  self.logger.i("suppress audio " .. tostring(self.suppressAudio))
  return self
end

--- BatteryMonitor:rebuild() -> self
--- Method
--- Discards the icon canvas so the next update redraws it with the current `iconStyle`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The BatteryMonitor object
---
--- For picking geometry and colours from the Console without a reload: assign to `BatteryMonitor.iconStyle`, call this, then `BatteryMonitor:update()`.
function obj:rebuild()
  self:discardCanvas()
  return self
end

--- BatteryMonitor:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for BatteryMonitor.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * toggleAudio - Silence or restore spoken alerts
---
--- Returns:
---  * The BatteryMonitor object
---
--- For example: `spoon.BatteryMonitor:bindHotkeys({ toggleAudio = { { "cmd", "alt", "shift" }, "B" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    toggleAudio = hs.fnutils.partial(self.setSuppressAudio, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

--- BatteryMonitor:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `suppressAudio`, `source`, `charging`, `percentage`, `timeRemaining`, `timeToFull` and `rules` keys
---
--- Each entry in `rules` carries `met` and `lastFired`. A rule showing `met = false` cannot fire, whatever `lastFired` says, which is the invariant the old `ext/battery.lua` did not hold.
function obj:status()
  local snapshot = self:snapshot()
  local rules = {}
  for index, rule in ipairs(self.rules) do
    local state = self.ruleState[index] or {}
    rules[index] = {
      onBattery = rule.onBattery,
      percentage = rule.percentage,
      timeRemaining = rule.timeRemaining,
      repeatEvery = rule.repeatEvery,
      met = state.met or false,
      lastFired = state.lastFired,
    }
  end
  return {
    running = self.running,
    suppressAudio = self.suppressAudio,
    source = snapshot.source,
    charging = snapshot.charging,
    percentage = snapshot.percentage,
    timeRemaining = snapshot.timeRemaining,
    timeToFull = snapshot.timeToFull,
    rules = rules,
  }
end

return obj
