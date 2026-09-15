-- Python executes argv requests shell-free against disposable fixtures. This
-- exercises the production Model:comparison and parser, not a reimplementation.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local userdir = base:match("^(.*)/plugins/gitpanel$")
package.path = userdir .. "/?.lua;" .. userdir .. "/?/init.lua;" .. package.path
local function put(text) io.write(#text, "\n", text) end
local function get() local size = assert(tonumber(io.read("*l"))); return size > 0 and assert(io.read(size)) or "" end
local threads, error_message = {}, nil
local core = { project_dir = arg[1], error = function(_, err) error_message = err end,
  add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end }
package.loaded.core = core
package.loaded["plugins.gitpanel.runner"] = { run = function(argv, cwd)
  io.write("REQUEST\n", #argv, "\n")
  for _, value in ipairs(argv) do put(value) end
  put(cwd); io.flush()
  return tonumber(io.read("*l")), get(), get()
end }
local Model = require "plugins.gitpanel.model"
local model = Model.new()
model.context, model.root = { project = arg[1], generation = 1 }, arg[1]
local result
model:comparison({ path = arg[3], x = arg[4], y = arg[5], old_path = arg[6] ~= "" and arg[6] or nil }, arg[2], function(data) result = data end)
for _, co in ipairs(threads) do
  while coroutine.status(co) ~= "dead" do local ok, err = coroutine.resume(co); assert(ok, err) end
end
io.write("RESULT\n")
result = result or { unsupported = error_message or "No result" }
for _, key in ipairs({ "original", "modified", "patch", "unsupported" }) do put(result[key] or "") end
io.write(result.lines and #result.lines[1] or 0, "\n", result.lines and #result.lines[2] or 0, "\n", result.rows and #result.rows or 0, "\n")
if result.rows then
  for _, row in ipairs(result.rows) do io.write(row[1] or 0, ",", row[2] or 0, ",", row.changed and 1 or 0, "\n") end
end
io.flush()
