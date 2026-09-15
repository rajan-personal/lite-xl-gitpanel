-- R02/R03 native core/Node/Doc with real Git/Python over the owned fixture bridge.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
local repo = arg[1]; arg[1] = nil
-- Bootstrap assertions are reported by the existing suite, not duplicated here.
local print_saved = print; print = function() end
dofile(base .. "/tests/native_smoke.lua")
print = print_saved
local core = require "core"
local Model = require "plugins.gitpanel.model"
local documents = require "plugins.gitpanel.documents"
local RootView = require "core.rootview"
local Doc, DocView = require "core.doc", require "core.docview"
local runner = require "plugins.gitpanel.runner"
local panel = require "plugins.gitpanel"
local function put(s) io.write(#s, "\n", s) end
local function get() local n=assert(tonumber(io.read("*l"))); return n>0 and assert(io.read(n)) or "" end
local checks, worker, model, hook, requests, errors, replaces = 0
local function check(ok, label) assert(ok,label); checks=checks+1; print("PASS " .. label) end
local function has(argv,s) for _,v in ipairs(argv) do if v==s then return true end end end
core.add_thread = function(fn) assert(not worker); worker=coroutine.create(fn) end
core.error = function(_,err) errors[#errors+1]=tostring(err) end
core.log = function() end
runner.run = function(argv,cwd,input)
  requests=requests+1
  io.write("REQUEST\n",#argv,"\n"); for _,v in ipairs(argv) do put(v) end
  put(cwd); put(input or ""); io.flush()
  local code,out,err=tonumber(io.read("*l")),get(),get()
  if argv[4]=="replace" then replaces=replaces+1 end
  if hook then code,out,err=hook(argv,code,out,err) end
  coroutine.yield()
  return code,out,err
end
local function tick()
  local ok,err=coroutine.resume(assert(worker)); assert(ok,err)
  if coroutine.status(worker)=="dead" then worker=nil end
end
local function flush() for _=1,300 do if not worker then return end; tick() end; error("busy deadlock") end
local function setup(deleted)
  assert(not worker)
  io.write("SETUP\n",type(deleted)=="string" and deleted .. "\n" or deleted and "deleted\n" or "modified\n")
  io.flush(); assert(io.read("*l")=="continue")
  core.root_view=RootView(); core.root_view.root_node.is_primary_node=true
  core.docs={}; core.project_dir=repo
  model=Model.new(); model.context={project=repo,generation=1}; model.root,model.status=repo,{}
  panel.model=model; panel.mode="git"
  hook,requests,replaces,errors=nil,0,0,{}
end
local function entry(deleted) return {path="file",x="M",y=deleted and "D" or "M",status=deleted and "MD" or "MM"} end
local function open(deleted)
  local owner
  model:browse_comparison(entry(deleted),"changes",function(data)
    owner=documents.open_browse_comparison(data,model.context)
    return function() return core.root_view.root_node:get_node_for_view(owner) and owner.data==data end
  end)
  flush(); assert(owner and owner.data.discard_snapshot,table.concat(errors,"\n")); return owner
end
local original="INDEX\na\nb\nc\nd\ne\nf\nlast\n"
local partial="INDEX\na\nb\nc\nd\nE\nf\nlast\n"
local function verify(text)
  io.write("VERIFY\n"); put(text); io.flush(); assert(io.read("*l")=="continue")
end
local function owners() return core.root_view.root_node:get_children() end
-- Same owner, two actual native undo hits, including the last remaining block.
-- The preview gate is in-memory only; production and installed defaults stay false.
local staging = require "plugins.gitpanel.staging"
local ui = require "plugins.gitpanel.ui"
local nag_show, dialogs = core.nag_view.show, 0
core.nag_view.show = function(...) dialogs=dialogs+1; return nag_show(...) end
for _,enabled in ipairs({true,false}) do
for _,mode in ipairs({"modified","insertions","mixed-addition"}) do
  staging.ENABLED=enabled
  setup(mode)
  local owner=open(); local count,focus=#owners(),core.active_view
  local label="R03 " .. mode .. " gate=" .. tostring(enabled)
  check(#owner.data.hunks==2 and not owner.data.invalidated, label .. ": starts with two fresh blocks")
  check((owner.data.staging_snapshot~=nil)==enabled, label .. ": QA gate really controls real staging helper capture")
  for step=1,2 do
    local old=owner.data
    owner.position.x,owner.position.y,owner.size.x,owner.size.y=0,0,900,600
    local boxes=owner:action_boxes(1); local box=assert(boxes.revert)
    local addition=mode=="insertions" or mode=="mixed-addition" and step==2
    if addition then
      local h=old.hunks[1]; local row=old.rows[h.row]
      check(h.ac==0 and h.bc>0 and not row[1] and row[2],label .. ": green insertion starts at an Original aligned gap")
    end
    local draw_action, rendered=ui.draw_action,false
    ui.draw_action=function(symbol,rect,hover,ready)
      if symbol=="undo" and rect and rect.x==box.x and rect.y==box.y and ready then rendered=true end
      return draw_action(symbol,rect,hover,ready)
    end
    owner:draw(); ui.draw_action=draw_action
    local x,y=box.x+box.w/2,box.y+box.h/2
    check(rendered and owner:arrow_at(x,y)==1 and not owner:stage_at(x,y),label .. ": visible undo and native hit agree at step " .. step)
    owner:on_mouse_pressed("left",x,y,1); flush()
    local expected=step==2 and original or mode=="modified" and partial
      or "INDEX\na\nb\nc\nd\ne\nf\nadded last\nlast\n"
    verify(expected)
    check(true,label .. ": real write retains file and exact index/HEAD/neighbors at step " .. step)
    check(owner.data~=old and old.invalidated and not owner.data.invalidated and owner.data.modified==expected
      and table.concat(owner.panes[2].doc.source_lines)==expected and #owner.data.hunks==2-step,
      label .. ": same owner publishes fresh " .. (2-step) .. " changes at step " .. step .. " errors=" .. table.concat(errors,";"))
    check(#owners()==count and core.active_view==focus and replaces==step and dialogs==0 and #errors==0,
      label .. ": no reopen, extra owner, focus steal, extra write, Git dialog or error")
  end
  check(owner.data.original==owner.data.modified and owner.data.entry.y==" " and not owner.data.discard_snapshot
    and not owner.data.staging_snapshot and not owner.data.staging_context and not owner.data.revert and not owner.data.stage
    and not owner:can_revert() and not owner:can_stage() and not next(owner:action_boxes(1)),
    label .. ": clean display has equal sources and no action controls or snapshot tokens")
  io.write("VERIFY_CLEAN\n"); io.flush(); assert(io.read("*l")=="continue")
  check(true,label .. ": real Git diff empty and Python helper still refuses no textual changes")
  local fresh
  model:comparison(owner.data.entry,"changes",function(data) fresh=data end); flush()
  check(fresh and fresh.original==fresh.modified and not fresh.staging_snapshot and not fresh.discard_snapshot
    and not fresh.stage and not fresh.revert,label .. ": default/action acquisition of clean text stays readonly")
  local revisited
  model:browse_comparison(owner.data.entry,"changes",function(data)
    revisited=documents.open_browse_comparison(data,model.context)
    return function() return revisited.data==data end
  end); flush()
  check(revisited==owner and #owners()==count and not owner.data.staging_snapshot and not owner.data.discard_snapshot
    and not owner.data.stage and not owner.data.revert and not owner.data.capabilities_pending,
    label .. ": subsequent clean browse reuses owner without pending or ready actions")
  verify(original)
end
end
staging.ENABLED=true
check(staging.eligible({group="changes"}) and staging.eligible({group="changes",unsupported="invalid",original="",modified=""}),
  "R03 missing/unsupported source is not mistaken for a validated equal-text comparison")
for _,group in ipairs({"changes","staged","untracked"}) do
  check(not staging.eligible({group=group,original="",modified=""}),"R03 validated equal-text " .. group .. " has no staging readiness")
end
staging.ENABLED=false
core.nag_view.show=nag_show
for _,mode in ipairs({"block","whole","deleted"}) do
  setup(mode=="deleted")
  local owner=open(mode=="deleted"); local old=owner.data; local old_callback=old.revert
  local duplicate=documents.open_comparison(old)
  local doc=Doc()
  if mode=="deleted" then doc:insert(1,1,"previous open text") else doc:load(repo .. "/file") end
  doc.abs_filename=repo .. "/file"; doc:clean()
  -- Deleted files still have an existing clean native document from before deletion.
  core.docs={doc}; local editor=DocView(doc); core.root_view:get_primary_node():add_view(editor)
  local count=#owners(); local focus=core.active_view
  if mode=="block" then model:discard(old,1) else model:discard_file(entry(mode=="deleted"),"changes") end
  flush()
  local expected=mode=="block" and partial or original
  check(owner.data~=old and owner.data.modified==expected and table.concat(owner.panes[2].doc.source_lines)==expected,
    mode .. ": successful helper refreshes existing readonly native owner bytes")
  check(duplicate.data~=old and duplicate.data.modified==expected and not owner.data.invalidated and not duplicate.data.invalidated,
    mode .. ": shared-old-data explicit duplicate refreshed safely")
  check(old.invalidated and #owners()==count and core.active_view==focus and editor.doc==doc,
    mode .. ": no tab creation or focus steal; old source invalidated")
  check(table.concat(doc.lines)==expected and not doc:is_dirty(),mode .. ": matching clean native Doc reloaded")
  check(#owner.data.hunks==(mode=="block" and 1 or 0) and (mode=="block" and owner.data.discard_snapshot~=nil or
    mode~="block" and owner.data.entry.y==" " and not owner.data.discard_snapshot),mode .. ": fresh status/actions including neutral zero-change entry")
  local before=requests; old_callback(1); flush()
  check(requests==before and errors[#errors]:find("Stale diff"),mode .. ": retained old callback refuses before transport")
  verify(expected); check(true,mode .. ": real Git exact worktree/index/HEAD/neighbor invariants")
  -- Explicit duplicate has independent fresh data, so P03 can reuse sidebar owner.
  local revisited
  model:browse_comparison(owner.data.entry,"changes",function(data)
    revisited=documents.open_browse_comparison(data,model.context); return function() return revisited.data==data end
  end); flush()
  check(revisited==owner and #owners()==count,mode .. ": P03 revisit still reuses original owner")
  verify(expected); check(true,mode .. ": ordinary comparison acquisition preserves raw index bytes")
end
-- Every asynchronous operation boundary: preflight, write, fresh status, patch,
-- index mode, index bytes, and new helper capture. An old target must not win
-- over a later close/replace/selection/browse/Files/project choice.
for _,action in ipairs({"block", "file"}) do
for _,scenario in ipairs({"close","replace","selection","browse","files","project","root"}) do
  for boundary=1,(action=="block" and 7 or 10) do
    setup(); local owner=open(); local old=owner.data
    if scenario=="close" then core.root_view:get_primary_node():add_view(DocView(Doc())) end
    local count=#owners()
    local n, fired, newer = 0,false,nil
    hook=function(argv,code,out,err)
      n=n+1
      if n==boundary then
        fired=true
        if scenario=="close" then
          local node=core.root_view.root_node:get_node_for_view(owner)
          node:close_view(core.root_view.root_node,owner)
        elseif scenario=="replace" then
          newer={foreign=true}; owner.data=newer
        elseif scenario=="selection" then
          owner.panes[2].doc:set_selection(2,2,1,1)
        elseif scenario=="browse" then
          model:browse_comparison(entry(),"changes",function(data)
            newer=documents.open_browse_comparison(data,model.context)
            return function() return newer.data==data end
          end)
        elseif scenario=="files" then panel:show("files")
        elseif scenario=="root" then model.root=repo .. "/new-root"
        else
          core.project_dir=repo .. "/new-project"
          model.context={project=core.project_dir,generation=2}; model.root=nil
          model:cancel_browse(); model.busy=false
        end
      end
      return code,out,err
    end
    if action=="block" then model:discard(old,1) else model:discard_file(entry(),"changes") end
    flush()
    check(fired,action .. " " .. scenario .. ": exercised await " .. boundary)
    local expected=action=="block" and partial or original
    local before_write=boundary<=(action=="block" and 1 or 5)
    if (scenario=="project" or scenario=="root") and before_write then expected="INDEX\nA\nb\nc\nd\nE\nf\nlast\n" end
    verify(expected)
    if scenario=="close" then
      check(not core.root_view.root_node:get_node_for_view(owner) and #owners()==count-1 and old.invalidated,
        "closed target is never reopened at await " .. boundary)
    elseif scenario=="replace" then
      check(owner.data==newer and old.invalidated and #owners()==count,"foreign replacement survives await " .. boundary)
    elseif scenario=="selection" then
      check(owner.data==old and old.invalidated and table.concat({owner.panes[2].doc:get_selection()},",")=="2,2,1,1",
        "newer native selection survives await " .. boundary)
    elseif scenario=="browse" then
      local early=action=="file" and boundary<=4
      check(newer==owner and owner.data~=old and (early and owner.data.invalidated or not early and owner.data.modified==expected
        and not owner.data.invalidated) and #owners()==count and replaces==1,
        "newer browse survives inline refresh without duplicate or lost mutation at await " .. boundary)
      if early and boundary==1 then
        local draw_text, stale = renderer.draw_text, false
        renderer.draw_text=function(font,text,...)
          stale=stale or tostring(text):find("STALE — reopen",1,true)~=nil
          return draw_text(font,text,...)
        end
        owner.size.x,owner.size.y=900,600; owner:draw(); renderer.draw_text=draw_text
        local before=requests; old.revert(1); owner:revert_block(1); flush()
        check(stale and not owner:can_revert() and not owner:can_stage() and requests==before,
          "early FIFO browse renders STALE and both old/new actions remain inert")
        local reopened
        model:browse_comparison(entry(),"changes",function(data)
          reopened=documents.open_browse_comparison(data,model.context)
          return function() return reopened.data==data end
        end); flush()
        check(reopened==owner and not owner.data.invalidated and owner.data.modified==expected and #owners()==count,
          "explicit reopen replaces early stale browse with current bytes in the same owner")
        verify(expected)
      end
    elseif scenario=="files" then
      check(panel.mode=="files" and core.active_view~=owner and owner.data==old and old.invalidated,
        "Files focus/cancellation survives await " .. boundary)
    elseif scenario=="root" then
      check(owner.data==old and #owners()==count and replaces==(before_write and 0 or 1),
        "changed raw root never receives old refresh publication at await " .. boundary)
    else
      check(model.context.project==repo .. "/new-project" and owner.data==old and #owners()==count,
        "project switch never receives old refresh publication at await " .. boundary)
    end
  end
end
end
-- One changed/ineligible owner must not prevent a still-eligible independent
-- owner refreshing, even when they shared the exact old data and action closures.
setup(); local owner=open(); local old=owner.data
local duplicate=documents.open_comparison(old)
local doc=Doc(); doc:load(repo .. "/file"); doc.abs_filename=repo .. "/file"; doc:clean(); core.docs={doc}
local editor=DocView(doc); core.root_view:get_primary_node():add_view(editor)
hook=function(argv,c,o,e)
  if argv[4]=="replace" then
    doc:insert(1,1,"new unsaved text\n")
    owner.panes[2]=DocView(Doc()) -- no permission to overwrite this editable helper
  end
  return c,o,e
end
model:discard(old,1); flush()
check(owner.data==old and old.invalidated and getmetatable(owner.panes[2].doc)==Doc
  and duplicate.data~=old and duplicate.data.modified==partial,"ineligible editable duplicate is untouched while eligible owner refreshes")
check(doc:is_dirty() and doc.lines[1]=="new unsaved text\n" and core.active_view==editor,
  "native edit after write starts survives clean reload and background refresh")
verify(partial)
-- Native undo/remove reuses the clean change ID without preserving revision.
-- The edit happens after the real helper write, before its success callback.
setup(); owner=open(); old=owner.data
local reused=Doc(); reused:load(repo .. "/file"); reused.abs_filename=repo .. "/file"
reused:insert(1,1,"saved insertion"); reused:clean(); core.docs={reused}
local saved_id, saved_text=reused:get_change_id(),table.concat(reused.lines)
local newer_text, undo, redo, undo_index, redo_index, undo_top, redo_top
hook=function(argv,c,o,e)
  if argv[4]=="replace" then
    reused:undo(); reused:remove(2,1,2,2)
    newer_text=table.concat(reused.lines)
    undo,redo=reused.undo_stack,reused.redo_stack
    undo_index,redo_index=undo.idx,redo.idx
    undo_top,redo_top=undo[undo.idx-1],redo[redo.idx-1]
    check(saved_id==3 and reused:get_change_id()==saved_id and not reused:is_dirty() and newer_text~=saved_text,
      "native post-write undo/remove really reuses clean index 3 with newer text")
  end
  return c,o,e
end
model:discard(old,1); flush()
check(table.concat(reused.lines)==newer_text and reused.undo_stack==undo and reused.redo_stack==redo
  and undo.idx==undo_index and redo.idx==redo_index and undo[undo.idx-1]==undo_top and redo[redo.idx-1]==redo_top,
  "post-write reused clean index preserves newer native text and undo/redo history")
check(owner.data~=old and owner.data.modified==partial,"reused Doc index does not prevent eligible comparison refresh")
verify(partial)
-- Same context pointer, different acquisition generation: old browse/explicit
-- owners and their legacy discard registrations cannot become generation 2.
setup(); local older=open(); local older_data, older_panes=older.data,older.panes
local older_duplicate=documents.open_comparison(older_data)
model.context.generation=2
local fresh=open(); local fresh_data=fresh.data
local fresh_duplicate=documents.open_comparison(fresh_data)
local unknown_data={}; for k,v in pairs(fresh_data) do unknown_data[k]=v end
local unknown=documents.open_comparison(unknown_data)
local captured=documents.capture_affected(model.context,repo,"file",model.comparison_views)
local count=#owners(); local focus=core.active_view
model:discard(fresh_data,1); flush()
check(older.data==older_data and older.panes==older_panes and older_duplicate.data==older_data
  and not older_data.invalidated,"same-context rollover leaves older native owners/data unrefreshed and uninvalidated")
check(#captured.owners==2 and model.comparison_views[older_data].generation==1
  and model.comparison_views[fresh_data].generation==2,"capture uses stable acquisition generations, not mutable context generation")
check(fresh.data~=fresh_data and fresh_duplicate.data~=fresh_data and fresh.data~=fresh_duplicate.data
  and fresh.data.modified==partial and fresh_duplicate.data.modified==partial and fresh_data.invalidated,
  "same-context rollover refreshes matching registered native owner and explicit duplicate independently")
check(unknown.data==unknown_data and not unknown_data.invalidated,
  "unregistered explicit data is conservatively excluded from generation-scoped refresh/invalidation")
check(#owners()==count and core.active_view==focus,"generation-scoped refresh adds no tabs or focus change")
verify(partial)
-- Remove intentional sharing, then P03 must reuse only the fresh registration.
for _,view in ipairs({older_duplicate,fresh_duplicate,unknown}) do
  core.root_view.root_node:get_node_for_view(view):close_view(core.root_view.root_node,view)
end
check(open()==fresh and older.data==older_data and older.panes==older_panes and not older_data.invalidated,
  "R02 never promotes the original older private browse registration into current eligibility")
verify(partial)
-- Matching aliases reload clean, preserve current selection and clamp when shorter.
setup(); owner=open(); old=owner.data
local a,b=Doc(),Doc(); a:load(repo .. "/file"); b:load(repo .. "/file")
a.abs_filename,b.abs_filename=repo .. "/file",repo .. "/./file"; a:clean(); b:clean(); core.docs={a,b}
local system=require "system"; local absolute=system.absolute_path
system.absolute_path=function(path) return path:gsub("/%./","/") end
hook=function(argv,c,o,e) if argv[4]=="replace" then a:set_selection(8,4); b:set_selection(2,2) end; return c,o,e end
model:discard(old,1); flush(); system.absolute_path=absolute
check(table.concat(a.lines)==partial and table.concat(b.lines)==partial and a:get_selection()==8
  and b:get_selection()==2 and not a:is_dirty() and not b:is_dirty(),"matching clean aliases reload with current native selections preserved")
verify(partial)
-- Post-write acquisition failures never present ready stale tokens. Ambiguous
-- write errors do not assume failure means unchanged disk, or run a UI refresh.
for _,failure in ipairs({"write","status","patch","mode","snapshot","mismatch","staging-snapshot","staging-mismatch"}) do
  staging.ENABLED=failure:find("staging-",1,true)~=nil
  setup(); owner=open(); old=owner.data
  local old_callback=old.revert; local after_write=false
  hook=function(argv,c,o,e)
    if argv[4]=="replace" then after_write=true; if failure=="write" then return nil,"","uncertain write result" end
    elseif after_write then
      if failure=="status" and has(argv,"status") or failure=="patch" and has(argv,"diff") then return 1,"","fresh read failed" end
      if failure=="mode" and has(argv,"ls-files") then return 0,"120000 abc 0\tfile\0","" end
      if argv[4]=="snapshot" then
        if failure=="snapshot" or failure=="staging-snapshot" and argv[3]:match("/staging.py$") then
          return 1,"","new helper unavailable"
        end
        if failure=="mismatch" or failure=="staging-mismatch" and argv[3]:match("/staging.py$") then
          local fields=require("plugins.gitpanel.discard").unpack_fields(o)
          return 0,require("plugins.gitpanel.discard").pack({fields[1],"different bytes\n",fields[3]}),""
        end
      end
    end
    return c,o,e
  end
  model:discard(old,1); flush()
  check(owner.data==old and old.invalidated and #errors>0 and not model.busy and not worker,
    failure .. ": failed/uncertain refresh leaves old owner disabled and nonmodal error, no deadlock")
  local before=requests; old_callback(1); flush()
  check(before==requests and replaces==1 and #owners()==1,failure .. ": no old-token retry, new tab or second write")
  verify(partial)
end
staging.ENABLED=false
-- The same early FIFO publication must be invalidated even if replace's result
-- is uncertain. Never treat this newer owner as an automatic replacement target.
setup(); owner=open(); old=owner.data
local newer_data, n = nil,0
hook=function(argv,c,o,e)
  n=n+1
  if n==1 then
    model:browse_comparison(entry(),"changes",function(data)
      newer_data=data
      local newer=documents.open_browse_comparison(data,model.context)
      return function() return newer.data==data end
    end)
  end
  if argv[4]=="replace" then return nil,"","uncertain write result" end
  return c,o,e
end
model:discard_file(entry(),"changes"); flush()
check(newer_data and owner.data==newer_data and newer_data.invalidated and not newer_data.capabilities_pending
  and not owner:can_revert() and not owner:can_stage() and old.invalidated and replaces==1 and #errors>0 and #owners()==1,
  "uncertain whole-file write invalidates newer action-unready FIFO browse without replacing it")
verify(original)
print(checks .. " R02/R03 refresh native/real-Git checks passed (bootstrap suppressed; no GUI)")
