local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local system = require "system"
local View = require "core.view"
local DocView = require "core.docview"
local ui = require "plugins.gitpanel.ui"
local document = require "plugins.gitpanel.markdown.document"
local layout = require "plugins.gitpanel.markdown.layout"
local M = {}
local Preview = View:extend()
M.Preview = Preview
-- No .doc field: native open_doc must keep opening the real source editor.
-- Snapshots neither participate in Doc save/undo nor keep discarded buffers alive.
function Preview:new(path, text)
  Preview.super.new(self)
  self.path, self.text, self.scrollable = path, text, true
  self.images, self.image_count, self.image_pixels = {}, 0, 0
end
function Preview:get_name() return common.basename(self.path) .. " · Markdown" end
function Preview:get_filename() return self.path .. " [read-only preview]" end
function Preview:header_height() return style.font:get_height() + style.padding.y * 2 end
function Preview:get_scrollable_size() return (self.display and self.display.height or 0) + self:header_height() end
function Preview:get_h_scrollable_size() return self.display and self.display.width or self.size.x end
function Preview:refresh()
  local text, err = document.read(self.path, core.docs, system)
  if not text then core.error("Markdown preview: %s", err); return end
  self.text, self.images, self.display = text, {}, nil
  self.image_count, self.image_pixels = 0, 0
  core.redraw = true
end
function Preview:source()
  local info = system.get_file_info(self.path)
  local existing
  for _, doc in ipairs(core.docs) do if doc.abs_filename == self.path then existing = doc; break end end
  if not existing and (not info or info.type ~= "file") then
    core.error("Markdown source is missing; no new file was created."); return
  end
  core.try(function() core.root_view:open_doc(existing or core.open_doc(self.path)) end)
end
function Preview:load_image(target)
  if self.images[target] then return (table.unpack or unpack)(self.images[target]) end
  local function fail(reason) self.images[target] = { false, reason }; return false, reason end
  local resolved, err = document.resolve(self.path, target)
  if not resolved then return fail(err) end
  if resolved.kind ~= "file" then return fail("Remote images are not fetched.") end
  local info = system.get_file_info(resolved.path)
  if not info or info.type ~= "file" then return fail("Missing image: " .. resolved.path) end
  if not resolved.path:lower():match("%.png$") and not resolved.path:lower():match("%.jpe?g$")
    and not resolved.path:lower():match("%.gif$") and not resolved.path:lower():match("%.bmp$") then
    return fail("Unsupported format (PNG/JPEG/GIF/BMP only).")
  end
  if info.size and info.size > 8 * 1024 * 1024 then return fail("Image exceeds 8 MiB.") end
  if not rawget(_G, "canvas") or not renderer.draw_canvas then
    return fail("Requires Lite XL canvas + libraries.image.")
  end
  local ok, image = pcall(require, "libraries.image")
  if not ok then return fail("Install the optional lite-xl-image library.") end
  if self.image_count >= 32 or self.image_pixels >= 8 * 1024 * 1024 then
    return fail("Preview image budget reached (32 images / 8 megapixels).")
  end
  local loaded, result = pcall(function()
    local data = image.load(resolved.path)
    assert(data and data.width > 0 and data.height > 0, "Invalid image")
    assert(data.width <= 4096 and data.height <= 4096 and data.width * data.height <= 4 * 1024 * 1024,
      "Image exceeds 4096px / 4 megapixels")
    assert(self.image_pixels + data.width * data.height <= 8 * 1024 * 1024, "Preview exceeds 8 megapixels")
    local surface = canvas.new(data.width, data.height)
    surface:set_pixels(data:save({ channels = 4 }), 0, 0, data.width, data.height)
    return { canvas = surface, w = data.width, h = data.height }
  end)
  if not loaded then return fail("Cannot decode image: " .. tostring(result)) end
  self.image_count, self.image_pixels = self.image_count + 1, self.image_pixels + result.w * result.h
  self.images[target] = { result }
  return result
end
function Preview:update_layout()
  local width = math.max(1, self.size.x - style.scrollbar_size)
  -- Cache geometry, but invalidate on font/scale/theme changes.
  local theme = table.concat({ tostring(style.text), tostring(style.accent), tostring(style.dim),
    tostring(style.background2), tostring(style.syntax.string), tostring(style.divider) }, ":")
  local font_size = style.font.get_size and style.font:get_size() or style.font:get_height()
  if not self.fonts or self.font ~= style.font or self.code_font ~= style.code_font
    or self.scale ~= SCALE or self.font_size ~= font_size then
    self.fonts = layout.fonts()
    self.font, self.code_font, self.scale, self.font_size = style.font, style.code_font, SCALE, font_size
    self.display = nil
  end
  if not self.display or self.width ~= width or self.theme ~= theme then
    self.display = layout.compute(self.text, width, self.fonts, function(target) return self:load_image(target) end)
    self.width, self.theme = width, theme
  end
end
function Preview:update()
  self:update_layout()
  Preview.super.update(self)
end
function Preview:buttons()
  local h = self:header_height()
  local w = math.min(self.size.x / 2, style.font:get_width("Refresh") + style.padding.x * 2)
  return {
    source = ui.rect(self.position.x, self.position.y, w, h),
    refresh = ui.rect(self.position.x + w, self.position.y, w, h),
  }
end
function Preview:hit(x, y)
  if not ui.inside(ui.rect(self.position.x, self.position.y, self.size.x, self.size.y), x, y) then return end
  for action, box in pairs(self:buttons()) do if ui.inside(box, x, y) then return action end end
  if y < self.position.y + self:header_height() or x >= self.position.x + self.size.x - style.scrollbar_size then return end
  local ox, oy = self:get_content_offset()
  for _, item in ipairs(self.display and self.display.items or {}) do
    if item.target and ui.inside(ui.rect(ox + item.x, oy + self:header_height() + item.y, item.w, item.h), x, y) then
      return "link", item.target
    end
  end
end
function Preview:follow(target)
  local resolved, err = document.resolve(self.path, target)
  if not resolved then core.error("Markdown link: %s", err); return end
  if resolved.kind == "url" then
    -- Explicit user gesture only. Native argv avoids shell interpolation.
    local opener = PLATFORM:find("Mac") and "open" or PLATFORM == "Linux" and "xdg-open"
    if not opener then core.error("Open this URL externally: %s", resolved.path); return end
    core.add_thread(function()
      local code, _, message = require("plugins.gitpanel.runner").run({ opener, resolved.path }, core.project_dir)
      if code ~= 0 then core.error("Could not open Markdown link: %s", message) end
    end)
  elseif resolved.kind == "anchor" or resolved.path == self.path then
    self:update_layout()
    local y = self.display.anchors[resolved.anchor]
    if y then self.scroll.to.y = y; core.redraw = true
    else core.error("Markdown heading not found: %s", resolved.anchor) end
  elseif document.is_markdown(resolved.path) then
    local view = M.open(resolved.path)
    if view and resolved.anchor ~= "" then view:follow("#" .. resolved.anchor) end
  else
    local info = system.get_file_info(resolved.path)
    if not info or info.type ~= "file" then core.error("Markdown link is missing: %s", resolved.path); return end
    -- Never send local attachments/scripts to the OS for execution.
    if not resolved.path:lower():match("%.txt$") and not resolved.path:lower():match("%.lua$")
      and not resolved.path:lower():match("%.json$") then
      core.error("Open this attachment manually: %s", resolved.path); return
    end
    core.try(function() core.root_view:open_doc(core.open_doc(resolved.path)) end)
  end
end
function Preview:on_mouse_pressed(button, x, y, clicks)
  if Preview.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button ~= "left" then return false end
  local action, target = self:hit(x, y)
  if action == "source" then self:source()
  elseif action == "refresh" then self:refresh()
  elseif action == "link" then self:follow(target) end
  return true
end
function Preview:on_mouse_moved(x, y, ...)
  Preview.super.on_mouse_moved(self, x, y, ...)
  local action = self:hit(x, y)
  self.cursor = action and "hand" or "arrow"
end
function Preview:draw()
  self:update_layout()
  self:draw_background(style.background)
  local ox, oy = self:get_content_offset()
  local h = self:header_height()
  core.push_clip_rect(self.position.x, self.position.y + h, self.size.x, math.max(0, self.size.y - h))
  for _, item in ipairs(self.display.items) do
    local y = oy + h + item.y
    if y + item.h >= self.position.y + h and y < self.position.y + self.size.y then
      if item.kind == "text" then renderer.draw_text(item.font, item.text, ox + item.x, y, item.color)
      elseif item.kind == "rect" then renderer.draw_rect(ox + item.x, y, item.w, item.h, item.color)
      elseif item.kind == "image" then renderer.draw_canvas(item.canvas, ox + item.x, y) end
    end
  end
  core.pop_clip_rect()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, math.min(h, self.size.y))
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, h, style.background2)
  for action, box in pairs(self:buttons()) do
    common.draw_text(style.font, style.accent, action == "source" and "Source" or "Refresh", "center", box.x, box.y, box.w, box.h)
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end
function M.open(path)
  local text, err = document.read(path, core.docs, system)
  if not text then core.error("Markdown preview: %s", err); return end
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view:is(Preview) and view.path == path then
      view.text, view.images, view.display = text, {}, nil
      view.image_count, view.image_pixels = 0, 0
      core.root_view.root_node:get_node_for_view(view):set_active_view(view)
      return view
    end
  end
  local view = Preview(path, text)
  core.root_view:get_active_node_default():add_view(view)
  return view
end
function M.install(panel, tree)
  local function selected()
    local active = core.active_view
    if active and active:is(Preview) then return active.path end
    if active and active:is(DocView) and active.doc.abs_filename then return active.doc.abs_filename end
    -- Clicking a Git row opens its comparison. Use that comparison, never a stale selection.
    local DiffView = require "plugins.gitpanel.diffview"
    if active and active:is(DiffView) then return active.data.root .. "/" .. active.data.path end
    if active == panel and panel.mode == "git" then
      local row = panel.list:selected_row()
      return row and row.entry and panel.model.root and panel.model.root .. "/" .. row.entry.path
    end
    if active == tree or active == panel and panel.mode == "files" then
      local item = tree.hovered_item or tree.selected_item
      return item and item.type == "file" and item.abs_filename
    end
  end
  command.add(function() local path = selected(); return document.is_markdown(path), path end, {
    ["git-panel:preview-markdown"] = function(path) M.open(path) end,
  })
  command.add(Preview, {
    ["git-panel:refresh-markdown"] = function(view) view:refresh() end,
    ["git-panel:markdown-source"] = function(view) view:source() end,
  })
  keymap.add { ["ctrl+shift+m"] = "git-panel:preview-markdown" }
  if tree.contextmenu and tree.contextmenu.register then
    tree.contextmenu:register(function() return document.is_markdown(selected()) end, {
      { text = "Preview Markdown", command = "git-panel:preview-markdown" },
    })
  end
end
return M
