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

variable "sdn" {
  description = <<-EOT
    Simple (isolated + SNAT) SDN zone for running workloads on a VNet. Simple
    zones are per-node isolated L2 with L3 routing between hosts — they do NOT
    stretch L2 across nodes, so they cannot host the multi-host HA Talos cluster
    with its L2 VIP / Cilium L2 LB as-is (see _docs follow-up). Use a NEW subnet
    that does not overlap the LAN (192.168.20.0/24).
  EOT
  type = object({
    zone_id     = optional(string, "talos")  # PVE SDN id, max 8 chars
    vnet_id     = optional(string, "vtalos") # PVE SDN id, max 8 chars
    subnet_cidr = string                     # e.g. "10.30.0.0/24"
    gateway     = string                     # e.g. "10.30.0.1"
    snat        = optional(bool, true)
    nodes       = optional(list(string)) # defaults to var.pve.hosts
    mtu         = optional(number)
  })
  validation {
    condition     = can(cidrnetmask(var.sdn.subnet_cidr))
    error_message = "sdn.subnet_cidr must be a valid CIDR (e.g. 10.30.0.0/24)."
  }
  validation {
    condition     = cidrhost("${var.sdn.gateway}/${split("/", var.sdn.subnet_cidr)[1]}", 0) == cidrhost(var.sdn.subnet_cidr, 0)
    error_message = "sdn.gateway must be inside sdn.subnet_cidr."
  }
  validation {
    condition     = cidrhost(var.sdn.subnet_cidr, 0) != "192.168.20.0"
    error_message = "sdn.subnet_cidr must not reuse the LAN 192.168.20.0/24 — a Simple zone needs its own isolated subnet."
  }
}
