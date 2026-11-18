# shellcheck shell=bash
# =============================================================
# lib/new.sh — dsonode new: write a set's nodes.yml from what the API shows (sourced by dsonode)
# =============================================================

NEW_USAGE="Usage: dsonode new <set> [--servers N] [--agents N]"

cmd_new() {
  # --servers / --agents (same words as k3d): start nodes.yml with K3s nodes. One given, the other is 1.
  local set="" servers="" agents=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --servers) servers="${2:-}"; shift ;;
      --agents)  agents="${2:-}"; shift ;;
      -*) die "Unknown option '$1'. ${NEW_USAGE}" ;;
      *)  [[ -z "$set" ]] || die "$NEW_USAGE"; set="$1" ;;
    esac
    if [[ $# -gt 0 ]]; then shift; fi
  done

  [[ -n "$set" ]] || die "$NEW_USAGE"
  [[ "$set" =~ $SET_RE ]] || die "Set name '${set}': lowercase letters, digits and -, starting with a letter, 16 characters max."
  local dir="${DSONODE_HOME}/${set}"
  [[ ! -e "${dir}/nodes.yml" ]] || die "Set '${set}' already exists: ${dir}/nodes.yml"

  local k3s=0
  if [[ -n "${servers}${agents}" ]]; then
    k3s=1
    servers="${servers:-1}"
    agents="${agents:-1}"
    [[ "$servers" =~ ^[1-9]$ ]] || die "--servers ${servers}: use a number from 1 to 9."
    [[ "$agents" =~ ^[0-9]{1,2}$ ]] || die "--agents ${agents}: use a number from 0 to 99."
    if (( servers % 2 == 0 )); then
      warn "${servers} servers: an even number does not survive more failures than one fewer. Use 1, 3 or 5."
    fi
  fi

  need_api

  step "Looking at Proxmox"
  local perms node pool storage template lxc_template zone mode bridge="" vnet="" cidr="" start n c b ip used taken i
  perms="$(pve_api /access/permissions)"
  node="$(pve_api /nodes | jq -r '[.data[] | select(.status == "online")][0].node // empty')"
  [[ -n "$node" ]] || die "No online Proxmox node."
  pool="$(paths_with "$perms" /pool/ VM.Allocate | head -n1)"
  storage="$(pve_api "/nodes/${node}/storage" | jq -r '.data[] | select(.active == 1 and ((.content // "") | split(",") | index("images"))) | .storage' \
    | while read -r s; do if paths_with "$perms" /storage/ Datastore.AllocateSpace | grep -qx "$s"; then echo "$s"; fi; done | head -n1)"
  template="$(vm_templates | awk 'NR == 1 {print $1}')"
  lxc_template="$(lxc_templates "$node" | grep -E 'debian-[0-9]+-standard' | sort -V | tail -n1)"
  zone="$(paths_with "$perms" /sdn/zones/ SDN.Allocate | head -n1)"
  log "node ${node}, pool ${pool:-?}, storage ${storage:-?}"
  log "VM template ${template:-none}, LXC template ${lxc_template:-none}"

  if [[ -n "$zone" ]]; then
    mode=sdn
    # vnet: <zone>n1, <zone>n2, ... not on the cluster yet
    used=" $(pve_api /cluster/sdn/vnets 2>/dev/null | jq -r '.data[].vnet' | tr '\n' ' ') $(set_values vnet | tr '\n' ' ') "
    n=1
    while :; do
      vnet="${zone}n${n}"
      [[ ${#vnet} -le 8 ]] || die "No free vnet name in zone ${zone}. Write nodes.yml by hand."
      [[ "$used" == *" ${vnet} "* ]] || break
      n=$((n + 1))
    done
    # cidr: first free 10.<B>.<C>.0/24, C from 40, B from this machine's address
    ip="$(my_ip)"
    b=73
    if [[ "$ip" == 10.* ]]; then b="$(cut -d. -f2 <<<"$ip")"; fi
    taken="$(sdn_cidrs; set_values cidr; if [[ -n "$ip" ]]; then echo "${ip}/24"; fi)"
    for c in $(seq 40 254); do
      cidr="10.${b}.${c}.0/24"
      used=0
      while read -r t; do
        if [[ -n "$t" ]] && cidr_overlap "$cidr" "$t"; then used=1; break; fi
      done <<<"$taken"
      [[ $used -eq 1 ]] || break
    done
    log "network: new vnet ${vnet} in zone ${zone}, ${cidr}"
  else
    mode=bridge
    bridge="$(pve_api "/nodes/${node}/network?type=any_bridge" 2>/dev/null | jq -r '.data[0].iface // empty')"
    bridge="${bridge:-vmbr0}"
    cidr="192.168.1.0/24"
    warn "No SDN zone this token can create vnets in: using bridge ${bridge}. Set network.cidr to that network."
  fi

  # VM IDs start after the management node (bootstrap), else at 100. IDs are given out by plan/up.
  start="$(mgmt_ctid)"
  if [[ -n "$start" ]]; then start=$((start + 1))
  elif [[ -n "$(bootstrap_env)" ]]; then start=201
  else start=100; fi

  [[ -n "$pool" ]] || warn "No pool this token can create guests in. Set proxmox.pool by hand."
  [[ -n "$storage" ]] || warn "No storage for VM disks found. Set proxmox.storage by hand."
  if [[ -z "$template" ]]; then
    local benv; benv="$(bootstrap_env)"
    warn "No VM template yet.${benv:+ On the Proxmox host: dsoadm template --env ${benv}}"
  fi

  install -d -m 700 "$dir"
  {
    cat <<EOF
# dsonode set "${set}". Written by dsonode new from what the API showed.
# Edit freely, then: dsonode plan ${set}

provider: proxmox

proxmox:
  node: ${node}
  pool: ${pool:-CHANGE-ME}
  storage: ${storage:-CHANGE-ME}      # VM disks and cloud-init drive
  template: ${template:-CHANGE-ME}         # VM template ID to clone (type: vm)
  lxc_template: "${lxc_template:-}"   # (type: lxc)

network:
  mode: ${mode}                     # sdn: a vnet of its own | bridge: join an existing bridge
EOF
    if [[ "$mode" == "sdn" ]]; then
      cat <<EOF
  zone: ${zone}
  vnet: ${vnet}                    # created by dsonode, 8 characters max
  cidr: ${cidr}            # node IP = host number in this network
  # gateway: (host 1 of cidr)
  # dns: [1.1.1.1]
EOF
    else
      cat <<EOF
  bridge: ${bridge}                 # vmbr0, a vnet, ...
  cidr: ${cidr}            # the network on that bridge
  # gateway: (host 1 of cidr)
  # vlan: 20
  # dns: [1.1.1.1]
EOF
    fi
    cat <<EOF

vmid_start: ${start}                # nodes get the next free VM IDs from here (written in by plan/up)

defaults:
  vm:  { cores: 2, memory: 2048, disk: 20 }   # MiB, GB
  lxc: { cores: 1, memory: 1024, disk: 8 }

# One line per node (dsonode adds vmid: to each line). host = last number of its IP.
# roles become Ansible groups (use _ not -).
# type: vm (SSH user debian) | lxc (SSH user root; nesting: true for Docker inside)
EOF
    if [[ $k3s -eq 1 ]]; then
      cat <<EOF
# K3s: server = control plane, agent = worker.
# One more agent: copy an agent line, change its name and host. Keep servers at 1, 3 or 5.
nodes:
EOF
      for i in $(seq 1 "$servers"); do
        printf '  server%d: { type: vm, host: %d, roles: [k3s_cluster, server] }\n' "$i" $((10 + i))
      done
      for i in $(seq 1 "$agents"); do
        printf '  agent%d: { type: vm, host: %d, roles: [k3s_cluster, agent] }\n' "$i" $((20 + i))
      done
    else
      cat <<EOF
nodes:
  node1: { type: vm, host: 11, roles: [example] }
  # box1: { type: lxc, host: 21, roles: [example] }
EOF
    fi
  } > "${dir}/nodes.yml"
  chmod 600 "${dir}/nodes.yml"
  echo
  log "Written: ${dir}/nodes.yml"
  info "Next: look at it, then  dsonode plan ${set}"
}

cmd_list() {
  local f set
  printf '  %-16s %s\n' SET STATE
  for f in "$DSONODE_HOME"/*/nodes.yml; do
    [[ -f "$f" ]] || { echo "  (none yet: dsonode new <set>)"; return 0; }
    set="${f%/nodes.yml}"; set="${set##*/}"
    # down leaves a state file with no resources in it: count them, not the file size
    if jq -e '(.resources // []) | length > 0' "${f%/nodes.yml}/terraform.tfstate" >/dev/null 2>&1; then
      printf '  %-16s %s\n' "$set" "built"
    else
      printf '  %-16s %s\n' "$set" "not built"
    fi
  done
}
