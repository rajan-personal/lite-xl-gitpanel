-- V01 uses actual installed native toolbar/Sidebar; renderer/font/process mocked.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core, style = require "core", require "core.style"
local panel, tree = require "plugins.gitpanel", require "plugins.treeview"
local ui, git, Model = require "plugins.gitpanel.ui", require "plugins.gitpanel.git", require "plugins.gitpanel.model"
local runner = require "plugins.gitpanel.runner"
local checks = 0
local function check(ok, label) assert(ok, label); checks=checks+1; print("PASS V01 " .. label) end
check(type(ui.scm_count)=="function", "display-only resource count helper exists")
core.project_dir="/v01"
panel.model=Model.new(); panel.model.context={project=core.project_dir}; panel.model.root=core.project_dir
local model=panel.model
local status=git.status("## main\0MM partial\0?? new\0UU conflict\0M  staged\0 M changed\0")
model.status=status
check(ui.scm_count(model)==6 and status.count==5 and #status.staged==2 and #status.changes==2,
  "VSCode default sums merge/index/working/untracked resources; partial counted twice, model unique unchanged")
model.error="operation failed"; model.refresh_error="refresh failed"
check(ui.scm_count(model)==6,"errors retain last valid status badge")
model.refreshing=true
check(ui.scm_count(model)==6,"refresh in flight retains last valid count")
model.root=nil; check(ui.scm_count(model)==0,"missing root hides stale status")
model.root=core.project_dir; model.context=nil; check(ui.scm_count(model)==0,"unbound model hides badge")
model.context={project=core.project_dir}; core.project_dir="/other"
check(ui.scm_count(model)==0,"project switch hides old badge before update")
model:bind(core.project_dir); check(ui.scm_count(model)==0 and not model.status,"bind reset hides badge")
-- Real Model refresh transport, with synchronous scheduling and no subprocesses.
core.add_thread=function(fn) fn() end
model.worker=false; model.queue={}; model.refreshing=false
local calls, output=0,"## main\0MM partial\0?? new\0"
runner.run=function(argv)
  calls=calls+1
  for _,v in ipairs(argv) do if v=="rev-parse" then return 0,core.project_dir .. "\n","" end end
  return 0,output,""
end
model:refresh(true); check(ui.scm_count(model)==3 and model.status.count==2 and calls==2,"status refresh updates display without changing unique count")
local before=calls
for _=1,100 do assert(ui.scm_count(model)==3) end
check(calls==before,"100 count reads add zero Git calls")
output="## main\0"; model:refresh(true)
check(ui.scm_count(model)==0,"clean refresh hides zero badge")
output="## main\0MM partial\0?? new\0"; model:refresh(true)
panel.size.x,panel.size.y=320,800; tree.toolbar.size.x=320; tree.toolbar:update()
local toolbar=tree.toolbar
local initial={}
for item,x,y,w,h in toolbar:each_item() do initial[item]={x,y,w,h} end
local texts, rects={},{}
local old_text,old_rect=renderer.draw_text,renderer.draw_rect
renderer.draw_text=function(f,t,x,y,c) texts[#texts+1]={font=f,text=t,x=x,y=y,color=c}; return old_text(f,t,x,y,c) end
renderer.draw_rect=function(x,y,w,h,c) rects[#rects+1]={x=x,y=y,w=w,h=h,color=c}; return old_rect(x,y,w,h,c) end
local function count_text(value) local n=0; for _,v in ipairs(texts) do if v.text==value then n=n+1 end end; return n end
local function badge_box()
 local b=initial[panel.toolbar_item]
 return ui.count_badge(ui.scm_count(model),ui.rect(b[1]-b[3]/4,b[2],b[3]*1.5,b[4]),ui.rect(toolbar.position.x,toolbar.position.y,toolbar.size.x,toolbar.size.y))
end
for _,mode in ipairs({"files","git"}) do
 panel.mode=mode; texts={}; toolbar:draw()
 check(count_text("3")==1,"one toolbar badge in " .. mode .. " mode")
end
local badge=assert(badge_box())
local found=false
for _,r in ipairs(rects) do if r.color[1]==0 and r.color[2]==120 and r.color[3]==212 then found=true end end
check(found and texts[#texts].color[1]==255 and texts[#texts].color[2]==255 and texts[#texts].color[3]==255,"Modern blue #0078D4 and white #FFFFFF defaults")
local last=initial[panel.toolbar_item]
check(badge.x>=last[1]-last[3]/4 and badge.x+badge.w<=last[1]+last[3]*1.25,"badge bounded to Git cell and half-gaps, not adjacent icons")
for item,x,y,w,h in toolbar:each_item() do local b=initial[item]; assert(x==b[1] and y==b[2] and w==b[3] and h==b[4]) end
check(true,"all native item geometry and layout unchanged")
panel.mode="files"; toolbar.hovered_item=nil
local refresh=model.refresh; model.refresh=function() end
-- Test extension in native gap, not just the original icon hitbox.
toolbar:on_mouse_pressed("left",badge.x+badge.w-.1,badge.y+badge.h/2,1)
check(panel.mode=="git" and toolbar.hovered_item==panel.toolbar_item,"badge gap click without move belongs to Git toggle")
toolbar:on_mouse_pressed("right",badge.x+badge.w-.1,badge.y+badge.h/2,1)
check(panel.mode=="git","badge right click does not toggle")
for item,b in pairs(initial) do if item~=panel.toolbar_item then
 toolbar:on_mouse_moved(b[1]+b[3]/2,b[2]+b[4]/2,0,0)
 assert(toolbar.hovered_item==item)
end end
check(true,"other native icon hit regions preserved")
local old_width=toolbar.size.x; toolbar.size.x=badge.x+badge.w-1
check(not badge_box(),"partially clipped badge is suppressed entirely")
toolbar:on_mouse_moved(badge.x+badge.w-.1,badge.y+badge.h/2,0,0)
check(toolbar.hovered_item~=panel.toolbar_item,"clipped badge extension has no invisible click target")
toolbar.size.x=old_width
for _,absent in ipairs({false,true}) do
 if absent then tree.toolbar=nil else toolbar.visible=false end
 for _,mode in ipairs({"files","git"}) do
  panel.mode=mode; texts={}; rects={}; panel:layout(); panel:draw()
  check(count_text("3")==1 and count_text("Git")==1 and count_text("Git  2")==0,"same single badge with " .. (absent and "absent" or "hidden") .. " toolbar in " .. mode)
  local tabs=panel.tabs
  for _,r in ipairs(rects) do
   if r.color[1]==0 and r.color[2]==120 and r.color[3]==212 then
    assert(r.y+r.h<=tabs.y+tabs.h-4*SCALE,"fallback badge must not overlap active underline")
   end
  end
  check(true,"fallback badge clear of native active underline")
  check(panel:hit(tabs.x+tabs.w-1,tabs.y+tabs.h/2)=="git","fallback badge region belongs to Git tab")
 end
 tree.toolbar=toolbar; toolbar.visible=true
end
model.refresh=refresh
for _,mode in ipairs({"files","git"}) do
 panel.mode=mode; model.status=git.status("## main\0"); texts={}; toolbar:draw()
 check(count_text("0")==0 and not badge_box(),"zero hidden in toolbar " .. mode)
 model.status=git.status("## main\0MM partial\0?? new\0"); core.project_dir="/switched"; texts={}; toolbar:draw()
 check(count_text("3")==0,"project switch suppresses rendered toolbar badge in " .. mode)
 core.project_dir=model.context.project
end
panel.mode="git"; model.error=nil; model.refresh_error=nil; panel:layout()
local collapsed_y=panel.list.position.y
check(panel.banner.h==0 and collapsed_y==panel.commit_box.y+panel.commit_box.h+style.padding.y,"normal summary and its height collapse to normal commit/group gap")
texts={}; panel:draw()
check(count_text("2 changed · 1 staged")==0 and count_text("Refreshing…")==0,"no changed/staged or refresh summary hint")
check(panel:hit(panel.banner.x+1,panel.banner.y+1)~="banner","collapsed banner cannot consume group clicks")
model.error="Git failed\nfull diagnostic"; panel:layout()
check(panel.banner.h>0 and panel.list.position.y>collapsed_y,"actionable error reserves height")
local opened,docs=nil,require "plugins.gitpanel.documents"
local old_open=docs.open; docs.open=function(title,body) opened={title,body} end
panel:on_mouse_pressed("left",panel.banner.x+1,panel.banner.y+1,1)
check(opened and opened[2]==model.error .. "\n" and opened[1]:find("read%-only"),"error click opens full read-only details, not group action")
docs.open=old_open
panel.size.y=panel.banner.y+5; toolbar.visible=false; panel:layout()
check(panel:hit(panel.banner.x+1,panel.tabs.y+panel.tabs.h+1)==nil,"off-viewport banner cannot steal clicks")
panel.size.y=800; toolbar.visible=true; model.error=nil; model.refresh_error="refresh failed"; panel:layout()
check(panel.banner.h>0,"refresh error retains details path")
model.refresh_error=nil; model.status=git.status("## main\0"); panel:layout(); panel.list:rebuild(); texts={}; panel:draw()
check(panel.banner.h==0 and #panel.list.rows==2,"clean repository retains Changes empty rows without summary; V02 hides empty Staged")
model.status=nil; model.root=nil; texts={}; panel:draw()
check(count_text("Select a repository")==1 and not badge_box(),"no repository remains intelligible and badge hidden")
-- Font copy and metric caches track the live theme font and SCALE, not frames.
local saved_font,saved_scale=style.font,SCALE
for _,scale in ipairs({1,1.5,2}) do
 SCALE=scale; style.font=saved_font:copy(15*scale)
 for _,count in ipairs({1,12,123,999,1000,1000000000}) do
  local box=assert(ui.count_badge(count,ui.rect(0,0,40*scale,30*scale),ui.rect(0,0,40*scale,30*scale)))
  check(box.x>=0 and box.y>=0 and box.x+box.w<=40*scale and box.y+box.h<=30*scale
   and box.font:get_width(box.label)<=box.w-4*scale,"font measured bounded badge scale " .. scale .. " count " .. count)
  check(box.label==(count<=999 and tostring(count) or "99+"),"documented exact reasonable counts / overflow " .. scale .. ":" .. count)
 end
 local a=ui.count_badge(12,ui.rect(0,0,40*scale,30*scale))
 local b=ui.count_badge(12,ui.rect(0,0,40*scale,30*scale))
 check(a.font==b.font,"cached font reused at scale " .. scale)
end
SCALE,style.font=saved_scale,saved_font
local copies,widths=0,0
local testfont=saved_font:copy(15)
local copy=testfont.copy
function testfont:copy(h)
 copies=copies+1; local f=copy(self,h); local width=f.get_width
 function f:get_width(s) widths=widths+1; return width(self,s) end
 return f
end
style.font=testfont
for _=1,100 do ui.count_badge(123,ui.rect(0,0,40,30)) end
check(copies==1 and widths==1,"100 repeated layouts reuse copied font and label metrics")
SCALE=2; ui.count_badge(123,ui.rect(0,0,80,60)); check(copies==2,"scale change invalidates metric cache")
style.font=saved_font; SCALE=saved_scale
for _,height in ipairs({12,20,28}) do
 local proportional=saved_font:copy(height)
 local pcopy=proportional.copy
 function proportional:copy(h)
  local f=pcopy(self,h)
  function f:get_width(s)
   local width=0
   for char in s:gmatch(".") do width=width+(char=="1" and 2 or 7)*h/11 end
   return width
  end
  return f
 end
 style.font=proportional
 local a=assert(ui.count_badge(111,ui.rect(0,0,80,50)))
 local b=assert(ui.count_badge(888,ui.rect(0,0,80,50)))
 check(a.w<b.w and a.font~=saved_font and a.h<=50 and b.w<=80,"live proportional font metrics at source height " .. height)
end
style.font=saved_font
check(not ui.count_badge(0,ui.rect(0,0,40,30)) and not ui.count_badge(123,ui.rect(0,0,1,1)),"zero and impossibly narrow badges suppressed")
local narrow=assert(ui.count_badge(999,ui.rect(0,0,16,30)))
check(narrow.label=="9+","narrow width uses documented 9+ overflow rather than overlap")
style.gitpanel_badge_background={1,2,3,255}; style.gitpanel_badge_foreground={4,5,6,255}
texts={}; rects={}; ui.draw_count_badge(assert(ui.count_badge(1,ui.rect(0,0,40,30))))
check(rects[1].color==style.gitpanel_badge_background and texts[1].color==style.gitpanel_badge_foreground,"plugin-local theme override without global theme change")
style.gitpanel_badge_background=nil; style.gitpanel_badge_foreground=nil
renderer.draw_text,renderer.draw_rect=old_text,old_rect
print(checks .. " SCM layout native-core checks passed (native bootstrap not counted twice; no GUI)")
