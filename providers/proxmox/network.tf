# network.mode: sdn    -> this set gets its own vnet + subnet in an SDN zone
# network.mode: bridge -> guests join an existing bridge (vmbr0, a vnet, ...); nothing is created

resource "proxmox_sdn_vnet" "set" {
  count = local.sdn ? 1 : 0

  id    = local.net.vnet
  zone  = local.net.zone
  alias = "dsonode-${var.set_name}"
}

resource "proxmox_sdn_subnet" "set" {
  count = local.sdn ? 1 : 0

  vnet    = proxmox_sdn_vnet.set[0].id
  cidr    = local.net.cidr
  gateway = local.gateway
  snat    = true
}

resource "proxmox_sdn_applier" "set" {
  count = local.sdn ? 1 : 0

  depends_on = [
    proxmox_sdn_vnet.set,
    proxmox_sdn_subnet.set,
  ]
}
