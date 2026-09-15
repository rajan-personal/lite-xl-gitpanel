local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local command = require "core.command"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local documents = require "plugins.gitpanel.documents"
local git = require "plugins.gitpanel.git"
local ui = require "plugins.gitpanel.ui"

-- Only this View is ever focused or inserted in a Node. The two DocViews are
-- rendering helpers, never root-command targets or independent editor tabs.
local DiffView = View:extend()
DiffView.context = "session"
function DiffView:new(data)
  self:replace_comparison(data)
end
-- Fresh acquisition resets source selection/scroll; only the logical tab and
-- its Node geometry survive. Construct helpers before retiring the old data.
function DiffView:replace_comparison(data)
  local panes = {}
  for side = 1, 2 do
    panes[side] = DocView(documents.SourceDoc(side == 1 and "Original" or "Modified",
      data.lines[side], side == 1 and (data.old_path or data.path) or data.path))
  end
  local position, size = self.position, self.size
  if self.data then
    self:on_mouse_left()
    self.data.invalidated, self.data.capabilities_pending = true, nil
  end
  DiffView.super.new(self)
  self.position, self.size = position or self.position, size or self.size
  self.data, self.side, self.scrollable, self.panes = data, 2, true, panes
  self.selecting, self.all, self.change_index = nil, nil, nil
  self.action_rail, self.actions_visible = nil, nil
  self.cursor = "ibeam"
end
function DiffView:get_name() return common.basename(git.display(self.data.path)) .. " · Diff" end
function DiffView:get_filename() return git.display(self.data.path) .. " [read-only comparison]" end
function DiffView:line_height() return self.panes[1]:get_line_height() end
function DiffView:header_height() return style.font:get_height() * 2 + style.padding.y * 3 end
function DiffView:get_scrollable_size()
  return self:header_height() + math.max(1, #self.data.rows) * self:line_height() + style.padding.y * 2
end
function DiffView:get_h_scrollable_size() return math.huge end
function DiffView:layout()
  local header = math.min(self:header_height(), self.size.y)
  local rail_width = ui.action_width() * 2 + ui.action_gap() * 3
  local actions = self.data.action_slots and (self.data.action_slots.stage or self.data.action_slots.revert)
    or self.data.stage or self.data.revert
  local width = actions and self.size.x >= rail_width + 160 * SCALE and rail_width or math.min(style.divider_size, self.size.x)
  local half = math.max(0, (self.size.x - width) / 2)
  self.action_rail = ui.rect(self.position.x + half, self.position.y + header, width, self.size.y - header)
  self.actions_visible = actions and width == rail_width
  for side, pane in ipairs(self.panes) do
    pane.position.x, pane.position.y = self.position.x + (side - 1) * (half + width), self.position.y + header
    pane.size.x, pane.size.y = half, math.max(0, self.size.y - header)
    pane.scroll.x, pane.scroll.y = self.scroll.x, self.scroll.y
  end
end
function DiffView:action_boxes(index)
  self:layout()
  local boxes, hunk = {}, (self.data.hunks or {})[index]
  if not self.actions_visible or not hunk then return boxes end
  local rail, width, gap = self.action_rail, ui.action_width(), ui.action_gap()
  local top = self.position.y + self:header_height() + style.padding.y + (hunk.row - 1) * self:line_height() - self.scroll.y
  if self.data.stage or (self.data.action_slots and self.data.action_slots.stage) then
    boxes.stage = ui.visible_box(ui.rect(rail.x + gap, top, width, self:line_height()), rail)
  end
  if self.data.revert or (self.data.action_slots and self.data.action_slots.revert) then
    boxes.revert = ui.visible_box(ui.rect(rail.x + gap * 2 + width, top, width, self:line_height()), rail)
  end
  return boxes
end
function DiffView:action_at(action, x, y)
  self:layout()
  if not self.actions_visible or not ui.inside(self.action_rail, x, y) then return end
  local row = self:row_at(y)
  for i, hunk in ipairs(self.data.hunks or {}) do
    if hunk.row == row and ui.inside(self:action_boxes(i)[action], x, y) then return i end
  end
end
function DiffView:row_at(y)
  return common.clamp(math.floor((y - self.position.y - self:header_height() + self.scroll.y - style.padding.y) / self:line_height()) + 1, 1, math.max(1, #self.data.rows))
end
function DiffView:position_at(x, y)
  local pane, rows = self.panes[self.side], self.data.rows
  local row = self:row_at(y)
  local line = rows[row] and rows[row][self.side]
  -- Clicking padding selects the nearest source line, never a fabricated line.
  if not line then
    local i = row
    while i <= #rows and not line do line = rows[i][self.side]; i = i + 1 end
    i = row - 1
    while i > 0 and not line do line = rows[i][self.side]; i = i - 1 end
  end
  line = line or 1
  return line, pane:get_x_offset_col(line, x - pane.position.x - pane:get_gutter_width() + self.scroll.x)
end
function DiffView:can_revert()
  return not self.data.capabilities_pending and self.data.revert and not self.data.invalidated and (not self.data.can_revert or self.data.can_revert())
end
function DiffView:can_stage()
  return not self.data.capabilities_pending and self.data.stage and not self.data.invalidated and (not self.data.can_stage or self.data.can_stage())
end
function DiffView:stage_block(index)
  if self:can_stage() then self.data.stage(index or self.change_index) end
end
function DiffView:stage_lines()
  if not self:can_stage() then return end
  local doc = self.panes[self.side].doc
  local line, col, al, ac = doc:get_selection()
  local ok, first, last = pcall(require("plugins.gitpanel.diff").selection_rows, self.data, self.side, line, col, al, ac, self.all)
  if not ok then core.error("Git panel: %s", first); return end
  self.data.stage(nil, first, last)
end
function DiffView:stage_at(x, y)
  if self:can_stage() then return self:action_at("stage", x, y) end
end
function DiffView:block_at(row)
  for i, h in ipairs(self.data.hunks or {}) do
    if row >= h.row and row < h.row + h.height then return i end
  end
end
function DiffView:revert_block(index)
  if self.data.capabilities_pending then return end
  index = index or self.change_index
  if not index then core.error("Git panel: Select a change block first."); return end
  if self:can_revert() then self.data.revert(index)
  else core.error("Git panel: %s", self.data.invalidated and "Stale diff: reopen this file to see current changes." or self.data.discard_reason or "Revert is unavailable for this comparison.") end
end
function DiffView:arrow_at(x, y)
  if self:can_revert() then return self:action_at("revert", x, y) end
end
function DiffView:on_mouse_pressed(button, x, y, clicks)
  if DiffView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return true end
  self:layout()
  local stage = self:stage_at(x, y)
  if stage then self.change_index = stage; self:stage_block(stage); return true end
  local arrow = self:arrow_at(x, y)
  if arrow then self.change_index = arrow; self:revert_block(arrow); return true end
  -- Rail padding and disabled buttons are never source-selection targets.
  if ui.inside(self.action_rail, x, y) then return true end
  if not ui.inside(ui.rect(self.position.x, self.position.y, self.size.x, self.size.y), x, y) then return true end
  if y < self.position.y + self:header_height() then
    if y < self.position.y + style.font:get_height() + style.padding.y * 2 then
      local edge = self.position.x + self.size.x
      if x > edge - 50 * SCALE then self:raw_patch()
      elseif x > edge - 100 * SCALE then self:change(1)
      elseif x > edge - 150 * SCALE then self:change(-1) end
    else self.side = x < self.position.x + self.size.x / 2 and 1 or 2; self.all = false end
    core.redraw = true
    return true
  end
  self.side = x < self.position.x + self.size.x / 2 and 1 or 2
  local doc = self.panes[self.side].doc
  local line, col = self:position_at(x, y)
  self.change_index = self:block_at(self:row_at(y))
  self.all = false
  local _, _, al, ac = doc:get_selection()
  if not keymap.modkeys.shift then al, ac = line, col end
  if clicks == 2 then
    line, col, al, ac = self.panes[self.side]:mouse_selection(doc, "word", line, col, line, col)
  end
  doc:set_selection(line, col, al, ac)
  self.selecting = {al, ac}
  core.redraw = true
  return true
end
function DiffView:on_mouse_moved(x, y, ...)
  DiffView.super.on_mouse_moved(self, x, y, ...)
  self:layout()
  local arrow, stage = self:action_at("revert", x, y), self:action_at("stage", x, y)
  self.cursor = (arrow and self:can_revert() or stage and self:can_stage()) and "hand"
    or ui.inside(self.action_rail, x, y) and "arrow" or "ibeam"
  local reason = not self:can_revert() and y < self.position.y + self:header_height() and
    (self.data.invalidated and "Stale diff: reopen this file to see current changes." or self.data.discard_reason)
  local enabled = (arrow and self:can_revert() or stage and self:can_stage()) or false
  if arrow ~= self.hover_arrow or stage ~= self.hover_stage or reason ~= self.hover_reason or enabled ~= self.hover_enabled then
    self.hover_arrow, self.hover_stage, self.hover_reason, self.hover_enabled = arrow, stage, reason, enabled
    if core.status_view then
      if stage then core.status_view:show_tooltip((self.data.group == "staged" and "Unstage" or "Stage") .. " change block " .. stage .. " · index only · " .. git.display(self.data.path) .. (not self:can_stage() and " · Unavailable" or ""))
      elseif arrow then core.status_view:show_tooltip((self.data.remove_file and "Remove untracked file (recoverable) · whole file" or "Revert unstaged change block " .. arrow) .. " · " .. git.display(self.data.path) .. (not self:can_revert() and " · Unavailable" or ""))
      elseif reason then core.status_view:show_tooltip("Revert unavailable · " .. reason)
      else core.status_view:remove_tooltip() end
    end
    core.redraw = true
  end
  if self.selecting and not ui.inside(self.action_rail, x, y) then
    local line, col = self:position_at(x, y)
    self.panes[self.side].doc:set_selection(line, col, self.selecting[1], self.selecting[2])
    local top = self.position.y + self:header_height()
    if y < top then self.scroll.to.y = self.scroll.to.y - self:line_height()
    elseif y > self.position.y + self.size.y then self.scroll.to.y = self.scroll.to.y + self:line_height() end
    core.redraw = true
  end
end
function DiffView:on_mouse_left()
  if (self.hover_arrow or self.hover_stage or self.hover_reason) and core.status_view then core.status_view:remove_tooltip() end
  self.hover_arrow, self.hover_stage, self.hover_reason, self.hover_enabled = nil, nil, nil, nil
  self.cursor = "ibeam"
  core.redraw = true
  DiffView.super.on_mouse_left(self)
end
function DiffView:on_mouse_released(...)
  DiffView.super.on_mouse_released(self, ...)
  self.selecting = nil
end
function DiffView:change(direction)
  local changes = self.data.changes
  if #changes == 0 then return end
  self.change_index = ((self.change_index or (direction > 0 and 0 or 1)) + direction - 1) % #changes + 1
  local target = changes[self.change_index]
  self.scroll.to.y = (target - 1) * self:line_height() + style.padding.y
  self.all = false
  for side, pane in ipairs(self.panes) do
    local line = self.data.rows[target][side]
    if line then pane.doc:set_selection(line, 1) end
  end
  core.redraw = true
end
function DiffView:raw_patch() documents.open_patch(self:get_name() .. " · Raw patch", self.data.patch) end
function DiffView:move(kind, select)
  local pane = self.panes[self.side]
  local doc = pane.doc
  local line, col, al, ac = doc:get_selection()
  self.all = false
  if kind == "up" or kind == "down" then
    -- Native vertical translation preserves visual X and resolves a UTF-8
    -- character boundary, rather than reusing a byte column on another line.
    line, col = DocView.translate[kind == "up" and "previous_line" or "next_line"](doc, line, col, pane)
  elseif kind == "home" then col = 1
  elseif kind == "end" then col = #doc.lines[line]
  else line, col = translate[kind == "left" and "previous_char" or "next_char"](doc, line, col) end
  doc:set_selection(line, col, select and al or line, select and ac or col)
  line, col = doc:get_selection()
  local row = self.data.maps[self.side][line] or 1
  self.change_index = self:block_at(row)
  local y, height = style.padding.y + (row - 1) * self:line_height(), math.max(self:line_height(), self.size.y - self:header_height())
  if y < self.scroll.to.y then self.scroll.to.y = y
  elseif y + self:line_height() > self.scroll.to.y + height then self.scroll.to.y = y + self:line_height() - height end
  local x = pane:get_col_x_offset(line, col)
  local width = math.max(1, pane.size.x - pane:get_gutter_width() - style.padding.x)
  if x < self.scroll.to.x then self.scroll.to.x = x
  elseif x > self.scroll.to.x + width then self.scroll.to.x = x - width end
  core.redraw = true
end
local function shade(tint)
  local bg = style.background
  return { math.floor(bg[1] * .84 + tint[1] * .16), math.floor(bg[2] * .84 + tint[2] * .16), math.floor(bg[3] * .84 + tint[3] * .16), 255 }
end
function DiffView:draw()
  self:layout()
  self:draw_background(style.background)
  local header, lh = self:header_height(), self:line_height()
  local first = math.max(1, math.floor((self.scroll.y - style.padding.y) / lh) + 1)
  local last = math.min(#self.data.rows, first + math.ceil(math.max(0, self.size.y - header) / lh))
  for side, pane in ipairs(self.panes) do
    local x, y, w, h = pane.position.x, pane.position.y, pane.size.x, pane.size.y
    core.push_clip_rect(x, y, w, h)
    local gw, gpad = pane:get_gutter_width()
    local tint = side == 1 and (style.gitdiff_deletion or style.error or {224, 83, 83}) or (style.gitdiff_addition or style.good or {75, 190, 110})
    local bg = shade(tint)
    local _, indent = pane.doc:get_indent_info()
    pane:get_font():set_tab_size(indent)
    for row = first, last do
      local item = self.data.rows[row]
      local line, ry = item[side], y + style.padding.y + (row - 1) * lh - self.scroll.y
      if item.changed then
        renderer.draw_rect(x, ry, w, lh, line and bg or style.background2)
        if line then renderer.draw_rect(x, ry, math.max(1, 2 * SCALE), lh, tint) end
      end
      if line then
        pane:draw_line_gutter(line, x, ry, gw - (gpad or 0))
        core.push_clip_rect(x + math.min(gw, w), y, math.max(0, w - gw), h)
        pane:draw_line_body(line, x + gw - self.scroll.x, ry)
        if core.active_view == self and self.side == side then
          local cl, cc = pane.doc:get_selection()
          if cl == line then pane:draw_caret(x + gw - self.scroll.x + pane:get_col_x_offset(cl, cc), ry) end
        end
        core.pop_clip_rect()
      end
    end
    core.pop_clip_rect()
  end
  local x, y, w = self.position.x, self.position.y, self.size.x
  renderer.draw_rect(x, y, w, math.min(header, self.size.y), style.background2)
  local title_h = style.font:get_height() + style.padding.y * 2
  core.push_clip_rect(x, y, math.max(0, w - 150 * SCALE), math.min(title_h, self.size.y))
  common.draw_text(style.font, style.text, (self.data.invalidated and "STALE — reopen · " or "") .. self:get_name() .. " · " .. (self.change_index and (self.change_index .. "/") or "") .. #self.data.changes .. " changes", nil, x + style.padding.x, y, w, title_h)
  core.pop_clip_rect()
  core.push_clip_rect(x, y, w, self.size.y)
  for i, label in ipairs({"Prev", "Next", "Raw"}) do
    common.draw_text(style.font, style.accent, label, "center", x + w - (4 - i) * 50 * SCALE, y, 50 * SCALE, title_h)
  end
  for side, pane in ipairs(self.panes) do
    local label = side == 1 and ("Original · " .. (self.data.group == "staged" and "HEAD" or self.data.group == "untracked" and "Empty" or "Staged"))
      or ("Modified · " .. (self.data.group == "staged" and "Staged" or "Working"))
    local lines = self.data.lines[side]
    label = label .. " · " .. #lines .. " lines"
    if #lines > 0 and lines[#lines]:sub(-1) ~= "\n" then label = label .. " · No final newline" end
    if (side == 1 and self.data.original or self.data.modified):find("\r\n", 1, true) then label = label .. " · CRLF" end
    core.push_clip_rect(pane.position.x, y + title_h, pane.size.x, math.max(0, math.min(header - title_h, self.size.y - title_h)))
    common.draw_text(style.font, self.side == side and style.accent or style.dim, label, nil, pane.position.x + style.padding.x, y + title_h, pane.size.x, header - title_h)
    core.pop_clip_rect()
  end
  local rail = self.action_rail
  renderer.draw_rect(rail.x, rail.y, rail.w, rail.h, style.background2)
  local divider = math.min(style.divider_size, rail.w)
  renderer.draw_rect(rail.x, rail.y, divider, rail.h, style.divider)
  if self.actions_visible then
    renderer.draw_rect(rail.x + rail.w - divider, rail.y, divider, rail.h, style.divider)
    local can_stage, can_revert = self:can_stage(), self:can_revert()
    for i, hunk in ipairs(self.data.hunks or {}) do
      if hunk.row >= first and hunk.row <= last then
        local boxes = self:action_boxes(i)
        ui.draw_action(self.data.group == "staged" and "unstage" or "stage", boxes.stage, self.hover_stage == i, can_stage)
        ui.draw_action("undo", boxes.revert, self.hover_arrow == i, can_revert)
      end
    end
  end
  if #self.data.rows == 0 then common.draw_text(style.font, style.dim, self.data.removed and "File removed · no current changes" or "Empty files · no textual changes", nil, x + style.padding.x, y + header, w, lh) end
  self:draw_scrollbar()
  core.pop_clip_rect()
end
local function active() return core.active_view:is(DiffView), core.active_view end
command.add(active, {
  ["git-panel:next-change"] = function(view) view:change(1) end,
  ["git-panel:previous-change"] = function(view) view:change(-1) end,
  ["git-panel:raw-patch"] = function(view) view:raw_patch() end,
  ["git-panel:diff-other-side"] = function(view) view.side = 3 - view.side; view.all = false; core.redraw = true end,
  ["git-panel:diff-copy"] = function(view)
    system.set_clipboard(view.all and (view.side == 1 and view.data.original or view.data.modified) or view.panes[view.side].doc:copy_selection())
  end,
  ["git-panel:diff-select-all"] = function(view)
    local doc = view.panes[view.side].doc
    doc:set_selection(1, 1, #doc.lines, #doc.lines[#doc.lines]); view.all = true; core.redraw = true
  end,
})
command.add(function()
  local yes, view = active()
  return yes and not view.data.remove_file and view:can_revert() and view.change_index ~= nil, view
end, { ["git-panel:revert-selected-change"] = function(view) view:revert_block(view.change_index) end })
for _, group in ipairs({"changes", "staged"}) do
  local staged = group == "staged"
  command.add(function()
    local yes, view = active()
    return yes and view:can_stage() and (view.data.group == "staged") == staged and view.change_index ~= nil, view
  end, { ["git-panel:" .. (staged and "unstage" or "stage") .. "-selected-block"] = function(view) view:stage_block() end })
  command.add(function()
    local yes, view = active()
    return yes and view:can_stage() and (view.data.group == "staged") == staged, view
  end, { ["git-panel:" .. (staged and "unstage" or "stage") .. "-selected-lines"] = function(view) view:stage_lines() end })
end
local bindings = { ["alt+down"] = "git-panel:next-change", ["alt+up"] = "git-panel:previous-change", ["tab"] = "git-panel:diff-other-side",
  ["ctrl+c"] = "git-panel:diff-copy", ["cmd+c"] = "git-panel:diff-copy", ["ctrl+a"] = "git-panel:diff-select-all", ["cmd+a"] = "git-panel:diff-select-all" }
for _, direction in ipairs({"left", "right", "up", "down", "home", "end"}) do
  local dir = direction
  for _, select in ipairs({false, true}) do
    local extend = select
    local name = "git-panel:diff-" .. (select and "select-" or "move-") .. dir
    command.add(active, {[name] = function(view) view:move(dir, extend) end})
    bindings[(select and "shift+" or "") .. dir] = name
  end
end
for _, direction in ipairs({-1, 1}) do
  local delta = direction
  local name = "git-panel:diff-page-" .. (delta < 0 and "up" or "down")
  command.add(active, {[name] = function(view) view.scroll.to.y = view.scroll.to.y + delta * math.max(view:line_height(), view.size.y - view:header_height()) end})
  bindings[delta < 0 and "pageup" or "pagedown"] = name
end
keymap.add(bindings)
return DiffView
