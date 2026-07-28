#!/usr/bin/env bash
# Build an offline bundle for disconnected Quay installs on RHEL 9/10.
#
# Run on a subscribed RHEL host (or bastion) WITH internet + registry.redhat.io access.
# Then copy the resulting archive to the air-gapped environment.
#
# Usage:
#   ./scripts/download-offline-bundle.sh
#   ./scripts/download-offline-bundle.sh --rhel-version 9 --rhel-version 10
#   ./scripts/download-offline-bundle.sh --output /tmp/quay-offline-bundle
#   ./scripts/download-offline-bundle.sh --skip-rpms          # images only
#   ./scripts/download-offline-bundle.sh --skip-images        # RPMs only
#   ./scripts/download-offline-bundle.sh --print-manual-steps # print manual cmds & exit
#
# Env:
#   QUAY_VERSION              (default: v3.17.3)
#   QUAY_REGISTRY_USERNAME / QUAY_REGISTRY_PASSWORD  (or pre-existing podman login)
#   QUAY_OFFLINE_OUTPUT       (default: ./quay-offline-bundle)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

QUAY_VERSION="${QUAY_VERSION:-v3.17.3}"
OUTPUT="${QUAY_OFFLINE_OUTPUT:-${REPO_ROOT}/quay-offline-bundle}"
RHEL_VERSIONS=()
SKIP_RPMS=0
SKIP_IMAGES=0
PRINT_MANUAL=0
MAKE_ARCHIVE=1

PACKAGES=(podman acl curl firewalld)

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --rhel-version)
      RHEL_VERSIONS+=("$2"); shift 2 ;;
    --output|-o)
      OUTPUT="$2"; shift 2 ;;
    --quay-version)
      QUAY_VERSION="$2"; shift 2 ;;
    --skip-rpms) SKIP_RPMS=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --no-archive) MAKE_ARCHIVE=0; shift ;;
    --print-manual-steps) PRINT_MANUAL=1; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ ${#RHEL_VERSIONS[@]} -eq 0 ]]; then
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    RHEL_VERSIONS=("${VERSION_ID%%.*}")
  else
    RHEL_VERSIONS=(9)
  fi
fi

for v in "${RHEL_VERSIONS[@]}"; do
  [[ "${v}" == "9" || "${v}" == "10" ]] || die "Unsupported --rhel-version ${v} (use 9 or 10)"
done

quay_image="registry.redhat.io/quay/quay-rhel9:${QUAY_VERSION}"

postgres_image_for() {
  case "$1" in
    9)  echo "registry.redhat.io/rhel9/postgresql-16:latest" ;;
    10) echo "registry.redhat.io/rhel10/postgresql-16:latest" ;;
  esac
}

redis_image_for() {
  # redis-7 is published under rhel9; usable on RHEL 10 hosts as well
  echo "registry.redhat.io/rhel9/redis-7:latest"
}

print_manual_steps() {
  cat <<EOF
================================================================================
Manual offline download steps (connected machine)
================================================================================

Prerequisites on the connected host:
  - Subscribed RHEL ${RHEL_VERSIONS[*]} (for RPM download)
  - podman
  - registry.redhat.io login:
      podman login registry.redhat.io

1) Create bundle directories
--------------------------------------------------------------------------------
BUNDLE=~/quay-offline-bundle
mkdir -p "\$BUNDLE"/{ansible,docs}

EOF

  for v in "${RHEL_VERSIONS[@]}"; do
    pg="$(postgres_image_for "${v}")"
    rd="$(redis_image_for "${v}")"
    cat <<EOF
--- RHEL ${v} ---
mkdir -p "\$BUNDLE/rhel${v}"/{rpms,images}

# RPMs (run on a subscribed RHEL ${v} host)
sudo dnf download --resolve --alldeps --destdir "\$BUNDLE/rhel${v}/rpms" \\
  ${PACKAGES[*]}

# Container images
podman pull ${pg}
podman pull ${rd}
podman pull ${quay_image}

podman save -o "\$BUNDLE/rhel${v}/images/postgresql-16.tar" ${pg}
podman save -o "\$BUNDLE/rhel${v}/images/redis-7.tar" ${rd}
podman save -o "\$BUNDLE/rhel${v}/images/quay-${QUAY_VERSION}.tar" ${quay_image}

EOF
  done

  cat <<EOF
2) Optional: Ansible control-node deps (if bastion is also offline)
--------------------------------------------------------------------------------
# On a connected machine with matching Python:
python3 -m pip download -d "\$BUNDLE/ansible/wheels" -r ${REPO_ROOT}/requirements.txt
ansible-galaxy collection download -r ${REPO_ROOT}/requirements.yml -p "\$BUNDLE/ansible/collections"

3) Package and transfer
--------------------------------------------------------------------------------
tar -C "\$(dirname "\$BUNDLE")" -czf quay-offline-bundle.tar.gz "\$(basename "\$BUNDLE")"
# Copy quay-offline-bundle.tar.gz to the disconnected server (USB/SCP bastion jump).

4) On the disconnected Quay host / bastion
--------------------------------------------------------------------------------
sudo mkdir -p /opt
sudo tar -C /opt -xzf quay-offline-bundle.tar.gz
# Result: /opt/quay-offline-bundle

cd ${REPO_ROOT}
# inventory: set quay_offline_bundle_dir: /opt/quay-offline-bundle
./scripts/setup-vault.sh   # no registry pull needed; still need app secrets
ansible-playbook playbooks/deploy_quay_disconnected.yml

================================================================================
Or use the automated helper on a connected host:
  ./scripts/download-offline-bundle.sh --rhel-version 9 --rhel-version 10
================================================================================
EOF
}

if [[ "${PRINT_MANUAL}" -eq 1 ]]; then
  print_manual_steps
  exit 0
fi

command -v podman >/dev/null 2>&1 || die "podman is required to save container images"
if [[ "${SKIP_RPMS}" -eq 0 ]]; then
  command -v dnf >/dev/null 2>&1 || die "dnf is required to download RPMs (or pass --skip-rpms)"
fi

registry_login() {
  if [[ -n "${QUAY_REGISTRY_USERNAME:-}" && -n "${QUAY_REGISTRY_PASSWORD:-}" ]]; then
    log "Logging in to registry.redhat.io"
    printf '%s\n' "${QUAY_REGISTRY_PASSWORD}" \
      | podman login registry.redhat.io \
          --username "${QUAY_REGISTRY_USERNAME}" \
          --password-stdin
  else
    if ! podman pull --quiet "${quay_image}" >/dev/null 2>&1; then
      warn "Not logged in to registry.redhat.io — attempting interactive login"
      podman login registry.redhat.io
    else
      # pull may have succeeded from cache; ensure we can reach registry for other images
      true
    fi
  fi
}

download_rpms() {
  local ver="$1" dest="$2"
  mkdir -p "${dest}"
  log "Downloading RPMs for RHEL ${ver} into ${dest}"

  local host_major=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    host_major="${VERSION_ID%%.*}"
  fi

  if [[ -n "${host_major}" && "${host_major}" != "${ver}" ]]; then
    warn "This host is RHEL/EL ${host_major}; downloading RPMs for ${ver} may pull wrong arches/deps."
    warn "Prefer running RPM download on a subscribed RHEL ${ver} system (or use --skip-rpms here)."
  fi

  # shellcheck disable=SC2086
  dnf download --resolve --alldeps --destdir "${dest}" "${PACKAGES[@]}"
  (cd "${dest}" && sha256sum *.rpm > SHA256SUMS)
  log "Downloaded $(find "${dest}" -name '*.rpm' | wc -l) RPM(s) for RHEL ${ver}"
}

save_images() {
  local ver="$1" dest="$2"
  local pg rd
  pg="$(postgres_image_for "${ver}")"
  rd="$(redis_image_for "${ver}")"
  mkdir -p "${dest}"

  log "Pulling images for RHEL ${ver}"
  podman pull "${pg}"
  podman pull "${rd}"
  podman pull "${quay_image}"

  log "Saving image tarballs to ${dest}"
  podman save -o "${dest}/postgresql-16.tar" "${pg}"
  podman save -o "${dest}/redis-7.tar" "${rd}"
  podman save -o "${dest}/quay-${QUAY_VERSION}.tar" "${quay_image}"

  cat >"${dest}/images.manifest" <<EOF
postgres_tar: postgresql-16.tar
postgres_ref: ${pg}
redis_tar: redis-7.tar
redis_ref: ${rd}
quay_tar: quay-${QUAY_VERSION}.tar
quay_ref: ${quay_image}
quay_version: ${QUAY_VERSION}
EOF
  (cd "${dest}" && sha256sum *.tar > SHA256SUMS)
}

download_ansible_deps() {
  local dest="$1"
  mkdir -p "${dest}/wheels" "${dest}/collections"
  if command -v python3 >/dev/null 2>&1; then
    log "Downloading Python wheels for bastion (optional)"
    python3 -m pip download -d "${dest}/wheels" -r "${REPO_ROOT}/requirements.txt" \
      || warn "pip download failed (optional) — install Ansible another way on the bastion"
  fi
  if command -v ansible-galaxy >/dev/null 2>&1; then
    log "Downloading Ansible collections (optional)"
    ansible-galaxy collection download -r "${REPO_ROOT}/requirements.yml" -p "${dest}/collections" \
      || warn "ansible-galaxy collection download failed (optional)"
  fi
}

write_manifest() {
  local manifest="$1"
  {
    echo "bundle_format: 1"
    echo "created_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "quay_version: ${QUAY_VERSION}"
    echo "quay_image: ${quay_image}"
    echo "rhel_versions: [${RHEL_VERSIONS[*]}]"
    echo "packages: [${PACKAGES[*]}]"
    echo "skip_rpms: ${SKIP_RPMS}"
    echo "skip_images: ${SKIP_IMAGES}"
  } >"${manifest}"
}

write_bundle_readme() {
  cat >"$1" <<EOF
Quay offline bundle
===================

Created for Quay ${QUAY_VERSION}. Transfer this directory (or the .tar.gz) to the
disconnected environment.

On the disconnected host
------------------------
1. Extract to /opt/quay-offline-bundle (or any path).
2. In inventory/hosts.yml set:

     quay_offline_bundle_dir: /opt/quay-offline-bundle

3. From the playbook repo:

     ./scripts/setup-vault.sh
     ansible-playbook playbooks/deploy_quay_disconnected.yml

The disconnected playbook installs RPMs from rhelX/rpms and loads images from
rhelX/images. It does not contact registry.redhat.io.

Manual image load (if needed)
-----------------------------
  sudo podman load -i /opt/quay-offline-bundle/rhel9/images/postgresql-16.tar
  sudo podman load -i /opt/quay-offline-bundle/rhel9/images/redis-7.tar
  sudo podman load -i /opt/quay-offline-bundle/rhel9/images/quay-${QUAY_VERSION}.tar

Manual RPM install (if needed)
------------------------------
  sudo dnf -y install --disablerepo='*' /opt/quay-offline-bundle/rhel9/rpms/*.rpm
EOF
}

# --- main ---
log "Offline bundle output: ${OUTPUT}"
mkdir -p "${OUTPUT}/docs" "${OUTPUT}/ansible"
write_manifest "${OUTPUT}/manifest.yml"
write_bundle_readme "${OUTPUT}/README-OFFLINE.txt"
print_manual_steps >"${OUTPUT}/docs/MANUAL-DOWNLOAD-STEPS.txt"

if [[ "${SKIP_IMAGES}" -eq 0 ]]; then
  registry_login
fi

for v in "${RHEL_VERSIONS[@]}"; do
  mkdir -p "${OUTPUT}/rhel${v}"/{rpms,images}
  if [[ "${SKIP_RPMS}" -eq 0 ]]; then
    download_rpms "${v}" "${OUTPUT}/rhel${v}/rpms"
  else
    warn "Skipping RPM download for RHEL ${v}"
  fi
  if [[ "${SKIP_IMAGES}" -eq 0 ]]; then
    save_images "${v}" "${OUTPUT}/rhel${v}/images"
  else
    warn "Skipping image download for RHEL ${v}"
  fi
done

download_ansible_deps "${OUTPUT}/ansible" || true

ARCHIVE="${OUTPUT}.tar.gz"
if [[ "${MAKE_ARCHIVE}" -eq 1 ]]; then
  log "Creating ${ARCHIVE}"
  tar -C "$(dirname "${OUTPUT}")" -czf "${ARCHIVE}" "$(basename "${OUTPUT}")"
  (cd "$(dirname "${ARCHIVE}")" && sha256sum "$(basename "${ARCHIVE}")" >"$(basename "${ARCHIVE}").sha256")
  log "Bundle ready: ${ARCHIVE}"
  log "Checksum:     ${ARCHIVE}.sha256"
else
  log "Bundle directory ready: ${OUTPUT}"
fi

cat <<EOF

Next steps:
  1. Copy $(basename "${ARCHIVE:-${OUTPUT}}") to the disconnected site
  2. Extract:  sudo tar -C /opt -xzf quay-offline-bundle.tar.gz
  3. Set inventory var:  quay_offline_bundle_dir: /opt/quay-offline-bundle
  4. Run:  ansible-playbook playbooks/deploy_quay_disconnected.yml

Manual steps were also written to:
  ${OUTPUT}/docs/MANUAL-DOWNLOAD-STEPS.txt
EOF
