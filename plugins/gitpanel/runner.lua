-- Nonblocking process pump. Call run from a core.add_thread coroutine.
local process = require "process"
local system = require "system"
local M = {}
local LIMIT = 8 * 1024 * 1024

function M.run(argv, cwd, input)
  local ok, proc, message = pcall(process.start, argv, {
    cwd = cwd, stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE,
    env = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "Never", LC_ALL = "C" }
  })
  if not ok or not proc then return nil, "", tostring(ok and message or proc) end
  local output, errors, bytes, offset = {}, {}, 0, 1
  local closed, eof = false, {}
  local started = system.get_time()
  local failure
  input = input or ""
  local function drain(stream, target)
    if eof[stream] then return end
    -- Bounded work per tick; service stderr and stdin even with busy stdout.
    for _ = 1, 16 do
      local chunk, err, code = proc:read(stream, 16384)
      if chunk and #chunk > 0 then
        bytes = bytes + #chunk
        if bytes > LIMIT then failure = "Git output exceeded 8 MiB. Operation may have partially completed; refresh before retrying or use Git externally."; return end
        target[#target + 1] = chunk
      elseif chunk == "" then
        -- Lite XL versions can return an empty string for a nonblocking read
        -- with no data. Only treat it as EOF once the child has exited.
        if not proc:running() then eof[stream] = true end
        return
      elseif code == process.ERROR_WOULDBLOCK then
        -- Native Lite XL also uses WOULD_BLOCK for an exhausted pipe after
        -- waitpid has reaped the child. No more bytes can arrive at that point.
        if not proc:running() then eof[stream] = true end
        return
      else
        -- Some Lite XL builds signal EOF with nil and no error.
        if not err and not code then
          if not proc:running() then eof[stream] = true end
        else failure = err or ("Git pipe error " .. tostring(code)) end
        return
      end
    end
  end
  while true do
    drain(process.STREAM_STDOUT, output)
    drain(process.STREAM_STDERR, errors)
    if not closed then
      if offset > #input then
        proc:close_stream(process.STREAM_STDIN)
        closed = true
      else
        local count, err, code = proc:write(input:sub(offset, offset + 16383))
        if count and count > 0 then offset = offset + count
        elseif code ~= process.ERROR_WOULDBLOCK then failure = err or "Git closed its input pipe" end
      end
    end
    local running = proc:running()
    if not running and eof[process.STREAM_STDOUT] and eof[process.STREAM_STDERR] then break end
    if system.get_time() - started > 120 then
      failure = "Git exceeded 120 seconds (check hooks/signing externally). Operation may have partially completed; refresh before retrying."
    end
    if failure then
      pcall(proc.kill, proc)
      -- Reap asynchronously; never block Lite XL on a child process.
      for _ = 1, 100 do
        if not proc:running() then break end
        coroutine.yield(0.01)
      end
      pcall(proc.wait, proc, 0)
      return nil, table.concat(output), failure .. "\n" .. table.concat(errors)
    end
    coroutine.yield(0.01)
  end
  local code = proc:returncode()
  if code == nil then code = proc:wait(0) end
  return code, table.concat(output), table.concat(errors)
end

return M
