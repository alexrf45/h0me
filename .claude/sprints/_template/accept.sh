#!/usr/bin/env bash
# Acceptance test template for a sprint task.
#
# Subagents copy this into .claude/sprints/<task-id>/accept.sh and customize.
# Runs in two places: locally by the subagent loop, and in CI by
# .github/workflows/sprint-accept.yml on the PR branch.
#
# Contract:
#   - Pure static + read-only. No `kubectl apply`, no `flux reconcile`, no
#     `helm install`, no `git push`. Validation only.
#   - Exits 0 on pass, non-zero on fail. Print enough context that a human
#     reading the CI log can pinpoint the failure.
#   - Idempotent — re-running must not mutate the worktree or the cluster.
#   - Wrapper rule (CLAUDE.md): cluster reads go through `k8sop dev kubectl ...`,
#     never raw `kubectl`. In CI the wrapper isn't available, so guard any
#     cluster probe behind `if command -v k8sop >/dev/null` and skip cleanly
#     when missing.

set -euo pipefail

TASK_ID="${TASK_ID:-CHANGEME}"  # set by the subagent in the real script
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

say() { printf '\033[1;34m[accept:%s]\033[0m %s\n' "$TASK_ID" "$*"; }
fail() { printf '\033[1;31m[accept:%s FAIL]\033[0m %s\n' "$TASK_ID" "$*" >&2; exit 1; }

# 1. yamllint touched paths.
#    Replace TOUCH_PATHS with the actual list the task touches.
TOUCH_PATHS=(
  # "_lib/<area>/<file>.yaml"
)
if [[ ${#TOUCH_PATHS[@]} -gt 0 ]]; then
  say "yamllint ${TOUCH_PATHS[*]}"
  yamllint -c .yamllint.yaml "${TOUCH_PATHS[@]}" || fail "yamllint failed"
fi

# 2. kustomize render — proves the overlay/base still produces valid YAML.
#    Use kubectl's built-in kustomize (CLAUDE.md → kustomize.md).
KUSTOMIZE_TARGETS=(
  # "_lib/<area>/overlays/dev"
)
for target in "${KUSTOMIZE_TARGETS[@]}"; do
  say "kubectl kustomize $target"
  out="$(kubectl kustomize "$target")" || fail "kustomize render failed: $target"
  [[ -n "$out" ]] || fail "kustomize render empty: $target"
  # Leftover ${VAR} is fine — Flux substitutes at reconcile. But unbalanced
  # `${...` (no closing brace) indicates a typo.
  if grep -qE '\$\{[^}]*$' <<<"$out"; then
    fail "unbalanced \${...} in kustomize output: $target"
  fi
done

# 3. Manifest invariants — task-specific assertions.
#    Example: a PodMonitor exists for service X.
#    yq '.kind == "PodMonitor" and .metadata.name == "..."' <(kubectl kustomize ...)

# 4. Optional read-only cluster probe — evidence of CURRENT state, not the
#    change being made. Guarded so CI (no wrapper) skips cleanly.
if command -v k8sop >/dev/null 2>&1; then
  say "k8sop probe (read-only)"
  # k8sop dev kubectl get <resource> -n <ns> <name> -o name >/dev/null \
  #   || fail "expected resource missing"
fi

say "PASS"
