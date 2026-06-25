#!/usr/bin/env bash
set -euo pipefail
# HY4: flux.md must no longer reference the removed wallabag app (content, not path).
if git grep -niq 'wallabag' -- .claude/rules/flux.md; then
  echo "FAIL: stale wallabag reference remains in .claude/rules/flux.md"; git grep -ni 'wallabag' -- .claude/rules/flux.md; exit 1
fi
# Sanity: the apps named are the live ones and exist on disk.
for app in authentik freshrss gatus homer; do
  test -d "_lib/applications/$app/overlays/dev" || { echo "FAIL: _lib/applications/$app/overlays/dev missing"; exit 1; }
done
echo "HY4 acceptance: PASSED"
