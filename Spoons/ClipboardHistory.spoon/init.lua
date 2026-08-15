--- === ClipboardHistory ===
---
--- A searchable clipboard history that survives a Hammerspoon restart.
---
--- macOS keeps exactly one clipboard entry, so anything copied over is gone. This Spoon
--- watches the pasteboard, keeps the last `ClipboardHistory.historySize` text entries, and
--- offers them back through a chooser or a menubar menu. Selecting an entry puts it back on
--- the clipboard; pasting stays a manual cmd+v.
---
--- The history is written to `hs.settings`, which means it lands on disk in plain text. Two
--- things guard against that becoming a liability: entries whose pasteboard types are marked
--- concealed or transient (see `ClipboardHistory.ignoredIdentifiers`) are never recorded,
--- and recording can be paused outright from the menu. Neither is a guarantee -- the markers
--- are advisory and only as good as the app that sets them -- so treat the history as
--- readable by anything that can read your home directory.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = 'ClipboardHistory'
obj.version = '1.0'
obj.author = 'Vladislav Doster <mvdoster@gmail.com>'
obj.license = 'MIT - https://opensource.org/licenses/MIT'

--- ClipboardHistory.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('ClipboardHistory', 'info')

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

--- ClipboardHistory.historySize
--- Variable
--- How many entries to keep. Defaults to `50`.
---
--- Notes:
---  * The whole history is serialised on every save, so this trades directly against how much work a save is. Several hundred entries of ordinary text is still cheap; several hundred entries of multi-kilobyte text is not.
obj.historySize = 50

--- ClipboardHistory.maxItemSize
--- Variable
--- Bytes; a copy larger than this is not recorded at all. Defaults to `102400` (100 KB).
---
--- Notes:
---  * This is a storage guard, not a display one -- oversized entries are dropped rather than truncated, because the point is to keep them out of the settings file. Truncation for display is `ClipboardHistory.labelLength` and applies to entries that were recorded.
obj.maxItemSize = 100 * 1024

--- ClipboardHistory.labelLength
--- Variable
--- Maximum number of characters of an entry shown in a chooser row or menu item. Defaults to `80`.
---
--- Notes:
---  * Only affects display. The full text is always what gets put back on the clipboard.
obj.labelLength = 80

--- ClipboardHistory.menuItems
--- Variable
--- How many recent entries to list inline in the menubar menu. Defaults to `10`.
---
--- Notes:
---  * The menu is for the last few things you copied; `Search…` opens the chooser over the whole history.
obj.menuItems = 10

--- ClipboardHistory.saveDelay
--- Variable
--- Seconds to wait after the last change before writing the history to `hs.settings`. Defaults to `5`.
---
--- Notes:
---  * `hs.settings.set` serialises synchronously, so writing on every copy would make a burst of copies stutter. Changes are coalesced behind this delay instead, and flushed by `ClipboardHistory:stop()` so a config reload does not lose the tail.
---  * The cost of the delay is that entries copied in the last few seconds before a crash are lost. A clean quit or reload is not a crash and loses nothing.
obj.saveDelay = 5

--- ClipboardHistory.chooserRows
--- Variable
--- How many rows the chooser shows at once. Defaults to `10`.
obj.chooserRows = 10

--- ClipboardHistory.chooserWidth
--- Variable
--- Chooser width as a percentage of the screen. Defaults to `40`.
obj.chooserWidth = 40

--- ClipboardHistory.showInMenubar
--- Variable
--- Whether to place an item in the menubar. Defaults to `true`.
obj.showInMenubar = true

--- ClipboardHistory.menubarTitle
--- Variable
--- Menubar title while recording. Defaults to a clipboard glyph.
obj.menubarTitle = '📋'

--- ClipboardHistory.menubarTitlePaused
--- Variable
--- Menubar title while recording is paused. Defaults to a clipboard glyph with a pause sign.
---
--- Notes:
---  * Deliberately different from `ClipboardHistory.menubarTitle`. A recorder that has silently stopped recording is worse than one that is obviously off.
obj.menubarTitlePaused = '📋⏸'

--- ClipboardHistory.ignoredIdentifiers
--- Variable
--- Pasteboard types that mark content as not worth remembering, from http://nspasteboard.org. An entry carrying any of these is never recorded.
---
--- Notes:
---  * This is how password managers ask not to be logged: 1Password sets its own type, and anything setting `org.nspasteboard.ConcealedType` is asking to be left alone.
---  * It is advisory. An app that does not set a marker gets recorded like anything else, so this reduces the risk of copying a secret into the history but does not remove it. Use `ClipboardHistory:togglePause()` when handling something sensitive from an app you do not trust to mark it.
obj.ignoredIdentifiers = {
  ['Pasteboard generator type'] = true, -- Transient : Typinator
  ['com.agilebits.onepassword'] = true, -- Confidential : 1Password
  ['com.typeit4me.clipping'] = true, -- Transient : TypeIt4Me
  ['de.petermaurer.TransientPasteboardType'] = true, -- Transient : Textpander, TextExpander, Butler
  ['org.nspasteboard.AutoGeneratedType'] = true, -- Universal, Automatic
  ['org.nspasteboard.ConcealedType'] = true, -- Universal, Concealed
  ['org.nspasteboard.TransientType'] = true, -- Universal, Transient
}

--------------------------------------------------------------------------------
-- Internal state
--------------------------------------------------------------------------------

-- Everything long-lived is a field on the Spoon object rather than a local inside start(),
-- because hs.menubar / hs.chooser / hs.pasteboard.watcher / hs.timer are userdata with a
-- __gc that tears down the real resource. hs.loadSpoon() keeps this object alive as
-- spoon.ClipboardHistory for the life of the config, so nothing here is collected out from
-- under a running watcher.
obj.items = {} -- most recent first; each { text = string, at = epoch seconds, id = number }
obj.paused = false
obj.running = false

-- Row identity, handed to the chooser in place of the text (see choiceList). Deliberately a
-- plain counter rather than a content hash: hs.hash has no one-shot digest function any more
-- -- the hs.hash.MD5 the old ext/clipboard.lua called no longer exists -- and a counter has
-- no collision case to reason about. Ids are in-memory only and reassigned on load, since
-- nothing outside a single run ever refers to one.
obj.nextId = 1

obj.watcher = nil
obj.menubarItem = nil
obj.chooser = nil
obj.saveTimer = nil
obj.warned = {}

local SETTINGS_ITEMS = 'ClipboardHistory.items'
local SETTINGS_PAUSED = 'ClipboardHistory.paused'

--------------------------------------------------------------------------------
-- Stateless helpers
--------------------------------------------------------------------------------

-- These touch no Spoon state, so they stay plain locals rather than becoming methods.

-- Collapse every run of whitespace to a single space and trim the ends.
--
-- A clipboard entry is frequently a whole file, a stack trace, or a shell heredoc. Rendered
-- verbatim in a chooser row that is one line tall, all of those look identical: a fragment
-- followed by nothing. Flattening first means the row shows the first ~labelLength
-- characters of actual content instead of the first line and a lot of nothing.
local function oneLine(s)
  local flat = s:gsub('%s+', ' ')
  return (flat:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Truncate to n characters, keeping the HEAD.
--
-- PinnedWindows truncates window titles in the middle, because a title is distinguishable at
-- both ends ("Quarterly Report — Google Docs"). Clipboard entries are the opposite: what
-- identifies them is how they start. Middle-ellipsising "curl -sSL https://example.com/x.sh"
-- would give "curl -sSL h…ple.com/x.sh", which is strictly worse than keeping the front.
--
-- utf8.len returns nil on invalid UTF-8, and the clipboard is perfectly capable of holding
-- bytes that are not valid UTF-8, so every step falls back to byte slicing rather than
-- assuming the string is well-formed.
local function truncate(s, n)
  if s == nil or s == '' then return '(empty)' end
  local len = utf8 and utf8.len and utf8.len(s)
  if len and len <= n then return s end
  if not len and #s <= n then return s end
  if len and utf8 and utf8.offset then
    local cut = utf8.offset(s, n + 1)
    if cut then return s:sub(1, cut - 1) .. '…' end
  end
  return s:sub(1, n) .. '…'
end

local function formatSize(bytes)
  if bytes < 1024 then return string.format('%d B', bytes) end
  if bytes < 1024 * 1024 then return string.format('%.1f KB', bytes / 1024) end
  return string.format('%.1f MB', bytes / (1024 * 1024))
end

local function formatAge(then_)
  local secs = os.time() - (then_ or 0)
  if secs < 60 then return 'just now' end
  if secs < 3600 then return string.format('%d min ago', math.floor(secs / 60)) end
  if secs < 86400 then return string.format('%d hr ago', math.floor(secs / 3600)) end
  return string.format('%d days ago', math.floor(secs / 86400))
end

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

function obj:assignId()
  local id = self.nextId
  self.nextId = self.nextId + 1
  return id
end

-- Whether the current pasteboard is asking not to be remembered.
--
-- Read at callback time rather than carried with the contents, because the watcher hands
-- over the string only. The types belong to the same pasteboard change that woke us, so
-- reading them here is reading the state we are being told about.
function obj:isIgnoredContent()
  local ok, types = pcall(hs.pasteboard.pasteboardTypes)
  if not ok or type(types) ~= 'table' then
    self:warnOnce('pasteboardTypes', 'hs.pasteboard.pasteboardTypes failed (%s); recording anyway', tostring(types))
    return false
  end
  for _, t in ipairs(types) do
    if self.ignoredIdentifiers[t] then
      self.logger.df('ignoring a copy marked %s', t)
      return true
    end
  end
  return false
end

--- ClipboardHistory:record(text) -> boolean
--- Method
--- Adds text to the history, or moves it to the top if it is already there.
---
--- Parameters:
---  * text - the string to record
---
--- Returns:
---  * `true` if the history changed, `false` if the entry was rejected
---
--- Notes:
---  * Called for you by the pasteboard watcher. Exposed because it is also the honest way to seed the history from the Console.
---  * Rejects empty or whitespace-only text and anything larger than `ClipboardHistory.maxItemSize`.
function obj:record(text)
  if type(text) ~= 'string' then return false end
  if text:match('^%s*$') then return false end

  if #text > self.maxItemSize then
    self.logger.df('skipping a %s copy; over maxItemSize', formatSize(#text))
    return false
  end

  -- Linear scan comparing the text itself. The list is historySize long -- tens of entries
  -- -- so the scan is free, and Lua compares string length before contents, so entries of a
  -- different size cost nothing to reject. An index keyed by a digest would have to be
  -- rebuilt on load and kept correct through every insert, move and trim, which is a desync
  -- waiting to happen in exchange for no measurable gain and a collision case.
  for i, item in ipairs(self.items) do
    if item.text == text then
      if i > 1 then
        table.remove(self.items, i)
        table.insert(self.items, 1, item)
      end
      item.at = os.time()
      self:scheduleSave()
      return true
    end
  end

  table.insert(self.items, 1, { text = text, at = os.time(), id = self:assignId() })
  while #self.items > self.historySize do
    table.remove(self.items)
  end

  self:scheduleSave()
  return true
end

--- ClipboardHistory:clear() -> self
--- Method
--- Discards the whole history, in memory and on disk.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:clear()
  self.items = {}
  self:saveNow()
  self.logger.i('history cleared')
  return self
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

-- Coalesce writes. hs.settings.set serialises the whole table synchronously, so a burst of
-- copies would otherwise pay that cost once per copy.
function obj:scheduleSave()
  if self.saveTimer then self.saveTimer:stop() end
  self.saveTimer = hs.timer.doAfter(self.saveDelay, function()
    self.saveTimer = nil
    self:saveNow()
  end)
  self:updateMenubar()
end

function obj:saveNow()
  if self.saveTimer then
    self.saveTimer:stop()
    self.saveTimer = nil
  end
  -- Only text and timestamp are persisted. Ids are per-run and reassigned on load, so
  -- writing them would store something nothing ever reads back.
  local plain = {}
  for i, item in ipairs(self.items) do
    plain[i] = { text = item.text, at = item.at }
  end

  local ok, err = pcall(hs.settings.set, SETTINGS_ITEMS, plain)
  if not ok then self.logger.wf('could not save the history: %s', tostring(err)) end
  local okP, errP = pcall(hs.settings.set, SETTINGS_PAUSED, self.paused)
  if not okP then self.logger.wf('could not save the paused flag: %s', tostring(errP)) end
end

-- Read the history back, discarding anything that does not look like an entry.
--
-- The settings file is plain text that a human can edit and an interrupted write can
-- truncate, so nothing about its shape is assumed. A missing timestamp is filled in rather
-- than being a reason to drop an otherwise good entry.
function obj:load()
  local ok, stored = pcall(hs.settings.get, SETTINGS_ITEMS)
  if not ok or type(stored) ~= 'table' then
    self.items = {}
  else
    local out = {}
    for _, item in ipairs(stored) do
      if type(item) == 'table' and type(item.text) == 'string' and item.text ~= '' then
        out[#out + 1] = {
          text = item.text,
          at = type(item.at) == 'number' and item.at or os.time(),
          id = self:assignId(),
        }
      end
    end
    while #out > self.historySize do
      table.remove(out)
    end
    self.items = out
  end

  local okP, paused = pcall(hs.settings.get, SETTINGS_PAUSED)
  self.paused = (okP and paused == true) or false

  self.logger.df('loaded %d entries, paused=%s', #self.items, tostring(self.paused))
  return self
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

-- One row's worth of text. Flatten first, then truncate: truncating a multi-line string
-- first would spend the whole budget on the first line.
function obj:label(item) return truncate(oneLine(item.text), self.labelLength) end

function obj:subLabel(item) return string.format('%s · %s', formatAge(item.at), formatSize(#item.text)) end

--- ClipboardHistory:choiceList() -> table
--- Method
--- Builds the chooser's list of choices from the current history.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A list of `hs.chooser` choice tables
---
--- Notes:
---  * Each choice carries the entry's `id`, never its text. `hs.chooser` retains every choice table it is given, so putting the full text in there would hand the chooser the entire history -- potentially megabytes -- every time the list opens. The id resolves back to the text through `ClipboardHistory:copyById()` only when a row is actually picked.
function obj:choiceList()
  if #self.items == 0 then
    -- valid = false keeps the row from dismissing the chooser when it is selected.
    return {
      {
        text = 'Clipboard history is empty',
        subText = self.paused and 'Recording is paused' or 'Copy something and it will show up here',
        valid = false,
      },
    }
  end

  local out = {}
  for _, item in ipairs(self.items) do
    out[#out + 1] = { text = self:label(item), subText = self:subLabel(item), id = item.id }
  end
  return out
end

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

--- ClipboardHistory:copyById(id) -> boolean
--- Method
--- Puts the full text of a history entry back on the clipboard.
---
--- Parameters:
---  * id - the `id` field of the entry, as carried by a chooser choice
---
--- Returns:
---  * `true` if the entry was found and copied
---
--- Notes:
---  * This changes the pasteboard, so our own watcher fires immediately afterwards. That is deliberate and needs no suppression: the text is already in the history, so `ClipboardHistory:record()` takes its move-to-top path, which is exactly the most-recently-used ordering wanted here.
function obj:copyById(id)
  for _, item in ipairs(self.items) do
    if item.id == id then
      local ok, err = pcall(hs.pasteboard.setContents, item.text)
      if not ok then
        self.logger.wf('could not set the clipboard: %s', tostring(err))
        hs.alert.show('ClipboardHistory: could not set the clipboard')
        return false
      end
      return true
    end
  end
  self.logger.wf('no history entry with id %s', tostring(id))
  hs.alert.show('ClipboardHistory: that entry is no longer available')
  return false
end

--- ClipboardHistory:togglePause() -> self
--- Method
--- Suspends or resumes recording.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
---
--- Notes:
---  * The watcher keeps running while paused; the callback simply discards what it is given. This costs nothing and means resuming does not have to rebuild anything.
---  * The flag is persisted, so a Spoon paused before a reload comes back paused rather than quietly resuming.
function obj:togglePause()
  self.paused = not self.paused
  self:saveNow()
  self:updateMenubar()
  self.logger.f('recording %s', self.paused and 'paused' or 'resumed')
  hs.alert.show(self.paused and 'Clipboard recording paused' or 'Clipboard recording resumed', 1)
  return self
end

--------------------------------------------------------------------------------
-- Chooser
--------------------------------------------------------------------------------

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection.
    if not choice or not choice.id then return end
    self:copyById(choice.id)
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  self.chooser:searchSubText(false)
  self.chooser:placeholderText('Search the clipboard history…')
  return self.chooser
end

--- ClipboardHistory:show() -> self
--- Method
--- Opens the chooser over the clipboard history.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:show()
  local chooser = self:ensureChooser()
  -- Choices are handed over as a static table rather than a callback, so the list is rebuilt
  -- on every open. A callback would be cached until refreshChoicesCallback().
  chooser:choices(self:choiceList())
  chooser:query('')
  chooser:show()
  return self
end

--- ClipboardHistory:hide() -> self
--- Method
--- Closes the chooser if it is open.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:hide()
  if self.chooser then self.chooser:hide() end
  return self
end

--------------------------------------------------------------------------------
-- Menubar
--------------------------------------------------------------------------------

function obj:buildMenu()
  local menu = { { title = 'Search…', fn = function() self:show() end } }

  menu[#menu + 1] = { title = '-' }
  if #self.items == 0 then
    menu[#menu + 1] = { title = 'No history yet', disabled = true }
  else
    for i, item in ipairs(self.items) do
      if i > self.menuItems then break end
      -- The id is captured rather than the index, so a history that changes between the menu
      -- being built and an item being picked cannot copy the wrong entry.
      local id = item.id
      menu[#menu + 1] = { title = self:label(item), fn = function() self:copyById(id) end }
    end
  end

  menu[#menu + 1] = { title = '-' }
  menu[#menu + 1] = { title = 'Pause recording', checked = self.paused, fn = function() self:togglePause() end }
  menu[#menu + 1] = {
    title = 'Clear history',
    disabled = #self.items == 0,
    fn = function() self:clear() end,
  }
  return menu
end

function obj:updateMenubar()
  if not self.menubarItem then return end
  self.menubarItem:setTitle(self.paused and self.menubarTitlePaused or self.menubarTitle)
  self.menubarItem:setTooltip(self.paused and 'Clipboard recording is paused' or string.format('%d clipboard entries', #self.items))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function obj:init() return self end

--- ClipboardHistory:start() -> self
--- Method
--- Loads the saved history and begins watching the pasteboard.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
function obj:start()
  if self.running then self:stop() end

  self:load()

  -- hs.pasteboard.watcher.new() creates AND starts the watcher, so there is no start() call
  -- to follow it -- and correspondingly the handle has to be kept so stop() can end it.
  --
  -- The callback is handed the contents as a string, or nil when the pasteboard does not
  -- hold a valid string. nil is the normal way images and file copies arrive here, so it is
  -- an early return rather than a warning.
  self.watcher = hs.pasteboard.watcher.new(function(contents)
    if self.paused then return end
    if contents == nil then return end
    if self:isIgnoredContent() then return end
    self:record(contents)
  end)

  if not self.watcher then
    self.logger.w('could not create the pasteboard watcher; nothing will be recorded')
    hs.alert.show('ClipboardHistory: could not watch the pasteboard')
  end

  if self.showInMenubar then
    -- The autosave name stays lower-case and distinct from the other Spoons': it is what
    -- macOS keys the item's saved position in the menu bar on, so it has to be unique and
    -- must never be renamed afterwards.
    self.menubarItem = hs.menubar.new(true, 'clipboardhistory')
    if self.menubarItem then
      -- Wrapped: an error thrown inside the menu callback would otherwise leave a dead
      -- menubar icon with no way to recover short of reloading the config.
      --
      -- Setting a menu also disables setClickCallback, by design -- a click opens this menu,
      -- and "Search…" at the top of it opens the chooser.
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
      self:updateMenubar()
    else
      self.logger.w('could not create the menubar item')
    end
  end

  self.running = true
  self.logger.i('started')
  return self
end

--- ClipboardHistory:stop() -> self
--- Method
--- Stops watching the pasteboard, flushes the history to disk and removes the menubar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
---
--- Notes:
---  * Any hotkeys bound with `ClipboardHistory:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped: saves are debounced, so there is very likely a
  -- pending timer holding the only record of the last few copies. Flushing here is what
  -- makes a config reload lossless.
  self:saveNow()

  if self.watcher then
    pcall(function() self.watcher:stop() end)
    self.watcher = nil
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

  self.warned = {}
  self.running = false
  self.logger.i('stopped')
  return self
end

--- ClipboardHistory:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for this Spoon.
---
--- Parameters:
---  * mapping - a table containing hotkey modifier/key details for the following items:
---   * show - open the chooser over the clipboard history
---   * togglePause - suspend or resume recording
---   * clear - discard the whole history
---
--- Returns:
---  * The ClipboardHistory object
function obj:bindHotkeys(mapping)
  local spec = {
    show = hs.fnutils.partial(self.show, self),
    togglePause = hs.fnutils.partial(self.togglePause, self),
    clear = hs.fnutils.partial(self.clear, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

return obj
