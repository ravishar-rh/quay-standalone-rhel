# Deploy Quay on standalone RHEL

Ansible playbook and role that deploys a **proof-of-concept** [Red Hat Quay](https://docs.redhat.com/en/documentation/red_hat_quay/) registry on a single RHEL 9 or RHEL 10 host using Podman.

This follows the official Quay PoC layout: PostgreSQL + Redis + Quay, with local storage. It is suitable for testing only — not production.

## What gets deployed

| Component   | Default image (RHEL 9 host)              | Default image (RHEL 10 host)             | Host ports   |
|-------------|------------------------------------------|------------------------------------------|--------------|
| PostgreSQL  | `rhel9/postgresql-16:latest`             | `rhel10/postgresql-16:latest`            | `5432`       |
| Redis       | `rhel9/redis-7:latest`                   | `rhel9/redis-7:latest`                   | `6379`       |
| Quay        | `quay/quay-rhel9:v3.17.3`                 | `quay/quay-rhel9:v3.17.3`                 | `80`, `443`  |

On each run the role installs/updates host packages to **latest**, pulls current image digests (`quay_pull_images`), and recreates containers when digests change (`quay_recreate_on_image_change`).

Data and config live under `/var/lib/quay` by default. Containers use `--restart=always` and `podman-restart.service` so they survive reboots.

## Deployment steps

1. **Prepare the bastion (control node)**

   ```bash
   sudo ./scripts/setup-bastion.sh
   ```

   Installs Python, Ansible, and collections from `requirements.txt` / `requirements.yml`.

2. **Configure inventory**

   ```bash
   cp inventory/hosts.yml.example inventory/hosts.yml
   ```

   Edit `inventory/hosts.yml`:

   - **Same machine** (bastion is also the Quay host): use local connection — do **not** use `ansible_host: localhost` with SSH:

     ```yaml
     quay-server.example.com:
       ansible_connection: local
       ansible_host: 127.0.0.1
       quay_hostname: quay-server.example.com
     ```

   - **Remote server**: set the real IP/DNS and SSH access:

     ```yaml
     quay-server.example.com:
       ansible_host: 192.0.2.10
       ansible_user: root
       ansible_ssh_private_key_file: ~/.ssh/id_rsa
       quay_hostname: quay-server.example.com
     ```

   Do **not** put passwords in the inventory. Test connectivity:

   ```bash
   ansible quay -m ping
   ```

3. **Save credentials in Ansible Vault**

   ```bash
   ./scripts/setup-vault.sh
   ```

   Do **not** copy `group_vars/vault.yml.example` — that path does not exist.
   The helper writes and encrypts `inventory/group_vars/quay/vault.yml` and creates `.vault_pass`.

4. **Deploy Quay**

   ```bash
   ansible-playbook playbooks/deploy_quay.yml
   ```

   Installs Podman, opens firewall ports, deploys PostgreSQL + Redis + Quay, and enables reboot persistence.

5. **First login to the Quay portal**

   Quay does **not** ship with a default username/password. Create the first account in the UI:

   1. Open `http://<quay_hostname>/` (for example `http://quay-server.example.com/`)
   2. Click **Create Account**
   3. Register as **`quayadmin`** (this name is listed in `SUPER_USERS`) and choose any password
   4. Sign in with that username and password — `quayadmin` is a superuser

   Then from a client:

   ```bash
   podman login --tls-verify=false <quay_hostname>
   ```

   Ensure clients resolve `quay_hostname` (DNS or `/etc/hosts`).

6. **Uninstall / cleanup** (optional)

   Stop and remove Quay containers (keeps `/var/lib/quay` data by default):

   ```bash
   ansible-playbook playbooks/uninstall_quay.yml -e quay_uninstall_confirm=true
   ```

   Also delete registry/DB data and images:

   ```bash
   ansible-playbook playbooks/uninstall_quay.yml \
     -e quay_uninstall_confirm=true \
     -e quay_uninstall_remove_data=true \
     -e quay_uninstall_remove_images=true
   ```

   Disconnected uninstall (and optionally remove the offline bundle):

   ```bash
   ansible-playbook playbooks/uninstall_quay_disconnected.yml \
     -e quay_uninstall_confirm=true \
     -e quay_uninstall_remove_data=true \
     -e quay_uninstall_remove_offline_bundle=true
   ```

   See [Uninstall / cleanup](#uninstall--cleanup) for all flags.

Optional before any git push:

```bash
./scripts/check-no-secrets.sh
```

## Disconnected / air-gapped install

When the Quay host cannot reach Red Hat repos or `registry.redhat.io`, follow the dedicated guide:

**[README-DISCONNECTED.md](README-DISCONNECTED.md)**

Short path:

```bash
# Connected machine
./scripts/download-offline-bundle.sh --rhel-version 9

# Air-gapped host (after copying/extracting the bundle to /opt)
./scripts/setup-vault.sh --disconnected
ansible-playbook playbooks/deploy_quay_disconnected.yml
```

## Ansible Automation Platform (AAP)

To run these playbooks from **Red Hat AAP 2.5+** (project, inventory, credentials, job templates):

**[README-AAP.md](README-AAP.md)**

## Uninstall / cleanup

Both online and disconnected installs can be removed with dedicated playbooks. You **must** pass `-e quay_uninstall_confirm=true`.

| Playbook | Use after |
|----------|-----------|
| `playbooks/uninstall_quay.yml` | `deploy_quay.yml` (online) |
| `playbooks/uninstall_quay_disconnected.yml` | `deploy_quay_disconnected.yml` |

**Default cleanup** (containers + images + firewall ports + `/etc/hosts` entry; **keeps** data under `/var/lib/quay`):

```bash
ansible-playbook playbooks/uninstall_quay.yml -e quay_uninstall_confirm=true
```

**Full wipe** (also delete Quay data directory):

```bash
ansible-playbook playbooks/uninstall_quay.yml \
  -e quay_uninstall_confirm=true \
  -e quay_uninstall_remove_data=true
```

**Disconnected** full wipe including offline bundle:

```bash
ansible-playbook playbooks/uninstall_quay_disconnected.yml \
  -e quay_uninstall_confirm=true \
  -e quay_uninstall_remove_data=true \
  -e quay_uninstall_remove_offline_bundle=true
```

| Variable | Default | Effect |
|----------|---------|--------|
| `quay_uninstall_confirm` | `false` | Required `true` or the play fails safely |
| `quay_uninstall_remove_data` | `false` | Delete `quay_base_dir` (`/var/lib/quay`) |
| `quay_uninstall_remove_images` | `true` | `podman rmi` Quay/Postgres/Redis images |
| `quay_uninstall_remove_firewall_ports` | `true` | Close HTTP/HTTPS/DB/Redis ports in firewalld |
| `quay_uninstall_remove_hosts_entry` | `true` | Remove `quay_hostname` from `/etc/hosts` |
| `quay_uninstall_remove_packages` | `false` | Remove podman/acl/curl/firewalld packages |
| `quay_uninstall_remove_offline_bundle` | `false` | Delete `quay_offline_bundle_dir` (disconnected playbook) |

What gets removed always (when confirmed): containers `quay`, `redis`, and `postgresql-quay`.

## Credentials (do not commit)

**Preferred:** run the vault helper (creates the encrypted file for you):

```bash
./scripts/setup-vault.sh
```

That writes **`inventory/group_vars/quay/vault.yml`** and `.vault_pass`.

| Wrong | Correct |
|-------|---------|
| `group_vars/vault.yml` | `inventory/group_vars/quay/vault.yml` |
| `group_vars/quay/vault.yml` | `inventory/group_vars/quay/vault.yml` |

**Manual alternative** (only if you skip the helper):

```bash
cp inventory/group_vars/quay/vault.yml.example inventory/group_vars/quay/vault.yml
# edit inventory/group_vars/quay/vault.yml — replace all CHANGE_ME_* values
ansible-vault encrypt inventory/group_vars/quay/vault.yml
printf '%s\n' 'your-vault-password' > .vault_pass
chmod 600 .vault_pass
```

What `./scripts/setup-vault.sh` does:

- Prompts for `registry.redhat.io` username/password (or token)
- Auto-generates DB, Redis, and Quay application secrets
- Writes `inventory/group_vars/quay/vault.yml` and encrypts with `ansible-vault`
- Creates `.vault_pass` (mode `0600`); `ansible.cfg` uses `vault_password_file = .vault_pass`

Non-interactive / CI:

```bash
QUAY_REGISTRY_USERNAME=myuser \
QUAY_REGISTRY_PASSWORD=mytoken \
QUAY_VAULT_PASSWORD='choose-a-strong-vault-pass' \
./scripts/setup-vault.sh --non-interactive
```

Other commands:

```bash
./scripts/setup-vault.sh --show                 # view decrypted vault
./scripts/setup-vault.sh --rotate-app-secrets   # regenerate DB/Redis/app secrets
./scripts/check-no-secrets.sh                   # refuse push of credential files
```

Gitignored (will not be pushed):

- `inventory/hosts.yml`
- `inventory/group_vars/quay/vault.yml`
- `.vault_pass*`
- `auth.json`, TLS keys (`*.pem`, `*.key`, `ssl.cert`, …)

## Bastion (control node) setup

```bash
sudo ./scripts/setup-bastion.sh
```

Installs Python 3, pip, git, sshpass, rsync, openssl, `ansible-core`, then applies [`requirements.txt`](requirements.txt) and [`requirements.yml`](requirements.yml).

## Requirements

**Online install**

- Control node: RHEL 9/10 bastion prepared with the setup script (Ansible 2.16+)
- Managed host: RHEL 9 or RHEL 10, registered/subscribed, with network access to `registry.redhat.io`
- SSH access with privilege escalation (`become`)
- Credentials to pull from `registry.redhat.io` (via vault or `auth.json` — never commit them)

**Disconnected install** — see **[README-DISCONNECTED.md](README-DISCONNECTED.md)**

- Connected machine to build the offline bundle (subscribed RHEL + `podman login registry.redhat.io`)
- Air-gapped Quay host with the extracted bundle at `quay_offline_bundle_dir`
- Ansible bastion that can reach the Quay host (bastion itself may also be offline if you install Ansible from the bundle’s `ansible/` deps)

## Useful variables

| Variable | Default | Description |
|----------|---------|-------------|
| `quay_hostname` | `quay-server.example.com` | Hostname in `config.yaml` and client URLs |
| `quay_version` | `v3.17.3` | Quay image tag |
| `quay_pull_images` | `true` | Pull images before deploy |
| `quay_recreate_on_image_change` | `true` | Recreate containers when digest changes |
| `quay_packages_state` | `latest` | dnf state for host packages |
| `quay_base_dir` | `/var/lib/quay` | Config, DB, and image storage root |
| `quay_disconnected` | `false` | Air-gapped mode (use disconnected playbook) |
| `quay_offline_bundle_dir` | `/opt/quay-offline-bundle` when disconnected | Path to extracted offline bundle |
| DB / Redis / app secrets | *(required via vault)* | See `inventory/group_vars/quay/vault.yml.example` |
| Registry username/password or `auth.json` | *(required for online pulls)* | Not required when disconnected |

See `roles/quay/defaults/main.yml` for non-secret defaults.

## Layout

```text
README.md
README-DISCONNECTED.md
README-AAP.md
scripts/setup-bastion.sh
scripts/setup-vault.sh
scripts/download-offline-bundle.sh
scripts/check-no-secrets.sh
requirements.txt
requirements.yml
collections/requirements.yml
ansible.cfg
inventory/hosts.yml.example
inventory/group_vars/quay/vars.yml
inventory/group_vars/quay/vault.yml.example
playbooks/deploy_quay.yml
playbooks/deploy_quay_disconnected.yml
playbooks/uninstall_quay.yml
playbooks/uninstall_quay_disconnected.yml
roles/quay/
```

## Notes

- Local storage does not provide the consistency guarantees Quay needs under concurrent access; use object storage for production.
- Optional TLS: place `ssl.cert` / `ssl.key` under `{{ quay_base_dir }}/config` on the host (not in git), set `quay_preferred_url_scheme: https`, and re-run.
