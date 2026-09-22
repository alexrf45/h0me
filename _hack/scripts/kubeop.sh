# shellcheck shell=bash
# =============================================================================
# kubeop.sh — Run kubeconfig-aware tools with credentials sourced from 1Password
# =============================================================================
#
# Fetches a kubeconfig from 1Password on demand and feeds it to the target
# command. The kubeconfig never touches persistent storage: it lives in a shell
# variable for the duration of the session, and the receiving tool reads it from
# a /dev/fd/N pipe.
#
# Convention: each cluster's kubeconfig lives in a 1Password Secure Note titled
# "<cluster-name>-kubeconfig" (e.g. "anubis-kubeconfig"). This script resolves
# env name (home, staging, prod) → cluster name → 1P reference.
#
# SHELL: bash. Ported from zsh 2026-09-19, to match the host migration to bash
# on 2026-09-13. Do not reintroduce zsh parameter expansions — ${(P)var},
# typeset -g and ${(k)parameters[...]} were the reason this file stopped working.
#
# To enable, source this file from ~/.bashrc:
#     source ~/h0me/_hack/scripts/kubeop.sh
#
# Prerequisites:
#   - 1Password CLI (`op`) installed and signed in
#   - bash 4.2+ (declare -g, ${!prefix@})
#   - The cluster's kubeconfig stored in the configured vault as a Secure Note
#
# =============================================================================
# COMMAND REFERENCE
# =============================================================================
#
#   k8sop <env> <command> [args...]
#       Run any kubeconfig-aware command against the named environment.
#
#   k8sop-file <env> <command> [args...]
#       Same, but materializes the kubeconfig in tmpfs for the life of the
#       command. Use ONLY for tools that open the kubeconfig more than once —
#       see "THE SINGLE-USE PIPE" below.
#
#   kube [env] [args...]          kubectl        (env defaults to $KUBEOP_ENV)
#   k9s-op [env] [args...]        k9s
#   kube-flush                    drop cached kubeconfigs from this shell
#   kubeop-env [env]              show or set the default env for this shell
#
#   Short forms, all against $KUBEOP_ENV: k kg kgp kgn kgall kd kdel kaf kx
#   kdry klogs kctx k-shell, plus kflux khelm kstern kcnpg kkustomize.
#
# =============================================================================
# THE SINGLE-USE PIPE
# =============================================================================
#
# k8sop passes the kubeconfig via process substitution, <(printenv ...). That
# is a pipe, and a pipe can be read exactly once. Any tool that opens the
# kubeconfig twice in one invocation gets an empty read the second time and
# fails with a confusing "no configuration has been provided" style error.
#
# The known offender is `flux ... --with-source`, which reconciles the source
# and then the kustomization, opening the config once for each. Either issue two
# separate calls:
#
#     kflux reconcile source git flux-system
#     kflux reconcile kustomization <name>
#
# or use k8sop-file, which writes the kubeconfig to a 0600 file in /dev/shm
# (tmpfs — RAM, never the disk) and removes it when the command exits:
#
#     k8sop-file home flux reconcile kustomization <name> --with-source
#
# k8sop-file is the weaker guarantee of the two: for the duration of the
# command the kubeconfig is readable by root and by this user's other
# processes. Prefer plain k8sop; reach for k8sop-file when a tool genuinely
# needs a seekable file.
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
#   kube home kubectl get nodes     # WRONG — kubectl is duplicated
#   kube home get nodes             # right
#   k8sop home kubectl get nodes    # right (explicit form)
#
#   kube home get pods -A
#   kube home -n freshrss rollout restart deploy/freshrss
#   kube home kustomize _lib/applications/homer/overlays/home   # no `build`
#
#   k9s-op home
#   k8sop home helm list -A
#   k8sop home kubectl-cnpg status wallabag-cluster -n wallabag
#   k8sop home stern -n wallabag .
#
#   # Pipe through other tools — kubeconfig stays in this shell only
#   k8sop home kubectl get pods -o json | jq '.items[].metadata.name'
#
#   kube-flush                      # force a re-fetch after re-bootstrapping
#
# =============================================================================
# CONFIGURATION
# =============================================================================

# 1Password vault UUID where cluster credentials are stored.
# Override per-shell with: export OP_VAULT="OtherVaultUuidOrName"
: "${OP_VAULT:=vh6lrleqqupcpurpxuuau2w7xe}"

# Default env for `kube` and the short forms. Override per-shell with
# `kubeop-env <env>`, or persistently with: export KUBEOP_ENV=home
: "${KUBEOP_ENV:=home}"

# Map env name → cluster name. The cluster name must match the 1Password item
# title, "<cluster>-kubeconfig".
#
#   home → anubis   single-node k3s on bare metal (192.168.20.87)
#
# `dev → memphis` was removed in 2026-09: the 6-node Talos-on-Proxmox cluster
# was decommissioned and its NUCs sold. Do not re-add it without a cluster
# behind it — a stale mapping fails as a 1Password lookup error, which reads
# like an auth problem rather than a dead cluster.
_kubeop_cluster_for_env() {
  case "$1" in
    home)    echo anubis ;;
    staging) echo staging ;;
    prod)    echo prod ;;
    *)       return 1 ;;
  esac
}

# =============================================================================
# IMPLEMENTATION
# =============================================================================

# Resolve <env> to kubeconfig text, caching it in a per-env global.
# Sets $_KUBEOP_DATA for the caller to read; diagnostics go to stderr.
#
# It sets a global rather than printing to stdout on purpose. A caller writing
# `data="$(_kubeop_fetch home)"` would run this in a command-substitution
# subshell, where the `declare -g` cache write is discarded when that subshell
# exits — so the cache would silently never hit and every single invocation
# would go out to 1Password. The zsh original got away with an inline fetch;
# this indirection has to assign in the caller's own scope.
_kubeop_fetch() {
  local env="$1" cluster cache_var kubedata

  if ! cluster="$(_kubeop_cluster_for_env "$env")"; then
    echo "k8sop: unknown env '$env' (edit _kubeop_cluster_for_env in ${BASH_SOURCE[0]})" >&2
    return 1
  fi

  # In-memory cache. bash indirect expansion ${!name} replaces zsh's ${(P)name}.
  cache_var="_OP_KUBECFG_${env}"

  if [[ -z "${!cache_var-}" ]]; then
    if ! kubedata="$(op read --no-newline "op://${OP_VAULT}/${cluster}-kubeconfig/notesPlain" 2>&1)"; then
      echo "k8sop: failed to read op://${OP_VAULT}/${cluster}-kubeconfig — ${kubedata}" >&2
      return 1
    fi
    # declare -g replaces zsh's typeset -g (bash 4.2+).
    declare -g "$cache_var=$kubedata"
  fi

  declare -g _KUBEOP_DATA="${!cache_var}"
}

k8sop() {
  local env="${1:?usage: k8sop <env> <cmd> [args...]}"
  local cmd="${2:?usage: k8sop <env> <cmd> [args...]}"
  shift 2

  _kubeop_fetch "$env" || return 1
  local kubedata="$_KUBEOP_DATA"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "k8sop: '$cmd' is not installed" >&2
    return 127
  fi

  # Process substitution materializes a /dev/fd/N pipe the command reads via
  # --kubeconfig. Single-use — see THE SINGLE-USE PIPE above.
  #
  # The export and the subshell are both load-bearing. A `VAR=x cmd <(...)`
  # prefix puts VAR only in cmd's environment, but bash forks the process
  # substitution from the *current* shell, where VAR is still unset — so
  # `printenv` writes nothing, the tool reads a zero-byte kubeconfig, and
  # kubectl falls back to its localhost:8080 default with a "connection
  # refused" that looks like a dead cluster rather than a missing config.
  # Exporting inside a subshell sets the variable before the substitution is
  # created, and keeps it out of the calling shell's environment.
  (
    export KUBECONFIG_DATA="$kubedata"
    "$cmd" --kubeconfig <(printenv KUBECONFIG_DATA) "$@"
  )
}

# Multi-read variant: kubeconfig in tmpfs, removed on exit. See the header.
k8sop-file() {
  local env="${1:?usage: k8sop-file <env> <cmd> [args...]}"
  local cmd="${2:?usage: k8sop-file <env> <cmd> [args...]}"
  shift 2

  _kubeop_fetch "$env" || return 1
  local kubedata="$_KUBEOP_DATA"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "k8sop-file: '$cmd' is not installed" >&2
    return 127
  fi

  local dir tmpfile rc=0
  dir=/dev/shm
  [[ -d "$dir" && -w "$dir" ]] || dir="${TMPDIR:-/tmp}"

  tmpfile="$(mktemp "${dir}/kubeconfig.XXXXXXXX")" || return 1
  chmod 0600 "$tmpfile"
  printf '%s' "$kubedata" >"$tmpfile"

  "$cmd" --kubeconfig "$tmpfile" "$@" || rc=$?

  rm -f "$tmpfile"
  return "$rc"
}

# Drop cached kubeconfigs from this shell's memory.
# ${!prefix@} expands to the *names* of set variables sharing that prefix —
# the bash equivalent of zsh's ${(k)parameters[(I)pattern]}.
kube-flush() {
  local cleared=0 v
  for v in ${!_OP_KUBECFG_@}; do
    unset "$v"
    cleared=$((cleared + 1))
  done
  echo "k8sop: cleared ${cleared} cached kubeconfig(s)"
}

# Show or set the default env used by `kube` and the short forms.
# SC2120: this is called interactively with an env argument; shellcheck only
# sees the no-argument self-call below, which is deliberate — it reprints the
# new state after a successful switch.
# shellcheck disable=SC2120
kubeop-env() {
  if [[ $# -eq 0 ]]; then
    echo "${KUBEOP_ENV} → $(_kubeop_cluster_for_env "$KUBEOP_ENV" 2>/dev/null || echo '(unmapped!)')"
    return 0
  fi
  if ! _kubeop_cluster_for_env "$1" >/dev/null; then
    echo "kubeop-env: unknown env '$1'" >&2
    return 1
  fi
  export KUBEOP_ENV="$1"
  # shellcheck disable=SC2119  # intentional: no args = print current state
  kubeop-env
}

# =============================================================================
# CONVENIENCE WRAPPERS
# =============================================================================
# These take an explicit env as $1.

kube()   { k8sop "${1:-$KUBEOP_ENV}" kubectl "${@:2}"; }
k9s-op() { k8sop "${1:-$KUBEOP_ENV}" k9s "${@:2}"; }

# =============================================================================
# SHORT FORMS
# =============================================================================
# Restored from the retired dotfiles/zsh/kube.zsh, rewritten to route through
# the wrapper — the originals called `kubectl` directly, which now has no
# kubeconfig at all. All of these act on $KUBEOP_ENV; switch with
# `kubeop-env <env>` rather than kubectx, which is meaningless when the
# kubeconfig is fetched per-invocation and holds exactly one context.

_kube_env() { k8sop "$KUBEOP_ENV" "$@"; }

k()      { _kube_env kubectl "$@"; }
kg()     { k get "$@"; }
kgp()    { k get pods -o wide "$@"; }
kgn()    { k get nodes -o wide "$@"; }
kgall()  { k get all -A "$@"; }
kd()     { _kube_env kubectl describe "$@"; }
kdel()   { _kube_env kubectl delete "$@"; }
kaf()    { _kube_env kubectl apply -f "$@"; }
kx()     { _kube_env kubectl exec -it "$@"; }
klogs()  { _kube_env kubectl logs "$@"; }
kdry()   { _kube_env kubectl -o yaml --dry-run=client "$@"; }
kctx()   { _kube_env kubectl config get-clusters "$@"; }

# Throwaway netshoot pod for in-cluster network debugging.
k-shell() {
  _kube_env kubectl run "tmp-shell-$$" --rm -i --tty \
    --image nicolaka/netshoot -- /bin/bash
}

# Other kubeconfig-aware tooling, against $KUBEOP_ENV.
kflux()      { _kube_env flux "$@"; }
khelm()      { _kube_env helm "$@"; }
kstern()     { _kube_env stern "$@"; }
kcnpg()      { _kube_env kubectl-cnpg "$@"; }
# kubectl's built-in kustomize — the standalone binary is not installed, and
# there is no `build` subcommand here. See .claude/rules/kustomize.md.
kkustomize() { _kube_env kubectl kustomize "$@"; }
