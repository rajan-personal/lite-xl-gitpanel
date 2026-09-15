-- Execute the production model/direct scheduling/helper protocol in temp Git fixtures.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local userdir = base:match("^(.*)/plugins/gitpanel$")
package.path = userdir .. "/?.lua;" .. userdir .. "/?/init.lua;" .. package.path
local function put(text) io.write(#text, "\n", text) end
local function get() local n = assert(tonumber(io.read("*l"))); return n > 0 and assert(io.read(n)) or "" end
local threads, errors, reloads, dialogs, snapshots = {}, {}, 0, 0, 0
local core = { project_dir = arg[1], docs = {},
  error = function(_, err) errors[#errors + 1] = err end, log = function() end,
  add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end }
package.loaded.core = core
package.loaded["plugins.gitpanel.documents"] = { reload_clean = function() reloads = reloads + 1 end }
package.loaded["plugins.gitpanel.documents"].capture_affected = function() return {} end
package.loaded["plugins.gitpanel.documents"].invalidate_affected = function() end
package.loaded["plugins.gitpanel.documents"].affected_live = function() return false end
package.loaded["plugins.gitpanel.reloadguard"] = { begin = function() return function() end end }
-- Exercise the production runner too: only process I/O crosses to Python.
package.loaded.system = { get_time = os.clock }
package.loaded.process = {
  REDIRECT_PIPE = 1, STREAM_STDIN = 0, STREAM_STDOUT = 1, STREAM_STDERR = 2,
  ERROR_WOULDBLOCK = -2,
  start = function(argv, options)
    local p = { input = "", streams = {} }
    function p:write(input) self.input = self.input .. input; return #input end
    function p:close_stream()
      io.write("REQUEST\n", #argv, "\n")
      for _, value in ipairs(argv) do put(value) end
      put(options.cwd); put(self.input); io.flush()
      self.code, self.streams[1], self.streams[2] = tonumber(io.read("*l")), get(), get()
      if argv[4] == "snapshot" then
        snapshots = snapshots + 1
        if snapshots == 2 and arg[5] == "dirty-preflight" then core.docs = {{is_dirty = function() return true end}} end
        if snapshots == 2 and arg[5] == "project-preflight" then core.project_dir = "/stale-project" end
        if snapshots == 2 and arg[5] == "root-preflight" then core.rebind_root() end
      end
    end
    function p:read(stream, count)
      if not self.code then return nil, "would block", -2 end
      local data = self.streams[stream]
      self.streams[stream] = data:sub(count + 1)
      return data:sub(1, count)
    end
    function p:running() return self.code == nil end
    function p:returncode() return self.code end
    function p:wait() return self.code end
    function p:kill() error("Unexpected runner failure") end
    return p
  end,
}
local Model = require "plugins.gitpanel.model"
local model = Model.new()
model.context, model.root, model.status = {project = arg[1], generation = 1}, arg[1], {}
core.nag_view = { show = function() dialogs = dialogs + 1; error("Discard must never invoke NagView") end }
core.rebind_root = function() model.root = "/stale-root" end
local data
local comparison = model.comparison
model.comparison = function(self, entry, group, callback)
  return comparison(self, entry, group, function(result)
    data = result
    callback(result)
  end)
end
if arg[5] == "file-entry" or arg[5] == "file-entry-duplicate" or arg[5] == "bind-file-entry" then
  local entry = {path=arg[2], x=arg[6] or "M", y=arg[3], status=(arg[6] or "M") .. arg[3]}
  if arg[5] == "bind-file-entry" then
    model.context = nil
    model:bind(arg[1])
    model:enqueue("Discard after root discovery", false, function() model:discard_file(entry, "changes") end)
  else model:discard_file(entry, "changes") end
  if arg[5] == "file-entry-duplicate" then model:discard_file(entry, "changes") end
else
model:comparison({path=arg[2], x=arg[6] or "M", y=arg[3], status=(arg[6] or "M") .. arg[3]}, "changes", function(result)
  data = result
  io.write("CAPTURED\n"); io.flush(); assert(io.read("*l") == "continue")
  if arg[5] == "root-queued" then model.root = "/stale-root" end
  if arg[5] == "generation-queued" then model.context = {project=arg[1],generation=2} end
  if arg[5] == "dirty-initial" then core.docs = {{is_dirty=function() return true end}} end
  model:discard(result, tonumber(arg[4]))
  if arg[5] == "duplicate" then model:discard(result, tonumber(arg[4])) end
end)
end
local function flush()
  for _, co in ipairs(threads) do while coroutine.status(co) ~= "dead" do local ok, err = coroutine.resume(co); assert(ok, err) end end
end
flush()
if arg[5] == "repeat" then model:discard(data, tonumber(arg[4])); flush() end
io.write("RESULT\n", reloads, "\n", dialogs, "\n", data and data.invalidated and 1 or 0, "\n")
put(table.concat(errors, "\n")); io.flush()
