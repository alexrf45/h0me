# Two-phase auth, no file edits needed to cut over:
#
#   Phase 1 (bootstrap): leave pve_api_token empty. The provider authenticates
#     as root@pam to create the automation user/role/token (users.tf) and SDN.
#   Phase 2 (cutover): set TF_VAR_pve_api_token to the generated token
#     (terraform@pve!<name>=<secret>, published to 1Password by this run) and
#     re-apply. The provider then uses the least-privilege token instead of root.
#
# Both branches keep the unused auth attributes null so bpg doesn't see a
# conflicting username+api_token pair.
provider "proxmox" {
  endpoint = "https://${var.pve.endpoint}:8006"
  insecure = true
  ssh {
    agent = false
  }

  api_token = var.pve_api_token != "" ? var.pve_api_token : null
  username  = var.pve_api_token == "" ? "root@pam" : null
  password  = var.pve_api_token == "" ? var.pve.password : null
}

provider "onepassword" {
  service_account_token = var.op_service_account_token
}
