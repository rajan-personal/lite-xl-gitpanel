# Handoff: Issue #6

PR: https://github.com/rajan-personal/lite-xl-gitpanel/pull/11
Branch: `fix/issue-6-redirected-git-environment`

Panel Git commands and mutation helpers share `git_env.py`'s environment policy,
so inherited Git redirects cannot make their repository/index reads disagree.
Python 3.9+ is now required for all Git operations.

Validation: `python3 -B plugins/gitpanel/tests/run.py` — 18 PR suites passed.
Regressions cover alternate-index and foreign-repository redirects through the
production model/runner. Optional installed SCM integration is skipped when
`plugins/scm/util.lua` is unavailable; no GUI acceptance is claimed.

Next: review/merge PR #11. Preserve the unrelated, uncommitted Markdown-preview
code, tests and documentation; they are excluded from this PR.
