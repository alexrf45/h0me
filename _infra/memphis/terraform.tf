# terraform.tf
terraform {
  # >= 1.11.0 for write-only arguments used by the talos-pve module.
  required_version = ">= 1.11.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.107.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0-alpha.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.1.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "3.3.1"
    }
  }
  backend "s3" {

  }
}
