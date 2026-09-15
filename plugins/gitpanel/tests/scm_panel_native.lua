-- V02 actual Sidebar/DocView/Node/toolbar; tree adapter, fonts/renderer/transport mocked.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core, style = require "core", require "core.style"
local panel, tree = require "plugins.gitpanel", require "plugins.treeview"
local ui, git, Model = require "plugins.gitpanel.ui", require "plugins.gitpanel.git", require "plugins.gitpanel.model"
local checks = 0
local function check(ok, label) assert(ok, label); checks=checks+1; print("PASS V02 " .. label) end
local texts, rects, items = {}, {}, {}
local old_text, old_rect, old_item = renderer.draw_text, renderer.draw_rect, tree.draw_item
renderer.draw_text=function(f,t,x,y,c) texts[#texts+1]={font=f,text=t,x=x,y=y,color=c}; return old_text(f,t,x,y,c) end
renderer.draw_rect=function(x,y,w,h,c) rects[#rects+1]={x=x,y=y,w=w,h=h,color=c}; return old_rect(x,y,w,h,c) end
tree.draw_item=function(self,item,...) items[#items+1]=item; return old_item(self,item,...) end
local function drawn(value) for _,v in ipairs(texts) do if v.text==value then return v end end end
local function draw() texts,rects,items={},{},{}; panel:layout(); panel.list:rebuild(); panel:draw() end
local function click(box,b) return panel:on_mouse_pressed(b or "left",box.x+box.w/2,box.y+box.h/2,1) end
local function hover(box) panel:on_mouse_moved(box.x+box.w/2,box.y+box.h/2,0,0) end
core.project_dir="/v02/repository"
panel.model=Model.new(); local model=panel.model
model.context={project=core.project_dir}; model.root=core.project_dir
model.status=git.status("## main\0MM src/partial.lua\0?? new.lua\0UU conflict.lua\0")
model.refresh=function() end
panel.composer=require("plugins.gitpanel.documents").Composer(); panel.composers[core.project_dir]=panel.composer
panel.mode="git"; panel.size.x,panel.size.y=240,800
panel.list.collapsed={}; panel.list.selected=nil; panel.list.hovered=nil; panel.list.dirty=true
panel.list.scroll.y,panel.list.scroll.to.y=0,0
core.set_active_view(panel)
draw()
check(drawn("SOURCE CONTROL") and drawn("Refresh"),"compact Source Control heading and real Refresh visible")
check(drawn("repository") and drawn("main") and not drawn("Git"),"repository plus branch context without duplicate Git heading")
check(panel.branch_box.y==panel.repository_box.y and panel.branch_box.w<panel.header.w,"branch picker shares compact repository row")
check(panel.composer_box.h==panel.composer:get_line_height()+style.padding.y*2+2,"empty native message starts one editable line with padding")
check(panel.composer_box.y<panel.position.y+100*SCALE,"composer follows two compact context rows at 240px")
check(drawn("Commit") and not drawn("Commit staged"),"primary action uses concise Commit label")
check(drawn("Staged Changes") and drawn("Changes") and drawn("Conflicts"),"SCM section titles are separate from counts")
check(#items==4,"only four file resources use native Files renderer; partial appears in two groups")
for _,item in ipairs(items) do assert(item.type=="file" and item.depth==1) end
check(true,"section headings never masquerade as native folders; file icon/style inputs retained")
check(drawn("-") and drawn("-").font==style.icon_font,"expanded sections use bundled native chevron glyph")
local tip
local old_tip=core.status_view.show_tooltip
core.status_view.show_tooltip=function(_,value) tip=value end
local refresh_calls,picker_calls,commit_calls=0,0,0
model.refresh=function(_,force) assert(force); refresh_calls=refresh_calls+1 end
local old_picker,old_commit=panel.pick_branch,model.commit
panel.pick_branch=function() picker_calls=picker_calls+1 end
model.commit=function(_,message) commit_calls=commit_calls+1; assert(message:find("Summary",1,true)) end
hover(panel.refresh_box); check(tip and tip:find("Refresh",1,true),"Refresh exposes real operation tooltip")
click(panel.refresh_box); check(refresh_calls==1,"Refresh dispatches existing forced refresh only")
model.refreshing=true; click(panel.refresh_box); check(refresh_calls==1,"refreshing control is inert")
model.refreshing=false
hover(panel.branch_box); check(tip:find("main",1,true) and tip:find(core.project_dir,1,true),"branch tooltip retains full repository and branch context")
click(panel.repository_box); check(picker_calls==0,"repository label is not a fake multi-repository picker")
click(panel.branch_box); click(panel.branch_box,"right"); check(picker_calls==1,"compact branch control routes only left click to existing branch picker")
click(panel.commit_box); check(commit_calls==0,"blank disabled Commit is inert, no warning or mutation")
panel.composer.doc:text_input("Summary\n\nBody")
panel.composer.doc:set_selection(3,3,1,2)
local draft=panel.composer:message(); local selection={panel.composer.doc:get_selection()}
model.status=git.status("## main\0MM src/partial.lua\0?? new.lua\0")
draw()
check(panel.composer_box.h==panel.composer:get_line_height()*3+style.padding.y*2+2,"multiline native draft grows to three visible lines")
check(panel:commit_ready(),"nonblank staged-only conflict-free draft enables Commit")
local commit_text=drawn("Commit"); local blue=false
for _,r in ipairs(rects) do if r.x==panel.commit_box.x and r.y==panel.commit_box.y then blue=r.color[1]==0 and r.color[2]==120 and r.color[3]==212 end end
check(blue and commit_text.color[1]==255 and commit_text.color[2]==255 and commit_text.color[3]==255,"enabled Commit is Modern blue and white")
hover(panel.commit_box); check(tip:find("staged",1,true),"Commit tooltip makes staged-only effect explicit without normal warning text")
draw(); local hover_blue=false
for _,r in ipairs(rects) do if r.x==panel.commit_box.x and r.y==panel.commit_box.y then hover_blue=r.color[1]==2 and r.color[2]==110 and r.color[3]==193 end end
check(hover_blue,"primary Commit has Modern blue hover treatment")
click(panel.commit_box); check(commit_calls==1,"enabled Commit dispatches existing message operation once")
for _,state in ipairs({"unstaged","conflicts","busy","blank"}) do
 local saved=model.status
 if state=="unstaged" then model.status=git.status("## main\0 M changed\0")
 elseif state=="conflicts" then model.status=git.status("## main\0M  staged\0UU conflict\0")
 elseif state=="busy" then model.busy="commit"
 else panel.composer.doc:reset() end
 draw(); click(panel.commit_box)
 check(not panel:commit_ready() and commit_calls==1,"disabled Commit remains inert for " .. state)
 if state~="busy" then check(drawn("Commit").color==style.dim,"disabled Commit visually dim for " .. state) end
 model.status=saved; model.busy=nil
end
panel.composer.doc:text_input(draft); panel.composer.doc:set_selection(unpack(selection))
core.set_active_view(panel.composer)
for _=1,10 do draw(); click(panel.refresh_box) end
local now={panel.composer.doc:get_selection()}
check(panel.composer:message()==draft and table.concat(now,",")==table.concat(selection,",") and core.active_view==panel.composer,"draw and refresh never reset draft, selection or editor focus")
local original_composer,project=panel.composer,core.project_dir
local draft_status=model.status
core.project_dir="/v02/other"; panel:update()
check(panel.composer~=original_composer and panel.composer:message()=="" and core.active_view==panel.composer,"project switch retains native composer focus on separate empty draft")
panel.composer.doc:text_input("Other draft"); panel.composer.doc:set_selection(1,4,1,2)
core.project_dir=project; panel:update()
now={panel.composer.doc:get_selection()}
check(panel.composer==original_composer and panel.composer:message()==draft and table.concat(now,",")==table.concat(selection,","),"return to repository restores exact draft and native selection")
model.root=project; model.status=draft_status
panel.composer.doc:insert(3,5,"\n4\n5\n6")
draw(); check(panel.composer_box.h==panel.composer:get_line_height()*3+style.padding.y*2+2 and #panel.composer.doc.lines==6,"long draft remains editable multiline with bounded height")
hover(panel.composer_box); local scroll=panel.composer.scroll.to.y; panel:on_mouse_wheel(-1)
check(panel.composer.scroll.to.y>scroll,"composer retains independent native scrolling")
-- Counts and actions share a measured layout: neutral pills never dispatch stage.
model.status=git.status("## main\0MM src/partial.lua\0?? new.lua\0UU conflict.lua\0")
draw()
local stage_calls=0
model.stage=function() stage_calls=stage_calls+1 end
for _,row in ipairs(panel.list.rows) do if row.entries then
 panel.list.hovered=row.key
 local pill=assert(panel.list:count_box(row)); local action=assert(panel.list:action_boxes(row).stage)
 check(pill.x+pill.w==panel.list.position.x+panel.list.size.x-style.padding.x,"right aligned neutral count for " .. row.group)
 check(action.x+action.w+ui.action_gap()<=pill.x,"contextual action separated from count for " .. row.group)
 check(not panel.list:action_at(row,pill.x+pill.w/2,pill.y+pill.h/2),"count is not stage hit target for " .. row.group)
 draw(); local neutral=false
 for _,r in ipairs(rects) do if r.y==pill.y and r.x>=pill.x and r.x<pill.x+pill.w then neutral=neutral or (r.color[1]==97 and r.color[2]==97 and r.color[3]==97) end end
 check(neutral,"neutral section pill drawn for " .. row.group)
 panel.list:on_mouse_pressed("left",pill.x+pill.w/2,pill.y+pill.h/2,1)
 check(panel.list.collapsed[row.group] and stage_calls==0,"count click only collapses " .. row.group)
 panel.list.collapsed[row.group]=false; panel.list.dirty=true
 panel.list:on_mouse_pressed("left",action.x+action.w/2,action.y+action.h/2,1)
 check(stage_calls==1,"separate contextual group action still dispatches " .. row.group); stage_calls=0
end end
panel.list.dirty=true; draw()
local tracked
for _,r in ipairs(panel.list.rows) do if r.group=="changes" and r.entry and r.entry.status~="??" then tracked=r end end
panel.list.hovered=tracked.key
local boxes=panel.list:action_boxes(tracked)
check(boxes.discard.x+boxes.discard.w+ui.action_gap()==boxes.stage.x and not panel.list:count_box(tracked),"file discard and stage remain separated; no file count pills")
panel.list.collapsed.staged=true; panel.list.collapsed.conflicts=true
model.status=git.status("## main\0"); panel.list.dirty=true; draw()
check(#panel.list.rows==0,"empty Staged/Changes/Conflicts sections are hidden")
model.status=git.status("## main\0M  staged\0UU conflict\0"); draw()
check(panel.list.collapsed.staged and panel.list.collapsed.conflicts and #panel.list.rows==2,"hidden then returning groups retain collapse state")
check(drawn("+") and drawn("+").font==style.icon_font,"collapsed sections retain native chevron spelling")
model.error="operation failed\nfull details"; model.refresh_error=nil; draw()
check(panel.banner.h>0 and drawn("Git needs attention · click for details"),"actionable operation error remains visible")
model.error=nil; model.refresh_error="refresh failed"; draw()
check(panel.banner.h>0,"refresh error still reserves details region")
model.refresh_error=nil; draw(); check(panel.banner.h==0,"normal panel has no redundant summary or warning")
model.root=nil; model.status=nil; draw(); click(panel.branch_box)
check(drawn("Select a repository") and picker_calls==1 and not panel:commit_ready(),"unbound repository is intelligible with inert branch and Commit")
model.root=core.project_dir; model.status=git.status("## " .. string.rep("feature/",20) .. "\0MM partial\0")
local saved_font,saved_scale=style.font,SCALE
for _,scale in ipairs({1,1.5,2}) do
 SCALE=scale; style.font=saved_font:copy(15*scale)
 for _,width in ipairs({80,240,400}) do
  panel.size.x=width*scale; panel.size.y=800*scale; draw()
  for _,box in ipairs({panel.header,panel.repository_box,panel.branch_box,panel.refresh_box,panel.composer_box,panel.commit_box}) do
   assert(box.x>=panel.position.x and box.w>=0 and box.x+box.w<=panel.position.x+panel.size.x)
  end
  check(true,"bounded header/context/composer/commit geometry width " .. width .. " scale " .. scale)
  check(panel.list.size.y>0,"list retains room at width " .. width .. " scale " .. scale)
 end
end
SCALE,style.font=saved_scale,saved_font
panel.size.x,panel.size.y=240,800; draw()
local old_target=tree.target_size
panel:set_target_size("x",240); check(tree.target_size==240,"native resize delegates to existing Files target size")
tree.target_size=old_target
local old_bg,old_fg=style.gitpanel_commit_background,style.gitpanel_commit_foreground
style.gitpanel_commit_background={1,2,3,255}; style.gitpanel_commit_foreground={4,5,6,255}
panel.hover=nil; draw(); local override=false
for _,r in ipairs(rects) do if r.x==panel.commit_box.x and r.y==panel.commit_box.y then override=r.color==style.gitpanel_commit_background end end
check(override and drawn("Commit").color==style.gitpanel_commit_foreground,"primary colors support plugin-local theme override")
style.gitpanel_commit_background,style.gitpanel_commit_foreground=old_bg,old_fg
local group_row=panel.list.rows[1]
style.gitpanel_section_background={7,8,9,255}; style.gitpanel_section_foreground={10,11,12,255}
texts,rects={},{}; ui.draw_section_count(panel.list:count_box(group_row))
check(rects[1].color==style.gitpanel_section_background and texts[1].color==style.gitpanel_section_foreground,"section neutral colors support plugin-local theme override")
style.gitpanel_section_background,style.gitpanel_section_foreground=nil,nil
panel.list.scroll.y=panel.list.rows[1].y+1; panel.list.hovered=panel.list.rows[1].key
check(not panel.list:count_box(panel.list.rows[1]) and not next(panel.list:action_boxes(panel.list.rows[1])),"partially scrolled group has no clipped count or hidden action")
panel.list.scroll.y=0
local native_draw,folder_calls=tree.draw,0
local folder={name="native-folder",type="dir",depth=0,expanded=true}
tree.draw=function(self) folder_calls=folder_calls+1; self:draw_item(folder,false,false,0,0,240,22) end
local tree_cache=tree.cache; tree.scroll.y=123
panel.mode="files"; draw()
check(folder_calls==1 and items[1]==folder and folder.type=="dir" and folder.expanded,"Files mode still draws native folder entries unchanged")
check(not drawn("SOURCE CONTROL") and tree.cache==tree_cache and tree.scroll.y==123 and tree.toolbar.visible,"Files mode retains native tree state and accessible bottom toolbar")
check(core.root_view.root_node:get_node_for_view(panel).locked.x and tree.draw_item~=nil,"native locked resizable docking owner retained")
tree.draw=native_draw
panel.pick_branch=old_picker; model.commit=old_commit; core.status_view.show_tooltip=old_tip
renderer.draw_text,renderer.draw_rect,tree.draw_item=old_text,old_rect,old_item
print(checks .. " SCM panel native-core checks passed (native bootstrap not counted twice; no GUI)")
