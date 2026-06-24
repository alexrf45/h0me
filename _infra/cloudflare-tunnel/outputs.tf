output "tunnel_id" {
  description = "Cloudflare tunnel UUID."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_cname_target" {
  description = "CNAME target for public hostnames routed through this tunnel."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
}

output "gatus_public_url" {
  description = "Public URL for the Gatus status page (G2)."
  value       = "https://${cloudflare_dns_record.gatus_public.name}"
}
