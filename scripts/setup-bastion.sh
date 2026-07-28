#!/usr/bin/env bash
# Bootstrap a RHEL 9/10 bastion (Ansible control node) for quay-standalone-rhel.
# Run as root or with sudo:  sudo ./scripts/setup-bastion.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  die "Run this script as root (sudo ./scripts/setup-bastion.sh)"
fi

if [[ ! -f /etc/os-release ]]; then
  die "/etc/os-release not found"
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID}-${VERSION_ID%%.*}" in
  rhel-9|rhel-10|centos-9|centos-10|rocky-9|rocky-10|almalinux-9|almalinux-10)
    log "Detected ${NAME} ${VERSION_ID}"
    ;;
  *)
    die "Unsupported OS: ${NAME:-unknown} ${VERSION_ID:-unknown} (need RHEL 9/10 or compatible)"
    ;;
esac

INSTALL_USER="${SUDO_USER:-${QUAY_BASTION_USER:-}}"

if [[ -n "${INSTALL_USER}" && "${INSTALL_USER}" != "root" ]]; then
  getent passwd "${INSTALL_USER}" >/dev/null || die "Cannot resolve user ${INSTALL_USER}"
  RUN_AS_USER=(runuser -u "${INSTALL_USER}" --)
else
  INSTALL_USER="root"
  RUN_AS_USER=()
fi

log "Updating system packages"
dnf -y upgrade

log "Installing bastion packages (Python, SSH helpers, build tools)"
dnf -y install \
  python3 \
  python3-pip \
  python3-devel \
  python3-setuptools \
  python3-wheel \
  gcc \
  make \
  openssl \
  openssl-devel \
  libffi-devel \
  git \
  rsync \
  sshpass \
  tar \
  unzip \
  which \
  curl \
  wget \
  jq \
  ansible-core

# Ensure pip itself is current for the install user
log "Upgrading pip / setuptools / wheel"
if [[ "${INSTALL_USER}" == "root" ]]; then
  python3 -m pip install --upgrade pip setuptools wheel
else
  "${RUN_AS_USER[@]}" python3 -m pip install --user --upgrade pip setuptools wheel
fi

log "Installing Python requirements from ${REPO_ROOT}/requirements.txt"
if [[ "${INSTALL_USER}" == "root" ]]; then
  python3 -m pip install --upgrade -r "${REPO_ROOT}/requirements.txt"
else
  "${RUN_AS_USER[@]}" python3 -m pip install --user --upgrade -r "${REPO_ROOT}/requirements.txt"
fi

log "Installing Ansible collections from ${REPO_ROOT}/requirements.yml"
if [[ "${INSTALL_USER}" == "root" ]]; then
  ansible-galaxy collection install -r "${REPO_ROOT}/requirements.yml" --upgrade
else
  "${RUN_AS_USER[@]}" ansible-galaxy collection install -r "${REPO_ROOT}/requirements.yml" --upgrade
fi

log "Verifying toolchain"
if [[ "${INSTALL_USER}" == "root" ]]; then
  python3 --version
  pip3 --version
  ansible --version
  ansible-galaxy collection list
else
  "${RUN_AS_USER[@]}" python3 --version
  "${RUN_AS_USER[@]}" python3 -m pip --version
  "${RUN_AS_USER[@]}" ansible --version
  "${RUN_AS_USER[@]}" ansible-galaxy collection list
fi

cat <<EOF

Bastion setup complete on ${NAME} ${VERSION_ID}.

Next steps:
  1. cd ${REPO_ROOT}
  2. cp inventory/hosts.yml.example inventory/hosts.yml
  3. Edit inventory/hosts.yml (ansible_host, quay_hostname)
  4. ./scripts/setup-vault.sh          # save credentials into Ansible Vault
  5. ansible-playbook playbooks/deploy_quay.yml

Installed for user: ${INSTALL_USER}
EOF
