local core = require "core"
local style = require "core.style"
local common = require "core.common"
local ui = {}

function ui.rect(x, y, w, h)
  return { x = x, y = y, w = math.max(0, w), h = math.max(0, h) }
end
function ui.inside(box, x, y)
  return box and x >= box.x and y >= box.y and x < box.x + box.w and y < box.y + box.h
end
-- A partially clipped symbol must not leave an invisible/ambiguous hit target.
function ui.visible_box(box, viewport)
  if box.w > 0 and box.h > 0 and box.x >= viewport.x and box.y >= viewport.y
    and box.x + box.w <= viewport.x + viewport.w and box.y + box.h <= viewport.y + viewport.h then
    return box
  end
end
function ui.action_width() return math.floor(22 * SCALE + .5) end
function ui.action_gap() return math.max(1, math.floor(8 * SCALE + .5)) end

-- The bundled icon font's +/- are tree chevrons, not index actions. These
-- small pixel-aligned strokes work with any theme/font; undo is a bent return
-- arrow, deliberately distinct from the index plus/minus.
function ui.draw_action(symbol, box, hovered, enabled)
  if not box then return end
  core.push_clip_rect(box.x, box.y, box.w, box.h)
  if hovered then renderer.draw_rect(box.x, box.y, box.w, box.h, style.line_highlight) end
  local tint = not enabled and style.dim or hovered and style.accent or style.text
  local unit = math.max(1, math.floor(SCALE + .5))
  local cx, cy = math.floor(box.x + box.w / 2), math.floor(box.y + box.h / 2)
  local function stroke(x, y, w, h)
    renderer.draw_rect(cx + x * unit, cy + y * unit, w * unit, h * unit, tint)
  end
  if symbol == "stage" or symbol == "unstage" then
    stroke(-5, 0, 11, 1)
    if symbol == "stage" then stroke(0, -5, 1, 11) end
  else
    assert(symbol == "undo", "unknown action symbol")
    stroke(-5, -3, 10, 1); stroke(4, -2, 1, 7); stroke(-1, 4, 5, 1)
    for i = 1, 3 do
      stroke(-5 + i, -3 - i, 1, 1)
      stroke(-5 + i, -3 + i, 1, 1)
    end
  end
  core.pop_clip_rect()
end
-- VS Code's default Git badge counts resources, not unique paths: a partially
-- staged file occurs in both index and working tree. Never use this for guards.
function ui.scm_count(model)
  local status = model.status
  if not model.root or not status or not model:valid(model.context) then return 0 end
  return #status.conflicts + #status.staged + #status.changes + #status.untracked
end

local badge_cache = setmetatable({}, { __mode = "k" })
local badge_blue, badge_white = { 0, 120, 212, 255 }, { 255, 255, 255, 255 }
local function badge_metrics()
  local source = style.font
  local size = math.max(1, math.floor(source:get_height() * .75))
  local cached = badge_cache[source]
  if not cached or cached.scale ~= SCALE or cached.size ~= size then
    local font = source:copy(size)
    cached = { scale = SCALE, size = size, font = font, height = font:get_height(), widths = {} }
    badge_cache[source] = cached
  end
  return cached
end

-- The owner supplies a non-overlapping cell. Hide, rather than paint a partial
-- badge, if that cell's resulting badge is clipped. No independent hit region.
function ui.count_badge(count, cell, viewport)
  if count <= 0 or cell.w <= 0 or cell.h <= 0 then return end
  local metrics = badge_metrics()
  local pad, height = 2 * SCALE, metrics.height + 2 * SCALE
  if height > cell.h then return end
  local label = count <= 999 and tostring(count) or "99+"
  local function width(value)
    if not metrics.widths[value] then metrics.widths[value] = metrics.font:get_width(value) end
    return math.max(height, metrics.widths[value] + pad * 2)
  end
  if width(label) > cell.w then label = count > 9 and "9+" or label end
  if width(label) > cell.w then return end
  local box = ui.rect(cell.x + cell.w - width(label), cell.y + cell.h - height, width(label), height)
  if viewport and not ui.visible_box(box, viewport) then return end
  box.label, box.font = label, metrics.font
  return box
end
-- Section totals include zero and remain exact; unlike the toolbar badge they
-- are centered in a row and have no independent action/hit target.
function ui.section_count(count, cell, viewport)
  local metrics = badge_metrics()
  local label = tostring(count)
  if not metrics.widths[label] then metrics.widths[label] = metrics.font:get_width(label) end
  local height = metrics.height + 2 * SCALE
  local width = math.max(height, metrics.widths[label] + 4 * SCALE)
  if width > cell.w or height > cell.h then return end
  local box = ui.rect(cell.x + cell.w - width, cell.y + (cell.h - height) / 2, width, height)
  if viewport and not ui.visible_box(box, viewport) then return end
  box.label, box.font = label, metrics.font
  return box
end
local section_gray, section_white = { 97, 97, 97, 255 }, { 248, 248, 248, 255 }
function ui.draw_section_count(box)
  ui.draw_count_badge(box, rawget(style, "gitpanel_section_background") or section_gray,
    rawget(style, "gitpanel_section_foreground") or section_white)
end
function ui.draw_count_badge(box, background, foreground)
  if not box then return end
  background = background or rawget(style, "gitpanel_badge_background") or badge_blue
  foreground = foreground or rawget(style, "gitpanel_badge_foreground") or badge_white
  core.push_clip_rect(box.x, box.y, box.w, box.h)
  -- Pixel-rounded capsule using existing renderer primitives, no glyph dependency.
  local corner = math.max(1, math.floor(SCALE))
  renderer.draw_rect(box.x + corner, box.y, box.w - corner * 2, box.h, background)
  renderer.draw_rect(box.x, box.y + corner, box.w, box.h - corner * 2, background)
  common.draw_text(box.font, foreground, box.label, "center", box.x, box.y, box.w, box.h)
  core.pop_clip_rect()
end
return ui
