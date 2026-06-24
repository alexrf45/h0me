variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token used to manage the tunnel. Account-scoped permissions:
    "Account · Cloudflare One Connector: cloudflared · Edit" (a.k.a. Cloudflare
    Tunnel: Edit). Add "Zone · DNS · Edit" for th0th.dev when the public
    hostname/DNS record is added in G2. Prefer an account-owned token.
    Separate from the cert-manager DNS-01 token (cf_token_th0th.dev).
  EOT
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the th0th.dev zone."
  type        = string
}

variable "op_service_account_token" {
  description = "1Password service account token with write access to the vault (same one terraform/dev uses to export kubeconfig)."
  type        = string
  sensitive   = true
}

variable "op_vault_id" {
  description = "1Password vault UUID where the tunnel-token item is created — the same vault 1Password Connect / ESO reads."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare tunnel."
  type        = string
  default     = "th0th"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for th0th.dev (find it on the zone's Overview page in the Cloudflare dashboard)."
  type        = string
}
