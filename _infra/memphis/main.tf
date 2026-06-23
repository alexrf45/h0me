module "dev" {
  source = "../modules/talos-pve"
  #source        = "git@github.com:alexrf45/lab.git//talos-pve?ref=v0.0.1"
  env                = var.env
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


# Git credentials for the FluxInstance GitRepository sync (HTTPS + token).
# Bootstrap-only secret (must exist before Flux/ESO run); kept TF-managed.
resource "kubernetes_secret_v1" "flux_git_auth" {
  count      = var.flux_config.enabled ? 1 : 0
  depends_on = [module.dev]
  metadata {
    name      = var.flux_config.git_secret_name
    namespace = "flux-system"
  }
  data = {
    username = "git"
    password = data.onepassword_item.github_token.credential
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

# One-time bootstrap of the Flux Operator. In steady state this same Helm
# release is adopted by the flux-operator HelmRelease in Git (Renovate bumps it).
resource "helm_release" "flux_operator" {
  count            = var.flux_config.enabled ? 1 : 0
  provider         = helm.cluster
  depends_on       = [module.dev]
  name             = "flux-operator"
  namespace        = "flux-system"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.flux_config.operator_version
  create_namespace = false
}

# One-time bootstrap of the FluxInstance (installs the Flux toolkit and starts
# the Git sync). Ordered after the operator so its CRDs exist. Adopted by the
# flux-instance HelmRelease in Git afterwards.
resource "helm_release" "flux_instance" {
  count     = var.flux_config.enabled ? 1 : 0
  provider  = helm.cluster
  name      = "flux"
  namespace = "flux-system"
  depends_on = [
    helm_release.flux_operator,
    kubernetes_secret_v1.sops_age,
    kubernetes_secret_v1.flux_git_auth,
  ]
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"
  version    = var.flux_config.instance_version

  values = [yamlencode({
    instance = {
      distribution = {
        version  = var.flux_config.flux_version
        registry = "ghcr.io/fluxcd"
      }
      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
      ]
      cluster = {
        type          = "kubernetes"
        multitenant   = false
        networkPolicy = true
        domain        = var.flux_config.cluster_domain
      }
      sync = {
        # name "flux-system" so the generated GitRepository/Kustomization match the
        # sourceRef.name in _clusters/dev/cluster.yaml (drop-in for classic bootstrap).
        name       = "flux-system"
        kind       = "GitRepository"
        url        = var.flux_config.git_url
        ref        = "refs/heads/${var.flux_config.branch}"
        path       = var.flux_config.cluster_path
        pullSecret = var.flux_config.git_secret_name
      }
    }
  })]
}
