#!/usr/bin/env bash
# Fail if files that must not be committed are staged or present as tracked paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

blocked_patterns=(
  'inventory/hosts.yml'
  'inventory/group_vars/.*/vault\.yml$'
  'group_vars/.*/vault\.yml$'
  'group_vars/vault\.yml$'
  'auth\.json$'
  '\.vault_pass'
  'credentials\.yml$'
  'secrets\.yml$'
  '\.pem$'
  '\.key$'
  'ssl\.cert$'
  'ssl\.key$'
)

fail=0

check_paths() {
  local label="$1"
  shift
  local paths=("$@")
  [[ ${#paths[@]} -eq 0 ]] && return 0
  for path in "${paths[@]}"; do
    [[ -z "${path}" ]] && continue
    # Allow documented examples
    [[ "${path}" == *.example ]] && continue
    [[ "${path}" == *.md ]] && continue
    for pat in "${blocked_patterns[@]}"; do
      if [[ "${path}" =~ ${pat} ]]; then
        printf 'ERROR: %s must not be committed: %s\n' "${label}" "${path}" >&2
        fail=1
      fi
    done
  done
}

mapfile -t tracked < <(git ls-files)
check_paths "tracked file" "${tracked[@]}"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t staged < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
  check_paths "staged file" "${staged[@]}"
fi

# Flag tracked YAML assignments that look like real secrets (not empty / CHANGE_ME)
secret_keys=(
  quay_registry_password
  quay_db_password
  quay_db_admin_password
  quay_redis_password
  quay_secret_key
  quay_database_secret_key
)

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

for key in "${secret_keys[@]}"; do
  git grep -n -E "^[[:space:]]*${key}:" -- \
    '*.yml' '*.yaml' \
    ':!**/*.example' \
    ':!roles/quay/tasks/assert_secrets.yml' \
    >"${tmpdir}/hits.txt" 2>/dev/null || true
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    value="${line#*:}"
    value="${value#*:}"
    value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')"
    if [[ -z "${value}" || "${value}" == CHANGE_ME* || "${value}" == '""' || "${value}" == "''" ]]; then
      continue
    fi
    printf 'ERROR: possible committed secret: %s\n' "${line}" >&2
    fail=1
  done <"${tmpdir}/hits.txt"
done

if [[ "${fail}" -ne 0 ]]; then
  printf '\nRefusing to proceed. Keep secrets in inventory/group_vars/quay/vault.yml (gitignored).\n' >&2
  exit 1
fi

printf 'OK: no blocked credential files detected in git index/staging.\n'
