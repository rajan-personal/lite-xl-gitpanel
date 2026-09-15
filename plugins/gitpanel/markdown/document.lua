-- Read-only Markdown inputs and link resolution; never save, execute or fetch.
local M = { max_bytes = 512 * 1024, max_lines = 10000, max_line = 16384 }
function M.is_markdown(path)
  local ext = type(path) == "string" and path:lower():match("%.([^./\\]+)$")
  return ext == "md" or ext == "markdown" or ext == "mdown" or ext == "mkd"
end
function M.validate(text)
  if #text > M.max_bytes then return nil, "Markdown preview limit: 512 KiB." end
  if text:find("%z") then return nil, "Binary Markdown cannot be previewed." end
  local count = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    count = count + 1
    if count > M.max_lines then return nil, "Markdown preview limit: 10,000 lines." end
    if #line > M.max_line then return nil, "Markdown preview limit: 16 KiB per line." end
  end
  return text
end
function M.read(path, docs, system)
  -- Prefer unsaved editor contents, without saving or reloading the Doc.
  for _, doc in ipairs(docs) do
    if doc.abs_filename == path then
      return M.validate(doc:get_text(1, 1, math.huge, math.huge))
    end
  end
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then return nil, "Markdown source is missing or is not a regular file." end
  if info.size and info.size > M.max_bytes then return nil, "Markdown preview limit: 512 KiB." end
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local text, read_error = file:read(M.max_bytes + 1)
  file:close()
  if not text and read_error then return nil, read_error end
  return M.validate(text or "")
end
local function decode(value)
  return (value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end
function M.resolve(source, target)
  if type(target) ~= "string" or target == "" or target:find("[%z\1-\31\127]") then
    return nil, "Empty or unsafe link. Encode spaces as %20 (or use angle-bracket destinations)."
  end
  -- No shell, file:, data:, javascript:, command:, protocol-relative or UNC URLs.
  local scheme = target:match("^([%a][%w+.-]*):")
  if scheme then
    if (scheme:lower() == "https" or scheme:lower() == "http") and target:match("^%a+://[^/]+") and not target:find("%s") then
      return { kind = "url", path = target }
    end
    return nil, "Unsupported link scheme: " .. scheme
  end
  if target:match("^//") or target:find("\\", 1, true) then return nil, "Network/backslash paths are not supported." end
  local path, anchor = target:match("^([^#]*)#?(.*)$")
  path, anchor = decode(path), decode(anchor)
  if path:find("[%z\1-\31\127]") or path:find("\\", 1, true) or path:match("^//")
    or path:match("^%a[%w+.-]*:") then return nil, "Unsafe local link." end
  if path == "" then return { kind = "anchor", path = source, anchor = anchor } end
  if path:sub(1, 1) ~= "/" then path = (source:match("^(.*)/") or ".") .. "/" .. path end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then table.remove(parts)
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return { kind = "file", path = "/" .. table.concat(parts, "/"), anchor = anchor }
end
function M.slug(text)
  return text:lower():gsub("[^%w_%-%s\128-\255]", ""):gsub("%s", "-")
end
return M
