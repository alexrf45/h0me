#!/usr/bin/env bash
set -euo pipefail

# Acceptance test for punch-list item M1 (PDB coverage).
# Validates the new PodDisruptionBudget manifests for authentik, gatus, homer.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

# The kube/k8sop wrappers are zsh functions sourced from the user's profile;
# they use zsh-only syntax (${(P)var}) so they can't be sourced under bash.
# Delegate to an interactive zsh, which loads the profile and the wrapper.
kube() {
  zsh -ic "kube $*"
}

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

# NOTE: `yq` here is the Python (kislyuk/yq) jq-wrapper, not mikefarah/yq.
# It applies the jq filter to each YAML document in a multi-doc stream and has
# no `eval-all` subcommand. Filters below are jq syntax.
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

for app in authentik gatus homer; do
  dir="_lib/applications/${app}/base"
  echo "== kustomize render: ${dir} =="
  out="${render_dir}/${app}.yaml"
  kube dev kustomize "$dir" >"$out"

  # Must contain at least one PodDisruptionBudget for this app.
  pdb_count="$(yq -r 'select(.kind == "PodDisruptionBudget") | .metadata.name' "$out" 2>/dev/null \
    | grep -c . || true)"
  if [ "$pdb_count" -lt 1 ]; then
    echo "FAIL: no PodDisruptionBudget rendered for ${app}" >&2
    exit 1
  fi

  # Every PDB must target the correct namespace.
  bad_ns="$(yq -r 'select(.kind == "PodDisruptionBudget" and .metadata.namespace != "'"${NS[$app]}"'") | .metadata.name' "$out" 2>/dev/null \
    | grep -c . || true)"
  if [ "$bad_ns" -ne 0 ]; then
    echo "FAIL: ${app} PDB in wrong namespace (expected ${NS[$app]})" >&2
    exit 1
  fi

  # Every PDB must have a non-empty selector.matchLabels.
  empty_sel="$(yq -r 'select(.kind == "PodDisruptionBudget" and ((.spec.selector.matchLabels // {}) | length == 0)) | .metadata.name' "$out" 2>/dev/null \
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
