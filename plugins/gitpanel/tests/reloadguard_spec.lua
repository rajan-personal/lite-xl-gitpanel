-- Reuse the native-core harness, then load the ACTUAL installed autoreload
-- plugin. Only watcher, disk and scheduler are controlled; no GUI/files are used.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local command = require "core.command"
local config = require "core.config"
local Model = require "plugins.gitpanel.model"
local documents = require "plugins.gitpanel.documents"
local diff = require "plugins.gitpanel.diff"
local runner = require "plugins.gitpanel.runner"
local checks, clock, jobs, warnings = 0, 10, {}, {}
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
core.warn = function(_, message) warnings[#warnings + 1] = message or "warn" end
core.project_dir, core.project_directories, core.docs = "/fixture", {}, {}
system.get_time = function() return clock end
core.add_thread = function(fn)
  local job = {co=coroutine.create(fn)}
  jobs[#jobs + 1] = job
  return job
end
local function step(job)
  if coroutine.status(job.co) ~= "dead" then local ok, err = coroutine.resume(job.co); assert(ok, err) end
end
local function tick()
  local count = #jobs -- new threads start on the following frame, as in core
  for i = 1, count do step(jobs[i]) end
end
local disk, mtimes = {}, {}
local real_open = io.open
io.open = function(path, mode)
  if disk[path] == nil then return real_open(path, mode) end
  assert(mode == "rb", "fixture disk writes must be explicit")
  local bytes, position = disk[path], 1
  return {close=function() end, lines=function()
    return function()
      if position > #bytes then return end
      local stop = bytes:find("\n", position, true)
      local line = bytes:sub(position, stop and stop - 1 or #bytes)
      position = stop and stop + 1 or #bytes + 1
      return line
    end
  end}
end
system.get_file_info = function(path) return disk[path] and {type="file", modified=mtimes[path], size=#disk[path]} end
local watcher = {}
local dirwatch = {}
function dirwatch.new() return setmetatable(watcher, {__index=dirwatch}) end
function dirwatch:watch() end
function dirwatch:check(callback)
  local event = self.event
  self.event = nil
  if event then callback(event) end
end
package.loaded["core.dirwatch"] = dirwatch
require "plugins.autoreload"
require "core.commands.doc"
local function text(doc) return table.concat(doc.lines) end
local function fixture(name)
  local path = "/fixture/" .. name
  disk[path], mtimes[path] = "old\n", clock
  local doc = Doc(path, path)
  core.docs[#core.docs + 1] = doc
  core.set_active_view(DocView(doc))
  return doc, path
end
local function notify(path)
  mtimes[path] = mtimes[path] + 1
  watcher.event = path
  watcher:check(function() end)
end
local function cancel()
  check(core.nag_view.visible and core.nag_view.hovered_item == 1, "protected reload confirmation defaults to Cancel")
  command.perform("dialog:select")
end
local function approve()
  command.perform("dialog:next-entry"); command.perform("dialog:select")
end

local doc, path = fixture("race.txt")
local model = Model.new()
model.context, model.root, model.status = {project=core.project_dir}, core.project_dir, {}
model.refresh = function() end
model.discard_snapshot = function() return {token="source"} end
local data = diff.build("index\n", "old\n", "@@ -1 +1 @@\n-index\n+old\n")
data.path, data.root, data.group, data.context = "race.txt", model.root, "changes", model.context
data.discard_snapshot = {token="source"}
local timer, mutation, late_doc, replace_failure
local during_replace = function() end
runner.run = function(argv)
  assert(argv[4] == "replace", "test must reach the actual production replacement boundary")
  disk[path] = "index\n" -- asynchronous filesystem replacement before completion
  notify(path) -- installed autoreload queues its real delayed_reload coroutine
  timer = jobs[#jobs]
  step(timer) -- timer yields for its documented one-second debounce
  during_replace()
  coroutine.yield() -- replacement result/completion has not arrived yet
  if replace_failure then error("fixture replacement failure") end
  return 0, "discarded\n", ""
end
local function start()
  data.invalidated = nil
  model:discard(data, 1)
  mutation = jobs[#jobs]
  step(mutation)
end
start()
assert(not model.error, model.error)
check(disk[path] == "index\n" and text(doc) == "old\n", "actual model replacement notifies installed autoreload before completion")
step(mutation) -- real success callback calls documents.reload_clean
check(text(doc) == "index\n" and not doc:is_dirty(), "immediate clean reload runs before outstanding autoreload timer")
doc:insert(1, 1, "typed ")
local undo, redo, undo_idx = doc.undo_stack, doc.redo_stack, doc.undo_stack.idx
clock = clock + 2
step(timer)
check(text(doc) == "typed index\n" and doc:is_dirty() and doc.undo_stack == undo and doc.redo_stack == redo and undo.idx == undo_idx,
  "delayed actual autoreload cannot erase text or undo history typed after immediate reload")
tick()
cancel()
watcher.event = path; watcher:check(function() end); tick()
check(not core.nag_view.visible and not doc.deferred_reload, "autoreload acknowledges mtime without repeated nags after protected Cancel")
-- Intentional installed manual reload must remain available, with fresh approval.
command.perform("doc:reload"); tick()
check(core.nag_view.title == "Reload protected file?", "installed manual Reload reaches the guarded boundary")
doc:insert(1, 1, "newer ")
local edited = text(doc)
approve()
check(text(doc) == edited and doc.undo_stack == undo and doc:is_dirty(), "editing during confirmation invalidates approval rather than erasing newer edits")
check(not core.nag_view.visible and #warnings > 0, "stale reload approval warns without an automatic nag/retry loop")
command.perform("doc:reload"); tick(); approve()
check(text(doc) == "index\n" and not doc:is_dirty() and doc.undo_stack ~= undo, "fresh explicitly approved manual Reload still restores disk and clears undo")

doc:insert(1, 1, "pending ")
command.perform("doc:reload"); tick()
local pending_text, pending_index = text(doc), doc.undo_stack.idx
clock = clock + 2
doc:insert(1, 1, "transient "); doc:undo()
check(text(doc) == pending_text and doc.undo_stack.idx == pending_index, "fixture returns to identical text/change ID after an edit and undo")
approve()
check(text(doc) == pending_text and doc:is_dirty() and doc.redo_stack.idx > 1, "reload approval also rejects changed undo/redo history when text/change ID are reused")
command.perform("doc:reload"); tick(); approve()

-- User types while the helper is still in flight, not just after clean reload.
during_replace = function() doc:insert(1, 1, "in flight ") end
start()
undo, undo_idx = doc.undo_stack, doc.undo_stack.idx
step(mutation)
check(text(doc) == "in flight index\n" and doc.undo_stack == undo, "completion skips dirty document edited during in-flight replace")
clock = clock + 2; step(timer); tick(); cancel()
check(text(doc) == "in flight index\n" and doc.undo_stack == undo and undo.idx == undo_idx, "in-flight edits and undo survive installed delayed timer plus Cancel")

-- Dirty-at-notification uses autoreload's OWN native File Changed nag first.
notify(path)
check(core.nag_view.title == "File Changed", "installed dirty-file watcher presents its native confirmation")
command.perform("dialog:select-yes")
check(not core.nag_view.visible and not doc.deferred_reload, "native Yes completes its callback/bookkeeping before protective prompt appears")
tick()
check(core.nag_view.title == "Reload protected file?", "native autoreload Yes cannot bypass fresh Cancel-default dirty-buffer protection")
cancel()
watcher.event = path; watcher:check(function() end); tick()
check(not core.nag_view.visible and text(doc) == "in flight index\n", "native prompt nesting does not cause infinite nags or unsafe followup reload")

-- An affected document opened while replacement is running is also guarded.
local guard = require "plugins.gitpanel.reloadguard"
local release = guard.begin("/fixture", "late.txt")
late_doc = fixture("late.txt")
late_doc:insert(1, 1, "late ")
late_doc:reload(); tick(); cancel() -- while the path lease is live
release(); release() -- cleanup is idempotent
late_doc:reload(); tick(); cancel() -- object protection outlives the lease
check(text(late_doc) == "late old\n", "new in-flight document stays protected after path lease cleanup")
-- Capture a newly opened doc at completion even if it never called reload yet.
release = guard.begin("/fixture", "finish.txt")
local finish_doc = fixture("finish.txt")
release()
finish_doc:insert(1, 1, "finish "); finish_doc:reload(); tick(); cancel()
check(text(finish_doc) == "finish old\n", "completion captures newly opened affected docs before dropping the path lease")
-- Future/unrelated objects receive native behavior; there is no permanent path registry.
local fresh = fixture("late.txt")
fresh:insert(1, 1, "unprotected "); fresh:reload()
check(text(fresh) == "old\n" and not core.nag_view.visible, "released path lease does not change reload policy for future document objects")
local unrelated = fixture("unrelated.txt")
unrelated:insert(1, 1, "unrelated "); unrelated:reload()
check(text(unrelated) == "old\n", "unrelated document reload is unchanged")
core.set_active_view(DocView(late_doc))
late_doc:reload(); tick()
core.project_dir = "/other"
approve()
check(text(late_doc) == "late old\n", "project change during protective confirmation cancels reload")
core.project_dir = "/fixture"
-- SCM's installed utility is the other reload caller outside core/autoreload.
local scm_file = real_open(USERDIR .. "/plugins/scm/util.lua", "rb")
if scm_file then
  scm_file:close()
  require("plugins.scm.util").reload_doc(late_doc.abs_filename); tick(); cancel()
  check(text(late_doc) == "late old\n", "installed SCM utility cannot bypass the affected-document guard")
else
  print("SKIP installed SCM reload integration: plugins/scm/util.lua is unavailable (core/autoreload checks remain mandatory)")
end
-- The watcher timer owns the doc object, even if Save As changes its filename.
local renamed = "/fixture/renamed.txt"
disk[renamed], mtimes[renamed] = "renamed disk\n", clock
late_doc:set_filename(renamed, renamed)
late_doc:reload(); tick(); cancel()
check(text(late_doc) == "late old\n", "object protection survives filename changes while old timers can still reference it")
late_doc:reload(); tick()
for i, open in ipairs(core.docs) do if open == late_doc then table.remove(core.docs, i); break end end
approve()
check(text(late_doc) == "late old\n", "closing a doc during reload confirmation prevents later approved replacement")
-- Failed replacement must also release the temporary path lease.
core.docs = {}
doc, path = fixture("race.txt")
during_replace, replace_failure = function() end, true
start(); step(mutation)
check(model.error and model.error:find("fixture replacement failure", 1, true), "actual model reports failed in-flight replacement")
local after_failure = fixture("race.txt")
after_failure:insert(1, 1, "fresh "); after_failure:reload()
check(text(after_failure) == "old\n", "failed replacement releases path lease without retaining future document objects")
-- Guard lifetime is weak: closed docs are not retained by a global registry.
core.docs, core.active_view, core.last_active_view = {}, {}, {}
local weak = setmetatable({}, {__mode="v"})
do
  local collected = fixture("collected.txt")
  release = guard.begin("/fixture", "collected.txt"); release()
  weak[1] = collected
end
core.docs, core.active_view, core.last_active_view = {}, {}, {}
collectgarbage(); collectgarbage()
check(weak[1] == nil, "closed affected documents can be garbage collected")
io.open = real_open
print(checks .. " reloadguard/installed-autoreload checks passed (plus native harness bootstrap; no GUI/filesystem writes).")
