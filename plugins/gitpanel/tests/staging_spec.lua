local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
package.path = base:match("^(.*)/plugins/gitpanel$") .. "/?.lua;" .. package.path
local diff = require "plugins.gitpanel.diff"
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
local data = diff.build("a\nb\nc\nd\n", "A\nb\nC\nd\n", "@@ -1 +1 @@\n-a\n+A\n@@ -3 +3 @@\n-c\n+C\n")
check(diff.stage_block(data, 1, false) == "A\nb\nc\nd\n", "stage block preserves neighboring unstaged hunk")
check(diff.stage_block(data, 2, true) == "A\nb\nc\nd\n", "unstage block preserves neighboring staged hunk")
for _, case in ipairs({
  {"a\n", "a\nb\n", "@@ -1,0 +2 @@\n+b\n"},
  {"a\nb\n", "a\n", "@@ -2 +1,0 @@\n-b\n"},
  {"", "x", "@@ -0,0 +1 @@\n+x\n\\ No newline at end of file\n"},
  {"é\r\nold", "é\r\nβ", "@@ -2 +2 @@\n-old\n\\ No newline at end of file\n+β\n\\ No newline at end of file\n"},
}) do
  local d = diff.build(unpack(case))
  check(diff.stage_block(d, 1, false) == case[2], "block forward exact bytes")
  check(diff.stage_block(d, 1, true) == case[1], "block reverse exact bytes")
end
data.invalidated = true
check(not pcall(diff.stage_block, data, 1, false), "stale block refused")
local range = diff.build("a\nb\nc\nd\ne\n", "A\nx\ny\nb\nC\ne\n", "@@ -1 +1,3 @@\n-a\n+A\n+x\n+y\n@@ -3,2 +5 @@\n-c\n-d\n+C\n")
local function select(side,l,c,al,ac,reverse,all)
  local first,last = diff.selection_rows(range,side,l,c,al,ac,all)
  return diff.stage_rows(range,first,last,reverse)
end
check(select(1,1,1,1,1) == "A\nb\nc\nd\ne\n", "left caret selects paired replacement only, not outside gap tails")
check(select(2,1,1,1,1) == "A\nb\nc\nd\ne\n", "right caret selects same paired replacement")
check(select(1,1,1,1,1,true) == "a\nx\ny\nb\nC\ne\n", "left caret unstages paired replacement only")
check(select(2,1,1,1,1,true) == "a\nx\ny\nb\nC\ne\n", "right caret unstages same paired replacement")
check(select(2,2,1,2,1) == "a\nx\nb\nc\nd\ne\n", "unequal replacement addition tail stages without paired deletion")
check(select(1,4,1,4,1) == "a\nb\nc\ne\n", "unequal replacement deletion tail stages on left")
check(select(1,3,2,1,1) == "A\nx\ny\nb\nC\nd\ne\n", "cross-hunk source range includes intervening gap additions but not outside deletion tail")
check(select(2,6,1,5,1) == "a\nb\nC\nd\ne\n", "end column one excludes endpoint and its intervening outside deletion gap")
check(select(2,6,2,5,1) == "a\nb\nC\ne\n", "including following source line includes intervening deletion gap")
check(select(1,1,1,3,2) == select(1,3,2,1,1), "reverse selection endpoints have identical half-open meaning")
check(select(2,2,1,2,1,true) == "A\ny\nb\nC\ne\n", "unstage selected addition tail preserves other staged rows")
check(select(1,4,1,4,1,true) == "A\nx\ny\nb\nC\nd\ne\n", "unstage selected deletion tail restores only its HEAD line")
check(select(1,1,1,1,1,false,true) == range.modified, "select all maps entire nonempty source including interior gaps")
check(not pcall(select,1,2,1,2,1), "unchanged-only selection refuses mutation")
local empty = diff.build("", "new\n", "@@ -0,0 +1 @@\n+new\n")
check(not pcall(diff.selection_rows,empty,1,1,1,1,1), "empty source cannot select opposite-only gap; use block")
local eof = diff.build("old", "new\nextra\n", "@@ -1 +1,2 @@\n-old\n\\ No newline at end of file\n+new\n+extra\n")
check(not pcall(diff.stage_rows,eof,2,2,false), "partial EOF addition cannot join unterminated original line")
local exact = diff.build("é\r\nold\r\ntail", "β\r\nNEW\r\ntail", "@@ -1,2 +1,2 @@\n-é\r\n-old\r\n+β\r\n+NEW\r\n")
check(diff.stage_rows(exact,2,2,false)=="é\r\nNEW\r\ntail", "selected row preserves exact UTF8/CRLF and untouched missing-final-newline")
print(checks .. " staging reconstruction checks passed")
