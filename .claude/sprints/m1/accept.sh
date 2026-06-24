#!/usr/bin/env bash
set -euo pipefail

# Acceptance test for punch-list item M1 (PDB coverage).
# Validates the new PodDisruptionBudget manifests for authentik, gatus, homer.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

FILES=(
  _lib/applications/authentik/base/pdb.yaml
  _lib/applications/gatus/base/pdb.yaml
  _lib/applications/homer/base/pdb.yaml
)

echo "== yamllint (default config) =="
yamllint "${FILES[@]}"

# app -> expected metadata.namespace
declare -A NS=(
  [authentik]=authentik
  [gatus]=gatus
  [homer]=homer
)

for app in authentik gatus homer; do
  dir="_lib/applications/${app}/base"
  echo "== kustomize render: ${dir} =="
  render="$(kube dev kustomize "$dir")"

  # Must contain at least one PodDisruptionBudget for this app.
  pdb_count="$(printf '%s\n' "$render" \
    | yq eval-all 'select(.kind == "PodDisruptionBudget") | .metadata.name' - 2>/dev/null \
    | grep -c . || true)"
  if [ "$pdb_count" -lt 1 ]; then
    echo "FAIL: no PodDisruptionBudget rendered for ${app}" >&2
    exit 1
  fi

  # Every PDB must target the correct namespace and have non-empty selector.matchLabels.
  bad_ns="$(printf '%s\n' "$render" \
    | yq eval-all 'select(.kind == "PodDisruptionBudget" and .metadata.namespace != "'"${NS[$app]}"'") | .metadata.name' - 2>/dev/null \
    | grep -c . || true)"
  if [ "$bad_ns" -ne 0 ]; then
    echo "FAIL: ${app} PDB in wrong namespace (expected ${NS[$app]})" >&2
    exit 1
  fi

  empty_sel="$(printf '%s\n' "$render" \
    | yq eval-all 'select(.kind == "PodDisruptionBudget" and ((.spec.selector.matchLabels // {}) | length == 0)) | .metadata.name' - 2>/dev/null \
    | grep -c . || true)"
  if [ "$empty_sel" -ne 0 ]; then
    echo "FAIL: ${app} PDB has empty selector.matchLabels" >&2
    exit 1
  fi

  echo "OK: ${app} -> ${pdb_count} PodDisruptionBudget(s), namespace ${NS[$app]}, non-empty selector"
done

echo "== read-only evidence: kube dev get pdb -A =="
kube dev get pdb -A || true

echo "ALL CHECKS PASSED"
