-- Add one toggle to the native toolbar; retain its spacing, hit testing,
-- tooltips, commands and all existing icons. No app-bundle edits.
local core = require "core"
local style = require "core.style"
local ui = require "plugins.gitpanel.ui"
local M = {}

local function branch_icon(x, y, w, h, tint)
  local size = math.min(w, h) * 0.82
  local left, top = x + (w - size) / 2, y + (h - size) / 2
  local stroke = math.max(1, math.floor(size / 12))
  local dot = math.max(stroke * 3, math.floor(size * 0.24))
  local a, b = math.floor(left), math.floor(left + size - dot)
  local t, mid, bottom = math.floor(top), math.floor(top + size * 0.48), math.floor(top + size - dot)
  local ac, bc = a + math.floor(dot / 2), b + math.floor(dot / 2)
  renderer.draw_rect(ac - stroke / 2, t + dot, stroke, math.max(0, bottom - t - dot), tint)
  renderer.draw_rect(ac, mid, math.max(0, bc - ac), stroke, tint)
  renderer.draw_rect(bc - stroke / 2, t + dot, stroke, math.max(0, mid - t - dot), tint)
  for _, point in ipairs({{a, t}, {b, t}, {a, bottom}}) do
    renderer.draw_rect(point[1], point[2], dot, dot, tint)
    renderer.draw_rect(point[1] + stroke, point[2] + stroke, dot - stroke * 2, dot - stroke * 2, style.background2)
  end
end

M.draw_branch_icon = branch_icon

function M.install(toolbar, panel)
  if not toolbar then return end
  local item = { symbol = " ", command = "git-panel:toggle" }
  table.insert(toolbar.toolbar_commands, math.min(3, #toolbar.toolbar_commands + 1), item)
  local function badge(self, x, y, w, h)
    -- Half of each native gap belongs to this icon; adjacent icon rectangles
    -- and all original layout/hit regions remain untouched.
    return ui.count_badge(ui.scm_count(panel.model), ui.rect(x - w / 4, y, w * 1.5, h),
      ui.rect(self.position.x, self.position.y, self.size.x, self.size.y))
  end
  local draw = toolbar.draw
  function toolbar:draw()
    draw(self)
    if not self.visible then return end
    for entry, x, y, w, h in self:each_item() do
      if entry == item then
        local active = panel.mode == "git"
        local tint = active and style.accent or self.hovered_item == item and style.text or style.dim
        branch_icon(x, y, w, h, tint)
        ui.draw_count_badge(badge(self, x, y, w, h))
        -- Same understated active colour as the Files tree, no extra tab bar.
        if active then
          renderer.draw_rect(x, y + h + math.max(1, style.padding.y / 2), w, math.max(1, SCALE), tint)
        end
        break
      end
    end
  end
  local mouse_moved = toolbar.on_mouse_moved
  function toolbar:on_mouse_moved(px, py, ...)
    mouse_moved(self, px, py, ...)
    if not self.visible then return end
    for entry, x, y, w, h in self:each_item() do
      if entry == item then
        if ui.inside(badge(self, x, y, w, h), px, py) then
          -- Reuse native tooltip/hover dispatch at this icon's center.
          mouse_moved(self, x + w / 2, y + h / 2, 0, 0)
        end
        break
      end
    end
  end
  local mouse_pressed = toolbar.on_mouse_pressed
  function toolbar:on_mouse_pressed(button, x, y, clicks)
    -- Resolve the clicked item even if no mouse-move preceded the click.
    if self.visible then self:on_mouse_moved(x, y, 0, 0) end
    if self.hovered_item == item and button ~= "left" then return true end
    return mouse_pressed(self, button, x, y, clicks)
  end
  core.redraw = true
  return item
end

return M
