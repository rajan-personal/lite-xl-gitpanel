-- Actual installed owner/Doc/commands; renderer/process are native_smoke substitutes.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core = require "core"
local command = require "core.command"
local diff = require "plugins.gitpanel.diff"
local DiffView = require "plugins.gitpanel.diffview"
local checks = 0
local function check(ok,label) assert(ok,label);checks=checks+1;print("PASS "..label) end
local data=diff.build("a\nb\n", "A\nb\n", "@@ -1 +1 @@\n-a\n+A\n")
data.path,data.root,data.group="fixture.txt","/fixture","changes"
local staged,reverted=0,0
data.stage=function(index) assert(index==1);staged=staged+1 end
data.revert=function(index) assert(index==1);reverted=reverted+1 end
local view=DiffView(data)
view.position.x,view.position.y,view.size.x,view.size.y=0,0,800,400
core.set_active_view(view);view:layout();view.change_index=1
check(command.perform("git-panel:stage-selected-block") and staged==1 and reverted==0,"native stage block command is distinct from destructive revert")
local y=view:header_height()+require("core.style").padding.y+view:line_height()/2
local boxes=view:action_boxes(1)
local x=boxes.revert.x+boxes.revert.w/2
local sx=boxes.stage.x+boxes.stage.w/2
check(view:stage_at(sx,y)==1 and not view:arrow_at(sx,y),"stage and revert hit regions do not overlap")
view:on_mouse_pressed("left",sx,y,1)
check(staged==2 and reverted==0 and core.active_view==view,"plus click routes to immutable owner index action")
view:on_mouse_pressed("left",x,y,1)
check(reverted==1 and staged==2,"separated undo button routes only to destructive revert")
data.group="staged"
check(not command.perform("git-panel:stage-selected-block") and command.perform("git-panel:unstage-selected-block") and staged==3,"staged comparison exposes only unstage command")
data.invalidated=true
check(not view:stage_at(sx,y) and not command.perform("git-panel:unstage-selected-block"),"stale comparison disables stage hit and command")
data.invalidated=false;data.can_stage=function() return false end
check(not view:stage_at(sx,y) and not command.perform("git-panel:unstage-selected-block"),"pending/stale-root gate disables native action")
view.size.x=0;view:draw()
check(not view:stage_at(-22*SCALE,y),"zero-width view has no offscreen stage action")
data.can_stage=nil;data.group="changes";view.size.x=800
local ui = require "plugins.gitpanel.ui"
local style = require "core.style"
local original_draw = ui.draw_action
local rendered = {}
ui.draw_action = function(symbol, box, hover, enabled)
  if box then rendered[symbol] = box end
  original_draw(symbol, box, hover, enabled)
end
view:draw()
check(rendered.stage.x == boxes.stage.x and rendered.undo.x == boxes.revert.x
  and view:stage_at(rendered.stage.x, rendered.stage.y) == 1
  and view:arrow_at(rendered.undo.x, rendered.undo.y) == 1,
  "diff drawing and hit testing share the exact action rectangles")
ui.draw_action = original_draw
local nag_count, nag_show = 0, core.nag_view.show
core.nag_view.show = function(...) nag_count=nag_count+1; return nag_show(...) end
view:on_mouse_pressed("left", sx, y, 1)
data.group="staged";view:on_mouse_pressed("left", sx, y, 1);data.group="changes"
check(nag_count==0, "stage and unstage block clicks never open native confirmation")
core.nag_view.show = nag_show
local before_stage, before_revert = staged, reverted
local rail = view.action_rail
local doc = view.panes[view.side].doc
local selection_before = {doc:get_selection()}
view:on_mouse_pressed("left", rail.x + 1, y, 1)
local selection_after = {doc:get_selection()}
check(staged==before_stage and reverted==before_revert and not view.selecting
  and table.concat(selection_before, ",")==table.concat(selection_after, ","),
  "blank action rail cannot mutate or start a source selection")
view.selecting={1,1}
view:on_mouse_moved(rail.x + 1,y,0,0)
check(table.concat({doc:get_selection()}, ",")==table.concat(selection_after, ","),
  "dragging over blank rail does not select fabricated source text")
view:on_mouse_released("left",rail.x+1,y)
data.can_stage=function() return false end;data.can_revert=function() return false end
view:on_mouse_pressed("left",sx,y,1);view:on_mouse_pressed("left",x,y,1)
check(staged==before_stage and reverted==before_revert and not view.selecting,
  "disabled visible rail buttons have no mutation or text-selection fallback")
local tooltip, removed
local show_tip, remove_tip=core.status_view.show_tooltip,core.status_view.remove_tooltip
core.status_view.show_tooltip=function(_, tip) tooltip=tip end
core.status_view.remove_tooltip=function() removed=true end
view:on_mouse_moved(x,y,0,0)
check(tooltip:find("Revert unstaged",1,true) and tooltip:find("Unavailable",1,true) and view.cursor=="arrow",
  "disabled undo button retains clear unavailable tooltip")
data.can_revert=nil
view:on_mouse_moved(x,y,0,0)
check(not tooltip:find("Unavailable",1,true) and view.cursor=="hand",
  "same hovered diff button updates tooltip when disabled state changes")
view:on_mouse_left()
check(removed and not view.hover_arrow and not view.hover_stage, "diff mouse leave removes action hover and tooltip")
core.status_view.show_tooltip,core.status_view.remove_tooltip=show_tip,remove_tip
data.can_stage,data.can_revert=nil,nil
local old_scale, old_padding, old_divider=SCALE,style.padding,style.divider_size
for _, scale in ipairs({1,1.5,2}) do
  SCALE=scale;style.padding={x=14*scale,y=7*scale};style.divider_size=scale
  view.position.x,view.position.y=37,29
  view.size.x,view.size.y=800*scale,400*scale
  view:layout()
  local b=view:action_boxes(1)
  local right=view.panes[2]
  check(b.stage and b.revert and view.panes[1].position.x+view.panes[1].size.x <= b.stage.x
    and b.stage.x+b.stage.w < b.revert.x and b.revert.x+b.revert.w <= right.position.x,
    "reserved action rail does not overlap source panes/gutters at scale "..scale)
  check(not view:stage_at(b.stage.x+b.stage.w,b.stage.y) and not view:arrow_at(b.revert.x-1,b.revert.y),
    "shared action edges and separating gap are exclusive at scale "..scale)
  view.scroll.y=style.padding.y+1
  check(not next(view:action_boxes(1)), "partially clipped hunk buttons have no hidden targets at scale "..scale)
  view.scroll.y=0
  view.size.y=view:header_height()+style.padding.y+view:line_height()-1
  check(not next(view:action_boxes(1)), "bottom-clipped hunk buttons hide safely at scale "..scale)
  for _, width in ipairs({0,40,180}) do
    view.size.x,view.size.y=width*scale,400*scale
    view:draw()
    check(not next(view:action_boxes(1)) and not view:arrow_at(x,y) and not view:stage_at(sx,y)
      and view.panes[1].size.x>=0 and view.panes[2].size.x>=0,
      "narrow/zero width has no invisible destructive target at scale "..scale.." width "..width)
  end
end
SCALE,style.padding,style.divider_size=old_scale,old_padding,old_divider
local range=diff.build("a\nb\nc\n", "A\nextra\nb\nC\n", "@@ -1 +1,2 @@\n-a\n+A\n+extra\n@@ -3 +4 @@\n-c\n+C\n")
range.path,range.group="fixture.txt","changes"
local selection
range.stage=function(index,first,last) selection={index,first,last} end
local selected=DiffView(range);selected.size.x,selected.size.y=800,400;core.set_active_view(selected)
for side=1,2 do
  selected.side=side;selected.panes[side].doc:set_selection(1,1)
  check(command.perform("git-panel:stage-selected-lines") and selection[1]==nil and selection[2]==1 and selection[3]==1,"native source-side caret selects one aligned replacement row "..side)
end
selected.side=1;selected.panes[1].doc:set_selection(3,2,1,1)
check(command.perform("git-panel:stage-selected-lines") and selection[2]==1 and selection[3]==4,"native source range maps cross-hunk interior gaps")
selected.panes[1].doc:set_selection(3,1,1,1)
check(command.perform("git-panel:stage-selected-lines") and selection[3]==3,"native end-column-one selection excludes final source line")
range.group="staged"
check(not command.perform("git-panel:stage-selected-lines") and command.perform("git-panel:unstage-selected-lines"),"native selected-line unstage command distinct by source mode")
local original=table.concat(selected.panes[1].doc.lines)
selected.panes[1].doc:insert(1,1,"NO")
check(core.active_view==selected and table.concat(selected.panes[1].doc.lines)==original,"selected-line dispatch never focuses or edits rendering helper")
range.invalidated=true
check(not command.perform("git-panel:unstage-selected-lines"),"stale selection command disabled")
print(checks.." staging native-core checks passed (native bootstrap not counted twice; no GUI)")
