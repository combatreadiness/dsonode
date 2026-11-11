# shellcheck shell=bash
# =============================================================
# lib/vmid.sh — give every node a VM ID once, and write it into nodes.yml (sourced by dsonode)
#
#   Start: the management node's ID + 1 (from host.yml, written by dsoadm facts),
#          else vmid_start in nodes.yml, else 100.
#   Then the next free ID, skipping IDs Proxmox already has and IDs other sets wrote down.
#   A node that already has vmid: keeps it, so plans stay stable.
#   nodes.yml must keep one node per line:  name: { type: vm, host: 11, ... }
# =============================================================

# mgmt_ctid  -> the bootstrap management node's ID from host.yml (mgmt.ctid), if written there
mgmt_ctid() {
  local env f
  env="$(bootstrap_env)"
  [[ -n "$env" ]] || return 0
  f="$HOME/.config/${env}/host.yml"
  sed -n '/^mgmt:/,/^[^[:space:]]/s/^[[:space:]]*ctid:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -n1
}

# yaml_vmids <file>  -> every "vmid: N" in that nodes.yml
yaml_vmids() { grep -oE 'vmid:[[:space:]]*[0-9]+' "$1" | grep -oE '[0-9]+' || true; }

# vmid_free <id>  -> exit 0 if Proxmox says nothing uses that ID
VMID_CHECK_WARNED=0
vmid_free() {
  local out
  if out="$(pve_api "/cluster/nextid?vmid=$1" 2>&1)"; then return 0; fi
  [[ "$out" == *"HTTP 400"* ]] && return 1
  # The token may not be allowed to ask: fall back to the guests it can see
  if [[ $VMID_CHECK_WARNED -eq 0 ]]; then
    warn "Cannot ask Proxmox for free IDs (${out}); checking only the guests this token can see."
    VMID_CHECK_WARNED=1
  fi
  ! pve_api '/cluster/resources?type=vm' 2>/dev/null | jq -e --argjson id "$1" '.data[] | select(.vmid == $id)' >/dev/null
}

# assign_vmids <dir>  -> add vmid: to every node line in <dir>/nodes.yml that has none
assign_vmids() {
  local file="$1/nodes.yml" start ctid used id name f
  ctid="$(mgmt_ctid)"
  start="$(sed -n 's/^vmid_start:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | head -n1)"
  if [[ -n "$ctid" ]]; then start=$((ctid + 1)); fi
  start="${start:-100}"

  # IDs written down in this set and in every other set
  used=" "
  for f in "$DSONODE_HOME"/*/nodes.yml; do
    if [[ -f "$f" ]]; then used+="$(yaml_vmids "$f" | tr '\n' ' ')"; fi
  done

  id=$start
  while read -r name; do
    while [[ "$used" == *" ${id} "* ]] || ! vmid_free "$id"; do id=$((id + 1)); done
    sed -i -E "s/^(  ${name}:[[:space:]]*\{)[[:space:]]*/\1 vmid: ${id}, /" "$file"
    log "${name}: VM ID ${id}"
    used+="${id} "
    id=$((id + 1))
  done < <(sed -n '/^nodes:/,$p' "$file" | grep -E '^  [a-z0-9_-]+:[[:space:]]*\{' | grep -v 'vmid:' \
             | sed -E 's/^  ([a-z0-9_-]+):.*/\1/')
}
