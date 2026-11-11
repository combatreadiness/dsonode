#!/usr/bin/env bash
# =============================================================
# install.sh — entry point for dsonode
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/combatreadiness/dsonode/main/install.sh)"
#
# Run on the machine that will build the guests (a proxmox-iac-bootstrap management node,
# or any Linux box with OpenTofu that can reach the Proxmox API), as root.
#
# What it does, in order:
#   1) Checks: root, required commands
#   2) Downloads one release archive (+ SHA256SUMS) into a temp folder and verifies it
#   3) Installs to /usr/local/lib/dsonode, links /usr/local/bin/dsonode
#   4) Runs `dsonode doctor` (reads only)
#
# Environment (all optional):
#   DSONODE_REF=latest|vX.Y.Z|main   What to install (default: latest release)
#   DSONODE_REPO=owner/name          Install from a fork
#   DSONODE_SRC=/path/to/checkout    Install from a local folder instead of GitHub (development)
#   DSONODE_NO_DOCTOR=1              Skip the doctor run at the end
# Re-run  : Safe. Replaces the installed files; your sets in ~/.config/dsonode stay.
# =============================================================
set -euo pipefail

NAME="dsonode"
REPO="${DSONODE_REPO:-combatreadiness/dsonode}"
REF="${DSONODE_REF:-latest}"
SRC="${DSONODE_SRC:-}"
LIB_DIR="/usr/local/lib/${NAME}"
BIN_LINK="/usr/local/bin/${NAME}"
REQUIRED_FILES=(dsonode lib/common.sh lib/proxmox.sh lib/doctor.sh lib/doctor-proxmox.sh
                lib/new.sh lib/vmid.sh lib/tofu.sh providers/proxmox/main.tf)
NEEDS=(curl tar gzip sha256sum jq ssh)

# ---------- Output (same look as proxmox-iac-bootstrap) ----------
GN=$'\e[1;32m'; YW=$'\e[1;33m'; RD=$'\e[1;31m'; BL=$'\e[1;36m'; DIM=$'\e[2m'; CL=$'\e[0m'
msg_info() { printf '  %s…%s %s' "$YW" "$CL" "$1"; }
msg_ok()   { printf '\r\e[K  %s✔%s %s\n' "$GN" "$CL" "$1"; }
msg_skip() { printf '\r\e[K  %s–%s %s\n' "$YW" "$CL" "$1"; }
msg_err()  { printf '\r\e[K  %s✖%s %s\n' "$RD" "$CL" "$1" >&2; exit 1; }

cat <<BANNER
${BL}
   ┌──────────────────────────────────────────────┐
   │   dsonode                                    │
   │   VMs and LXCs from one YAML · OpenTofu      │
   └──────────────────────────────────────────────┘
${CL}
BANNER

TMP=""
cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

# =============================================================
echo "${DIM}  This machine${CL}"
# =============================================================
[[ $EUID -eq 0 ]] || msg_err "Run as root (it installs to ${LIB_DIR})."
for c in "${NEEDS[@]}"; do
  command -v "$c" >/dev/null || msg_err "Missing command: $c (apt install $c)"
done
msg_ok "Required commands present"
if command -v tofu >/dev/null; then
  msg_ok "$(tofu version | head -n1)"
else
  msg_skip "OpenTofu not found. dsonode needs it: https://opentofu.org/docs/intro/install/"
fi

# =============================================================
echo; echo "${DIM}  Download${CL}"
# =============================================================
TMP="$(mktemp -d)"
cd "$TMP"

fetch() {  # fetch <url> <file>
  curl -fsSL --proto '=https' --retry 3 --retry-delay 2 -o "$2" "$1" || msg_err "Download failed: $1"
}

if [[ -n "$SRC" ]]; then
  [[ -d "$SRC" ]] || msg_err "DSONODE_SRC is not a folder: ${SRC}"
  mkdir src
  (cd "$SRC" && tar --exclude=.git -cf - .) | tar -xf - -C src
  TAG="local"
  if command -v git >/dev/null && git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
    TAG="local-$(git -C "$SRC" rev-parse --short HEAD)"
  fi
  echo "$TAG" > src/VERSION
  msg_skip "Using local folder ${SRC} (${TAG}), no checksum"
else
  msg_info "Finding release"
  if [[ "$REF" == "latest" ]]; then
    url=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest") \
      || msg_err "Cannot reach GitHub to find the latest release."
    TAG="${url##*/}"
    [[ "$TAG" == v* ]] || msg_err "No release found for ${REPO}. Use DSONODE_REF=main to install from the branch."
  else
    TAG="$REF"
  fi
  msg_ok "${REPO} ${TAG}"

  if [[ "$TAG" == v* ]]; then
    ARCHIVE="${NAME}-${TAG}.tar.gz"
    base="https://github.com/${REPO}/releases/download/${TAG}"
    msg_info "Downloading ${ARCHIVE}"
    fetch "${base}/${ARCHIVE}" "$ARCHIVE"
    fetch "${base}/SHA256SUMS" SHA256SUMS
    msg_ok "Downloaded ${ARCHIVE}"
    line=$(grep -E "  ${ARCHIVE}\$" SHA256SUMS || true)
    [[ -n "$line" ]] || msg_err "${ARCHIVE} is not listed in SHA256SUMS."
    echo "$line" | sha256sum -c --quiet - >/dev/null 2>&1 || msg_err "Checksum mismatch for ${ARCHIVE}."
    msg_ok "SHA256 verified"
  else
    ARCHIVE="${NAME}-src.tar.gz"
    msg_info "Downloading ${TAG}"
    fetch "https://github.com/${REPO}/archive/${TAG}.tar.gz" "$ARCHIVE"
    msg_skip "No checksum for a branch build (${TAG}); use a release for normal installs"
  fi
  mkdir src
  tar -xzf "$ARCHIVE" -C src --strip-components=1 || msg_err "Cannot extract ${ARCHIVE}."
fi

for f in "${REQUIRED_FILES[@]}"; do
  [[ -f "src/$f" ]] || msg_err "Archive is missing ${f}."
done
[[ -f src/VERSION ]] || echo "${TAG}" > src/VERSION
msg_ok "All files present"

# =============================================================
echo; echo "${DIM}  Install${CL}"
# =============================================================
chmod 755 "src/${NAME}"
rm -rf "${LIB_DIR}.new"
mkdir -p "$(dirname "$LIB_DIR")"
cp -a src "${LIB_DIR}.new"
chown -R root:root "${LIB_DIR}.new"
if [[ -d "$LIB_DIR" ]]; then rm -rf "${LIB_DIR}.old"; mv "$LIB_DIR" "${LIB_DIR}.old"; fi
mv "${LIB_DIR}.new" "$LIB_DIR"
rm -rf "${LIB_DIR}.old"
ln -sfn "${LIB_DIR}/${NAME}" "$BIN_LINK"
msg_ok "Installed ${LIB_DIR} ($(cat "${LIB_DIR}/VERSION"))"
msg_ok "Linked ${BIN_LINK}"
cd /

if [[ "${DSONODE_NO_DOCTOR:-0}" != "1" ]]; then
  echo
  "$BIN_LINK" doctor || true
fi
echo
echo "  Next: ${BL}dsonode new <set>${CL}   then edit ~/.config/dsonode/<set>/nodes.yml and ${BL}dsonode up <set>${CL}"
