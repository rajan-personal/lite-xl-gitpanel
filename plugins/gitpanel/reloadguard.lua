-- Autoreload's delayed coroutine calls Doc:reload after its original clean check.
-- Guard that actual boundary, not a guessed timer interval. Only discard-affected
-- documents remain protected (weak keys); path leases exist only during a write.
local core = require "core"
local Doc = require "core.doc"
local system = require "system"
local git = require "plugins.gitpanel.git"
local revision = require "plugins.gitpanel.docrevision"
local M = {}
local affected = setmetatable({}, { __mode = "k" })
local writes, removals = {}, {}
local original_reload = Doc.reload

local function canonical(path) return system.absolute_path(path) or path end
local function matches(doc, path)
  return doc.abs_filename and (doc.abs_filename == path or canonical(doc.abs_filename) == path)
end
local function protect(doc, removing)
  local state = affected[doc]
  if not state then
    state = {}
    affected[doc] = state
  end
  state.removal = state.removal or removing
  return state
end
local function live(doc, project, filename)
  if core.project_dir ~= project or doc.abs_filename ~= filename then return false end
  for _, open in ipairs(core.docs) do if open == doc then return true end end
  return false
end

function Doc:reload(...)
  local state = affected[self]
  if not state then
    for path in pairs(writes) do if matches(self, path) then state = protect(self, removals[path]); break end end
  end
  if state and state.removal and self.abs_filename and not system.get_file_info(self.abs_filename) then
    core.warn("Git panel: removed file is still absent; editor text and undo history retained. Save to a new path to keep it.")
    return
  end
  if not self.filename or not state or not self:is_dirty() then return original_reload(self, ...) end
  if state.pending then return end
  state.pending = true
  local doc, project, filename = self, core.project_dir, self.abs_filename
  core.add_thread(function()
    -- Native autoreload may be inside its own Yes callback. Let that callback
    -- finish update_time/deferred_reload and NagView:next before showing ours.
    while core.nag_view.visible and live(doc, project, filename) do coroutine.yield(0.05) end
    if not live(doc, project, filename) or not doc:is_dirty() then state.pending = false; return end
    local before = revision.capture(doc)
    local answered = false
    core.nag_view:show("Reload protected file?", git.display(filename or doc.filename) ..
      "\nThis file was affected by Git discard. Reloading replaces ALL unsaved editor edits with disk contents and clears undo history.",
      { { text = "Cancel", default_yes = true, default_no = true }, { text = "Reload from disk", reload = true } },
      function(item)
        if answered then return end
        answered, state.pending = true, false
        if not item.reload then return end
        if not live(doc, project, filename) or not revision.unchanged(doc, before) then
          core.warn("Git panel: document/project changed during reload confirmation. Nothing reloaded; run Reload again to review current edits.")
          return
        end
        -- No yield between validation and the deliberately approved native reload.
        local ok, err = pcall(original_reload, doc)
        if not ok then core.error("Git panel: reload failed: %s", err) end
      end)
  end)
end

function M.begin(root, path, removing)
  local absolute = canonical(root .. "/" .. path)
  writes[absolute] = (writes[absolute] or 0) + 1
  if removing then removals[absolute] = true end
  local function capture()
    for _, doc in ipairs(core.docs) do if matches(doc, absolute) then protect(doc, removing) end end
  end
  capture()
  local finished = false
  return function()
    if finished then return end
    finished = true
    -- Include documents opened while the asynchronous replacement was running.
    capture()
    writes[absolute] = writes[absolute] > 1 and writes[absolute] - 1 or nil
    if not writes[absolute] then removals[absolute] = nil end
  end
end
return M
