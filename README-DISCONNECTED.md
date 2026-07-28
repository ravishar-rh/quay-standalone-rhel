# Disconnected / air-gapped Quay install

Use this guide when the Quay host (and usually the bastion) **cannot** reach Red Hat repositories or `registry.redhat.io`.

Online (connected) installs: see [README.md](README.md).

## Overview

1. On a **connected** machine, build an offline bundle (RPMs + container images).
2. Copy the bundle to the air-gapped site.
3. Extract it and point inventory at the bundle path.
4. Run the **disconnected** playbook (loads local RPMs/images; no registry access).

## Prerequisites

### Connected builder host

- Subscribed RHEL 9 or 10 (for `dnf download` of matching RPMs)
- `podman`
- Login to Red Hat registry:

  ```bash
  podman login registry.redhat.io
  ```

### Disconnected Quay host

- RHEL 9 or RHEL 10
- Extracted offline bundle (default path `/opt/quay-offline-bundle`)
- This playbook repo + Ansible (bastion may also be offline; see [Bastion offline](#optional-bastion-also-offline))

## 1. Build the offline bundle (connected machine)

### Automated

```bash
# Match the target Quay host major version
./scripts/download-offline-bundle.sh --rhel-version 9

# Or build for both majors
./scripts/download-offline-bundle.sh --rhel-version 9 --rhel-version 10
```

Useful options:

| Option | Purpose |
|--------|---------|
| `--output DIR` | Bundle directory (default: `./quay-offline-bundle`) |
| `--quay-version v3.17.3` | Quay image tag |
| `--skip-rpms` | Images only |
| `--skip-images` | RPMs only |
| `--no-archive` | Skip creating `.tar.gz` |
| `--print-manual-steps` | Print copy-paste commands and exit (no download) |

Output:

- `quay-offline-bundle/` directory
- `quay-offline-bundle.tar.gz`
- `quay-offline-bundle.tar.gz.sha256`

### Manual commands only

```bash
./scripts/download-offline-bundle.sh --print-manual-steps
```

The same text is written into the bundle as `docs/MANUAL-DOWNLOAD-STEPS.txt` when you run a full download.

## 2. Transfer to the disconnected site

Copy `quay-offline-bundle.tar.gz` (and optionally the `.sha256` file) via USB or other sneakernet.

On the target (or bastion that will stage files onto the Quay host):

```bash
sha256sum -c quay-offline-bundle.tar.gz.sha256   # optional verify
sudo tar -C /opt -xzf quay-offline-bundle.tar.gz
# results in /opt/quay-offline-bundle
```

## 3. Configure inventory

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
```

Example (same machine as Ansible control node):

```yaml
all:
  children:
    quay:
      hosts:
        quay-server.example.com:
          ansible_connection: local
          ansible_host: 127.0.0.1
          quay_hostname: quay-server.example.com
          quay_offline_bundle_dir: /opt/quay-offline-bundle
```

For a remote Quay host, set `ansible_host` / SSH and keep `quay_offline_bundle_dir` as the path **on that host** (copy/extract the bundle there first).

## 4. Vault and deploy

Registry pulls are not used in disconnected mode, so skip Red Hat registry prompts:

```bash
./scripts/setup-vault.sh --disconnected
ansible-playbook playbooks/deploy_quay_disconnected.yml
```

What the disconnected playbook does:

- Installs `podman` and related packages from bundle RPMs (`disablerepo=*`)
- Loads PostgreSQL, Redis, and Quay images with `podman load`
- Skips `registry.redhat.io` login and image pulls
- Continues with the same Quay config / firewall / systemd flow as the online playbook

## 5. First login

Same as online: Quay has **no** default password.

1. Open `http://<quay_hostname>/`
2. **Create Account** as `quayadmin` with a password you choose
3. Sign in; `quayadmin` is a superuser

```bash
podman login --tls-verify=false <quay_hostname>
```

## 6. Uninstall / cleanup

```bash
# Remove containers/images/firewall rules; keep /var/lib/quay and the offline bundle
ansible-playbook playbooks/uninstall_quay_disconnected.yml \
  -e quay_uninstall_confirm=true

# Full wipe including data + offline bundle
ansible-playbook playbooks/uninstall_quay_disconnected.yml \
  -e quay_uninstall_confirm=true \
  -e quay_uninstall_remove_data=true \
  -e quay_uninstall_remove_offline_bundle=true
```

See [README.md — Uninstall / cleanup](README.md#uninstall--cleanup) for all flags.

## Bundle layout

```text
quay-offline-bundle/
  manifest.yml
  README-OFFLINE.txt
  docs/MANUAL-DOWNLOAD-STEPS.txt
  rhel9/
    rpms/*.rpm
    images/
      postgresql-16.tar
      redis-7.tar
      quay-v3.17.3.tar
      images.manifest
  rhel10/
    rpms/
    images/
  ansible/                 # optional
    wheels/                # pip download of requirements.txt
    collections/           # ansible-galaxy collection download
```

## Optional: bastion also offline

If the Ansible control node has no internet either:

1. Include Ansible deps when building the bundle (the download script tries this automatically).
2. On the bastion, install from the bundle, for example:

   ```bash
   python3 -m pip install --no-index --find-links=/opt/quay-offline-bundle/ansible/wheels -r requirements.txt
   ansible-galaxy collection install /opt/quay-offline-bundle/ansible/collections/*.tar.gz
   ```

   Exact collection install commands depend on what `ansible-galaxy collection download` produced; see files under `ansible/collections/`.

Alternatively install `ansible-core` from a local RPM mirror or DVD on the bastion, then use only the Quay host offline bundle for images/RPMs.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `quay_disconnected` | `true` in disconnected playbook | Enables offline RPM/image path |
| `quay_offline_bundle_dir` | `/opt/quay-offline-bundle` if unset | Extracted bundle on the Quay host |
| `quay_offline_disable_gpg_check` | `true` | Allow installing local RPMs without repo GPG |
| `quay_pull_images` | `false` in disconnected playbook | Must stay false offline |
| `quay_version` | `v3.17.3` | Must match the Quay tarball in the bundle |

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Missing offline RPM dir | Bundle extracted? Path matches host major (`rhel9` vs `rhel10`)? |
| Missing `*.tar` images | Re-run download with registry login; confirm `rhelX/images/` |
| Image ref not found after load | Ensure `images.manifest` exists; tarball was saved with original tags |
| Assert wants registry credentials | Use `deploy_quay_disconnected.yml`, not `deploy_quay.yml` |
| Vault secrets missing | Run `./scripts/setup-vault.sh --disconnected` from repo root |

## Related files

- `scripts/download-offline-bundle.sh` — build or print manual download steps
- `playbooks/deploy_quay_disconnected.yml` — air-gapped deploy entrypoint
- `playbooks/uninstall_quay_disconnected.yml` — air-gapped uninstall / cleanup
- `roles/quay/tasks/offline_packages.yml` / `offline_images.yml` — offline install logic
- [README.md](README.md) — online deploy and general project docs
- [README-AAP.md](README-AAP.md) — run via Red Hat Ansible Automation Platform
