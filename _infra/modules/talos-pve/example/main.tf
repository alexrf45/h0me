module "cluster" {
  source = "../"

  env                = var.env
  bootstrap_cluster  = var.bootstrap_cluster
  talos              = var.talos
  pve                = var.pve
  nameservers        = var.nameservers
  controlplane_nodes = var.controlplane_nodes
  worker_nodes       = var.worker_nodes
  cilium_config      = var.cilium_config
  op_vault_id        = var.op_vault_id
}

# SOPS age key pulled from 1Password (same pattern as terraform/dev) — keep the
# bootstrap secret rotatable rather than reading it from a file on disk.
data "onepassword_item" "sops_age_key" {
  depends_on = [module.cluster]
  vault      = var.op_vault_id
  title      = "flux_age_key"
}

resource "kubernetes_secret_v1" "sops_age" {
  count = var.flux_config.enabled ? 1 : 0

  depends_on = [
    module.cluster,
    data.onepassword_item.sops_age_key,
  ]

  metadata {
    name      = var.flux_config.sops_secret_name
    namespace = "flux-system"
  }

  data = {
    "${var.flux_config.sops_age_key_name}" = data.onepassword_item.sops_age_key.note_value
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

#############################
# Flux Bootstrap
#############################
resource "flux_bootstrap_git" "this" {
  count = var.flux_config.enabled ? 1 : 0

  depends_on = [
    module.cluster,
    kubernetes_secret_v1.sops_age,
  ]

  cluster_domain     = var.flux_config.cluster_domain
  path               = var.flux_config.cluster_path
  embedded_manifests = true
}
