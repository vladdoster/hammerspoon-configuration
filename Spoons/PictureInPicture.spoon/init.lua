-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
--- === PictureInPicture ===
---
--- Toggles the front tab's video into and out of macOS Picture in Picture, for Safari and Google Chrome.
---
--- The two browsers are reached by entirely different means, because only one of them can be reached at all.
---
--- Safari takes an Apple Event: `do JavaScript ... in front document`, calling WebKit's own
--- `webkitSetPresentationMode`. That API predates the transient-activation rule, so it answers a script with no user
--- gesture behind it, and Safari's Picture in Picture is hosted out of process by `PIPAgent`, so entering it never
--- moves a window or takes focus from the page.
---
--- Chrome cannot be reached that way, and no amount of API-shopping changes it. Both `requestPictureInPicture` and
--- `documentPictureInPicture.requestWindow` refuse without transient activation, which is exactly what JavaScript
--- injected through an Apple Event lacks. What Chrome will accept is one of its own shortcuts: invoking an extension
--- action counts as a genuine user gesture, so Google's Picture-in-Picture extension gets the activation an outside
--- caller never can. The Chrome path is therefore a single forwarded keystroke and nothing else -- see
--- `PictureInPicture.chromeShortcut`.
---
--- The asymmetry runs all the way through. Safari needs `Allow JavaScript from Apple Events` turned on and an
--- Automation permission macOS asks for once; Chrome needs neither, only the extension. Nothing here is settable from
--- code, so each failure is detected and the fix named in the alert.

local obj = {}
obj.__index = obj

obj.name = "PictureInPicture"
obj.version = "1.0"
obj.author = "Vladislav Doster <mvdoster@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- PictureInPicture.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("PictureInPicture", "info")

-- Configuration

--- PictureInPicture.showInMenubar
--- Variable
--- Whether to place an item in the menubar. Defaults to `true`.
obj.showInMenubar = true

--- PictureInPicture.menubarTitle
--- Variable
--- Menubar title. Defaults to the SF Symbols `pip.enter` glyph.
---
--- SF Symbols are reachable only as private-use codepoints rendered in the menu bar font, since `hs.image` cannot resolve them by name.
--- They are drawn from SF Pro, which is an Apple download rather than part of macOS: without it this renders as a missing-glyph box.
obj.menubarTitle = utf8.char(0x100468)

--- PictureInPicture.menubarFont
--- Variable
--- Font for the menubar title, as `hs.styledtext` understands it. Defaults to the menu bar font at 14pt.
---
--- No colour is set deliberately, so AppKit's default menubar label colour applies and follows light and dark appearance on its own.
obj.menubarFont = { name = hs.styledtext.defaultFonts.menuBar.name, size = 14 }

--- PictureInPicture.alertDuration
--- Variable
--- Seconds an alert stays on screen. Defaults to `2`.
obj.alertDuration = 2

--- PictureInPicture.chromeShortcut
--- Variable
--- The Chrome shortcut to forward, as `{ modifiers, key }`. Defaults to `{ { "alt" }, "p" }`.
---
--- This is Chrome's whole Picture in Picture story: the browser will not let an outside caller enter it, but it will act on its own shortcut, and invoking an extension action is a user gesture as far as the page is concerned.
--- The default matches the suggested key of Google's Picture-in-Picture extension. Change it here to whatever `chrome://extensions/shortcuts` says, since the two have to agree and only Chrome knows the truth.
--- Nothing verifies the extension is installed, because nothing outside Chrome can: a missing extension makes this a silent no-op.
obj.chromeShortcut = { { "alt" }, "p" }

-- Internal state

-- Fields rather than locals in start(): userdata whose __gc would tear down the real resource
obj.running = false

obj.menubarItem = nil
obj.appWatcher = nil
obj.frontBundle = nil
obj.jsBlocked = {}
obj.warned = {}

-- Keyed by bundle id rather than name, which is localised and renamed between releases. `app` is what the tell block needs, and `jsMenu` only Safari has, since Chrome is never sent an Apple Event
local BROWSERS = {
  ["com.apple.Safari"] = {
    app = "Safari",
    dialect = "safari",
    jsMenu = "Develop > Allow JavaScript from Apple Events",
  },
  ["com.google.Chrome"] = {
    app = "Google Chrome",
    dialect = "chrome",
  },
}

-- Injected JavaScript

-- A page's video is often inside a player frame rather than the top document. Same-origin frames are reachable; cross-origin ones throw on .document and are skipped, which is why the recursion is wrapped rather than guarded
local FIND_VIDEO = [[
  function find(d) {
    var v = d.querySelector('video');
    if (v) return v;
    var w = d.defaultView;
    for (var i = 0; w && i < w.frames.length; i++) {
      try { var f = find(w.frames[i].document); if (f) return f; } catch (e) {}
    }
    return null;
  }
]]

-- WebKit's own API rather than the standard one: it predates the transient-activation rule and so still answers an Apple Event. Returns the status string that report() reads
local SAFARI_JS = "(function () {"
  .. FIND_VIDEO
  .. [[
  var v = find(document);
  if (!v) return 'no-video';
  if (typeof v.webkitSetPresentationMode !== 'function') return 'unsupported';
  try {
    var on = v.webkitPresentationMode === 'picture-in-picture';
    v.webkitSetPresentationMode(on ? 'inline' : 'picture-in-picture');
    return on ? 'exit' : 'enter';
  } catch (e) { return 'error:' + e.name; }
})()]]

-- Stateless helpers

-- AppleScript string literals cannot span lines, so the JavaScript is flattened before it is embedded. Safe here only because none of it relies on newline-driven semicolon insertion, and none of its own strings contain runs of whitespace
local function flatten(js)
  return (js:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- AppleScript escapes exactly two characters inside a literal
local function quote(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Spoken by Safari only. `front document` resolves without the app being frontmost, so nothing is activated and no window is raised
local function safariScript()
  return string.format(
    'tell application "Safari"\n  do JavaScript %s in front document\nend tell',
    quote(flatten(SAFARI_JS))
  )
end

-- Browser detection

function obj:warnOnce(key, fmt, ...)
  if self.warned[key] then return end
  self.warned[key] = true
  self.logger.w(string.format(fmt, ...))
end

-- Reports a toggle that could not be attempted at all, as opposed to one attempted and refused
function obj:reportFailure(what, why)
  self.logger.ef("could not %s: %s", what, tostring(why))
  hs.alert.show(string.format("Could not %s\n%s", what, tostring(why)), self.alertDuration + 1)
  return self
end

-- By pid rather than win:application(): that returns nil transiently even for a live process, and logs the failure from C where a pcall cannot swallow it
function obj:focusedBundle()
  local win = hs.window.focusedWindow()
  if not win then return nil end
  local okPid, pid = pcall(win.pid, win)
  if not okPid or not pid then return nil end
  local okApp, app = pcall(hs.application.applicationForPID, pid)
  if not okApp or not app then return nil end
  local okId, bundle = pcall(app.bundleID, app)
  if not okId then return nil end
  return bundle
end

-- Falls back to the watcher's record, since a menubar menu is built with no focused window of its own
function obj:resolveBrowser()
  local bundle = self:focusedBundle()
  if bundle and BROWSERS[bundle] then return BROWSERS[bundle], bundle end
  if self.frontBundle and BROWSERS[self.frontBundle] then return BROWSERS[self.frontBundle], self.frontBundle end
  return nil, bundle
end

-- Apple Events

-- Returns the script's value, or nil once the failure has been reported
function obj:runScript(bundle, script)
  local browser = BROWSERS[bundle]
  local ok, result, descriptor = hs.osascript.applescript(script)
  if ok then
    self.jsBlocked[bundle] = nil
    return result
  end

  local info = type(descriptor) == "table" and descriptor or {}
  local message = tostring(info.NSLocalizedDescription or info.OSAScriptErrorMessage or "unknown error")
  local number = tonumber(info.NSAppleScriptErrorNumber)

  if number == -1743 then
    self.logger.ef("automation permission denied for %s: %s", browser.app, message)
    hs.alert.show(
      string.format("Allow Hammerspoon to control %s\nSystem Settings > Privacy & Security > Automation", browser.app),
      self.alertDuration + 2
    )
    return nil
  end

  -- Safari answers the generic -10000, and do JavaScript is the only thing it is ever sent, so the setting is the overwhelmingly likely cause
  if message:lower():find("applescript") or message:lower():find("apple event") or number == -10000 then
    self.jsBlocked[bundle] = true
    self:updateMenubar()
    self.logger.ef("%s refused the script: %s", browser.app, message)
    hs.alert.show(string.format("Enable %s\nin %s", browser.jsMenu, browser.app), self.alertDuration + 2)
    return nil
  end

  self:reportFailure(string.format("toggle Picture in Picture in %s", browser.app), message)
  return nil
end

-- Anything the page reports back, turned into something worth reading. Safari's alone, since Chrome answers nothing at all. enter and exit say nothing: the PiP window is its own confirmation
function obj:report(status, browser)
  status = tostring(status or "unknown")
  if status == "enter" or status == "exit" then
    self.logger.df("%s picture in picture in %s", status, browser.app)
    return
  end

  local message
  if status == "no-video" then
    message = "No video on this page"
  elseif status == "unsupported" then
    message = string.format("%s cannot put this video in Picture in Picture", browser.app)
  elseif status:sub(1, 6) == "error:" then
    message = string.format("%s refused: %s", browser.app, status:sub(7))
  else
    message = string.format("%s answered %s", browser.app, status)
  end

  self.logger.wf("toggle in %s returned %s", browser.app, status)
  hs.alert.show(message, self.alertDuration)
end

function obj:toggleSafari(bundle, browser)
  local status = self:runScript(bundle, safariScript())
  if status ~= nil then self:report(status, browser) end
end

-- Chrome's own shortcut rather than an Apple Event, because Chrome will not enter Picture in Picture for an outside caller at all: the web APIs demand a user gesture that injected JavaScript can never have, and an extension action is the browser handing one out
-- Posted at the application rather than broadcast, and Chrome claims the chord before the page sees it, so nothing lands in a focused text field
-- Nothing comes back: whether the extension is installed, or found a video, is Chrome's business and is invisible from here
function obj:toggleChrome(bundle, browser)
  local app = hs.application.get(bundle)
  local mods, key = self.chromeShortcut[1], self.chromeShortcut[2]
  local ok, err = pcall(hs.eventtap.keyStroke, mods, key, 0, app)
  if not ok then self:reportFailure(string.format("send the shortcut to %s", browser.app), err) end
  return self
end

-- Menubar

-- The chord as a person reads it, for the menu and the tooltip
function obj:shortcutLabel()
  local glyphs = { alt = "⌥", cmd = "⌘", ctrl = "⌃", shift = "⇧" }
  local out = ""
  for _, mod in ipairs(self.chromeShortcut[1] or {}) do
    out = out .. (glyphs[mod:lower()] or mod)
  end
  return out .. tostring(self.chromeShortcut[2]):upper()
end

function obj:buildMenu()
  local browser, bundle = self:resolveBrowser()
  local menu = {
    {
      title = "Toggle Picture in Picture",
      disabled = browser == nil,
      fn = function()
        self:toggle()
      end,
    },
    { title = "-" },
  }
  if browser then
    menu[#menu + 1] = { title = string.format("Front browser: %s", browser.app), disabled = true }
    if self.jsBlocked[bundle] then
      menu[#menu + 1] = { title = string.format("Blocked: enable %s", browser.jsMenu), disabled = true }
    elseif browser.dialect == "chrome" then
      -- Named rather than merely done: Chrome answers nothing, so a missing extension is silence, and this line is the only clue to where it went
      menu[#menu + 1] = { title = string.format("Forwards %s to the extension", self:shortcutLabel()), disabled = true }
    end
  else
    menu[#menu + 1] = { title = "No supported browser in front", disabled = true }
  end
  return menu
end

function obj:updateMenubar()
  if not self.menubarItem then return end
  -- Styled for the size only. Leaving the colour out is what keeps AppKit's own menubar label colour, and with it light and dark appearance for free
  self.menubarItem:setTitle(hs.styledtext.new(self.menubarTitle, { font = self.menubarFont }))
  local browser, bundle = self:resolveBrowser()
  if not browser then
    self.menubarItem:setTooltip("No supported browser in front")
  elseif self.jsBlocked[bundle] then
    self.menubarItem:setTooltip(string.format("%s is blocking Apple Events JavaScript", browser.app))
  elseif browser.dialect == "chrome" then
    self.menubarItem:setTooltip(
      string.format("Toggle Picture in Picture by sending %s to Chrome", self:shortcutLabel())
    )
  else
    self.menubarItem:setTooltip(string.format("Toggle Picture in Picture in %s", browser.app))
  end
end

-- Kept current by the watcher rather than fetched on open, since hs.menubar wants its menu synchronously and a clicked menubar leaves no focused window to read
function obj:onAppEvent(_, event, app)
  if event ~= hs.application.watcher.activated then return end
  local okId, bundle = pcall(app.bundleID, app)
  if not okId then return end
  self.frontBundle = bundle
  self:updateMenubar()
end

-- Spoon API

--- PictureInPicture:init() -> self
--- Method
--- Prepares the Spoon. Called automatically by `hs.loadSpoon()`.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PictureInPicture object
---
--- Deliberately starts nothing. The menubar item and the application watcher both belong to `PictureInPicture:start()`.
function obj:init()
  return self
end

--- PictureInPicture:toggle() -> self
--- Method
--- Puts the front tab's video into Picture in Picture, or takes it out again.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PictureInPicture object
---
--- Does nothing but say so when the focused window belongs to neither Safari nor Google Chrome. Nothing is sent in that case, so an unsupported application is never asked for permission it does not need to grant.
---
--- What "does it" means differs by browser. Safari is told outright, and answers, so a page with no video says so. Chrome is only handed `PictureInPicture.chromeShortcut` and never replies, so a missing extension, a page with no video and a working toggle are indistinguishable from here.
function obj:toggle()
  local browser, bundle = self:resolveBrowser()
  if not browser then
    hs.alert.show("No Safari or Chrome window in front", self.alertDuration)
    return self
  end

  if browser.dialect == "safari" then
    self:toggleSafari(bundle, browser)
  else
    self:toggleChrome(bundle, browser)
  end
  return self
end

--- PictureInPicture:start() -> self
--- Method
--- Places the menubar item and begins tracking which application is in front.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PictureInPicture object
function obj:start()
  if self.running then self:stop() end

  self.appWatcher = hs.application.watcher.new(function(name, event, app)
    local ok, err = pcall(self.onAppEvent, self, name, event, app)
    if not ok then self.logger.ef("app event failed: %s", tostring(err)) end
  end)
  if self.appWatcher then
    self.appWatcher:start()
  else
    self:warnOnce("watcher", "could not create the application watcher; the menu will read the focused window instead")
  end

  self.frontBundle = self:focusedBundle()

  if self.showInMenubar then
    -- The autosave name keys the saved menu bar position: unique, and never renamed
    self.menubarItem = hs.menubar.new(true, "pictureinpicture")
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
            title = "Toggle Picture in Picture",
            fn = function()
              self:toggle()
            end,
          },
        }
      end)
      self:updateMenubar()
    else
      self:warnOnce("menubar", "could not create the menubar item")
    end
  end

  self.running = true
  self.logger.i("started")
  return self
end

--- PictureInPicture:stop() -> self
--- Method
--- Stops tracking the front application and removes the menubar item.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PictureInPicture object
---
--- Clears the record of which browsers were refusing Apple Events, so turning the setting on and reloading re-probes rather than believing what it was told last time.
--- Any hotkeys bound with `PictureInPicture:bindHotkeys()` stay bound; rebind or delete them separately if you want them gone.
function obj:stop()
  -- Field NAMES, not handles: ipairs over handles halts at the first nil and skips the rest
  for _, name in ipairs({ "appWatcher" }) do
    local handle = self[name]
    -- pcall: stop() reaches into a framework that may already be tearing down
    if handle then pcall(handle.stop, handle) end
    self[name] = nil
  end

  if self.menubarItem then
    self.menubarItem:delete()
    self.menubarItem = nil
  end

  self.frontBundle = nil
  self.jsBlocked = {}
  self.warned = {}
  self.running = false
  self.logger.i("stopped")
  return self
end

--- PictureInPicture:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for this Spoon.
---
--- Parameters:
---  * mapping - a table containing hotkey modifier/key details for the following items:
---    * toggle - put the front tab's video into Picture in Picture, or take it out again
---
--- Returns:
---  * The PictureInPicture object
---
--- For example: `spoon.PictureInPicture:bindHotkeys({ toggle = { { "cmd", "alt", "ctrl" }, "P" } })`
function obj:bindHotkeys(mapping)
  local spec = {
    toggle = hs.fnutils.partial(self.toggle, self),
  }
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  -- HSKeybindings.spoon walks loaded Spoons looking for a `mapping` field to display
  self.mapping = mapping
  return self
end

--- PictureInPicture:status() -> table
--- Method
--- Returns the Spoon's current state, for poking at from the Hammerspoon Console.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `running`, `menubar`, `frontBundle`, `browser`, `chromeShortcut` and `blocked` keys
---
--- `browser` is nil whenever the front application is neither Safari nor Google Chrome, which is exactly when `PictureInPicture:toggle()` declines to do anything. `blocked` lists the browsers that have refused to run JavaScript from an Apple Event since the Spoon last started.
function obj:status()
  local browser = self:resolveBrowser()
  local blocked = {}
  for bundle in pairs(self.jsBlocked) do
    blocked[#blocked + 1] = BROWSERS[bundle] and BROWSERS[bundle].app or bundle
  end
  return {
    running = self.running,
    menubar = self.menubarItem ~= nil,
    frontBundle = self.frontBundle,
    browser = browser and browser.app or nil,
    chromeShortcut = self:shortcutLabel(),
    blocked = blocked,
  }
end

return obj
