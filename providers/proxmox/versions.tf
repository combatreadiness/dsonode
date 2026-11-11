terraform {
  required_version = ">= 1.8.0"

  # dsonode passes the path: ~/.config/dsonode/<set>/terraform.tfstate
  backend "local" {}

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.117.0"
    }
  }
}

# PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN and PROXMOX_VE_INSECURE come from the environment.
provider "proxmox" {}
