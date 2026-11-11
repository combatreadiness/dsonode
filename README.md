**English** | [한국어](README.ko.md)

# dsonode

Write the VMs and LXCs you want in one YAML file. `dsonode up` builds them on Proxmox VE, network included, and hands you an Ansible inventory. `dsonode down` takes it all away again.

```bash
dsonode new lab1      # nodes.yml filled in from what the API shows
dsonode up lab1       # network + VMs/LXCs + inventory
ansible -i "$(dsonode inventory lab1)" all -m ping
```

It is plain OpenTofu (bpg/proxmox) under a small bash script. It works with a least-privilege API token, and fits on a management node made by [proxmox-iac-bootstrap](https://github.com/combatreadiness/proxmox-iac-bootstrap) without any setup. A plain Proxmox host works too.

## What you get

A set called `lab1`, with one VM and one LXC:

```
SDN zone "lab"
├── vnet "labmg"   10.73.10.0/24   management node (proxmox-iac-bootstrap)
└── vnet "labn1"   10.73.40.0/24   set lab1 (dsonode-lab1), SNAT to the internet
    ├── VM  201  cp1    10.73.40.11   cloned from the VM template, SSH user debian
    └── LXC 202  git    10.73.40.21   from the LXC template, unprivileged, SSH user root

Pool lab-workloads    the guests

~/.config/dsonode/lab1/
├── nodes.yml           what to build (you edit this)
├── inventory.yml       Ansible inventory, written by `dsonode up`
├── terraform.tfstate   what was built
└── known_hosts         host keys of this set only
```

Every `roles` entry in `nodes.yml` becomes an Ansible group. That is the whole contract with whatever runs next: [dsokube](https://github.com/combatreadiness/dsokube) takes `k3s_cluster`, `server` and `agent`, your own playbook takes its own groups.

## nodes.yml

`dsonode new` writes it with every key filled in:

```yaml
provider: proxmox

proxmox:
  node: p82-proxmox-01
  pool: lab-workloads
  storage: local-lvm           # VM disks and cloud-init drive
  template: 9000               # VM template ID to clone (type: vm)
  lxc_template: "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

network:
  mode: sdn                    # sdn: a vnet of its own | bridge: join an existing bridge
  zone: lab
  vnet: labn1                  # created by dsonode, 8 characters max
  cidr: 10.73.40.0/24          # node IP = host number in this network

vmid_start: 201                # nodes get the next free VM IDs from here

defaults:
  vm:  { cores: 2, memory: 2048, disk: 20 }   # MiB, GB
  lxc: { cores: 1, memory: 1024, disk: 8 }

nodes:
  cp1: { vmid: 201, type: vm,  host: 11, memory: 4096, roles: [k3s_cluster, server] }
  git: { vmid: 202, type: lxc, host: 21, roles: [git] }
```

What `new` picks for you:

- **Node, pool, storage, templates**: the first ones this token may use.
- **Network**: if the token may create vnets in an SDN zone, a new vnet `<zone>n1`, `<zone>n2`, ... and the first free `10.N.C.0/24` from `C = 40`, skipping the management network and every other set. Without SDN rights it falls back to `mode: bridge` on an existing bridge; set `cidr` to that network.
- **VM IDs**: the next free IDs after `vmid_start` (201 on a bootstrap node, 100 elsewhere). `plan` and `up` write them into the node lines, so a node keeps its ID from then on.

Per node you can set `cores`, `memory`, `disk`, `roles`, and for LXCs `nesting: true` (Docker inside). Keep one node per line: dsonode adds `vmid:` to that line.

In bridge mode, `bridge`, `vlan`, `gateway` (default host 1) and `dns` (default `1.1.1.1`) are also read.

## Requirements

- Proxmox VE 8.x, single node. Tested on 8.4.
- On the machine that runs dsonode: bash, curl, jq, OpenTofu 1.8+, `~/.ssh/id_ed25519.pub`. A proxmox-iac-bootstrap management node has all of it.
- A Debian 12 cloud-init VM template (`dsoadm template` builds one) and/or a Debian LXC template (`pveam download`).
- An API token, from one of:
  - `PROXMOX_VE_ENDPOINT` and `PROXMOX_VE_API_TOKEN` (and `PROXMOX_VE_INSECURE`) in the environment
  - a file with those lines: `DSONODE_CRED=/path/to/file`
  - the proxmox-iac-bootstrap credentials file, found by itself when there is exactly one

Not sure the token can do it? `dsonode doctor` reads the API and tells you which pools, storage, SDN zones, templates and bridges it can use. It changes nothing.

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsonode/main/install.sh)"
dsonode doctor
```

## Commands

| Command | What it does |
|---|---|
| `dsonode doctor [--cred FILE]` | Check tools, API, token rights, storage, templates, networks. Reads only |
| `dsonode new <set>` | Write `~/.config/dsonode/<set>/nodes.yml` from what the API shows |
| `dsonode list` | Every set, built or not |
| `dsonode plan <set>` | What OpenTofu would change. Gives out missing VM IDs, builds nothing |
| `dsonode up <set> [-y]` | Build it, write the inventory, wait until every node answers on SSH |
| `dsonode inventory <set>` | Print the inventory path |
| `dsonode down <set> [-y] [--purge]` | Destroy the guests and the vnet. `--purge` deletes `nodes.yml` too |

Each set has its own OpenTofu state, so sets never touch each other. Running `up` again on an unchanged file should say `No changes`.

Add a node: add a line, `dsonode up <set>`. Only the new guest is created.

## Security

- The token goes in a header file for curl and in the environment for OpenTofu. It is never printed; `doctor` shows the token ID only.
- `nodes.yml`, `inventory.yml` and the state are mode 600 in a mode-700 folder.
- SSH host keys go to a `known_hosts` file per set. A rebuilt guest does not clash with your own `~/.ssh/known_hosts`.
- Guests get the management node's public key and nothing else. No passwords.

## Known limitations

- Proxmox VE 9 is not tested yet.
- Guests are assumed to be Debian: SSH user `debian` on VMs, LXC `ostype` `debian`, VM disk on `scsi0` (the `dsoadm template` layout).
- LXCs are created without tags. With a token limited to a pool, Proxmox checks tag rights on `/vms/<id>` before the new container is in the pool, and refuses.
- Removing `vmid:` from a node that is already built gives it a new ID, and OpenTofu replaces the guest.
- `doctor` may not list `vmbr0`, depending on the token's rights on the node. Bridge mode still works if you name the bridge.
- Single-node Proxmox only.

## License

Apache-2.0. See [LICENSE](LICENSE).
