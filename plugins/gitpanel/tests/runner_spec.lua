local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
local clock, current = 0, nil
local process = { REDIRECT_PIPE = 1, STREAM_STDIN = 0, STREAM_STDOUT = 1, STREAM_STDERR = 2, ERROR_WOULDBLOCK = -2 }
local scenario, spawned
function process.start(argv, options)
  spawned = argv
  if scenario.spawn_error then return nil, "cannot execute git" end
  if scenario.spawn_throw then error("spawn exception") end
  check(type(argv) == "table" and options.stdin == 1 and options.stdout == 1 and options.stderr == 1, "argv API and independent nonblocking pipes")
  local p = { tick = 0, input = "", reads = {}, closed = false }
  current = p
  function p:running() return not self.killed and self.tick < (scenario.exit_tick or 4) end
  function p:read(stream, len)
    if scenario.pipe_error then return nil, "pipe broken", -1 end
    local chunks = scenario[stream] or {}
    local index = (self.reads[stream] or 0) + 1
    local chunk = chunks[index]
    if chunk and self.tick >= chunk[1] then self.reads[stream] = index; return chunk[2] end
    if scenario.exhausted_wouldblock or scenario.wouldblock and self:running() then return nil, "would block", -2 end
    return "" -- Older API behavior: empty before child emits output.
  end
  function p:write(input)
    if scenario.write_error then return nil, "input broken", -1 end
    if self.tick == 0 then return nil, "would block", -2 end
    local part = input:sub(1, 3)
    self.input = self.input .. part
    return #part
  end
  function p:close_stream(stream) self.closed = stream == 0; return 0 end
  function p:returncode() if not self:running() then return scenario.code or 0 end end
  function p:wait() return self:returncode() end
  function p:kill() self.killed = true end
  return p
end
package.loaded.process = process
package.loaded.system = { get_time = function() return clock end }
local runner = dofile(base .. "/runner.lua")
local function run(s, input, argv)
  scenario, clock, current = s, 0, nil
  local co = coroutine.create(function() return runner.run(argv or { "git", "status" }, "/fixture", input) end)
  for _ = 1, 200 do
    local ok, code, out, err = coroutine.resume(co)
    assert(ok, code)
    if coroutine.status(co) == "dead" then return code, out, err end
    clock = clock + (s.clock_step or 0.02)
    current.tick = current.tick + 1
  end
  error("Runner failed to terminate")
end
local code, out, err = run({ [1] = {{2, "late stdout"}}, [2] = {{1, "early stderr"}}, exit_tick = 8 }, "abcdefghijk")
check(code == 0 and out == "late stdout" and err == "early stderr", "empty reads while running are not treated as EOF")
check(current.input == "abcdefghijk" and current.closed, "partial writes retry and stdin closes after complete message")
check(spawned[1] == "python3" and spawned[2] == "-I" and spawned[3] == base .. "/git_env.py"
  and spawned[4] == "status", "all Git commands use isolated environment wrapper")
local literal = { "git", "--literal-pathspecs", "-C", "/fixture with spaces", "diff", "--", ":(literal) é\nfile" }
run({}, nil, literal)
check(#spawned == #literal + 2 and spawned[6] == literal[4] and spawned[9] == literal[7]
  and literal[1] == "git", "wrapper preserves literal arguments without mutating caller argv")
local helper = { "python3", "-I", base .. "/discard.py", "snapshot" }
run({}, nil, helper)
check(spawned == helper, "non-Git helper commands are not wrapped")
code, out, err = run({ [1] = {{1, "out"}}, [2] = {{2, "failure detail"}}, code = 7, wouldblock = true })
check(code == 7 and out == "out" and err == "failure detail", "nonzero exit retains both streams and would-block is retried")
code, out, err = run({ [1] = {{1, "root\n"}}, exhausted_wouldblock = true })
check(code == 0 and out == "root\n" and clock < 1, "exhausted WOULD_BLOCK pipes after child exit finish without waiting for timeout")
code, out, err = run({spawn_error = true})
check(code == nil and err:find("cannot execute"), "spawn failure surfaced")
code, out, err = run({spawn_throw = true})
check(code == nil and err:find("spawn exception"), "spawn exception contained")
code, out, err = run({pipe_error = true})
check(code == nil and err:find("pipe broken") and current.killed, "pipe failure kills and reports child")
code, out, err = run({write_error = true}, "message")
check(code == nil and err:find("input broken"), "stdin failure surfaced")
code, out, err = run({exit_tick = 10000, clock_step = 61})
check(code == nil and err:find("120 seconds") and current.killed, "timeout kills without blocking and warns of partial completion")
code, out, err = run({[1] = {{0, string.rep("x", 8 * 1024 * 1024 + 1)}}})
check(code == nil and err:find("8 MiB") and current.killed, "oversized output is a visible error, never parsed as complete status")
print(checks .. " runner checks passed (mock process).")
