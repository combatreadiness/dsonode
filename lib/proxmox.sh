# shellcheck shell=bash
# =============================================================
# lib/proxmox.sh — Proxmox API lookups shared by doctor and new (sourced by dsonode)
# =============================================================

# bootstrap_env  -> name of the proxmox-iac-bootstrap environment on this machine, if exactly one
bootstrap_env() {
  local found=() f
  for f in "$HOME"/.config/*/host.yml; do
    if [[ -f "$f" ]]; then f="${f%/host.yml}"; found+=("${f##*/}"); fi
  done
  if [[ ${#found[@]} -eq 1 ]]; then echo "${found[0]}"; fi
}

need_api() {
  local t
  for t in curl jq tofu; do command -v "$t" >/dev/null || die "$t not found. Run: dsonode doctor"; done
  load_pve_credentials "" || die "No Proxmox credentials. Run: dsonode doctor"
  pve_api /version >/dev/null 2>&1 || die "Proxmox API not reachable. Run: dsonode doctor"
}

# paths_with <permissions json> <prefix> <privilege>  -> rest of every path that has it
paths_with() {
  jq -r --arg pre "$2" --arg priv "$3" \
    '.data | to_entries[] | select((.key | startswith($pre)) and (.value[$priv] == 1)) | .key | ltrimstr($pre)' <<<"$1"
}

# vm_templates  -> "<vmid> <name> (qemu)" for every VM template the token can see
vm_templates() {
  pve_api '/cluster/resources?type=vm' 2>/dev/null \
    | jq -r '.data[] | select(.template == 1 and .type == "qemu") | "\(.vmid) \(.name // "") (\(.type))"'
}

# sdn_cidrs  -> every SDN subnet CIDR the token can see, one per line
sdn_cidrs() {
  local v
  for v in $(pve_api /cluster/sdn/vnets 2>/dev/null | jq -r '.data[].vnet'); do
    pve_api "/cluster/sdn/vnets/${v}/subnets" 2>/dev/null | jq -r '.data[].cidr // empty' || true
  done
}

# set_values <yaml key>  -> that key's value from every other set's nodes.yml (simple "  key: value" lines)
set_values() {
  local f
  for f in "$DSONODE_HOME"/*/nodes.yml; do
    if [[ -f "$f" ]]; then sed -n "s/^[[:space:]]*$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$f"; fi
  done
}

# lxc_templates <node>  -> every LXC template volid on storages with vztmpl content
lxc_templates() {
  local s
  for s in $(pve_api "/nodes/$1/storage" 2>/dev/null \
             | jq -r '.data[] | select((.content // "") | split(",") | index("vztmpl")) | .storage'); do
    pve_api "/nodes/$1/storage/${s}/content?content=vztmpl" 2>/dev/null | jq -r '.data[].volid' || true
  done
}
