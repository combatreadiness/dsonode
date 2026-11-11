# shellcheck shell=bash
# =============================================================
# lib/doctor.sh — dsonode doctor: reads only, changes nothing (sourced by dsonode)
# =============================================================

PROBLEMS=0
problem() { bad "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# Returns 1 when a tool the API checks need is missing
doctor_tools() {
  step "Tools on this machine"
  local t missing=0
  for t in curl jq; do
    if command -v "$t" >/dev/null; then
      log "$t"
    else
      problem "$t not found (apt install $t)"
      missing=1
    fi
  done
  if command -v ssh >/dev/null; then log "ssh"; else problem "ssh not found (apt install openssh-client)"; fi
  if command -v tofu >/dev/null; then
    log "$(tofu version | head -n1)"
  else
    problem "OpenTofu not found (https://opentofu.org/docs/intro/install/)"
  fi
  if command -v ansible >/dev/null; then
    log "$(ansible --version | head -n1) (not needed by dsonode; dsokube and dsopipe use it)"
  else
    warn "Ansible not found. dsonode does not need it; dsokube and dsopipe do."
  fi
  return $missing
}

doctor_this_machine() {
  step "This machine"
  local ip
  ip="$(my_ip)"
  log "Address ${ip:-unknown}"
  info "Guests must be reachable from here over SSH. Put them on a network this address can route to."
  if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    log "SSH key ~/.ssh/id_ed25519.pub (goes into every guest)"
  else
    problem "No ~/.ssh/id_ed25519.pub. Create one: ssh-keygen -t ed25519"
  fi
}

cmd_doctor() {
  local cred=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cred) cred="${2:-}"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if doctor_tools; then
    doctor_this_machine
    doctor_proxmox "$cred"
  else
    doctor_this_machine
    warn "Skipping the Proxmox checks until curl and jq are installed."
  fi
  echo
  if [[ $PROBLEMS -eq 0 ]]; then
    log "No blocking problems."
  else
    bad "${PROBLEMS} problem(s) above."
    exit 1
  fi
}
