# Remotely-managed (token-based) tunnel. cloudflared in-cluster runs with only
# the connector token (TUNNEL_TOKEN); ingress/public-hostname config is managed
# on the Cloudflare side — added in G2 via cloudflare_zero_trust_tunnel_cloudflared_config
# + a DNS record, once Gatus exists.
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.cloudflare_account_id
  name       = var.tunnel_name
  config_src = "cloudflare"
}

# The connector token for the tunnel (v5: exposed via a data source, not the
# resource). Stable for a given tunnel, so no perpetual diff.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# Publish the token to 1Password so the cluster ExternalSecret
# (_lib/networking/cloudflared/externalsecret.yaml → key cf_tunnel_th0th.dev,
# property tunnel-token) ingests it. Rotatable: re-apply republishes; ESO
# re-syncs within its refreshInterval.
resource "onepassword_item" "cf_tunnel" {
  vault    = var.op_vault_id
  title    = "cf_tunnel_th0th.dev"
  category = "password"

  section {
    label = "tunnel"

    field {
      label = "tunnel-token"
      type  = "CONCEALED"
      value = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
    }
  }
}

# Public ingress for the cloudflared tunnel. Remotely-managed config is pushed
# to Cloudflare; the cluster cloudflared connectors pick it up automatically
# (no redeploy). Routes:
#   dev-status.th0th.dev → gatus (G2)
#   dev-kromgo.th0th.dev → kromgo (README live cluster stats)
# Add more public hostnames by appending entries below the existing ones
# (the trailing http_status:404 catch-all stays last).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = [
      {
        hostname = "dev-status.th0th.dev"
        service  = "http://gatus.gatus.svc.cluster.local:8080"
      },
      {
        hostname = "dev-kromgo.th0th.dev"
        service  = "http://kromgo.monitoring.svc.cluster.local:8080"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

# CNAME -> tunnel; orange-cloud (proxied) so the tunnel actually routes it.
resource "cloudflare_dns_record" "gatus_public" {
  zone_id = var.cloudflare_zone_id
  name    = "dev-status.th0th.dev"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  ttl     = 1 # 1 = automatic; required when proxied
  proxied = true
  comment = "Gatus public status page (managed by terraform/cloudflare-tunnel)"
}

# Public CNAME for the kromgo Prometheus → shields.io endpoint proxy. Same
# tunnel as gatus; shields.io fetches /<metric_name> from this host to render
# the README "Cluster" badges. Orange-cloud (proxied) is required to route
# through the tunnel and to put the rate-limit ruleset below in the path.
resource "cloudflare_dns_record" "kromgo_public" {
  zone_id = var.cloudflare_zone_id
  name    = "dev-kromgo.th0th.dev"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  ttl     = 1 # 1 = automatic; required when proxied
  proxied = true
  comment = "kromgo public metrics endpoint (managed by terraform/cloudflare-tunnel)"
}

# N-4 / G2-2 — baseline public-surface hardening. A zone-level rate-limit
# ruleset scoped to the tunnel-fronted public hostnames (Gatus + kromgo).
# Both endpoints are read-only and infrequently-accessed (shields.io heavily
# caches kromgo responses; humans hit Gatus directly), so 20 req/10s per IP
# is generous for legitimate traffic while shutting down scrape/abuse loops.
# WAF managed rules are a follow-on if needed; this is the immediate guardrail.
# Adding a new tunnel-fronted hostname? Append it to the `in {...}` set.
resource "cloudflare_ruleset" "public_status_rate_limit" {
  zone_id     = var.cloudflare_zone_id
  name        = "Public endpoints rate limit"
  kind        = "zone"
  phase       = "http_ratelimit"
  description = "Rate-limit the public tunnel-fronted hostnames (terraform/cloudflare-tunnel)."

  rules = [
    {
      description = "Block IPs exceeding 20 req/10s on tunnel-fronted public hosts"
      expression  = "(http.host in {\"dev-status.th0th.dev\" \"dev-kromgo.th0th.dev\"})"
      action      = "block"
      enabled     = true
      ratelimit = {
        # Cloudflare requires cf.colo.id (counters live per-colo, not global).
        # In practice per-IP-per-colo ≈ per-IP for any single client; a real
        # client's traffic almost always lands in one colo. shields.io fetches
        # for kromgo come from a handful of distributed IPs across colos —
        # well under the threshold per (ip, colo) pair.
        characteristics = ["ip.src", "cf.colo.id"]
        # period is plan-restricted (free plan: only 10s windows). 20 req/10s
        # ≈ 2 req/sec average — fine for both Gatus (static assets + the
        # occasional API poll) and kromgo (10 endpoints, cached for ~5min by
        # shields.io's CDN), tight enough to block scrapers.
        period              = 10
        requests_per_period = 20
        mitigation_timeout  = 10
      }
    },
  ]
}
