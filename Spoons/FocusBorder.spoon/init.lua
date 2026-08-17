--- === FocusBorder ===
---
--- Draws a red border around the focused window, hidden while that window is fullscreen.
---
--- The border occupies a band just OUTSIDE the window frame, so it never covers the window's
--- own content -- the trade-off being that it is clipped where a window sits flush against a
--- screen edge.

local obj = {}
obj.__index = obj

obj.name = "FocusBorder"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- FocusBorder.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("FocusBorder", "info")

-- Configuration

--- FocusBorder.borderWidth
--- Variable
--- Width in points of the band drawn outside the window frame. Defaults to `2`.
---
--- Baked into the canvas at build time, so assigning this does nothing to a border already on screen. Set it before `FocusBorder:start()`, or use `FocusBorder:setWidth()`, which rebuilds.
obj.borderWidth = 2

--- FocusBorder.borderColor
--- Variable
--- Border colour, as any table `hs.drawing.color` understands. Defaults to red at 90% alpha.
---
--- Carries the same caveat as `FocusBorder.borderWidth`: use `FocusBorder:setColor()` to change it on a running border.
obj.borderColor = { red = 1, green = 0, blue = 0, alpha = 0.9 }

--- FocusBorder.cornerRadius
--- Variable
--- The WINDOW's own corner rounding in points, not the border's. Defaults to `14`.
---
--- No API exposes the real figure, so this is meant to be eyeballed: too small and the border cuts across the corners, too large and it bulges past them. macOS 26 rounds them more than earlier releases.
--- The radius drawn is derived from this and `FocusBorder.borderWidth` at build time; use `FocusBorder:setCornerRadius()` to change it on a running border.
obj.cornerRadius = 14

--- FocusBorder.fullscreenSettle
--- Variable
--- Seconds to hide the border for while a fullscreen transition animates. Defaults to `0.6`.
obj.fullscreenSettle = 0.6

--- FocusBorder.spaceSettle
--- Variable
--- Seconds to wait after a Space switch before re-deriving the focused window. Defaults to `0.35`.
---
--- Immediately after a switch, `hs.spaces.focusedSpace()` still reports the old Space.
obj.spaceSettle = 0.35

--- FocusBorder.screenSettle
--- Variable
--- Seconds to debounce display reconfiguration, which fires several events. Defaults to `1.0`.
obj.screenSettle = 1.0

--- FocusBorder.appSettle
--- Variable
--- Seconds to let macOS settle on a focused window after an application change. Defaults to `0.15`.
obj.appSettle = 0.15

--- FocusBorder.startRetry
--- Variable
--- Seconds after `start()` at which the focused window is re-derived once. Defaults to `1.0`.
---
--- `start()` runs while the config is still loading, when the accessibility bridge is least responsive. This retry keeps a cold start from leaving the border stuck until the next app switch.
obj.startRetry = 1.0

--- FocusBorder.fullTolerance
--- Variable
--- Points; a window this close to the whole display on every edge counts as fullscreen. Defaults to `2`.
obj.fullTolerance = 2

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.borderCanvas = nil
obj.shown = false -- our own record; show() is makeKeyAndOrderFront, not free to repeat
obj.lastRect = nil -- last canvas rect, so a pure move can skip the resize path
obj.focusFilter = nil
obj.axWatcher = nil -- exactly one, always on the currently focused window
obj.trackedId = nil -- window id axWatcher is attached to; the id is the identity, not the handle
obj.trackedWin = nil
obj.appAxWatcher = nil -- exactly one, on the application owning the focused window
obj.appAxPid = nil -- pid appAxWatcher is attached to; the pid is the identity, not the handle
obj.wasFullScreen = false -- last known state, so a transition can be told from a plain resize
obj.suppressUntil = 0 -- redraws are ignored until this time (fullscreen animation)
obj.appWatcher = nil
obj.spaceWatcher = nil
obj.screenWatcher = nil
obj.screenTimer = nil
obj.spaceTimer = nil
obj.settleTimer = nil
obj.appTimer = nil
obj.startTimer = nil
obj.onFocusEvent = nil -- kept so unsubscribe() can name the exact callback
obj.onUnfocusEvent = nil
obj.enabled = true
obj.running = false
obj.warned = {}

local AX = hs.uielement.watcher

-- Small helpers

-- Stateless, so a plain local rather than a method
local function now()
  return hs.timer.secondsSinceEpoch()
end

-- Log a given message only once, so a broken system API cannot spam the console
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- Restart a settle timer; the cancel is load-bearing, or a burst queues one refresh() each
function obj:debounce(name, delay, fn)
  local pending = self[name]
  if pending then pending:stop() end
  self[name] = hs.timer.doAfter(delay, function()
    self[name] = nil
    fn()
  end)
end

-- Re-resolve the tracked window. hs.window handles go stale; the id is the identity
function obj:resolveTracked()
  if not self.trackedId then return nil end
  if self.trackedWin then
    local ok, id = pcall(self.trackedWin.id, self.trackedWin)
    if ok and id == self.trackedId then return self.trackedWin end
  end
  local w = hs.window.get(self.trackedId)
  self.trackedWin = w
  return w
end

-- hs.spaces is experimental, so this fails OPEN: a stray border beats disabling the Spoon
function obj:isOnCurrentSpace(win)
  if not (hs.spaces and hs.spaces.windowSpaces) then return true end
  local ok, spaces = pcall(hs.spaces.windowSpaces, win)
  if not ok or type(spaces) ~= "table" then
    self:warnOnce("spaces", "hs.spaces.windowSpaces unavailable (%s); assuming current space", tostring(spaces))
    return true
  end
  local okCur, current = pcall(hs.spaces.focusedSpace)
  if not okCur or not current then return true end
  return hs.fnutils.contains(spaces, current)
end

-- Native fullscreen only, hence fullFrame(); the frame test catches the zoom animation, where isFullScreen() still says false
function obj:isFullScreen(win, frame)
  local okFS, fs = pcall(win.isFullScreen, win)
  if okFS and fs then return true end

  local f = frame
  if not f then
    local okF
    okF, f = pcall(win.frame, win)
    if not okF or not f then return false end
  end
  -- find(f), not win:screen(), which is screen.find(self:frame()) -- one AX call cheaper
  local okS, screen = pcall(hs.screen.find, f)
  if not okS or not screen then return false end
  local okB, full = pcall(screen.fullFrame, screen)
  if not okB or not full then return false end

  local t = self.fullTolerance
  return math.abs(f.x - full.x) <= t
    and math.abs(f.y - full.y) <= t
    and math.abs(f.w - full.w) <= t
    and math.abs(f.h - full.h) <= t
end

-- Every reason the border should be absent. `fs` is a boolean, so "supplied" tests `== nil`
function obj:shouldShowBorder(win, frame, fs)
  if not self.enabled or not win then return false end
  -- isVisible() is `not isHidden and not isMinimized`, so no isMinimized() call follows it
  local okV, visible = pcall(win.isVisible, win)
  if not okV or not visible then return false end
  if fs == nil then fs = self:isFullScreen(win, frame) end
  if fs then return false end
  if not self:isOnCurrentSpace(win) then return false end
  return true
end

-- Drawing

-- Built once, then only moved: recreating it per focus change would flicker
function obj:ensureCanvas()
  if self.borderCanvas then return self.borderCanvas end

  local ok, canvas = pcall(hs.canvas.new, { x = 0, y = 0, w = 1, h = 1 })
  if not ok or not canvas then
    self:warnOnce("canvas", "could not create the border canvas: %s", tostring(canvas))
    return nil
  end

  -- The path runs borderWidth/2 outside the window, so its corners are that much rounder
  local pathRadius = self.cornerRadius + self.borderWidth / 2

  canvas:appendElements({
    type = "rectangle",
    -- "stroke", never "strokeAndFill": a fill would paint over the window it is framing
    action = "stroke",
    strokeColor = self.borderColor,
    strokeWidth = self.borderWidth,
    -- Radii depend only on config, so they are set here rather than on redraw()'s hot path
    roundedRectRadii = { xRadius = pathRadius, yRadius = pathRadius },
    frame = { x = 0, y = 0, w = 1, h = 1 }, -- placeholder; redraw() sets the real geometry
  })

  -- Mandatory: a canvas is born at screen-saver level and would paint across the menu bar. No level solves fullscreen, which wins by owning its Space
  canvas:level(hs.canvas.windowLevels.floating)

  -- Never own a Space, and hide under Exposé. ("stationary" means the opposite: the trap.)
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "transient" })

  -- Click-through needs no code; canvasMouseEvents(), mouseCallback() or clickActivating(false) all break it, the last by changing the AXSubrole that hides this canvas from hs.window.filter

  self.borderCanvas = canvas
  return canvas
end

-- Real NSWindow calls, and a drag notifies every frame, so both are gated on `shown`
function obj:hideBorder()
  if self.borderCanvas and self.shown then
    pcall(self.borderCanvas.hide, self.borderCanvas)
    self.shown = false
  end
end

function obj:showBorder()
  if self.borderCanvas and not self.shown then
    pcall(self.borderCanvas.show, self.borderCanvas)
    self.shown = true
  end
end

-- shouldShowBorder() runs first, so redraw(nil) hides without ever touching a window
function obj:redraw(win, frame, fs)
  if now() < self.suppressUntil then return end
  if not self:shouldShowBorder(win, frame, fs) then return self:hideBorder() end

  local f = frame
  if not f then
    local okF
    okF, f = pcall(win.frame, win)
    if not okF or not f then return self:hideBorder() end
  end

  local canvas = self:ensureCanvas()
  if not canvas then return end

  local w = self.borderWidth
  -- The canvas covers the window plus a w-wide band on every side
  local rect = { x = f.x - w, y = f.y - w, w = f.w + 2 * w, h = f.h + 2 * w }

  local last = self.lastRect
  if last and math.abs(last.w - rect.w) <= 0.5 and math.abs(last.h - rect.h) <= 0.5 then
    -- Move without resize, nearly every drag notification; frame() would re-render
    canvas:topLeft({ x = rect.x, y = rect.y })
  else
    canvas:frame(rect)
    -- A stroke straddles its path, so a w/2 inset puts all of it in the band, unclipped
    canvas:elementAttribute(1, "frame", { x = w / 2, y = w / 2, w = f.w + w, h = f.h + w })
  end

  self.lastRect = rect
  self:showBorder()
end

-- Tracking the focused window

-- NOT window.filter's windowMoved, debounced 500ms (WINDOWMOVED_DELAY), which would trail the window like a rubber band; nothing is coalesced here either, since delay reads as drag lag
function obj:onAXEvent(_, event, watcher, id)
  if id ~= self.trackedId then
    pcall(watcher.stop, watcher) -- stale watcher, self-heal
    return
  end

  if event == AX.elementDestroyed then
    -- Hide first, so a border around a window that no longer exists never survives a frame
    self:hideBorder()
    -- detach(), since the id guard proves this is self.axWatcher; it clears all three fields
    self:detach()
    return
  end

  -- A minimized window keeps its watcher, so unminimizing restores the border by itself
  if event == AX.windowMinimized then return self:hideBorder() end

  local win = self:resolveTracked()
  if not win then return self:hideBorder() end

  -- One frame() and one fullscreen verdict per notification: on a drag this runs every frame, and the callees would otherwise re-query five times over
  local okF, f = pcall(win.frame, win)
  if not okF then f = nil end

  local fs = self:isFullScreen(win, f)
  if fs ~= self.wasFullScreen then
    -- A transition is a burst of resizes; sit it out rather than smearing the border
    self.wasFullScreen = fs
    self.suppressUntil = now() + self.fullscreenSettle
    self:hideBorder()
    self:debounce("settleTimer", self.fullscreenSettle, function()
      self.suppressUntil = 0
      self:redraw(self:resolveTracked())
    end)
    return
  end

  self:redraw(win, f, fs)
end

function obj:detach()
  if self.axWatcher then
    pcall(self.axWatcher.stop, self.axWatcher)
    self.axWatcher = nil
  end
  self.trackedId, self.trackedWin = nil, nil
end

-- One watcher, migrating with focus: no need for the per-window fleet PinnedWindows keeps
function obj:attachTo(win, id)
  self:detach()
  self.trackedId, self.trackedWin = id, win
  self.wasFullScreen = self:isFullScreen(win)

  if type(win.newWatcher) ~= "function" then
    self:warnOnce("newWatcher", "hs.window has no newWatcher; the border will not follow drags")
    return
  end
  -- fn(element, event, watcher, userData) has no slot for self, hence the closure
  local ok, watcher = pcall(win.newWatcher, win, function(el, ev, w, wid)
    self:onAXEvent(el, ev, w, wid)
  end, id)
  if not ok or not watcher then
    self:warnOnce("axcreate", "could not create an AX watcher: %s", tostring(watcher))
    return
  end
  local started = pcall(watcher.start, watcher, {
    AX.windowMoved,
    AX.windowResized,
    AX.windowMinimized,
    AX.windowUnminimized,
    AX.elementDestroyed,
  })
  if not started then
    -- start() registers before arming, so a half-started watcher is stopped, not dropped
    pcall(watcher.stop, watcher)
    self:warnOnce("axstart", "could not start the AX watcher; the border will not follow drags")
    return
  end
  self.axWatcher = watcher
end

-- Tracking the focused APPLICATION

-- A focus switch inside one app emits only AXFocusedWindowChanged, on the *application* element, which no other source reports: window.filter registers apps during config load, when the AX bridge is coldest, and never retries
function obj:detachApp()
  if self.appAxWatcher then
    pcall(self.appAxWatcher.stop, self.appAxWatcher)
    self.appAxWatcher = nil
  end
  self.appAxPid = nil
end

function obj:onAppAXEvent(_, event, watcher, pid)
  if pid ~= self.appAxPid then
    pcall(watcher.stop, watcher) -- stale watcher, self-heal
    return
  end
  if event ~= AX.focusedWindowChanged then return end

  -- refresh(), not the element: this also fires for apps that are NOT frontmost, and following the element would move the border onto a background window
  self:refresh()
end

-- Keyed on pid, and early-out: a switch inside one app must not rebuild its own observer
function obj:attachToApp(win)
  local okA, app = pcall(win.application, win)
  if not okA or not app then return end
  local okP, pid = pcall(app.pid, app)
  if not okP or not pid then return end
  if self.appAxWatcher and pid == self.appAxPid then return end

  self:detachApp()
  -- No newWatcher pre-check here: it is inherited from hs.uielement, and pcall covers both
  local ok, watcher = pcall(app.newWatcher, app, function(el, ev, w, wpid)
    self:onAppAXEvent(el, ev, w, wpid)
  end, pid)
  if not ok or not watcher then
    self:warnOnce(
      "appaxcreate",
      "could not create an application AX watcher (%s); the border will not follow same-app focus",
      tostring(watcher)
    )
    return
  end
  -- Only this event: hs.uielement already stops a pid's watchers when the process dies
  local started = pcall(watcher.start, watcher, { AX.focusedWindowChanged })
  if not started then
    pcall(watcher.stop, watcher)
    self:warnOnce("appaxstart", "could not start the application AX watcher; the border will not follow same-app focus")
    return
  end
  self.appAxPid = pid
  self.appAxWatcher = watcher
end

-- The canvas is a window, and mistaken for the focused one it would draw around itself forever, so start() rejects Hammerspoon on the filter and every candidate is checked here
-- By pid, not by name: refresh() reads focusedWindow() directly and bypasses the filter, so this is the only guard there, and win:application() would fail open on the transient nil that NSRunningApplication returns even for a live process
function obj:isOwnWindow(win)
  local okP, pid = pcall(win.pid, win)
  return okP and pid == hs.processInfo.processID
end

function obj:onWindowFocused(win)
  if not win or self:isOwnWindow(win) then return end
  local okId, id = pcall(win.id, win)
  if not okId or not id then return end

  if id ~= self.trackedId then
    self:attachTo(win, id)
  else
    self.trackedWin = win
  end
  -- Every focus change: attachToApp() no-ops on an unchanged pid, so first signal wins
  self:attachToApp(win)
  -- A deliberate focus change cancels any suppression left over from a transition
  self.suppressUntil = 0
  self:redraw(win)
end

-- detachApp() is pointedly NOT called on the empty branch: an app can be frontmost with no focused window, and its observer is the only thing that reports the next one
function obj:refresh()
  local win = hs.window.focusedWindow()
  if win and not self:isOwnWindow(win) then
    self:onWindowFocused(win)
  else
    self:detach()
    self:hideBorder()
  end
end

-- System watchers

function obj:onScreensChanged()
  self:debounce("screenTimer", self.screenSettle, function()
    self:refresh()
  end)
end

function obj:onAppEvent(_, event)
  if event == hs.application.watcher.activated or event == hs.application.watcher.terminated then
    -- Delayed: just after an app activates or dies, focusedWindow() reports the outgoing one
    self:debounce("appTimer", self.appSettle, function()
      self:refresh()
    end)
  end
end

-- delete(), not hide(), so no NSWindow outlives a reload; clearing lastRect forces the next redraw down the full frame() path
function obj:discardCanvas()
  if self.borderCanvas then
    pcall(self.borderCanvas.delete, self.borderCanvas)
    self.borderCanvas = nil
  end
  self.shown, self.lastRect = false, nil
end

-- Colour, width and radius are baked in at build time, so changing them means a new canvas
function obj:rebuild()
  self:discardCanvas()
  if self.running then self:refresh() end
end

-- Spoon API

--- FocusBorder:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The FocusBorder object
---
--- Deliberately starts nothing. Every watcher and timer belongs to `FocusBorder:start()`, and the canvas is built lazily on the first redraw.
--- Deliberately empty rather than re-initialising state: `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load, so resetting here would clear state out from under running watchers.
function obj:init()
  return self
end

--- FocusBorder:start() -> self
--- Method
--- Starts watching for focus changes and draws the border around the focused window.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The FocusBorder object
---
--- Calling this on an already-started Spoon restarts it cleanly.
--- Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  -- A second, redundant path beside the application observer: a filter costs an AX observer per running app, but the global watcher is refcounted and shared with PinnedWindows
  local ok, filter = pcall(hs.window.filter.new)
  if not ok or not filter then
    self:warnOnce("filter", "could not create a window filter (%s); the border will not track focus", tostring(filter))
  else
    self.focusFilter = filter
    -- Guard 1 against the self-focus loop described above
    pcall(self.focusFilter.rejectApp, self.focusFilter, "Hammerspoon")
    self.onFocusEvent = function(win)
      self:onWindowFocused(win)
    end
    self.onUnfocusEvent = function()
      self:hideBorder()
    end
    self.focusFilter:subscribe(hs.window.filter.windowFocused, self.onFocusEvent)
    self.focusFilter:subscribe(hs.window.filter.windowUnfocused, self.onUnfocusEvent)
  end

  self.appWatcher = hs.application.watcher.new(function(name, event, app)
    self:onAppEvent(name, event, app)
  end)
  self.appWatcher:start()

  if hs.spaces and hs.spaces.watcher then
    self.spaceWatcher = hs.spaces.watcher.new(function()
      -- Delayed, since focusedSpace() lags a switch; debounced, so a swipe costs one refresh
      self:debounce("spaceTimer", self.spaceSettle, function()
        self:refresh()
      end)
    end)
    self.spaceWatcher:start()
  end

  self.screenWatcher = hs.screen.watcher.new(function()
    self:onScreensChanged()
  end)
  self.screenWatcher:start()

  self.running = true
  self.enabled = true

  if not hs.accessibilityState() then
    hs.alert.show("FocusBorder needs Accessibility permission")
    self.logger.w("accessibility permission not granted; nothing will work until it is")
  end

  self:refresh()

  -- start() runs during config load, when the AX bridge is least responsive; if that first refresh() came back empty nothing would arm the observer until an app switch
  self:debounce("startTimer", self.startRetry, function()
    self:refresh()
  end)

  self.logger.i("started")
  return self
end

--- FocusBorder:stop() -> self
--- Method
--- Stops the Spoon, removing the border and every watcher and timer it owns.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The FocusBorder object
---
--- Any hotkeys bound with `FocusBorder:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  self:detach()
  self:detachApp()

  if self.focusFilter then
    -- By (event, fn): by event alone would drop another module's callbacks on a shared filter
    if self.onFocusEvent then
      pcall(self.focusFilter.unsubscribe, self.focusFilter, hs.window.filter.windowFocused, self.onFocusEvent)
    end
    if self.onUnfocusEvent then
      pcall(self.focusFilter.unsubscribe, self.focusFilter, hs.window.filter.windowUnfocused, self.onUnfocusEvent)
    end
  end
  self.focusFilter, self.onFocusEvent, self.onUnfocusEvent = nil, nil, nil

  -- Field NAMES, not handles: ipairs over handles halts at the first nil and skips the rest
  for _, name in ipairs({ "appWatcher", "spaceWatcher", "screenWatcher" }) do
    local watcher = self[name]
    -- pcall: stop() reaches into a framework that may already be tearing down
    if watcher then pcall(watcher.stop, watcher) end
    self[name] = nil
  end

  for _, name in ipairs({ "screenTimer", "spaceTimer", "settleTimer", "appTimer", "startTimer" }) do
    local timer = self[name]
    if timer then timer:stop() end
    self[name] = nil
  end

  self:discardCanvas()

  self.suppressUntil = 0
  self.wasFullScreen = false
  self.warned = {}
  self.running = false
  self.logger.i("stopped")
  return self
end

--- FocusBorder:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for FocusBorder.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * toggle - Show or hide the border without tearing the watchers down
---
--- Returns:
---  * The FocusBorder object
---
--- For example: `spoon.FocusBorder:bindHotkeys({ toggle = { { "cmd", "alt", "shift" }, "B" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    toggle = hs.fnutils.partial(self.toggle, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

--- FocusBorder:toggle([state]) -> self
--- Method
--- Shows or hides the border without tearing the watchers down.
---
--- Parameters:
---  * state - An optional boolean. `true` shows the border, `false` hides it. If omitted, the current state is flipped.
---
--- Returns:
---  * The FocusBorder object
function obj:toggle(state)
  if state == nil then
    self.enabled = not self.enabled
  else
    self.enabled = state and true or false
  end
  if self.enabled then
    self:refresh()
  else
    self:hideBorder()
  end
  hs.alert.show("Focus border " .. (self.enabled and "on" or "off"), 1)
  return self
end

--- FocusBorder:setColor(color) -> self
--- Method
--- Changes the border colour and redraws.
---
--- Parameters:
---  * color - Any table `hs.drawing.color` understands, e.g. `{ red = 0, green = 0.6, blue = 1 }`. Anything that is not a table is ignored.
---
--- Returns:
---  * The FocusBorder object
function obj:setColor(color)
  if type(color) ~= "table" then return self end
  self.borderColor = color
  self:rebuild()
  return self
end

--- FocusBorder:setWidth(width) -> self
--- Method
--- Changes the border thickness and redraws.
---
--- Parameters:
---  * width - Thickness in points. Values that are not a positive number are ignored.
---
--- Returns:
---  * The FocusBorder object
function obj:setWidth(width)
  width = tonumber(width)
  if not width or width <= 0 then return self end
  self.borderWidth = width
  self:rebuild()
  return self
end

--- FocusBorder:setCornerRadius(radius) -> self
--- Method
--- Changes the assumed window corner rounding and redraws.
---
--- Parameters:
---  * radius - The window's own corner rounding in points. Values that are not a positive number are ignored.
---
--- Returns:
---  * The FocusBorder object
---
--- This is the one setting meant to be eyeballed against your macOS version, so it exists mainly to let you try values from the Console without reloading.
function obj:setCornerRadius(radius)
  radius = tonumber(radius)
  if not radius or radius <= 0 then return self end
  self.cornerRadius = radius
  self:rebuild()
  return self
end

--- FocusBorder:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `enabled`, `trackedId`, `tracking`, `trackingApp`, `appPid`, `fullScreen` and `borderWidth` keys
---
--- `trackingApp` being false while `running` is true is the signature of the same-app focus stall: the application observer is what makes a window switch inside one app visible.
function obj:status()
  return {
    running = self.running,
    enabled = self.enabled,
    trackedId = self.trackedId,
    tracking = self.axWatcher ~= nil,
    trackingApp = self.appAxWatcher ~= nil,
    appPid = self.appAxPid,
    fullScreen = self.wasFullScreen,
    borderWidth = self.borderWidth,
  }
end

return obj
