# VMs cloned from a cloud-init template (e.g. the one `dsoadm template` builds:
# Debian 12 cloud image, disk on scsi0, cloud-init drive, no guest agent).

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.vms

  name        = each.key
  description = "Managed by dsonode, set ${var.set_name}. Roles: ${join(", ", each.value.roles)}"
  node_name   = local.px.node
  vm_id       = each.value.vmid
  pool_id     = local.px.pool
  tags        = concat(["dsonode", "set-${var.set_name}"], each.value.roles)

  started         = true
  on_boot         = true
  stop_on_destroy = true # no guest agent, so do not wait for a clean shutdown

  clone {
    vm_id = local.px.template
    full  = true
  }

  agent {
    enabled = false
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = local.px.storage
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
  }

  network_device {
    bridge  = local.bridge
    vlan_id = local.vlan
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = local.px.storage

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
      username = "debian"
      keys     = [var.ssh_public_key]
    }
  }

  depends_on = [
    terraform_data.checks,
    proxmox_sdn_applier.set,
  ]
}

