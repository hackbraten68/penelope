# Penelope Windows Server VM – implementation plan and thread handover

**Status:** reviewed design / implementation handover  
**Date:** 2026-09-08  
**Target host:** `penelope`  
**Target OS:** Ubuntu 24.04-based Penelope host  
**Purpose:** add one managed Windows Server KVM/libvirt VM to Penelope. Dragon / Findentity and other application software are installed later inside Windows and are deliberately outside the first Penelope implementation block.

---

## 1. Purpose of this document

This document is the starting point for a separate implementation thread.

That thread should create and review:

1. a new `penelope-windows-vm-setup-<version>.sh` bundle,
2. the minimum required `penelope-backup-setup` integration,
3. Penelope-specific guideline changes,
4. documentation changes,
5. walkthrough-assistant changes,
6. README / release-bundle navigation updates,
7. static and target-host validation for the new domain.

This is a **design and scope handover**, not finished code.

The implementation must preserve the existing Penelope operating model:

```text
write-config
    -> operator edits external config
verify-config
    -> non-destructive validation
apply
    -> reconcile/install managed runtime state
```

The new domain must remain clearly separate from:

- destructive bare-metal installation (`penelope-install`),
- backup-domain ownership (`penelope-backup-setup`),
- Samba-domain ownership (`penelope-samba-setup`),
- Windows/application administration inside the guest.

---

## 2. Reviewed project baseline

The supplied `penelope-rc01` source line contains:

| Artefact | Reviewed version |
|---|---:|
| `penelope-install` | `0.9.400` |
| `penelope-backup-setup` | `0.3.449` |
| `penelope-samba-setup` | `0.1.150` |
| `penelope-common` | `1.5.25` |
| `penelope-walkthrough-assistant` | `0.0.51` |
| `penelope-documentation` | `0.0.385` |
| `penelope-guidelines` | `0.0.269` |

The new work must use these exact full files as the operative baseline unless a newer operator-approved baseline is supplied in the implementation thread.

### Relevant existing Penelope contracts

Penelope currently treats these as canonical logical storage roles:

```text
/
/home
/_archive
/_backup
```

For the shipped default `two-disk` profile:

```text
DISK_SYS  ~= 2 TB
  /boot/efi
  /boot
  /          ~220 GiB
  /home      remaining capacity

DISK_DATA ~= 4 TB
  /_archive  ~1 TiB, LUKS2 encrypted
  /_backup   remaining capacity, unencrypted
```

The existing backup runner creates separate Restic repositories for:

```text
system
home
_archive
```

`/_archive` is therefore a normal backup source.

Important consequence: in the default two-disk profile, `/_archive` and `/_backup` are partitions on the **same physical `DISK_DATA` device**. Internal Restic backup protects against many logical failures, but does **not** provide physical-disk-failure independence for archive data. External USB backup remains required for off-device protection.

---

## 3. Reviewed architecture decision

### Decision `PENELOPE-WINDOWS-VM-001`: separate live VM state from backup-safe VM artefacts

**Scope:** Windows VM storage and Penelope backup integration.  
**Affected artefacts:** new Windows VM setup bundle, backup setup, guidelines, documentation, walkthrough.  
**Baseline contract change:** yes; introduces one explicitly excluded runtime subtree inside the existing `/_archive` backup source.

### Chosen layout

```text
/_archive/.penelope/windows-vm/
|
+-- runtime/                         # NOT backed up by normal _archive Restic runs
|   |
|   +-- live/
|   |   +-- win-findentity.qcow2    # active VM disk
|   |
|   +-- staging/                    # incomplete VM backup construction
|
+-- backup-source/                   # normal _archive backup source; IS backed up
    |
    +-- baselines/
    |   +-- activated-clean/
    |   +-- pre-thax/
    |   +-- production-clean/
    |
    +-- backups/
        +-- <timestamp-or-label>/
```

The exact baseline names are operator choices; the names above describe the intended lifecycle.

### Why this is preferred

Do **not** place the active 120 GiB VM image on `/` by default:

- the current root contract is only about 220 GiB,
- a Windows VM expected to have roughly 100 GiB available can consume too much of root,
- root pressure would affect the entire file server.

Do **not** place the active VM on `/_backup`:

- `/_backup` is intentionally unencrypted,
- it is the local Restic/recovery area, not application runtime storage,
- a Windows server disk can contain credentials, application data and sensitive documents.

Do **not** let Restic directly read the active QCOW2 file:

- a changing virtual disk copied as a normal file is not a reliable point-in-time guest backup,
- later SQL Server / Dragon / Findentity activity makes consistency more important,
- external USB backups may start independently of VM maintenance activity.

Do **not** exclude the complete Windows VM tree from `/_archive` backup.

Only this subtree is excluded:

```text
/_archive/.penelope/windows-vm/runtime
```

Completed, verified VM backup artefacts are atomically published under:

```text
/_archive/.penelope/windows-vm/backup-source
```

and are therefore picked up by the existing `/_archive` Restic target.

### Atomic publish rule

A VM backup must be built under the excluded `runtime/staging` tree first.

Only after all required files exist and validation/checksums succeed may the completed directory be renamed into `backup-source`.

Because staging and destination are on the same filesystem, directory rename can be used as the publication boundary.

Restic must never see a half-written VM backup directory as a valid published backup.

---

## 4. Backup model

### 4.1 First implementation: cold consistent backups

The first implementation should use **graceful guest shutdown + offline disk copy** for named baselines and manual production backups.

This deliberately favours correctness and implementation simplicity over zero-downtime operation.

Expected operation:

```text
baseline-create / backup-create
    |
    +-- detect whether VM was running
    +-- request graceful virsh shutdown
    +-- wait for clean shut-off
    +-- NEVER force virsh destroy automatically
    +-- capture domain metadata
    +-- create standalone disk copy under runtime/staging
    +-- capture UEFI/NVRAM state
    +-- capture TPM state only if TPM is explicitly enabled
    +-- create manifest + hashes
    +-- validate backup
    +-- atomically publish into backup-source
    +-- restart VM only if it was running before the operation
```

If graceful shutdown does not complete within the configured timeout, the operation must fail safely. It must not silently escalate to `virsh destroy`.

### 4.2 Why live backup is not the first implementation

Ubuntu 24.04 has a sufficiently recent libvirt/QEMU generation for libvirt's modern backup API (`virDomainBackupBegin` / `virsh backup-begin`). Upstream libvirt documents push- and pull-mode full/incremental backup support, with modern full push backup requiring libvirt >= 7.2 and QEMU >= 4.2.

That makes a future live-backup implementation technically viable.

It should still be deferred until the actual Windows application stack is known, because:

- SQL Server may require application-aware/VSS-consistent handling,
- Dragon / Findentity may have service-level consistency requirements,
- a hypervisor point-in-time copy is not automatically equivalent to application-consistent backup,
- the first Penelope implementation should avoid premature checkpoint/bitmap complexity.

**Future enhancement:** evaluate QEMU Guest Agent + Windows/VSS + `virsh backup-begin` only after the production application stack exists and a restore test can prove the chosen semantics.

### 4.3 Baseline semantics

Named baselines are immutable operator checkpoints.

Recommended lifecycle:

```text
activated-clean
    Windows Server installed
    VirtIO drivers installed
    Windows updated
    Windows activated
    basic networking/RDP working
    no Dragon/Findentity yet

pre-thax
    Windows prerequisites prepared
    immediately before Thax/application installation

production-clean
    Dragon/Findentity/application stack installed and proven working
```

A baseline command must refuse to overwrite an existing baseline name.

### 4.4 Manual rolling backups

The same cold-backup engine may expose a separate command such as:

```bash
sudo -E ./penelope-windows-vm-setup-<version>.sh backup-create
```

It should create a unique timestamped/labelled backup under:

```text
/_archive/.penelope/windows-vm/backup-source/backups/
```

Do **not** introduce an automatic recurring VM shutdown timer in the first patch series. Downtime scheduling should be an explicit later decision after Dragon/Findentity is running.

### 4.5 What a complete VM backup contains

At minimum:

```text
<backup>/
+-- win-findentity.qcow2
+-- domain.xml
+-- domain.uuid
+-- domblklist.txt
+-- qemu-img-info.json
+-- nvram.fd                       # when UEFI/NVRAM exists
+-- network-host.xml               # managed host-only libvirt network definition
+-- manifest.json
+-- SHA256SUMS
+-- tpm/                           # only when TPM explicitly enabled
```

The backup must preserve enough identity/configuration to maximise restoration as the **same VM**:

- domain UUID,
- NIC MAC addresses,
- virtual hardware definition,
- UEFI/NVRAM,
- TPM state if used,
- disk image.

This improves activation continuity, but the documentation must **not promise** that Windows will never request reactivation after a physical-host/hardware change.

The Windows product key itself must not be written to Penelope config, logs, manifests or backup metadata.

### 4.6 Backup verification

At minimum a completed backup should pass:

```text
SHA256 checksum generation/verification
qemu-img info
qemu-img check
presence/schema checks for manifest
presence of domain XML + UUID
presence of NVRAM when domain XML references NVRAM
presence of TPM state when TPM is enabled
```

A non-destructive command should be provided:

```bash
sudo -E ./penelope-windows-vm-setup-<version>.sh backup-verify <backup-or-baseline>
```

### 4.7 Restore policy for the first implementation

Do not add an automatic destructive `restore` command in the first patch merely for completeness.

The first release should provide:

- verified complete backups,
- a documented manual restore procedure,
- optionally a non-destructive `restore-plan` / inspect command.

An automated restore path should be a separate later patch after one manual restore/boot proof has established the exact domain/NVRAM/storage mechanics on Penelope.

### 4.8 Required off-device proof

A new baseline is not considered disaster-recovery-protected merely because it exists under `/_archive`.

Acceptance sequence for important baselines:

```text
create baseline
    -> run/await internal Restic backup
    -> verify internal backup
    -> run external USB backup
    -> verify external backup
    -> prove the baseline path exists in the external _archive repository snapshot
```

This matters especially on the default two-disk layout because `/_archive` and `/_backup` share `DISK_DATA`.

---

## 5. Network design

### Decision `PENELOPE-WINDOWS-VM-002`: do not rewrite Penelope host networking in v1

**Scope:** guest LAN connectivity.  
**Affected artefacts:** new Windows VM setup, documentation, walkthrough.  
**Baseline contract change:** no host network-layout rewrite.

The first design proposed a traditional host bridge (`br0`) and Netplan changes.

For Penelope this has unnecessarily high blast radius:

- the host is remotely operated,
- SSH, Samba and remote unlock are critical,
- a bridge misconfiguration can disconnect the whole server.

### Preferred v1 network model

Use two guest NICs:

```text
Windows VM
|
+-- NIC 1: macvtap/direct, mode=bridge
|          attached to the explicitly configured physical LAN NIC
|          -> LAN clients can reach the Windows VM directly
|          -> Windows gets normal LAN IP/DHCP/static configuration
|
+-- NIC 2: Penelope-managed isolated libvirt network
           -> host/guest-only communication
           -> Windows reaches Ubuntu/Samba through host-only IP
```

Example host-only network:

```text
network name: penelope-vm-host
host IP:      192.168.254.1/24
Windows IP:   192.168.254.2/24
Windows gateway on this NIC: none
Windows DNS on this NIC:     none
```

The exact subnet must be configurable and validated against current host routes.

### Why two NICs are required

Libvirt documents a macvtap/direct limitation: a guest connected directly to the physical interface can communicate with the physical LAN, but cannot directly communicate with its virtualization host through that macvtap path.

The second isolated libvirt network is therefore intentional, not redundant.

The Windows VM can use:

```text
\\192.168.254.1\<Penelope-Samba-share>
```

for host-resident data while LAN clients use the VM's normal LAN address.

### Safety rules

- `VM_LAN_INTERFACE` must be an explicit operator config value; do not guess and silently apply.
- `verify-config` must confirm that the interface exists and is suitable before `apply` defines the VM.
- The script must not edit Netplan in v1.
- The script must not move the Penelope host IP to a bridge in v1.
- The host-only subnet must not overlap existing host routes.
- Fixed VM MAC addresses must be persisted in config or domain state and preserved on reruns/restores.

If macvtap proves incompatible with the site's switch/network, a traditional host bridge can be designed later as an explicit separate network migration, not as an invisible side effect of VM setup.

---

## 6. New script: `penelope-windows-vm-setup`

### 6.1 Canonical role

`penelope-windows-vm-setup` is the rerunnable domain owner for:

- Ubuntu KVM/QEMU/libvirt prerequisites,
- one Penelope-managed Windows Server VM definition,
- VM-specific host networking,
- VM runtime/storage directories,
- VM lifecycle inspection/basic control,
- consistent VM backup/baseline creation,
- VM backup verification.

It is **not** the owner of:

- bare-metal disk provisioning,
- Penelope Restic repository semantics,
- Samba user/share policy,
- Windows product activation logic,
- Windows patch management,
- Dragon,
- Findentity,
- Word,
- SQL Server,
- application-specific Windows configuration.

### 6.2 Suggested initial filename/version

New artefact:

```text
penelope-windows-vm-setup-0.1.0.sh
```

Use the project versioning rules in the implementation thread; `0.1.0` is the proposed initial domain version, not permission to skip predecessor/full-file review requirements for other touched artefacts.

### 6.3 Bundle rule

The new setup bundle follows the existing two-file setup pattern:

```text
penelope-windows-vm-setup-<version>.sh
penelope-common.sh
```

The script sources the sibling:

```text
${SCRIPT_DIR}/penelope-common.sh
```

and should install/refresh the common library only if the project-level ownership review concludes that this new domain should do so consistently with the other running-system setup bundles.

Do not duplicate general helper functions that already belong in `penelope-common`.

### 6.4 External config tree

Canonical path:

```text
/etc/penelope/windows-vm-setup/
```

Suggested contents:

```text
/etc/penelope/windows-vm-setup/
+-- windows-vm-setup.conf
+-- examples/
    +-- windows-vm-setup.conf.example
```

No secret file is required for the first implementation.

The Windows product key must remain outside this tree.

Suggested initial config keys:

```bash
config_schema_version="1"

VM_NAME="win-findentity"
VM_VCPUS="4"
VM_MEMORY_MIB="12288"
VM_DISK_SIZE_GIB="120"
VM_CPU_MODE="host-passthrough"
VM_AUTOSTART="no"

VM_RUNTIME_BASE="/_archive/.penelope/windows-vm/runtime"
VM_BACKUP_SOURCE_BASE="/_archive/.penelope/windows-vm/backup-source"

WINDOWS_ISO_PATH="/var/lib/penelope/windows-vm/iso/windows-server.iso"
VIRTIO_ISO_PATH="/var/lib/penelope/windows-vm/iso/virtio-win.iso"
VM_OS_VARIANT="win2k22"

VM_LAN_INTERFACE="REPLACE_ME"
VM_HOST_NETWORK_NAME="penelope-vm-host"
VM_HOST_NETWORK_CIDR="192.168.254.0/24"
VM_HOST_NETWORK_HOST_IP="192.168.254.1"
VM_HOST_NETWORK_GUEST_IP="192.168.254.2"

VM_TPM_ENABLED="no"
VM_SHUTDOWN_TIMEOUT_SECONDS="300"
```

Exact key names may be refined in implementation, but the semantics above should remain stable unless the implementation review finds a concrete reason to change them.

### 6.5 `write-config`

Expected behaviour:

- create the external config tree,
- seed package-owned example(s),
- preserve an existing current-schema operator config,
- append newly introduced known keys with defaults on later versions,
- never overwrite operator values silently,
- exit before provisioning or VM mutation.

### 6.6 `verify-config`

Must be non-destructive.

Verify at least:

#### Host/KVM

- Ubuntu supported target context,
- `/dev/kvm` exists,
- CPU exposes virtualization support,
- required commands/packages are available or can be installed by `apply`,
- `virt-host-validate qemu` result is reviewed appropriately,
- libvirt connection can be inspected.

#### Storage

- `/_archive` exists and is mounted,
- `/_archive` is the expected Penelope logical role,
- sufficient free capacity for live disk + staging + at least one backup copy,
- runtime path and backup-source path are not equal/nested incorrectly,
- runtime path is inside the expected excluded subtree,
- backup-source path is outside the excluded subtree,
- `/_backup` is not selected for live VM storage.

#### Backup integration

Before creating the live VM, verify that the installed/current backup runner contract excludes:

```text
/_archive/.penelope/windows-vm/runtime
```

A mismatch should fail closed rather than risk backing up a changing live QCOW2 file as normal archive data.

#### Media

- Windows ISO exists and is a regular readable file,
- VirtIO ISO exists and is a regular readable file,
- no automatic Windows ISO download is performed.

#### VM identity

- VM name valid,
- configured MACs valid/unique where applicable,
- existing libvirt domain with the same name is either:
  - clearly the already-managed same VM, or
  - a conflict that requires explicit operator resolution.

Do not silently redefine an unrelated existing domain.

#### Network

- configured physical LAN interface exists,
- interface is not loopback,
- host-only CIDR parses correctly,
- host-only CIDR does not overlap existing host routes,
- libvirt network name does not collide with an incompatible existing definition.

#### Resource sanity

- vCPU count plausible for current host,
- configured RAM leaves a meaningful reserve for Penelope file/backup services,
- disk size is positive and reasonable,
- resource checks warn/fail according to actual host capacity rather than assuming every Penelope host has 32 GiB RAM.

### 6.7 `apply`

Expected v1 responsibilities:

1. install required virtualization packages,
2. enable/start libvirt as required,
3. create managed directories with restrictive ownership/modes,
4. define/start the isolated host-only libvirt network,
5. create the QCOW2 disk only if it does not already exist,
6. define the VM only if it is absent or already safely managed,
7. attach the Windows and VirtIO install media,
8. leave the VM stopped unless the operator explicitly starts it,
9. print next inspection/start commands.

Suggested package family:

```text
qemu-kvm
qemu-system-x86
qemu-utils
libvirt-daemon-system
libvirt-clients
virtinst
ovmf
cpu-checker                  # optional if retained by project
swtpm / swtpm-tools          # only if TPM support is enabled/needed
```

`bridge-utils` is not required for the preferred macvtap + isolated-network v1 design.

### 6.8 VM defaults

Proposed initial VM defaults:

| Resource | Default |
|---|---:|
| vCPU | 4 |
| RAM | 12 GiB (`12288 MiB`) |
| disk | 120 GiB QCOW2 |
| machine | Q35 |
| firmware | UEFI / OVMF |
| disk/network drivers | VirtIO |
| graphics during install | localhost-only VNC or equivalent libvirt console |
| TPM | disabled by default unless a concrete requirement exists |
| autostart | disabled until Windows install is complete |

Do not hard-code the assumption that every Penelope host has 32 GiB RAM; validate actual host memory.

### 6.9 Useful operator commands

The first script surface should be deliberately small.

Recommended commands:

```text
write-config
verify-config
apply
status
start
shutdown
enable-autostart
disable-autostart
baseline-create NAME
backup-create [LABEL]
backup-verify TARGET
```

Optional but useful non-destructive command:

```text
restore-plan TARGET
```

Do not add broad VM-manager functionality that duplicates `virsh` without Penelope-specific value.

### 6.10 Lifecycle safety

- Never use `virsh destroy` automatically.
- Never delete an existing VM disk during normal `apply`.
- Never replace a non-empty QCOW2 disk because config changed.
- Never overwrite an existing baseline name.
- Never silently regenerate UUID/MAC/NVRAM for an existing managed VM.
- Never enable autostart before the operator requests it.
- Never download or store Windows license keys.
- Never patch host Netplan in v1.
- Never perform application installation inside Windows.

---

## 7. `penelope-backup-setup` change

### Decision `PENELOPE-WINDOWS-VM-003`: backup setup remains owner of Restic exclusion semantics

The Windows VM setup script must **not** patch the installed Restic runner ad hoc.

`penelope-backup-setup` remains the domain owner of backup source/exclude semantics.

### Minimal required backup change

For the `_archive` target, add exactly the runtime exclusion contract:

```text
--exclude=/_archive/.penelope/windows-vm/runtime
```

The current `_archive` target otherwise remains unchanged.

Completed `backup-source` data must remain included.

### Why a fixed path is preferable in this first implementation

A generic operator-editable exclude plug-in system would increase the risk that important archive trees become silently unprotected.

The first implementation should therefore use the narrow project-defined runtime path above rather than introducing arbitrary user-configurable archive exclusions merely to support this VM.

A general exclude-drop-in architecture can be reconsidered only if a second real Penelope use case requires it.

### Verification requirements for backup setup

The backup-setup patch must prove that:

- system target behaviour is unchanged,
- home target behaviour is unchanged,
- `_archive` still backs up normal archive data,
- Windows VM `runtime` is excluded,
- Windows VM `backup-source` is included,
- no source/repository recursion guard is weakened,
- generated runner validation still passes.

### Recovery-bundle integration

Preferred integration:

- `penelope-windows-vm-setup` stages a non-secret copy of itself in the Penelope recovery-stage directory,
- successful backup sync may include `penelope-windows-vm-setup.sh` as an optional recovery tool,
- absence before the Windows VM domain has ever been configured is informational, not fatal,
- `/etc/penelope/windows-vm-setup` remains canonical live config and is restored from the **system** backup; `_recovery` is tooling-only,
- effective VM disk backups come from the `_archive` Restic repository, not from `_recovery`.

If adding this cleanly requires touching the generated `penelope-verify-security.sh` contract in `penelope-install`, treat that as a separate small patch block rather than hiding it inside unrelated changes.

---

## 8. Windows installation boundary

After Penelope creates the VM, Windows installation is an operator phase.

Expected flow:

```text
penelope-windows-vm-setup apply
    -> start VM
    -> Windows Server installation
    -> VirtIO storage/network drivers
    -> Windows updates
    -> Windows LAN NIC configuration
    -> host-only NIC = configured guest IP, no gateway/DNS
    -> RDP administration enabled as intended
    -> Windows activation
    -> baseline-create activated-clean
    -> internal Penelope backup + verify
    -> external USB Penelope backup + verify
```

Only after `activated-clean` is protected should application preparation begin.

### Explicitly later

Dragon / Findentity / Word / SQL Server and related security exclusions are installed **later inside the Windows VM**.

That work must not be embedded into the host-side Penelope VM setup script.

Recommended later sequence:

```text
activated-clean
    -> Windows prerequisites / Word / SQL preparation as required
    -> pre-thax baseline
    -> Thax / Dragon / Findentity installation
    -> functional test
    -> production-clean baseline
    -> external backup proof
```

Application-specific service shutdown/VSS semantics for recurring production backups should be designed only after this stack is known.

---

## 9. Guidelines changes – project-specific section

The implementation thread should update **`penelope_specific`**, not duplicate general workflow rules.

### 9.1 `project_architecture.components`

Add entries for:

```text
penelope-windows-vm-setup
    Rerunnable KVM/libvirt Windows VM domain owner on an installed Penelope host.

penelope-windows-vm backup/baseline helper semantics
    Consistent guest backup publication into the normal _archive backup source.
```

### 9.2 `script_operation_governance.applies_to`

Add:

```text
penelope-windows-vm-setup
```

### 9.3 `script_role_matrix`

Add a `penelope_windows_vm_setup` role.

Canonical role:

- rerunnable virtualization/managed-VM domain owner on an installed system,
- not a bare-metal installer,
- not a Windows application installer.

Preferred operation classes:

```text
fresh_bring_up
inspect
apply_config_changes
upgrade_tooling
recover_or_reattach
```

Explicit lifecycle actions such as VM backup/baseline creation should be named operator actions, not hidden `apply` side effects.

### 9.4 New project-specific section: `windows_vm_rules`

This should be the canonical owner for Penelope-only VM semantics.

Recommended normative content:

#### Storage

- live VM disk must reside under `/_archive/.penelope/windows-vm/runtime` unless an explicit later architecture decision replaces this contract,
- runtime subtree is excluded from normal `_archive` Restic backup,
- completed VM backup artefacts are published under `/_archive/.penelope/windows-vm/backup-source`,
- incomplete/staging data must never be published into backup-source,
- `/_backup` must not host the live Windows disk because it is unencrypted and backup-domain storage.

#### Backup

- first implementation uses graceful-shutdown cold backups,
- no automatic force-stop fallback,
- baseline names are immutable,
- backup publication requires validation/checksums,
- important baselines require an external USB backup proof before being called off-device protected,
- direct Restic backup of the active QCOW2 is prohibited.

#### Network

- v1 must not rewrite Netplan or host bridge state,
- preferred v1 uses direct/macvtap LAN + isolated host-only second NIC,
- physical LAN NIC is explicit operator config,
- host-only subnet must be collision-checked,
- domain identity/MACs are stable state.

#### Windows/application boundary

- product keys are never Penelope config/secrets,
- Windows installation/activation is operator work inside the guest,
- Dragon/Findentity/Word/SQL are out of host-side setup scope,
- no guarantee that restored Windows will never request reactivation after physical hardware change.

#### Restore

- v1 requires documented manual restore + non-destructive backup verification,
- destructive automatic restore is deferred until a manual restore proof exists.

### 9.5 `layout_invariant`

Do **not** add a new top-level mount such as `/_vm` in this patch.

The existing logical mount contract remains unchanged.

### 9.6 `backup_upgrade_rules`

Add the fixed `_archive` VM runtime exclusion contract and its verification requirement.

Do not duplicate the full VM backup policy here; cross-reference `windows_vm_rules`.

### 9.7 `recovery_bundle_model`

If recovery-stage integration is implemented:

- optional `penelope-windows-vm-setup.sh` tooling copy,
- never include product keys or application credentials,
- live config restored from system repo,
- VM backups restored from `_archive` repo.

### 9.8 `operator_walkthrough_documentation`

Extend normal installed-system cadence for hosts using the optional Windows VM domain:

```text
firstboot
-> early verify
-> backup setup / verify
-> Samba setup / verify
-> Windows VM setup / verify
-> Windows installation
-> activated-clean baseline
-> internal backup verify
-> external backup verify
-> final combined host checks
```

The Windows VM step must remain clearly conditional/feature-specific if Penelope continues to support hosts without this VM.

### 9.9 `bundling`

Add the new setup bundle:

```text
penelope-windows-vm-setup-X.Y.Z.sh + penelope-common.sh
```

Apply the same filename/internal-version/generated-artefact alignment rules.

### 9.10 `release_bundle_policy`

Define whether `penelope-windows-vm-setup` is a single-file setup bundle that emits persistent helper/network/runtime artefacts.

Any generated persistent shell/config/systemd/libvirt XML artefact must follow the existing validation/version-stamping policy appropriate to its type.

Do not copy general artefact-validation text into the new section; cross-reference the existing canonical rules.

---

## 10. Documentation changes

Update `penelope-documentation` as one coherent operator-facing change.

### 10.1 Version table and scope

Add the current Windows VM setup version to:

```text
Current tool versions (release bundle)
```

Extend document scope to include the optional managed Windows Server VM.

### 10.2 Bundle structure

Add:

```text
Windows VM setup bundle:
- penelope-windows-vm-setup-<version>.sh
- penelope-common.sh
```

### 10.3 Typical workflows

Add a new workflow section after backup/Samba bring-up, for example:

```text
1.x Add the Windows Server VM on an installed Penelope host
```

Cover:

1. `write-config`,
2. edit config,
3. `verify-config`,
4. `apply`,
5. start installer,
6. Windows/VirtIO setup,
7. network setup,
8. activation,
9. `activated-clean` baseline,
10. internal backup/verify,
11. external USB backup/verify.

### 10.4 System overview

Add:

```text
Penelope Ubuntu host
|
+-- Samba / file services
+-- Restic backup
+-- KVM/libvirt
    +-- Windows Server VM
```

Make the host/application ownership boundary explicit.

### 10.5 Backup chapter

Document:

```text
/_archive/.penelope/windows-vm/runtime       excluded
/_archive/.penelope/windows-vm/backup-source included
```

Explain the distinction between:

- live VM state,
- VM baseline artefact,
- internal Restic copy,
- external USB copy.

Explicitly state the same-physical-disk caveat for the default `two-disk` layout.

### 10.6 Recovery chapter

Add a Windows VM restore subsection:

```text
restore /etc/penelope/windows-vm-setup from system backup
restore chosen VM backup directory from _archive repository
install KVM/libvirt prerequisites if necessary
restore domain XML / disk / NVRAM / TPM if applicable
preserve UUID/MACs
validate before start
start VM
check Windows activation/application state
```

The first version should be documented/manual, not presented as a fully automated restore if no such tool has been proven.

### 10.7 Security chapter

State:

- Windows disk lives on encrypted `/_archive`,
- `/_backup` remains unencrypted and does not host live guest state,
- product keys are not stored in Penelope files,
- VNC/console is localhost-only or equivalently restricted,
- RDP exposure is controlled inside Windows/network policy,
- no host Netplan rewrite in v1.

### 10.8 Troubleshooting

Add quick commands such as:

```bash
virsh list --all
virsh dominfo win-findentity
virsh domblklist win-findentity --details
virsh dumpxml win-findentity
virsh net-list --all
virsh net-dumpxml penelope-vm-host
qemu-img info <disk>
qemu-img check <backup-disk>
```

Add explicit troubleshooting for:

- `/dev/kvm` unavailable,
- wrong `VM_LAN_INTERFACE`,
- LAN can reach VM but host cannot (expected macvtap behaviour; check second NIC),
- host-only CIDR collision,
- Windows cannot see VirtIO disk,
- backup shutdown timeout,
- baseline exists but not yet protected by external backup.

### 10.9 Appendix: files and locations

Add all new canonical paths.

---

## 11. Walkthrough-assistant changes

Current helper phases remain:

```text
live-usb
installed
status
```

Do not add a new top-level phase unless implementation review proves it necessary.

### 11.1 Asset discovery

Add detection of the latest sibling:

```text
penelope-windows-vm-setup-<version>.sh
```

`status` should show it when present.

### 11.2 Installed phase

After backup and Samba bring-up/verification, print a Windows VM section when the Windows VM bundle is present.

Suggested flow:

```text
9. Prepare Windows VM host-side domain.

   sudo -E ./penelope-windows-vm-setup-<version>.sh write-config
   sudoedit /etc/penelope/windows-vm-setup/windows-vm-setup.conf
   sudo -E ./penelope-windows-vm-setup-<version>.sh verify-config
   sudo -E ./penelope-windows-vm-setup-<version>.sh apply

10. Install and activate Windows manually.

11. Create activated baseline.

   sudo -E ./penelope-windows-vm-setup-<version>.sh baseline-create activated-clean

12. Protect the baseline.

   sudo /usr/local/sbin/penelope-backup.sh --mode internal
   ... verify ...
   ... external USB backup + verify ...
```

The helper must not prompt for or store a Windows product key.

### 11.3 Conditionality

If the VM setup asset is absent, the walkthrough should not turn a previously valid non-VM Penelope host into an error state.

The Windows VM is an additional installed-system domain, not a prerequisite for all Penelope deployments unless the operator later changes that project-wide contract explicitly.

---

## 12. README changes

Add the new setup script to:

- `Start here`,
- `Current source line`,
- repository/bundle description,
- guided installed-system workflow where appropriate.

Extend the release validation path only after real target-host proof exists.

Do not claim VM validation in README before the corresponding runtime test has actually succeeded.

---

## 13. Recovery-stage / verifier integration

This should be treated as an explicit patch-block decision, not accidental scope creep.

### Preferred end state

Recovery-stage can contain:

```text
penelope-install.sh
penelope-backup-setup.sh
penelope-samba-setup.sh
penelope-windows-vm-setup.sh      # optional until configured/installed
penelope-common.sh
```

The VM setup copy is non-secret.

If `penelope-verify-security.sh` is extended:

- presence is informational before VM setup exists,
- once the local staged file exists, verify shell syntax and non-secret invariants,
- do not make Windows VM existence a universal Penelope security prerequisite.

This may require a small `penelope-install` version bump because that bundle owns the generated verifier.

If this integration is deferred, the handover/release notes must say so explicitly rather than implying the recovery bundle already contains the new tool.

---

## 14. Application layer – explicitly out of first script scope

The following belong to a later Windows/application runbook:

```text
Windows Server edition choice
Windows activation
Media Foundation
Microsoft Word
SQL Server Express / existing SQL connectivity
Dragon Professional/Legal
Findentity Back-End
Thax-specific service setup
Thax-specific antivirus/security exclusions
application users/service accounts
application backup/VSS behaviour
```

The host-side script may document prerequisites, but must not automate these in v1.

The existing intended architecture remains:

```text
Penelope Ubuntu host
  +-- Samba / Findentity data share
  +-- KVM Windows VM
        +-- Windows Server
        +-- Dragon
        +-- Findentity
        +-- Word
        +-- SQL Server as required
```

Dragon/Findentity installation occurs **after** the clean activated Windows baseline.

---

## 15. Proposed implementation patch blocks

Follow Penelope's normal small patch-block workflow rather than changing every artefact in one uncontrolled edit.

### Patch block A – architecture/guidelines seam

Goal:

- introduce `windows_vm_rules`,
- add new script role/bundle semantics,
- record storage/network/backup decisions,
- no runtime code yet.

Cheap proof:

```text
YAML parse
scope/owner review
no duplicated general rules
version bump consistency
```

### Patch block B – backup exclusion contract

Goal:

- add `_archive` runtime exclusion to `penelope-backup-setup`,
- prove backup-source remains included,
- preserve all other backup behaviour.

Cheap proof:

```text
bash -n
shellcheck
render/extract installed backup runner
grep/assert exact archive runtime exclusion
prove no new home/system exclusion
```

Target proof before acceptance:

```text
internal _archive backup while a test file exists in runtime and backup-source
runtime file absent from snapshot
backup-source file present in snapshot
```

### Patch block C – new Windows VM setup bundle

Goal:

- config scaffold,
- verify-config,
- apply,
- VM/network/storage definition,
- status/basic lifecycle,
- cold baseline/backup creation,
- backup verification.

Cheap proof:

```text
bash -n
shellcheck
write-config into temporary config dir
schema tests
rendered libvirt XML validation
no unexpanded tokens
--help/status dry paths
```

Target proof:

```text
verify-config on Penelope
apply
libvirt network exists
VM defined
Windows installer boots
```

### Patch block D – baseline/restore proof

Goal:

- create a disposable/test baseline,
- validate QCOW2/metadata,
- manually reconstruct/boot a test restore,
- refine restore documentation from actual evidence.

This is an **expensive/high-risk validation block** and should not be replaced by syntax-only tests.

### Patch block E – recovery-stage integration

Goal:

- stage non-secret VM setup copy,
- include in recovery bundle if appropriate,
- optional verifier integration.

Keep absence non-fatal on hosts where VM setup has never been used.

### Patch block F – documentation / walkthrough / README sync

Goal:

- operator workflow reflects proven behaviour only,
- current version tables updated,
- walkthrough detects new bundle,
- README navigation updated,
- no claim of runtime proof beyond what was actually tested.

---

## 16. Testing and acceptance criteria

### 16.1 Static acceptance

For every delivered script patch:

```bash
bash -n ./*.sh
shellcheck ./*.sh
```

Guidelines:

```bash
python3 - <<'PY'
import yaml
with open('penelope-guidelines-<version>.yaml', 'r', encoding='utf-8') as fh:
    yaml.safe_load(fh)
print('guidelines-yaml-ok')
PY
```

Also apply existing Penelope version/bundle checks:

- filename version = internal version,
- generated artefact version stamping aligned,
- no unexpanded `___PENELOPE_*___` placeholders,
- sibling `penelope-common.sh` contract satisfied,
- full-file predecessor diff reviewed.

### 16.2 VM setup target-host acceptance

Before Windows installation:

- [ ] `verify-config` is non-destructive and succeeds.
- [ ] KVM acceleration available.
- [ ] libvirt healthy.
- [ ] no Netplan changes performed.
- [ ] host-only libvirt network created.
- [ ] direct/macvtap NIC attached to correct physical LAN NIC.
- [ ] QCOW2 exists under VM runtime tree.
- [ ] VM domain is defined with stable UUID/MACs.
- [ ] Windows installer can see disk after VirtIO driver load.

After Windows installation:

- [ ] Windows gets expected LAN connectivity.
- [ ] LAN workstation can reach Windows VM.
- [ ] Windows reaches Penelope host over host-only NIC.
- [ ] Windows can reach required Samba share through host-only address.
- [ ] RDP administration works as intended.
- [ ] Windows activation complete.

### 16.3 Baseline acceptance

- [ ] `baseline-create activated-clean` gracefully shuts down the VM.
- [ ] no force destroy occurs.
- [ ] VM restarts only if it was running before.
- [ ] backup staged outside normal Restic source visibility.
- [ ] completed baseline atomically published.
- [ ] `qemu-img check` succeeds.
- [ ] hashes verify.
- [ ] domain UUID/MAC/NVRAM metadata captured.
- [ ] existing baseline cannot be overwritten.

### 16.4 Restic integration acceptance

With test markers:

```text
/_archive/.penelope/windows-vm/runtime/test-do-not-back-up
/_archive/.penelope/windows-vm/backup-source/test-must-back-up
```

After internal `_archive` backup:

- [ ] runtime marker absent from Restic snapshot.
- [ ] backup-source marker present.
- [ ] normal archive files still present.
- [ ] backup verification succeeds.

After external USB backup:

- [ ] important VM baseline present in external `_archive` repo snapshot.
- [ ] external backup verify succeeds.

### 16.5 Restore acceptance before production

Perform at least one real restore proof before calling the VM backup design production-ready:

- [ ] restore selected backup to test location,
- [ ] verify hashes and `qemu-img check`,
- [ ] define/reconstruct a VM from preserved metadata without destroying production VM,
- [ ] boot restored Windows,
- [ ] confirm guest filesystem/boot health,
- [ ] record activation behaviour,
- [ ] refine documentation based on actual restore evidence.

---

## 17. Explicit non-goals for the first implementation

Do not add these merely because they are possible:

- Docker-based Windows,
- PCI/USB microphone passthrough,
- GPU passthrough,
- Netplan/host bridge migration,
- automatic Windows ISO download,
- Windows unattended installation with embedded product key,
- Dragon/Findentity automation,
- SQL-aware live backup before application testing,
- incremental bitmap backup chains,
- automatic destructive VM restore,
- automatic nightly guest shutdown without an operator-approved maintenance window,
- new `/_vm` partition/layout profile.

These can be revisited only with a concrete requirement.

---

## 18. Open target-host facts to verify during implementation

These are validation inputs, not reasons to redesign the architecture in advance:

- actual CPU model and virtualization flags,
- actual host RAM,
- actual physical LAN interface name,
- actual free space on `/_archive`,
- current libvirt/QEMU package versions after Ubuntu updates,
- whether the LAN/switch accepts the additional macvtap guest MAC,
- chosen Windows Server release/edition and ISO path,
- whether TPM is actually required,
- actual time needed to create a cold 120 GiB sparse QCOW2 backup,
- acceptable application downtime once Dragon/Findentity is in production.

If macvtap is rejected by the actual LAN environment, stop and create a separate explicit network-design patch. Do not fall back automatically to rewriting host bridge/Netplan state.

---

## 19. Recovery model summary

The desired recovery chain is:

```text
Penelope bare-metal recovery
    |
    +-- restore system
    |     +-- /etc/penelope/windows-vm-setup
    |     +-- libvirt/host prerequisites recreated by setup bundle
    |
    +-- restore _archive
          +-- .penelope/windows-vm/backup-source/<chosen backup>

then

penelope-windows-vm-setup verify-config / apply
    -> inspect restore plan
    -> restore disk + XML + NVRAM (+ TPM if used)
    -> preserve UUID/MAC
    -> start VM
    -> verify Windows
    -> verify activation
    -> verify Dragon/Findentity when installed
```

The live runtime QCOW2 is intentionally **not** the recovery source.

The recovery source is a completed, validated VM backup that was subsequently captured by Penelope Restic and, for real physical-disk protection, by external USB backup.

---

## 20. Final architecture

```text
                         LAN clients
                             |
                             | Windows VM LAN IP
                             v
+------------------------------------------------------------------+
| Penelope Ubuntu host                                             |
|                                                                  |
|  Samba / files / Restic                                          |
|                                                                  |
|  /_archive (LUKS2)                                               |
|  |                                                               |
|  +-- normal archive data --------------------------+              |
|  |                                                 |              |
|  +-- .penelope/windows-vm/                         |              |
|      |                                             |              |
|      +-- runtime/                 EXCLUDED         |              |
|      |   +-- live/*.qcow2                          |              |
|      |   +-- staging/                              |              |
|      |                                             |              |
|      +-- backup-source/           INCLUDED --------+              |
|          +-- baselines/                            |              |
|          +-- backups/                              |              |
|                                                    v              |
|                                             Restic _archive       |
|                                             internal -> /_backup  |
|                                             external -> USB       |
|                                                                  |
|  libvirt/KVM                                                     |
|      |                                                           |
|      +-- win-findentity                                          |
|          +-- NIC 1: direct/macvtap -> physical LAN               |
|          +-- NIC 2: isolated host-only network                   |
|                    Windows 192.168.254.2                          |
|                    Host    192.168.254.1 -> Samba                 |
+------------------------------------------------------------------+
```

Application layer later:

```text
win-findentity
+-- Windows Server
+-- VirtIO drivers
+-- Word / SQL prerequisites as required
+-- Dragon
+-- Findentity
```

---

## 21. Recommended starting instruction for the next thread

Use this document together with the complete `penelope-rc01` source bundle as the operative baseline.

Start by reviewing the full current files and the direct predecessor contracts before editing.

Implement in small Penelope patch blocks. The first code-bearing block should **not** start with Dragon/Findentity. It should establish the Penelope host-side Windows VM domain and the safe backup boundary first.

The most important invariants to preserve are:

1. no host network outage risk from automatic bridge/Netplan rewrites,
2. no normal Restic copy of the active QCOW2,
3. completed VM backups remain inside the normal `_archive` backup path,
4. important baselines are externally backed up before being treated as disaster-recovery protected,
5. no automatic force-stop or destructive restore,
6. Windows/application configuration remains a later guest-side phase,
7. project-specific rules go into `penelope_specific`; generic workflow rules stay with their existing canonical owners.

---

## 22. Technical references used to re-check the design

- Libvirt backup XML / `virDomainBackupBegin`: https://www.libvirt.org/formatbackup.html
- Libvirt efficient live full disk backup: https://www.libvirt.org/kbase/live_full_disk_backup.html
- Libvirt `virsh backup-begin`: https://www.libvirt.org/manpages/virsh.html
- Libvirt macvtap host/guest limitation and second-interface solution: https://wiki.libvirt.org/TroubleshootMacvtapHostFail.html
- Libvirt network XML / direct macvtap networking: https://www.libvirt.org/formatnetwork.html
- Ubuntu package search (Ubuntu 24.04 / Noble libvirt): https://packages.ubuntu.com/search?keywords=libvirt
- Ubuntu package search (Ubuntu 24.04 / Noble QEMU): https://packages.ubuntu.com/search?keywords=qemu

