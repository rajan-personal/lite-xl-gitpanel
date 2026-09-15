-- Linear, source-validated alignment from Git's zero-context unified hunks.
-- Rows reference real source lines; padding never enters a snapshot document.
local M = { MAX_BYTES = 2 * 1024 * 1024, MAX_LINES = 50000, MAX_LINE = 16384 }
local function valid_utf8(text)
  local pos = text:find("[\128-\255]")
  while pos do
    local a, b, c, d = text:byte(pos, pos + 3)
    local length = a >= 194 and a <= 223 and 2 or a >= 224 and a <= 239 and 3 or a >= 240 and a <= 244 and 4
    if not length or not b or b < 128 or b > 191 then return false end
    if length >= 3 and (not c or c < 128 or c > 191 or (a == 224 and b < 160) or (a == 237 and b > 159)) then return false end
    if length == 4 and (not d or d < 128 or d > 191 or (a == 240 and b < 144) or (a == 244 and b > 143)) then return false end
    pos = text:find("[\128-\255]", pos + length)
  end
  return true
end
function M.lines(text)
  assert(#text <= M.MAX_BYTES, "Text comparison exceeds 2 MiB per side; use Git externally.")
  assert(not text:find("\0", 1, true), "Binary data: textual comparison is unsupported.")
  assert(valid_utf8(text), "Non-UTF-8 source: textual comparison is unsupported; use Git externally.")
  local lines, pos = {}, 1
  while pos <= #text do
    local stop = text:find("\n", pos, true)
    local line = text:sub(pos, stop or #text)
    assert(#line <= M.MAX_LINE, "Text comparison contains a line over 16 KiB; use Git externally.")
    lines[#lines + 1] = line
    assert(#lines <= M.MAX_LINES, "Text comparison exceeds 50,000 lines per side; use Git externally.")
    pos = stop and stop + 1 or #text + 1
  end
  return lines
end
local function canonical(line) return line and line:gsub("\r\n$", "\n") end
function M.has_mode(patch, mode)
  patch = "\n" .. patch
  for _, prefix in ipairs({"old mode ", "new mode ", "new file mode ", "deleted file mode "}) do
    if patch:find("\n" .. prefix .. mode .. "\n", 1, true) then return true end
  end
  return patch:match("\nindex %x+%.%.%x+ " .. mode .. "\n") ~= nil
end
function M.build(original, modified, patch)
  local headers = "\n" .. patch
  assert(not headers:find("\n@@@ ", 1, true), "Combined merge diff: textual comparison is unsupported.")
  assert(not headers:find("\nBinary files ", 1, true) and not headers:find("\nGIT binary patch\n", 1, true),
    "Binary diff: textual comparison is unsupported.")
  assert(not M.has_mode(patch, "160000"), "Submodule: textual comparison is unsupported.")
  local left, right = M.lines(original), M.lines(modified)
  local rows, changes, hunks, maps = {}, {}, {}, { {}, {} }
  local a, b = 1, 1
  local function row(l, r, changed)
    rows[#rows + 1] = { l, r, changed = changed }
    if l then maps[1][l] = #rows end
    if r then maps[2][r] = #rows end
  end
  local function unchanged(n)
    assert(n >= 0, "Overlapping or stale Git hunks; refresh and retry.")
    for _ = 1, n do
      assert(left[a] and right[b] and canonical(left[a]) == canonical(right[b]),
        "Sources differ from Git's hunks (external edit or Git filter); refresh or use raw patch.")
      row(a, b); a, b = a + 1, b + 1
    end
  end
  local hunk, payload = nil, {}
  local function finish()
    if not hunk then return end
    local old, new = {}, {}
    for _, line in ipairs(payload) do
      local prefix = line:sub(1, 1)
      if prefix == "-" then old[#old + 1] = line:sub(2)
      elseif prefix == "+" then new[#new + 1] = line:sub(2)
      elseif prefix == "\\" then
        local side = hunk.last == "-" and old or new
        assert(#side > 0, "Invalid no-newline marker")
        side[#side] = side[#side]:gsub("\n$", "")
      else error("Unexpected context in zero-context Git diff") end
      if prefix == "-" or prefix == "+" then hunk.last = prefix end
    end
    assert(#old == hunk.ac and #new == hunk.bc, "Incomplete Git hunk")
    for i, line in ipairs(old) do assert(canonical(left[a+i-1]) == canonical(line), "Original source changed or filtered; refresh or use raw patch.") end
    for i, line in ipairs(new) do assert(canonical(right[b+i-1]) == canonical(line), "Modified source changed or filtered; refresh or use raw patch.") end
    changes[#changes + 1] = #rows + 1
    hunks[#hunks + 1] = { a = a, b = b, ac = #old, bc = #new, row = #rows + 1, height = math.max(#old, #new) }
    for i = 1, math.max(#old, #new) do row(i <= #old and a+i-1 or nil, i <= #new and b+i-1 or nil, true) end
    a, b = a + #old, b + #new
    hunk, payload = nil, {}
  end
  for line in (patch .. (patch:sub(-1) == "\n" and "" or "\n")):gmatch("[^\n]*\n") do
    if line:sub(1, 3) == "@@ " then
      finish()
      local as, ac, bs, bc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      assert(as, "Invalid Git hunk header")
      as, bs, ac, bc = tonumber(as), tonumber(bs), tonumber(ac) or 1, tonumber(bc) or 1
      local start_a, start_b = as + (ac == 0 and 1 or 0), bs + (bc == 0 and 1 or 0)
      assert(start_a - a == start_b - b, "Git hunk source offsets disagree")
      unchanged(start_a - a)
      hunk = { ac = ac, bc = bc }
    elseif line:sub(1, 11) == "diff --git " or line:sub(1, 13) == "diff --no-index" then
      finish()
    elseif hunk then payload[#payload + 1] = line end
  end
  finish()
  unchanged(#left - a + 1)
  assert(b == #right + 1, "Git hunks do not cover modified source; refresh or use raw patch.")
  return { original = original, modified = modified, lines = {left, right}, rows = rows, maps = maps, changes = changes, hunks = hunks, patch = patch }
end
-- Reconstruct from exact source bytes, never normalized display lines or regexes.
function M.revert(data, index)
  assert(not data.unsupported and not data.invalidated, "Stale or unsupported diff; reopen it before reverting.")
  local h = assert(data.hunks and data.hunks[index], "Select a change block first.")
  local out = {}
  for i = 1, h.b - 1 do out[#out + 1] = data.lines[2][i] end
  for i = h.a, h.a + h.ac - 1 do out[#out + 1] = data.lines[1][i] end
  for i = h.b + h.bc, #data.lines[2] do out[#out + 1] = data.lines[2][i] end
  return table.concat(out)
end
-- Index reconstruction uses complete aligned changed rows. A paired row is a
-- replacement; never stage just its addition while accidentally retaining old text.
function M.stage_rows(data, first, last, reverse)
  assert(not data.unsupported and not data.invalidated, "Stale or unsupported diff; reopen it before staging.")
  assert(first and last and first >= 1 and last <= #data.rows and first <= last, "Select changed lines first.")
  local out, count = {}, 0
  for row, item in ipairs(data.rows) do
    local selected = item.changed and row >= first and row <= last
    if selected then count = count + 1 end
    local side = ((not not selected) ~= (not not reverse)) and 2 or 1
    local line = item[side]
    if line then
      assert(#out == 0 or out[#out]:sub(-1) == "\n", "Selection would join a no-final-newline fragment; select the whole block instead.")
      out[#out + 1] = data.lines[side][line]
    end
  end
  assert(count > 0, "Selection contains no changed lines.")
  return table.concat(out)
end
-- Source selection is half-open in native byte columns. Only endpoint source
-- lines define the interval; interior alignment gaps count, outside gaps do not.
function M.selection_rows(data, side, line, col, anchor_line, anchor_col, all)
  assert(side == 1 or side == 2, "Choose a source side.")
  local count = #data.lines[side]
  assert(count > 0, "Empty source has no selectable lines; use a block action.")
  local first, last = line, anchor_line
  if all then first, last = 1, count
  else
    if first > last or (first == last and col > anchor_col) then
      first, last, col, anchor_col = last, first, anchor_col, col
    end
    if last > first and anchor_col == 1 then last = last - 1 end
  end
  assert(first >= 1 and last <= count and first <= last, "Selection is outside captured source.")
  return assert(data.maps[side][first]), assert(data.maps[side][last])
end
function M.stage_block(data, index, reverse)
  local h = assert(data.hunks and data.hunks[index], "Select a change block first.")
  return M.stage_rows(data, h.row, h.row + h.height - 1, reverse)
end
return M
