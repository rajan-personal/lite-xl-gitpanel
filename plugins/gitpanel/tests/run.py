#!/usr/bin/env python3
"""Run every suite from any cwd; no GUI, network, or user repository writes."""
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
lua = shutil.which("luajit")
if not lua:
    sys.exit("ERROR: luajit is required; no suites skipped")
suites = ["runner_spec.lua", "model_spec.lua", "browse_spec.lua", "native_smoke.lua", "diff_spec.lua",
          "browse_native.lua", "scm_layout_native.lua", "scm_panel_native.lua", "reloadguard_spec.lua", "integration.py", "comparison_integration.py", "discard_integration.py",
          "staging_spec.lua", "staging_integration.py", "staging_native.lua", "refresh_integration.py", "remove_integration.py", "remove_ui_integration.py", "markdown_native.lua"]
failed = []
for name in suites:
    print("\n=== " + name + " ===", flush=True)
    argv = [lua] if name.endswith(".lua") else [sys.executable, "-B"]
    result = subprocess.run(argv + [str(HERE / name)])
    if result.returncode:
        failed.append(name)
print("\nSUITES: %d passed, %d failed; optional integration SKIP lines above are not passes" % (len(suites)-len(failed), len(failed)), flush=True)
sys.exit(bool(failed))
