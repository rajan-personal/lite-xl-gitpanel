local core = require "core"
local git = require "plugins.gitpanel.git"
local runner = require "plugins.gitpanel.runner"
local M = {}
M.__index = M

function M.new()
  return setmetatable({ generation = 0, queue = {}, refreshing = false }, M)
end

function M:valid(context)
  return context ~= nil and self.context == context and context.project == core.project_dir
end

function M:bind(project)
  if self.context and self.context.project == project then return end
  self:cancel_browse()
  self.generation = self.generation + 1
  self.context = { project = project, generation = self.generation }
  self.root, self.status, self.error, self.refresh_error = nil, nil, nil, nil
  self.refreshing, self.busy = false, false
  self:refresh(true)
end

function M:fail(message)
  self.error = tostring(message)
  core.error("Git panel: %s", self.error)
  core.redraw = true
end

-- Browse identity is independent of project generation and action intent.
function M:valid_browse(request)
  return request ~= nil and self.browse_request == request
    and self:valid(request.context) and self.root == request.root
end

function M:cancel_browse()
  if self.browse_request and self.browse_request.data then self.browse_request.data.capabilities_pending = nil end
  self.browse_request = nil
  for i = #self.queue, 1, -1 do
    if self.queue[i].browse then table.remove(self.queue, i) end
  end
end

function M:browse_comparison(entry, group, callback)
  self:cancel_browse()
  if not self.context then return end
  local request = { context = self.context, root = self.root }
  self.browse_request = request
  self:comparison(entry, group, callback, request)
  return request
end

function M:enqueue(label, mutation, callback, browse)
  local context = self.context
  if not context then return end
  if mutation and self.busy then self:fail("Another Git operation is running. Wait, then retry."); return end
  if mutation then
    self.busy = label
    -- Accepted mutations invalidate pending captures before their FIFO turn.
    self.mutation_generation = (self.mutation_generation or 0) + 1
  end
  self.queue[#self.queue + 1] = { context = context, callback = callback, label = label, mutation = mutation, browse = browse }
  if self.worker then return end
  self.worker = true
  core.add_thread(function()
    while #self.queue > 0 do
      local job = table.remove(self.queue, 1)
      if self:valid(job.context) and (not job.browse or self:valid_browse(job.browse)) then
        local ok, err = pcall(job.callback, job.context)
        if self:valid(job.context) then
          if job.mutation then self.busy = false end
          if not ok and (not job.browse or self:valid_browse(job.browse)) then
            self:fail(err)
            if not job.browse then self.refreshing = false end
          end
          core.redraw = true
        end
      end
    end
    self.worker = false
  end)
end

function M:run(context, args, input, root)
  if not self:valid(context) then return nil, "", "Project changed; request cancelled." end
  root = root or self.root
  if not root then return nil, "", "No Git worktree is selected." end
  return runner.run(git.argv(root, args), root, input)
end

local function failure(code, out, err)
  return err ~= "" and err or (out ~= "" and out or ("Git exited with " .. tostring(code)))
end

function M:read_status(context, root)
  local code, out, err = self:run(context,
    { "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=none" }, nil, root)
  if code ~= 0 then return nil, failure(code, out, err) end
  return git.status(out)
end

function M:refresh(explicit)
  if not self.context or self.refreshing then return end
  self.refreshing = true
  self:enqueue("Refresh", false, function(context)
    local code, out, err = self:run(context, { "rev-parse", "--show-toplevel" }, nil, context.project)
    if not self:valid(context) then return end
    if code ~= 0 then
      self.root, self.status = nil, nil
      self.refresh_error = "No Git worktree available.\n" .. failure(code, out, err)
    else
      local root = out:gsub("\n$", "")
      local status, status_error = self:read_status(context, root)
      if not self:valid(context) then return end
      self.root = root
      if status then
        self.status = status
        self.refresh_error = nil
        if explicit then self.error = nil end
      else
        self.refresh_error = status_error
      end
    end
    self.refreshing = false
  end)
end

function M:mutate(label, operation, success)
  if not self.root or not self.status then self:fail("Refresh a Git worktree first."); return end
  local root = self.root -- capture the worktree at request time, not queue execution
  self:enqueue(label, true, function(context)
    local code, out, err = operation(context, root)
    if not self:valid(context) then
      local detail = code == 0 and "completed" or failure(code, out or "", err or "")
      core.log("Git panel: %s for previous project %s: %s. Refresh that project before retrying.", label, context.project, detail)
      return
    end
    if code ~= 0 then
      self:fail(label .. " failed:\n" .. failure(code, out or "", err or ""))
    else
      self.error = nil
      if success then success() end
    end
    -- Success handlers may now yield for targeted comparison reads. Never
    -- schedule an old mutation's follow-up into a newly bound project.
    -- Keep mutation errors sticky through every background refresh.
    if self:valid(context) and self.root == root then self:refresh(false) end
  end)
end

function M:stage(group, entries)
  local input = git.paths(entries, group)
  if input == "" then return end
  self:mutate(group == "staged" and "Unstage" or "Stage", function(context, root)
    local status, err = self:read_status(context, root)
    if not status then return nil, "", err end
    return self:run(context, git.stage_args(group, status.unborn), input, root)
  end)
end

function M:commit(message, success)
  if not message:find("%S") then self:fail("Write a commit message first."); return end
  if message:find("\0", 1, true) then self:fail("Commit messages cannot contain NUL bytes."); return end
  self:mutate("Commit staged", function(context, root)
    local status, err = self:read_status(context, root)
    if not status then return nil, "", err end
    if #status.conflicts > 0 then return nil, "", "Resolve and stage all conflicts before committing." end
    if #status.staged == 0 then return nil, "", "The index is empty. Stage changes first." end
    -- No -a or path arguments: commit exactly the index, never the worktree.
    return self:run(context, { "commit", "--cleanup=whitespace", "--file=-" }, message, root)
  end, success)
end

function M:switch(name, create)
  if name == "" or name:sub(1, 1) == "-" then self:fail("Enter a valid branch name (not an option)."); return end
  self:mutate(create and "Create branch" or "Switch branch", function(context, root)
    local status, err = self:read_status(context, root)
    if not status then return nil, "", err end
    -- Status yields. Check buffers afterwards, immediately before switch can
    -- start, so edits made during preflight cannot bypass this guard.
    for _, doc in ipairs(core.docs) do
      -- Conservatively include untitled files and symlinked paths, which may
      -- not share the canonical worktree prefix returned by rev-parse.
      if doc:is_dirty() then
        return nil, "", "Save editor changes before switching branches (including untitled buffers). Nothing was stashed or discarded."
      end
    end
    if status.count > 0 then
      return nil, "", "Branch switching is blocked while the index or worktree is dirty (including untracked files). Commit or handle changes externally, then refresh. Nothing was stashed or discarded."
    end
    if status.unborn then return nil, "", "Create the first commit before switching or creating branches." end
    local args = create and { "switch", "--no-guess", "-c", name } or { "switch", "--no-guess", name }
    return self:run(context, args, nil, root)
  end)
end

function M:branches(callback)
  local root = self.root
  self:enqueue("Branches", false, function(context)
    local code, out, err = self:run(context,
      { "for-each-ref", "--sort=refname", "--format=%(refname)%00%(symref)%00", "refs/heads/", "refs/remotes/" }, nil, root)
    if not self:valid(context) then return end
    if code ~= 0 then self:fail(failure(code, out, err)); return end
    callback(git.branches(out), context)
  end)
end

function M:diff(entry, group, callback)
  local root = self.root
  self:enqueue("Diff", false, function(context)
    local code, out, err = self:run(context, git.diff_args(entry, group), nil, root)
    if not self:valid(context) then return end
    if code ~= 0 and not (group == "untracked" and code == 1) then
      self:fail(failure(code, out, err)); return
    end
    callback(out ~= "" and out or "No textual diff. The file may have changed since refresh, be a submodule, or contain only metadata changes.\n", root)
  end)
end

-- Default callers receive full action readiness; private row discard only
-- consumes discard readiness. Browse publication keeps its full capability path.
function M:comparison(entry, group, callback, browse, action_intent)
  local root = self.root
  self:enqueue("Side-by-side diff", false, function(context)
    self:load_comparison(entry, group, callback, context, root, browse, nil, action_intent)
  end, browse)
end

-- Also used inline by post-discard refresh, within the serialized mutation job.
-- It must not enqueue behind that job or cancel the user's independent browse.
function M:load_comparison(entry, group, callback, context, root, browse, refresh, action_intent)
    local generation = context.generation
    local function current()
      return context.generation == generation and self:valid(context) and (not browse or self:valid_browse(browse))
        and (not refresh or refresh())
    end
    local args = git.diff_args(entry, group, true)
    -- Git diff's automatic stat refresh can write index bytes even with
    -- --no-optional-locks after a file becomes clean. All comparison reads,
    -- including a newer browse queued around discard, must remain read-only.
    table.insert(args, 1, "diff.autoRefreshIndex=false")
    table.insert(args, 1, "-c")
    local code, patch, err = self:run(context, args, nil, root)
    if not current() then return end
    if code ~= 0 and not (group == "untracked" and code == 1) then self:fail(failure(code, patch, err)); return end
    local diff = require "plugins.gitpanel.diff"
    local function run(args)
      assert(current(), "Comparison request cancelled.")
      local c, out, e = self:run(context, args, nil, root)
      assert(current(), "Comparison request cancelled.")
      assert(c == 0, failure(c, out, e))
      return out
    end
    local ok, result = pcall(function()
      assert(group ~= "conflicts", "Unmerged/conflict: textual comparison is unsupported; raw combined patch follows.")
      local index = run({ "ls-files", "--stage", "-z", "--", entry.path })
      assert(not refresh or index ~= "", "Tracked index entry disappeared during refresh; reopen the comparison.")
      for mode, stage in index:gmatch("(%d+) %x+ (%d)\t[^%z]*%z") do
        assert(stage == "0", "Unmerged/conflict: textual comparison is unsupported.")
        assert(mode ~= "160000", "Submodule: textual comparison is unsupported.")
        assert(mode ~= "120000", "Symbolic link: textual comparison is unsupported; raw patch follows.")
      end
      assert(not diff.has_mode(patch, "120000"), "Symbolic link: textual comparison is unsupported.")
      local original, modified = "", ""
      if group == "staged" then
        if entry.x ~= "A" then original = run({ "show", "HEAD:" .. (entry.old_path or entry.path) }) end
        if entry.x ~= "D" then modified = run({ "show", ":" .. entry.path }) end
      else
        if group ~= "untracked" then original = run({ "show", ":" .. ((entry.y == "R" and entry.old_path) or entry.path) }) end
        if entry.y ~= "D" then
          local file, message = io.open(root .. "/" .. entry.path, "rb")
          assert(file, message)
          modified = file:read(diff.MAX_BYTES + 1) or ""
          file:close()
          assert(#modified <= diff.MAX_BYTES, "Disk source exceeds 2 MiB; use Git externally.")
        end
      end
      return diff.build(original, modified, patch)
    end)
    if not current() then return end
    if not ok then result = { unsupported = tostring(result), patch = patch } end
    result.path, result.old_path, result.group, result.root = entry.path, entry.old_path, group, root
    result.entry, result.context = entry, context
    -- Capability preparation may be withheld while a mutation is already queued.
    -- Still retain weak, acquisition-time identities for truthful invalidation.
    self.comparison_views = self.comparison_views or setmetatable({}, { __mode = "k" })
    self.comparison_views[result] = { context = context, generation = context.generation, root = root, path = entry.path }
    if refresh then
      assert(not result.unsupported, result.unsupported)
      local discard, discard_mismatch, discard_error = self:prepare_discard(result, context, root, true)
      if not current() then return end
      local staging, staging_mismatch, staging_error = self:prepare_staging(result, context, root, true)
      if not current() then return end
      assert(not discard_mismatch and not staging_mismatch, "Source/index changed during post-discard refresh; reopen the comparison.")
      assert(not discard_error and not staging_error, discard_error or staging_error)
      local identity = self.comparison_views[result]
      callback(result, function(target)
        self.comparison_views[target] = identity
        discard(target)
      end, staging)
      return
    end
    if browse then
      browse.data = result
      if result.unsupported then callback(result); return end
      result.action_slots = {
        revert = group == "untracked" and require("plugins.gitpanel.discard").whole_untracked(result)
          or group ~= "untracked" and require("plugins.gitpanel.discard").eligible(entry, group),
        stage = require("plugins.gitpanel.staging").eligible(result),
      }
      result.remove_file = group == "untracked" or nil
      result.capabilities_pending = true
      local mutation_generation = self.mutation_generation
      local published, alive = pcall(callback, result)
      if not published then result.capabilities_pending = nil; error(alive) end
      local function attachable()
        return current() and not result.invalidated and not self.busy
          and self.mutation_generation == mutation_generation
          and type(alive) == "function" and alive()
      end
      local function matching(mismatch)
        if not mismatch then return true end
        -- A later capture positively disproved this displayed source. Never
        -- expose an earlier token, even though mutation preflight would refuse.
        local reason = "File or index changed while loading diff; reopen it before acting."
        result.discard_reason, result.staging_reason = reason, reason
        return false
      end
      -- Preparation only returns private, non-yielding attachment closures.
      -- No action token or weak registration reaches published data mid-await.
      pcall(function()
        if not attachable() then return end
        local discard, discard_mismatch = self:prepare_discard(result, context, root, true)
        if not attachable() or not matching(discard_mismatch) then return end
        local staging, staging_mismatch = self:prepare_staging(result, context, root, true)
        if not attachable() or not matching(staging_mismatch) then return end
        discard()
        staging()
      end)
      result.capabilities_pending = nil
      -- Read-only publication succeeded; failed/unavailable readiness is inert,
      -- not an unsolicited error popup. Action helpers retain refusal reasons.
      core.redraw = true
      return
    end
    if not result.unsupported then
      self:prepare_discard(result, context, root)
      if not current() then return end
      if action_intent ~= "discard" then self:prepare_staging(result, context, root) end
    end
    if not current() then return end
    callback(result)
end

function M:refresh_discarded(targets, context, root, path)
  local documents = require "plugins.gitpanel.documents"
  local epoch = self.mutation_generation
  local function current()
    return self:valid(context) and self.root == root and self.mutation_generation == epoch
      and self.browse_request == targets.browse_request and documents.affected_live(targets)
  end
  if not current() then return end
  local status, err = self:read_status(context, root)
  if not current() then return end
  assert(status, err)
  self.status, self.refresh_error = status, nil
  for _, group in ipairs(documents.affected_groups(targets)) do
    if not current() then return end
    local entry
    for _, candidate in ipairs(status[group] or {}) do
      if candidate.path == path then entry = candidate; break end
    end
    -- A successful discard can remove the Changes row entirely. Neutral status
    -- reads the current tracked index/disk; never reuse the old deletion flag.
    entry = entry or { path = path, x = " ", y = " ", status = "  " }
    self:load_comparison(entry, group, function(data, discard, staging)
      if current() then documents.refresh_affected(targets, data, discard, staging) end
    end, context, root, nil, current)
  end
end

-- A receipt is not an absence token. Reacquire status/index, then check disk
-- immediately before publishing; never run no-index diff against a missing path.
function M:refresh_removed(targets, context, root, path, receipt)
  local documents = require "plugins.gitpanel.documents"
  local epoch = self.mutation_generation
  local function current()
    if not self:valid(context) or self.root ~= root or context.generation ~= targets.generation
      or self.mutation_generation ~= epoch or self.browse_request ~= targets.browse_request
      or not documents.affected_live(targets) then return false end
    for _, doc in ipairs(core.docs or {}) do if doc:is_dirty() then return false end end
    return true
  end
  if not current() then return end
  assert(receipt and receipt[2] == path and receipt[3] == "removed", "Missing Remove receipt")
  local status, err = self:read_status(context, root)
  if not current() then return end
  assert(status, err)
  self.status, self.refresh_error = status, nil
  for _, group in ipairs({ "changes", "staged", "conflicts", "untracked" }) do
    for _, entry in ipairs(status[group]) do
      assert(entry.path ~= path and entry.old_path ~= path, "Removed path reappeared; comparison remains stale.")
    end
  end
  local code, index, failure = self:run(context, { "ls-files", "--stage", "-z", "--", path }, nil, root)
  if not current() then return end
  assert(code == 0 and index == "", failure ~= "" and failure or "Removed path is now indexed; comparison remains stale.")
  -- POSIX rename(p, p) on an existing entry succeeds and performs NO OTHER
  -- ACTION, using a final symlink itself (even dangling), not its target. This
  -- synchronous no-op respects filesystem case/normalization aliases without
  -- opening contents (including FIFOs). Only native numeric ENOENT proves
  -- absence; nil stat or raw-name listing exclusion cannot. Lua's third return
  -- is errno; ENOENT is 2 on the supported Darwin/Linux platforms only.
  assert(PLATFORM == "Mac OS X" or PLATFORM == "Linux", "Cannot verify removed path absence on this platform.")
  assert(type(path) == "string" and path ~= "" and not path:find("\0", 1, true), "Invalid removed path")
  local absolute = root .. "/" .. path
  local exists, probe_error, errno = os.rename(absolute, absolute)
  assert(not exists, "Removed path reappeared; comparison remains stale.")
  assert(exists == nil and errno == 2,
    "Cannot verify removed path absence; comparison remains stale: " .. tostring(probe_error))
  local data = require("plugins.gitpanel.diff").build("", "", "")
  data.path, data.root, data.context, data.group = path, root, context, "untracked"
  data.entry, data.removed = { path = path, x = " ", y = " ", status = "  " }, true
  data.discard_reason, data.staging_reason = "File removed; no current changes.", "File removed; no current changes."
  local identity = { context = context, generation = targets.generation, root = root, path = path }
  documents.refresh_affected(targets, data, function(target) self.comparison_views[target] = identity end, function() end)
end

require("plugins.gitpanel.discard").install(M)
require("plugins.gitpanel.staging").install(M)
return M
