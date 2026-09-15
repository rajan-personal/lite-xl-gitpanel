-- Native display-list renderer. Markdown is data, never HTML or executable code.
local style = require "core.style"
local common = require "core.common"
local parser = require "plugins.gitpanel.markdown.parser"
local document = require "plugins.gitpanel.markdown.document"
local M = {}
local B, S = parser.TOKENS.BLOCK, parser.TOKENS.SPAN

function M.fonts()
  local size = style.font.get_size and style.font:get_size() or style.font:get_height()
  local fonts = { normal = style.font, code = style.code_font,
    bold = style.font:copy(size, { bold = true }),
    italic = style.font:copy(size, { italic = true }), headings = {} }
  for i, scale in ipairs({ 1.8, 1.5, 1.3, 1.15, 1.05, 1 }) do
    fonts.headings[i] = style.font:copy(size * scale, { bold = true })
  end
  return fonts
end

function M.compute(text, width, fonts, load_image)
  local items, anchors, slugs = {}, {}, {}
  local pad, gap = style.padding.x, style.padding.y
  local right, y, seen = math.max(pad + 1, width - pad), gap, width
  local function rect(x, top, w, h, color)
    items[#items + 1] = { kind = "rect", x = x, y = top, w = math.max(0, w), h = h, color = color }
  end
  local function put(text, font, x, top, color, target)
    local w, h = font:get_width(text), font:get_height()
    items[#items + 1] = { kind = "text", text = text, font = font, x = x, y = top,
      w = w, h = h, color = color, target = target }
    seen = math.max(seen, x + w + pad)
    if target then rect(x, top + h - 1, w, 1, color) end
    return w
  end
  local function inline(text, left, base)
    local x, line_h = left, base:get_height()
    local function newline() x, y, line_h = left, y + line_h, base:get_height() end
    for _, span in ipairs(parser.parse_spans(text)) do
      local font = span.style == S.CODE and fonts.code or span.style == S.BOLD and fonts.bold
        or span.style == S.ITALIC and fonts.italic or base
      local color = span.target and style.accent or span.style == S.CODE and style.syntax.string or style.text
      if span.style == S.IMAGE then
        if x > left then newline() end
        local image, reason = load_image(span.target)
        if image then
          items[#items + 1] = { kind = "image", canvas = image.canvas, x = left, y = y,
            w = image.w, h = image.h }
          seen = math.max(seen, left + image.w + pad)
          y = y + image.h + gap
        else
          -- Alt text and a reason remain readable even without canvas support.
          local label = "[Image: " .. (span.text ~= "" and span.text or span.target) .. "] " .. reason
          for word in label:gmatch("%S+%s*") do
            local w = font:get_width(word)
            if x > left and x + w > right then newline() end
            x = x + put(word, font, x, y, style.dim)
          end
          newline()
        end
      else
        for word in span.text:gmatch("%s*%S+%s*") do
          local w = font:get_width(word)
          if x > left and x + w > right then newline() end
          line_h = math.max(line_h, font:get_height())
          -- Split oversized words at UTF-8 character boundaries.
          local chunks, chunk = {}, ""
          for char in common.utf8_chars(word) do
            if chunk ~= "" and font:get_width(chunk .. char) > math.max(1, right - left) then
              chunks[#chunks + 1], chunk = chunk, ""
            end
            chunk = chunk .. char
          end
          chunks[#chunks + 1] = chunk
          for i, part in ipairs(chunks) do
            if i > 1 then newline() end
            local pw = font:get_width(part)
            if span.style == S.CODE then rect(x, y, pw, line_h, style.background2) end
            put(part, font, x, y, color, span.style == S.LINK and span.target or nil)
            if span.style == S.STRIKE then rect(x, y + line_h / 2, pw, 1, color) end
            x = x + pw
          end
        end
        -- Preserve whitespace-only spans between formatted runs.
        if span.text:match("^%s+$") then x = x + font:get_width(span.text) end
      end
    end
    y = y + line_h
  end
  for _, block in ipairs(parser.parse_blocks(text)) do
    local top = y
    if block.type == B.HEADER then
      local visible = {}
      for _, span in ipairs(parser.parse_spans(block.text)) do visible[#visible + 1] = span.text end
      local slug = document.slug(table.concat(visible))
      local count = slugs[slug] or 0
      slugs[slug] = count + 1
      anchors[slug .. (count > 0 and "-" .. count or "")] = y
      inline(block.text, pad, fonts.headings[block.arg])
    elseif block.type == B.CODE then
      local height = #block.lines * fonts.code:get_height() + gap * 2
      rect(pad, y, right - pad, height, style.background2)
      y = y + gap
      for _, line in ipairs(block.lines) do
        put(line, fonts.code, pad + gap, y, style.text)
        y = y + fonts.code:get_height()
      end
      y = y + gap
    elseif block.type == B.RULE then
      rect(pad, y + gap, right - pad, math.max(1, SCALE), style.divider)
      y = y + gap * 2
    elseif block.type == B.LIST then
      local marker = block.checked ~= nil and (block.checked and "[x]" or "[ ]")
        or block.is_ordered and tostring(block.number) .. "." or "•"
      local left = pad + math.min(block.level or 0, 8) * pad
      local marker_w = put(marker, fonts.normal, left, y, style.dim)
      inline(block.text, left + marker_w + gap, fonts.normal)
    elseif block.type == B.QUOTE then
      inline(block.text, pad * 2, fonts.normal)
      rect(pad, top, math.max(2, SCALE * 2), y - top, style.accent)
    else
      inline(block.text, pad, fonts.normal)
    end
    y = y + gap
  end
  return { items = items, anchors = anchors, height = y + gap, width = seen }
end
return M
