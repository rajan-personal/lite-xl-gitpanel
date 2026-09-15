-- Native core boundaries; no GUI/network. Uses the shared bootstrap explicitly.
local base = assert(arg[0]:match("^(.*)/tests/[^/]+$"))
dofile(base .. "/tests/native_smoke.lua")
local core = require "core"
local system = require "system"
local command = require "core.command"
local Doc, DocView = require "core.doc", require "core.docview"
local RootView = require "core.rootview"
local md = require "plugins.gitpanel.markdown"
local parser = require "plugins.gitpanel.markdown.parser"
local document = require "plugins.gitpanel.markdown.document"
local panel, tree = require "plugins.gitpanel", require "plugins.treeview"
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1; print("PASS " .. label) end
local B, S = parser.TOKENS.BLOCK, parser.TOKENS.SPAN
local blocks = parser.parse_blocks("# Heading\r\n\nparagraph\ncontinued\n\n> quote\n- list\n2. numbered\n~~~lua\n\tcode\n```\n~~~~\n")
check(blocks[1].type == B.HEADER and blocks[1].text == "Heading", "CRLF headings parsed")
check(blocks[2].text == "paragraph continued" and blocks[3].type == B.QUOTE, "paragraph runs and blockquotes")
check(blocks[4].type == B.LIST and blocks[5].number == 2, "ordered and unordered lists")
check(blocks[6].type == B.CODE and blocks[6].lines[1] == "\tcode" and blocks[6].lines[2] == "```", "fences preserve tabs and only close matching fence kind/length")
local spans = parser.parse_spans('**bold** _italic_ __bold__ `![not image](x)` ![alt](<img a.png>) [link](dir/a(b).md)')
local found = {}
for _, span in ipairs(spans) do found[span.style] = span end
check(found[S.BOLD] and found[S.ITALIC] and found[S.CODE].text == "![not image](x)", "emphasis and literal inline code")
check(found[S.IMAGE].target == "img a.png" and found[S.LINK].target == "dir/a(b).md", "images and balanced link destinations")
check(parser.parse_blocks("unclosed\n```\nraw\n")[2].lines[1] == "raw", "unclosed code fence degrades to code")
check(document.is_markdown("/p/README.MD") and document.is_markdown("/p/a.markdown") and not document.is_markdown("a.md.lua"), "Markdown extensions are case insensitive and exact")
local target = assert(document.resolve("/p/docs/readme.md", "../images/a%20b.png"))
check(target.path == "/p/images/a b.png" and target.kind == "file", "relative percent-encoded paths resolve against source, not project cwd")
check(document.resolve("/p/a.md", "<bad>").kind == "file", "ordinary local names remain literal data")
check(document.resolve("/p/a.md", "img a.png").path == "/p/img a.png", "angle-bracket destination spaces supported")
for _, bad in ipairs({ "javascript:alert(1)", "data:x", "file:///tmp/a", "command:delete", "//server/a", "\\\\server\\a", "%00bad", "%0abad", "%2f%2fserver/a", "https://host/\nattack", "%6aavascript:bad" }) do
  check(not document.resolve("/p/a.md", bad), "refuses unsafe destination " .. bad:gsub("\n", "\\n"))
end
check(document.resolve("/p/a.md", "https://example.com/a").kind == "url", "HTTP links classified without being opened")
check(document.resolve("/p/a.md", "#heading").anchor == "heading", "local anchors classified")
check(document.validate("") == "" and not document.validate("x\0y"), "empty accepted and binary refused")
check(not document.validate(("a\n"):rep(10001)) and not document.validate(("a"):rep(16385))
  and not document.validate(("a"):rep(512 * 1024 + 1)), "line, per-line and total input bounds")

local errors = {}
core.error = function(message, ...) errors[#errors + 1] = string.format(message, ...) end
core.root_view = RootView(); core.root_view.root_node.is_primary_node = true
core.root_view.root_node:split("left", panel, {x = true}, true)
core.root_view.root_node.size.x, core.root_view.root_node.size.y = 1200, 800
local doc = Doc()
doc.filename, doc.abs_filename = "README.md", "/fixture/README.md"
doc:insert(1, 1, "# Heading\n\n**bold** and *italic* [next](next.md#next)\n\n> quoted\n\n- item\n1. one\n\n```lua\nprint('ok')\n```\n\n![diagram](img.png)\n\n<table>unsupported HTML</table>\n")
core.docs = { doc }
local source = core.root_view:open_doc(doc)
local before, change = doc:get_text(1, 1, math.huge, math.huge), doc:get_change_id()
local saves = 0
doc.save = function() saves = saves + 1; error("preview must not save") end
system.get_file_info = function(path)
  if path == "/fixture/img.png" or path == "/fixture/README.md" then return {type = "file", size = 12} end
end
check(command.perform("git-panel:preview-markdown"), "palette command works from Markdown source")
local preview = core.active_view
check(preview:is(md.Preview) and not preview.doc and preview.text == before, "preview is separate native View snapshot including dirty text")
check(core.root_view.root_node:get_node_for_view(source) ~= nil and saves == 0 and doc:is_dirty() and doc:get_change_id() == change,
  "source tab, dirty state, undo identity and contents survive preview")
preview.size.x, preview.size.y = 500, 400
preview:update(); preview:draw()
local drawtext, links = {}, 0
for _, item in ipairs(preview.display.items) do
  if item.text then drawtext[#drawtext + 1] = item.text end
  if item.target then links = links + 1 end
end
check(table.concat(drawtext):find("Requires Lite XL canvas", 1, true) and links > 0, "stock renderer gets readable image fallback and link hit targets")
check(table.concat(drawtext):find("<table>unsupported HTML</table>", 1, true), "unsupported HTML stays literal; never executed")
local old = preview.display
preview.size.x = 200; preview:update(); preview:draw()
check(preview.display ~= old and preview.display.height >= old.height, "narrow pane reflows paragraphs")
for _, width in ipairs({0, 1, 35, 80, 800}) do
  preview.size.x = width; preview:update(); preview:draw()
end
check(true, "zero/narrow/wide panes draw without negative rectangles")
preview.size.x = 500; preview:update()
preview:follow("#heading")
check(preview.scroll.to.y == preview.display.anchors.heading, "heading link scrolls within native preview")
preview.scroll.x, preview.scroll.y = 0, 20
local item
for _, entry in ipairs(preview.display.items) do if entry.target then item = entry; break end end
local ox, oy = preview:get_content_offset()
local action, link = preview:hit(ox + item.x + 1, oy + preview:header_height() + item.y + 1)
check(action == "link" and link == item.target, "scrolled hit coordinates match rendered links")
check(not preview:hit(-100, -100), "outside preview cannot activate clipped link")
local viewcount = #core.root_view.root_node:get_children()
md.open(doc.abs_filename)
check(core.active_view == preview and #core.root_view.root_node:get_children() == viewcount, "reopening same file reuses its preview tab")
doc:insert(1, 1, "new text\n\n")
check(preview.text == before, "preview remains explicit snapshot until refresh")
preview:refresh()
check(preview.text == doc:get_text(1, 1, math.huge, math.huge) and saves == 0, "refresh reads dirty buffer without reload/save")
preview:source()
check(core.active_view == source and source:is(DocView), "Source returns to native source editor, not preview")
check(core.root_view:open_doc(doc) == source, "normal open_doc workflow still resolves to source")
core.set_active_view(preview)
preview:follow("javascript:bad")
check(errors[#errors]:find("Unsupported link scheme", 1, true), "unsafe link reports actionable error")
preview:follow("missing.md")
check(errors[#errors]:find("missing", 1, true) and core.active_view == preview, "missing relative Markdown neither creates doc nor changes focus")
local nextdoc = Doc(); nextdoc.filename, nextdoc.abs_filename = "next.md", "/fixture/next.md"
nextdoc:insert(1, 1, "# Next\n")
core.docs[#core.docs + 1] = nextdoc
preview:follow("next.md#next")
check(core.active_view:is(md.Preview) and core.active_view.path == nextdoc.abs_filename
  and core.active_view.scroll.to.y == core.active_view.display.anchors.next, "relative Markdown link opens preview and resolves heading")
core.set_active_view(panel); panel.mode = "git"
panel.model.root = "/fixture"
panel.list.rows = {{key="md", entry={path="README.md"}}}; panel.list.selected = "md"
check(command.perform("git-panel:preview-markdown") and core.active_view == preview, "Git selection opens working-buffer preview")
panel.mode = "files"; tree.selected_item = {type="file", abs_filename=doc.abs_filename}; tree.hovered_item = nil
core.set_active_view(tree)
check(command.perform("git-panel:preview-markdown") and core.active_view == preview, "Files selection opens Markdown preview")
core.set_active_view(panel.composer)
check(not command.perform("git-panel:preview-markdown"), "composer does not reuse stale file selection")

-- Capability adapter follows lite-xl-image's published canvas API; no native DLL loaded.
canvas = { new = function(w, h) return {set_pixels=function(_, bytes, x, y, pw, ph) assert(bytes=="rgba" and pw==w and ph==h) end} end }
renderer.draw_canvas = function() end
package.loaded["libraries.image"] = { load = function(path)
  assert(path == "/fixture/img.png")
  return {width=20,height=10,save=function(_, opts) assert(opts.channels==4); return "rgba" end}
end }
preview.images = {}
local image = preview:load_image("img.png")
check(image and image.w == 20 and image.h == 10, "optional image/canvas API bridge creates drawable local image")
local remote, reason = preview:load_image("https://example.com/image.png")
check(not remote and reason:find("not fetched",1,true), "remote images never cause background network requests")
preview.display=nil; preview:update(); preview:draw()
package.loaded["libraries.image"].load = function() error("bad image") end
preview.images = {}
local bad, message = preview:load_image("img.png")
check(not bad and message:find("Cannot decode",1,true), "corrupt image gracefully becomes placeholder")
package.loaded["libraries.image"].load = function() return {width=9999,height=1} end
preview.images = {}
check(not preview:load_image("img.png"), "oversized decoded image rejected before canvas allocation")
preview.images, preview.image_count = {}, 32
local limited, limit_reason = preview:load_image("img.png")
check(not limited and limit_reason:find("budget", 1, true), "aggregate image budget bounds retained decoded content")
canvas, renderer.draw_canvas = nil, nil
local opened
require("plugins.gitpanel.runner").run = function(argv) opened = argv; return 0, "", "" end
core.add_thread = function(fn) fn() end
preview:follow("https://example.com/$(touch%20x)")
check(opened and opened[1] == "open" and opened[2] == "https://example.com/$(touch%20x)", "HTTP click passes a literal argv URL, never shell interpolation")
local file = os.tmpname()
local bytes = "# Disk snapshot\r\n\n![missing](none.png)\n"
local out = assert(io.open(file, "wb")); out:write(bytes); out:close()
local disk = assert(document.read(file, {}, {get_file_info=function() return {type="file",size=#bytes} end}))
local input = assert(io.open(file, "rb")); local after = input:read("*a"); input:close(); os.remove(file)
check(disk == bytes and after == bytes, "real disk preview acquisition preserves exact source bytes")
local before_failure = preview.text
core.docs = {}
preview:refresh()
check(preview.text == before_failure, "failed refresh preserves previous snapshot")
check(saves == 0 and doc:is_dirty(), "all preview/navigation/refresh/image paths leave edits unsaved")
print(checks .. " Markdown native checks passed (mock renderer/image boundary; no GUI).")
