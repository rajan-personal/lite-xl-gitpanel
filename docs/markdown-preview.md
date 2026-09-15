# Markdown preview (issue #10)

Use **Ctrl+Shift+M** or **Git Panel: Preview Markdown** in the command palette:

- From an open `.md`, `.markdown`, `.mdown`, or `.mkd` source (case insensitive).
- From a selected file in Files, including **Preview Markdown** in its context menu.
- From a selected Git row or its comparison. This previews the **working file or
  open buffer**, not the index/HEAD version shown on a comparison side.

A separate **filename · Markdown** tab opens inside Lite XL. Repeating the command
reuses that file's preview. The source editor and normal file-opening behavior
remain unchanged. **Source** returns to the editor; **Refresh** takes a new
snapshot, preferring unsaved contents in an already-open buffer, otherwise disk.
The palette also provides **Git Panel: Markdown Source / Refresh Markdown**.
Preview does not save, reload, stage, modify undo history, or write temporary files.
There is no automatic refresh or auto-save. Closing a source tab still uses Lite
XL's normal unsaved-change handling; the preview only retains a text snapshot.

## Rendering and navigation

Native, theme-aware headings, paragraphs, bold/italic text, inline/fenced code,
lists, task markers, rules, blockquotes and clickable inline links are supported.
Text wraps when the preview pane is resized. Long code lines and images can be
scrolled horizontally. Task markers are display-only, not editing controls.

Relative links and image paths resolve against the Markdown file's directory,
including `../`, percent-encoded names and angle-bracket destinations with spaces.
Markdown links open another native preview. Heading fragments scroll to matching
headings (simple lowercase/punctuation-stripped slugs, duplicate suffixes `-1`,
`-2`, etc.; not full GitHub/Unicode slug compatibility).

HTTP(S) links open the system browser **only on click**, using argv rather than a
shell command on macOS/Linux. Other platforms report the URL for manual opening.
Local `.txt`, `.lua`, and `.json` links open as source text; other attachments are
reported for manual opening, never handed to the OS for execution. Missing files
produce an error without creating a new document. Unsafe schemes, protocol-relative
network paths, and control characters are refused.

## Images: stock Lite XL limitation

Stock mod-version 3 Lite XL has no image/canvas rendering API. It shows descriptive
image placeholders (alt text plus the reason), rather than failing the preview.

On a compatible canvas-enabled Lite XL build with
[`libraries.image`](https://github.com/adamharrison/lite-xl-image) installed,
local PNG/JPEG/GIF/BMP images render at their native dimensions. The plugin does
not install libraries or upgrade Lite XL. The upstream `imagepreview` plugin is
not required; its current version targets mod-version 4. The adapter uses its
published `canvas.new` / `set_pixels` / `renderer.draw_canvas` API.
Remote images are **never fetched**, even on these builds. SVG, animation, scaling,
and other formats are not supported. Missing, unsupported, oversized or corrupt
images show placeholders. Per-image limits: 8 MiB file size, 4096px per dimension,
4 megapixels decoded. Each preview retains at most 32 images / 8 megapixels in
total; the native decoder must still allocate an individual image before its
dimensions can be checked. Refresh retries failed images.

The optional image API is covered by mocks, **not verified on a real canvas build**.
Thus full inline image rendering is not available on the project's stock mod-3
baseline; it remains a capability-dependent portion of issue #10.

## Scope and safety

No web service, browser engine, Python dependency, JavaScript, or HTML execution is
needed to render Markdown. Raw HTML, reference links, setext headings, tables,
math, footnotes, complex nested emphasis/lists, and other unsupported syntax may
remain literal or partially styled. This is a pragmatic renderer, **not a complete
CommonMark/GFM implementation**. Do not rely on it for exact publishing fidelity.

Inputs are limited to 512 KiB, 10,000 lines and 16 KiB per line; binary/NUL input is
refused. Failed refresh retains the previous snapshot and reports the failure.
Normal native tab close/split/scroll commands apply; there is no preview text
selection/search or session restoration yet. Only the existing macOS native-core
headless environment is tested; no new platform/GUI support is claimed.

## Existing tools researched

- [LiteMark](https://github.com/Quillwyrm/LiteMark): native rendered read views;
  selected as the reusable starting point. Its auto-save/edit-swap workflow is
  deliberately **not imported**. Its documented renderer lacks links, images and
  blockquotes. Git panel vendors/adapts only its small MIT parser from commit
  `936e6875534bed6a5093a64774562d1cf812a805`, retaining the license in
  `plugins/gitpanel/markdown/LICENSE`. Changes add links/images/quotes, fence
  matching, tab preservation and emphasis fixes. No fonts or other assets copied.
- [ghmarkdown](https://github.com/lite-xl/lite-xl-plugins/blob/master/plugins/ghmarkdown.lua):
  sends the document to GitHub's Markdown API and needs a token; rejected because
  issue #10 asks for local rendering without external services.
- [Grip](https://github.com/joeyespo/grip): also uses GitHub's Markdown API in its
  standard renderer, and opens a browser rather than a native Lite XL view.
- [markdown_tools](https://github.com/Guldoman/lite-xl-markdown_tools): editing
  utilities, not a drop-in rendered preview.
- [lite-xl-image](https://github.com/adamharrison/lite-xl-image): existing local
  image decoder/canvas integration, used optionally rather than building a decoder.

## Validation

`python3 -B plugins/gitpanel/tests/run.py` includes `markdown_native.lua`.
It uses the existing real Lite XL core bootstrap with mocked rendering/process
boundaries. Focused checks cover parsing, limits, link safety/resolution, actual
command dispatch, separate source/preview tabs, dirty-buffer preservation,
refresh/reuse, narrow-pane rendering, scrolled link hit testing, missing files,
and optional image success/failure. These checks are not visual GUI acceptance.
