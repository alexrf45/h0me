provider "talos" {
}

provider "proxmox" {
  endpoint = "https://${var.pve.endpoint}:8006"
  username = "root@pam"
  password = var.pve.password
  #api_token = var.pve.api_token
  insecure = true
  ssh {
    agent = false
    #username = "terraform"
  }
}

provider "onepassword" {
  service_account_token = var.op_service_account_token
}

provider "kubernetes" {
  host                   = module.dev.kubernetes_host
  client_certificate     = module.dev.kubernetes_client_certificate
  client_key             = module.dev.kubernetes_client_key
  cluster_ca_certificate = module.dev.kubernetes_cluster_ca_certificate
}

# Default helm provider: UNCONFIGURED. Inherited by the talos-pve module's
# data.helm_template.this, which renders the Cilium chart locally and must NOT
# depend on the cluster. Sharing a cluster-connected helm provider with the module
# creates a cycle: the provider would depend on module outputs (kubeconfig), which
# depend on the Talos machine config, which embeds the helm_template output.
provider "helm" {}

# Cluster-connected helm provider — used ONLY by the root flux-operator /
# flux-instance releases (downstream of the cluster, so no cycle).
provider "helm" {
  alias = "cluster"
  kubernetes = {
    host                   = module.dev.kubernetes_host
    client_certificate     = module.dev.kubernetes_client_certificate
    client_key             = module.dev.kubernetes_client_key
    cluster_ca_certificate = module.dev.kubernetes_cluster_ca_certificate
  }
}

data "onepassword_item" "github_token" {
  vault = var.op_vault_id
  title = "flux_bootstrap_test"
}
