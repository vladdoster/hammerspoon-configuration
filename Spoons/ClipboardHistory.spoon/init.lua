-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === ClipboardHistory ===
---
--- A searchable clipboard history that survives a Hammerspoon restart.
---
--- Watches the pasteboard, keeps the last `ClipboardHistory.historySize` entries, and
--- offers them back through a chooser or a menubar menu. An entry is text, an image, or a set of
--- files copied in Finder. Selecting an entry puts it back on the clipboard; pasting stays a manual
--- cmd+v. A second action, `ClipboardHistory:showAndType()`, types a picked text entry into the
--- front app instead and leaves the clipboard alone.
---
--- The history is written to `hs.settings`, so text lands on disk in plain text. Each image goes
--- to a file under `~/Library/Application Support/Hammerspoon/ClipboardHistory/` as its raw
--- pasteboard bytes, and the file is deleted when the image leaves the history. A files entry
--- keeps only the paths. Entries marked
--- concealed or transient (see `ClipboardHistory.ignoredIdentifiers`) are never recorded, and
--- recording can be paused from the menu -- but the markers are advisory, so treat the
--- history as readable by anything that can read your home directory.

local obj = {}
obj.__index = obj

obj.name = "ClipboardHistory"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- ClipboardHistory.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("ClipboardHistory", "info")

-- Configuration

--- ClipboardHistory.historySize
--- Variable
--- How many entries to keep. Defaults to `50`.
---
--- The whole history is serialised on every save, so this trades against how much work a save is.
obj.historySize = 50

--- ClipboardHistory.maxItemSize
--- Variable
--- Bytes; a text copy larger than this is not recorded at all. Defaults to `102400` (100 KB).
---
--- Text only. For images, see `ClipboardHistory.maxImageSize`.
--- A storage guard, not a display one: oversized entries are dropped rather than truncated. For display truncation see `ClipboardHistory.labelLength`.
obj.maxItemSize = 100 * 1024

--- ClipboardHistory.maxImageSize
--- Variable
--- Bytes; an image copy larger than this is not recorded at all. Defaults to `26214400` (25 MB).
---
--- Large enough for an uncompressed full-screen TIFF on a 3024 by 1964 display.
--- Each image is a file on disk, so the history can hold up to `ClipboardHistory.historySize` images of this size.
obj.maxImageSize = 25 * 1024 * 1024

--- ClipboardHistory.labelLength
--- Variable
--- Maximum number of characters of an entry shown in a chooser row or menu item. Defaults to `80`.
---
--- Display only. The full text is what gets put back on the clipboard.
obj.labelLength = 80

--- ClipboardHistory.menuItems
--- Variable
--- How many recent entries to list inline in the menubar menu. Defaults to `30`.
---
--- `Search…` opens the chooser over the whole history. Capped in practice by `ClipboardHistory.historySize`, and the menu is built on demand, so a larger number costs nothing per copy.
obj.menuItems = 30

--- ClipboardHistory.saveDelay
--- Variable
--- Seconds to wait after the last change before writing the history to `hs.settings`. Defaults to `5`.
---
--- `hs.settings.set` serialises synchronously, so writes are coalesced behind this delay and flushed by `ClipboardHistory:stop()`.
--- The cost is that entries copied in the last few seconds before a crash are lost. A clean quit or reload loses nothing.
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
--- Menubar title while recording. Defaults to the SF Symbols `doc.on.clipboard` glyph.
---
--- SF Symbols are reachable only as private-use codepoints rendered in the menu bar font, since `hs.image` cannot resolve them by name.
--- They are drawn from SF Pro, which is an Apple download rather than part of macOS: without it this renders as a missing-glyph box.
obj.menubarTitle = utf8.char(0x100243)

--- ClipboardHistory.menubarTitlePaused
--- Variable
--- Menubar title while recording is paused. Defaults to the clipboard glyph followed by `pause.fill`.
---
--- Deliberately different from `ClipboardHistory.menubarTitle`, so a paused recorder is obviously off.
obj.menubarTitlePaused = utf8.char(0x100243) .. utf8.char(0x100286)

--- ClipboardHistory.menubarFont
--- Variable
--- Font for the menubar title, as `hs.styledtext` understands it. Defaults to the menu bar font at 14pt.
---
--- No colour is set deliberately, so AppKit's default menubar label colour applies and follows light and dark appearance on its own.
obj.menubarFont = { name = hs.styledtext.defaultFonts.menuBar.name, size = 14 }

--- ClipboardHistory.ignoredIdentifiers
--- Variable
--- Pasteboard types that mark content as not worth remembering, from http://nspasteboard.org. An entry carrying any of these is never recorded.
---
--- This is how password managers ask not to be logged.
--- Advisory only: an app that sets no marker is recorded like anything else. Use `ClipboardHistory:togglePause()` for anything sensitive from an app you do not trust to mark it.
obj.ignoredIdentifiers = {
  ["Pasteboard generator type"] = true, -- Transient : Typinator
  ["com.agilebits.onepassword"] = true, -- Confidential : 1Password
  ["com.typeit4me.clipping"] = true, -- Transient : TypeIt4Me
  ["de.petermaurer.TransientPasteboardType"] = true, -- Transient : Textpander, TextExpander, Butler
  ["org.nspasteboard.AutoGeneratedType"] = true, -- Universal, Automatic
  ["org.nspasteboard.ConcealedType"] = true, -- Universal, Concealed
  ["org.nspasteboard.TransientType"] = true, -- Universal, Transient
}

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.items = {} -- most recent first: each { kind, at, id } plus the fields restoreEntry() lists for its kind
obj.paused = false
obj.running = false

-- Row identity for the chooser (see choiceList); a counter, so there is no collision case
obj.nextId = 1

obj.watcher = nil
obj.menubarItem = nil
obj.chooser = nil
-- What a chooser pick does: "copy" or "type"; set by show() on every open
obj.chooserAction = "copy"
obj.saveTimer = nil
obj.warned = {}

local SETTINGS_ITEMS = "ClipboardHistory.items"
local SETTINGS_PAUSED = "ClipboardHistory.paused"

-- Images live here as raw pasteboard bytes. Settings hold only the file name
local IMAGE_DIR = os.getenv("HOME") .. "/Library/Application Support/Hammerspoon/ClipboardHistory"

-- Read in this order. TIFF comes last because NSImage always provides it
local IMAGE_TYPES = {
  { uti = "public.png", ext = "png" },
  { uti = "public.tiff", ext = "tiff" },
}

-- Hex digest and extension. Settings are hand-editable, and the pattern keeps paths inside IMAGE_DIR
local IMAGE_FILE_PATTERN = "^%x+%.%a+$"

-- Stateless helpers

-- Flatten whitespace, so a one-line row shows content rather than a short first line
local function oneLine(s)
  local flat = s:gsub("%s+", " ")
  return (flat:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Keeps the HEAD, which is what identifies a clipboard entry; byte-slices invalid UTF-8
local function truncate(s, n)
  if s == nil or s == "" then return "(empty)" end
  local len = utf8 and utf8.len and utf8.len(s)
  if len and len <= n then return s end
  if not len and #s <= n then return s end
  if len and utf8 and utf8.offset then
    local cut = utf8.offset(s, n + 1)
    if cut then return s:sub(1, cut - 1) .. "…" end
  end
  return s:sub(1, n) .. "…"
end

local function formatSize(bytes)
  if bytes < 1024 then return string.format("%d B", bytes) end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  return string.format("%.1f MB", bytes / (1024 * 1024))
end

local function formatAge(then_)
  local secs = os.time() - (then_ or 0)
  if secs < 60 then return "just now" end
  if secs < 3600 then return string.format("%d min ago", math.floor(secs / 60)) end
  if secs < 86400 then return string.format("%d hr ago", math.floor(secs / 3600)) end
  return string.format("%d days ago", math.floor(secs / 86400))
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

-- Parent folder of a path, with ~ for HOME
local function parentDir(path)
  local dir = path:match("^(.*)/[^/]*$")
  if not dir or dir == "" then return "/" end
  local home = os.getenv("HOME")
  if dir == home then return "~" end
  if dir:sub(1, #home + 1) == home .. "/" then return "~" .. dir:sub(#home + 1) end
  return dir
end

-- Scales a size down to fit a max by max box and keeps the aspect ratio
local function fitSize(size, max)
  local scale = math.min(1, max / math.max(size.w, size.h, 1))
  return { w = math.max(1, math.floor(size.w * scale)), h = math.max(1, math.floor(size.h * scale)) }
end

local function sha256(data)
  return hs.hash.new("SHA256"):append(data):finish():value()
end

-- Writes an entry to the pasteboard in its own form. Returns true, or false and an alert reason
local function writeToPasteboard(item)
  if item.kind == "image" then
    local f = io.open(IMAGE_DIR .. "/" .. item.file, "rb")
    if not f then return false, "the image file is missing" end
    local data = f:read("a")
    f:close()
    return hs.pasteboard.writeDataForUTI(item.uti, data)
  elseif item.kind == "files" then
    local objects = {}
    for _, path in ipairs(item.paths) do
      -- nil for a path that no longer exists
      local url = hs.fs.urlFromPath(path)
      if url then objects[#objects + 1] = { url = url } end
    end
    if #objects == 0 then return false, "the files no longer exist" end
    return hs.pasteboard.writeObjects(objects)
  end
  return hs.pasteboard.setContents(item.text)
end

-- Returns a clean copy of a stored entry, or nil. An entry without kind is text from before images
local function restoreEntry(item)
  if type(item) ~= "table" then return nil end
  local kind = item.kind or "text"
  if kind == "text" then
    if type(item.text) == "string" and item.text ~= "" then return { kind = "text", text = item.text } end
  elseif kind == "image" then
    if type(item.file) ~= "string" or not item.file:match(IMAGE_FILE_PATTERN) or type(item.uti) ~= "string" then return nil end
    local attrs = hs.fs.attributes(IMAGE_DIR .. "/" .. item.file)
    if not attrs or attrs.mode ~= "file" then return nil end
    local bytes = type(item.bytes) == "number" and item.bytes or attrs.size
    return { kind = "image", file = item.file, uti = item.uti, bytes = bytes }
  elseif kind == "files" then
    if type(item.paths) ~= "table" or #item.paths == 0 then return nil end
    local paths = {}
    for i, path in ipairs(item.paths) do
      if type(path) ~= "string" then return nil end
      paths[i] = path
    end
    return { kind = "files", paths = paths }
  end
  return nil
end

-- History

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

-- Read at callback time, since the watcher hands over the string without its types
function obj:isIgnoredContent()
  local ok, types = pcall(hs.pasteboard.pasteboardTypes)
  if not ok or type(types) ~= "table" then
    self:warnOnce("pasteboardTypes", "hs.pasteboard.pasteboardTypes failed (%s); recording anyway", tostring(types))
    return false
  end
  for _, t in ipairs(types) do
    if self.ignoredIdentifiers[t] then
      self.logger.df("ignoring a copy marked %s", t)
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
--- Called for you by the pasteboard watcher; exposed so the history can be seeded from the Console.
--- Rejects empty or whitespace-only text and anything larger than `ClipboardHistory.maxItemSize`.
function obj:record(text)
  if type(text) ~= "string" then return false end
  if text:match("^%s*$") then return false end

  if #text > self.maxItemSize then
    self.logger.df("skipping a %s copy; over maxItemSize", formatSize(#text))
    return false
  end

  return self:upsert({ kind = "text", text = text }, function(item)
    return item.kind == "text" and item.text == text
  end)
end

-- Moves the first entry that matches to the top, or inserts entry there and trims the history
function obj:upsert(entry, matches)
  -- Linear over tens of entries; a digest index would need keeping correct for no gain
  for i, item in ipairs(self.items) do
    if matches(item) then
      if i > 1 then
        table.remove(self.items, i)
        table.insert(self.items, 1, item)
      end
      item.at = os.time()
      self:scheduleSave()
      return true
    end
  end

  entry.at = os.time()
  entry.id = self:assignId()
  table.insert(self.items, 1, entry)
  while #self.items > self.historySize do
    table.remove(self.items)
  end

  self:scheduleSave()
  return true
end

-- The file name is the content hash, so a repeat copy writes nothing and moves the entry up
function obj:recordImage(uti, ext, data)
  if type(data) ~= "string" or data == "" then return false end
  if #data > self.maxImageSize then
    self.logger.df("skipping a %s image; over maxImageSize", formatSize(#data))
    return false
  end

  local file = sha256(data) .. "." .. ext
  local path = IMAGE_DIR .. "/" .. file
  if not hs.fs.attributes(path) then
    local f, err = io.open(path, "wb")
    local written
    if f then
      written, err = f:write(data)
      f:close()
    end
    if not written then
      -- load() accepts a partial file, and a pick then pastes a broken image
      os.remove(path)
      self.logger.wf("could not write the image: %s", tostring(err))
      return false
    end
  end

  return self:upsert({ kind = "image", file = file, uti = uti, bytes = #data }, function(item)
    return item.kind == "image" and item.file == file
  end)
end

-- Stores paths only. The same paths in the same order match the same entry
function obj:recordFiles(paths)
  local key = table.concat(paths, "\n")
  return self:upsert({ kind = "files", paths = paths }, function(item)
    return item.kind == "files" and table.concat(item.paths, "\n") == key
  end)
end

-- Checks files, then text, then an image. Finder also puts the file names on the pasteboard as text
function obj:capture(contents)
  local ok, avail = pcall(hs.pasteboard.typesAvailable)
  if not ok or type(avail) ~= "table" then
    self:warnOnce("typesAvailable", "hs.pasteboard.typesAvailable failed (%s); recording text only", tostring(avail))
    avail = {}
  end

  if avail.URL then
    local okU, urls = pcall(hs.pasteboard.readURL, nil, true)
    local paths = {}
    for _, url in ipairs(okU and type(urls) == "table" and urls or {}) do
      -- LuaSkin sets filePath on file URLs only. A remote URL goes on to the text check
      if type(url) == "table" and type(url.filePath) == "string" then paths[#paths + 1] = url.filePath end
    end
    if #paths > 0 then return self:recordFiles(paths) end
  end

  -- Text wins over an image in a mixed copy, such as spreadsheet cells
  -- Rich-text copies put U+FFFC where an image is. Text of only U+FFFC and blanks goes to the image check
  local hasText = contents ~= nil and contents:gsub("\239\191\188", ""):match("%S") ~= nil
  if hasText and self:record(contents) then return true end

  if avail.image then
    local okT, types = pcall(hs.pasteboard.contentTypes)
    local present = {}
    for _, t in ipairs(okT and type(types) == "table" and types or {}) do
      present[t] = true
    end
    for _, t in ipairs(IMAGE_TYPES) do
      if present[t.uti] then
        local okD, data = pcall(hs.pasteboard.readDataForUTI, t.uti)
        return okD and self:recordImage(t.uti, t.ext, data) or false
      end
    end
    self.logger.d("skipping an image that is not PNG or TIFF")
  end
  return false
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
  self.logger.i("history cleared")
  return self
end

-- Persistence

-- Coalesce writes: hs.settings.set serialises the whole table synchronously
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
  -- Ids and thumbnails are per-run: load() reassigns ids and thumbFor() rebuilds thumbnails
  local plain = {}
  for i, item in ipairs(self.items) do
    if item.kind == "image" then
      plain[i] = { kind = "image", file = item.file, uti = item.uti, bytes = item.bytes, at = item.at }
    elseif item.kind == "files" then
      plain[i] = { kind = "files", paths = item.paths, at = item.at }
    else
      plain[i] = { kind = "text", text = item.text, at = item.at }
    end
  end

  local ok, err = pcall(hs.settings.set, SETTINGS_ITEMS, plain)
  if ok then
    -- Only after a good write: settings must stop naming a file before the sweep deletes it
    self:sweepImages()
  else
    self.logger.wf("could not save the history: %s", tostring(err))
  end
  local okP, errP = pcall(hs.settings.set, SETTINGS_PAUSED, self.paused)
  if not okP then self.logger.wf("could not save the paused flag: %s", tostring(errP)) end
end

-- Deletes image files that no entry names: evictions, clear(), and orphans from a crash
function obj:sweepImages()
  local keep = {}
  for _, item in ipairs(self.items) do
    if item.kind == "image" then keep[item.file] = true end
  end

  local ok, iter, dirObj = pcall(hs.fs.dir, IMAGE_DIR)
  if not ok or not iter then return end
  -- Collect first: deleting while readdir walks the folder can skip names
  local doomed = {}
  for name in iter, dirObj do
    if name:match(IMAGE_FILE_PATTERN) and not keep[name] then doomed[#doomed + 1] = name end
  end
  for _, name in ipairs(doomed) do
    local removed, err = os.remove(IMAGE_DIR .. "/" .. name)
    if not removed then self.logger.wf("could not delete %s: %s", name, tostring(err)) end
  end
end

-- Assumes nothing: the settings file is hand-editable and a broken write can truncate it
function obj:load()
  local ok, stored = pcall(hs.settings.get, SETTINGS_ITEMS)
  if not ok or type(stored) ~= "table" then
    self.items = {}
  else
    local out = {}
    for _, item in ipairs(stored) do
      local entry = restoreEntry(item)
      if entry then
        entry.at = type(item.at) == "number" and item.at or os.time()
        entry.id = self:assignId()
        out[#out + 1] = entry
      end
    end
    while #out > self.historySize do
      table.remove(out)
    end
    self.items = out
  end

  local okP, paused = pcall(hs.settings.get, SETTINGS_PAUSED)
  self.paused = (okP and paused == true) or false

  self.logger.df("loaded %d entries, paused=%s", #self.items, tostring(self.paused))
  return self
end

-- Display

-- Flatten first, then truncate: the other order spends the whole budget on the first line
function obj:label(item)
  if item.kind == "image" then return string.format("Image (%s)", item.file:match("%.(%a+)$"):upper()) end
  if item.kind == "files" then
    local names = {}
    for i, path in ipairs(item.paths) do
      names[i] = basename(path)
    end
    local title = #names == 1 and names[1] or string.format("%d files: %s", #names, table.concat(names, ", "))
    return truncate(title, self.labelLength)
  end
  return truncate(oneLine(item.text), self.labelLength)
end

function obj:subLabel(item)
  if item.kind == "files" then return string.format("%s · %s", formatAge(item.at), parentDir(item.paths[1])) end
  local size = item.kind == "image" and item.bytes or #item.text
  return string.format("%s · %s", formatAge(item.at), formatSize(size))
end

-- Built on first use and kept in memory on the entry. false marks a build that failed
function obj:thumbFor(item)
  if item.thumb == nil then
    local thumb
    if item.kind == "image" then
      local img = hs.image.imageFromPath(IMAGE_DIR .. "/" .. item.file)
      -- Shrunk to 64 points, so the history does not hold full bitmaps
      if img then thumb = img:bitmapRepresentation(fitSize(img:size(), 64)) end
    elseif item.kind == "files" then
      thumb = hs.image.iconForFile(item.paths)
    end
    item.thumb = thumb or false
  end
  return item.thumb or nil
end

--- ClipboardHistory:choiceList([textOnly]) -> table
--- Method
--- Builds the chooser's list of choices from the current history.
---
--- Parameters:
---  * textOnly - optional; when `true`, lists text entries only, as the type action needs
---
--- Returns:
---  * A list of `hs.chooser` choice tables
---
--- Each choice carries the entry's `id`, never its text: `hs.chooser` retains every choice table it is given, so the full text would hand it the whole history on every open. `ClipboardHistory:copyById()` resolves the id when a row is picked.
--- Image and files entries also carry a thumbnail.
function obj:choiceList(textOnly)
  local out = {}
  for _, item in ipairs(self.items) do
    if not textOnly or item.kind == "text" then
      out[#out + 1] = { text = self:label(item), subText = self:subLabel(item), image = self:thumbFor(item), id = item.id }
    end
  end
  if #out > 0 then return out end

  -- valid = false keeps the row from dismissing the chooser when it is selected
  return {
    {
      text = textOnly and "No text entries to type" or "Clipboard history is empty",
      subText = self.paused and "Recording is paused" or "Copy something and it will show up here",
      valid = false,
    },
  }
end

-- Selection

--- ClipboardHistory:copyById(id) -> boolean
--- Method
--- Puts a history entry back on the clipboard in its own form.
---
--- Parameters:
---  * id - the `id` field of the entry, as carried by a chooser choice
---
--- Returns:
---  * `true` if the entry was found and copied
---
--- Text goes back as text. An image goes back as the bytes it was copied with, under the same type, so it pastes at its original size.
--- Files go back as file URLs, so Finder pastes the files themselves. The copy skips paths that no longer exist. When no path exists, the copy fails with an alert.
--- This fires our own watcher, deliberately and with no suppression: the entry is already in the history, so the watcher takes its move-to-top path, which is the ordering wanted here.
function obj:copyById(id)
  for _, item in ipairs(self.items) do
    if item.id == id then
      local ok, written, reason = pcall(writeToPasteboard, item)
      if not ok or not written then
        reason = reason or "could not set the clipboard"
        self.logger.wf("could not set the clipboard: %s", ok and reason or tostring(written))
        hs.alert.show("ClipboardHistory: " .. reason)
        return false
      end
      return true
    end
  end
  self.logger.wf("no history entry with id %s", tostring(id))
  hs.alert.show("ClipboardHistory: that entry is no longer available")
  return false
end

--- ClipboardHistory:typeById(id) -> boolean
--- Method
--- Types the full text of a history entry into the front app as keystrokes.
---
--- Parameters:
---  * id - the `id` field of the entry, as carried by a chooser choice
---
--- Returns:
---  * `true` if the entry was found and typed
---
--- The clipboard is not touched, so the watcher does not fire and the entry keeps its place in the history.
--- Newlines arrive as Return keystrokes, which a chat or form field may treat as submit.
--- Refuses while secure input is on (a focused password field), since synthetic keys are dropped there.
--- Each character is one key event, so a large entry takes visibly long; copy those instead.
--- Text entries only. The method refuses an image or files entry with an alert.
function obj:typeById(id)
  for _, item in ipairs(self.items) do
    if item.id == id then
      if item.kind ~= "text" then
        self.logger.wf("entry %s is %s, not text; not typing", tostring(id), tostring(item.kind))
        hs.alert.show("ClipboardHistory: cannot type an image or files entry")
        return false
      end
      if hs.eventtap.isSecureInputEnabled() then
        self.logger.w("secure input is active; not typing")
        hs.alert.show("ClipboardHistory: secure input is on, cannot type")
        return false
      end
      local ok, err = pcall(hs.eventtap.keyStrokes, item.text)
      if not ok then
        self.logger.wf("could not type the entry: %s", tostring(err))
        hs.alert.show("ClipboardHistory: could not type the entry")
        return false
      end
      return true
    end
  end
  self.logger.wf("no history entry with id %s", tostring(id))
  hs.alert.show("ClipboardHistory: that entry is no longer available")
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
--- The watcher keeps running while paused and its callback discards what it is given, so resuming rebuilds nothing.
--- The flag is persisted, so a Spoon paused before a reload comes back paused.
function obj:togglePause()
  self.paused = not self.paused
  self:saveNow()
  self:updateMenubar()
  self.logger.f("recording %s", self.paused and "paused" or "resumed")
  hs.alert.show(self.paused and "Clipboard recording paused" or "Clipboard recording resumed", 1)
  return self
end

-- Chooser

function obj:ensureChooser()
  if self.chooser then return self.chooser end

  self.chooser = hs.chooser.new(function(choice)
    -- nil when the chooser was dismissed with Escape rather than a selection
    if not choice or not choice.id then return end
    if self.chooserAction == "type" then
      self:typeById(choice.id)
    else
      self:copyById(choice.id)
    end
  end)

  self.chooser:rows(self.chooserRows)
  self.chooser:width(self.chooserWidth)
  self.chooser:searchSubText(false)
  return self.chooser
end

--- ClipboardHistory:show([action]) -> self
--- Method
--- Opens the chooser over the clipboard history.
---
--- Parameters:
---  * action - optional; what a pick does. `"copy"` (the default) puts the entry on the clipboard, `"type"` types it into the front app
---
--- Returns:
---  * The ClipboardHistory object
function obj:show(action)
  local chooser = self:ensureChooser()
  self.chooserAction = action == "type" and "type" or "copy"
  -- Set on every open, so the placeholder names the action this open takes
  chooser:placeholderText(self.chooserAction == "type" and "Type an entry into the front app…" or "Search the clipboard history…")
  -- Static table, so the list rebuilds on open; a callback caches until refreshChoicesCallback()
  chooser:choices(self:choiceList(self.chooserAction == "type"))
  chooser:query("")
  chooser:show()
  return self
end

--- ClipboardHistory:showAndType() -> self
--- Method
--- Opens the chooser; the picked entry is typed into the front app instead of copied.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The ClipboardHistory object
---
--- See `ClipboardHistory:typeById()` for what typing does and does not do.
function obj:showAndType()
  return self:show("type")
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

-- Menubar

-- One menu item per recent entry, capped at menuItems; pick(id) is what a click does, textOnly skips non-text entries
function obj:entryItems(pick, textOnly)
  local out = {}
  for _, item in ipairs(self.items) do
    if #out >= self.menuItems then break end
    if not textOnly or item.kind == "text" then
      -- The id, not the index: the history can change between the menu being built and picked
      local id = item.id
      local thumb = self:thumbFor(item)
      out[#out + 1] = {
        title = self:label(item),
        -- A copy, so the cached thumbnail keeps its size
        image = thumb and thumb:copy():size(fitSize(thumb:size(), 16)) or nil,
        fn = function()
          pick(self, id)
        end,
      }
    end
  end
  return out
end

function obj:buildMenu()
  local menu = {
    {
      title = "Search…",
      fn = function()
        self:show()
      end,
    },
    {
      title = "Type…",
      fn = function()
        self:showAndType()
      end,
    },
  }

  menu[#menu + 1] = { title = "-" }
  if #self.items == 0 then
    menu[#menu + 1] = { title = "No history yet", disabled = true }
  else
    for _, item in ipairs(self:entryItems(self.copyById)) do
      menu[#menu + 1] = item
    end
  end

  menu[#menu + 1] = { title = "-" }
  local typeItems = self:entryItems(self.typeById, true)
  menu[#menu + 1] = {
    title = "Type recent",
    disabled = #typeItems == 0,
    menu = typeItems,
  }

  menu[#menu + 1] = { title = "-" }
  menu[#menu + 1] = {
    title = "Pause recording",
    checked = self.paused,
    fn = function()
      self:togglePause()
    end,
  }
  menu[#menu + 1] = {
    title = "Clear history",
    disabled = #self.items == 0,
    fn = function()
      self:clear()
    end,
  }
  return menu
end

function obj:updateMenubar()
  if not self.menubarItem then return end
  -- Styled for the size only. Leaving the colour out is what keeps AppKit's own menubar label colour, and with it light and dark appearance for free
  local title = self.paused and self.menubarTitlePaused or self.menubarTitle
  self.menubarItem:setTitle(hs.styledtext.new(title, { font = self.menubarFont }))
  self.menubarItem:setTooltip(self.paused and "Clipboard recording is paused" or string.format("%d clipboard entries", #self.items))
end

-- Lifecycle

function obj:init()
  return self
end

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

  -- mkdir makes one level and fails harmlessly when the folder exists
  hs.fs.mkdir(IMAGE_DIR:match("^(.*)/[^/]+$"))
  hs.fs.mkdir(IMAGE_DIR)

  self:load()

  -- watcher.new() also starts it, so the handle is kept for stop(); contents is nil for a copy without text
  self.watcher = hs.pasteboard.watcher.new(function(contents)
    if self.paused then return end
    if self:isIgnoredContent() then return end
    self:capture(contents)
  end)

  if not self.watcher then
    self.logger.w("could not create the pasteboard watcher; nothing will be recorded")
    hs.alert.show("ClipboardHistory: could not watch the pasteboard")
  end

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "clipboardhistory")
    if self.menubarItem then
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
      self:updateMenubar()
    else
      self.logger.w("could not create the menubar item")
    end
  end

  self.running = true
  self.logger.i("started")
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
--- Any hotkeys bound with `ClipboardHistory:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- First, before any handle is dropped: a debounced save holds the last few copies
  self:saveNow()

  if self.watcher then
    pcall(function()
      self.watcher:stop()
    end)
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
  self.logger.i("stopped")
  return self
end

--- ClipboardHistory:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for this Spoon.
---
--- Parameters:
---  * mapping - a table containing hotkey modifier/key details for the following items:
---   * show - open the chooser over the clipboard history
---   * showAndType - open the chooser; the pick is typed into the front app
---   * togglePause - suspend or resume recording
---   * clear - discard the whole history
---
--- Returns:
---  * The ClipboardHistory object
function obj:bindHotkeys(mapping)
  local spec = {
    show = hs.fnutils.partial(self.show, self),
    showAndType = hs.fnutils.partial(self.showAndType, self),
    togglePause = hs.fnutils.partial(self.togglePause, self),
    clear = hs.fnutils.partial(self.clear, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

return obj
