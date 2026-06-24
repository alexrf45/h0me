# Migration: classic Flux bootstrap → Flux Operator + Cilium GitOps handover

Date: 2026-06-23 · Module: `_infra/modules/talos-pve` · Root: `_infra/memphis`
Trigger: `flux_bootstrap_git` failed on apply (missing `gotk-sync.yaml`). Plan:
`~/.claude/plans/everything-worked-except-the-sparkling-dahl.md` (Option B, approved).

## Goal
Retire the classic `flux_bootstrap_git` bootstrap for the **Flux Operator** so Flux
upgrades like any HelmRelease, and **decouple Cilium from the Talos inline manifest**
so Flux owns Cilium as a HelmRelease. Bootstrap order: Talos provides CNI → Flux
installs → Flux adopts Cilium (and the operator) as HelmReleases.

## End-state architecture
```
Talos (cni:none) + inline MINIMAL Cilium (Helm-ownership stamped)   [bootstrap]
  → TF: helm_release flux-operator + flux-instance (FluxInstance) + git/sops secrets
  → Flux syncs _clusters/dev →
       HR cilium       (networking)  adopts the inline release, applies FULL config
       HR flux-operator (controllers) adopts the TF operator release
       HR flux-instance (controllers) adopts the TF `flux` release (FluxInstance)
```
Both charts pinned at `0.52.0`. Flux toolkit `distribution.version: "2.x"`
(operator auto-tracks). Renovate's flux manager bumps the OCIRepository tags +
the Cilium HelmRelease version automatically (no config change needed).

## Verified upstream facts
- `flux-operator` chart `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator`
  installs the operator + CRDs. No `instance:` values block.
- `flux-instance` chart `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance`
  renders the `FluxInstance` from `.Values.instance.{distribution,components,cluster,sync}`.
- `FluxInstance` is `fluxcd.controlplane.io/v1`, name `flux`, ns `flux-system`.

## Changes
**Terraform (`_infra/memphis`)**
- `providers.tf`: `flux` provider → `helm` provider.
- `terraform.tf`: dropped `fluxcd/flux` (helm 3.1.2 already present).
- `main.tf`: removed `flux_bootstrap_git`; added `kubernetes_secret_v1.flux_git_auth`
  (HTTPS token from 1P `flux_bootstrap_test`), `helm_release.flux_operator`, and
  `helm_release.flux_instance` (dependsOn operator; sync→`_clusters/dev`, name `flux-system`).
  `kubernetes_secret_v1.sops_age` kept.
- `variables.tf`: `flux_config` gained `git_secret_name`, `operator_version`,
  `instance_version`, `flux_version` (optional, defaults).

**Git — self-management**
- `_lib/controllers/flux-operator/` (OCIRepository + HelmRelease, `installCRDs: true`).
- `_lib/controllers/flux-instance/` (OCIRepository + HelmRelease, `releaseName: flux`,
  `dependsOn: flux-operator`, instance/sync values).
- wired into `_lib/controllers/kustomization.yaml`.
- `_clusters/dev/kustomization.yaml` added (root sync target = `cluster.yaml`);
  **deleted** `_clusters/dev/flux-system/` (gotk-components + kustomization).

**Cilium handover (`_infra/modules/talos-pve`)**
- `cilium_config.tf`: inline `helm_template` keeps the **FULL** values (see pitfall
  below — a "minimal" subset broke the datapath); new local `cilium_owned_manifest`
  stamps `meta.helm.sh/release-{name,namespace}` + `app.kubernetes.io/managed-by: Helm`
  on every rendered doc (adoption handshake). Inline values == HelmRelease values
  → zero-churn adoption.
- `talos.tf`: inline manifest now uses `local.cilium_owned_manifest`.
- `_lib/networking/cilium/` (HelmRepository + HelmRelease, `releaseName: cilium`,
  `targetNamespace`/`storageNamespace: networking`, FULL values) added first in the
  networking layer.

## NOT run by me (1Password-wrapped Terraform)
`init -upgrade` (re-lock: drop fluxcd/flux, add hashicorp/helm), `validate`, `fmt`,
`plan`, `apply`. Clean-slate rebuild chosen — destroy the half-bootstrapped cluster,
re-apply from scratch.

## Manual / confirm before apply
1. **`_lib/controllers/flux-instance/helmrelease.yaml` sync values** (`url`, `ref`,
   `path`) MUST equal `flux_config.{git_url, branch, cluster_path}` in tfvars — I used
   best-guess `https://github.com/alexrf45/th0th.git` / `refs/heads/dev` / `./_clusters/dev`.
2. **`_lib/networking/cilium/helmrelease.yaml` values** must match the live
   `var.cilium_config` (esp. `gatewayAPI.enabled`, `ingressController`, `loadBalancerIP`).
3. tfvars `flux_config` may add `git_secret_name`/`*_version` (optional; defaults used).

## Verification
- `kube dev -n flux-system get fluxinstance flux` → Ready; pods (source/kustomize/
  helm/notification controllers) Running.
- `kube dev get kustomizations -A` all Ready (cluster.yaml DAG).
- Cilium adopted: `kube dev -n networking get helmrelease cilium` Ready; a `cilium`
  Helm release secret exists in `networking`; nodes stay Ready (no CNI blip).
- Operator/instance adopted: `kube dev -n flux-system get hr flux-operator flux-instance`
  Ready; no duplicate operator Deployments.
- Re-run `terraform apply` → Flux resources idempotent (no-op).
- Renovate PR bumps an OCIRepository tag / cilium chart → Flux rolls it, no Terraform.

## Notes / deviations
- crds.md: the flux-operator chart installs its own CRDs (`installCRDs: true`) rather
  than `_global/crds/`. The rule's dry-run race does not apply — the `FluxInstance` CR
  is Helm-rendered by `flux-instance`, which `dependsOn` `flux-operator` (CRDs first).
- Cilium LB manifests (`CiliumL2AnnouncementPolicy`/`CiliumLoadBalancerIPPool`) remain
  inline in Talos for now (not chart resources; no adoption conflict). Candidate to
  move into `_lib/networking/cilium/` later.
- **Cilium "minimal inline" pitfall (fixed):** do NOT trim the inline bootstrap Cilium
  to a CNI-minimum subset. On Proxmox/virtio + VXLAN, the wireguard `encryption` block
  is load-bearing — without it, cross-node L4 (TCP/UDP) pod traffic is silently dropped
  by virtio checksum offload (ICMP survives), so pods can't reach the CoreDNS ClusterIP
  and the Flux bootstrap stalls on `lookup ghcr.io: i/o timeout`. Keep the full config
  inline (== HelmRelease). NB: Talos `inlineManifests` apply only at **bootstrap** — a
  plain `apply` won't re-run them; recover via clean-slate rebuild or a manual Cilium patch.
- **Provider cycle gotcha (fixed):** the root `helm` provider must NOT be the one the
  talos-pve module uses for `data.helm_template.this`. The default `provider "helm" {}`
  is left unconfigured (module inherits it for local chart rendering); a separate
  `provider "helm" { alias = "cluster" }` carries the kubeconfig and is used only by
  the flux `helm_release`s (`provider = helm.cluster`). Configuring the default helm
  provider from `module.dev.kubernetes_*` outputs creates a dependency cycle
  (helm provider → kubeconfig → Talos machine config → helm_template → helm provider).
