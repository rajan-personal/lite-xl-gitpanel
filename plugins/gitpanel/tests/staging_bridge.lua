local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local userdir = base:match("^(.*)/plugins/gitpanel$")
package.path = userdir .. "/?.lua;" .. userdir .. "/?/init.lua;" .. package.path
local function put(text) io.write(#text, "\n", text) end
local function get() local n = assert(tonumber(io.read("*l"))); return n > 0 and assert(io.read(n)) or "" end
local threads, errors, snapshots = {}, {}, 0
local core = {project_dir=arg[1], docs={}, error=function(_, e) errors[#errors+1]=e end, log=function() end,
  add_thread=function(fn) threads[#threads+1]=coroutine.create(fn) end}
package.loaded.core = core
local model
package.loaded["plugins.gitpanel.runner"] = {run=function(argv, cwd, input)
  io.write("REQUEST\n", #argv, "\n")
  for _, value in ipairs(argv) do put(value) end
  put(cwd); put(input or ""); io.flush()
  local code, out, err = tonumber(io.read("*l")), get(), get()
  if argv[3] and argv[3]:match("/staging.py$") and argv[4] == "snapshot" then
    snapshots = snapshots + 1
    if snapshots == 2 and arg[7] == "root-preflight" then model.root = "/stale-root" end
    if snapshots == 2 and arg[7] == "project-preflight" then core.project_dir = "/stale-project" end
    if snapshots == 2 and arg[7] == "generation-preflight" then model.context = {project=arg[1], generation=2} end
  end
  return code, out, err
end}
local Model = require "plugins.gitpanel.model"
local staging = require "plugins.gitpanel.staging"
staging.ENABLED = arg[7] ~= "disabled"
model = Model.new()
model.context, model.root, model.status = {project=arg[1], generation=1}, arg[1], {}
local data
model:comparison({path=arg[2], x=arg[4], y=arg[5], status=arg[4]..arg[5]}, arg[3], function(result)
  data=result
  if arg[7] == "root-loaded" then model.root = "/stale-root" end
  if arg[7] == "cancel" then return end
  if arg[7] == "selection-left" or arg[7] == "selection-right" then
    local ok, first, last = pcall(require("plugins.gitpanel.diff").selection_rows, data,
      arg[7] == "selection-left" and 1 or 2, tonumber(arg[8]), tonumber(arg[9]), tonumber(arg[10]), tonumber(arg[11]))
    if ok then model:stage_selection(data, nil, first, last) else errors[#errors+1]=first end
  else
    model:stage_selection(data, tonumber(arg[6]), tonumber(arg[8]), tonumber(arg[9]))
  end
end)
local function flush()
  for _, co in ipairs(threads) do while coroutine.status(co) ~= "dead" do local ok,e=coroutine.resume(co); assert(ok,e) end end
end
flush()
if arg[7] == "repeat" then model:stage_selection(data, tonumber(arg[6])); flush() end
io.write("RESULT\n", data and data.invalidated and 1 or 0, "\n")
put(table.concat(errors, "\n")); put(data and data.staging_reason or ""); io.flush()
