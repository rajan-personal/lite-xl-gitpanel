local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local revision = require "plugins.gitpanel.docrevision"

local ReadDoc = Doc:extend()
function ReadDoc:new(title, text)
  ReadDoc.super.new(self)
  self.title = title
  -- Populate once through the base implementation, then forbid all mutations.
  Doc.raw_insert(self, 1, 1, text, self.undo_stack, 0)
  self:clean()
  self.filename = "gitpanel.diff" -- select syntax without loading a file
  self:reset_syntax()
  self.filename = nil -- do not add a fictional file to recent-files/workspaces
end
function ReadDoc:get_name() return self.title end
function ReadDoc:is_dirty() return false end
function ReadDoc:raw_insert() end
function ReadDoc:raw_remove() end
function ReadDoc:load() end
function ReadDoc:reload() end
function ReadDoc:save() core.warn("Git panel snapshots are read-only; copy text to a new document to save it.") end

local Snapshot = DocView:extend()
function Snapshot:get_name() return self.doc.title end
function Snapshot:get_filename() return self.doc.title end

local Draft = Doc:extend()
function Draft:get_name() return "Commit message" end
function Draft:save() core.warn("Commit drafts stay in memory. Use Commit staged, or copy the message to a document.") end

local Composer = DocView:extend()
Composer.context = "application"
function Composer:new()
  Composer.super.new(self, Draft())
  self.font = "font"
end
function Composer:get_gutter_width() return style.padding.x, style.padding.x end
function Composer:draw_line_gutter() end
function Composer:get_scrollable_size()
  return self:get_line_height() * #self.doc.lines + style.padding.y * 2
end
function Composer:message() return self.doc:get_text(1, 1, math.huge, math.huge) end

local SourceDoc = ReadDoc:extend()
function SourceDoc:new(title, lines, path)
  Doc.new(self)
  self.title, self.source_lines = title, lines
  self.lines = {}
  for i, line in ipairs(lines) do
    self.lines[i] = line:gsub("\r\n$", "\n")
    if self.lines[i]:sub(-1) ~= "\n" then self.lines[i] = self.lines[i] .. "\n" end
  end
  if #self.lines == 0 then self.lines[1] = "\n" end
  self.filename = path
  self:reset_syntax()
  self.filename = nil
  self.frozen = true
end
function SourceDoc:reset() if not self.frozen then Doc.reset(self) end end
-- Copy source bytes, not alignment gaps or the editor's mandatory EOF sentinel.
function SourceDoc:copy_selection()
  local l1, c1, l2, c2 = self:get_selection(true)
  local pieces = {}
  for line = l1, l2 do
    local source = self.source_lines[line] or ""
    local from, to = line == l1 and c1 or 1, line == l2 and c2 - 1 or #source
    pieces[#pieces + 1] = source:sub(from, to)
  end
  return table.concat(pieces)
end

local M = { Composer = Composer, ReadDoc = ReadDoc, SourceDoc = SourceDoc }
function M.open(title, text)
  -- Explicitly choose an editor node: a sidebar or inline composer must never
  -- become an editor tab host, even when it currently has keyboard focus.
  local node = core.root_view:get_active_node_default()
  if node.locked then node = core.root_view:get_primary_node() end
  local view = Snapshot(ReadDoc(title, text))
  node:add_view(view)
  core.root_view.root_node:update_layout()
  return view
end
local function patch_text(patch, introduction)
  -- A rejected huge source must not freeze the editor via its raw fallback.
  local ok, reason = pcall(require("plugins.gitpanel.diff").lines, patch)
  local text = ok and (patch ~= "" and patch or "No textual Git hunks (metadata-only or unchanged).\n")
    or ("Raw Git patch not rendered: it exceeds safe text/encoding limits. Use Git externally.\n" .. tostring(reason) .. "\n")
  return (introduction or "") .. text
end
function M.open_patch(title, patch, introduction)
  return M.open(title, patch_text(patch, introduction))
end
local function fallback_doc(data)
  return ReadDoc("Diff · " .. require("plugins.gitpanel.git").display(data.path), patch_text(data.patch,
    "Textual comparison unavailable\n" .. data.unsupported .. "\n\nRaw Git patch:\n"))
end
local function comparison_view(data)
  if data.unsupported then return Snapshot(fallback_doc(data)) end
  return require("plugins.gitpanel.diffview")(data)
end
function M.open_comparison(data)
  local view = comparison_view(data)
  local node = core.root_view:get_active_node_default()
  if node.locked then node = core.root_view:get_primary_node() end
  node:add_view(view)
  core.root_view.root_node:update_layout()
  return view
end

-- Eligibility belongs only to sidebar publications, never generic snapshots or
-- explicit multiview opens. Weak owner keys do not keep closed tabs alive.
local browse_owners = setmetatable({}, { __mode = "k" })
local function same_key(record, data, context)
  return record.context == context and record.generation == context.generation
    and record.root == data.root and record.group == data.group
    and record.path == data.path and record.old_path == data.old_path
end
local function readonly_owner(view, record)
  if view.data ~= record.data then return false end
  if record.doc then
    return getmetatable(view) == Snapshot and view.doc == record.doc
      and getmetatable(view.doc) == ReadDoc and not view.doc:is_dirty()
  end
  if getmetatable(view) ~= require("plugins.gitpanel.diffview") or view.doc or view.panes ~= record.panes then return false end
  for side = 1, 2 do
    local pane = view.panes[side]
    if not pane or not pane.doc or pane ~= record.helpers[side] or pane.doc ~= record.docs[side]
      or getmetatable(pane.doc) ~= SourceDoc or not pane.doc.frozen or pane.doc:is_dirty() then return false end
  end
  return true
end
function M.open_browse_comparison(data, context)
  local root = core.root_view.root_node
  local views = root:get_children()
  local owner, node
  for _, view in ipairs(views) do
    local record = browse_owners[view]
    if record and same_key(record, data, context) and same_key(record, record.data, context)
      and readonly_owner(view, record) then
      local candidate = root:get_node_for_view(view)
      local references = 0
      for _, other in ipairs(views) do
        if other == view or other.data == record.data or record.doc and other.doc == record.doc
          or record.panes and (other == record.helpers[1] or other == record.helpers[2]
            or other.doc == record.docs[1] or other.doc == record.docs[2]) then
          references = references + 1
        end
      end
      if references == 1 and candidate.type == "leaf" and not candidate.locked then
        owner, node = view, candidate
        break
      end
    end
  end
  if not owner then
    owner = M.open_comparison(data)
  elseif not data.unsupported and not owner.doc then
    owner:replace_comparison(data)
    node:set_active_view(owner)
  elseif data.unsupported and owner.doc then
    local doc = fallback_doc(data)
    local position, size = owner.position, owner.size
    owner.data.invalidated, owner.data.capabilities_pending = true, nil
    owner:on_mouse_left()
    DocView.new(owner, doc)
    owner.position, owner.size, owner.mouse_selecting = position, size, nil
    node:set_active_view(owner)
  else
    local replacement = comparison_view(data)
    owner:on_mouse_left()
    owner.data.invalidated, owner.data.capabilities_pending = true, nil
    -- Insert first: removing a sole tab first could collapse its split/primary
    -- node. Native APIs retain tab position and update focus/last-active state.
    node:add_view(replacement, node:get_view_idx(owner))
    node:remove_view(root, owner)
    browse_owners[owner] = nil
    owner = replacement
  end
  owner.data = data
  browse_owners[owner] = {
    context = context, generation = context.generation, root = data.root,
    group = data.group, path = data.path, old_path = data.old_path, data = data,
    doc = owner.doc, panes = owner.panes,
    helpers = owner.panes and { owner.panes[1], owner.panes[2] },
    docs = owner.panes and { owner.panes[1].doc, owner.panes[2].doc },
  }
  root:update_layout()
  return owner
end
-- Operation-time identities, not a later scan of whatever happens to occupy a
-- tab. These records never grant browse eligibility to an explicit multiview.
local function owner_record(view, identity)
  local data = view.data
  return {
    context = identity.context, generation = identity.generation, root = data.root,
    group = data.group, path = data.path, old_path = data.old_path, data = data,
    doc = view.doc, panes = view.panes,
    helpers = view.panes and { view.panes[1], view.panes[2] },
    docs = view.panes and { view.panes[1] and view.panes[1].doc, view.panes[2] and view.panes[2].doc },
  }
end
local function selection_state(view)
  local values = { tostring(view.side), tostring(view.change_index), tostring(view.all), tostring(view.selecting) }
  for _, pane in ipairs(view.panes or { view }) do
    for _, value in ipairs({ pane.doc:get_selection() }) do values[#values + 1] = tostring(value) end
  end
  -- Scroll interpolation can advance without user input; only the target is intent.
  values[#values + 1], values[#values + 2] = tostring(view.scroll.to.x), tostring(view.scroll.to.y)
  return table.concat(values, ",")
end
local function affected_owner_live(targets, target)
  local root = core.root_view and core.root_view.root_node
  return root == targets.node and core.project_dir == targets.context.project
    and targets.context.generation == targets.generation
    and root:get_node_for_view(target.owner) == target.node
    and target.node.type == "leaf" and not target.node.locked
    and same_key(target.record, target.record.data, targets.context)
    and readonly_owner(target.owner, target.record)
    and selection_state(target.owner) == target.selection
end
function M.capture_affected(context, root, path, comparisons)
  local targets = { context = context, generation = context and context.generation,
    node = core.root_view and core.root_view.root_node, owners = {}, docs = {} }
  if not root or not context then return targets end
  local system = require "system"
  local absolute = root .. "/" .. path
  local canonical = system.absolute_path(absolute) or absolute
  for _, doc in ipairs(core.docs or {}) do
    local filename = doc.abs_filename
    if filename and (filename == absolute or system.absolute_path(filename) == canonical) and not doc:is_dirty() then
      targets.docs[doc] = { filename = filename, revision = revision.capture(doc) }
    end
  end
  if not targets.node or not context then return targets end
  for _, owner in ipairs(targets.node:get_children()) do
    local data, browse = owner.data, browse_owners[owner]
    -- Context objects may advance in place. Only an acquisition-time numeric
    -- generation (Model registry or original private browse record) is authority.
    local identity = data and (comparisons and comparisons[data] or browse)
    if identity and identity.context == context and identity.generation == context.generation
      and identity.root == root and identity.path == path
      and data.context == context and data.root == root and data.path == path
      and (data.group == "changes" or data.group == "staged" or data.group == "untracked") then
      local record = owner_record(owner, identity)
      if readonly_owner(owner, record) and (not browse or same_key(browse, data, context)
        and readonly_owner(owner, browse)) then
        targets.owners[#targets.owners + 1] = { owner = owner, record = record,
          node = targets.node:get_node_for_view(owner), selection = selection_state(owner), browse = browse }
      end
    end
  end
  return targets
end
function M.invalidate_affected(targets)
  for _, target in ipairs(targets.owners) do
    target.record.data.invalidated, target.record.data.capabilities_pending = true, nil
  end
end
function M.affected_live(targets)
  for _, target in ipairs(targets.owners) do
    if affected_owner_live(targets, target) then return true end
  end
  return false
end
function M.affected_groups(targets)
  local groups, seen = {}, {}
  for _, target in ipairs(targets.owners) do
    local group = target.record.group
    if affected_owner_live(targets, target) and not seen[group] then
      groups[#groups + 1], seen[group] = group, true
    end
  end
  return groups
end
function M.refresh_affected(targets, source, discard, staging)
  for _, target in ipairs(targets.owners) do
    -- Unsupported/type-changing refreshes leave the old owner truthfully stale;
    -- never insert/remove a tab behind the user's current editor selection.
    if target.record.group == source.group and not target.record.doc
      and affected_owner_live(targets, target) then
      local data = {}
      for key, value in pairs(source) do data[key] = value end
      discard(data); staging(data) -- independent callbacks/weak registrations per owner
      local preserve_browse = target.browse and browse_owners[target.owner] == target.browse
        and same_key(target.browse, target.record.data, targets.context)
        and readonly_owner(target.owner, target.browse)
      target.owner:replace_comparison(data)
      if preserve_browse then
        browse_owners[target.owner] = owner_record(target.owner, target.record)
      end
    end
  end
  core.redraw = true
end
function M.reload_clean(root, path, targets)
  local absolute = root .. "/" .. path
  local system = require "system"
  local canonical = system.absolute_path(absolute) or absolute
  for _, doc in ipairs(core.docs) do
    local filename = doc.abs_filename
    local captured = targets and targets.docs[doc]
    if filename and (filename == absolute or system.absolute_path(filename) == canonical) and not doc:is_dirty()
      and (not targets or captured and captured.filename == filename and revision.unchanged(doc, captured.revision)) then
      local selection = { doc:get_selection() }
      local ok, err = pcall(function()
        doc.crlf = false
        doc:load(absolute)
        doc:clean()
        doc:set_selection((table.unpack or unpack)(selection))
      end)
      if not ok then core.error("Git panel: discard completed, but editor reload failed: %s", err) end
    end
  end
end
return M
