-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === DeleteSpace ===
---
--- Lists Mission Control Spaces with their managed window counts, and deletes the one you pick.
---
--- One Space per invocation, deliberately. Both backends select the Space to destroy by its Mission
--- Control position rather than by any stable handle, and those positions renumber the moment a Space
--- goes away, so a batch loop is a loop whose target drifts under it. Deleting one and re-reading the
--- world is the only shape that cannot delete the wrong Space.
---
--- Prefers `yabai` for reading, which reports every Space and window over a socket without disturbing
--- anything. Deleting is separate: `yabai` can only destroy a Space through its scripting addition, so
--- where that is missing -- a common state on machines otherwise running yabai fine -- the delete falls
--- back to `hs.spaces`, which opens Mission Control and drives its remove button through Accessibility.
--- The two are mixed deliberately rather than chosen once: the fast reader is worth having even when it
--- cannot be the writer.
---
--- A Space macOS refuses to remove -- the active one, the last one on a screen, a fullscreen app -- is
--- listed anyway, with the reason, so the list matches what Mission Control shows.

local obj = {}
obj.__index = obj

obj.name = "DeleteSpace"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- DeleteSpace.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("DeleteSpace", "info")

-- Configuration

--- DeleteSpace.chooserRows
--- Variable
--- How many rows the chooser shows at once. Defaults to `10`.
obj.chooserRows = 10

--- DeleteSpace.chooserWidth
--- Variable
--- Chooser width as a percentage of the screen. Defaults to `40`.
obj.chooserWidth = 40

--- DeleteSpace.showInMenubar
--- Variable
--- Whether to place an item in the menubar. Defaults to `true`.
---
--- The item is a button rather than a menu: clicking it opens the same chooser the hotkey does, so there is one way to choose a Space and not two.
obj.showInMenubar = true

--- DeleteSpace.menubarTitle
--- Variable
--- Glyph shown in the menubar, with the current Space count appended. Defaults to a squared minus.
obj.menubarTitle = "⊟"

--- DeleteSpace.confirmWhenWindows
--- Variable
--- Whether to confirm before deleting a Space that still holds managed windows. Defaults to `true`.
---
--- An empty Space is deleted without a prompt. Deleting one that is not empty does not close its windows, it relocates them to another Space, which is recoverable but disorienting enough to be worth a keypress.
obj.confirmWhenWindows = true

--- DeleteSpace.countFloating
--- Variable
--- Whether floating windows count towards a Space's total. Defaults to `false`.
---
--- False matches what yabai calls a managed window. It also excludes sticky windows for free, since a sticky window is always floating, and a sticky window is on every Space rather than the one being deleted.
---
--- Ignored on the `hs.spaces` fallback, which cannot tell a floating window from a tiled one and so always reports every window on the Space.
obj.countFloating = false

--- DeleteSpace.useYabai
--- Variable
--- Whether to use yabai when it is installed. Defaults to `true`.
---
--- Set to `false` to exercise the `hs.spaces` fallback on a machine that has yabai.
obj.useYabai = true

--- DeleteSpace.yabaiPath
--- Variable
--- Absolute path to the yabai binary, or `nil` to search the usual install prefixes. Defaults to `nil`.
obj.yabaiPath = nil

--- DeleteSpace.yabaiTimeout
--- Variable
--- Seconds to wait for a yabai command before giving up on it. Defaults to `2`.
obj.yabaiTimeout = 2

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
obj.byId = {} -- last listed model, keyed on the stable Space id

local UNKNOWN_SCREEN = "Unknown display"

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

-- yabai

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
        "DeleteSpace.yabaiPath is %s, which is not an executable file; ignoring it",
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

-- Deliberately uncached. Every read here either builds a list the user is about to act on or re-checks one immediately before destroying something, and a stale answer in either place is the bug this Spoon exists to avoid
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
    done(decoded, nil)
  end)
end

-- The model

-- Space ids are stable, Mission Control positions are not. Everything the chooser hands back is an id, and the position is re-read from the id at the last possible moment
local function entryFor(id, index, label, screenName, count, isActive, isFullscreen)
  return {
    id = id,
    index = index,
    label = label,
    screenName = screenName,
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
        s["is-native-fullscreen"] == true
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

  for _, screen in ipairs(hs.screen.allScreens()) do
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
          local e = entryFor(id, i, nil, screenName, count, id == active, kind == "fullscreen")
          entries[#entries + 1] = e
          if not e.isFullscreen then perScreen[screenName] = (perScreen[screenName] or 0) + 1 end
        end
      end
    end
  end

  markBlocked(entries, perScreen)
  return entries
end

--- DeleteSpace:listSpaces(done) -> self
--- Method
--- Builds the current Space model and hands it to a callback.
---
--- Parameters:
---  * done - Called as `done(entries, err)`. `entries` is an array of tables carrying `id`, `index`, `label`, `screenName`, `managedCount`, `isActive`, `isFullscreen` and `blockedReason`, or nil and a message if the world could not be read
---
--- Returns:
---  * The DeleteSpace object
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
      local ok, entries = pcall(self.assembleSpaces, self)
      return done(ok and entries or nil, ok and nil or err)
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

-- The chooser

function obj:choicesFor(entries)
  if #entries == 0 then
    -- valid = false keeps the row from dismissing the chooser when it is selected
    return { { text = "No Spaces found", subText = "Neither yabai nor hs.spaces reported any", valid = false } }
  end

  local out = {}
  for _, e in ipairs(entries) do
    local name = e.label or string.format("Desktop %d", e.index)
    local detail = string.format("%s - %s", e.screenName, plural(e.managedCount, "managed window"))
    out[#out + 1] = {
      text = e.blockedReason and (name .. "  (" .. e.blockedReason .. ")") or name,
      subText = detail,
      -- Only plain values survive the trip into the chooser, and only the id is stable enough to act on later
      spaceId = e.blockedReason and nil or e.id,
      valid = e.blockedReason == nil,
    }
  end
  return out
end

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection
    if not choice or not choice.spaceId then return end
    self:deleteById(choice.spaceId)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  -- So that typing a screen name filters, even though the row itself shows the Space
  self.chooser:searchSubText(true)
  self.chooser:placeholderText("Delete a Space…")
  return self.chooser
end

--- DeleteSpace:show() -> self
--- Method
--- Opens the chooser, listing every Space with its managed window count.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeleteSpace object
---
--- Bound to a hotkey through `bindHotkeys`, and to the menubar item's click.
function obj:show()
  self:listSpaces(function(entries, err)
    if not entries then
      self.logger.ef("could not list Spaces: %s", tostring(err))
      hs.alert.show("DeleteSpace: could not list Spaces\n" .. tostring(err))
      return
    end
    self.byId = {}
    for _, e in ipairs(entries) do
      self.byId[e.id] = e
    end
    local chooser = self:ensureChooser()
    chooser:choices(self:choicesFor(entries))
    chooser:show()
  end)
  return self
end

-- Deletion

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

--- DeleteSpace:deleteById(id) -> self
--- Method
--- Deletes one Space, named by its stable Space id.
---
--- Parameters:
---  * id - The Space id, as reported by `DeleteSpace:listSpaces()` or `hs.spaces`
---
--- Returns:
---  * The DeleteSpace object
---
--- Re-reads every Space before acting. The id the chooser handed back is stable, but the Mission Control position both backends select on is not, and the list may be seconds old by the time a choice is made, so the position is resolved from the id here and the Space is re-checked for having become active or last-on-its-screen in the meantime.
function obj:deleteById(id)
  self:listSpaces(function(entries, err)
    if not entries then
      hs.alert.show("DeleteSpace: could not re-read Spaces\n" .. tostring(err))
      return
    end

    local entry
    for _, e in ipairs(entries) do
      if e.id == id then entry = e end
    end
    if not entry then return hs.alert.show("That Space is already gone") end
    if entry.blockedReason then return hs.alert.show("Cannot delete that Space: " .. entry.blockedReason) end

    local name = entry.label or string.format("Desktop %d", entry.index)
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
      if not ok then
        self.logger.ef("could not delete Space %d: %s", entry.id, tostring(why))
        return hs.alert.show(string.format("Could not delete %s\n%s", name, tostring(why)))
      end
      -- Nothing here trusts an exit code: the Space is gone when it is observed to be gone
      self:listSpaces(function(after)
        local survived = false
        for _, e in ipairs(after or {}) do
          if e.id == entry.id then survived = true end
        end
        if survived then
          hs.alert.show(string.format("%s is still there", name))
        else
          hs.alert.show(string.format("Deleted %s", name))
        end
        self:updateMenubar()
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

--- DeleteSpace:start() -> self
--- Method
--- Creates the menubar item and starts watching for Space changes.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeleteSpace object
function obj:start()
  if self.running then return self end
  self.running = true

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "deletespace")
    if self.menubarItem then
      self.menubarItem:setClickCallback(function()
        self:show()
      end)
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

  return self
end

--- DeleteSpace:stop() -> self
--- Method
--- Tears down the menubar item, the watcher and the chooser.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The DeleteSpace object
function obj:stop()
  if not self.running then return self end
  self.running = false

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
    self.chooser = nil
  end

  -- A task still running would call back into a stopped Spoon
  for job in pairs(self.yabaiTasks) do
    if job.timer then pcall(function()
      job.timer:stop()
    end) end
    if job.task then pcall(function()
      if job.task:isRunning() then job.task:terminate() end
    end) end
  end
  self.yabaiTasks = {}

  return self
end

--- DeleteSpace:bindHotkeys(mapping) -> self
--- Method
--- Binds the hotkeys this Spoon offers.
---
--- Parameters:
---  * mapping - A table with a `show` key, whose value is a `{ { modifiers }, key }` pair
---
--- Returns:
---  * The DeleteSpace object
function obj:bindHotkeys(mapping)
  local spec = {
    show = hs.fnutils.partial(self.show, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

return obj
