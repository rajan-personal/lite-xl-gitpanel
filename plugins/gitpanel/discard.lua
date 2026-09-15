-- Direct destructive actions retain captured-state and final preflight guards.
local core = require "core"
local runner = require "plugins.gitpanel.runner"
local git = require "plugins.gitpanel.git"
local diff = require "plugins.gitpanel.diff"
local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local helper = assert(source:match("^(.*)/[^/]+$")) .. "/discard.py"
local remove_helper = helper:gsub("discard.py$", "remove.py")
local function pack(values)
  local out = {}
  for _, v in ipairs(values) do out[#out + 1] = #v .. "\n" .. v end
  return table.concat(out)
end
local function unpack_fields(text)
  local fields, pos = {}, 1
  for _ = 1, 3 do
    local stop = assert(text:find("\n", pos, true), "Incomplete discard response")
    local size = assert(tonumber(text:sub(pos, stop - 1)), "Invalid discard response")
    assert(size >= 0 and size <= diff.MAX_BYTES and stop + size <= #text, "Invalid discard response size")
    fields[#fields + 1], pos = text:sub(stop + 1, stop + size), stop + size + 1
  end
  assert(pos == #text + 1, "Unexpected discard response")
  return fields
end
-- Shared bounded wire format for the separate index-only helper.
M.pack, M.unpack_fields = pack, unpack_fields
local function clean_buffers()
  -- Include aliases and untitled buffers: the native API cannot reliably resolve
  -- symlink/hardlink editor aliases. Never auto-save or reload a dirty document.
  for _, doc in ipairs(core.docs or {}) do
    assert(not doc:is_dirty(), "Save editor changes before discarding (including untitled buffers). Nothing was discarded.")
  end
end
function M.eligible(entry, group)
  if group == "untracked" and entry.status == "??" and not entry.old_path then return true end
  if group ~= "changes" or entry.status == "??" then return false, "Only unstaged changes or untracked files are eligible; staged additions require Unstage first." end
  if entry.old_path or (entry.y ~= "M" and entry.y ~= "D") or entry.x == "U" or entry.x == "R" or entry.x == "C" then
    return false, "Rename, conflict or metadata-only change: discard is not supported."
  end
  return true
end
function M.whole_untracked(data)
  local h = data.hunks and #data.hunks == 1 and data.hunks[1]
  return data.group == "untracked" and data.original == "" and h and h.ac == 0
    and h.b == 1 and h.bc == #data.lines[2]
end
function M.install(Model)
  function Model:remove_snapshot(context, root, path)
    assert(self:valid(context) and self.root == root, "Project/root changed; Remove cancelled.")
    local code, out, err = runner.run({ "python3", "-I", remove_helper, "snapshot", root, path }, root)
    assert(self:valid(context) and self.root == root, "Project/root changed; Remove cancelled.")
    assert(code == 0, err ~= "" and err or out)
    local fields = unpack_fields(out)
    assert(fields[2]:match("^[0-7][0-7][0-7][0-7]$") and #fields[3] == 64
      and fields[3]:match("^%x+$"), "Invalid Remove snapshot")
    return { original = "", modified = fields[1], mode = fields[2], token = fields[3] }
  end

  function Model:discard_snapshot(context, root, path)
    assert(self:valid(context) and self.root == root, "Project/root changed; discard cancelled.")
    local code, out, err = runner.run({ "python3", "-I", helper, "snapshot", root, path }, root)
    assert(self:valid(context) and self.root == root, "Project/root changed; discard cancelled.")
    assert(code == 0, "Discard requires existing Python3 and a safe regular file. " .. (err ~= "" and err or out))
    local fields = unpack_fields(out)
    return { original = fields[1], modified = fields[2], token = fields[3] }
  end

  -- Deferred callers capture privately; the returned attachment never yields.
  function Model:prepare_discard(data, context, root, deferred)
    -- Legacy action registrations also retain acquisition identity, never the
    -- later generation of a mutable context object at invalidation time.
    local identity = self.comparison_views and self.comparison_views[data]
      or { context = context, generation = context.generation, root = root, path = data.path }
    local eligible, reason = M.eligible(data.entry, data.group)
    local snapshot, mismatch
    if eligible then
      local ok
      ok, snapshot = pcall(data.group == "untracked" and self.remove_snapshot or self.discard_snapshot, self, context, root, data.path)
      if not ok then reason = tostring(snapshot)
      elseif snapshot.original ~= data.original or snapshot.modified ~= data.modified then
        mismatch = true
        reason = "File or index changed while loading diff; reopen it before discarding."
      end
    end
    local function attach(target)
      local data = target or data
      if reason then data.discard_reason = reason; return end
      data.discard_snapshot, data.context = snapshot, context
      data.remove_file = data.group == "untracked" or nil
      self.discard_views = self.discard_views or setmetatable({}, { __mode = "k" })
      self.discard_views[data] = identity
      data.can_revert = function()
        return self:valid(context) and context.generation == identity.generation and self.root == root and not self.busy and not self.discard_pending
      end
      if data.group ~= "untracked" or M.whole_untracked(data) then
        data.revert = function(index) self:discard(data, index) end
      end
    end
    if deferred then return attach, mismatch, eligible and reason end
    attach()
  end

  function Model:discard_file(entry, group)
    if self.busy or self.discard_pending then self:fail("Another Git operation or discard is pending."); return end
    local eligible, reason = M.eligible(entry, group)
    if not eligible then self:fail(reason); return end
    local context, root = self.context, self.root
    local epoch, scheduled = self.mutation_generation or 0, false
    local targets = require("plugins.gitpanel.documents").capture_affected(context, root, entry.path, self.comparison_views)
    targets.browse_request = self.browse_request
    local generation = context.generation
    local function acquired(data)
      -- Action reads are not browse requests: superseding a tab must not drop
      -- this intent. Repeated delivery or a queued duplicate cannot accept a
      -- second mutation, even if the first has already finished its FIFO turn.
      if scheduled then return end
      scheduled = true
      if not self:valid(context) or context.generation ~= generation or self.root ~= root then self:fail("Project/root changed; discard cancelled."); return end
      if (self.mutation_generation or 0) ~= epoch then self:fail("Git operation accepted since discard request; retry from current state."); return end
      self:discard(data, nil, targets)
    end
    if group == "untracked" then
      -- Whole-file row removal does not depend on textual diff support.
      self:enqueue("Capture untracked file", false, function()
        clean_buffers()
        local snapshot = self:remove_snapshot(context, root, entry.path)
        local data = { path = entry.path, root = root, group = group, entry = entry,
          context = context, discard_snapshot = snapshot, remove_file = true }
        self.comparison_views = self.comparison_views or setmetatable({}, { __mode = "k" })
        self.comparison_views[data] = { context = context, generation = generation, root = root, path = entry.path }
        acquired(data)
      end)
    else self:comparison(entry, group, acquired, nil, "discard") end
  end

  function Model:discard(data, index, targets)
    local identity = self.comparison_views and self.comparison_views[data]
    local removing = data.group == "untracked"
    local function validate()
      assert(not data.invalidated, "Stale diff: reopen the file before discarding again.")
      assert(data.discard_snapshot, data.discard_reason or data.unsupported or "Discard unavailable for this comparison.")
      assert((data.group == "changes" or removing) and self:valid(data.context) and self.root == data.root,
        "Project/root changed; discard cancelled.")
      assert(not identity or identity.generation == data.context.generation, "Acquisition generation changed; discard cancelled.")
      if removing then
        assert(data.remove_file and M.eligible(data.entry, data.group), "Remove unavailable.")
        assert(not index or index == 1 and M.whole_untracked(data), "Remove is whole-file only, never selected-line undo.")
      end
      clean_buffers()
    end
    local ok, err = pcall(validate)
    if not ok then self:fail(err); return end
    if self.busy or self.discard_pending then self:fail("Another Git operation or discard is pending."); return end
    local snapshot, context, root = data.discard_snapshot, data.context, data.root
    local replacement
    ok, replacement = pcall(function() return not removing and (index and diff.revert(data, index) or data.original) or "" end)
    if not ok then self:fail(replacement); return end
    local label = removing and "Remove untracked file (recoverable)" or index and ("Revert change block " .. index) or "Discard unstaged changes"
    local receipt
    local documents = require "plugins.gitpanel.documents"
    if not targets then
      targets = documents.capture_affected(context, root, data.path, self.comparison_views)
      targets.browse_request = self.browse_request
    end
    self:mutate(label, function(job_context, job_root)
      local finish_reload_guard
      local safe, result = pcall(function()
        assert(job_context == context and job_root == root, "Project/root changed; discard cancelled.")
        local current = (removing and self.remove_snapshot or self.discard_snapshot)(self, context, root, data.path)
        assert(current.token == snapshot.token, "File or index changed since capture; reopen the diff and retry.")
        validate() -- final dirty-buffer check AFTER asynchronous preflight
        for other, legacy in pairs(self.discard_views or {}) do
          local identity = self.comparison_views and self.comparison_views[other] or legacy
          if type(identity) == "table" and identity.context == context and identity.generation == context.generation
            and identity.root == root and identity.path == data.path then other.invalidated = true end
        end
        for other, identity in pairs(self.comparison_views or {}) do
          if identity.context == context and identity.generation == context.generation
            and identity.root == root and identity.path == data.path then
            other.invalidated, other.capabilities_pending = true, nil
          end
        end
        documents.invalidate_affected(targets)
        -- Protect the actual delayed Doc:reload boundary before the write can
        -- notify a watcher, including documents opened while it is in flight.
        finish_reload_guard = require("plugins.gitpanel.reloadguard").begin(root, data.path, removing)
        local code, out, failure = runner.run({ "python3", "-I", removing and remove_helper or helper, removing and "remove" or "replace", root, data.path }, root,
          pack(removing and { snapshot.token } or { snapshot.token, replacement }))
        assert(code == 0, failure ~= "" and failure or out)
        if removing then
          receipt = unpack_fields(out)
          assert(receipt[1]:sub(1, 1) == "/" and receipt[2] == data.path and receipt[3] == "removed", "Invalid Remove receipt")
          core.log("Git panel: Removed %s; recovery: %s", git.display(data.path), git.display(receipt[1]))
        end
        return true
      end)
      if finish_reload_guard then finish_reload_guard() end
      if not safe then return nil, "", result end
      return 0, "", ""
    end, function()
      if not self:valid(context) or self.root ~= root then return end
      -- A removed path must never be force-loaded or mark an ordinary Doc clean.
      if not removing then documents.reload_clean(root, data.path, targets) end
      local refreshed, refresh_error = pcall(removing and self.refresh_removed or self.refresh_discarded,
        self, targets, context, root, data.path, receipt)
      if not refreshed then self:fail("Discard completed, but comparison refresh failed; reopen it:\n" .. tostring(refresh_error)) end
      core.log("Git panel: %s completed for %s. Eligible open documents/comparisons refreshed; skipped comparisons remain stale.", label, git.display(data.path))
    end)
  end
end
return M
