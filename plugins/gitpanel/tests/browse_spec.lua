-- Deterministic P01/P02 scheduler: real comparison/preparation, mocked awaited transport.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
package.path = base:match("^(.*)/plugins/gitpanel$") .. "/?.lua;" .. package.path
local checks, threads, requests, publications, errors, events = 0, {}, {}, {}, {}, {}
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
local core = {project_dir="/browse", docs={}}
core.add_thread = function(fn) threads[#threads+1] = coroutine.create(fn) end
core.error = function(_, message) errors[#errors+1] = message end
core.log = function() end
package.loaded.core = core
local group, fail_at, throw_at, unsupported = "changes", nil, nil, false
local mismatch, live, on_publish = {}, true, nil
local function has(argv, value) for _, a in ipairs(argv) do if a == value then return true end end end
local function pack(a,b,c) return #a .. "\n" .. a .. #b .. "\n" .. b .. #c .. "\n" .. c end
package.loaded["plugins.gitpanel.runner"] = {run=function(argv, cwd)
  local kind = argv[1] == "python3" and (argv[3]:find("discard",1,true) and "discard" or "staging")
    or has(argv,"diff") and "diff" or has(argv,"ls-files") and "index"
    or has(argv,"show") and "source" or has(argv,"rev-parse") and "root"
    or has(argv,"status") and "status" or has(argv,"for-each-ref") and "branches" or "mutation"
  requests[#requests+1] = {kind=kind, cwd=cwd}
  local number = #requests
  events[#events+1] = kind
  coroutine.yield(kind)
  if number == throw_at then error("injected transport exception") end
  if number == fail_at then return 2, "", "injected failure" end
  if kind == "diff" then return 0, group == "changes" and "@@ -1 +0,0 @@\n-old\n" or "@@ -1 +1 @@\n-old\n+new\n", "" end
  if kind == "index" then return 0, (unsupported and "120000" or "100644") .. " abc 0\tA\0", "" end
  if kind == "source" then return 0, (has(argv, "HEAD:A") or group == "changes") and "old\n" or "new\n", "" end
  if kind == "discard" or kind == "staging" then return 0, pack(mismatch[kind] == "index" and "changed\n" or "old\n", mismatch[kind] == "file" and "changed\n" or (group == "changes" and "" or "new\n"), mismatch[kind] and "changed-token" or "token"), "" end
  if kind == "root" then return 0, cwd .. "\n", "" end
  if kind == "status" then return 0, "## main\0", "" end
  if kind == "branches" then return 0, "refs/heads/main\0\0\n", "" end
  return 0, "", ""
end}
local Model = require "plugins.gitpanel.model"
local staging = require "plugins.gitpanel.staging"
staging.ENABLED = true -- test-only readiness boundary; production gate remains false
local function tick()
  assert(#threads == 1, "single FIFO worker")
  local ok, err = coroutine.resume(threads[1]); assert(ok,err)
  if coroutine.status(threads[1]) == "dead" then table.remove(threads,1) end
end
local function flush() for _=1,100 do if #threads == 0 then return end; tick() end; error("worker stuck") end
local function fresh(g)
  assert(#threads == 0)
  requests, publications, errors, events = {}, {}, {}, {}
  group, fail_at, throw_at, unsupported = g or "changes", nil, nil, false
  mismatch, live, on_publish = {}, true, nil
  core.project_dir = "/browse"
  local m=Model.new(); m.context={project=core.project_dir,generation=1}; m.root=core.project_dir; m.status={}
  return m
end
local function entry(path) return {path=path or "A",x="M",y="D"} end
local function publish(data)
  publications[#publications+1]=data; events[#events+1]="publish:" .. data.path
  if not data.unsupported then
    data.publication_inert = not data.stage and not data.revert and data.capabilities_pending == true
  end
  data.publication_requests = #requests
  if on_publish then on_publish(data) end
  return function() return live end
end
local function browse(m,path) return m:browse_comparison(entry(path),group,publish) end
local function clean(m) return not m.worker and not m.busy and not m.refreshing and #m.queue == 0 end
local m=fresh()
browse(m,"A"); browse(m,"B"); browse(m,"A")
check(#m.queue == 1, "A-B-A before execution retains only latest pending browse")
flush()
check(#requests == 5 and #publications == 1 and publications[1].path == "A", "pre-execution burst executes one pipeline and one early publication")
check(publications[1].publication_inert and publications[1].publication_requests == 3, "browse publishes inert read-only data before Python helpers")
check(publications[1].discard_snapshot and publications[1].staging_snapshot and clean(m), "P02 same published data receives both capabilities by full readiness")
print("BURST before: requests=" .. #requests .. " publications=" .. #publications .. " pending_max=1")
for _,g in ipairs({"changes","staged"}) do
  for boundary=1,5 do
    for _,failure in ipairs({"success","exit","throw"}) do
      m=fresh(g); browse(m,"A")
      for _=1,boundary do tick() end
      if failure == "exit" then fail_at=boundary elseif failure == "throw" then throw_at=boundary end
      browse(m,"B"); browse(m,"A")
      check(#m.queue == 1, g .. " " .. boundary .. " " .. failure .. " bounded pending")
      flush()
      -- P02 can already have displayed the first readonly snapshot before the
      -- newer click. It is not republished, and its late readiness is cancelled.
      local early = (g == "changes" and boundary >= 4 or g == "staged" and boundary >= 5) and 1 or 0
      check(#requests == boundary+5 and #publications == 1+early and publications[#publications].path == "A" and #errors == 0 and clean(m),
        g .. " " .. boundary .. " " .. failure .. " abandons obsolete work/errors after awaited boundary")
      print("BURST " .. g .. " boundary=" .. boundary .. " result=" .. failure .. " requests=" .. #requests .. " publications=" .. #publications .. " pending_max=1")
    end
  end
end
m=fresh(); for i=1,1000 do browse(m,i%2 == 0 and "A" or "B"); assert(#m.queue == 1) end; flush()
check(#requests == 5 and #publications == 1, "1000-request pending burst executes only one pipeline")
print("BURST 1000: requests=" .. #requests .. " publications=" .. #publications .. " pending_max=1")
m=fresh(); unsupported=true; browse(m,"A"); tick(); tick(); browse(m,"B"); browse(m,"A"); flush()
check(#requests == 4 and #publications == 1 and publications[1].unsupported and #errors == 0, "unsupported fallback honors newest browse identity")
m=fresh(); browse(m,"A"); tick(); m:cancel_browse(); flush()
check(#requests == 1 and #publications == 0 and clean(m), "explicit browse cancellation stops running work without process kill")
m=fresh(); browse(m,"A"); m:cancel_browse(); flush()
check(#requests == 0 and #publications == 0 and clean(m), "explicit cancellation removes pending browse and releases worker")
for _,position in ipairs({"before","between","after"}) do
  m=fresh()
  local executed, succeeded = 0,0
  local function mutation()
    m:mutate("test mutation",function(context,root)
      executed=executed+1
      return m:run(context,{"test-mutation"},nil,root)
    end,function() succeeded=succeeded+1 end)
  end
  if position == "before" then mutation() end
  browse(m,"A")
  if position == "between" then mutation() end
  m:branches(function() events[#events+1]="branch-callback" end)
  m:refresh(false)
  browse(m,"B"); browse(m,"A")
  if position == "after" then mutation() end
  flush()
  local order=table.concat(events,",")
  check(executed == 1 and succeeded == 1 and clean(m), "mutation " .. position .. " browse executes exactly once and releases state")
  local mp,dp=assert(order:find("mutation",1,true)),assert(order:find("diff",1,true))
  check((position == "after" and mp > dp or position ~= "after" and mp < dp)
    and order:find("branch%-callback,root,status,diff"), "mutation " .. position .. " keeps actual FIFO position with branches and refresh")
  print("ORDER " .. position .. ": " .. order)
end
m=fresh(); browse(m,"A"); tick()
local mutation_runs, mutation_successes=0,0
m:mutate("queued mutation",function(context,root)
  mutation_runs=mutation_runs+1
  return m:run(context,{"test-mutation"},nil,root)
end,function() mutation_successes=mutation_successes+1 end)
browse(m,"B"); m:refresh(false); browse(m,"A")
throw_at=1; tick() -- obsolete exception exits, then mutation awaits
check(m.busy == "queued mutation" and m.refreshing and mutation_runs == 1 and #errors == 0,
  "obsolete exception cannot clear queued mutation busy or refresh ownership")
browse(m,"B"); browse(m,"A"); flush()
check(mutation_runs == 1 and mutation_successes == 1 and #publications == 1 and #requests == 9 and clean(m),
  "supersession during running mutation preserves exactly-once mutation and queued refresh")
m=fresh(); local action=0
m:comparison(entry(),group,function(d) action=action+1; assert(d.discard_snapshot and d.staging_snapshot) end)
tick(); browse(m,"B"); browse(m,"A"); flush()
check(action == 1 and #publications == 1 and #requests == 10 and clean(m), "generic action-intent comparison retains full readiness exactly once despite newer browse")
m=fresh(); action=0; browse(m,"B")
m:comparison(entry(),group,function(d) action=action+1; assert(d.discard_snapshot and d.staging_snapshot) end)
browse(m,"A"); flush()
check(action == 1 and #publications == 1 and #requests == 10 and clean(m), "pending action-intent comparison is retained when queued browse is replaced")
m=fresh(); local nags, replacements=0,0
core.nag_view={show=function() nags=nags+1 end}
package.loaded["plugins.gitpanel.reloadguard"]={begin=function() return function() end end}
package.loaded["plugins.gitpanel.documents"]={reload_clean=function() replacements=replacements+1 end}
package.loaded["plugins.gitpanel.documents"].capture_affected = function() return {} end
package.loaded["plugins.gitpanel.documents"].invalidate_affected = function() end
package.loaded["plugins.gitpanel.documents"].affected_live = function() return false end
m:discard_file(entry(),group); tick(); browse(m,"B"); browse(m,"A"); flush()
check(nags == 0 and replacements == 1 and not m.discard_pending and #publications == 1 and clean(m), "discard-file discard-ready action survives browse supersession and executes once without NagView")
-- Private row intent skips only unused staging capture, never discard capture or
-- final preflight. Generic comparison and browse full readiness remain above.
for _,gate in ipairs({false,true}) do
  staging.ENABLED=gate
  m=fresh(); replacements=0
  local acquired
  local discard=m.discard
  m.discard=function(self,data,...) acquired=data; return discard(self,data,...) end
  m:discard_file(entry(),group); flush()
  local captures,stages=0,0
  for _,r in ipairs(requests) do
    if r.kind=="discard" then captures=captures+1 elseif r.kind=="staging" then stages=stages+1 end
  end
  check(acquired and acquired.discard_snapshot and not acquired.staging_snapshot and not acquired.stage
    and captures==3 and stages==0 and replacements==1 and clean(m) and nags==0,
    "row intent retains acquisition/preflight/replace and omits staging gate=" .. tostring(gate))
  for boundary=1,5 do
    for _,scenario in ipairs({"dirty","generation","root","failure","mismatch"}) do
      m=fresh(); replacements=0
      m:discard_file(entry(),group)
      for _=1,boundary do tick() end
      if scenario=="dirty" then core.docs={{is_dirty=function() return true end}}
      elseif scenario=="generation" then m.context.generation=m.context.generation+1
      elseif scenario=="root" then m.root="/other"
      elseif scenario=="failure" then fail_at=boundary
      else mismatch.discard="file" end
      flush(); core.docs={}
      check(replacements==0 and clean(m) and not m.discard_pending and nags==0,
        "row discard-only " .. scenario .. " refuses at await " .. boundary .. " gate=" .. tostring(gate))
    end
  end
end
staging.ENABLED=true
m=fresh(); replacements=0
m:discard_file(entry(),group); m:discard_file(entry(),group); flush()
check(replacements == 1 and nags == 0 and m.mutation_generation == 1 and clean(m) and not m.discard_pending,
  "queued duplicate file action comparisons cannot schedule two accepted mutations")
m=fresh(); replacements=0
m:discard_file(entry(),group); fail_at=1; flush()
check(replacements == 0 and #errors == 1 and clean(m) and not m.discard_pending, "failed file comparison leaves no pending or busy action")
m=fresh(); replacements=0
m:discard_file(entry(),group); tick(); core.project_dir="/other"; m:bind(core.project_dir); flush()
check(replacements == 0 and clean(m) and not m.discard_pending, "project switch cancels queued file action without stuck pending state")
for boundary=1,5 do
  m=fresh(); browse(m,"A"); for _=1,boundary do tick() end
  local old=m.context
  core.project_dir="/other"; m:bind(core.project_dir)
  core.project_dir="/browse"; m:bind(core.project_dir)
  flush()
  check(not m:valid(old) and #publications == (boundary >= 4 and 1 or 0) and (#publications == 0 or not publications[1].revert) and #requests == boundary+2 and m.root == "/browse" and clean(m), "rapid project return at boundary " .. boundary .. " invalidates generation and cleans refresh")
end
m=fresh(); browse(m,"A"); tick(); m.root="/different"; flush()
check(#requests == 1 and #publications == 0 and clean(m), "same-context root change invalidates browse only")
m=fresh(); browse(m,"A"); throw_at=1; m:refresh(false); flush()
check(#errors == 1 and #publications == 0 and clean(m) and m.status.branch == "main", "current browse exception reports once and pending refresh finishes")
m=fresh(); browse(m,"A"); fail_at=1; flush()
check(#errors == 1 and #publications == 0 and clean(m), "current browse exit error remains visible with worker cleanup")
m=fresh(); browse(m,"A"); fail_at=4; flush()
check(#errors == 0 and #publications == 1 and publications[1].discard_reason and publications[1].staging_snapshot and clean(m), "current helper failure leaves readonly publication and independent matching stage outcome")
m=fresh(); browse(m,"A"); m:refresh(false)
m:cancel_browse(); throw_at=1; flush()
check(#requests == 1 and #errors == 1 and clean(m), "refresh exception after pending browse cancellation releases its own state")
m=fresh(); m:mutate("failing mutation",function() error("mutation failure") end)
browse(m,"B"); browse(m,"A"); flush()
check(#errors == 1 and #publications == 1 and #requests == 5 and clean(m), "mutation exception still reports and releases busy before latest browse")
-- P02: no helper or capability registration on the publication critical path.
m=fresh(); browse(m,"A")
for _=1,4 do tick() end
local data=publications[1]
check(data and data.publication_requests == 3 and #requests == 4 and requests[4].kind == "discard",
  "tracked browse publishes after three Git requests before first Python await")
check(data.capabilities_pending and not data.stage and not data.revert and not m.discard_views and not m.staging_views,
  "pending browse has no action closures tokens or weak registrations")
tick()
check(data.capabilities_pending and not data.revert and not data.stage and not m.discard_views and #requests == 5,
  "discard capture stays private across staging await")
flush()
check(publications[1] == data and #publications == 1 and data.revert and data.stage and not data.capabilities_pending
  and m.discard_views[data] and m.staging_views[data], "matching captures attach once to same readonly data")
for boundary=1,5 do
  for _,event in ipairs({"close","replace","Files","newer","root","generation","invalidate","mutation"}) do
    m=fresh(); browse(m,"A"); for _=1,boundary do tick() end
    local old=publications[1]
    if event == "close" or event == "replace" then live=false
    elseif event == "Files" then m:cancel_browse()
    elseif event == "newer" then browse(m,"B")
    elseif event == "root" then m.root="/elsewhere"
    elseif event == "generation" then
      core.project_dir="/elsewhere"; m:bind(core.project_dir)
      core.project_dir="/browse"; m:bind(core.project_dir)
    elseif event == "invalidate" then
      if old then old.invalidated=true else on_publish=function(d) d.invalidated=true end end
    elseif event == "mutation" then
      m:mutate("intervening mutation", function(context,root) return m:run(context,{"test-mutation"},nil,root) end)
    end
    flush()
    -- Prior to publication a closed/replaced owner is represented by a false
    -- callback predicate; native tests below cover actual Node membership.
    old=old or (event ~= "newer" and publications[1])
    check((not old or (not old.capabilities_pending and not old.revert and not old.stage
      and not old.discard_snapshot and not old.staging_snapshot
      and not (m.discard_views or {})[old] and not (m.staging_views or {})[old])) and #errors == 0 and clean(m),
      "P02 " .. event .. " boundary " .. boundary .. " never attaches stale capabilities or registrations")
  end
end
for boundary=1,5 do
  for _,source in ipairs({"file","index"}) do
    m=fresh(); browse(m,"A"); for _=1,boundary do tick() end
    mismatch.discard, mismatch.staging = source, source
    flush(); data=publications[1]
    check(data and not data.capabilities_pending and not data.stage and not data.revert
      and not data.discard_snapshot and not data.staging_snapshot and not m.discard_views and not m.staging_views
      and data.discard_reason and data.staging_reason and #errors == 0 and clean(m),
      "changed " .. source .. " at await " .. boundary .. " prevents ALL closures and registrations without popup")
    mismatch={}; browse(m,"A"); flush()
    check(publications[2] ~= data and publications[2].stage and publications[2].revert and not data.stage and not data.revert,
      "fresh browse after " .. source .. " mismatch at await " .. boundary .. " recovers without reviving old data")
  end
end
-- Ordinary ineligibility/failure is not positive proof of a changed source.
m=fresh(); fail_at=5; browse(m,"A"); flush(); data=publications[1]
check(data.revert and not data.stage and data.staging_reason and #errors == 0,
  "ordinary staging helper refusal retains a matching discard capture")
for boundary=4,5 do
  for _,failure in ipairs({"exit","throw"}) do
    m=fresh(); browse(m,"A"); for _=1,boundary do tick() end
    if failure == "exit" then fail_at=boundary else throw_at=boundary end
    flush(); data=publications[1]
    check(#publications == 1 and data and not data.capabilities_pending and #errors == 0 and clean(m),
      "P02 helper " .. failure .. " boundary " .. boundary .. " cleans pending without popup or republishing")
  end
end
m=fresh(); on_publish=function() error("publication failed") end; browse(m,"A"); flush()
check(#requests == 3 and not publications[1].capabilities_pending and clean(m), "publication failure starts no helper and releases worker")
m=fresh(); mismatch.staging="index"; local action_data
m:comparison(entry(),group,function(d) action_data=d end); flush()
check(action_data and action_data.revert and action_data.discard_snapshot and not action_data.stage
  and action_data.staging_reason and not action_data.capabilities_pending,
  "default action-intent comparison retains independent capability outcomes and full readiness")
m=fresh(); m:browse_comparison(entry(),group,function(d) publications[1]=d end); flush()
check(#requests == 3 and not publications[1].capabilities_pending and not m.discard_views and not m.staging_views,
  "suppressed publication with no live-owner predicate starts no safety helpers")
m=fresh(); m.prepare_staging=function() error("unexpected preparation failure") end
browse(m,"A"); flush(); data=publications[1]
check(not data.capabilities_pending and not data.revert and not data.stage and not m.discard_views and #errors == 0 and clean(m),
  "unexpected readiness exception cannot leak private earlier capture or pending state")
staging.ENABLED=false
m=fresh(); browse(m,"A"); flush(); data=publications[1]
check(data.publication_requests == 3 and #requests == 4 and data.revert and not data.stage and not data.action_slots.stage,
  "production-disabled browse publishes before discard and never starts staging helper")
staging.ENABLED=false
print(checks .. " browse cancellation checks passed (deterministic mocked asynchronous transport; no GUI).")
