## Kubernetes Operations

- YOU MUST use the `k8sop` (or `kube`) wrapper for kubectl commands, not raw `kubectl`
- Verify operator/wrapper conventions before executing cluster commands

The kubeconfig is **not on disk**. It lives in 1Password and is fetched on demand
by `_hack/scripts/kubeop.sh`, a **bash** script sourced from `~/.bashrc` by the
Home Manager module `modules/home-manager/dev-tools/kubernetes.nix` in
`nix-config`. (It was zsh until 2026-09-19; the host moved to bash on 2026-09-13,
which silently broke it. Do not reintroduce zsh parameter expansions.)

Every command that talks to a live cluster MUST go through one of these wrappers:

| Wrapper                          | Use for                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------- |
| `kube [env] <args>`              | kubectl (env defaults to `$KUBEOP_ENV`, itself defaulting to `home`)                |
| `k9s-op [env] <args>`            | k9s                                                                                 |
| `k8sop <env> <tool> <args>`      | any other kubeconfig-aware tool: flux, helm, kubectl-cnpg, stern, cilium, etc.      |
| `k8sop-file <env> <tool> <args>` | same, for tools that open the kubeconfig **more than once** — see the gotcha below  |
| `kube-flush`                     | drop the cached kubeconfig (re-fetch on next call)                                  |
| `kubeop-env [env]`               | show or set the default env for this shell                                          |

Short forms, all acting on `$KUBEOP_ENV`: `k kg kgp kgn kgall kd kdel kaf kx kdry
klogs kctx k-shell`, plus `kflux khelm kstern kcnpg kkustomize`.

Examples:

- `kube home get pods -A`
- `kube home -n freshrss rollout restart deploy/freshrss`
- `k8sop home flux reconcile source git flux-system` then `k8sop home flux reconcile kustomization security`
- `k8sop home helm list -A`
- `kube home kustomize _lib/applications/freshrss/overlays/home` (kubectl's built-in kustomize; standalone `kustomize` is not installed — see `kustomize.md`)

NEVER invoke raw `kubectl …`, `flux …`, `helm …`, or `kustomize build …`
against the cluster — those have no kubeconfig and will fail or target the
wrong context. This applies to slash commands, verification steps, runbooks,
and follow-up suggestions. `KUBECONFIG` is deliberately unset, so a bare
`kubectl` failing with "no configuration has been provided" is the design
working, not a fault to fix.

**Gotcha — `flux ... --with-source` fails through `k8sop`.** `k8sop` feeds the
kubeconfig via process substitution (`<(printenv KUBECONFIG_DATA)`), which is a
single-use pipe. `--with-source` makes flux open the kubeconfig twice — once to
reconcile the source, once for the kustomization — and the second read comes back
empty. The same limit applies to any wrapped command that opens the kubeconfig
more than once in a single invocation.

Two ways out. Prefer the first:

```
# two calls, each getting a fresh pipe
k8sop home flux reconcile source git flux-system
k8sop home flux reconcile kustomization <name>

# or, when a tool genuinely needs a seekable file
k8sop-file home flux reconcile kustomization <name> --with-source
```

`k8sop-file` writes the kubeconfig to a `0600` file in `/dev/shm` (tmpfs — RAM,
never the disk) and removes it when the command exits. It is the weaker
guarantee of the two: for the duration of the command the kubeconfig is readable
by root and by this user's other processes. Use `k8sop` unless you need the file.

Env → cluster mapping (from `_kubeop_cluster_for_env` in the wrapper):
`home → anubis`, `staging → staging`, `prod → prod`. The 1Password Secure Note
is titled `<cluster-name>-kubeconfig` in the vault named by `$OP_VAULT`. For
`anubis` it is created by hand — see `_docs/runbooks/anubis-host-setup.md` §8,
including the `127.0.0.1` → `192.168.20.87` rewrite the note must carry.

`dev → memphis` was **removed** in 2026-09 along with the Talos-on-Proxmox
cluster it pointed at. A stale env mapping surfaces as a 1Password lookup
failure, which reads like an auth problem rather than a dead cluster — do not
re-add one without a cluster behind it.
