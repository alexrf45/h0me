# shellcheck shell=bash
# =============================================================================
# kubeop.sh — Run kubeconfig-aware tools with credentials sourced from 1Password
# =============================================================================
#
# Fetches a kubeconfig from 1Password on demand and feeds it to the target
# command via process substitution. The kubeconfig never touches a filesystem:
# it lives in an environment variable for the duration of the invocation, and
# the receiving tool reads it from a /dev/fd/N pipe.
#
# Convention: the terraform module at terraform/dev/talos-pve-v3.1.0/
# config-export.tf writes each cluster's kubeconfig to a 1Password Secure Note
# titled "<cluster-name>-kubeconfig" (e.g. "memphis-kubeconfig"). This script
# resolves the env name (dev, staging, prod) → cluster name → 1P reference.
#
# To enable, source this file from ~/.zshrc:
#     source ~/.zsh/kubeop.sh
#
# Prerequisites:
#   - 1Password CLI (`op`) installed and signed in
#   - Bash available as /bin/bash (used internally for process substitution)
#   - The cluster's kubeconfig stored in the configured vault as a Secure Note
#
# =============================================================================
# COMMAND REFERENCE
# =============================================================================
#
#   k8sop <env> <command> [args...]
#       Run any kubeconfig-aware command against the named environment.
#       Returns non-zero with a clear error if the env is unknown or the
#       1Password lookup fails.
#
#   kube [env] [args...]
#       Convenience wrapper for kubectl. Defaults env to "dev".
#
#   k9s-op [env] [args...]
#       Convenience wrapper for k9s. Defaults env to "dev".
#
#   kube-flush
#       Drop the in-memory kubeconfig cache. Run this after rotating creds
#       or to force the next call to re-fetch from 1Password.
#
# =============================================================================
# EXAMPLES
# =============================================================================
#
# NOTE: `kube` already implies `kubectl` and `k9s-op` already implies `k9s`.
# Don't repeat the tool name in those wrappers — that turns into nonsense like
# `kubectl --kubeconfig ... kubectl get nodes` and kubectl will treat the
# second `kubectl` as a plugin name. Use k8sop directly to name a tool.
#
#   kube dev kubectl get nodes      # WRONG — kubectl is duplicated
#   kube dev get nodes              # right
#   k8sop dev kubectl get nodes     # right (explicit form)
#
#   # Plain kubectl
#   kube dev get nodes
#   kube dev get pods -A
#   kube dev describe pod -n wallabag wallabag-xyz
#
#   # k9s
#   k9s-op dev
#   k9s-op dev -n flux-system
#
#   # Any other kubeconfig-aware tool via k8sop
#   k8sop dev helm list -A
#   k8sop dev flux get kustomizations
#   k8sop dev kustomize build _lib/applications/wallabag/overlays/dev
#   k8sop dev kubectl-cnpg status wallabag-dev-cluster -n wallabag
#   k8sop dev stern -n wallabag .                 # tail logs
#   k8sop dev kubecolor get pods -A               # if you prefer kubecolor
#
#   # Pipe through other tools — kubeconfig stays in this shell only
#   k8sop dev kubectl get pods -o json | jq '.items[].metadata.name'
#
#   # Force a re-fetch (e.g., after re-bootstrapping the cluster)
#   kube-flush
#
# =============================================================================
# CONFIGURATION
# =============================================================================

# 1Password vault UUID where terraform exports cluster credentials.
# Override per-shell with: export OP_VAULT="OtherVaultUuidOrName"
: "${OP_VAULT:=vh6lrleqqupcpurpxuuau2w7xe}"

# Map env name → cluster name. The cluster name must match var.talos.name in
# the corresponding terraform.tfvars (and therefore the 1Password item title).
# Add staging/prod entries here as those clusters come online.
_kubeop_cluster_for_env() {
  case "$1" in
    dev)     echo memphis ;;
    staging) echo staging ;;
    prod)    echo prod ;;
    *)       return 1 ;;
  esac
}

# =============================================================================
# IMPLEMENTATION
# =============================================================================

k8sop() {
  local env="${1:?usage: k8sop <env> <cmd> [args...]}"
  local cmd="${2:?usage: k8sop <env> <cmd> [args...]}"
  shift 2

  local cluster
  if ! cluster="$(_kubeop_cluster_for_env "$env")"; then
    echo "k8sop: unknown env '$env' (edit _kubeop_cluster_for_env in ~/.zsh/kubeop.sh)" >&2
    return 1
  fi

  # In-memory cache. Comment out the cache block to fetch on every call.
  local cache_var="_OP_KUBECFG_${env}"
  local kubedata="${(P)cache_var}"
  if [[ -z "$kubedata" ]]; then
    if ! kubedata="$(op read --no-newline "op://${OP_VAULT}/${cluster}-kubeconfig/notesPlain" 2>&1)"; then
      echo "k8sop: failed to read op://${OP_VAULT}/${cluster}-kubeconfig — ${kubedata}" >&2
      return 1
    fi
    typeset -g "$cache_var=$kubedata"
  fi

  # Pass the kubeconfig as KUBECONFIG_DATA to a bash subshell. Inside that
  # subshell, process substitution <(printenv KUBECONFIG_DATA) materializes a
  # /dev/fd/N pipe that the command reads via --kubeconfig.
  KUBECONFIG_DATA="$kubedata" \
    bash -c '"$0" --kubeconfig <(printenv KUBECONFIG_DATA) "$@"' "$cmd" "$@"
}

# Drop cached kubeconfigs from this shell's memory.
kube-flush() {
  local cleared=0
  for v in ${(k)parameters[(I)_OP_KUBECFG_*]}; do
    unset "$v"
    cleared=$((cleared + 1))
  done
  echo "k8sop: cleared ${cleared} cached kubeconfig(s)"
}

# =============================================================================
# CONVENIENCE WRAPPERS
# =============================================================================

kube()   { k8sop "${1:-dev}" kubectl "${@:2}"; }
k9s-op() { k8sop "${1:-dev}" k9s "${@:2}"; }
