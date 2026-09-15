-- Review/native verification gate. Never enable via user configuration implicitly.
local M = { ENABLED = false }
local runner = require "plugins.gitpanel.runner"
local diff = require "plugins.gitpanel.diff"
local protocol = require "plugins.gitpanel.discard"
local source = debug.getinfo(1, "S").source:sub(2)
local helper = assert(source:match("^(.*)/[^/]+$")) .. "/staging.py"
function M.eligible(data)
  if not M.ENABLED then return false, "Granular staging is review/native-pending; not enabled." end
  if data.old_path or (data.group ~= "changes" and data.group ~= "staged" and data.group ~= "untracked") then
    return false, "Rename/conflict comparison is unsupported for granular staging."
  end
  -- A validated clean comparison is displayable, but has no action snapshot.
  -- Do not invoke the mutation helper: it correctly refuses equal source text.
  if not data.unsupported and type(data.original) == "string" and data.original == data.modified then
    return false, "No textual changes remain."
  end
  return true
end
function M.install(Model)
  function Model:staging_snapshot(context, root, data)
    assert(self:valid(context) and self.root == root, "Project/root changed; staging cancelled.")
    local code, out, err = runner.run({"python3", "-I", helper, "snapshot", root, data.path, data.group}, root)
    assert(self:valid(context) and self.root == root, "Project/root changed; staging cancelled.")
    assert(code == 0, "Granular staging requires existing Python3 and a supported file. " .. (err ~= "" and err or out))
    local fields = protocol.unpack_fields(out)
    return {original=fields[1], modified=fields[2], token=fields[3]}
  end
  -- Keep captures private until the browse owner and request are checked.
  function Model:prepare_staging(data, context, root, deferred)
    local eligible, reason = M.eligible(data)
    local snapshot, mismatch
    if eligible then
      local ok
      ok, snapshot = pcall(self.staging_snapshot, self, context, root, data)
      if not ok then reason = tostring(snapshot)
      elseif snapshot.original ~= data.original or snapshot.modified ~= data.modified then
        mismatch = true
        reason = "Source/index changed while loading comparison; reopen it."
      end
    end
    local function attach(target)
      local data = target or data
      if reason then data.staging_reason = reason; return end
      data.staging_snapshot, data.staging_context = snapshot, context
      self.staging_views = self.staging_views or setmetatable({}, {__mode="k"})
      self.staging_views[data] = true
      data.can_stage = function()
        return M.ENABLED and self:valid(context) and self.root == root and not self.busy and not self.discard_pending
      end
      data.stage = function(index, first, last) self:stage_selection(data, index, first, last) end
    end
    if deferred then return attach, mismatch, eligible and reason end
    attach()
  end
  function Model:stage_selection(data, index, first, last)
    local ok, replacement = pcall(function()
      assert(M.ENABLED and data.staging_snapshot and not data.invalidated, data.staging_reason or "Stale/unavailable diff: reopen it.")
      assert(data.can_stage(), "Project/root changed or Git operation pending; staging cancelled.")
      return index and diff.stage_block(data, index, data.group == "staged") or diff.stage_rows(data, first, last, data.group == "staged")
    end)
    if not ok then self:fail(replacement); return end
    local context, root = data.staging_context, data.root
    self:mutate(data.group == "staged" and "Unstage selection" or "Stage selection", function(job_context, job_root)
      assert(job_context == context and job_root == root and self.root == root and self:valid(context), "Project/root changed; staging cancelled.")
      local snapshot = self:staging_snapshot(context, root, data)
      assert(not data.invalidated and snapshot.token == data.staging_snapshot.token, "Stale source/index/HEAD: reopen diff.")
      -- Index mutations invalidate both source modes and existing discard snapshots.
      -- Mark before execution, including uncertain timeout/failure, never auto-retry.
      for _, views in ipairs({self.staging_views or {}, self.discard_views or {}}) do
        for other in pairs(views) do
          if other.root == root and other.path == data.path then other.invalidated = true end
        end
      end
      return runner.run({"python3", "-I", helper, "replace", root, data.path, data.group}, root,
        protocol.pack({snapshot.token, replacement}))
    end)
  end
end
return M
