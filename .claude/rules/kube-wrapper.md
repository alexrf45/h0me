## Kubernetes Operations

- YOU MUST use the `k8sop` (or `kube`) wrapper for kubectl commands, not raw `kubectl`
- Verify operator/wrapper conventions before executing cluster commands

The kubeconfig is **not on disk**. It lives in 1Password and is fetched on demand
by `~/.zsh/kubeop.sh`, which is sourced from `~/.zshrc`. Every command that
talks to a live cluster MUST go through one of these wrappers:

| Wrapper                     | Use for                                                                                      |
| --------------------------- | -------------------------------------------------------------------------------------------- |
| `kube [env] <args>`         | kubectl (env defaults to `dev`)                                                              |
| `k9s-op [env] <args>`       | k9s                                                                                          |
| `k8sop <env> <tool> <args>` | any other kubeconfig-aware tool: flux, helm, kustomize, kubectl-cnpg, stern, kubecolor, etc. |
| `kube-flush`                | drop the cached kubeconfig (re-fetch on next call)                                           |

Examples:

- `kube dev get pods -A`
- `kube dev -n freshrss rollout restart deploy/freshrss`
- `k8sop dev flux reconcile source git flux-system` then `k8sop dev flux reconcile kustomization security` (see `--with-source` gotcha below)
- `k8sop dev helm list -A`
- `kube dev kustomize _lib/applications/freshrss/overlays/dev` (kubectl's built-in kustomize; standalone `kustomize` is not installed — see `kustomize.md`)

NEVER invoke raw `kubectl …`, `flux …`, `helm …`, or `kustomize build …`
against the cluster — those have no kubeconfig and will fail or target the
wrong context. This applies to slash commands, verification steps, runbooks,
and follow-up suggestions.

**Gotcha — `flux ... --with-source` fails through the wrapper.** The wrapper
feeds the kubeconfig via process substitution (`<(printenv KUBECONFIG_DATA)`),
which is a single-use pipe. `--with-source` makes flux open the kubeconfig
twice — once to reconcile the source, once for the kustomization.
Reconcile in two separate calls instead, each getting a fresh pipe:

```
k8sop dev flux reconcile source git flux-system
k8sop dev flux reconcile kustomization <name>
```

The same single-use-pipe limit applies to any wrapped command that opens the
kubeconfig more than once in a single invocation.

Env → cluster mapping (from `_kubeop_cluster_for_env` in the wrapper):
`dev → memphis`, `staging → staging`, `prod → prod`. The 1Password Secure
Note is titled `<cluster-name>-kubeconfig` and is exported by the terraform
module at `_infra/modules/talos-pve/config-export.tf`.
