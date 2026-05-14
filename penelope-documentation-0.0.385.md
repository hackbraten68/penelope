# Penelope Documentation 0.0.385

**Document version:** 0.0.385
**Last updated:** 2026-05-14 (Europe/Berlin)
**Scope:** Installation, remote unlock, backup, USB external backup, recovery, managed Samba bring-up, and release-candidate operator validation.

## Current tool versions (release bundle)
- **penelope-install:** 0.9.400
- **penelope-backup-setup:** 0.3.449
- **penelope-common:** 1.5.25 (shared library, installed/refreshed by all setup bundles)
- **penelope-samba-setup:** 0.1.150 (managed Samba shares for Windows/SMB clients; standard installed-system bring-up step)
- **penelope-walkthrough-assistant:** 0.0.51 (optional operator-guided assistant; bundle/workdir wrapper only, not an installer replacement)

**Current release-candidate line:** the current version set is release-candidate ready for full target-host validation. The versioned source artefacts in this line preserve the validated Penelope architecture and operator workflow while keeping destructive install work, installed-system updates, backup setup, Samba setup, recovery, and documentation responsibilities separate.

**Latest live proof:** the target-host release-candidate walkthrough completed install, reboot/unlock, firstboot, backup setup, internal and external backup/verify, USB disk registration, Samba setup, Samba include placement via `penelope-samba-setup-0.1.150.sh`, final internal/external recovery-bundle sync, final `penelope-verify-security.sh`, and a successful Windows 11 SMB client login.

**Known accepted warning:** Ubuntu/Samba may report `Weak crypto is allowed by GnuTLS`; Penelope verifies the practical baseline `server min protocol = SMB3_00`, `client min protocol = SMB3_00`, and NTLMv2-only.

**Primary source/operator entrypoints:**
- `README-0.0.201.md` for the repository entrypoint and navigation.
- `penelope-documentation-0.0.385.md` for the full operations manual.
- `penelope-walkthrough-assistant-0.0.51.sh` for phase-oriented operator guidance.
- `penelope-guidelines-0.0.269.yaml` for project and review rules.

**Note:** In command examples below, `penelope-install-<version>.sh`, `penelope-backup-setup-<version>.sh`, `penelope-samba-setup-<version>.sh`, and `penelope-walkthrough-assistant-<version>.sh` refer to the current versions listed above. When the operator is already inside one runnable bundle/workdir, command examples prefer `./<script>` form; informational status text may still show absolute paths.

## Table of contents
- [Current tool versions (release bundle)](#current-tool-versions-release-bundle)
- [Bundle structure and deployment](#bundle-structure-and-deployment)
  - [Required files per bundle](#required-files-per-bundle)
  - [Why bundling is required](#why-bundling-is-required)
  - [Version compatibility](#version-compatibility)
  - [Distribution checklist](#distribution-checklist)
  - [Git repository workflow vs. runnable bundles](#git-repository-workflow-vs-runnable-bundles)
  - [Live-USB + release-ZIP-based operator workflow](#live-usb--release-zip-based-operator-workflow)
  - [Update model on a running system](#update-model-on-a-running-system)
- [Script set and versions](#script-set-and-versions)
- [1) Typical workflows](#1-typical-workflows)
  - [1.1 Standard installation (Live-USB)](#11-standard-installation-live-usb)
    - [1.1.1 Canonical scratch-install walkthrough (`two-disk`, approx. 2 TB + 4 TB)](#111-canonical-scratch-install-walkthrough-two-disk-approx-2-tb--4-tb)
    - [1.1.2 Optional guided assistant (`penelope-walkthrough-assistant`)](#112-optional-guided-assistant-penelope-walkthrough-assistant)
  - [1.2 Prepare an external USB backup disk (one-time)](#12-prepare-an-external-usb-backup-disk-one-time)
  - [1.3 Run an external backup (operator flow)](#13-run-an-external-backup-operator-flow)
  - [1.4 Live-USB reinstall while preserving `/_backup` (disaster reinstall)](#14-live-usb-reinstall-while-preserving-_backup-disaster-reinstall)
  - [1.5 Post-install checklist (5 minutes)](#15-post-install-checklist-5-minutes)
  - [1.6 How to verify that backup setup and backup disks are functioning](#16-how-to-verify-that-backup-setup-and-backup-disks-are-functioning)
  - [1.7 Penelope software-only update walkthrough (installed system)](#17-penelope-software-only-update-walkthrough-installed-system)
- [2) System overview](#2-system-overview)
- [3) Prerequisites and assumptions](#3-prerequisites-and-assumptions)
- [4) Installation (penelope-install)](#4-installation-penelope-install)
  - [4.2 Required inputs (external bootstrap-config plus external layout-config)](#42-required-inputs-external-bootstrap-config-plus-external-layout-config)
    - [4.2.1 Install layout profiles and config seam (phase-5)](#421-install-layout-profiles-and-config-seam-phase-5)
  - [4.5 Initramfs-only refresh (non-destructive fast iteration)](#45-initramfs-only-refresh-non-destructive-fast-iteration)
  - [4.6 Managed-artifacts-only refresh (non-destructive installer-owned target artifacts)](#46-managed-artifacts-only-refresh-non-destructive-installer-owned-target-artifacts)
  - [4.7 Verify-layout-contract preflight (non-destructive install-plan verification)](#47-verify-layout-contract-preflight-non-destructive-install-plan-verification)
- [5) Remote unlock (Dropbear initramfs)](#5-remote-unlock-dropbear-initramfs)
- [6) Post-install checks (recommended)](#6-post-install-checks-recommended)
- [7) Backup setup and operation (penelope-backup)](#7-backup-setup-and-operation-penelope-backup)
  - [7.4 Backup-Dashboard Files (for Samba/Windows Clients)](#74-backup-dashboard-files-for-sambawindows-clients)
  - [7.6 USB external backup workflow (Backup Disk Operator + Operator)](#76-usb-external-backup-workflow-backup-disk-operator--operator)
  - [7.8 USB backup disk preparation and registration (recommended: tool)](#78-usb-backup-disk-preparation-and-registration-recommended-tool)
- [8) Recovery (Flows; offline-only full restore via penelope-offline-recover)](#8-recovery-flows-offline-only-full-restore-via-penelope-offline-recover)
  - [8.2 Recovery flows (Flow A / Flow B)](#82-recovery-flows-flow-a--flow-b)
  - [8.7 Restoring `backup.conf` and restic credential material from the system repository (CLI example)](#87-restoring-backupconf-and-restic-credential-material-from-the-system-repository-cli-example)
- [9) Security notes](#9-security-notes)
- [10) Troubleshooting](#10-troubleshooting)
  - [10.5 Backup troubleshooting (restic)](#105-backup-troubleshooting-restic)
  - [10.7 Troubleshooting penelope-install failures (quick commands)](#107-troubleshooting-penelope-install-failures-quick-commands)
- [Appendix A: Files and locations (overview)](#appendix-a-files-and-locations-overview)
- [Change log](#change-log)

## Bundle structure and deployment

### Required files per bundle

Each Penelope setup bundle consists of **two files** that must be kept together:

**Installation bundle:**
- `penelope-install-<version>.sh` (main installer; use the current version from the list above)
- `penelope-common.sh` (shared library; use the current version from the list above)

**Backup setup bundle:**
- `penelope-backup-setup-<version>.sh` (backup system installer; use the current version from the list above)
- `penelope-common.sh` (shared library; use the current version from the list above)

**Samba setup bundle (normally required for a standard Penelope server):**
- `penelope-samba-setup-<version>.sh` (managed Samba-share installer; use the current version from the list above)
- `penelope-common.sh` (shared library; use the current version from the list above)

**Optional walkthrough helper bundle:**
- `penelope-walkthrough-assistant-<version>.sh` (screen-by-screen operator guide; does not replace the real setup scripts)
- `penelope-common.sh` (shared library; use the current version from the list above)

### Why bundling is required

The three setup scripts install `penelope-common.sh` to `/usr/local/lib/penelope/common.sh` on the target system:

1. **penelope-install** copies `penelope-common.sh` from the Live-USB/script directory to `${TARGET}/usr/local/lib/penelope/common.sh` during installation
2. **penelope-backup-setup** copies `penelope-common.sh` from the script directory to `/usr/local/lib/penelope/common.sh` on the running system
3. **penelope-samba-setup** copies `penelope-common.sh` from the script directory to `/usr/local/lib/penelope/common.sh` on the running system before provisioning managed Samba state

`penelope-walkthrough-assistant` is different: it is an optional guide-layer assistant that runs from a bundle/workdir and does not install target artifacts itself. It still expects a sibling `penelope-common.sh` in the same bundle directory. If the extracted workdir does not preserve executable bits, run `chmod +x ./*.sh` once before invoking the bundle scripts from that workdir.

All generated system tools (`/usr/local/sbin/penelope-*.sh`) use the `___PENELOPE_SOURCE_COMMON___` macro and prefer a sibling `penelope-common.sh` from the current bundle/workdir/recovery copy; if no sibling copy exists, they fall back to the installed system library.

### Version compatibility

⚠️ **Critical:** The `penelope-common.sh` version must match the setup script version:

- **penelope-install `<current bundle version>`** requires the **current `penelope-common.sh` version from the central release-bundle list above**.
- **penelope-backup-setup `<current bundle version>`** requires the **current `penelope-common.sh` version from the central release-bundle list above**.
- **penelope-samba-setup `<current bundle version>`** requires the **current `penelope-common.sh` version from the central release-bundle list above**.

For the active pre-release line, do **not** rely on mixed-version bundles. Treat the sibling `penelope-common.sh` inside the runnable bundle/workdir as the authoritative runtime library, and refresh it whenever you switch to a newer versioned `penelope-common-<version>.sh`. A newer setup script with an older sibling `penelope-common.sh` will fail with missing-function errors.

### Distribution checklist

When distributing Penelope bundles:

- ✅ Gather the chosen versioned artefacts into one release ZIP (for example `penelope-x.y.z.zip`)
- ✅ Verify bundle compatibility against the single canonical version list above
- ✅ In the extracted runtime workdir, refresh the sibling runtime file `penelope-common.sh` from the chosen current `penelope-common-<version>.sh` before running any latest script
- ✅ Do not repeat concrete current tool versions elsewhere in the document
- ✅ Treat the extracted workdir, not the bare ZIP contents listing, as the real runtime object
- ✅ Initramfs scripts are self-contained and do not require the library (they use inline macros)
- ✅ If Samba is part of the deployment, distribute `penelope-samba-setup-<version>.sh` in the same release ZIP and recreate the same `penelope-common.sh` in the extracted workdir

### Release ZIP / assembled workdir workflow

For the current pre-release operator workflow, Penelope distinguishes between:

- **versioned release artefacts** (the files that are gathered for one release)
- **one release ZIP** such as `penelope-x.y.z.zip`
- **the extracted runnable workdir** that the operator actually uses

Canonical operator flow:

1. Gather the chosen versioned release artefacts for one release.
2. Package them as one release ZIP such as `penelope-x.y.z.zip`.
3. Extract that ZIP into one local workdir (for example on the Live-USB Desktop or later on the installed Desktop).
4. `cd` into the extracted `penelope-x.y.z/` directory.
5. Copy the chosen versioned common library to the unversioned runtime filename:

   ```bash
   cp -f ./penelope-common-<version>.sh ./penelope-common.sh
   ```

6. Run the real Penelope tools from that extracted workdir.

The important contract is therefore:

- a Git clone or a loose source/release directory is a **source base**, not automatically the final runnable object
- the **extracted workdir** is the canonical operator runtime object
- inside that extracted workdir, the unversioned sibling **`penelope-common.sh`** is the authoritative runtime library
- a newer versioned `penelope-common-<version>.sh` beside the scripts remains only a source/release artefact until it is copied or symlinked to `penelope-common.sh`

This same unversioned naming model is used later on the installed system and in recovery bundles:

- installed system library: `/usr/local/lib/penelope/common.sh`
- staged/recovery copy: `penelope-common.sh` next to the staged or recovered Penelope scripts

Operational consequence:

- **bundle-local `penelope-common.sh` should be treated as the authoritative runtime library for that extracted workdir**
- the installed system library is the fallback/default for installed tools on the running system

### Live-USB + release-ZIP-based operator workflow

A practical operator workflow is:

1. Build or obtain the current Penelope release ZIP.
2. Boot the Live-USB.
3. Extract the release ZIP into one local workdir.
4. `cd` into the extracted release directory.
5. Copy the chosen versioned common file to `penelope-common.sh` there.
6. Optional: run `./penelope-walkthrough-assistant-<version>.sh status` or `live-usb` from that same extracted workdir.
7. Generate, edit, and keep the external bootstrap/layout config files in that extracted workdir.
8. Run the installer from that extracted workdir.
9. After reboot, run firstboot and verify.
10. For later backup or Samba updates on the installed host, extract the desired release ZIP again to one temporary workdir, recreate `penelope-common.sh` there, and run the corresponding setup bundle from that extracted workdir.

A Git checkout may still be useful to assemble release artefacts, but the canonical operator runtime object is the extracted release ZIP workdir.

### Update model on a running system

Use Penelope bundles according to their domain:

- **`penelope-install`** remains the destructive Live-USB installer / reinstall tool by default. Do not treat a normal rerun as the routine in-place updater for a running system.
- **`penelope-install --initramfs-only`** is the narrow non-destructive fast-iteration path inside the install bundle. Use it only for initramfs/Dropbear refresh and validation on a plausible existing target system (running host or prepared chroot). It intentionally skips partitioning, mkfs, `cryptsetup luksFormat`, debootstrap, and other destructive install planes.
- **`penelope-install --managed-artifacts-only`** is the broader but still non-destructive install-bundle maintenance plane for a strict allowlist of installer-owned target artifacts. It refreshes the Penelope SSH hardening drop-in, installer-owned ops tools under `/usr/local/sbin`, the manual firstboot helper, the automatic initramfs log-copy helper, and a small initramfs/Dropbear subset, then rebuilds initramfs only if one of those early-boot artifacts changed.
- **`penelope-install --verify-layout-contract`** is the non-destructive install preflight plane for role/profile/sizing verification. It reads the current install layout intent (including `--layout-config` if supplied), runs the same preserve/layout contract checks that would run before a destructive reinstall, prints the plan, persists a manifest/log bundle, and exits before confirmation or destructive steps. The shipped implementation now understands `single-disk`, `two-disk`, `three-disk`, and `four-disk`; the shipped implementation now also supports verification-first fixed-layout selective preserve/recreate for `four-disk`, with the system disk always recreated and preserved home/archive/backup disks verified individually before destructive steps. The persisted verify manifest now also enumerates the requested recreate/preserve targets and, when fixed-layout verification is required, the concrete per-target disk path, role summary, expected partition count, expected PARTLABELs, and size-contract summary.
- **`penelope-backup-setup`** is the normal rerunnable updater for the backup domain on an installed system.
- **`penelope-samba-setup`** is the normal rerunnable updater for the managed Samba domain on an installed system.
- the installed `/usr/local/lib/penelope/common.sh` may be refreshed by the setup bundles that install it
- The canonical operator runbook split is therefore: **Live-USB scratch install or reinstall** in the install bundle, then **software-only updates on the running host** via the narrow install maintenance modes plus normal reruns of `penelope-backup-setup` and `penelope-samba-setup`.

---



### Update-loop config convergence contract

For installed-system patch/update loops, `write-config` means "converge the operator input tree to the current schema". It must not reset existing operator values or active secrets. It may create missing files during first bring-up, append newly introduced known keys with defaults to existing active setup configs, and refresh package-owned `examples/`. For structural pre-release model changes, do not add compatibility code: move the old local test config tree aside deliberately, scaffold the current schema, and copy only intended values/secrets back by hand. After that, `verify-config` checks the active inputs read-only, and `apply` performs the same preflight before runtime changes. Samba default active principals are seeded only for a genuinely fresh setup tree.

## Script set and versions
This documentation is written to match **exactly** these script bundles and installed artifacts:

- **Installer (Live-USB):** `penelope-install-<version>.sh`
- **Backup setup (installed system; run as $ADMIN_USER via sudo):** `penelope-backup-setup-<version>.sh`
  - installs runner **`/usr/local/sbin/penelope-backup.sh`** (**Version: bundle-stamped**, stamped from the bundle)
  - installs backup verify tool **`/usr/local/sbin/penelope-backup-verify.sh`** (**Version: bundle-stamped**, stamped from the bundle)
  - installs USB preparation tool **`/usr/local/sbin/penelope-usb-disk-setup.sh`** (**Version: bundle-stamped**, stamped from the bundle)
  - installs offline recovery tool **`/usr/local/sbin/penelope-offline-recover.sh`** (**Version: bundle-stamped**, stamped from the bundle)
  - successful internal/external backup completions sync a non-secret recovery bundle beside the repos under **`<repo-base>/_recovery/`** (for example `/_backup/<HOST_SCOPE_NAME>/_recovery` and `<USB mount>/<HOST_SCOPE_NAME>/_recovery`). When automatic post-backup verify is enabled, that sync now happens only after the chained verify step has succeeded.
- **Samba share setup (standard installed-system bring-up step):** `penelope-samba-setup-<version>.sh`
- **Optional operator-guided assistant (bundle/workdir helper only; no target installation):** `penelope-walkthrough-assistant-<version>.sh`
- **Credential rotation (installed by penelope-install; run on installed system as root/sudo):** `/usr/local/sbin/penelope-rotate-masterpw-dropbear.sh` (bundle-stamped)
- **Security verification (installed by penelope-install; run on installed system as root/sudo):** `/usr/local/sbin/penelope-verify-security.sh` (bundle-stamped)

**Release bundle rule:** On a target system, the files installed by the Penelope bundles are authoritative. Documentation and operator procedures must reference the installed paths and the bundle versions that produced them.

**Version reference rule:** Concrete current tool versions appear only in **Current tool versions (release bundle)** near the top of this document. The body text and examples stay version-neutral (`penelope-<tool>-<version>.sh`) or use installed target paths.

If you change a bundle script, bump its version and update the **Current tool versions** section (near the top) accordingly.


## 1) Typical workflows

### 1.1 Standard installation (Live-USB)
**Purpose:** Bring a fresh system into the normal Penelope target state: installed OS, firstboot completed, backup tooling installed, Samba installed for normal server operation, and verify checkpoints completed.

**Prerequisites:**
- Live-USB booted in UEFI mode
- current installation bundle available in one directory
- current backup setup bundle available in one directory
- current Samba setup bundle available in one directory

**Live-check quick path:**

Use this as the short operator checklist before following the detailed walkthrough:

1. Extract the release ZIP and `cd` into the extracted workdir.
2. Recreate the runtime common file: `cp -f ./penelope-common-<version>.sh ./penelope-common.sh`.
3. If needed, run `chmod +x ./*.sh`.
4. Run `./penelope-walkthrough-assistant-<version>.sh status` and `live-usb`.
5. Write bootstrap/layout templates, edit them, and keep them with the workdir.
6. Run `--audit-config-evolution`, then `--verify-layout-contract`.
7. Run the real installer.
8. Before reboot, preserve the generated key archives and the effective configs.
9. Reboot, intentionally test Dropbear remote unlock, then run firstboot.
10. Run early `penelope-verify-security.sh`.
11. Extract the same release ZIP on the installed system and recreate `penelope-common.sh`.
12. Bring up backup setup, then run one internal backup and check chained verify.
13. Prepare/register a USB backup disk and run one external backup.
14. Bring up Samba setup and verify the intended client access.
15. Run late `penelope-verify-security.sh` and inspect the recovery bundle.

At the first failure, capture the exact command, full output, relevant logs, and
current config state before applying manual repairs.

**Steps:**
1. Boot the Live-USB in UEFI mode.
2. Extract the current `penelope-x.y.z.zip` release bundle into one local workdir and `cd` into the extracted directory.
3. Recreate the runnable sibling runtime library in that extracted workdir:
   - `cp -f ./penelope-common-<version>.sh ./penelope-common.sh`
   - If the extracted workdir did not preserve executable bits, run `chmod +x ./*.sh` once before invoking the bundle scripts.
4. Optional but recommended: run the guide-layer assistant from that same workdir first:
   - `./penelope-walkthrough-assistant-<version>.sh status`
   - `./penelope-walkthrough-assistant-<version>.sh live-usb`
5. Generate the external install configs from that same workdir:
   - `./penelope-install-<version>.sh --write-bootstrap-config-template ./penelope-install.bootstrap.conf`
   - `./penelope-install-<version>.sh --write-layout-config-template ./penelope-install.layout.conf`
6. Edit the generated bootstrap/layout config pair and resolve all remaining placeholders.
7. If you are reusing older operator-owned install config files with a newer installer release, run the non-destructive config-evolution audit first:
   - `./penelope-install-<version>.sh --audit-config-evolution --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf`
   - If the audit reports absent/older schema markers or missing current keys, generate fresh templates at separate paths and merge the missing current keys into the effective config before runtime.
8. Run the non-destructive install preflight before the real install:
   - `sudo -E ./penelope-install-<version>.sh --verify-layout-contract --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf`
9. Run the real installer from that same extracted workdir:
   - `sudo -E ./penelope-install-<version>.sh --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf`
   - The installer completion banner should already mirror the post-install sequence instead of ending effectively at `sudo reboot`: reboot, manual firstboot, early verify, backup setup, normally Samba setup, late verify.
10. After the first boot, log in as the admin user.
11. Run the manual firstboot step:
    - `sudo /usr/local/sbin/${TARGET_HOST}-firstboot.sh`
    - This manual firstboot step is distinct from the automatic initramfs log persistence path: `penelope-initramfs-logcopy.service` runs `/usr/local/sbin/penelope-copy-initramfs-logs.sh` after boot.
12. Run an **early** verification pass:
    - `sudo -E /usr/local/sbin/penelope-verify-security.sh`
    - At this point, the verifier should already validate the install-owned state and the local staged copies of `penelope-install.sh` and `penelope-common.sh`.
    - It must **not** assume that `penelope-backup-setup` or `penelope-samba-setup` has already been run.
13. Extract the same release ZIP on the installed system into one temporary workdir, recreate `penelope-common.sh` there again, and use that workdir for the software-side setup steps.
14. Run `penelope-backup-setup` from that extracted workdir to install backup automation and tools (runner, udev+systemd autorun, logrotate, dashboard).
15. Run `penelope-samba-setup` from that extracted workdir afterwards as the standard installed-system bring-up step.
16. Run a **late** verification pass:
    - `sudo -E /usr/local/sbin/penelope-verify-security.sh`
    - Now the local staged copies from `penelope-backup-setup` and `penelope-samba-setup` should appear in the recovery-stage checks as well.
    - Late verify should also confirm `/etc/samba/smb.conf`, active Penelope include wiring, successful `testparm -s`, and `smbd` enabled + active.
17. After the first successful internal backup run, run the verifier once more if you want to confirm that the internal `/_backup/<HOST_SCOPE_NAME>/_recovery` bundle has been synced and is sanitized.

**Expected result / What good looks like:**
- install and firstboot complete without unresolved verifier findings
- backup tooling is installed and operational
- Samba tooling is installed for the normal server profile
- early verify shows only install-owned staged artifacts
- late verify shows backup/Samba staged artifacts once those setup steps have run
- bundle verify after the first successful internal backup confirms the synchronized sanitized internal `/_recovery` bundle


#### 1.1.1 Canonical scratch-install walkthrough (`two-disk`, approx. 2 TB + 4 TB)

Use this as the default operator walkthrough for the currently typical Penelope host shape:

- one approx. **2 TB M.2** for `DISK_SYS`
- one approx. **4 TB M.2** for `DISK_DATA`
- `INSTALL_LAYOUT_PROFILE="two-disk"`

This is an explicit **Live-USB scratch install** workflow. You boot the Ubuntu Live system, but you do **not** run the Ubuntu installer itself. Penelope performs the real provisioning.

**Assumptions for this walkthrough:**
- Ubuntu 24.04 Desktop Live-USB boots in **English** and you choose the physically correct keyboard layout during the Live session (for example de-DE).
- The machine has network connectivity in the Live session.
- You obtain the current Penelope release bundle as a `.zip` (or an equivalent archive) and extract it into a temporary workdir such as `~/Desktop/penelope-install-bundle/`. A later Git-based workflow is fine too, but the runnable extracted bundle is the simplest default runbook.
- The current install workflow has **two external operator-managed config surfaces**:
  - the external bootstrap-config file generated by `--write-bootstrap-config-template` (identity / password values)
  - the external layout-config file generated by `--write-layout-config-template` (disk/profile/sizing values)
- Secret-bearing working copies on the Desktop are **temporary staging only**. After the values have been captured in KeePass or an equivalent secure vault and verified, do not keep loose credential files on the Desktop as the routine long-term storage location.

**Walkthrough:**
1. Boot the Live-USB in UEFI mode, choose the correct keyboard layout, and confirm network access.
2. Do **not** start the Ubuntu installer. Open a terminal instead.
3. Create a temporary install workdir and extract the current install bundle there:
   ```bash
   mkdir -p ~/Desktop/penelope-install-bundle
   cd ~/Desktop/penelope-install-bundle
   unzip ~/Downloads/penelope-release.zip
   chmod +x penelope-install-<version>.sh
   ```
4. Identify the two internal disks carefully before editing any config:
   ```bash
   lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINT
   ls -l /dev/disk/by-id/
   ```
   The intended default mapping for this walkthrough is:
   - `DISK_SYS` = the approx. **2 TB** M.2
   - `DISK_DATA` = the approx. **4 TB** M.2

   Prefer stable `/dev/disk/by-id/<device-id>` paths over raw `/dev/nvmeXnY`.
5. Generate a bootstrap-config template and edit it:
   ```bash
   ./penelope-install-<version>.sh --write-bootstrap-config-template ./penelope-install.bootstrap.conf
   nano ./penelope-install.bootstrap.conf
   ```
   Set at least `ADMIN_USER`, `TARGET_HOST`, `CRED_MASTER_PW`, and `CRED_LOGIN_PW` there.
6. Generate a layout-config template and review/edit it:
   ```bash
   ./penelope-install-<version>.sh --write-layout-config-template ./penelope-install.layout.conf
   nano ./penelope-install.layout.conf
   ```
   The template writer now analyzes the currently visible local hardware before writing the file.
   In the canonical clear case (one approx. 2 TB disk plus one approx. 4 TB disk), it auto-fills `DISK_SYS` and `DISK_DATA` with stable `/dev/disk/by-id/<device-id>` paths and records the detected candidates in comments near the top of the file.
   For this walkthrough:
   - keep `INSTALL_LAYOUT_PROFILE="two-disk"`
   - confirm that `DISK_SYS` points at the approx. 2 TB by-id path
   - confirm that `DISK_DATA` points at the approx. 4 TB by-id path
   - leave `DISK_HOME`, `DISK_ARCHIVE`, and `DISK_BACKUP` empty
   - if any `REPLACE_WITH_<VALUE>` values remain, stop and resolve them before runtime
7. Optional but recommended when reusing older operator-owned install config files with a newer installer release: run the config-evolution audit first.
   ```bash
   ./penelope-install-<version>.sh --audit-config-evolution --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
   ```
   If the audit reports absent/older schema markers or missing current keys, generate fresh templates at separate paths and merge the missing current keys into the effective config before runtime. Do **not** blind-overwrite an effective config that already represents the intended host.
8. Optional but recommended: run the non-destructive layout preflight first.
   ```bash
   sudo -E ./penelope-install-<version>.sh --verify-layout-contract --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
   ```
   Review the printed plan and confirm that the 2 TB disk is treated as `DISK_SYS` and the 4 TB disk as `DISK_DATA`.
   The preflight now also refuses unedited template placeholders in the external bootstrap-config or layout-config before any long-running provisioning work starts, and it also refuses external install configs that are missing current schema markers or current keys.
9. Run the real install:
   ```bash
   sudo -E ./penelope-install-<version>.sh --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
   ```
10. **Before reboot**, preserve the generated key archives and the effective operator-edited install artefacts:
   - `${TARGET_HOST}_unlock_keys.7z` (written beside the bootstrap config used for the run)
   - `${ADMIN_USER}_ssh_keys.7z` (written beside the bootstrap config used for the run)
   - the real `penelope-install.bootstrap.conf` you actually used
   - the real `penelope-install.layout.conf` you actually used
   - the chosen non-secret install notes you need later (for example target host, admin user, final by-id disk mapping)

   Record the recovery-relevant secrets in KeePass or an equivalent secure vault immediately, and keep an additional independent copy outside the server. The server itself must not be the only place that holds the credentials or the KeePass database.
10. Reboot.
11. From a **second device on the same network**, test remote unlock on purpose so that the Dropbear path is proven early:
   ```bash
   ssh -i <path-to-extracted-unlock-private-key> -p 2222 root@<ip-or-hostname>
   ```
   Then enter `CRED_MASTER_PW` when prompted by the unlock helper.
12. Let the system boot fully, then log in as the admin user in the normal installed session.
13. Run the mandatory manual firstboot step:
   ```bash
   sudo /usr/local/sbin/${TARGET_HOST}-firstboot.sh
   ```
14. Run the **early verify** checkpoint:
   ```bash
   sudo -E /usr/local/sbin/penelope-verify-security.sh
   ```
15. Prepare a fresh running-system workdir for the setup bundles (again a `.zip` extract on `~/Desktop` is fine), then bring up backup tooling:
   ```bash
   mkdir -p ~/Desktop/penelope-ops-bundle
   cd ~/Desktop/penelope-ops-bundle
   unzip ~/Downloads/penelope-release.zip
   ```
   Fresh bring-up on a newly installed host:
   ```bash
   sudo -E ./penelope-backup-setup-<version>.sh write-config
   sudoedit /etc/penelope/backup-setup/backup-setup.conf
   sudoedit /etc/penelope/backup-setup/secrets.d/system.secret
   sudoedit /etc/penelope/backup-setup/secrets.d/home.secret
   sudoedit /etc/penelope/backup-setup/secrets.d/_archive.secret
   # Optional examples are under /etc/penelope/backup-setup/examples/.
   sudo -E ./penelope-backup-setup-<version>.sh verify-config
   sudo -E ./penelope-backup-setup-<version>.sh apply
   ```
   Recovery / reattach with already restored effective backup state:
   ```bash
   sudo -E ./penelope-backup-setup-<version>.sh verify-config --keep-config --keep-secrets
   sudo -E ./penelope-backup-setup-<version>.sh apply --keep-config --keep-secrets
   ```
   If `/etc/penelope/backup.conf` and `/root/.config/restic/*` were already restored, treat them as the canonical live state, but keep `/etc/penelope/backup-setup/backup-setup.conf` and its `secrets.d/*.secret` files aligned as the operator-owned setup input for future create/reset and verification. On update reruns, `write-config` is safe to run: it refreshes package-owned examples and appends newly introduced known setup keys with defaults, while preserving existing operator values and non-empty secrets. On a mounted non-empty preserved `/_backup`, `verify-config` applies the same scope guard as `apply`: blind bootstrap with the default host scope and explicit creation of a fresh new scope beside historical repos are rejected there; reuse is accepted only when `HOST_SCOPE_NAME` already matches one of the detected existing scopes on disk. `verify-config` and `apply` reject active `change-me` setup secrets; after replacing placeholders with effective restic passwords, capture those effective values in KeePass or an equivalent secure external vault.
16. Verify backup bring-up:
   ```bash
   sudo -E /usr/local/sbin/penelope-verify-security.sh
   sudo /usr/local/sbin/penelope-backup.sh --mode internal
   sudo cat /var/lib/penelope/backup-dashboard/last-verify.json
   sudo tail -n 50 /var/log/*/backup/verify.log
   ```
   Then review the dashboard/log state as described in [1.6 How to verify that backup setup and backup disks are functioning](#16-how-to-verify-that-backup-setup-and-backup-disks-are-functioning). Successful internal and external backups now chain a read-only verify automatically at the end of the run. For an explicit fresh proof run, `backup-verify --run-now` still remains available; on the internal path it now triggers exactly one fresh backup run and one verify pass instead of recursively chaining a second automatic verify.
17. Bring up Samba on the installed host:
   Fresh bring-up on a host without an existing `/etc/penelope/samba-setup` tree:
   ```bash
   sudo -E ./penelope-samba-setup-<version>.sh write-config
   sudoedit /etc/penelope/samba-setup/samba-setup.conf
   sudoedit /etc/penelope/samba-setup/secrets.d/p001.secret
   sudoedit /etc/penelope/samba-setup/secrets.d/p002.secret
   sudoedit /etc/penelope/samba-setup/secrets.d/penelope_client.secret
   sudoedit /etc/penelope/samba-setup/secrets.d/scan.secret
   sudoedit /etc/penelope/samba-setup/secrets.d/backup_dashboard.secret
   sudo -E ./penelope-samba-setup-<version>.sh verify-config
   sudo -E ./penelope-samba-setup-<version>.sh apply
   ```
   Recovery / reattach with an already restored Samba config tree:
   ```bash
   ./penelope-samba-setup-<version>.sh list-users
   ./penelope-samba-setup-<version>.sh list-shares
   sudo -E ./penelope-samba-setup-<version>.sh verify-config
   sudo -E ./penelope-samba-setup-<version>.sh apply
   ```
   If `/etc/penelope/samba-setup` was already restored and has the current schema, treat it as the canonical source of truth. On update reruns, `write-config` is safe to run inside the current schema: it preserves active declarations and non-empty secrets, appends newly introduced known keys to `samba-setup.conf`, and refreshes package-owned examples. Restore or fill any missing effective secrets from KeePass before `verify-config` or `apply`, because active `change-me` secrets are rejected. The default Penelope Samba seed now separates identities from resources: `penelope_client` is the default Windows/Linux workstation identity, `p001` and `p002` are archive identities with additional private archive shares and explicit `default_access` semantics, `scan` is the scanner/printer service identity, and the shared resources are `rawin`, `scan`, `internal`, and readonly `backup_dashboard`. `internal` is a share/resource name, not a Samba login. If an older pre-release schema is still present and you want the new defaults, move the old `/etc/penelope/samba-setup` aside deliberately before running `write-config`; no compatibility migration code is kept for this model change.
   Share-name ownership guardrails now enforced by `verify-config` / `apply`:
   - operator-declared shares must not reuse the fixed Penelope names `rawin`, `scan`, `internal`, or `backup_dashboard`
   - a declared Penelope share must not collide with an already active non-Penelope Samba share
18. Verify Samba bring-up:
   ```bash
   ./penelope-samba-setup-<version>.sh list-users
   ./penelope-samba-setup-<version>.sh list-shares
   sudo -E /usr/local/sbin/penelope-verify-security.sh
   sudo testparm -s
   systemctl status smbd --no-pager
   ```

   Representative Windows SMB client validation:
   ```powershell
   net use
   cmdkey /list | findstr /i PENELOPE
   ```
   Before switching between `penelope_client`, `p001`, `p002`, or another SMB identity on the same Windows client, remove cached server sessions and saved credentials deliberately:
   ```powershell
   net use * /delete
   cmdkey /delete:PENELOPE
   cmdkey /delete:Domain:target=penelope
   ```
   It is acceptable for `cmdkey` to report that an item was not found. Recheck `net use` before continuing. Windows normally allows only one active credential set per SMB server name, so for a p-user with `default_access=yes` provide `/user:` only on the first mapping and map further shares for the same server without repeating `/user:`. This avoids Windows error 1219 and matches the combined workstation/archive model. Example:
   ```powershell
   net use Z: \\PENELOPE\archive_p001 /user:PENELOPE\p001 * /persistent:no
   net use Y: \\PENELOPE\internal /persistent:no
   net use X: \\PENELOPE\scan /persistent:no
   net use W: \\PENELOPE\rawin /persistent:no
   ```
   For the standard client identity, `internal`, `scan`, and `rawin` should be read/write; `backup_dashboard` should be readable but not writable; private archive shares such as `archive_p001` should not map with `penelope_client`. For a p-user such as `p001`, the matching private archive share should be read/write. Another p-user's archive share, such as `archive_p002`, should not open under the existing `p001` session and should prompt for different credentials or fail.

19. Treat **verify all** as the final combined checkpoint for the host:
   - install / initramfs / recovery-stage state via `sudo -E /usr/local/sbin/penelope-verify-security.sh`
   - backup runtime and dashboard state via the checks in section 1.6 plus at least one reviewed `last-internal.json` / `events-internal.log` pair
   - Samba runtime state via `./penelope-samba-setup-<version>.sh list-users`, `./penelope-samba-setup-<version>.sh list-shares`, `sudo testparm -s`, `systemctl status smbd --no-pager`, and the expected managed shares

   In the current tool surface, the scripts now keep the same operator pattern: write config -> edit externally -> verify non-destructively -> apply live state.

#### 1.1.2 Optional guided assistant (`penelope-walkthrough-assistant`)

`penelope-walkthrough-assistant-<version>.sh` is an **optional guide-layer assistant**, not a replacement for `penelope-install`, `penelope-backup-setup`, or `penelope-samba-setup`.

Its current scaffold intentionally stays narrow:

- `./penelope-walkthrough-assistant-<version>.sh live-usb` prints the canonical scratch-install sequence for the Ubuntu **Live-USB** session.
- `./penelope-walkthrough-assistant-<version>.sh installed` prints the canonical post-reboot / installed-system sequence.
- `./penelope-walkthrough-assistant-<version>.sh status` prints the currently detected sibling bundle assets and command paths.
- The current assistant also warns when the sibling runtime file `penelope-common.sh` in that workdir appears older than the newest versioned `penelope-common-<version>.sh` beside it.

Design intent for the helper:

- prefer the explicit term **Live-USB** for the booted Ubuntu session and **installed** for the running system after reboot
- keep the helper idempotent and rerunnable
- keep secrets out of helper state; the helper is not a secret vault and should not try to remember relied-on passwords or keys
- keep the real execution and destructive semantics in the core scripts

So the helper is best understood as a **phase-oriented operator wrapper**: it can be run once before the first reboot and again later on the installed system, but it does not become a second installer implementation.

   - write-config / template paths print numbered **Next steps**
   - verify-config stays a distinct pre-apply checkpoint instead of being folded into the real apply step
   - completion paths print **Next inspect commands** and/or **Next verify commands** where that helps the walk-through stay explicit
20. After the secrets and key archives have been captured externally and verified, remove loose workdir copies of secret-bearing material from the routine work area. KeePassXC on the server may be convenient, but it must **not** be the only copy of the vault or of the recovery-relevant credentials.
21. Current setup bundles normalize displayed bundle commands to bundle-local `./<script>` form, so a walk-through started from `~/Desktop/<workdir>` or another explicit workdir keeps printing reusable workdir commands instead of depending on the original invocation path.

**What good looks like:**
- the 2 TB disk is provisioned as the canonical `DISK_SYS` for the default `two-disk` host shape
- the 4 TB disk is provisioned as the canonical `DISK_DATA`
- remote unlock was tested successfully from another device before the host is accepted
- firstboot, early verify, backup setup, backup verify, Samba setup, Samba verify, and final combined verify all complete without unresolved operator surprises
- no relied-on credentials remain only on the server or only as loose Desktop files


### 1.2 Prepare an external USB backup disk (one-time)
**Purpose:** Either prepare a new removable USB backup disk or register an already prepared Penelope USB backup disk so that future external backups can run through the allow-list and autorun flow.

**Prerequisites:**
- installed system is already running
- backup tooling is installed
- target USB disk is attached

**Steps:**
1. Decide which of the two explicit modes matches the situation:
   - **Create a new Penelope USB backup disk (destructive):**
     - `sudo /usr/local/sbin/penelope-usb-disk-setup.sh --prepare-new`
   - **Register an already prepared Penelope USB backup disk on this system (non-destructive):**
     - `sudo /usr/local/sbin/penelope-usb-disk-setup.sh --register-existing`
2. Do **not** rely on the bare command without a mode in operator runbooks; the tool default is `--prepare-new`, which is the destructive path for creating a new disk.
3. Record the filesystem UUID and the chosen `DISK_NAME` that are associated with the allow-list entry.
4. `DISK_NAME` is mandatory and should be unique on this system. Before choosing a new name, inspect the already registered backup disks:
   - `sudo cat /etc/penelope/usb-backup-disks.conf`
5. If you need to compare the local registrations with the currently attached disks, use:
   - `lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,UUID,MOUNTPOINT`
6. If the desktop automounts the disk and the tool reports “busy”, rerun with `--force` and follow the on-screen diagnostics.

**Expected result / What good looks like:**
- the correct explicit mode was used for the intended scenario
- the disk is prepared or registered successfully
- its filesystem UUID is present in the allow-list
- the local allow-list entry has a human-readable `DISK_NAME`
- a later insert of this disk can trigger the documented external-backup flow

### 1.3 Run an external backup (operator flow)
**Purpose:** Run an external USB backup safely, either via normal autorun or via an explicit manual diagnostic trigger.

Autorun means a new post-boot insert of an allow-listed disk. A disk that was already attached while the host booted is treated as boot-present and is not supposed to start an automatic external backup merely because udev enumerated it during reboot. After that disk is physically removed, the autorun gate must clear the transient boot-present marker so a later reinsert can auto-run normally. To back up a still-attached boot-present disk without unplugging it, run an explicit manual command by UUID or DISK_NAME.

**Prerequisites:**
- backup tooling is installed
- the USB disk is already prepared/registered and allow-listed
- the operator can inspect the Backup-Dashboard files

**Steps:**
1. Insert an allow-listed backup disk.
2. Confirm that the Backup-Dashboard shows `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` for the specific registered disk you just attached; this means that named allow-listed USB backup drive was detected and the backup has started.
3. While `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` is present for that disk, do **not** remove that disk.
4. Only remove the disk when the Backup-Dashboard indicates it is safe to do so for that same disk (i.e. `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` is present and the disk has been unmounted).
5. `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` is cleared automatically again when that disk is physically detached. If the disk disappeared during an incomplete run, the dashboard may later show `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` for that same disk instead of escalating immediately.
6. If a second allow-listed backup disk is attached while another one is already present, each disk keeps its own dashboard signal files. Different allow-listed USB backup disks may therefore run in parallel with each other. The per-disk filenames are the primary user-facing way to understand which disk is running, ready, or on hold. Internal backups still remain serialized against active external runs.
7. If you need a manual diagnostic trigger instead of autorun:
   - Runner (preferred): `sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid <UUID>`
   - Runner by registered disk name: `sudo /usr/local/sbin/penelope-backup.sh --mode external --disk-name <DISK_NAME>`
   - Or via systemd (if the per-UUID unit is installed): `sudo systemctl start penelope-usb-backup@<UUID>.service`
   - If more than one allow-listed backup disk is present, specify `--uuid <UUID>` or `--disk-name <DISK_NAME>` explicitly so the intended disk is unambiguous. `--disk-name` resolves only through `/etc/penelope/usb-backup-disks.conf`; filesystem labels are not scanned or trusted as authorization.
8. Inspect the normal status locations when needed:
   - Status: `systemctl status penelope-usb-backup@<UUID>.service`
   - Quick operator status: `last-external-<DISK_NAME>.json` (latest structured external result for that disk; per-disk, not global)
   - User-facing live state: `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt`, `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt`, `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt`, `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt`
   - Short operational history: `events-external.log`
   - Deep diagnostics: `/var/log/${HOST_SCOPE_NAME}/backup/backup.log` (technical operator log; external runs include short run-context prefixes so overlapping runs remain distinguishable)

**Stopping an external backup deliberately:**
- For an autorun/systemd-started external backup, use `sudo systemctl stop penelope-usb-backup@<UUID>.service`, then inspect `systemctl status` and the mount state under `/_usbbackup/<UUID>` before removing the disk.
- For a manually started external backup in a terminal, press Ctrl-C once and wait for the runner to handle the signal. If it does not return, inspect `pgrep -af 'penelope-backup.sh.*--mode external'` and `pgrep -af 'restic .*penelope_mode=external'` before terminating the specific parent process.
- If the disk remains mounted after a failed or canceled external backup and no relevant backup process is active, unmount only that external USB mountpoint, for example `sudo umount /_usbbackup/<UUID>`. If it is busy, inspect `sudo fuser -vm /_usbbackup/<UUID>` before killing anything.

**Expected result / What good looks like:**
- the Backup-Dashboard shows the per-disk running/do-not-remove state while the job is active
- the job completes without requiring unsafe disk removal
- the Backup-Dashboard eventually shows the per-disk ready-to-remove state and the disk is unmounted
- if the disk was interrupted and is currently absent, the Backup-Dashboard may instead show the per-disk reattach-and-wait state until that same disk is reinserted for a later retry
- diagnostics are available in the documented log and status files if anything goes wrong

**Interruption rule:** If the disk was removed before `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` appeared, or if the host lost power during the run, treat that external backup attempt as **incomplete**. Reattach the same disk later and inspect the per-disk dashboard/log state; do not treat the earlier attempt as successful merely because the service is triggered again.

**Supersession rule:** A later external run that actually starts for the same allow-listed disk becomes the new per-disk dashboard truth for that disk. If that later run reaches `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` successfully, the earlier per-disk `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` state for that same disk is superseded and no longer the current Backup-Dashboard instruction for the Backup Disk Operator.

### 1.4 Live-USB reinstall while preserving `/_backup` (disaster reinstall)
**Purpose:** Reinstall the operating system while preserving the unencrypted `/_backup` partition so that internal repositories and the recovery bundle can be reused.

**Prerequisites:**
- Live-USB booted in UEFI mode
- preserved `/_backup` partition still present and still matches the current preserve contract (`ext4`, readable UUID, `LABEL=_backup`)
- recovery decision taken for `backup.conf` and restic credentials (see chapter 8)

**Steps:**
1. Boot the Live-USB in UEFI mode.
2. In the installer config, set:
   - `RECREATION_TARGET_LIST="system,home,_archive"`
   - No extra `STRICT_VERIFY` / `PENELOPE_STRICT_VERIFY` toggle is available in the current uploaded installer; relevant verification blockers already abort according to per-check severity.
3. Run the installer bundle as root.
4. After the first boot, restore `backup.conf` and the restic password files first (see chapter 8).
   - Then run `penelope-backup-setup --keep-config --keep-secrets` so that the runner, policies, cron, logrotate, udev/systemd integration, and Backup-Dashboard are re-installed without reinitializing secrets.
   - On a mounted non-empty preserved `/_backup`, plain `penelope-backup-setup` now deliberately refuses a blind bootstrap when no concrete backup scope has been restored or explicitly selected. This prevents silently creating a fresh local scope/password state that does not match the preserved repositories. In addition, an explicit `PENELOPE_HOST_SCOPE_NAME` fallback is now accepted there only when it names one of the already detected internal scopes on that preserved partition; the setup no longer treats an explicit but unknown scope as permission to create a fresh internal scope beside historical repos. If `backup.conf` is still missing at that point, the accepted explicit scope is now also persisted into the newly created `backup.conf` instead of falling back to the local host name.
5. After the configuration/credential state is correct, restore `/home` and `/_archive` from the internal repositories on the preserved `/_backup` partition (see chapter 8).

**Expected result / What good looks like:**
- the fresh OS is installed and boots correctly
- preserved internal repositories on `/_backup` remain available
- backup tooling is reattached to the restored configuration and secret material
- `/home` and `/_archive` can be restored from the preserved repositories

### 1.5 Post-install checklist (5 minutes)

Run this once after a fresh install (and especially after a Live-USB disaster reinstall). The goal is to detect common misconfigurations early (mounts, unlock/remote access, initramfs keys, and backup tooling).

#### A) Core mounts and disk layout
- [ ] Confirm expected mounts are present:
  ```bash
  findmnt -rno TARGET,SOURCE,FSTYPE / /boot /boot/efi /home /_archive /_backup
  ```
- [ ] Confirm block devices and filesystems look plausible:
  ```bash
  lsblk -f
  ```

#### B) Unlock / initramfs / remote access
- [ ] Verify the security posture and initramfs integration:
  ```bash
  sudo -E /usr/local/sbin/penelope-verify-security.sh
  ```
- [ ] Review the recovery-related part of the verifier output as well:
  - local recovery-stage directory present
  - install-owned staged copies (`penelope-install.sh`, `penelope-common.sh`) present and syntax-valid immediately after install
  - `penelope-backup-setup.sh` appears there only after `penelope-backup-setup` has run
  - `penelope-samba-setup.sh` appears there only after `penelope-samba-setup` has run
  - internal `/_backup/<HOST_SCOPE_NAME>/_recovery` bundle present and sanitized **only after at least one successful internal backup has already synced it**
- [ ] Treat verifier reruns as phase-aware checkpoints rather than a one-time action:
  - early verify: after install + firstboot
  - late verify: after `penelope-backup-setup` and `penelope-samba-setup`
  - bundle verify: after the first successful internal backup sync
- [ ] If you rely on remote unlock: verify Dropbear is reachable and the initramfs key material is present (see the command output above). If in doubt:
  ```bash
  sudo journalctl -b --no-pager | tail -n 200
  ```

#### C) Backup tooling installed and healthy
- [ ] Ensure backup tooling is installed (bundle) and Cron / USB autorun plumbing are present:
  ```bash
  sudo test -f /etc/cron.d/penelope-backup
  systemctl status 'penelope-usb-backup@*.service' --no-pager || true
  ```
- [ ] Verify backup log location exists (host-scoped):
  ```bash
  sudo ls -la /var/log/*/backup/backup.log 2>/dev/null || true
  ```

#### D) If you preserved `/_backup`
- [ ] Ensure `/_backup` is mounted from UUID (fstab) and contains repos:
  ```bash
  findmnt /_backup
  ls -la /_backup
  ```

#### If anything fails
- Start with:
  ```bash
  lsblk -f
  findmnt
  sudo journalctl -b --no-pager | tail -n 300
  ```
- Then re-run:
  ```bash
  sudo -E /usr/local/sbin/penelope-verify-security.sh
  ```


### 1.6 How to verify that backup setup and backup disks are functioning

Use this as the short operator-facing verification path after install, after a backup-setup rerun, or after preparing/registering a USB backup disk. After `penelope-backup-setup apply`, the current verification path is one immediate fresh proof run, typically `sudo /usr/local/sbin/penelope-backup.sh --mode internal` on fresh internal bring-up or `sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --uuid <UUID> --run-now` or the allow-list alias `--disk-name <DISK_NAME>` on a newly prepared external disk. Successful backups now chain a read-only verify automatically at the end of the run. Manual `penelope-backup-verify.sh` remains available as a separate read-only check, and `--run-now` remains available when you want one explicit fresh proof run. The goal is not to prove every recovery scenario; the goal is to confirm that the installed backup tooling, dashboard signals, repository integrity, and at least one known-good restore path behave as expected.

**1) Confirm setup state is complete**
- Run the phased verifier on the installed system:
  ```bash
  sudo -E /usr/local/sbin/penelope-verify-security.sh
  ```
- Treat the result as phase-aware:
  - **early verify** is expected immediately after install + firstboot
  - **late verify** is expected after `penelope-backup-setup` and `penelope-samba-setup`
  - **bundle verify** becomes meaningful only after the first successful internal backup has synced `/_backup/<HOST_SCOPE_NAME>/_recovery`
- Late verify should not leave unresolved Samba findings.

**2) Confirm the installed backup runtime exists**
- Check the installed runner/config artefacts:
  ```bash
  sudo test -x /usr/local/sbin/penelope-backup.sh
  sudo test -x /usr/local/sbin/penelope-backup-verify.sh
  sudo test -f /etc/penelope/backup.conf
  sudo test -f /etc/cron.d/penelope-backup
  ```
- Confirm the configured host scope and dashboard path:
  ```bash
  sudo grep -E '^(HOST_SCOPE_NAME|BACKUP_DASHBOARD_DIR)=' /etc/penelope/backup.conf
  ```
- Confirm the technical log locations exist:
  ```bash
  sudo ls -ld /var/log/*/backup /var/log/*/backup/backup.log 2>/dev/null || true
  sudo ls -l /var/log/*/backup/verify.log 2>/dev/null || true
  ```

**3) Run the backup proof run**
- Run:
  ```bash
  sudo /usr/local/sbin/penelope-backup.sh --mode internal
  ```
- a successful internal backup run now chains a read-only `penelope-backup-verify.sh --mode internal` automatically, which:
  - checks the internal repositories with `restic check --no-lock`
  - confirms the latest `system`, `home`, and `_archive` snapshots are readable
  - performs a small additional restore probe by restoring `/etc/hostname` from the latest system snapshot
- when you want one explicit fresh proof run from the verify tool itself, use `sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal --run-now`; that path also writes fresh per-target sentinel files and verifies sentinel round trips from the latest snapshots
- Inspect the structured verify result:
  ```bash
  sudo cat /var/lib/penelope/backup-dashboard/last-verify.json
  sudo tail -n 50 /var/log/*/backup/verify.log
  ```
- A healthy internal verify run means:
  - `last-verify.json` exists and the most recent status is `success`
  - `BACKUP_VERIFY_ERROR_CONTACT_OPERATOR.txt` is absent
  - `BACKUP_VERIFY_OK.txt` exists after the completed run
  - `last-internal.json` and `events-internal.log` show the successful internal run; when that run was operator-triggered from `backup-verify --run-now`, they also show the runtime history of that explicit proof run

**4) Confirm an external USB backup disk behaves correctly**
- First confirm the disk is already allow-listed:
  ```bash
  sudo cat /etc/penelope/usb-backup-disks.conf
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,UUID,MOUNTPOINT
  ```
- Insert exactly one known registered disk and watch the Backup-Dashboard directory:
  ```bash
  sudo ls -1 /var/lib/penelope/backup-dashboard/
  ```
- A healthy external run follows this visible sequence for that same `DISK_NAME`:
  1. `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` appears while the job is active
  2. the final state is exactly one of:
     - `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` after successful completion and confirmed unmount
     - `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` when a detached interrupted run should be retried by reinserting the same disk
     - `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` when operator attention is required
  3. `last-external-<DISK_NAME>.json` exists for operator diagnostics
  4. `events-external.log` records the short run history
- The disk is considered functioning only when the dashboard reaches the per-disk `READY` signal for that same disk. A started run, a transient mount, or a success marker alone is not enough.

**5) Confirm the operator-only diagnostics path works**
- If the external run did not end in `READY`, inspect:
  ```bash
  sudo systemctl status 'penelope-usb-backup@*.service' --no-pager || true
  sudo tail -n 200 /var/log/*/backup/backup.log 2>/dev/null || true
  sudo cat /var/lib/penelope/backup-dashboard/last-external-<DISK_NAME>.json 2>/dev/null || true
  ```
- Use the operator decision table in **10.5.3** before retrying, unlocking, or telling the user to remove the disk.

**6) Optional Samba-facing confirmation**
- If the Backup-Dashboard is exported through Samba, confirm that the `backup_dashboard` share is reachable read-only for the intended dashboard user and still reflects the canonical on-disk directory `/var/lib/penelope/backup-dashboard`.

**What good looks like**
- late verify is green for the intended host profile
- the installed backup runner/config/dashboard artefacts exist
- `penelope-backup-verify.sh` succeeds and `last-verify.json` reports `success`
- the verify result shows fresh latest-snapshot round trips for `system`, `home`, and `_archive`
- an allow-listed external disk produces `RUNNING` and eventually the per-disk `READY` signal for that same disk
- when a run does not finish cleanly, the operator can see a clear `HOLD` signal and follow the documented diagnostic path


### 1.7 Penelope software-only update walkthrough (installed system)

Use this runbook when the host is already installed and accepted, and you want to update Penelope tooling without doing a new destructive install.

**Purpose:** Refresh the Penelope software on a running host while keeping the existing installed system, data layout, and operator-managed live config.

**Assumptions:**
- You are logged in as the normal admin user on the installed system.
- You obtain the current Penelope bundle as a `.zip` (or prepare an equivalent runnable workdir from Git) and extract it into a temporary admin-side workdir such as `~/Desktop/penelope-update-bundle/`.
- Existing effective secrets already live in KeePass or another secure external vault.
- The installed runtime files under `/usr/local/sbin/`, `/usr/local/lib/penelope/`, `/etc/penelope/backup*`, and `/etc/penelope/samba-setup/` remain the authoritative live state; the Desktop workdir is only the update workspace.

**Runbook:**
1. Create a temporary update workdir on the installed system and extract the current bundle there:
   ```bash
   mkdir -p ~/Desktop/penelope-update-bundle
   cd ~/Desktop/penelope-update-bundle
   unzip ~/Downloads/penelope-release.zip
   ```
2. Recreate or refresh the authoritative sibling runtime library in that extracted workdir before any real bundle run:
   ```bash
   cp -f ./penelope-common-<version>.sh ./penelope-common.sh
   ```
   A Git-based workflow is fine later, but the same runnable-bundle rule still applies: the extracted workdir is the real runtime object, and its unversioned sibling `penelope-common.sh` is the library actually sourced by the bundle scripts.
3. Decide which domain actually changed. Do **not** treat a normal rerun of `penelope-install` as the generic all-purpose in-place updater for a running host.
4. If you only need an initramfs / Dropbear / early-boot refresh from the install bundle, use:
   ```bash
   sudo -E ./penelope-install-<version>.sh --initramfs-only
   ```
5. If you need the broader installer-owned but still non-destructive maintenance plane, use:
   ```bash
   sudo -E ./penelope-install-<version>.sh --managed-artifacts-only
   ```
6. After either install-bundle maintenance mode, run the standard verify checkpoint:
   ```bash
   sudo -E /usr/local/sbin/penelope-verify-security.sh
   ```
7. For a normal backup-tooling software update on the installed host, rerun the backup setup bundle from the temporary workdir:
   ```bash
   sudo -E ./penelope-backup-setup-<version>.sh verify-config --keep-secrets
   sudo -E ./penelope-backup-setup-<version>.sh apply --keep-secrets
   ```
   Decision rule:
   - keep the default merge behavior when you want new documented non-secret keys appended into `/etc/penelope/backup.conf`
   - use `--keep-config --keep-secrets` when you want a strict tooling-only refresh without changing the live config file content
8. If you intentionally changed effective restic or Samba credentials during the update, store the **effective** new values in KeePass immediately. Routine updates must not leave the only current credential copy on the server.
9. For a normal Samba software/config update, edit the live config tree under `/etc/penelope/samba-setup/` if needed, then rerun the same preflight/apply split:
   ```bash
   sudo -E ./penelope-samba-setup-<version>.sh verify-config
   sudo -E ./penelope-samba-setup-<version>.sh apply
   ```
10. Run the verification checkpoints relevant to the domains you touched:
   ```bash
   sudo -E /usr/local/sbin/penelope-verify-security.sh
   sudo testparm -s
   systemctl status smbd --no-pager
   ```
   If the Samba domain was touched, also run the standard inspect pair from the same temporary workdir:
   ```bash
   ./penelope-samba-setup-<version>.sh list-users
   ./penelope-samba-setup-<version>.sh list-shares
   ```
   If the backup domain was touched, also use the checks from [1.6 How to verify that backup setup and backup disks are functioning](#16-how-to-verify-that-backup-setup-and-backup-disks-are-functioning). The current backup verification command is:
   ```bash
   sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal --run-now
   ```
11. After the update succeeds, do not leave loose secret-bearing notes, edited password files, or the only KeePass database copy on the server Desktop. The Desktop update workdir is disposable; the relied-on credential store must remain redundantly available outside the server.

**What good looks like:**
- the correct Penelope domain tools were rerun without invoking a destructive reinstall
- install-bundle maintenance, backup updates, and Samba updates remain clearly separated
- verifier, backup checks, and Samba checks all pass for the domains that were touched
- the authoritative live config stays under `/etc/penelope/<component>`, while the admin Desktop workdir remains only a temporary update workspace

## 2) System overview

This chapter defines the hardware assumptions, partition layout, and the core credential/unlock model. It is the reference baseline for all installation and recovery workflows.

### 2.1 Hardware assumptions
- Penelope is hardware-profile driven; the current installer is not tied to a single vendor/model.
- No RAID in the shipped profile assumptions unless a future explicit profile states otherwise.
- The current shipped installer supports four explicit provisioning profiles:
  - `two-disk`
  - `single-disk`
  - `three-disk`
  - `four-disk`
- Disk capacities shown in examples are only examples. They are **not** the long-term Penelope architecture contract.

### 2.2 Canonical logical storage roles

Penelope's stable storage model is defined first by **logical roles**, not by example disk sizes:

- `/boot/efi`
- `/boot`
- `/`
- `/home`
- `/_archive`
- `/_backup`

The first four roles together form the canonical install/recovery contract. Future install layout profiles may place these roles on one disk, two disks, or later other explicit profile topologies, but the logical role names remain the canonical operator and recovery vocabulary.

`/_backup` remains the intentionally readable local backup/recovery area and is mounted with `nofail`. A missing or temporarily absent backup device must not block boot; backup tooling should detect/report the degraded state separately.

### 2.3 Current shipped layout profiles

#### `INSTALL_LAYOUT_PROFILE="two-disk"` (shipped default)

The shipped default hardware example for this profile is:
- `DISK_SYS` ~= 2 TB M.2 for `/boot/efi`, `/boot`, `/`, `/home`
- `DISK_DATA` ~= 4 TB M.2 for `/_archive`, `/_backup`

##### System disk (`DISK_SYS`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 512 MiB | FAT32 (ESP) | `/boot/efi` | unencrypted |
| 2 | ~1.5 GiB | ext4 | `/boot` | unencrypted |
| 3 | 220 GiB | ext4 (inside LUKS2) | `/` | LUKS2 |
| 4 | remaining | ext4 (inside LUKS2) | `/home` | LUKS2 |

##### Data disk (`DISK_DATA`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 1 TiB | ext4 (inside LUKS2) | `/_archive` | LUKS2 |
| 2 | remaining | ext4 | `/_backup` | unencrypted |

#### `INSTALL_LAYOUT_PROFILE="single-disk"`

##### Only disk (`DISK_SYS`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 512 MiB | FAT32 (ESP) | `/boot/efi` | unencrypted |
| 2 | ~1.5 GiB | ext4 | `/boot` | unencrypted |
| 3 | 220 GiB | ext4 (inside LUKS2) | `/` | LUKS2 |
| 4 | 200 GiB | ext4 (inside LUKS2) | `/home` | LUKS2 |
| 5 | 1 TiB | ext4 (inside LUKS2) | `/_archive` | LUKS2 |
| 6 | remaining | ext4 | `/_backup` | unencrypted |

#### `INSTALL_LAYOUT_PROFILE="three-disk"`

Canonical meaning:
- `DISK_SYS` -> `/boot/efi`, `/boot`, `/`
- `DISK_HOME` -> `/home`
- `DISK_DATA` -> `/_archive`, `/_backup`

##### System disk (`DISK_SYS`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 512 MiB | FAT32 (ESP) | `/boot/efi` | unencrypted |
| 2 | ~1.5 GiB | ext4 | `/boot` | unencrypted |
| 3 | remaining | ext4 (inside LUKS2) | `/` | LUKS2 |

##### Home disk (`DISK_HOME`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | remaining | ext4 (inside LUKS2) | `/home` | LUKS2 |

##### Data disk (`DISK_DATA`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 1 TiB | ext4 (inside LUKS2) | `/_archive` | LUKS2 |
| 2 | remaining | ext4 | `/_backup` | unencrypted |

#### `INSTALL_LAYOUT_PROFILE="four-disk"`

Canonical meaning:
- `DISK_SYS` -> `/boot/efi`, `/boot`, `/`
- `DISK_HOME` -> `/home`
- `DISK_ARCHIVE` -> `/_archive`
- `DISK_BACKUP` -> `/_backup`

Current shipped step:
- provisioning / reinstall support is shipped
- selective preserve/recreate for `four-disk` is now shipped in **verification-first fixed-layout mode**
- the system disk is always recreated; preserved `home`, `archive`, and/or `backup` disks must already match the shipped `four-disk` contract closely enough that no repartitioning/resizing is required on those preserved disks

##### System disk (`DISK_SYS`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | 512 MiB | FAT32 (ESP) | `/boot/efi` | unencrypted |
| 2 | ~1.5 GiB | ext4 | `/boot` | unencrypted |
| 3 | 220 GiB | ext4 (inside LUKS2) | `/` | LUKS2 |

##### Home disk (`DISK_HOME`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | remaining | ext4 (inside LUKS2) | `/home` | LUKS2 |

##### Archive disk (`DISK_ARCHIVE`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | remaining | ext4 (inside LUKS2) | `/_archive` | LUKS2 |

##### Backup disk (`DISK_BACKUP`)
| Partition | Size (approx.) | Type / FS | Mountpoint | Encryption |
|---|---:|---|---|---|
| 1 | remaining | ext4 | `/_backup` | unencrypted |

These are the current shipped provisioning profiles, not the only future Penelope topologies. The current shipped default remains the `two-disk` profile, and its 2 TB / 4 TB example hardware split is the default example for the shipped installer/template set, not a project-wide architecture law. The shipped `three-disk` and `four-disk` profiles extend the same canonical logical-role model with cleaner multi-disk placement, not a different architecture. Future expansion must still come through explicit named install layout profiles instead of silently hard-coding one example hardware split into the project model.

### 2.4 Password/Unlock behavior

#### 2.3.1 Rotating CRED_MASTER_PW and the Dropbear unlock key

Use this when you want to invalidate an old master password and/or an old Dropbear initramfs unlock key.

Run on the **installed system** as root:
```bash
sudo /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh
```
The script will:
- ask for **old** `CRED_MASTER_PW` once,
- ask for **new** `CRED_MASTER_PW` twice (must match),
- rotate the LUKS passphrase for all encrypted volumes listed in `/etc/hostname`,
- generate a new Dropbear unlock keypair,
- write a new restrictive `/etc/dropbear/initramfs/authorized_keys`,
- create a new encrypted 7z archive (password = **new** `CRED_MASTER_PW`) in your current working directory,
- update initramfs.

Afterwards reboot once and verify remote unlock works with the **new** key and **new** `CRED_MASTER_PW`.

Notes:
- **One** master password (`CRED_MASTER_PW`) unlocks **three** LUKS volumes (`/`, `/home`, `/_archive`).
- During early boot (initramfs), unlock is possible via local keyboard prompt or via remote Dropbear (default port `2222`).
- Only **one** passphrase entry is intended (using `decrypt_keyctl` in `crypttab` to reuse the first passphrase for additional LUKS volumes).

### 2.5 Desktop/Remote access
- Ubuntu 24.04 LTS Desktop (noble) + HWE kernel.
- AnyDesk installed; GDM configured for X11 (Wayland disabled).
- KeePassXC installed on the target desktop for local operator secret handling (no automated secret export/population).
- **First boot:** remote unlock is done via Dropbear (initramfs). After the system boots, log in as the admin user in GNOME.
- **Manual firstboot:** run `sudo /usr/local/sbin/${TARGET_HOST}-firstboot.sh` from a GNOME terminal (no firstboot systemd service).
- **AnyDesk:** the installer installs and starts AnyDesk, but **does not** set an unattended password. Enable “no session request” and set the full-access password in the AnyDesk GUI after the first GNOME login.

---

## 3) Prerequisites and assumptions

This chapter lists the environmental prerequisites (UEFI/Secure Boot/networking) and basic operational assumptions. Read this before running the installer.

### 3.1 UEFI mode
Installation must run in UEFI mode.

Validation in Live-USB session:
```bash
ls /sys/firmware/efi/efivars
```
If the directory exists, the live system was booted in UEFI mode.

### 3.2 Secure Boot
Secure Boot being **disabled** in BIOS is acceptable and compatible with this setup.
(Installation uses signed EFI components, but does not require Secure Boot.)

### 3.3 Networking
- LAN via DHCP is assumed.
- Remote unlock depends on early-boot DHCP (initramfs).
- The unlock workstation must be able to reach TCP port `2222` on the target during initramfs boot. If host, site, VLAN, VPN, or other network firewalls are in the path, allow that traffic explicitly for the intended management path; Penelope does not open that path for you automatically.
- If no reliable wired NIC can be identified at install time, the installer leaves initramfs `DEVICE` unset and warns; initramfs then auto-selects an interface. On multi-NIC systems, set `PENELOPE_INITRAMFS_IFACE` explicitly before the real install.

#### 3.3.1 Remote-first operational model (default)
Penelope is operated **remote-first**: unlocking encrypted disks via **SSH (Dropbear in initramfs)** is the default and expected workflow.

**Operator constraint:** In the standard scenario, the machine is **not physically accessible** at boot time. Therefore:
- Do not rely on local keyboard unlock as a recovery mechanism.
- Do not rely on per-boot BIOS/GRUB changes or kernel-parameter toggles (cannot be applied remotely while initramfs is waiting).
- A boot that requires physical intervention is treated as a **hard failure**.

#### 3.3.2 Initramfs command contract (tool availability)
Initramfs scripts must only rely on commands that are **proven present** in the initramfs build used for the current boot.

**Contract source of truth:** `/var/log/${TARGET_HOST}/initramfs/penelope-initramfs-diag.log` → section `## command inventory (initramfs)`.
It reports per-command availability as `OK:` or `MISSING:` for the *actual initramfs used at boot*.

Rules:
- Treat the inventory’s **OK/MISSING** status as the contract.
- For Penelope remote unlock, the built initramfs must contain at least `dropbear`, `dropbear.conf`, `authorized_keys`, `cryptroot-unlock`, and `decrypt_keyctl`.
- Prefer POSIX-shell read loops (`while IFS= read -r line`) and `/proc` parsing over external tools.
- If an optional command is used, guard it with a presence check (e.g. `command -v <cmd>`), and keep the script functional without it.

#### 3.3.3 Initramfs DHCP stability requirement
Because SSH unlock is the default scenario, initramfs DHCP handling must be resilient and bounded:
- Avoid multi-minute exponential backoff loops that delay the boot.
- If a DHCP client returns non-zero but a non-link-local IPv4 address **and** a default route are already present, treat networking as usable and proceed to Dropbear.
- Minimize DHCP hook surface in initramfs (e.g. do not require resolv.conf/hostname hooks for unlock).

### 3.4 Data loss warning
Penelope installation scripts **wipe and repartition** both disks (`DISK_SYS` and `DISK_DATA`). No data is preserved.

### 3.5 Text file format
Scripts must be saved with **LF** line endings (Unix format). CRLF can break parsing.

---

## 4) Installation (penelope-install)

This chapter documents the Live-USB installation process. The default is destructive; use `RECREATION_TARGET_LIST` to preserve selected data targets during reinstall.

### 4.1 What penelope-install does
At a high level, `penelope-install`:

1. Cleans up from any previous run (unmount + close LUKS mappings).
2. Generates a Dropbear/Initramfs unlock SSH keypair and stores it as an encrypted 7z archive beside the **bootstrap-config used for the install run**.
3. By default, wipes both disk disks completely (**data loss**). Optionally, `RECREATION_TARGET_LIST` can preserve selected targets (e.g., preserve `/_backup`).
4. Creates the partitions as specified.
5. Sets up LUKS2 on `/`, `/home`, `/_archive` with one passphrase.
6. Creates filesystems and mounts them in the correct order (`/boot` first, then `/boot/efi`).
7. Installs Ubuntu via `debootstrap` and configures it in a chroot (locale/timezone/keyboard, desktop+HWE, GRUB EFI, Dropbear initramfs remote unlock, crypttab with `decrypt_keyctl`, admin user with sudo, KeePassXC, AnyDesk best-effort, disable Wayland).
8. Exports a second encrypted 7z archive beside the **bootstrap-config used for the install run** containing the SSH keypair for `$ADMIN_USER`.

#### 4.1.1 Recreation policy (`RECREATION_TARGET_LIST`)
`penelope-install` no longer expects routine operator edits in the script body for identity/password bootstrapping. Instead, real provisioning runs externalize those values into `--bootstrap-config <path>` (`ADMIN_USER`, `TARGET_HOST`, `CRED_MASTER_PW`, `CRED_LOGIN_PW`) while disk/profile/sizing values stay in the separate optional `--layout-config <path>`. The `CRED_` prefix is used only for top-level credential carriers; `ADMIN_USER` and `TARGET_HOST` remain unprefixed identifiers. For required operator-edited secrets, the shipped placeholder remains the literal value `change-me`; replace it in the external bootstrap-config before any real execution. Whenever you set or later change credential-bearing bootstrap values that become effective on a real system, record the effective secrets in KeePass or an equivalent external recovery vault immediately. For recovery workflows it also supports a **recreation policy** via a single configuration constant:

- `RECREATION_TARGET_LIST="all"` (default; full reinstall with full data loss on all targets)

Allowed tokens (comma-separated): `system,home,_archive,_backup,all`

Rules and semantics:

- The list must include **`system`** or **`all`**. If it contains neither, the installer aborts.
- `system` means: recreate the **system stack** including `/` **and always refresh `/boot` and `/boot/efi`** (bootloader/EFI contents are updated).
- Examples:
  - `all` → recreate everything (`system,home,_archive,_backup`)
  - `system,home,_archive` → preserve `/_backup` (no wipe/mkfs on the backup partition)
  - `system,home` → preserve `/_archive` and `/_backup`
  - `system` → preserve `/home`, `/_archive`, and `/_backup`

Additional profile note:
- In `INSTALL_LAYOUT_PROFILE="single-disk"`, selective preserve/recreate is supported only when the run matches the existing unchanged Penelope single-disk layout closely enough that no repartitioning or resizing is required.
- In that case the installer keeps the partition table unchanged, verifies role partitions/labels/size intent first, then refreshes only the selected role partitions in place.
- If the requested single-disk config implies profile drift, placement drift, sizing drift, or unverifiable preserved targets, the installer aborts before destructive steps.
- Those refusal paths are now expected to name the concrete drift reason and to point the operator at the safe next step instead of only failing generically.
- In the shipped `three-disk` profile, selective preserve/recreate is now supported only in verification-first fixed-layout mode: the system disk is always recreated, while preserved `home` and/or data disks must already match the existing Penelope three-disk layout closely enough that no repartitioning/resizing is required on those preserved disks.
- In the shipped `four-disk` profile, selective preserve/recreate is supported only in verification-first fixed-layout mode: the system disk is always recreated, while preserved `home`, `archive`, and/or `backup` disks must already match the existing Penelope four-disk layout closely enough that no repartitioning/resizing is required on those preserved disks.

Important: `penelope-install` recreates **partitions and filesystems**; it does not restore user data. After reinstall, follow the documented recovery flow: restore `backup.conf` and restic credential material first where possible, then run `penelope-backup-setup --keep-config --keep-secrets` if the operational tooling must be reattached to the restored repository scope, and only then restore data from the chosen repositories/snapshots.

#### 4.1.2 Verification failure policy
The current uploaded installer does **not** expose an operator-set runtime toggle named `STRICT_VERIFY` or `PENELOPE_STRICT_VERIFY`.

Current behavior in the uploaded code:

- verification and validation checks run according to the installer's built-in flow
- severity is defined **per check**, not by a single global lax/strict switch
- findings that can endanger installation correctness, later stable operation, disk-layout consistency, bootability, or remote SSH unlock are treated as **fatal**
- non-critical observability/comfort findings may still be logged as warnings when the owning check explicitly classifies them that way

Operational consequence:

- For Live-USB recovery and reinstall runbooks, do **not** instruct operators to set `STRICT_VERIFY=1`; that variable is not part of the current uploaded installer interface.
- Instead, rely on the installer's current fail-fast behavior for relevant verification blockers and troubleshoot the concrete failed check.

Typical verification failures you may see:
- Dropbear/initramfs verification did not find expected keys in the initramfs image.
- Preserve-target checks (e.g., `/_backup` is missing, not `ext4`, has no readable UUID, or carries a missing/wrong label instead of `LABEL=_backup`).
- Preserving encrypted targets: the configured `CRED_MASTER_PW` does not unlock an existing LUKS container (the installer aborts before destructive steps).

Troubleshooting pointers for installation failures are included in the troubleshooting section (see 10.7).

Debug/diagnostic instrumentation should be treated as **observation code**, not as a workaround path:
- It must not initialize variables, apply fallbacks, or otherwise change behavior that the normal (non-diagnostic) path depends on.
- A run that succeeds only with extra diagnostic/debug code enabled is **not** considered a valid production result.
- For productive runs, keep diagnostics minimal unless explicitly needed for troubleshooting.

#### 4.1.3 Post-install security verification
Run the installed verification tool on the **installed system** (after first boot):

```bash
sudo -E /usr/local/sbin/penelope-verify-security.sh
```

The installer remains fail-fast for relevant verification blockers. The commands below remain useful as manual checks after first boot (or after a failed run) to validate the remote-unlock path, in addition to the built-in verifier tool:

```bash
# Show current block layout
lsblk -f

# Check expected crypttab entries
sudo cat /etc/crypttab

# Check dropbear initramfs key material exists
sudo ls -la /etc/dropbear/initramfs/

# Verify that the initramfs contains dropbear (and keys) for remote unlock
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'dropbear|authorized_keys' || true

# Check recent installer/boot logs (adjust units as needed)
sudo journalctl -b --no-pager | tail -n 200
```

If remote unlock fails, verify that the private key used by your operator workstation matches the public key configured in `/etc/dropbear/initramfs/authorized_keys`, and re-run `sudo update-initramfs -u -k all` followed by a controlled reboot.

### 4.2 Required inputs (external bootstrap-config plus external layout-config)
Typical values to configure in the external install bootstrap-config are:
- `ADMIN_USER`
- `TARGET_HOST`
- `CRED_MASTER_PW` (LUKS passphrase)
- `CRED_LOGIN_PW` (Ubuntu login password)

Typical values to configure in the external layout-config are:
- `INSTALL_LAYOUT_PROFILE`
- `DISK_SYS`, `DISK_DATA`, `DISK_HOME`, `DISK_ARCHIVE`, `DISK_BACKUP` as required by the selected profile
- sizing values such as `ROOT_SIZE_GIB` and `ARCHIVE_SIZE_GIB`

The layout-config template writer now performs a local hardware scan when the file is generated. In the canonical clear `two-disk` case (one approx. 2 TB whole disk plus one approx. 4 TB whole disk), it auto-fills `DISK_SYS` and `DISK_DATA` with stable `/dev/disk/by-id/<device-id>` paths and records the detected candidates in comments. If the situation is ambiguous, the file is still written, but unresolved values remain visibly marked and must be fixed before runtime.

Additional direct script/runtime input:
- `DROPBEAR_PORT` (default 2222; may still be overridden explicitly when needed)

Secrets note (external-config-before-run): The bootstrap-config template ships with dummy password placeholders.
Before running, replace `CRED_MASTER_PW` and `CRED_LOGIN_PW` with strong unique values in the external bootstrap-config and store them redundantly outside the system
(for example in KeePass, a separate secure vault, or a sealed printed recovery record). **As soon as the installation is accepted for use, record the effective values in KeePass immediately.** Do not rely on a loose Desktop copy or on a vault stored only on the server.
Treat these install-time secrets as recovery prerequisites: after a reinstall or offline restore you may need the same `CRED_MASTER_PW`, the admin login password, and the Dropbear/admin key archives again.
AnyDesk is installed by the installer, but **unattended/full access is enabled manually** after the first GNOME login (see 9.4). If you configure an AnyDesk unattended password, store that password redundantly outside the system as well.
The installer is designed to avoid logging secrets; do not enable shell tracing (`set -x`) during a productive run.

### 4.2.1 Install layout profiles and config seam (phase-5)

Disk selection, partition layout, and sizing belong conceptually to the **external operator-edited layout-config**. Identity/password bootstrapping lives separately in the external bootstrap-config. The explicit layout seam now starts with:

- `INSTALL_LAYOUT_PROFILE`
- `DISK_SYS`
- `DISK_HOME`
- `DISK_DATA`
- `DISK_ARCHIVE`
- `DISK_BACKUP`
- `EFI_SIZE_MIB`
- `BOOT_SIZE_MIB`
- `ROOT_SIZE_GIB`
- `HOME_SIZE_GIB`
- `ARCHIVE_SIZE_GIB`

Current contract:

- Shipped explicit profiles today:
  - `two-disk`
  - `single-disk`
  - `three-disk`
  - `four-disk`
- The logical storage roles remain canonical: `/boot/efi`, `/boot`, `/`, `/home`, `/_archive`, `/_backup`.
- Example capacities are sizing defaults for the shipped profiles, not a project-wide architecture law.
- The current shipped default example is the `two-disk` profile with an approx. 2 TB system/home disk and an approx. 4 TB archive/backup disk.
- Future profiles (for example later broader multi-disk placements such as `custom`) should extend this seam explicitly instead of hard-coding one hardware example deeper into the installer.
- These layout controls belong only to the **destructive provisioning/reinstall plane** of `penelope-install`; they are **not** consumed by `--initramfs-only` or `--managed-artifacts-only`.
- `penelope-install-<version>.sh` continues the external config-file seam for this area:
  - `--write-layout-config-template <path>` writes an operator-editable layout-config template and now also analyzes the currently visible hardware to prefill the canonical `two-disk` mapping when the local disk picture is clear.
  - `--layout-config <path>` is required for the full install/reinstall provisioning path and for `--verify-layout-contract`; inline shipped layout defaults are no longer accepted there.
  - `--audit-config-evolution --bootstrap-config <path> --layout-config <path>` reports whether an older operator-owned config pair is missing current schema markers or current keys before you attempt runtime reuse.
  - unresolved `REPLACE_WITH_<VALUE>` device placeholders in the layout-config are refused before runtime.
  - when an external install config file is present, the current-only contract is strict: Penelope install does not silently fall back to shipped inline defaults or placeholders for missing current keys.
- The current shipped config-file schema remains intentionally narrow and supports:
  - `INSTALL_LAYOUT_PROFILE`
  - `DISK_SYS`
  - `DISK_HOME`
  - `DISK_DATA`
  - `DISK_ARCHIVE`
  - `DISK_BACKUP`
  - `EFI_SIZE_MIB`
  - `BOOT_SIZE_MIB`
  - `ROOT_SIZE_GIB`
  - `HOME_SIZE_GIB`
  - `ARCHIVE_SIZE_GIB`
- Phase-3/4/5/6/8/11/12 profile rules:
  - `two-disk` remains the shipped default profile and routes selective preserve/recreate through the reusable **profile-verification scaffold** on each preserved disk
  - in `two-disk`, preserved disks must still match the shipped role-partition contract closely enough that no repartitioning/resizing is required on those preserved disks; fully recreated disks may still be repartitioned
  - `single-disk` supports selective preserve/recreate only in **fixed-layout mode**
  - `three-disk` is a shipped provisioning profile with `system` on `DISK_SYS`, `home` on `DISK_HOME`, and `archive+backup` on `DISK_DATA`; selective preserve/recreate is supported only in verification-first fixed-layout mode, with the system disk always recreated
  - `four-disk` is now a shipped provisioning profile with `system` on `DISK_SYS`, `home` on `DISK_HOME`, `archive` on `DISK_ARCHIVE`, and `backup` on `DISK_BACKUP`; selective preserve/recreate is supported only in verification-first fixed-layout mode, with the system disk always recreated
  - fixed-layout mode means: existing Penelope profile layout already present, same selected profile, same role/partition order for every preserved disk, no repartitioning/resizing on preserved disks, and successful verification before destructive steps
  - if the requested preserve run would imply profile drift, sizing drift, repartitioning, or unverifiable preserved role targets on a preserved disk, the installer aborts loudly instead of guessing
  - those fixed-layout refusal paths now name not only the drift reason, contract summary, and safe next step, but also the current preserve targets and fixed-layout verification targets for faster operator triage
  - the current shipped installer routes this through a reusable **profile-verification scaffold** so later profiles can plug into the same pre-destructive verification/refusal structure
  - the persisted verify manifest now records the requested recreate/preserve targets and, for every fixed-layout verification target, the concrete disk path, role summary, expected partition count, expected PARTLABELs, and size-contract summary
  - unsupported future profile names still fail loudly
  - there is no silent fallback guessing

So the current Penelope direction is: make storage topology declarative and operator-editable, but keep its evaluation strictly inside the destructive install plane.

### 4.3 Installation procedure (Live-USB)
1. Boot Ubuntu 24.04 Desktop Live-USB in **UEFI** mode.
2. Open a terminal.
3. Work from one assembled runnable bundle/workdir, not from a loose artefact set:
   - extract the current release ZIP into one directory
   - `cd` into that extracted workdir
   - ensure the sibling runtime library `penelope-common.sh` exists there
   - if the workdir currently contains only `penelope-common-<version>.sh`, copy it to `penelope-common.sh` before running the latest tools
4. Generate and edit the external bootstrap-config:
```bash
chmod +x ./*.sh
./penelope-install-<version>.sh --write-bootstrap-config-template ./penelope-install.bootstrap.conf
nano ./penelope-install.bootstrap.conf
```
5. Generate and edit the external layout-config:
```bash
./penelope-install-<version>.sh --write-layout-config-template ./penelope-install.layout.conf
nano ./penelope-install.layout.conf
```
6. Optional but recommended when reusing older operator-owned install config files: run the config-evolution audit first.
```bash
./penelope-install-<version>.sh --audit-config-evolution --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
```
7. Recommended non-destructive preflight before the real install:
```bash
sudo -E ./penelope-install-<version>.sh --verify-layout-contract --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
```
8. Run the real installer **as root** from that same workdir:
```bash
sudo -E ./penelope-install-<version>.sh --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
```

Current install contract:
- real install/reinstall runs require an explicit external `--bootstrap-config <path>`
- real install/reinstall runs also require an explicit external `--layout-config <path>`
- `--audit-config-evolution` is the non-destructive forward-update seam for older operator-owned install config files
- `--verify-layout-contract` uses the same external config pair and stays strictly non-destructive
- shipped inline placeholders/defaults are **not** accepted as the live operator input surface for full install/reinstall or verify-layout-contract runs
- when an external config file is present, missing current schema markers or missing current keys are a loud stop condition, not a silent fallback case

Typical profile examples:
- `two-disk` (shipped default): `DISK_SYS` + `DISK_DATA`; default example hardware is approx. 2 TB for `DISK_SYS` and approx. 4 TB for `DISK_DATA`
- `single-disk`: set `INSTALL_LAYOUT_PROFILE="single-disk"`, point `DISK_SYS` at the only disk, and leave `DISK_HOME`/`DISK_DATA` empty
- `three-disk`: set `INSTALL_LAYOUT_PROFILE="three-disk"`, point `DISK_SYS` at the system disk, `DISK_HOME` at the home disk, and `DISK_DATA` at the archive/backup disk
- `four-disk`: set `INSTALL_LAYOUT_PROFILE="four-disk"`, point `DISK_SYS` at the system disk, `DISK_HOME` at the home disk, `DISK_ARCHIVE` at the archive disk, and `DISK_BACKUP` at the backup disk; leave `DISK_DATA` empty
9. At script end, **before reboot**, copy the generated artifacts (see next section).

### 4.4 Artifacts to preserve (IMPORTANT)
At the end of the run, the installer writes two encrypted archives beside the bootstrap-config used for that run:

- `${TARGET_HOST}_unlock_keys.7z`
  Contains the SSH keypair used to connect to Dropbear in initramfs (remote unlock).

- `${ADMIN_USER}_ssh_keys.7z`
  Contains a copy of `$ADMIN_USER`’s SSH keypair (private/public) for later login.

Both archives are encrypted with **CRED_MASTER_PW**.
You must copy both files off the Live-USB environment (e.g., to a USB stick or to another LAN host) **before reboot**.
Recommended: store them in KeePass or equivalent.
Do not keep the only relied-on copy on the server or only in the temporary workdir. After you have captured and verified the archives in an external secure vault/workflow, remove loose workdir copies from the normal routine workspace.

### 4.5 Initramfs-only refresh (non-destructive fast iteration)

`penelope-install` now exposes a narrow non-destructive maintenance path:

```bash
sudo -E ./penelope-install-<version>.sh --initramfs-only
```

Optional kernel targeting:

```bash
sudo -E ./penelope-install-<version>.sh --initramfs-only --kver <kernel-version>
```

Contract:

- This mode is **only** for initramfs/Dropbear refresh and validation.
- It requires a plausible existing target system (`/etc/os-release`, `/etc/crypttab`, `/etc/initramfs-tools`, `/lib/modules`, `/boot`).
- It logs `FAST_ITERATION_MODE=1` and explicitly skips the destructive install planes.
- It runs `update-initramfs`, records a small `lsinitramfs`-based manifest, and persists the log/manifest under `/var/log/<host>/install/`.
- It does **not** repartition disks, format filesystems, run `cryptsetup luksFormat`, run `debootstrap`, or perform a fresh install bring-up.
- It does **not** require the FIRST EDIT passwords to be changed away from `change-me`, because it does not consume those install-time secrets in this mode.

Use this mode for iterative remote-unlock diagnostics or after a targeted initramfs-related code update. For normal install/reinstall workflows, continue to use the default destructive installer path.

### 4.6 Managed-artifacts-only refresh (non-destructive installer-owned target artifacts)

`penelope-install` now also exposes a broader but still explicitly bounded maintenance path:

```bash
sudo -E ./penelope-install-<version>.sh --managed-artifacts-only
```

Optional kernel targeting (only relevant if an initramfs-owned artifact changed and a rebuild is required):

```bash
sudo -E ./penelope-install-<version>.sh --managed-artifacts-only --kver <kernel-version>
```

Phase-1 allowlist:

- `/etc/ssh/sshd_config.d/50-penelope-hardening.conf`
- `/usr/local/sbin/penelope-rotate-masterpw-dropbear.sh`
- `/usr/local/sbin/penelope-verify-security.sh`
- `/usr/local/sbin/${TARGET_HOST}-firstboot.sh`
- `/usr/local/sbin/penelope-copy-initramfs-logs.sh`
- `/bin/penelope-cryptroot-unlock-wrapper`
- `/etc/dropbear/initramfs/dropbear.conf`
- `/etc/initramfs-tools/scripts/init-premount/dropbear`

Contract:

- This mode is **not** a generic rerun of the installer against a running system.
- It is limited to a strict allowlist of **installer-owned generated target artifacts**.
- It requires a plausible installed Penelope target context (`/etc/os-release`, `/etc/initramfs-tools`, `/lib/modules`, `/boot`, plus either `/etc/penelope/buildinfo` or `/usr/local/lib/penelope/common.sh`).
- It logs `FAST_ITERATION_MODE=1`, the skipped destructive planes, and a changed/unchanged manifest under `/var/log/<host>/install/`.
- It may rebuild initramfs (with `lsinitramfs` evidence) **only** when one of the allowlisted initramfs-owned artifacts changed.
- It does **not** repartition disks, format filesystems, run `cryptsetup luksFormat`, run `debootstrap`, reinstall the base OS, or silently rotate install-time secrets.
- It does **not** rewrite `/etc/dropbear/initramfs/authorized_keys`; Dropbear/LUKS secret rotation remains the dedicated operator action via the installed rotation tool.

Use this mode when you need to refresh the installer-owned runtime artifacts on an already installed system without entering the destructive provisioning plane. Examples: updated SSH hardening drop-in, refreshed installed Penelope ops tools, or a small non-secret initramfs/Dropbear artifact update that should trigger a clean initramfs rebuild.


### 4.7 Verify-layout-contract preflight (non-destructive install-plan verification)

`penelope-install` exposes a non-destructive preflight mode for the install layout contract:

```bash
sudo -E ./penelope-install-<version>.sh --verify-layout-contract --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
```

Contract:

- This mode is **not** a generic running-system updater and it does **not** perform confirmation or destructive install steps.
- It requires the same explicit external config seam as the real install path: `--bootstrap-config <path>` plus `--layout-config <path>`.
- It does **not** fall back to shipped inline bootstrap placeholders or shipped inline layout defaults.
- It runs the same recreation-policy parsing, profile/layout verification, preserved-target checks, and plan rendering that would happen before a destructive install/reinstall.
- For shipped `four-disk`, this mode can verify and print both full-recreation and selective preserve/recreate plans using the same fixed-layout contract checks that run before a real destructive install.
- It does **not** require `CRED_LOGIN_PW`; when preserved encrypted roles are part of the requested policy, it requires `CRED_MASTER_PW` so the preserved LUKS targets can actually be verified as unlockable.
- It prints the install plan, records a small manifest, and persists the log/manifest bundle under `/var/log/<host>/install/`.
- When fixed-layout preserve verification is in scope, the manifest/log output also carries a one-line contract summary, the preserved verification targets, and an explicit next-step hint (keep the preserved layout unchanged, switch to `RECREATION_TARGET_LIST=all`, or use a separate migration workflow).
- It does **not** repartition disks, format filesystems, run `cryptsetup luksFormat`, run `debootstrap`, or ask for destructive confirmation.

Use this mode when you want to validate that the current disk reality still matches the selected profile/layout/sizing contract **before** running a real reinstall/preserve workflow.

---

## 5) Remote unlock (Dropbear initramfs)

### 5.1 Unlock path overview

**Operational default:** Remote unlock via SSH is the standard path. Local keyboard unlock is a fallback only.
If remote unlock is unavailable, assume **no physical access** and treat it as an incident that must be fixed in the installer/initramfs layer (bounded DHCP, stable Dropbear startup).

During early boot:

- initramfs starts Dropbear SSH on `DROPBEAR_PORT` (default 2222).
- The unlock workstation must be able to reach that TCP port over the intended LAN/VPN path; any host or network firewall on that path must permit it explicitly.
- After SSH login, `cryptroot-unlock` is executed (forced command).
- You enter `CRED_MASTER_PW` once; the system continues booting.

Expected behavior:
- You connect to **Dropbear in initramfs** (not the normal `sshd`).
- Authentication is typically **key-only**.
- After successful unlock, the SSH session is **closed automatically** (no interactive shell in initramfs).

After the system boots fully:
- Dropbear is no longer relevant.
- The normal OpenSSH daemon (`sshd`) handles SSH connections (typically port 22).

#### 5.1.1 Initramfs command availability contract
Initramfs is a constrained environment. **Do not assume tools exist.** Penelope therefore treats the initramfs **command inventory** as the contract for what is safe to use in early-boot scripts.

Where to find it:
- `penelope-initramfs-diag.log` contains a section `## command inventory (initramfs)` with entries like `OK: <cmd>` / `MISSING: <cmd>`.

Rules:
- Implement initramfs scripts using **POSIX `sh`** and the smallest possible tool set.
- Prefer `/proc`-based parsing (e.g., `/proc/net/route`) over optional userland tools.
- If a command is not guaranteed, gate it behind `have <cmd>` / `command -v <cmd>` and provide a fallback.
- Avoid long retry loops that can block remote unlock. If you retry networking, keep it bounded and log backoff decisions.


### 5.2 How to unlock remotely (Linux / macOS)
```bash
chmod 600 ./penelope_unlock
ssh -i ./penelope_unlock -p 2222 root@<PENELOPE-IP>
# Prompt: Please unlock disk <DEVICE> -> enter CRED_MASTER_PW
```
Use the private key from `${TARGET_HOST}_unlock_keys.7z` (where `TARGET_HOST` is the install-time hostname).

### 5.3 Windows 10/11 client notes (PowerShell / OpenSSH_for_Windows)
Windows OpenSSH validates private keys against **NTFS ACLs**, not Unix `chmod` bits. If the key resides on a broad-permission NTFS location (e.g., with *Authenticated Users* access), it is rejected with `UNPROTECTED PRIVATE KEY FILE` / `bad permissions`.

Recommended workflow:
1) Store the private key under `%USERPROFILE%\.ssh` (not on a shared NTFS data partition).
2) Ensure the directory and the key are only accessible by **SYSTEM**, **Administrators**, and **your user**.

Verify directory ACLs:
```powershell
icacls $env:USERPROFILE\.ssh
```
If required, reset directory ACLs (restrictive):
```powershell
icacls $env:USERPROFILE\.ssh /inheritance:r
icacls $env:USERPROFILE\.ssh /grant:r "$env:USERNAME:(OI)(CI)(F)" "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)"
icacls $env:USERPROFILE\.ssh /remove "Authenticated Users" "Users" "Everyone"
```
Copy keys into `.ssh`:
```powershell
mkdir $env:USERPROFILE\.ssh -Force
Copy-Item .\penelope_unlock $env:USERPROFILE\.ssh\penelope_unlock
Copy-Item .\penelope_unlock.pub $env:USERPROFILE\.ssh\penelope_unlock.pub
```
Restrict the private key ACLs:
```powershell
cd $env:USERPROFILE\.ssh
icacls .\penelope_unlock /inheritance:r
icacls .\penelope_unlock /grant:r "$env:USERNAME:(R)" "SYSTEM:(F)" "Administrators:(F)"
icacls .\penelope_unlock /remove "Authenticated Users" "Users" "Everyone"

icacls .\penelope_unlock
```
Unlock:
```powershell
ssh -i $env:USERPROFILE\.ssh\penelope_unlock -p 2222 root@<PENELOPE-IP>
```
Note: `chmod 600` in Git Bash usually does **not** change Windows ACLs; Windows OpenSSH will still consider the key too open.

#### Alternative under Windows: WSL
If WSL is available, you can store the key on the Linux filesystem (ext4) and use classic permissions:
```bash
chmod 600 ~/penelope_unlock
ssh -i ~/penelope_unlock -p 2222 root@<PENELOPE-IP>
```

### 5.4 Local unlock
If you are physically present, you can enter `CRED_MASTER_PW` at the console prompt.

---

## 6) Post-install checks (recommended)

After first successful boot:

### 6.1 Validate mounts
```bash
lsblk -f
mount | egrep "/boot|/home|/_archive|/_backup"
```
### 6.2 Validate user and sudo
```bash
id "$ADMIN_USER"
groups "$ADMIN_USER"
sudo -l
```
### 6.3 Validate Wayland disabled
```bash
grep -n "WaylandEnable" /etc/gdm3/custom.conf
```
### 6.4 Validate initramfs contains dropbear and network
```bash
grep -R "DROPBEAR_OPTIONS" -n /etc/dropbear/initramfs/
grep -R "^IP=" -n /etc/initramfs-tools/
```
### 6.5 Initramfs hostname / DHCP identification
If the host only becomes visible on the network after manual unlock (or still appears as `ubuntu` during early boot), the initramfs usually does not have a clean hostname handoff yet, or the DHCP-related kernel command line is incomplete.

Check:
```bash
grep -E '^GRUB_CMDLINE_LINUX=' /etc/default/grub
lsinitramfs /boot/initrd.img-$(uname -r) | egrep 'etc/hostname|scripts/init-top/00-.*-hostname'
```

Expected state:
- `GRUB_CMDLINE_LINUX` contains an `ip=` argument with a hostname field, for example `ip=:::::penelope::dhcp` (the hostname is field 5).
- The initrd contains `/etc/hostname` and the early init-top hostname script `00-<TARGET_HOST>-hostname`.

After changes to `/etc/default/grub` or initramfs scripts, always run `sudo update-grub` and `sudo update-initramfs -u -k all`.

### 6.6 Validate initramfs logs are persisted
After boot, initramfs diagnostics should be available under:
- `/var/log/${TARGET_HOST}/initramfs/latest.log` (symlink) plus timestamped copies

If logs are missing:
```bash
systemctl status penelope-initramfs-logcopy.service --no-pager
journalctl -u penelope-initramfs-logcopy.service -b --no-pager
```

---

## 7) Backup setup and operation (penelope-backup)

> Note: Internal scheduled backups are installed via Cron (`/etc/cron.d/penelope-backup`), not via a `penelope-backup.timer` / `penelope-backup.service` pair. USB attach-triggered runs use udev + systemd instance services (`penelope-usb-backup@.service`).

### 7.1 Design goals
- Backups are **encrypted at rest** (restic encryption), even though `/_backup` is unencrypted.
- Internal backups run on a schedule (Cron) **without catch-up** (if the server is down, the run is missed).
- External (USB) backups are designed for **offline rotation**: when a disk is attached, a backup runs once; then the disk is removed and stored elsewhere.
- Backup Disk Operators should not need shell access: they act only from a small Backup-Dashboard signal file set (typically later exposed read-only via Samba).

Penelope assumes a **four-partition safety model** created by `penelope-install`: `/`, `/home`, `/_archive`, and `/_backup`. This separation is intentional. It reduces blast radius when one filesystem is damaged, keeps the unencrypted restic repositories on `/_backup` independent from the system partition, and makes selective recovery easier (for example, reinstall/restore `/` without touching `/home`, `/_archive`, or `/_backup`). A running system that does not match this expected layout is treated as **out of policy**: backup runs warn and abort instead of continuing in a degraded mode.

### 7.2 What backup-setup installs
Run once on the installed target host, with the **backup setup bundle** kept together in one directory (`penelope-backup-setup-<version>.sh` plus `penelope-common.sh`):

```bash
# Fresh bring-up: scaffold editable bootstrap files first
sudo -E ./penelope-backup-setup-<version>.sh write-config

# Then edit /etc/penelope/backup-setup/backup-setup.conf and
# /etc/penelope/backup-setup/secrets.d/*.secret, preflight the candidate,
# and only then run the real apply:
sudo -E ./penelope-backup-setup-<version>.sh verify-config
sudo -E ./penelope-backup-setup-<version>.sh apply
```

`penelope-backup-setup` installs and maintains (idempotently):

- `/etc/penelope/backup-setup/backup-setup.conf` (active bootstrap config for fresh create/reset of `backup.conf`)
- `/etc/penelope/backup-setup/secrets.d/*.secret` (active bootstrap initialization secrets for missing/empty local restic password files)
- `/etc/penelope/backup-setup/examples/` (template-only examples; never consumed as active bootstrap state)
- `/etc/penelope/backup.conf` (effective live backup configuration; merge/keep/reset policies apply)
- `/root/.config/restic/` (effective live restic password files; init/keep policies apply)
- `/usr/local/sbin/penelope-backup.sh` (runner; bundle-stamped version)
- `/usr/local/sbin/penelope-backup-verify.sh` (backup verification helper; bundle-stamped version)
- `/usr/local/sbin/penelope-backup-find-snapshot.sh` (read-only recovery helper to find the newest snapshot containing a path; bundle-stamped version)
- `/usr/local/sbin/penelope-usb-disk-setup.sh` (USB disk preparation tool; bundle-stamped version)
- `/usr/local/sbin/penelope-offline-recover.sh` (offline recovery tool for Live-USB/Rescue; bundle-stamped version)
- systemd units + udev integration for USB autorun (allowlist-based)
- cron integration (minimal output) and logrotate for `/var/log/${HOST_SCOPE_NAME}/backup/backup.log`
- canonical Backup-Dashboard directory and files under `${BACKUP_DASHBOARD_DIR}`


#### 7.2.1 Upgrade/Update behavior

> **Terminology (important):** `TARGET_HOST` is the installation-time or recovery-target hostname (used for initramfs log paths, generated host-specific artefacts, and unlock-key naming). `HOST_SCOPE_NAME` is the stable backup scope stored in `backup.conf` and used for backup logs, repository paths, and restic snapshot hostname metadata; it may intentionally differ from `TARGET_HOST` and should remain constant even if the system hostname changes.
>
> **Why this distinction matters:** recovery and migration may restore backups from one historical host onto a differently named new target system. Example: recover **asterix** backups onto a new target host **obelix**. In that case, keep `HOST_SCOPE_NAME=asterix` for the repository/log scope while `TARGET_HOST=obelix` identifies the installed system.


`penelope-backup-setup` is designed to be safely rerun for upgrades. It should always leave a consistent state.

**Backup source-set contract:** Penelope backs up exactly three source scopes. `system` means the root system scope from `/`, but with Penelope data roles, backup repositories, external USB mount roots, and runtime pseudo-filesystems excluded. `home` means `/home`. `_archive` means `/_archive`. Internal vs. external mode changes only the destination repository base (`/_backup/<HOST_SCOPE_NAME>` versus `USB_MOUNT_BASE/<UUID>/<HOST_SCOPE_NAME>`); it must never add a USB disk, backup repository, or other external mount as a source. The generated runner enforces this with explicit system-source excludes, including `/_backup` and `USB_MOUNT_BASE` (default `/_usbbackup`), and with a runtime guard that refuses a target repository located inside the source tree unless a covering absolute exclude protects it.

**Operational model:** treat `penelope-backup-setup` as an idempotent software/update installer for the backup tooling. A normal rerun should update tooling and extend configuration when new keys are introduced, but it must not silently replace established operator configuration or reinitialize existing secrets.

- Default behavior:
  - Updates installed artifacts (runner, backup verify, cron, logrotate, udev rule, systemd units).
  - **Merges** `/etc/penelope/backup.conf`: existing values are kept; missing new keys are appended.
  - Initializes restic password files only if missing/empty (create-once).
- Optional flags (recommended for long-lived systems):
  - `--keep-config`: keep `backup.conf` as-is (no merge). Still fixes permissions and installs artifacts.
  - `--reset-config`: write a fresh template config (backs up the previous file first).
  - `--keep-secrets`: do not create restic password files. If any are missing/empty: hard abort with a clear error.
  - `--init-secrets`: create missing/empty local restic password files from the bootstrap `secrets.d` values (default).
  - `write-config`: scaffold `/etc/penelope/backup-setup` and exit without applying live backup state.
  - `verify-config`: validate the bootstrap tree and print what `apply` would do without touching live backup state. On a mounted non-empty preserved `/_backup`, it now mirrors the same scope guard as `apply`: blind bootstrap or an explicit fresh new scope beside historical repos are rejected already at preflight, while an existing-scope reattach/update remains valid.

**What a normal rerun is for:**
- Upgrade the installed backup tooling to a newer bundle version.
- Add new default config keys that did not exist in an older `backup.conf` yet.
- Reinstall or repair operational artefacts such as runner scripts, cron, logrotate, udev rules, systemd units, and Backup-Dashboard scaffolding.

**What a normal rerun is not for:**
- Replacing the operator's established `backup.conf` values without an explicit reset decision.
- Rotating existing restic repository passwords as part of a routine software update.
- Treating a rerun as a destructive reinitialization of existing repositories or Backup-Dashboard history.

Notes:
- The script must never print secret material (passwords) into logs.
- If you rotate restic passwords, use `restic key passwd` for the repo and then update the corresponding password file. Password rotation is an intentional operator change, not a normal side effect of rerunning `penelope-backup-setup`.
- After the first successful setup (and after every password rotation), copy the effective restic password files to a redundant external location (for example KeePass, a separate secure vault, or a sealed printed recovery record). Treat them like the installer passwords and Dropbear/admin access material: they are hard recovery prerequisites.
- Existing `backup.log` content is preserved on rerun/upgrade; the setup only creates the file if missing and still fixes owner/mode.
- Existing Backup-Dashboard event logs (`events-internal.log`, `events-external.log`) and last-status JSON files are preserved on rerun/upgrade; only missing Backup-Dashboard artifacts are seeded.

#### 7.2.2 External bootstrap config tree for first real apply

`penelope-backup-setup` now uses a small external bootstrap tree instead of editing inline restic password variables inside the script itself:

Active bootstrap state:

- `/etc/penelope/backup-setup/backup-setup.conf`
- `/etc/penelope/backup-setup/secrets.d/system.secret`
- `/etc/penelope/backup-setup/secrets.d/home.secret`
- `/etc/penelope/backup-setup/secrets.d/_archive.secret`

Template-only examples:

- `/etc/penelope/backup-setup/examples/backup-setup.conf.example`
- `/etc/penelope/backup-setup/examples/secrets.d/system.secret.example`
- `/etc/penelope/backup-setup/examples/secrets.d/home.secret.example`
- `/etc/penelope/backup-setup/examples/secrets.d/_archive.secret.example`

Create that tree explicitly first:

```bash
sudo -E ./penelope-backup-setup-<version>.sh write-config
```

Then edit the generated files, run `verify-config`, and only then run the first real apply.

Current contract:

- `backup-setup.conf` carries `config_schema_version=1` and supplies the operator-edited bootstrap values for creating or resetting `/etc/penelope/backup.conf`.
- `secrets.d/*.secret` supply initialization-only values for the matching local password files under `/root/.config/restic/` **only when** those local files are missing or empty.
- A normal rerun does **not** overwrite a non-empty local password file just because the bootstrap secret changed.
- Once `/etc/penelope/backup.conf` and `/root/.config/restic/*` exist, those live files remain the canonical source of truth for routine reruns/upgrades.
- A normal rerun may update tooling even when the bootstrap tree is not needed by that rerun path.

Operator rule:

- Leave the scaffolded placeholder as `change-me` only long enough to finish `write-config`; replace it before the first real apply that should initialize relied-on repositories.
- Do **not** expect a routine rerun of `penelope-backup-setup` to rotate already established repository credentials.
- As soon as the effective values in `/root/.config/restic/{system_pw,home_pw,_archive_pw}` become relied-on credentials for a system, store those **effective** values in KeePass immediately. Without the matching effective password, the corresponding repository cannot be opened for restore.

#### 7.2.3 External USB repo password rotation after a local password change

When the local system password files have already been rotated but one or more allow-listed USB backup disks still carry the **previous** password generation, do **not** overload the normal USB autorun with password migration logic. Use the dedicated tool installed by `penelope-backup-setup` instead:

```bash
sudo /usr/local/sbin/penelope-rotate-external-restic-passwords.sh
```

Operational model:
- The tool targets only the external scoped repos for the current `HOST_SCOPE_NAME`: `<USB-mount>/<HOST_SCOPE_NAME>/{system,home,_archive}`.
- It uses the **current** local password files as the target state.
- It may use the optional previous-password buffer files
  - `/root/.config/restic/system_pw.prev`
  - `/root/.config/restic/home_pw.prev`
  - `/root/.config/restic/_archive_pw.prev`
  to open older external repos and migrate them to the current local password generation.
- Per repo, the fallback order is: **current password first**, then the repo-specific `.prev` file if present, then interactive fallback.
- If the first interactively entered old password works for one repo, the tool may try that same old password for later repo types before prompting again.
- If that reused interactive old password does not fit a later repo, the tool prompts again only for that specific repo type.
- If a repo already accepts the current password, the tool must detect that and leave it unchanged (no-op for that target).
- If the selected allow-listed disk does not contain the expected `HOST_SCOPE_NAME`, the tool reports the scope directories found on that disk so the operator can diagnose a wrong disk or wrong scope assumption.

Why this is separate from normal USB autorun:
- A user may insert an older USB backup disk days or weeks after the local password files were rotated.
- The normal external backup path should remain simple and fail clearly instead of silently attempting credential migration.
- A failed external autorun in this scenario should leave the disk attached and show the normal Backup-Dashboard hold signal; the operator then uses the dedicated rotation tool for that specific disk.

Operator workflow for a late external disk:
1. Leave the USB disk attached if the Backup-Dashboard shows `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` for that disk.
2. Confirm the intended backup scope in `/etc/penelope/backup.conf` (`HOST_SCOPE_NAME`).
3. Run `penelope-rotate-external-restic-passwords.sh` against the currently attached allow-listed disk. If exactly one registered backup disk is attached, the tool can use it directly; if more than one is attached, explicitly select the intended device/UUID.
4. Let the tool try the current password, then `.prev`, then interactive fallback per repo. In the common case, one interactively entered old password can be reused for later repo types; only mismatching repo types require an additional prompt.
5. After successful verification with the current password generation, rerun or retry the normal external backup path if needed.

Dashboard/ops event note:
- The dedicated rotation tool records its own operator-facing Backup-Dashboard events in `events-ops.log` / `last-ops.json`.
- This is separate from normal `events-external.log`; users still decide only from the USB signal files whether the disk may be removed.
- The recorded operator status now includes a compact per-repo outcome summary for `system`, `home`, and `archive` so a partial rotation attempt remains diagnosable from the dashboard/log view.

Outcome semantics:
- The tool still stops on the first hard failure; it does **not** silently continue with later repo types after a failed repo.
- The per-repo outcome summary is there so the operator can see which repo types were already current, which were rotated successfully, which were skipped as uninitialized, and where the failure occurred before deciding on the next action.

Practical note: keeping the previous password generation in KeePass or another secure external vault is strongly recommended while not all registered USB disks have been migrated yet.

### 7.3 Log locations (host-scoped)
Detailed logs (rotated together under the same host-scoped policy):

- `/var/log/${HOST_SCOPE_NAME}/backup/backup.log`
- `/var/log/${HOST_SCOPE_NAME}/backup/verify.log`

Rotation policy:
- daily
- keep 14 rotations
- compress older logs with the normal logrotate gzip flow (`compress` + `delaycompress`)
- ownership/permissions stay `root:adm` / `0640`

Where `${HOST_SCOPE_NAME}` is the stable backup scope stored in `/etc/penelope/backup.conf` (initialized once from `hostname -s`; do not rely on shell `$HOST`).

Cron output is intentionally concise, but not restricted to bare STARTED/SUCCESS/FAILED only. Normal runs emit one-line STARTED and SUCCESS/FAILED summaries; when a run completes with dashboard-publication or cleanup residue, the final one-line summary may carry a short suffix such as `(dashboard publish incomplete; inspect backup.log)` or `(cleanup incomplete; inspect backup.log)`.

**Operator rule of thumb for internal runs:**
- Internal backups are triggered by Cron at the configured time; there is **no catch-up** if the host was powered off or unavailable at that time.
- A missing run after downtime is therefore not automatically a runner fault; first compare the expected schedule with the timestamp in `last-internal.json`.
- For Backup-Dashboard viewers without system access, `INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt` is the simpler signal: if it exists, the viewer should contact the operator.
- If you want an explicit fresh proof run now, use:
  - `sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal`
- Use `last-verify.json` for the current verify result, `last-internal.json` for the latest backup runtime result, `verify.log` for verify details, and `backup.log` for the underlying backup-run details.

### 7.4 Backup-Dashboard Files (for Samba/Windows Clients)
The runner writes a canonical **Backup-Dashboard** directory on the system partition (default, configurable in `backup.conf`):

- `/var/lib/penelope/backup-dashboard`

This single canonical directory is the canonical Backup-Dashboard source used by the backup tooling. If you later export it via Samba, the `backup_dashboard` share must point at this canonical path directly; there is no separate mirror/publish path.

**Roles:**
- **Backup Disk Operator** = Person without SSH/admin access who sees only the Backup-Dashboard and may insert or remove already registered USB backup disks.
- **Operator** = Person with SSH/admin access who prepares/registers USB backup disks, maintains the allow-list, and handles HOLD/troubleshooting cases.
- **Windows/Samba Backup-Dashboard viewer** = A read-only access path to the same Backup-Dashboard content, not a separate admin role. This viewer may be the Backup Disk Operator or another non-technical viewer, but the decision contract stays the same: decide only from the Backup-Dashboard signal files and contact the Operator when a `*_CONTACT_OPERATOR.txt` file is present.

Files:

- `events-internal.log`
  Append-only event log for internal runs (seeded at setup time, then preserved across upgrades).
- `events-external.log`
  Append-only event log for external USB runs (seeded at setup time, then preserved across upgrades).
- `events-ops.log`
  Append-only operator-event log for backup-related maintenance actions such as USB disk registration and external password rotation.
- `last-internal.json`
  Last internal run summary (success/failure, timestamp, cycle/kind, log path). Preserved across reruns/upgrades.
- `last-external-<DISK_NAME>.json`
  Last external run summary for that named disk (same, plus processed UUIDs and the resolved `disk_name`). Preserved across reruns/upgrades.
- `last-ops.json`
  Last backup-related operator event summary (for example USB disk registration or external password rotation).
- `INTERNAL_BACKUP_RUNNING.txt`
  Written while an internal backup run is currently executing.
- `INTERNAL_BACKUP_OK.txt`
  Written when the last internal backup completed successfully and is still considered fresh.
- `INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt`
  Written when the last internal backup failed or did not finish cleanly.
- `INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt`
  Written when no fresh successful internal backup has been seen within the configured threshold (`INTERNAL_BACKUP_STALE_AFTER_HOURS`, default 48).
- `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt`
  Written as soon as a specific allow-listed USB backup drive is detected and that external backup run starts. While this file exists for that disk, that USB backup drive must stay attached. The file body also includes `disk_name=<DISK_NAME>`.
- `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt`
  Written **only** after a successful external (USB) backup and confirmed unmount for that specific disk. This is the user/operator signal that the named USB backup drive can be removed. This file is removed automatically again when that disk is physically detached.
- `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt`
  Written when an external backup attempt for that disk was interrupted or left unresolved while the disk is no longer attached. The Backup Disk Operator should reattach that same allow-listed disk and wait for the next retry; immediate operator escalation is not the default outcome for a merely interrupted detached-disk case.
- `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt`
  Written only when the external backup for that disk requires operator attention. If that disk is still present, leave it attached and contact the operator. This is not the default detached-disk aftermath for a merely interrupted run.

These files are designed to be exposed read-only via Samba later (no symlink tricks required).

**Backup Disk Operator view (dashboard-only):**
- `USB_BACKUP_*_<DISK_NAME>.txt` = per-disk external USB user signals; the filename is the canonical signal and the file body is supplemental human-readable context.
- `INTERNAL_BACKUP_*.txt` = internal status text files; for non-technical viewers these text files are the primary indication of backup freshness or failure.
- There are no mail alerts. If a `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` file exists, reattach that same disk and wait for the next retry (normally on reinsert when USB autorun is enabled, which is the current default). If a `*_CONTACT_OPERATOR.txt` file exists, leave that disk attached if applicable and contact the Operator.
- Do **not** rely on JSON files, event logs, `backup.log`, `/etc/penelope/*`, or shell commands in the Backup Disk Operator workflow.

**Operator view (system/admin):**
- `last-internal.json` / `last-external-<DISK_NAME>.json` = quick structured state for the most recent internal run and the most recent external run for that disk; external status is per disk, not global.
- `last-ops.json` = quick current state for the most recent backup-related operator action (for example disk registration or password rotation).
- `events-internal.log` / `events-external.log` = short operational history for internal/external runs.
- `events-ops.log` = short operational history for backup-related operator actions.
- `backup.log` = detailed technical diagnosis when a run failed or behaved unexpectedly; external-run lines carry a short run context so concurrent or back-to-back USB runs remain distinguishable.
- Internal dashboard signal priority is `RUNNING > ERROR_CONTACT_OPERATOR > STALE_CONTACT_OPERATOR > OK`.
- `penelope-refresh-backup-dashboard.sh` plus its hourly systemd timer keep the internal dashboard freshness state updated even when no external USB workflow is currently running.

#### 7.4.1 Samba/Windows access to the share `backup_dashboard` (standard on a normal Penelope server)

**When to run `penelope-samba-setup`:** Run it only on the installed system. Treat it as the standard next step after `penelope-backup-setup`, because the host is expected to provide managed shares and usually the readonly Backup-Dashboard export for Windows/SMB clients. If you need the dedicated readonly Backup-Dashboard export (`backup_dashboard`), run `penelope-backup-setup` first so that `backup.conf` and the canonical Backup-Dashboard path already exist. This is a hard prerequisite for `ENABLE_BACKUP_DASHBOARD_SHARE=1`, not merely a preferred order hint. If you only need managed Samba users/shares and do **not** enable the Backup-Dashboard export, `penelope-samba-setup` can also be run without prior backup setup as a conscious exception path for that feature dependency, not as the standard bring-up order.
After `penelope-samba-setup`, the late verifier on Samba-enabled hosts should confirm that `/etc/samba/smb.conf` exists, the active Penelope include wiring is present, `testparm -s` succeeds, and `smbd` is enabled + active.
If you enable the Backup-Dashboard export, the canonical backup-dashboard directory `/var/lib/penelope/backup-dashboard` is exported directly as the dedicated Samba share `backup_dashboard` for Windows/SMB clients.

Recommended Samba shape:

- path: `/var/lib/penelope/backup-dashboard`
- Samba user: `backup_dashboard`
- share mode: `ro`
- share name: `backup_dashboard`

This keeps the Backup-Dashboard contract simple: one canonical path, no extra mirror, and a readonly SMB export for Windows clients that does not reuse the rw `internal` share credentials. The dedicated `backup_dashboard` account is only a technical SMB principal for that export; no separate dashboard home directory is part of the model.

**Operational model:** treat `penelope-samba-setup` as the declarative managed-state tool for Penelope Samba users and shares. The live operator source of truth is now an external config directory (default: `/etc/penelope/samba-setup`), while the script-managed Samba include remains generated output that should not be hand-edited in the normal workflow.

**Current project phase note:** Penelope is still pre-release. Favor a clean forward design and do not keep compatibility code for superseded pre-release Samba setup schemas. When a local test host still has an older schema, move that setup tree aside deliberately and scaffold the current schema.

**Config directory layout (current model):**

```text
/etc/penelope/samba-setup/
  samba-setup.conf
  users.d/
    penelope_client.conf
    scan.conf
    p001.conf
    p002.conf
  shares.d/
    archive_p001.conf
    archive_p002.conf
  secrets.d/
    backup_dashboard.secret
    penelope_client.secret
    scan.secret
    p001.secret
    p002.secret
  examples/
    samba-setup.conf.example
    users.d/
      client-user.conf.example
      archive-user.conf.example
      service-user.conf.example
      home-user.conf.example
    shares.d/
      extra-share.conf.example
    secrets.d/
      backup_dashboard.secret.example
      penelope_client.secret.example
      scan.secret.example
      archive-user.secret.example
      home-user.secret.example
```

- active setup config: `/etc/penelope/samba-setup/samba-setup.conf`
  - includes `config_schema_version=4` in the current release
- active managed user principals: `/etc/penelope/samba-setup/users.d/*.conf`
- active extra share declarations: `/etc/penelope/samba-setup/shares.d/*.conf`
- active secrets: `/etc/penelope/samba-setup/secrets.d/*.secret`
- templates only (never loaded as live state): `/etc/penelope/samba-setup/examples/**`

Each active user file in `users.d/*.conf` is one canonical managed Samba user principal and defines:
- `user=<linux+samba user>`
- `purpose=client|service|admin plus default_access/private_home/private_archive/extra_groups`

Each active share file in `shares.d/*.conf` defines:
- `kind=extra for additional explicit shares; private home/archive shares are generated from users.d`
- `path=<absolute export path>`
- `share=<visible SMB share name>`
- `user=<already managed user>`
- `mode=ro|rw`

Private home/archive shares are configured directly in `users.d/*.conf`; `shares.d/*.conf` is reserved for optional extra shares.

The fixed built-in share name `internal` and the fixed dedicated Backup-Dashboard export user `backup_dashboard` remain hard-coded in this release. `internal` is a resource name for the shared `/home/internal` workspace and has no Samba password or secret file in the fresh model. The active password for the dedicated readonly dashboard identity lives in `secrets.d/backup_dashboard.secret` when that export is enabled. Template secret placeholders live only under `examples/secrets.d/*.secret.example` and are never loaded as live state.

Default identity/resource overview:

| Name | Unix account? | Samba user? | Built-in SMB share/resource? | `/etc/passwd` home | Primary role |
| --- | --- | --- | --- | --- | --- |
| `penelope_client` | yes | yes | no built-in private share | `/nonexistent` | standard Windows/Linux workstation identity |
| `p001`, `p002` | yes | yes | yes, `archive_p001` / `archive_p002` under `/_archive` | `/nonexistent` | archive identities; shipped examples use `default_access=yes` for combined workstation/archive use |
| `rawin` | no | no | yes, `rawin` at `/home/rawin` | none | shared raw-inbox resource |
| `scan` | yes | yes | yes, `scan` at `/home/scan` | `/nonexistent` | scanner/printer service identity and inbox |
| `internal` | no | no | yes, `internal` at `/home/internal` | none | shared team workspace resource |
| `backup_dashboard` | yes | yes | yes, readonly `backup_dashboard` at the canonical dashboard path | `/nonexistent` | readonly dashboard export identity |

`/home/scan` and `/home/internal` are shared work directories, not Unix login homes. On a fresh install, `getent passwd scan backup_dashboard` should show `/nonexistent` and `/usr/sbin/nologin` for those local accounts when those principals are enabled. `rawin` and `internal` should not be required as Samba login accounts in the fresh model because they are built-in SMB resource names.

**Initialization command (mandatory on a fresh Samba bring-up):**
- `sudo -E ./penelope-samba-setup-<version>.sh write-config`
- optional alternate workdir/recovery location: `sudo -E ./penelope-samba-setup-<version>.sh --config-dir <DIR> write-config`

`write-config` creates missing active files on a fresh bring-up, appends newly introduced known keys with defaults to an existing `samba-setup.conf`, writes missing placeholder secret files with `change-me`, and overwrites package-owned example scaffolds under `/etc/penelope/samba-setup/examples/`, then exits without provisioning Samba state. A later `apply` also refreshes those package-owned examples but still does not overwrite active operator config or non-empty secrets. Edit the generated files first, run `verify-config`, and only then run `apply`.

**Upgrade / restore rule:** if `/etc/penelope/samba-setup` already exists (for example because you restored it from a system backup), treat that tree as the canonical source of truth. On update reruns, run `write-config` to refresh examples and add any newly introduced known non-secret keys to `samba-setup.conf`; it must not overwrite active operator values or non-empty secrets. Inspect first, restore or fill any missing effective secrets from KeePass, then run `verify-config` and `apply`.

Active secret files must match active or disabled managed user declarations. If `verify-config` reports an unreferenced file such as `/etc/penelope/samba-setup/secrets.d/internal.secret`, inspect it and remove or move it deliberately before rerunning verification. The setup tool does not delete secret-bearing files automatically.

**Share-name ownership guardrails (current release):** operator-declared shares must not reuse the fixed Penelope names `rawin`, `scan`, `internal`, or `backup_dashboard`. `verify-config` and `apply` now also fail if a declared Penelope share collides with an already active non-Penelope Samba share in the live Samba configuration.

**Read-only inspection commands:**
- `./penelope-samba-setup-<version>.sh list-users`
- `./penelope-samba-setup-<version>.sh list-shares`
- `./penelope-samba-setup-<version>.sh show-user <USER>`
- `./penelope-samba-setup-<version>.sh show-share <SHARE>`

These commands validate and print the declared managed model without provisioning accounts, rewriting `smb.conf`, or rotating passwords. They read the external config tree and tolerate missing/unreadable secrets by treating them as `change-me` placeholders, so you can inspect a restored config directory without first retyping every password. `list-users` and `list-shares` now include a `state` column (`active` or `disabled`) so the normal inspection surface already shows what can be reactivated; `show-user` and `show-share` report the same state for targeted inspection.
The Samba config tree has an explicit schema marker in `samba-setup.conf` (`config_schema_version`). The current release writes and accepts schema `4` only. Older pre-release schema values fail loudly instead of triggering compatibility migration code.

**Write-side Day-2 commands:**
- `sudo -E ./penelope-samba-setup-<version>.sh add-user <USER> [--purpose client|service|admin] [--default-access yes|no] [--private-home yes|no] [--private-archive yes|no] [--path <ARCHIVE_PATH>] [--share <ARCHIVE_SHARE>] (--password-file <FILE> | --password-stdin)`
- `sudo -E ./penelope-samba-setup-<version>.sh disable-user <USER>`
- `sudo -E ./penelope-samba-setup-<version>.sh remove-user <USER>` (legacy alias of `disable-user`)
- `sudo -E ./penelope-samba-setup-<version>.sh enable-user <USER>`
- `sudo -E ./penelope-samba-setup-<version>.sh add-share <SHARE> --user <USER> --path <PATH> [--mode ro|rw]`
- `sudo -E ./penelope-samba-setup-<version>.sh disable-share <SHARE>`
- `sudo -E ./penelope-samba-setup-<version>.sh remove-share <SHARE>` (legacy alias of `disable-share`)
- `sudo -E ./penelope-samba-setup-<version>.sh enable-share <SHARE>`
- `sudo -E ./penelope-samba-setup-<version>.sh set-password <USER> (--password-file <FILE> | --password-stdin)`

**Current command semantics:**
- `add-user` creates one new `users.d/<user>.conf` plus exactly one new `secrets.d/<user>.secret`, then runs `apply`; private storage is controlled by `private_home` and `private_archive`.
- `add-share` creates one new `shares.d/<share>.conf` with `kind=extra`, then runs `apply`.
- `set-password` overwrites exactly one `secrets.d/<user>.secret`, then runs `apply` so Samba picks up the new password.
- `disable-share` is the canonical non-destructive deactivation operation: the active live extra-share file is renamed to `.disabled`, preserved for later inspection/reactivation, and then `apply` runs again. `remove-share` is a legacy alias of `disable-share`.
- `disable-user` is also non-destructive with respect to the operating system and user data: it deactivates the live user file and any live extra-share files owned by that user by renaming them to `.disabled`, then runs `apply`. It does not delete `/home/<user>`, `/_archive/<user>`, or other data directories. `remove-user` is a legacy alias of `disable-user`.
- `enable-user` is the symmetric reactivation path for a previously removed user: it renames `users.d/<user>.conf.disabled` back to live, also reactivates that user's disabled extra-share files, and then runs `apply`.
- `enable-share` renames one disabled extra-share file back to live and then runs `apply`.

**Apply command:**
- `sudo -E ./penelope-samba-setup-<version>.sh apply`

**What apply is for:**
- upgrade the installed Samba setup bundle to a newer version
- apply the current state from `/etc/penelope/samba-setup` (or `--config-dir <DIR>`)
- provision the declared users, shares, permissions, groups, and password state after a config/secret change
- regenerate the managed include if Samba package updates or local drift require it

**Upgrade / restore rule:** if the config directory already exists (for example because you restored `/etc/penelope/samba-setup` from a system backup), a normal rerun must **reuse it as the canonical source of truth**. `write-config` may append newly introduced known keys with defaults and refresh package-owned files under `examples/`; `apply` may refresh package-owned files under `examples/`; neither command may silently replace established operator config values or overwrite non-empty secret files. Structural changes still belong in the explicit config-schema seam keyed by `config_schema_version`, but the current pre-release line intentionally carries no compatibility code for older layouts.

Whenever you replace shipped defaults or later change effective Samba client passwords in `secrets.d/*.secret`, record the effective values in KeePass immediately.

**Important safety boundary:** the current write-side Day-2 commands are intentionally non-destructive at the OS/data level. They change the declared Samba model by creating/updating/renaming files inside `/etc/penelope/samba-setup`, then rerun `apply`. They do **not** automatically delete Linux users, Samba accounts, home/data directories, archive directories, or the data stored there. A deactivated share or user can therefore leave orphaned local accounts, orphaned `smbpasswd` entries, and directories still consuming space until you clean them up explicitly. Treat destructive cleanup as a separate conscious operator task, not as an implicit rerun side effect.

Current release default shape after `write-config`:
- active managed principal files for:
  - `penelope_client` as the standard Windows/Linux workstation identity without private home/archive
  - `scan` as the scanner/printer service identity for devices that write into the scan inbox
  - `p001` with `default_access=yes` and `private_archive=yes` (`archive_p001`); set `default_access=no` for archive-only separation
  - `p002` with `default_access=yes` and `private_archive=yes` (`archive_p002`); set `default_access=no` for archive-only separation
- built-in fixed technical identity outside `users.d`: `backup_dashboard` when the readonly Backup-Dashboard export is enabled
- built-in fixed resource name outside `users.d`: `internal` at `/home/internal`, without a Samba login or secret
- built-in shared rw resources for users with `default_access=yes`: `rawin`, `scan`, `internal`
- built-in shared ro resource for users with `default_access=yes`: `backup_dashboard`; the dedicated `backup_dashboard` identity also has ro access
- package-owned examples under `examples/`, including `examples/secrets.d/*.secret.example`, are refreshed by `write-config`/`apply` and are not live state
- placeholder secrets in the generated active `secrets.d/*.secret` files use the canonical value `change-me`; do **not** keep that placeholder on a relied-on system

**p-user `default_access` decision:** keep `default_access=yes` for Windows-oriented archive workstations that should use one SMB credential for the standard shares and the private archive share. Set `default_access=no` when the p-user should be archive-only, for example on Linux/Unix clients or carefully managed macOS clients that can keep separate SMB credentials. Windows commonly resists simultaneous different credentials to the same server name, so the combined setting remains the shipped example default.

**Worked example: one active user with both private home and private archive**
```ini
# /etc/penelope/samba-setup/users.d/apollo.conf
user=apollo
purpose=client
default_access=yes
private_home=yes
home_path=/home/apollo
home_share=home_apollo
private_archive=yes
archive_path=/_archive/apollo
archive_share=archive_apollo
extra_groups=
```

**Worked example: one active extra-share file for a team scan inbox**
```ini
# /etc/penelope/samba-setup/shares.d/scan_team_a.conf
kind=extra
path=/srv/penelope/scan-team-a
share=scan_team_a
user=scan
mode=rw
allowed_users=
allowed_groups=team_a
force_group=team_a
```

**RW extra-share mode contract:** `rw_extra_share_create_mode` is the single operator-facing policy knob for rw extra-share creation. `penelope-samba-setup` creates rw extra-share directories on disk with that directory mode, and the generated Samba include derives `directory mask` directly from the same value while deriving `create mask` as `rw_extra_share_create_mode & 0666`. Keep this value aligned with the effective rw-share policy you want clients to experience; do not treat the Samba masks as an unrelated second policy surface.

Credential note: whenever you set or change `backup_dashboard.secret` or any per-user secret in `secrets.d/*.secret`, update the effective Samba passwords in KeePass immediately. These credentials are operationally important for Windows/SMB clients even though they are not bare-metal restore secrets in the same sense as the restic password files.

**Responsibility split (important):**
- `penelope-backup-setup` owns the Backup-Dashboard content contract:
  - canonical dashboard: `/var/lib/penelope/backup-dashboard`
  - Backup-Dashboard artefacts, status JSON files, event logs, and USB safety signal files are written directly there
  - `penelope-backup-setup` does **not** own Samba user provisioning or SMB share semantics
- `penelope-samba-setup` owns the SMB/export contract:
  - declared local non-login user provisioning and the dedicated readonly `backup_dashboard` user when that export is enabled
  - Samba account creation/password updates for declared principals
  - Samba share definitions and `ro|rw` export semantics for Windows/SMB clients
- Operational consequence:
  - if the canonical Backup-Dashboard path or Backup-Dashboard artefacts are missing/drifted, rerun `penelope-backup-setup`
  - if the dedicated `backup_dashboard` user, declared Samba credentials, shared-resource permissions, or SMB share/export semantics are missing/drifted, rerun `penelope-samba-setup`

**Windows Explorer discovery:** `penelope-samba-setup apply` installs and enables `wsdd2.service` so Windows 10/11 clients can discover the Penelope Samba host in Explorer's Network view. Direct access via `\\penelope` or `\\<IP>` remains the primary operational test; WS-Discovery only controls whether the host is advertised in the Explorer network browser. Do not enable SMB1 for discovery.

**Windows 10/11 Backup-Dashboard viewer workflow:**
1. In File Explorer or the Run dialog, open `\\<server>\<share>` (example: `\\penelope\backup_dashboard`).
2. When Windows asks for credentials, enter the configured Samba user and password. For the readonly Backup-Dashboard export, use the dedicated `backup_dashboard` Samba account. If Windows insists on a qualified username, try `<server>\\backup_dashboard`.
3. Find the per-disk dashboard signal files for the intended disk. The filename is the canonical removal/hold decision signal; the file body is only supplemental human-readable context.
4. If `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` exists for that disk, do **not** remove it yet.
5. Remove that disk only when `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` exists for that same disk.
6. If `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` exists for that disk, reattach that same disk and wait for the next retry (normally on reinsert when USB autorun is enabled, which is the current default).
7. If `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` exists, leave that disk attached if it is still present and contact the Operator.
8. If neither READY, REATTACH_AND_WAIT, nor CONTACT_OPERATOR is present for that disk after an attempted run, do **not** treat the disk as safe to remove yet; contact the Operator.

Operator/admin note: `last-external-<DISK_NAME>.json`, `events-external.log`, and `backup.log` remain useful diagnostics for the SSH/admin Operator, but they are not the primary Backup-Dashboard viewer workflow.

Do **not** recommend or reuse the rw `internal` credentials just to make Backup-Dashboard access work. The dedicated `backup_dashboard` account exists specifically so readonly Backup-Dashboard viewers do not also receive access to the rw shared work resources.

**If Windows keeps using the wrong credentials:**
- Disconnect the share in File Explorer.
- Remove the stored entry in **Credential Manager** (`Control Panel -> Credential Manager -> Windows Credentials`).
- Connect again and enter the correct Samba username/password.

### 7.5 Semantic daily cadence and retention by cycles
Restic backups are technically always incremental/deduplicated. Penelope implements a semantic cadence using tags:

- The default internal schedule remains daily, now at 18:00.
- The default full-marker weekdays are Monday and Thursday:
  - `FULL_BACKUP_WEEKDAYS_INTERNAL="mon,thu"`
  - `FULL_BACKUP_WEEKDAYS_EXTERNAL="mon,thu"`
- A cycle is identified by the most recent configured full-marker weekday, encoded as `penelope_cycle=<YYYYMMDD>`.
- Per scope/repository, the first successful snapshot in the current configured cycle is tagged `penelope_kind=full`.
- Later snapshots in the same configured cycle are tagged `penelope_kind=incr`.
- `--force-full` can deliberately tag a run as `penelope_kind=full` in the current configured cycle. It does not change `FULL_BACKUP_WEEKDAYS_*`, retention policy, or future cycle calculation.

Retention is applied in **whole cycles**:

- `KEEP_CYCLES_INTERNAL=2` keeps the last 2 internal cycles.
- `KEEP_CYCLES_EXTERNAL=2` keeps the last 2 external cycles.
- Extra manual/debug snapshots inside an active cycle are allowed; they are not trimmed down to one snapshot per nominal cycle day and age out only when that whole cycle ages out.

Older cycles are removed together. Penelope does not try to enforce an exact fixed snapshot count inside a still-retained cycle.

### 7.6 USB external backup workflow (Backup Disk Operator + Operator)
1. **Backup Disk Operator** plugs in a known registered USB backup disk (exFAT recommended for interoperability).
2. udev triggers `penelope-usb-backup@<UUID>.service`.
3. The runner:
   - mounts the disk under `USB_MOUNT_BASE="/_usbbackup/<UUID>"`,
   - acquires an **on-disk lock** on the USB root (`/.penelope-backup-lock.json`) and maintains a heartbeat,
     - the lock is per disk/UUID and prevents a conflicting second run against the same USB backup disk;
     - different allow-listed USB disks may run in parallel when each run keeps its own lock and its own per-disk dashboard signal files, while internal backups remain serialized against active external runs,
     - `--force` overrides an active lock explicitly,
   - for an already existing external repo after crash/reboot/interrupted-run scenarios, the runner may attempt **controlled stale-lock recovery** before writing new backup data,
     - automatic unlock is attempted only when the repo is readable via `restic snapshots --json --no-lock`,
     - no live `restic` process may still be using that same repo,
     - after `restic unlock`, the runner must pass `restic check --no-lock` before normal backup writes continue,
     - this path is **not** a general repo-repair workflow; if any gate fails, the run stops and the disk remains in operator-hold state,
   - runs the external backup once (targets default to `all`; see `--targets`),
   - applies retention,
   - writes status files in the canonical Backup-Dashboard,
   - on a successful external run, may write an **on-disk success marker** on the USB root (only when `WRITE_USB_SUCCESS_MARKER=1`):
     - `PENELOPE_BACKUP_OK_YYYYMMDD-HHMMSS.txt`
   - unmounts.

   **Backup Disk Operator signals in the Backup-Dashboard:** When an allow-listed backup disk is detected, the dashboard must first show `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` for that disk. At the end of the run, the final user-facing state for that same disk must be one of four outcomes: `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` on success with confirmed unmount, `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` when a merely interrupted run left the disk absent and the next dashboard-only action is to reattach that same disk, `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` when operator attention is actually required, or the still-live `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` while that same run is actively in progress. The filename is the canonical per-disk user signal; the file body repeats `disk_name=<DISK_NAME>` as human-readable context.

   **Detach cleanup / absence reconciliation:** `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` is removed automatically again when that disk is physically detached. If the disk is absent after an incomplete run, dashboard refresh may replace a stale per-disk `RUNNING` file with `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` for that same disk. If `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` already exists for that disk, that hold state keeps precedence; refresh may clear a stale `RUNNING` file, but it must not downgrade HOLD to REATTACH_AND_WAIT.

   **Unmount policy:** By default `FORCE_UNMOUNT_EXTERNAL=1` is enforced. The runner will take over (unmount/remount) allowlisted disks and only write `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` when the disk is confirmed to be fully unmounted. If a desktop automounter immediately remounts the same registered device under `/media/...` after Penelope releases `/_usbbackup/<UUID>`, the runner attempts to unmount that remount during a short final release-settle window before publishing READY. If the run fails, the drive remains busy, or any mount remains active after the settle window, `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` must be shown instead.

4. **Backup Disk Operator** checks only the Backup-Dashboard:
   - if `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` exists for the intended disk and no stronger per-disk signal exists for that same disk, the disk may be removed and stored securely.
   - if `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` exists for that disk, reattach that same disk and wait for the next retry (normally on reinsert when USB autorun is enabled, which is the current default).
   - if `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` exists for that disk, leave that disk attached if it is still present and contact the Operator.
   - the per-disk filename is the canonical decision signal; `disk_name=<DISK_NAME>` inside the file is only supporting context.
5. **Operator** (only if needed) checks operator artefacts only:
   - `/var/lib/penelope/backup-dashboard/last-external-<DISK_NAME>.json` for the latest structured external result for that disk
   - `events-external.log` if a short history is needed
   - `backup.log` if the run failed or diagnostics are needed
   - `/etc/penelope/usb-backup-disks.conf` and `lsblk` only in operator/admin workflows, not in Backup Disk Operator instructions
   - if the run was interrupted or ended in a hold state, use the operator decision table in **10.5.3** before retrying or telling the user to remove the disk

> **Windows/Samba note:** If you expose `/var/lib/penelope/backup-dashboard` via `penelope-samba-setup`, keep the share `backup_dashboard` read-only and use the dedicated Samba credentials configured there.

#### USB allow-list (required)
Only disks with filesystem UUIDs listed in:

- `/etc/penelope/usb-backup-disks.conf`

will run. Unknown UUIDs are ignored silently.

### 7.7 Configuration reference (backup.conf)
#### 7.7.1 System backup scope and filesystem boundaries (`/boot`, `/boot/efi`)

The `system` backup target is taken from the root filesystem (`/`) and is intended to capture the complete operating system state, including `/etc`, `/usr`, and `/var` (e.g., application state such as Docker/DB installs and their data under `/var/lib/<APP>/`).

Important nuance: `system` is captured from `/`. If `/boot` and `/boot/efi` are mounted at backup time (typical), their **file contents** are included as well. This is usually desired, but it has one operational implication:

- During a full `system` restore, you must ensure the restore environment mounts the target partitions consistently, i.e. `/boot` and `/boot/efi` must be mounted into the sysroot *before* restoring, otherwise restored boot files may end up on the root filesystem and later appear “duplicated” or inconsistent.

**Recommended operator approach:**
- **Flow A (recommended for most incidents):** reinstall the system with `penelope-install` (which refreshes boot/EFI/initramfs), then restore data and configuration selectively.
- **Flow B (advanced):** offline full restore (`system,home,_archive`) in a Live-USB environment, with explicit mount guards and a post-restore boot refresh.

**TODO (future hardening, not implemented yet):** consider switching the `system` backup to `--one-file-system` and/or excluding `/boot` explicitly, with a dedicated strategy for boot/EFI. This would reduce “mount layout sensitivity” during restore, but also increases complexity and is therefore deferred.

Primary settings (defaults shown):

- Schedule (internal):
  - `CRON_HOUR="18"`, `CRON_MINUTE="0"`
- Enable/disable sources:
  - Runner (>=0.3.36) supports explicit targets:
    - `--targets system,home,_archive` (comma-separated) or `--targets all` (default).
    - Legacy calls without `--targets` behave as `all`.
  - `/_archive` is a regular, expected backup source in the Penelope model; there is no separate enable/disable switch.
  - Required mount layout for backup execution: `/_backup`, `/_archive`, and `/home` must all be mounted as expected. If the system does not match this layout, the runner warns and aborts instead of continuing in a degraded mode.
- Cadence / retention:
  - `FULL_BACKUP_WEEKDAYS_INTERNAL="mon,thu"`, `FULL_BACKUP_WEEKDAYS_EXTERNAL="mon,thu"` (default full-marker weekdays)
  - `--force-full` marks the current run as full in the current configured cycle and does not change future cycle calculation
  - `KEEP_CYCLES_INTERNAL="2"`, `KEEP_CYCLES_EXTERNAL="2"` (retention in whole cycles)
- Operator dashboard:
  - `BACKUP_DASHBOARD_DIR="/var/lib/penelope/backup-dashboard"`
- Running-system operator rule after live config edits:
  - If you change live backup settings in `/etc/penelope/backup.conf` that affect installed runtime behavior or rendered artifacts, rerun:
    - `sudo -E ./penelope-backup-setup-<version>.sh verify-config`
    - `sudo -E ./penelope-backup-setup-<version>.sh apply`
  - Typical examples:
    - `CRON_HOUR`, `CRON_MINUTE` → rewrites `/etc/cron.d/penelope-backup`
    - `BACKUP_DASHBOARD_DIR` → updates the runner/helper/dashboard path contract
  - Example: move the daily internal backup from the default 18:00 to 20:00 by setting `CRON_HOUR="20"` and `CRON_MINUTE="0"` in `/etc/penelope/backup.conf`, then rerun `verify-config` and `apply`.
  - `FULL_BACKUP_WEEKDAYS_INTERNAL`, `FULL_BACKUP_WEEKDAYS_EXTERNAL` → change configured full-marker weekdays; values are comma-separated `mon,tue,wed,thu,fri,sat,sun`.
- Identity / host scoping:
  - `HOST_SCOPE_NAME="<stable>"` (initialized by backup-setup; used for host-scoped backup logs, repository namespace, and restic snapshot hostname even after rename/new-hardware recovery)
- External USB safety:
  - `USB_LOCK_HEARTBEAT_INTERVAL_SECONDS="180"` (runner heartbeat cadence for the per-disk on-disk USB lock)
  - `USB_LOCK_TTL_SECONDS="600"` (on-disk lock TTL; heartbeat extends `expires_at`; keep this greater than the heartbeat interval so stale-lock detection converges after crash/reboot)
  - `FORCE_UNMOUNT_EXTERNAL="1"` (enforced: runner takes over mounts for allowlisted disks and unmounts on completion; set to `0` to keep marker-policy)
- USB behavior:
  - `ENABLE_USB_AUTORUN="1"`
    - This is the current default. For a normal allow-listed detached-disk case, the next external retry should usually be expected on reinsert of that same disk.
  - `WRITE_USB_SUCCESS_MARKER="1"`
  - `USB_MOUNT_BASE="/_usbbackup"`
  - `USB_FS_UMASK="077"` (used for exFAT/NTFS mounts)

### 7.8 USB backup disk preparation and registration (recommended: guided tool)

On Ubuntu (especially Desktop), freshly inserted USB disks are frequently **auto-mounted**. The recommended procedure is therefore tool-driven and safe-by-default.

#### 7.8.1 Guided default mode (`penelope-usb-disk-setup.sh`)

Run on the installed system as root (typically via sudo):

```bash
sudo /usr/local/sbin/penelope-usb-disk-setup.sh
```

The bare invocation is the normal operator path. It prints:

- protected internal disks with mountpoint reasons, for example `/`, `/home`, `/_archive`, or `/_backup`
- selectable USB disks with device, size, model, serial, partition, filesystem label, UUID, and registration state
- for existing filesystems, capacity, detected Penelope host scopes, and an internal-backup footprint estimate derived from `/_backup/<HOST_SCOPE_NAME>` when available

The operator then selects the intended USB disk by number.

For newly prepared Penelope USB backup disks:

- `DISK_NAME` is operator-chosen; examples such as `backup-01` or `penelope-01` are examples only
- `DISK_NAME` and filesystem `LABEL` are kept identical
- the name must fit the label-safe rules: letters, digits, dot, underscore, or hyphen; start with a letter or digit; maximum 16 characters
- too-long or unsafe names are rejected and must be entered again
- the disk is erased only after the tool prints the selected device and requires the exact confirmation phrase, for example:

```text
erase /dev/sdc for backup-01
```

For an already registered disk, the guided mode is idempotent: it prints the UUID and local `DISK_NAME`, reports that no changes are needed, and exits successfully.

For an existing Penelope disk, the tool distinguishes current-host scopes, foreign-host scopes, and mixed scopes. Foreign scopes are preserved by default. The operator may explicitly register the disk for the current host without deleting old backups; normal external backups write only below the current `HOST_SCOPE_NAME` scope. Reinitialization remains a separate destructive path and still requires the exact erase phrase.

#### 7.8.2 Explicit modes

The explicit modes remain available for operators who already know the intended action:

```bash
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --prepare-new
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --register-existing
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --rename-disk
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --list-registered
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --uuid <UUID>
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --disk-name <DISK_NAME>
```

`--prepare-new` is destructive and uses the same selectable USB disk list plus the same exact destructive confirmation phrase. Use it only for a new or disposable disk.

`--register-existing` does not reformat. It verifies that a plausible Penelope backup structure already exists on disk. The disk may contain the current host scope, a foreign host scope, or both; the tool asks before allow-listing the UUID and never deletes foreign scopes as part of registration.

`--rename-disk` renames a registered disk in `/etc/penelope/usb-backup-disks.conf` and can also rename a supported filesystem label after an explicit case-sensitive `Yes` confirmation. This operation is separate from backup execution.

`--list-registered` reads only the local allow-list and prints the UUID/DISK_NAME entries currently authorized on this host. It does not scan filesystem labels and does not start a backup.

`--deregister` is non-destructive. It removes exactly one local allow-list entry selected by UUID or DISK_NAME, clears per-disk dashboard signals for that registration, and requires exact interactive confirmation such as `deregister backup-01` or `deregister <UUID>`. It refuses to proceed when the per-UUID backup lock indicates active backup activity. It does not format the disk, delete repositories, or erase backup data. To use the disk again on this host, register it again. A filesystem label alone is not authorization; only an active entry in `/etc/penelope/usb-backup-disks.conf` makes a USB disk a Penelope backup disk on this host.

#### 7.8.3 First external backup proof run

After successful registration, inspect the allowlist:

```bash
sudo cat /etc/penelope/usb-backup-disks.conf
```

For a first manual external run, replace `backup-01` with the chosen `DISK_NAME`:

```bash
UUID="$(sudo awk '$2=="backup-01"{print $1; exit}' /etc/penelope/usb-backup-disks.conf)"
echo "${UUID}"
sudo /usr/local/sbin/penelope-backup.sh --mode external --disk-name backup-01
sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --disk-name backup-01
sudo /usr/local/sbin/penelope-backup.sh --list --mode external --disk-name backup-01
sudo ls -al /var/lib/penelope/backup-dashboard
sudo tail -n 100 /var/log/*/backup/backup.log
```

Do not run manual external backup and USB autorun for the same disk at the same time. Use either the manual command path or an unplug/replug autorun test.

To inspect existing snapshots without taking or verifying a backup, use the read-only list path:

```bash
sudo /usr/local/sbin/penelope-backup.sh --list --mode external --disk-name backup-01
sudo /usr/local/sbin/penelope-backup.sh --list --mode internal
```

The listing output is grouped by Penelope scope (`system`, `home`, `_archive`) and shows Restic snapshot tags. `penelope_kind=full` marks a configured Penelope retention-cycle full marker; `penelope_kind=incr` marks later snapshots in that cycle. Restic still stores deduplicating snapshots, so these are Penelope retention-cycle tags rather than separate full-file backup formats.

#### 7.8.4 Reinitializing or retiring a registered USB backup disk

A registered USB backup disk is authorized by the local allow-list entry in `/etc/penelope/usb-backup-disks.conf`, not by its filesystem label alone. Before reinitializing or retiring a disk, remove the local authorization for the old UUID with the USB disk setup tool:

```bash
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --list-registered
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --uuid <OLD-UUID>
# or, when DISK_NAME is known and unique in the allow-list:
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --disk-name <DISK_NAME>
```

`--deregister` is intentionally non-destructive. It removes the local allow-list entry and per-disk dashboard signals for that registration. It does not erase the USB disk, delete repositories, delete backup data, or change the filesystem label.

Use one of these safe reinitialization variants:

**Variant A: temporary autorun masking before reconnecting a still-registered disk**

```bash
UUID="<OLD-UUID>"
sudo systemctl stop "penelope-usb-backup@${UUID}.service" 2>/dev/null || true
sudo systemctl mask penelope-usb-backup@.service
sudo systemctl daemon-reload

sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --uuid "${UUID}"
sudo /usr/local/sbin/penelope-usb-disk-setup.sh --prepare-new

sudo systemctl unmask penelope-usb-backup@.service
sudo systemctl daemon-reload
```

This variant is appropriate when the old filesystem UUID may still be present when the disk is connected to Penelope. Masking the template prevents a registered old UUID from starting autorun while the operator is deliberately reinitializing the disk.

**Variant B: external reformat before reconnecting to Penelope**

You may reformat the disk on another computer first. This is safe only when that reformat removes or changes the old registered filesystem UUID before the disk is reconnected to Penelope. Then the old UUID cannot start a valid allow-listed backup. Deregister the old allow-list entry before reusing the same `DISK_NAME`, because Penelope keeps `DISK_NAME` values unique in the local allow-list.

After either variant, use `--prepare-new` or `--register-existing` deliberately for the new intended state. Do not rely on a disk label alone as authorization.

#### 7.8.5 Canceling backups safely

For an external backup, prefer the symmetric cancel command:

```bash
sudo /usr/local/sbin/penelope-backup.sh --cancel --mode external --disk-name <DISK_NAME>
# or
UUID="<UUID>"
sudo /usr/local/sbin/penelope-backup.sh --cancel --mode external --uuid "${UUID}"
```

For an autorun/systemd-started external backup, the cancel command asks systemd to stop the matching instantiated unit. The direct systemd command remains useful as a diagnostic fallback:

```bash
UUID="<UUID>"
sudo systemctl stop "penelope-usb-backup@${UUID}.service"
sudo systemctl status "penelope-usb-backup@${UUID}.service" --no-pager -l
findmnt "/_usbbackup/${UUID}" || echo "USB backup disk not mounted"
```

If the disk remains mounted and no backup process is active, unmount only that external mountpoint:

```bash
sudo umount "/_usbbackup/${UUID}"
```

If the mount is busy, inspect it first:

```bash
sudo fuser -vm "/_usbbackup/${UUID}"
```

For a manually started external backup in a terminal, press Ctrl-C once and wait. From another terminal, prefer the `--cancel --mode external` command above. If low-level diagnosis is still needed, inspect first and terminate only the specific relevant parent process:

```bash
pgrep -af 'penelope-backup.sh.*--mode external'
pgrep -af 'restic .*penelope_mode=external'
sudo kill -TERM <PENELOPE_BACKUP_PID>
```

For a manually or cron-started internal backup, press Ctrl-C once when it is in the foreground. From another terminal, prefer:

```bash
sudo /usr/local/sbin/penelope-backup.sh --cancel --mode internal
```

If low-level diagnosis is still needed, inspect first:

```bash
pgrep -af 'penelope-backup.sh.*--mode internal'
pgrep -af 'restic .*penelope_mode=internal'
```

Then terminate only the specific parent `penelope-backup.sh --mode internal` process if necessary:

```bash
sudo kill -TERM <PENELOPE_BACKUP_PID>
```

Do not unmount `/_backup` or any internal backup partition when canceling an internal backup. After cancellation, verify that the internal backup role is still mounted and inspect the backup status:

```bash
findmnt /_backup || echo "ERROR: /_backup is not mounted"
sudo tail -n 120 /var/log/penelope/backup/backup.log
sudo cat /var/lib/penelope/backup-dashboard/last-internal.json
```


## Backup cancellation, allow-list management, and active-run behavior

The current backup tooling provides explicit operator interfaces for USB allow-list management, backup cancellation, and duplicate external-run protection:

- `penelope-usb-disk-setup.sh --list-registered` lists local registered USB backup disks.
- `penelope-usb-disk-setup.sh --deregister --uuid <UUID>` and `--deregister --disk-name <DISK_NAME>` remove one local allow-list entry after exact confirmation without deleting backup data.
- `penelope-backup.sh --cancel --mode internal` cancels the active internal backup without unmounting `/_backup`.
- `penelope-backup.sh --cancel --mode external --uuid <UUID>` or `--disk-name <DISK_NAME>` cancels the selected external backup and reports remaining process/mount state.
- External starts for a UUID that already has active Penelope backup work wait briefly for the older run to finish before refusing a parallel writer.

These commands are part of the current operator surface and are documented above in the USB setup and cancellation sections.

## 8) Recovery (Flows; offline-only full restore via penelope-offline-recover)

This chapter documents recovery patterns and decision-making.

- For **file-level / selective recovery on a running system**, use manual restic commands (see the examples below).
- For an **offline full restore** (Live-USB/Rescue, including `system`), use `/usr/local/sbin/penelope-offline-recover.sh` (installed by `penelope-backup-setup`).
- Successful internal/external backup runs that reach their final success boundary also sync a **non-secret recovery bundle** beside the repositories under `<repo-base>/_recovery/`. When automatic post-backup verify is enabled, this sync happens only after the chained verify step has succeeded.
- That bundle now contains:
  - `penelope-install.sh` (sanitized copy if the installer has staged one on this system)
  - `penelope-backup-setup.sh` (sanitized copy)
  - `penelope-samba-setup.sh` (sanitized copy if the Samba setup has been run on this system)
  - `penelope-common.sh`
  - `penelope-offline-recover.sh`
  - selected generated runtime helpers when present (`penelope-backup.sh`, `penelope-backup-verify.sh`, `penelope-backup-find-snapshot.sh`, `penelope-rotate-external-restic-passwords.sh`, `penelope-usb-disk-setup.sh`, `penelope-refresh-backup-dashboard.sh`)
  - `README-RECOVERY.txt` and `manifest.txt`
- The setup-script copies inside `_recovery` are **password-sanitized**. `CRED_`-prefixed top-level credential edit variables and other password-bearing initialization fields are reset to `change-me`, while structural values such as `ADMIN_USER`, `TARGET_HOST`, usernames, share names, and paths remain visible; obtain the effective values from KeePass before using them.
- `penelope-verify-security.sh` checks the local recovery-stage area and, when available, the internal `/_backup/<HOST_SCOPE_NAME>/_recovery` bundle for presence, shell syntax, and known sanitized credential markers, including placeholder-reset `CRED_` edit variables. The verifier applies the same check families to both paths so staged and synced recovery copies stay aligned. On Samba-enabled hosts it also verifies `/etc/samba/smb.conf`, active Penelope include wiring, `testparm -s`, `smbd` enabled + active, and the Windows Explorer discovery service `wsdd2.service` enabled + active. The Samba setup apply path additionally keeps the AD DC service disabled for the standalone file-server role.
- In a Live-USB situation, copy the matching `_recovery` directory to the Live session (for example Desktop or `/tmp`), edit the sanitized setup copies locally, and **do not** write edited copies with real credentials back into `_recovery`.


### 8.1 Key principles
- Recovery is always initiated manually (never triggered by USB insert).
- For “complete restore” of `/home` or `/_archive`, the **target is overwritten** deliberately.
- Distinguish the **installed target hostname** (`TARGET_HOST`) from the **backup scope identity** (`HOST_SCOPE_NAME`). They may intentionally differ during recovery or migration.
- Example: you may restore backups that were created under the scope **asterix** onto a newly installed target host **obelix**. In that case, `TARGET_HOST=obelix` identifies the restored system, while `HOST_SCOPE_NAME=asterix` continues to identify the repository/log scope.
- Recovery starts with an explicit **operator decision**: choose the desired target state, the repository source (**internal first, external as fallback when needed**), and the snapshot you actually want to restore.
- The `_recovery` bundle beside the repositories is tooling only. It does **not** contain effective restic passwords or other secrets; fetch those from KeePass or another external secure vault first.
- Treat the sanitized setup copies in `_recovery` as **throw-away Live-session working copies**: copy them to a temporary local directory, edit them there, run them, and leave `_recovery` itself non-secret.
- Do **not** assume that the newest snapshot is always correct; if corruption or deletion may already be present in recent backups, deliberately choose a snapshot that still contains the path you need.
- Use `/usr/local/sbin/penelope-backup-find-snapshot.sh` to find the newest snapshot that still contains a given absolute path for `system`, `home`, and `_archive`, across internal and external repositories. The helper is read-only: it does not restore, delete, prune, unlock, or modify repositories. Select and verify the snapshot deliberately before restoring.

### 8.2 Recovery flows (Flow A / Flow B)

This project intentionally supports **two** operator recovery flows. Choose the flow based on the incident type and what you need to recover.

**Quick decision rule:**
- Use **Flow A** by default. It is the normative standard for most incidents because it starts with a fresh reinstall, keeps the recovery decision explicit, and avoids accidentally dragging an entire old system state back in when you only need data or selected configuration.
- Use **Flow B** only when you explicitly want a full snapshot rollback of one or more targets, especially `system`, in an offline environment.
- `penelope-offline-recover.sh` now requires `--snapshot` in restore mode; even `latest` must be chosen explicitly instead of being assumed silently.
- If you are unsure, choose **Flow A** first.

#### Flow A (normative standard for most incidents): reinstall (system refresh) + restore data/config (selective where possible)

Use this flow when the system is not bootable (e.g., broken initramfs/boot), or when you want a conservative recovery with minimal risk.

High-level steps:
1. Boot a Live-USB environment.
2. Run `penelope-install` to recreate the required targets (often `system`, optionally `home` and `/_archive`; preserve `/_backup` if you rely on internal repositories).
3. Reboot into the newly installed system and log in as `admin_user`.
4. Make the recovery decisions explicitly **before** rerunning backup tooling:
   - choose the repository source for each target (**prefer internal scoped repos first; use external USB repos if internal restore is unavailable or if an external snapshot is the correct recovery point**)
   - choose the snapshot you actually want (`latest` or an older known-good snapshot)
   - restore `backup.conf` and credential material first (see 8.7), or explicitly set the intended backup scope before rerunning setup tooling
5. Run `penelope-backup-setup --keep-config --keep-secrets` only after the configuration/credential state is correct.
6. Restore the required data.
7. If a preserved mounted `/_backup` already contains internal repositories, plain `penelope-backup-setup` intentionally refuses a blind bootstrap without a concrete restored or explicitly selected backup scope. This is a safety guard against accidental new-scope / new-password drift on top of preserved repositories. An explicit fallback scope is valid there only when it matches one of the already detected internal scopes on disk; an explicit but unknown scope is now rejected instead of creating a fresh internal scope beside historical repos.

**Installed software + data (typical real-world case: Docker/DB):**
- Many applications store data under `/var/lib/<APP>/` and configuration under `/etc/<APP>/`. This application state is typically included in the **system** repository (because it is part of `/`).
- With Flow A, you have two options:
  - **Option A1 (recommended in many cases):** re-provision software after reinstall, then restore only the required data/config selectively (specific paths) from the system repository.
  - **Option A2 (if you require a full rollback of software state and `/var` data):** restore the full **system** target using Flow B (offline) and then perform the mandatory post-restore boot refresh.


**Notes:**
- Flow A is compatible with your “preserve `/_backup`” disaster-reinstall model.
- Flow A is the **normative standard** for most incidents because it starts with an explicit recovery decision (source + snapshot) and keeps the fresh system/tooling path separate from full snapshot rollback.
- Full “wipe and restore” of `/home` on a running system is generally unsafe; prefer Live-USB for complete restores. Selective restores on a running system are usually fine.

#### Flow B (advanced): offline full restore (Live-USB), including `system`

Use this flow when you want to restore targets **fully** to a snapshot state (no “phantom” files), and you can work in an **offline** environment.

Key properties (current behavior of `penelope-offline-recover`):
- Runs **only** on Live-USB/Rescue. If it detects a running installed system, it aborts with a clear diagnostic.
- Restore mode still requires an explicit `--snapshot <snapshot-id|latest>` argument; even `latest` must be chosen deliberately.
- Before any destructive `mkfs` / optional `luksFormat` step begins, the tool now preflights **all selected targets**:
  - the scoped repo path for each selected target must exist and look like a valid restic repository
  - the required restic password for each selected target must be accepted
  - the requested snapshot (`latest` or a specific snapshot ID) must resolve successfully for each selected target
  - obvious target-device blockers such as missing partitions, already-mounted target devices, or already-open holder/mapper chains on selected target devices are checked up front
- If any selected target fails that preflight, the run aborts **before wiping any selected target**.
- For each selected target (`system`, `home`, `/_archive`):
  - Default: unlock LUKS (if applicable) and perform a **clean mkfs** on the mapper, then restore the chosen snapshot.
  - Optional: `luksFormat` (explicit flag), using the **same CRED_MASTER_PW**, then mkfs + restore.
- **Repo sources default to read-only:** internal sources are mounted/read-used read-only by default, and external sources are also read-only unless you explicitly pass `--usb-mount-rw`. If the tool reuses an already-mounted repo source while read-only mode is expected, it now requires the effective mount to be read-only instead of continuing after a best-effort remount.
- **System restore requires mount guards:** `/boot` and `/boot/efi` must be mounted into the sysroot before restoring to avoid inconsistent boot files.
- **System restore refreshes `/etc/fstab` and `/etc/crypttab` to the current on-disk UUIDs** after the selected targets have been restored, so recreated filesystems and optional `--recreate-luks` do not leave stale IDs behind. This refresh now also covers the current Penelope layout entries for `/home`, `/_archive`, and `/_backup` even when the same recovery run restores only `system`, so a restored system snapshot does not keep stale layout IDs from the historical source host.
- **System restore requires a post-restore boot refresh** (see below).

**Post-restore boot refresh (mandatory when restoring `system`):**
After restoring `system`, the recovery tool first refreshes `/etc/fstab` and `/etc/crypttab` inside the restored sysroot so that `/`, `/boot`, `/boot/efi`, and any recreated `/home` / `/_archive` targets point to the current on-disk UUIDs. It then chroots into the restored sysroot and runs:
- `update-initramfs -u -k all`
- `update-grub`
- and, when the EFI-loader guard shows that the restored system is currently missing the expected loader on disk, `grub-install`.

This step is needed because bootability depends not only on files on disk but also on generated artifacts and platform boot state. In unusual firmware states you may still need additional platform-specific boot-entry repair outside the automatic helper path; the current helper does not promise a generic `efibootmgr` remediation sweep.

#### Recovery onto differently named new hardware (`TARGET_HOST != HOST_SCOPE_NAME`)

This is a normal Penelope scenario, not an exception.

**Source of truth:**
- `TARGET_HOST` identifies the newly installed or newly restored machine.
- `HOST_SCOPE_NAME` identifies the historical backup scope that already owns the repositories and should usually stay stable.

**Code path:**
- `penelope-install` and initramfs-side artefacts use `TARGET_HOST`.
- `penelope-backup-setup` and the backup runner use `HOST_SCOPE_NAME` for repository paths, host-scoped backup logs, and restic snapshot hostname metadata.

**Expected behaviour:**
- The restored or reinstalled machine boots and identifies itself as `TARGET_HOST`.
- Backups continue in the existing scoped repositories under `/_backup/<HOST_SCOPE_NAME>/<repo>` (or the matching external scoped path).
- New restic snapshots in that historical scope continue to appear under the stable scope identity rather than switching to the new machine hostname.

**Failure behaviour / operator pitfall:**
- If `HOST_SCOPE_NAME` is changed accidentally to the new machine name, Penelope will treat that as a different backup namespace and the expected historical repositories may appear to be “missing”.
- On a non-empty preserved internal `/_backup`, the current setup intentionally blocks blind bootstrap and also blocks creating a fresh internal scope beside historical repos.

**Required operator decision:**
- Decide explicitly whether the new machine continues an existing historical backup scope or intentionally starts a brand-new scope.
- If it continues an existing scope, keep or restore the original `HOST_SCOPE_NAME` and the matching restic passwords before reattaching tooling.

#### Online recovery on a running system (limited)
- Complete restores of `/` or `/home` are **not recommended** while the system is running.
- Prefer **selective restic restores** of specific files/directories (see scenario C below) or use Flow A/B in an offline environment.
- `/_archive` can sometimes be fully restored on a running system if it can be cleanly unmounted and no process is using it; treat this as an advanced operation.

#### Typical manual recovery scenarios (restic patterns)
#### A) Restore full `/home` (overwrite completely)
Use case: roll back to last known-good state.

High-level approach:
1. Ensure you have the correct repo (internal or USB).
2. Select snapshot (latest or specific).
   - For `penelope-offline-recover.sh`, restore mode now requires an explicit `--snapshot <snapshot-id|latest>` argument. Use `--snapshot latest` only when that is the deliberate recovery point.
3. Move existing content aside (optional) or wipe target.
4. Restore snapshot to `/home`.
5. Fix ownership/permissions if needed.
6. Restart services (if applicable).

#### B) Restore full `/_archive` (overwrite completely)
Same approach as `/home`, but target is `/_archive`.

#### C) Restore only selected folders/files
Use restic path filtering to restore only a subdirectory.


### 8.3 Snapshot selection UX
Current behavior of `penelope-offline-recover`:
- restore mode requires an explicit `--snapshot latest|<SNAPSHOT_ID>` argument
- the tool currently does **not** present a numbered interactive snapshot chooser and does **not** auto-default to the newest snapshot after a timeout
- if you pass `--snapshot latest`, the tool resolves that choice during preflight before any destructive step begins

Recommended operator workflow for choosing a recovery point:
- inspect candidate snapshots explicitly with `restic snapshots` (or equivalent repository inspection) before a destructive restore
- do **not** treat the newest snapshot as the normative default in recovery runbooks; an older known-good snapshot may be the correct choice after latent corruption
- record the chosen snapshot ID in the operator notes so later steps use the same recovery point consistently

How to choose a **known-good snapshot** in practice:
1. Define the path you want to recover, for example `/home/internal/project-x`, `/_archive/p001`, or `/etc/penelope/backup.conf`.
2. Use the read-only helper to find the newest snapshot that still contains that path. Do not assume `latest` is safe after accidental deletion.

```bash
sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /home/internal/project-x
sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /_archive/p001
sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target system --path /etc/penelope/backup.conf
sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode external --disk-name <DISK_NAME> --target auto --path /_archive/p001
```

3. Use the reported `snapshot_id` as the recovery candidate. If the helper reports no match, search an older external source or reassess the path.
4. Restore selected files/configuration into a staging directory first, or inspect repository contents/snapshot metadata to confirm that the expected state is present.
5. Record the chosen `SNAPSHOT_ID` in the operator notes/runbook for the incident so later steps use the same recovery point consistently.

Helper behavior:
- `--target auto` maps `/home paths` to the `home` repository, `/_archive paths` to `_archive`, and normal system paths such as `/etc paths` to `system`.
- It rejects `/_backup` and volatile/excluded trees such as `/proc`, `/dev`, `/sys`, `/run`, `/tmp`, `/mnt`, and `/media`.
- With `--mode external`, select a registered USB backup disk with `--uuid <UUID>` or `--disk-name <DISK_NAME>`. The helper mounts the disk read-only when it needs to mount it itself and releases the runtime UUID lock afterward.
- `--json` prints machine-readable output for runbooks.

### 8.4 Example: complete restore of `/home` from internal backups

This is an **offline** example (Live-USB/Rescue recommended). The core idea is: mount the target filesystem somewhere safe, then restore a snapshot into that mountpoint.

Assuming:
- internal home repo: `/_backup/<HOST_SCOPE_NAME>/home`
- restic password file: `/root/.config/restic/home_pw` (example; may differ per host)

**How to obtain `<SNAPSHOT_ID>` for this repo:**
```bash
export RESTIC_REPOSITORY="/_backup/<HOST_SCOPE_NAME>/home"
export RESTIC_PASSWORD_FILE="/root/.config/restic/home_pw"
restic snapshots --latest 5
```
Choose the snapshot ID from the first column of the `restic snapshots` output for the recovery point you selected.

**Tool behavior (offline tool):**
```bash
sudo /usr/local/sbin/penelope-offline-recover.sh --repo internal --targets home --snapshot <SNAPSHOT_ID> --yes-i-know-this-wipes-data
```

**Manual restic pattern (today):**
```bash
export RESTIC_REPOSITORY="/_backup/<HOST_SCOPE_NAME>/home"
export RESTIC_PASSWORD_FILE="/root/.config/restic/home_pw"

restic snapshots --latest 5
# Ensure the target is mounted, e.g.:
#   mount /dev/mapper/<HOME_MAPPER> /mnt/home
# Then restore:
restic restore <SNAPSHOT_ID> --target /mnt/home
sync
```

Notes:
- A complete `/home` restore is not recommended on a running system with active users; use Live-USB where possible.
- If you need a guaranteed “no phantom files” state, wipe/format the target (offline) before restoring.


### 8.5 Example: complete restore of `/_archive` from USB backups

This is an **offline** example (Live-USB/Rescue recommended).

Assuming:
- USB repo root contains: `<HOST_SCOPE_NAME>/_archive` (restic repo layout)
- restic password file: `/root/.config/restic/_archive_pw` (example; may differ per host)

**How to obtain `<SNAPSHOT_ID>` for this repo:**
```bash
# Mount the USB disk read-only (recommended), then:
export RESTIC_REPOSITORY="/mnt/usb/<HOST_SCOPE_NAME>/_archive"
export RESTIC_PASSWORD_FILE="/root/.config/restic/_archive_pw"
restic snapshots --latest 5
```
Choose the snapshot ID from the first column of the `restic snapshots` output for the selected recovery point after mounting the correct USB backup device.

**Tool behavior (offline tool):**
```bash
sudo /usr/local/sbin/penelope-offline-recover.sh --repo external --targets _archive --uuid <USB_UUID> --snapshot <SNAPSHOT_ID> --yes-i-know-this-wipes-data
```

**Manual restic pattern (today):**
```bash
# Mount the USB disk read-only (recommended), then:
export RESTIC_REPOSITORY="/mnt/usb/<HOST_SCOPE_NAME>/_archive"
export RESTIC_PASSWORD_FILE="/root/.config/restic/_archive_pw"

restic snapshots --latest 5
# Ensure the target is mounted, e.g.:
#   mount /dev/mapper/<ARCHIVE_MAPPER> /mnt/archive
restic restore <SNAPSHOT_ID> --target /mnt/archive
sync
```

Notes:
- `/_archive` is often easier to restore than `/home` because it can be kept “cold” (unmounted) during normal operations.

### 8.6 Live-USB reinstall while preserving the unencrypted `/_backup` partition

**Goal:** enable a “reinstall-from-Live-USB” recovery mode where the OS is rebuilt cleanly via `penelope-install`, while an existing, unencrypted `/_backup` partition on the second disk remains untouched. After reboot and login as `admin_user`, `penelope-backup-setup` can be re-run and `/home` and `/_archive` can be restored from the scoped internal restic repositories stored on that preserved `/_backup` partition (`/_backup/<HOST_SCOPE_NAME>/home` and `/_backup/<HOST_SCOPE_NAME>/_archive`).

Proposed operational workflow:

1) Boot from Live-USB.
2) Run `penelope-install` with `RECREATION_TARGET_LIST=system,home,_archive` to preserve the existing unencrypted `/_backup` partition.
   - The current uploaded installer does not expose a separate `STRICT_VERIFY` / `PENELOPE_STRICT_VERIFY` toggle; relevant verification blockers already abort according to per-check severity.
   - Ensure `CRED_MASTER_PW` matches the existing LUKS containers if you preserve encrypted targets.
3) Reboot into the newly installed system and login as `admin_user`.
4) Decide the recovery plan explicitly before restoring data:
   - choose the repository source for each target (**internal scoped repo first; external USB repo when the internal repo is unavailable or when the correct recovery point is on USB**)
   - choose the snapshot you actually want (`latest` or an older known-good snapshot)
   - restore `backup.conf` and restic credentials first where possible
5) If backup tooling is needed on the freshly installed system, run `penelope-backup-setup --keep-config --keep-secrets` after `backup.conf` and credentials are in place.
6) Restore `/home` from the internal scoped repository `/_backup/<HOST_SCOPE_NAME>/home` unless you intentionally choose an external snapshot instead.
7) Restore `/_archive` from either:
   - the internal scoped repository `/_backup/<HOST_SCOPE_NAME>/_archive`, or
   - an external USB repository `<USB-root>/<HOST_SCOPE_NAME>/_archive`.
8) Use the tooling-first variant only as a constrained fallback: only when you already know the intended `HOST_SCOPE_NAME` (from restored `backup.conf` or from an explicit verified decision such as `PENELOPE_HOST_SCOPE_NAME=<scope>`) and already have the matching restic password files available. On a non-empty preserved `/_backup`, that explicit fallback is valid only for one of the already detected internal scopes on disk; the current setup intentionally rejects both blind bootstrap and explicit creation of a fresh internal scope beside historical repos. If the reinstall target host is newly renamed hardware, do **not** change `HOST_SCOPE_NAME` just to mirror the new machine name; keep the historical scope identity when you mean to reattach to the existing repositories. If you reinstall tooling before `backup.conf` itself has been restored, rerun `penelope-backup-setup --keep-config --keep-secrets` again after restoring `backup.conf` so the installed tooling reflects the restored config file without reinitializing secrets.
9) Choose the repository source and snapshot explicitly; do not assume that internal vs. external repositories or newest vs. older snapshots are interchangeable in operator runbooks. If you later switch from reinstall/selective restore to `penelope-offline-recover` (Flow B), the offline tool now preflights repo layout, restic password acceptance, snapshot resolution, and obvious target-device blockers for **all** selected targets before any destructive wipe begins.

**Legacy note:** earlier drafts proposed adding a CLI parameter. The implemented mechanism is the config constant `RECREATION_TARGET_LIST` (see 4.1.1). The text below is kept for context: a comma-separated list similar in spirit to backup targets can make sense, but the naming must be unambiguous in the context of installation/wipe operations.

Two viable designs:

**Current behavior (implemented):**
- `RECREATION_TARGET_LIST` is set in the header section of `penelope-install` (no CLI parsing).
- Allowed tokens: `system`, `home`, `_archive`, `_backup`, `all`.
- Preserve a target by omitting it from `RECREATION_TARGET_LIST` (e.g. `system,home,_archive` preserves `/_backup`).

**TODO:** If a future `penelope-install` introduces CLI flags for recreation/preserve, document the finalized semantics here.


### 8.7 Restoring `backup.conf` and restic credential material from the system repository (CLI example)

If you have access to the **system** restic repository, you can restore the backup configuration and restic password material via CLI. This is useful after a reinstall when you want to reattach to existing repositories.

Example (adjust paths to your environment):

```bash
# 1) Point restic to the system repository and provide the system password file
export RESTIC_REPOSITORY="/_backup/<HOST_SCOPE_NAME>/system"
export RESTIC_PASSWORD_FILE="/root/.config/restic/system_pw"  # example; may differ per host

# 2) Choose a snapshot
restic snapshots

# 3) Restore the configuration and credentials into a staging directory
mkdir -p /root/restore-staging
restic restore <SNAPSHOT_ID> --target /root/restore-staging \
  --include /etc/penelope/backup.conf \
  --include /etc/penelope/usb-backup-disks.conf \
  --include /root/.config/restic
```

Then copy the files back with correct permissions:

```bash
install -d -m 0750 /etc/penelope
install -m 0640 /root/restore-staging/etc/penelope/backup.conf /etc/penelope/backup.conf
install -m 0640 /root/restore-staging/etc/penelope/usb-backup-disks.conf /etc/penelope/usb-backup-disks.conf

install -d -m 0700 /root/.config/restic
cp -a /root/restore-staging/root/.config/restic/* /root/.config/restic/
chmod 0600 /root/.config/restic/* || true
```

Notes:

- If the system backup already contains `/etc/penelope/samba-setup`, restore that directory first and treat it as the canonical Samba source of truth for later reruns/upgrades. The sibling `<HOST_SCOPE_NAME>/_recovery` bundle is tooling-only; it is **not** the live Samba config location.
- Minimal Samba restore runbook after reinstall or system-level recovery:
  1. Restore `/etc/penelope/samba-setup` from the chosen system snapshot.
  2. Copy the matching sanitized `penelope-samba-setup.sh` and `penelope-common.sh` from `<HOST_SCOPE_NAME>/_recovery` into a temporary local workspace.
  3. Inspect the restored config first, even if some secrets are still missing or placeholder-valued:
     - `./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup list-users`
     - `./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup list-shares`
     - `./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup show-user <USER>`
     - `./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup show-share <SHARE>`
  4. Rehydrate `/etc/penelope/samba-setup/secrets.d/*.secret` with the effective values from KeePass.
  5. Run `./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup verify-config` from that temporary workspace.
  6. Run `sudo -E ./penelope-samba-setup.sh --config-dir /etc/penelope/samba-setup apply` so the derived Samba runtime state is regenerated on the target host.
  7. Do not write secret-bearing edited copies back into `_recovery`.
- Generated Samba runtime output is derived state. After a restore, prefer restoring `/etc/penelope/samba-setup` plus the sanitized tooling bundle, then regenerate the effective Samba runtime files with `apply` instead of treating generated include files as the canonical restore source.
- Without the corresponding password file (e.g. `system_pw`), the system repository cannot be accessed.
- Treat restic password files, Dropbear unlock/access credentials, admin credentials, and AnyDesk credentials as **hard recovery prerequisites**; they must exist redundantly outside the system (for example in KeePass, a separate secure vault, or a sealed printed recovery record).
- In reinstall flows, treat recovery as a decision-first process: restore `backup.conf` and the restic password files first where possible, confirm the intended repository source and snapshot, then run `penelope-backup-setup --keep-config --keep-secrets` if the tooling is needed on the freshly installed system.
- If you use an explicit `PENELOPE_HOST_SCOPE_NAME` fallback on a non-empty preserved internal `/_backup`, that scope must already exist among the detected internal repo scopes on disk; explicit selection is for reattaching to an existing scope, not for creating a fresh internal scope beside preserved repositories.
- If you already reran `penelope-backup-setup` before restoring `backup.conf`, rerun `penelope-backup-setup --keep-config --keep-secrets` again after the restore so that the installed tooling is attached to the restored configuration and secrets without reinitializing them.
- After a **full system restore** of `/`, rerunning `penelope-backup-setup` is usually not required unless you intentionally want to upgrade the bundle or regenerate operational artifacts.

## 9) Security notes

This chapter covers credential rotation and security verification tools installed by `penelope-install`, plus operational guidance for secure handling of keys and passwords.

### 9.1 Theft scenario
If the device is stolen:
- Data in `/`, `/home`, `/_archive` remains protected by LUKS2 (requires `CRED_MASTER_PW`).
- `/boot` is unencrypted (normal), but does not expose encrypted data contents.

### 9.2 SSH key hygiene
- The Dropbear/initramfs key is powerful: protect `${TARGET_HOST}_unlock_keys.7z` carefully.
- Store both encrypted archives in KeePass.
- KeePassXC on the server desktop is only a convenience copy; do not let the server be the only place that holds the vault or the recovery-relevant credentials.
- After the values are captured externally and verified, do not keep loose secret-bearing Desktop copies as the routine long-term store.
- Consider periodic key rotation once the base system is stable.

### 9.3 Network exposure
- Do **not** expose Dropbear (port 2222) or SSH (22) via router port-forwarding to the Internet.
- Remote unlock is designed for **LAN** (or controlled VPN/jump-host environments).

### 9.4 AnyDesk note
AnyDesk is installed and enabled by `penelope-install` (APT/deb.anydesk.com). The installer treats AnyDesk as required. Before destructive partitioning, it checks that the external AnyDesk key and repository metadata are reachable, using `curl` as the explicitly installed live HTTPS download tool. It stages the fetched repository key and then requires that staged key in the later chroot configuration phase. The chroot AnyDesk APT path uses retry logic and IPv4-forced APT operations, but it does not attempt a second late key download fallback inside the chroot. This is **not** a complete unattended setup.

**Contract:**
- The installer ensures the AnyDesk service is present and can be brought online.
- Unattended/full-access (password) and “no session request” are enabled **manually** in the AnyDesk GUI after the first GNOME login.
  - This avoids persisting an AnyDesk password in cleartext on the target system and avoids brittle CLI/setting differences between AnyDesk builds.

If AnyDesk key or repository access fails during the pre-destructive preflight, fix connectivity and rerun before continuing. If the later chroot APT install still fails after the built-in retries, treat that as an external vendor/network failure and rerun the install after connectivity is fixed or handle AnyDesk installation manually before accepting the host as complete.

## 10) Troubleshooting

### 10.1 Live run: “mount point does not exist” for `/mnt/root/boot/efi`
Root cause: incorrect mount order.
Correct order:
1) mount `/mnt/root`
2) mount `/mnt/root/boot`
3) create `/mnt/root/boot/efi`
4) mount EFI to `/mnt/root/boot/efi`

### 10.2 “Partition(s) in use — reboot now”
Usually means:
- some mountpoints are still busy, or
- LUKS mappings still active.

Actions:
- ensure `/mnt/root` is fully unmounted (`umount -R /mnt/root`)
- close crypt mappings (`cryptsetup close <mapper>`)
- use `fuser` or lazy unmount if required

### 10.3 Cannot SSH to Dropbear during boot
Check:
- initramfs configured for DHCP (kernel cmdline `ip=:::::<host>::dhcp` and/or initramfs-tools `IP=dhcp`)
- correct port `2222`
- network path (same LAN / routing / firewall)

If the host is “not visible” in the router UI, do not assume a fixed IP; search by MAC address if possible.

### 10.4 Initramfs logging: where to look
1) After a successful boot/unlock, check:
- `/var/log/${TARGET_HOST}/initramfs/latest.log`
2) If logs are missing:
```bash
systemctl status penelope-initramfs-logcopy.service --no-pager
journalctl -u penelope-initramfs-logcopy.service -b --no-pager
```
3) If still present in RAM (immediately after boot):
- `/run/initramfs/penelope/` (volatile)

**Optional (debug):** To keep the volatile `/run` initramfs logs after boot (normally cleaned up), run logcopy once with:
```bash
sudo PENELOPE_KEEP_INITRAMFS_LOGS=1 /usr/local/sbin/penelope-copy-initramfs-logs.sh
```
⚠️ Use only temporarily; keeping logs in `/run` can fill the initramfs/tmpfs.

### 10.5 Backup troubleshooting (restic)
Pragmatic backup-verify first checks after backup setup:
```bash
# current backup verification
sudo /usr/local/sbin/penelope-backup-verify.sh

# verify mountpoints
findmnt /_backup
findmnt /_archive

# inspect latest verify result
sudo cat /var/lib/penelope/backup-dashboard/last-verify.json

# list snapshots through Penelope (preferred)
sudo /usr/local/sbin/penelope-backup.sh --list --mode internal
sudo /usr/local/sbin/penelope-backup.sh --list --mode external --disk-name backup-01

# raw Restic fallback for advanced diagnostics
RESTIC_REPOSITORY=/_backup/${HOST_SCOPE_NAME}/system RESTIC_PASSWORD_FILE=/root/.config/restic/system_pw restic snapshots
RESTIC_REPOSITORY=/_backup/${HOST_SCOPE_NAME}/home   RESTIC_PASSWORD_FILE=/root/.config/restic/home_pw   restic snapshots
RESTIC_REPOSITORY=/_backup/${HOST_SCOPE_NAME}/_archive RESTIC_PASSWORD_FILE=/root/.config/restic/_archive_pw restic snapshots
```
If verify fails, inspect both `verify.log` and `backup.log` before rerunning anything.

**Common operator-visible failure cases:**

- **Expected mount layout is missing**
  - Symptom: the runner or backup-verify aborts immediately instead of taking a backup.
  - Code contract: `/_backup`, `/_archive`, and `/home` must all be mounted as expected; otherwise Penelope refuses to continue.
  - Operator check: run `findmnt /_backup`, `findmnt /_archive`, and `findmnt /home`. If one of them is missing or merged into `/`, fix the mount/layout problem first; do not expect a degraded-mode backup to continue.

- **Wrong `HOST_SCOPE_NAME` / wrong repository namespace**
  - Symptom: logs appear under an unexpected host-scoped path or the expected internal repositories seem “missing”.
  - Source of truth: `/etc/penelope/backup.conf` (`HOST_SCOPE_NAME`) and the resulting paths `/_backup/<HOST_SCOPE_NAME>/{system,home,_archive}` and `/var/log/<HOST_SCOPE_NAME>/backup/backup.log`.
  - Validation contract: `HOST_SCOPE_NAME` must match `^[a-z0-9][a-z0-9_-]{0,61}$`. `penelope-backup-setup` and its generated helpers now abort on invalid values from `backup.conf` or an explicit override instead of deriving repo/log paths from malformed scope names.
  - Operator rule: before rerunning setup or forcing a backup, verify that `HOST_SCOPE_NAME` is the intended historical backup scope. After reinstall/recovery, restore `backup.conf` first if you need to reattach to existing repositories. If the scope value is invalid, fix `backup.conf` (or the explicit override) before retrying any setup/rotation/backup action.

- **Restic password files are missing**
  - Symptom: backup/restore commands cannot open the repositories.
  - Required files: `/root/.config/restic/{system_pw,home_pw,_archive_pw}`.
  - Operator rule: this is a hard blocker, not a soft warning. Retrieve the redundant external copies (for example from KeePass or another secure recovery vault) before continuing.

- **USB disk is not allow-listed / ambiguous USB selection**
  - Symptom: external backup does not start, or a manual non-interactive run aborts.
  - Source of truth: `/etc/penelope/usb-backup-disks.conf`.
  - Operator rule: if more than one allow-listed disk is present, use `--uuid <UUID>` or `--disk-name <DISK_NAME>` explicitly. `--disk-name` is resolved strictly through `usb-backup-disks.conf`; a filesystem label alone is not authorization. If no allow-listed disk is detected, verify the UUID in `usb-backup-disks.conf` or re-register the disk with `penelope-usb-disk-setup.sh`.

- **USB disk remains busy / not safe to remove yet**
  - Symptom: `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` stays present for longer than expected for a specific disk, or the external backup finished but `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` is missing, `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` exists, or the disk still appears mounted under `/_usbbackup/<UUID>`.
  - Code contract: `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` is written as soon as that allow-listed USB backup drive is detected and the external backup run starts. At the end of the run, `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` is written only after a successful external run and confirmed unmount for that disk. `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` is written when the user must leave that USB backup drive attached and contact the operator.
  - Operator rule: while `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` exists, do **not** remove that disk. If `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` exists, leave that disk attached and contact the operator. Inspect `last-external-<DISK_NAME>.json`, `events-external.log`, `backup.log`, and `findmnt | grep /_usbbackup`. Only remove the disk after `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` exists.

#### 10.5.1 Quick response when `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` stays present or `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` never appears
1. Confirm whether `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` exists. If yes, leave the disk attached and switch to operator diagnostics; do not let the user remove the disk.
2. Check whether the USB backup disk is still mounted under `/_usbbackup/<UUID>` (`findmnt | grep /_usbbackup`). If it is still mounted, treat the disk as not yet safe to remove.
3. Read `last-external-<DISK_NAME>.json` for the last structured result of that disk and `events-external.log` for the recent event sequence.
4. Inspect `/var/log/${HOST_SCOPE_NAME}/backup/backup.log` for the underlying restic/mount/systemd error.
5. Only treat the disk as safe to remove after the READY file exists **and** the USB mount is gone.

#### 10.5.2 Interrupted external run (early disk removal, power loss, or reboot)
1. Treat the interrupted run as **incomplete** unless `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` had already been shown for that same disk.
2. For the dashboard-only Backup Disk Operator, the default next user-facing state after such a detached incomplete run is `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt`: reattach the same disk and wait for the next retry (normally on reinsert when USB autorun is enabled, which is the current default).
3. The SSH/admin Operator should inspect the per-disk dashboard files, `last-external-<DISK_NAME>.json`, `events-external.log`, and `backup.log` before assuming that the retry is safe.
4. Penelope may perform a **controlled stale-lock recovery** automatically only when all of the following are true:
   - `restic snapshots --json --no-lock` can read the repo,
   - no live `restic` process still uses that repo,
   - `restic unlock` succeeds,
   - `restic check --no-lock` succeeds afterwards.
5. If that gate succeeds, the next trigger may continue with a normal backup run.
6. If that gate fails, or if the repo still fails `check --no-lock`, stop automatic retries and make an explicit operator decision:
   - continue only with repo-level diagnostics/repair,
   - keep the disk attached while a hold signal exists,
   - do **not** treat `unlock` alone as proof that the repository is healthy.
7. A host reboot should clear Penelope runtime state sufficiently for the next trigger to start again, but it does **not** by itself prove that the interrupted repo is healthy; the repository health gate still decides whether writes continue.

#### 10.5.3 Operator decision table for interrupted or failed external runs
Use this table after early USB removal, power loss, an external-run reboot, or any run that leaves a per-disk hold signal behind.

| Situation | What it means | Operator action | Automatic retry allowed? |
|---|---|---|---|
| `USB_BACKUP_READY_TO_REMOVE_<DISK_NAME>.txt` exists, `USB_BACKUP_DO_NOT_REMOVE_<DISK_NAME>_CONTACT_OPERATOR.txt` does not exist, and the disk is no longer mounted under `/_usbbackup/<UUID>` | The external run finished cleanly for that disk and the user-facing removal signal is complete. | The disk may be removed and stored securely. No repo-level recovery work is needed. | Not needed. |
| `USB_BACKUP_RUNNING_DO_NOT_REMOVE_<DISK_NAME>.txt` still exists, or the disk is still mounted, or a live `restic` process still uses that repo | The run may still be active or the cleanup phase is not complete yet. This is **not** a stale-lock case yet. | Do **not** remove the disk. Do **not** run `restic unlock`. Inspect `findmnt`, the recent logs, and the live process state first. | No. Wait or investigate first. |
| `USB_BACKUP_REATTACH_AND_WAIT_<DISK_NAME>.txt` exists for that disk and the controlled stale-lock recovery gate passes (`restic snapshots --json --no-lock`, no live repo process, `restic unlock`, `restic check --no-lock`) | The interrupted detached-disk case is still within the narrow self-healing path. | Reattach that same disk and allow the next normal retry to proceed. | Yes. |
| `restic unlock` fails, or a live process still appears for the same repo, or lock ownership is still ambiguous | Exclusion is not proven. Unlocking would risk interfering with a still-active writer or with an unresolved ownership problem. | Stop automatic retries. If the disk is still present, keep it attached while a hold signal exists. Investigate process ownership / lock ownership before trying again. | No. |
| `restic snapshots --json --no-lock` is unreadable, or `restic check --no-lock` fails after unlock, or the disk stays in `*_CONTACT_OPERATOR.txt` hold state | The problem is no longer just a stale lock; repository health or I/O integrity is now in doubt. | Treat this as an explicit operator decision point. Continue only with repo diagnostics/repair or other incident handling. Do **not** treat `unlock` alone as recovery. | No. |

**Boundary rule:** Penelope automates only the narrow stale-lock recovery path above. Anything beyond that boundary is an operator decision, not a silent best-effort repair path.

### 10.6 Script preflight (required)
A syntax error in an installer is a hard fail and costs test cycles. Before a productive run:
```bash
bash -n penelope-install-<version>.sh
shellcheck penelope-install-<version>.sh
```
If `shellcheck` is missing on your environment, install it first (Ubuntu):
```bash
sudo apt-get update && sudo apt-get install -y shellcheck
```

#### Versioning rules (collaboration)
- If an artifact with version `a.b.x` is changed, bump to `a.b.(x+1)`.
- No suffixes like `-fixed` – every fix is a new numeric version.
- Unless explicitly requested otherwise, base new work on the **latest delivered** version.

---

### 10.7 Troubleshooting penelope-install failures (quick commands)

If `penelope-install` aborts (including fail-fast verification aborts from the current per-check validation policy), the fastest way to diagnose is to capture the current disk and mount state and relevant system logs.

Run these commands from the Live environment:

```bash
# Disk layout and filesystems
lsblk -f
blkid
sudo sgdisk -p <DISK_SYS>
sudo sgdisk -p <DISK_DATA>

# Mount state (automount/busy mounts)
findmnt
mount | grep -E '/_backup|/_archive|/home|/boot|/boot/efi' || true

# Recent installer output (if logged) and system messages
dmesg --color=never | tail -n 200
journalctl -b --no-pager | tail -n 200
```

If the failure concerns Dropbear/initramfs verification, prefer the install bundle's non-destructive fast-iteration path instead of manually retyping the rebuild commands:

```bash
sudo -E ./penelope-install-<version>.sh --initramfs-only
```

Or target one installed kernel explicitly:

```bash
sudo -E ./penelope-install-<version>.sh --initramfs-only --kver <kernel-version>
```

This mode rebuilds initramfs, runs `lsinitramfs` inventory capture, logs the updated initrd paths, and persists a small manifest/log bundle under `/var/log/<host>/install/`.

## Appendix A: Files and locations (overview)

Quick reference for key paths created by the bundles. Use this when triaging logs, credentials, and dashboard artifacts.

- Installation script (Live-USB): `./penelope-install-<version>.sh` (from inside the runnable bundle/workdir)
- Artifacts (beside the effective bootstrap-config used for the install run):
  - `<bootstrap-config-dir>/${TARGET_HOST}_unlock_keys.7z`
  - `<bootstrap-config-dir>/${ADMIN_USER}_ssh_keys.7z`
- System scripts (installed system):
  - `/usr/local/sbin/penelope-backup.sh`
  - `/usr/local/sbin/${TARGET_HOST}-firstboot.sh`
- System config (current scripts):
  - restic password files: `/root/.config/restic/{system_pw,home_pw,_archive_pw}` (see 7.7)
- Logs (recommended host-scoped convention):
  - initramfs: `/var/log/${TARGET_HOST}/initramfs/`
  - install: `/var/log/${TARGET_HOST}/install/`
  - backup: `/var/log/${HOST_SCOPE_NAME}/backup/`
- Operator config tree:
  ```text
  /etc/penelope/
    backup.conf
    backup-setup/
      backup-setup.conf
      secrets.d/{system.secret,home.secret,_archive.secret}
      examples/
        backup-setup.conf.example
        secrets.d/{system.secret.example,home.secret.example,_archive.secret.example}
    samba-setup/
      samba-setup.conf
      users.d/*.conf
      shares.d/*.conf
      secrets.d/*.secret
      examples/
        samba-setup.conf.example
        users.d/*.conf.example
        shares.d/*.conf.example
        secrets.d/*.secret.example
    usb-backup-disks.conf
  ```
  Active backup bootstrap state lives directly under `backup-setup/`; backup
  examples live under `backup-setup/examples/`. Active Samba state lives in
  `users.d/*.conf` and `shares.d/*.conf`; Samba examples live under
  `samba-setup/examples/`. Files under these `examples/` directories are not loaded
  as live state.

## Change log

- release candidate source line 0.0.134: public README/documentation polish; no runtime-code change