variable "pve" {
  description = "Proxmox VE connection + node inventory. `hosts` are the PVE node names the SDN zone is deployed to."
  type = object({
    endpoint = string
    password = string
    hosts    = list(string)
  })
  sensitive = true
}

variable "pve_api_token" {
  description = <<-EOT
    Phase-2 cutover token in the form `user@realm!tokenname=secret`. Leave empty
    to bootstrap as root@pam (Phase 1). Inject via TF_VAR_pve_api_token / op run
    after the automation token has been created and published to 1Password.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "op_service_account_token" {
  description = "1Password service account token with write access to the vault (same one terraform/dev uses to export kubeconfig)."
  type        = string
  sensitive   = true
}

variable "op_vault_id" {
  description = "1Password vault UUID for infrastructure secrets (where the automation token item is written and the admin password item is read)."
  type        = string
}

variable "admin" {
  description = <<-EOT
    Day-to-day Proxmox admin. granted the built-in PVEAdmin role at /. The
    password is READ from a pre-created 1Password item — never hardcoded — so it
    stays rotatable.
  EOT
  type = object({
    user_id       = optional(string, "admin@pve")
    op_item_title = string # 1P item holding the admin password
    comment       = optional(string, "Day-to-day admin (managed by terraform/proxmox-base)")
  })
}

variable "automation" {
  description = "Least-privilege Terraform automation principal (@pve) + API token that replaces root@pam in the provider blocks."
  type = object({
    user_id       = optional(string, "terraform@pve")
    role_id       = optional(string, "terraform")
    token_name    = optional(string, "tf")
    op_item_title = optional(string, "proxmox-terraform-token") # 1P item the token is written to
    comment       = optional(string, "Terraform automation (managed by terraform/proxmox-base)")
  })
  default = {}
}
