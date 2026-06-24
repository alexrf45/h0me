module "pve-admin" {
  source                   = "../modules/proxmox-base"
  op_service_account_token = var.op_service_account_token
  op_vault_id              = var.op_vault_id
  pve                      = var.pve
}
