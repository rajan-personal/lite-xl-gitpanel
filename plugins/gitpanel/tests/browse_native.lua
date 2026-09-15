-- P03: actual Sidebar -> Model -> documents -> installed native Node/Doc/View.
-- Transport, renderer and scheduling are substitutes; no GUI or filesystem fixture.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core = require "core"
local panel = require "plugins.gitpanel"
local Model = require "plugins.gitpanel.model"
local documents = require "plugins.gitpanel.documents"
local DiffView = require "plugins.gitpanel.diffview"
local RootView = require "core.rootview"
local Doc, DocView = require "core.doc", require "core.docview"
local staging = require "plugins.gitpanel.staging"
local runner = require "plugins.gitpanel.runner"
local checks, worker, acquisitions, requests, errors = 0, nil, 0, 0, 0
local source, modified, unsupported = "old\n", "new\n", false
local function check(ok, label) assert(ok, label); checks=checks+1; print("PASS " .. label) end
local function has(argv, value) for _,v in ipairs(argv) do if v == value then return true end end end
local function pack(a,b,c) return #a .. "\n" .. a .. #b .. "\n" .. b .. #c .. "\n" .. c end
core.error = function() errors=errors+1 end
core.add_thread = function(fn) assert(not worker); worker=coroutine.create(fn) end
staging.ENABLED = true -- in-memory only
local current_group
runner.run = function(argv)
  requests=requests+1
  local capture_source, capture_modified = source, current_group == "staged" and modified or ""
  if has(argv,"diff") then acquisitions=acquisitions+1 end
  coroutine.yield()
  if argv[1] == "python3" then return 0,pack(capture_source,capture_modified,"token-" .. acquisitions),"" end
  if has(argv,"diff") then
    if source==capture_modified then return 0,"","" end
    local lines=require("plugins.gitpanel.diff").lines
    local left,right=lines(source),lines(capture_modified)
    local patch="@@ -" .. (#left==0 and "0" or "1") .. "," .. #left
      .. " +" .. (#right==0 and "0" or "1") .. "," .. #right .. " @@\n"
    for _,line in ipairs(left) do patch=patch .. "-" .. line end
    for _,line in ipairs(right) do patch=patch .. "+" .. line end
    return 0,patch,""
  end
  if has(argv,"ls-files") then return 0,(unsupported and "120000" or "100644") .. " abc 0\tfile\0","" end
  if has(argv,"show") then
    for _,v in ipairs(argv) do if v:sub(1,5) == "HEAD:" then return 0,source,"" end end
    return 0,current_group == "staged" and modified or source,""
  end
  return 0,"",""
end
local function tick()
  local ok,err=coroutine.resume(assert(worker)); assert(ok,err)
  if coroutine.status(worker) == "dead" then worker=nil end
end
local function flush() for _=1,100 do if not worker then return end; tick() end; error("stuck worker") end
local function fresh()
  assert(not worker)
  core.root_view=RootView(); core.root_view.root_node.is_primary_node=true
  core.root_view.root_node:split("left",panel,{x=true},true)
  core.root_view.root_node.size.x,core.root_view.root_node.size.y=1200,800
  core.project_dir="/p03"
  panel.model=Model.new(); panel.model.context={project=core.project_dir,generation=1}
  panel.model.root, panel.model.status=core.project_dir,{}
  panel.mode="git"; core.set_active_view(panel)
  acquisitions,requests,errors=0,0,0; source,modified,unsupported="old\n","new\n",false
end
local function entry(path,old_path) return {path=path or "file",old_path=old_path,x="M",y="D"} end
local function start(e,g)
  current_group=g or "changes"
  panel:open_diff(e or entry(),current_group)
end
local function open(e,g) start(e,g); flush(); return core.active_view end
local function owners()
  local out={}
  for _,v in ipairs(core.root_view.root_node:get_children()) do
    if v ~= panel then out[#out+1]=v end
  end
  return out
end
local function node(v) return core.root_view.root_node:get_node_for_view(v) end
fresh()
local owner, old_data, old_panes
for i=1,20 do
  local v=open()
  if i==1 then owner=v else assert(v.data ~= old_data,"fresh data object for every acquisition") end
  old_data,old_panes=v.data,v.panes
end
print("TABCOUNT sequential_identical opens=20 fresh_acquisitions=" .. acquisitions .. " owners=" .. #owners())
check(acquisitions==20 and #owners()==1 and core.active_view==owner,
  "20 sequential fresh sidebar acquisitions retain one logical eligible owner")
source="updated\n"
owner.scroll.x,owner.scroll.y,owner.scroll.to.x,owner.scroll.to.y=999,999,999,999
owner.side,owner.all,owner.change_index,owner.selecting=1,true,77,{99,99}
owner.panes[1].doc:set_selection(1,3,1,1)
local old_stage, old_revert=old_data.stage,old_data.revert
local refreshed=open()
check(refreshed==owner and owner.data.original==source and owner.panes~=old_panes
  and owner.panes[1].doc.source_lines[1]==source and old_data.invalidated and not old_data.capabilities_pending,
  "reuse replaces source bytes/helpers and invalidates superseded snapshot")
check(owner.side==2 and not owner.all and not owner.change_index and not owner.selecting
  and owner.scroll.x==0 and owner.scroll.y==0 and owner.scroll.to.x==0 and owner.scroll.to.y==0
  and table.concat({owner.panes[1].doc:get_selection()},",")=="1,1,1,1",
  "reuse initializes selection and scroll within shorter fresh source bounds")
local before=requests
old_stage(1); flush(); old_revert(1)
check(requests==before and errors==2 and not core.nag_view.visible,
  "retained old stage/revert callbacks refuse invalidated data before transport or confirmation")
for _,pane in ipairs(owner.panes) do
  local text=table.concat(pane.doc.lines)
  pane.doc:insert(1,1,"forbidden"); pane.doc:remove(1,1,1,2); pane.doc:reset()
  check(not node(pane) and not pane.doc.filename and not pane.doc:is_dirty() and table.concat(pane.doc.lines)==text,
    "fresh source helper stays readonly and outside Node ownership")
end
owner:layout(); owner:draw()
check(owner:row_at(-999)==1 and owner:row_at(999999)==#owner.data.rows,
  "fresh alignment row lookup clamps at both source bounds")
fresh(); source="one\ntwo\nthree\n"; owner=open()
owner.panes[1].doc:set_selection(3,5,2,2); owner.scroll.to.y=999
source="short\n"; check(open()==owner and owner.data.original==source and owner.panes[1].doc:get_selection()==1
  and owner.scroll.to.y==0,"shorter source resets out-of-range old selection/scroll")
source,modified="",""; local empty=open(nil,"staged"); local empty_data=empty.data
check(open(nil,"staged")==empty and empty.data~=empty_data and #empty.data.rows==0
  and empty.panes[1].doc:get_selection()==1 and empty:row_at(999)==1,
  "empty supported source reuse retains valid selection/row sentinel")
modified="updated index\n"; local staged=open(nil,"staged")
check(staged==empty and staged.data.modified==modified and staged.panes[2].doc.source_lines[1]==modified,
  "fresh staged source bytes replace the reused modified pane")
-- Original P02 liveness closes over both owner identity and the published data.
fresh(); local predicates={}; local browse=panel.model.browse_comparison
panel.model.browse_comparison=function(self,e,g,callback)
  return browse(self,e,g,function(data)
    local alive=callback(data); predicates[#predicates+1]=alive; return alive
  end)
end
owner=open(); check(predicates[1](),"published P02 predicate recognizes live original owner/data")
check(open()==owner and not predicates[1]() and predicates[2](),
  "P02 original-view same-data predicate rejects superseded data despite same live tab")
-- Composite identity compares raw values, never rendered names or delimiters.
fresh(); owner=open()
local variants={
  {entry(),"staged"}, {entry("dir/file")}, {entry("file","old")},
  {entry("line\nname")}, {entry("line\\nname")}, {entry("tab\tname")}, {entry("tab\\tname")},
  {entry("a|b","c")}, {entry("a","b|c")}, {entry("a/line\nname")}, {entry("b/line\nname")},
}
for _,v in ipairs(variants) do
  local n=#owners(); local first=open(v[1],v[2]); local data=first.data
  local again=open(v[1],v[2])
  check(#owners()==n+1 and first==again and again.data~=data,
    "raw group/path/old_path identity disambiguates variant " .. n)
end
check(open(entry("a/line\nname")):get_name()==open(entry("b/line\nname")):get_name(),
  "escaped basename collision fixtures actually share tab display text")
local n=#owners(); panel.model.root="/other-root"; local other=open()
check(#owners()==n+1 and other~=owner,"different raw root cannot reuse prior owner")
-- Returning roots does not revive any action token; same valid context/key can refresh.
panel.model.root="/p03"; check(open()==owner,"return to same raw root/context still reacquires before reuse")
local ctx=panel.model.context; n=#owners()
panel.model.context={project=core.project_dir,generation=ctx.generation}
check(open()~=owner and #owners()==n+1,"different context identity cannot reuse even equal generation")
n=#owners(); panel.model.context.generation=2
check(open()~=owner and #owners()==n+1,"changed generation on same context cannot reuse")
-- Generic explicit openings and dirty editors retain intentional multiplicity.
fresh(); owner=open(); old_data=owner.data
local explicit_data=require("plugins.gitpanel.diff").build(old_data.original,old_data.modified,old_data.patch)
explicit_data.path,explicit_data.root,explicit_data.group=old_data.path,old_data.root,old_data.group
local explicit1=documents.open_comparison(explicit_data)
local explicit2=documents.open_comparison(explicit_data)
local raw1=documents.open("same", "one"); local raw2=documents.open("same", "two")
local dirty=Doc(); dirty:insert(1,1,"unsaved"); local editor=DocView(dirty); node(raw2):add_view(editor)
local count=#owners(); check(open()==owner and #owners()==count and node(explicit1) and node(explicit2)
  and node(raw1) and node(raw2) and dirty:is_dirty() and dirty:get_text(1,1,1,8)=="unsaved",
  "generic explicit multi-view/raw snapshots and dirty editor tabs are not deduplicated or edited")
-- Replaced foreign data/doc/helper identities are not an eligible browse owner.
fresh(); owner=open(); owner.data={foreign=true}; n=#owners()
check(open()~=owner and #owners()==n+1 and owner.data.foreign,"foreign replaced data is not overwritten")
fresh(); owner=open(); owner.panes[1]=DocView(Doc()); n=#owners()
check(open()~=owner and #owners()==n+1,"replaced editable source helper excludes browse owner")
fresh(); owner=open(); local parent=node(owner); parent:close_view(core.root_view.root_node,owner)
check(not node(owner),"native close removes eligible owner")
local reopened=open(); check(reopened~=owner and #owners()==1 and acquisitions==2,"closed owner is freshly reopened, never revived")
-- Cross-split focus must be selected through the owning Node, not active_node.
fresh(); owner=open(); local side=node(owner):split("right",DocView(Doc()))
local editor=side.active_view; local own_node=node(owner); local count=#owners()
check(open()==owner and node(owner)==own_node and own_node.active_view==owner and core.root_view:get_active_node()==own_node
  and side.active_view==editor and #owners()==count,"same-key owner in other split reuses its legitimate Node and focus")
-- Both type transitions stay at the tab slot in its original split.
for _,fallback in ipairs({true,false,true,false}) do
  core.set_active_view(editor); unsupported=fallback
  local previous=owner; local data=owner.data; local slot=own_node:get_view_idx(owner)
  owner=open()
  check(#owners()==count and node(owner)==own_node and own_node:get_view_idx(owner)==slot and own_node.active_view==owner
    and core.root_view:get_active_node()==own_node and not node(previous) and data.invalidated
    and (fallback and owner.doc and not owner.doc:is_dirty() or not fallback and owner:is(DiffView)),
    "fallback transition " .. tostring(fallback) .. " replaces type without tab/split/focus leak")
end
unsupported=true; owner=open(); old_data=owner.data; local fallback_doc=owner.doc
check(open()==owner and owner.doc~=fallback_doc and old_data.invalidated and #owners()==count,
  "same-type fallback reuses owner with a fresh readonly document")
owner.doc=Doc(); owner.doc:insert(1,1,"dirty"); n=#owners()
check(open()~=owner and #owners()==n+1 and owner.doc:is_dirty(),"foreign dirty fallback doc cannot be reused")
-- An explicit duplicate owner reference in a second node is multiview intent.
fresh(); owner=open(); node(owner):split("right",owner); n=#owners()
check(open()~=owner and #owners()==n+1,"shared owner across two Nodes is excluded from reuse")
fresh(); owner=open(); documents.open_comparison(owner.data); n=#owners()
check(open()~=owner and #owners()==n+1 and not owner.data.invalidated,
  "data shared with explicit multiview owner is neither reused nor invalidated")
fresh(); owner=open(); node(owner):split("right",DocView(owner.panes[1].doc)); n=#owners()
check(open()~=owner and #owners()==n+1 and not owner.data.invalidated,
  "source document shared with an explicit Node owner excludes reuse")
fresh(); owner=open(); local other_node=node(owner):split("right",DocView(Doc()))
node(owner).locked={x=true}; n=#owners()
other_node.is_primary_node=true; node(owner).is_primary_node=nil
core.set_active_view(other_node.active_view)
check(open()~=owner and #owners()==n+1 and not owner.data.invalidated,
  "locked foreign host is not a reusable editor Node")
-- P01/P02 actual async boundaries, including old private captures after reuse.
for boundary=1,5 do
  fresh(); owner=open(); old_data=owner.data
  start(); for _=1,boundary do tick() end
  local pending=owner.data
  start(); start(); flush()
  check(#owners()==1 and core.active_view==owner and owner.data~=old_data and old_data.invalidated
    and acquisitions==3 and owner.data.stage and owner.data.revert,
    "rapid latest same-key browse boundary " .. boundary .. " retains one fresh ready owner")
  check(boundary<4 or pending~=owner.data and pending.invalidated and not pending.capabilities_pending
    and not pending.stage and not pending.revert and not (panel.model.staging_views or {})[pending]
    and not (panel.model.discard_views or {})[pending],
    "old pending data boundary " .. boundary .. " receives no late tokens/registrations after reuse")
end
for _,event in ipairs({"focus","Files","root","context","close","foreign"}) do
  fresh(); owner=open(); old_data=owner.data; start(); tick()
  local focus=owner
  if event=="focus" then focus=DocView(Doc()); node(owner):add_view(focus)
  elseif event=="Files" then panel:show("files"); focus=core.active_view
  elseif event=="root" then panel.model.root="/other"
  elseif event=="context" then panel.model.context={project=core.project_dir,generation=2}
  elseif event=="close" then node(owner):close_view(core.root_view.root_node,owner); core.set_active_view(panel); focus=panel
  else owner.data={foreign=true} end
  flush()
  check(event=="foreign" and owner.data.foreign and core.active_view~=owner and #owners()==2
    or event~="foreign" and owner.data==old_data and core.active_view==focus,
    "pending fresh acquisition " .. event .. " never overwrites/refocuses obsolete or foreign owner")
end
staging.ENABLED=false
fresh(); owner=open(); check(acquisitions==1 and requests==4 and not owner.data.stage and owner.data.revert,
  "production gate false retains fresh browse pipeline with discard only")
check(open()==owner and acquisitions==2 and requests==8 and #owners()==1,
  "production gate false also reuses only after another full fresh acquisition")
print(checks .. " browse native-core checks passed (native bootstrap counted once; no GUI)")
