# Penelope

Penelope is an opinionated Ubuntu-based server setup for a small, remotely operated file and backup server. It automates bare-metal installation, encrypted system/data layout, initramfs-based SSH unlock, internal and external Restic backups, recovery tooling, and managed Samba shares for Windows/SMB clients.

The project is designed around a small number of explicit operator workflows: install from a Live-USB, unlock remotely after reboot, run firstboot, bring up backup tooling, register USB backup disks, expose a read-only Backup-Dashboard, and provision managed Samba shares.

Penelope is intentionally conservative: destructive installation steps are separated from installed-system update steps, backup and Samba configuration live under `/etc/penelope`, secrets are externalized, and recovery-critical material is staged and verified.

This repository contains the versioned Penelope source artefacts. Runnable operator bundles are assembled from these files and include an unversioned `penelope-common.sh` runtime copy plus bundle-local metadata.

## Start here

- Full operations manual: `penelope-documentation-0.0.385.md`
- Installer: `penelope-install-0.9.400.sh`
- Backup setup: `penelope-backup-setup-0.3.449.sh`
- Samba setup: `penelope-samba-setup-0.1.150.sh`
- Shared library source: `penelope-common-1.5.25.sh`
- Phase-oriented walkthrough helper: `penelope-walkthrough-assistant-0.0.51.sh`
- Project guidelines: `penelope-guidelines-0.0.269.yaml`

Use the walkthrough assistant for phase prompts and the documentation for the complete runbook, decision rules, and recovery procedures.

## Current source line

- `penelope-install-0.9.400.sh`
- `penelope-backup-setup-0.3.449.sh`
- `penelope-samba-setup-0.1.150.sh`
- `penelope-common-1.5.25.sh`
- `penelope-walkthrough-assistant-0.0.51.sh`
- `penelope-documentation-0.0.385.md`
- `penelope-guidelines-0.0.269.yaml`

The versioned filenames are retained intentionally. For a runnable operator workdir, copy the current versioned common library to the unversioned sibling runtime filename:

```bash
cp -f ./penelope-common-1.5.25.sh ./penelope-common.sh
```

If executable bits were not preserved by extraction or copy, run:

```bash
chmod +x ./*.sh
```

The runnable release bundle intentionally does not ship an active `penelope-install.layout.conf`; generate it on the target Live-USB system so hardware-specific disk IDs come from the actual target host.

## Repository vs. runnable workdir

The repository keeps versioned source artefacts. To run the tools from a working directory, create the unversioned sibling runtime library from the versioned common source:

```bash
cp -f ./penelope-common-1.5.25.sh ./penelope-common.sh
```

`penelope-common.sh` is a generated runtime convenience copy for an operator workdir. The long-lived Git source is `penelope-common-1.5.25.sh`.

## Guided operator flow

Start with the assistant when you want the current phase checklist:

```bash
./penelope-walkthrough-assistant-0.0.51.sh status
./penelope-walkthrough-assistant-0.0.51.sh live-usb
./penelope-walkthrough-assistant-0.0.51.sh installed
```

Then use the full documentation for detailed steps and decision rules:

```text
penelope-documentation-0.0.385.md
```

## Release-candidate validation status

The current release-candidate line has been validated on the target Penelope host with the core system path:

```text
Install / Reboot / Unlock / Firstboot
-> backup-setup write-config / verify-config / apply
-> internal backup + automatic verify
-> USB register-existing
-> external backup + automatic verify
-> samba-setup write-config / verify-config / apply
-> Samba include placement under [global]
-> internal backup after final Samba state
-> external backup after final Samba state
-> final verify-security
-> successful Windows 11 SMB client login
```

The expected Penelope Samba shares render correctly:

```text
[archive_p001]
[archive_p002]
[rawin]
[scan]
[internal]
[backup_dashboard]
```

The final external backup after the accepted Samba state completed and synced the external recovery bundle:

```text
EXTERNAL backup done.
penelope-backup-verify SUCCESS
Recovery bundle synced: /_usbbackup/<UUID>/<HOST_SCOPE_NAME>/_recovery
```

The remaining recommended external check before a final production release is broader real-client access testing for the intended Windows/macOS/Linux client mix and share-permission model.

## Known accepted warning

Ubuntu/Samba may report:

```text
Weak crypto is allowed by GnuTLS
```

Penelope still verifies the intended Samba baseline: SMB3 minimum on server and client side, plus NTLMv2-only. This warning is not treated as a release-candidate blocker for this line.

## Recommended static verification

From a runnable source or bundle workdir:

```bash
cmp -s penelope-common.sh penelope-common-1.5.25.sh
bash -n ./*.sh
shellcheck ./*.sh
python3 - <<'PY'
import yaml
with open('penelope-guidelines-0.0.269.yaml', 'r', encoding='utf-8') as fh:
    yaml.safe_load(fh)
print('guidelines-yaml-ok')
PY
```
