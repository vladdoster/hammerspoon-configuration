--- === DeminimizeWindow ===
---
--- Brings a minimized window back, onto the Space you are on rather than the one it left.
---
--- Minimizing is a one-way door on macOS. The Dock collapses a window into an anonymous
--- thumbnail, `cmd-tab` walks straight past it, and the one gesture that does bring it back
--- -- clicking that thumbnail -- restores it to the Space it was minimized *from*, dragging
--- you to a different desktop to go and look at it. A window minimized on Space 3 is, in
--- practice, gone until you go there yourself.
---
--- This Spoon binds one hotkey to the obvious behaviour instead. It finds every minimized
--- window, and if there is exactly one it restores it outright; if there are several it opens
--- an `hs.chooser` to pick from; if there are none it says so and gets out of the way. In
--- every case the window arrives on the Space you are already looking at.
---
--- The hard part is not the unminimizing, which is a single Accessibility write. It is the
--- *placing*. `hs.spaces.moveWindowToSpace()` has done nothing at all since macOS 15 -- and
--- returns `true` regardless, so it cannot even be caught at it -- which leaves yabai as the
--- only thing on the machine that can move a window between Spaces. yabai in turn exits zero
--- for commands it merely accepted rather than performed, so nothing here is believed on the
--- strength of an exit code. Every step re-queries and checks.
---
--- One rule shapes the whole Spoon: **place first, reveal second, and never reveal a window
--- you could not place.** While a window is still minimized it has no presence on screen, so
--- moving it cannot pull the user anywhere; once it has been verifiably moved to the current
--- Space there is nowhere else for any later step to pull them *to*. Revealing first inverts
--- that -- `yabai --deminimize` focuses the window when its application already has focus,
--- and focusing a window on another Space is exactly the yank this Spoon exists to avoid --
--- and it fails worse, leaving the window visible somewhere the user cannot see. Placing
--- first fails harmlessly: the window stays in the Dock and nothing has moved.
---
--- A ladder of five strategies sits behind that rule, tried in turn and each verified before
--- the next is considered, so a machine without yabai still restores windows and merely
--- stops promising to place them. `DeminimizeWindow:diagnose()` prints what every source can
--- see when the list is not what you expected.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = 'DeminimizeWindow'
obj.version = '1.0'
obj.author = 'Vladislav Doster <mvdoster@gmail.com>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

--- DeminimizeWindow.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('DeminimizeWindow', 'info')

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- DeminimizeWindow.useYabai
--- Variable
--- Whether yabai is used to move the restored window onto the current Space. Defaults to `true`.
---
--- Notes:
---  * With this off -- or with yabai absent -- the Spoon still restores windows, but only through Accessibility, which cannot choose a Space. A window minimized on another Space will reappear there, and the Spoon will say so rather than pretending it succeeded.
---  * `hs.spaces.moveWindowToSpace()` is not an alternative. It has been a silent no-op since macOS 15 and returns `true` regardless of what the window server did.
obj.useYabai = true

--- DeminimizeWindow.yabaiPath
--- Variable
--- Absolute path to the yabai binary, or `nil` to probe the usual locations. Defaults to `nil`.
---
--- Notes:
---  * Only needed for an installation somewhere unusual. Homebrew on both architectures, nix-darwin and `~/.local/bin` are probed already.
obj.yabaiPath = nil

--- DeminimizeWindow.yabaiTimeout
--- Variable
--- Seconds any single yabai command may take before it is abandoned. Defaults to `1.5`.
obj.yabaiTimeout = 1.5

--- DeminimizeWindow.placeTimeout
--- Variable
--- Seconds spent confirming that a window really did land on the current Space. Defaults to `0.6`.
---
--- Notes:
---  * This is a confirmation window, not a delay. A move that worked is usually visible on the first poll.
obj.placeTimeout = 0.6

--- DeminimizeWindow.revealTimeout
--- Variable
--- Seconds spent confirming that a window really did come out of the Dock. Defaults to `1.0`.
---
--- Notes:
---  * Longer than `DeminimizeWindow.placeTimeout` because the un-minimize animation alone runs about half a second, and a busy application can be slow to honour the Accessibility write behind it.
obj.revealTimeout = 1.0

--- DeminimizeWindow.pollInterval
--- Variable
--- Seconds between checks while confirming a step. Defaults to `0.12`.
---
--- Notes:
---  * Each yabai poll is a subprocess, which is what sets this floor. Checks that can be answered from an `hs.window` run at a quarter of this interval, since they cost nothing but a function call.
obj.pollInterval = 0.12

--- DeminimizeWindow.ladderDeadline
--- Variable
--- Seconds after which a restore still in flight is abandoned outright. Defaults to `8`.
---
--- Notes:
---  * A backstop for the busy flag rather than a timeout anybody should reach. Without it, a restore stranded by an application that never answers would leave the hotkey permanently deaf -- the worst possible failure in a Spoon whose entire interface is one key.
obj.ladderDeadline = 8

--- DeminimizeWindow.skipChooserForSingle
--- Variable
--- Whether a lone minimized window is restored without showing the chooser. Defaults to `true`.
obj.skipChooserForSingle = true

--- DeminimizeWindow.focusAfterRestore
--- Variable
--- Whether the restored window is focused and raised once it has arrived. Defaults to `true`.
---
--- Notes:
---  * Reached only from success. Focusing a window that never moved is precisely what drags the user to its Space, so no failure path in this Spoon can arrive here.
---  * `yabai --deminimize` deliberately does not focus, so this is always an explicit extra step rather than something that happens by itself.
obj.focusAfterRestore = true

--- DeminimizeWindow.allowRevealFirst
--- Variable
--- Whether the reveal-first rungs of the ladder may run after placing has failed. Defaults to `true`.
---
--- Notes:
---  * These are the only rungs that can pull you to another Space, and they run only once placing has already failed -- at which point the choice is between that risk and not restoring the window at all.
---  * Set to `false` for a Spoon that is structurally incapable of moving you, and that occasionally does nothing instead.
obj.allowRevealFirst = true

--- DeminimizeWindow.returnAfterSpaceChange
--- Variable
--- Whether to send you back if restoring a window changed the Space out from under you. Defaults to `true`.
---
--- Notes:
---  * Applies only after a fully successful restore, where the window is here and being moved was therefore gratuitous. A partial success is left alone: you may well be looking at your window.
obj.returnAfterSpaceChange = true

--- DeminimizeWindow.refuseFullscreenSpace
--- Variable
--- Whether to refuse to restore anything while the current Space is fullscreen. Defaults to `true`.
---
--- Notes:
---  * The window server will not accept a window into a native fullscreen Space, so every row of the chooser would fail on click. Refusing up front is the honest version of that.
obj.refuseFullscreenSpace = true

--- DeminimizeWindow.includeHidden
--- Variable
--- Whether windows of hidden applications (`cmd-H`) are offered alongside minimized ones. Defaults to `false`.
---
--- Notes:
---  * Hiding an application and minimizing a window are different states: a hidden application's windows report `is-hidden` and *not* `is-minimized`, and never appear in `hs.window.minimizedWindows()`. Unminimizing does nothing for them; they need `hs.application:unhide()`.
---  * Off by default because they are not minimized and listing them would surprise. This is the answer to "why is the window I pressed cmd-H on not in the list".
obj.includeHidden = false

--- DeminimizeWindow.includeScratchpad
--- Variable
--- Whether yabai scratchpad windows are offered. Defaults to `false`.
---
--- Notes:
---  * yabai keeps a scratchpad window minimized as its hidden state, so every scratchpad on the machine would otherwise appear in this list. Restoring one behind yabai's back also desynchronises its own bookkeeping -- use `yabai -m window --toggle <label>` for those.
obj.includeScratchpad = false

--- DeminimizeWindow.useAccessibilitySweep
--- Variable
--- Whether `hs.window.minimizedWindows()` is consulted as well as yabai. Defaults to `true`.
---
--- Notes:
---  * The two sources answer different questions about the same window. yabai is authoritative about Spaces and window state; Accessibility is the only one that hands back a real `hs.window`, which is what the Spoon needs in order to unminimize without yabai at all.
---  * Turning this off is a diagnostic aid: it makes `DeminimizeWindow:diagnose()` show what yabai alone can do.
obj.useAccessibilitySweep = true

--- DeminimizeWindow.showInMenubar
--- Variable
--- Whether a menubar item listing minimized windows is created. Defaults to `false`.
---
--- Notes:
---  * Off by default: the hotkey is the whole point, and two sibling Spoons already occupy the menu bar. Changing this takes effect on the next `DeminimizeWindow:start()`.
obj.showInMenubar = false

--- DeminimizeWindow.menubarTitle
--- Variable
--- Text shown in the menubar when `DeminimizeWindow.showInMenubar` is on. Defaults to `'▣'`.
obj.menubarTitle = '▣'

--- DeminimizeWindow.chooserRows
--- Variable
--- Number of rows visible in the chooser at once. Defaults to `10`.
obj.chooserRows = 10

--- DeminimizeWindow.chooserWidth
--- Variable
--- Chooser width as a percentage of screen width. Defaults to `35`.
obj.chooserWidth = 35

--- DeminimizeWindow.alertDuration
--- Variable
--- Seconds an informational alert stays on screen. Defaults to `1.2`.
obj.alertDuration = 1.2

--- DeminimizeWindow.titleMax
--- Variable
--- Longest window title shown in alerts and diagnostics, in characters. Defaults to `60`.
---
--- Notes:
---  * Chooser rows are not truncated. The chooser has a width of its own and elides for itself, and a truncated row would also be a row the search field cannot match against.
obj.titleMax = 60

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Everything long-lived is a field on the Spoon object rather than a local inside start(),
-- because hs.chooser / hs.menubar / hs.timer are userdata with a __gc that tears down the
-- real resource. hs.loadSpoon() keeps this object alive as spoon.DeminimizeWindow for the
-- life of the config, so nothing here is collected out from under a live chooser or a poll
-- that is halfway through confirming a move.
obj.chooser = nil
obj.menubarItem = nil

-- id -> { win = <hs.window or nil>, record = <yabai table or nil>, appName, title }.
-- Rebuilt on every list, and deliberately not cached: a stale list of minimized windows is
-- worse than no list, because picking from it means acting on a window somebody has already
-- restored.
obj.byId = {}

-- The restore in flight, and the busy flag, in one field. Non-nil means a ladder is walking.
obj.pending = nil

obj.yabaiResolved = nil
obj.yabaiTasks = {}
obj.yabaiLastError = nil

-- The list the menubar menu is built from, kept current by the watcher below rather than
-- fetched when the menu opens, because hs.menubar wants its menu synchronously and every
-- source here is asynchronous. All three are nil or unused when showInMenubar is off, which
-- is the default -- the hotkey path allocates none of it.
obj.lastMenuItems = {}
obj.windowFilter = nil
obj.menuEvents = nil
obj.menuHandler = nil

-- Every hs.timer this Spoon has outstanding, so that stop() can cancel a poll rather than
-- leaving it to fire into a torn-down Spoon.
obj.timers = {}

obj.running = false
obj.warned = {}

-- Note two things deliberately absent, both of which the sibling SummonWindow Spoon has.
--
-- There is no hs.window.filter. Its default filter is built with visible=true, so it
-- discards exactly the windows this Spoon is about; and a filter configured to keep them
-- would cost a permanent Accessibility watcher across every running application, all day,
-- for a feature used a few times an hour. hs.window.minimizedWindows() answers the same
-- question on demand and costs nothing in between.
--
-- There is no query cache. Nothing here needs a synchronous answer -- the menubar is off by
-- default and builds its menu from a live query when it is on -- so there is no pressure to
-- keep a stale snapshot around, and every reason not to.

--------------------------------------------------------------------------------
-- Stateless helpers
--------------------------------------------------------------------------------

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

-- yabai rejects "1628.0". A window id that has been through hs.json.decode is a Lua number,
-- which tostring() renders with a decimal point on some builds, so ids are always formatted
-- through here on their way to an argument list.
local function fmtId(id) return string.format('%d', math.floor(id)) end

-- Hoisted rather than written inline at the table.sort() below, which would allocate a fresh
-- closure on every list build.
--
-- Alphabetical, and not most-recently-minimized, because neither source records when a
-- window was minimized -- yabai keeps no timestamp and neither does hs.window. A stable
-- order you can learn beats a clever one that cannot actually be computed.
local function byAppThenTitle(a, b)
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

-- Remember a timer so stop() can cancel it, and forget it once it has fired.
function obj:track(timer)
  if timer then self.timers[timer] = true end
  return timer
end

function obj:abortTimers()
  for timer in pairs(self.timers) do
    pcall(function() timer:stop() end)
  end
  self.timers = {}
  return self
end

-- Poll an asynchronous predicate until it answers true or the deadline passes.
--
-- `probe` is handed a callback and must call it exactly once with a boolean. Written this way
-- rather than with hs.timer.waitUntil because half the things this Spoon waits on are answers
-- from a subprocess, which no synchronous predicate can express.
function obj:pollUntil(probe, timeout, interval, done)
  local deadline = hs.timer.secondsSinceEpoch() + timeout

  local function tick()
    probe(function(ok)
      if ok then return done(true) end
      if hs.timer.secondsSinceEpoch() >= deadline then return done(false) end
      local timer
      timer = hs.timer.doAfter(interval, function()
        self.timers[timer] = nil
        tick()
      end)
      self:track(timer)
    end)
  end

  tick()
end

--------------------------------------------------------------------------------
-- yabai
--------------------------------------------------------------------------------

-- Everything in this section is absent-tolerant. yabai not installed, not running, or
-- refusing a command are all ordinary outcomes rather than errors: the caller records a
-- reason and the ladder carries on to a rung that does not need it.

-- Where Homebrew (both architectures), nix-darwin and hand installs put it, in descending
-- order of likelihood.
--
-- A static list rather than a shell probe, and that is not laziness. hs.task needs a full
-- path and will not search PATH; asking a shell to search it instead would be actively wrong,
-- because Hammerspoon inherits launchd's environment rather than a login shell's, so
-- `command -v yabai` from here misses on precisely the machines where a shell rc file put
-- yabai on the path. DeminimizeWindow.yabaiPath covers anything this list does not.
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
        'DeminimizeWindow.yabaiPath is set to %s, which is not an executable file; ignoring it',
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

-- Run one yabai command. Calls done(ok, stdout, err) exactly once, or -- if the Spoon is torn
-- down mid-flight -- not at all.
--
-- The settled flag is load-bearing rather than defensive. Terminating a hung task does not
-- cancel its completion callback, it *causes* one, arriving a moment later carrying the exit
-- code of the signal. Without the flag a timed-out command would answer twice, and for this
-- Spoon answering twice means walking the ladder twice and issuing a --focus nobody asked
-- for, which is the one thing here that can move the user off their Space.
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

  -- The argument table is handed to execve verbatim with no shell in between, so nothing here
  -- needs quoting or escaping.
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

  -- Guarded, because a process that exits instantly can settle the job before we reach here,
  -- and an orphan timer holding a closure for a second and a half is untidy.
  if not job.settled then
    job.timer = hs.timer.doAfter(
      self.yabaiTimeout,
      function() finish(false, nil, string.format('no answer within %ss', tostring(self.yabaiTimeout))) end
    )
  end
end

--- DeminimizeWindow:abortYabai() -> self
--- Method
--- Kills any yabai commands in flight and abandons whatever they were part of.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Called from `DeminimizeWindow:stop()`. Each job is marked settled *before* its process is signalled, which is the whole point: terminating a task causes a completion callback rather than cancelling one, so without the flag a config reload would answer into a half-torn-down Spoon and walk the ladder on into a `--focus`.
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
  if n > 0 then self.logger.f('abandoned %d yabai command(s)', n) end
  return self
end

-- Run a yabai query and hand back the decoded JSON. Calls done(data, err) exactly once, with
-- data nil on failure.
function obj:yabaiJSON(args, done)
  self:yabaiRun(args, function(ok, out, err)
    if not ok then
      self.yabaiLastError = tostring(err)
      -- A query is the first thing anything here runs, so a failure is overwhelmingly "the
      -- binary is installed but the service is not running". Worth exactly one line: someone
      -- who installed yabai meant it to work.
      self:warnOnce(
        'yabaiserver',
        'yabai is installed but not answering (%s); is the service running? ' .. 'Try `yabai --start-service`. Carrying on without it.',
        tostring(err)
      )
      return done(nil, err)
    end

    -- decode() raises on malformed input rather than returning nil.
    local okJson, decoded = pcall(hs.json.decode, out or '')
    if not okJson or type(decoded) ~= 'table' then
      self:warnOnce('yabaijson', 'could not parse yabai query output; the yabai CLI may have changed shape')
      return done(nil, 'unparseable output')
    end

    self.yabaiLastError = nil
    done(decoded, nil)
  end)
end

-- One live look at one window. done(record, err); the record is a single object rather than a
-- one-element array, which is what `query --windows --window <id>` returns.
--
-- A window that has gone away exits non-zero with "could not locate window with the specified
-- id", so this doubles as the check for a window that died between being listed and picked.
function obj:windowRecord(winId, done)
  self:yabaiJSON({ '-m', 'query', '--windows', '--window', fmtId(winId) }, function(data, err)
    if type(data) ~= 'table' or type(data.id) ~= 'number' then return done(nil, err or 'no such window') end
    done(data, nil)
  end)
end

--------------------------------------------------------------------------------
-- The current Space
--------------------------------------------------------------------------------

-- Both numbering systems for the Space we are on, because both are needed and neither can be
-- derived from the other without asking.
--
-- yabai's `--space` selector takes a Mission Control index, 1-based and renumbered whenever a
-- Space is created or dragged. hs.spaces speaks CGS ids, which are stable. Handing one where
-- the other is expected does not fail -- it silently acts on a different Space -- so the two
-- are kept apart by name everywhere below: `index` is always yabai's, `spaceId` always
-- hs.spaces'.
function obj:currentSpace(done)
  local spaceId = nil
  if hs.spaces and hs.spaces.focusedSpace then
    local ok, id = pcall(hs.spaces.focusedSpace)
    if ok then spaceId = id end
  end

  if not self:yabaiBinary() then
    -- No index without yabai, and nothing that consumes one either: placing is what needs it,
    -- and placing is exactly what is unavailable here.
    if not spaceId then return done(nil, 'neither yabai nor hs.spaces can say which Space this is') end
    return done({ index = nil, spaceId = spaceId, fullscreen = self:spaceIsFullscreen(spaceId) }, nil)
  end

  self:yabaiJSON({ '-m', 'query', '--spaces', '--space' }, function(space, err)
    if type(space) ~= 'table' or type(space.index) ~= 'number' then
      if not spaceId then return done(nil, err or 'could not determine the current Space') end
      return done({ index = nil, spaceId = spaceId, fullscreen = self:spaceIsFullscreen(spaceId) }, nil)
    end

    -- When the two disagree it is nearly always the mouse being on one display and the
    -- keyboard focus on another. yabai's reading wins, because its index is what --space
    -- consumes and a mismatch there would move the window somewhere neither of them meant.
    if spaceId and type(space.id) == 'number' and math.floor(space.id) ~= spaceId then
      self:warnOnce(
        'spacemismatch',
        'yabai says the current Space is id %d and hs.spaces says %s; trusting yabai, ' .. 'since its index is what --space consumes',
        math.floor(space.id),
        tostring(spaceId)
      )
      spaceId = math.floor(space.id)
    end

    done({
      index = math.floor(space.index),
      spaceId = spaceId or (type(space.id) == 'number' and math.floor(space.id)) or nil,
      fullscreen = space['is-native-fullscreen'] and true or false,
    }, nil)
  end)
end

-- Second opinion for the no-yabai path, where the Space object is not available.
function obj:spaceIsFullscreen(spaceId)
  if not (spaceId and hs.spaces and hs.spaces.spaceType) then return false end
  local ok, kind = pcall(hs.spaces.spaceType, spaceId)
  return ok and kind == 'fullscreen'
end

--------------------------------------------------------------------------------
-- Finding minimized windows
--------------------------------------------------------------------------------

-- The subroles a window the user could have minimized actually reports.
--
-- Emphatically not just AXStandardWindow, which is the tempting one-liner and is wrong. An
-- ordinary Finder window on macOS 26 reports AXDialog, so allowing only standard windows
-- silently drops every Finder window from the list -- and, worse, drops only yabai's half of
-- it, leaving a row that Accessibility could still see but that had lost the Space and
-- sticky information the ladder needs. The same is true of the palettes and inspectors that
-- report AXFloatingWindow.
--
-- An allowlist rather than a denylist even so, because it is what keeps out the surfaces
-- with no subrole at all, and Hammerspoon's own AXUnknown.Hammerspoon window.
local RESTORABLE_SUBROLES = {
  AXStandardWindow = true,
  AXDialog = true,
  AXSystemDialog = true,
  AXFloatingWindow = true,
}

-- Does this yabai record describe something the user would call a minimized window?
--
-- Only ever asked about records. A window that reached the list through Accessibility alone
-- came from hs.window.minimizedWindows(), which has already answered the question.
function obj:isRestorable(record)
  if type(record) ~= 'table' then return false end
  if record.pid == hs.processInfo.processID then return false end

  -- Anything without a titlebar -- menulets, overlays, the Dock's own surfaces -- would pad
  -- the list with rows that cannot be restored and cannot be identified either.
  if record.role ~= 'AXWindow' then return false end
  if not RESTORABLE_SUBROLES[record.subrole] then return false end

  -- Cannot co-exist with being minimized, but a window server that thinks otherwise would
  -- offer a row whose restore can only fail.
  if record['is-native-fullscreen'] then return false end

  if not self.includeScratchpad and type(record.scratchpad) == 'string' and record.scratchpad ~= '' then return false end

  if record['is-minimized'] then return true end
  -- Hidden is a different state and is off by default; see DeminimizeWindow.includeHidden.
  if self.includeHidden and record['is-hidden'] then return true end
  return false
end

--- DeminimizeWindow:collect(done) -> self
--- Method
--- Builds the list of restorable windows and hands it to a callback.
---
--- Parameters:
---  * done - A function called as `done(items, space, err)`. `items` is a sorted list of tables with `winId`, `appName`, `title` and `minimized` keys; `space` describes the Space they would be restored to; both are nil when `err` is set
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Unions two sources by window id, which is the same `CGWindowID` in both, so the join needs no guessing. yabai is authoritative about window state and Spaces; Accessibility contributes the `hs.window` that the yabai-free rungs of the ladder need.
---  * Either source alone yields a usable entry. A window only yabai can see is restorable by yabai only; a window only Accessibility can see is restorable but cannot be placed with confidence.
function obj:collect(done)
  self:currentSpace(function(space, err)
    if not space then return done(nil, nil, err or 'could not determine the current Space') end
    if space.fullscreen and self.refuseFullscreenSpace then
      return done(nil, space, 'the current Space is fullscreen; the window server will not accept a window into one')
    end

    local function merge(windows)
      local byId = {}

      if type(windows) == 'table' then
        for _, record in ipairs(windows) do
          if type(record) == 'table' and type(record.id) == 'number' and self:isRestorable(record) then
            byId[math.floor(record.id)] = { record = record }
          end
        end
      end

      if self.useAccessibilitySweep then
        local ok, wins = pcall(hs.window.minimizedWindows)
        if ok and type(wins) == 'table' then
          for _, win in ipairs(wins) do
            local okId, id = pcall(win.id, win)
            -- Every accessor on a window that may have died mid-sweep goes through a pcall,
            -- so a window closing underneath this loop skips a row rather than throwing out
            -- of the whole list build.
            local okApp, app = pcall(win.application, win)
            local mine = false
            if okApp and app then
              local okBundle, bundle = pcall(app.bundleID, app)
              mine = okBundle and bundle == hs.processInfo.bundleID
            end
            -- Hammerspoon's own windows are dropped here as well as in isRestorable, because
            -- this half of the union never passes through it.
            if okId and id and not mine then
              id = math.floor(id)
              local slot = byId[id]
              if slot then
                slot.win = win
              else
                byId[id] = { win = win }
              end
            end
          end
        else
          self:warnOnce('minimizedwindows', 'hs.window.minimizedWindows failed (%s)', tostring(wins))
        end
      end

      local items = {}
      for id, slot in pairs(byId) do
        local record, win = slot.record, slot.win
        local appName, title

        if record then
          appName, title = record.app or '?', record.title or ''
        else
          local app = win and win:application()
          appName = (app and app:name()) or '?'
          local okTitle, t = pcall(win.title, win)
          title = (okTitle and t) or ''
        end

        slot.appName, slot.title = appName, title
        items[#items + 1] = {
          winId = id,
          appName = appName,
          title = title,
          minimized = record and record['is-minimized'] or (record == nil),
        }
      end

      table.sort(items, byAppThenTitle)
      self.byId = byId
      done(items, space, nil)
    end

    if not self:yabaiBinary() then return merge(nil) end
    self:yabaiJSON({ '-m', 'query', '--windows' }, function(windows) merge(windows) end)
  end)
  return self
end

--------------------------------------------------------------------------------
-- Chooser
--------------------------------------------------------------------------------

function obj:choiceList(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      -- '(untitled)' rather than falling back to the application name, which would print the
      -- same string twice and make two untitled windows of one application indistinguishable.
      text = (item.title ~= '' and item.title) or '(untitled)',
      subText = item.appName,
      -- Only plain values survive the trip into the chooser and back; everything else known
      -- about the window lives in self.byId under this key.
      winId = item.winId,
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection.
    if not choice or not choice.winId then return end
    self:restoreById(choice.winId)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  -- So that typing an application name filters, even though the row itself shows the title.
  self.chooser:searchSubText(true)
  self.chooser:placeholderText('Restore a minimized window…')
  return self.chooser
end

--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

-- Nothing in this section trusts an exit code. yabai returns zero for a command it accepted,
-- which is not the same as one it performed, and an Accessibility write returns nothing at
-- all. A step is done when the world has been observed to have changed, and not before.

-- Has the window come out of the Dock?
function obj:awaitRevealed(ctx, timeout, done)
  if ctx.win then
    -- Free and synchronous, so it polls four times as often as the yabai path below.
    return self:pollUntil(function(answer)
      local ok, minimized = pcall(ctx.win.isMinimized, ctx.win)
      answer(ok and not minimized)
    end, timeout, self.pollInterval / 4, done)
  end

  if not self:yabaiBinary() then return done(false) end
  self:pollUntil(function(answer)
    self:windowRecord(ctx.winId, function(record) answer(record ~= nil and not record['is-minimized']) end)
  end, timeout, self.pollInterval, done)
end

-- Is the window on the Space we are on?
--
-- The obvious implementation is hs.spaces.windowSpaces(), and it is a trap. Hammerspoon
-- reports a *minimized* window as being in the current Space no matter where it was minimized
-- from, so asking it here would not merely be imprecise -- it would confirm a move that never
-- happened, and send the ladder on to reveal a window still sitting on somebody else's Space.
-- It becomes trustworthy again the moment the window is visible, which is why the no-yabai
-- branch at the bottom is allowed to use it and nothing above it is.
function obj:awaitPlaced(ctx, timeout, done)
  -- On every Space at once, so already here by definition. Confirmed on this machine: a
  -- sticky window reports a single `space` while appearing in the window list of every one.
  if ctx.record and ctx.record['is-sticky'] then return done(true) end

  if self:yabaiBinary() and ctx.index then
    return self:pollUntil(function(answer)
      self:windowRecord(ctx.winId, function(record)
        if not record then return answer(false) end
        -- Kept for the next step's benefit: sticky-ness and ax-reference can change under us.
        ctx.record = record
        answer(record['is-sticky'] and true or record.space == ctx.index)
      end)
    end, timeout, self.pollInterval, done)
  end

  -- No yabai. Only meaningful once the window is out of the Dock, and only reached from the
  -- reveal-first rung, where by construction it is.
  if not (ctx.win and ctx.revealed and ctx.spaceId and hs.spaces and hs.spaces.windowSpaces) then return done(false) end
  self:pollUntil(function(answer)
    local ok, spaces = pcall(hs.spaces.windowSpaces, ctx.win)
    answer(ok and type(spaces) == 'table' and hs.fnutils.contains(spaces, ctx.spaceId))
  end, timeout, self.pollInterval, done)
end

-- What actually happened. Three outcomes rather than two, because "revealed but somewhere
-- else" needs a different response from "still in the Dock": one is a partial success to be
-- reported honestly, the other is a rung that did nothing and should be followed by the next.
function obj:verifyRestored(ctx, done)
  self:awaitRevealed(ctx, self.revealTimeout, function(revealed)
    if not revealed then return done('still-minimized') end
    ctx.revealed = true
    self:awaitPlaced(ctx, self.placeTimeout, function(placed)
      ctx.placed = placed
      done(placed and 'ok' or 'unplaced')
    end)
  end)
end

--------------------------------------------------------------------------------
-- Restore steps
--------------------------------------------------------------------------------

-- Bookkeeping the three reveal steps share. Deliberately not a member of STEPS: a name in
-- that table is something the ladder may list as a step, and this one never calls next(),
-- so listing it would strand the rung.
--
-- Clearing placeFailed is the point. A move that failed while the window was minimized says
-- nothing about the same move now that it is visible, and the reveal-first rungs depend on
-- being allowed to genuinely retry rather than inheriting a stale verdict.
local function markRevealed(ctx)
  ctx.revealed = true
  ctx.placeFailed = false
end

-- The vocabulary the ladder is written in. Each step is fn(self, ctx, next) and calls
-- next(ok, err) exactly once. They are deliberately small and order-independent: the ladder
-- below is nothing but different orderings of these five.
local STEPS = {}

-- Put the window on the current Space, while it is still minimized if at all possible.
--
-- Memoised both ways. Repeating it across rungs is free, and a failure is remembered so that
-- the three place-first rungs fail fast rather than each paying for the same doomed move.
function STEPS.place(self, ctx, next)
  if ctx.placed then return next(true) end
  if ctx.placeFailed then return next(false, 'placing already failed for this window') end

  if not (self:yabaiBinary() and ctx.index) then
    -- Nothing on this machine can move a window between Spaces. If it is already out of the
    -- Dock we can at least find out where it landed -- and for the commonest case of all, a
    -- window minimized on this very Space, it landed exactly where it was wanted. Reporting
    -- that as a success rather than as a failure to place is the difference between the
    -- no-yabai path working and the no-yabai path apologising every time.
    if ctx.revealed then
      return self:awaitPlaced(ctx, self.placeTimeout, function(landed)
        ctx.placed = landed
        if landed then return next(true) end
        ctx.placeFailed = true
        next(false, 'no yabai; the window came back on the Space it was minimized from')
      end)
    end
    ctx.placeFailed = true
    return next(false, 'no yabai; nothing on this machine can move a window between Spaces')
  end

  -- A sticky window is on every Space at once, so it is already here -- and --space would
  -- take that away, pinning it to one. The list keeps sticky windows, since they can be
  -- minimized like any other; it is only the move that has to be skipped.
  if ctx.record and ctx.record['is-sticky'] then
    ctx.placed = true
    return next(true)
  end

  -- Already here. Skipped rather than issued, for three reasons: it is a wasted subprocess;
  -- it is the exact shape yabai issue #382 mishandles for minimized windows; and it means the
  -- commonest case of all -- minimize a window on this Space, want it back -- issues a single
  -- --deminimize and cannot move the user anywhere at all.
  if ctx.record and ctx.record.space == ctx.index then
    ctx.placed = true
    return next(true)
  end

  self:yabaiRun({ '-m', 'window', fmtId(ctx.winId), '--space', tostring(ctx.index) }, function(ok, _, err)
    if not ok then
      ctx.placeFailed = true
      return next(false, 'yabai refused the move (' .. tostring(err) .. ')')
    end

    -- Exit zero means accepted, never moved. Positive confirmation only: a reading that has
    -- not changed is a failure, not "probably fine". Failing here is safe, which is the whole
    -- reason the ladder places before it reveals -- the window is still in the Dock and
    -- nothing has appeared anywhere the user cannot see.
    self:awaitPlaced(ctx, self.placeTimeout, function(landed)
      ctx.placed, ctx.placeFailed = landed, not landed
      if landed then return next(true) end
      next(false, 'yabai accepted the move but the window is still not on this Space')
    end)
  end)
end

-- Reveal, quietly, via yabai.
function STEPS.deminimize(self, ctx, next)
  if not self:yabaiBinary() then return next(false, 'no yabai') end
  -- Note the inverted grammar: --deminimize takes its window selector as a required argument
  -- *after* the flag, unlike --space, which takes the selector before it.
  self:yabaiRun({ '-m', 'window', '--deminimize', fmtId(ctx.winId) }, function(ok, _, err)
    if not ok then return next(false, 'yabai refused to deminimize (' .. tostring(err) .. ')') end
    markRevealed(ctx)
    next(true)
  end)
end

-- Reveal, quietly, via Accessibility. An independent path to the same end: yabai may be
-- holding a stale AXUIElement for a window that Hammerspoon can address perfectly well.
function STEPS.unminimize(self, ctx, next)
  if not ctx.win then return next(false, 'no window object') end

  -- Hiding and minimizing are separate states and a window can be in both, in which case
  -- unminimizing alone leaves it just as invisible as it was.
  if self.includeHidden then
    local app = ctx.win:application()
    if app then pcall(app.unhide, app) end
  end

  local ok, err = pcall(ctx.win.unminimize, ctx.win)
  if not ok then return next(false, 'unminimize threw (' .. tostring(err) .. ')') end
  markRevealed(ctx)
  next(true)
end

-- Reveal, loudly. --focus restores *and* focuses, which makes it the strongest reveal
-- available and, unguarded, the most dangerous command in this Spoon: focusing a window that
-- is somewhere else is exactly what drags the user to another Space. It is only ever reached
-- through requirePlaced, at which point there is nowhere else for it to drag them to.
--
-- Worth having because --deminimize is known to no-op silently on windows the user minimized
-- by hand, which is this Spoon's entire use case.
function STEPS.focus(self, ctx, next)
  if not self:yabaiBinary() then return next(false, 'no yabai') end
  self:yabaiRun({ '-m', 'window', '--focus', fmtId(ctx.winId) }, function(ok, _, err)
    if not ok then return next(false, 'yabai refused to focus (' .. tostring(err) .. ')') end
    markRevealed(ctx)
    next(true)
  end)
end

-- The gate. Fails the rung unless placement has been positively confirmed.
function STEPS.requirePlaced(self, ctx, next)
  if ctx.placed then return next(true) end
  next(false, 'placement unconfirmed; going further could move the user off their Space')
end

--------------------------------------------------------------------------------
-- The restore ladder
--------------------------------------------------------------------------------

-- This table is the control flow. A sixth way to restore a window should mean a sixth entry
-- here and nothing else.
--
-- The order encodes one rule: place first, reveal second, and never reveal a window that
-- could not be placed. The first three rungs all begin by placing, and differ only in how
-- they then reveal -- yabai, Accessibility, then yabai's forceful version behind the gate.
-- Only once placing has genuinely failed do the last two invert the order, accepting the risk
-- of a Space change because the alternative at that point is not restoring the window at all.
--
-- `available` returning false is not a failure and never warns: a machine without yabai
-- simply has a two-rung ladder.
local ENGINES = {
  {
    name = 'place+deminimize',
    steps = { 'place', 'deminimize' },
    available = function(self, ctx)
      if not self:yabaiBinary() then return false, 'yabai unavailable' end
      -- yabai holds no AXUIElement for this window, so both of its reveal verbs will fail.
      -- Skipping saves a second of polling for an answer that cannot come.
      if ctx.record and ctx.record['has-ax-reference'] == false then return false, 'yabai has no accessibility reference' end
      return true
    end,
  },
  {
    name = 'place+unminimize',
    steps = { 'place', 'unminimize' },
    available = function(self, ctx)
      if not ctx.win then return false, 'no window object' end
      return true
    end,
  },
  {
    -- requirePlaced sits between the two deliberately, rather than in available(): placing is
    -- memoised, so on this rung it either confirms what an earlier rung already did or makes
    -- the first real attempt, and only then is the gate a meaningful question.
    name = 'place+focus',
    steps = { 'place', 'requirePlaced', 'focus' },
    available = function(self)
      if not self:yabaiBinary() then return false, 'yabai unavailable' end
      return true
    end,
  },
  {
    name = 'deminimize+place',
    steps = { 'deminimize', 'place', 'requirePlaced' },
    available = function(self, ctx)
      if not self:yabaiBinary() then return false, 'yabai unavailable' end
      if not self.allowRevealFirst then return false, 'allowRevealFirst is off' end
      if not ctx.placeFailed then return false, 'placing has not failed, so revealing first is not warranted' end
      return true
    end,
  },
  {
    -- Last, and the whole ladder on a machine without yabai. Placing degrades to a best-effort
    -- report rather than an action, so this rung can succeed at revealing while honestly
    -- failing to place -- which is reported as a partial success, not as a win.
    name = 'unminimize+place',
    steps = { 'unminimize', 'place' },
    available = function(self, ctx)
      if not ctx.win then return false, 'no window object' end
      if self:yabaiBinary() and not self.allowRevealFirst then return false, 'allowRevealFirst is off' end
      return true
    end,
  },
}

-- Walk one rung's steps in order, stopping at the first failure. Written as a recursion over
-- the list rather than as nested callbacks, so the nesting stays one level deep however many
-- steps a rung grows.
function obj:runSteps(ctx, names, done)
  local function step(i)
    -- This rung was abandoned while it was in flight -- stop(), or the ladderDeadline
    -- watchdog firing. Every callback in runLadder tests this, but the guard has to be here
    -- too: without it the watchdog only stops the *next* rung from starting, while the one
    -- already running walks its remaining steps and issues yabai --space / --deminimize /
    -- --focus seconds after the user was told the restore had failed.
    if self.pending ~= ctx then return end

    local name = names[i]
    if not name then return done(true, nil) end
    local fn = STEPS[name]
    if not fn then return done(false, 'unknown step ' .. tostring(name)) end

    -- Exactly one answer per step, whichever way it ends. These run inside timer and task
    -- callbacks, where a throw is swallowed rather than raised, so a step that died mid-flight
    -- would otherwise strand the ladder with nothing ever reporting and no alert ever shown.
    local answered = false
    local function reply(ok, err)
      if answered then return end
      answered = true
      -- Consume the answer either way, but do not act on one that arrives after this rung
      -- was abandoned: reporting it would overwrite the outcome the watchdog already gave.
      if self.pending ~= ctx then return end
      if not ok then return done(false, err) end
      step(i + 1)
    end

    local okRun, runErr = pcall(fn, self, ctx, reply)
    if not okRun then reply(false, tostring(runErr)) end
  end

  step(1)
end

function obj:runLadder(ctx)
  local reasons = {}

  local function attempt(i)
    -- The Spoon was stopped, or the deadline fired, while this rung was in flight.
    if self.pending ~= ctx then return end

    local engine = ENGINES[i]
    if not engine then return self:finishRestore(ctx, nil, table.concat(reasons, '; ')) end

    local okAvail, available, whyNot = pcall(engine.available, self, ctx)
    if not okAvail or not available then
      reasons[#reasons + 1] = engine.name .. ': ' .. tostring(whyNot or available or 'unavailable')
      return attempt(i + 1)
    end

    self:runSteps(ctx, engine.steps, function(ok, err)
      if self.pending ~= ctx then return end

      if not ok then
        reasons[#reasons + 1] = string.format('%s: %s', engine.name, tostring(err or 'failed'))
        return attempt(i + 1)
      end

      self:verifyRestored(ctx, function(outcome)
        if self.pending ~= ctx then return end
        if outcome == 'ok' then return self:finishRestore(ctx, engine.name, nil) end

        if outcome == 'unplaced' then
          -- Revealed, but elsewhere. One corrective move, then re-check; the window is
          -- visible now, so this attempt is on genuinely different terms from any that failed
          -- while it was still in the Dock.
          ctx.placeFailed = false
          return self:runSteps(ctx, { 'place' }, function()
            if self.pending ~= ctx then return end
            self:awaitPlaced(ctx, self.placeTimeout, function(landed)
              if self.pending ~= ctx then return end
              ctx.placed = landed
              if landed then return self:finishRestore(ctx, engine.name, nil) end
              reasons[#reasons + 1] = engine.name .. ': revealed, but on another Space'
              attempt(i + 1)
            end)
          end)
        end

        reasons[#reasons + 1] = engine.name .. ': issued, but the window stayed minimized'
        attempt(i + 1)
      end)
    end)
  end

  attempt(1)
  return self
end

-- Release the busy flag and the deadline that goes with it. Returns false when this ctx was
-- not the one holding them, which is how every callback in the ladder tells that the Spoon
-- was stopped, or the deadline fired, while it was in flight.
--
-- The flag is released here and nowhere else. Leaking it would leave the hotkey deaf until a
-- config reload, which is the worst available failure in a Spoon whose whole interface is
-- one key.
function obj:clearPending(ctx)
  if self.pending ~= ctx then return false end
  self.pending = nil
  if ctx.watchdog then
    pcall(function() ctx.watchdog:stop() end)
    self.timers[ctx.watchdog] = nil
    ctx.watchdog = nil
  end
  return true
end

-- The single exit from a restore that actually walked the ladder. Focus -- which is
-- unreachable from every failure path, because focusing a window that never moved is the yank
-- this Spoon exists to prevent -- is applied only to a full success.
function obj:finishRestore(ctx, engine, why)
  if not self:clearPending(ctx) then return self end

  local label = string.format('%s — %s', ctx.appName, truncate(ctx.title, self.titleMax))

  if engine and ctx.placed then
    if self.focusAfterRestore then
      -- yabai first, and Accessibility only as the fallback -- the reverse of the preference
      -- everywhere else in this Spoon, and measured rather than assumed. On macOS 26,
      -- hs.window:focus() on a window that was minimized a moment ago returns cleanly while
      -- the frontmost application does not change, and hs.application:activate() returns
      -- false as often as not; `yabai -m window --focus` moves the keyboard every time.
      -- Restoring a window nobody can type into is a bug users would report as "it didn't
      -- work", so the reliable path goes first.
      --
      -- Safe here for the same reason rung 3 is: this is reached only after placement was
      -- confirmed, so there is no other Space for a focus to drag anyone to.
      if self:yabaiBinary() then
        self:yabaiRun({ '-m', 'window', '--focus', fmtId(ctx.winId) }, function(ok, _, err)
          if not ok then self.logger.f('could not focus window %s: %s', tostring(ctx.winId), tostring(err)) end
        end)
      elseif ctx.win then
        -- Raised first, so it is the frontmost window *within* its application before that
        -- application is brought forward; otherwise activating would surface whichever of its
        -- windows happened to be in front.
        pcall(ctx.win.raise, ctx.win)
        pcall(ctx.win.focus, ctx.win)
        local okApp, app = pcall(ctx.win.application, ctx.win)
        if okApp and app then pcall(app.activate, app) end
      end
    end

    -- Succeeding and being moved anyway means something along the way switched Spaces
    -- gratuitously: the window is here, so there was never any need to go elsewhere.
    if self.returnAfterSpaceChange and ctx.spaceId and hs.spaces and hs.spaces.gotoSpace then
      local ok, now = pcall(hs.spaces.focusedSpace)
      if ok and now and now ~= ctx.spaceId then
        self.logger.wf('restoring moved the current Space to %s; going back to %s', tostring(now), tostring(ctx.spaceId))
        pcall(hs.spaces.gotoSpace, ctx.spaceId)
      end
    end

    self.logger.f('restored %s via %s', label, engine)
    return self
  end

  if ctx.revealed then
    -- Partial. The window is out of the Dock but somewhere else, so it is emphatically not
    -- focused, and the user is not sent back either -- they may be looking at it right now.
    self.logger.wf('restored %s, but could not place it on this Space: %s', label, tostring(why or 'unknown'))
    hs.alert.show(string.format('Restored %s, but it stayed on another Space', ctx.appName), self.alertDuration + 1)
    return self
  end

  self.logger.wf('could not restore %s: %s', label, tostring(why or 'no method available'))
  hs.alert.show(string.format('Could not restore %s', ctx.appName), self.alertDuration + 1)
  return self
end

--------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------

--- DeminimizeWindow:restoreById(winId) -> self
--- Method
--- Restores one minimized window by its window id, onto the current Space.
---
--- Parameters:
---  * winId - The window id, as returned in the `winId` field of `DeminimizeWindow:collect()`
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * The id must have come from a `DeminimizeWindow:collect()` pass, since everything else known about the window is looked up in the map that call builds.
---  * The target Space and the window's state are both re-read here rather than taken from when the list was built, because a chooser can sit open across a Space change for as long as the user likes.
function obj:restoreById(winId)
  local slot = self.byId[winId]
  if not slot then
    self.logger.wf('window %s is not in the current list', tostring(winId))
    hs.alert.show('DeminimizeWindow: that window is no longer available', self.alertDuration)
    return self
  end

  if self.pending then
    self.logger.f('already restoring window %s; ignoring', tostring(self.pending.winId))
    return self
  end

  -- Claimed synchronously, before either of the two queries below. Both are asynchronous, so
  -- a second press arriving between them would otherwise find `pending` still nil and start a
  -- parallel ladder on the same window -- two moves and two --focus calls racing each other.
  -- ctx.index and ctx.spaceId are filled in once the Space answers.
  local ctx = {
    winId = winId,
    win = slot.win,
    record = slot.record,
    appName = slot.appName or '?',
    title = slot.title or '',
    placed = false,
    placeFailed = false,
    revealed = false,
  }
  self.pending = ctx
  ctx.watchdog = self:track(hs.timer.doAfter(self.ladderDeadline, function()
    if self.pending ~= ctx then return end
    self.logger.wf('restore of window %s did not finish within %ss; abandoning it', tostring(winId), tostring(self.ladderDeadline))
    self:finishRestore(ctx, nil, 'timed out')
  end))

  -- Pre-flight refusals, which carry a specific reason worth showing. They release the flag
  -- directly rather than through finishRestore, whose message is the generic one for a ladder
  -- that ran and got nowhere.
  local function giveUp(why)
    if not self:clearPending(ctx) then return end
    self.logger.wf('not restoring window %s: %s', tostring(winId), tostring(why))
    hs.alert.show('DeminimizeWindow: ' .. tostring(why), self.alertDuration + 1)
  end

  self:currentSpace(function(space, err)
    if self.pending ~= ctx then return end
    if not space then return giveUp(err or 'could not determine the current Space') end
    if space.fullscreen and self.refuseFullscreenSpace then return giveUp('cannot restore into a fullscreen Space') end

    ctx.index = space.index
    ctx.spaceId = space.spaceId

    local function begin(record)
      if self.pending ~= ctx then return end
      ctx.record = record or ctx.record

      -- Somebody else restored it while the chooser was open. Not an error: place it here and
      -- focus it, which is what the user was asking for anyway.
      if ctx.record and ctx.record['is-minimized'] == false then
        self.logger.f('window %s is already out of the Dock; placing it only', tostring(winId))
        ctx.revealed = true
      end

      self:runLadder(ctx)
    end

    -- Re-read the record, which is also how a window that died between being listed and
    -- picked is detected: yabai exits non-zero for an id it cannot locate.
    if not self:yabaiBinary() then return begin(nil) end
    self:windowRecord(winId, function(record, recErr)
      if self.pending ~= ctx then return end
      if not record then
        -- An hs.window we still hold is proof the window exists, whatever yabai thinks, so
        -- only a total absence is fatal.
        if not slot.win then
          self.logger.wf('window %s is gone (%s)', tostring(winId), tostring(recErr))
          return giveUp('that window is no longer available')
        end
        return begin(nil)
      end
      begin(record)
    end)
  end)

  return self
end

--- DeminimizeWindow:restore() -> self
--- Method
--- Restores a minimized window, asking which one only when there is a choice.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * With no minimized windows this shows a brief alert; with exactly one it restores it outright; with more it opens the chooser. See `DeminimizeWindow.skipChooserForSingle`.
---  * This is the method `DeminimizeWindow:bindHotkeys()` binds. Pressing the hotkey while the chooser is open closes it again.
function obj:restore()
  if self.chooser and self.chooser:isVisible() then return self:hide() end

  if self.pending then
    self.logger.f('already restoring window %s; ignoring', tostring(self.pending.winId))
    return self
  end

  self:collect(function(items, _, err)
    if err then
      self.logger.wf('could not build the window list: %s', tostring(err))
      hs.alert.show('DeminimizeWindow: ' .. tostring(err), self.alertDuration + 1)
      return
    end

    -- The only place the count is branched on.
    if #items == 0 then return hs.alert.show('No minimized windows', self.alertDuration) end
    if #items == 1 and self.skipChooserForSingle then return self:restoreById(items[1].winId) end

    local chooser = self:ensureChooser()
    -- Handed over as a static table rather than a callback, so the list is rebuilt on every
    -- open. A callback would be cached until refreshChoicesCallback().
    chooser:choices(self:choiceList(items))
    chooser:query('')
    chooser:show()
  end)

  return self
end

--- DeminimizeWindow:show() -> self
--- Method
--- Opens the chooser, whatever the number of minimized windows.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Unlike `DeminimizeWindow:restore()` this never restores anything by itself, so it is the method to bind if you would always rather see the list first.
function obj:show()
  self:collect(function(items, _, err)
    if err then
      hs.alert.show('DeminimizeWindow: ' .. tostring(err), self.alertDuration + 1)
      return
    end

    local chooser = self:ensureChooser()
    if #items == 0 then
      -- valid = false keeps the row from dismissing the chooser when it is selected.
      chooser:choices({
        { text = 'No minimized windows', subText = 'Nothing is in the Dock', valid = false },
      })
    else
      chooser:choices(self:choiceList(items))
    end
    chooser:query('')
    chooser:show()
  end)
  return self
end

--- DeminimizeWindow:hide() -> self
--- Method
--- Closes the chooser if it is open.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
function obj:hide()
  if self.chooser then self.chooser:hide() end
  return self
end

--------------------------------------------------------------------------------
-- Menubar
--------------------------------------------------------------------------------

-- Built from a live query, like everything else here, which is why it is a callback-driven
-- menu rather than a table: hs.menubar wants its menu synchronously, so the list is refreshed
-- when the menu is asked for and the previous one is shown if the query has not landed yet.
function obj:buildMenu()
  local items = self.lastMenuItems or {}
  local menu = {}

  if #items == 0 then
    menu[#menu + 1] = { title = 'No minimized windows', disabled = true }
  else
    for _, item in ipairs(items) do
      local id = item.winId
      menu[#menu + 1] = {
        title = string.format('%s — %s', item.appName, truncate(item.title, self.titleMax)),
        fn = function() self:restoreById(id) end,
      }
    end
  end

  menu[#menu + 1] = { title = '-' }
  menu[#menu + 1] = { title = 'Search…', fn = function() self:show() end }
  return menu
end

-- Keep the cached list current, since the menu itself cannot wait for it.
--
-- hs.menubar calls its menu function synchronously and every source here is asynchronous, so
-- there is no way to fetch the list at the moment the menu opens: hs.menubar.popupMenu()
-- returns immediately rather than blocking until the menu closes, so the set-menu-then-pop
-- trick would tear the menu down as fast as it appeared. The list is therefore kept fresh in
-- the background instead, on the two events that can change it.
function obj:refreshMenu()
  if not self.menubarItem then return self end
  self:collect(function(items) self.lastMenuItems = items or {} end)
  return self
end

--------------------------------------------------------------------------------
-- Spoon lifecycle
--------------------------------------------------------------------------------

--- DeminimizeWindow:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Deliberately starts nothing. The chooser and the menubar item both belong to `DeminimizeWindow:start()`.
---  * It is also deliberately empty rather than re-initialising state. The declarations above already run on a freshly loaded object, and `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load -- so clearing state here would strand a chooser that is already live.
function obj:init() return self end

--- DeminimizeWindow:start() -> self
--- Method
--- Makes the Spoon ready to restore windows, and adds the menubar item if it is enabled.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Calling this on an already-started Spoon restarts it cleanly.
---  * Nothing polls and no timer runs while idle. The window list is built on demand, when the hotkey is pressed or the menu is pulled down.
---  * Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  self.byId = {}
  self.lastMenuItems = {}

  if self.showInMenubar then
    -- The autosave name stays lower-case and distinct from the sibling Spoons': it is what
    -- macOS keys the item's saved position in the menu bar on, so it has to be unique and
    -- must never be renamed afterwards.
    self.menubarItem = hs.menubar.new(true, 'deminimizewindow')
    if self.menubarItem then
      self.menubarItem:setTitle(self.menubarTitle)
      self.menubarItem:setTooltip('Restore a minimized window onto this Space')
      -- Wrapped: an error thrown inside the menu callback would otherwise leave a dead
      -- menubar icon with no way to recover short of reloading the config.
      self.menubarItem:setMenu(function()
        local ok, menu = pcall(self.buildMenu, self)
        if ok then return menu end
        self.logger.wf('menu build failed: %s', tostring(menu))
        return {
          { title = 'Menu failed to build — see console', disabled = true },
          { title = '-' },
          { title = 'Search…', fn = function() self:show() end },
        }
      end)

      -- The watcher exists only while the menubar does, which is the whole reason the menubar
      -- is off by default: this is a permanent Accessibility subscription across every running
      -- application, and the hotkey needs nothing of the sort. setDefaultFilter{} is
      -- load-bearing -- a stock filter is built with visible=true and would never report a
      -- window minimizing, which is precisely the event being subscribed to.
      self.windowFilter = hs.window.filter.new()
      self.windowFilter:setDefaultFilter({})
      self.windowFilter:setCurrentSpace(nil)
      self.windowFilter:rejectApp('Hammerspoon')
      self.menuEvents = {
        hs.window.filter.windowMinimized,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowDestroyed,
      }
      self.menuHandler = function() self:refreshMenu() end
      self.windowFilter:subscribe(self.menuEvents, self.menuHandler)

      self:refreshMenu()
    else
      self.logger.w('could not create the menubar item')
    end
  end

  self.running = true

  if not hs.accessibilityState() then
    hs.alert.show('DeminimizeWindow needs Accessibility permission')
    self.logger.w('accessibility permission not granted; nothing will work until it is')
  end
  if not self:yabaiBinary() then
    self.logger.w(
      'yabai is not available, so restored windows cannot be placed on the current Space; '
        .. 'they will reappear wherever they were minimized'
    )
  end

  self.logger.i('started')
  return self
end

--- DeminimizeWindow:stop() -> self
--- Method
--- Abandons any restore in flight, destroys the chooser and removes the menubar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Any hotkeys bound with `DeminimizeWindow:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped. A yabai command in flight is holding a subprocess
  -- whose completion would otherwise answer into a half-torn-down Spoon and walk the ladder
  -- on into a --focus, which is the one thing here that can move the user off their Space.
  self:abortYabai()
  self:abortTimers()
  self.pending = nil

  -- Unsubscribed by the exact (events, function) pair it was subscribed with, so that the
  -- global window watcher underneath -- which is refcounted and shared with the sibling
  -- Spoons' filters -- is released rather than left running for nobody.
  if self.windowFilter then
    if self.menuEvents and self.menuHandler then
      pcall(self.windowFilter.unsubscribe, self.windowFilter, self.menuEvents, self.menuHandler)
    end
    self.windowFilter = nil
    self.menuEvents = nil
    self.menuHandler = nil
  end

  if self.menubarItem then
    self.menubarItem:delete()
    self.menubarItem = nil
  end

  if self.chooser then
    pcall(self.chooser.hide, self.chooser)
    pcall(self.chooser.delete, self.chooser)
    self.chooser = nil
  end

  self.byId = {}
  self.lastMenuItems = {}
  self.warned = {}
  self.yabaiLastError = nil
  -- Re-probed on the next start(), so installing yabai and reloading the config is all it
  -- takes for this Spoon to notice it.
  self.yabaiResolved = nil
  self.running = false
  self.logger.i('stopped')
  return self
end

--- DeminimizeWindow:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for DeminimizeWindow.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * restore - Restore a minimized window, showing the chooser only when there is a choice
---    * show - Always show the chooser, whatever the number of minimized windows
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * For example: `spoon.DeminimizeWindow:bindHotkeys({ restore = { { "cmd", "alt", "ctrl" }, "M" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    restore = hs.fnutils.partial(self.restore, self),
    show = hs.fnutils.partial(self.show, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display.
  self.mapping = mapping
  return self
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

--- DeminimizeWindow:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `menubar`, `chooserVisible`, `restoring`, `yabai`, `yabaiBusy`, `yabaiLastError`, `listed` and `timers` keys
---
--- Notes:
---  * `yabai` is the resolved binary path, or `false` when yabai is switched off or not installed. It says nothing about whether the yabai *service* is running -- only `DeminimizeWindow:diagnose()` answers that.
---  * `listed` counts the windows in the most recent list, which may be stale; the list is never reused across a press.
function obj:status()
  local busy = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then busy = busy + 1 end
  end

  local listed = 0
  for _ in pairs(self.byId) do
    listed = listed + 1
  end

  local timers = 0
  for _ in pairs(self.timers) do
    timers = timers + 1
  end

  return {
    running = self.running,
    menubar = self.menubarItem ~= nil,
    chooserVisible = self.chooser ~= nil and self.chooser:isVisible() or false,
    restoring = self.pending and self.pending.winId or false,
    yabai = self:yabaiBinary() or false,
    yabaiBusy = busy,
    yabaiLastError = self.yabaiLastError,
    listed = listed,
    timers = timers,
  }
end

--- DeminimizeWindow:diagnose([done]) -> self
--- Method
--- Prints what each source can see, and why a window is or is not being offered.
---
--- Parameters:
---  * done - An optional function called with the report text once it has been gathered
---
--- Returns:
---  * The DeminimizeWindow object
---
--- Notes:
---  * Asynchronous, because it asks yabai. The report is printed to the Hammerspoon Console when it arrives, so calling this bare from the Console is the normal way to use it.
---  * The decisive line is the per-window one. A row tagged only `yabai` has no `hs.window` behind it, so the Accessibility rungs of the ladder do not apply to it; a row tagged only `ax` cannot be placed on a Space with any confidence.
function obj:diagnose(done)
  local out = {}
  local function say(fmt, ...) out[#out + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt end

  local function finish()
    local text = table.concat(out, '\n')
    print(text)
    if done then pcall(done, text) end
  end

  say('DeminimizeWindow diagnosis')
  say('')
  say('  running               %s', tostring(self.running))
  say('  accessibility         %s', tostring(hs.accessibilityState()))
  say('  yabai                 %s', tostring(self:yabaiBinary() or (not self.useYabai and '(turned off)' or '(not installed)')))
  say('  hs.spaces             %s', tostring(hs.spaces ~= nil and hs.spaces.focusedSpace ~= nil))
  say('  minimizedWindows      %s', tostring(hs.window.minimizedWindows ~= nil))

  -- Counted before the union, so a disagreement between the two sources is visible rather
  -- than merged away.
  local axSet, axN = {}, 0
  local okAx, wins = pcall(hs.window.minimizedWindows)
  if okAx and type(wins) == 'table' then
    for _, win in ipairs(wins) do
      local okId, id = pcall(win.id, win)
      if okId and id then
        axSet[math.floor(id)] = true
        axN = axN + 1
      end
    end
  end

  self:currentSpace(function(space, err)
    say('')
    if space then
      say(
        'Current Space:          yabai index=%s   hs.spaces id=%s   fullscreen=%s',
        tostring(space.index),
        tostring(space.spaceId),
        tostring(space.fullscreen)
      )
    else
      say('Current Space:          UNKNOWN (%s)', tostring(err))
    end

    self:collect(function(items, _, collectErr)
      say('')
      say('Sources:')
      say('  hs.window.minimizedWindows   %4d window(s)', axN)

      if not self:yabaiBinary() then
        say('  yabai                        (unavailable) — restored windows cannot be placed')
      elseif self.yabaiLastError then
        -- The distinction that matters: a binary that is present but whose service is down
        -- looks exactly like one that has simply not been asked yet, and the fixes differ.
        say('  yabai                        NOT ANSWERING (%s) — try `yabai --start-service`', self.yabaiLastError)
      else
        local n = 0
        for _ in pairs(self.byId) do
          n = n + 1
        end
        say('  yabai                        answering; %d window(s) in the merged list', n)
      end

      say('')
      if collectErr then
        say('Restorable: none (%s)', tostring(collectErr))
        return finish()
      end

      items = items or {}
      say('Restorable: %d window(s)', #items)
      for _, item in ipairs(items) do
        local slot = self.byId[item.winId] or {}
        local tags = {}
        if axSet[item.winId] then tags[#tags + 1] = 'ax' end
        if slot.record then tags[#tags + 1] = 'yabai' end
        say(
          '  [%-9s] %-22s %-52s %s',
          table.concat(tags, '+'),
          item.appName,
          truncate(item.title, 52),
          slot.record
              and string.format(
                'space=%s sticky=%s ax-ref=%s',
                tostring(slot.record.space),
                tostring(slot.record['is-sticky']),
                tostring(slot.record['has-ax-reference'])
              )
            or 'no yabai record'
        )
      end

      if #items == 0 then
        say('')
        say('Nothing to restore. If a window really is in the Dock, check the sources above:')
        say('a zero on both lines means macOS is not reporting it as minimized at all, and a')
        say('window hidden with cmd-H is not minimized -- see DeminimizeWindow.includeHidden.')
      end

      finish()
    end)
  end)

  return self
end

return obj
