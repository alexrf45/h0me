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

provider "flux" {
  kubernetes = {
    host                   = module.dev.kubernetes_host
    client_certificate     = module.dev.kubernetes_client_certificate
    client_key             = module.dev.kubernetes_client_key
    cluster_ca_certificate = module.dev.kubernetes_cluster_ca_certificate
  }
  git = {
    url    = var.flux_config.git_url
    branch = var.flux_config.branch
    http = {
      username = "git"
      password = data.onepassword_item.github_token.credential
    }
  }
}

data "onepassword_item" "github_token" {
  vault = var.op_vault_id
  title = "flux_bootstrap_test"
}
