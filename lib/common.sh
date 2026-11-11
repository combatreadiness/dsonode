# shellcheck shell=bash
# =============================================================
# lib/common.sh — shared by dsonode (sourced, not run)
# Needs: bash, curl, jq. YAML is read by OpenTofu, not here.
# =============================================================

log()  { echo -e "  \e[1;32m✔\e[0m $*"; }
warn() { echo -e "  \e[1;33m⚠\e[0m $*"; }
bad()  { echo -e "  \e[1;31m✖\e[0m $*"; }
die()  { echo -e "  \e[1;31m✖\e[0m $*" >&2; exit 1; }
info() { echo -e "    \e[2m$*\e[0m"; }
step() { echo -e "\n\e[1m▸ $*\e[0m"; }

# join_lines  -> "a, b, c" from one item per line on stdin
join_lines() { paste -sd, - | sed 's/,/, /g'; }

# ---------- IPv4 helpers (no python) ----------
ip2int() { local IFS=.; local -a o; read -r -a o <<<"$1"; echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] )); }

# cidr_overlap <a.b.c.d/n> <a.b.c.d/m>  -> exit 0 when the two networks overlap
cidr_overlap() {
  local n1="${1%/*}" m1="${1#*/}" n2="${2%/*}" m2="${2#*/}" m
  m=$(( m1 < m2 ? m1 : m2 ))
  (( m == 0 )) && return 0
  (( ($(ip2int "$n1") >> (32 - m)) == ($(ip2int "$n2") >> (32 - m)) ))
}

# my_ip  -> this machine's address on the default route
my_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}'; }

# ---------- Proxmox credentials ----------
# Order: variables already in the shell, then --cred FILE / DSONODE_CRED,
# then the only proxmox-iac-bootstrap credentials file on this machine.
# Sets CRED_SOURCE to say where they came from.
load_pve_credentials() {
  local file="${1:-${DSONODE_CRED:-}}" found=() f
  if [[ -n "${PROXMOX_VE_ENDPOINT:-}" && -n "${PROXMOX_VE_API_TOKEN:-}" && -z "$file" ]]; then
    # shellcheck disable=SC2034  # read in doctor-proxmox.sh
    CRED_SOURCE="environment variables"
    return 0
  fi
  if [[ -z "$file" ]]; then
    for f in "$HOME"/.config/*/credentials.env; do
      if [[ -f "$f" ]]; then found+=("$f"); fi
    done
    case "${#found[@]}" in
      0) return 1 ;;
      1) file="${found[0]}" ;;
      *) die "Several credentials files (${found[*]}). Pick one: --cred FILE" ;;
    esac
  fi
  [[ -r "$file" ]] || die "Cannot read credentials file ${file}"
  set -a
  # shellcheck source=/dev/null
  . "$file"
  set +a
  # shellcheck disable=SC2034  # read in doctor-proxmox.sh
  CRED_SOURCE="$file"
  [[ -n "${PROXMOX_VE_ENDPOINT:-}" && -n "${PROXMOX_VE_API_TOKEN:-}" ]]
}

# pve_api <path>  -> the response JSON on stdout. On failure: "HTTP <code>" on stderr, exit 1.
# Read-only (GET). The token goes in a header file so it never shows up in `ps`.
pve_api() {
  local hdr tmp code
  local -a tls=()
  hdr="$(mktemp)"; tmp="$(mktemp)"
  printf 'Authorization: PVEAPIToken=%s\n' "$PROXMOX_VE_API_TOKEN" > "$hdr"
  if [[ "${PROXMOX_VE_INSECURE:-false}" == "true" ]]; then tls=(-k); fi
  code=$(curl -s "${tls[@]}" --max-time 15 -o "$tmp" -w '%{http_code}' -H "@${hdr}" \
    "${PROXMOX_VE_ENDPOINT%/}/api2/json$1" || true)
  rm -f "$hdr"
  if [[ "$code" == "200" ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  echo "HTTP ${code}" >&2
  return 1
}
