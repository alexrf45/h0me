# talos-pve

Terraform module for provisioning Talos Linux Kubernetes clusters on Proxmox VE
with integrated post-bootstrap automation (Cilium CNI, kubeconfig/talosconfig
export to 1Password, worker node labeling).

## What the module does

- Provisions control-plane and worker VMs on Proxmox (`pve.tf`), with control
  plane and workers scaled independently (separate `for_each` maps).
- Downloads the Talos image (factory schematic with the configured system
  extensions) to each Proxmox host (`pve-images.tf`, `talos-images.tf`).
- Renders per-node Talos machine config, applies it via `talos_machine`, and
  bootstraps the cluster via `talos_cluster` (`talos.tf`), including Cilium as an
  inline manifest rendered from the Helm chart (`cilium_config.tf`) and a split
  CoreDNS override.
- Manages Talos OS version in place: `talos_machine.image` reconciles drift /
  upgrades via `talosctl upgrade` (with node drain) instead of rebuilding the VM.
- Exports kubeconfig + talosconfig to 1Password (`config-export.tf`).

> Worker node labeling is handled by Kyverno (cluster-side policy), not this
> module.

## Requirements

| Provider              | Version | Used by                                  |
| --------------------- | ------- | ---------------------------------------- |
| bpg/proxmox           | 0.107.0        | VM provisioning + image download              |
| siderolabs/talos      | 0.12.0-alpha.4 | machine apply, cluster bootstrap, kubeconfig  |
| hashicorp/helm        | 3.1.2          | Cilium inline manifest (`helm_template`)      |
| hashicorp/random      | 3.7.2          | unique VM naming                              |
| hashicorp/kubernetes  | 3.1.0          | root provider wiring from exported kubeconfig |
| 1Password/onepassword | 3.3.1          | kubeconfig/talosconfig export                 |
| fluxcd/flux           | 1.8.8          | Flux bootstrap (**root only** )               |

Requires Terraform **>= 1.11.0** (write-only `talos_machine.kubeconfig_wo`).

## Usage

example:

```hcl
module "cluster" {
  source = "../modules/talos-pve"

  env                = "dev"
  op_vault_id        = var.op_vault_id
  talos              = var.talos
  pve                = var.pve
  nameservers        = var.nameservers
  controlplane_nodes = var.controlplane_nodes
  worker_nodes       = var.worker_nodes
  kubernetes_version = "v1.36.0" # standalone + Renovate-managed; omit to use the module default
  cilium_config      = var.cilium_config

  config_export = { enabled = true } # writes <cluster>-kubeconfig / -talosconfig to 1Password
}
```

See `example/` for the module call plus the root-level SOPS-secret and Flux
bootstrap resources, and `terraform.tfvars.example` for a full variable set.

`flux_bootstrap_git` needs the `flux` provider configured with both Kubernetes
credentials and Git creds.

## Day-2 operations

- `talos_cluster` is idempotent — no `bootstrap_cluster` flag. Re-applying an
  already-bootstrapped cluster is a no-op for the bootstrap step.
- **k8s upgrades:** bump `kubernetes_version` (Renovate-managed) and apply.
- **OS upgrades:** bump the Talos installer tag (`var.talos.version`); `talos_machine`
  performs an in-place `talosctl upgrade` with node drain — no VM rebuild.
- Add workers by adding entries to `worker_nodes` and re-applying — the control
  plane is untouched. Worker role labels are applied cluster-side by Kyverno.
- Removing a worker triggers a graceful etcd leave (`on_destroy`), so scale-down
  is now reflected in k8s.
- Disable Flux re-bootstrap on later applies with `flux_config.enabled = false`.
