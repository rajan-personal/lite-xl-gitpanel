-- Headless smoke test using installed *actual* Object/View/Doc/DocView/Node.
-- Renderer, scheduling, syntax engine and process are mocked; no GUI is started.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local resources = arg[1] or "/Applications/Lite XL.app/Contents/Resources"
package.path = base .. "/../../../?.lua;" .. base .. "/../../../?/init.lua;" .. resources .. "/?.lua;" .. resources .. "/?/init.lua;" .. package.path
-- Userdir path patterns need plugins/..., not a second plugins component.
package.path = base:match("^(.*)/plugins/gitpanel$") .. "/?.lua;" .. base:match("^(.*)/plugins/gitpanel$") .. "/?/init.lua;" .. package.path
SCALE, PATHSEP, PLATFORM, DATADIR, USERDIR = 1, "/", "Mac OS X", resources, base:match("^(.*)/plugins/gitpanel$")
table.unpack = table.unpack or unpack
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
local function noop() end
local Font = {}
Font.__index = Font
function Font:get_height() return self.height end
function Font:get_width(s) return #tostring(s) * self.height / 2 end
function Font:copy(h) return setmetatable({ height = h }, Font) end
function Font:set_tab_size() end
function Font:get_tab_size() return 2 end
local font = setmetatable({ height = 15 }, Font)
local draws, clips = {}, 0
renderer = {
  draw_rect = function(x, y, w, h, color) assert(w >= 0 and h >= 0); assert(color) end,
  draw_text = function(f, t, x, y, c) assert(c); draws[#draws + 1] = t; return x + f:get_width(t) end,
  set_clip_rect = noop,
}
local clock = 1
system = { get_time = function() return clock end, absolute_path = function(p) return p end, set_clipboard = noop, window_has_focus = function() return true end }
package.loaded.system = system
local core = { docs = {}, project_dir = "/fixture", project_directories = {}, redraw = true, blink_start = 0, blink_timer = 0,
  error = noop, warn = noop, log = noop, blink_reset = noop, request_cursor = noop,
  on_quit_project = noop, threads = {}, last_active_view = nil,
  push_clip_rect = function() clips = clips + 1 end,
  pop_clip_rect = function() clips = clips - 1; assert(clips >= 0) end,
  add_thread = function(fn) end,
  status_view = { show_tooltip = noop, remove_tooltip = noop },
}
function core.set_active_view(v) core.last_active_view, core.active_view = core.active_view, v end
function core.get_views_referencing_doc() return {} end
package.loaded.core = core
local common = require "core.common"
-- LuaJIT 5.1 cannot parse the native 5.4 UTF-8 pattern's literal NUL.
-- Equivalent iterator shim; all Doc/DocView operations remain native.
function common.utf8_chars(s) return s:gmatch("[%z\1-\127\194-\244][\128-\191]*") end
local config = require "core.config"
config.transitions = false
config.plugins.treeview = {}
local c = { 50, 50, 50, 255 }
local style = setmetatable({ font = font, code_font = font, icon_font = font, icon_big_font = font:copy(25), big_font = font, padding = {x = 14, y = 7},
  scrollbar_size = 4, expanded_scrollbar_size = 12, divider_size = 1, caret_width = 2, tab_width = 170,
  syntax = setmetatable({}, {__index = function() return c end}), syntax_fonts = {}, log = {},
}, {__index = function() return c end})
package.loaded["core.style"] = style
package.loaded["core.ime"] = { editing = false, set_location = noop }
-- Use actual dispatch and root predicates: errors must fail the test rather
-- than being swallowed by core.try's normal error-reporting boundary.
function core.try(fn, ...) return true, fn(...) end
core.log_quiet = noop
local command = require "core.command"
package.loaded["core.keymap"] = { modkeys = {}, add = noop, get_binding = function() return "key" end }
local syntax_paths = {}
local syntax = { get = function(path) if path then syntax_paths[#syntax_paths + 1] = path end; return {} end }
package.loaded["core.syntax"] = syntax
local Object = require "core.object"
local Highlighter = Object:extend()
function Highlighter:new(doc) self.doc, self.lines = doc, {} end
Highlighter.soft_reset, Highlighter.insert_notify, Highlighter.remove_notify = noop, noop, noop
function Highlighter:get_line(line) return { tokens = {"normal", self.doc.lines[line]} } end
function Highlighter:each_token(line)
  local yielded = false
  return function()
    if not yielded then yielded = true; return 1, "normal", self.doc.lines[line] end
  end
end
package.loaded["core.doc.highlighter"] = Highlighter
package.loaded.process = {}
local View = require "core.view"
local tree = View()
tree.visible, tree.target_size, tree.init_size = true, 200, true
tree.tooltip = { alpha = 0 }
tree.cache = { retained = { expanded = true } }
tree.contextmenu = { on_mouse_pressed = function() return true end }
function tree:set_target_size(axis, value) if axis == "x" then self.target_size = value; return true end end
function tree:update() self.size.x = self.visible and self.target_size or 0 end
function tree:get_item_height() return style.font:get_height() + style.padding.y end
function tree:draw() end
local native_items = {}
function tree:draw_item_background() end
function tree:draw_item(item, active, hovered, x, y, w, h)
  native_items[#native_items + 1] = { item = item, h = h }
end
local ToolbarView = require "plugins.toolbarview"
tree.toolbar = ToolbarView()
local original_toolbar_count = #tree.toolbar.toolbar_commands
package.loaded["plugins.treeview"] = tree
local RootView = require "core.rootview"
core.root_view = RootView()
core.root_view.root_node.is_primary_node = true
core.set_active_view(core.root_view.root_node.active_view)
local tree_node = core.root_view:get_active_node():split("left", tree, {x = true}, true)
local StatusView = require "core.statusview"
core.status_view = StatusView()
core.status_view.size.x = 1000
local existing_scm = core.status_view:add_item { name = "status:scm", get_item = function() return {"main"} end }
local panel = require "plugins.gitpanel"
require "core.commands.root"
panel.size.x, panel.size.y = 320, 800
panel:update()
assert(tree_node.active_view == panel and tree_node.locked.x and tree_node.resizable)
local checks = 0
local function check(c, label) assert(c, label); checks = checks + 1; print("PASS " .. label) end
local ui = require "plugins.gitpanel.ui"
local symbol_draws, symbol_strokes = #draws, {}
local draw_rect = renderer.draw_rect
for _, symbol in ipairs({"stage", "unstage", "undo"}) do
  local strokes = 0
  renderer.draw_rect = function(...) strokes=strokes+1; draw_rect(...) end
  ui.draw_action(symbol, {x=0,y=0,w=22,h=22}, false, true)
  symbol_strokes[symbol] = strokes
end
renderer.draw_rect = draw_rect
check(#draws == symbol_draws and symbol_strokes.stage==2 and symbol_strokes.unstage==1 and symbol_strokes.undo==9,
  "action symbols render distinct plus/minus/bent-undo primitives, never unsupported text or chevrons")
local saved_scale, saved_text, saved_dim, saved_accent = SCALE, style.text, style.dim, style.accent
style.text,style.dim,style.accent={1,2,3,255},{4,5,6,255},{7,8,9,255}
for _, scale in ipairs({1,1.5,2}) do
  SCALE=scale
  local tint, bounded=true,true
  renderer.draw_rect = function(x,y,w,h,color)
    bounded=bounded and x>=0 and y>=0 and x+w<=22*scale and y+h<=22*scale
    tint=tint and color==style.dim
    draw_rect(x,y,w,h,color)
  end
  ui.draw_action("undo",{x=0,y=0,w=22*scale,h=22*scale},false,false)
  check(tint and bounded, "disabled primitive uses theme dim and stays in scaled button bounds at scale "..scale)
end
renderer.draw_rect = draw_rect
SCALE,style.text,style.dim,style.accent=saved_scale,saved_text,saved_dim,saved_accent
check(panel.size.x == 200, "native Files width preserved without adding an editor host")
check(#tree.toolbar.toolbar_commands == original_toolbar_count + 1 and tree.toolbar.toolbar_commands[3] == panel.toolbar_item,
  "Git toggle inserted beside native file/folder toolbar controls")
panel.model.status = require("plugins.gitpanel.git").status("## main\0MM src/partial.lua\0?? file name.lua\0")
panel.model.root = "/fixture"
panel.model.refreshing = false
local branch_item = core.status_view:get_item("git-panel:branch")
check(branch_item == panel.branch_item and branch_item.visible, "branch item registered in actual native status bar")
for _, view in ipairs({tree, panel, panel.composer, core.root_view:get_primary_node().active_view}) do
  core.set_active_view(view)
  check(branch_item:predicate(), "branch remains visible independently of active Files/Git/composer/editor view")
end
branch_item:get_item()
local before_draws = #draws
local branch_width = branch_item.on_draw(0, 0, 30, false, true)
check(branch_width > 0 and #draws == before_draws, "branch item measures without rendering during native layout")
branch_item.on_draw(0, 0, 30, false)
check(draws[#draws] == "main" and branch_item.tooltip:find("main"), "status bar renders current branch and exposes tooltip")
check(not existing_scm:predicate(), "existing SCM branch item hidden only while Git status available")
local original_picker, picker_calls = panel.pick_branch, 0
panel.pick_branch = function() picker_calls = picker_calls + 1 end
panel:show("files")
branch_item.on_click("left")
branch_item.on_click("right")
check(picker_calls == 1 and panel.mode == "files", "branch click opens picker without switching Files view; right click ignored")
local saved_status = panel.model.status
panel.model.status = nil
branch_item.on_draw(0, 0, 30, false)
branch_item.on_click("left")
check(draws[#draws] == "No Git repository" and picker_calls == 1 and existing_scm:predicate(), "no-repository state is explicit, inert and restores existing SCM predicate")
panel.model.status = { branch = "Detached HEAD" }
branch_item.on_draw(0, 0, 30, false)
check(draws[#draws] == "Detached HEAD", "detached HEAD is visible in bottom bar")
panel.model.status = { branch = string.rep("feature/", 50) }
branch_item:get_item()
branch_item.on_draw(0, 0, 30, false)
check(style.font:get_width(draws[#draws]) <= 240 and #branch_item.tooltip > 350, "long branch label is bounded while tooltip retains full name")
panel.model.status = saved_status
panel.pick_branch = original_picker
core.status_view:update()
check(branch_item.active and branch_item.w > 0, "native status-bar layout activates branch with Files focused")
core.status_view:show_tooltip("file/path.lua")
before_draws = #draws
core.status_view:draw()
local branch_with_tooltip = false
for i = before_draws + 1, #draws do if draws[i] == "main" then branch_with_tooltip = true end end
check(branch_with_tooltip and clips == 0, "branch remains drawn beside native file-path tooltips")
core.status_view:remove_tooltip()
panel.composer.doc:text_input("Summary\n\nDescription")
local draft = panel.composer:message()
tree.scroll.y, tree.scroll.to.y = 123, 123
panel:show("git")
panel:update()
panel:draw()
check(clips == 0, "native Git draw has balanced clip stack")
check(panel.list.size.y > 0 and panel.tabs.h == 0 and tree.size.y == panel.size.y,
  "native toolbar replaces duplicate Files/Git strip without stealing tree space")
check(#native_items > 0 and native_items[1].item.type == "file" and native_items[2].item.type == "file" and native_items[2].item.depth == 1,
  "Git file resources retain native tree draw_item icons and indentation; SCM groups are not folders")
local same_height = true
for _, item in ipairs(native_items) do if item.h ~= tree:get_item_height() then same_height = false end end
check(same_height and panel.small_font == style.font, "Git row density and font exactly match Files")
local changes_header, new_row, tracked_row, untracked_header
for _, row in ipairs(panel.list.rows) do
  if row.key == "changes" then changes_header = row end
  if row.key == "untracked" then untracked_header = row end
  if row.group == "changes" and row.entry then
    if row.entry.status == "??" then new_row = row else tracked_row = row end
  end
end
check(changes_header and #changes_header.entries == 2 and new_row and tracked_row and not untracked_header,
  "one Changes section combines tracked and untracked files with total count")
check(#panel.model.status.changes == 1 and #panel.model.status.untracked == 1,
  "combined list leaves backend status classifications unchanged")
local rendered_u = false
for _, value in ipairs(draws) do if value == "U" then rendered_u = true end end
check(rendered_u, "untracked file displays U in combined Changes list")
local original_open_diff, routed_group = panel.open_diff
panel.open_diff = function(_, entry, group) routed_group = group end
panel.list:activate(new_row, false)
check(routed_group == "untracked", "combined untracked row still requests new-file diff")
panel.list:activate(tracked_row, false)
check(routed_group == "changes", "combined tracked row still requests index-to-disk diff")
panel.open_diff = original_open_diff
local original_stage, staged_group, staged_entries = panel.model.stage
panel.model.stage = function(_, group, entries) staged_group, staged_entries = group, entries end
panel.list:activate(changes_header, true)
check(staged_group == "changes" and #staged_entries == 2 and require("plugins.gitpanel.git").paths(staged_entries, staged_group) == "file name.lua\0src/partial.lua\0",
  "Changes header stages both new and tracked files in one literal path stream")
panel.list:activate(new_row, true)
check(staged_group == "changes" and #staged_entries == 1 and staged_entries[1] == new_row.entry,
  "new file supports individual staging inside Changes")
panel.model.stage = original_stage
panel.list:activate(changes_header, false)
local hidden = true
for _, row in ipairs(panel.list.rows) do if row.group == "changes" and row.entry then hidden = false end end
check(hidden, "collapsing Changes hides both tracked and untracked rows")
panel.list:activate(changes_header, false)
panel.list.selected = nil
tree.toolbar.size.x = 300
tree.toolbar:update()
tree.toolbar:draw()
local tx, ty
for entry, x, y, w, h in tree.toolbar:each_item() do if entry == panel.toolbar_item then tx, ty = x + w / 2, y + h / 2 end end
check(tx ~= nil, "native toolbar exposes clickable Git icon geometry")
core.last_active_view = panel
check(tree.toolbar:on_mouse_pressed("left", tx, ty, 1) and panel.mode == "files", "Git toolbar icon switches to Files without prior mouse movement")
core.last_active_view = tree
tree.toolbar:on_mouse_pressed("left", tx, ty, 1)
check(panel.mode == "git", "same Git toolbar icon switches back to Git")
tree.toolbar.visible = false
panel:layout()
check(panel.tabs.h == tree:get_item_height(), "hidden toolbar retains compact Files/Git fallback")
tree.toolbar.visible = true
panel:layout()
panel:show("files")
panel:update()
panel:draw()
panel:show("git")
panel:update()
check(tree.scroll.y == 123 and tree.cache.retained.expanded and panel.composer:message() == draft, "tree state and multiline draft survive Files/Git toggle")
panel:set_target_size("x", 410)
panel:update()
check(panel.size.x == 410, "native divider target width honored")
panel.list:move(1)
check(panel.list:selected_row().group == "staged", "keyboard navigation selects staged header")
panel.list:activate(panel.list:selected_row(), false)
check(panel.list.collapsed.staged, "keyboard section collapse")
local docs = require "plugins.gitpanel.documents"
local doc = docs.ReadDoc("Staged snapshot", "--- a/file\n+++ b/file\n+index\n")
local before = doc:get_text(1, 1, math.huge, math.huge)
doc:text_input("no mutation")
doc:remove(1, 1, 2, 1)
doc:undo()
doc:save("/must-not-write")
check(doc:get_text(1, 1, math.huge, math.huge) == before and not doc:is_dirty(), "native diff Doc blocks insert/remove/undo/save")
core.set_active_view(panel.composer)
local snapshot = docs.open("Snapshot [read-only]", "diff --git a/a b/a\n+text\n")
check(core.root_view.root_node:get_node_for_view(snapshot) ~= tree_node and tree_node.active_view == panel, "diff opens in editor, not sidebar, from embedded composer focus")
local editor_node = core.root_view:get_primary_node()
local editor_view, editor_count = editor_node.active_view, #editor_node.views
for _, embedded in ipairs({tree, panel.composer}) do
  core.set_active_view(embedded)
  check(core.root_view:get_active_node() == tree_node, "embedded focus resolves to locked sidebar")
  for _, name in ipairs({"root:switch-to-next-tab", "root:switch-to-previous-tab", "root:close", "root:close-or-quit"}) do
    check(not command.perform(name) and editor_node.active_view == editor_view and #editor_node.views == editor_count,
      name .. " cannot mutate editor tabs from embedded focus")
  end
end
core.set_active_view(editor_view)
check(command.perform("root:switch-to-next-tab"), "native editor tab navigation still works")
local old_composer = panel.composer
core.set_active_view(old_composer)
core.project_dir = "/other"
panel:update()
check(panel.composer ~= old_composer and panel.composer:message() == "" and core.active_view == panel.composer, "draft and composer focus are project-bound")
core.project_dir = "/fixture"
panel:update()
check(panel.composer == old_composer and panel.composer:message() == draft, "returning project restores in-memory draft")
for _, size in ipairs({240, 320, 500}) do
  panel:set_target_size("x", size)
  for _, height in ipairs({400, 800}) do panel.size.y = height; panel:update(); panel:draw() end
end
check(clips == 0, "native draws at narrow/wide and short/tall sizes")
local original_commit = panel.model.commit
panel.model.commit = function(_, message, success)
  panel.composer.doc:text_input(" newer edit")
  success()
end
panel:commit()
check(panel.composer:message():find("newer edit", 1, true), "successful commit cannot erase a draft edited while hooks run")
panel.model.commit = function(_, message, success) success() end
panel:commit()
check(panel.composer:message() == "", "successful commit clears only unchanged draft")
panel.model.commit = original_commit
-- Real root command dispatch with either visual diff side selected. Children
-- never enter core.active_view, so move/close always operate on the owner tab.
local diff = require "plugins.gitpanel.diff"
local data = diff.build("one\nold\nend", "one\nnew\nextra\nend", "@@ -2 +2,2 @@\n-old\n+new\n+extra\n")
data.path, data.group = "src/example.lua", "changes"
local dv = docs.open_comparison(data)
local DiffView = require "plugins.gitpanel.diffview"
check(syntax_paths[#syntax_paths] == "/fixture/src/example.lua" and syntax_paths[#syntax_paths - 1] == "/fixture/src/example.lua", "both native snapshot highlighters select source-file syntax, not diff syntax")
package.loaded["core.tokenizer"] = {} -- syntax engine is substituted in this harness
require "core.commands.doc"
check(not command.perform("doc:save") and not command.perform("doc:undo") and not command.perform("doc:paste"), "native mutation command predicates reject owner instead of exposing an embedded DocView")
check(dv:is(DiffView) and not dv:is(require "core.docview") and editor_node:get_view_idx(dv), "comparison is exactly one native owner tab, not DocView impersonation")
local clipboard
system.set_clipboard = function(text) clipboard = text end
for side = 1, 2 do
  dv.side = side
  core.set_active_view(dv)
  dv.position.x, dv.position.y, dv.size.x, dv.size.y = 0, 0, 800, 500
  dv:update(); dv:draw()
  local pane = dv.panes[side]
  local sx = pane.position.x + pane:get_gutter_width() + 3
  local sy = pane.position.y + style.padding.y + dv:line_height() * 1.5
  dv:on_mouse_pressed("left", sx, sy, 1)
  dv:on_mouse_moved(sx + 10, sy, 10, 0)
  dv:on_mouse_released("left", sx + 10, sy)
  check(core.active_view == dv and dv.side == side and core.root_view:get_active_node() == editor_node,
    "mouse selection on side " .. side .. " keeps owner focus and unlocked node identity")
  local source = pane.doc:get_text(1, 1, math.huge, math.huge)
  pane.doc:text_input("bad"); pane.doc:remove(1, 1, 2, 1); pane.doc:undo(); pane.doc:redo(); pane.doc:reset()
  pane.doc:save("/must-not-write"); pane.doc:load("/must-not-read"); pane.doc:reload()
  dv:on_text_input("bad"); dv:on_ime_text_editing("bad", 0, 3)
  check(source == pane.doc:get_text(1, 1, math.huge, math.huge) and not pane.doc.filename and not pane.doc.abs_filename and not pane.doc:is_dirty(),
    "side " .. side .. " source snapshot blocks edit/save/load/reset/undo without real filenames")
  command.perform("git-panel:diff-select-all"); command.perform("git-panel:diff-copy")
  check(clipboard == (side == 1 and data.original or data.modified), "side " .. side .. " select-all copy preserves exact source, excluding gaps/EOF sentinel")
  check(command.perform("git-panel:diff-move-right") and command.perform("git-panel:diff-select-down"), "side " .. side .. " scoped movement and selection dispatch")
  local count = #editor_node.views
  command.perform("root:move-tab-left"); command.perform("root:move-tab-right")
  check(#editor_node.views == count and editor_node:get_view_idx(dv) and not editor_node:get_view_idx(pane), "side " .. side .. " tab moves reorder owner only")
  command.perform("root:switch-to-previous-tab")
  check(core.active_view ~= dv and #editor_node.views == count, "side " .. side .. " previous-tab dispatch never closes unrelated editor")
  core.set_active_view(dv)
  command.perform("root:switch-to-next-tab")
  check(core.active_view ~= dv and #editor_node.views == count, "side " .. side .. " next-tab dispatch resolves actual owner index")
  editor_node:set_active_view(dv)
end
for _, width in ipairs({0, 40, 180, 800}) do
  for _, height in ipairs({0, 20, 80, 400}) do dv.size.x, dv.size.y = width, height; dv:update(); dv:draw() end
end
check(clips == 0, "two-column drawing clips safely at zero/narrow widths and short heights")
dv.size.x, dv.size.y = 800, 100
command.perform("git-panel:next-change")
check(dv.change_index == 1 and dv.scroll.to.y == dv:line_height() + style.padding.y, "next-change action targets Git hunk row")
command.perform("git-panel:previous-change")
check(dv.change_index == 1, "previous-change wraps safely")
command.perform("root:scroll", -2)
dv:update(); dv:layout()
check(dv.panes[1].scroll.y == dv.panes[2].scroll.y and dv.panes[1].scroll.y == dv.scroll.y, "real root scroll dispatch shares vertical alignment across sides")
command.perform("git-panel:diff-other-side")
check(core.active_view == dv and dv.side == 1, "Tab-side action never focuses render child")
for side = 1, 2 do
  dv.side = side
  local count, unrelated = #editor_node.views, snapshot
  editor_node:set_active_view(dv)
  command.perform(side == 1 and "root:close" or "root:close-or-quit")
  check(#editor_node.views == count - 1 and not editor_node:get_view_idx(dv) and editor_node:get_view_idx(unrelated), "side " .. side .. " native close removes only diff owner")
  if side == 1 then dv = docs.open_comparison(data) end
end
local empty = diff.build("", "", "")
empty.path, empty.group = "empty.txt", "untracked"
local empty_view = docs.open_comparison(empty)
empty_view.size.x, empty_view.size.y = 400, 200
empty_view:update(); empty_view:draw()
check(#empty_view.data.rows == 0 and command.perform("git-panel:next-change"), "empty-file comparison draws honest empty state and navigation is safe")
local fallback = docs.open_comparison({path="binary", unsupported="Binary: textual comparison unsupported", patch="Binary files differ\n"})
check(fallback.doc:get_text(1, 1, math.huge, math.huge):find("Textual comparison unavailable", 1, true), "unsupported comparison opens explicit read-only fallback")
local split_view = docs.open_comparison(data)
check(command.perform("root:split-right"), "native split command accepts comparison owner without cloning render children")
local split_owner = core.root_view.root_node:get_node_for_view(split_view)
check(split_owner and split_owner:get_view_idx(split_view) and not split_owner:get_view_idx(split_view.panes[1]) and not split_owner:get_view_idx(split_view.panes[2]), "split preserves one owner tab and no embedded editor corruption")
local crlf_data = diff.build("", "a\r\nβ\r\n", "@@ -0,0 +1,2 @@\n+a\r\n+β\r\n")
crlf_data.path, crlf_data.group = "crlf.txt", "untracked"
local crlf_view = docs.open_comparison(crlf_data)
crlf_view.panes[2].doc:set_selection(1, 1, 2, 3)
command.perform("git-panel:diff-copy")
check(clipboard == "a\r\nβ", "cross-line partial copy retains original CRLF bytes and UTF-8 columns")
command.perform("git-panel:diff-select-all"); command.perform("git-panel:diff-copy")
check(clipboard == "a\r\nβ\r\n", "copy-all retains final CRLF without editor sentinel")
for _, glyph in ipairs({"β", "😀"}) do
  local source = "ab\n" .. glyph .. "\nab\n"
  local unicode_data = diff.build(source, source, "")
  unicode_data.path, unicode_data.group = "unicode.txt", "changes"
  local unicode_view = docs.open_comparison(unicode_data)
  unicode_view.size.x, unicode_view.size.y = 800, 400
  unicode_view:layout()
  for side = 1, 2 do
    unicode_view.side = side
    local doc = unicode_view.panes[side].doc
    for _, direction in ipairs({"down", "up"}) do
      doc:set_selection(direction == "down" and 1 or 3, 2)
      command.perform("git-panel:diff-move-" .. direction)
      local line, col = doc:get_selection()
      check(line == 2 and (col == 1 or col == #glyph + 1),
        "side " .. side .. " " .. direction .. " resolves a " .. #glyph .. "-byte UTF-8 character boundary")
      command.perform("git-panel:diff-select-" .. (col == 1 and "end" or "home"))
      command.perform("git-panel:diff-copy")
      check(clipboard == glyph, "vertical keyboard selection copies complete " .. #glyph .. "-byte character on side " .. side)
    end
  end
end
local long_source = string.rep("line\n", 24)
local scroll_data = diff.build(long_source, long_source, "")
scroll_data.path, scroll_data.group = "scroll.txt", "changes"
local scroll_view = docs.open_comparison(scroll_data)
scroll_view.size.x = 800
scroll_view.size.y = scroll_view:header_height() + scroll_view:line_height() * 10
scroll_view:layout()
scroll_view.panes[2].doc:set_selection(9, 1)
scroll_view.scroll.y, scroll_view.scroll.to.y = 0, 0
command.perform("git-panel:diff-move-down")
scroll_view:update()
local row_bottom = style.padding.y + 10 * scroll_view:line_height() - scroll_view.scroll.y
check(scroll_view.scroll.to.y >= style.padding.y and row_bottom <= scroll_view.size.y - scroll_view:header_height(),
  "keyboard scrolling reveals the complete destination row including top content padding")
local oversized = docs.open_comparison({path="large.txt", unsupported="Source exceeds limit", patch=string.rep("+row\n", 50001)})
check(#oversized.doc.lines < 10 and oversized.doc:get_text(1, 1, math.huge, math.huge):find("Raw Git patch not rendered", 1, true), "oversized raw fallback is explicitly omitted, not sent to native editor as a huge partial document")
-- Real installed NagView and dialog commands; no GUI or filesystem mutations.
local NagView = require "core.nagview"
require "core.commands.dialog"
core.nag_view = NagView()
core.nag_view.size.x = 1000
local Model = require "plugins.gitpanel.model"
local undo_model = Model.new()
undo_model.context, undo_model.root, undo_model.status = {project=core.project_dir, generation=1}, core.project_dir, {}
local undo_data = diff.build("a\nb\nc\nd\ne\n", "a\nB\nc\nd\nE\n", "@@ -2 +2 @@\n-b\n+B\n@@ -5 +5 @@\n-e\n+E\n")
undo_data.path, undo_data.root, undo_data.group = "literal\nundo.txt", core.project_dir, "changes"
undo_data.context, undo_data.discard_snapshot = undo_model.context, {token="test"}
undo_data.revert = function(index) undo_model:discard(undo_data, index) end
local undo_view = docs.open_comparison(undo_data)
undo_view.size.x, undo_view.size.y = 800, 400
undo_view:layout()
local undo_count, undo_label = 0
undo_model.mutate = function(_, label) undo_count, undo_label = undo_count + 1, label end
core.docs = {}
local undo_box = undo_view:action_boxes(1).revert
local center = undo_box.x + undo_box.w / 2
local function arrow_y(i) local box = undo_view:action_boxes(i).revert; return box and box.y + box.h / 2 or 0 end
undo_view:draw()
check(undo_view:arrow_at(center, arrow_y(1)) == 1 and undo_view:arrow_at(center, arrow_y(2)) == 2, "separate clickable undo buttons are associated with each visible block")
local undo_nags, nag_show = 0, core.nag_view.show
core.nag_view.show = function(...) undo_nags = undo_nags + 1; return nag_show(...) end
undo_view:on_mouse_pressed("left", center, arrow_y(2), 1)
check(undo_count == 1 and undo_label == "Revert change block 2" and undo_nags == 0, "block undo button directly dispatches exact block without NagView")
check(not core.nag_view.visible and core.active_view == undo_view, "direct block preserves owner focus without a modal")
command.perform("git-panel:revert-selected-change")
check(undo_count == 2 and undo_label == "Revert change block 2" and undo_nags == 0, "palette selected-change uses same direct block path")
command.perform("git-panel:previous-change")
command.perform("git-panel:revert-selected-change")
check(undo_count == 3 and undo_label == "Revert change block 1", "keyboard-selected block dispatches its exact index")
undo_model:discard(undo_data)
check(undo_count == 4 and undo_label == "Discard unstaged changes" and undo_nags == 0, "whole-file path directly schedules with distinct operation label")
core.nag_view:show("Unrelated", "Leave this dialog alone", {{text="Cancel", default_yes=true, default_no=true}}, function() end)
undo_model:discard(undo_data, 1)
check(undo_count == 5 and undo_nags == 1 and core.nag_view.visible and core.nag_view.title == "Unrelated", "direct discard neither replaces nor closes unrelated visible NagView")
command.perform("dialog:select")
undo_model.root = "/different-root"
undo_model:discard(undo_data, 1)
check(undo_count == 5 and undo_model.error:find("Project/root changed"), "direct action cannot redirect old-root snapshot")
core.nag_view.show = nag_show
undo_data.invalidated = true
check(not command.perform("git-panel:revert-selected-change") and not undo_view:arrow_at(center, arrow_y(1)), "invalidated comparison disables both palette and per-block arrows")
undo_data.invalidated, undo_data.revert, undo_data.group = nil, nil, "staged"
check(not command.perform("git-panel:revert-selected-change") and not undo_view:arrow_at(center, arrow_y(1)), "HEAD-to-index view exposes no destructive block controls")
local undo_node = core.root_view:get_active_node()
local undo_tabs = #undo_node.views
command.perform("root:close")
check(#undo_node.views == undo_tabs - 1 and not core.root_view.root_node:get_node_for_view(undo_view), "root close after direct revert closes only the owner, not helper tabs")
-- Row action keeps native Files renderer/+ intact and uses a separate hit box.
panel.mode = "git"; core.set_active_view(panel)
panel.size.x, panel.size.y = 320, 800
panel.list.scroll.y, panel.list.scroll.to.y = 0, 0
panel.model.error, panel.model.refresh_error = nil, nil
panel.model.status = require("plugins.gitpanel.git").status("## main\0MM file.txt\0?? new.txt\0")
panel.list.collapsed, panel.list.dirty = {}, true
panel.list:rebuild(); panel:layout()
local tracked, untracked
for _, row in ipairs(panel.list.rows) do if row.entry and row.group == "changes" then if row.entry.status == "??" then untracked = row else tracked = row end end end
local discard_requests, requested_group = 0
panel.model.discard_file = function(_, entry, group) discard_requests, requested_group = discard_requests + 1, group end
panel.list.selected, panel.list.hovered = nil, nil
check(not next(panel.list:action_boxes(tracked)), "unhovered unselected rows have no visible or hidden action targets")
panel.list.selected = tracked.key
local row_boxes = panel.list:action_boxes(tracked)
local rx, ry = row_boxes.discard.x + row_boxes.discard.w / 2, row_boxes.discard.y + row_boxes.discard.h / 2
check(row_boxes.discard.x + row_boxes.discard.w < row_boxes.stage.x, "selected row separates discard and index buttons with a non-action gap")
local action_draw, drawn_boxes = ui.draw_action, {}
ui.draw_action = function(symbol, box, hovered, enabled)
  if box and box.y == row_boxes.stage.y then drawn_boxes[symbol] = box end
  action_draw(symbol, box, hovered, enabled)
end
panel.list:draw()
ui.draw_action = action_draw
check(drawn_boxes.undo.x == row_boxes.discard.x and drawn_boxes.stage.x == row_boxes.stage.x
  and panel.list:action_at(tracked, drawn_boxes.undo.x, drawn_boxes.undo.y) == "discard",
  "row draw and click geometry use the same shared rectangles")
check(not panel.list:action_at(tracked, row_boxes.discard.x - 1, ry)
  and not panel.list:action_at(tracked, row_boxes.discard.x + row_boxes.discard.w, ry),
  "status letter and gap are not stage/discard buttons")
panel.list:on_mouse_pressed("left", rx, ry, 1)
check(discard_requests == 1 and requested_group == "changes" and not panel.list:action_boxes(untracked).discard, "tracked row has separate discard hit target; unselected/unhovered U row has no action")
local tooltip
local old_tooltip = core.status_view.show_tooltip
core.status_view.show_tooltip = function(_, message) tooltip = message end
panel.list:on_mouse_moved(rx, ry, 0, 0)
check(tooltip and tooltip:find("Discard unstaged changes", 1, true), "row undo tooltip states unstaged-only consequence")
local sx = row_boxes.stage.x + row_boxes.stage.w / 2
panel.list:on_mouse_moved(sx, ry, 0, 0)
check(tooltip:find("Stage file", 1, true) and tooltip:find("index only", 1, true), "stage tooltip explicitly distinguishes index-only action")
panel.list:on_mouse_left()
check(not panel.list.hovered and not panel.list.hover_action and not panel.list.tooltip and panel.list:action_boxes(tracked).stage,
  "mouse leave clears hover/tooltip but preserves keyboard-selected actions")
panel.list.selected = nil
panel.list:on_mouse_moved(rx, ry, 0, 0)
check(panel.list:action_boxes(tracked).discard and panel.list.hover_action == "discard", "hover reveals contextual row actions")
panel.model.busy = "test"
panel.list:on_mouse_pressed("left", rx, ry, 1)
check(discard_requests == 1 and not panel.list:action_enabled(tracked, "discard"), "disabled row discard is visible but inert")
panel.model.busy = nil
panel.list.selected = tracked.key
local old_width, old_height, old_scroll = panel.list.size.x, panel.list.size.y, panel.list.scroll.y
panel.list.size.x = 40
check(not next(panel.list:action_boxes(tracked)) and not panel.list:action_at(tracked, rx, ry), "narrow row hides actions and destructive hit regions together")
panel.list:draw()
panel.list.size.x = old_width
panel.list.scroll.y = tracked.y + 1
check(not next(panel.list:action_boxes(tracked)), "partially clipped row hides entire action and hitbox")
panel.list.scroll.y = old_scroll
panel.list.size.y = tracked.y
check(not next(panel.list:action_boxes(tracked)), "row below viewport has no action hitbox")
panel.list.size.y = old_height
local old_stage = panel.model.stage
local stage_clicks = 0
panel.model.stage = function() stage_clicks = stage_clicks + 1 end
panel.list:on_mouse_pressed("left", sx, ry, 1)
check(stage_clicks == 1 and discard_requests == 1 and not core.nag_view.visible, "row stage click is prompt-free and never routes to discard")
local staged_row
for _, row in ipairs(panel.list.rows) do if row.entry and row.group == "staged" then staged_row = row end end
panel.list.selected, panel.list.hovered = staged_row.key, nil
local unstage_box = panel.list:action_boxes(staged_row).stage
panel.list:on_mouse_moved(unstage_box.x + 1, unstage_box.y + 1, 0, 0)
panel.list:on_mouse_pressed("left", unstage_box.x + 1, unstage_box.y + 1, 1)
check(stage_clicks == 2 and tooltip:find("Unstage file", 1, true) and not core.nag_view.visible,
  "row unstage click has explicit tooltip and no confirmation")
panel.list.selected, panel.list.hovered = nil, nil
local open_diff, opened_rows = panel.open_diff, 0
panel.open_diff = function() opened_rows=opened_rows+1 end
panel.list:on_mouse_pressed("left", rx, ry, 1)
check(opened_rows==1 and discard_requests==1 and stage_clicks==2,
  "click where a hidden discard would be opens the file, never a destructive action")
panel.open_diff = open_diff
panel.list.selected = tracked.key
panel.model.busy="test"
panel.list:on_mouse_pressed("left",sx,ry,1)
check(stage_clicks==2, "disabled row stage does not dispatch mutation")
panel.model.busy=nil
local original_scale, original_padding = SCALE, style.padding
for _, scale in ipairs({1,1.5,2}) do
  SCALE=scale;style.padding={x=14*scale,y=7*scale}
  panel.list.size.x=320*scale
  local b=panel.list:action_boxes(tracked)
  check(b.stage.w==math.floor(22*scale+.5) and b.discard.x+b.discard.w < b.stage.x
    and not panel.list:action_at(tracked,b.stage.x+b.stage.w,b.stage.y),
    "row actions scale together with exclusive separated hitboxes at scale "..scale)
  panel.list:draw()
end
SCALE,style.padding=original_scale,original_padding
panel.list.size.x=old_width
panel.model.stage = old_stage
panel.list.selected = tracked.key
core.status_view.show_tooltip = old_tooltip
command.perform("git-panel:discard-unstaged-changes")
check(discard_requests == 2, "palette whole-file action routes selected tracked Changes row")
-- Compare actual Undo rectangles, not only dispatch labels, across both surfaces.
do
  local scale_before, width_before = SCALE, panel.list.size.x
  local draw_action, rect = ui.draw_action, renderer.draw_rect
  local function glyph(draw, box, hovered, enabled)
    local actual, symbol, strokes = {}, nil, nil
    ui.draw_action = function(s,b,h,e)
      if b and b.x==box.x and b.y==box.y then
        symbol=s; strokes={}
        renderer.draw_rect=function(x,y,w,h,color)
          strokes[#strokes+1]={x-math.floor(b.x+b.w/2),y-math.floor(b.y+b.h/2),w,h,color}
          rect(x,y,w,h,color)
        end
        draw_action(s,b,h,e); renderer.draw_rect=rect
        actual=strokes
      else draw_action(s,b,h,e) end
    end
    draw(); ui.draw_action=draw_action
    assert(symbol=="undo" and #actual==(hovered and 10 or 9),"shared bent Undo primitive")
    local tint=not enabled and style.dim or hovered and style.accent or style.text
    local encoded={}
    for i,v in ipairs(actual) do
      if not hovered or i>1 then
        assert(v[5]==tint,"shared theme state")
        encoded[#encoded+1]=table.concat({v[1],v[2],v[3],v[4]},",")
      end
    end
    return table.concat(encoded,";")
  end
  for _,scale in ipairs({1,1.5,2}) do
    SCALE=scale; panel.list.size.x=320*scale
    for _,state in ipairs({"normal","hover","disabled"}) do
      local hover,enabled=state=="hover",state~="disabled"
      local reference
      panel.model.busy=not enabled and "glyph test" or nil
      for _,row in ipairs({tracked,untracked}) do
        panel.list.selected,panel.list.hovered=row.key,hover and row.key or nil
        panel.list.hover_action=hover and "discard" or nil
        local box=assert(panel.list:action_boxes(row).discard)
        local shape=glyph(function() panel.list:draw() end,box,hover,enabled)
        reference=reference or shape
        check(shape==reference and box.w==ui.action_width()
          and panel.list:action_at(row,box.x+box.w/2,box.y+box.h/2)=="discard"
          and not not panel.list:action_enabled(row,"discard")==enabled,
          row.entry.status .. " row shared Undo strokes/style/hit " .. state .. " scale=" .. scale)
        local data=diff.build("","new\n","@@ -0,0 +1 @@\n+new\n")
        data.path,data.group,data.remove_file="glyph",row.entry.status=="??" and "untracked" or "changes",row.entry.status=="??"
        data.revert=function() end; data.can_revert=function() return enabled end
        local view=DiffView(data); view.size.x,view.size.y=900*scale,600*scale
        view.hover_arrow=hover and 1 or nil
        local rail=assert(view:action_boxes(1).revert)
        check(glyph(function() view:draw() end,rail,hover,enabled)==reference
          and rail.w==box.w and (view:arrow_at(rail.x+rail.w/2,rail.y+rail.h/2)==1)==enabled,
          row.entry.status .. " rail shares row Undo strokes/style/hit " .. state .. " scale=" .. scale)
        view.size.y=view:header_height()+style.padding.y+view:line_height()-1
        check(not view:action_boxes(1).revert,"clipped shared Undo rail has no hitbox " .. row.entry.status .. " " .. state .. " " .. scale)
      end
    end
  end
  SCALE,panel.list.size.x=scale_before,width_before
  panel.model.busy=nil; panel.list.selected,panel.list.hovered,panel.list.hover_action=tracked.key,nil,nil
end
local Doc = require "core.doc"
local clean_doc, dirty_doc, other_doc = Doc(), Doc(), Doc()
local reload_count = 0
for _, doc in ipairs({clean_doc, dirty_doc, other_doc}) do doc.abs_filename = "/reload/file"; doc.load = function() reload_count = reload_count + 1 end end
other_doc.abs_filename = "/reload/other"
dirty_doc:insert(1, 1, "unsaved")
core.docs = {clean_doc, dirty_doc, other_doc}
docs.reload_clean("/reload", "file")
check(reload_count == 1 and dirty_doc:is_dirty(), "success reload touches only matching clean open documents, never dirty or unrelated buffers")
core.docs = {}
-- P01: actual Sidebar -> Model -> document publication, paused at transport.
do
  local saved_model, saved_mode, saved_active = panel.model, panel.mode, core.active_view
  local runner = require "plugins.gitpanel.runner"
  local saved_run, saved_thread, saved_open = runner.run, core.add_thread, docs.open_browse_comparison
  local worker, requests, opened = nil, 0, 0
  core.add_thread = function(fn) assert(not worker); worker = coroutine.create(fn) end
  runner.run = function()
    requests = requests + 1
    coroutine.yield()
    return 0, "", ""
  end
  docs.open_browse_comparison = function(result, context) opened = opened + 1; return saved_open(result, context) end
  local function tick()
    local ok, err = coroutine.resume(worker); assert(ok, err)
    if coroutine.status(worker) == "dead" then worker = nil end
  end
  local function flush() for _ = 1, 30 do if not worker then return end; tick() end; error("browse worker stuck") end
  local function reset()
    assert(not worker)
    panel.model = Model.new()
    panel.model.context = {project=core.project_dir, generation=1}
    panel.model.root, panel.model.status = core.project_dir, {}
    panel.mode = "git"
    core.set_active_view(panel)
    requests, opened = 0, 0
  end
  local e = {path="browse.txt", x="A", y=" "}
  reset()
  panel:open_diff(e,"staged"); panel:open_diff(e,"staged"); panel:open_diff(e,"staged")
  flush()
  check(requests == 3 and opened == 1 and core.active_view ~= panel,
    "sidebar latest browse publishes and focuses exactly one actual comparison owner")
  reset()
  panel:open_diff(e,"staged"); tick(); panel:show("files"); flush()
  check(requests == 1 and opened == 0 and core.active_view == tree and not panel.model.worker,
    "explicit Files switch cancels in-flight sidebar browse without stealing focus")
  reset()
  panel:open_diff(e,"staged"); panel:show("files"); flush()
  check(requests == 0 and opened == 0 and not panel.model.worker,
    "explicit Files switch removes pending sidebar browse")
  reset()
  panel:open_diff(e,"staged"); tick(); core.set_active_view(unrelated); flush()
  check(requests == 3 and opened == 0 and core.active_view == unrelated,
    "another active view suppresses only final sidebar publication without model focus coupling")
  reset()
  panel:open_diff(e,"conflicts"); tick(); core.set_active_view(unrelated); flush()
  check(requests == 1 and opened == 0 and core.active_view == unrelated,
    "unsupported sidebar fallback also respects changed focus intent")
  reset()
  panel:open_diff(e,"conflicts"); panel:open_diff(e,"conflicts"); flush()
  check(requests == 1 and opened == 1 and core.active_view.doc,
    "latest unsupported browse opens exactly one actual read-only fallback")
  -- P02: actual owner/Node membership, helpers paused after early publication.
  local staging = require "plugins.gitpanel.staging"
  local saved_enabled = staging.ENABLED
  staging.ENABLED = true
  local function pack(a,b,c) return #a .. "\n" .. a .. #b .. "\n" .. b .. #c .. "\n" .. c end
  runner.run = function(argv)
    requests = requests + 1
    coroutine.yield()
    if argv[1] == "python3" then return 0, pack("old\n", "", "token"), "" end
    for _,v in ipairs(argv) do
      if v == "diff" then return 0, "@@ -1 +0,0 @@\n-old\n", "" end
      if v == "ls-files" then return 0, "100644 abc 0\tbrowse.txt\0", "" end
      if v == "show" then return 0, "old\n", "" end
    end
    return 0, "", ""
  end
  e = {path="browse.txt", x="M", y="D"}
  reset(); panel:open_diff(e,"changes")
  for _=1,4 do tick() end
  local owner = core.active_view
  local data = owner.data
  check(opened == 1 and requests == 4 and data.capabilities_pending and owner:is(DiffView),
    "P02 native owner is published before Python readiness")
  owner.size.x, owner.size.y = 900, 400
  owner:layout(); owner.change_index=1
  local left_width, right_x, rail_width = owner.panes[1].size.x, owner.panes[2].position.x, owner.action_rail.w
  local boxes=owner:action_boxes(1)
  local px,py=boxes.stage.x+boxes.stage.w/2,boxes.stage.y+boxes.stage.h/2
  local rx=boxes.revert.x+boxes.revert.w/2
  owner.panes[1].doc:set_selection(1,2,1,1)
  local selection={owner.panes[1].doc:get_selection()}
  local saved_error, notifications = core.error, 0
  core.error = function() notifications=notifications+1 end
  check(not owner:can_stage() and not owner:can_revert() and not owner:stage_at(px,py) and not owner:arrow_at(rx,py)
    and not command.perform("git-panel:stage-selected-block") and not command.perform("git-panel:revert-selected-change"),
    "P02 pending native mouse and keyboard actions are inert")
  owner:on_mouse_pressed("left",px,py,1); owner:on_mouse_pressed("left",rx,py,1)
  owner:stage_block(1); owner:revert_block(1); owner:draw()
  check(notifications == 0 and not core.nag_view.visible and owner.panes[1].doc:get_selection() == selection[1],
    "P02 pending controls neither select rail text nor show notification or confirmation")
  core.set_active_view(unrelated); core.redraw=false; flush(); owner:layout()
  check(opened == 1 and core.active_view == unrelated and owner.data == data and data.stage and data.revert and core.redraw,
    "P02 readiness updates same live owner and redraws without tab or focus change")
  check(owner.panes[1].size.x == left_width and owner.panes[2].position.x == right_x and owner.action_rail.w == rail_width
    and table.concat({owner.panes[1].doc:get_selection()},",") == table.concat(selection,","),
    "P02 source pane rail and selection geometry remains stable after readiness")
  check(not data.capabilities_pending and owner:can_stage() and owner:can_revert(),
    "P02 native controls enable only after matching captures")
  for _,event in ipairs({"close","replace","Files","newer","invalidate"}) do
    for boundary=4,5 do
      reset(); panel:open_diff(e,"changes"); for _=1,boundary do tick() end
      owner=core.active_view; data=owner.data
      if event == "close" then
        local node=core.root_view.root_node:get_node_for_view(owner)
        node:close_view(core.root_view.root_node,owner)
      elseif event == "replace" then owner.data={}
      elseif event == "Files" then panel:show("files")
      elseif event == "newer" then panel:open_diff(e,"changes")
      else data.invalidated=true end
      local focus=core.active_view
      flush()
      check(not data.stage and not data.revert and not data.capabilities_pending
        and not (panel.model.staging_views or {})[data] and not (panel.model.discard_views or {})[data],
        "P02 native " .. event .. " at helper boundary " .. boundary .. " rejects late attachment")
      check(event == "newer" and opened == 2 or event ~= "newer" and opened == 1 and core.active_view == focus,
        "P02 native " .. event .. " at helper boundary " .. boundary .. " adds no readiness tab or refocus")
      -- Restore foreign replacement after checking the P02 same-data seam.
      if event == "replace" then owner.data=data end
    end
  end
  core.error = saved_error
  staging.ENABLED = saved_enabled
  panel.model, panel.mode = saved_model, saved_mode
  runner.run, core.add_thread, docs.open_browse_comparison = saved_run, saved_thread, saved_open
  core.set_active_view(saved_active)
end
print(checks .. " native-core smoke checks passed (mock renderer/process; no GUI).")
