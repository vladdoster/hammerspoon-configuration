--- === SummonWindow ===
---
--- Brings a window from another Mission Control Space to the one you are on.
---
--- macOS offers no way to pull a window towards you. If it is on Space 3 and you are on
--- Space 1, the only choices are to navigate away or to drag the window around inside
--- Mission Control. This Spoon inverts that: a hotkey or a menubar click lists every
--- window living on some other Space, and picking one moves it here and focuses it,
--- without ever leaving the Space you are on.
---
--- Two hard parts, and neither is the one you would expect.
---
--- The first is *enumerating* windows that macOS Accessibility deliberately hides from a
--- process that is not looking at them; see `SummonWindow.deepScan`, `SummonWindow.useYabai`
--- and `SummonWindow:diagnose()`.
---
--- The second is the move itself. `hs.spaces.moveWindowToSpace()` was the obvious answer
--- and is a **silent no-op on macOS 15 and later** -- Apple gutted the private window
--- server calls it relies on, and the surviving ones check that the caller owns the
--- window or is the Dock. Worse, it still returns `true`, because Hammerspoon never
--- checks a return value that no longer means anything (see Hammerspoon issue #3698,
--- open since 2024).
---
--- So a move is attempted three ways in turn, and *every* one of them is verified against
--- where the window actually ended up rather than believed, because all three lie. yabai
--- goes first: it moves a window instantly and invisibly, through a scripting addition
--- injected into Dock.app that the window server still trusts. The native call goes
--- second, kept for the day it works again. Physically dragging the window across goes
--- last. See `SummonWindow.useYabai` and `SummonWindow.dragFallback`.
---
--- Windows that cannot be moved are never listed. A fullscreen or tiled window lives in
--- its own managed Space, and the window server refuses to move windows out of one, so
--- listing them would only produce rows that fail when clicked.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = 'SummonWindow'
obj.version = '1.0'
obj.author = 'Vladislav Doster <mvdoster@gmail.com>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

--- SummonWindow.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('SummonWindow', 'info')

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- SummonWindow.deepScan
--- Variable
--- Whether to add a live `hs.window.allWindows()` sweep to the window filter's cache when building the list. Defaults to `true`.
---
--- Notes:
---  * The window filter only knows about Spaces it has already witnessed, so on a fresh config reload it can be blind to windows you have not visited yet. The sweep asks every application directly instead, and the two sources are unioned.
---  * Set to `false` if the sweep proves slow on a machine with very many windows; the list will then be limited to what the filter has learned.
obj.deepScan = true

--- SummonWindow.includeMinimized
--- Variable
--- Whether minimized windows on other Spaces are offered. Defaults to `false`.
---
--- Notes:
---  * When enabled, summoning a minimized window also unminimizes it -- moving a window you cannot see would otherwise do nothing visible.
---  * This depends on `SummonWindow.deepScan`. The default window filter is built with `visible=true`, so it discards minimized windows before this Spoon ever sees them; the direct sweep is the only source that reports them.
obj.includeMinimized = false

--- SummonWindow.useMissionControlNames
--- Variable
--- Whether to label Spaces with their real Mission Control names instead of ordinals. Defaults to `false`.
---
--- Notes:
---  * Reading those names requires `hs.spaces.missionControlSpaceNames()`, which physically opens and closes Mission Control every time it is called. That is far too intrusive to do each time the list is built, so the default derives `Space N` from the Space's position instead.
obj.useMissionControlNames = false

--- SummonWindow.focusAfterMove
--- Variable
--- Whether a summoned window is focused and raised once it arrives. Defaults to `true`.
obj.focusAfterMove = true

--- SummonWindow.chooserRows
--- Variable
--- Number of rows visible in the chooser at once. Defaults to `10`.
obj.chooserRows = 10

--- SummonWindow.chooserWidth
--- Variable
--- Chooser width as a percentage of screen width. Defaults to `35`.
obj.chooserWidth = 35

--- SummonWindow.titleMax
--- Variable
--- Maximum length of a window title in the menubar menu before it is middle-ellipsised. Defaults to `55`.
---
--- Notes:
---  * The chooser is not truncated; it is searchable, and its rows wrap on their own.
obj.titleMax = 55

--- SummonWindow.showInMenubar
--- Variable
--- Whether `SummonWindow:start()` adds a menubar item. Defaults to `true`.
obj.showInMenubar = true

--- SummonWindow.menubarTitle
--- Variable
--- Glyph shown in the menubar. Defaults to `'⧉'`.
obj.menubarTitle = '⧉'

--- SummonWindow.useYabai
--- Variable
--- Whether to use yabai, when it is installed, to move windows and to find them. Defaults to `true`.
---
--- Notes:
---  * yabai does what `hs.spaces.moveWindowToSpace()` used to: it moves a window to another Space instantly, invisibly, and without touching the mouse. It manages that because its scripting addition is injected into Dock.app, so the window server sees the request arriving from one of the few processes still permitted to make it.
---  * That injection requires System Integrity Protection to be partially disabled and the addition to be loaded (`sudo yabai --load-sa`), so this can never be the only strategy. On a machine without yabai this Spoon behaves exactly as it did before yabai was ever mentioned: an absent yabai is not an error, is never reported as one, and simply drops the ladder to its next rung.
---  * yabai is also consulted as a third source of windows, alongside the window filter and `SummonWindow.deepScan`. Its server tracks every window on every Space continuously, so unlike the other two it does not depend on what Accessibility is willing to tell this process at the moment you ask.
---  * A window that *only* yabai can see has no `hs.window` behind it, so it can only be moved by yabai -- the native call and the drag both need a real window object. Such a window is summoned or not; there is no fallback for it.
obj.useYabai = true

--- SummonWindow.yabaiPath
--- Variable
--- Full path to the yabai binary, or `nil` to probe the usual install locations. Defaults to `nil`.
---
--- Notes:
---  * `hs.task` cannot search `PATH`, and handing the search to a shell instead would be worse than useless: Hammerspoon inherits launchd's environment rather than your login shell's, so `command -v yabai` run from here would miss on exactly the machines where a shell rc file put yabai on the path. A short list of known install prefixes is probed instead.
---  * Set this if yabai lives somewhere unusual. Unlike a failed probe, a path set here that is not an executable file is a mistake in the config rather than a missing optional dependency, and is warned about once.
obj.yabaiPath = nil

--- SummonWindow.yabaiTimeout
--- Variable
--- How long a single yabai invocation may run before it is killed, in seconds. Defaults to `1.5`.
---
--- Notes:
---  * `yabai -m ...` is a thin client that talks to the running yabai server over a unix socket, and every command this Spoon issues takes single-digit milliseconds when that server is healthy. This limit exists only so a wedged server cannot hold a summon open forever; reaching it always means something is wrong elsewhere.
obj.yabaiTimeout = 1.5

--- SummonWindow.yabaiVerifyTimeout
--- Variable
--- How long to wait for a window to actually arrive after yabai reports the move succeeded, in seconds. Defaults to `0.6`.
---
--- Notes:
---  * yabai exiting zero means "the command was accepted", which is emphatically not the same as "the window moved". On recent macOS builds the scripting addition can be loaded, report success, and do nothing at all -- so the move is verified here exactly as it is for the other two rungs, and never believed.
obj.yabaiVerifyTimeout = 0.6

--- SummonWindow.yabaiCacheSeconds
--- Variable
--- How long a yabai query result is reused before it is fetched again, in seconds. Defaults to `3`.
---
--- Notes:
---  * Only the window list is served from this cache, and only for the menubar menu: `hs.menubar` demands a menu table synchronously, so it cannot wait for a subprocess. The chooser refreshes before it opens, and a move never uses a cached Space list at all -- Mission Control indices renumber whenever a Space is created or dragged, and a stale one would not fail, it would put the window on the wrong Space.
obj.yabaiCacheSeconds = 3

--- SummonWindow.dragFallback
--- Variable
--- Whether to physically drag a window across when neither yabai nor the window server will move it. Defaults to `true`.
---
--- Notes:
---  * `hs.spaces.moveWindowToSpace()` does nothing on macOS 15 and later, so without yabai this is not a fallback at all -- it is the only thing that works. It is still tried last, because it is the only rung that borrows the pointer and slides the screen about.
---  * A window can only be picked up while it is on the visible Space, so a drag is necessarily a round trip: walk to the window, take hold of its titlebar, walk back still holding it. Expect roughly a second, some Space animation, and the pointer to be borrowed and put back.
---  * Single display only. Dragging between Spaces on different screens does not work, and is refused rather than attempted.
obj.dragFallback = true

--- SummonWindow.gotoGraceSeconds
--- Variable
--- How long the offer to jump to an unmovable window's Space stays open, in seconds. Defaults to `4`.
---
--- Notes:
---  * When a window cannot be moved, pressing the hotkey again within this window of time goes to that Space instead of reopening the chooser. Doing nothing lets the offer lapse, so the hotkey never does something surprising later.
obj.gotoGraceSeconds = 4

--- SummonWindow.useFnModifier
--- Variable
--- Whether the synthetic Space-switch arrows carry the `fn` modifier. Defaults to `true`.
---
--- Notes:
---  * Real arrow keys on a real keyboard set `NSEventModifierFlagFunction`, and the macOS matcher for the "Move left/right a space" shortcut checks the whole modifier mask. A synthetic ctrl+arrow without `fn` is silently ignored on some systems. Turn this off only if Space switches start firing twice.
obj.useFnModifier = true

--- SummonWindow.dragTiming
--- Variable
--- Delays in seconds between the stages of a drag.
---
--- Notes:
---  * These are hand-tuned against a gesture that macOS never intended to be synthesised, and the defaults come from the three published implementations that are known to work. Raise `hopTimeout` first if Space traversal is unreliable on a slow machine, then `preRelease` if windows are dropped before they land.
obj.dragTiming = {
  warpSettle = 0.03, -- cursor warp emits no event, so give listeners a moment to notice
  raiseSettle = 0.12, -- after raise()/focus(), before the frame can be trusted
  downToDrag = 0.05, -- mouse down -> the drag event that arms the gesture
  dragToHop = 0.08, -- armed -> first Space switch
  keyHold = 0.03, -- between modifier and key events, as hardware would
  hopPoll = 0.05, -- how often to ask whether the Space switch landed
  hopTimeout = 1.60, -- per hop; a Space slide is ~0.5s, so this is ample
  hopSettle = 0.22, -- the Space id flips when the switch commits, not when it finishes
  preRelease = 0.30, -- final landing -> mouse up
  postRelease = 0.10, -- mouse up -> undoing the pixel nudge
  verifyTimeout = 1.50, -- how long to keep asking whether the window actually landed
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Everything long-lived is a field on the Spoon object rather than a local inside
-- start(), because hs.chooser / hs.menubar / hs.window.filter are userdata with a __gc
-- that tears down the real resource. hs.loadSpoon() keeps this object alive as
-- spoon.SummonWindow for the life of the config, so nothing here is collected out from
-- under a live chooser or menu.
obj.chooser = nil
obj.menubarItem = nil
obj.windowFilter = nil

-- id -> hs.window, rebuilt on every candidates() pass.
--
-- This map is not a cache, it is a necessity. hs.chooser runs every choice table through
-- a Lua<->ObjC conversion, so a choice may only carry plain values -- an hs.window cannot
-- ride along. The obvious workaround, storing win:id() and calling hs.window.get(id) in
-- the callback, fails for exactly the windows this Spoon exists for: get() is backed by
-- hs.window.allWindows(), which cannot reliably see other Spaces. So the objects are kept
-- here on the Lua side and the choice carries only the integer key into this table.
obj.byId = {}

-- id -> the descriptive entry from the same pass, for naming things in failure messages.
obj.lastEntries = {}

-- The in-flight drag, or nil. A drag is a genuinely dangerous piece of state: between the
-- mouse going down and coming back up, macOS believes the user is physically holding a
-- button. Keeping every part of it in one table means abortDrag() has exactly one thing
-- to tear down, and there is never a stray timer left holding the button.
obj.dragJob = nil

-- { spaceId, label, at } -- a standing offer to jump to the Space of a window that could
-- not be moved, consumed by the next hotkey press within gotoGraceSeconds.
obj.pendingGoto = nil

-- The resolved yabai binary path, `false` for "looked, and there is none", or nil for "not
-- looked yet". The negative is cached as deliberately as the positive: with yabai absent --
-- which is the ordinary case -- this turns four stat() calls per list build into four per
-- start(). Cleared in stop(), so installing yabai and reloading the config is enough for
-- this Spoon to notice it.
obj.yabaiResolved = nil

-- Every yabai subprocess currently in flight, as a set of job tables. Held for the same
-- reason as dragJob: a config reload part-way through must be able to find each process and
-- the timer watching it. Unlike dragJob this is a set rather than a single slot, because a
-- background list refresh and a move can legitimately overlap.
obj.yabaiTasks = {}

-- kind -> { at, data } for the last successful `yabai -m query --<kind>`.
obj.yabaiCache = {}

-- kind -> list of callbacks waiting on a query already in flight, so that a menubar menu
-- and a chooser opening together cost one subprocess rather than two.
obj.yabaiPending = {}

-- Why the last yabai query failed, or nil if the last one worked. Kept because the warning
-- is only ever emitted once and :diagnose() may well be run long after it scrolled away --
-- and "installed but not answering" is a completely different problem from "installed and
-- answering, but blind", which without this they would report identically.
obj.yabaiLastError = nil

-- When that failure happened, so a yabai which is installed but not running does not cost a
-- doomed subprocess on every menu open. Held for yabaiCacheSeconds, exactly as a successful
-- answer is, so the two states cost the same and starting the service is still noticed
-- within seconds.
obj.yabaiFailedAt = nil

obj.running = false
obj.warned = {}

--------------------------------------------------------------------------------
-- Stateless helpers
--------------------------------------------------------------------------------

-- These touch no Spoon state, so they stay plain locals rather than becoming methods.

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

-- Hoisted rather than written inline at the table.sort() below, which would allocate a
-- fresh closure on every list build.
local function bySpaceThenApp(a, b)
  if a.order ~= b.order then return a.order < b.order end
  if a.appName ~= b.appName then return a.appName < b.appName end
  return a.title < b.title
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

-- App icons are 512pt originals; menubar menus draw them at natural size, so anything
-- destined for a menu has to be shrunk first. `cache` is per list build: an app with
-- eight windows should cost one icon lookup, not eight.
function obj:iconFor(bundleID, cache, size)
  if not bundleID then return nil end
  local hit = cache[bundleID]
  if hit ~= nil then return hit or nil end

  local ok, img = pcall(hs.image.imageFromAppBundle, bundleID)
  if not ok then img = nil end
  if img and size then
    local okCopy, small = pcall(function() return img:copy():size({ w = size, h = size }) end)
    if okCopy and small then img = small end
  end

  -- `false` rather than nil as the negative result, so a missing icon is remembered
  -- instead of being looked up again for every remaining window of the same app.
  cache[bundleID] = img or false
  return img
end

--------------------------------------------------------------------------------
-- Spaces
--------------------------------------------------------------------------------

-- hs.spaces is built on private window server APIs and is documented as experimental.
-- Unlike a decoration Spoon, this one cannot fail open: without a Space to move to there
-- is nothing sensible to do, so these helpers return nil and say so rather than guessing.

function obj:currentSpace()
  if not (hs.spaces and hs.spaces.focusedSpace) then
    self:warnOnce('spaces', 'hs.spaces is unavailable; SummonWindow cannot work on this build')
    return nil
  end
  local ok, id = pcall(hs.spaces.focusedSpace)
  if not ok or type(id) ~= 'number' then
    self:warnOnce('focusedSpace', 'hs.spaces.focusedSpace failed (%s)', tostring(id))
    return nil
  end
  return id
end

function obj:spacesFor(win)
  if not (hs.spaces and hs.spaces.windowSpaces) then return nil end
  local ok, spaces = pcall(hs.spaces.windowSpaces, win)
  if not ok or type(spaces) ~= 'table' then
    self:warnOnce('windowSpaces', 'hs.spaces.windowSpaces failed (%s)', tostring(spaces))
    return nil
  end
  return spaces
end

-- The first Space in a window's list that it could actually be moved out of.
--
-- Everything that moves a window has to agree with classify() on which Space it is coming
-- from, and classify() deliberately skips fullscreen Spaces because a window cannot be
-- dragged out of one. Taking spaces[1] blindly instead routes the walk to a Space the
-- window is not reachable on, so grabPoint() takes hold of whatever happens to be under
-- the cursor there, or the hop simply times out.
--
-- Takes the already-fetched list rather than calling spacesFor() itself: that is a system
-- call per window and classify() runs it over every window in the list.
--
-- An unknown type counts as movable, matching classify(): if spaceType() is unavailable we
-- would rather offer a window that fails than silently refuse it.
local function firstMovableSpace(spaces, types)
  if not spaces then return nil end
  for _, id in ipairs(spaces) do
    if not types or types[id] ~= 'fullscreen' then return id end
  end
  return nil
end

--- SummonWindow:windowIsOn(win, spaceId) -> boolean
--- Method
--- Reports whether a window is currently on a given Space.
---
--- Parameters:
---  * win - an `hs.window` object
---  * spaceId - the integer id of a Space
---
--- Returns:
---  * `true` if the window is on that Space, `false` if it is not or cannot be determined
---
--- Notes:
---  * This is the Spoon's only source of truth about whether a move worked. `hs.spaces.moveWindowToSpace()` returns `true` unconditionally -- it does not check, and cannot check, what the window server actually did with the request -- so its result is ignored entirely in favour of asking where the window ended up.
---  * Only meaningful once a move has settled. During a drag the window server does not commit the move until the mouse button is released, so this reports the *old* Space right up until the drop.
function obj:windowIsOn(win, spaceId)
  local spaces = self:spacesFor(win)
  if not spaces then return false end
  return hs.fnutils.contains(spaces, spaceId)
end

-- Poll windowIsOn for a short while. The window server is not instantaneous, so checking
-- once immediately after a move would report failure for a move that was about to succeed.
function obj:awaitArrival(win, spaceId, timeout, done)
  local deadline = hs.timer.secondsSinceEpoch() + (timeout or 0.6)
  local timer
  timer = hs.timer.waitUntil(function() return self:windowIsOn(win, spaceId) or hs.timer.secondsSinceEpoch() > deadline end, function()
    if timer then pcall(function() timer:stop() end) end
    done(self:windowIsOn(win, spaceId))
  end, 0.05)
end

-- The Space we would be moving a window into, or nil plus a reason to show the user.
function obj:summonableSpace()
  local current = self:currentSpace()
  if not current then return nil, 'hs.spaces is unavailable' end

  -- A fullscreen or tiled app owns its Space outright and the window server will not
  -- accept arrivals into it. Better to say so up front than to open a list where every
  -- row fails.
  local ok, kind = pcall(hs.spaces.spaceType, current)
  if ok and kind == 'fullscreen' then return nil, 'cannot summon into a fullscreen Space' end
  return current
end

-- Reads real Mission Control names, at the cost of opening Mission Control. Only called
-- when useMissionControlNames is on.
function obj:missionControlNames()
  if not self.useMissionControlNames then return {} end
  if not (hs.spaces and hs.spaces.missionControlSpaceNames) then return {} end

  local ok, byScreen = pcall(hs.spaces.missionControlSpaceNames)
  if not ok or type(byScreen) ~= 'table' then
    self:warnOnce('mcNames', 'hs.spaces.missionControlSpaceNames failed (%s)', tostring(byScreen))
    return {}
  end

  local names = {}
  for _, spaces in pairs(byScreen) do
    if type(spaces) == 'table' then
      for id, name in pairs(spaces) do
        -- Keys survive the ObjC round trip as either numbers or numeric strings.
        local n = tonumber(id)
        if n and type(name) == 'string' and name ~= '' then names[n] = name end
      end
    end
  end
  return names
end

-- One snapshot of the Space layout per list build: labels for display, types to reject
-- fullscreen Spaces, and a global ordering so the list groups the way Mission Control
-- lays the Spaces out.
--
-- hs.spaces.spaceType() re-reads the whole managed-display table on every call, so it is
-- called once per Space here rather than once per window.
function obj:spaceModel()
  local model = { labels = {}, types = {}, order = {} }
  if not (hs.spaces and hs.spaces.allSpaces) then return model end

  local ok, all = pcall(hs.spaces.allSpaces)
  if not ok or type(all) ~= 'table' then
    self:warnOnce('allSpaces', 'hs.spaces.allSpaces failed (%s)', tostring(all))
    return model
  end

  -- pairs() order is undefined, and an unstable order would reshuffle the menu between
  -- openings. Primary screen first, then the rest by UUID, purely for determinism.
  local primary = hs.screen.primaryScreen()
  local primaryUUID = primary and primary:getUUID() or nil
  local uuids = {}
  for uuid in pairs(all) do
    uuids[#uuids + 1] = uuid
  end
  table.sort(uuids, function(a, b)
    if a == primaryUUID then return true end
    if b == primaryUUID then return false end
    return a < b
  end)

  local names = self:missionControlNames()
  local rank = 0

  for _, uuid in ipairs(uuids) do
    -- Naming the screen only helps when there is more than one; "Space 2" reads better
    -- than "Built-in Retina Display · Space 2" on a laptop by itself.
    local screenLabel
    if #uuids > 1 then
      local scr = hs.screen.find(uuid)
      screenLabel = (scr and scr:name()) or 'Display'
    end

    for index, id in ipairs(all[uuid] or {}) do
      rank = rank + 1
      local label = names[id] or string.format('Space %d', index)
      if screenLabel then label = screenLabel .. ' · ' .. label end
      model.labels[id] = label
      model.order[id] = rank

      local okType, kind = pcall(hs.spaces.spaceType, id)
      if okType and type(kind) == 'string' then model.types[id] = kind end
    end
  end

  return model
end

--------------------------------------------------------------------------------
-- yabai
--------------------------------------------------------------------------------

-- Everything in this section is written to be absent-tolerant. yabai not installed, not
-- running, or refusing a move are all ordinary outcomes rather than errors: the caller
-- records a reason and carries on without it. The only thing here that warns loudly is
-- yabai claiming to have done something and not having done it, because that is the one
-- failure a user cannot see for themselves.

-- Where Homebrew (both architectures), nix-darwin and hand installs put it, in descending
-- order of likelihood.
--
-- A static list rather than a shell probe, and that is not laziness. hs.task needs a full
-- path and will not search PATH; asking a shell to search it instead would be actively
-- wrong, because Hammerspoon inherits launchd's environment rather than a login shell's,
-- so `command -v yabai` from here misses on precisely the machines where a shell rc file
-- put yabai on the path. SummonWindow.yabaiPath covers anything this list does not.
local YABAI_PATHS = {
  '/opt/homebrew/bin/yabai',
  '/usr/local/bin/yabai',
  '/run/current-system/sw/bin/yabai',
  -- Last, and nil-safe: a table constructor tolerates a trailing nil, so a missing HOME
  -- shortens the list rather than erroring.
  os.getenv('HOME') and (os.getenv('HOME') .. '/.local/bin/yabai') or nil,
}

-- Is this path something we could actually execute? attributes() follows symlinks, which is
-- what we want here: /opt/homebrew/bin/yabai is a link into the Cellar.
local function executableFile(path)
  if type(path) ~= 'string' or path == '' then return false end
  local okMode, mode = pcall(hs.fs.attributes, path, 'mode')
  if not okMode or mode ~= 'file' then return false end
  local okPerm, perms = pcall(hs.fs.attributes, path, 'permissions')
  -- Owner-execute, since Hammerspoon runs as the user who installed it.
  return okPerm and type(perms) == 'string' and perms:sub(3, 3) == 'x'
end

-- Both directions of the only translation this Spoon needs.
--
-- yabai's space selector vocabulary is prev/next/first/last/recent/mouse/<index>/<label>:
-- there is deliberately no selector meaning "the Space I am on", and none that takes a
-- window server id. So the id this Spoon threads everywhere has to be turned into a Mission
-- Control index, and only yabai can be trusted to say what its own numbering is.
local function yabaiSpaceMaps(spaces)
  local idToIndex, indexToId = {}, {}
  for _, s in ipairs(spaces or {}) do
    if type(s) == 'table' and type(s.id) == 'number' and type(s.index) == 'number' then
      local id, index = math.floor(s.id), math.floor(s.index)
      idToIndex[id] = index
      indexToId[index] = id
    end
  end
  return idToIndex, indexToId
end

-- Resolve yabai once and remember the answer, including the negative one.
function obj:yabaiBinary()
  if not self.useYabai then return nil end
  if self.yabaiResolved ~= nil then return self.yabaiResolved or nil end

  if self.yabaiPath then
    -- An explicit path that does not work is a mistake in the config rather than a missing
    -- optional dependency, so unlike a failed probe it is worth saying out loud.
    if executableFile(self.yabaiPath) then
      self.yabaiResolved = self.yabaiPath
    else
      self:warnOnce(
        'yabaipath',
        'SummonWindow.yabaiPath is set to %s, which is not an executable file; ignoring it',
        tostring(self.yabaiPath)
      )
      self.yabaiResolved = false
    end
    return self.yabaiResolved or nil
  end

  for _, path in ipairs(YABAI_PATHS) do
    if executableFile(path) then
      self.yabaiResolved = path
      self.logger.f('found yabai at %s', path)
      return path
    end
  end

  self.yabaiResolved = false
  return nil
end

-- Run one yabai command. Calls done(ok, stdout, err) exactly once, or -- if the Spoon is
-- torn down mid-flight -- not at all, which is the same contract abortDrag() has.
--
-- The settled flag is load-bearing rather than defensive. Terminating a hung task does not
-- cancel its completion callback, it *causes* one, arriving a moment later carrying the exit
-- code of the signal. Without the flag a timed-out query would answer twice, and for this
-- Spoon answering twice means walking the move ladder twice and starting a drag nobody
-- asked for.
function obj:yabaiRun(args, done)
  local bin = self:yabaiBinary()
  if not bin then return done(false, nil, 'not installed') end

  local job = { task = nil, timer = nil, settled = false }
  self.yabaiTasks[job] = true

  local function finish(ok, out, err)
    if job.settled then return end
    job.settled = true
    if job.timer then pcall(function() job.timer:stop() end) end
    if job.task then pcall(function()
      if job.task:isRunning() then job.task:terminate() end
    end) end
    self.yabaiTasks[job] = nil
    done(ok, out, err)
  end

  -- The argument table is handed to execve verbatim with no shell in between, so nothing
  -- here needs quoting or escaping. That is most of the reason a move is two clean
  -- subprocesses rather than one shell pipeline.
  local okNew, made = pcall(hs.task.new, bin, function(code, out, err)
    if code == 0 then return finish(true, out, nil) end
    finish(
      false,
      out,
      string.format('exit %s%s', tostring(code), (type(err) == 'string' and err ~= '') and (': ' .. err:gsub('%s+$', '')) or '')
    )
  end, args)

  if not okNew or not made then return finish(false, nil, 'could not create the task (' .. tostring(made) .. ')') end
  -- Assigned before start(), so the completion callback can always find the task to reap.
  job.task = made

  local okStart, started = pcall(made.start, made)
  if not okStart or not started then return finish(false, nil, 'failed to launch') end

  -- Guarded, because a process that exits instantly can settle the job before we reach
  -- here, and an orphan timer holding a closure for a second and a half is untidy.
  if not job.settled then
    job.timer = hs.timer.doAfter(
      self.yabaiTimeout,
      function() finish(false, nil, string.format('no answer within %ss', tostring(self.yabaiTimeout))) end
    )
  end
end

--- SummonWindow:abortYabai() -> self
--- Method
--- Kills any yabai commands in flight and abandons whatever they were part of.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Called from `SummonWindow:stop()`. Each job is marked settled *before* its process is signalled, which is the whole point: terminating a task causes a completion callback rather than cancelling one, so without the flag a config reload would answer into a half-torn-down Spoon and walk the move ladder on into a drag nobody asked for.
function obj:abortYabai()
  local n = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then
      job.settled = true
      if job.timer then pcall(function() job.timer:stop() end) end
      if job.task then pcall(function()
        if job.task:isRunning() then job.task:terminate() end
      end) end
      n = n + 1
    end
  end
  self.yabaiTasks = {}
  self.yabaiPending = {}
  if n > 0 then self.logger.f('abandoned %d yabai command(s)', n) end
  return self
end

-- Ask yabai for its spaces or its windows, decoded.
--
-- Calls done(data, err) exactly once, with data nil on failure. `kind` is 'spaces' or
-- 'windows' and doubles as the query flag. `force` bypasses the cache.
function obj:yabaiQuery(kind, force, done)
  if not self:yabaiBinary() then return done(nil, 'not installed') end

  local hit = self.yabaiCache[kind]
  if not force and hit and (hs.timer.secondsSinceEpoch() - hit.at) < self.yabaiCacheSeconds then return done(hit.data, nil) end

  -- A recent failure is cached as firmly as a recent answer, and this one *is* checked even
  -- when forced. Retrying a socket that refused a connection ten milliseconds ago cannot
  -- succeed, and the caller that forced the query -- opening the chooser, or issuing a move
  -- -- is exactly the caller that should not be made to wait for it to fail again.
  if self.yabaiFailedAt and (hs.timer.secondsSinceEpoch() - self.yabaiFailedAt) < self.yabaiCacheSeconds then
    return done(nil, self.yabaiLastError or 'yabai failed a moment ago')
  end

  -- Join a query of the same kind already in flight rather than starting a second one.
  local waiting = self.yabaiPending[kind]
  if waiting then
    waiting[#waiting + 1] = done
    return
  end
  self.yabaiPending[kind] = { done }

  self:yabaiRun({ '--message', 'query', '--' .. kind }, function(ok, out, err)
    local data, why
    if not ok then
      -- A query is the first thing anything here runs, so a failure is overwhelmingly "the
      -- binary is installed but the service is not running". Worth exactly one line:
      -- someone who installed yabai meant it to work, and silently paying a second-long
      -- drag forever instead is not a kindness.
      why = err
      self.yabaiLastError = tostring(err)
      self.yabaiFailedAt = hs.timer.secondsSinceEpoch()
      self:warnOnce(
        'yabaiserver',
        'yabai is installed but not answering (%s); is the service running? ' .. 'Try `yabai --start-service`. Carrying on without it.',
        tostring(err)
      )
    else
      -- decode() raises on malformed input rather than returning nil.
      local okJson, decoded = pcall(hs.json.decode, out or '')
      if okJson and type(decoded) == 'table' then
        data = decoded
        self.yabaiLastError = nil
        self.yabaiFailedAt = nil
        self.yabaiCache[kind] = { at = hs.timer.secondsSinceEpoch(), data = decoded }
      else
        why = 'unparseable ' .. kind .. ' list'
        self:warnOnce('yabaijson', 'could not parse `yabai --message query --%s` output; the yabai CLI may have changed shape', kind)
      end
    end

    -- Taken and cleared before any callback runs, so that a waiter which itself queries
    -- starts a fresh round rather than appending to a list about to be discarded.
    local waiters = self.yabaiPending[kind] or {}
    self.yabaiPending[kind] = nil
    for _, cb in ipairs(waiters) do
      pcall(cb, data, why)
    end
  end)
end

-- The last known space and window lists, or nil when yabai has never answered.
function obj:yabaiSnapshot()
  local spaces = self.yabaiCache.spaces and self.yabaiCache.spaces.data
  local windows = self.yabaiCache.windows and self.yabaiCache.windows.data
  if not (spaces and windows) then return nil end
  return spaces, windows, self.yabaiCache.windows.at
end

--- SummonWindow:refreshYabai([force], [done]) -> self
--- Method
--- Re-reads yabai's space and window lists into the snapshot the window list is built from.
---
--- Parameters:
---  * force - Optional boolean, `true` to ignore `SummonWindow.yabaiCacheSeconds`. Defaults to `false`
---  * done - Optional function called with `true` when both lists were read, `false` otherwise
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * When yabai is switched off or not installed, `done` is called immediately and synchronously with `false`. That is what keeps every caller's behaviour identical to what it was before yabai existed.
function obj:refreshYabai(force, done)
  done = done or function() end
  if not self:yabaiBinary() then
    done(false)
    return self
  end
  self:yabaiQuery('spaces', force, function(spaces)
    self:yabaiQuery('windows', force, function(windows) done(spaces ~= nil and windows ~= nil) end)
  end)
  return self
end

-- Translate a window server Space id into the Mission Control index yabai speaks. Calls
-- done(index, err) exactly once, with index nil on failure.
--
-- Deliberately never cached. Mission Control indices renumber whenever a Space is created,
-- destroyed or dragged about, and a stale index does not fail -- it moves the window to the
-- *wrong Space*, which is a great deal worse than spending fifteen milliseconds.
function obj:yabaiSpaceIndex(spaceId, done)
  self:yabaiQuery('spaces', true, function(spaces, err)
    if not spaces then return done(nil, err or 'no answer from yabai') end
    local idToIndex = yabaiSpaceMaps(spaces)
    local index = idToIndex[spaceId]
    if index then return done(index, nil) end
    self:warnOnce(
      'yabaispace',
      'yabai does not list Space %s; its idea of the Space layout disagrees with ' .. 'hs.spaces, so yabai is skipped for moves onto it',
      tostring(spaceId)
    )
    done(nil, string.format('Space %s is unknown to yabai', tostring(spaceId)))
  end)
end

-- Move a window with yabai. Calls done(ok, err) exactly once.
--
-- `ok` means only "yabai accepted the command". The move itself travels through the
-- scripting addition injected into Dock.app, and on recent macOS builds that injection can
-- be present, exit zero, and do nothing whatsoever -- so the caller verifies arrival
-- afterwards, exactly as it does for the rungs either side of this one.
function obj:yabaiMove(winId, target, done)
  self:yabaiSpaceIndex(target, function(index, err)
    if not index then return done(false, err) end
    -- Formatted with %d rather than tostring(): a window id that round-tripped through JSON
    -- as a float would otherwise reach yabai as "4713.0", which it rejects.
    self:yabaiRun({
      '-m',
      'window',
      string.format('%d', math.floor(winId)),
      '--space',
      string.format('%d', index),
    }, function(ok, _, moveErr)
      if not ok then
        -- yabai's own stderr is the genuinely diagnostic part here: it distinguishes a
        -- missing scripting addition from a window yabai cannot see.
        self:warnOnce('yabaimove', 'yabai refused the move (%s)', tostring(moveErr))
      end
      done(ok, moveErr)
    end)
  end)
end

-- Focus a window through yabai. Only for windows with no hs.window behind them, and only
-- ever on a path where arrival has already been verified.
function obj:yabaiFocus(winId)
  self:yabaiRun({ '--message', 'window', string.format('%d', math.floor(winId)), '--focus' }, function(ok, _, err)
    if not ok then self.logger.f('yabai could not focus window %s (%s)', tostring(winId), tostring(err)) end
  end)
end

--------------------------------------------------------------------------------
-- Finding windows on other Spaces
--------------------------------------------------------------------------------

-- The union of every source that can hand back a real hs.window object.
--
-- Neither source is sufficient alone. hs.window.filter accumulates knowledge of windows
-- across Spaces, but only learns about a window once it has seen the Space it lives on or
-- the window has been interacted with -- so it is partly blind after a config reload.
-- hs.window.allWindows() queries applications live, which covers windows the filter never
-- witnessed, but is documented as being limited to the current Space (that is a statement
-- about what Accessibility reliably exposes rather than a hard filter, so in practice it
-- often reaches further -- run diagnose() to see what it actually manages here).
--
-- The sweep goes through hs.window.allWindows() rather than iterating
-- hs.application.runningApplications() by hand, because allWindows() carries a skip list
-- for applications known to blow macOS's 6-second limit on answering AX queries.
--
-- `deep` overrides SummonWindow.deepScan for one call, and exists for the menubar path: the
-- skip list above is there because allWindows() can take seconds, and hs.menubar demands
-- its menu synchronously, so running the sweep inside that callback beachballs Hammerspoon
-- for as long as the slowest application takes to answer. Pass nil to use the setting.
function obj:knownWindows(deep)
  if deep == nil then deep = self.deepScan end
  local seen, out = {}, {}

  local function add(win)
    if not win then return end
    local ok, id = pcall(win.id, win)
    if not ok or not id or seen[id] then return end
    seen[id] = true
    out[#out + 1] = win
  end

  if self.windowFilter then
    local ok, wins = pcall(self.windowFilter.getWindows, self.windowFilter)
    if ok and type(wins) == 'table' then
      for _, win in ipairs(wins) do
        add(win)
      end
    else
      self:warnOnce('filter', 'window filter query failed (%s)', tostring(wins))
    end
  end

  if deep then
    local ok, wins = pcall(hs.window.allWindows)
    if ok and type(wins) == 'table' then
      for _, win in ipairs(wins) do
        add(win)
      end
    else
      self:warnOnce('allWindows', 'hs.window.allWindows failed (%s)', tostring(wins))
    end
  end

  return out
end

-- Decide whether one window belongs in the list, and describe it if so. Returns nil for
-- anything unsummonable, so the caller can simply skip falsy results.
--
-- Accessors are called bare rather than through pcall: candidates() already wraps this
-- whole function, so a window that dies mid-inspection is caught in one place instead of
-- six, and the failure is logged rather than being mistaken for "not summonable".
function obj:classify(win, current, model)
  if not win:isStandard() then return nil end

  local app = win:application()
  if app and app:bundleID() == hs.processInfo.bundleID then return nil end

  -- Fullscreen is checked twice, here on the window and below on its Space. The window
  -- test catches the app that is fullscreen right now; the Space test catches windows
  -- parked in a fullscreen or tiled Space that do not report it themselves.
  if win:isFullScreen() then return nil end

  local minimized = win:isMinimized()
  if minimized and not self.includeMinimized then return nil end

  local spaces = self:spacesFor(win)
  if not spaces or #spaces == 0 then return nil end

  -- Already here. This also correctly drops sticky windows, which report every Space and
  -- therefore always contain the current one -- they are visible here already.
  if hs.fnutils.contains(spaces, current) then return nil end

  -- Prefer the first Space we could actually move the window out of.
  local spaceId = firstMovableSpace(spaces, model.types)
  if not spaceId then return nil end

  local title = win:title() or ''
  return {
    winId = win:id(),
    spaceId = spaceId,
    appName = (app and app:name()) or '?',
    bundleID = app and app:bundleID() or nil,
    title = title,
    minimized = minimized,
    label = model.labels[spaceId] or string.format('Space %s', tostring(spaceId)),
    -- Unplaceable Spaces sort last rather than erroring out of table.sort().
    order = model.order[spaceId] or math.huge,
  }
end

-- The windows yabai knows about that the Accessibility sources did not hand us.
--
-- yabai's server tracks every window on every Space continuously, so its list does not
-- depend on what macOS is willing to tell this process at the moment we ask -- which is
-- exactly the blindness :diagnose() exists to explain. Two kinds of thing come out of it.
-- Most are windows Accessibility would have produced if asked about the right application,
-- and those are recovered as real hs.window objects so that every rung of the move ladder
-- still applies. The rest cannot be recovered at all; those are listed anyway, because
-- yabai moves a window by id and needs no window object, but they are marked so the ladder
-- knows to skip the two rungs that do need one.
--
-- The rejections below deliberately mirror classify() rather than calling it. classify()
-- settles a window's Space with hs.spaces.windowSpaces(), which needs an hs.window and is
-- blind in the same way the enumeration is, so putting these windows through it would
-- discard the very ones worth having. yabai's own flags answer the same questions, and
-- answer them for windows Accessibility cannot see.
function obj:yabaiEntries(current, model, seen)
  local out = {}
  local spaces, windows = self:yabaiSnapshot()
  if not (spaces and windows) then return out end

  local _, indexToId = yabaiSpaceMaps(spaces)

  -- pid -> { app, windows = { id -> hs.window } }, memoised for this pass. An application
  -- with eight windows out there should cost one AX query, not eight.
  local apps = {}
  local function appFor(pid)
    if type(pid) ~= 'number' then return nil end
    if apps[pid] then return apps[pid] end

    local entry = { app = false, windows = {} }
    local okApp, app = pcall(hs.application.applicationForPID, pid)
    if okApp and app then
      entry.app = app
      -- One application's AX query rather than the whole system's, which is what makes this
      -- affordable where hs.window.allWindows() on its own already was not.
      local okWins, wins = pcall(app.allWindows, app)
      if okWins and type(wins) == 'table' then
        for _, w in ipairs(wins) do
          local okId, id = pcall(w.id, w)
          if okId and id then entry.windows[id] = w end
        end
      end
    end
    apps[pid] = entry
    return entry
  end

  for _, w in ipairs(windows) do
    local id = (type(w) == 'table' and type(w.id) == 'number') and math.floor(w.id) or nil
    -- is-sticky windows report every Space and so are already here; is-hidden is the whole
    -- application being hidden, which is not something summoning can undo.
    if
      id
      and not seen[id]
      and w.pid ~= hs.processInfo.processID
      and w.role == 'AXWindow'
      and w.subrole == 'AXStandardWindow'
      and not w['is-sticky']
      and not w['is-native-fullscreen']
      and not w['is-hidden']
      and (self.includeMinimized or not w['is-minimized'])
    then
      local spaceId = type(w.space) == 'number' and indexToId[math.floor(w.space)] or nil
      if spaceId and spaceId ~= current and model.types[spaceId] ~= 'fullscreen' then
        seen[id] = true

        local app = appFor(w.pid)
        local win = app and app.windows[id] or nil
        local bundleID
        if app and app.app then
          local okB, b = pcall(app.app.bundleID, app.app)
          if okB then bundleID = b end
        end

        out[#out + 1] = {
          win = win,
          entry = {
            winId = id,
            spaceId = spaceId,
            appName = w.app or '?',
            bundleID = bundleID,
            title = w.title or '',
            minimized = w['is-minimized'] and true or false,
            label = model.labels[spaceId] or string.format('Space %s', tostring(spaceId)),
            order = model.order[spaceId] or math.huge,
            -- No hs.window behind it, so only the yabai rung can move this one.
            yabaiOnly = win == nil,
          },
        }
      end
    end
  end

  return out
end

--- SummonWindow:candidates([opts]) -> table
--- Method
--- Returns the windows currently living on other Spaces, in the order they are listed.
---
--- Parameters:
---  * opts - an optional table; `deep` overrides `SummonWindow.deepScan` for this call
---
--- Returns:
---  * A list of plain tables with `winId`, `spaceId`, `appName`, `bundleID`, `title`, `minimized`, `label`, `order` and `yabaiOnly` keys
---
--- Notes:
---  * Rebuilds from scratch on every call, and as a side effect refreshes the internal id-to-window map that `SummonWindow:summonById()` reads.
---  * The yabai source is served from the last snapshot rather than fetched here, because `hs.menubar` demands its menu synchronously and cannot wait for a subprocess. `SummonWindow:show()` refreshes before it builds, so the chooser is always current; the menubar menu can be up to `SummonWindow.yabaiCacheSeconds` behind.
---  * The menubar path passes `deep = false` for the same reason: the `hs.window.allWindows()` sweep can take seconds, and the menu callback cannot wait for it either. The chooser, `status()` and `diagnose()` all still run the full sweep.
function obj:candidates(opts)
  local current = self:currentSpace()
  if not current then return {} end

  local model = self:spaceModel()
  local entries = {}
  -- Built into locals and published together at the end, rather than cleared in place. An
  -- open chooser holds winIds that only resolve through these tables, and anything that
  -- rebuilds the list while it is open -- clicking the menubar item, status(), diagnose()
  -- -- would otherwise empty them out from under the rows the user is still looking at.
  local byId = {}
  -- Kept alongside byId so a failure message can still name the app and Space of a window
  -- that has since become uninspectable.
  local lastEntries = {}

  -- Every id the Accessibility sources produced, whatever classify() then decided about it.
  -- yabai is only ever allowed to *add* windows those sources could not see at all: a window
  -- Accessibility handed us and classify() rejected has already been ruled on, and letting
  -- yabai resurrect it would quietly undo that ruling.
  local seen = {}

  for _, win in ipairs(self:knownWindows(opts and opts.deep)) do
    local okId, id = pcall(win.id, win)
    if okId and id then seen[id] = true end

    -- Wrapped per window: a window closed between being enumerated and being inspected
    -- leaves a stale userdata whose accessors throw, and one dead window should cost one
    -- row rather than the whole list.
    local ok, entry = pcall(self.classify, self, win, current, model)
    if not ok then
      self:warnOnce('classify', 'window inspection failed (%s); skipping', tostring(entry))
    elseif entry then
      byId[entry.winId] = win
      lastEntries[entry.winId] = entry
      entries[#entries + 1] = entry
    end
  end

  local okYabai, found = pcall(self.yabaiEntries, self, current, model, seen)
  if not okYabai then
    self:warnOnce('yabaientries', "reading yabai's window list failed (%s); skipping it", tostring(found))
  else
    for _, item in ipairs(found) do
      -- win is nil for a window only yabai can see. byId simply has no entry for it, which
      -- is why summonById reads lastEntries as its authority instead.
      byId[item.entry.winId] = item.win
      lastEntries[item.entry.winId] = item.entry
      entries[#entries + 1] = item.entry
    end
  end

  -- Leave a warmer snapshot behind for the next build. Not forced, so repeated calls inside
  -- the cache window cost nothing.
  self:refreshYabai(false)

  -- Published only now that both tables are complete, so a row picked from an open chooser
  -- never resolves against a half-built map.
  self.byId, self.lastEntries = byId, lastEntries

  table.sort(entries, bySpaceThenApp)
  return entries
end

--------------------------------------------------------------------------------
-- Chooser
--------------------------------------------------------------------------------

function obj:choiceList()
  local entries = self:candidates()

  if #entries == 0 then
    -- valid = false keeps the row from dismissing the chooser when it is selected.
    return {
      {
        text = 'No windows on other Spaces',
        subText = 'Everything is already here — or run SummonWindow:diagnose() in the Console',
        valid = false,
      },
    }
  end

  local icons, out = {}, {}
  for _, e in ipairs(entries) do
    out[#out + 1] = {
      text = e.title ~= '' and e.title or e.appName,
      subText = string.format('%s — %s%s', e.appName, e.label, e.minimized and ' (minimized)' or ''),
      image = self:iconFor(e.bundleID, icons),
      -- Only plain values survive the trip into the chooser and back; the window itself
      -- lives in self.byId under this key.
      winId = e.winId,
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection.
    if not choice or not choice.winId then return end
    self:summonById(choice.winId)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  self.chooser:searchSubText(true)
  self.chooser:placeholderText('Summon a window from another Space…')
  return self.chooser
end

--------------------------------------------------------------------------------
-- Menubar
--------------------------------------------------------------------------------

function obj:buildMenu()
  local menu = {}
  -- deep = false: hs.menubar demands this table synchronously, so the allWindows() sweep
  -- would block the main thread until every application has answered. Same bargain the
  -- yabai snapshot already makes here -- a menu that can be slightly behind beats a menu
  -- that beachballs.
  local entries = self:candidates({ deep = false })

  if #entries == 0 then
    menu[#menu + 1] = { title = 'No windows on other Spaces', disabled = true }
  else
    local icons, lastLabel = {}, nil
    for _, e in ipairs(entries) do
      if e.label ~= lastLabel then
        if lastLabel then menu[#menu + 1] = { title = '-' } end
        menu[#menu + 1] = { title = e.label, disabled = true }
        lastLabel = e.label
      end

      -- winId is copied into a local: closing over `e` would keep the whole entry alive
      -- for as long as the menu exists, and the id is the real identity anyway.
      local winId = e.winId
      menu[#menu + 1] = {
        title = string.format('%s — %s', e.appName, truncate(e.title, self.titleMax)),
        image = self:iconFor(e.bundleID, icons, 16),
        indent = 1,
        fn = function() self:summonById(winId) end,
      }
    end
  end

  menu[#menu + 1] = { title = '-' }
  menu[#menu + 1] = { title = 'Search…', fn = function() self:show() end }
  return menu
end

--------------------------------------------------------------------------------
-- Synthetic input
--------------------------------------------------------------------------------

local ET = hs.eventtap.event
local TY = ET.types
local PR = ET.properties

-- Press the left button. clickState is set by hand because the event constructor leaves
-- it at zero, which makes NSEvent report a clickCount of 0; Chromium-derived apps read
-- that as "not a real click" and ignore the press.
local function mouseDown(pt)
  local e = ET.newMouseEvent(TY.leftMouseDown, pt)
  pcall(function() e:setProperty(PR.mouseEventClickState, 1) end)
  e:post()
end

-- A drag of dx pixels, carrying an explicit delta.
--
-- This tiny event is what makes the whole routine work. macOS does not consider a window
-- to be in a move gesture until a drag *follows* the press, and applications that hit-test
-- their own titlebars -- Telegram, and Qt or Electron shells generally -- ignore a press
-- with no drag behind it. Without this the Space switches happen and the window stays put.
local function mouseDrag(pt, dx)
  local e = ET.newMouseEvent(TY.leftMouseDragged, { x = pt.x + dx, y = pt.y })
  pcall(function()
    e:setProperty(PR.mouseEventDeltaX, dx)
    e:setProperty(PR.mouseEventDeltaY, 0)
  end)
  e:post()
end

local function mouseUp(pt) ET.newMouseEvent(TY.leftMouseUp, pt):post() end

-- Warp the pointer, then announce that it moved. hs.mouse.absolutePosition is a warp: it
-- relocates the cursor without generating a move event, so anything listening for one
-- never learns the pointer is somewhere new. Posting the event as well costs nothing and
-- satisfies both kinds of observer.
local function placeCursor(pt)
  hs.mouse.absolutePosition(pt)
  ET.newMouseEvent(TY.mouseMoved, pt):post()
end

-- Release a ctrl we are holding down, at most once. Idempotent, because both the normal
-- end of an arrow and every teardown path call it and either may get there first.
local function releaseCtrl(job)
  if not job.ctrlDown then return end
  job.ctrlDown = false
  pcall(function() ET.newKeyEvent('ctrl', false):post() end)
end

-- One Space-switch arrow, emitted the way a keyboard would: modifier down, key down
-- carrying the whole mask, key up, modifier up.
--
-- The ctrl-up is the dangerous half. It is posted from a timer, so a teardown during the
-- ~2*keyHold this takes -- a config reload, hs.reload() bound to a hotkey, stop() -- would
-- collect the timer and strand ctrl down system-wide with nothing left to release it. That
-- is the same hazard abortDrag() already guards for the mouse button, so it is handled the
-- same way: the timers are registered on the job so teardown can stop them, and job.ctrlDown
-- records that a release is owed so teardown can pay it.
local function pressSpaceArrow(job, dir, useFn, keyHold, done)
  local mods = useFn and { 'ctrl', 'fn' } or { 'ctrl' }
  ET.newKeyEvent('ctrl', true):post()
  job.ctrlDown = true
  job.timer = hs.timer.doAfter(keyHold, function()
    if job.finished then return end
    ET.newKeyEvent(mods, dir, true):post()
    job.timer = hs.timer.doAfter(keyHold, function()
      if job.finished then return end
      ET.newKeyEvent(mods, dir, false):post()
      releaseCtrl(job)
      done()
    end)
  end)
end

--------------------------------------------------------------------------------
-- Dragging a window across Spaces
--------------------------------------------------------------------------------

-- Where to take hold of a window: the dead strip at the far left of the titlebar, left of
-- the close button and above the resize edge.
--
-- Every published implementation of this trick picks a different point and each is wrong
-- somewhere. Grabbing the horizontal centre lands in a browser's tab strip, so with enough
-- tabs open you tear off a tab instead of moving the window. A hardcoded titlebar height
-- misses on compact and unified toolbars. Aiming just off the zoom button leaves one pixel
-- of margin before you click it. Reading the close button's own frame avoids all three: it
-- gives a true centre line for any titlebar style, and the space to its left is guaranteed
-- draggable chrome in every app.
function obj:grabPoint(win)
  local okF, f = pcall(win.frame, win)
  if not okF or not f then return nil, 'window has no frame' end

  local ok, ax = pcall(hs.axuielement.windowElement, win)
  if ok and ax then
    local okB, btn = pcall(function() return ax.AXCloseButton end)
    local cf = okB and btn and btn.AXFrame
    if cf and cf.x and cf.h and cf.h > 0 then
      return {
        x = math.floor(f.x + (cf.x - f.x) / 2),
        y = math.floor(cf.y + cf.h / 2),
      }
    end
  end

  -- No accessible close button: derive it from the zoom button instead. The three lights
  -- sit 20pt apart, so the close button's left edge is about 40pt to the zoom button's.
  local okZ, zr = pcall(win.zoomButtonRect, win)
  if okZ and type(zr) == 'table' and zr.x and zr.h and zr.h > 0 then
    return {
      x = math.floor(f.x + math.max(6, (zr.x - 40 - f.x) / 2)),
      y = math.floor(zr.y + zr.h / 2),
    }
  end

  -- Neither means the window genuinely has no titlebar -- a terminal with decorations
  -- turned off, an undecorated editor frame. There is nothing to take hold of, and
  -- guessing a point would press into the application's own content.
  return nil, 'window has no titlebar to grab'
end

-- The full Mission Control ordering for the window's screen. It has to be the full list
-- rather than just the user Spaces, because the arrow keys step through fullscreen Spaces
-- too and counting only user Spaces would stop short.
function obj:spaceOrder(win)
  local scr = win:screen()
  local uuid = scr and scr:getUUID()
  if not uuid then return nil, 'window is not on any screen' end
  local ok, list = pcall(hs.spaces.spacesForScreen, uuid)
  if not ok or type(list) ~= 'table' or #list == 0 then return nil, 'could not read the Space order for this screen' end
  return list
end

local function indexOf(list, id)
  for i, v in ipairs(list) do
    if v == id then return i end
  end
  return nil
end

-- Each Space id we expect to land on, in order. Precomputing the whole route is what
-- allows every hop to be gated on actually arriving somewhere known, rather than on a
-- hopeful delay -- and it is only sound because macOS is not rearranging Spaces by use.
local function pathBetween(order, fromIdx, toIdx)
  local step = (toIdx > fromIdx) and 1 or -1
  local path = {}
  for i = fromIdx + step, toIdx, step do
    path[#path + 1] = order[i]
  end
  return path, (step == 1) and 'right' or 'left'
end

--- SummonWindow:abortDrag() -> self
--- Method
--- Releases the mouse button and abandons any drag in progress.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Called from `SummonWindow:stop()`. A config reload part-way through a drag would otherwise collect the timers that hold the sequence together and leave the button down with nothing left to release it.
function obj:abortDrag()
  local job = self.dragJob
  if job and not job.finished then
    job.finished = true
    if job.holding then pcall(mouseUp, hs.mouse.absolutePosition()) end
    releaseCtrl(job)
    if job.watchdog then pcall(function() job.watchdog:stop() end) end
    if job.timer then pcall(function() job.timer:stop() end) end
    pcall(hs.mouse.absolutePosition, job.cursor)
    self.dragJob = nil
    self.logger.w('drag aborted')
  end
  return self
end

-- Carry a window here by hand, because the window server will not do it for us.
--
-- The shape is forced by one fact: a window can only be picked up while it is on the
-- visible Space. So this walks to the window empty-handed, takes hold of it, and walks
-- back still holding it. Both legs use the same keyboard shortcut rather than
-- hs.spaces.gotoSpace(), which would open Mission Control -- and mouse events are not
-- delivered at all while Mission Control is up, which would break the return leg outright.
--
-- Calls done(ok, err) exactly once.
function obj:dragToCurrentSpace(win, done)
  local T = self.dragTiming

  if self.dragJob then return done(false, 'a drag is already in progress') end
  if hs.eventtap.isSecureInputEnabled() then
    -- A focused password field anywhere on the system swallows synthetic keystrokes, so
    -- the Space switches would quietly do nothing with the window held mid-air.
    return done(false, 'secure input is active, so Space switches would be ignored')
  end

  local okHere, here = pcall(hs.spaces.focusedSpace)
  if not okHere or type(here) ~= 'number' then return done(false, 'could not determine the current Space') end
  local spaces = self:spacesFor(win)
  if not spaces or #spaces == 0 then return done(false, "could not determine the window's Space") end
  local from = firstMovableSpace(spaces, self:spaceModel().types)
  if not from then return done(false, 'the window is only on a fullscreen Space, which it cannot be dragged out of') end

  local order, oErr = self:spaceOrder(win)
  if not order then return done(false, oErr) end
  local iFrom, iHere = indexOf(order, from), indexOf(order, here)
  if not (iFrom and iHere) then return done(false, 'the window is on a different display; dragging across screens does not work') end

  local outPath, outDir = pathBetween(order, iHere, iFrom) -- empty-handed, to fetch it
  local backPath, backDir = pathBetween(order, iFrom, iHere) -- loaded, bringing it home

  ------------------------------------------------------------------------------
  -- From here a mouse button may be held down, so there is exactly one exit path
  -- and it always releases. Three things can end the job: finishing, a step
  -- throwing, or the watchdog -- and all three go through finish().
  ------------------------------------------------------------------------------

  local job = {
    homeSpace = here,
    cursor = hs.mouse.absolutePosition(),
    frame = nil,
    grab = nil,
    holding = false,
    finished = false,
    ctrlDown = false,
    watchdog = nil,
    timer = nil,
    dragSign = 1,
  }
  self.dragJob = job

  local function finish(ok, err)
    if job.finished then return end
    job.finished = true

    -- Release first, before anything that could itself fail.
    if job.holding then
      pcall(mouseUp, hs.mouse.absolutePosition())
      job.holding = false
    end
    releaseCtrl(job)
    if job.watchdog then pcall(function() job.watchdog:stop() end) end
    if job.timer then pcall(function() job.timer:stop() end) end
    self.dragJob = nil

    hs.timer.doAfter(T.postRelease, function()
      -- Undo the pixel nudges that armed the gesture. The alternating sign should have
      -- cancelled them out already, but an app that snapped the window mid-drag will
      -- have moved it regardless.
      if job.frame then
        local okVis, visible = pcall(win.isVisible, win)
        if okVis and visible then pcall(win.setFrame, win, job.frame) end
      end
      pcall(hs.mouse.absolutePosition, job.cursor)
      done(ok, err)
    end)
  end

  -- Run one step under pcall. This is not belt and braces: hs.timer callbacks execute in a
  -- protected context, so an error inside one is logged and swallowed rather than raised.
  -- Without this a throw would simply stop the sequence, silently, with the button still
  -- down, and only the watchdog seconds later would rescue it.
  local function step(fn)
    return function()
      if job.finished then return end
      local ok, err = pcall(fn)
      if not ok then finish(false, tostring(err)) end
    end
  end

  local hops = #outPath + #backPath
  job.watchdog = hs.timer.doAfter(2.0 + (T.hopTimeout + 0.3) * hops, function() finish(false, 'the drag stalled and was abandoned') end)

  -- One hop, gated on arriving somewhere known.
  --
  -- Firing several arrows in a row does not work: the window server drops Space-switch
  -- input while a switch is already animating, so a burst of N presses yields one or two
  -- hops with no way to tell which. Waiting for each landing turns an unreliable burst
  -- into a series of reliable steps.
  local function hop(dir, expectId, onOk)
    pressSpaceArrow(job, dir, self.useFnModifier, T.keyHold, function()
      local deadline = hs.timer.secondsSinceEpoch() + T.hopTimeout
      local function arrived()
        local ok, cur = pcall(hs.spaces.focusedSpace)
        return ok and cur == expectId
      end
      job.timer = hs.timer.waitUntil(function() return arrived() or hs.timer.secondsSinceEpoch() > deadline end, function()
        if not arrived() then
          local _, cur = pcall(hs.spaces.focusedSpace)
          return finish(false, string.format('Space switch timed out (wanted %s, still on %s)', tostring(expectId), tostring(cur)))
        end
        hs.timer.doAfter(T.hopSettle, step(onOk))
      end, T.hopPoll)
    end)
  end

  -- Walk a whole route, keeping the gesture alive between hops while carrying something.
  -- Each landing gets a fresh drag event so the gesture cannot lapse mid-journey, and the
  -- sign alternates so the nudges cancel out instead of accumulating.
  local function walk(path, dir, i, onDone)
    if i > #path then return onDone() end
    hop(dir, path[i], function()
      if job.holding and job.grab then
        mouseDrag(job.grab, job.dragSign)
        job.dragSign = -job.dragSign
      end
      walk(path, dir, i + 1, onDone)
    end)
  end

  local function release()
    hs.timer.doAfter(
      T.preRelease,
      step(function()
        mouseUp(hs.mouse.absolutePosition())
        job.holding = false
        finish(true, nil)
      end)
    )
  end

  local function grabAndReturn()
    pcall(win.unminimize, win)
    pcall(win.raise, win)
    pcall(win.focus, win)

    hs.timer.doAfter(
      T.raiseSettle,
      step(function()
        -- Raising matters more than it looks. If another window overlaps the grab point and
        -- this one is not on top, we would take hold of the wrong window entirely.
        local pt, gErr = self:grabPoint(win)
        if not pt then return finish(false, gErr) end

        job.grab = pt
        job.frame = win:frame()

        placeCursor(pt)
        hs.timer.doAfter(
          T.warpSettle,
          step(function()
            mouseDown(pt)
            job.holding = true -- set the instant the button goes down, so every exit releases

            hs.timer.doAfter(
              T.downToDrag,
              step(function()
                mouseDrag(pt, 1)
                job.dragSign = -1
                hs.timer.doAfter(T.dragToHop, step(function() walk(backPath, backDir, 1, release) end))
              end)
            )
          end)
        )
      end)
    )
  end

  self.logger.f('dragging window %s home: %d hop(s) %s to fetch, %d back', tostring(win:id()), #outPath, outDir, #backPath)
  walk(outPath, outDir, 1, grabAndReturn)
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

--- SummonWindow:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Deliberately starts nothing. The menubar item, the chooser and the window filter all belong to `SummonWindow:start()`.
---  * It is also deliberately empty rather than re-initialising state. The declarations above already run on a freshly loaded object, and `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load -- so clearing state here would strand a chooser or menubar item that is already live.
function obj:init() return self end

--- SummonWindow:start() -> self
--- Method
--- Adds the menubar item and begins tracking windows across Spaces.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Calling this on an already-started Spoon restarts it cleanly.
---  * Nothing polls and no timer runs. The window list is built on demand, when the chooser opens or the menu is pulled down.
---  * Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  -- A copy of the default filter, which already discards menulets, launchers, preference
  -- panes and the other non-windows that would otherwise pad the list.
  --
  -- setCurrentSpace(nil) is already the default, but it is spelled out because it is the
  -- exact property this Spoon depends on: the filter must NOT be restricted to the
  -- current Space. It is started here rather than lazily so that it has the whole session
  -- to accumulate knowledge of Spaces before the first time anyone opens the list.
  self.windowFilter = hs.window.filter.new()
  self.windowFilter:setCurrentSpace(nil)
  self.windowFilter:rejectApp('Hammerspoon')

  -- Deliberately NOT setting hs.window.filter.forceRefreshOnSpaceChange = true. That flag
  -- is global, so it would also tax the filters FocusBorder and PinnedWindows keep alive,
  -- on every Space change, forever. The hs.window.allWindows() sweep in knownWindows()
  -- buys the same coverage on demand instead of paying for it continuously.

  self.byId = {}

  if self.showInMenubar then
    -- The autosave name stays lower-case and distinct from "pinnedwindows": it is what
    -- macOS keys the item's saved position in the menu bar on, so it has to be unique and
    -- must never be renamed afterwards.
    self.menubarItem = hs.menubar.new(true, 'summonwindow')
    if self.menubarItem then
      self.menubarItem:setTitle(self.menubarTitle)
      self.menubarItem:setTooltip('Summon a window from another Space')
      -- Wrapped: an error thrown inside the menu callback would otherwise leave a dead
      -- menubar icon with no way to recover short of reloading the config.
      --
      -- Setting a menu also disables setClickCallback, by design -- a click opens this
      -- menu, and "Search…" at the bottom of it opens the chooser.
      self.menubarItem:setMenu(function(mods)
        local ok, menu = pcall(self.buildMenu, self, mods)
        if ok then return menu end
        self.logger.wf('menu build failed: %s', tostring(menu))
        return {
          { title = 'Menu failed to build — see console', disabled = true },
          { title = '-' },
          { title = 'Search…', fn = function() self:show() end },
        }
      end)
    else
      self.logger.w('could not create the menubar item')
    end
  end

  self.running = true

  if not hs.accessibilityState() then
    hs.alert.show('SummonWindow needs Accessibility permission')
    self.logger.w('accessibility permission not granted; nothing will work until it is')
  end
  if not (hs.spaces and hs.spaces.moveWindowToSpace) then
    self.logger.w('hs.spaces.moveWindowToSpace is unavailable; relying on yabai and dragging')
  end

  -- Warm the yabai snapshot now rather than on the first summon, so the first list built
  -- after a config reload is as complete as every list after it. Costs nothing and returns
  -- immediately when yabai is not installed.
  self:refreshYabai(true)

  self.logger.i('started')
  return self
end

--- SummonWindow:stop() -> self
--- Method
--- Removes the menubar item, destroys the chooser and drops the window filter.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Any hotkeys bound with `SummonWindow:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped: a drag in flight is holding a mouse button down and
  -- the timers that would release it are about to become unreachable, and a yabai command in
  -- flight is holding a subprocess whose completion would otherwise answer into a
  -- half-torn-down Spoon -- and, worse, walk the move ladder on into a drag.
  self:abortDrag()
  self:abortYabai()
  self.pendingGoto = nil

  if self.menubarItem then
    self.menubarItem:delete()
    self.menubarItem = nil
  end

  if self.chooser then
    pcall(self.chooser.hide, self.chooser)
    pcall(self.chooser.delete, self.chooser)
    self.chooser = nil
  end

  -- No unsubscribe needed: this Spoon never subscribes to filter events, it only queries.
  -- Dropping the reference is enough, and the global window watcher underneath is
  -- refcounted, so the filters the other Spoons hold are unaffected.
  self.windowFilter = nil

  self.byId = {}
  self.lastEntries = {}
  self.warned = {}
  self.yabaiCache = {}
  self.yabaiLastError = nil
  self.yabaiFailedAt = nil
  -- Re-probed on the next start(), so installing yabai and reloading the config is all it
  -- takes for this Spoon to notice it -- and so is starting its service, since the backoff
  -- above goes with it.
  self.yabaiResolved = nil
  self.running = false
  self.logger.i('stopped')
  return self
end

--- SummonWindow:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for SummonWindow.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * summon - Show the window chooser, or hide it if it is already showing
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * For example: `spoon.SummonWindow:bindHotkeys({ summon = { { "cmd", "alt", "shift" }, "S" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    summon = hs.fnutils.partial(self.toggle, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display.
  self.mapping = mapping
  return self
end

--- SummonWindow:show() -> self
--- Method
--- Opens the chooser, listing every window on another Space.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * Refuses to open while you are on a fullscreen Space, because the window server will not accept a window moved into one.
---  * When yabai is in use the chooser opens a few milliseconds late, because it waits for a current window list rather than showing a cached one. Without yabai it opens synchronously, exactly as it always did.
function obj:show()
  local target, why = self:summonableSpace()
  if not target then
    hs.alert.show('SummonWindow: ' .. why)
    self.logger.wf('cannot show chooser: %s', why)
    return self
  end

  -- The chooser is the hotkey path and the one people search in, so it is worth a few
  -- milliseconds to open against a current picture rather than a cached one. With yabai
  -- absent this calls straight back on this same stack, so nothing about the old behaviour
  -- changes -- including that show() has finished by the time it returns.
  self:refreshYabai(true, function()
    local chooser = self:ensureChooser()
    -- Choices are handed over as a static table rather than a callback, so that the list is
    -- rebuilt on every open. A callback would be cached until refreshChoicesCallback().
    chooser:choices(self:choiceList())
    chooser:query('')
    chooser:show()
  end)
  return self
end

--- SummonWindow:hide() -> self
--- Method
--- Closes the chooser if it is open.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
function obj:hide()
  if self.chooser then self.chooser:hide() end
  return self
end

--- SummonWindow:toggle() -> self
--- Method
--- Opens the chooser, or closes it if it is already open. This is what the hotkey is bound to.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * If the last summon failed and left an offer to jump to that window's Space, pressing the hotkey again within `SummonWindow.gotoGraceSeconds` takes the offer instead of reopening the chooser. The offer is consumed either way, so a third press behaves normally.
function obj:toggle()
  if self.chooser and self.chooser:isVisible() then return self:hide() end
  -- Checked before anything else: this is the "press again to go there" half of the
  -- failure path, and it must win over reopening the chooser.
  if self:takePendingGoto() then return self end
  return self:show()
end

-- Did the window actually land? The one question the whole Spoon turns on.
--
-- With an hs.window this is awaitArrival() as it always was. Without one -- a window only
-- yabai could see -- hs.spaces.windowSpaces() has nothing to take, so yabai is asked where
-- the window is instead. That poll is deliberately slower than awaitArrival's: each tick is
-- a subprocess rather than a function call.
function obj:confirmArrival(win, winId, target, timeout, done)
  if win then return self:awaitArrival(win, target, timeout, done) end

  self:yabaiSpaceIndex(target, function(index)
    if not index then return done(false) end
    local deadline = hs.timer.secondsSinceEpoch() + (timeout or 0.6)
    local function poll()
      self:yabaiRun({ '--message', 'query', '--windows', '--window', string.format('%d', math.floor(winId)) }, function(ok, out)
        local landed = false
        if ok then
          local okJson, w = pcall(hs.json.decode, out or '')
          landed = okJson and type(w) == 'table' and type(w.space) == 'number' and math.floor(w.space) == index
        end
        if landed or hs.timer.secondsSinceEpoch() > deadline then return done(landed) end
        hs.timer.doAfter(0.15, poll)
      end)
    end
    poll()
  end)
end

--------------------------------------------------------------------------------
-- The move ladder
--------------------------------------------------------------------------------

-- Every way this Spoon knows to move a window, in the order they are tried: least intrusive
-- and most likely first, most intrusive last. This list *is* the control flow -- a fourth
-- way to move a window should mean a fourth table here and nothing else.
--
-- `run` reports only whether it managed to issue its request. It never reports success,
-- because all three of these lie: the native call returns true unconditionally, yabai
-- returns zero when the scripting addition quietly swallowed the request, and a drag can
-- complete cleanly with the window left behind. Arrival is decided by confirmArrival() and
-- by nothing else.
--
-- `available` returns false plus a short reason for a rung that is switched off, absent, or
-- inapplicable to this particular window. That is not a failure and never warns: on a
-- machine without yabai the ladder below is exactly what this Spoon did before yabai was
-- ever mentioned, with exactly the same timings.
local ENGINES = {
  {
    -- First, ahead of the native call, because the native rung is only free in CPU. It
    -- costs 350ms of wall clock finding out it did nothing, on every summon, on every macOS
    -- 15 and later. yabai answers in about thirty milliseconds.
    name = 'yabai',
    available = function(self)
      if not self.useYabai then return false, 'turned off' end
      if not self:yabaiBinary() then return false, 'not installed' end
      return true
    end,
    verify = function(self) return self.yabaiVerifyTimeout end,
    run = function(self, win, winId, target, done) self:yabaiMove(winId, target, done) end,
    onNoArrival = function(self)
      self:warnOnce(
        'yabaisilent',
        'yabai accepted the move but the window did not arrive. Its scripting addition is '
          .. 'probably not loaded for this macOS build -- try `sudo yabai --load-sa`. '
          .. 'Falling back to the other rungs.'
      )
    end,
  },
  {
    -- Kept, though on a current macOS it has never once worked, because it costs one
    -- function call to try and this Spoon starts using the fast path again by itself the
    -- day Hammerspoon adopts the replacement window server API.
    name = 'native',
    available = function(self, win)
      if not win then return false, 'no window object; only yabai can move this one' end
      if not (hs.spaces and hs.spaces.moveWindowToSpace) then return false, 'unavailable on this build' end
      return true
    end,
    verify = function(self) return 0.35 end,
    run = function(self, win, winId, target, done)
      local ok, _, err = pcall(hs.spaces.moveWindowToSpace, win, target)
      if not ok then self:warnOnce('movecall', 'moveWindowToSpace threw: %s', tostring(err)) end
      -- Reported as issued whatever it returned. Its return value carries no information at
      -- all -- Hammerspoon never checks what the window server did with the request -- so
      -- confirmArrival is the only thing entitled to an opinion here.
      done(true, nil)
    end,
    onNoArrival = function(self)
      self:warnOnce(
        'nativedead',
        'hs.spaces.moveWindowToSpace reported success but the window did not move; '
          .. 'this is expected on macOS 15+ (Hammerspoon issue #3698).'
      )
    end,
  },
  {
    -- Last, always. It borrows the pointer, slides the screen about twice and takes the
    -- better part of a second -- but it is the only rung that needs neither a private API
    -- nor a disabled SIP, so on a stock machine it is the one that does all the work.
    name = 'drag',
    available = function(self, win)
      if not win then return false, 'no window object; only yabai can move this one' end
      if not self.dragFallback then return false, 'dragFallback is off' end
      return true
    end,
    verify = function(self) return self.dragTiming.verifyTimeout end,
    -- target is ignored: a drag can only ever land on the Space you are looking at, which is
    -- the same Space summonableSpace() just handed us.
    run = function(self, win, winId, target, done) self:dragToCurrentSpace(win, done) end,
  },
}

--- SummonWindow:summonById(winId) -> self
--- Method
--- Moves one window to the current Space by its window id.
---
--- Parameters:
---  * winId - The window id, as returned in the `winId` field of `SummonWindow:candidates()`
---
--- Returns:
---  * The SummonWindow object
---
--- Notes:
---  * The id must have come from a `SummonWindow:candidates()` pass, since everything known about the window is looked up in the maps that call builds. Windows on other Spaces cannot be recovered from an id alone.
---  * Tries every rung of the move ladder in turn -- yabai, then the native window server call, then dragging -- stopping at the first one whose result can be *verified*. A window only yabai could see has no `hs.window` behind it, so for that window the ladder is one rung long.
function obj:summonById(winId)
  -- lastEntries rather than byId is the authority, because a window only yabai can see has
  -- a description here and no hs.window anywhere.
  local entry = self.lastEntries[winId]
  if not entry then
    self.logger.wf('window %s is not in the current candidate map', tostring(winId))
    hs.alert.show('SummonWindow: that window is no longer available')
    return self
  end
  local win = self.byId[winId]

  -- Re-checked at the moment of the move rather than trusted from when the list was
  -- built: the list may have been sitting open while the Space changed underneath it.
  local target, why = self:summonableSpace()
  if not target then
    hs.alert.show('SummonWindow: ' .. why)
    return self
  end

  local label, appName = self:describe(winId)
  -- Asked fresh when we can, since the window may have moved since the list was built, and
  -- fall back to what the list recorded when there is no window object to ask about.
  local sourceSpace = entry.spaceId
  if win then
    local spaces = self:spacesFor(win)
    sourceSpace = firstMovableSpace(spaces, self:spaceModel().types) or sourceSpace
  end

  -- Arriving is the only definition of success. Note that focus() is deliberately not
  -- reached from any failure path: focusing a window that never moved is exactly what
  -- yanks the user to its Space, which is the single worst thing this Spoon can do.
  local function arrived(engine)
    self:clearPendingGoto()
    if self.focusAfterMove then
      if win then
        -- Moving a minimized window would otherwise be invisible: it arrives, still in the
        -- Dock, with nothing to show for it.
        local okMin, minimized = pcall(win.isMinimized, win)
        if okMin and minimized then pcall(win.unminimize, win) end
        pcall(win.focus, win)
        pcall(win.raise, win)
      else
        -- Nothing to focus locally, so yabai does it. Reached only after arrival was
        -- verified, so this cannot yank the user to a Space the window never left.
        self:yabaiFocus(winId)
      end
    end
    self.logger.f('summoned window %s to space %s via %s', tostring(winId), tostring(target), engine)
  end

  -- The log gets the whole ladder's reasoning, the alert gets only the headline: three
  -- semicolon-joined clauses do not fit in an hs.alert anybody will read.
  local function gaveUp(why, detail)
    self.logger.wf('could not summon window %s: %s', tostring(winId), tostring(detail or why))
    if sourceSpace then
      self:offerGoto(sourceSpace, label)
      hs.alert.show(string.format('SummonWindow: could not move %s — press again to go to %s', appName, label), 3)
    else
      hs.alert.show('SummonWindow: could not move that window — ' .. tostring(why), 3)
    end
  end

  -- Walk the ladder. A rung that is off, absent, inapplicable, refuses, or silently does
  -- nothing all lead to the same place, which is the next rung down. Written as a recursion
  -- over ENGINES rather than as nested callbacks so that the nesting stays one level deep
  -- however many rungs there are.
  local reasons = {}

  local function attempt(i)
    local engine = ENGINES[i]
    if not engine then return gaveUp(reasons[#reasons] or 'no method available', table.concat(reasons, '; ')) end

    local okAvail, available, whyNot = pcall(engine.available, self, win)
    if not okAvail or not available then
      reasons[#reasons + 1] = engine.name .. ': ' .. tostring(whyNot or available or 'unavailable')
      return attempt(i + 1)
    end

    -- run() answers from inside timer and task callbacks, where a throw is swallowed rather
    -- than raised -- so a rung that died mid-flight would otherwise strand the ladder with
    -- nothing ever reporting and no alert ever shown. This guarantees exactly one answer per
    -- rung, whichever way it ends.
    local answered = false
    local function step(ok, err)
      if answered then return end
      answered = true

      if not ok then
        reasons[#reasons + 1] = string.format('%s: %s', engine.name, tostring(err or 'failed'))
        return attempt(i + 1)
      end

      self:confirmArrival(win, winId, target, engine.verify(self), function(moved)
        if moved then return arrived(engine.name) end
        if engine.onNoArrival then pcall(engine.onNoArrival, self) end
        reasons[#reasons + 1] = engine.name .. ': issued, but the window did not arrive'
        attempt(i + 1)
      end)
    end

    local okRun, runErr = pcall(engine.run, self, win, winId, target, step)
    if not okRun then step(false, tostring(runErr)) end
  end

  attempt(1)
  return self
end

-- A human label for a window we may no longer be able to inspect, taken from the last
-- candidates() pass so that failure messages still name the right thing.
function obj:describe(winId)
  local entry = self.lastEntries and self.lastEntries[winId]
  if entry then return entry.label, entry.appName end
  return 'its Space', 'that window'
end

function obj:offerGoto(spaceId, label) self.pendingGoto = { spaceId = spaceId, label = label, at = hs.timer.secondsSinceEpoch() } end

function obj:clearPendingGoto() self.pendingGoto = nil end

-- Consume the standing offer if it is still fresh. Returns true when it acted, so the
-- caller knows not to open the chooser.
function obj:takePendingGoto()
  local pending = self.pendingGoto
  if not pending then return false end
  self.pendingGoto = nil
  if hs.timer.secondsSinceEpoch() - pending.at > self.gotoGraceSeconds then return false end
  self.logger.f('going to space %s instead of summoning', tostring(pending.spaceId))
  pcall(hs.spaces.gotoSpace, pending.spaceId)
  return true
end

--- SummonWindow:diagnose() -> string
--- Method
--- Reports what each window source can actually see, and why any given window is or is not offered.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The report text, which is also printed to the Console
---
--- Notes:
---  * Run this first if the list comes up empty. The line that matters is the per-source count of windows found on *other* Spaces: if both sources report zero while windows plainly exist elsewhere, macOS is hiding them from Accessibility and no amount of filtering will help.
---  * Each listed window is tagged with the source that found it -- `filter`, `ax`, or both -- which shows whether `SummonWindow.deepScan` is earning its keep on this machine.
function obj:diagnose()
  local out = {}
  local function say(fmt, ...) out[#out + 1] = (select('#', ...) > 0) and string.format(fmt, ...) or tostring(fmt) end

  say('SummonWindow diagnose')
  say(
    'running=%s  deepScan=%s  includeMinimized=%s  filter=%s',
    tostring(self.running),
    tostring(self.deepScan),
    tostring(self.includeMinimized),
    tostring(self.windowFilter ~= nil)
  )

  if not (hs.spaces and hs.spaces.focusedSpace) then
    say('')
    say('hs.spaces is UNAVAILABLE on this build -- this Spoon cannot work.')
    local text = table.concat(out, '\n')
    print(text)
    return text
  end

  local current = self:currentSpace()
  local model = self:spaceModel()
  -- Deliberately not reported as a plain "moveWindowToSpace=true". The function exists on
  -- every build; what matters is whether it does anything, and on macOS 15+ it does not.
  local major = tonumber((hs.host.operatingSystemVersionString() or ''):match('(%d+)%.')) or 0
  say(
    'accessibility=%s  secureInput=%s  dragFallback=%s',
    tostring(hs.accessibilityState()),
    tostring(hs.eventtap.isSecureInputEnabled()),
    tostring(self.dragFallback)
  )
  -- Which rung actually carries the work is now a three-way answer, so the ladder is
  -- reported as a ladder rather than as a verdict on the native call alone.
  local yabaiBin = self:yabaiBinary()
  say(
    'move ladder: 1.yabai=%s  2.native=%s  3.drag=%s',
    not self.useYabai and 'off' or yabaiBin or 'not installed',
    major >= 15 and 'expected DEAD (Hammerspoon #3698)' or 'may work on this macOS',
    tostring(self.dragFallback)
  )
  say(
    'current Space: %s (%s, type=%s)',
    tostring(current),
    current and (model.labels[current] or 'unlabelled') or 'unknown',
    current and (model.types[current] or 'unknown') or 'n/a'
  )

  -- Each source queried separately here rather than through knownWindows(), so that the
  -- report can attribute every window to the source that found it.
  local function idSetOf(getter)
    local set, n = {}, 0
    local ok, wins = pcall(getter)
    if not ok or type(wins) ~= 'table' then return set, n, tostring(wins) end
    for _, win in ipairs(wins) do
      local okId, id = pcall(win.id, win)
      if okId and id and not set[id] then
        set[id] = win
        n = n + 1
      end
    end
    return set, n
  end

  -- The decisive measurement: how many windows each source sees that are NOT here.
  local function elsewhere(set)
    local n = 0
    if not current then return n end
    for _, win in pairs(set) do
      local spaces = self:spacesFor(win)
      if spaces and #spaces > 0 and not hs.fnutils.contains(spaces, current) then n = n + 1 end
    end
    return n
  end

  local filterSet, filterN, filterErr = idSetOf(function()
    if not self.windowFilter then return {} end
    return self.windowFilter:getWindows()
  end)
  local axSet, axN, axErr = idSetOf(hs.window.allWindows)

  say('')
  say('Sources:')
  say(
    '  hs.window.filter      %4d windows, %d on other Spaces%s',
    filterN,
    elsewhere(filterSet),
    filterErr and (' [error: ' .. filterErr .. ']') or ''
  )
  say('  hs.window.allWindows  %4d windows, %d on other Spaces%s', axN, elsewhere(axSet), axErr and (' [error: ' .. axErr .. ']') or '')

  -- yabai is counted from its own snapshot rather than re-queried, because a query is a
  -- subprocess and diagnose() has to return its text on this stack. The snapshot's age is
  -- printed so a stale one cannot be mistaken for a current one; start(), every list build
  -- and every chooser open refresh it, so in practice it is seconds old at most.
  local yabaiSet, yabaiN = {}, 0
  if yabaiBin then
    local spaces, windows, at = self:yabaiSnapshot()
    if not windows then
      -- The distinction that matters: a binary that is present but whose service is down
      -- looks exactly like one that simply has not been asked yet, and the fixes are
      -- completely different.
      say(
        '  yabai                 %s',
        self.yabaiLastError and ('INSTALLED BUT NOT ANSWERING (' .. self.yabaiLastError .. ') — try `yabai --start-service`')
          or '(no snapshot yet — run diagnose() again in a moment)'
      )
    else
      local _, indexToId = yabaiSpaceMaps(spaces)
      local away = 0
      for _, w in ipairs(windows) do
        if type(w) == 'table' and type(w.id) == 'number' then
          yabaiSet[math.floor(w.id)] = true
          yabaiN = yabaiN + 1
          local sid = type(w.space) == 'number' and indexToId[math.floor(w.space)] or nil
          if sid and sid ~= current then away = away + 1 end
        end
      end
      -- The decisive line when the two lists disagree: if yabai reports Spaces this Spoon
      -- cannot match to an hs.spaces id, the two are numbering the world differently and
      -- the yabai source will be quietly useless.
      local matched = 0
      for _, s in ipairs(spaces or {}) do
        if type(s) == 'table' and model.order[s.id] then matched = matched + 1 end
      end
      say(
        '  yabai                 %4d windows, %d on other Spaces  [snapshot %.1fs old, %d/%d Spaces matched to hs.spaces]',
        yabaiN,
        away,
        hs.timer.secondsSinceEpoch() - at,
        matched,
        #(spaces or {})
      )
    end
  else
    say('  yabai                 %s', not self.useYabai and '(turned off)' or '(not installed)')
  end

  say('')
  say('Spaces:')
  local ids = {}
  for id in pairs(model.order) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b) return model.order[a] < model.order[b] end)
  for _, id in ipairs(ids) do
    -- windowsForSpace sees every Space, but returns bare ids and includes a lot of things
    -- nobody would call a window (overlays, tooltips, off-screen scratch surfaces), so
    -- this count is a ceiling, not a target.
    local raw = '-'
    if hs.spaces.windowsForSpace then
      local okRaw, rawIds = pcall(hs.spaces.windowsForSpace, id)
      if okRaw and type(rawIds) == 'table' then raw = tostring(#rawIds) end
    end
    say(
      '  %-34s id=%-7s type=%-11s windowsForSpace=%-5s%s',
      model.labels[id] or '?',
      tostring(id),
      model.types[id] or '?',
      raw,
      id == current and '  <- current' or ''
    )
  end

  local entries = self:candidates()
  say('')
  say('Summonable: %d window(s)', #entries)
  for _, e in ipairs(entries) do
    local tags = {}
    if filterSet[e.winId] then tags[#tags + 1] = 'filter' end
    if axSet[e.winId] then tags[#tags + 1] = 'ax' end
    if yabaiSet[e.winId] then tags[#tags + 1] = 'yabai' end
    -- A row tagged only 'yabai' is a window Accessibility will not surface at all: it can be
    -- summoned, but only by yabai, and there is no fallback behind it.
    say(
      '  [%-16s] %-22s %-50s %s%s',
      table.concat(tags, '+'),
      e.appName,
      truncate(e.title, 50),
      e.label,
      e.yabaiOnly and '  (yabai only)' or ''
    )
  end

  if #entries == 0 then
    say('')
    if #ids <= 1 then
      say('Nothing to summon: only one Space exists.')
    elseif yabaiBin then
      say('Nothing to summon, and yabai is installed -- so if windows really are on the other')
      say('Spaces above, check the yabai source line: a zero count there means the service is')
      say('not running, and a low Spaces-matched count means yabai and hs.spaces disagree')
      say('about the Space layout.')
    else
      say('Nothing to summon. If windows really are on the other Spaces above, then macOS')
      say('is not exposing them to Accessibility from here. Visit those Spaces once so the')
      say('window filter can learn them, then run this again -- or install yabai, which sees')
      say('every Space regardless.')
    end
  end

  local text = table.concat(out, '\n')
  print(text)
  return text
end

--- SummonWindow:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `menubar`, `chooserVisible`, `currentSpace`, `summonable`, `dragging`, `yabai`, `yabaiBusy` and `pendingGoto` keys
---
--- Notes:
---  * `yabai` is the resolved binary path, or `false` when yabai is switched off or not installed. It says nothing about whether the yabai *service* is running -- only `SummonWindow:diagnose()` answers that.
function obj:status()
  local busy = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then busy = busy + 1 end
  end
  return {
    running = self.running,
    menubar = self.menubarItem ~= nil,
    chooserVisible = self.chooser ~= nil and self.chooser:isVisible() or false,
    currentSpace = self:currentSpace(),
    summonable = #self:candidates(),
    dragging = self.dragJob ~= nil,
    yabai = self:yabaiBinary() or false,
    yabaiBusy = busy,
    pendingGoto = self.pendingGoto and self.pendingGoto.label or nil,
  }
end

return obj
