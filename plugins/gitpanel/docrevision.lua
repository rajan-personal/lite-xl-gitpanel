-- Pure native document revision identity; selection is deliberately not an edit.
local M = {}
function M.capture(doc)
  local undo, redo = doc.undo_stack, doc.redo_stack
  -- A change ID alone can be reused after undo. Include text and both native
  -- history stacks/tops so a new edit or undo/redo cannot reuse old approval.
  return { text = doc:get_text(1, 1, math.huge, math.huge), filename = doc.filename,
    undo_stack = undo, redo_stack = redo,
    undo_index = undo.idx, redo_index = redo.idx,
    undo_top = undo[undo.idx - 1], redo_top = redo[redo.idx - 1] }
end
function M.unchanged(doc, before)
  local after = M.capture(doc)
  for key, value in pairs(before) do if after[key] ~= value then return false end end
  for key, value in pairs(after) do if before[key] ~= value then return false end end
  return true
end

return M
