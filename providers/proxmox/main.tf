# Reads the set's nodes.yml directly. dsonode itself never parses YAML.

variable "set_name" {
  type = string
}

variable "config_path" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

locals {
  cfg = yamldecode(file(var.config_path))
  px  = local.cfg.proxmox
  net = local.cfg.network

  sdn     = local.net.mode == "sdn"
  bridge  = local.sdn ? local.net.vnet : local.net.bridge
  prefix  = split("/", local.net.cidr)[1]
  gateway = try(local.net.gateway, cidrhost(local.net.cidr, 1))
  dns     = try(local.net.dns, ["1.1.1.1"])
  vlan    = try(local.net.vlan, null)

  defaults = {
    vm  = merge({ cores = 2, memory = 2048, disk = 20 }, try(local.cfg.defaults.vm, {}))
    lxc = merge({ cores = 1, memory = 1024, disk = 8 }, try(local.cfg.defaults.lxc, {}))
  }

  nodes = {
    for name, n in local.cfg.nodes : name => {
      type    = try(n.type, "vm")
      vmid    = try(n.vmid, 0)
      ip      = cidrhost(local.net.cidr, n.host)
      cores   = try(n.cores, local.defaults[try(n.type, "vm")].cores)
      memory  = try(n.memory, local.defaults[try(n.type, "vm")].memory)
      disk    = try(n.disk, local.defaults[try(n.type, "vm")].disk)
      nesting = try(n.nesting, false)
      roles   = try(n.roles, [])
      user    = try(n.type, "vm") == "lxc" ? "root" : "debian"
    }
  }
  vms  = { for k, n in local.nodes : k => n if n.type == "vm" }
  lxcs = { for k, n in local.nodes : k => n if n.type == "lxc" }
}

resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = contains(["sdn", "bridge"], local.net.mode)
      error_message = "network.mode must be sdn or bridge."
    }
    precondition {
      condition     = alltrue([for n in local.nodes : contains(["vm", "lxc"], n.type)])
      error_message = "Node type must be vm or lxc."
    }
    precondition {
      condition     = length(local.lxcs) == 0 || try(local.px.lxc_template, "") != ""
      error_message = "LXC nodes need proxmox.lxc_template (e.g. local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst)."
    }
    precondition {
      condition     = length(local.vms) == 0 || try(local.px.template, "") != ""
      error_message = "VM nodes need proxmox.template (a VM template ID)."
    }
    precondition {
      condition     = alltrue([for n in local.nodes : n.vmid > 0])
      error_message = "Every node needs a vmid. Run dsonode plan/up, which fills them in."
    }
    precondition {
      condition     = length(distinct([for n in local.nodes : n.vmid])) == length(local.nodes)
      error_message = "Two nodes have the same vmid."
    }
    precondition {
      condition     = length(distinct([for n in local.nodes : n.ip])) == length(local.nodes)
      error_message = "Two nodes have the same host number."
    }
  }
}
