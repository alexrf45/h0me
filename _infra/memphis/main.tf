module "dev" {
  source = "../modules/talos-pve"
  #source        = "git@github.com:alexrf45/lab.git//talos-pve?ref=v0.0.1"
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


data "onepassword_item" "sops_age_key" {
  depends_on = [module.dev]
  vault      = var.op_vault_id
  title      = "staging_flux_age_key"
}

resource "kubernetes_secret_v1" "sops_age" {
  count = var.flux_config.enabled ? 1 : 0
  depends_on = [
    module.dev,
    data.onepassword_item.sops_age_key
  ]
  metadata {
    name      = var.flux_config.sops_secret_name
    namespace = "flux-system"
  }
  data = {
    "${var.flux_config.sops_age_key_name}" = data.onepassword_item.sops_age_key.note_value
  }
  lifecycle {
    # Prevent replacement if the secret already exists from a prior bootstrap
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }

}


resource "flux_bootstrap_git" "this" {
  count = var.flux_config.enabled ? 1 : 0

  depends_on = [
    module.dev,
    kubernetes_secret_v1.sops_age,
  ]

  cluster_domain     = var.flux_config.cluster_domain
  path               = var.flux_config.cluster_path
  embedded_manifests = true
}
