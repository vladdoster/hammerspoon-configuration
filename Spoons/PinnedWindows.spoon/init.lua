--- === PinnedWindows ===
---
--- A menubar item for pinning windows: always on top, locked size, locked position.
---
--- macOS gives no public API for one app to change another app's window level, so
--- "always on top" here is emulated: whenever something else comes forward, the pinned
--- window is re-raised. Size and position are held by snapshotting the frame and
--- restoring it whenever the window is moved or resized.
---
--- Where an app offers its own "always on top" menu item, that is used instead -- it is
--- implemented in-process, where macOS does allow it, and so is a real fix rather than
--- an emulation. See `PinnedWindows.floatHints`.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = 'PinnedWindows'
obj.version = '1.0'
obj.author = 't <t@t>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

--- PinnedWindows.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('PinnedWindows', 'info')

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- PinnedWindows.pollInterval
--- Variable
--- Seconds between safety-net enforcement passes. Defaults to `1.0`.
---
--- Notes:
---  * The poll only runs while something is pinned. An idle repeating timer defeats CPU idle states, which matters on a laptop.
obj.pollInterval = 1.0

--- PinnedWindows.raiseCoalesce
--- Variable
--- Seconds over which a burst of focus events is collapsed into one raise pass. Defaults to `0.06`.
obj.raiseCoalesce = 0.06

--- PinnedWindows.raiseMinGap
--- Variable
--- Minimum seconds between `raise()` calls for any one window. Defaults to `0.20`.
obj.raiseMinGap = 0.20

--- PinnedWindows.frameTolerance
--- Variable
--- Points; a frame closer than this to the target counts as "already correct". Defaults to `2`.
obj.frameTolerance = 2

--- PinnedWindows.suppressEcho
--- Variable
--- Seconds for which the accessibility echo of our own `setFrame` is ignored. Defaults to `0.05`.
obj.suppressEcho = 0.05

--- PinnedWindows.failLimit
--- Variable
--- Consecutive failed frame restores before the Spoon stops fighting the window. Defaults to `5`.
---
--- Notes:
---  * Some windows simply cannot reach the requested frame -- Terminal snaps to a character grid, fixed dialogs refuse outright. On hitting this limit the current frame is adopted as the new target instead of spinning forever.
obj.failLimit = 5

--- PinnedWindows.failWindow
--- Variable
--- Seconds; failures spread wider apart than this reset the failure streak. Defaults to `2.0`.
obj.failWindow = 2.0

--- PinnedWindows.spaceSettle
--- Variable
--- Seconds to let a Space-switch animation finish before re-enforcing. Defaults to `0.35`.
obj.spaceSettle = 0.35

--- PinnedWindows.screenSettle
--- Variable
--- Seconds to debounce display reconfiguration, which fires several events. Defaults to `1.0`.
obj.screenSettle = 1.0

--- PinnedWindows.titleMax
--- Variable
--- Maximum length of a window title in the menu before it is middle-ellipsised. Defaults to `45`.
obj.titleMax = 45

--- PinnedWindows.maxWindowsPerApp
--- Variable
--- Cap on how many windows one app contributes to its submenu. Defaults to `20`.
obj.maxWindowsPerApp = 20

--- PinnedWindows.floatHints
--- Variable
--- Lower-case substrings matched against menu item titles when hunting for an app's own "always on top" toggle.
---
--- Notes:
---  * Ordered most specific first, so "Always on Top" wins over a bare "on top" match.
---  * Every hint must name a *toggle* that the app keeps set. A one-shot action such as Window > "Bring All to Front" must never appear here: it is present in nearly every Cocoa app, so as a low-ranked hint it would match almost everywhere no real toggle exists, report windows as floating when nothing is, and yank every window of the app forward again on unpin.
---  * Extend this list to teach the Spoon about an app whose float menu item is worded differently, e.g. `table.insert(spoon.PinnedWindows.floatHints, 1, "pin window")`.
obj.floatHints = {
  'always on top',
  'float on top',
  'keep on top',
  'stay on top',
  'always in front',
  'float above',
  'always visible',
  'on top',
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Everything long-lived is a field on the Spoon object rather than a local inside
-- start(), because hs.menubar / hs.timer / hs.window.filter / hs.uielement.watcher are
-- userdata with a __gc that tears down the real resource. hs.loadSpoon() keeps this
-- object alive as spoon.PinnedWindows for the life of the config, so nothing here is
-- collected out from under a running watcher.
obj.pinned = {} -- [windowId] = entry
obj.pinnedCount = 0
obj.pinOrder = 0
obj.running = false

obj.menubarItem = nil
obj.focusFilter = nil
obj.pollTimer = nil
obj.raiseTimer = nil
obj.appWatcher = nil
obj.spaceWatcher = nil
obj.screenWatcher = nil
obj.screenTimer = nil
obj.spaceTimer = nil
obj.onFocusEvent = nil -- kept so unsubscribe() can name the exact callback
obj.lastAccessibilityState = nil -- last value seen by the poll; nil forces one first pass
obj.warned = {}

-- Counters, so diagnose() can tell "the events never arrived" apart from
-- "the events arrived, we called raise(), and macOS ignored us".
--
-- Built by a function rather than written as a literal in each place a zeroed set is
-- needed: adding a counter is the whole point of this table, and a literal repeated at the
-- declaration and in resetStats() means a new counter can be added to one and missed in the
-- other, leaving `nil + 1` waiting at whichever increment site runs first.
local function newStats() return { focusEvents = 0, appActivations = 0, raiseCalls = 0, frameRestores = 0 } end

obj.stats = newStats()

local AX = hs.uielement.watcher

--------------------------------------------------------------------------------
-- Stateless helpers
--------------------------------------------------------------------------------

-- These touch no Spoon state, so they stay plain locals rather than becoming methods.

-- Convert an hs.geometry rect to a plain table, so comparisons never depend on
-- hs.geometry's metatable behaviour.
local function rectOf(f) return { x = f.x, y = f.y, w = f.w, h = f.h } end

local function framesEqual(a, b, tol)
  return math.abs(a.x - b.x) <= tol and math.abs(a.y - b.y) <= tol and math.abs(a.w - b.w) <= tol and math.abs(a.h - b.h) <= tol
end

-- UTF-8 safe middle-ellipsis. Window titles are most distinguishable at both ends
-- ("Quarterly Report — Google Docs"), so trimming the middle beats trimming the tail.
local function truncate(s, n)
  if s == nil or s == '' then return '(untitled)' end
  local len = (utf8 and utf8.len and utf8.len(s)) or #s
  if not len or len <= n then return s end
  local keep = math.floor((n - 1) / 2)
  if utf8 and utf8.offset then
    local head = s:sub(1, (utf8.offset(s, keep + 1) or keep + 1) - 1)
    local tail = s:sub(utf8.offset(s, -keep) or (#s - keep + 1))
    return head .. '…' .. tail
  end
  return s:sub(1, keep) .. '…' .. s:sub(-keep)
end

-- Re-resolve an entry's window. hs.window objects can go stale; the id is the identity.
local function resolve(entry)
  local win = entry.win
  if win then
    local ok, id = pcall(win.id, win)
    if ok and id == entry.id then return win end
  end
  local w = hs.window.get(entry.id)
  if w then entry.win = w end
  return w
end

-- Only the locked axes are forced; unlocked ones follow wherever the window currently is.
local function targetFrame(entry, cur)
  return {
    x = entry.lockPos and entry.frame.x or cur.x,
    y = entry.lockPos and entry.frame.y or cur.y,
    w = entry.lockSize and entry.frame.w or cur.w,
    h = entry.lockSize and entry.frame.h or cur.h,
  }
end

-- Keep the snapshot current for axes the user is allowed to change, so turning a lock
-- back on holds the window where they just put it rather than yanking it back.
local function syncUnlocked(entry, cur)
  if not entry.lockPos then
    entry.frame.x, entry.frame.y = cur.x, cur.y
  end
  if not entry.lockSize then
    entry.frame.w, entry.frame.h = cur.w, cur.h
  end
end

-- Walk the getMenuItems() tree. Its exact nesting varies (AXChildren is sometimes a list
-- of items, sometimes a list containing one list), so this recurses structurally: a table
-- with an AXTitle is an item, anything else is a container to descend into.
local function walkMenu(node, path, visit, depth)
  if type(node) ~= 'table' or (depth or 0) > 12 then return end
  if node.AXTitle then
    local p = hs.fnutils.copy(path)
    p[#p + 1] = node.AXTitle
    visit(node, p)
    walkMenu(node.AXChildren, p, visit, (depth or 0) + 1)
  else
    for _, child in pairs(node) do
      walkMenu(child, path, visit, (depth or 0) + 1)
    end
  end
end

-- Note on the window list: hs.window.orderedWindows() is used rather than a window filter
-- because it already returns front-to-back z-order and needs no extra machinery.
local function collectWindows()
  local groups, names = {}, {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    local ok, id = pcall(w.id, w)
    if ok and id and w:isStandard() and not w:isMinimized() then
      local app = w:application()
      local name = (app and app:name()) or 'Unknown'
      if not groups[name] then
        groups[name] = {}
        names[#names + 1] = name
      end
      table.insert(groups[name], w)
    end
  end
  table.sort(names)
  return groups, names
end

-- hs.window.orderedWindows() is backed by window._orderedwinids(), the real front-to-back
-- window-server order, so it is a trustworthy probe. Hammerspoon's own windows are
-- excluded: when the diagnostic is triggered from the Console, Hammerspoon is the active
-- app and would otherwise always occupy slot 1 and mask the result.
local function zOrderExcludingHammerspoon()
  local out = {}
  for _, w in ipairs(hs.window.orderedWindows()) do
    local app = w:application()
    if not app or app:name() ~= 'Hammerspoon' then out[#out + 1] = w end
  end
  return out
end

local function zIndexOf(id, list)
  for i, w in ipairs(list) do
    if w:id() == id then return i end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Small stateful helpers
--------------------------------------------------------------------------------

-- Log a given message only once, so a broken system API cannot spam the console.
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- hs.spaces is built on private APIs and is documented as experimental. If it ever
-- breaks we fail OPEN: occasionally raising a window on another space is annoying but
-- debuggable, whereas failing closed would silently disable the whole feature.
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

-- A pinned window is only worth acting on when it is actually on screen here and now.
function obj:isActionable(entry, win)
  if entry.minimized then return false end
  if not win:isVisible() then return false end
  if win:isFullScreen() then return false end
  if not self:isOnCurrentSpace(win) then return false end
  return true
end

-- Hoisted rather than written inline at the table.sort() below, which would allocate a
-- fresh closure on every call -- and this is called several times per enforcement pass.
local function byPinOrder(a, b) return a.order < b.order end

function obj:sortedPins()
  local list = {}
  for _, entry in pairs(self.pinned) do
    list[#list + 1] = entry
  end
  table.sort(list, byPinOrder)
  return list
end

--------------------------------------------------------------------------------
-- Always on top
--------------------------------------------------------------------------------

function obj:maybeRaise(entry)
  if not entry.onTop then return end
  local now = hs.timer.secondsSinceEpoch()
  if now - entry.lastRaise < self.raiseMinGap then return end

  local win = resolve(entry)
  if not win then return self:unpin(entry.id, 'window went away') end
  if not self:isActionable(entry, win) then return end

  entry.lastRaise = now
  self.stats.raiseCalls = self.stats.raiseCalls + 1
  -- becomeMain makes this the app's main window without transferring focus, which makes
  -- the subsequent AXRaise stick more often. raise(), never focus(): AXRaise does not
  -- activate the app, so keystrokes keep going wherever the user is actually typing.
  pcall(win.becomeMain, win)
  pcall(win.raise, win)
end

function obj:raiseAll()
  -- Ascending pin order means the most recently pinned window ends up on top,
  -- which is stable and predictable (pairs() order would not be).
  for _, entry in ipairs(self:sortedPins()) do
    self:maybeRaise(entry)
  end
end

-- Everything that wants a raise goes through here. The coalescer collapses the burst of
-- events a single app switch produces, and gives macOS a moment to finish its own window
-- ordering before we reassert ours.
function obj:scheduleRaise()
  if self.pinnedCount == 0 then return end
  if self.raiseTimer then
    self.raiseTimer:setNextTrigger(self.raiseCoalesce)
  else
    self.raiseTimer = hs.timer.doAfter(self.raiseCoalesce, function()
      self.raiseTimer = nil
      self:raiseAll()
    end)
  end
end

--------------------------------------------------------------------------------
-- Size and position lock
--------------------------------------------------------------------------------

function obj:restoreFrame(entry)
  local win = resolve(entry)
  if not win then return self:unpin(entry.id, 'window went away') end

  if not (entry.lockPos or entry.lockSize) then
    local okF, f = pcall(win.frame, win)
    if okF and f then syncUnlocked(entry, rectOf(f)) end
    return
  end

  local now = hs.timer.secondsSinceEpoch()
  -- Guard 1: swallow the echo of our own setFrame cheaply, and cap how often we snap
  -- back during a live drag. This is a throughput guard, not the loop terminator.
  if now < entry.suppressUntil then return end
  if not self:isActionable(entry, win) then return end

  local okF, f = pcall(win.frame, win)
  if not okF or not f then return end
  local cur = rectOf(f)
  local target = targetFrame(entry, cur)

  -- Guard 2: the actual loop terminator. After a successful restore the frame matches
  -- the target, so the AX echo re-enters here and returns without acting. The exit
  -- condition is observed state, never a flag -- an "am I applying" boolean cannot work,
  -- because the AX notification arrives long after the flag would have been cleared.
  if framesEqual(cur, target, self.frameTolerance) then
    entry.attempts = 0
    syncUnlocked(entry, cur)
    return
  end

  entry.suppressUntil = now + self.suppressEcho
  self.stats.frameRestores = self.stats.frameRestores + 1
  if entry.attempts >= 2 then
    -- Escalate before giving up: this recovers the sticky screen-edge / Dock-edge case.
    pcall(win.setFrameWithWorkarounds, win, target, 0)
  else
    pcall(win.setFrame, win, target, 0) -- duration 0 skips the animation path entirely
  end

  -- failWindow separates one bout of resistance from the next: a failure that lands more
  -- than failWindow after the previous one is a fresh problem, not a continuation. It is
  -- the gap between consecutive failures, never a deadline the whole streak must fit
  -- inside -- enforcement polls every pollInterval, so any streak long enough to reach
  -- failLimit necessarily spans longer than failWindow and would disarm the guard below
  -- permanently.
  if entry.attempts > 0 and (now - entry.lastAttempt) > self.failWindow then entry.attempts = 0 end
  if entry.attempts == 0 then entry.firstAttempt = now end
  entry.lastAttempt = now
  entry.attempts = entry.attempts + 1

  -- Guard 3: some windows simply cannot reach the requested frame (Terminal snaps to a
  -- character grid, fixed dialogs refuse outright). Without this we would spin forever
  -- against a target that is unreachable by construction, so we adopt reality instead.
  if entry.attempts >= self.failLimit then
    local okNow, actual = pcall(win.frame, win)
    if okNow and actual then entry.frame = rectOf(actual) end
    entry.attempts = 0
    if not entry.resisted then
      entry.resisted = true
      self.logger.wf('%s: window will not take the exact frame; locking to %s instead', entry.appName, hs.inspect(entry.frame))
      hs.alert.show(entry.appName .. ': window resists exact sizing\nlocked to nearest possible')
    end
  end
end

function obj:enforceAll()
  for _, entry in ipairs(self:sortedPins()) do
    self:restoreFrame(entry)
  end
  self:raiseAll()
end

--------------------------------------------------------------------------------
-- Per-window accessibility watcher
--------------------------------------------------------------------------------

-- The geometry lock deliberately does NOT use hs.window.filter's windowMoved event:
-- that event is debounced by 500ms (WINDOWMOVED_DELAY in window_filter.lua) and coalesced
-- with setNextTrigger, so it only fires half a second after the user STOPS dragging.
-- That would be a rubber band, not a lock. These raw AX notifications are undebounced.
function obj:onAXEvent(_, event, watcher, id)
  local entry = self.pinned[id]
  if not entry then
    pcall(watcher.stop, watcher) -- stale watcher, self-heal
    return
  end

  if event == AX.elementDestroyed then
    self:unpin(id, 'window closed')
  elseif event == AX.windowMinimized then
    entry.minimized = true
  elseif event == AX.windowUnminimized then
    entry.minimized = false
    self:restoreFrame(entry)
    self:scheduleRaise()
  elseif event == AX.windowMoved or event == AX.windowResized then
    self:restoreFrame(entry)
  end
end

function obj:attachWatcher(entry)
  local win = entry.win
  if type(win.newWatcher) ~= 'function' then
    self:warnOnce('newWatcher', 'hs.window has no newWatcher; geometry lock falls back to the %.1fs poll', self.pollInterval)
    return nil
  end
  -- The AX callback signature is fixed -- fn(element, event, watcher, userData) -- with no
  -- slot for self, so the method is reached through a closure. userData still carries the
  -- window id, which is what the stale-watcher check in onAXEvent compares against.
  local ok, watcher = pcall(win.newWatcher, win, function(el, ev, w, id) self:onAXEvent(el, ev, w, id) end, entry.id)
  if not ok or not watcher then
    self.logger.wf('could not create an AX watcher for %s: %s', entry.appName, tostring(watcher))
    return nil
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
    self.logger.wf('could not start the AX watcher for %s', entry.appName)
    return nil
  end
  return watcher
end

--------------------------------------------------------------------------------
-- Enforcement lifecycle
--------------------------------------------------------------------------------

-- Building an hs.window.filter spins up accessibility watchers across every running app,
-- and pausing it does not undo that. So it is created on the first pin rather than at
-- startup: a session where nothing is ever pinned costs nothing. Once created it is kept
-- and merely paused, so only the very first pin pays the setup.
function obj:ensureFocusFilter()
  if self.focusFilter then return end
  self.onFocusEvent = function()
    self.stats.focusEvents = self.stats.focusEvents + 1
    self:scheduleRaise()
  end
  local ok, filter = pcall(hs.window.filter.new)
  if not ok or not filter then
    self.logger.wf('could not create a window filter (%s); relying on the %.1fs poll', tostring(filter), self.pollInterval)
    return
  end
  self.focusFilter = filter
  self.focusFilter:subscribe(hs.window.filter.windowFocused, self.onFocusEvent)
end

-- Nothing pinned means no background work at all: an idle repeating timer defeats CPU
-- idle states, which matters on a laptop.
function obj:startEnforcement()
  self:ensureFocusFilter()
  if self.focusFilter then self.focusFilter:resume() end
  if not self.pollTimer then
    self.pollTimer = hs.timer.doEvery(self.pollInterval, function()
      self:enforceAll()
      -- The title is NOT rebuilt every tick. It depends only on pinnedCount and each
      -- entry's appName/title, none of which the poll changes -- titles are refreshed in
      -- buildMenu() when the menu opens, and every real transition (pin, unpin, native
      -- float found) already calls updateMenubarTitle itself. Rebuilding it here meant an
      -- accessibilityState() syscall, a sortedPins() sort and two Cocoa writes per second
      -- to store the string that was already there. Accessibility permission is the one
      -- input that can change with no event of its own, so that alone is still watched.
      local trusted = hs.accessibilityState()
      if trusted ~= self.lastAccessibilityState then
        self.lastAccessibilityState = trusted
        self:updateMenubarTitle()
      end
    end)
  end
end

function obj:stopEnforcement()
  if self.focusFilter then self.focusFilter:pause() end
  if self.pollTimer then
    self.pollTimer:stop()
    self.pollTimer = nil
  end
  if self.raiseTimer then
    self.raiseTimer:stop()
    self.raiseTimer = nil
  end
end

--------------------------------------------------------------------------------
-- Native always-on-top
--------------------------------------------------------------------------------

-- Emulated raising cannot work: macOS orders windows by application, and AXRaise only
-- reorders within an app's own layer, so a background window can never climb over the
-- active app. Plenty of apps (VLC, IINA, mpv, Finder-likes, many players and terminals)
-- expose a real "always on top" of their own, implemented in-process where it IS allowed.
-- Flipping that menu item is a genuine fix rather than an emulation, and it only has to
-- happen once -- the app maintains the window level itself from then on.
function obj:findFloatMenuItem(app, callback)
  if not app then return callback(nil) end
  -- Callback form: getMenuItems builds the tree on a background thread. The blocking
  -- form can take a noticeable moment on apps with large menus.
  app:getMenuItems(function(menus)
    if not menus then return callback(nil) end
    local best
    walkMenu(menus, {}, function(item, path)
      local title = item.AXTitle
      if not title or title == '' then return end
      -- Only leaves are actionable; a submenu titled "Always on Top" is not a toggle.
      if item.AXChildren then return end
      local lower = title:lower()
      for rank, hint in ipairs(self.floatHints) do
        if lower:find(hint, 1, true) then
          if not best or rank < best.rank then
            local mark = item.AXMenuItemMarkChar
            best = {
              path = path,
              rank = rank,
              title = title,
              ticked = mark ~= nil and mark ~= '',
            }
          end
          break
        end
      end
    end)
    callback(best)
  end)
end

-- selectMenuItem often works without the app being frontmost. Try that first so the
-- common case costs no focus change at all, and only fall back to activating if it fails.
-- No success/failure return: the fallback below is asynchronous, so by the time this
-- returns the retry has not happened yet and there is nothing truthful to report.
function obj:clickMenuItem(app, path)
  if app:selectMenuItem(path) then return end
  local previous = hs.window.focusedWindow()
  app:activate()
  hs.timer.doAfter(0.15, function()
    if not app:selectMenuItem(path) then self.logger.wf('could not select menu item %s', table.concat(path, ' > ')) end
    if previous and previous:application() and previous:application():pid() ~= app:pid() then
      hs.timer.doAfter(0.15, function() pcall(previous.focus, previous) end)
    end
  end)
end

function obj:enableNativeFloat(entry)
  local win = resolve(entry)
  local app = win and win:application()
  if not app then return end
  self:findFloatMenuItem(app, function(found)
    if not self.pinned[entry.id] then return end -- unpinned while we were searching
    if not found then
      entry.nativeFloat = false
      self.logger.f('%s has no native always-on-top menu item', entry.appName)
      self:updateMenubarTitle()
      return
    end
    -- Two different questions, tracked separately: `on` is the item's current state and is
    -- what the menu renders, while `enabledByUs` records whether we were the one who
    -- switched it on and is what decides whether unpinning switches it back off. Folding
    -- them into one field makes toggling the row from the menu flip the ownership flag,
    -- which leaves an already-floating app floating after it is unpinned.
    entry.nativeFloat = { path = found.path, title = found.title, on = true }
    if found.ticked then
      -- Already on before we touched it; leave it alone when unpinning.
      entry.nativeFloat.enabledByUs = false
      self.logger.f("%s already floating via '%s'", entry.appName, found.title)
    else
      entry.nativeFloat.enabledByUs = true
      self:clickMenuItem(app, found.path)
      self.logger.f("%s: enabled native float via '%s'", entry.appName, table.concat(found.path, ' > '))
      hs.alert.show(entry.appName .. ': using its own "' .. found.title .. '"', 2)
    end
    self:updateMenubarTitle()
  end)
end

function obj:disableNativeFloat(entry)
  local nf = entry.nativeFloat
  -- Only undo our own doing, and only if it is still done: the user may have turned the
  -- app's float back off from the submenu, in which case clicking it again turns it on.
  if type(nf) ~= 'table' or not nf.enabledByUs or not nf.on then return end
  local win = resolve(entry)
  local app = win and win:application()
  if not app then return end
  self:clickMenuItem(app, nf.path)
  self.logger.f('%s: turned native float back off', entry.appName)
end

--------------------------------------------------------------------------------
-- Pin lifecycle
--------------------------------------------------------------------------------

function obj:pin(win)
  if not win then return end
  local id = win:id()
  if not id then
    hs.alert.show('That window has no id and cannot be pinned')
    return
  end
  if self.pinned[id] then return end
  if win:isFullScreen() then
    hs.alert.show("Can't pin a fullscreen window")
    return
  end

  local app = win:application()
  self.pinOrder = self.pinOrder + 1

  local entry = {
    id = id,
    win = win,
    pid = app and app:pid() or nil,
    appName = app and app:name() or 'Unknown',
    title = win:title() or '',
    frame = rectOf(win:frame()),
    order = self.pinOrder,
    onTop = true,
    lockSize = true,
    lockPos = true,
    minimized = win:isMinimized() and true or false,
    suppressUntil = 0,
    attempts = 0,
    firstAttempt = 0,
    lastAttempt = 0,
    lastRaise = 0,
    resisted = false,
    nativeFloat = nil, -- nil = still looking, false = none, table = found
  }
  entry.watcher = self:attachWatcher(entry)

  self.pinned[id] = entry
  self.pinnedCount = self.pinnedCount + 1
  if self.pinnedCount == 1 then self:startEnforcement() end

  self:updateMenubarTitle()
  self:enableNativeFloat(entry) -- the real fix, where the app offers one
  self:scheduleRaise() -- best-effort fallback; only helps within the same app
  self.logger.f('pinned %s - %s', entry.appName, entry.title)
  hs.alert.show('Pinned: ' .. truncate(entry.appName .. ' — ' .. entry.title, self.titleMax), 1)
end

function obj:unpin(id, reason)
  local entry = self.pinned[id]
  if not entry then return end

  -- Only if we turned it on: a window closing does not mean the user wants the app's
  -- own float preference reverted, but our own toggle should not outlive the pin.
  if reason ~= 'window closed' and reason ~= 'app quit' then pcall(self.disableNativeFloat, self, entry) end
  if entry.watcher then pcall(entry.watcher.stop, entry.watcher) end
  self.pinned[id] = nil
  self.pinnedCount = self.pinnedCount - 1
  if self.pinnedCount <= 0 then
    self.pinnedCount = 0
    self:stopEnforcement()
  end

  self:updateMenubarTitle()
  self.logger.f('unpinned %s (%s)', entry.appName, reason or 'user')
  return entry
end

function obj:togglePin(win)
  if not win then return end
  local id = win:id()
  if id and self.pinned[id] then
    local entry = self:unpin(id, 'toggled off')
    if entry then hs.alert.show('Unpinned: ' .. truncate(entry.appName, self.titleMax), 1) end
  else
    self:pin(win)
  end
end

-- Re-snapshot: the escape hatch for repositioning a pinned window without unpinning it.
function obj:resnapshot(entry)
  local win = resolve(entry)
  if not win then return end
  entry.frame = rectOf(win:frame())
  entry.attempts = 0
  entry.resisted = false
  hs.alert.show('Saved new position and size', 1)
end

-- Drop entries whose window no longer exists. AX usually tells us via elementDestroyed,
-- but an app that is force-quit can die without delivering it.
function obj:pruneStale()
  for id, entry in pairs(self.pinned) do
    if not resolve(entry) then self:unpin(id, 'vanished') end
  end
end

--------------------------------------------------------------------------------
-- Menubar
--------------------------------------------------------------------------------

function obj:updateMenubarTitle()
  if not self.menubarItem then return end
  if not hs.accessibilityState() then
    self.menubarItem:setTitle('◇!')
    self.menubarItem:setTooltip('Pinned Windows — Accessibility permission is not granted')
    return
  end
  if self.pinnedCount == 0 then
    self.menubarItem:setTitle('◇')
    self.menubarItem:setTooltip('Pinned Windows — nothing pinned')
    return
  end
  self.menubarItem:setTitle(self.pinnedCount == 1 and '◆' or ('◆' .. self.pinnedCount))
  local lines = {}
  for _, e in ipairs(self:sortedPins()) do
    lines[#lines + 1] = e.appName .. ' — ' .. (e.title ~= '' and e.title or '(untitled)')
  end
  self.menubarItem:setTooltip(table.concat(lines, '\n'))
end

function obj:statusSuffix(entry)
  local win = resolve(entry)
  if not win then return ' (gone)' end
  if entry.minimized then return ' (minimized)' end
  if win:isFullScreen() then return ' (fullscreen)' end
  if not self:isOnCurrentSpace(win) then return ' (other space)' end
  local off = {}
  if not entry.onTop then off[#off + 1] = 'top' end
  if not entry.lockSize then off[#off + 1] = 'size' end
  if not entry.lockPos then off[#off + 1] = 'position' end
  if #off > 0 then return ' (' .. table.concat(off, '/') .. ' unlocked)' end
  -- Be honest about which windows are genuinely floating and which are not.
  if type(entry.nativeFloat) == 'table' then return entry.nativeFloat.on and ' ✓floating' or ' (float off)' end
  if entry.nativeFloat == false then return ' (no real on-top)' end
  return ''
end

function obj:pinSubmenu(entry)
  local floatRow
  if type(entry.nativeFloat) == 'table' then
    floatRow = {
      title = 'Always on Top — ' .. entry.appName .. '’s “' .. entry.nativeFloat.title .. '”',
      checked = entry.nativeFloat.on,
      fn = function()
        local win = resolve(entry)
        local app = win and win:application()
        if app then
          self:clickMenuItem(app, entry.nativeFloat.path)
          entry.nativeFloat.on = not entry.nativeFloat.on
        end
      end,
    }
  elseif entry.nativeFloat == false then
    floatRow = {
      title = 'No real always-on-top — ' .. entry.appName .. ' has no float option',
      disabled = true,
    }
  else
    floatRow = { title = 'Looking for a native float option…', disabled = true }
  end

  return {
    {
      title = 'Unpin',
      fn = function()
        self:unpin(entry.id, 'menu')
        hs.alert.show('Unpinned: ' .. truncate(entry.appName, self.titleMax), 1)
      end,
    },
    -- The one place focus() is used: an explicit, direct user action.
    {
      title = 'Bring to Front & Focus',
      fn = function()
        local win = resolve(entry)
        if win then win:focus() end
      end,
    },
    { title = '-' },
    floatRow,
    {
      title = 'Keep re-raising (best effort)',
      checked = entry.onTop,
      fn = function()
        entry.onTop = not entry.onTop
        if entry.onTop then self:scheduleRaise() end
      end,
    },
    {
      title = 'Lock Size',
      checked = entry.lockSize,
      fn = function()
        entry.lockSize = not entry.lockSize
        entry.attempts, entry.resisted = 0, false
        self:restoreFrame(entry)
      end,
    },
    {
      title = 'Lock Position',
      checked = entry.lockPos,
      fn = function()
        entry.lockPos = not entry.lockPos
        entry.attempts, entry.resisted = 0, false
        self:restoreFrame(entry)
      end,
    },
    { title = '-' },
    { title = 'Update Saved Position & Size', fn = function() self:resnapshot(entry) end },
  }
end

function obj:buildMenu(mods)
  self:pruneStale()
  local menu = {}

  local front = hs.window.frontmostWindow()
  local frontPinned = front and front:id() and self.pinned[front:id()] ~= nil
  menu[#menu + 1] = {
    title = frontPinned and 'Unpin Frontmost Window' or 'Pin Frontmost Window',
    disabled = front == nil,
    fn = function() self:togglePin(front) end,
  }

  if self.pinnedCount > 0 then
    menu[#menu + 1] = { title = '-' }
    menu[#menu + 1] = { title = 'Pinned (' .. self.pinnedCount .. ')', disabled = true }
    for _, entry in ipairs(self:sortedPins()) do
      local win = resolve(entry)
      if win then entry.title = win:title() or entry.title end
      menu[#menu + 1] = {
        title = truncate(entry.appName .. ' — ' .. (entry.title ~= '' and entry.title or '(untitled)'), self.titleMax)
          .. self:statusSuffix(entry),
        checked = true,
        indent = 1,
        menu = self:pinSubmenu(entry),
      }
    end
    menu[#menu + 1] = { title = 'Unpin All', fn = function() self:unpinAll() end }
  end

  menu[#menu + 1] = { title = '-' }
  menu[#menu + 1] = { title = 'Windows', disabled = true }

  local groups, names = collectWindows()
  if #names == 0 then menu[#menu + 1] = { title = 'No windows available', disabled = true } end
  for _, name in ipairs(names) do
    local wins = groups[name]
    if #wins == 1 then
      -- Collapse single-window apps to one flat row rather than a submenu of one.
      local w = wins[1]
      menu[#menu + 1] = {
        title = truncate(name .. ' — ' .. (w:title() or ''), self.titleMax),
        checked = self.pinned[w:id()] ~= nil,
        indent = 1,
        fn = function() self:togglePin(w) end,
      }
    else
      local sub = {}
      for i, w in ipairs(wins) do
        if i > self.maxWindowsPerApp then
          sub[#sub + 1] = {
            title = string.format('… %d more', #wins - self.maxWindowsPerApp),
            disabled = true,
          }
          break
        end
        sub[#sub + 1] = {
          title = truncate(w:title() or '', self.titleMax),
          checked = self.pinned[w:id()] ~= nil,
          fn = function() self:togglePin(w) end,
        }
      end
      menu[#menu + 1] = {
        title = string.format('%s (%d)', name, #wins),
        indent = 1,
        menu = sub,
      }
    end
  end

  -- Alt-click reveals diagnostics without cluttering the everyday menu.
  if mods and mods.alt then
    menu[#menu + 1] = { title = '-' }
    menu[#menu + 1] = {
      title = 'Log level: ' .. tostring(self.logger.getLogLevel()),
      fn = function() self.logger.setLogLevel(self.logger.getLogLevel() == 3 and 'debug' or 'info') end,
    }
    menu[#menu + 1] = {
      title = 'Dump state to console',
      fn = function()
        print(hs.inspect({
          pinnedCount = self.pinnedCount,
          polling = self.pollTimer ~= nil and self.pollTimer:running(),
          pins = self:sortedPins(),
        }, { depth = 3 }))
      end,
    }
  end

  return menu
end

--------------------------------------------------------------------------------
-- System watchers
--------------------------------------------------------------------------------

-- Never leave a pinned window stranded off-screen: an invisible window that also refuses
-- to move is the worst possible failure mode. Pulled out of the debounce closure below so
-- the guards read as preconditions rather than burying the one interesting line four
-- levels deep.
function obj:refitToScreen(entry)
  local win = resolve(entry)
  if not win then return end
  local screen = win:screen()
  if not screen then return end
  entry.frame = rectOf(hs.geometry(entry.frame):fit(screen:frame()))
  entry.attempts = 0
end

function obj:onScreensChanged()
  if self.screenTimer then self.screenTimer:stop() end
  self.screenTimer = hs.timer.doAfter(self.screenSettle, function()
    self.screenTimer = nil
    for _, entry in ipairs(self:sortedPins()) do
      self:refitToScreen(entry)
    end
    self:enforceAll()
  end)
end

function obj:onAppEvent(_, event, app)
  if event == hs.application.watcher.activated then
    self.stats.appActivations = self.stats.appActivations + 1
    self:scheduleRaise()
  elseif event == hs.application.watcher.terminated then
    -- AX observers die with the process, sometimes without delivering elementDestroyed,
    -- which is why the pid is captured at pin time.
    local pid = app and app:pid()
    for id, entry in pairs(self.pinned) do
      if pid and entry.pid == pid then self:unpin(id, 'app quit') end
    end
    self:pruneStale()
  end
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

function obj:runDiagnose()
  local out = {}
  local function say(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

  say(
    'running=%s  accessibility=%s  menubar=%s  pinned=%d',
    tostring(self.running),
    tostring(hs.accessibilityState()),
    tostring(self.menubarItem ~= nil),
    self.pinnedCount
  )
  say('pollTimer=%s  focusFilter=%s', tostring(self.pollTimer ~= nil and self.pollTimer:running()), tostring(self.focusFilter ~= nil))
  say(
    'events seen: focus=%d appActivated=%d raiseCalls=%d frameRestores=%d',
    self.stats.focusEvents,
    self.stats.appActivations,
    self.stats.raiseCalls,
    self.stats.frameRestores
  )

  local focused = hs.window.focusedWindow()
  local focusedApp = focused and focused:application() and focused:application():name()
  say('focused window: %s (%s)', tostring(focused and focused:title()), tostring(focusedApp))

  if self.pinnedCount == 0 then
    say('')
    say('NOTHING IS PINNED — pin a window first, then run this again.')
  end

  for _, entry in ipairs(self:sortedPins()) do
    local win = resolve(entry)
    say('')
    say('pin: %s — %s', entry.appName, entry.title)
    if not win then
      say('  window no longer resolves')
    else
      say(
        '  onTop=%s visible=%s fullscreen=%s currentSpace=%s minimized=%s',
        tostring(entry.onTop),
        tostring(win:isVisible()),
        tostring(win:isFullScreen()),
        tostring(self:isOnCurrentSpace(win)),
        tostring(entry.minimized)
      )
      if type(entry.nativeFloat) == 'table' then
        say(
          "  native float: USING '%s' (%s)",
          table.concat(entry.nativeFloat.path, ' > '),
          entry.nativeFloat.enabledByUs and 'we turned it on' or 'was already on'
        )
      elseif entry.nativeFloat == false then
        say("  native float: none found in this app's menus")
      else
        say('  native float: still searching (or search failed)')
      end

      local before = zOrderExcludingHammerspoon()
      local zBefore = zIndexOf(entry.id, before)
      local topApp = before[1] and before[1]:application() and before[1]:application():name()
      say('  window on top right now: %s', tostring(topApp))
      say('  z-order before raise: %s of %d', tostring(zBefore), #before)

      pcall(win.becomeMain, win)
      pcall(win.raise, win)

      local after = zOrderExcludingHammerspoon()
      local zAfter = zIndexOf(entry.id, after)
      say('  z-order after raise:  %s of %d', tostring(zAfter), #after)

      if zAfter == 1 then
        say('  >>> RAISE WORKS. On-top is achievable; the bug is in my logic.')
      elseif zBefore and zAfter and zAfter < zBefore then
        say('  >>> PARTIAL: climbed %d -> %d but not to the front.', zBefore, zAfter)
        say('      Consistent with AXRaise only reordering within its own app.')
      else
        say('  >>> RAISE HAS NO EFFECT across applications (OS limitation).')
      end
      if topApp and topApp ~= entry.appName then say('      (the covering window belongs to a DIFFERENT app: %s)', topApp) end
    end
  end

  local text = table.concat(out, '\n')
  print('\n--- PinnedWindows diagnose ---\n' .. text .. '\n--- end ---')
  return text
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

--- PinnedWindows:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
---
--- Notes:
---  * Deliberately starts nothing. The menubar item, every watcher and every timer belong to `PinnedWindows:start()`.
---  * It is also deliberately empty rather than re-initialising state. The declarations above already run on a freshly loaded object, and `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load -- so clearing `pinned` here would orphan the accessibility watchers of anything already pinned.
function obj:init() return self end

--- PinnedWindows:start() -> self
--- Method
--- Adds the menubar item and starts watching for the events that pinning depends on.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
---
--- Notes:
---  * Calling this on an already-started Spoon restarts it cleanly.
---  * No polling or focus tracking begins until the first window is pinned, so an idle session costs nothing.
---  * Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  -- The autosave name stays "pinnedwindows" rather than matching the Spoon name: it is what
  -- macOS keys the item's saved position in the menu bar on, so renaming it would silently
  -- move the icon back to the default slot.
  self.menubarItem = hs.menubar.new(true, 'pinnedwindows')
  if self.menubarItem then
    -- Wrapped: an error thrown inside the menu callback would otherwise leave a dead
    -- menubar icon with no way to recover short of reloading the config.
    self.menubarItem:setMenu(function(mods)
      local ok, menu = pcall(self.buildMenu, self, mods)
      if ok then return menu end
      self.logger.wf('menu build failed: %s', tostring(menu))
      return {
        { title = 'Menu failed to build — see console', disabled = true },
        { title = '-' },
        { title = 'Unpin All', fn = function() self:unpinAll() end },
      }
    end)
  end

  self.appWatcher = hs.application.watcher.new(function(name, event, app) self:onAppEvent(name, event, app) end)
  self.appWatcher:start()

  if hs.spaces and hs.spaces.watcher then
    self.spaceWatcher = hs.spaces.watcher.new(function()
      -- Delay: immediately after a switch, focusedSpace() still reports the old space.
      -- Kept in a handle and restarted rather than fired and forgotten: swiping through
      -- several Spaces inside spaceSettle would otherwise queue one independent timer per
      -- Space, every one of them running a full enforceAll(). Only the last switch matters.
      if self.spaceTimer then self.spaceTimer:stop() end
      self.spaceTimer = hs.timer.doAfter(self.spaceSettle, function()
        self.spaceTimer = nil
        self:enforceAll()
      end)
    end)
    self.spaceWatcher:start()
  end

  self.screenWatcher = hs.screen.watcher.new(function() self:onScreensChanged() end)
  self.screenWatcher:start()

  self.running = true
  self:updateMenubarTitle()

  if not hs.accessibilityState() then
    hs.alert.show('PinnedWindows needs Accessibility permission')
    self.logger.w('accessibility permission not granted; nothing will work until it is')
  end

  self.logger.i('started')
  return self
end

--- PinnedWindows:stop() -> self
--- Method
--- Unpins everything and removes the menubar item, every watcher and every timer.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
---
--- Notes:
---  * Any hotkeys bound with `PinnedWindows:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  self:unpinAll()
  self:stopEnforcement()

  if self.menubarItem then
    self.menubarItem:delete()
    self.menubarItem = nil
  end
  if self.focusFilter and self.onFocusEvent then
    -- Unsubscribe by (event, fn): unsubscribing by event alone would also remove
    -- callbacks any other module registered on a shared filter.
    pcall(self.focusFilter.unsubscribe, self.focusFilter, hs.window.filter.windowFocused, self.onFocusEvent)
  end
  self.focusFilter, self.onFocusEvent = nil, nil

  -- Stopped one by one rather than by iterating a table literal. ipairs() halts at the
  -- first nil hole, so `ipairs({ appWatcher, spaceWatcher, screenWatcher })` would silently
  -- skip the screen watcher on any machine where hs.spaces is missing.
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

  self.warned = {}
  self.running = false
  self.logger.i('stopped')
  return self
end

--- PinnedWindows:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for PinnedWindows.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * togglePin - Pin or unpin the frontmost window
---    * unpinAll - Unpin every pinned window
---
--- Returns:
---  * The PinnedWindows object
---
--- Notes:
---  * For example: `spoon.PinnedWindows:bindHotkeys({ togglePin = { { "cmd", "alt", "shift" }, "P" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    togglePin = hs.fnutils.partial(self.togglePinFrontmost, self),
    unpinAll = hs.fnutils.partial(self.unpinAll, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

--- PinnedWindows:togglePinFrontmost() -> self
--- Method
--- Pins the frontmost window, or unpins it if it is already pinned.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
function obj:togglePinFrontmost()
  local win = hs.window.frontmostWindow()
  if win then
    self:togglePin(win)
  else
    hs.alert.show('No frontmost window')
  end
  return self
end

--- PinnedWindows:unpinAll() -> self
--- Method
--- Unpins every currently pinned window.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
function obj:unpinAll()
  for id in pairs(self.pinned) do
    self:unpin(id, 'unpin all')
  end
  return self
end

--- PinnedWindows:diagnose([delay]) -> string
--- Method
--- Reports why always-on-top is or is not working, by measuring real window z-order before and after a raise.
---
--- Parameters:
---  * delay - Optional seconds to wait before measuring. Defaults to `0`, which measures immediately.
---
--- Returns:
---  * The report text when run immediately, or a short acknowledgement when a delay was given. Either way the full report is printed to the Console.
---
--- Notes:
---  * Pass a delay and click the app that covers your pinned window during it, so the measurement is taken while a DIFFERENT app is frontmost -- that is the case that matters, and running straight from the Console would measure Hammerspoon instead. For example: `spoon.PinnedWindows:diagnose(6)`
function obj:diagnose(delay)
  delay = tonumber(delay) or 0
  if delay <= 0 then return self:runDiagnose() end
  hs.alert.show(('Diagnosing in %ds — click the app that covers your pinned window'):format(delay), delay)
  hs.timer.doAfter(delay, function() self:runDiagnose() end)
  return string.format('measuring in %ds; results will print to this console', delay)
end

--- PinnedWindows:resetStats() -> self
--- Method
--- Resets the event counters, so the next `diagnose()` reflects only what happened since.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PinnedWindows object
function obj:resetStats()
  self.stats = newStats()
  return self
end

--- PinnedWindows:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `pinnedCount`, `polling` and `pins` keys
function obj:status()
  return {
    running = self.running,
    pinnedCount = self.pinnedCount,
    polling = self.pollTimer ~= nil and self.pollTimer:running() or false,
    pins = self:sortedPins(),
  }
end

return obj
