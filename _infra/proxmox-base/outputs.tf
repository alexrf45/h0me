output "admin_user_id" {
  description = "Human admin login (PVEAdmin at /)."
  value       = proxmox_virtual_environment_user.admin.user_id
}

output "automation_token_id" {
  description = "Automation token id (terraform@pve!<name>). The secret is in 1Password, not here."
  value       = proxmox_user_token.automation.id
}

output "automation_token_op_item" {
  description = "1Password item holding the api-token field used for Phase-2 provider cutover."
  value       = var.automation.op_item_title
}

output "sdn_vnet_bridge" {
  description = "VNet id = the bridge name to set as var.pve.bridge when migrating a single-host workload onto the VNet."
  value       = proxmox_sdn_vnet.this.id
}

output "sdn_subnet" {
  description = "Isolated subnet CIDR / gateway for the VNet."
  value       = "${proxmox_sdn_subnet.this.cidr} (gw ${proxmox_sdn_subnet.this.gateway})"
}
