-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === DeminimizeWindow ===
---
--- Brings a minimized window back, onto the Space you are on rather than the one it left.
---
--- Clicking a Dock thumbnail restores a window to the Space it was minimized *from*, dragging
--- you to another desktop to go and look at it. This Spoon binds one hotkey to the obvious
--- behaviour instead: with one minimized window it restores it outright, with several it
--- opens an `hs.chooser`, with none it says so -- and the window arrives on the Space you are
--- already looking at.
---
--- The hard part is the *placing*, not the unminimizing. `hs.spaces.moveWindowToSpace()` has
--- done nothing since macOS 15 and returns `true` regardless, leaving yabai as the only thing
--- that can move a window between Spaces -- and yabai exits zero for commands it merely
--- accepted, so nothing here is believed on the strength of an exit code.
---
--- One rule shapes the Spoon: **place first, reveal second, and never reveal a window you
--- could not place.** A minimized window has no presence on screen, so moving it cannot pull
--- the user anywhere, and once it is verifiably here there is nowhere else to pull them to.
--- Revealing first inverts that and fails worse, leaving the window visible somewhere the
--- user cannot see. A ladder of five strategies sits behind the rule, each verified before
--- the next is tried; `DeminimizeWindow:diagnose()` prints what every source can see.

local obj = {}
obj.__index = obj

obj.name = "DeminimizeWindow"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- DeminimizeWindow.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("DeminimizeWindow", "info")

-- Configuration

--- DeminimizeWindow.useYabai
--- Variable
--- Whether yabai is used to move the restored window onto the current Space. Defaults to `true`.
---
--- With this off, or yabai absent, restores go through Accessibility alone, which cannot choose a Space: a window minimized elsewhere reappears there, and the Spoon says so rather than pretending it succeeded.
--- `hs.spaces.moveWindowToSpace()` is not an alternative; it has been a silent no-op since macOS 15.
obj.useYabai = true

--- DeminimizeWindow.yabaiPath
--- Variable
--- Absolute path to the yabai binary, or `nil` to probe the usual locations. Defaults to `nil`.
---
--- Only needed for an installation somewhere unusual. Homebrew on both architectures, nix-darwin and `~/.local/bin` are probed already.
obj.yabaiPath = nil

--- DeminimizeWindow.yabaiTimeout
--- Variable
--- Seconds any single yabai command may take before it is abandoned. Defaults to `1.5`.
obj.yabaiTimeout = 1.5

--- DeminimizeWindow.placeTimeout
--- Variable
--- Seconds spent confirming that a window really did land on the current Space. Defaults to `0.6`.
---
--- This is a confirmation window, not a delay. A move that worked is usually visible on the first poll.
obj.placeTimeout = 0.6

--- DeminimizeWindow.revealTimeout
--- Variable
--- Seconds spent confirming that a window really did come out of the Dock. Defaults to `1.0`.
---
--- Longer than `DeminimizeWindow.placeTimeout`: the un-minimize animation alone runs about half a second.
obj.revealTimeout = 1.0

--- DeminimizeWindow.pollInterval
--- Variable
--- Seconds between checks while confirming a step. Defaults to `0.12`.
---
--- Each yabai poll is a subprocess, which is what sets this floor. Checks that can be answered from an `hs.window` run at a quarter of this interval, since they cost nothing but a function call.
obj.pollInterval = 0.12

--- DeminimizeWindow.ladderDeadline
--- Variable
--- Seconds after which a restore still in flight is abandoned outright. Defaults to `8`.
---
--- A backstop for the busy flag rather than a timeout anybody should reach: without it, a restore stranded by an application that never answers would leave the hotkey permanently deaf.
obj.ladderDeadline = 8

--- DeminimizeWindow.skipChooserForSingle
--- Variable
--- Whether a lone minimized window is restored without showing the chooser. Defaults to `true`.
obj.skipChooserForSingle = true

--- DeminimizeWindow.focusAfterRestore
--- Variable
--- Whether the restored window is focused and raised once it has arrived. Defaults to `true`.
---
--- Reached only from success: focusing a window that never moved is what drags the user to its Space, so no failure path arrives here.
--- `yabai --deminimize` does not focus, so this is always an explicit extra step.
obj.focusAfterRestore = true

--- DeminimizeWindow.allowRevealFirst
--- Variable
--- Whether the reveal-first rungs of the ladder may run after placing has failed. Defaults to `true`.
---
--- The only rungs that can pull you to another Space, and they run only once placing has failed, when the choice is between that risk and not restoring the window at all.
--- Set to `false` for a Spoon that is structurally incapable of moving you, and that occasionally does nothing instead.
obj.allowRevealFirst = true

--- DeminimizeWindow.returnAfterSpaceChange
--- Variable
--- Whether to send you back if restoring a window changed the Space out from under you. Defaults to `true`.
---
--- Applies only after a fully successful restore, where the window is here and being moved was therefore gratuitous. A partial success is left alone: you may well be looking at your window.
obj.returnAfterSpaceChange = true

--- DeminimizeWindow.refuseFullscreenSpace
--- Variable
--- Whether to refuse to restore anything while the current Space is fullscreen. Defaults to `true`.
---
--- The window server will not accept a window into a native fullscreen Space, so every row of the chooser would fail on click. Refusing up front is the honest version of that.
obj.refuseFullscreenSpace = true

--- DeminimizeWindow.includeHidden
--- Variable
--- Whether windows of hidden applications (`cmd-H`) are offered alongside minimized ones. Defaults to `false`.
---
--- Hiding an application and minimizing a window are different states: a hidden application's windows report `is-hidden` and not `is-minimized`, never appear in `hs.window.minimizedWindows()`, and need `hs.application:unhide()` rather than unminimizing.
--- Off by default, which is the answer to "why is the window I pressed cmd-H on not in the list".
obj.includeHidden = false

--- DeminimizeWindow.includeScratchpad
--- Variable
--- Whether yabai scratchpad windows are offered. Defaults to `false`.
---
--- yabai keeps a scratchpad window minimized as its hidden state, so every scratchpad would otherwise appear here, and restoring one behind yabai's back desynchronises its bookkeeping. Use `yabai -m window --toggle <label>` for those.
obj.includeScratchpad = false

--- DeminimizeWindow.useAccessibilitySweep
--- Variable
--- Whether `hs.window.minimizedWindows()` is consulted as well as yabai. Defaults to `true`.
---
--- The two sources answer different questions: yabai is authoritative about Spaces and window state, while Accessibility is the only one that hands back a real `hs.window`, which is what unminimizing without yabai needs.
--- Turning this off makes `DeminimizeWindow:diagnose()` show what yabai alone can do.
obj.useAccessibilitySweep = true

--- DeminimizeWindow.showInMenubar
--- Variable
--- Whether a menubar item listing minimized windows is created. Defaults to `false`.
---
--- Off by default: the hotkey is the point, and two sibling Spoons already occupy the menu bar. Takes effect on the next `DeminimizeWindow:start()`.
obj.showInMenubar = false

--- DeminimizeWindow.menubarTitle
--- Variable
--- Text shown in the menubar when `DeminimizeWindow.showInMenubar` is on. Defaults to `'▣'`.
obj.menubarTitle = "▣"

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
--- Chooser rows are not truncated: it elides for itself, and a truncated row is one the search field cannot match against.
obj.titleMax = 60

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.chooser = nil
obj.menubarItem = nil

-- id -> { win, record, appName, title }; rebuilt per list, since picking from a stale one means acting on a window somebody already restored
obj.byId = {}

-- The restore in flight, and the busy flag, in one field. Non-nil means a ladder is walking
obj.pending = nil

obj.yabaiResolved = nil
obj.yabaiTasks = {}
obj.yabaiLastError = nil

-- Kept current by the watcher below rather than fetched on open, since hs.menubar wants its menu synchronously and every source here is asynchronous
obj.lastMenuItems = {}
obj.windowFilter = nil
obj.menuEvents = nil
obj.menuHandler = nil

-- Every outstanding hs.timer, so stop() can cancel a poll rather than let it fire into a torn-down Spoon
obj.timers = {}

obj.running = false
obj.warned = {}

-- No hs.window.filter, unlike SummonWindow: its visible=true default discards exactly these windows, and keeping them costs a permanent AX watcher across every app. No query cache either

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

-- #t is undefined for keys that are not a 1..n sequence, the shape of every table asked here
local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- Alphabetical, not most-recently-minimized: neither source records when a window was minimized
local function byAppThenTitle(a, b)
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

-- Remember a timer so stop() can cancel it, and forget it once it has fired
function obj:track(timer)
  if timer then self.timers[timer] = true end
  return timer
end

function obj:abortTimers()
  for timer in pairs(self.timers) do
    pcall(function()
      timer:stop()
    end)
  end
  self.timers = {}
  return self
end

-- `probe` gets a callback and must call it once with a boolean. Not hs.timer.waitUntil, since half the things waited on here are answers from a subprocess
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

-- yabai

-- Absent-tolerant throughout: yabai missing, stopped or refusing are ordinary outcomes, and the caller records a reason and moves to a rung that does not need it

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
        "DeminimizeWindow.yabaiPath is set to %s, which is not an executable file; ignoring it",
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

-- Raise the flag, THEN signal: terminating a task causes a completion callback rather than cancelling one, so the reverse order answers twice
local function settleAndKill(job)
  job.settled = true
  if job.timer then pcall(function()
    job.timer:stop()
  end) end
  if job.task then pcall(function()
    if job.task:isRunning() then job.task:terminate() end
  end) end
end

-- Calls done() exactly once, or not at all if torn down in flight; answering twice would walk the ladder twice and issue a --focus nobody asked for
function obj:yabaiRun(args, done)
  local bin = self:yabaiBinary()
  if not bin then return done(false, nil, "not installed") end

  local job = { task = nil, timer = nil, settled = false }
  self.yabaiTasks[job] = true

  local function finish(ok, out, err)
    if job.settled then return end
    settleAndKill(job)
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
--- Called from `DeminimizeWindow:stop()`. Each job is marked settled *before* its process is signalled: terminating a task causes a completion callback rather than cancelling one, so without the flag a config reload would answer into a half-torn-down Spoon and walk the ladder on into a `--focus`.
function obj:abortYabai()
  local n = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then
      settleAndKill(job)
      n = n + 1
    end
  end
  self.yabaiTasks = {}
  if n > 0 then self.logger.f("abandoned %d yabai command(s)", n) end
  return self
end

-- Calls done(data, err) exactly once, with data nil on failure
function obj:yabaiJSON(args, done)
  self:yabaiRun(args, function(ok, out, err)
    if not ok then
      self.yabaiLastError = tostring(err)
      -- A first query failing overwhelmingly means installed but not running. One line only
      self:warnOnce(
        "yabaiserver",
        "yabai is installed but not answering (%s); is the service running? "
          .. "Try `yabai --start-service`. Carrying on without it.",
        tostring(err)
      )
      return done(nil, err)
    end

    -- decode() raises on malformed input rather than returning nil
    local okJson, decoded = pcall(hs.json.decode, out or "")
    if not okJson or type(decoded) ~= "table" then
      self:warnOnce("yabaijson", "could not parse yabai query output; the yabai CLI may have changed shape")
      return done(nil, "unparseable output")
    end

    self.yabaiLastError = nil
    done(decoded, nil)
  end)
end

-- done(record, err) with the single object `query --windows --window <id>` returns; a window that has gone away exits non-zero, so this also catches one that died since being listed
function obj:windowRecord(winId, done)
  self:yabaiJSON({ "-m", "query", "--windows", "--window", fmtId(winId) }, function(data, err)
    if type(data) ~= "table" or type(data.id) ~= "number" then return done(nil, err or "no such window") end
    done(data, nil)
  end)
end

-- The current Space

-- Both numbering systems, since neither derives from the other: `index` is yabai's renumbering Mission Control index, `spaceId` hs.spaces' stable id, and swapping them acts on the wrong Space
function obj:currentSpace(done)
  local spaceId = nil
  if hs.spaces and hs.spaces.focusedSpace then
    local ok, id = pcall(hs.spaces.focusedSpace)
    if ok then spaceId = id end
  end

  if not self:yabaiBinary() then
    -- No index without yabai, and nothing to consume one: placing is what needs it
    if not spaceId then return done(nil, "neither yabai nor hs.spaces can say which Space this is") end
    return done({ index = nil, spaceId = spaceId, fullscreen = self:spaceIsFullscreen(spaceId) }, nil)
  end

  self:yabaiJSON({ "-m", "query", "--spaces", "--space" }, function(space, err)
    if type(space) ~= "table" or type(space.index) ~= "number" then
      if not spaceId then return done(nil, err or "could not determine the current Space") end
      return done({ index = nil, spaceId = spaceId, fullscreen = self:spaceIsFullscreen(spaceId) }, nil)
    end

    -- Usually mouse on one display, keyboard on another; yabai wins, since --space eats its index
    if spaceId and type(space.id) == "number" and math.floor(space.id) ~= spaceId then
      self:warnOnce(
        "spacemismatch",
        "yabai says the current Space is id %d and hs.spaces says %s; trusting yabai, "
          .. "since its index is what --space consumes",
        math.floor(space.id),
        tostring(spaceId)
      )
      spaceId = math.floor(space.id)
    end

    done({
      index = math.floor(space.index),
      spaceId = spaceId or (type(space.id) == "number" and math.floor(space.id)) or nil,
      fullscreen = space["is-native-fullscreen"] and true or false,
    }, nil)
  end)
end

-- Second opinion for the no-yabai path, where the Space object is not available
function obj:spaceIsFullscreen(spaceId)
  if not (spaceId and hs.spaces and hs.spaces.spaceType) then return false end
  local ok, kind = pcall(hs.spaces.spaceType, spaceId)
  return ok and kind == "fullscreen"
end

-- Finding minimized windows

-- Not just AXStandardWindow: Finder reports AXDialog on macOS 26 and palettes AXFloatingWindow. Still an allowlist, to keep out subrole-less surfaces and our own window
local RESTORABLE_SUBROLES = {
  AXStandardWindow = true,
  AXDialog = true,
  AXSystemDialog = true,
  AXFloatingWindow = true,
}

-- Only ever asked about yabai records; the Accessibility half came from minimizedWindows(), which has already answered the question
function obj:isRestorable(record)
  if type(record) ~= "table" then return false end
  if record.pid == hs.processInfo.processID then return false end

  -- Menulets, overlays and Dock surfaces would pad the list with unrestorable rows
  if record.role ~= "AXWindow" then return false end
  if not RESTORABLE_SUBROLES[record.subrole] then return false end

  -- Cannot co-exist with minimized, but a window server that disagrees would offer a doomed row
  if record["is-native-fullscreen"] then return false end

  if not self.includeScratchpad and type(record.scratchpad) == "string" and record.scratchpad ~= "" then
    return false
  end

  if record["is-minimized"] then return true end
  -- Hidden is a different state and is off by default; see DeminimizeWindow.includeHidden
  if self.includeHidden and record["is-hidden"] then return true end
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
--- Unions two sources by window id, the same `CGWindowID` in both, so the join needs no guessing. yabai is authoritative about window state and Spaces; Accessibility contributes the `hs.window` the yabai-free rungs need.
--- Either source alone yields a usable entry: a window only yabai can see is restorable by yabai only, and one only Accessibility can see cannot be placed with confidence.
function obj:collect(done)
  self:currentSpace(function(space, err)
    if not space then return done(nil, nil, err or "could not determine the current Space") end
    if space.fullscreen and self.refuseFullscreenSpace then
      return done(nil, space, "the current Space is fullscreen; the window server will not accept a window into one")
    end

    local function merge(windows)
      local byId = {}

      if type(windows) == "table" then
        for _, record in ipairs(windows) do
          if type(record) == "table" and type(record.id) == "number" and self:isRestorable(record) then
            byId[math.floor(record.id)] = { record = record }
          end
        end
      end

      if self.useAccessibilitySweep then
        local ok, wins = pcall(hs.window.minimizedWindows)
        if ok and type(wins) == "table" then
          for _, win in ipairs(wins) do
            local okId, id = pcall(win.id, win)
            -- Every accessor is pcall'd, so a window dying here costs a row, not the list
            local okApp, app = pcall(win.application, win)
            local mine = false
            if okApp and app then
              local okBundle, bundle = pcall(app.bundleID, app)
              mine = okBundle and bundle == hs.processInfo.bundleID
            end
            -- Dropped here as well as in isRestorable: this half never passes through it
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
          self:warnOnce("minimizedwindows", "hs.window.minimizedWindows failed (%s)", tostring(wins))
        end
      end

      local items = {}
      for id, slot in pairs(byId) do
        local record, win = slot.record, slot.win
        local appName, title

        if record then
          appName, title = record.app or "?", record.title or ""
        else
          local app = win and win:application()
          appName = (app and app:name()) or "?"
          local okTitle, t = pcall(win.title, win)
          title = (okTitle and t) or ""
        end

        slot.appName, slot.title = appName, title
        items[#items + 1] = {
          winId = id,
          appName = appName,
          title = title,
          minimized = record and record["is-minimized"] or (record == nil),
        }
      end

      table.sort(items, byAppThenTitle)
      self.byId = byId
      done(items, space, nil)
    end

    if not self:yabaiBinary() then return merge(nil) end
    self:yabaiJSON({ "-m", "query", "--windows" }, function(windows)
      merge(windows)
    end)
  end)
  return self
end

-- Chooser

function obj:choiceList(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      -- '(untitled)', not the app name, which would print twice and merge two untitled windows
      text = (item.title ~= "" and item.title) or "(untitled)",
      subText = item.appName,
      -- Only plain values survive the trip into the chooser and back; the rest is in byId
      winId = item.winId,
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection
    if not choice or not choice.winId then return end
    self:restoreById(choice.winId)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  -- So that typing an application name filters, even though the row itself shows the title
  self.chooser:searchSubText(true)
  self.chooser:placeholderText("Restore a minimized window…")
  return self.chooser
end

-- Verification

-- Nothing here trusts an exit code: a step is done when the world is observed to have changed

-- Has the window come out of the Dock?
function obj:awaitRevealed(ctx, timeout, done)
  if ctx.win then
    -- Free and synchronous, so it polls four times as often as the yabai path below
    return self:pollUntil(function(answer)
      local ok, minimized = pcall(ctx.win.isMinimized, ctx.win)
      answer(ok and not minimized)
    end, timeout, self.pollInterval / 4, done)
  end

  if not self:yabaiBinary() then return done(false) end
  self:pollUntil(function(answer)
    self:windowRecord(ctx.winId, function(record)
      answer(record ~= nil and not record["is-minimized"])
    end)
  end, timeout, self.pollInterval, done)
end

-- Not hs.spaces.windowSpaces(), which reports a MINIMIZED window as being here wherever it was minimized from; it is trustworthy once visible, hence the no-yabai branch below
function obj:awaitPlaced(ctx, timeout, done)
  -- Already here by definition: a sticky window reports one `space` but appears on every one
  if ctx.record and ctx.record["is-sticky"] then return done(true) end

  if self:yabaiBinary() and ctx.index then
    return self:pollUntil(function(answer)
      self:windowRecord(ctx.winId, function(record)
        if not record then return answer(false) end
        ctx.record = record -- sticky-ness and ax-reference can change under us
        answer(record["is-sticky"] and true or record.space == ctx.index)
      end)
    end, timeout, self.pollInterval, done)
  end

  -- No yabai; only meaningful once out of the Dock, and only reached from the reveal-first rung
  if not (ctx.win and ctx.revealed and ctx.spaceId and hs.spaces and hs.spaces.windowSpaces) then return done(false) end
  self:pollUntil(function(answer)
    local ok, spaces = pcall(hs.spaces.windowSpaces, ctx.win)
    answer(ok and type(spaces) == "table" and hs.fnutils.contains(spaces, ctx.spaceId))
  end, timeout, self.pollInterval, done)
end

-- Three outcomes: "revealed but elsewhere" is a partial success, where "still in the Dock" is a rung that did nothing and needs the next
function obj:verifyRestored(ctx, done)
  self:awaitRevealed(ctx, self.revealTimeout, function(revealed)
    if not revealed then return done("still-minimized") end
    ctx.revealed = true
    self:awaitPlaced(ctx, self.placeTimeout, function(placed)
      ctx.placed = placed
      done(placed and "ok" or "unplaced")
    end)
  end)
end

-- Restore steps

-- Not in STEPS, which it would strand by never calling next(). Clearing placeFailed is the point: a move that failed from the Dock says nothing about one made now the window is visible
local function markRevealed(ctx)
  ctx.revealed = true
  ctx.placeFailed = false
end

-- Each step is fn(self, ctx, next) calling next(ok, err) exactly once; the ladder below is nothing but different orderings of these five
local STEPS = {}

-- Place while still minimized if at all possible. Memoised both ways, so the three place-first rungs fail fast rather than each paying for the same doomed move
function STEPS.place(self, ctx, next)
  if ctx.placed then return next(true) end
  if ctx.placeFailed then return next(false, "placing already failed for this window") end

  if not (self:yabaiBinary() and ctx.index) then
    -- Nothing here moves a window between Spaces, but if it is out of the Dock we can report where it landed -- and a window minimized on this Space is already where it was wanted
    if ctx.revealed then
      return self:awaitPlaced(ctx, self.placeTimeout, function(landed)
        ctx.placed = landed
        if landed then return next(true) end
        ctx.placeFailed = true
        next(false, "no yabai; the window came back on the Space it was minimized from")
      end)
    end
    ctx.placeFailed = true
    return next(false, "no yabai; nothing on this machine can move a window between Spaces")
  end

  -- Sticky windows are already everywhere, and --space would pin them to one; only the move is skipped
  if ctx.record and ctx.record["is-sticky"] then
    ctx.placed = true
    return next(true)
  end

  -- Already here: skipped as a wasted subprocess, as the shape yabai issue #382 mishandles for minimized windows, and so the commonest case issues one --deminimize that cannot move anyone
  if ctx.record and ctx.record.space == ctx.index then
    ctx.placed = true
    return next(true)
  end

  self:yabaiRun({ "-m", "window", fmtId(ctx.winId), "--space", tostring(ctx.index) }, function(ok, _, err)
    if not ok then
      ctx.placeFailed = true
      return next(false, "yabai refused the move (" .. tostring(err) .. ")")
    end

    -- Exit zero means accepted, never moved, so confirm positively; failing here is safe, the window being still in the Dock, which is why the ladder places before it reveals
    self:awaitPlaced(ctx, self.placeTimeout, function(landed)
      ctx.placed, ctx.placeFailed = landed, not landed
      if landed then return next(true) end
      next(false, "yabai accepted the move but the window is still not on this Space")
    end)
  end)
end

-- Reveal, quietly, via yabai
function STEPS.deminimize(self, ctx, next)
  if not self:yabaiBinary() then return next(false, "no yabai") end
  -- Inverted grammar: --deminimize takes its window selector AFTER the flag, unlike --space
  self:yabaiRun({ "-m", "window", "--deminimize", fmtId(ctx.winId) }, function(ok, _, err)
    if not ok then return next(false, "yabai refused to deminimize (" .. tostring(err) .. ")") end
    markRevealed(ctx)
    next(true)
  end)
end

-- An independent path: yabai may hold a stale AXUIElement for a window Hammerspoon can address
function STEPS.unminimize(self, ctx, next)
  if not ctx.win then return next(false, "no window object") end

  -- A window can be hidden AND minimized, in which case unminimizing alone leaves it invisible
  if self.includeHidden then
    local app = ctx.win:application()
    if app then pcall(app.unhide, app) end
  end

  local ok, err = pcall(ctx.win.unminimize, ctx.win)
  if not ok then return next(false, "unminimize threw (" .. tostring(err) .. ")") end
  markRevealed(ctx)
  next(true)
end

-- --focus restores AND focuses, the strongest reveal and the most dangerous command here, so it is only ever reached through requirePlaced
function STEPS.focus(self, ctx, next)
  if not self:yabaiBinary() then return next(false, "no yabai") end
  self:yabaiRun({ "-m", "window", "--focus", fmtId(ctx.winId) }, function(ok, _, err)
    if not ok then return next(false, "yabai refused to focus (" .. tostring(err) .. ")") end
    markRevealed(ctx)
    next(true)
  end)
end

-- The gate. Fails the rung unless placement has been positively confirmed
function STEPS.requirePlaced(self, ctx, next)
  if ctx.placed then return next(true) end
  next(false, "placement unconfirmed; going further could move the user off their Space")
end

-- The restore ladder

-- The control flow: the first three rungs place and differ only in how they reveal, and only once placing has genuinely failed do the last two invert that
local ENGINES = {
  {
    name = "place+deminimize",
    steps = { "place", "deminimize" },
    available = function(self, ctx)
      if not self:yabaiBinary() then return false, "yabai unavailable" end
      -- No AXUIElement means both reveal verbs fail; skipping saves a second of polling
      if ctx.record and ctx.record["has-ax-reference"] == false then
        return false, "yabai has no accessibility reference"
      end
      return true
    end,
  },
  {
    name = "place+unminimize",
    steps = { "place", "unminimize" },
    available = function(self, ctx)
      if not ctx.win then return false, "no window object" end
      return true
    end,
  },
  {
    -- Between the two rather than in available(): placing is memoised, so the gate only becomes a meaningful question once this rung's place step has run
    name = "place+focus",
    steps = { "place", "requirePlaced", "focus" },
    available = function(self)
      if not self:yabaiBinary() then return false, "yabai unavailable" end
      return true
    end,
  },
  {
    name = "deminimize+place",
    steps = { "deminimize", "place", "requirePlaced" },
    available = function(self, ctx)
      if not self:yabaiBinary() then return false, "yabai unavailable" end
      if not self.allowRevealFirst then return false, "allowRevealFirst is off" end
      if not ctx.placeFailed then return false, "placing has not failed, so revealing first is not warranted" end
      return true
    end,
  },
  {
    -- Last, and the whole ladder without yabai: placing degrades to a report, so this rung can reveal while honestly failing to place
    name = "unminimize+place",
    steps = { "unminimize", "place" },
    available = function(self, ctx)
      if not ctx.win then return false, "no window object" end
      if self:yabaiBinary() and not self.allowRevealFirst then return false, "allowRevealFirst is off" end
      return true
    end,
  },
}

-- A recursion over the list rather than nested callbacks, so nesting stays one level deep
function obj:runSteps(ctx, names, done)
  local function step(i)
    -- Needed here as well as in runLadder: without it the watchdog stops only the NEXT rung, while this one issues --space / --deminimize / --focus seconds after the user was told it failed
    if self.pending ~= ctx then return end

    local name = names[i]
    if not name then return done(true, nil) end
    local fn = STEPS[name]
    if not fn then return done(false, "unknown step " .. tostring(name)) end

    -- Exactly one answer per step: these run in timer and task callbacks, where a throw is swallowed, so a step dying mid-flight would strand the ladder with no alert ever shown
    local answered = false
    local function reply(ok, err)
      if answered then return end
      answered = true
      -- Consumed but not acted on once abandoned, which would overwrite the watchdog's outcome
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
    -- The Spoon was stopped, or the deadline fired, while this rung was in flight
    if self.pending ~= ctx then return end

    local engine = ENGINES[i]
    if not engine then return self:finishRestore(ctx, nil, table.concat(reasons, "; ")) end

    local okAvail, available, whyNot = pcall(engine.available, self, ctx)
    if not okAvail or not available then
      reasons[#reasons + 1] = engine.name .. ": " .. tostring(whyNot or available or "unavailable")
      return attempt(i + 1)
    end

    self:runSteps(ctx, engine.steps, function(ok, err)
      if self.pending ~= ctx then return end

      if not ok then
        reasons[#reasons + 1] = string.format("%s: %s", engine.name, tostring(err or "failed"))
        return attempt(i + 1)
      end

      self:verifyRestored(ctx, function(outcome)
        if self.pending ~= ctx then return end
        if outcome == "ok" then return self:finishRestore(ctx, engine.name, nil) end

        if outcome == "unplaced" then
          -- One corrective move: the window is visible now, so this is a genuinely new attempt
          ctx.placeFailed = false
          return self:runSteps(ctx, { "place" }, function()
            if self.pending ~= ctx then return end
            self:awaitPlaced(ctx, self.placeTimeout, function(landed)
              if self.pending ~= ctx then return end
              ctx.placed = landed
              if landed then return self:finishRestore(ctx, engine.name, nil) end
              reasons[#reasons + 1] = engine.name .. ": revealed, but on another Space"
              attempt(i + 1)
            end)
          end)
        end

        reasons[#reasons + 1] = engine.name .. ": issued, but the window stayed minimized"
        attempt(i + 1)
      end)
    end)
  end

  attempt(1)
  return self
end

-- Returns false when this ctx no longer holds the flag, which is how every ladder callback tells it was abandoned. Released here and nowhere else: leaking it leaves the hotkey deaf
function obj:clearPending(ctx)
  if self.pending ~= ctx then return false end
  self.pending = nil
  if ctx.watchdog then
    pcall(function()
      ctx.watchdog:stop()
    end)
    self.timers[ctx.watchdog] = nil
    ctx.watchdog = nil
  end
  return true
end

-- The single exit from a ladder that ran; focus is applied only to a full success
function obj:finishRestore(ctx, engine, why)
  if not self:clearPending(ctx) then return self end

  local label = string.format("%s - %s", ctx.appName, truncate(ctx.title, self.titleMax))

  if engine and ctx.placed then
    if self.focusAfterRestore then
      -- yabai first here, the reverse of everywhere else and measured: on macOS 26 focus() returns cleanly without changing the frontmost app, where `yabai --focus` always moves the keyboard
      if self:yabaiBinary() then
        self:yabaiRun({ "-m", "window", "--focus", fmtId(ctx.winId) }, function(ok, _, err)
          if not ok then self.logger.f("could not focus window %s: %s", tostring(ctx.winId), tostring(err)) end
        end)
      elseif ctx.win then
        -- Raised first, so it is frontmost WITHIN its app before that app comes forward
        pcall(ctx.win.raise, ctx.win)
        pcall(ctx.win.focus, ctx.win)
        local okApp, app = pcall(ctx.win.application, ctx.win)
        if okApp and app then pcall(app.activate, app) end
      end
    end

    -- Being moved anyway means something switched Spaces gratuitously; the window is here
    if self.returnAfterSpaceChange and ctx.spaceId and hs.spaces and hs.spaces.gotoSpace then
      local ok, now = pcall(hs.spaces.focusedSpace)
      if ok and now and now ~= ctx.spaceId then
        self.logger.wf(
          "restoring moved the current Space to %s; going back to %s",
          tostring(now),
          tostring(ctx.spaceId)
        )
        pcall(hs.spaces.gotoSpace, ctx.spaceId)
      end
    end

    self.logger.f("restored %s via %s", label, engine)
    return self
  end

  if ctx.revealed then
    -- Partial: out of the Dock but elsewhere, so emphatically not focused, and no trip back
    self.logger.wf("restored %s, but could not place it on this Space: %s", label, tostring(why or "unknown"))
    hs.alert.show(string.format("Restored %s, but it stayed on another Space", ctx.appName), self.alertDuration + 1)
    return self
  end

  self.logger.wf("could not restore %s: %s", label, tostring(why or "no method available"))
  hs.alert.show(string.format("Could not restore %s", ctx.appName), self.alertDuration + 1)
  return self
end

-- Entry points

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
--- The id must have come from a `DeminimizeWindow:collect()` pass, since everything else known about the window is looked up in the map that call builds.
--- The target Space and the window's state are re-read here rather than taken from the list, because a chooser can sit open across a Space change.
function obj:restoreById(winId)
  local slot = self.byId[winId]
  if not slot then
    self.logger.wf("window %s is not in the current list", tostring(winId))
    hs.alert.show("DeminimizeWindow: that window is no longer available", self.alertDuration)
    return self
  end

  if self.pending then
    self.logger.f("already restoring window %s; ignoring", tostring(self.pending.winId))
    return self
  end

  -- Claimed synchronously, before the asynchronous queries below: a second press between them would find `pending` nil and start a parallel ladder on the same window
  local ctx = {
    winId = winId,
    win = slot.win,
    record = slot.record,
    appName = slot.appName or "?",
    title = slot.title or "",
    placed = false,
    placeFailed = false,
    revealed = false,
  }
  self.pending = ctx
  ctx.watchdog = self:track(hs.timer.doAfter(self.ladderDeadline, function()
    if self.pending ~= ctx then return end
    self.logger.wf(
      "restore of window %s did not finish within %ss; abandoning it",
      tostring(winId),
      tostring(self.ladderDeadline)
    )
    self:finishRestore(ctx, nil, "timed out")
  end))

  -- Pre-flight refusals carry a specific reason, so they bypass finishRestore's generic message
  local function giveUp(why)
    if not self:clearPending(ctx) then return end
    self.logger.wf("not restoring window %s: %s", tostring(winId), tostring(why))
    hs.alert.show("DeminimizeWindow: " .. tostring(why), self.alertDuration + 1)
  end

  self:currentSpace(function(space, err)
    if self.pending ~= ctx then return end
    if not space then return giveUp(err or "could not determine the current Space") end
    if space.fullscreen and self.refuseFullscreenSpace then return giveUp("cannot restore into a fullscreen Space") end

    ctx.index = space.index
    ctx.spaceId = space.spaceId

    local function begin(record)
      if self.pending ~= ctx then return end
      ctx.record = record or ctx.record

      -- Restored by somebody else while the chooser was open; place and focus it anyway
      if ctx.record and ctx.record["is-minimized"] == false then
        self.logger.f("window %s is already out of the Dock; placing it only", tostring(winId))
        ctx.revealed = true
      end

      self:runLadder(ctx)
    end

    -- Also how a window that died between listing and picking is caught: yabai exits non-zero
    if not self:yabaiBinary() then return begin(nil) end
    self:windowRecord(winId, function(record, recErr)
      if self.pending ~= ctx then return end
      if not record then
        -- An hs.window we hold proves it exists whatever yabai thinks, so only absence is fatal
        if not slot.win then
          self.logger.wf("window %s is gone (%s)", tostring(winId), tostring(recErr))
          return giveUp("that window is no longer available")
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
--- With no minimized windows this shows a brief alert, with exactly one it restores it outright, with more it opens the chooser. See `DeminimizeWindow.skipChooserForSingle`.
--- This is the method `DeminimizeWindow:bindHotkeys()` binds; pressing the hotkey while the chooser is open closes it again.
function obj:restore()
  if self.chooser and self.chooser:isVisible() then return self:hide() end

  if self.pending then
    self.logger.f("already restoring window %s; ignoring", tostring(self.pending.winId))
    return self
  end

  self:collect(function(items, _, err)
    if err then
      self.logger.wf("could not build the window list: %s", tostring(err))
      hs.alert.show("DeminimizeWindow: " .. tostring(err), self.alertDuration + 1)
      return
    end

    if #items == 0 then return hs.alert.show("No minimized windows", self.alertDuration) end
    if #items == 1 and self.skipChooserForSingle then return self:restoreById(items[1].winId) end

    local chooser = self:ensureChooser()
    -- Static table, so the list rebuilds on open; a callback caches until refreshChoicesCallback()
    chooser:choices(self:choiceList(items))
    chooser:query("")
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
--- Unlike `DeminimizeWindow:restore()` this never restores anything by itself, so it is the method to bind if you would always rather see the list first.
function obj:show()
  self:collect(function(items, _, err)
    if err then
      hs.alert.show("DeminimizeWindow: " .. tostring(err), self.alertDuration + 1)
      return
    end

    local chooser = self:ensureChooser()
    if #items == 0 then
      -- valid = false keeps the row from dismissing the chooser when it is selected
      chooser:choices({
        { text = "No minimized windows", subText = "Nothing is in the Dock", valid = false },
      })
    else
      chooser:choices(self:choiceList(items))
    end
    chooser:query("")
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

-- Menubar

-- Callback-driven, since hs.menubar wants its menu synchronously: refreshed when asked for, showing the previous list until the new one lands
function obj:buildMenu()
  local items = self.lastMenuItems or {}
  local menu = {}

  if #items == 0 then
    menu[#menu + 1] = { title = "No minimized windows", disabled = true }
  else
    for _, item in ipairs(items) do
      local id = item.winId
      menu[#menu + 1] = {
        title = string.format("%s - %s", item.appName, truncate(item.title, self.titleMax)),
        fn = function()
          self:restoreById(id)
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

-- The menu cannot wait for a subprocess: popupMenu() returns immediately rather than blocking until close, so the set-menu-then-pop trick would tear it down as fast as it appeared
function obj:refreshMenu()
  if not self.menubarItem then return self end
  self:collect(function(items)
    self.lastMenuItems = items or {}
  end)
  return self
end

-- Spoon lifecycle

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
--- Deliberately starts nothing. The chooser and the menubar item both belong to `DeminimizeWindow:start()`.
--- Deliberately empty rather than re-initialising state: `hs.loadSpoon()` reaches `init()` through `require()`, which returns a cached object on a second load, so clearing state here would strand a live chooser.
function obj:init()
  return self
end

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
--- Calling this on an already-started Spoon restarts it cleanly.
--- Nothing polls and no timer runs while idle. The window list is built on demand, when the hotkey is pressed or the menu is pulled down.
--- Warns via `hs.alert` if Accessibility permission has not been granted, since nothing works without it.
function obj:start()
  if self.running then self:stop() end

  self.byId = {}
  self.lastMenuItems = {}

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "deminimizewindow")
    if self.menubarItem then
      self.menubarItem:setTitle(self.menubarTitle)
      self.menubarItem:setTooltip("Restore a minimized window onto this Space")
      -- Wrapped: a throw inside the menu callback would leave a dead menubar icon
      self.menubarItem:setMenu(function()
        local ok, menu = pcall(self.buildMenu, self)
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

      -- Alive only while the menubar is, hence that being off by default. setDefaultFilter{} is load-bearing: a stock filter is visible=true and never reports a window minimizing
      self.windowFilter = hs.window.filter.new()
      self.windowFilter:setDefaultFilter({})
      self.windowFilter:setCurrentSpace(nil)
      self.windowFilter:rejectApp("Hammerspoon")
      self.menuEvents = {
        hs.window.filter.windowMinimized,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowDestroyed,
      }
      self.menuHandler = function()
        self:refreshMenu()
      end
      self.windowFilter:subscribe(self.menuEvents, self.menuHandler)

      self:refreshMenu()
    else
      self.logger.w("could not create the menubar item")
    end
  end

  self.running = true

  if not hs.accessibilityState() then
    hs.alert.show("DeminimizeWindow needs Accessibility permission")
    self.logger.w("accessibility permission not granted; nothing will work until it is")
  end
  if not self:yabaiBinary() then
    self.logger.w(
      "yabai is not available, so restored windows cannot be placed on the current Space; "
        .. "they will reappear wherever they were minimized"
    )
  end

  self.logger.i("started")
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
--- Any hotkeys bound with `DeminimizeWindow:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped: a yabai command in flight would otherwise answer into a half-torn-down Spoon and walk the ladder on into a --focus
  self:abortYabai()
  self:abortTimers()
  self.pending = nil

  -- By the exact (events, fn) pair, so the refcounted global watcher is actually released
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
  -- Re-probed on the next start(), so installing yabai and reloading is enough to notice it
  self.yabaiResolved = nil
  self.running = false
  self.logger.i("stopped")
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
--- For example: `spoon.DeminimizeWindow:bindHotkeys({ restore = { { "cmd", "alt", "ctrl" }, "M" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    restore = hs.fnutils.partial(self.restore, self),
    show = hs.fnutils.partial(self.show, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

-- Diagnostics

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
--- `yabai` is the resolved binary path, or `false` when yabai is off or not installed. It says nothing about whether the yabai *service* is running; only `DeminimizeWindow:diagnose()` answers that.
--- `listed` counts the windows in the most recent list, which may be stale; the list is never reused across a press.
function obj:status()
  local busy = 0
  for job in pairs(self.yabaiTasks) do
    if not job.settled then busy = busy + 1 end
  end

  return {
    running = self.running,
    menubar = self.menubarItem ~= nil,
    chooserVisible = self.chooser ~= nil and self.chooser:isVisible() or false,
    restoring = self.pending and self.pending.winId or false,
    yabai = self:yabaiBinary() or false,
    yabaiBusy = busy,
    yabaiLastError = self.yabaiLastError,
    listed = countKeys(self.byId),
    timers = countKeys(self.timers),
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
--- Asynchronous, because it asks yabai. The report is printed to the Console when it arrives, so calling this bare from the Console is the normal way to use it.
--- The decisive line is the per-window one: a row tagged only `yabai` has no `hs.window`, so the Accessibility rungs do not apply to it, and a row tagged only `ax` cannot be placed with confidence.
function obj:diagnose(done)
  local out = {}
  local function say(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  end

  local function finish()
    local text = table.concat(out, "\n")
    print(text)
    if done then pcall(done, text) end
  end

  say("DeminimizeWindow diagnosis")
  say("")
  say("  running               %s", tostring(self.running))
  say("  accessibility         %s", tostring(hs.accessibilityState()))
  say(
    "  yabai                 %s",
    tostring(self:yabaiBinary() or (not self.useYabai and "(turned off)" or "(not installed)"))
  )
  say("  hs.spaces             %s", tostring(hs.spaces ~= nil and hs.spaces.focusedSpace ~= nil))
  say("  minimizedWindows      %s", tostring(hs.window.minimizedWindows ~= nil))

  -- Counted before the union, so a disagreement between sources is visible, not merged away
  local axSet, axN = {}, 0
  local okAx, wins = pcall(hs.window.minimizedWindows)
  if okAx and type(wins) == "table" then
    for _, win in ipairs(wins) do
      local okId, id = pcall(win.id, win)
      if okId and id then
        axSet[math.floor(id)] = true
        axN = axN + 1
      end
    end
  end

  self:currentSpace(function(space, err)
    say("")
    if space then
      say(
        "Current Space:          yabai index=%s   hs.spaces id=%s   fullscreen=%s",
        tostring(space.index),
        tostring(space.spaceId),
        tostring(space.fullscreen)
      )
    else
      say("Current Space:          UNKNOWN (%s)", tostring(err))
    end

    self:collect(function(items, _, collectErr)
      say("")
      say("Sources:")
      say("  hs.window.minimizedWindows   %4d window(s)", axN)

      if not self:yabaiBinary() then
        say("  yabai                        (unavailable) - restored windows cannot be placed")
      elseif self.yabaiLastError then
        -- A service that is down looks like one not yet asked, and the fixes differ
        say("  yabai                        NOT ANSWERING (%s) - try `yabai --start-service`", self.yabaiLastError)
      else
        say("  yabai                        answering; %d window(s) in the merged list", countKeys(self.byId))
      end

      say("")
      if collectErr then
        say("Restorable: none (%s)", tostring(collectErr))
        return finish()
      end

      items = items or {}
      say("Restorable: %d window(s)", #items)
      for _, item in ipairs(items) do
        local slot = self.byId[item.winId] or {}
        local tags = {}
        if axSet[item.winId] then tags[#tags + 1] = "ax" end
        if slot.record then tags[#tags + 1] = "yabai" end
        say(
          "  [%-9s] %-22s %-52s %s",
          table.concat(tags, "+"),
          item.appName,
          truncate(item.title, 52),
          slot.record
              and string.format(
                "space=%s sticky=%s ax-ref=%s",
                tostring(slot.record.space),
                tostring(slot.record["is-sticky"]),
                tostring(slot.record["has-ax-reference"])
              )
            or "no yabai record"
        )
      end

      if #items == 0 then
        say("")
        say("Nothing to restore. If a window really is in the Dock, check the sources above:")
        say("a zero on both lines means macOS is not reporting it as minimized at all, and a")
        say("window hidden with cmd-H is not minimized -- see DeminimizeWindow.includeHidden.")
      end

      finish()
    end)
  end)

  return self
end

return obj
