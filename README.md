# Git panel for Lite XL

Stage, diff, commit, switch branches. Native sidebar. **Ctrl+Shift+G** to open.

![Git panel](docs/screenshots/git-panel-editor.png)

## Install

Requires Lite XL mod-version 3 + `treeview`, Git 2.25+ on PATH.
Discard/revert/remove also need Python 3.9+ on PATH. Only macOS editor integration verified.

With Claude Code (or paste the instruction into another agent):

```sh
claude "Install https://github.com/rajan-personal/lite-xl-gitpanel following its README. Confirm Lite XL is closed; ask before replacing files."
```

Quit Lite XL. Back up any existing plugin outside `USERDIR/plugins`.
Copy this repo's **`plugins/gitpanel`** to **`USERDIR/plugins/gitpanel`**, not the whole repo.
`USERDIR` is usually `~/.config/lite-xl`. Restart.

**Warning:** Discard/Revert restore tracked files from the index immediately—no confirmation or editor undo.
Untracked removal is immediate; recovery from `.git/gitpanel-recovery/` is manual. Keep backups.

**Markdown preview:** Ctrl+Shift+M opens a read-only native preview of the current
or selected Markdown file. [Usage, offline behavior & image limitations](docs/markdown-preview.md).

[Usage & safety](plugins/gitpanel/README.md) · [Limitations](FEATURES.md) · [MIT](LICENSE)
