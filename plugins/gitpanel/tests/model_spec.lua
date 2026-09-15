local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
package.path = base:match("^(.*)/plugins/gitpanel$") .. "/?.lua;" .. base:match("^(.*)/plugins/gitpanel$") .. "/?/init.lua;" .. package.path
local checks, threads, calls, log = 0, {}, {}, {}
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
local core = { project_dir = "/one", docs = {},
  error = function(_, msg) log[#log + 1] = msg end,
  log = function(...) log[#log + 1] = "log" end,
  add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
}
local stage_nags = 0
core.nag_view = { show = function() stage_nags = stage_nags + 1 end }
package.loaded.core = core
local handler
package.loaded["plugins.gitpanel.runner"] = { run = function(argv, cwd, input)
  calls[#calls + 1] = { argv = argv, cwd = cwd, input = input }
  coroutine.yield()
  return handler(argv, cwd, input)
end }
local Model = require "plugins.gitpanel.model"
local git = require "plugins.gitpanel.git"
local status_data, commit_fail, status_fail = "## main\0", false, false
local function find(argv, value) for _, a in ipairs(argv) do if a == value then return true end end end
handler = function(argv, cwd, input)
  if find(argv, "rev-parse") then return 0, cwd .. "\n", "" end
  if find(argv, "status") then
    if status_fail then return 1, "", "status unavailable" end
    return 0, status_data, ""
  end
  if find(argv, "commit") and commit_fail then return 1, "", "hook rejected message" end
  if find(argv, "diff") then return 0, "+index\n", "" end
  if find(argv, "for-each-ref") then return 0, "refs/heads/main\0\0\n", "" end
  return 0, "", ""
end
local function tick()
  for i = #threads, 1, -1 do
    local ok, err = coroutine.resume(threads[i]); assert(ok, err)
    if coroutine.status(threads[i]) == "dead" then table.remove(threads, i) end
  end
end
local function flush() for _ = 1, 200 do if #threads == 0 then return end; tick() end; error("scheduler did not finish") end
local m = Model.new()
m:bind("/one"); flush()
check(m.root == "/one" and m.status.branch == "main", "repository discovery and status serialized")
status_data = "## main\0MM partial\0"
m:refresh(false); flush()
status_fail = true
m:refresh(false); flush()
check(m.status == nil and m.refresh_error:find("status unavailable"), "failed status refresh clears stale status and fails closed")
status_fail = false
m:refresh(true); flush()
commit_fail = true
local successful = 0
m:commit("summary\n\nbody", function() successful = successful + 1 end)
flush()
check(successful == 0 and m.error:find("hook rejected") and not m.busy, "failed commit preserves draft callback and releases mutation lock")
local commit_call
for _, call in ipairs(calls) do if find(call.argv, "commit") then commit_call = call end end
check(commit_call.input == "summary\n\nbody" and not find(commit_call.argv, "-a") and not find(commit_call.argv, "--all"), "commit passes multiline stdin without worktree staging flags")
check(find(commit_call.argv, "--cleanup=whitespace"), "commit preserves comment-prefixed message lines")
m:refresh(false); flush()
check(m.error and m.error:find("hook rejected"), "periodic refresh never hides mutation failure")
m:refresh(true); flush()
check(m.error == nil, "explicit successful refresh acknowledges old failure")
local entry = m.status.changes[1]
m:stage("changes", {entry})
local queued = #m.queue
m:stage("changes", {entry})
check(#m.queue == queued and m.error:find("Another Git"), "overlapping mutations rejected rather than racing index lock")
flush()
local call = calls[#calls - 2]
local literal = false
for _, c in ipairs(calls) do if find(c.argv, "add") then literal = c.input == "partial\0" and find(c.argv, "--literal-pathspecs") end end
check(literal, "stage uses literal NUL path stream")
check(stage_nags == 0, "actual file staging runs without confirmation or preference nag")
local unstage_start = #calls
m:stage("staged", {entry}); flush()
local unstaged = false
for i = unstage_start + 1, #calls do if find(calls[i].argv, "reset") then unstaged = true end end
check(unstaged and stage_nags == 0, "actual file unstaging runs without confirmation or preference nag")
local before = #calls
m:switch("feature", false); flush()
local switched = false
for i = before + 1, #calls do if find(calls[i].argv, "switch") then switched = true end end
check(not switched and m.error:find("blocked"), "dirty worktree branch switch is blocked with explanation")
status_data = "## main\0"
core.docs = {{ abs_filename = "/one/file", is_dirty = function() return true end }}
before = #calls
m:switch("feature", false); flush()
check(m.error:find("Save editor changes"), "unsaved editor buffer prevents branch switch")
core.docs = {}
before = #calls
m:switch("feature", false)
tick() -- status subprocess in flight; editor was clean when switch requested
core.docs = {{ is_dirty = function() return true end }}
flush()
local raced_switch = false
for i = before + 1, #calls do if find(calls[i].argv, "switch") then raced_switch = true end end
check(not raced_switch and m.error:find("Save editor changes"), "edit during asynchronous branch preflight prevents switch")
core.docs = {}
m:switch("feature", false); flush()
local last_switch
for _, c in ipairs(calls) do if find(c.argv, "switch") then last_switch = c end end
check(last_switch and find(last_switch.argv, "--no-guess") and last_switch.cwd == "/one", "clean switch is local and repository-bound")
status_data = "## main\0UU conflict\0"
m:commit("cannot commit", function() successful = successful + 1 end); flush()
check(m.error:find("Resolve and stage") and successful == 0, "conflicts block commit before invoking git commit")
status_data = "## main\0"
m:commit("nothing", function() successful = successful + 1 end); flush()
check(m.error:find("index is empty"), "empty index commit is explained")
status_data = "## main\0M  partial\0"
commit_fail = false
m:commit("works", function() successful = successful + 1 end); flush()
check(successful == 1 and not m.error, "successful index commit runs success callback once")

-- In-flight read must not open an old diff after project changes.
local diff_opened = false
m:diff({path = "partial", y = "M"}, "staged", function() diff_opened = true end)
tick() -- starts process, suspended before return
core.project_dir = "/two"
m:bind("/two")
flush()
check(not diff_opened and m.root == "/two", "stale diff callback suppressed across project switch")
-- Cancel before a second subprocess in a compound mutation.
status_data = "## main\0 M partial\0"
m:refresh(false); flush()
m:stage("changes", m.status.changes)
tick() -- paused in status preflight
local marker = #calls
core.project_dir = "/three"
m:bind("/three")
flush()
local bad = false
for i = marker + 1, #calls do if find(calls[i].argv, "add") then bad = true end end
check(not bad and m.root == "/three", "project switch cancels unstarted mutation subprocess")
local old = m.context
m.context = nil
m:bind("/three")
check(not m:valid(old), "same-directory reopen invalidates old generation")
flush()
local both = git.status("## main\0RM new\0old\0")
check(git.paths(both.staged, "staged") == "new\0old\0" and git.paths(both.changes, "changes") == "new\0", "rename sides selected independently for staged and worktree actions")
check(not pcall(git.status, "## main\0 M broken"), "truncated status is rejected")
check(git.display("line\n\t\\file") == "line\\n\\t\\\\file", "display escaping never changes stored path bytes")
check(not Model.new():valid(nil), "absent project context is safely invalid")
local request_marker = #calls
m:stage("changes", {{path = "partial", y = "M"}})
m.root = "/different-root"
flush()
local bound_root
for i = request_marker + 1, #calls do if find(calls[i].argv, "add") then bound_root = calls[i].cwd end end
check(bound_root == "/three", "queued mutation captures repository root at request time")
m.root = "/three"
local comparison_opened = false
m:comparison({path = "new", x = "A", y = " "}, "staged", function() comparison_opened = true end)
tick() -- Git patch subprocess
tick() -- ls-files subprocess within compound comparison
local comparison_marker = #calls
core.project_dir = "/four"
m:bind("/four")
flush()
local stale_show = false
for i = comparison_marker + 1, #calls do if find(calls[i].argv, "show") then stale_show = true end end
check(not comparison_opened and not stale_show and m.root == "/four", "compound comparison suppresses stale callbacks and blob reads after project switch")
local captured, compare_start = nil, #calls
m:comparison({path = "new", x = "A", y = " "}, "staged", function(data) captured = data end)
m.root = "/not-the-request-root"
flush()
local bound = true
for i = compare_start + 1, #calls do if calls[i].cwd ~= "/four" then bound = false end end
check(bound and captured and captured.original == "" and captured.modified == "", "comparison captures request root across every queued source read")
check(captured and #captured.rows == 0 and captured.group == "staged", "unborn/new empty staged comparison returns honest zero-row snapshot")
local special_path_marker = #calls
package.loaded.system = { get_file_info = function() return nil, "special file" end }
local special_opened = false
m.root = "/four"
m:comparison({path = "fifo", x = "?", y = "?", status = "??"}, "untracked", function() special_opened = true end)
flush()
local special_diff = false
for i = special_path_marker + 1, #calls do if find(calls[i].argv, "diff") then special_diff = true end end
check(not special_opened and not special_diff and m.error:find("special file"), "special untracked paths are rejected before diff I/O")
package.loaded.system = nil
-- Actual one-shot destructive model protocol, without filesystem mutations.
local diff = require "plugins.gitpanel.diff"
local discard = require "plugins.gitpanel.discard"
local nags, replacements, reloads, token = 0, 0, 0, "captured-token"
local guarding = false
package.loaded["plugins.gitpanel.reloadguard"] = { begin = function()
  guarding = true
  return function() guarding = false end
end }
package.loaded["plugins.gitpanel.documents"] = {reload_clean = function() reloads = reloads + 1 end}
package.loaded["plugins.gitpanel.documents"].capture_affected = function() return {} end
package.loaded["plugins.gitpanel.documents"].invalidate_affected = function() end
package.loaded["plugins.gitpanel.documents"].affected_live = function() return false end
core.nag_view = {visible=true, show = function() nags = nags + 1 end, hide=function() error("unrelated nag must remain visible") end}
core.project_dir, core.docs = "/discard-root", {}
local dm = Model.new()
dm.root, dm.status, dm.context = core.project_dir, {}, {project=core.project_dir, generation=1}
local function fields(a, b, c) return #a .. "\n" .. a .. #b .. "\n" .. b .. #c .. "\n" .. c end
handler = function(argv)
  if argv[4] == "snapshot" then return 0, fields("old\n", "new\n", token), "" end
  if argv[4] == "replace" then assert(guarding, "reload guard must precede replacement"); replacements = replacements + 1; return 0, "discarded\n", "" end
  if find(argv, "rev-parse") then return 0, dm.root .. "\n", "" end
  if find(argv, "status") then return 0, "## main\0", "" end
  return 0, "", ""
end
local function data()
  local d = diff.build("old\n", "new\n", "@@ -1 +1 @@\n-old\n+new\n")
  d.path, d.root, d.group, d.entry = "literal\nfile", dm.root, "changes", {path="literal\nfile", x="M", y="M"}
  dm:enqueue("Prepare", false, function(context) dm:prepare_discard(d, context, dm.root) end); flush()
  return d
end
local d = data()
dm:discard(d, 1)
check(nags == 0 and dm.busy and core.nag_view.visible, "direct block schedules without showing or closing unrelated NagView")
dm:discard(d, 1)
check(dm.error:find("pending") and #dm.queue == 1, "duplicate direct block rejected while mutation queued")
flush()
check(replacements == 1 and reloads == 1 and d.invalidated and not guarding and not dm.busy and not dm.discard_pending, "direct block invalidates snapshot, reloads once and releases busy/guard state")
dm:discard(d, 1); flush()
check(replacements == 1 and dm.error:find("Stale diff"), "old snapshot refuses repeated mutation")
d = data(); dm:discard(d); tick()
core.docs = {{is_dirty=function() return true end}}; flush()
check(replacements == 1 and dm.error:find("Save editor changes") and not dm.busy and not dm.discard_pending, "dirty buffer introduced during async discard preflight prevents mutation and cleans state")
core.docs = {}; d = data(); dm:discard(d, 1); token = "changed-token"; flush()
check(replacements == 1 and dm.error:find("changed since capture"), "snapshot token checked again before direct execution")
d = data(); dm:discard(d, 1); dm.root = "/other-root"; flush()
check(replacements == 1 and dm.error:find("Project/root changed") and not dm.busy, "queued root rebind cannot redirect discard and clears busy")
dm.root = core.project_dir
d = data(); core.docs = {{is_dirty=function() return true end}}; dm:discard(d); flush()
check(replacements == 1 and not d.invalidated and not dm.busy and not dm.discard_pending, "initial dirty refusal neither schedules nor invalidates")
core.docs = {}; d = data(); dm:discard(d); flush()
check(replacements == 2 and reloads == 2 and nags == 0, "actual whole-file path dispatches directly once without NagView")
local comparison, callback = dm.comparison
dm.comparison = function(_, _, _, cb) callback = cb end
d = data(); dm:discard_file(d.entry, d.group); callback(d); callback(d); flush()
check(replacements == 3 and reloads == 3 and nags == 0, "action comparison callback schedules exactly once even when delivered twice")
dm.comparison = comparison
d = data(); dm:discard(d, 99); flush()
check(not dm.busy and not dm.discard_pending and not d.invalidated and replacements == 3, "invalid block refuses without scheduling or pending state")
d = data(); dm.status = nil; dm:discard(d); flush()
check(dm.error:find("Refresh a Git worktree") and not dm.busy and not dm.discard_pending and replacements == 3, "missing status refuses direct scheduling without a stuck operation")
dm.status = {}
local saved_handler = handler
for _, failure in ipairs({"exit", "throw"}) do
  d = data()
  handler = function(argv)
    if argv[4] == "replace" then
      assert(guarding)
      if failure == "throw" then error("injected replacement exception") end
      return 2, "", "injected replacement exit"
    end
    return saved_handler(argv)
  end
  dm:discard(d); flush()
  check(dm.error:find("injected replacement") and not guarding and not dm.busy and not dm.discard_pending and d.invalidated and reloads == 3,
    "replacement " .. failure .. " releases guard/busy and keeps stale snapshot without reload")
  handler = saved_handler
end
check(discard.eligible({status="??"}, "untracked") and not discard.eligible({x="M",y=" "}, "staged"), "recoverable untracked removal eligible; staged revert remains unavailable")
dm.root = core.project_dir
handler = function() return nil, "", "python3 executable not found" end
d = data()
check(not d.revert and d.discard_reason:find("Python3"), "missing Python3 disables only destructive action with an actionable explanation")
print(checks .. " model/protocol checks passed (mock scheduler/process).")
