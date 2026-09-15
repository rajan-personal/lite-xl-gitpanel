-- Shell-free Git protocol and argument builders. No editor dependencies.
local M = {}

function M.display(path)
  return (path:gsub("\\", "\\\\"):gsub("[%z\1-\31\127]", function(c)
    return ({ ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" })[c]
      or string.format("\\x%02x", c:byte())
  end))
end

function M.status(data)
  local result = { staged = {}, changes = {}, untracked = {}, conflicts = {}, count = 0 }
  local pos = 1
  local function next_record()
    local stop = data:find("\0", pos, true)
    assert(stop, "Incomplete NUL-delimited Git status")
    local record = data:sub(pos, stop - 1)
    pos = stop + 1
    return record
  end
  while pos <= #data do
    local record = next_record()
    if record:sub(1, 3) == "## " then
      local branch = record:sub(4)
      local unborn = branch:match("^No commits yet on (.+)$") or branch:match("^Initial commit on (.+)$")
      result.unborn = unborn ~= nil
      result.detached = branch:match("^HEAD ") ~= nil
      result.branch = unborn or (result.detached and "Detached HEAD") or branch:match("^(.-)%.%.") or branch
    else
      assert(#record >= 4 and record:sub(3, 3) == " ", "Invalid Git status record")
      local x, y = record:sub(1, 1), record:sub(2, 2)
      local entry = { path = record:sub(4), x = x, y = y, status = x .. y }
      if x == "R" or x == "C" or y == "R" or y == "C" then entry.old_path = next_record() end
      local conflict = x == "U" or y == "U" or entry.status == "AA" or entry.status == "DD"
      if entry.status ~= "!!" then
        result.count = result.count + 1
        if conflict then
          table.insert(result.conflicts, entry)
        elseif entry.status == "??" then
          table.insert(result.untracked, entry)
        else
          if x ~= " " then table.insert(result.staged, entry) end
          if y ~= " " then table.insert(result.changes, entry) end
        end
      end
    end
  end
  return result
end

function M.branches(data)
  local list = {}
  for ref, symbolic in data:gmatch("([^%z\n]+)%z([^%z]*)%z\n?") do
    local name = ref:match("^refs/heads/(.+)$")
    if name then
      list[#list + 1] = { name = name, remote = false }
    elseif symbolic == "" then
      name = ref:match("^refs/remotes/(.+)$")
      if name then list[#list + 1] = { name = name, remote = true } end
    end
  end
  return list
end

function M.argv(root, args)
  local argv = { "git", "--no-pager", "--literal-pathspecs", "--no-optional-locks", "-C", root }
  for _, arg in ipairs(args) do argv[#argv + 1] = arg end
  return argv
end

-- Include both sides when unstaging renames; never treat names as pathspecs.
function M.paths(entries, group)
  local paths, seen = {}, {}
  local function add(path)
    if path and not seen[path] then paths[#paths + 1], seen[path] = path, true end
  end
  for _, entry in ipairs(entries) do
    add(entry.path)
    if group == "staged" or entry.y == "R" or entry.y == "C" then add(entry.old_path) end
  end
  return table.concat(paths, "\0") .. (#paths > 0 and "\0" or "")
end

function M.stage_args(group, unborn)
  if group ~= "staged" then
    return { "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul" }
  elseif unborn then
    return { "rm", "--cached", "-r", "-f", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul" }
  end
  return { "reset", "-q", "HEAD", "--pathspec-from-file=-", "--pathspec-file-nul" }
end

function M.diff_args(entry, group, aligned)
  local args = { "diff", "--no-ext-diff", "--no-textconv", "--no-color" }
  if aligned then
    for _, arg in ipairs({ "--unified=0", "--inter-hunk-context=0", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/" }) do args[#args + 1] = arg end
    -- Compare the known staged rename/copy blobs directly: rename heuristics
    -- can turn an edited pair into two delete/add patches with reset offsets.
    if group == "staged" and entry.old_path then
      args[#args + 1] = "HEAD:" .. entry.old_path
      args[#args + 1] = ":" .. entry.path
      args[#args + 1] = "--"
      return args
    end
  end
  if group == "untracked" then
    args[#args + 1] = "--no-index"
    args[#args + 1] = "--"
    args[#args + 1] = "/dev/null"
    args[#args + 1] = entry.path
  else
    if group == "staged" then args[#args + 1] = "--cached" end
    args[#args + 1] = "--"
    args[#args + 1] = entry.path
    if entry.old_path and (group == "staged" or entry.y == "R") then args[#args + 1] = entry.old_path end
  end
  return args
end

return M
