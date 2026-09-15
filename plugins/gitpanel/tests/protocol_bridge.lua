local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local git = dofile(base .. "/git.lua")
local function emit(values) io.write(table.concat(values, "\0"), "\0") end
if arg[1] == "status" then
  local s = git.status(io.read("*a"))
  emit({ s.branch or "", tostring(s.unborn), tostring(s.detached), tostring(s.count) })
  for _, group in ipairs({ "staged", "changes", "untracked", "conflicts" }) do
    for _, e in ipairs(s[group]) do emit({ group, e.path, e.x, e.y, e.old_path or "" }) end
  end
elseif arg[1] == "stage" then
  emit(git.stage_args(arg[2], arg[3] == "true"))
elseif arg[1] == "diff" then
  emit(git.diff_args({ path = arg[3], old_path = arg[4] ~= "" and arg[4] or nil, y = arg[5] or " " }, arg[2]))
elseif arg[1] == "branches" then
  for _, b in ipairs(git.branches(io.read("*a"))) do emit({ b.name, tostring(b.remote) }) end
else error("Unknown bridge operation") end
