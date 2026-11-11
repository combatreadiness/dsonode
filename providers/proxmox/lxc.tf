# LXC containers from a template in Proxmox's vztmpl storage (pveam download ...).
# Unprivileged. SSH as root with the management node's key.
# nesting: true on a node turns on the nesting feature (needed for Docker or systemd-in-container tricks).

resource "proxmox_virtual_environment_container" "node" {
  for_each = local.lxcs

  description   = "Managed by dsonode, set ${var.set_name}. Roles: ${join(", ", each.value.roles)}"
  node_name     = local.px.node
  vm_id         = each.value.vmid
  pool_id       = local.px.pool
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = each.value.nesting
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
    swap      = 512
  }

  disk {
    datastore_id = local.px.storage
    size         = each.value.disk
  }

  operating_system {
    template_file_id = local.px.lxc_template
    type             = "debian"
  }

  network_interface {
    name    = "eth0"
    bridge  = local.bridge
    vlan_id = local.vlan
  }

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.prefix}"
        gateway = local.gateway
      }
    }

    dns {
      servers = local.dns
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  depends_on = [
    terraform_data.checks,
    proxmox_sdn_applier.set,
  ]
}
