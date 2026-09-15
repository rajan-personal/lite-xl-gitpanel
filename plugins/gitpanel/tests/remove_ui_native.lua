-- Actual native Node/Doc/command/hit dispatch; renderer/process bridge, no GUI.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local repo, case_alias, unicode_alias = arg[1], arg[2]=="yes", arg[3]=="yes"; arg[1],arg[2],arg[3] = nil,nil,nil
local saved_print = print; print = function() end
dofile(base .. "/tests/native_smoke.lua"); print = saved_print
local core, Model = require "core", require "plugins.gitpanel.model"
local documents, runner = require "plugins.gitpanel.documents", require "plugins.gitpanel.runner"
local RootView, Doc, DocView = require "core.rootview", require "core.doc", require "core.docview"
local panel, ui, command = require "plugins.gitpanel", require "plugins.gitpanel.ui", require "core.command"
local function put(s) io.write(#s, "\n", s) end
local function get() local n=assert(tonumber(io.read("*l"))); return n>0 and assert(io.read(n)) or "" end
local checks, worker, model, hook, requests, errors, removes, logs, dialogs = 0
local source_name = "new"
local function check(ok,label) assert(ok,label); checks=checks+1; print("PASS R04B " .. label) end
local function has(a,s) for _,v in ipairs(a) do if v==s then return true end end end
core.add_thread=function(fn) assert(not worker); worker=coroutine.create(fn) end
core.error=function(_,err) errors[#errors+1]=tostring(err) end
core.log=function(fmt,...) logs[#logs+1]=string.format(fmt,...) end
core.nag_view.show=function() dialogs=dialogs+1 end
require("system").get_file_info=function(path)
  io.write("STAT\n"); put(path); io.flush()
  if io.read("*l")=="yes" then return {type=get()} end
  return nil,get()
end
require("system").list_dir=function(path)
  io.write("LIST_DIR\n"); put(path); io.flush()
  if io.read("*l")~="yes" then return nil,get() end
  local entries={}
  for i=1,assert(tonumber(io.read("*l"))) do entries[i]=get() end
  return entries
end
runner.run=function(argv,cwd,input)
  requests=requests+1
  io.write("REQUEST\n",#argv,"\n"); for _,v in ipairs(argv) do put(v) end
  put(cwd); put(input or ""); io.flush()
  local c,o,e=tonumber(io.read("*l")),get(),get()
  if argv[4]=="remove" then removes=removes+1 end
  if hook then c,o,e=hook(argv,c,o,e) end
  coroutine.yield(); return c,o,e
end
local function tick()
  local ok,err=coroutine.resume(assert(worker)); assert(ok,err)
  if coroutine.status(worker)=="dead" then worker=nil end
end
local function flush() for _=1,100 do if not worker then return end; tick() end; error("deadlock") end
local function event(name) io.write("EVENT\n",name,"\n"); io.flush(); assert(io.read("*l")=="continue") end
local function verify(expected) io.write("VERIFY\n",expected,"\n"); io.flush(); assert(io.read("*l")=="continue") end
local function setup(mode)
  source_name = mode=="unicode" and "néw" or "new"
  assert(not worker); io.write("SETUP\n",mode or "text","\n"); io.flush(); assert(io.read("*l")=="continue")
  core.root_view=RootView(); core.root_view.root_node.is_primary_node=true
  core.docs={}; core.project_dir=repo
  model=Model.new(); model.context={project=repo,generation=1}; model.root,model.status=repo,{}
  panel.model=model; panel.mode="git"
  hook,requests,removes,errors,logs,dialogs=nil,0,0,{},{},0
end
local function entry() return {path=source_name,x="?",y="?",status="??"} end
local function open()
  local owner
  model:browse_comparison(entry(),"untracked",function(data)
    owner=documents.open_browse_comparison(data,model.context)
    return function() return core.root_view.root_node:get_node_for_view(owner) and owner.data==data end
  end)
  flush(); assert(owner and owner.data.discard_snapshot,table.concat(errors,";")); return owner
end
local function hit(owner)
  owner.position.x,owner.position.y,owner.size.x,owner.size.y=0,0,900,600
  local box=assert(owner:action_boxes(1).revert)
  local x,y=box.x+box.w/2,box.y+box.h/2
  owner:on_mouse_pressed("left",x,y,1)
end
local function owners() return core.root_view.root_node:get_children() end
for _,gate in ipairs({false,true}) do
for _,action in ipairs({"row","hunk"}) do
  require("plugins.gitpanel.staging").ENABLED=gate
  setup(); local owner=open(); local old=owner.data
  local doc=Doc(); doc:load(repo .. "/" .. source_name); doc.abs_filename=repo .. "/" .. source_name; doc:clean(); core.docs={doc}
  local editor=DocView(doc); core.root_view:get_primary_node():add_view(editor)
  local before=table.concat(doc.lines); local undo=doc.undo_stack; local count,focus=#owners(),core.active_view
  check(old.remove_file and owner:can_revert() and #old.hunks==1 and old.hunks[1].ac==0,"whole all-addition comparison offers explicit Remove gate=" .. tostring(gate))
  local tip; core.status_view.show_tooltip=function(_,s) tip=s end
  if action=="row" then
    model.status=require("plugins.gitpanel.git").status("## main\0?? new\0MM neighbor\0")
    panel.list.size.x,panel.list.size.y=300,600; panel.list.position.x,panel.list.position.y=0,0
    panel.list.scroll.y,panel.list.scroll.to.y=0,0; panel.list.collapsed={}; panel.list.dirty=true; panel.list:rebuild()
    local row; for _,r in ipairs(panel.list.rows) do if r.entry and r.entry.path=="new" then row=r end end
    panel.list.selected=row.key
    local box=assert(panel.list:action_boxes(row).discard); local x,y=box.x+box.w/2,box.y+box.h/2
    panel.list:on_mouse_moved(x,y,0,0)
    local rendered=false; local draw=ui.draw_action
    ui.draw_action=function(s,b,h,e) if s=="undo" and b and b.x==box.x and e then rendered=true end; draw(s,b,h,e) end
    panel.list:draw(); ui.draw_action=draw
    check(rendered and tip:find("Remove untracked file (recoverable)",1,true) and panel.list:action_at(row,x,y)=="discard","U row native drawn shared Undo/Remove tooltip/hit agree")
    panel.list:on_mouse_pressed("right",x,y,1); check(not worker,"right U-row hit is inert")
    panel.list:on_mouse_pressed("left",x,y,1)
  else
    owner.size.x,owner.size.y=900,600
    local box=assert(owner:action_boxes(1).revert)
    owner:on_mouse_moved(box.x+box.w/2,box.y+box.h/2,0,0)
    local rendered=false; local draw=ui.draw_action
    ui.draw_action=function(s,b,h,e) if s=="undo" and b and b.x==box.x and e then rendered=true end; draw(s,b,h,e) end
    owner:draw(); ui.draw_action=draw
    check(rendered and tip:find("whole file",1,true) and tip:find("Remove untracked",1,true),"all-addition rail draws shared Undo with explicit whole-file Remove tooltip")
    core.set_active_view(owner); owner.change_index=1; owner.panes[2].doc:set_selection(1,1,2,1)
    check(not command.perform("git-panel:revert-selected-change") and not worker,"native selected-change undo command never turns partial selection into file deletion")
    focus=core.active_view
    hit(owner)
  end
  flush(); verify("removed")
  check(removes==1 and #errors==0 and dialogs==0 and logs[1]:find("recovery:",1,true),action .. " exact receipt/backups/index/HEAD/neighbors; one write, nonmodal recovery log")
  check(owner.data~=old and old.invalidated and owner.data.removed and not owner.data.invalidated
    and owner.data.original=="" and owner.data.modified=="" and #owner.data.hunks==0
    and #owner.panes[2].doc.source_lines==0 and not owner:can_revert() and not owner:can_stage(),action .. " same owner truthful empty zero-current comparison without actions")
  check(#owners()==count and core.active_view==focus and #model.status.untracked==0 and ui.scm_count(model)==2,action .. " no reopen/refocus; fresh status/count")
  doc:reload()
  check(table.concat(doc.lines)==before and doc.undo_stack==undo and not doc:is_dirty() and dialogs==0,action .. " missing clean normal Doc never force-loaded/cleaned/closed by action or delayed reload")
  local n=requests; old.revert(1); flush(); check(n==requests and removes==1,"old one-shot callback inert after removal")
end
end
require("plugins.gitpanel.staging").ENABLED=false
for _,mode in ipairs({"empty","binary"}) do
  setup(mode); model:discard_file(entry(),"untracked"); flush(); verify("removed")
  check(removes==1 and #errors==0 and dialogs==0,mode .. " U-row Remove independent of textual hunks and F11")
end
setup("staged")
local a={path="new",x="A",y=" ",status="A "}
model:discard_file(a,"staged"); flush(); verify("original")
check(removes==0 and requests==0 and errors[1]:find("Unstage first",1,true),"staged A must Unstage first; no helper mutation")
for _,scenario in ipairs({"dirty-initial","dirty-await","source","lock","stage","duplicate","generation"}) do
  setup(); local owner=open(); local old=owner.data
  local doc=Doc(); core.docs={doc}
  if scenario=="dirty-initial" then doc:insert(1,1,"unsaved") end
  if scenario=="source" or scenario=="lock" or scenario=="stage" then event(scenario) end
  if scenario=="generation" then model.context.generation=2 end
  hook=function(argv,c,o,e)
    if argv[4]=="snapshot" and scenario=="dirty-await" then doc:insert(1,1,"late unsaved") end
    return c,o,e
  end
  model:discard(old,1)
  if scenario=="duplicate" then model:discard(old,1); model:discard_file(entry(),"untracked") end
  flush(); verify(scenario=="duplicate" and "removed" or scenario=="source" and "newer" or "original")
  check(removes==(scenario=="duplicate" and 1 or scenario=="lock" and 1 or 0) and #errors>0 and not worker and not model.busy and dialogs==0,scenario .. " guarded one-shot mutation/refusal with no dialog or busy leak")
  if scenario:find("dirty",1,true) then check(doc:is_dirty() and doc.lines[1]:find("unsaved",1,true),scenario .. " retains all unpersisted text") end
end
-- Each actual await in direct Remove: snapshot, remove, status, index absence.
for _,scenario in ipairs({"dirty","replace","close","browse","files","generation","source","stage"}) do
for boundary=1,4 do
  setup(); local owner=open(); local old=owner.data; local doc=Doc(); core.docs={doc}
  if scenario=="close" then core.root_view:get_primary_node():add_view(DocView(Doc())) end
  local count=#owners(); local n,fired,newer=0,false,nil
  hook=function(argv,c,o,e)
    n=n+1
    if n==boundary then
      fired=true
      if scenario=="dirty" then doc:insert(1,1,"new unsaved\n")
      elseif scenario=="replace" then newer={foreign=true}; owner.data=newer
      elseif scenario=="close" then core.root_view.root_node:get_node_for_view(owner):close_view(core.root_view.root_node,owner)
      elseif scenario=="browse" then model:browse_comparison(entry(),"untracked",function(data)
        newer=data; local view=documents.open_browse_comparison(data,model.context); return function() return view.data==data end
      end)
      elseif scenario=="files" then panel:show("files")
      elseif scenario=="generation" then model.context.generation=2
      else event(scenario) end
    end
    return c,o,e
  end
  model:discard(old,1); flush()
  local expected=(scenario=="source" or scenario=="stage") and "newer" or
    boundary==1 and (scenario=="dirty" or scenario=="generation") and "original" or "removed"
  -- A staged-before-write event retains the original checked file bytes.
  if scenario=="stage" and boundary==1 then expected="original" end
  verify(expected)
  check(fired,scenario .. " exercised actual await " .. boundary)
  if scenario=="close" then check(not core.root_view.root_node:get_node_for_view(owner) and #owners()==count-1,"closed owner never reopened " .. boundary)
  elseif scenario=="replace" then check(owner.data==newer and #owners()==count,"newer owner data preserved " .. boundary)
  elseif scenario=="browse" then check(model.browse_request~=nil and not owner.data.removed,"newer browse never cancelled or replaced by final removal refresh " .. boundary)
  else check(owner.data==old and not owner.data.removed,"late " .. scenario .. " refuses cached-empty publication " .. boundary) end
  check(not model.busy and not worker and dialogs==0,"no pending mutation/dialog leak " .. scenario .. " " .. boundary)
end
end
-- Real disk errors/entries injected AFTER the final index read, not earlier
-- status or helper boundaries. nil stat includes real ENOENT, not an absence token.
local final_scenarios={"inaccessible","unsearchable","unlistable","dangling","source","absent","fifo"}
if case_alias then table.insert(final_scenarios,1,"case-alias"); table.insert(final_scenarios,"alias-dangling") end
if unicode_alias then table.insert(final_scenarios,"unicode-alias") end
for _,scenario in ipairs(final_scenarios) do
  setup(scenario=="unicode-alias" and "unicode" or nil); local owner=open(); local old=owner.data
  local doc=Doc(); doc:load(repo .. "/" .. source_name); doc.abs_filename=repo .. "/" .. source_name; doc:clean(); core.docs={doc}
  local editor=DocView(doc); core.root_view:get_primary_node():add_view(editor)
  local before,undo=table.concat(doc.lines),doc.undo_stack
  local old_original,old_modified=old.original,old.modified
  local count,focus,n,fired=#owners(),core.active_view,0,false
  -- Restore fixture permissions only AFTER the real publication method returns,
  -- so the unrelated queued general status refresh can still spawn in its cwd.
  local refresh_removed=model.refresh_removed
  model.refresh_removed=function(...)
    local ok,err=pcall(refresh_removed,...)
    event("accessible")
    if not ok then error(err) end
  end
  hook=function(argv,c,o,e)
    n=n+1
    if n==4 then
      assert(has(argv,"ls-files") and c==0 and o=="", "final index-read boundary")
      fired=true
      if scenario~="absent" then event(scenario) end
    end
    return c,o,e
  end
  model:discard(old,1); flush()
  verify(scenario=="absent" and "removed" or (scenario=="dangling" or scenario=="alias-dangling") and "dangling"
    or scenario=="fifo" and "fifo" or "newer")
  check(fired and removes==1,"final absence " .. scenario .. " real receipt/disk/index/HEAD/neighbor verified")
  check(#owners()==count and core.active_view==focus and dialogs==0 and not model.busy and not worker
    and table.concat(doc.lines)==before and doc.undo_stack==undo and not doc:is_dirty(),
    "final absence " .. scenario .. " no focus/tab/Doc mutation or dialog")
  check(old.original==old_original and old.modified==old_modified and old.invalidated,
    "final absence " .. scenario .. " acquired source bytes retained stale")
  if scenario=="absent" then
    check(owner.data~=old and owner.data.removed and not owner.data.invalidated and #errors==0
      and owner.data.original=="" and owner.data.modified=="" and #owner.data.hunks==0
      and #owner.panes[2].doc.source_lines==0 and not owner:can_revert() and not owner:can_stage(),
      "final absence genuine ENOENT refreshes same owner to removed/zero")
    doc:reload()
    check(table.concat(doc.lines)==before and doc.undo_stack==undo and not doc:is_dirty(),
      "final absence missing source never force-loaded by delayed reload")
  else
    print("OBSERVED final absence " .. scenario .. " owner_replaced=" .. tostring(owner.data~=old)
      .. " removed=" .. tostring(owner.data.removed==true) .. " errors=" .. #errors)
    check(owner.data==old and not owner.data.removed and #errors>0,
      "final absence " .. scenario .. " refuses false removed publication")
  end
end
-- Same mutable context: only current authoritative acquisitions are invalidated.
setup(); local older=open(); local old=older.data; model.context.generation=2
local fresh=open(); local current=fresh.data; local duplicate=documents.open_comparison(current)
model:discard(current,1); flush(); verify("removed")
check(older.data==old and not old.invalidated and model.comparison_views[old].generation==1,"older generation never promoted, refreshed or invalidated")
check(fresh.data.removed and duplicate.data.removed and fresh.data~=duplicate.data and current.invalidated,"current registered readonly owners refreshed independently")
-- New normal document edited after helper write stays intact; missing reload is inert.
setup(); local owner=open(); local doc
hook=function(argv,c,o,e)
  if argv[4]=="remove" then
    doc=Doc(); doc.filename,doc.abs_filename="new",repo .. "/" .. source_name; core.docs={doc}; doc:insert(1,1,"later new text\n")
  end
  return c,o,e
end
model:discard(owner.data,1); flush(); doc:reload(); verify("removed")
check(doc:is_dirty() and doc.lines[1]=="later new text\n" and not owner.data.removed and dialogs==0,"later-opened dirty Doc protected without extra NagView or missing-file reload")
print(checks .. " R04B removal native/real-Git checks passed (bootstrap suppressed; no GUI)")
