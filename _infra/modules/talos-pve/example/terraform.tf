# terraform.tf - Example provider requirements (mirrors terraform/dev)
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.107.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.11.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.1.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "3.3.1"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "1.8.8"
    }
  }
}
