#!/usr/bin/env bash
set -euo pipefail

# HY2 acceptance test: no stale doc paths remain in scope, corrected targets exist.

cd "$(git rev-parse --show-toplevel)"

fail=0

# 1. No bare `global/crds` (only `_global/crds` is allowed) in scope.
if git grep -nE '(^|[^_])global/crds' -- CLAUDE.md '.claude/rules/*'; then
  echo "FAIL: stale 'global/crds' reference(s) found (should be '_global/crds')" >&2
  fail=1
fi

# 2. No deprecated talos-pve-v3.1.0 terraform path in scope.
if git grep -n 'terraform/dev/talos-pve-v3.1.0' -- CLAUDE.md '.claude/rules/*'; then
  echo "FAIL: stale 'terraform/dev/talos-pve-v3.1.0' reference(s) found" >&2
  fail=1
fi

# 3. Corrected targets exist on disk.
if ! test -d _global/crds; then
  echo "FAIL: _global/crds directory does not exist" >&2
  fail=1
fi

if ! test -f _infra/modules/talos-pve/config-export.tf; then
  echo "FAIL: _infra/modules/talos-pve/config-export.tf does not exist" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "HY2 acceptance: FAILED" >&2
  exit 1
fi

echo "HY2 acceptance: PASSED"
