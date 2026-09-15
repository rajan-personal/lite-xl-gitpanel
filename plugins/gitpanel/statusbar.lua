local core = require "core"
local common = require "core.common"
local style = require "core.style"
local git = require "plugins.gitpanel.git"
local icons = require "plugins.gitpanel.toolbar"
local M = {}

function M.install(bar, panel)
  local function current_status()
    local model = panel.model
    return model:valid(model.context) and model.status or nil
  end
  local function label()
    local status = current_status()
    return status and git.display(status.branch)
      or (panel.model.refreshing and "Git…" or "No Git repository")
  end
  local item = bar:add_item {
    name = "git-panel:branch",
    alignment = bar.Item.RIGHT,
    position = 1,
    -- Independent of active editor/sidebar: visible even with no document open.
    get_item = function(self)
      self.tooltip = label() .. (current_status() and " — Click to switch branches" or " — Open a Git project")
      return {}
    end,
    command = function(button)
      if button == "left" and current_status() and panel.model.root then
        panel:pick_branch()
      end
    end,
  }
  item.on_draw = function(x, y, h, hovered, calc_only)
    local font, gap = style.font, style.padding.x / 2
    local icon_size = font:get_height()
    local name = label()
    local limit = math.max(60 * SCALE, math.min(240 * SCALE, bar.size.x / 3))
    if font:get_width(name) > limit then
      local shortened = ""
      for char in common.utf8_chars(name) do
        if font:get_width(shortened .. char .. "…") > limit then break end
        shortened = shortened .. char
      end
      name = shortened .. "…"
    end
    local width = icon_size + gap + font:get_width(name)
    if not calc_only then
      local tint = hovered and style.accent or current_status() and style.text or style.dim
      icons.draw_branch_icon(x, y, icon_size, h, tint)
      common.draw_text(font, tint, name, nil, x + icon_size + gap, y, 0, h)
    end
    return width
  end

  -- SCM already supplies a plain branch item. Suppress that duplicate only
  -- while our Git status is available; retain its original predicate otherwise.
  local scm_item = bar:get_item("status:scm")
  if scm_item then
    local predicate = scm_item.predicate
    function scm_item:predicate(...)
      return not current_status() and predicate(self, ...)
    end
  end
  return item
end

return M
