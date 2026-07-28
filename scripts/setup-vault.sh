#!/usr/bin/env bash
# Collect Quay credentials, write inventory/group_vars/quay/vault.yml, encrypt with ansible-vault.
# Also manages a local .vault_pass file (gitignored) and wires ansible.cfg to use it.
#
# Usage:
#   ./scripts/setup-vault.sh
#   ./scripts/setup-vault.sh --non-interactive
#   ./scripts/setup-vault.sh --rotate-app-secrets
#   ./scripts/setup-vault.sh --disconnected
#   ./scripts/setup-vault.sh --show
#
# Env (non-interactive / CI):
#   QUAY_REGISTRY_USERNAME  QUAY_REGISTRY_PASSWORD
#   QUAY_DB_PASSWORD  QUAY_DB_ADMIN_PASSWORD  QUAY_REDIS_PASSWORD
#   QUAY_SECRET_KEY  QUAY_DATABASE_SECRET_KEY
#   QUAY_VAULT_PASSWORD     (password that encrypts the vault file)
#   QUAY_GENERATE_SECRETS=1 (default) auto-generate unset app/db/redis secrets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_DIR="${REPO_ROOT}/inventory/group_vars/quay"
VAULT_FILE="${VAULT_DIR}/vault.yml"
VAULT_PASS_FILE="${REPO_ROOT}/.vault_pass"
ANSIBLE_CFG="${REPO_ROOT}/ansible.cfg"

NON_INTERACTIVE=0
ROTATE_APP_SECRETS=0
SHOW_ONLY=0
FORCE=0
DISCONNECTED=0

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -y|--yes|--non-interactive) NON_INTERACTIVE=1; shift ;;
    --rotate-app-secrets) ROTATE_APP_SECRETS=1; shift ;;
    --show) SHOW_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --disconnected) DISCONNECTED=1; shift ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

command -v ansible-vault >/dev/null 2>&1 || die "ansible-vault not found; run ./scripts/setup-bastion.sh first"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# Keep Ansible temp files writable even in restricted environments
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-${REPO_ROOT}/.ansible/tmp}"
mkdir -p "${ANSIBLE_LOCAL_TEMP}"

cd "${REPO_ROOT}"
mkdir -p "${VAULT_DIR}"

prompt_secret() {
  local var="$1" text="$2" default="${3-}" value=""
  if [[ -n "${!var-}" ]]; then
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${default}" ]]; then
      printf -v "${var}" '%s' "${default}"
      return 0
    fi
    die "Missing required value for ${var} (non-interactive mode)"
  fi
  if [[ -n "${default}" ]]; then
    read -r -s -p "${text} [press Enter to use generated]: " value
    printf '\n'
    printf -v "${var}" '%s' "${value:-${default}}"
  else
    while true; do
      read -r -s -p "${text}: " value
      printf '\n'
      [[ -n "${value}" ]] && break
      warn "Value cannot be empty"
    done
    printf -v "${var}" '%s' "${value}"
  fi
}

prompt_value() {
  local var="$1" text="$2" default="${3-}" value=""
  if [[ -n "${!var-}" ]]; then
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    [[ -n "${default}" ]] || die "Missing required value for ${var} (non-interactive mode)"
    printf -v "${var}" '%s' "${default}"
    return 0
  fi
  if [[ -n "${default}" ]]; then
    read -r -p "${text} [${default}]: " value
    printf -v "${var}" '%s' "${value:-${default}}"
  else
    while true; do
      read -r -p "${text}: " value
      [[ -n "${value}" ]] && break
      warn "Value cannot be empty"
    done
    printf -v "${var}" '%s' "${value}"
  fi
}

gen_password() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
}

gen_uuid() {
  python3 -c 'import uuid; print(uuid.uuid4())'
}

ensure_vault_pass() {
  if [[ -f "${VAULT_PASS_FILE}" ]]; then
    log "Using existing vault password file: ${VAULT_PASS_FILE}"
    return 0
  fi

  local vault_pw="${QUAY_VAULT_PASSWORD-}"
  if [[ -z "${vault_pw}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      vault_pw="$(gen_password)"
      log "Generated vault password (saved to ${VAULT_PASS_FILE})"
    else
      local generated
      generated="$(gen_password)"
      prompt_secret vault_pw "Ansible vault password (encrypts vault.yml)" "${generated}"
    fi
  fi

  umask 077
  printf '%s\n' "${vault_pw}" >"${VAULT_PASS_FILE}"
  chmod 600 "${VAULT_PASS_FILE}"
  log "Wrote ${VAULT_PASS_FILE} (gitignored, mode 0600)"
}

ensure_ansible_cfg_vault_file() {
  if grep -qE '^[[:space:]]*vault_password_file[[:space:]]*=' "${ANSIBLE_CFG}" 2>/dev/null; then
    return 0
  fi
  python3 - <<PY
from pathlib import Path
path = Path("${ANSIBLE_CFG}")
text = path.read_text() if path.exists() else "[defaults]\n"
lines = text.splitlines(keepends=True)
out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.strip() == "[defaults]":
        out.append("vault_password_file = .vault_pass\n")
        inserted = True
if not inserted:
    out.append("\n[defaults]\nvault_password_file = .vault_pass\n")
path.write_text("".join(out))
PY
  log "Configured ansible.cfg to use vault_password_file = .vault_pass"
}

write_vault_yaml() {
  local tmp
  tmp="$(mktemp)"
  export _V_REG_USER="${quay_registry_username}"
  export _V_REG_PASS="${quay_registry_password}"
  export _V_DB_PASS="${quay_db_password}"
  export _V_DB_ADMIN="${quay_db_admin_password}"
  export _V_REDIS="${quay_redis_password}"
  export _V_SECRET="${quay_secret_key}"
  export _V_DB_SECRET="${quay_database_secret_key}"

  python3 - <<'PY' >"${tmp}"
import json
import os

def q(key: str) -> str:
    return json.dumps(os.environ[key], ensure_ascii=False)

print("# Generated by scripts/setup-vault.sh — DO NOT COMMIT")
print("---")
print(f"quay_registry_username: {q('_V_REG_USER')}")
print(f"quay_registry_password: {q('_V_REG_PASS')}")
print(f"quay_db_password: {q('_V_DB_PASS')}")
print(f"quay_db_admin_password: {q('_V_DB_ADMIN')}")
print(f"quay_redis_password: {q('_V_REDIS')}")
print(f"quay_secret_key: {q('_V_SECRET')}")
print(f"quay_database_secret_key: {q('_V_DB_SECRET')}")
PY

  umask 077
  mv -f "${tmp}" "${VAULT_FILE}"
  chmod 600 "${VAULT_FILE}"
}

encrypt_vault() {
  ensure_vault_pass
  ensure_ansible_cfg_vault_file

  if head -1 "${VAULT_FILE}" | grep -q '^\$ANSIBLE_VAULT;'; then
    die "Refusing to encrypt: ${VAULT_FILE} is already vault-encrypted. Re-run after plaintext write failed."
  fi

  # ansible.cfg already points at .vault_pass — do not also pass --vault-password-file
  ansible-vault encrypt "${VAULT_FILE}"
  chmod 600 "${VAULT_FILE}"
  log "Encrypted ${VAULT_FILE}"
}

load_existing_vault_if_any() {
  [[ -f "${VAULT_FILE}" ]] || return 0
  [[ -f "${VAULT_PASS_FILE}" ]] || return 0
  if ! ansible-vault view "${VAULT_FILE}" >/dev/null 2>&1; then
    return 0
  fi
  log "Loading existing encrypted vault for merge"
  local parsed
  parsed="$(
    ansible-vault view "${VAULT_FILE}" \
      | python3 -c '
import json, sys
data = {}
for raw in sys.stdin:
    line = raw.strip()
    if not line or line.startswith("#") or line == "---":
        continue
    if ":" not in line:
        continue
    key, _, rest = line.partition(":")
    key = key.strip()
    rest = rest.strip()
    if rest.startswith("\""):
        data[key] = json.loads(rest)
    elif rest.startswith("\x27"):
        data[key] = rest[1:-1].replace("\x27\x27", "\x27")
    else:
        data[key] = rest
for k, v in data.items():
    s = str(v).replace("\x27", "\x27\"\x27\"\x27")
    print("export %s=\x27%s\x27" % (k, s))
'
  )"
  # shellcheck disable=SC1090
  eval "${parsed}"
}

if [[ "${SHOW_ONLY}" -eq 1 ]]; then
  [[ -f "${VAULT_FILE}" ]] || die "No vault at ${VAULT_FILE}; run ./scripts/setup-vault.sh first"
  [[ -f "${VAULT_PASS_FILE}" ]] || die "Missing ${VAULT_PASS_FILE}; cannot decrypt"
  ensure_ansible_cfg_vault_file
  ansible-vault view "${VAULT_FILE}"
  exit 0
fi

if [[ -f "${VAULT_FILE}" && "${FORCE}" -eq 0 ]]; then
  if head -1 "${VAULT_FILE}" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT;'; then
    load_existing_vault_if_any
    log "Existing vault found — updating values"
  else
    warn "Found unencrypted ${VAULT_FILE}; it will be replaced and encrypted"
  fi
fi

quay_registry_username="${QUAY_REGISTRY_USERNAME-${quay_registry_username-}}"
quay_registry_password="${QUAY_REGISTRY_PASSWORD-${quay_registry_password-}}"
quay_db_password="${QUAY_DB_PASSWORD-${quay_db_password-}}"
quay_db_admin_password="${QUAY_DB_ADMIN_PASSWORD-${quay_db_admin_password-}}"
quay_redis_password="${QUAY_REDIS_PASSWORD-${quay_redis_password-}}"
quay_secret_key="${QUAY_SECRET_KEY-${quay_secret_key-}}"
quay_database_secret_key="${QUAY_DATABASE_SECRET_KEY-${quay_database_secret_key-}}"

generate="${QUAY_GENERATE_SECRETS:-1}"

log "Collecting credentials for Ansible Vault"
if [[ "${DISCONNECTED}" -eq 1 ]]; then
  log "Disconnected mode — registry.redhat.io credentials are not required"
  quay_registry_username="${quay_registry_username:-offline}"
  quay_registry_password="${quay_registry_password:-offline-not-used}"
else
  prompt_value quay_registry_username "registry.redhat.io username"
  prompt_secret quay_registry_password "registry.redhat.io password / token"
fi

if [[ "${ROTATE_APP_SECRETS}" -eq 1 ]]; then
  quay_db_password="$(gen_password)"
  quay_db_admin_password="$(gen_password)"
  quay_redis_password="$(gen_password)"
  quay_secret_key="$(gen_uuid)"
  quay_database_secret_key="$(gen_uuid)"
  log "Rotated DB/Redis/application secrets"
elif [[ "${generate}" == "1" ]]; then
  [[ -n "${quay_db_password}" ]] || quay_db_password="$(gen_password)"
  [[ -n "${quay_db_admin_password}" ]] || quay_db_admin_password="$(gen_password)"
  [[ -n "${quay_redis_password}" ]] || quay_redis_password="$(gen_password)"
  [[ -n "${quay_secret_key}" ]] || quay_secret_key="$(gen_uuid)"
  [[ -n "${quay_database_secret_key}" ]] || quay_database_secret_key="$(gen_uuid)"
fi

prompt_secret quay_db_password "Quay DB password" "${quay_db_password}"
prompt_secret quay_db_admin_password "Quay DB admin password" "${quay_db_admin_password}"
prompt_secret quay_redis_password "Redis password" "${quay_redis_password}"
prompt_secret quay_secret_key "Quay SECRET_KEY" "${quay_secret_key}"
prompt_secret quay_database_secret_key "Quay DATABASE_SECRET_KEY" "${quay_database_secret_key}"

for v in quay_registry_username quay_registry_password quay_db_password \
         quay_db_admin_password quay_redis_password quay_secret_key \
         quay_database_secret_key; do
  val="${!v}"
  [[ -n "${val}" ]] || die "${v} is empty"
  [[ "${val}" != CHANGE_ME* ]] || die "${v} still looks like a placeholder"
done

log "Writing secrets to ${VAULT_FILE}"
write_vault_yaml
encrypt_vault

unset _V_REG_USER _V_REG_PASS _V_DB_PASS _V_DB_ADMIN _V_REDIS _V_SECRET _V_DB_SECRET \
  quay_registry_password quay_db_password quay_db_admin_password quay_redis_password \
  quay_secret_key quay_database_secret_key QUAY_REGISTRY_PASSWORD QUAY_DB_PASSWORD \
  QUAY_DB_ADMIN_PASSWORD QUAY_REDIS_PASSWORD QUAY_SECRET_KEY QUAY_DATABASE_SECRET_KEY \
  QUAY_VAULT_PASSWORD 2>/dev/null || true

cat <<EOF

Vault ready.
  Secrets file : ${VAULT_FILE} (encrypted, gitignored)
  Vault pass   : ${VAULT_PASS_FILE} (gitignored)

Deploy with:
  ansible-playbook playbooks/deploy_quay.yml
  # or disconnected:
  # ansible-playbook playbooks/deploy_quay_disconnected.yml

View secrets:
  ./scripts/setup-vault.sh --show

Rotate DB/Redis/app secrets:
  ./scripts/setup-vault.sh --rotate-app-secrets
EOF
