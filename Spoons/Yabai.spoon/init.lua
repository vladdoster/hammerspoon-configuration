-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === Yabai ===
---
--- A modal keyboard grammar for Mission Control: create, delete, reorder and focus Spaces, and move
--- windows between Spaces and displays.
---
--- The grammar is vim's, verb before noun. A leader hotkey enters an `hs.hotkey.modal`, one keystroke
--- names the verb -- `f` focus, `d` delete, `m` move a window -- and one further keystroke names each
--- operand that verb takes, so `f3` focuses Desktop 3 and `ma3` moves window `a` onto Space 3. A
--- which-key style panel lists what the next keystroke can be, after a short delay, so a sequence typed
--- at speed draws nothing at all.
---
--- Underneath it is a step stack rather than a list. The first level is the verb -- Create Space, Move
--- Window to Space -- and picking one pushes however many operands that verb needs, one level each.
--- Escape pops a level and leaves from the top, so a wrong turn costs a keypress rather than a restart.
---
--- `/` at any level hands the same half-finished operation to an `hs.chooser`, which is the same step
--- stack rendered as a list. It is where a window with a long title is easier to find by typing than by
--- hunting for its letter, and it is what the menubar item opens.
---
--- Prefers `yabai` for reading, which reports every Space, window and display over a socket without
--- disturbing anything. Writing is a separate question. yabai can only mutate a Space through its
--- scripting addition, which is an extra install and absent on plenty of machines otherwise running
--- yabai fine, so every verb that has an `hs.spaces` equivalent falls back to it when the yabai command
--- fails -- not merely when yabai is missing. The two are mixed deliberately: the fast reader is worth
--- having even where it cannot be the writer.
---
--- Two verbs have no fallback at all, because nothing outside yabai can reorder a Space or send one to
--- another display. Where yabai cannot do them they stay listed, greyed and keyless, with the reason -- the
--- same treatment a Space macOS refuses to delete gets, so the panel always matches what is really on offer.
---
--- Without yabai entirely the Spoon still creates, deletes and focuses Spaces through `hs.spaces`, and
--- still lists windows through `hs.window.filter`. It is named for its preferred backend, not its only one.

local obj = {}
obj.__index = obj

obj.name = "Yabai"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- Yabai.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("Yabai", "info")

-- Configuration

--- Yabai.chooserRows
--- Variable
--- How many rows the chooser shows at once. Defaults to `10`.
obj.chooserRows = 10

--- Yabai.chooserWidth
--- Variable
--- Chooser width as a percentage of the screen. Defaults to `40`.
obj.chooserWidth = 40

--- Yabai.showInMenubar
--- Variable
--- Whether to place an item in the menubar. Defaults to `true`.
---
--- The item is a button rather than a menu: clicking it opens the same chooser the hotkey does, so there is one way to choose a verb and not two.
obj.showInMenubar = true

--- Yabai.menubarTitle
--- Variable
--- Glyph shown in the menubar, with the current Space count appended. Defaults to a squared plus.
obj.menubarTitle = "⊞"

--- Yabai.confirmWhenWindows
--- Variable
--- Whether to confirm before deleting a Space that still holds managed windows. Defaults to `true`.
---
--- An empty Space is deleted without a prompt. Deleting one that is not empty does not close its windows, it relocates them to another Space, which is recoverable but disorienting enough to be worth a keypress.
---
--- Scoped to deletion alone. Moving, reordering and focusing are all reversible by doing them again, so none of them prompt.
obj.confirmWhenWindows = true

--- Yabai.countFloating
--- Variable
--- Whether floating windows count towards a Space's total. Defaults to `false`.
---
--- False matches what yabai calls a managed window. It also excludes sticky windows for free, since a sticky window is always floating, and a sticky window is on every Space rather than the one being counted.
---
--- Ignored on the `hs.spaces` fallback, which cannot tell a floating window from a tiled one and so always reports every window on the Space.
obj.countFloating = false

--- Yabai.showMinimized
--- Variable
--- Whether minimized windows appear in the window lists. Defaults to `false`.
---
--- A minimized window has no Space in any useful sense: it sits in the Dock, and moving it somewhere only decides where it will reappear. `DeminimizeWindow` is the Spoon for that, so they are left out here by default.
obj.showMinimized = false

--- Yabai.useYabai
--- Variable
--- Whether to use yabai when it is installed. Defaults to `true`.
---
--- Set to `false` to exercise the `hs.spaces` fallbacks on a machine that has yabai.
obj.useYabai = true

--- Yabai.yabaiPath
--- Variable
--- Absolute path to the yabai binary, or `nil` to search the usual install prefixes. Defaults to `nil`.
obj.yabaiPath = nil

--- Yabai.yabaiTimeout
--- Variable
--- Seconds to wait for a yabai command before giving up on it. Defaults to `2`.
obj.yabaiTimeout = 2

--- Yabai.verifyTimeout
--- Variable
--- Seconds to keep re-reading the world while waiting for a verb to take effect. Defaults to `1.5`.
---
--- Nothing here trusts an exit code. A window manager acknowledges a command long before macOS finishes animating it, so every verb polls until it observes the change or this runs out.
obj.verifyTimeout = 1.5

--- Yabai.verifyInterval
--- Variable
--- Seconds between those re-reads. Defaults to `0.15`.
obj.verifyInterval = 0.15

--- Yabai.hintKeys
--- Variable
--- Letters handed to rows that have no natural key of their own, in the order they are handed out. Defaults to the home row first.
---
--- Spaces, displays and positions key off the number Mission Control already gives them, so this is mostly what windows are labelled with.
obj.hintKeys = "asdfghjklqwertyuiopzxcvbnm"

--- Yabai.panelDelay
--- Variable
--- Seconds the modal waits before drawing the panel. Defaults to `0.2`.
---
--- Mirrors which-key's own delay, and for the same reason: a sequence typed from memory finishes inside it and never puts anything on screen, while a pause is read as not knowing what comes next and is answered with the list.
obj.panelDelay = 0.2

--- Yabai.modalTimeout
--- Variable
--- Seconds of inactivity after which the modal leaves by itself. Defaults to `5`.
---
--- The modal swallows every letter and digit while it is up, so a forgotten one is a keyboard that appears to have stopped working. This is the backstop for walking away mid-sequence.
obj.modalTimeout = 5

--- Yabai.panelRows
--- Variable
--- Rows per column on the panel, before a second column is started. Defaults to `12`.
---
--- Four columns is the ceiling. Anything past that is dropped from the panel, counted in the footer, and still reachable through `/`.
obj.panelRows = 12

--- Yabai.panelStyle
--- Variable
--- Appearance of the panel, shaped like `hs.alert.defaultStyle` so it sits alongside the alerts the verbs report through.
---
--- Read at draw time, so a change from the Console shows up on the next level.
obj.panelStyle = {
  strokeWidth = 2,
  strokeColor = { white = 1, alpha = 0.3 },
  fillColor = { white = 0, alpha = 0.85 },
  textColor = { white = 1, alpha = 1 },
  titleColor = { white = 1, alpha = 0.9 },
  subColor = { white = 1, alpha = 0.5 },
  dimColor = { white = 1, alpha = 0.3 },
  keyColor = { hex = "#7AA2F7", alpha = 1 },
  noteColor = { hex = "#E0AF68", alpha = 1 },
  textFont = ".AppleSystemUIFont",
  keyFont = "Menlo",
  textSize = 14,
  radius = 12,
  padding = 16,
  rowGap = 8,
  keyGap = 10,
  subGap = 18,
  columnGap = 28,
  bottomMargin = 60,
  fadeInDuration = 0.1,
  -- Zero on purpose, as VolumeControl explains: hs.canvas:hide(duration) schedules an orderOut for when
  -- its animation finishes and nothing cancels it, so a panel put back up mid-fade is yanked off again
  fadeOutDuration = 0,
}

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.chooser = nil
obj.menubarItem = nil
obj.spaceWatcher = nil
obj.hotkeys = {}
obj.warned = {}
obj.running = false

obj.yabaiResolved = nil -- nil not yet looked for, false looked for and absent, string the path
obj.yabaiTasks = {}
obj.byId = {} -- last listed Space model, keyed on the stable Space id
obj.flow = nil -- nil at the verb list, otherwise { verb = <VERBS entry>, step, picks = {}, trail = {} }
obj.flowTimer = nil
obj.pollTimers = {}

obj.modal = nil
obj.modalActive = false
obj.level = nil -- what the panel is showing: { title, prompt, rows, keymap, loading, note }
obj.gen = 0 -- bumped on every level change, so a list that arrives late cannot draw over the level that replaced it
obj.panel = nil
obj.panelShown = false -- our own record; show() is makeKeyAndOrderFront, not free to repeat
obj.panelTimer = nil
obj.noteTimer = nil
obj.idleTimer = nil

local UNKNOWN_SCREEN = "Unknown display"
local BACK_TEXT = "← Back"

-- Stateless helpers

-- Log a given message only once, so a broken system API cannot spam the console
function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- yabai rejects "1628.0", which is what tostring() makes of a JSON-decoded id on some builds
local function fmtId(id)
  return string.format("%d", math.floor(id))
end

-- A digit key for whatever Mission Control already numbers, so the key on the panel is the number on the Space
local function indexHint(n)
  if type(n) == "number" and n >= 1 and n <= 9 then return string.format("%d", math.floor(n)) end
  return nil
end

local function spaceName(entry)
  return entry.label or string.format("Desktop %d", entry.index)
end

-- attributes() follows symlinks, which is wanted: /opt/homebrew/bin/yabai links into the Cellar
local function executableFile(path)
  if type(path) ~= "string" or path == "" then return false end
  local okMode, mode = pcall(hs.fs.attributes, path, "mode")
  if not okMode or mode ~= "file" then return false end
  local okPerm, perms = pcall(hs.fs.attributes, path, "permissions")
  -- Owner-execute, since Hammerspoon runs as the user who installed it
  return okPerm and type(perms) == "string" and perms:sub(3, 3) == "x"
end

-- Screen names by UUID, which is the only field yabai and hs.screen agree on
local function screenNamesByUUID()
  local names = {}
  for _, s in ipairs(hs.screen.allScreens()) do
    local okU, uuid = pcall(s.getUUID, s)
    local okN, name = pcall(s.name, s)
    if okU and uuid then names[uuid] = (okN and name) or UNKNOWN_SCREEN end
  end
  return names
end

-- hs.screen by yabai display index, for the fallbacks, which speak in screen objects where yabai speaks in indices
local function screensByDisplayIndex(displays)
  local uuids, out = {}, {}
  for _, s in ipairs(hs.screen.allScreens()) do
    local okU, uuid = pcall(s.getUUID, s)
    if okU and uuid then uuids[uuid] = s end
  end
  for _, d in ipairs(displays or {}) do
    if type(d) == "table" and d.index and d.uuid then out[math.floor(d.index)] = uuids[d.uuid] end
  end
  return out
end

-- yabai

-- Homebrew, nix-darwin and hand installs. Static, because hs.task cannot search PATH and Hammerspoon inherits launchd's environment rather than a login shell's
local YABAI_PATHS = {
  "/opt/homebrew/bin/yabai",
  "/usr/local/bin/yabai",
  "/run/current-system/sw/bin/yabai",
  -- Last, and nil-safe: a trailing nil shortens the list rather than erroring
  os.getenv("HOME") and (os.getenv("HOME") .. "/.local/bin/yabai") or nil,
}

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
        "Yabai.yabaiPath is %s, which is not an executable file; ignoring it",
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

-- Calls done(ok, out, err) exactly once
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

-- Deliberately uncached. Every read here either builds a list the user is about to act on or re-checks one immediately after acting, and a stale answer in either place is the bug this Spoon exists to avoid
function obj:yabaiQuery(kind, done)
  self:yabaiRun({ "--message", "query", "--" .. kind }, function(ok, out, err)
    if not ok then
      self:warnOnce(
        "yabaiserver",
        "yabai is installed but not answering (%s); is the service running? Try `yabai --start-service`. Falling back to hs.spaces.",
        tostring(err)
      )
      return done(nil, tostring(err))
    end
    -- decode() raises on malformed input rather than returning nil
    local okJson, decoded = pcall(hs.json.decode, out or "")
    if not okJson or type(decoded) ~= "table" then
      self:warnOnce(
        "yabaijson",
        "could not parse `yabai --message query --%s` output; the yabai CLI may have changed shape",
        kind
      )
      return done(nil, "unparseable " .. kind .. " list")
    end

    self.logger.df("query --%s returned %s", kind, hs.inspect(decoded))
    done(decoded, nil)
  end)
end

-- Poll rather than wait: half the things checked here are answers from a subprocess, which hs.timer.waitUntil cannot await. `probe` gets a callback and must call it once with a boolean
function obj:pollUntil(probe, timeout, interval, done)
  local deadline = hs.timer.secondsSinceEpoch() + timeout
  local settled = false

  local function tick()
    probe(function(ok)
      if settled then return end
      if ok then
        settled = true
        return done(true)
      end
      if hs.timer.secondsSinceEpoch() >= deadline then
        settled = true
        return done(false)
      end
      local t
      t = hs.timer.doAfter(interval, function()
        self.pollTimers[t] = nil
        tick()
      end)
      self.pollTimers[t] = true
    end)
  end

  tick()
end

-- Drop every pending poll, so a torn-down Spoon cannot be called back into
function obj:abortPolls()
  for t in pairs(self.pollTimers) do
    pcall(function()
      t:stop()
    end)
  end
  self.pollTimers = {}
  return self
end

-- The model

-- Space ids are stable, Mission Control positions are not. Everything the chooser hands back is an id, and the position is re-read from the id at the last possible moment
local function entryFor(id, index, label, screenName, count, isActive, isFullscreen, displayIndex)
  return {
    id = id,
    index = index,
    label = label,
    screenName = screenName,
    displayIndex = displayIndex,
    managedCount = count,
    isActive = isActive,
    isFullscreen = isFullscreen,
    blockedReason = nil,
  }
end

-- macOS refuses the active Space and the last ordinary Space on a screen, so refuse them here too rather than letting the user pick one and watch it fail
local function markBlocked(entries, perScreenUserCount)
  for _, e in ipairs(entries) do
    if e.isFullscreen then
      e.blockedReason = "fullscreen app, close it instead"
    elseif e.isActive then
      e.blockedReason = "active Space, switch away first"
    elseif (perScreenUserCount[e.screenName] or 0) < 2 then
      e.blockedReason = "only Space on this screen"
    end
  end
end

function obj:assembleYabai(spaces, windows, displays)
  local uuidNames = screenNamesByUUID()
  local displayNames = {}
  for _, d in ipairs(displays or {}) do
    if type(d) == "table" and d.index then displayNames[d.index] = uuidNames[d.uuid] or UNKNOWN_SCREEN end
  end

  -- One pass over every window, bucketed by the Mission Control index each one reports
  local ownPid = hs.processInfo and hs.processInfo.processID
  local counts = {}
  for _, w in ipairs(windows or {}) do
    local wanted = self.countFloating or not w["is-floating"]
    -- Our own canvases come and go with focus, so a count that includes them changes while it is being read
    if wanted and w.pid ~= ownPid and type(w.space) == "number" then counts[w.space] = (counts[w.space] or 0) + 1 end
  end

  local entries, perScreen = {}, {}
  for _, s in ipairs(spaces or {}) do
    if type(s) == "table" and type(s.id) == "number" and type(s.index) == "number" then
      local screenName = displayNames[s.display] or UNKNOWN_SCREEN
      local label = (type(s.label) == "string" and s.label ~= "") and s.label or nil
      local e = entryFor(
        math.floor(s.id),
        math.floor(s.index),
        label,
        screenName,
        counts[s.index] or 0,
        s["has-focus"] == true,
        s["is-native-fullscreen"] == true,
        type(s.display) == "number" and math.floor(s.display) or nil
      )
      entries[#entries + 1] = e
      if not e.isFullscreen then perScreen[screenName] = (perScreen[screenName] or 0) + 1 end
    end
  end

  markBlocked(entries, perScreen)
  return entries
end

-- Fallback. Correct, but coarser: hs.spaces counts every window on a Space rather than the managed ones, so its totals read high next to yabai's
function obj:assembleSpaces()
  local ownPid = hs.processInfo and hs.processInfo.processID
  local entries, perScreen = {}, {}

  for screenIndex, screen in ipairs(hs.screen.allScreens()) do
    local okU, uuid = pcall(screen.getUUID, screen)
    if okU and uuid then
      local screenName = (select(2, pcall(screen.name, screen))) or UNKNOWN_SCREEN
      local okL, list = pcall(hs.spaces.spacesForScreen, uuid)
      local active = select(2, pcall(hs.spaces.activeSpaceOnScreen, uuid))
      if okL and type(list) == "table" then
        for i, id in ipairs(list) do
          local kind = select(2, pcall(hs.spaces.spaceType, id))
          local okW, wins = pcall(hs.spaces.windowsForSpace, id)
          local count = 0
          for _, winId in ipairs((okW and wins) or {}) do
            local w = hs.window.get(winId)
            local okP, pid = pcall(function()
              return w and w:pid()
            end)
            if not (okP and pid == ownPid) then count = count + 1 end
          end
          local e = entryFor(id, i, nil, screenName, count, id == active, kind == "fullscreen", screenIndex)
          entries[#entries + 1] = e
          if not e.isFullscreen then perScreen[screenName] = (perScreen[screenName] or 0) + 1 end
        end
      end
    end
  end

  markBlocked(entries, perScreen)
  return entries
end

--- Yabai:listSpaces(done) -> self
--- Method
--- Builds the current Space model and hands it to a callback.
---
--- Parameters:
---  * done - Called as `done(entries, err)`. `entries` is an array of tables carrying `id`, `index`, `label`, `screenName`, `displayIndex`, `managedCount`, `isActive`, `isFullscreen` and `blockedReason`, or nil and a message if the world could not be read
---
--- Returns:
---  * The Yabai object
---
--- Asynchronous because the yabai path is: three socket queries, none of which may block the runloop. Exposed for prodding from the Console, where `hs.inspect` on the result is the fastest way to see what the chooser is about to show.
function obj:listSpaces(done)
  if not self:yabaiBinary() then
    local ok, entries = pcall(self.assembleSpaces, self)
    if not ok then return done(nil, tostring(entries)) end
    return done(entries, nil)
  end

  self:yabaiQuery("spaces", function(spaces, err)
    if not spaces then
      -- Spelled out rather than folded into `and`/`or`: `ok and nil or err` yields err even when ok, which reports a fallback that worked as a failure
      local ok, entries = pcall(self.assembleSpaces, self)
      if not ok then
        return done(nil, string.format("%s, and hs.spaces also failed (%s)", tostring(err), tostring(entries)))
      end
      return done(entries, nil)
    end
    self:yabaiQuery("windows", function(windows, err2)
      if not windows then return done(nil, err2) end
      -- Display names are cosmetic, so a failure here degrades the row rather than the operation
      self:yabaiQuery("displays", function(displays)
        local ok, entries = pcall(self.assembleYabai, self, spaces, windows, displays)
        if not ok then return done(nil, tostring(entries)) end
        done(entries, nil)
      end)
    end)
  end)
  return self
end

--- Yabai:listDisplays(done) -> self
--- Method
--- Lists the attached displays, with the number of Spaces on each.
---
--- Parameters:
---  * done - Called as `done(entries, err)`. `entries` is an array of tables carrying `index`, `name`, `spaceCount`, `isActive` and `screen`
---
--- Returns:
---  * The Yabai object
---
--- `index` is yabai's display number, which is what every yabai display selector wants, and `screen` is the matching `hs.screen` for the fallbacks, which speak in screen objects instead.
function obj:listDisplays(done)
  local uuidNames = screenNamesByUUID()

  if not self:yabaiBinary() then
    local entries = {}
    -- hs.screen's own ordering stands in for yabai's display numbering, which is the same left-to-right order in practice
    for i, screen in ipairs(hs.screen.allScreens()) do
      local okU, uuid = pcall(screen.getUUID, screen)
      local count = 0
      if okU and uuid then
        local okL, list = pcall(hs.spaces.spacesForScreen, uuid)
        if okL and type(list) == "table" then count = #list end
      end
      entries[i] = {
        index = i,
        name = (okU and uuidNames[uuid]) or UNKNOWN_SCREEN,
        spaceCount = count,
        isActive = screen == hs.screen.mainScreen(),
        screen = screen,
      }
    end
    return done(entries, nil)
  end

  self:yabaiQuery("displays", function(displays, err)
    if not displays then return done(nil, err) end
    local screens = screensByDisplayIndex(displays)
    local entries = {}
    for _, d in ipairs(displays) do
      if type(d) == "table" and type(d.index) == "number" then
        local index = math.floor(d.index)
        entries[#entries + 1] = {
          index = index,
          name = uuidNames[d.uuid] or UNKNOWN_SCREEN,
          spaceCount = type(d.spaces) == "table" and #d.spaces or 0,
          isActive = d["has-focus"] == true,
          screen = screens[index],
        }
      end
    end
    done(entries, nil)
  end)
  return self
end

--- Yabai:listWindows(done) -> self
--- Method
--- Lists every window that is not our own, with the Space it is on.
---
--- Parameters:
---  * done - Called as `done(entries, err)`. `entries` is an array of tables carrying `winId`, `appName`, `title`, `spaceId`, `spaceIndex`, `spaceName`, `displayIndex` and `minimized`
---
--- Returns:
---  * The Yabai object
---
--- Own windows are excluded by pid rather than by application name. `hs.window:application()` logs from Hammerspoon's C layer and returns nil transiently even for a live process, so a guard written on it fails open; the pid a window already carries cannot.
---
--- Minimized windows are left out unless `Yabai.showMinimized` is set. They have no Space in any useful sense, and `DeminimizeWindow` is the Spoon that deals with them.
function obj:listWindows(done)
  local ownPid = hs.processInfo and hs.processInfo.processID

  if not self:yabaiBinary() then
    -- Spaces first here too, so a fallback row reads "Desktop 2" like every other row rather than a raw Space id
    return self:listSpaces(function(spaces, err)
      if not spaces then return done(nil, err) end
      local byId = {}
      for _, s in ipairs(spaces) do
        byId[s.id] = s
      end

      -- One bulk read instead of win:application() per window: that call logs from Hammerspoon's C layer and returns nil transiently even for a live process, so a per-window lookup is both noisy and unreliable
      local names = {}
      for _, app in ipairs(hs.application.runningApplications()) do
        local okP, pid = pcall(app.pid, app)
        local okN, name = pcall(app.name, app)
        if okP and pid then names[pid] = (okN and name) or "Unknown" end
      end

      -- setDefaultFilter{} is load-bearing: a stock filter is visible=true and so never reports a minimized window. setCurrentSpace(nil) is what widens it past the Space we happen to be standing on
      local okF, filter = pcall(hs.window.filter.new)
      if not okF or not filter then return done(nil, "could not build a window filter") end
      pcall(filter.setDefaultFilter, filter, {})
      pcall(filter.setCurrentSpace, filter, nil)

      local entries = {}
      for _, win in ipairs(filter:getWindows()) do
        local okP, pid = pcall(win.pid, win)
        local minimized = select(2, pcall(win.isMinimized, win)) == true
        if okP and pid ~= ownPid and (self.showMinimized or not minimized) then
          local ids = select(2, pcall(hs.spaces.windowSpaces, win:id()))
          local space = type(ids) == "table" and ids[1] and byId[ids[1]] or nil
          entries[#entries + 1] = {
            winId = win:id(),
            appName = names[pid] or "Unknown",
            title = select(2, pcall(win.title, win)) or "",
            spaceId = space and space.id or nil,
            spaceIndex = space and space.index or nil,
            spaceName = space and spaceName(space) or "Unknown Space",
            displayIndex = space and space.displayIndex or nil,
            minimized = minimized,
          }
        end
      end
      done(entries, nil)
    end)
  end

  -- Spaces first, so each window can be labelled with the Space name the rest of the chooser uses rather than a bare index
  self:listSpaces(function(spaces, err)
    if not spaces then return done(nil, err) end
    local byIndex = {}
    for _, s in ipairs(spaces) do
      byIndex[s.index] = s
    end

    self:yabaiQuery("windows", function(windows, err2)
      if not windows then return done(nil, err2) end
      local entries = {}
      for _, w in ipairs(windows) do
        local minimized = w["is-minimized"] == true
        if type(w.id) == "number" and w.pid ~= ownPid and (self.showMinimized or not minimized) then
          local space = type(w.space) == "number" and byIndex[math.floor(w.space)] or nil
          entries[#entries + 1] = {
            winId = math.floor(w.id),
            appName = (type(w.app) == "string" and w.app ~= "") and w.app or "Unknown",
            title = type(w.title) == "string" and w.title or "",
            spaceId = space and space.id or nil,
            spaceIndex = space and space.index or nil,
            spaceName = space and spaceName(space) or "Unknown Space",
            displayIndex = type(w.display) == "number" and math.floor(w.display) or nil,
            minimized = minimized,
          }
        end
      end
      done(entries, nil)
    end)
  end)
  return self
end

-- The verbs

local function findSpace(entries, id)
  for _, e in ipairs(entries or {}) do
    if e.id == id then return e end
  end
  return nil
end

-- Every verb ends here: nothing trusts an exit code, so the command is followed by re-reading the world until the change shows up or verifyTimeout runs out
function obj:confirmThen(what, probe, done)
  self:pollUntil(probe, self.verifyTimeout, self.verifyInterval, function(observed)
    -- A function rather than a string where naming the thing is only possible afterwards: a window on another Space has no hs.window to ask until the focus has actually moved there
    if type(what) == "function" then what = what(observed) end
    if observed then
      self.logger.f("%s took effect", what)
      hs.alert.show(what)
    else
      self.logger.wf("%s was issued but never took effect", what)
      hs.alert.show(string.format("%s\nIssued, but nothing changed", what))
    end
    self:updateMenubar()
    if done then done(observed) end
  end)
end

-- Reports a verb that could not be issued at all, as opposed to one issued and ignored
function obj:reportFailure(what, why)
  self.logger.ef("could not %s: %s", what, tostring(why))
  hs.alert.show(string.format("Could not %s\n%s", what, tostring(why)))
  return self
end

--- Yabai:focusSpaceById(id) -> self
--- Method
--- Switches to one Space, named by its stable Space id.
---
--- Parameters:
---  * id - The Space id, as reported by `Yabai:listSpaces()` or `hs.spaces`
---
--- Returns:
---  * The Yabai object
---
--- The one verb that needs nothing special from yabai: `space --focus` goes over the plain socket, so this works on a machine with System Integrity Protection fully enabled, and `hs.spaces.gotoSpace` stands behind it regardless.
function obj:focusSpaceById(id)
  self:listSpaces(function(entries, err)
    if not entries then return self:reportFailure("read the Spaces", err) end
    local entry = findSpace(entries, id)
    if not entry then return hs.alert.show("That Space is already gone") end
    if entry.isActive then return hs.alert.show(string.format("Already on %s", spaceName(entry))) end

    local what = string.format("Focused %s", spaceName(entry))
    local function probe(answer)
      answer(select(2, pcall(hs.spaces.focusedSpace)) == id)
    end
    local function viaSpaces()
      local ok, why = hs.spaces.gotoSpace(id)
      if ok ~= true then return self:reportFailure("focus " .. spaceName(entry), why) end
      self:confirmThen(what, probe)
    end

    if self:yabaiBinary() then
      -- The selector is a Mission Control position, so it is read fresh from the id rather than remembered from the list
      self:yabaiRun({ "--message", "space", "--focus", tostring(entry.index) }, function(ok, _, why)
        if ok then return self:confirmThen(what, probe) end
        self.logger.f("yabai could not focus Space %d (%s); falling back to hs.spaces", id, tostring(why))
        viaSpaces()
      end)
    else
      viaSpaces()
    end
  end)
  return self
end

--- Yabai:createSpaceOnDisplay(displayIndex) -> self
--- Method
--- Adds a Space to the end of one display.
---
--- Parameters:
---  * displayIndex - The yabai display number, as reported by `Yabai:listDisplays()`
---
--- Returns:
---  * The Yabai object
---
--- macOS always appends: neither backend can insert a Space at a chosen position, so the new Space lands last and `Yabai:moveSpaceToPosition()` is what puts it somewhere else.
function obj:createSpaceOnDisplay(displayIndex)
  self:listDisplays(function(displays, err)
    if not displays then return self:reportFailure("read the displays", err) end

    local display
    for _, d in ipairs(displays) do
      if d.index == displayIndex then display = d end
    end
    if not display then return hs.alert.show("That display is no longer attached") end

    -- Counted before, because the only evidence a Space was created is that there is one more of them
    self:listSpaces(function(before, err2)
      if not before then return self:reportFailure("read the Spaces", err2) end
      local was = #before

      local what = string.format("Created a Space on %s", display.name)
      local function probe(answer)
        self:listSpaces(function(after)
          answer(after ~= nil and #after > was)
        end)
      end
      local function viaSpaces()
        if not display.screen then
          return self:reportFailure("create a Space", "no hs.screen matches display " .. tostring(displayIndex))
        end
        local ok, why = hs.spaces.addSpaceToScreen(display.screen)
        if ok ~= true then return self:reportFailure("create a Space on " .. display.name, why) end
        self:confirmThen(what, probe)
      end

      if self:yabaiBinary() then
        self:yabaiRun({ "--message", "space", "--create", tostring(displayIndex) }, function(ok, _, why)
          if ok then return self:confirmThen(what, probe) end
          -- Creating a Space goes through yabai's scripting addition, which is a separate install and absent on plenty of machines that otherwise run yabai happily. A failure for want of it is no reason to stop while hs.spaces can still do the job
          self.logger.f("yabai could not create a Space (%s); falling back to hs.spaces", tostring(why))
          viaSpaces()
        end)
      else
        viaSpaces()
      end
    end)
  end)
  return self
end

-- Fails without yabai's scripting addition, which is why every caller has a fallback behind it
function obj:destroyViaYabai(entry, done)
  -- The selector is a Mission Control position, so it is read fresh from the id above rather than remembered from the list
  self:yabaiRun({ "--message", "space", "--destroy", tostring(entry.index) }, function(ok, _, err)
    done(ok, err)
  end)
end

function obj:destroyViaSpaces(entry, done)
  -- Takes the stable id, but opens Mission Control and clicks its remove button to do it
  local ok, err = hs.spaces.removeSpace(entry.id)
  done(ok == true, err)
end

--- Yabai:deleteById(id) -> self
--- Method
--- Deletes one Space, named by its stable Space id.
---
--- Parameters:
---  * id - The Space id, as reported by `Yabai:listSpaces()` or `hs.spaces`
---
--- Returns:
---  * The Yabai object
---
--- Re-reads every Space before acting. The id the chooser handed back is stable, but the Mission Control position both backends select on is not, and the list may be seconds old by the time a choice is made, so the position is resolved from the id here and the Space is re-checked for having become active or last-on-its-screen in the meantime.
---
--- One Space per invocation, deliberately. Those positions renumber the moment a Space goes away, so a batch loop is a loop whose target drifts under it.
function obj:deleteById(id)
  self:listSpaces(function(entries, err)
    if not entries then return self:reportFailure("re-read the Spaces", err) end

    local entry = findSpace(entries, id)
    if not entry then return hs.alert.show("That Space is already gone") end
    if entry.blockedReason then return hs.alert.show("Cannot delete that Space: " .. entry.blockedReason) end

    local name = spaceName(entry)
    if self.confirmWhenWindows and entry.managedCount > 0 then
      local answer = hs.dialog.blockAlert(
        string.format("Delete %s?", name),
        string.format(
          "Its %s will move to another Space. This cannot be undone.",
          plural(entry.managedCount, "managed window")
        ),
        "Delete",
        "Cancel"
      )
      if answer ~= "Delete" then return end
    end

    local function report(ok, why)
      if not ok then return self:reportFailure("delete " .. name, why) end
      -- Nothing here trusts an exit code: the Space is gone when it is observed to be gone
      self:confirmThen(string.format("Deleted %s", name), function(answer)
        self:listSpaces(function(after)
          answer(after ~= nil and findSpace(after, id) == nil)
        end)
      end)
    end

    if self:yabaiBinary() then
      self:destroyViaYabai(entry, function(ok, why)
        if ok then return report(true) end
        -- Querying yabai needs nothing special, but destroying a Space goes through its scripting addition, which is a separate install and absent on plenty of machines that otherwise run yabai happily. A destroy that fails for want of it is no reason to stop while hs.spaces can still do the job
        self.logger.f("yabai could not destroy Space %d (%s); falling back to hs.spaces", entry.id, tostring(why))
        self:destroyViaSpaces(entry, report)
      end)
    else
      self:destroyViaSpaces(entry, report)
    end
  end)
  return self
end

--- Yabai:moveSpaceToPosition(id, position) -> self
--- Method
--- Moves a Space to another Mission Control position on the display it is already on.
---
--- Parameters:
---  * id - The Space id to move
---  * position - The Mission Control position to move it to, counted across all displays as yabai counts them
---
--- Returns:
---  * The Yabai object
---
--- yabai only. `hs.spaces` can create, remove and switch Spaces but has no way to reorder them, so where yabai cannot do this nothing can, and the failure says so rather than pretending a fallback was tried.
function obj:moveSpaceToPosition(id, position)
  if not self:yabaiBinary() then
    return self:reportFailure("reorder a Space", "yabai is required; nothing else can reorder Spaces")
  end

  self:listSpaces(function(entries, err)
    if not entries then return self:reportFailure("re-read the Spaces", err) end
    local entry = findSpace(entries, id)
    if not entry then return hs.alert.show("That Space is already gone") end
    if entry.index == position then return hs.alert.show(string.format("%s is already there", spaceName(entry))) end

    local name = spaceName(entry)
    -- Selected space first, destination after the flag: `space <src> --move <dst>` moves the former to the latter's position
    self:yabaiRun({ "--message", "space", tostring(entry.index), "--move", tostring(position) }, function(ok, _, why)
      if not ok then
        return self:reportFailure("reorder " .. name, tostring(why) .. " (this needs yabai's scripting addition)")
      end
      self:confirmThen(string.format("Moved %s to position %d", name, position), function(answer)
        self:listSpaces(function(after)
          local moved = findSpace(after, id)
          answer(moved ~= nil and moved.index == position)
        end)
      end)
    end)
  end)
  return self
end

--- Yabai:moveSpaceToDisplay(id, displayIndex) -> self
--- Method
--- Sends a whole Space, and everything on it, to another display.
---
--- Parameters:
---  * id - The Space id to send
---  * displayIndex - The yabai display number to send it to
---
--- Returns:
---  * The Yabai object
---
--- yabai only, for the same reason as `Yabai:moveSpaceToPosition()`: `hs.spaces` cannot move a Space between displays at all.
function obj:moveSpaceToDisplay(id, displayIndex)
  if not self:yabaiBinary() then
    return self:reportFailure(
      "send a Space to another display",
      "yabai is required; nothing else can move Spaces between displays"
    )
  end

  self:listSpaces(function(entries, err)
    if not entries then return self:reportFailure("re-read the Spaces", err) end
    local entry = findSpace(entries, id)
    if not entry then return hs.alert.show("That Space is already gone") end
    if entry.displayIndex == displayIndex then
      return hs.alert.show(string.format("%s is already on that display", spaceName(entry)))
    end

    local name = spaceName(entry)
    self:yabaiRun(
      { "--message", "space", tostring(entry.index), "--display", tostring(displayIndex) },
      function(ok, _, why)
        if not ok then
          return self:reportFailure(
            "send " .. name .. " to display " .. tostring(displayIndex),
            tostring(why) .. " (this needs yabai's scripting addition)"
          )
        end
        self:confirmThen(string.format("Sent %s to display %d", name, displayIndex), function(answer)
          self:listSpaces(function(after)
            local moved = findSpace(after, id)
            answer(moved ~= nil and moved.displayIndex == displayIndex)
          end)
        end)
      end
    )
  end)
  return self
end

local function windowLabel(entry)
  return (entry.title ~= "" and entry.title) or entry.appName
end

--- Yabai:focusWindowById(winId) -> self
--- Method
--- Focuses one window, following it onto whatever Space it is on.
---
--- Parameters:
---  * winId - The window id, as reported by `Yabai:listWindows()` or `hs.window:id()`
---
--- Returns:
---  * The Yabai object
---
--- Needs nothing from yabai's scripting addition, and `hs.window:focus()` stands behind it, so this is the one window verb that works everywhere.
function obj:focusWindowById(winId)
  -- Named afterwards, not before: hs.window.get() returns nil for a window on another Space, so there is nothing to ask for a title until the focus has moved there
  local function what()
    local win = hs.window.get(winId)
    local title = win and select(2, pcall(win.title, win)) or nil
    return string.format("Focused %s", (title ~= nil and title ~= "") and title or "window")
  end

  local function probe(answer)
    local focused = hs.window.focusedWindow()
    answer(focused ~= nil and focused:id() == winId)
  end

  local function viaHammerspoon()
    local win = hs.window.get(winId)
    -- Not "it no longer exists": a window sitting on another Space is invisible to hs.window and perfectly alive, and only yabai can reach across to it
    if not win then
      return self:reportFailure("focus that window", "it is on another Space, which needs yabai to reach")
    end
    pcall(win.focus, win)
    self:confirmThen(what, probe)
  end

  if self:yabaiBinary() then
    self:yabaiRun({ "--message", "window", "--focus", fmtId(winId) }, function(ok, _, why)
      if ok then return self:confirmThen(what, probe) end
      self.logger.f("yabai could not focus window %s (%s); falling back to hs.window", fmtId(winId), tostring(why))
      viaHammerspoon()
    end)
  else
    viaHammerspoon()
  end
  return self
end

--- Yabai:moveWindowToSpace(winId, spaceId) -> self
--- Method
--- Moves one window to another Space.
---
--- Parameters:
---  * winId - The window id to move
---  * spaceId - The stable Space id to move it to
---
--- Returns:
---  * The Yabai object
---
--- yabai is the real path here. `hs.spaces.moveWindowToSpace()` is tried behind it and reported honestly, but it has been a silent no-op since macOS 15 -- it returns success and moves nothing -- which is why the result is polled rather than believed. `SummonWindow` carries a third rung that borrows the mouse pointer to drag the window across in Mission Control; it is deliberately not duplicated here.
function obj:moveWindowToSpace(winId, spaceId)
  self:listSpaces(function(entries, err)
    if not entries then return self:reportFailure("re-read the Spaces", err) end
    local target = findSpace(entries, spaceId)
    if not target then return hs.alert.show("That Space is already gone") end

    local name = spaceName(target)
    local function probe(answer)
      local ids = select(2, pcall(hs.spaces.windowSpaces, winId))
      answer(type(ids) == "table" and hs.fnutils.contains(ids, spaceId))
    end
    local function viaSpaces()
      -- The value carries no information on macOS 15 and later, so it is logged and the poll below is left to have the opinion
      local ok, why = hs.spaces.moveWindowToSpace(winId, spaceId)
      self.logger.f("hs.spaces.moveWindowToSpace returned %s (%s)", tostring(ok), tostring(why))
      self:confirmThen(string.format("Moved window to %s", name), probe)
    end

    if self:yabaiBinary() then
      -- Window id first, destination index after the flag
      self:yabaiRun({ "--message", "window", fmtId(winId), "--space", tostring(target.index) }, function(ok, _, why)
        if ok then return self:confirmThen(string.format("Moved window to %s", name), probe) end
        -- Moving a window across Spaces goes through yabai's scripting addition too, so this failure is the common one on a machine with SIP left on
        self.logger.f(
          "yabai could not move window %s to Space %d (%s); falling back to hs.spaces",
          fmtId(winId),
          spaceId,
          tostring(why)
        )
        viaSpaces()
      end)
    else
      viaSpaces()
    end
  end)
  return self
end

--- Yabai:moveWindowToDisplay(winId, displayIndex) -> self
--- Method
--- Sends one window to another display.
---
--- Parameters:
---  * winId - The window id to send
---  * displayIndex - The yabai display number to send it to
---
--- Returns:
---  * The Yabai object
---
--- `hs.window:moveToScreen()` stands behind yabai here and genuinely works, because moving a window between displays does not cross a Space and so needs no scripting addition.
function obj:moveWindowToDisplay(winId, displayIndex)
  self:listDisplays(function(displays, err)
    if not displays then return self:reportFailure("read the displays", err) end

    local display
    for _, d in ipairs(displays) do
      if d.index == displayIndex then display = d end
    end
    if not display then return hs.alert.show("That display is no longer attached") end

    local what = string.format("Sent window to %s", display.name)
    local function probe(answer)
      local win = hs.window.get(winId)
      local okS, screen = pcall(function()
        return win and win:screen()
      end)
      answer(okS and screen ~= nil and display.screen ~= nil and screen:getUUID() == display.screen:getUUID())
    end
    local function viaHammerspoon()
      local win = hs.window.get(winId)
      if not win then return self:reportFailure("send that window", "it no longer exists") end
      if not display.screen then
        return self:reportFailure("send that window", "no hs.screen matches display " .. tostring(displayIndex))
      end
      pcall(win.moveToScreen, win, display.screen)
      self:confirmThen(what, probe)
    end

    if self:yabaiBinary() then
      self:yabaiRun({ "--message", "window", fmtId(winId), "--display", tostring(displayIndex) }, function(ok, _, why)
        if ok then return self:confirmThen(what, probe) end
        self.logger.f(
          "yabai could not send window %s to display %d (%s); falling back to hs.window",
          fmtId(winId),
          displayIndex,
          tostring(why)
        )
        viaHammerspoon()
      end)
    else
      viaHammerspoon()
    end
  end)
  return self
end

-- The chooser

-- One entry per verb. `operands` names the screens it needs, in order, and each name keys both the builder that fills that screen and the pick it leaves behind in `flow.picks`
local VERBS = {
  {
    key = "focusSpace",
    hotkey = "f",
    text = "Focus Space",
    subText = "Switch to another Mission Control Space",
    operands = { "space" },
    run = function(self, picks)
      self:focusSpaceById(picks.space)
    end,
  },
  {
    key = "createSpace",
    hotkey = "c",
    text = "Create Space",
    subText = "Add a Space to the end of a display",
    operands = { "display" },
    run = function(self, picks)
      self:createSpaceOnDisplay(picks.display)
    end,
  },
  {
    key = "deleteSpace",
    hotkey = "d",
    text = "Delete Space",
    subText = "Remove a Space; its windows move elsewhere",
    operands = { "spaceDeletable" },
    run = function(self, picks)
      self:deleteById(picks.spaceDeletable)
    end,
  },
  {
    key = "reorderSpace",
    hotkey = "r",
    text = "Reorder Space",
    subText = "Move a Space to another position on its display",
    operands = { "space", "position" },
    yabaiOnly = true,
    run = function(self, picks)
      self:moveSpaceToPosition(picks.space, picks.position)
    end,
  },
  {
    key = "spaceToDisplay",
    hotkey = "s",
    text = "Send Space to Display",
    subText = "Move a Space, and everything on it, to another display",
    operands = { "space", "display" },
    yabaiOnly = true,
    multiDisplay = true,
    run = function(self, picks)
      self:moveSpaceToDisplay(picks.space, picks.display)
    end,
  },
  {
    key = "focusWindow",
    hotkey = "w",
    text = "Focus Window",
    subText = "Jump to a window, whichever Space it is on",
    operands = { "window" },
    run = function(self, picks)
      self:focusWindowById(picks.window)
    end,
  },
  {
    key = "windowToSpace",
    hotkey = "m",
    text = "Move Window to Space",
    subText = "Push a window onto another Space",
    operands = { "window", "space" },
    run = function(self, picks)
      self:moveWindowToSpace(picks.window, picks.space)
    end,
  },
  {
    key = "windowToDisplay",
    hotkey = "p",
    text = "Send Window to Display",
    subText = "Push a window onto another display",
    operands = { "window", "display" },
    multiDisplay = true,
    run = function(self, picks)
      self:moveWindowToDisplay(picks.window, picks.display)
    end,
  },
}

local function verbByKey(key)
  for _, v in ipairs(VERBS) do
    if v.key == key then return v end
  end
  return nil
end

-- Every operand screen is built the same way: asynchronously, from a fresh read, and handed back as a plain choices table. `picks` carries what earlier screens of the same verb already chose
local OPERANDS = {}

OPERANDS.space = function(self, picks, done)
  self:listSpaces(function(entries, err)
    if not entries then return done(nil, err) end
    local out = {}
    for _, e in ipairs(entries) do
      local blocked = nil
      -- A window already on a Space cannot be moved onto it, and a Space cannot be reordered relative to itself
      if picks.windowSpaceId and e.id == picks.windowSpaceId then
        blocked = "window is already here"
      elseif e.isFullscreen then
        blocked = "fullscreen app"
      end
      out[#out + 1] = {
        text = blocked and (spaceName(e) .. "  (" .. blocked .. ")") or spaceName(e),
        subText = string.format(
          "%s - %s%s",
          e.screenName,
          plural(e.managedCount, "managed window"),
          e.isActive and " - current" or ""
        ),
        -- Only plain values survive the trip into the chooser, and only the id is stable enough to act on later
        value = (not blocked) and e.id or nil,
        valid = blocked == nil,
        -- The key the modal prefers for this row; the chooser ignores it
        hint = indexHint(e.index),
        -- Carried alongside, so the display screen can grey out the one this Space is already on
        displayIndex = e.displayIndex,
      }
    end
    done(out, nil)
  end)
end

OPERANDS.spaceDeletable = function(self, picks, done)
  self:listSpaces(function(entries, err)
    if not entries then return done(nil, err) end
    self.byId = {}
    for _, e in ipairs(entries) do
      self.byId[e.id] = e
    end
    done(self:choicesFor(entries), nil)
  end)
end

OPERANDS.display = function(self, picks, done)
  self:listDisplays(function(entries, err)
    if not entries then return done(nil, err) end
    local out = {}
    for _, d in ipairs(entries) do
      local blocked = nil
      if picks.spaceDisplayIndex and d.index == picks.spaceDisplayIndex then
        blocked = "already on this display"
      elseif picks.windowDisplayIndex and d.index == picks.windowDisplayIndex then
        blocked = "window is already here"
      end
      out[#out + 1] = {
        text = blocked and (d.name .. "  (" .. blocked .. ")") or d.name,
        subText = string.format(
          "Display %d - %s%s",
          d.index,
          plural(d.spaceCount, "Space"),
          d.isActive and " - current" or ""
        ),
        value = (not blocked) and d.index or nil,
        valid = blocked == nil,
        hint = indexHint(d.index),
      }
    end
    done(out, nil)
  end)
end

-- Positions on the picked Space's own display. yabai numbers Mission Control positions across every display at once, so the positions offered are the ones its display actually occupies rather than 1..n
OPERANDS.position = function(self, picks, done)
  self:listSpaces(function(entries, err)
    if not entries then return done(nil, err) end
    local moving = findSpace(entries, picks.space)
    if not moving then return done(nil, "that Space is already gone") end

    local out = {}
    for _, e in ipairs(entries) do
      if e.displayIndex == moving.displayIndex then
        local isSelf = e.id == moving.id
        out[#out + 1] = {
          text = isSelf and string.format("Position %d  (where it is now)", e.index)
            or string.format("Position %d", e.index),
          subText = isSelf and string.format("%s stays put", spaceName(moving))
            or string.format("Move %s to where %s is", spaceName(moving), spaceName(e)),
          value = (not isSelf) and e.index or nil,
          valid = not isSelf,
          hint = indexHint(e.index),
        }
      end
    end
    done(out, nil)
  end)
end

OPERANDS.window = function(self, picks, done)
  self:listWindows(function(entries, err)
    if not entries then return done(nil, err) end
    -- Grouped by application, then by title, so the list does not reshuffle every time a window is focused
    table.sort(entries, function(a, b)
      if a.appName ~= b.appName then return a.appName < b.appName end
      return windowLabel(a) < windowLabel(b)
    end)
    local out = {}
    for _, e in ipairs(entries) do
      out[#out + 1] = {
        text = windowLabel(e),
        subText = string.format("%s - %s%s", e.appName, e.spaceName, e.minimized and " (minimized)" or ""),
        value = e.winId,
        valid = true,
        -- Carried alongside, so the next screen can grey out the Space and display it is already on
        spaceId = e.spaceId,
        displayIndex = e.displayIndex,
      }
    end
    done(out, nil)
  end)
end

-- What each screen says it is asking for
local PROMPTS = {
  space = "Which Space?",
  spaceDeletable = "Delete which Space?",
  display = "Which display?",
  position = "Move it where?",
  window = "Which window?",
}

--- Yabai:choicesFor(entries) -> table
--- Method
--- Renders a Space model as chooser rows for the delete screen, blocked Spaces included.
---
--- Parameters:
---  * entries - A Space model, as `Yabai:listSpaces()` produces
---
--- Returns:
---  * A list of `hs.chooser` choice tables
---
--- A Space macOS refuses to remove is rendered with its reason and made unselectable rather than dropped, so the list still matches what Mission Control shows.
function obj:choicesFor(entries)
  if #entries == 0 then
    -- valid = false keeps the row from dismissing the chooser when it is selected
    return { { text = "No Spaces found", subText = "Neither yabai nor hs.spaces reported any", valid = false } }
  end

  local out = {}
  for _, e in ipairs(entries) do
    local name = spaceName(e)
    local detail = string.format("%s - %s", e.screenName, plural(e.managedCount, "managed window"))
    out[#out + 1] = {
      text = e.blockedReason and (name .. "  (" .. e.blockedReason .. ")") or name,
      subText = detail,
      -- Only plain values survive the trip into the chooser, and only the id is stable enough to act on later
      value = (not e.blockedReason) and e.id or nil,
      valid = e.blockedReason == nil,
      hint = indexHint(e.index),
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    self:onChoice(choice)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  -- So that typing a screen or application name filters, even though the row itself shows the Space or the title
  self.chooser:searchSubText(true)
  return self.chooser
end

-- hs.chooser hides itself before it calls back, so the next screen is scheduled rather than shown inline: re-entering show() from inside the completion function fights the dismiss animation
function obj:present(choices, prompt)
  if self.flowTimer then pcall(function()
    self.flowTimer:stop()
  end) end
  self.flowTimer = hs.timer.doAfter(0, function()
    self.flowTimer = nil
    local chooser = self:ensureChooser()
    chooser:choices(choices)
    chooser:placeholderText(prompt)
    -- Cleared between screens, or the query typed to find a window would still be filtering the Space list
    chooser:query("")
    chooser:show()
  end)
  return self
end

-- The verb list. Display-dependent verbs are omitted outright on a single-screen machine rather than listed as no-ops; yabai-dependent ones stay, greyed, because a missing scripting addition is worth naming
function obj:verbChoices(done)
  self:listDisplays(function(displays)
    local multiDisplay = displays ~= nil and #displays > 1
    local hasYabai = self:yabaiBinary() ~= nil
    local out = {}
    for _, v in ipairs(VERBS) do
      if multiDisplay or not v.multiDisplay then
        local blocked = (v.yabaiOnly and not hasYabai) and "needs yabai" or nil
        out[#out + 1] = {
          text = blocked and (v.text .. "  (" .. blocked .. ")") or v.text,
          subText = v.subText,
          verbKey = (not blocked) and v.key or nil,
          valid = blocked == nil,
          hint = v.hotkey,
        }
      end
    end
    done(out)
  end)
end

function obj:showOperand()
  local flow = self.flow
  if not flow then return self end
  local kind = flow.verb.operands[flow.step]
  local prompt = string.format("%s - %s", flow.verb.text, PROMPTS[kind] or "?")

  OPERANDS[kind](self, flow.picks, function(choices, err)
    if not choices then
      self.logger.ef("could not build the %s list: %s", kind, tostring(err))
      choices = { { text = "Could not read that list", subText = tostring(err), valid = false } }
    elseif #choices == 0 then
      choices = { { text = "Nothing to choose here", subText = "Escape to go back", valid = false } }
    end
    -- Present on every screen, including the first, where back means the verb list. Escape does the same thing for the keyboard
    table.insert(choices, 1, { text = BACK_TEXT, subText = "Return to the previous screen", back = true, valid = true })
    self:present(choices, prompt)
  end)
  return self
end

-- The flow is the whole state of a half-finished operation, and both front ends push and pop the same one.
-- What follows is deliberately renderer-agnostic: the chooser and the modal differ in how a row is chosen,
-- not in what choosing it means

function obj:startFlow(verbKey)
  local verb = verbByKey(verbKey)
  if not verb then return nil end
  self.flow = { verb = verb, step = 1, picks = {}, trail = {} }
  return self.flow
end

-- Records one operand pick and says what should happen next: "run", "next", or "ignore" for a row carrying nothing to record
function obj:record(row)
  local flow = self.flow
  if not flow or not row or row.value == nil then return "ignore" end

  local kind = flow.verb.operands[flow.step]
  flow.picks[kind] = row.value
  -- Carried forward so the next screen can grey out where the thing already is, rather than offering a move to nowhere
  if kind == "window" then
    flow.picks.windowSpaceId = row.spaceId
    flow.picks.windowDisplayIndex = row.displayIndex
  elseif kind == "space" then
    flow.picks.spaceDisplayIndex = row.displayIndex
  end
  -- What the panel's breadcrumb reads back; the chooser has its own placeholder and ignores it
  flow.trail[#flow.trail + 1] = row.text or ""

  flow.step = flow.step + 1
  if flow.step > #flow.verb.operands then return "run" end
  return "next"
end

function obj:runFlow()
  local flow = self.flow
  if not flow then return self end
  -- Cleared before running, so a verb that reports asynchronously cannot be re-entered into a stale flow
  local verb, picks = flow.verb, flow.picks
  self.flow = nil
  verb.run(self, picks)
  return self
end

-- Whichever front end is live renders the step the flow is standing on
function obj:showStep()
  if self.modalActive then return self:showLevel() end
  return self:showOperand()
end

-- The single entry point for everything the chooser hands back: a verb, an operand, a back row, or nil for Escape
function obj:onChoice(choice)
  if not choice or choice.back then return self:back() end

  if choice.verbKey then
    if not self:startFlow(choice.verbKey) then return self end
    return self:showOperand()
  end

  local outcome = self:record(choice)
  if outcome == "run" then return self:runFlow() end
  if outcome == "next" then return self:showOperand() end
  return self
end

--- Yabai:back() -> self
--- Method
--- Steps one level back, dropping the pick made on the level being left.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- What Escape, Delete and the `← Back` row all call, in either front end. On the first operand level it returns to the verb list; at the verb list there is nothing left to pop, so the chooser dismisses and the modal leaves.
function obj:back()
  local flow = self.flow
  if not flow then
    if self.modalActive then return self:exitModal() end
    return self
  end

  if flow.step <= 1 then
    self.flow = nil
    if self.modalActive then return self:showLevel() end
    return self:show()
  end

  flow.step = flow.step - 1
  local kind = flow.verb.operands[flow.step]
  flow.picks[kind] = nil
  -- The fields carried alongside a pick are dropped with it, or the level being returned to would go on greying out where the abandoned window used to be
  if kind == "window" then
    flow.picks.windowSpaceId, flow.picks.windowDisplayIndex = nil, nil
  elseif kind == "space" then
    flow.picks.spaceDisplayIndex = nil
  end
  if flow.trail then flow.trail[#flow.trail] = nil end

  return self:showStep()
end

--- Yabai:show() -> self
--- Method
--- Opens the chooser at the verb list.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- What the menubar item's click opens, and what `Yabai:searchHere()` falls back to. Any half-finished flow is abandoned, so this always starts from the top; `/` inside the modal is the way to open the chooser mid-verb instead.
function obj:show()
  self:exitModal()
  self.flow = nil
  self:verbChoices(function(choices)
    self:present(choices, "What should yabai do?")
  end)
  return self
end

--- Yabai:hide() -> self
--- Method
--- Closes the chooser, abandoning any half-finished flow.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
function obj:hide()
  self:exitModal()
  self.flow = nil
  if self.chooser then pcall(self.chooser.hide, self.chooser) end
  return self
end

-- The panel

local PANEL_MAX_COLUMNS = 4
local PANEL_NOTE_SECONDS = 1.2
local PANEL_FOOTER = "esc  back      /  search"

-- getTextDrawingSize answers nil for a font it cannot resolve, and a nil width collapses the whole layout
local function measure(text, font, size)
  local ok, m = pcall(hs.drawing.getTextDrawingSize, text, { font = font, size = size })
  if not ok or type(m) ~= "table" or type(m.w) ~= "number" then return { w = #tostring(text) * size * 0.62 } end
  return m
end

-- A window title runs to whatever length its page gave it, and measuring one unclipped stretches the panel
-- off the screen, so a row is cut to fit before it is measured. utf8.offset snaps the cut to a character
-- boundary; cutting a multi-byte sequence in half draws a replacement glyph
local function fit(text, font, size, maxW)
  text = tostring(text or "")
  if maxW <= 0 or text == "" then return text end
  local width = measure(text, font, size).w
  if width <= maxW then return text end

  local chars = utf8.len(text)
  if not chars then return text end

  -- Proportional fonts make the first cut an estimate, so it is measured and retried rather than trusted
  local out = text
  for _ = 1, 4 do
    local keep = math.max(1, math.floor(chars * (maxW / width)) - 2)
    local cut = utf8.offset(text, keep + 1)
    if not cut then return out end
    out = (text:sub(1, cut - 1):gsub("%s+$", "")) .. "..."
    width = measure(out, font, size).w
    if width <= maxW then return out end
    chars = keep
  end
  return out
end

function obj:ensurePanel()
  if self.panel then return self.panel end

  local ok, canvas = pcall(hs.canvas.new, { x = 0, y = 0, w = 1, h = 1 })
  if not ok or not canvas then
    self:warnOnce("panel", "could not create the panel canvas: %s", tostring(canvas))
    return nil
  end
  -- Above the Dock and the menubar; a panel that slides under them reads as a bug
  canvas:level(hs.canvas.windowLevels.overlay)
  -- Never own a Space, and hide under Expose
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "transient" })

  self.panel = canvas
  return canvas
end

-- Rebuilt element by element on every level rather than re-textured like VolumeControl's readout: the row
-- count, the widths and the column split all change from one level to the next, and this runs on a keypress
-- rather than on a key repeat
function obj:drawPanel()
  local canvas = self:ensurePanel()
  local level = self.level
  if not canvas or not level then return self end

  local style = self.panelStyle
  local size = style.textSize
  local pad = style.padding
  local stroke = style.strokeWidth
  local lineH = math.ceil(size * 1.5)

  -- Four columns of panelRows is the ceiling; the rest is counted in the footer and left to the chooser
  local rows, dropped = {}, 0
  for _, row in ipairs(level.rows) do
    if #rows < self.panelRows * PANEL_MAX_COLUMNS then
      rows[#rows + 1] = row
    else
      dropped = dropped + 1
    end
  end

  local columns = math.max(1, math.min(PANEL_MAX_COLUMNS, math.ceil(#rows / self.panelRows)))
  local perColumn = math.max(1, math.ceil(#rows / columns))

  local screen = hs.screen.mainScreen()
  -- frame() rather than fullFrame(), so the bottom margin is measured from above the Dock
  local screenFrame = screen and screen:frame() or { x = 0, y = 0, w = 800, h = 600 }
  -- Per column, so four columns of long titles still land inside the panel rather than past the screen
  local maxLabelW = math.floor(screenFrame.w * (0.34 / columns) + 120)
  local maxSubW = math.floor(screenFrame.w * (0.26 / columns) + 80)

  local keyW = math.ceil(measure("mm", style.keyFont, size).w)
  local labels, subs = {}, {}
  local labelW, subW = 0, 0
  for i, row in ipairs(rows) do
    -- Cut here rather than in the row itself: the untruncated text is what keymap() and the breadcrumb read
    labels[i] = fit(row.text, style.textFont, size, maxLabelW)
    labelW = math.max(labelW, measure(labels[i], style.textFont, size).w)
    if type(row.subText) == "string" and row.subText ~= "" then
      subs[i] = fit(row.subText, style.textFont, size, maxSubW)
      subW = math.max(subW, measure(subs[i], style.textFont, size).w)
    end
  end
  labelW, subW = math.ceil(labelW), math.ceil(subW)
  local columnW = keyW + style.keyGap + labelW + (subW > 0 and (style.subGap + subW) or 0)

  local headerMax = math.floor(screenFrame.w * 0.88) - pad * 2
  local header = level.loading and string.format("%s  -  reading", level.title)
    or string.format("%s  -  %s", level.title, level.prompt)
  header = fit(header, style.textFont, size, headerMax)
  local footer = level.note or PANEL_FOOTER
  if dropped > 0 and not level.note then
    footer = string.format("%s      %s not shown, / to search", PANEL_FOOTER, plural(dropped, "row"))
  end

  local bodyRows = (level.loading or #rows == 0) and 1 or perColumn
  local w = math.max(
    pad * 2 + columns * columnW + (columns - 1) * style.columnGap,
    pad * 2 + math.ceil(measure(header, style.textFont, size).w),
    pad * 2 + math.ceil(measure(footer, style.textFont, size).w)
  )
  local h = pad * 2 + lineH + style.rowGap + bodyRows * lineH + style.rowGap + lineH
  w = math.min(w, math.floor(screenFrame.w * 0.92))

  local function text(str, x, y, width, color, font, alignment)
    return {
      type = "text",
      text = str,
      textFont = font or style.textFont,
      textSize = size,
      textColor = color,
      textAlignment = alignment or "left",
      frame = { x = x, y = y, w = width, h = lineH },
    }
  end

  local elements = {
    {
      type = "rectangle",
      action = "strokeAndFill",
      strokeWidth = stroke,
      strokeColor = style.strokeColor,
      fillColor = style.fillColor,
      roundedRectRadii = { xRadius = style.radius, yRadius = style.radius },
      -- Inset by half the stroke, which straddles its path and would otherwise clip at the edge
      frame = { x = stroke / 2, y = stroke / 2, w = w - stroke, h = h - stroke },
    },
    text(header, pad, pad, w - pad * 2, style.titleColor),
    text(footer, pad, h - pad - lineH, w - pad * 2, level.note and style.noteColor or style.subColor),
  }

  local top = pad + lineH + style.rowGap
  if level.loading then
    elements[#elements + 1] = text("Reading the world", pad, top, w - pad * 2, style.subColor)
  else
    for i, row in ipairs(rows) do
      -- Down each column and then across, so consecutive Spaces stay next to each other in reading order
      local x = pad + math.floor((i - 1) / perColumn) * (columnW + style.columnGap)
      local y = top + ((i - 1) % perColumn) * lineH
      local keyless = row.key == nil
      elements[#elements + 1] =
        text(row.key or "-", x, y, keyW, keyless and style.dimColor or style.keyColor, style.keyFont, "right")
      elements[#elements + 1] =
        text(labels[i], x + keyW + style.keyGap, y, labelW, keyless and style.dimColor or style.textColor)
      if subW > 0 and subs[i] then
        elements[#elements + 1] =
          text(subs[i], x + keyW + style.keyGap + labelW + style.subGap, y, subW, style.subColor)
      end
    end
  end

  canvas:frame({
    x = screenFrame.x + math.floor((screenFrame.w - w) / 2),
    y = screenFrame.y + screenFrame.h - h - style.bottomMargin,
    w = w,
    h = h,
  })
  canvas:replaceElements(table.unpack(elements))

  -- Already up: the elements have just been replaced under it, which is the whole update
  if self.panelShown then return self end
  if self.panelTimer then return self end
  -- Nothing is drawn for panelDelay seconds, so a sequence typed from memory finishes before the panel exists
  self.panelTimer = hs.timer.doAfter(self.panelDelay, function()
    self.panelTimer = nil
    if not self.modalActive then return end
    -- alpha() first, in case a previous hide left the canvas transparent
    pcall(canvas.alpha, canvas, 1)
    pcall(canvas.show, canvas, style.fadeInDuration)
    self.panelShown = true
  end)
  return self
end

function obj:hidePanel()
  if self.panelTimer then
    pcall(function()
      self.panelTimer:stop()
    end)
    self.panelTimer = nil
  end
  if self.noteTimer then
    pcall(function()
      self.noteTimer:stop()
    end)
    self.noteTimer = nil
  end
  if self.panel and self.panelShown then pcall(self.panel.hide, self.panel, self.panelStyle.fadeOutDuration) end
  self.panelShown = false
  return self
end

-- delete(), not hide(), so no NSWindow outlives a reload
function obj:discardPanel()
  self:hidePanel()
  if self.panel then
    pcall(self.panel.delete, self.panel)
    self.panel = nil
  end
  return self
end

-- A key with nothing behind it is swallowed and named in the footer rather than passed through: a modal that
-- leaks keystrokes into whatever is underneath is worse than one that says no
function obj:flash(note)
  if not self.level then return self end
  self.level.note = note
  self:drawPanel()
  if self.noteTimer then pcall(function()
    self.noteTimer:stop()
  end) end
  self.noteTimer = hs.timer.doAfter(PANEL_NOTE_SECONDS, function()
    self.noteTimer = nil
    if self.level and self.level.note == note then
      self.level.note = nil
      self:drawPanel()
    end
  end)
  return self
end

-- The modal

-- Every key the dispatcher can be handed. Bound once at start(), because hs.hotkey.modal only appends to its
-- key list and offers no unbind, so a keymap that changes per level has to change underneath a fixed set of
-- bindings rather than as one
local MODAL_KEYS = {}
for char in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do
  MODAL_KEYS[#MODAL_KEYS + 1] = char
end

local function firstFree(pool, taken)
  for char in pool:gmatch(".") do
    if not taken[char] then return char end
  end
  return nil
end

--- Yabai:assignKeys(rows) -> table
--- Method
--- Gives every selectable row a key and returns the key-to-row map the modal dispatches through.
---
--- Parameters:
---  * rows - A list of choice tables, as the operand builders and `Yabai:verbChoices()` produce
---
--- Returns:
---  * A table mapping each assigned key to its row
---
--- A row's own `hint` wins where it is still free -- the Space index, the display number, the verb's mnemonic -- and everything else takes the next unused letter from `Yabai.hintKeys`.
---
--- A row that cannot be chosen is left keyless rather than skipped over, so a Space in the middle of the list that macOS refuses to delete does not shift the digits of the ones after it. The keys on the panel keep matching the numbers in Mission Control.
function obj:assignKeys(rows)
  local taken, keymap = {}, {}
  for _, row in ipairs(rows or {}) do
    row.key = nil
    if row.valid ~= false and (row.value ~= nil or row.verbKey ~= nil) then
      local hint = row.hint
      if type(hint) == "string" and #hint == 1 and not taken[hint] then
        row.key = hint
      else
        row.key = firstFree(self.hintKeys, taken)
      end
      if row.key then
        taken[row.key] = true
        keymap[row.key] = row
      end
    end
  end
  return keymap
end

function obj:setLevel(level)
  level.rows = level.rows or {}
  level.keymap = self:assignKeys(level.rows)
  self.level = level
  return self:drawPanel()
end

-- The verb, then whatever has been picked since: what the panel reads back above the list
function obj:breadcrumb()
  local flow = self.flow
  if not flow then return "yabai" end
  local parts = { flow.verb.text }
  for _, label in ipairs(flow.trail or {}) do
    parts[#parts + 1] = label
  end
  return table.concat(parts, "  >  ")
end

--- Yabai:showLevel() -> self
--- Method
--- Rebuilds the panel for wherever the flow currently stands: the verb list, or one operand level.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- The modal's half of `Yabai:showStep()`, and the direct counterpart of `Yabai:showOperand()`. Both read the same flow and the same operand builders; only the rendering differs.
function obj:showLevel()
  local flow = self.flow
  -- Bumped before the read rather than after it: an operand list is three yabai queries deep, and an Escape
  -- arriving mid-read has to be able to invalidate an answer that has not come back yet
  self.gen = self.gen + 1
  local gen = self.gen
  local title = self:breadcrumb()

  local function fill(prompt, build)
    -- Up immediately, so a slow read shows a panel that is honest about waiting rather than the level just left
    self:setLevel({ title = title, prompt = prompt, loading = true })
    build(function(rows, err)
      if gen ~= self.gen or not self.modalActive then return end
      if not rows then
        self.logger.ef("could not build the %s list: %s", prompt, tostring(err))
        rows = { { text = "Could not read that list", subText = tostring(err), valid = false } }
      elseif #rows == 0 then
        rows = { { text = "Nothing to choose here", subText = "esc to go back", valid = false } }
      end
      self:setLevel({ title = title, prompt = prompt, rows = rows })
    end)
  end

  if not flow then
    fill("What should yabai do?", function(done)
      self:verbChoices(function(rows)
        done(rows, nil)
      end)
    end)
    return self
  end

  local kind = flow.verb.operands[flow.step]
  fill(PROMPTS[kind] or "?", function(done)
    OPERANDS[kind](self, flow.picks, done)
  end)
  return self
end

--- Yabai:onKey(char) -> self
--- Method
--- Routes one keystroke against the level currently on the panel.
---
--- Parameters:
---  * char - The single character the modal was handed
---
--- Returns:
---  * The Yabai object
---
--- Every letter and digit reaches this, bound or not. One with nothing behind it is swallowed and reported in the panel's footer, because a modal that lets a stray keystroke through into the window underneath is worse than one that says no.
function obj:onKey(char)
  if not self.modalActive then return self end
  self:touch()

  local level = self.level
  if not level then return self end
  -- A level whose list has not arrived has no keymap, so the keystroke is dropped rather than routed against
  -- the level it is in the middle of replacing
  if level.loading then return self:flash("still reading") end

  local row = level.keymap[char]
  if not row then return self:flash(string.format("%s is not bound here", char)) end

  if row.verbKey then
    if not self:startFlow(row.verbKey) then return self end
    return self:showLevel()
  end

  local outcome = self:record(row)
  if outcome == "run" then
    -- Left before running: every verb reports through hs.alert, and a panel still up over the alert reads as
    -- a modal that never ended
    self:exitModal()
    return self:runFlow()
  end
  if outcome == "next" then return self:showLevel() end
  return self
end

--- Yabai:searchHere() -> self
--- Method
--- Leaves the modal and reopens the same half-finished operation in the chooser.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- What `/` does. The two front ends push and pop the same flow, so the chooser opens on the level the modal was standing on with every pick so far intact, and a window that is easier to find by typing is found by typing.
function obj:searchHere()
  local flow = self.flow
  self:exitModal()
  if not flow then return self:show() end
  -- Restored after the exit, which takes down the panel but deliberately leaves the flow alone
  self.flow = flow
  return self:showOperand()
end

-- One long-lived timer whose start() restarts the countdown, rather than an hs.timer.doAfter per keystroke
function obj:touch()
  if not self.idleTimer then
    self.idleTimer = hs.timer.delayed.new(self.modalTimeout, function()
      if not self.modalActive then return end
      self.logger.d("modal timed out")
      self:exitModal()
    end)
  end
  -- Picks up a modalTimeout changed from the Console since the timer was built
  self.idleTimer:setDelay(self.modalTimeout)
  self.idleTimer:start()
  return self
end

-- Built once and kept: enter() and exit() enable and disable the bindings, so there is nothing to rebuild
function obj:buildModal()
  if self.modal then return self.modal end

  -- No entry hotkey of its own. Hotkeys belong in init.lua through bindHotkeys, and hs.hotkey.modal.new()
  -- with no key registers none
  local okNew, modal = pcall(hs.hotkey.modal.new)
  if not okNew or not modal then
    self:warnOnce("modal", "could not create the modal: %s", tostring(modal))
    return nil
  end

  for _, char in ipairs(MODAL_KEYS) do
    modal:bind({}, char, nil, function()
      self:onKey(char)
    end)
  end
  for _, char in ipairs({ "escape", "delete" }) do
    modal:bind({}, char, nil, function()
      self:touch()
      self:back()
    end)
  end
  modal:bind({}, "/", nil, function()
    self:searchHere()
  end)

  modal.entered = function()
    self.modalActive = true
    self:touch()
    self:showLevel()
  end
  modal.exited = function()
    self.modalActive = false
    -- Invalidates every read still in flight, so a list arriving after the modal has gone cannot put the
    -- panel back up over an empty screen
    self.gen = self.gen + 1
    self.level = nil
    if self.idleTimer then pcall(function()
      self.idleTimer:stop()
    end) end
    self:hidePanel()
  end

  self.modal = modal
  return modal
end

--- Yabai:enterModal() -> self
--- Method
--- Enters the modal at the verb list.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- What the leader hotkey is bound to. Any half-finished flow is abandoned, so this always starts from the verb list, and every letter and digit belongs to the modal until it is left: by finishing a verb, by Escape at the verb list, or by `Yabai.modalTimeout` seconds of doing nothing.
function obj:enterModal()
  local modal = self:buildModal()
  if not modal or self.modalActive then return self end
  self.flow = nil
  -- The two front ends cannot both be up: the chooser takes the keystrokes the modal is waiting for
  if self.chooser then pcall(self.chooser.hide, self.chooser) end
  pcall(modal.enter, modal)
  return self
end

--- Yabai:exitModal() -> self
--- Method
--- Leaves the modal and takes the panel down.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- Any half-finished flow is left alone rather than dropped, which is what lets `Yabai:searchHere()` hand it to the chooser mid-verb.
function obj:exitModal()
  if self.modal and self.modalActive then pcall(self.modal.exit, self.modal) end
  return self
end

--- Yabai:keymap() -> table
--- Method
--- Reports the keys the level currently on the panel answers to.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table mapping each live key to the row it would choose, empty outside the modal
---
--- For prodding from the Console: `hs.inspect(spoon.Yabai:keymap())` is the quickest way to see what a level assigned without reading the panel off the screen.
function obj:keymap()
  local out = {}
  for key, row in pairs(self.level and self.level.keymap or {}) do
    out[key] = row.text
  end
  return out
end

-- The menubar item

function obj:updateMenubar()
  if not self.menubarItem then return self end
  local total = 0
  for _, screen in ipairs(hs.screen.allScreens()) do
    local okU, uuid = pcall(screen.getUUID, screen)
    if okU and uuid then
      local okL, list = pcall(hs.spaces.spacesForScreen, uuid)
      if okL and type(list) == "table" then total = total + #list end
    end
  end
  self.menubarItem:setTitle(string.format("%s %d", self.menubarTitle, total))
  return self
end

-- Lifecycle

--- Yabai:start() -> self
--- Method
--- Builds the modal, creates the menubar item and starts watching for Space changes.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
function obj:start()
  if self.running then return self end
  self.running = true

  -- Bound here rather than on first use: 39 hotkey registrations is not something to do on a keypress
  self:buildModal()

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "yabai")
    if self.menubarItem then
      self.menubarItem:setClickCallback(function()
        self:show()
      end)
      self.menubarItem:setTooltip("Create, delete, reorder and focus Spaces; move windows between them")
      self:updateMenubar()
    else
      self:warnOnce("menubar", "could not create the menubar item")
    end
  end

  -- Only the count in the title depends on this, so a build without hs.spaces.watcher degrades to a stale number rather than failing
  if hs.spaces and hs.spaces.watcher then
    local okW, watcher = pcall(hs.spaces.watcher.new, function()
      self:updateMenubar()
    end)
    if okW and watcher then
      self.spaceWatcher = watcher
      pcall(watcher.start, watcher)
    end
  end

  if not self:yabaiBinary() then
    self.logger.w(
      "yabai is not available; reordering Spaces and moving them between displays are unavailable, "
        .. "and moving a window between Spaces falls back to hs.spaces, which macOS 15 ignores"
    )
  end

  self.logger.i("started")
  return self
end

--- Yabai:stop() -> self
--- Method
--- Tears down the modal, the panel, the menubar item, the watcher, the chooser and anything still in flight.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The Yabai object
---
--- Any hotkeys bound with `Yabai:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  if not self.running then return self end
  self.running = false

  -- First, before any handle is dropped: a yabai command or a verification poll still in flight would otherwise answer into a half-torn-down Spoon
  for job in pairs(self.yabaiTasks) do
    job.settled = true
    if job.timer then pcall(function()
      job.timer:stop()
    end) end
    if job.task then pcall(function()
      if job.task:isRunning() then job.task:terminate() end
    end) end
  end
  self.yabaiTasks = {}
  self:abortPolls()

  if self.flowTimer then
    pcall(function()
      self.flowTimer:stop()
    end)
    self.flowTimer = nil
  end
  self.flow = nil

  -- exit() before delete(), which does not call exited(): the panel and the idle timer hang off that callback
  if self.modal then
    if self.modalActive then pcall(self.modal.exit, self.modal) end
    pcall(self.modal.delete, self.modal)
    self.modal = nil
  end
  self.modalActive = false
  self.level = nil
  if self.idleTimer then
    pcall(function()
      self.idleTimer:stop()
    end)
    self.idleTimer = nil
  end
  self:discardPanel()

  if self.spaceWatcher then
    pcall(self.spaceWatcher.stop, self.spaceWatcher)
    self.spaceWatcher = nil
  end
  if self.menubarItem then
    pcall(self.menubarItem.delete, self.menubarItem)
    self.menubarItem = nil
  end
  if self.chooser then
    pcall(self.chooser.hide, self.chooser)
    pcall(self.chooser.delete, self.chooser)
    self.chooser = nil
  end

  self.byId = {}
  self.warned = {}
  -- Re-probed on the next start(), so installing yabai and reloading is enough to notice it
  self.yabaiResolved = nil

  self.logger.i("stopped")
  return self
end

--- Yabai:status() -> table
--- Method
--- Reports what the Spoon currently thinks the world looks like.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table carrying `running`, `yabai`, `modalActive`, `level`, `chooserVisible`, `verb`, `step`, `menubar` and `pendingTasks`
---
--- For prodding from the Console. `hs.inspect(spoon.Yabai:status())` is the quickest way to tell whether yabai was found and whether a flow is half-finished. `verb` and `step` read the same whichever front end put them there.
function obj:status()
  local pending = 0
  for _ in pairs(self.yabaiTasks) do
    pending = pending + 1
  end
  return {
    running = self.running,
    yabai = self:yabaiBinary() or false,
    modalActive = self.modalActive,
    level = self.level and self.level.prompt or nil,
    chooserVisible = self.chooser ~= nil and self.chooser:isVisible() or false,
    verb = self.flow and self.flow.verb.key or nil,
    step = self.flow and self.flow.step or nil,
    menubar = self.menubarItem ~= nil,
    pendingTasks = pending,
  }
end

--- Yabai:bindHotkeys(mapping) -> self
--- Method
--- Binds the hotkeys this Spoon offers.
---
--- Parameters:
---  * mapping - A table containing hotkey modifier/key details for the following items:
---    * modal - Enter the modal at the verb list; the leader for the whole grammar
---    * show - Open the chooser at the verb list, skipping the modal
---    * hide - Leave the modal and close the chooser, abandoning any half-finished flow
---
--- Returns:
---  * The Yabai object
---
--- For example: `spoon.Yabai:bindHotkeys({ modal = { { "cmd", "alt", "ctrl" }, "Y" } })`
---
--- One leader is enough: everything else is a letter inside the modal, and `/` reaches the chooser from any level, so binding `show` as well is optional. Every verb is also a method, so a favourite one can be given its own key directly: `hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "N", function() spoon.Yabai:createSpaceOnDisplay(1) end)`.
function obj:bindHotkeys(mapping)
  local spec = {
    hide = hs.fnutils.partial(self.hide, self),
    modal = hs.fnutils.partial(self.enterModal, self),
    show = hs.fnutils.partial(self.show, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

return obj
