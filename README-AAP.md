# Running Quay playbooks on Red Hat Ansible Automation Platform (AAP)

This guide covers deploying this repository with **Red Hat Ansible Automation Platform 2.5+** (Automation Controller / Automation Execution). UI labels below match current AAP navigation; names can vary slightly by patch level.

Related docs:

- Online CLI deploy: [README.md](README.md)
- Air-gapped / offline bundle: [README-DISCONNECTED.md](README-DISCONNECTED.md)

## What you will create in AAP

| AAP object | Purpose |
|------------|---------|
| **Organization** | Owns project, inventory, credentials, templates |
| **Project** | Git (or manual) sync of this repo |
| **Inventory** + hosts in group `quay` | Target RHEL 9/10 Quay server(s) |
| **Credentials** | Machine (SSH), Ansible Vault, optional registry extras |
| **Job templates** | Online and/or disconnected playbooks |
| **Execution Environment** (recommended) | Image with `ansible-core` + collections |

Playbooks:

| Playbook | When to use |
|----------|-------------|
| `playbooks/deploy_quay.yml` | Host can reach Red Hat repos + `registry.redhat.io` |
| `playbooks/deploy_quay_disconnected.yml` | Offline bundle already on the host |
| `playbooks/uninstall_quay.yml` | Remove an online Quay PoC |
| `playbooks/uninstall_quay_disconnected.yml` | Remove a disconnected Quay PoC |

Both plays target inventory group **`quay`** and use `become: true`.

## Prerequisites

- AAP 2.5+ (or current supported release) with permission to create projects, inventories, credentials, and job templates
- A RHEL 9 or 10 Quay host reachable from the AAP execution nodes (SSH)
- This repository available to AAP via Git SCM (recommended) or a manual project
- Secrets **not** committed to Git (keep using gitignored vault/inventory patterns)

For **online** jobs, the Quay host (or EE, depending on where pulls run) needs access to `registry.redhat.io`. Image pulls happen **on the managed host** via Podman.

For **disconnected** jobs, stage the offline bundle on the Quay host first (see [README-DISCONNECTED.md](README-DISCONNECTED.md)).

## 1. Collections for project sync

Automation Controller installs Galaxy collections listed in:

```text
collections/requirements.yml
```

This repo also has a root `requirements.yml`. For AAP, use the copy under `collections/`:

```bash
# already provided in-repo as collections/requirements.yml
```

On **Project** sync, AAP installs those collections into the job environment (or use a custom EE that already contains them).

## 2. Create a Project

**Automation Execution → Projects → Create project**

| Field | Suggested value |
|-------|-----------------|
| Name | `quay-standalone-rhel` |
| Organization | your org |
| Source control type | Git |
| Source control URL | your fork/remote URL for this repo |
| Source control branch/tag | `main` (or your release branch) |
| Source control credential | Git credential if the repo is private |
| Options | Enable **Update revision on launch** (optional but useful) |

Save, then **Sync** the project. Confirm the sync succeeds and collections install without errors.

### Manual project (no Git)

If you cannot use SCM: create a Manual project and copy the repo onto the controller project path per your AAP install docs. Prefer Git when possible.

## 3. Create an Inventory

**Automation Execution → Inventories → Create inventory**

1. Create inventory e.g. `Quay standalone`.
2. Add a host (the Quay RHEL server).
3. Put the host in group **`quay`** (required — playbooks use `hosts: quay`).

### Host variables (Examples)

**Remote Quay host (online):**

```yaml
ansible_host: 192.0.2.10
ansible_user: root
# or ansible_user: cloud-user with become
quay_hostname: quay.example.com
quay_host_ip: 192.0.2.10
```

**Disconnected host** (bundle already extracted on the server):

```yaml
ansible_host: 192.0.2.10
ansible_user: root
quay_hostname: quay.example.com
quay_offline_bundle_dir: /opt/quay-offline-bundle
```

Do **not** store registry passwords or DB secrets as plain inventory variables in SCM. Use AAP credentials / Vault / surveys (next sections).

> **Note:** `ansible_connection: local` only makes sense when the job runs *on* the Quay host itself. AAP jobs normally run on execution nodes and SSH to the host — use SSH machine credentials, not `local`, unless you have a custom hop/local execution design.

## 4. Credentials

**Automation Execution → Infrastructure → Credentials**

### 4.1 Machine credential

| Field | Value |
|-------|-------|
| Credential type | **Machine** |
| Username | SSH user on the Quay host |
| SSH private key | (or password) |
| Privilege escalation | `sudo` if the user is not root |
| Privilege escalation password | if required |

Attach this credential to the job template so AAP can reach group `quay`.

### 4.2 Ansible Vault credential

This project expects encrypted secrets in:

```text
inventory/group_vars/quay/vault.yml
```

That file is **gitignored**. For AAP you typically:

**Option A — Encrypt vault in a private branch / controller-only path (not ideal for GitOps)**

1. Create `inventory/group_vars/quay/vault.yml` with the required keys (see `inventory/group_vars/quay/vault.yml.example`).
2. Encrypt it with `ansible-vault encrypt`.
3. Store only in an AAP-accessible location that is not public Git, **or** use a private repo that AAP can read.
4. Create credential type **Vault**, paste the vault password.
5. Attach the Vault credential to the job template.

**Option B — Prefer AAP-native secrets (recommended)**

Keep `vault.yml` out of Git. Pass the same variables as **extra variables** from an AAP **Survey** or a **Custom credential type** injector:

Required variables (same names the role expects):

```yaml
quay_registry_username: "..."      # online only; omit/dummy if disconnected
quay_registry_password: "..."
quay_db_password: "..."
quay_db_admin_password: "..."
quay_redis_password: "..."
quay_secret_key: "..."             # UUID-like string
quay_database_secret_key: "..."
```

Mark survey fields as **Password** where appropriate so values are masked.

**Option C — HashiCorp Vault / external secret lookup**

On AAP 2.5+, use supported external credential / HashiCorp integrations to inject the variables above at job runtime. Map each Quay secret to a Vault path/key, then attach those credentials to the job template.

### 4.3 Optional: registry credential as extra vars only

Podman on the **managed host** performs `podman login`. Supplying `quay_registry_username` / `quay_registry_password` via survey or Vault file is enough; you do not need a separate “Container Registry” credential type unless you build a custom workflow around it.

## 5. Execution Environment (recommended)

Use a supported AAP execution environment that includes:

- `ansible-core` compatible with this project (2.16+)
- Collections from `collections/requirements.yml` (`ansible.posix`, `community.general`, `containers.podman`)

You can:

- Rely on **project collection install** at sync/job time, or
- Build a custom EE with `ansible-builder` that vendors those collections for air-gapped AAP

Assign the EE on the Job Template (or Organization default).

## 6. Job templates

**Automation Execution → Templates → Create job template**

### Online deploy

| Field | Value |
|-------|-------|
| Name | `Deploy Quay (online)` |
| Job type | Run |
| Inventory | `Quay standalone` |
| Project | `quay-standalone-rhel` |
| Playbook | `playbooks/deploy_quay.yml` |
| Execution environment | your EE |
| Credentials | Machine + Vault (if using vault file) |
| Privilege escalation | Enabled if needed (play already has `become: true`) |
| Limit | optional host limit |
| Options | **Enable webhook** / concurrent jobs as you prefer |

**Survey** (optional but useful): prompt for `quay_hostname`, registry user/password, and generated DB/Redis/app secrets (or document that operators run a one-time vault seed).

**Extra variables** example (non-secret):

```yaml
quay_hostname: quay.example.com
quay_version: v3.17.3
```

Launch the template and confirm the job reaches `Assert required secrets` successfully (secrets must be present via Vault file or extra vars).

### Disconnected deploy

| Field | Value |
|-------|-------|
| Name | `Deploy Quay (disconnected)` |
| Playbook | `playbooks/deploy_quay_disconnected.yml` |
| Inventory / Project / EE / Machine cred | same pattern as online |

**Extra variables:**

```yaml
quay_offline_bundle_dir: /opt/quay-offline-bundle
```

Ensure the offline bundle exists on the managed host **before** launch (`download-offline-bundle.sh` on a connected machine, then copy/extract). Details: [README-DISCONNECTED.md](README-DISCONNECTED.md).

Registry credentials are **not** required for the disconnected playbook asserts; DB/Redis/app secrets still are.

### Uninstall (online)

| Field | Value |
|-------|-------|
| Name | `Uninstall Quay (online)` |
| Playbook | `playbooks/uninstall_quay.yml` |
| Inventory / Project / EE / Machine cred | same as deploy |
| Extra variables | `quay_uninstall_confirm: true` |

Optional extra variables: `quay_uninstall_remove_data: true`, `quay_uninstall_remove_images: true`, `quay_uninstall_remove_packages: true`.

### Uninstall (disconnected)

| Field | Value |
|-------|-------|
| Name | `Uninstall Quay (disconnected)` |
| Playbook | `playbooks/uninstall_quay_disconnected.yml` |
| Extra variables | `quay_uninstall_confirm: true` |

Optional: `quay_uninstall_remove_data: true`, `quay_uninstall_remove_offline_bundle: true`, `quay_offline_bundle_dir: /opt/quay-offline-bundle`.

Uninstall templates do **not** need registry secrets; attach Machine credential (and Vault only if your inventory still references vaulted host vars).

## 7. Suggested launch checklist

1. Project synced (playbooks + collections visible).
2. Inventory group `quay` contains the target host; `ansible quay -m ping` equivalent succeeds via an ad-hoc command in AAP if you use that feature.
3. Machine credential can SSH and escalate.
4. Secrets available (Vault credential and/or survey extra vars).
5. Online: host can pull from `registry.redhat.io` after Podman login from the play.
6. Disconnected: `/opt/quay-offline-bundle` (or your path) present on the host with `rhel9` or `rhel10` content matching the OS.
7. Launch job template → follow job output through PostgreSQL, Redis, Quay, health wait.
8. Open `http://<quay_hostname>/`, create **`quayadmin`** (no default password).

## 8. Mapping CLI scripts to AAP

| CLI workflow | AAP equivalent |
|--------------|----------------|
| `./scripts/setup-bastion.sh` | Not required on controller; use EE + project collections |
| `./scripts/setup-vault.sh` | Vault credential + encrypted `vault.yml`, **or** Survey / custom credential injector |
| `ansible-playbook playbooks/deploy_quay.yml` | Job template → that playbook |
| `ansible-playbook playbooks/deploy_quay_disconnected.yml` | Separate job template |
| `ansible-playbook playbooks/uninstall_quay.yml -e quay_uninstall_confirm=true` | Uninstall job template + extra var |
| `ansible-playbook playbooks/uninstall_quay_disconnected.yml -e ...` | Disconnected uninstall template |
| `./scripts/download-offline-bundle.sh` | Run outside AAP on a connected builder; stage bundle on Quay host (or automate staging with a separate template) |

`ansible.cfg` settings such as `vault_password_file = .vault_pass` apply to CLI use. In AAP, prefer the **Vault** credential attached to the template instead of shipping `.vault_pass`.

## 9. Security notes

- Never commit `inventory/hosts.yml`, `inventory/group_vars/quay/vault.yml`, or `.vault_pass` to a public repo.
- Prefer AAP credential store / external vault over plaintext extra vars in saved templates.
- Restrict who can execute Quay job templates and who can view survey/credential values.
- After deploy, rotate any secrets that were used in temporary surveys if your policy requires it.

## 10. Troubleshooting in AAP

| Job failure | Likely cause |
|-------------|--------------|
| Host pattern / no hosts | Inventory missing group `quay` |
| UNREACHABLE / SSH | Machine credential, firewall, wrong `ansible_host` |
| Missing secrets assert | Vault not attached, or survey vars not passed |
| registry.redhat.io pull errors | Bad registry creds, or use disconnected template + bundle |
| Collection not found | Project `collections/requirements.yml` sync failed; fix EE/collections |
| Privilege escalation failed | Enable become on credential / provide sudo password |

## Related files in this repo

```text
playbooks/deploy_quay.yml
playbooks/deploy_quay_disconnected.yml
playbooks/uninstall_quay.yml
playbooks/uninstall_quay_disconnected.yml
collections/requirements.yml
requirements.yml
inventory/group_vars/quay/vault.yml.example
roles/quay/
```

Official AAP docs: [Using automation execution](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_automation_execution/index) (Projects, Job templates, Credentials).
