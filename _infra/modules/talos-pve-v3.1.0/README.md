# talos-pve

Terraform module for provisioning Talos Linux Kubernetes clusters on Proxmox VE
with integrated post-bootstrap automation (Cilium CNI, kubeconfig/talosconfig
export to 1Password, worker node labeling).

> Module directory is still named `talos-pve-v3.1.0`; renaming to git-tag-based
> versioning is tracked in [ADR-0006](../../../_docs/decisions/0006-talos-pve-module-refactor.md)
> (Option C). Provider/refactor state below reflects ADR-0006 Option B.

## What the module does

- Provisions control-plane and worker VMs on Proxmox (`pve.tf`), with control
  plane and workers scaled independently (separate `for_each` maps).
- Downloads the Talos image (factory schematic with the configured system
  extensions) to each Proxmox host (`pve-images.tf`, `talos-images.tf`).
- Renders Talos machine config and bootstraps the cluster (`talos.tf`), including
  Cilium as an inline manifest rendered from the Helm chart (`cilium_config.tf`)
  and a split-horizon CoreDNS override.
- Exports kubeconfig + talosconfig to 1Password (`config-export.tf`).
- Labels worker nodes post-bootstrap (`worker-labels.tf`).

Flux bootstrap and the SOPS age secret live in the **root** consumer
(`terraform/dev`), not in this module — see "Why Flux is at root level" below.

## Requirements

| Provider              | Version | Used by                                   |
| --------------------- | ------- | ----------------------------------------- |
| bpg/proxmox           | 0.107.0 | VM provisioning + image download          |
| siderolabs/talos      | 0.11.0  | machine config, bootstrap, kubeconfig     |
| hashicorp/helm        | 3.1.2   | Cilium inline manifest (`helm_template`)  |
| hashicorp/random      | 3.7.2   | unique VM naming                          |
| hashicorp/time        | 0.11.2  | bootstrap timing (`time_sleep`)           |
| hashicorp/kubernetes  | 3.1.0   | worker labeling (`kubernetes_labels`)     |
| 1Password/onepassword | 3.3.1   | kubeconfig/talosconfig export             |
| fluxcd/flux           | 1.8.8   | Flux bootstrap (**root only**, not module)|

All providers are pinned to exact versions (reproducibility — see ADR-0006).

## Usage

The live reference implementation is `terraform/dev`. Minimal call:

```hcl
module "cluster" {
  source = "../modules/talos-pve-v3.1.0"

  env                = "dev"
  bootstrap_cluster  = true
  op_vault_id        = var.op_vault_id
  talos              = var.talos
  pve                = var.pve
  nameservers        = var.nameservers
  controlplane_nodes = var.controlplane_nodes
  worker_nodes       = var.worker_nodes
  cilium_config      = var.cilium_config

  config_export = { enabled = true } # writes <cluster>-kubeconfig / -talosconfig to 1Password
  worker_labels = { enabled = true }
}
```

See `example/` for the module call plus the root-level SOPS-secret and Flux
bootstrap resources, and `terraform.tfvars.example` for a full variable set.

## Split-horizon DNS

`var.nameservers.internal` is the resolver CoreDNS forwards `*.th0th.dev` to
(so in-cluster back-channels like Grafana → Authentik resolve internal records).
It falls back to `var.nameservers.secondary` when unset — set it explicitly to your
internal resolver; do not leave it pointing at a public upstream.

## Why Flux bootstrap is at root level

`flux_bootstrap_git` needs the `flux` provider configured with both Kubernetes
credentials and Git creds. Terraform can't configure a provider inside a module
from computed values, so the flux + kubernetes providers are configured in the
root consumer (`terraform/dev/providers.tf`) from `module.<name>` outputs, and the
SOPS age secret + `flux_bootstrap_git` live in `terraform/dev/main.tf`.

## Day-2 operations

- After the first deploy, set `bootstrap_cluster = false` to avoid re-bootstrap.
- Add workers by adding entries to `worker_nodes` and re-applying — control plane
  is untouched and new workers are provisioned, configured, and labeled.
- Disable Flux re-bootstrap on later applies with `flux_config.enabled = false`.
