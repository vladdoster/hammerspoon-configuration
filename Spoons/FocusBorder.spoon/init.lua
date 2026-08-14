--- === FocusBorder ===
---
--- Draws a red border around the focused window, hidden while that window is fullscreen.
---
--- macOS signals keyboard focus with only a subtle title-bar tint, and borderless or
--- dark-themed apps drop even that. This Spoon draws an explicit outline instead. The
--- border occupies a band just OUTSIDE the window frame, so it never covers any of the
--- window's own content -- the trade-off being that it is clipped where a window sits
--- flush against a screen edge.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = 'FocusBorder'
obj.version = '1.0'
obj.author = 'Vladislav Doster <mvdoster@gmail.com>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

--- FocusBorder.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('FocusBorder', 'info')

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- FocusBorder.borderWidth
--- Variable
--- Width in points of the band drawn outside the window frame. Defaults to `2`.
---
--- Notes:
---  * The width is baked into the canvas when it is built, so assigning this field on its own does nothing to a border already on screen. Set it before `FocusBorder:start()`, or call `FocusBorder:setWidth()` afterwards, which rebuilds the canvas for you.
obj.borderWidth = 2

--- FocusBorder.borderColor
--- Variable
--- Border colour, as any table `hs.drawing.color` understands. Defaults to red at 90% alpha.
---
--- Notes:
---  * Carries the same caveat as `FocusBorder.borderWidth`: use `FocusBorder:setColor()` to change it on a running border.
obj.borderColor = { red = 1, green = 0, blue = 0, alpha = 0.9 }

--- FocusBorder.cornerRadius
--- Variable
--- The WINDOW's own corner rounding in points, not the border's. Defaults to `14`.
---
--- Notes:
---  * macOS 26 (Tahoe) rounds window corners noticeably more than earlier releases did, and the exact figure is not exposed by any API, so this is the one setting meant to be eyeballed: too small and the border cuts across the corners, too large and it bulges past them.
---  * The radius actually drawn is derived from this and `FocusBorder.borderWidth` when the canvas is built.
---  * Carries the same caveat as `FocusBorder.borderWidth`: use `FocusBorder:setCornerRadius()` to change it on a running border.
obj.cornerRadius = 14

--- FocusBorder.fullscreenSettle
--- Variable
--- Seconds to hide the border for while a fullscreen transition animates. Defaults to `0.6`.
obj.fullscreenSettle = 0.6

--- FocusBorder.spaceSettle
--- Variable
--- Seconds to wait after a Space switch before re-deriving the focused window. Defaults to `0.35`.
---
--- Notes:
---  * Immediately after a switch, `hs.spaces.focusedSpace()` still reports the old Space.
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
--- Notes:
---  * `start()` runs while the config is still loading, which is when the accessibility bridge is least responsive. This one retry is what keeps a cold start from leaving the border stuck until the next app switch.
obj.startRetry = 1.0

--- FocusBorder.fullTolerance
--- Variable
--- Points; a window this close to the whole display on every edge counts as fullscreen. Defaults to `2`.
obj.fullTolerance = 2

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Everything long-lived is a field on the Spoon object rather than a local inside
-- start(), because hs.canvas / hs.timer / hs.window.filter / hs.uielement.watcher are
-- userdata with a __gc that tears down the real resource. hs.loadSpoon() keeps this
-- object alive as spoon.FocusBorder for the life of the config, so nothing here is
-- collected out from under a running watcher.
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

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- Stateless, so a plain local rather than a method.
local function now() return hs.timer.secondsSinceEpoch() end

-- Log a given message only once, so a broken system API cannot spam the console.
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- Re-resolve the tracked window. hs.window handles go stale; the id is the identity.
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

-- hs.spaces is built on private APIs and is documented as experimental. If it ever breaks
-- we fail OPEN: briefly outlining a window that is on another space is cosmetic, whereas
-- failing closed would silently disable the whole Spoon.
function obj:isOnCurrentSpace(win)
  if not (hs.spaces and hs.spaces.windowSpaces) then return true end
  local ok, spaces = pcall(hs.spaces.windowSpaces, win)
  if not ok or type(spaces) ~= 'table' then
    self:warnOnce('spaces', 'hs.spaces.windowSpaces unavailable (%s); assuming current space', tostring(spaces))
    return true
  end
  local okCur, current = pcall(hs.spaces.focusedSpace)
  if not okCur or not current then return true end
  return hs.fnutils.contains(spaces, current)
end

-- Native fullscreen only: a window merely maximised to fill the usable screen still gets a
-- border. That distinction is exactly the difference between screen:frame(), which excludes
-- the menu bar and Dock, and screen:fullFrame(), which is the whole display -- so comparing
-- against fullFrame separates the two cleanly.
--
-- The frame comparison is not just a fallback for a failed AX query. During the zoom
-- animation win:isFullScreen() still reports false while the window has already grown to
-- cover the display, and following that would smear the border across the screen. The frame
-- test flips early enough to catch the transition the AX query misses.
--
-- `frame` is an optional frame the caller has already queried. Every accessibility call
-- here is a synchronous round-trip into another process, and this runs on the drag path,
-- so a caller that already holds the frame passes it in rather than paying for it twice.
function obj:isFullScreen(win, frame)
  local okFS, fs = pcall(win.isFullScreen, win)
  if okFS and fs then return true end

  local f = frame
  if not f then
    local okF
    okF, f = pcall(win.frame, win)
    if not okF or not f then return false end
  end
  -- hs.screen.find(f), not win:screen(). window.lua defines screen() as
  -- `screen.find(self:frame())`, so calling it would throw away the frame just resolved
  -- above and issue another accessibility round-trip for the same rect. Passing f straight
  -- to find() is what screen() would have done anyway, one query cheaper.
  local okS, screen = pcall(hs.screen.find, f)
  if not okS or not screen then return false end
  local okB, full = pcall(screen.fullFrame, screen)
  if not okB or not full then return false end

  local t = self.fullTolerance
  return math.abs(f.x - full.x) <= t and math.abs(f.y - full.y) <= t and math.abs(f.w - full.w) <= t and math.abs(f.h - full.h) <= t
end

-- Every reason the border should be absent, in one place. `frame` and `fs` are both
-- optional: a caller that has already resolved the frame, or already asked whether the
-- window is fullscreen, passes them rather than paying for the query twice. `fs` is a
-- boolean, so the "was it supplied" test has to be `== nil` and not `not fs`.
function obj:shouldShowBorder(win, frame, fs)
  if not self.enabled or not win then return false end
  local okV, visible = pcall(win.isVisible, win)
  if not okV or not visible then return false end
  local okM, minimized = pcall(win.isMinimized, win)
  if okM and minimized then return false end
  if fs == nil then fs = self:isFullScreen(win, frame) end
  if fs then return false end
  if not self:isOnCurrentSpace(win) then return false end
  return true
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- The canvas is built once and thereafter only moved, shown and hidden. Recreating it on
-- every focus change would flicker and churn window-server objects for no benefit.
function obj:ensureCanvas()
  if self.borderCanvas then return self.borderCanvas end

  local ok, canvas = pcall(hs.canvas.new, { x = 0, y = 0, w = 1, h = 1 })
  if not ok or not canvas then
    self:warnOnce('canvas', 'could not create the border canvas: %s', tostring(canvas))
    return nil
  end

  -- The stroked path runs borderWidth/2 outside the window edge, so its corners have to be
  -- that much rounder than the window's own to stay concentric with them.
  local pathRadius = self.cornerRadius + self.borderWidth / 2

  canvas:appendElements({
    type = 'rectangle',
    -- "stroke", never "strokeAndFill": a fill would paint over the window it is framing.
    action = 'stroke',
    strokeColor = self.borderColor,
    strokeWidth = self.borderWidth,
    roundedRectRadii = { xRadius = pathRadius, yRadius = pathRadius },
    -- Placeholder; redraw() sets the real geometry on every reposition. The radii above do
    -- not belong there: they depend only on config, so they are set once, off the hot path.
    frame = { x = 0, y = 0, w = 1, h = 1 },
  })

  -- Setting the level is mandatory, not a nicety: a canvas is born at the screen-saver
  -- level, i.e. above absolutely everything, so leaving the default would paint a red
  -- rectangle across the menu bar. "floating" is where Cocoa puts "always keep on top"
  -- panels -- above every ordinary window, below modal panels, the Dock and the menu bar.
  --
  -- Note that no level can solve the fullscreen case. A native-fullscreen app's window
  -- sits at the *normal* level and wins only by owning its own Space, so nothing above
  -- normal stays out of its way. That is why hiding the border is implemented below
  -- rather than configured here.
  canvas:level(hs.canvas.windowLevels.floating)

  -- canJoinAllSpaces: the canvas must never own a space or get stranded on the one it
  -- happened to be created on -- when the border is visible is decided here, not by macOS.
  -- transient: hidden by Exposé, so Mission Control does not shrink a stray red rectangle
  -- into the Spaces strip. ("stationary" is the trap here: it means the opposite, "stays
  -- visible", which is right for a desktop widget and wrong for a focus indicator.)
  canvas:behaviorAsLabels({ 'canJoinAllSpaces', 'transient' })

  -- Click-through deliberately requires no code. hs.canvas windows are created with
  -- ignoresMouseEvents set, and only opting an element into mouse tracking clears it, so
  -- every click already lands on whatever is underneath. Do not "harden" that by calling
  -- canvasMouseEvents() or mouseCallback(), even temporarily while debugging -- those are
  -- what make the border start eating clicks.
  --
  -- Do NOT call clickActivating(false) either, however harmless it reads: it is documented
  -- to change the canvas's AXSubrole, and the nonstandard subrole hs.canvas normally
  -- reports is exactly the thing that stops hs.window.filter from mistaking a canvas for a
  -- Hammerspoon window. Turning it off re-arms the self-focus loop guarded against below.
  -- It only has any effect for a canvas with a click callback, and this one has none.

  self.borderCanvas = canvas
  return canvas
end

-- show() and hide() are real NSWindow operations, and a drag delivers a notification every
-- frame, so both are gated on our own record of the current state rather than being called
-- unconditionally on every redraw.
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

-- `frame` and `fs` are optional and simply forwarded. shouldShowBorder() is still
-- evaluated first, before the frame is needed, so redraw(nil) from the settle timer --
-- where resolveTracked() can hand back nil -- still short-circuits to hideBorder()
-- without touching the window.
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
  -- The canvas covers the window plus a w-wide band on every side.
  local rect = { x = f.x - w, y = f.y - w, w = f.w + 2 * w, h = f.h + 2 * w }

  local last = self.lastRect
  if last and math.abs(last.w - rect.w) <= 0.5 and math.abs(last.h - rect.h) <= 0.5 then
    -- Move without resize, which is what nearly every notification during a drag is.
    -- topLeft() only repositions the window, where frame() re-renders and would make us
    -- recompute an element frame for a size that has not changed.
    canvas:topLeft({ x = rect.x, y = rect.y })
  else
    canvas:frame(rect)
    -- A stroke straddles its path, half either side. Insetting the path by w/2 from the
    -- canvas edge therefore lands the stroke's outer edge exactly on the canvas edge and its
    -- inner edge exactly on the window edge, so the whole stroke sits in the band and not one
    -- pixel of it covers the window. It also means nothing is clipped: a canvas discards
    -- anything drawn past its own bounds, which is what would happen to the outer half of
    -- the stroke if the canvas were sized to the window instead.
    canvas:elementAttribute(1, 'frame', { x = w / 2, y = w / 2, w = f.w + w, h = f.h + w })
  end

  self.lastRect = rect
  self:showBorder()
end

--------------------------------------------------------------------------------
-- Tracking the focused window
--------------------------------------------------------------------------------

-- Geometry deliberately does NOT come from hs.window.filter's windowMoved event: that event
-- is debounced by 500ms (WINDOWMOVED_DELAY in window_filter.lua) and coalesced with
-- setNextTrigger, so it fires only half a second after the user STOPS dragging. The border
-- would trail the window like a rubber band. These raw AX notifications are undebounced.
--
-- The same debounce is why windowFullscreened / windowUnfullscreened are unused: window_filter
-- emits both from doMoved(), behind that very same timer, long after the zoom animation has
-- finished. The fullscreen state is therefore checked inline here instead.
--
-- Nor is anything coalesced on our side. PinnedWindows collapses event bursts because
-- raising windows is expensive; a redraw here is a single reposition, and any delay added to
-- it is directly visible as lag while dragging.
function obj:onAXEvent(_, event, watcher, id)
  if id ~= self.trackedId then
    pcall(watcher.stop, watcher) -- stale watcher, self-heal
    return
  end

  if event == AX.elementDestroyed then
    -- Hide before anything else: a border still drawn around a window that no longer exists
    -- is the most obviously broken thing this Spoon could produce, so it does not survive
    -- even one frame. Then drop the watcher rather than leaving it bound to a dead element;
    -- whichever window gains focus next will bring a fresh one.
    self:hideBorder()
    -- detach() rather than stopping `watcher` inline: the id guard above means we only get
    -- here for the watcher bound to the live trackedId, and attachTo() stores exactly that
    -- one as self.axWatcher -- so this is the same object, and the three tracking fields
    -- get cleared in the one place that knows they belong together.
    self:detach()
    return
  end

  -- A minimized window keeps its watcher, so unminimizing restores the border by itself.
  if event == AX.windowMinimized then return self:hideBorder() end

  local win = self:resolveTracked()
  if not win then return self:hideBorder() end

  -- One frame() query and one fullscreen verdict per notification, threaded through
  -- everything below. During a drag this handler runs on every frame, and each
  -- accessibility call is a synchronous IPC round-trip; left to re-query, isFullScreen(),
  -- shouldShowBorder() and redraw() would ask for the same frame five times over (three
  -- explicitly, twice more hidden inside win:screen(), which is itself defined as
  -- screen.find(self:frame())). nil on failure is fine -- each callee falls back to
  -- querying for itself, which is exactly the old behaviour.
  local okF, f = pcall(win.frame, win)
  if not okF then f = nil end

  local fs = self:isFullScreen(win, f)
  if fs ~= self.wasFullScreen then
    -- A fullscreen transition arrives as a burst of resizes. Sit the animation out rather
    -- than smearing the border across the screen following it, then re-evaluate once the
    -- window has settled at whichever size it ended up.
    self.wasFullScreen = fs
    self.suppressUntil = now() + self.fullscreenSettle
    self:hideBorder()
    if self.settleTimer then self.settleTimer:stop() end
    self.settleTimer = hs.timer.doAfter(self.fullscreenSettle, function()
      self.settleTimer = nil
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

-- Exactly one AX watcher exists at a time and it migrates with focus. A border only ever
-- follows one window, so there is no reason to pay for the per-window fleet that
-- PinnedWindows has to maintain.
function obj:attachTo(win, id)
  self:detach()
  self.trackedId, self.trackedWin = id, win
  self.wasFullScreen = self:isFullScreen(win)

  if type(win.newWatcher) ~= 'function' then
    self:warnOnce('newWatcher', 'hs.window has no newWatcher; the border will not follow drags')
    return
  end
  -- The AX callback signature is fixed -- fn(element, event, watcher, userData) -- with no
  -- slot for self, so the method is reached through a closure. userData still carries the
  -- window id, which is what the stale-watcher check above compares against.
  local ok, watcher = pcall(win.newWatcher, win, function(el, ev, w, wid) self:onAXEvent(el, ev, w, wid) end, id)
  if not ok or not watcher then
    self:warnOnce('axcreate', 'could not create an AX watcher: %s', tostring(watcher))
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
    -- uielement.watcher:start() registers itself before arming the AX observer, so a
    -- half-started watcher must be stopped rather than simply dropped.
    pcall(watcher.stop, watcher)
    self:warnOnce('axstart', 'could not start the AX watcher; the border will not follow drags')
    return
  end
  self.axWatcher = watcher
end

--------------------------------------------------------------------------------
-- Tracking the focused APPLICATION
--------------------------------------------------------------------------------

-- macOS has no "some window got focused" notification. Moving focus between two windows of
-- the SAME app produces exactly one signal, AXFocusedWindowChanged, and it is delivered on
-- the *application* element -- hs.uielement documents it as an application-level event that
-- "send[s] the relevant child element to the handler". No app activation happens, so
-- hs.application.watcher stays silent, and the window watcher above is bound to the window
-- being switched AWAY from, so it says nothing either.
--
-- That left hs.window.filter as the only path for a same-app switch, and it is precisely the
-- path that breaks after a reload. window_filter only re-emits the notification as its
-- windowFocused event if the app is both registered in its own table and is its current
-- global.active; registration happens in one synchronous burst over every running app the
-- moment the first filter subscribes -- i.e. during config load, when the accessibility
-- bridge is coldest -- and an app whose AX probe fails there is dropped with no retry. It is
-- re-registered on the next application-activated event, which is why the border came back
-- to life only after switching apps or leaving and re-entering the Space, and why a Space
-- holding a single app with several windows was the case that stayed broken.
--
-- Observing the notification ourselves removes that dependency: two AX observers instead of
-- window_filter's per-app fleet, and no shared state that a cold start can corrupt.
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

  -- refresh() rather than the element the notification carries. The event also fires for
  -- apps that are NOT frontmost (the docs call this out), and following the element there
  -- would move the border onto a background window; refresh() re-derives from
  -- hs.window.focusedWindow(), so such an event correctly changes nothing. It also reuses
  -- the isOwnWindow / detach / hide branch instead of duplicating it. One AX query, and
  -- nothing debounces it, so the border still moves on the same frame as the switch.
  self:refresh()
end

-- Migrates with focus like attachTo() does, keyed on pid rather than window id. The
-- early-out matters: a focus change inside one app must not tear down and rebuild the
-- observer that reported it.
function obj:attachToApp(win)
  local okA, app = pcall(win.application, win)
  if not okA or not app then return end
  local okP, pid = pcall(app.pid, app)
  if not okP or not pid then return end
  if self.appAxWatcher and pid == self.appAxPid then return end

  self:detachApp()
  -- No type(app.newWatcher)=="function" pre-check as attachTo() does for windows. newWatcher
  -- is inherited from hs.uielement rather than declared on hs.application, so probing for it
  -- reasons about a metatable chain the docs do not describe; pcall covers a missing method
  -- ("attempt to call a nil value") and a failing one alike, and says which in the log.
  local ok, watcher = pcall(app.newWatcher, app, function(el, ev, w, wpid) self:onAppAXEvent(el, ev, w, wpid) end, pid)
  if not ok or not watcher then
    self:warnOnce(
      'appaxcreate',
      'could not create an application AX watcher (%s); the border will not follow same-app focus',
      tostring(watcher)
    )
    return
  end
  -- Only the one event. elementDestroyed is deliberately absent and is not auto-added for
  -- application elements the way it is for ordinary ones; hs.uielement already stops every
  -- watcher belonging to a pid when that process terminates, so an app quitting needs no
  -- teardown here.
  local started = pcall(watcher.start, watcher, { AX.focusedWindowChanged })
  if not started then
    pcall(watcher.stop, watcher)
    self:warnOnce('appaxstart', 'could not start the application AX watcher; the border will not follow same-app focus')
    return
  end
  self.appAxPid = pid
  self.appAxWatcher = watcher
end

-- The canvas is itself a window. Were it ever taken for the focused window, the border would
-- draw around itself and each redraw would look like another focus change -- a loop painting
-- an ever-shrinking rectangle. Two independent guards, so one failing cannot revive it: the
-- filter rejects Hammerspoon outright in start(), and every candidate is checked here too.
function obj:isOwnWindow(win)
  local okA, app = pcall(win.application, win)
  if not okA or not app then return false end
  local okN, name = pcall(app.name, app)
  return okN and name == 'Hammerspoon'
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
  -- Every focus change, not just those that cross an app boundary: attachToApp() no-ops on
  -- an unchanged pid, and routing it through here means the observer is armed by whichever
  -- signal arrives first, including the initial refresh() at the end of start().
  self:attachToApp(win)
  -- A deliberate focus change cancels any suppression left over from a transition.
  self.suppressUntil = 0
  self:redraw(win)
end

-- Re-derive everything from scratch. Used after any event that can invalidate the whole
-- picture at once: a space switch, a display change, an app quitting.
--
-- detachApp() is pointedly NOT called on the empty branch. An app can be frontmost with no
-- focused window -- every window closed, or a sheet in the way -- and the application
-- observer is the only thing that will report the next window focused within it. Dropping it
-- here would recreate the very stall this Spoon exists to avoid.
function obj:refresh()
  local win = hs.window.focusedWindow()
  if win and not self:isOwnWindow(win) then
    self:onWindowFocused(win)
  else
    self:detach()
    self:hideBorder()
  end
end

--------------------------------------------------------------------------------
-- System watchers
--------------------------------------------------------------------------------

function obj:onScreensChanged()
  if self.screenTimer then self.screenTimer:stop() end
  self.screenTimer = hs.timer.doAfter(self.screenSettle, function()
    self.screenTimer = nil
    self:refresh()
  end)
end

function obj:onAppEvent(_, event)
  if event == hs.application.watcher.activated or event == hs.application.watcher.terminated then
    -- A short delay: right after an app activates or dies, focusedWindow() can still report
    -- the outgoing window, which would anchor the border to something already gone.
    if self.appTimer then self.appTimer:stop() end
    self.appTimer = hs.timer.doAfter(self.appSettle, function()
      self.appTimer = nil
      self:refresh()
    end)
  end
end

-- delete(), not hide(): no NSWindow may be left behind, because a config reload builds a
-- fresh one and nothing would be left owning the old one.
--
-- Clearing lastRect matters as much as clearing the canvas: it is what forces the next
-- redraw down the full frame() path so the replacement canvas gets its element geometry.
-- Those two always travel together, which is why dropping the canvas is one call rather
-- than something each caller open-codes.
function obj:discardCanvas()
  if self.borderCanvas then
    pcall(self.borderCanvas.delete, self.borderCanvas)
    self.borderCanvas = nil
  end
  self.shown, self.lastRect = false, nil
end

-- Colour, width and corner radius are baked into the canvas element at build time, so
-- changing any of them means throwing the canvas away and letting the next redraw build a
-- new one.
function obj:rebuild()
  self:discardCanvas()
  if self.running then self:refresh() end
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

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
--- Notes:
---  * Deliberately starts nothing. Every watcher and timer belongs to `FocusBorder:start()`, and the canvas is built lazily on the first redraw.
---  * It is also deliberately empty rather than re-initialising state. The declarations above already run on a freshly loaded object, and `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load -- so resetting anything here would clear state out from under watchers that are already running.
function obj:init() return self end

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
--- Notes:
---  * Calling this on an already-started Spoon restarts it cleanly.
---  * Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  -- Focus tracking also goes through hs.window.filter, and that is a deliberate trade
  -- rather than the only option. Creating a filter starts window_filter's global watcher,
  -- which registers an accessibility observer for every running app and every window they
  -- own. PinnedWindows only pays that on the first pin; this Spoon runs always, so it pays
  -- it for the whole session. It is kept as a second, redundant path alongside the
  -- application observer above: the filter is the boring, well-trodden route for ordinary
  -- app switches, and the global watcher is refcounted, so the cost is shared with
  -- PinnedWindows rather than doubled.
  local ok, filter = pcall(hs.window.filter.new)
  if not ok or not filter then
    self:warnOnce('filter', 'could not create a window filter (%s); the border will not track focus', tostring(filter))
  else
    self.focusFilter = filter
    -- Guard 1 against the self-focus loop described above.
    pcall(self.focusFilter.rejectApp, self.focusFilter, 'Hammerspoon')
    self.onFocusEvent = function(win) self:onWindowFocused(win) end
    self.onUnfocusEvent = function() self:hideBorder() end
    self.focusFilter:subscribe(hs.window.filter.windowFocused, self.onFocusEvent)
    self.focusFilter:subscribe(hs.window.filter.windowUnfocused, self.onUnfocusEvent)
  end

  self.appWatcher = hs.application.watcher.new(function(name, event, app) self:onAppEvent(name, event, app) end)
  self.appWatcher:start()

  if hs.spaces and hs.spaces.watcher then
    self.spaceWatcher = hs.spaces.watcher.new(function()
      -- Delay: immediately after a switch, focusedSpace() still reports the old space.
      -- Kept in a handle and restarted rather than fired and forgotten: swiping through
      -- several Spaces inside spaceSettle would otherwise queue one independent timer per
      -- Space, every one of them running a full refresh(). Only the last switch matters.
      if self.spaceTimer then self.spaceTimer:stop() end
      self.spaceTimer = hs.timer.doAfter(self.spaceSettle, function()
        self.spaceTimer = nil
        self:refresh()
      end)
    end)
    self.spaceWatcher:start()
  end

  self.screenWatcher = hs.screen.watcher.new(function() self:onScreensChanged() end)
  self.screenWatcher:start()

  self.running = true
  self.enabled = true

  if not hs.accessibilityState() then
    hs.alert.show('FocusBorder needs Accessibility permission')
    self.logger.w('accessibility permission not granted; nothing will work until it is')
  end

  self:refresh()

  -- start() runs while the config is still being loaded, which is exactly when the
  -- accessibility bridge is least responsive. If that first refresh() came back empty --
  -- focusedWindow() nil, or app:newWatcher() refused -- nothing else would arm the
  -- application observer until the user happened to switch apps, which is the stall this
  -- Spoon exists to avoid. One re-derive once the machine has settled closes that window.
  -- refresh() is idempotent: an unchanged window id re-attaches nothing and attachToApp()
  -- no-ops on an unchanged pid, so this costs nothing when the first attempt worked.
  if self.startTimer then self.startTimer:stop() end
  self.startTimer = hs.timer.doAfter(self.startRetry, function()
    self.startTimer = nil
    self:refresh()
  end)

  self.logger.i('started')
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
--- Notes:
---  * Any hotkeys bound with `FocusBorder:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  self:detach()
  self:detachApp()

  if self.focusFilter then
    -- Unsubscribe by (event, fn): unsubscribing by event alone would also remove callbacks
    -- any other module registered on a shared filter.
    if self.onFocusEvent then pcall(self.focusFilter.unsubscribe, self.focusFilter, hs.window.filter.windowFocused, self.onFocusEvent) end
    if self.onUnfocusEvent then
      pcall(self.focusFilter.unsubscribe, self.focusFilter, hs.window.filter.windowUnfocused, self.onUnfocusEvent)
    end
  end
  self.focusFilter, self.onFocusEvent, self.onUnfocusEvent = nil, nil, nil

  -- Stopped one by one rather than by iterating a table literal. ipairs() halts at the
  -- first nil hole, so `ipairs({ appWatcher, spaceWatcher, screenWatcher })` would silently
  -- skip the screen watcher on any machine where hs.spaces is missing -- and the timers
  -- below are nil most of the time, which would make such a loop almost a no-op.
  if self.appWatcher then
    pcall(self.appWatcher.stop, self.appWatcher)
    self.appWatcher = nil
  end
  if self.spaceWatcher then
    pcall(self.spaceWatcher.stop, self.spaceWatcher)
    self.spaceWatcher = nil
  end
  if self.screenWatcher then
    pcall(self.screenWatcher.stop, self.screenWatcher)
    self.screenWatcher = nil
  end

  if self.screenTimer then
    self.screenTimer:stop()
    self.screenTimer = nil
  end
  if self.spaceTimer then
    self.spaceTimer:stop()
    self.spaceTimer = nil
  end
  if self.settleTimer then
    self.settleTimer:stop()
    self.settleTimer = nil
  end
  if self.appTimer then
    self.appTimer:stop()
    self.appTimer = nil
  end
  if self.startTimer then
    self.startTimer:stop()
    self.startTimer = nil
  end

  self:discardCanvas()

  self.suppressUntil = 0
  self.wasFullScreen = false
  self.warned = {}
  self.running = false
  self.logger.i('stopped')
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
--- Notes:
---  * For example: `spoon.FocusBorder:bindHotkeys({ toggle = { { "cmd", "alt", "shift" }, "B" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    toggle = hs.fnutils.partial(self.toggle, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
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
  hs.alert.show('Focus border ' .. (self.enabled and 'on' or 'off'), 1)
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
  if type(color) ~= 'table' then return self end
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
--- Notes:
---  * This is the one setting meant to be eyeballed against your macOS version, so it exists mainly to let you try values from the Console without reloading.
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
--- Notes:
---  * `trackingApp` being false while `running` is true is the signature of the same-app focus stall: the application observer is what makes a window switch inside one app visible.
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
