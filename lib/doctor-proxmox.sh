# shellcheck shell=bash
# =============================================================
# lib/doctor-proxmox.sh — the Proxmox part of dsonode doctor (sourced by dsonode)
# =============================================================

doctor_proxmox() {
  local cred="$1" out
  step "Proxmox API"
  if ! load_pve_credentials "$cred"; then
    problem "No Proxmox credentials. Export PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN, or use --cred FILE."
    return
  fi
  log "Credentials from ${CRED_SOURCE}"
  info "endpoint ${PROXMOX_VE_ENDPOINT}, token ${PROXMOX_VE_API_TOKEN%%=*}"
  if [[ "${PROXMOX_VE_INSECURE:-false}" == "true" ]]; then info "TLS certificate check is off (PROXMOX_VE_INSECURE=true)"; fi

  if ! out="$(pve_api /version 2>&1)"; then
    case "$out" in
      *401*) problem "Token rejected (401)." ;;
      *000*) problem "Cannot reach ${PROXMOX_VE_ENDPOINT} (network, firewall or TLS)." ;;
      *)     problem "Unexpected answer from the API: ${out}" ;;
    esac
    return
  fi
  log "Proxmox VE $(jq -r '.data.version' <<<"$out")"

  # ---------- Nodes ----------
  step "Nodes"
  local nodes name status
  nodes="$(pve_api /nodes | jq -r '.data[] | "\(.node) \(.status // "?")"')" \
    || { problem "Cannot list nodes."; return; }
  while read -r name status; do
    if [[ "$status" == "online" ]]; then log "${name} (${status})"; else warn "${name} (${status})"; fi
  done <<<"$nodes"
  NODE="$(awk '$2 == "online" {print $1; exit}' <<<"$nodes")"
  [[ -n "$NODE" ]] || { problem "No online node."; return; }
  if [[ "$(wc -l <<<"$nodes")" -gt 1 ]]; then info "Using ${NODE} for the checks below"; fi

  # ---------- What the token may do ----------
  step "What this token may do"
  local perms pools stores zones vnet_zones
  perms="$(pve_api /access/permissions)" || { problem "Cannot read the token's permissions."; return; }
  if jq -e '.data | has("/")' <<<"$perms" >/dev/null; then
    warn "Token has rights on / (whole datacenter). Fine for testing, too broad otherwise."
  fi
  pools="$(paths_with "$perms" /pool/ VM.Allocate | join_lines)"
  stores="$(paths_with "$perms" /storage/ Datastore.AllocateSpace | join_lines)"
  zones="$(paths_with "$perms" /sdn/zones/ SDN.Use | join_lines)"
  vnet_zones="$(paths_with "$perms" /sdn/zones/ SDN.Allocate | join_lines)"
  if [[ -n "$pools" ]];  then log "Pools it can create guests in: ${pools}"; else warn "No pool with VM.Allocate listed"; fi
  if [[ -n "$stores" ]]; then log "Storage it can put disks on: ${stores}"; else warn "No storage with Datastore.AllocateSpace listed"; fi
  if [[ -n "$zones" ]];  then log "SDN zones it can use: ${zones}"; else info "No SDN zone. Bridge mode only (vmbr0 and friends)."; fi
  if [[ -n "$vnet_zones" ]]; then info "can also create vnets in: ${vnet_zones}"; fi

  # ---------- Storage ----------
  step "Storage on ${NODE}"
  local storage_json sname stype sfree sactive skinds
  storage_json="$(pve_api "/nodes/${NODE}/storage")" || { problem "Cannot list storage on ${NODE}."; return; }
  while IFS=$'\t' read -r sname stype sfree sactive skinds; do
    if [[ "$sactive" == "1" ]]; then
      log "$(printf '%-14s %-8s %6s GiB free   %s' "$sname" "$stype" "$sfree" "$skinds")"
    else
      warn "$(printf '%-14s %-8s (inactive)' "$sname" "$stype")"
    fi
  done < <(jq -r '
    {"images": "VM disks", "rootdir": "LXC disks", "vztmpl": "LXC templates", "iso": "ISO", "import": "image import"} as $w
    | .data | sort_by(.storage)[]
    | [ .storage, (.type // "?"), ((.avail // 0) / 1073741824 | floor | tostring), ((.active // 0) | tostring),
        ([(.content // "") | split(",")[] | $w[.] // empty] | join(", ") | if . == "" then "-" else . end) ]
    | @tsv' <<<"$storage_json")

  # ---------- Images ----------
  step "Images it can start from"
  local templates benv line
  templates="$(vm_templates)" || templates=""
  if [[ -n "$templates" ]]; then
    while read -r line; do log "Template ${line}"; done <<<"$templates"
  else
    benv="$(bootstrap_env)"
    if [[ -n "$benv" ]]; then
      warn "No VM template visible to this token. On the Proxmox host: dsoadm template --env ${benv}"
    else
      warn "No VM template visible to this token. Create a cloud-init VM template first."
    fi
  fi

  local s lxc_found=0 volids
  for s in $(jq -r '.data[] | select((.content // "") | split(",") | index("vztmpl")) | .storage' <<<"$storage_json"); do
    volids="$(pve_api "/nodes/${NODE}/storage/${s}/content?content=vztmpl" 2>/dev/null | jq -r '.data[].volid')" || continue
    while read -r line; do
      if [[ -n "$line" ]]; then log "LXC template ${line}"; lxc_found=1; fi
    done <<<"$volids"
  done
  if [[ $lxc_found -eq 0 ]]; then
    warn "No LXC template found. On the host: pveam update && pveam available --section system"
  fi

  # ---------- Network ----------
  step "Networks guests can join"
  local bridges vnets iface addr vnet zone alias
  bridges="$(pve_api "/nodes/${NODE}/network?type=any_bridge" 2>/dev/null \
    | jq -r '.data[] | "\(.iface) \(.cidr // .address // "")"')" || bridges=""
  if [[ -n "$bridges" ]]; then
    while read -r iface addr; do log "Bridge ${iface}${addr:+ ${addr}}"; done <<<"$bridges"
  else
    warn "Cannot list bridges (the token needs Sys.Audit on /nodes/${NODE}). Bridge mode still works if you name one."
  fi
  vnets="$(pve_api /cluster/sdn/vnets 2>/dev/null \
    | jq -r '.data[] | "\(.vnet) \(.zone // "-") \(.alias // "")"')" || vnets=""
  if [[ -n "$vnets" ]]; then
    while read -r vnet zone alias; do log "SDN vnet ${vnet} (zone ${zone}${alias:+, ${alias}})"; done <<<"$vnets"
  else
    info "No SDN vnets visible (none, or no SDN rights). Bridge mode works without SDN."
  fi
}
