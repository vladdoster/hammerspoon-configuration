-- vim: set expandtab filetype=lua shiftwidth=2 softtabstop=2 tabstop=2 textwidth=120:
local M = {}

M.font = { name = "ServerMono-Regular", size = 12 }

M.logColors = {
  name = { red = 0.2, green = 0.85, blue = 0.85 },
  error = { red = 1, green = 0.35, blue = 0.35 },
}

-- Indexed by hs.logger level: 1 is error, 2 is warning
local levelLabels = { "ERROR: ", "Warning: " }

local hooks -- where the stock writers live, so a failure can put them back
local pendingRuns -- styled { text, color } runs for the line that the next print() call writes
local mode = "direct" -- "queue" holds lines in Lua, "raw" sends plain text to the Console buffer
local queue = {}
local settle
local appended = 0
local writing = false
local logDepth = 0

local function findUpvalue(fn, name)
  for i = 1, math.huge do
    local upvalueName, value = debug.getupvalue(fn, i)
    if upvalueName == nil then return nil end
    if upvalueName == name then return i, value end
  end
end

local function styledLine(runs)
  local font, color = hs.console.consoleFont(), hs.console.consolePrintColor()
  local line = hs.styledtext.new(os.date("%Y-%m-%d %H:%M:%S: "), { font = font, color = color })
  for _, run in ipairs(runs) do
    line = line .. hs.styledtext.new(run[1], { font = font, color = run[2] or color })
  end
  return line
end

-- printStyledtext skips the Console length limit, so apply the limit here
local function write(line)
  hs.console.printStyledtext(line)
  local max = hs.console.maxOutputHistory()
  appended = appended + #line
  if max > 0 and appended > max / 10 then
    appended = 0
    local text = hs.console.getConsole(true)
    if #text > max then hs.console.setConsole(text:sub(#text - max + 1)) end
  end
end

local function flush()
  local lines = queue
  queue = {}
  for _, entry in ipairs(lines) do
    write(entry.line)
  end
end

local function unhook(err)
  debug.setupvalue(hooks.logger, hooks.writerIndex, hooks.writer)
  debug.setupvalue(hooks.print, hooks.sinkIndex, hooks.sink)
  for _, entry in ipairs(queue) do
    hooks.sink(entry.text)
  end
  queue = {}
  hooks.sink("console: styled output is off: " .. tostring(err) .. "\n")
end

-- Replaces hs._logmessage, which buffers text until the next 0.2 s Console tick
local function sink(str)
  local runs = pendingRuns or { { (str:gsub("\n$", "")), str:find("^%*%*%* ERROR:") and M.logColors.error } }
  pendingRuns = nil
  -- A print from inside this function, such as a lazy "Loading extension" line, would call it again
  if writing then return hooks.sink(str) end
  if mode == "raw" then
    settle:start()
    return hooks.sink(str)
  end

  writing = true
  local ok, err = pcall(function()
    local line = styledLine(runs)
    if mode == "queue" then
      queue[#queue + 1] = { line = line, text = str }
      settle:start()
    else
      write(line)
    end
  end)
  writing = false
  if not ok then
    hooks.sink(str)
    unhook(err)
  end
end

-- Replaces the writer that every hs.logger instance shares
local function logWriter(loglevel, level, id, fmt, ...)
  -- Level 0 lets hs.logger record its history without printing
  hooks.writer(0, level, id, fmt, ...)
  if loglevel < level then return end

  local name, message = id:lower(), (levelLabels[level] or "") .. string.format(fmt, ...)
  local text = string.format("[%s] %s", name, message)
  pendingRuns = { { "[" }, { name, M.logColors.name }, { "] " }, { message, level == 1 and M.logColors.error } }
  -- hs.ipc logs from inside print(), so a nested log call skips print() to stop a loop
  logDepth = logDepth + 1
  local ok, err
  if logDepth > 1 then
    ok, err = pcall(sink, text .. "\n")
  else
    ok, err = pcall(print, text)
  end
  logDepth = logDepth - 1
  pendingRuns = nil
  if not ok then error(err, 0) end
end

-- Formats log lines as "[name] message" and writes all output as styled text
-- hs.logger and print() keep their writers in local variables, so this replaces them through debug upvalues
M.styleLogs = function()
  if hooks then return end
  -- Load these now: loading one later prints a line from inside the sink
  local _ = hs.styledtext and hs.timer

  local probe = hs.logger.new("console")
  local writerIndex, writer = findUpvalue(probe.f, "lf")
  local printFn, sinkIndex, rawSink = print, nil, nil
  while printFn and not sinkIndex do
    sinkIndex, rawSink = findUpvalue(printFn, "logmessage")
    if not sinkIndex then printFn = select(2, findUpvalue(printFn, "originalPrint")) end
  end
  if not (writerIndex and sinkIndex) then
    probe.w("log writers not found; log lines keep the stock format")
    return
  end
  hooks = {
    logger = probe.f,
    writerIndex = writerIndex,
    writer = writer,
    print = printFn,
    sinkIndex = sinkIndex,
    sink = rawSink,
  }

  -- Styled text goes on screen at once, so it waits until the Console shows what it buffered before now
  settle = hs.timer.delayed.new(0.3, function()
    flush()
    mode = "direct"
  end)
  mode = "queue"
  settle:start()

  debug.setupvalue(probe.f, writerIndex, logWriter)
  debug.setupvalue(printFn, sinkIndex, sink)

  -- The Console buffers a command and its result, so output during a command goes to the same buffer
  local previous = hs._consoleInputPreparser
  hs._consoleInputPreparser = function(command)
    flush()
    mode = "raw"
    settle:start()
    return previous and previous(command) or command
  end
end

M.setup = function()
  hs.console.darkMode(true)
  hs.console.consoleFont(M.font)
  hs.console.windowBackgroundColor({ white = 0.1 })
  hs.console.outputBackgroundColor({ white = 0.1 })
  hs.console.inputBackgroundColor({ white = 0.15 })
  hs.console.consolePrintColor({ white = 0.85 })
  hs.console.consoleCommandColor({ white = 1 })
  hs.console.consoleResultColor({ red = 0.55, green = 0.8, blue = 1 })
  M.styleLogs()
end

M.bindHotkeys = function(mapping)
  hs.hotkey.bind(mapping.toggle[1], mapping.toggle[2], hs.toggleConsole)
end

return M
