# Testing

From the repository root:

```sh
python3 -B plugins/gitpanel/tests/run.py
```

The runner executes all **19 registered suites sequentially**, exits nonzero if
any fails, and refuses a missing LuaJIT instead of silently skipping suites.
Python child suites use `-B` too, including the importing removal-helper tests.
Run unoptimized Python: helpers deliberately refuse optimized invocation.
No dependency installation or GUI launch is performed by the runner. If isolating
Git templates, provide a template with an empty `hooks/` directory: the commit-hook
fixture expects that directory to exist. Do not supply executable template hooks.

## Dependencies and existing resource assumptions

- `python3` (3.9+) and `luajit` on PATH, plus Git **2.28+ for tests**
  (fixtures use `git init -b`; the plugin's ordinary runtime requirement is 2.25+).
- Actual Lite XL mod-version 3 core modules, native `toolbarview`, `autoreload`
  and their dependencies at **`/Applications/Lite XL.app/Contents/Resources`**.
  These are **not bundled**. Fonts/renderer/process/scheduler boundaries are
  mocked in native-core tests.
- `native_smoke.lua` accepts a resources directory as its first argument, but
  the complete runner/bootstrapping suites do **not** expose a universal resource
  override. There is no resource environment-variable interface or portable CI
  setup promised here. The harness sets the Darwin platform explicitly.
- macOS metadata tests use native xattr/chmod tools. Linux removal-helper
  contracts alone do not establish full-suite or editor support on Linux.
  Windows is not claimed.

Plugin modules resolve from the checkout's `plugins/gitpanel` tree, and Python
helpers from paths relative to their Lua/Python callers. Preserve the repository
layout when testing. Lite XL core resources are dependencies, not a substitute
installed copy of this plugin.

## Coverage and interpretation

The suite covers runner/protocol/model behavior, browsing/layout, read-only diffs,
staged-only commits, literal Git paths, tracked discard/reload protection,
experimental staging, post-write refresh, removal-helper failure/recovery and
native removal hit/command dispatch. Git mutations, hooks and recovery data occur
only in newly created disposable fixtures with isolated Git identity/configuration;
no network or user-project mutation is required.

The byte-identical executable baseline was previously checked with Python 3.14.6
and 3.9.6. The public-layout validation passed on Python 3.14.6: **18 suites,
1659 distinct checks**, including 23 removal-helper unittest cases and nine native
filesystem probes. The 225-check native bootstrap runs six times and is counted
once, not repeatedly. One initial validation failed because its isolated empty Git
template lacked the hooks directory expected by a fixture; a corrected run with
an empty hooks directory passed without code changes. Private logs are not packaged.
These are automated/headless results, **not real GUI clicks, fresh appearance
acceptance or an authorization to enable experimental staging**.

Optional SCM integration prints an explicit **SKIP** if `plugins/scm/util.lua`
is absent; that is not a pass. Filesystem case/Unicode alias checks measure actual
volume behavior and may separately skip when lookup is distinct. Inspect all SKIP
lines and per-suite results rather than treating an aggregate count as universal
coverage. Tests enable granular staging only in memory; the shipped gate stays
false.

The added `markdown_native.lua` suite covers native Markdown preview command
routing, read-only snapshots, dirty-buffer refresh/source navigation, parser/link
safety, responsive layout and optional image API fallbacks. Image/canvas and
rendering boundaries are mocked; no real GUI or canvas-build acceptance is claimed.
See [Markdown preview](docs/markdown-preview.md).

For contributions, retain safety refusals and add focused tests using new owned
fixtures. Run the full suite and report dependencies, skips and platform accurately.
Do not submit recovery contents, private diffs, local audit logs or credentials.
