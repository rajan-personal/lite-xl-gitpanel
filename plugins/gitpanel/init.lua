-- mod-version:3 -- priority:120
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local git = require "plugins.gitpanel.git"
local Model = require "plugins.gitpanel.model"
local documents = require "plugins.gitpanel.documents"
local ui = require "plugins.gitpanel.ui"

if config.plugins.treeview == false then
  core.error("Git panel requires the native treeview plugin. Enable treeview, then restart Lite XL.")
  return
end
local tree = require "plugins.treeview"
local node = core.root_view.root_node:get_node_for_view(tree)
if not node or not node.locked then
  core.error("Git panel could not find the native locked treeview pane; no layout changes made.")
  return
end

local groups = { "conflicts", "staged", "changes" }
local labels = { conflicts = "Conflicts", staged = "Staged Changes", changes = "Changes", untracked = "Untracked" }
local function inside(rect, x, y)
  return rect and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end
local function rect(x, y, w, h) return { x = x, y = y, w = math.max(0, w), h = math.max(0, h) } end
local function color(group)
  return group == "staged" and (style.syntax.string or style.accent)
    or group == "conflicts" and (style.syntax.keyword or style.accent)
    or group == "changes" and style.accent or style.dim
end
local function text(label, x, y, w, h, tint, font, align)
  if w <= 0 or h <= 0 then return end
  core.push_clip_rect(x, y, w, h)
  common.draw_text(font or style.font, tint or style.text, label, align, x, y, w, h)
  core.pop_clip_rect()
end
local primary_blue, primary_hover, primary_white = { 0, 120, 212, 255 }, { 2, 110, 193, 255 }, { 255, 255, 255, 255 }
local function button(label, box, hovered, enabled, primary)
  local background = hovered and enabled and style.line_highlight or style.background2
  local foreground = enabled and style.text or style.dim
  if primary then
    background = enabled and (hovered and (rawget(style, "gitpanel_commit_hover") or primary_hover)
      or rawget(style, "gitpanel_commit_background") or primary_blue) or style.background
    foreground = enabled and (rawget(style, "gitpanel_commit_foreground") or primary_white) or style.dim
  end
  renderer.draw_rect(box.x, box.y, box.w, box.h, background)
  text(label, box.x, box.y, box.w, box.h, foreground, nil, "center")
end

local ChangeList = View:extend()
function ChangeList:new(panel)
  ChangeList.super.new(self)
  self.panel, self.collapsed, self.rows = panel, {}, {}
  self.scrollable = true
end
function ChangeList:rebuild()
  local status = self.panel.model.status
  local row_height = tree:get_item_height()
  if self.built_status == status and self.built_font == self.panel.small_font and self.built_height == row_height and not self.dirty then return end
  self.built_status, self.built_font, self.built_height, self.dirty = status, self.panel.small_font, row_height, false
  self.rows = {}
  local y = style.padding.y
  if status then
    for _, group in ipairs(groups) do
      local entries = status[group]
      if group == "changes" then
        -- Merge only the presentation; preserve Git's untracked classification
        -- for new-file diffs and leave the model's status arrays untouched.
        entries = {}
        for _, source in ipairs({ status.changes, status.untracked }) do
          for _, entry in ipairs(source) do entries[#entries + 1] = entry end
        end
        table.sort(entries, function(a, b) return a.path < b.path end)
      end
      if group == "changes" or #entries > 0 then
        local h = row_height
        self.rows[#self.rows + 1] = { key = group, group = group, y = y, h = h, entries = entries }
        y = y + h
        if not self.collapsed[group] then
          for _, entry in ipairs(entries) do
            local rh = h
            self.rows[#self.rows + 1] = { key = group .. "\0" .. entry.path, group = group, entry = entry, y = y, h = rh }
            y = y + rh
          end
          if #entries == 0 then
            self.rows[#self.rows + 1] = { key = group .. ":empty", hint = true, group = group, y = y, h = h }
            y = y + h
          end
        end
      end
    end
  end
  self.content_height = y + style.padding.y
end
function ChangeList:get_scrollable_size() return math.max(self.content_height or 1, self.size.y) end
function ChangeList:row_at(x, y)
  if not inside(rect(self.position.x, self.position.y, self.size.x, self.size.y), x, y) then return end
  local offset = y - self.position.y + self.scroll.y
  for _, row in ipairs(self.rows) do
    if offset >= row.y and offset < row.y + row.h then return row end
  end
end
function ChangeList:selected_row()
  for _, row in ipairs(self.rows) do if row.key == self.selected then return row end end
end
function ChangeList:move(direction)
  local index = direction > 0 and 0 or #self.rows + 1
  for i, row in ipairs(self.rows) do if row.key == self.selected then index = i; break end end
  repeat index = index + direction until not self.rows[index] or not self.rows[index].hint
  local row = self.rows[index]
  if row then
    self.selected = row.key
    if row.y < self.scroll.to.y then self.scroll.to.y = row.y end
    if row.y + row.h > self.scroll.to.y + self.size.y then self.scroll.to.y = row.y + row.h - self.size.y end
    core.redraw = true
  end
end
function ChangeList:activate(row, action)
  if not row or row.hint then return end
  self.selected = row.key
  if action then
    self.panel.model:stage(row.group, row.entry and { row.entry } or row.entries)
  elseif row.entry then
    self.panel:open_diff(row.entry, row.entry.status == "??" and "untracked" or row.group)
  else
    self.collapsed[row.group] = not self.collapsed[row.group]
    self.dirty = true
    self:rebuild()
  end
  core.redraw = true
end
function ChangeList:discard(row)
  if row and row.entry then
    self.selected = row.key
    self.panel.model:discard_file(row.entry, row.entry.status == "??" and "untracked" or row.group)
  end
end
function ChangeList:count_box(row)
  if not row or not row.entries then return end
  local _, y = self:get_content_offset()
  local p = style.padding.x
  local viewport = ui.rect(self.position.x, self.position.y, self.size.x, self.size.y)
  -- Suppress the entire heading's controls if its row is partially scrolled.
  if not ui.visible_box(ui.rect(self.position.x, y + row.y, self.size.x, row.h), viewport) then return end
  local width = math.min(80 * SCALE, math.max(0, self.size.x - p * 2) / 3)
  return ui.section_count(#row.entries,
    ui.rect(self.position.x + self.size.x - p - width, y + row.y, width, row.h), viewport)
end
function ChangeList:action_boxes(row)
  local boxes = {}
  if not row or row.hint or (row.key ~= self.hovered and row.key ~= self.selected) then return boxes end
  local _, y = self:get_content_offset()
  local width, gap = ui.action_width(), ui.action_gap()
  local count = self:count_box(row)
  local edge = count and count.x - gap or self.position.x + self.size.x - style.padding.x
  local discard = row.entry and row.group == "changes"
  local reserved = width + (discard and width + gap or 0)
  local count_space = count and count.w + gap or 0
  -- Leave native indentation/name and a separate status letter readable.
  if self.size.x < reserved + count_space + style.padding.x * 4 + 60 * SCALE then return boxes end
  local viewport = ui.rect(self.position.x, self.position.y, self.size.x, self.size.y)
  boxes.stage = ui.visible_box(ui.rect(edge - width, y + row.y, width, row.h), viewport)
  if discard then
    boxes.discard = ui.visible_box(ui.rect(edge - reserved, y + row.y, width, row.h), viewport)
  end
  return boxes
end
function ChangeList:action_enabled(row, action)
  if self.panel.model.busy or self.panel.model.discard_pending then return false end
  if action == "discard" then return require("plugins.gitpanel.discard").eligible(row.entry, row.entry.status == "??" and "untracked" or row.group) end
  return row.entry ~= nil or #row.entries > 0
end
function ChangeList:action_at(row, x, y)
  for action, box in pairs(self:action_boxes(row)) do
    if ui.inside(box, x, y) then return action end
  end
end
function ChangeList:on_mouse_pressed(b, x, y, clicks)
  if ChangeList.super.on_mouse_pressed(self, b, x, y, clicks) then return true end
  if b ~= "left" then return true end
  local row = self:row_at(x, y)
  local action = self:action_at(row, x, y)
  if action then
    if self:action_enabled(row, action) then
      if action == "discard" then self:discard(row) else self:activate(row, true) end
    end
  else self:activate(row, false) end
  return true
end
function ChangeList:on_mouse_moved(x, y, ...)
  ChangeList.super.on_mouse_moved(self, x, y, ...)
  local row = self:row_at(x, y)
  local key, previous = row and row.key, self.hovered
  self.hovered = key
  local action = self:action_at(row, x, y)
  if previous ~= key or self.hover_action ~= action then core.redraw = true end
  self.hover_action = action
  self.cursor = action and self:action_enabled(row, action) and "hand" or "arrow"
  if core.status_view then
    if row and not row.hint then
      local tip = row.entry and (git.display(row.entry.path) .. (row.entry.old_path and "  ← " .. git.display(row.entry.old_path) or "")) or labels[row.group]
      if action == "discard" then
        local enabled, reason = self:action_enabled(row, action)
        tip = (row.entry.status == "??" and "Remove untracked file (recoverable) · " or "Discard unstaged changes · ") .. tip .. (not enabled and (" · " .. (reason or "Git operation pending")) or "")
      elseif action == "stage" then
        tip = (row.group == "staged" and "Unstage" or "Stage") .. (row.entry and " file" or " group") .. " · index only · " .. tip
        if not self:action_enabled(row, action) then tip = tip .. " · Unavailable" end
      end
      core.status_view:show_tooltip(tip)
      self.tooltip = true
    elseif self.tooltip then core.status_view:remove_tooltip(); self.tooltip = false end
  end
end
function ChangeList:on_mouse_left()
  self.hovered, self.hover_action = nil, nil
  self.cursor = "arrow"
  if self.tooltip and core.status_view then core.status_view:remove_tooltip(); self.tooltip = false end
  core.redraw = true
  ChangeList.super.on_mouse_left(self)
end
function ChangeList:on_mouse_wheel(y)
  self.scroll.to.y = self.scroll.to.y - y * (style.font:get_height() + style.padding.y) * 3
  return true
end
function ChangeList:draw()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local x, y = self:get_content_offset()
  local w, p = self.size.x, style.padding.x
  local status = self.panel.model.status
  if not status then
    text(self.panel.model.refreshing and "Reading repository…" or "Open a Git project to get started.", x + p, y + p, w - p * 2, 36 * SCALE, style.dim)
  else
    for _, row in ipairs(self.rows) do
      local ry = y + row.y
      if ry + row.h >= self.position.y and ry < self.position.y + self.size.y then
        if row.hint then
          local hints = { staged = "No staged files", changes = "No unstaged changes" }
          text(hints[row.group], x + p * 2, ry, w - p * 3, row.h, style.dim, self.panel.small_font)
        else
          local hover, selected = row.key == self.hovered, row.key == self.selected
          local entry = row.entry
          local item = {
            name = entry and git.display(common.basename(entry.path)) or labels[row.group],
            type = entry and "file" or "dir", depth = entry and 1 or 0,
            expanded = not self.collapsed[row.group],
            abs_filename = entry and ((self.panel.model.root or "") .. PATHSEP .. entry.path) or "",
          }
          -- Files retain the native renderer. Sections use its chevron/font
          -- and background, but are SCM groups rather than folder entries.
          tree.item_icon_width = style.icon_font:get_width("D")
          tree.item_text_spacing = style.icon_font:get_width("f") / 2
          tree:draw_item_background(item, selected, hover, x, ry, w, row.h)
          local boxes, count = self:action_boxes(row), self:count_box(row)
          local edge = boxes.discard and boxes.discard.x or boxes.stage and boxes.stage.x
            or count and count.x - ui.action_gap() or x + w - p
          local status_width = entry and p * 2 or 0
          core.push_clip_rect(x, ry, math.max(0, edge - x - status_width), row.h)
          if entry then
            tree:draw_item(item, selected, hover, x, ry, w, row.h)
          else
            text(item.expanded and "-" or "+", x + p, ry, p, row.h,
              hover and style.accent or style.text, style.icon_font)
            text(item.name, x + p * 2, ry, math.max(0, edge - x - p * 2), row.h)
          end
          core.pop_clip_rect()
          ui.draw_section_count(count)
          if entry then
            local state = row.group == "staged" and entry.x or entry.status == "??" and "U" or entry.y
            text(state, math.max(x, edge - status_width), ry, math.min(w, status_width), row.h, color(row.group), nil, "center")
          end
          for action, box in pairs(boxes) do
            ui.draw_action(action == "discard" and "undo" or row.group == "staged" and "unstage" or "stage",
              box, hover and self.hover_action == action, self:action_enabled(row, action))
          end
        end
      end
    end
  end
  self:draw_scrollbar()
  core.pop_clip_rect()
end

local Sidebar = View:extend()
function Sidebar:__tostring() return "GitPanel" end
function Sidebar:new()
  Sidebar.super.new(self)
  self.mode = "files"
  self.model = Model.new()
  self.composers = {}
  self.list = ChangeList(self)
  self.small_font = style.font
  self.font_source, self.font_scale = style.font, SCALE
  self.next_refresh = 0
  -- Keep the native Files width; only reserve room for its toolbar icons.
end
function Sidebar:get_name() return nil end
function Sidebar:try_close() end -- application pane, never a closeable editor
function Sidebar:set_target_size(axis, value)
  local minimum = tree.toolbar and tree.toolbar:get_min_width() or 200 * SCALE
  return tree:set_target_size(axis, math.max(minimum, value))
end
function Sidebar:show(mode)
  if mode == "files" then self.model:cancel_browse() end
  self.mode, tree.visible = mode, true
  tree.tooltip.alpha, tree.tooltip.x, tree.tooltip.y = 0, nil, nil
  core.set_active_view(mode == "files" and tree or self)
  if mode == "git" then self.model:refresh(false) end
  core.redraw = true
end
function Sidebar:open_diff(entry, group)
  local origin, context = core.active_view, self.model.context
  self.model:browse_comparison(entry, group, function(data)
    -- Publication must not steal focus from a subsequently selected view.
    -- Keep this UI guard separate from model readiness/cancellation identity.
    if self.mode ~= "git" or core.active_view ~= origin then return end
    local view = documents.open_browse_comparison(data, context)
    return function()
      -- Publication itself changes focus. Readiness needs the same live owner,
      -- not the original focus, and must never add or focus another tab.
      return view.data == data and core.root_view.root_node:get_node_for_view(view) ~= nil
    end
  end)
end
function Sidebar:commit_ready()
  local status = self.model.status
  return status and #status.staged > 0 and #status.conflicts == 0
    and not self.model.busy and self.composer and self.composer:message():find("%S") ~= nil
end
function Sidebar:commit()
  local composer = self.composer
  if not composer then return end
  local message = composer:message()
  self.model:commit(message, function()
    -- A user may continue typing while hooks run. Never erase a newer draft.
    if composer:message() == message then composer.doc:reset() end
  end)
end
function Sidebar:show_error()
  local message = self.model.error or self.model.refresh_error
  if message then documents.open("Git panel · details [read-only]", message .. "\n") end
end
function Sidebar:create_branch()
  local context = self.model.context
  core.command_view:enter("Create local branch", {
    show_suggestions = false,
    submit = function(name)
      if self.model:valid(context) then self.model:switch(name, true) end
    end
  })
end
function Sidebar:pick_branch()
  self.model:branches(function(branches, context)
    local items = { { text = "+ Create local branch…", create = true } }
    for _, branch in ipairs(branches) do
      items[#items + 1] = { text = (branch.remote and "remote  " or "local  ") .. branch.name,
        name = branch.name, remote = branch.remote }
    end
    core.command_view:enter("Git branches", {
      suggest = function(query)
        local matches = {}
        for _, item in ipairs(items) do
          if item.text:lower():find(query:lower(), 1, true) then matches[#matches + 1] = item end
        end
        return matches
      end,
      submit = function(_, item)
        if not self.model:valid(context) or not item then return end
        if item.create then self:create_branch()
        elseif item.remote then
          self.model:fail("Remote branches are listed for reference only. Create/check out a tracking branch with Git externally; no fetch or network operation was performed.")
        else self.model:switch(item.name, false) end
      end
    })
  end)
end
function Sidebar:layout()
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local p = math.min(style.padding.x, w / 2)
  local line = self.composer and self.composer:get_line_height() or style.font:get_height()
  local gap = math.max(2 * SCALE, style.padding.y / 2)
  local tab_h = (tree.toolbar and tree.toolbar.visible) and 0 or tree:get_item_height()
  self.tabs = rect(x, y + h - tab_h, w, tab_h)
  tree.position.x, tree.position.y = x, y
  tree.size.x, tree.size.y = w, math.max(0, h - tab_h)
  self.header = rect(x + p, y + style.padding.y, w - p * 2, tree:get_item_height())
  local refresh_w = math.min(self.header.w, style.font:get_width("Refresh") + gap * 2)
  self.refresh_box = rect(x + w - p - refresh_w, self.header.y, refresh_w, self.header.h)
  local cy = self.header.y + self.header.h + gap
  local context_w = math.max(0, w - p * 2)
  local branch_w = self.model.root and math.min(context_w * .5,
    style.font:get_width(self.model.status and self.model.status.branch or "…") + p * 2) or 0
  self.repository_box = rect(x + p, cy, context_w - branch_w, tree:get_item_height())
  self.branch_box = rect(x + w - p - branch_w, cy, branch_w, self.repository_box.h)
  cy = cy + self.repository_box.h + gap
  local lines = self.composer and math.min(3, #self.composer.doc.lines) or 1
  self.composer_box = rect(x + p, cy, w - p * 2, line * lines + style.padding.y * 2 + 2)
  if self.composer then
    self.composer.position.x, self.composer.position.y = self.composer_box.x + 1, cy + 1
    self.composer.size.x, self.composer.size.y = math.max(0, self.composer_box.w - 2), self.composer_box.h - 2
  end
  cy = cy + self.composer_box.h + gap
  self.commit_box = rect(x + p, cy, w - p * 2, tree:get_item_height())
  cy = cy + self.commit_box.h + style.padding.y
  local banner_h = (self.model.error or self.model.refresh_error) and self.small_font:get_height() * 2 + style.padding.y * 2 or 0
  self.banner = rect(x + p, cy, w - p * 2, banner_h)
  if banner_h > 0 then cy = cy + banner_h + style.padding.y end
  self.list.position.x, self.list.position.y = x, cy
  self.list.size.x, self.list.size.y = w, math.max(0, self.tabs.y - cy)
end
function Sidebar:update()
  if not self.model.context or self.model.context.project ~= core.project_dir then
    local composer_focused = self.composer and core.active_view == self.composer
    self.model:bind(core.project_dir)
    self.composer = self.composers[core.project_dir]
    if not self.composer then
      self.composer = documents.Composer()
      self.composers[core.project_dir] = self.composer
    end
    if composer_focused then core.set_active_view(self.composer) end
    self.list.selected, self.list.scroll.y, self.list.scroll.to.y = nil, 0, 0
  end
  if self.font_source ~= style.font or self.font_scale ~= SCALE then
    self.small_font = style.font
    self.font_source, self.font_scale = style.font, SCALE
  end
  self:layout()
  -- Run the original tree's update only in Files mode, preserving its scroll
  -- and expansion objects verbatim while Git is visible.
  if self.mode == "files" then tree:update()
  else
    tree:move_towards(tree.size, "x", tree.visible and tree.target_size or 0, nil, "treeview")
    self.list:rebuild()
    self.list:update()
    self.composer:update()
  end
  self.size.x = tree.size.x
  if system.get_time() >= self.next_refresh and not self.model.busy then
    self.next_refresh = system.get_time() + 5
    self.model:refresh(false)
  end
  if core.active_view == tree and self.mode ~= "files" then self:show("files") end
end
function Sidebar:draw()
  if self.size.x < 1 then return end
  self:layout()
  self:draw_background(style.background2)
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, math.max(0, self.tabs.y - self.position.y))
  if self.mode == "files" then
    tree:draw()
  else
    local model, status = self.model, self.model.status
    text("SOURCE CONTROL", self.header.x, self.header.y, self.refresh_box.x - self.header.x, self.header.h, style.text)
    button(model.refreshing and "…" or "Refresh", self.refresh_box, self.hover == "refresh", not model.refreshing)
    local repo, branch = self.repository_box, self.branch_box
    text(model.root and git.display(common.basename(model.root)) or "Select a repository",
      repo.x, repo.y, repo.w, repo.h, model.root and style.text or style.dim)
    if model.root then
      if self.hover == "branch" then renderer.draw_rect(branch.x, branch.y, branch.w, branch.h, style.line_highlight) end
      local chevron = math.min(style.padding.x, branch.w)
      text(status and status.branch or "…", branch.x, branch.y, branch.w - chevron, branch.h, style.dim, nil, "right")
      text("-", branch.x + branch.w - chevron, branch.y, chevron, branch.h, style.dim, style.icon_font, "center")
    end
    local b = self.composer_box
    renderer.draw_rect(b.x - 1, b.y - 1, b.w + 2, b.h + 2, core.active_view == self.composer and style.accent or style.divider)
    core.push_clip_rect(b.x, b.y, b.w, b.h)
    self.composer:draw()
    if self.composer:message() == "" and core.active_view ~= self.composer then
      text("Commit message…", b.x + style.padding.x, b.y + style.padding.y, b.w - style.padding.x * 2, style.font:get_height(), style.dim)
    end
    core.pop_clip_rect()
    button(model.busy and (model.busy .. "…") or "Commit", self.commit_box, self.hover == "commit", self:commit_ready(), true)
    local bnr = self.banner
    local err = model.error or model.refresh_error
    if err then
      text("Git needs attention · click for details", bnr.x, bnr.y, bnr.w, self.small_font:get_height() + style.padding.y, color("conflicts"), self.small_font)
      text(git.display(err:match("[^\n]+") or err), bnr.x, bnr.y + self.small_font:get_height() + style.padding.y, bnr.w, self.small_font:get_height(), style.dim, self.small_font)
    end
    self.list:draw()
  end
  core.pop_clip_rect()
  local t = self.tabs
  if t.h == 0 then return end
  renderer.draw_rect(t.x, t.y, t.w, t.h, style.background2)
  renderer.draw_rect(t.x, t.y, t.w, style.divider_size, style.divider)
  for i, mode in ipairs({ "files", "git" }) do
    local box = rect(t.x + (i - 1) * t.w / 2, t.y, t.w / 2, t.h)
    if self.hover == mode then renderer.draw_rect(box.x, box.y + 1, box.w, box.h - 1, style.line_highlight) end
    local label = mode == "files" and "Files" or "Git"
    local badge
    if mode == "git" then
      -- Reserve the label's measured width before fitting the same toolbar badge.
      local room = math.max(0, box.w - style.font:get_width(label) - 4 * SCALE)
      badge = ui.count_badge(ui.scm_count(self.model), rect(box.x + box.w - room, box.y, room, box.h - 4 * SCALE), t)
    end
    text(label, box.x, box.y, badge and math.max(0, badge.x - box.x - 2 * SCALE) or box.w, box.h,
      self.mode == mode and style.accent or style.dim, nil, "center")
    ui.draw_count_badge(badge)
    if self.mode == mode then renderer.draw_rect(box.x + style.padding.x, box.y + box.h - 3 * SCALE, math.max(0, box.w - style.padding.x * 2), 2 * SCALE, style.accent) end
  end
end
function Sidebar:hit(x, y)
  if not inside(rect(self.position.x, self.position.y, self.size.x, self.size.y), x, y) then return end
  if inside(self.tabs, x, y) then return x < self.tabs.x + self.tabs.w / 2 and "files" or "git" end
  if self.mode ~= "git" then return end
  for name, box in pairs({ refresh = self.refresh_box, branch = self.branch_box, commit = self.commit_box, composer = self.composer_box, banner = self.banner }) do
    if inside(box, x, y) then return name end
  end
end
function Sidebar:on_mouse_pressed(b, x, y, clicks)
  local hit = self:hit(x, y)
  if hit == "files" or hit == "git" then if b == "left" then self:show(hit) end; return true end
  if self.mode == "files" then
    core.set_active_view(tree)
    tree:on_mouse_moved(x, y, 0, 0)
    if b == "right" and tree.contextmenu:on_mouse_pressed(b, x, y, clicks) then return true end
    return tree:on_mouse_pressed(b, x, y, clicks)
  end
  if hit == "composer" then
    core.set_active_view(self.composer)
    return self.composer:on_mouse_pressed(b, x, y, clicks)
  end
  if b ~= "left" then return true end
  if hit == "refresh" then if not self.model.refreshing then self.model:refresh(true) end
  elseif hit == "branch" then if self.model.root then self:pick_branch() end
  elseif hit == "commit" then if self:commit_ready() then self:commit() end
  elseif hit == "banner" then self:show_error()
  else return self.list:on_mouse_pressed(b, x, y, clicks) end
  return true
end
function Sidebar:on_mouse_moved(x, y, ...)
  local hover = self:hit(x, y)
  if hover ~= self.hover then self.hover = hover; core.redraw = true end
  if self.mode == "files" then
    if not hover then tree:on_mouse_moved(x, y, ...) else tree.hovered_item = nil end
  else
    if self.tooltip and core.status_view then core.status_view:remove_tooltip(); self.tooltip = false end
    self.list:on_mouse_moved(x, y, ...)
    self.composer:on_mouse_moved(x, y, ...)
    local tip = hover == "refresh" and "Refresh repository status"
      or hover == "commit" and "Commit staged changes only · Ctrl+Return"
      or hover == "branch" and ("Switch branch · " .. git.display(self.model.root or "") .. " · " .. (self.model.status and self.model.status.branch or "Reading repository…"))
    if tip and core.status_view then core.status_view:show_tooltip(tip); self.tooltip = true end
  end
  local disabled = hover == "commit" and not self:commit_ready() or hover == "refresh" and self.model.refreshing
  self.cursor = hover == "composer" and "ibeam" or hover and not disabled and "hand" or "arrow"
end
function Sidebar:on_mouse_released(...)
  tree:on_mouse_released(...)
  self.list:on_mouse_released(...)
  if self.composer then self.composer:on_mouse_released(...) end
end
function Sidebar:on_mouse_left()
  self.hover = nil
  if self.tooltip and core.status_view then core.status_view:remove_tooltip(); self.tooltip = false end
  tree:on_mouse_left()
  tree.hovered_item = nil
  tree.tooltip.alpha, tree.tooltip.x, tree.tooltip.y = 0, nil, nil
  self.list:on_mouse_left()
end
function Sidebar:on_mouse_wheel(y, x)
  if self.mode == "files" then
    tree.scroll.to.y = tree.scroll.to.y - y * tree:get_item_height() * 3
    return true
  elseif self.hover == "composer" then
    self.composer.scroll.to.y = self.composer.scroll.to.y - y * self.composer:get_line_height() * 3
    return true
  end
  return self.list:on_mouse_wheel(y, x)
end
function Sidebar:scrollbar_overlaps_point(x, y)
  if self.mode == "files" then return tree:scrollbar_overlaps_point(x, y) end
  return self.list:scrollbar_overlaps_point(x, y) or self.composer and self.composer:scrollbar_overlaps_point(x, y)
end

local panel = Sidebar()
panel.toolbar_item = require("plugins.gitpanel.toolbar").install(tree.toolbar, panel)
panel.branch_item = require("plugins.gitpanel.statusbar").install(core.status_view, panel)
if tree.toolbar then tree.target_size = math.max(tree.target_size, tree.toolbar:get_min_width()) end
-- Replace only the tree leaf's content, retaining its native resizable lock,
-- sibling toolbar, tree instance, SCM decorations and every expansion key.
node.views[node:get_view_idx(tree)] = panel
node.active_view = panel
panel.size.x = tree.target_size
if core.active_view == tree then core.set_active_view(panel) end

-- Embedded views retain native editing/tree commands, but belong to this
-- locked pane for root commands (Close, tab navigation, splitting, etc.).
local get_active_node = core.root_view.get_active_node
function core.root_view:get_active_node()
  if core.active_view == tree or core.active_view == panel.composer then
    local owner = self.root_node:get_node_for_view(panel)
    if owner then return owner end
  end
  return get_active_node(self)
end

local on_quit_project = core.on_quit_project
function core.on_quit_project(...)
  panel.model.context = nil -- invalidate callbacks even when reopening the same directory
  panel.model.generation = panel.model.generation + 1
  return on_quit_project(...)
end

command.add(nil, {
  ["git-panel:show-git"] = function() panel:show("git") end,
  ["git-panel:show-files"] = function() panel:show("files") end,
  ["git-panel:toggle"] = function() panel:show(panel.mode == "git" and "files" or "git") end,
  ["git-panel:refresh"] = function() panel.model:refresh(true) end,
  ["git-panel:branches"] = function() panel:show("git"); panel:pick_branch() end,
  ["git-panel:create-branch"] = function() panel:show("git"); panel:create_branch() end,
  ["git-panel:show-error"] = function() panel:show_error() end,
  ["git-panel:focus-message"] = function() panel:show("git"); if panel.composer then core.set_active_view(panel.composer) end end,
})
command.add(function() return panel.mode == "git" and (core.active_view == panel or core.active_view == panel.composer) end, {
  ["git-panel:commit"] = function() panel:commit() end,
  ["git-panel:focus-list"] = function() core.set_active_view(panel) end,
  ["git-panel:stage-all"] = function()
    local status = panel.model.status
    if status then
      local entries = {}
      for _, group in ipairs({ "changes", "untracked" }) do for _, e in ipairs(status[group]) do entries[#entries + 1] = e end end
      panel.model:stage("changes", entries)
    end
  end,
  ["git-panel:unstage-all"] = function() if panel.model.status then panel.model:stage("staged", panel.model.status.staged) end end,
})
command.add(function() return core.active_view == panel and panel.mode == "git" end, {
  ["git-panel:next"] = function() panel.list:move(1) end,
  ["git-panel:previous"] = function() panel.list:move(-1) end,
  ["git-panel:open"] = function() panel.list:activate(panel.list:selected_row(), false) end,
  ["git-panel:stage-selected"] = function() panel.list:activate(panel.list:selected_row(), true) end,
  ["git-panel:discard-unstaged-changes"] = function() panel.list:discard(panel.list:selected_row()) end,
  ["git-panel:collapse"] = function() local row = panel.list:selected_row(); if row then panel.list.collapsed[row.group], panel.list.dirty = true, true end end,
  ["git-panel:expand"] = function() local row = panel.list:selected_row(); if row then panel.list.collapsed[row.group], panel.list.dirty = false, true end end,
})
keymap.add {
  ["ctrl+shift+g"] = "git-panel:toggle",
  ["ctrl+alt+r"] = "git-panel:refresh",
  ["ctrl+alt+b"] = "git-panel:branches",
  ["ctrl+alt+m"] = "git-panel:focus-message",
  ["ctrl+return"] = "git-panel:commit",
  ["escape"] = "git-panel:focus-list",
  ["up"] = "git-panel:previous", ["down"] = "git-panel:next",
  ["left"] = "git-panel:collapse", ["right"] = "git-panel:expand",
  ["return"] = "git-panel:open", ["space"] = "git-panel:open",
  ["+"] = "git-panel:stage-selected", ["="] = "git-panel:stage-selected", ["-"] = "git-panel:stage-selected",
}
return panel
