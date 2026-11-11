# shellcheck shell=bash
# =============================================================
# lib/tofu.sh — dsonode plan / up / down / inventory: OpenTofu per set (sourced by dsonode)
#   Each set has its own state and working dir in ~/.config/dsonode/<set>/
# =============================================================

TF_PROXMOX="${SCRIPT_DIR}/providers/proxmox"

# set_dir <set>  -> the set's folder, after checking nodes.yml is there and filled in
set_dir() {
  local dir="${DSONODE_HOME}/$1"
  [[ -f "${dir}/nodes.yml" ]] || die "No set '$1'. Create it: dsonode new $1"
  grep -q 'CHANGE-ME' "${dir}/nodes.yml" && die "${dir}/nodes.yml still has CHANGE-ME values."
  echo "$dir"
}

# tofu_env <dir>  -> OpenTofu working dir and state for this set; init once
tofu_env() {
  export TF_DATA_DIR="$1/.terraform"
  export TF_PLUGIN_CACHE_DIR="$HOME/.cache/opentofu/plugins"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  if [[ ! -d "${TF_DATA_DIR}/providers" ]]; then
    log "tofu init (state: $1/terraform.tfstate)"
    tofu -chdir="$TF_PROXMOX" init -input=false -reconfigure -backend-config="path=$1/terraform.tfstate" >/dev/null
  fi
}

# tofu_set <set> <plan|apply|destroy> [args]
tofu_set() {
  local set="$1" sub="$2"; shift 2
  local dir pubkey="$HOME/.ssh/id_ed25519.pub"
  dir="$(set_dir "$set")"
  [[ -f "$pubkey" ]] || die "No ${pubkey}. Create one: ssh-keygen -t ed25519"
  tofu_env "$dir"
  tofu -chdir="$TF_PROXMOX" "$sub" \
    -var "set_name=${set}" \
    -var "config_path=${dir}/nodes.yml" \
    -var "state_dir=${dir}" \
    -var "ssh_public_key=$(cat "$pubkey")" \
    "$@"
}

# wait_ssh  -> wait until port 22 answers on every node (3 minutes each at most).
# Reads "<name> <ip>" lines on stdin.
wait_ssh() {
  local name ip
  while read -r name ip; do
    for _ in $(seq 1 60); do
      if timeout 2 bash -c "</dev/tcp/${ip}/22" 2>/dev/null; then log "${name} ${ip}: SSH up"; continue 2; fi
      sleep 3
    done
    warn "${name} ${ip}: no SSH after 3 minutes (still booting, or not reachable from here)"
  done
}

cmd_plan() {
  [[ $# -ge 1 ]] || die "Usage: dsonode plan <set>"
  need_api
  assign_vmids "$(set_dir "$1")"
  tofu_set "$1" plan
}

cmd_up() {
  [[ $# -ge 1 ]] || die "Usage: dsonode up <set> [-y]"
  local set="$1" dir; shift
  local -a yes=()
  if [[ "${1:-}" == "-y" ]]; then yes=(-auto-approve); fi
  need_api
  dir="$(set_dir "$set")"
  assign_vmids "$dir"
  step "Build ${set}"
  tofu_set "$set" apply "${yes[@]}"
  tofu -chdir="$TF_PROXMOX" output -raw inventory > "${dir}/inventory.yml"
  chmod 600 "${dir}/inventory.yml"
  log "Inventory: ${dir}/inventory.yml"
  step "Waiting for SSH"
  tofu -chdir="$TF_PROXMOX" output -json nodes | jq -r 'to_entries[] | "\(.key) \(.value.ip)"' | wait_ssh
  echo
  info "Try it: ansible -i ${dir}/inventory.yml all -m ping"
}

cmd_down() {
  [[ $# -ge 1 ]] || die "Usage: dsonode down <set> [-y] [--purge]"
  local set="$1" dir purge=0; shift
  local -a yes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) yes=(-auto-approve); shift ;;
      --purge) purge=1; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  need_api
  dir="$(set_dir "$set")"
  step "Destroy ${set}"
  tofu_set "$set" destroy "${yes[@]}"
  rm -f "${dir}/inventory.yml" "${dir}/known_hosts"
  if [[ $purge -eq 1 ]]; then
    rm -rf "$dir"
    log "Set '${set}' removed, nodes.yml too."
  else
    log "Set '${set}' removed. Kept: ${dir}/nodes.yml"
  fi
}

cmd_inventory() {
  [[ $# -ge 1 ]] || die "Usage: dsonode inventory <set>"
  local dir
  dir="$(set_dir "$1")"
  [[ -f "${dir}/inventory.yml" ]] || die "Not built yet. Run: dsonode up $1"
  echo "${dir}/inventory.yml"
}
