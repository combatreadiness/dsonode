# The Ansible inventory, written by OpenTofu itself (yamlencode), so dsonode needs no YAML tools.
# Every role in nodes.yml becomes a group. dsokube, dsopipe and any playbook take the groups they need.

variable "state_dir" {
  type = string
}

locals {
  roles = distinct(flatten([for n in local.nodes : n.roles]))
}

output "inventory" {
  value = yamlencode({
    all = {
      vars = {
        ansible_ssh_common_args = "-o UserKnownHostsFile=${var.state_dir}/known_hosts -o StrictHostKeyChecking=accept-new"
      }
      hosts = {
        for k, n in local.nodes : k => {
          ansible_host = n.ip
          ansible_user = n.user
          dsonode_type = n.type
          dsonode_set  = var.set_name
        }
      }
      children = {
        for r in local.roles : r => {
          hosts = { for k, n in local.nodes : k => {} if contains(n.roles, r) }
        }
      }
    }
  })
}

# Used by dsonode itself (waiting for SSH, listing)
output "nodes" {
  value = {
    for k, n in local.nodes : k => {
      type  = n.type
      ip    = n.ip
      vmid  = n.vmid
      roles = n.roles
      user  = n.user
    }
  }
}
