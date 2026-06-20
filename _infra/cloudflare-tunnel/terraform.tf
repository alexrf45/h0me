# terraform.tf - Cloudflare Tunnel (cloudflared) for public service exposure.
# Own state, independent of the cluster root, so a cluster rebuild never
# destroys the tunnel or its 1Password token.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.19.1"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "3.3.1"
    }
  }

  backend "s3" {}
}
