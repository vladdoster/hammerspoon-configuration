--- === SummonWindow ===
---
--- Brings a window from another Mission Control Space to the one you are on.
---
--- macOS offers no way to pull a window towards you: if it is on Space 3 and you are on
--- Space 1, the only choices are to navigate away or to drag it around inside Mission
--- Control. A hotkey or menubar click here lists every window living on some other Space,
--- and picking one moves it to you without ever leaving the Space you are on.
---
--- Two hard parts. The first is *enumerating* windows that macOS Accessibility hides from a
--- process not looking at them; see `SummonWindow.deepScan`, `SummonWindow.useYabai` and
--- `SummonWindow:diagnose()`.
---
--- The second is the move. `hs.spaces.moveWindowToSpace()` is a **silent no-op on macOS 15
--- and later** -- Apple gutted the private window server calls behind it, and the survivors
--- check that the caller owns the window or is the Dock -- and it still returns `true`
--- (Hammerspoon issue #3698, open since 2024). So a move is attempted three ways in turn and
--- every one is verified against where the window actually ended up, because all three lie:
--- yabai first, through a scripting addition injected into Dock.app that the window server
--- still trusts; the native call second, kept for the day it works again; and physically
--- dragging the window across last.
---
--- Windows that cannot be moved are never listed. A fullscreen or tiled window lives in its
--- own managed Space and the window server refuses to move windows out of one, so listing
--- them would only produce rows that fail when clicked.

local obj = {}
obj.__index = obj

obj.name = "SummonWindow"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- SummonWindow.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("SummonWindow", "info")

-- Configuration

--- SummonWindow.deepScan
--- Variable
--- Whether to add a live `hs.window.allWindows()` sweep to the window filter's cache when building the list. Defaults to `true`.
---
--- The window filter only knows about Spaces it has witnessed, so after a config reload it can be blind to windows you have not visited. The sweep asks every application directly, and the two sources are unioned.
--- Set to `false` if the sweep proves slow on a machine with very many windows; the list is then limited to what the filter has learned.
obj.deepScan = true

--- SummonWindow.includeMinimized
--- Variable
--- Whether minimized windows on other Spaces are offered. Defaults to `false`.
---
--- When enabled, summoning a minimized window also unminimizes it, since moving a window you cannot see would do nothing visible.
--- Depends on `SummonWindow.deepScan`: the default window filter is built with `visible=true`, so the direct sweep is the only source that reports minimized windows.
obj.includeMinimized = false

--- SummonWindow.useMissionControlNames
--- Variable
--- Whether to label Spaces with their real Mission Control names instead of ordinals. Defaults to `false`.
---
--- Reading them requires `hs.spaces.missionControlSpaceNames()`, which physically opens and closes Mission Control on every call -- far too intrusive per list build, so the default derives `Space N` from position instead.
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
--- The chooser is not truncated; it is searchable, and its rows wrap on their own.
obj.titleMax = 55

--- SummonWindow.showInMenubar
--- Variable
--- Whether `SummonWindow:start()` adds a menubar item. Defaults to `true`.
obj.showInMenubar = true

--- SummonWindow.menubarTitle
--- Variable
--- Glyph shown in the menubar. Defaults to the SF Symbols `macwindow` glyph.
---
--- SF Symbols are reachable only as private-use codepoints rendered in the menu bar font, since `hs.image` cannot resolve them by name.
--- They are drawn from SF Pro, which is an Apple download rather than part of macOS: without it this renders as a missing-glyph box.
obj.menubarTitle = utf8.char(0x1003DC)

--- SummonWindow.menubarFont
--- Variable
--- Font for the menubar title, as `hs.styledtext` understands it. Defaults to the menu bar font at 14pt.
---
--- No colour is set deliberately, so AppKit's default menubar label colour applies and follows light and dark appearance on its own.
obj.menubarFont = { name = hs.styledtext.defaultFonts.menuBar.name, size = 14 }

--- SummonWindow.useYabai
--- Variable
--- Whether to use yabai, when it is installed, to move windows and to find them. Defaults to `true`.
---
--- yabai does what `hs.spaces.moveWindowToSpace()` used to: it moves a window instantly, invisibly and without touching the mouse, because its scripting addition is injected into Dock.app, one of the few processes the window server still trusts with the request.
--- That injection needs System Integrity Protection partially disabled and the addition loaded (`sudo yabai --load-sa`), so it can never be the only strategy. An absent yabai is not an error, is never reported as one, and simply drops the ladder to its next rung.
--- yabai is also a third source of windows: its server tracks every window on every Space continuously, so unlike the other two it does not depend on what Accessibility will tell this process.
--- A window only yabai can see has no `hs.window` behind it, so only yabai can move it -- the native call and the drag both need a real window object, and there is no fallback for such a window.
obj.useYabai = true

--- SummonWindow.yabaiPath
--- Variable
--- Full path to the yabai binary, or `nil` to probe the usual install locations. Defaults to `nil`.
---
--- `hs.task` cannot search `PATH`, and handing the search to a shell would be worse than useless: Hammerspoon inherits launchd's environment rather than your login shell's, so `command -v yabai` would miss on exactly the machines where a shell rc file put it on the path. A short list of install prefixes is probed instead.
--- Set this if yabai lives somewhere unusual. Unlike a failed probe, a path set here that is not executable is a config mistake, and is warned about once.
obj.yabaiPath = nil

--- SummonWindow.yabaiTimeout
--- Variable
--- How long a single yabai invocation may run before it is killed, in seconds. Defaults to `1.5`.
---
--- `yabai -m ...` is a thin client over a unix socket, and every command here takes single-digit milliseconds when the server is healthy. This exists only so a wedged server cannot hold a summon open forever; reaching it means something is wrong elsewhere.
obj.yabaiTimeout = 1.5

--- SummonWindow.yabaiVerifyTimeout
--- Variable
--- How long to wait for a window to actually arrive after yabai reports the move succeeded, in seconds. Defaults to `0.6`.
---
--- yabai exiting zero means the command was accepted, not that the window moved: on recent macOS builds the scripting addition can be loaded, report success and do nothing. The move is verified exactly as the other two rungs are.
obj.yabaiVerifyTimeout = 0.6

--- SummonWindow.yabaiCacheSeconds
--- Variable
--- How long a yabai query result is reused before it is fetched again, in seconds. Defaults to `3`.
---
--- Only the window list is served from this cache, and only for the menubar menu, since `hs.menubar` demands its table synchronously. The chooser refreshes before it opens, and a move never uses a cached Space list: Mission Control indices renumber whenever a Space is created or dragged, and a stale one would not fail, it would move the window to the wrong Space.
obj.yabaiCacheSeconds = 3

--- SummonWindow.dragFallback
--- Variable
--- Whether to physically drag a window across when neither yabai nor the window server will move it. Defaults to `true`.
---
--- `hs.spaces.moveWindowToSpace()` does nothing on macOS 15 and later, so without yabai this is not a fallback but the only thing that works. It is still tried last, being the only rung that borrows the pointer and slides the screen about.
--- A window can only be picked up while it is on the visible Space, so a drag is a round trip: walk to the window, take hold of its titlebar, walk back still holding it. Expect roughly a second and some Space animation.
--- Single display only. Dragging between Spaces on different screens does not work, and is refused rather than attempted.
obj.dragFallback = true

--- SummonWindow.gotoGraceSeconds
--- Variable
--- How long the offer to jump to an unmovable window's Space stays open, in seconds. Defaults to `4`.
---
--- When a window cannot be moved, pressing the hotkey again within this window of time goes to that Space instead of reopening the chooser. Doing nothing lets the offer lapse, so the hotkey never does something surprising later.
obj.gotoGraceSeconds = 4

--- SummonWindow.useFnModifier
--- Variable
--- Whether the synthetic Space-switch arrows carry the `fn` modifier. Defaults to `true`.
---
--- Real arrow keys set `NSEventModifierFlagFunction`, and the macOS matcher for "Move left/right a space" checks the whole modifier mask, so a synthetic ctrl+arrow without `fn` is silently ignored on some systems. Turn this off only if Space switches start firing twice.
obj.useFnModifier = true

--- SummonWindow.dragTiming
--- Variable
--- Delays in seconds between the stages of a drag.
---
--- Hand-tuned against a gesture macOS never intended to be synthesised. Raise `hopTimeout` first if Space traversal is unreliable on a slow machine, then `preRelease` if windows are dropped before they land.
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

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.chooser = nil
obj.menubarItem = nil
obj.windowFilter = nil

-- id -> hs.window, rebuilt per pass. A necessity, not a cache: a chooser choice carries only plain values, and hs.window.get(id) fails for exactly these windows
obj.byId = {}

-- id -> the descriptive entry from the same pass, for naming things in failure messages
obj.lastEntries = {}

-- The in-flight drag. Dangerous state -- macOS believes a button is physically held -- so it all lives in one table that abortDrag() can tear down at once
obj.dragJob = nil

-- A standing offer to jump to an unmovable window's Space, taken by the next hotkey press
obj.pendingGoto = nil

-- Path, `false` for "looked, none there", nil for "not looked". The negative is cached as deliberately as the positive: absent yabai, that is four stat() calls per start() not per list
obj.yabaiResolved = nil

-- Every subprocess in flight, so a reload part-way through finds each process and its timer. A set, not a slot, since a background refresh and a move can legitimately overlap
obj.yabaiTasks = {}

-- kind -> { at, data } for the last successful `yabai -m query --<kind>`
obj.yabaiCache = {}

-- Callbacks waiting on a query already in flight, so a menu and a chooser opening together cost one subprocess
obj.yabaiPending = {}

-- Kept because the warning is emitted once and :diagnose() may run long after it scrolled away, and "not answering" is a different problem from "answering, but blind"
obj.yabaiLastError = nil

-- So an installed-but-stopped yabai does not cost a doomed subprocess per menu open; held for yabaiCacheSeconds, so starting the service is still noticed within seconds
obj.yabaiFailedAt = nil

obj.running = false
obj.warned = {}

-- Stateless helpers

-- UTF-8 safe middle-ellipsis: a window title is most distinguishable at both ends
local function truncate(s, n)
  if s == nil or s == "" then return "(untitled)" end
  local len = (utf8 and utf8.len and utf8.len(s)) or #s
  if not len or len <= n then return s end
  local keep = math.floor((n - 1) / 2)
  if utf8 and utf8.offset then
    local head = s:sub(1, (utf8.offset(s, keep + 1) or keep + 1) - 1)
    local tail = s:sub(utf8.offset(s, -keep) or (#s - keep + 1))
    return head .. "…" .. tail
  end
  return s:sub(1, keep) .. "…" .. s:sub(-keep)
end

-- yabai rejects "1628.0", which is what tostring() makes of a JSON-decoded id on some builds
local function fmtId(id)
  return string.format("%d", math.floor(id))
end

-- Hoisted out of the table.sort() below
local function bySpaceThenApp(a, b)
  if a.order ~= b.order then return a.order < b.order end
  if a.appName ~= b.appName then return a.appName < b.appName end
  return a.title < b.title
end

-- Small stateful helpers

-- Log a given message only once, so a broken system API cannot spam the console
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- Icons are 512pt originals and menus draw at natural size, so shrink first; `cache` is per list build, so an app with eight windows costs one lookup
function obj:iconFor(bundleID, cache, size)
  if not bundleID then return nil end
  local hit = cache[bundleID]
  if hit ~= nil then return hit or nil end

  local ok, img = pcall(hs.image.imageFromAppBundle, bundleID)
  if not ok then img = nil end
  if img and size then
    local okCopy, small = pcall(function()
      return img:copy():size({ w = size, h = size })
    end)
    if okCopy and small then img = small end
  end

  -- `false`, not nil, so a missing icon is not looked up again for every window of the app
  cache[bundleID] = img or false
  return img
end

-- Spaces

-- hs.spaces is experimental, and unlike a decoration Spoon this one cannot fail open: with no Space to move to there is nothing sensible to do, so these return nil rather than guess

function obj:currentSpace()
  if not (hs.spaces and hs.spaces.focusedSpace) then
    self:warnOnce("spaces", "hs.spaces is unavailable; SummonWindow cannot work on this build")
    return nil
  end
  local ok, id = pcall(hs.spaces.focusedSpace)
  if not ok or type(id) ~= "number" then
    self:warnOnce("focusedSpace", "hs.spaces.focusedSpace failed (%s)", tostring(id))
    return nil
  end
  return id
end

function obj:spacesFor(win)
  if not (hs.spaces and hs.spaces.windowSpaces) then return nil end
  local ok, spaces = pcall(hs.spaces.windowSpaces, win)
  if not ok or type(spaces) ~= "table" then
    self:warnOnce("windowSpaces", "hs.spaces.windowSpaces failed (%s)", tostring(spaces))
    return nil
  end
  return spaces
end

-- Must agree with classify(), which skips fullscreen Spaces; taking spaces[1] would route the walk somewhere the window is not, and grabPoint() would seize whatever sat under the cursor
local function firstMovableSpace(spaces, types)
  if not spaces then return nil end
  for _, id in ipairs(spaces) do
    if not types or types[id] ~= "fullscreen" then return id end
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
--- The Spoon's only source of truth about whether a move worked. `hs.spaces.moveWindowToSpace()` returns `true` unconditionally and cannot check what the window server did, so its result is ignored in favour of asking where the window ended up.
--- Only meaningful once a move has settled: during a drag the window server does not commit until the mouse button is released, so this reports the *old* Space right up until the drop.
function obj:windowIsOn(win, spaceId)
  local spaces = self:spacesFor(win)
  if not spaces then return false end
  return hs.fnutils.contains(spaces, spaceId)
end

-- The window server is not instantaneous, so one check would fail a move about to succeed
function obj:awaitArrival(win, spaceId, timeout, done)
  local deadline = hs.timer.secondsSinceEpoch() + (timeout or 0.6)
  local timer
  timer = hs.timer.waitUntil(function()
    return self:windowIsOn(win, spaceId) or hs.timer.secondsSinceEpoch() > deadline
  end, function()
    if timer then pcall(function()
      timer:stop()
    end) end
    done(self:windowIsOn(win, spaceId))
  end, 0.05)
end

-- The Space we would be moving a window into, or nil plus a reason to show the user
function obj:summonableSpace()
  local current = self:currentSpace()
  if not current then return nil, "hs.spaces is unavailable" end

  -- A fullscreen or tiled app owns its Space and refuses arrivals; say so before listing rows that would all fail
  local ok, kind = pcall(hs.spaces.spaceType, current)
  if ok and kind == "fullscreen" then return nil, "cannot summon into a fullscreen Space" end
  return current
end

-- Reads real Mission Control names, at the cost of opening Mission Control
function obj:missionControlNames()
  if not self.useMissionControlNames then return {} end
  if not (hs.spaces and hs.spaces.missionControlSpaceNames) then return {} end

  local ok, byScreen = pcall(hs.spaces.missionControlSpaceNames)
  if not ok or type(byScreen) ~= "table" then
    self:warnOnce("mcNames", "hs.spaces.missionControlSpaceNames failed (%s)", tostring(byScreen))
    return {}
  end

  local names = {}
  for _, spaces in pairs(byScreen) do
    if type(spaces) == "table" then
      for id, name in pairs(spaces) do
        local n = tonumber(id) -- keys survive the ObjC round trip as numbers or strings
        if n and type(name) == "string" and name ~= "" then names[n] = name end
      end
    end
  end
  return names
end

-- One Space snapshot per list build: labels, types to reject fullscreen, and a global order matching Mission Control. spaceType() re-reads everything per call, so it runs once per Space
function obj:spaceModel()
  local model = { labels = {}, types = {}, order = {} }
  if not (hs.spaces and hs.spaces.allSpaces) then return model end

  local ok, all = pcall(hs.spaces.allSpaces)
  if not ok or type(all) ~= "table" then
    self:warnOnce("allSpaces", "hs.spaces.allSpaces failed (%s)", tostring(all))
    return model
  end

  -- pairs() order is undefined and would reshuffle the menu; primary screen first for determinism
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
    -- Naming the screen only helps when there is more than one
    local screenLabel
    if #uuids > 1 then
      local scr = hs.screen.find(uuid)
      screenLabel = (scr and scr:name()) or "Display"
    end

    for index, id in ipairs(all[uuid] or {}) do
      rank = rank + 1
      local label = names[id] or string.format("Space %d", index)
      if screenLabel then label = screenLabel .. " · " .. label end
      model.labels[id] = label
      model.order[id] = rank

      local okType, kind = pcall(hs.spaces.spaceType, id)
      if okType and type(kind) == "string" then model.types[id] = kind end
    end
  end

  return model
end

-- yabai

-- Absent-tolerant throughout. The one thing warned loudly is yabai claiming to have moved a window it did not, being the failure a user cannot see

-- Homebrew, nix-darwin and hand installs. Static, because hs.task cannot search PATH and Hammerspoon inherits launchd's environment rather than a login shell's
local YABAI_PATHS = {
  "/opt/homebrew/bin/yabai",
  "/usr/local/bin/yabai",
  "/run/current-system/sw/bin/yabai",
  -- Last, and nil-safe: a trailing nil shortens the list rather than erroring
  os.getenv("HOME") and (os.getenv("HOME") .. "/.local/bin/yabai") or nil,
}

-- attributes() follows symlinks, which is wanted: /opt/homebrew/bin/yabai links into the Cellar
local function executableFile(path)
  if type(path) ~= "string" or path == "" then return false end
  local okMode, mode = pcall(hs.fs.attributes, path, "mode")
  if not okMode or mode ~= "file" then return false end
  local okPerm, perms = pcall(hs.fs.attributes, path, "permissions")
  -- Owner-execute, since Hammerspoon runs as the user who installed it
  return okPerm and type(perms) == "string" and perms:sub(3, 3) == "x"
end

-- No yabai space selector takes a window server id, so ids must become Mission Control indices, and only yabai can say what its own numbering is
local function yabaiSpaceMaps(spaces)
  local idToIndex, indexToId = {}, {}
  for _, s in ipairs(spaces or {}) do
    if type(s) == "table" and type(s.id) == "number" and type(s.index) == "number" then
      local id, index = math.floor(s.id), math.floor(s.index)
      idToIndex[id] = index
      indexToId[index] = id
    end
  end
  return idToIndex, indexToId
end

-- Resolve yabai once and remember the answer, including the negative one
function obj:yabaiBinary()
  if not self.useYabai then return nil end
  if self.yabaiResolved ~= nil then return self.yabaiResolved or nil end

  if self.yabaiPath then
    -- An explicit path that fails is a config mistake, not a missing optional dependency
    if executableFile(self.yabaiPath) then
      self.yabaiResolved = self.yabaiPath
    else
      self:warnOnce(
        "yabaipath",
        "SummonWindow.yabaiPath is set to %s, which is not an executable file; ignoring it",
        tostring(self.yabaiPath)
      )
      self.yabaiResolved = false
    end
    return self.yabaiResolved or nil
  end

  for _, path in ipairs(YABAI_PATHS) do
    if executableFile(path) then
      self.yabaiResolved = path
      self.logger.f("found yabai at %s", path)
      return path
    end
  end

  self.yabaiResolved = false
  return nil
end

-- Calls done() exactly once, or not at all if torn down in flight; answering twice would walk the ladder twice and start a drag nobody asked for
function obj:yabaiRun(args, done)
  local bin = self:yabaiBinary()
  if not bin then return done(false, nil, "not installed") end

  local job = { task = nil, timer = nil, settled = false }
  self.yabaiTasks[job] = true

  local function finish(ok, out, err)
    if job.settled then return end
    job.settled = true
    if job.timer then pcall(function()
      job.timer:stop()
    end) end
    if job.task then pcall(function()
      if job.task:isRunning() then job.task:terminate() end
    end) end
    self.yabaiTasks[job] = nil
    done(ok, out, err)
  end

  -- Handed to execve verbatim with no shell in between, so nothing needs quoting or escaping
  local okNew, made = pcall(hs.task.new, bin, function(code, out, err)
    if code == 0 then return finish(true, out, nil) end
    finish(
      false,
      out,
      string.format(
        "exit %s%s",
        tostring(code),
        (type(err) == "string" and err ~= "") and (": " .. err:gsub("%s+$", "")) or ""
      )
    )
  end, args)

  if not okNew or not made then return finish(false, nil, "could not create the task (" .. tostring(made) .. ")") end
  -- Assigned before start(), so the completion callback can always find the task to reap
  job.task = made

  local okStart, started = pcall(made.start, made)
  if not okStart or not started then return finish(false, nil, "failed to launch") end

  -- Guarded: a process that exits instantly settles the job before we reach here
  if not job.settled then
    job.timer = hs.timer.doAfter(self.yabaiTimeout, function()
      finish(false, nil, string.format("no answer within %ss", tostring(self.yabaiTimeout)))
    end)
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
--- Called from `SummonWindow:stop()`. Each job is marked settled *before* its process is signalled: terminating a task causes a completion callback rather than cancelling one, so without the flag a config reload would answer into a half-torn-down Spoon and walk the move ladder on into a drag nobody asked for.
function obj:abortYabai()
  local n = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then
      job.settled = true
      if job.timer then pcall(function()
        job.timer:stop()
      end) end
      if job.task then pcall(function()
        if job.task:isRunning() then job.task:terminate() end
      end) end
      n = n + 1
    end
  end
  self.yabaiTasks = {}
  self.yabaiPending = {}
  if n > 0 then self.logger.f("abandoned %d yabai command(s)", n) end
  return self
end

-- Calls done(data, err) once, data nil on failure; `kind` doubles as the query flag
function obj:yabaiQuery(kind, force, done)
  if not self:yabaiBinary() then return done(nil, "not installed") end

  local hit = self.yabaiCache[kind]
  if not force and hit and (hs.timer.secondsSinceEpoch() - hit.at) < self.yabaiCacheSeconds then
    return done(hit.data, nil)
  end

  -- A recent failure is cached as firmly as an answer, and checked even when forced: a socket that refused ten milliseconds ago cannot succeed, and the forcing caller should wait least
  if self.yabaiFailedAt and (hs.timer.secondsSinceEpoch() - self.yabaiFailedAt) < self.yabaiCacheSeconds then
    return done(nil, self.yabaiLastError or "yabai failed a moment ago")
  end

  -- Join a query of the same kind already in flight rather than starting a second one
  local waiting = self.yabaiPending[kind]
  if waiting then
    waiting[#waiting + 1] = done
    return
  end
  self.yabaiPending[kind] = { done }

  self:yabaiRun({ "--message", "query", "--" .. kind }, function(ok, out, err)
    local data, why
    if not ok then
      -- A first query failing overwhelmingly means installed but not running; worth one line, since the alternative is silently paying for a second-long drag forever
      why = err
      self.yabaiLastError = tostring(err)
      self.yabaiFailedAt = hs.timer.secondsSinceEpoch()
      self:warnOnce(
        "yabaiserver",
        "yabai is installed but not answering (%s); is the service running? "
          .. "Try `yabai --start-service`. Carrying on without it.",
        tostring(err)
      )
    else
      -- decode() raises on malformed input rather than returning nil
      local okJson, decoded = pcall(hs.json.decode, out or "")
      if okJson and type(decoded) == "table" then
        data = decoded
        self.yabaiLastError = nil
        self.yabaiFailedAt = nil
        self.yabaiCache[kind] = { at = hs.timer.secondsSinceEpoch(), data = decoded }
      else
        why = "unparseable " .. kind .. " list"
        self:warnOnce(
          "yabaijson",
          "could not parse `yabai --message query --%s` output; the yabai CLI may have changed shape",
          kind
        )
      end
    end

    -- Cleared before any callback, so a waiter that queries starts a fresh round
    local waiters = self.yabaiPending[kind] or {}
    self.yabaiPending[kind] = nil
    for _, cb in ipairs(waiters) do
      pcall(cb, data, why)
    end
  end)
end

-- The last known space and window lists, or nil when yabai has never answered
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
--- When yabai is off or not installed, `done` is called immediately and synchronously with `false`, which keeps every caller's behaviour identical to what it was before yabai existed.
function obj:refreshYabai(force, done)
  done = done or function() end
  if not self:yabaiBinary() then
    done(false)
    return self
  end
  self:yabaiQuery("spaces", force, function(spaces)
    self:yabaiQuery("windows", force, function(windows)
      done(spaces ~= nil and windows ~= nil)
    end)
  end)
  return self
end

-- Calls done(index, err) once. Never cached: indices renumber whenever a Space is created, destroyed or dragged, and a stale one does not fail, it moves the window to the WRONG Space
function obj:yabaiSpaceIndex(spaceId, done)
  self:yabaiQuery("spaces", true, function(spaces, err)
    if not spaces then return done(nil, err or "no answer from yabai") end
    local idToIndex = yabaiSpaceMaps(spaces)
    local index = idToIndex[spaceId]
    if index then return done(index, nil) end
    self:warnOnce(
      "yabaispace",
      "yabai does not list Space %s; its idea of the Space layout disagrees with "
        .. "hs.spaces, so yabai is skipped for moves onto it",
      tostring(spaceId)
    )
    done(nil, string.format("Space %s is unknown to yabai", tostring(spaceId)))
  end)
end

-- `ok` means only that yabai accepted the command: the scripting addition can be present, exit zero and do nothing, so the caller verifies arrival
function obj:yabaiMove(winId, target, done)
  self:yabaiSpaceIndex(target, function(index, err)
    if not index then return done(false, err) end
    self:yabaiRun({
      "-m",
      "window",
      fmtId(winId),
      "--space",
      string.format("%d", index),
    }, function(ok, _, moveErr)
      if not ok then
        -- yabai's stderr is the diagnostic part: a missing addition reads differently from an unseen window
        self:warnOnce("yabaimove", "yabai refused the move (%s)", tostring(moveErr))
      end
      done(ok, moveErr)
    end)
  end)
end

-- Only for windows with no hs.window, and only where arrival has already been verified
function obj:yabaiFocus(winId)
  self:yabaiRun({ "--message", "window", fmtId(winId), "--focus" }, function(ok, _, err)
    if not ok then self.logger.f("yabai could not focus window %s (%s)", tostring(winId), tostring(err)) end
  end)
end

-- Finding windows on other Spaces

-- Neither source suffices: the filter only learns a window once it has seen its Space, and allWindows() is documented as current-Space only. `deep` overrides deepScan for the menubar, where the sweep would beachball the synchronous callback
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
    if ok and type(wins) == "table" then
      for _, win in ipairs(wins) do
        add(win)
      end
    else
      self:warnOnce("filter", "window filter query failed (%s)", tostring(wins))
    end
  end

  if deep then
    local ok, wins = pcall(hs.window.allWindows)
    if ok and type(wins) == "table" then
      for _, win in ipairs(wins) do
        add(win)
      end
    else
      self:warnOnce("allWindows", "hs.window.allWindows failed (%s)", tostring(wins))
    end
  end

  return out
end

-- Accessors are bare rather than pcall'd because candidates() wraps this whole function, so a window dying mid-inspection is caught once rather than read as "not summonable"
function obj:classify(win, current, model)
  if not win:isStandard() then return nil end

  local app = win:application()
  if app and app:bundleID() == hs.processInfo.bundleID then return nil end

  -- Checked here and on the Space below: this catches the app fullscreen right now, that catches windows parked in a fullscreen Space that do not report it themselves
  if win:isFullScreen() then return nil end

  local minimized = win:isMinimized()
  if minimized and not self.includeMinimized then return nil end

  local spaces = self:spacesFor(win)
  if not spaces or #spaces == 0 then return nil end

  -- Also drops sticky windows, which report every Space and so always contain this one
  if hs.fnutils.contains(spaces, current) then return nil end

  -- Prefer the first Space we could actually move the window out of
  local spaceId = firstMovableSpace(spaces, model.types)
  if not spaceId then return nil end

  local title = win:title() or ""
  return {
    winId = win:id(),
    spaceId = spaceId,
    appName = (app and app:name()) or "?",
    bundleID = app and app:bundleID() or nil,
    title = title,
    minimized = minimized,
    label = model.labels[spaceId] or string.format("Space %s", tostring(spaceId)),
    -- Unplaceable Spaces sort last rather than erroring out of table.sort()
    order = model.order[spaceId] or math.huge,
  }
end

-- The windows yabai sees that Accessibility did not hand us. Most are recovered as real hs.window objects; the rest are marked yabaiOnly, since yabai moves by id. The rejections mirror classify() rather than calling it, which would discard the very windows worth having
function obj:yabaiEntries(current, model, seen)
  local out = {}
  local spaces, windows = self:yabaiSnapshot()
  if not (spaces and windows) then return out end

  local _, indexToId = yabaiSpaceMaps(spaces)

  -- Memoised per pass, so an application with eight windows out there costs one AX query
  local apps = {}
  local function appFor(pid)
    if type(pid) ~= "number" then return nil end
    if apps[pid] then return apps[pid] end

    local entry = { app = false, windows = {} }
    local okApp, app = pcall(hs.application.applicationForPID, pid)
    if okApp and app then
      entry.app = app
      -- One application's AX query, not the whole system's, which is what makes this affordable
      local okWins, wins = pcall(app.allWindows, app)
      if okWins and type(wins) == "table" then
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
    local id = (type(w) == "table" and type(w.id) == "number") and math.floor(w.id) or nil
    -- is-sticky windows are already here; is-hidden is the whole app, which summoning cannot undo
    if
      id
      and not seen[id]
      and w.pid ~= hs.processInfo.processID
      and w.role == "AXWindow"
      and w.subrole == "AXStandardWindow"
      and not w["is-sticky"]
      and not w["is-native-fullscreen"]
      and not w["is-hidden"]
      and (self.includeMinimized or not w["is-minimized"])
    then
      local spaceId = type(w.space) == "number" and indexToId[math.floor(w.space)] or nil
      if spaceId and spaceId ~= current and model.types[spaceId] ~= "fullscreen" then
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
            appName = w.app or "?",
            bundleID = bundleID,
            title = w.title or "",
            minimized = w["is-minimized"] and true or false,
            label = model.labels[spaceId] or string.format("Space %s", tostring(spaceId)),
            order = model.order[spaceId] or math.huge,
            -- No hs.window behind it, so only the yabai rung can move this one
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
--- Rebuilds from scratch on every call, and as a side effect refreshes the internal id-to-window map that `SummonWindow:summonById()` reads.
--- The yabai source is served from the last snapshot rather than fetched here, because `hs.menubar` demands its menu synchronously and cannot wait for a subprocess. `SummonWindow:show()` refreshes before it builds, so the chooser is always current; the menubar menu can be up to `SummonWindow.yabaiCacheSeconds` behind.
--- The menubar path passes `deep = false` for the same reason: the `hs.window.allWindows()` sweep can take seconds, and the menu callback cannot wait for it either. The chooser, `status()` and `diagnose()` all still run the full sweep.
function obj:candidates(opts)
  local current = self:currentSpace()
  if not current then return {} end

  local model = self:spaceModel()
  local entries = {}
  -- Built in locals and published together, since an open chooser holds winIds that resolve only through these tables, and any rebuild would empty them under the rows on screen
  local byId = {}
  -- So a failure message can still name a window that has become uninspectable since
  local lastEntries = {}

  -- Every id Accessibility produced, whatever classify() decided: yabai may only ADD windows those sources could not see, never resurrect one already ruled out
  local seen = {}

  for _, win in ipairs(self:knownWindows(opts and opts.deep)) do
    local okId, id = pcall(win.id, win)
    if okId and id then seen[id] = true end

    -- Wrapped per window: a window closed since enumeration leaves userdata whose accessors throw, and one dead window should cost one row rather than the list
    local ok, entry = pcall(self.classify, self, win, current, model)
    if not ok then
      self:warnOnce("classify", "window inspection failed (%s); skipping", tostring(entry))
    elseif entry then
      byId[entry.winId] = win
      lastEntries[entry.winId] = entry
      entries[#entries + 1] = entry
    end
  end

  local okYabai, found = pcall(self.yabaiEntries, self, current, model, seen)
  if not okYabai then
    self:warnOnce("yabaientries", "reading yabai's window list failed (%s); skipping it", tostring(found))
  else
    for _, item in ipairs(found) do
      -- nil for a yabai-only window, which is why summonById reads lastEntries as authority
      byId[item.entry.winId] = item.win
      lastEntries[item.entry.winId] = item.entry
      entries[#entries + 1] = item.entry
    end
  end

  -- Warm the next build's snapshot; unforced, so repeated calls inside the window cost nothing
  self:refreshYabai(false)

  -- Published only now both are complete, so an open chooser never hits a half-built map
  self.byId, self.lastEntries = byId, lastEntries

  table.sort(entries, bySpaceThenApp)
  return entries
end

-- Chooser

function obj:choiceList()
  local entries = self:candidates()

  if #entries == 0 then
    -- valid = false keeps the row from dismissing the chooser when it is selected
    return {
      {
        text = "No windows on other Spaces",
        subText = "Everything is already here - or run SummonWindow:diagnose() in the Console",
        valid = false,
      },
    }
  end

  local icons, out = {}, {}
  for _, e in ipairs(entries) do
    out[#out + 1] = {
      text = e.title ~= "" and e.title or e.appName,
      subText = string.format("%s - %s%s", e.appName, e.label, e.minimized and " (minimized)" or ""),
      image = self:iconFor(e.bundleID, icons),
      -- Only plain values survive the trip into the chooser; the window itself is in byId
      winId = e.winId,
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection
    if not choice or not choice.winId then return end
    self:summonById(choice.winId)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  self.chooser:searchSubText(true)
  self.chooser:placeholderText("Summon a window from another Space…")
  return self.chooser
end

-- Menubar

function obj:buildMenu()
  local menu = {}
  -- deep = false: hs.menubar demands this table synchronously, and the allWindows() sweep would block the main thread until every application answered. A slightly stale menu beats one that beachballs
  local entries = self:candidates({ deep = false })

  if #entries == 0 then
    menu[#menu + 1] = { title = "No windows on other Spaces", disabled = true }
  else
    local icons, lastLabel = {}, nil
    for _, e in ipairs(entries) do
      if e.label ~= lastLabel then
        if lastLabel then menu[#menu + 1] = { title = "-" } end
        menu[#menu + 1] = { title = e.label, disabled = true }
        lastLabel = e.label
      end

      -- The id, not `e`: closing over the entry would keep it alive as long as the menu
      local winId = e.winId
      menu[#menu + 1] = {
        title = string.format("%s - %s", e.appName, truncate(e.title, self.titleMax)),
        image = self:iconFor(e.bundleID, icons, 16),
        indent = 1,
        fn = function()
          self:summonById(winId)
        end,
      }
    end
  end

  menu[#menu + 1] = { title = "-" }
  menu[#menu + 1] = {
    title = "Search…",
    fn = function()
      self:show()
    end,
  }
  return menu
end

-- Synthetic input

local ET = hs.eventtap.event
local TY = ET.types
local PR = ET.properties

-- clickState is set by hand: the constructor leaves it zero, which NSEvent reports as a clickCount of 0, and Chromium-derived apps read that as "not a real click"
local function mouseDown(pt)
  local e = ET.newMouseEvent(TY.leftMouseDown, pt)
  pcall(function()
    e:setProperty(PR.mouseEventClickState, 1)
  end)
  e:post()
end

-- What makes the routine work: macOS starts a move gesture only when a drag FOLLOWS the press, and apps that hit-test their own titlebars ignore a press without one
local function mouseDrag(pt, dx)
  local e = ET.newMouseEvent(TY.leftMouseDragged, { x = pt.x + dx, y = pt.y })
  pcall(function()
    e:setProperty(PR.mouseEventDeltaX, dx)
    e:setProperty(PR.mouseEventDeltaY, 0)
  end)
  e:post()
end

local function mouseUp(pt)
  ET.newMouseEvent(TY.leftMouseUp, pt):post()
end

-- absolutePosition is a warp and generates no move event, so post one too and satisfy both kinds of observer
local function placeCursor(pt)
  hs.mouse.absolutePosition(pt)
  ET.newMouseEvent(TY.mouseMoved, pt):post()
end

-- Idempotent, since the end of an arrow and every teardown path both call it
local function releaseCtrl(job)
  if not job.ctrlDown then return end
  job.ctrlDown = false
  pcall(function()
    ET.newKeyEvent("ctrl", false):post()
  end)
end

-- The ctrl-up is the dangerous half, posted from a timer: a teardown mid-sequence would strand ctrl down system-wide, so the timers live on the job and ctrlDown records the debt
local function pressSpaceArrow(job, dir, useFn, keyHold, done)
  local mods = useFn and { "ctrl", "fn" } or { "ctrl" }
  ET.newKeyEvent("ctrl", true):post()
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

-- Dragging a window across Spaces

-- The dead strip left of the close button: the centre tears off a browser tab, a fixed titlebar height misses compact toolbars, and the close button's frame gives a true centre line
function obj:grabPoint(win)
  local okF, f = pcall(win.frame, win)
  if not okF or not f then return nil, "window has no frame" end

  local ok, ax = pcall(hs.axuielement.windowElement, win)
  if ok and ax then
    local okB, btn = pcall(function()
      return ax.AXCloseButton
    end)
    local cf = okB and btn and btn.AXFrame
    if cf and cf.x and cf.h and cf.h > 0 then
      return {
        x = math.floor(f.x + (cf.x - f.x) / 2),
        y = math.floor(cf.y + cf.h / 2),
      }
    end
  end

  -- No close button: the three lights sit 20pt apart, so its left edge is ~40pt from zoom's
  local okZ, zr = pcall(win.zoomButtonRect, win)
  if okZ and type(zr) == "table" and zr.x and zr.h and zr.h > 0 then
    return {
      x = math.floor(f.x + math.max(6, (zr.x - 40 - f.x) / 2)),
      y = math.floor(zr.y + zr.h / 2),
    }
  end

  -- Neither means there is genuinely no titlebar, and a guessed point would press into content
  return nil, "window has no titlebar to grab"
end

-- The full list, not just user Spaces: the arrow keys step through fullscreen ones too
function obj:spaceOrder(win)
  local scr = win:screen()
  local uuid = scr and scr:getUUID()
  if not uuid then return nil, "window is not on any screen" end
  local ok, list = pcall(hs.spaces.spacesForScreen, uuid)
  if not ok or type(list) ~= "table" or #list == 0 then return nil, "could not read the Space order for this screen" end
  return list
end

-- Precomputing the route is what lets every hop be gated on arriving somewhere known rather than on a hopeful delay
local function pathBetween(order, fromIdx, toIdx)
  local step = (toIdx > fromIdx) and 1 or -1
  local path = {}
  for i = fromIdx + step, toIdx, step do
    path[#path + 1] = order[i]
  end
  return path, (step == 1) and "right" or "left"
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
--- Called from `SummonWindow:stop()`. A config reload part-way through a drag would otherwise collect the timers that hold the sequence together and leave the button down with nothing left to release it.
function obj:abortDrag()
  local job = self.dragJob
  if job and not job.finished then
    job.finished = true
    if job.holding then pcall(mouseUp, hs.mouse.absolutePosition()) end
    releaseCtrl(job)
    if job.watchdog then pcall(function()
      job.watchdog:stop()
    end) end
    if job.timer then pcall(function()
      job.timer:stop()
    end) end
    pcall(hs.mouse.absolutePosition, job.cursor)
    self.dragJob = nil
    self.logger.w("drag aborted")
  end
  return self
end

-- A window can only be picked up on the visible Space, so this walks there, takes hold, and walks back carrying it. Both legs use the keyboard shortcut, since Mission Control eats mouse events
function obj:dragToCurrentSpace(win, done)
  local T = self.dragTiming

  if self.dragJob then return done(false, "a drag is already in progress") end
  if hs.eventtap.isSecureInputEnabled() then
    -- A focused password field anywhere swallows synthetic keys, stranding the window mid-air
    return done(false, "secure input is active, so Space switches would be ignored")
  end

  local okHere, here = pcall(hs.spaces.focusedSpace)
  if not okHere or type(here) ~= "number" then return done(false, "could not determine the current Space") end
  local spaces = self:spacesFor(win)
  if not spaces or #spaces == 0 then return done(false, "could not determine the window's Space") end
  local from = firstMovableSpace(spaces, self:spaceModel().types)
  if not from then return done(false, "the window is only on a fullscreen Space, which it cannot be dragged out of") end

  local order, oErr = self:spaceOrder(win)
  if not order then return done(false, oErr) end
  local iFrom, iHere = hs.fnutils.indexOf(order, from), hs.fnutils.indexOf(order, here)
  if not (iFrom and iHere) then
    return done(false, "the window is on a different display; dragging across screens does not work")
  end

  local outPath, outDir = pathBetween(order, iHere, iFrom) -- empty-handed, to fetch it
  local backPath, backDir = pathBetween(order, iFrom, iHere) -- loaded, bringing it home

  -- From here a button may be held, so there is exactly one exit path and it always releases: finishing, a step throwing and the watchdog all go through finish()

  local job = {
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

    -- Release first, before anything that could itself fail
    if job.holding then
      pcall(mouseUp, hs.mouse.absolutePosition())
      job.holding = false
    end
    releaseCtrl(job)
    if job.watchdog then pcall(function()
      job.watchdog:stop()
    end) end
    if job.timer then pcall(function()
      job.timer:stop()
    end) end
    self.dragJob = nil

    hs.timer.doAfter(T.postRelease, function()
      -- Undo the arming nudges: the alternating sign should cancel them, but an app that snapped the window mid-drag will have moved it anyway
      if job.frame then
        local okVis, visible = pcall(win.isVisible, win)
        if okVis and visible then pcall(win.setFrame, win, job.frame) end
      end
      pcall(hs.mouse.absolutePosition, job.cursor)
      done(ok, err)
    end)
  end

  -- Not belt and braces: hs.timer callbacks run protected, so a throw would stop the sequence silently with the button still down, and only the watchdog would rescue it
  local function step(fn)
    return function()
      if job.finished then return end
      local ok, err = pcall(fn)
      if not ok then finish(false, tostring(err)) end
    end
  end

  local hops = #outPath + #backPath
  job.watchdog = hs.timer.doAfter(2.0 + (T.hopTimeout + 0.3) * hops, function()
    finish(false, "the drag stalled and was abandoned")
  end)

  -- One hop, gated on arriving somewhere known: the window server drops Space-switch input while a switch animates, so a burst of N presses yields one or two hops with no way to tell which
  local function hop(dir, expectId, onOk)
    pressSpaceArrow(job, dir, self.useFnModifier, T.keyHold, function()
      local deadline = hs.timer.secondsSinceEpoch() + T.hopTimeout
      local function arrived()
        local ok, cur = pcall(hs.spaces.focusedSpace)
        return ok and cur == expectId
      end
      job.timer = hs.timer.waitUntil(function()
        return arrived() or hs.timer.secondsSinceEpoch() > deadline
      end, function()
        if not arrived() then
          local _, cur = pcall(hs.spaces.focusedSpace)
          return finish(
            false,
            string.format("Space switch timed out (wanted %s, still on %s)", tostring(expectId), tostring(cur))
          )
        end
        hs.timer.doAfter(T.hopSettle, step(onOk))
      end, T.hopPoll)
    end)
  end

  -- Each landing gets a fresh drag event so the gesture cannot lapse, with an alternating sign so the nudges cancel out
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
        -- Raising matters: if another window overlaps the grab point we would seize that one
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
                hs.timer.doAfter(
                  T.dragToHop,
                  step(function()
                    walk(backPath, backDir, 1, release)
                  end)
                )
              end)
            )
          end)
        )
      end)
    )
  end

  self.logger.f(
    "dragging window %s home: %d hop(s) %s to fetch, %d back",
    tostring(win:id()),
    #outPath,
    outDir,
    #backPath
  )
  walk(outPath, outDir, 1, grabAndReturn)
end

-- Spoon API

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
--- Deliberately starts nothing. The menubar item, the chooser and the window filter all belong to `SummonWindow:start()`.
--- It is also deliberately empty rather than re-initialising state. The declarations above already run on a freshly loaded object, and `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load -- so clearing state here would strand a chooser or menubar item that is already live.
function obj:init()
  return self
end

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
--- Calling this on an already-started Spoon restarts it cleanly.
--- Nothing polls and no timer runs. The window list is built on demand, when the chooser opens or the menu is pulled down.
--- Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  -- The default filter already discards menulets and preference panes. setCurrentSpace(nil) is spelled out because it is the exact property this Spoon depends on
  self.windowFilter = hs.window.filter.new()
  self.windowFilter:setCurrentSpace(nil)
  self.windowFilter:rejectApp("Hammerspoon")

  -- Deliberately NOT forceRefreshOnSpaceChange: it is global, and would tax the filters FocusBorder and PinnedWindows keep alive on every Space change

  self.byId = {}

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "summonwindow")
    if self.menubarItem then
      -- Styled for the size only. Leaving the colour out is what keeps AppKit's own menubar label colour, and with it light and dark appearance for free
      self.menubarItem:setTitle(hs.styledtext.new(self.menubarTitle, { font = self.menubarFont }))
      self.menubarItem:setTooltip("Summon a window from another Space")
      -- Wrapped: a throw inside the menu callback would leave a dead menubar icon. Setting a menu also disables setClickCallback by design, so "Search…" is what opens the chooser
      self.menubarItem:setMenu(function(mods)
        local ok, menu = pcall(self.buildMenu, self, mods)
        if ok then return menu end
        self.logger.wf("menu build failed: %s", tostring(menu))
        return {
          { title = "Menu failed to build - see console", disabled = true },
          { title = "-" },
          {
            title = "Search…",
            fn = function()
              self:show()
            end,
          },
        }
      end)
    else
      self.logger.w("could not create the menubar item")
    end
  end

  self.running = true

  if not hs.accessibilityState() then
    hs.alert.show("SummonWindow needs Accessibility permission")
    self.logger.w("accessibility permission not granted; nothing will work until it is")
  end
  if not (hs.spaces and hs.spaces.moveWindowToSpace) then
    self.logger.w("hs.spaces.moveWindowToSpace is unavailable; relying on yabai and dragging")
  end

  -- Warmed now rather than on the first summon, so the first list after a reload is as complete as every later one; returns immediately when yabai is absent
  self:refreshYabai(true)

  self.logger.i("started")
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
--- Any hotkeys bound with `SummonWindow:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped: a drag holds a mouse button whose release timers are about to become unreachable, and a yabai command would answer into a half-torn-down Spoon
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

  -- No unsubscribe: this Spoon only queries the filter, and the global watcher is refcounted, so the other Spoons' filters are unaffected
  self.windowFilter = nil

  self.byId = {}
  self.lastEntries = {}
  self.warned = {}
  self.yabaiCache = {}
  self.yabaiLastError = nil
  self.yabaiFailedAt = nil
  -- Re-probed on the next start(), so installing yabai or starting its service is noticed after a reload; the failure backoff goes with it
  self.yabaiResolved = nil
  self.running = false
  self.logger.i("stopped")
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
--- For example: `spoon.SummonWindow:bindHotkeys({ summon = { { "cmd", "alt", "shift" }, "S" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    summon = hs.fnutils.partial(self.toggle, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
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
--- Refuses to open while you are on a fullscreen Space, because the window server will not accept a window moved into one.
--- When yabai is in use the chooser opens a few milliseconds late, because it waits for a current window list rather than showing a cached one. Without yabai it opens synchronously, exactly as it always did.
function obj:show()
  local target, why = self:summonableSpace()
  if not target then
    hs.alert.show("SummonWindow: " .. why)
    self.logger.wf("cannot show chooser: %s", why)
    return self
  end

  -- The chooser is the hotkey path, so it is worth milliseconds to open against a current picture; without yabai this calls straight back on this stack, exactly as it always did
  self:refreshYabai(true, function()
    local chooser = self:ensureChooser()
    -- Static table, so the list rebuilds on open; a callback caches until refreshChoicesCallback()
    chooser:choices(self:choiceList())
    chooser:query("")
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
--- If the last summon failed and left an offer to jump to that window's Space, pressing the hotkey again within `SummonWindow.gotoGraceSeconds` takes the offer instead of reopening the chooser. The offer is consumed either way, so a third press behaves normally.
function obj:toggle()
  if self.chooser and self.chooser:isVisible() then return self:hide() end
  -- Checked first: the "press again to go there" half must win over reopening the chooser
  if self:takePendingGoto() then return self end
  return self:show()
end

-- Did the window land? With an hs.window this is awaitArrival(); without one, yabai is asked instead, on a deliberately slower poll, each tick being a subprocess rather than a call
function obj:confirmArrival(win, winId, target, timeout, done)
  if win then return self:awaitArrival(win, target, timeout, done) end

  self:yabaiSpaceIndex(target, function(index)
    if not index then return done(false) end
    local deadline = hs.timer.secondsSinceEpoch() + (timeout or 0.6)
    local function poll()
      self:yabaiRun({ "--message", "query", "--windows", "--window", fmtId(winId) }, function(ok, out)
        local landed = false
        if ok then
          local okJson, w = pcall(hs.json.decode, out or "")
          landed = okJson and type(w) == "table" and type(w.space) == "number" and math.floor(w.space) == index
        end
        if landed or hs.timer.secondsSinceEpoch() > deadline then return done(landed) end
        hs.timer.doAfter(0.15, poll)
      end)
    end
    poll()
  end)
end

-- The move ladder

-- Least intrusive first; this list IS the control flow. `run` reports only that it issued its request, never success, because all three lie -- arrival is decided by confirmArrival() alone
local ENGINES = {
  {
    -- Ahead of the native rung, which is free only in CPU: it costs 350ms of wall clock finding out it did nothing, on every summon, where yabai answers in about thirty
    name = "yabai",
    available = function(self)
      if not self.useYabai then return false, "turned off" end
      if not self:yabaiBinary() then return false, "not installed" end
      return true
    end,
    verify = function(self)
      return self.yabaiVerifyTimeout
    end,
    run = function(self, win, winId, target, done)
      self:yabaiMove(winId, target, done)
    end,
    onNoArrival = function(self)
      self:warnOnce(
        "yabaisilent",
        "yabai accepted the move but the window did not arrive. Its scripting addition is "
          .. "probably not loaded for this macOS build -- try `sudo yabai --load-sa`. "
          .. "Falling back to the other rungs."
      )
    end,
  },
  {
    -- Kept though it has never worked on a current macOS: one call to try, and this starts using the fast path again by itself the day Hammerspoon adopts the replacement API
    name = "native",
    available = function(self, win)
      if not win then return false, "no window object; only yabai can move this one" end
      if not (hs.spaces and hs.spaces.moveWindowToSpace) then return false, "unavailable on this build" end
      return true
    end,
    verify = function(self)
      return 0.35
    end,
    run = function(self, win, winId, target, done)
      local ok, _, err = pcall(hs.spaces.moveWindowToSpace, win, target)
      if not ok then self:warnOnce("movecall", "moveWindowToSpace threw: %s", tostring(err)) end
      -- Reported as issued whatever it returned: the value carries no information, so confirmArrival is the only thing entitled to an opinion
      done(true, nil)
    end,
    onNoArrival = function(self)
      self:warnOnce(
        "nativedead",
        "hs.spaces.moveWindowToSpace reported success but the window did not move; "
          .. "this is expected on macOS 15+ (Hammerspoon issue #3698)."
      )
    end,
  },
  {
    -- Last, always: it borrows the pointer and takes the better part of a second, but it is the only rung needing neither a private API nor a disabled SIP, so on a stock machine it does all the work
    name = "drag",
    available = function(self, win)
      if not win then return false, "no window object; only yabai can move this one" end
      if not self.dragFallback then return false, "dragFallback is off" end
      return true
    end,
    verify = function(self)
      return self.dragTiming.verifyTimeout
    end,
    -- target is ignored: a drag can only land on the Space you are looking at, which is this one
    run = function(self, win, winId, target, done)
      self:dragToCurrentSpace(win, done)
    end,
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
--- The id must have come from a `SummonWindow:candidates()` pass, since everything known about the window is looked up in the maps that call builds. Windows on other Spaces cannot be recovered from an id alone.
--- Tries every rung of the move ladder in turn -- yabai, then the native window server call, then dragging -- stopping at the first one whose result can be *verified*. A window only yabai could see has no `hs.window` behind it, so for that window the ladder is one rung long.
function obj:summonById(winId)
  -- lastEntries is the authority, since a yabai-only window has a description and no hs.window
  local entry = self.lastEntries[winId]
  if not entry then
    self.logger.wf("window %s is not in the current candidate map", tostring(winId))
    hs.alert.show("SummonWindow: that window is no longer available")
    return self
  end
  local win = self.byId[winId]

  -- Re-checked at the moment of the move: the list may have sat open across a Space change
  local target, why = self:summonableSpace()
  if not target then
    hs.alert.show("SummonWindow: " .. why)
    return self
  end

  -- Straight off the entry, which is in hand by here; the name comes from the list rather than the window because a failure message must name one we may no longer be able to inspect
  local label, appName = entry.label, entry.appName
  -- Asked fresh when possible, since the window may have moved since the list was built
  local sourceSpace = entry.spaceId
  if win then
    local spaces = self:spacesFor(win)
    sourceSpace = firstMovableSpace(spaces, self:spaceModel().types) or sourceSpace
  end

  -- Arriving is the only definition of success, and focus() is deliberately unreachable from any failure path: focusing a window that never moved is the yank this Spoon exists to avoid
  local function arrived(engine)
    self:clearPendingGoto()
    if self.focusAfterMove then
      if win then
        -- Otherwise the move is invisible: it arrives still in the Dock, with nothing to show
        local okMin, minimized = pcall(win.isMinimized, win)
        if okMin and minimized then pcall(win.unminimize, win) end
        pcall(win.focus, win)
        pcall(win.raise, win)
      else
        -- Nothing local to focus, and reached only after arrival was verified
        self:yabaiFocus(winId)
      end
    end
    self.logger.f("summoned window %s to space %s via %s", tostring(winId), tostring(target), engine)
  end

  -- The log gets the whole ladder's reasoning; three semicolon-joined clauses do not fit an alert
  local function gaveUp(why, detail)
    self.logger.wf("could not summon window %s: %s", tostring(winId), tostring(detail or why))
    if sourceSpace then
      self:offerGoto(sourceSpace, label)
      hs.alert.show(string.format("SummonWindow: could not move %s - press again to go to %s", appName, label), 3)
    else
      hs.alert.show("SummonWindow: could not move that window - " .. tostring(why), 3)
    end
  end

  -- Off, absent, inapplicable, refusing and silently doing nothing all lead to the next rung. A recursion over ENGINES, so the nesting stays one level deep however many rungs there are
  local reasons = {}

  local function attempt(i)
    local engine = ENGINES[i]
    if not engine then return gaveUp(reasons[#reasons] or "no method available", table.concat(reasons, "; ")) end

    local okAvail, available, whyNot = pcall(engine.available, self, win)
    if not okAvail or not available then
      reasons[#reasons + 1] = engine.name .. ": " .. tostring(whyNot or available or "unavailable")
      return attempt(i + 1)
    end

    -- run() answers from timer and task callbacks, where a throw is swallowed, so this guarantees exactly one answer per rung rather than a ladder stranded with no alert shown
    local answered = false
    local function step(ok, err)
      if answered then return end
      answered = true

      if not ok then
        reasons[#reasons + 1] = string.format("%s: %s", engine.name, tostring(err or "failed"))
        return attempt(i + 1)
      end

      self:confirmArrival(win, winId, target, engine.verify(self), function(moved)
        if moved then return arrived(engine.name) end
        if engine.onNoArrival then pcall(engine.onNoArrival, self) end
        reasons[#reasons + 1] = engine.name .. ": issued, but the window did not arrive"
        attempt(i + 1)
      end)
    end

    local okRun, runErr = pcall(engine.run, self, win, winId, target, step)
    if not okRun then step(false, tostring(runErr)) end
  end

  attempt(1)
  return self
end

function obj:offerGoto(spaceId, label)
  self.pendingGoto = { spaceId = spaceId, label = label, at = hs.timer.secondsSinceEpoch() }
end

function obj:clearPendingGoto()
  self.pendingGoto = nil
end

-- Returns true when it acted, so the caller knows not to open the chooser
function obj:takePendingGoto()
  local pending = self.pendingGoto
  if not pending then return false end
  self.pendingGoto = nil
  if hs.timer.secondsSinceEpoch() - pending.at > self.gotoGraceSeconds then return false end
  self.logger.f("going to space %s instead of summoning", tostring(pending.spaceId))
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
--- Run this first if the list comes up empty. The line that matters is the per-source count of windows found on *other* Spaces: if both sources report zero while windows plainly exist elsewhere, macOS is hiding them from Accessibility and no amount of filtering will help.
--- Each listed window is tagged with the source that found it -- `filter`, `ax`, or both -- which shows whether `SummonWindow.deepScan` is earning its keep on this machine.
function obj:diagnose()
  local out = {}
  local function say(fmt, ...)
    out[#out + 1] = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
  end

  say("SummonWindow diagnose")
  say(
    "running=%s  deepScan=%s  includeMinimized=%s  filter=%s",
    tostring(self.running),
    tostring(self.deepScan),
    tostring(self.includeMinimized),
    tostring(self.windowFilter ~= nil)
  )

  if not (hs.spaces and hs.spaces.focusedSpace) then
    say("")
    say("hs.spaces is UNAVAILABLE on this build -- this Spoon cannot work.")
    local text = table.concat(out, "\n")
    print(text)
    return text
  end

  local current = self:currentSpace()
  local model = self:spaceModel()
  -- Not reported as a plain "moveWindowToSpace=true": it exists on every build, and what matters is whether it does anything, which on macOS 15+ it does not
  local major = tonumber((hs.host.operatingSystemVersionString() or ""):match("(%d+)%.")) or 0
  say(
    "accessibility=%s  secureInput=%s  dragFallback=%s",
    tostring(hs.accessibilityState()),
    tostring(hs.eventtap.isSecureInputEnabled()),
    tostring(self.dragFallback)
  )
  -- Reported as a ladder, since which rung carries the work is now a three-way answer
  local yabaiBin = self:yabaiBinary()
  say(
    "move ladder: 1.yabai=%s  2.native=%s  3.drag=%s",
    not self.useYabai and "off" or yabaiBin or "not installed",
    major >= 15 and "expected DEAD (Hammerspoon #3698)" or "may work on this macOS",
    tostring(self.dragFallback)
  )
  say(
    "current Space: %s (%s, type=%s)",
    tostring(current),
    current and (model.labels[current] or "unlabelled") or "unknown",
    current and (model.types[current] or "unknown") or "n/a"
  )

  -- Queried separately rather than through knownWindows(), so every window can be attributed
  local function idSetOf(getter)
    local set, n = {}, 0
    local ok, wins = pcall(getter)
    if not ok or type(wins) ~= "table" then return set, n, tostring(wins) end
    for _, win in ipairs(wins) do
      local okId, id = pcall(win.id, win)
      if okId and id and not set[id] then
        set[id] = win
        n = n + 1
      end
    end
    return set, n
  end

  -- The decisive measurement: how many windows each source sees that are NOT here
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

  say("")
  say("Sources:")
  say(
    "  hs.window.filter      %4d windows, %d on other Spaces%s",
    filterN,
    elsewhere(filterSet),
    filterErr and (" [error: " .. filterErr .. "]") or ""
  )
  say(
    "  hs.window.allWindows  %4d windows, %d on other Spaces%s",
    axN,
    elsewhere(axSet),
    axErr and (" [error: " .. axErr .. "]") or ""
  )

  -- From the snapshot rather than re-queried, since a query is a subprocess and diagnose() returns its text on this stack; the age is printed so a stale one cannot pass for current
  local yabaiSet, yabaiN = {}, 0
  if yabaiBin then
    local spaces, windows, at = self:yabaiSnapshot()
    if not windows then
      -- A service that is down looks like one not yet asked, and the fixes are different
      say(
        "  yabai                 %s",
        self.yabaiLastError
            and ("INSTALLED BUT NOT ANSWERING (" .. self.yabaiLastError .. ") - try `yabai --start-service`")
          or "(no snapshot yet - run diagnose() again in a moment)"
      )
    else
      local _, indexToId = yabaiSpaceMaps(spaces)
      local away = 0
      for _, w in ipairs(windows) do
        if type(w) == "table" and type(w.id) == "number" then
          yabaiSet[math.floor(w.id)] = true
          yabaiN = yabaiN + 1
          local sid = type(w.space) == "number" and indexToId[math.floor(w.space)] or nil
          if sid and sid ~= current then away = away + 1 end
        end
      end
      -- The decisive line when the lists disagree: Spaces yabai reports but hs.spaces cannot match mean the two are numbering the world differently, and the yabai source is quietly useless
      local matched = 0
      for _, s in ipairs(spaces or {}) do
        if type(s) == "table" and model.order[s.id] then matched = matched + 1 end
      end
      say(
        "  yabai                 %4d windows, %d on other Spaces  [snapshot %.1fs old, %d/%d Spaces matched to hs.spaces]",
        yabaiN,
        away,
        hs.timer.secondsSinceEpoch() - at,
        matched,
        #(spaces or {})
      )
    end
  else
    say("  yabai                 %s", not self.useYabai and "(turned off)" or "(not installed)")
  end

  say("")
  say("Spaces:")
  local ids = {}
  for id in pairs(model.order) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return model.order[a] < model.order[b]
  end)
  for _, id in ipairs(ids) do
    -- windowsForSpace sees every Space but includes overlays and scratch surfaces: a ceiling, not a target
    local raw = "-"
    if hs.spaces.windowsForSpace then
      local okRaw, rawIds = pcall(hs.spaces.windowsForSpace, id)
      if okRaw and type(rawIds) == "table" then raw = tostring(#rawIds) end
    end
    say(
      "  %-34s id=%-7s type=%-11s windowsForSpace=%-5s%s",
      model.labels[id] or "?",
      tostring(id),
      model.types[id] or "?",
      raw,
      id == current and "  <- current" or ""
    )
  end

  local entries = self:candidates()
  say("")
  say("Summonable: %d window(s)", #entries)
  for _, e in ipairs(entries) do
    local tags = {}
    if filterSet[e.winId] then tags[#tags + 1] = "filter" end
    if axSet[e.winId] then tags[#tags + 1] = "ax" end
    if yabaiSet[e.winId] then tags[#tags + 1] = "yabai" end
    -- A row tagged only 'yabai' is invisible to Accessibility: summonable, with no fallback
    say(
      "  [%-16s] %-22s %-50s %s%s",
      table.concat(tags, "+"),
      e.appName,
      truncate(e.title, 50),
      e.label,
      e.yabaiOnly and "  (yabai only)" or ""
    )
  end

  if #entries == 0 then
    say("")
    if #ids <= 1 then
      say("Nothing to summon: only one Space exists.")
    elseif yabaiBin then
      say("Nothing to summon, and yabai is installed -- so if windows really are on the other")
      say("Spaces above, check the yabai source line: a zero count there means the service is")
      say("not running, and a low Spaces-matched count means yabai and hs.spaces disagree")
      say("about the Space layout.")
    else
      say("Nothing to summon. If windows really are on the other Spaces above, then macOS")
      say("is not exposing them to Accessibility from here. Visit those Spaces once so the")
      say("window filter can learn them, then run this again -- or install yabai, which sees")
      say("every Space regardless.")
    end
  end

  local text = table.concat(out, "\n")
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
--- `yabai` is the resolved binary path, or `false` when yabai is switched off or not installed. It says nothing about whether the yabai *service* is running -- only `SummonWindow:diagnose()` answers that.
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
