#!/usr/bin/env bash
# penelope-install.sh
#
# Penelope - automated Ubuntu installation (UEFI/GPT)
#
# Target properties:
# - Ubuntu 24.04 LTS Desktop (noble) + HWE kernel
# - /boot/efi (vfat) + /boot (ext4) unencrypted
# - /, /home, /_archive encrypted (LUKS2) with one shared CRED_MASTER_PW
# - /_backup unencrypted (restic repositories later; repository contents remain encrypted by restic)
# - No TPM auto-unlock by design. Unlock via:
#     - local keyboard entry, or
#     - remote SSH in initramfs (Dropbear, key-only) -> cryptroot-unlock
# - one password prompt for all three LUKS containers (decrypt_keyctl)
# - system language: English, keyboard layout: de-DE, timezone: Europe/Berlin
# - AnyDesk installed + Wayland disabled (X11)
# - OpenSSH server enabled on the installed system
# - KeePassXC available on the installed desktop
# - two encrypted 7z archives beside the bootstrap-config used for the install run
#   (password = CRED_MASTER_PW):
#     - <TARGET_HOST>_unlock_keys.7z  (Dropbear unlock key pair)
#     - <ADMIN_USER>_ssh_keys.7z      (admin-user SSH key pair)
#
# Important:
# - Standard mode (RECREATION_TARGET_LIST="all") deletes all data on DISK_SYS, DISK_HOME, DISK_ARCHIVE,
#   DISK_BACKUP, and optionally DISK_DATA depending on INSTALL_LAYOUT_PROFILE.
# - Preserve mode is supported (for example RECREATION_TARGET_LIST="system,home,_archive" to keep /_backup).
# - Canonical operator flow (current pre-release line):
#     1. Work inside the assembled bundle/workdir, not from a loose artifact set.
#     2. Ensure the workdir contains a current sibling 'penelope-common.sh'
#        (for versioned artifacts: copy 'penelope-common-<version>.sh' to 'penelope-common.sh').
#     3. Run '--write-bootstrap-config-template <path>' and '--write-layout-config-template <path>'
#        (existing files are overwritten only with '--force').
#     4. Edit both external config files in the current workdir.
#     5. Run '--verify-layout-contract --bootstrap-config <path> --layout-config <path>' as the non-destructive preflight.
#     6. Only then run the real install with '--bootstrap-config <path> --layout-config <path>'.
#

#
set -Eeuo pipefail


# Optional: redact bash xtrace output (when the script is invoked with "bash -x")
# to reduce accidental secret leakage into logs/tee output.
# This redaction is a safety net, not a complete guarantee for every possible
# shell expansion. Secret-handling call sites must still keep their explicit
# set +x guards.
# Default: enabled. Disable with: PENELOPE_REDACT_XTRACE=0
penelope_setup_xtrace_redaction() {
  local enabled="${PENELOPE_REDACT_XTRACE:-1}"

  # Only relevant when xtrace is active (e.g., bash -x)
  case "$-" in
    *x*) ;;
    *) return 0 ;;
  esac

  if [[ "$enabled" != "1" ]]; then
    return 0
  fi

  # Respect an explicitly configured xtrace fd
  if [[ -n "${BASH_XTRACEFD:-}" ]]; then
    return 0
  fi

  # Route xtrace to FD 9 and redact secrets there.
  # Keep xtrace visible (command lines remain), but mask:
  #  - 7z password flags (-pSECRET)
  #  - password variables (CRED_MASTER_PW/CRED_LOGIN_PW)
  exec 9> >(sed -u -E -e 's/(-p)[^[:space:]]+/\1<REDACTED>/g' -e 's/(CRED_MASTER_PW=)[^[:space:]]+/\1<REDACTED>/g' -e 's/(CRED_LOGIN_PW=)[^[:space:]]+/\1<REDACTED>/g' >&2)

  export BASH_XTRACEFD=9
  export PS4='+(${BASH_SOURCE##*/}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
}

# Optional: enable xtrace via environment (preferred over invoking 'bash -x').
# Set PENELOPE_XTRACE=1 to turn on xtrace. If the script is already started with -x, this is a no-op.
penelope_maybe_enable_xtrace() {
  if [[ "${PENELOPE_XTRACE:-0}" == "1" ]]; then
    case "$-" in
      *x*) ;;
      *) set -x ;;
    esac
  fi
}
penelope_maybe_enable_xtrace

penelope_setup_xtrace_redaction

export TZ="${TZ:-Europe/Berlin}"

# ================== CONFIGURATION ==================
# Install bootstrap identity + secret inputs are now externalized.
# Use --write-bootstrap-config-template <path> and then pass --bootstrap-config <path>
# for full provisioning / verify-layout-contract runs.
# The installer keeps only inert shipped placeholders inline here.

ADMIN_USER=""               # Loaded from --bootstrap-config for full provisioning; inferred from runtime context for maintenance modes
TARGET_HOST=""              # Loaded from --bootstrap-config for full provisioning; inferred from runtime context for maintenance modes

# Secrets stay shielded against accidental xtrace exposure below even though they are now expected
# to arrive via --bootstrap-config for real provisioning runs.
__PENELOPE_XTRACE_SECRETS=0
case "$-" in *x*) __PENELOPE_XTRACE_SECRETS=1; set +x;; esac
CRED_MASTER_PW="change-me"  # Loaded from --bootstrap-config for real provisioning runs
CRED_LOGIN_PW="change-me"   # Loaded from --bootstrap-config for real provisioning runs
if (( __PENELOPE_XTRACE_SECRETS == 1 )); then
  set -x
fi
unset __PENELOPE_XTRACE_SECRETS

# Source common library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/penelope-common.sh"

# --- Logging: always capture full installer output ---
SCRIPT_NAME="$(basename "$0")"
DEFAULT_LOGFILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S)-$$.log"
LOGFILE="${PENELOPE_LOGFILE:-$DEFAULT_LOGFILE}"

# ================== VERSION ==================
readonly VERSION="0.9.400"

penelope_bundle_startup \
  "penelope-install" "${VERSION}" "${SCRIPT_DIR}/penelope-common.sh" \
  "${BASH_SOURCE[0]:-}" "preflight: source preflight scan failed" \
  warn \
  log \
  validate_secret_not_placeholder \
  require_root \
  require_cmd \
  require_cmd_many \
  ensure_dir \
  ensure_file \
  apt_install \
  validate_shell_script \
  validate_systemd_unit \
  ensure_no_unexpanded_tokens \
  inject_known_macros_if_present \
  inject_source_common_macro_if_present \
  read_kv_value_from_file \
  read_kv_value_from_file_or_default \
  penelope_recovery_stage_dir_for_target \
  penelope_ensure_recovery_stage_dir \
  penelope_stage_common_for_recovery \
  penelope_publish_recovery_stage_file \
  penelope_refresh_installed_common_lib \
  penelope_log_trap_error \
  penelope_signal_exit_code_for_name

SELF_CMD="$(penelope_resolved_script_invocation_for_display "penelope-install.sh" "${0:-${BASH_SOURCE[0]:-penelope-install.sh}}")"
readonly SELF_CMD


usage() {
  local self_cmd
  self_cmd="${SELF_CMD}"
  cat <<EOF_USAGE_INSTALL
Usage:
  ${self_cmd} --write-bootstrap-config-template <path> [--force]
  ${self_cmd} --write-layout-config-template <path> [--force]
  ${self_cmd} --audit-config-evolution --bootstrap-config <path> --layout-config <path>
  sudo -E ${self_cmd} --verify-layout-contract --bootstrap-config <path> --layout-config <path>
  sudo -E ${self_cmd} --bootstrap-config <path> --layout-config <path>
  sudo -E ${self_cmd} --initramfs-only [--kver <kernel_version>]
  sudo -E ${self_cmd} --managed-artifacts-only [--kver <kernel_version>]
  sudo -E ${self_cmd} [--help]

Recommended Live-USB sequence:
  1. ${self_cmd} --write-bootstrap-config-template ./penelope-install.bootstrap.conf
  2. ${self_cmd} --write-layout-config-template ./penelope-install.layout.conf
  3. Edit both files in the current bundle/workdir. Set CRED_MASTER_PW now; set
     CRED_LOGIN_PW before the real install.
  4. Optional forward-update review for existing configs:
     ${self_cmd} --audit-config-evolution --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
  5. sudo -E ${self_cmd} --verify-layout-contract --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf
  6. sudo -E ${self_cmd} --bootstrap-config ./penelope-install.bootstrap.conf --layout-config ./penelope-install.layout.conf

Options:
  -h, --help         Show this help and exit.
      --initramfs-only
                     Non-destructive fast-iteration mode: rebuild/validate initramfs only.
      --managed-artifacts-only
                     Non-destructive host-artifact refresh for a strict Penelope-managed allowlist.
      --audit-config-evolution
                     Non-destructive review of external bootstrap/layout configs against the
                     current shipped config schema and key set. Useful before reusing older
                     operator-owned config files with a newer Penelope installer.
      --verify-layout-contract
                     Non-destructive preflight: verify the current disk/layout contract and print
                     the install plan without confirmation or destructive steps.
      --write-bootstrap-config-template <path>
                     Write a template install bootstrap config file (ADMIN_USER / TARGET_HOST /
                     CRED_MASTER_PW / CRED_LOGIN_PW) and exit.
      --write-layout-config-template <path>
                     Write a template install layout config file and exit.
      --force
                     Overwrite an existing template target when used together with
                     --write-bootstrap-config-template or --write-layout-config-template.
      --bootstrap-config <path>
                     Read install bootstrap identity/secret config from an explicit operator-edited
                     config file.
      --layout-config <path>
                     Read install layout config from an explicit operator-edited config file
                     (currently supports INSTALL_LAYOUT_PROFILE=two-disk|single-disk|three-disk|four-disk).
      --kver <ver>   Kernel version for --initramfs-only/--managed-artifacts-only
                     (default: all installed kernels).

Notes:
  - Template writers refuse to overwrite an existing target by default; use --force to replace an
    existing bootstrap/layout template intentionally.
  - The bootstrap config template contains real install secrets once edited and is therefore written
    with mode 0600.
  - Real provisioning runs externalize operator-edited identity + secrets via --bootstrap-config <path>.
  - Real provisioning runs also require an explicit --layout-config <path>; inline shipped
    layout defaults are not accepted for full installs or for --verify-layout-contract.
  - External install config files are current-only: when a config file is present, Penelope
    install must not silently fall back to shipped inline defaults or placeholders for
    missing current keys.
  - Use --audit-config-evolution before reusing older operator-owned install config files
    with a newer installer release.
  - --verify-layout-contract now refuses unedited bootstrap/layout placeholders; it does
    not require CRED_LOGIN_PW, and it requires CRED_MASTER_PW only when preserved
    encrypted roles must be verified.
  - --initramfs-only is for diagnostic/day-2 initramfs refresh only; it must not touch disks,
    partitioning, luksFormat, mkfs, or grub-install.
  - --managed-artifacts-only refreshes only the explicit installer-owned artifact allowlist; it
    must not act as a generic in-place reinstall path for the running system.
  - --verify-layout-contract runs the same profile/layout/preserve preflight used before a
    destructive install/reinstall, then exits after printing the plan and verification outcome.
EOF_USAGE_INSTALL
}

INSTALL_OPERATION_MODE="full-install"
INITRAMFS_ONLY_KVER="all"
INSTALL_BOOTSTRAP_CONFIG_FILE="${INSTALL_BOOTSTRAP_CONFIG_FILE:-}"
INSTALL_BOOTSTRAP_TEMPLATE_OUTPUT=""
INSTALL_LAYOUT_CONFIG_FILE="${INSTALL_LAYOUT_CONFIG_FILE:-}"
INSTALL_LAYOUT_TEMPLATE_OUTPUT=""
INSTALL_TEMPLATE_WRITE_FORCE="0"

parse_cli_args() {
  while (( $# > 0 )); do
    case "${1}" in
      -h|--help)
        usage
        exit 0
        ;;
      --initramfs-only)
        INSTALL_OPERATION_MODE="initramfs-only"
        shift
        ;;
      --audit-config-evolution)
        INSTALL_OPERATION_MODE="audit-config-evolution"
        shift
        ;;
      --managed-artifacts-only)
        INSTALL_OPERATION_MODE="managed-artifacts-only"
        shift
        ;;
      --verify-layout-contract)
        INSTALL_OPERATION_MODE="verify-layout-contract"
        shift
        ;;
      --write-bootstrap-config-template)
        [[ $# -ge 2 ]] || die "Missing value for --write-bootstrap-config-template"
        INSTALL_OPERATION_MODE="write-bootstrap-config-template"
        INSTALL_BOOTSTRAP_TEMPLATE_OUTPUT="${2}"
        [[ -n "${INSTALL_BOOTSTRAP_TEMPLATE_OUTPUT}" ]] || die "--write-bootstrap-config-template requires a non-empty path"
        shift 2
        ;;
      --write-layout-config-template)
        [[ $# -ge 2 ]] || die "Missing value for --write-layout-config-template"
        INSTALL_OPERATION_MODE="write-layout-config-template"
        INSTALL_LAYOUT_TEMPLATE_OUTPUT="${2}"
        [[ -n "${INSTALL_LAYOUT_TEMPLATE_OUTPUT}" ]] || die "--write-layout-config-template requires a non-empty path"
        shift 2
        ;;
      --bootstrap-config)
        [[ $# -ge 2 ]] || die "Missing value for --bootstrap-config"
        INSTALL_BOOTSTRAP_CONFIG_FILE="${2}"
        [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]] || die "--bootstrap-config requires a non-empty path"
        shift 2
        ;;
      --layout-config)
        [[ $# -ge 2 ]] || die "Missing value for --layout-config"
        INSTALL_LAYOUT_CONFIG_FILE="${2}"
        [[ -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]] || die "--layout-config requires a non-empty path"
        shift 2
        ;;
      --kver)
        [[ $# -ge 2 ]] || die "Missing value for --kver"
        INITRAMFS_ONLY_KVER="${2}"
        [[ -n "${INITRAMFS_ONLY_KVER}" ]] || die "--kver requires a non-empty kernel version"
        shift 2
        ;;
      --force)
        INSTALL_TEMPLATE_WRITE_FORCE="1"
        shift
        ;;
      *)
        die "Unknown argument: ${1} (use --help)"
        ;;
    esac
  done

  if [[ "${INSTALL_OPERATION_MODE}" != "initramfs-only" &&
        "${INSTALL_OPERATION_MODE}" != "managed-artifacts-only" &&
        "${INITRAMFS_ONLY_KVER}" != "all" ]]; then
    die "--kver is only valid together with --initramfs-only or --managed-artifacts-only"
  fi

  if [[ "${INSTALL_OPERATION_MODE}" != "full-install" &&
        "${INSTALL_OPERATION_MODE}" != "verify-layout-contract" &&
        "${INSTALL_OPERATION_MODE}" != "audit-config-evolution" &&
        -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]]; then
    die "--bootstrap-config is only valid together with the full install provisioning path, --verify-layout-contract, or --audit-config-evolution"
  fi

  if [[ "${INSTALL_OPERATION_MODE}" != "write-bootstrap-config-template" &&
        -n "${INSTALL_BOOTSTRAP_TEMPLATE_OUTPUT}" ]]; then
    die "--write-bootstrap-config-template requires template output mode"
  fi

  if [[ "${INSTALL_OPERATION_MODE}" != "full-install" &&
        "${INSTALL_OPERATION_MODE}" != "verify-layout-contract" &&
        "${INSTALL_OPERATION_MODE}" != "audit-config-evolution" &&
        -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]]; then
    die "--layout-config is only valid together with the full install provisioning path, --verify-layout-contract, or --audit-config-evolution"
  fi

  if [[ "${INSTALL_OPERATION_MODE}" != "write-layout-config-template" &&
        -n "${INSTALL_LAYOUT_TEMPLATE_OUTPUT}" ]]; then
    die "--write-layout-config-template requires template output mode"
  fi

  if [[ "${INSTALL_TEMPLATE_WRITE_FORCE}" == "1" &&
        "${INSTALL_OPERATION_MODE}" != "write-bootstrap-config-template" &&
        "${INSTALL_OPERATION_MODE}" != "write-layout-config-template" ]]; then
    die "--force is only valid together with --write-bootstrap-config-template or --write-layout-config-template"
  fi

  if [[ "${INSTALL_OPERATION_MODE}" == "audit-config-evolution" ]]; then
    [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]] || die "--bootstrap-config is required together with --audit-config-evolution"
    [[ -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]] || die "--layout-config is required together with --audit-config-evolution"
  fi
}

verify_layout_contract_needs_master_password() {
  local list
  list="$(normalize_list "${RECREATION_TARGET_LIST}")"

  if list_has_token "$list" "all"; then
    return 1
  fi

  if ! list_has_token "$list" "home" || ! list_has_token "$list" "_archive"; then
    return 0
  fi

  return 1
}

validate_required_operator_edited_secrets() {
  verify_layout_contract_master_password_required=""
  case "${INSTALL_OPERATION_MODE}" in
    initramfs-only|managed-artifacts-only)
      return 0
      ;;
    verify-layout-contract)
      if verify_layout_contract_needs_master_password; then
        verify_layout_contract_master_password_required="1"
        validate_secret_not_placeholder CRED_MASTER_PW "${CRED_MASTER_PW}"
      else
        verify_layout_contract_master_password_required="0"
      fi
      return 0
      ;;
    full-install)
      validate_secret_not_placeholder CRED_MASTER_PW "${CRED_MASTER_PW}"
      validate_secret_not_placeholder CRED_LOGIN_PW "${CRED_LOGIN_PW}"
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# Parse help/argument-control requests before any top-level mirror probing or other
# expensive initialization. This keeps --help side-effect free enough for routine use.
parse_cli_args "$@"

# ================== DROPBEAR PORT (Installer) ==================
# Single source of truth for the dropbear initramfs SSH port.
# Can be overridden via environment, for example: DROPBEAR_PORT=2222
readonly DROPBEAR_PORT_DEFAULT="2222"

verify_layout_contract_master_password_required=""

: "${DROPBEAR_PORT:=${DROPBEAR_PORT_DEFAULT}}"
# Validate early (avoid later set -u crashes and ensure placeholder substitution is safe).
if [[ ! "${DROPBEAR_PORT}" =~ ^[0-9]+$ ]] || (( DROPBEAR_PORT < 1 || DROPBEAR_PORT > 65535 )); then
  die "Invalid DROPBEAR_PORT='${DROPBEAR_PORT}' (expected 1..65535)."
fi

# Verifier failure policy for remaining verifier checks:
# fail-fast (fatal) without global strict-mode toggle or legacy compatibility path.
# Initramfs diagnostic mode: when =1, initramfs performs one one-shot retry each (DHCP/Dropbear) with backoff (in addition to kernel cmdline penelope_debug_retry=1).
INITRAMFS_DEBUG_RETRY="${PENELOPE_INITRAMFS_DEBUG_RETRY:-0}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

readonly ANYDESK_GPG_KEY_URL="https://keys.anydesk.com/repos/DEB-GPG-KEY"
readonly ANYDESK_APT_RELEASE_URL="https://deb.anydesk.com/dists/all/Release"
readonly ANYDESK_STAGED_GPG_KEY="/tmp/penelope-anydesk-gpg-key-${RUN_TS}.asc"
readonly ANYDESK_TARGET_STAGED_GPG_KEY="/etc/penelope/install-cache/keys.anydesk.com.asc"

# Severity helper for verifier-failure policy wording.
penelope_verifier_mode_label() {
  printf '%s
' "severity=fatal (verifier failure policy)"
}


# APT Mirror override (optional)
# - If empty: Penelope automatically selects the fastest mirror from a fixed list inside the chroot.
# - Regional examples:
#     PENELOPE_APT_MIRROR="de.archive.ubuntu.com"
#     PENELOPE_APT_MIRROR="ftp.halifax.rwth-aachen.de/ubuntu"
#     PENELOPE_APT_MIRROR="mirror.netcologne.de/ubuntu"
# - Examples (global):
#     PENELOPE_APT_MIRROR="archive.ubuntu.com"
PENELOPE_APT_MIRROR="${PENELOPE_APT_MIRROR:-}"
PENELOPE_APT_MIRROR_BASE="${PENELOPE_APT_MIRROR_BASE:-}"

initialize_apt_mirror_selection() {
  # Mirror selection: if no override is set, select the fastest mirror on the live system.
  # The result is passed into the chroot environment (env -i).
  if [[ -z "${PENELOPE_APT_MIRROR}" ]]; then
    PENELOPE_APT_MIRROR="$(apt_select_ubuntu_mirror "" "noble")"
    log "APT Mirror auto: ${PENELOPE_APT_MIRROR}"
  else
    log "APT Mirror override: ${PENELOPE_APT_MIRROR}"
  fi

  # Export for debootstrap + chroot (the chroot only inherits exported variables).
  export PENELOPE_APT_MIRROR
  # Normalized mirror base (must end with /ubuntu/). Used for debootstrap and sources.list.
  PENELOPE_APT_MIRROR_BASE="$(apt_select_ubuntu_mirror "${PENELOPE_APT_MIRROR}" "noble")"
  export PENELOPE_APT_MIRROR_BASE
  log "APT Mirror base: ${PENELOPE_APT_MIRROR_BASE}"
}

# Note: the AnyDesk password is optional. If set, replace it before execution and store it securely as well.

# Reinstallation policy (comma list): system,home,_archive,_backup,all
# - all (default): recreate everything (data loss across all partitions)
# - system: recreate only system (/) + always refresh /boot and /boot/efi; preserve home,_archive,_backup
# - system,home: preserve _archive,_backup
# - system,home,_archive: preserve _backup
# NOTE: list must contain "system" or "all" (otherwise ERROR).
RECREATION_TARGET_LIST="all"

# Install layout profile (operator-edited provisioning topology)
# Current shipped implementation supports: two-disk, single-disk, three-disk, four-disk
# Future profiles (e.g. custom) belong behind this explicit seam instead of
# hard-coding example capacities or device-count assumptions into the project model.
#
# Phase-3 seam:
# - Inline values below remain the shipped defaults for the current two-disk profile.
# - The shipped default hardware example for that two-disk profile is: system/home on an approx. 2 TB M.2
#   plus archive/backup on an approx. 4 TB M.2.
# - single-disk is now an explicit additional shipped profile.
# - An operator-edited install layout config file may override them via --layout-config <path>; identity/secrets live in the separate --bootstrap-config <path>.
# - Layout config belongs only to the destructive provisioning plane; maintenance submodes must not evaluate it.
INSTALL_LAYOUT_PROFILE="two-disk"

# Devices (IMPORTANT: data-loss risk)
# Recommendation: use stable device paths under /dev/disk/by-id/ instead of /dev/sdX or /dev/nvmeXnY,
# because sdX ordering can change between boots. For example, identify matching IDs like this:
#   lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
#   ls -l /dev/disk/by-id/
#   readlink -f /dev/disk/by-id/<ID>
# DISK_SYS = primary install disk. In two-disk it holds EFI/BOOT/ROOT/HOME. In three-disk/four-disk it holds EFI/BOOT/ROOT.
# DISK_HOME = dedicated home disk for three-disk/four-disk; leave empty for two-disk/single-disk.
# DISK_DATA = archive/backup disk for two-disk and three-disk; leave empty for single-disk/four-disk.
# DISK_ARCHIVE = dedicated archive disk for four-disk; leave empty for two-disk/single-disk/three-disk.
# DISK_BACKUP = dedicated backup disk for four-disk; leave empty for two-disk/single-disk/three-disk.
# Prefer stable device paths (e.g. /dev/disk/by-id/<id>).
# Example:
#   DISK_SYS="/dev/disk/by-id/REPLACE_WITH_SYSTEM_DISK_ID"; DISK_HOME=""; DISK_DATA="/dev/disk/by-id/REPLACE_WITH_DATA_DISK_ID"
#
# Current shipped defaults for the two-disk profile:
# - shipped default hardware example: approx. 2 TB DISK_SYS + approx. 4 TB DISK_DATA
# - system/home live on DISK_SYS; archive/backup live on DISK_DATA
DISK_SYS="/dev/nvme0n1"   # example system disk for the shipped two-disk default (approx. 2 TB class)
DISK_HOME=""              # empty for shipped two-disk default; used by three-disk/four-disk
DISK_DATA="/dev/nvme1n1"  # example data disk for the shipped two-disk default (approx. 4 TB class)
DISK_ARCHIVE=""           # empty for shipped two-disk default; used only by four-disk
DISK_BACKUP=""            # empty for shipped two-disk default; used only by four-disk

# Derived devices (do not hand-edit): resolved from the effective layout profile/device config.
EFI_DEV=""
BOOT_DEV=""
ROOT_LUKS_DEV=""
HOME_LUKS_DEV=""
ARCHIVE_LUKS_DEV=""
BACKUP_DEV=""

# Stable mapper names (independent of underlying device naming). Keep '_crypt' suffix for consistency.
readonly MAPPER_ROOT="penelope_root_crypt"
readonly MAPPER_HOME="penelope_home_crypt"
readonly MAPPER_ARCHIVE="penelope_archive_crypt"

readonly ROOT_MAPPER="/dev/mapper/${MAPPER_ROOT}"
readonly HOME_MAPPER="/dev/mapper/${MAPPER_HOME}"
readonly ARCHIVE_MAPPER="/dev/mapper/${MAPPER_ARCHIVE}"

# Current shipped sizing defaults.
# - two-disk: tuned for the shipped default example of approx. 2 TB system/home + approx. 4 TB archive/backup.
#   ROOT_SIZE_GIB and ARCHIVE_SIZE_GIB are applied; /home and /_backup consume the remaining capacity on their disks.
# - single-disk: HOME_SIZE_GIB and ARCHIVE_SIZE_GIB are applied; /_backup consumes the remaining capacity on the only disk.
# - three-disk: ROOT uses remaining capacity on DISK_SYS; HOME uses remaining capacity
#   on DISK_HOME; ARCHIVE_SIZE_GIB is applied on DISK_DATA and /_backup consumes the
#   remaining capacity there.
# - four-disk: ROOT_SIZE_GIB is applied on DISK_SYS; /home, /_archive, and /_backup each consume the remaining capacity on their dedicated disks.
EFI_SIZE_MIB=512
BOOT_SIZE_MIB=1536  # ~1.5 GiB
ROOT_SIZE_GIB=220  # shipped default root size for the two-disk default example and current shipped profiles
HOME_SIZE_GIB=200  # used by single-disk; ignored by two-disk, three-disk, and four-disk
ARCHIVE_SIZE_GIB=1024  # shipped default archive size for the two-disk default example and for single-disk/three-disk; ignored by four-disk

readonly INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT="1"
readonly INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT="1"

INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE=""
INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE=""
INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN="0"
INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN="0"
INSTALL_BOOTSTRAP_CONFIG_SEEN_ADMIN_USER="0"
INSTALL_BOOTSTRAP_CONFIG_SEEN_TARGET_HOST="0"
INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_MASTER_PW="0"
INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_LOGIN_PW="0"
INSTALL_LAYOUT_CONFIG_SEEN_INSTALL_LAYOUT_PROFILE="0"
INSTALL_LAYOUT_CONFIG_SEEN_DISK_SYS="0"
INSTALL_LAYOUT_CONFIG_SEEN_DISK_HOME="0"
INSTALL_LAYOUT_CONFIG_SEEN_DISK_DATA="0"
INSTALL_LAYOUT_CONFIG_SEEN_DISK_ARCHIVE="0"
INSTALL_LAYOUT_CONFIG_SEEN_DISK_BACKUP="0"
INSTALL_LAYOUT_CONFIG_SEEN_EFI_SIZE_MIB="0"
INSTALL_LAYOUT_CONFIG_SEEN_BOOT_SIZE_MIB="0"
INSTALL_LAYOUT_CONFIG_SEEN_ROOT_SIZE_GIB="0"
INSTALL_LAYOUT_CONFIG_SEEN_HOME_SIZE_GIB="0"
INSTALL_LAYOUT_CONFIG_SEEN_ARCHIVE_SIZE_GIB="0"

reset_install_bootstrap_config_seen_state() {
  INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE=""
  INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN="0"
  INSTALL_BOOTSTRAP_CONFIG_SEEN_ADMIN_USER="0"
  INSTALL_BOOTSTRAP_CONFIG_SEEN_TARGET_HOST="0"
  INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_MASTER_PW="0"
  INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_LOGIN_PW="0"
}

reset_install_layout_config_seen_state() {
  INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE=""
  INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN="0"
  INSTALL_LAYOUT_CONFIG_SEEN_INSTALL_LAYOUT_PROFILE="0"
  INSTALL_LAYOUT_CONFIG_SEEN_DISK_SYS="0"
  INSTALL_LAYOUT_CONFIG_SEEN_DISK_HOME="0"
  INSTALL_LAYOUT_CONFIG_SEEN_DISK_DATA="0"
  INSTALL_LAYOUT_CONFIG_SEEN_DISK_ARCHIVE="0"
  INSTALL_LAYOUT_CONFIG_SEEN_DISK_BACKUP="0"
  INSTALL_LAYOUT_CONFIG_SEEN_EFI_SIZE_MIB="0"
  INSTALL_LAYOUT_CONFIG_SEEN_BOOT_SIZE_MIB="0"
  INSTALL_LAYOUT_CONFIG_SEEN_ROOT_SIZE_GIB="0"
  INSTALL_LAYOUT_CONFIG_SEEN_HOME_SIZE_GIB="0"
  INSTALL_LAYOUT_CONFIG_SEEN_ARCHIVE_SIZE_GIB="0"
}

install_append_missing_key_if_unseen() {
  local seen_flag="${1:-0}"
  local key_name="${2:-}"
  local list_name="${3:-}"
  [[ -n "${key_name}" && -n "${list_name}" ]] || die "install_append_missing_key_if_unseen requires a key and list variable name"
  [[ "${key_name}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "install_append_missing_key_if_unseen received invalid key name: ${key_name}"
  [[ "${list_name}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "install_append_missing_key_if_unseen received invalid list variable name: ${list_name}"
  local -n list_ref="${list_name}"
  if [[ "${seen_flag}" != "1" ]]; then
    list_ref+=("${key_name}")
  fi
}

install_join_by_comma_or_none() {
  if (( $# == 0 )); then
    printf '%s' 'none'
    return 0
  fi
  local first="1" item
  for item in "$@"; do
    if [[ "${first}" == "1" ]]; then
      printf '%s' "${item}"
      first="0"
    else
      printf ', %s' "${item}"
    fi
  done
}

install_schema_version_is_numeric_or_die() {
  local label="${1:?label required}"
  local value="${2:-}"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be an integer schema version (got: ${value:-<empty>})"
}

collect_install_bootstrap_config_missing_keys() {
  local -a missing_keys=()

  install_append_missing_key_if_unseen "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN}" "INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_BOOTSTRAP_CONFIG_SEEN_ADMIN_USER}" "ADMIN_USER" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_BOOTSTRAP_CONFIG_SEEN_TARGET_HOST}" "TARGET_HOST" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_MASTER_PW}" "CRED_MASTER_PW" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_LOGIN_PW}" "CRED_LOGIN_PW" missing_keys

  (( ${#missing_keys[@]} == 0 )) || printf '%s\n' "${missing_keys[@]}"
}

collect_install_layout_config_missing_keys() {
  local -a missing_keys=()

  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN}" "INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_INSTALL_LAYOUT_PROFILE}" "INSTALL_LAYOUT_PROFILE" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_DISK_SYS}" "DISK_SYS" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_DISK_HOME}" "DISK_HOME" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_DISK_DATA}" "DISK_DATA" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_DISK_ARCHIVE}" "DISK_ARCHIVE" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_DISK_BACKUP}" "DISK_BACKUP" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_EFI_SIZE_MIB}" "EFI_SIZE_MIB" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_BOOT_SIZE_MIB}" "BOOT_SIZE_MIB" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_ROOT_SIZE_GIB}" "ROOT_SIZE_GIB" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_HOME_SIZE_GIB}" "HOME_SIZE_GIB" missing_keys
  install_append_missing_key_if_unseen "${INSTALL_LAYOUT_CONFIG_SEEN_ARCHIVE_SIZE_GIB}" "ARCHIVE_SIZE_GIB" missing_keys

  (( ${#missing_keys[@]} == 0 )) || printf '%s\n' "${missing_keys[@]}"
}


install_print_config_upgrade_guidance() {
  local bootstrap_path="${1:-}"
  local layout_path="${2:-}"
  local self_cmd="${SELF_CMD}"
  local bootstrap_suggest layout_suggest
  bootstrap_suggest="$(dirname -- "${bootstrap_path:-.}")/penelope-install.bootstrap.NEW.conf"
  layout_suggest="$(dirname -- "${layout_path:-.}")/penelope-install.layout.NEW.conf"
  printf '%s
' 'Guidance:'
  printf '  - Do not overwrite an effective install config blindly.
'
  printf '  - Generate fresh current templates at separate paths, then manually merge the missing current keys into the effective config.
'
  printf '  - Suggested commands:
'
  printf '      %s --write-bootstrap-config-template %s
' "${self_cmd}" "$(printf '%q' "${bootstrap_suggest}")"
  printf '      %s --write-layout-config-template %s
' "${self_cmd}" "$(printf '%q' "${layout_suggest}")"
}

install_report_bootstrap_config_evolution_or_die() {
  local mode="${1:?mode required}"
  local cfg="${2:?config path required}"
  local -a missing=()
  mapfile -t missing < <(collect_install_bootstrap_config_missing_keys)

  if [[ "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
    install_schema_version_is_numeric_or_die \
      "INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION in ${cfg}" \
      "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE}"
    if (( INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE > INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT )); then
      die "Install bootstrap config ${cfg} declares newer schema version ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE} than this installer supports (${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT})."
    fi
  fi

  if [[ "${mode}" == "audit" ]]; then
    printf '%s
' "Bootstrap config: ${cfg}"
    if [[ "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
      printf '%s
' "  schema version in file: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE} (current: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT})"
    else
      printf '%s
' "  schema version in file: absent (current: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT})"
    fi
    printf '%s
' "  missing current keys: $(install_join_by_comma_or_none "${missing[@]}")"
    return 0
  fi

  if [[ "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN}" != "1" \
    || ${#missing[@]} -gt 0 \
    || ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE:-0} -lt ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT} ]]; then
    printf '%s
' "Install bootstrap config requires an explicit forward-update merge before runtime: ${cfg}" >&2
    if [[ "${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
      printf '%s
' "  schema version in file: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE} (current: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT})" >&2
    else
      printf '%s
' "  schema version in file: absent (current: ${INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_CURRENT})" >&2
    fi
    printf '%s
' "  missing current keys: $(install_join_by_comma_or_none "${missing[@]}")" >&2
    printf '%s
' 'Penelope install does not silently fall back to shipped placeholders or inline defaults for missing current keys in an external install config.' >&2
    install_print_config_upgrade_guidance "${cfg}" "${INSTALL_LAYOUT_CONFIG_FILE:-$(dirname -- "${cfg}")/penelope-install.layout.conf}" >&2
    exit 1
  fi
}

install_report_layout_config_evolution_or_die() {
  local mode="${1:?mode required}"
  local cfg="${2:?config path required}"
  local -a missing=()
  mapfile -t missing < <(collect_install_layout_config_missing_keys)

  if [[ "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
    install_schema_version_is_numeric_or_die \
      "INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION in ${cfg}" \
      "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE}"
    if (( INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE > INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT )); then
      die "Install layout config ${cfg} declares newer schema version ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE} than this installer supports (${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT})."
    fi
  fi

  if [[ "${mode}" == "audit" ]]; then
    printf '%s
' "Layout config: ${cfg}"
    if [[ "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
      printf '%s
' "  schema version in file: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE} (current: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT})"
    else
      printf '%s
' "  schema version in file: absent (current: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT})"
    fi
    printf '%s
' "  missing current keys: $(install_join_by_comma_or_none "${missing[@]}")"
    return 0
  fi

  if [[ "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN}" != "1" \
    || ${#missing[@]} -gt 0 \
    || ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE:-0} -lt ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT} ]]; then
    printf '%s
' "Install layout config requires an explicit forward-update merge before runtime: ${cfg}" >&2
    if [[ "${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN}" == "1" ]]; then
      printf '%s
' "  schema version in file: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE} (current: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT})" >&2
    else
      printf '%s
' "  schema version in file: absent (current: ${INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_CURRENT})" >&2
    fi
    printf '%s
' "  missing current keys: $(install_join_by_comma_or_none "${missing[@]}")" >&2
    printf '%s
' 'Penelope install does not silently fall back to shipped placeholders or inline defaults for missing current keys in an external install config.' >&2
    install_print_config_upgrade_guidance "${INSTALL_BOOTSTRAP_CONFIG_FILE:-$(dirname -- "${cfg}")/penelope-install.bootstrap.conf}" "${cfg}" >&2
    exit 1
  fi
}

run_install_config_evolution_audit_mode() {
  [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]] || die "--bootstrap-config is required for --audit-config-evolution"
  [[ -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]] || die "--layout-config is required for --audit-config-evolution"

  load_install_bootstrap_config_file_or_die
  load_install_layout_config_file_or_die

  printf '%s
' "=== Penelope: install config evolution audit (v${VERSION}) ==="
  install_report_bootstrap_config_evolution_or_die audit "${INSTALL_BOOTSTRAP_CONFIG_FILE}"
  install_report_layout_config_evolution_or_die audit "${INSTALL_LAYOUT_CONFIG_FILE}"
  printf '%s
' 'Result:'
  printf '%s
' '  - Audit completed. If schema versions are absent/older or current keys are missing, merge them explicitly before verify-layout-contract or a real install.'
  install_print_config_upgrade_guidance "${INSTALL_BOOTSTRAP_CONFIG_FILE}" "${INSTALL_LAYOUT_CONFIG_FILE}"
}

install_layout_config_recognized_key_or_die() {
  case "${1:-}" in
    INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION|INSTALL_LAYOUT_PROFILE|DISK_SYS|DISK_HOME|DISK_DATA|\
    DISK_ARCHIVE|DISK_BACKUP|EFI_SIZE_MIB|BOOT_SIZE_MIB|ROOT_SIZE_GIB|\
    HOME_SIZE_GIB|ARCHIVE_SIZE_GIB)
      return 0
      ;;
    *)
      die "Unknown key in install layout config: ${1:-<empty>}"
      ;;
  esac
}

strip_optional_wrapping_quotes() {
  local raw="${1-}"
  if [[ "${raw}" == \"*\" && "${raw}" == *\" ]]; then
    raw="${raw:1:${#raw}-2}"
  elif [[ "${raw}" == \'*\' && "${raw}" == *\' ]]; then
    raw="${raw:1:${#raw}-2}"
  fi
  printf '%s' "${raw}"
}

apply_install_layout_config_line_or_die() {
  local line_no="${1}"
  local line="${2}"
  local trimmed="${line}"

  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  [[ -z "${trimmed}" ]] && return 0
  [[ "${trimmed}" == \#* ]] && return 0
  [[ "${trimmed}" == *=* ]] || die "Invalid install layout config line ${line_no}: expected KEY=VALUE"

  local key="${trimmed%%=*}"
  local value="${trimmed#*=}"

  key="${key%"${key##*[![:space:]]}"}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="$(strip_optional_wrapping_quotes "${value}")"

  install_layout_config_recognized_key_or_die "${key}"

  case "${key}" in
    INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION) INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_FILE="${value}"; INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION_SEEN="1" ;;
    INSTALL_LAYOUT_PROFILE) INSTALL_LAYOUT_PROFILE="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_INSTALL_LAYOUT_PROFILE="1" ;;
    DISK_SYS) DISK_SYS="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_DISK_SYS="1" ;;
    DISK_HOME) DISK_HOME="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_DISK_HOME="1" ;;
    DISK_DATA) DISK_DATA="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_DISK_DATA="1" ;;
    DISK_ARCHIVE) DISK_ARCHIVE="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_DISK_ARCHIVE="1" ;;
    DISK_BACKUP) DISK_BACKUP="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_DISK_BACKUP="1" ;;
    EFI_SIZE_MIB) EFI_SIZE_MIB="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_EFI_SIZE_MIB="1" ;;
    BOOT_SIZE_MIB) BOOT_SIZE_MIB="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_BOOT_SIZE_MIB="1" ;;
    ROOT_SIZE_GIB) ROOT_SIZE_GIB="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_ROOT_SIZE_GIB="1" ;;
    HOME_SIZE_GIB) HOME_SIZE_GIB="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_HOME_SIZE_GIB="1" ;;
    ARCHIVE_SIZE_GIB) ARCHIVE_SIZE_GIB="${value}"; INSTALL_LAYOUT_CONFIG_SEEN_ARCHIVE_SIZE_GIB="1" ;;
    *) die "Unhandled install layout config key: ${key}" ;;
  esac
}

install_bootstrap_config_recognized_key_or_die() {
  case "${1:-}" in
    INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION|ADMIN_USER|TARGET_HOST|CRED_MASTER_PW|CRED_LOGIN_PW)
      ;;
    *)
      die "Unknown key in install bootstrap config: ${1:-<empty>}"
      ;;
  esac
}

apply_install_bootstrap_config_line_or_die() {
  local line_no="${1}"
  local line="${2}"
  local trimmed="${line}"

  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  [[ -z "${trimmed}" ]] && return 0
  [[ "${trimmed}" == \#* ]] && return 0
  [[ "${trimmed}" == *=* ]] || die "Invalid install bootstrap config line ${line_no}: expected KEY=VALUE"

  local key="${trimmed%%=*}"
  local value="${trimmed#*=}"

  key="${key%"${key##*[![:space:]]}"}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="$(strip_optional_wrapping_quotes "${value}")"

  install_bootstrap_config_recognized_key_or_die "${key}"

  case "${key}" in
    INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION) INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_FILE="${value}"; INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION_SEEN="1" ;;
    ADMIN_USER) ADMIN_USER="${value}"; INSTALL_BOOTSTRAP_CONFIG_SEEN_ADMIN_USER="1" ;;
    TARGET_HOST) TARGET_HOST="${value}"; INSTALL_BOOTSTRAP_CONFIG_SEEN_TARGET_HOST="1" ;;
    CRED_MASTER_PW) CRED_MASTER_PW="${value}"; INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_MASTER_PW="1" ;;
    CRED_LOGIN_PW) CRED_LOGIN_PW="${value}"; INSTALL_BOOTSTRAP_CONFIG_SEEN_CRED_LOGIN_PW="1" ;;
    *) die "Unhandled install bootstrap config key: ${key}" ;;
  esac
}

install_template_write_maybe_refuse_existing_target() {
  local out_path="${1:-}"
  local template_label="${2:-template}"
  [[ -n "${out_path}" ]] || die "install_template_write_maybe_refuse_existing_target requires a non-empty path"
  [[ -n "${template_label}" ]] || die "install_template_write_maybe_refuse_existing_target requires a template label"

  if [[ -e "${out_path}" && "${INSTALL_TEMPLATE_WRITE_FORCE}" != "1" ]]; then
    die "Refusing to overwrite existing ${template_label}: ${out_path}. Caution: file already exists. Use --force to overwrite it."
  fi
}

install_template_mktemp_or_die() {
  local out_path="${1:-}"
  [[ -n "${out_path}" ]] || die "install_template_mktemp_or_die requires a non-empty path"
  local dir base tmp
  dir="$(dirname -- "${out_path}")"
  base="$(basename -- "${out_path}")"
  tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX")" || die "Could not create temporary file for ${out_path}"
  printf '%s' "${tmp}"
}

write_install_bootstrap_config_template_or_die() {
  local out_path="${1:-}"
  [[ -n "${out_path}" ]] || die "write_install_bootstrap_config_template_or_die requires a non-empty path"
  mkdir -p "$(dirname -- "${out_path}")"
  install_template_write_maybe_refuse_existing_target "${out_path}" "install bootstrap config template"

  local tmp_path=""
  tmp_path="$(install_template_mktemp_or_die "${out_path}")"
  chmod 600 "${tmp_path}" || { rm -f -- "${tmp_path}"; die "Could not secure bootstrap template temp file: ${tmp_path}"; }

  cat >"${tmp_path}" <<'EOF_INSTALL_BOOTSTRAP_CONFIG'
# Penelope install bootstrap config template
# Phase seam:
# - This file carries operator-edited host identity + install bootstrap secrets.
# - It is consumed only by the destructive full-install path and by --verify-layout-contract.
# - For --verify-layout-contract, CRED_LOGIN_PW may still remain change-me; real full installs require both secrets.
# - Non-destructive maintenance modes must not require this file.
# - Keep this file out of loose Desktop/workdir sprawl and password-manage the final values appropriately.
# - Current-only contract: the live install path must not fall back to inline shipped identity/secret placeholders.

INSTALL_BOOTSTRAP_CONFIG_SCHEMA_VERSION="1"
ADMIN_USER="REPLACE_WITH_ADMIN_USER"
TARGET_HOST="REPLACE_WITH_TARGET_HOST"

# Install secrets:
# - Set CRED_MASTER_PW before any verify that needs preserved encrypted-role validation and before any real install.
# - Set CRED_LOGIN_PW before the real install.
CRED_MASTER_PW="change-me"
CRED_LOGIN_PW="change-me"
EOF_INSTALL_BOOTSTRAP_CONFIG

  mv -f -- "${tmp_path}" "${out_path}" || { rm -f -- "${tmp_path}"; die "Could not move bootstrap config template into place: ${out_path}"; }
  chmod 600 "${out_path}" || die "Could not enforce mode 0600 on bootstrap config template: ${out_path}"

  printf '%s
' "Wrote install bootstrap config template: ${out_path}"
  printf '%s
' "Permissions: 0600"
  local self_cmd bootstrap_q companion_layout_path companion_layout_q
  self_cmd="${SELF_CMD}"
  bootstrap_q="$(penelope_quote_path_for_display "${out_path}")"
  companion_layout_path="$(dirname -- "${out_path}")/penelope-install.layout.conf"
  companion_layout_q="$(penelope_quote_path_for_display "${companion_layout_path}")"
  printf '%s
' "Next steps:"
  printf '  1. Edit %s: set ADMIN_USER, TARGET_HOST, and CRED_MASTER_PW now; set CRED_LOGIN_PW before a real install.
' "${bootstrap_q}"
  if [[ -f "${companion_layout_path}" ]]; then
    printf '  2. Review the matching layout config and replace any remaining REPLACE_WITH values before runtime: %s
' "${companion_layout_q}"
  else
    printf '  2. Write or review the matching layout config: %s --write-layout-config-template %s
' "${self_cmd}" "${companion_layout_q}"
  fi
  printf '  3. Optional config-evolution audit for reused older configs: %s --audit-config-evolution --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${bootstrap_q}" "${companion_layout_q}"
  printf '  4. Optional preflight: sudo -E %s --verify-layout-contract --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${bootstrap_q}" "${companion_layout_q}"
  printf '  5. Real install:       sudo -E %s --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${bootstrap_q}" "${companion_layout_q}"
}
load_install_bootstrap_config_file_or_die() {
  local cfg="${INSTALL_BOOTSTRAP_CONFIG_FILE:-}"
  reset_install_bootstrap_config_seen_state
  [[ -n "${cfg}" ]] || return 0
  [[ -f "${cfg}" ]] || die "Install bootstrap config file not found: ${cfg}"
  [[ -r "${cfg}" ]] || die "Install bootstrap config file is not readable: ${cfg}"

  local line line_no=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no + 1))
    apply_install_bootstrap_config_line_or_die "${line_no}" "${line}"
  done < "${cfg}"
}

refresh_install_bootstrap_runtime_context() {
  if [[ -z "${TARGET_HOST}" ]]; then
    TARGET_HOST="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo penelope)"
  fi
  if [[ -z "${ADMIN_USER}" ]]; then
    ADMIN_USER="${SUDO_USER:-$(id -un 2>/dev/null || echo admin)}"
  fi
}

refresh_install_bootstrap_derived_names() {
  DROPBEAR_KEY_NAME="${TARGET_HOST}_unlock"
  ADMIN_SSH_KEY_NAME="${ADMIN_USER}_ssh"
  KEY_STAGE_DIR="${TARGET_HOST}_keys"
}

initialize_install_bootstrap_context_or_die() {
  case "${INSTALL_OPERATION_MODE}" in
    full-install|verify-layout-contract)
      [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]] || die "--bootstrap-config is required for the full install provisioning path and for --verify-layout-contract"
      load_install_bootstrap_config_file_or_die
      install_report_bootstrap_config_evolution_or_die enforce "${INSTALL_BOOTSTRAP_CONFIG_FILE}"
      ;;
    initramfs-only|managed-artifacts-only)
      refresh_install_bootstrap_runtime_context
      ;;
    *)
      ;;
  esac

  if [[ "${INSTALL_OPERATION_MODE}" == "full-install" || "${INSTALL_OPERATION_MODE}" == "verify-layout-contract" ]]; then
    require_non_placeholder_install_scalar_or_die "ADMIN_USER" "${ADMIN_USER}" "bootstrap-config"
    require_non_placeholder_install_scalar_or_die "TARGET_HOST" "${TARGET_HOST}" "bootstrap-config"
  fi

  if [[ -n "${ADMIN_USER}" ]]; then
    validate_username_or_die "${ADMIN_USER}"
  fi
  if [[ -n "${TARGET_HOST}" ]]; then
    validate_hostname_or_die "${TARGET_HOST}"
  fi

  if [[ -n "${TARGET_HOST}" && -n "${ADMIN_USER}" ]]; then
    refresh_install_bootstrap_derived_names
  fi
}

install_value_is_unedited_placeholder() {
  local value="${1-}"
  [[ -n "${value}" && "${value}" == *REPLACE_WITH* ]]
}

require_non_placeholder_install_scalar_or_die() {
  local label="${1:?label required}"
  local value="${2-}"
  local source_hint="${3:-config}"
  [[ -n "${value}" ]] || die "${label} must not be empty (${source_hint})"
  if install_value_is_unedited_placeholder "${value}"; then
    die "${label} still contains an unedited template placeholder (${value}); edit the external ${source_hint} before runtime."
  fi
}

disk_identity_for_display_or_empty() {
  local dev="${1:-}"
  [[ -n "${dev}" ]] || return 0
  command -v lsblk >/dev/null 2>&1 || return 0
  lsblk -dno NAME,SIZE,MODEL,SERIAL "${dev}" 2>/dev/null | tr -s ' ' || true
}

detect_preferred_by_id_path_for_device_or_empty() {
  local dev="${1:-}"
  local dev_real path target bn
  local -a preferred=()
  local -a fallback=()

  [[ -n "${dev}" && -b "${dev}" ]] || return 0
  [[ -d /dev/disk/by-id ]] || return 0
  dev_real="$(readlink -f -- "${dev}" 2>/dev/null || true)"
  [[ -n "${dev_real}" ]] || return 0

  while IFS= read -r path; do
    [[ -L "${path}" ]] || continue
    bn="${path##*/}"
    [[ "${bn}" == *-part* ]] && continue
    target="$(readlink -f -- "${path}" 2>/dev/null || true)"
    [[ "${target}" == "${dev_real}" ]] || continue
    case "${bn}" in
      nvme-*|ata-*|scsi-*|wwn-*) preferred+=("${path}") ;;
      *) fallback+=("${path}") ;;
    esac
  done < <(find /dev/disk/by-id -mindepth 1 -maxdepth 1 -type l 2>/dev/null | sort)

  if (( ${#preferred[@]} > 0 )); then
    printf '%s\n' "${preferred[0]}"
    return 0
  fi
  if (( ${#fallback[@]} > 0 )); then
    printf '%s\n' "${fallback[0]}"
  fi
}

disk_bytes_looks_like_default_two_tb() {
  local bytes="${1:-0}"
  [[ "${bytes}" =~ ^[0-9]+$ ]] || return 1
  (( bytes >= 1500000000000 && bytes <= 2500000000000 ))
}

disk_bytes_looks_like_default_four_tb() {
  local bytes="${1:-0}"
  [[ "${bytes}" =~ ^[0-9]+$ ]] || return 1
  (( bytes >= 3000000000000 && bytes <= 5000000000000 ))
}

INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK=""
INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_SYS="/dev/disk/by-id/REPLACE_WITH_SYSTEM_DISK"
INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_DATA="/dev/disk/by-id/REPLACE_WITH_DATA_DISK"

populate_install_layout_template_autodetect_context() {
  INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK=""
  INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_SYS="/dev/disk/by-id/REPLACE_WITH_SYSTEM_DISK"
  INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_DATA="/dev/disk/by-id/REPLACE_WITH_DATA_DISK"

  local comment="# Hardware analysis at template generation time:\n"
  local name bytes rm dtype dev byid info
  local two_tb_hits=0 four_tb_hits=0
  local sys_candidate="" data_candidate="" sys_info="" data_info=""
  local candidate_count=0

  if ! command -v lsblk >/dev/null 2>&1; then
    comment+="# - lsblk is unavailable here; no disk auto-fill was attempted.\n"
    printf -v INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK '%b' "${comment}"
    return 0
  fi

  local lsblk_listing=""
  lsblk_listing="$(lsblk -dnbo NAME,SIZE,RM,TYPE 2>/dev/null || true)"
  if [[ -z "${lsblk_listing}" ]]; then
    comment+="# - lsblk returned no usable whole-disk listing here; no disk auto-fill was attempted.\n"
    printf -v INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK '%b' "${comment}"
    return 0
  fi

  while read -r name bytes rm dtype; do
    [[ -n "${name:-}" ]] || continue
    [[ "${rm}" == "0" && "${dtype}" == "disk" ]] || continue
    dev="/dev/${name}"
    byid="$(detect_preferred_by_id_path_for_device_or_empty "${dev}")"
    info="$(disk_identity_for_display_or_empty "${dev}")"
    candidate_count=$((candidate_count + 1))
    if [[ -n "${byid}" ]]; then
      comment+="#   candidate: ${byid} -> ${info:-unknown}\n"
    else
      comment+="#   candidate: ${dev} (no stable /dev/disk/by-id path found) -> ${info:-unknown}\n"
    fi

    if disk_bytes_looks_like_default_two_tb "${bytes}"; then
      two_tb_hits=$((two_tb_hits + 1))
      if [[ -z "${sys_candidate}" && -n "${byid}" ]]; then
        sys_candidate="${byid}"
        sys_info="${info}"
      fi
    fi
    if disk_bytes_looks_like_default_four_tb "${bytes}"; then
      four_tb_hits=$((four_tb_hits + 1))
      if [[ -z "${data_candidate}" && -n "${byid}" ]]; then
        data_candidate="${byid}"
        data_info="${info}"
      fi
    fi
  done <<< "${lsblk_listing}"

  if (( candidate_count == 0 )); then
    comment+="# - No non-removable whole-disk candidates were detected.\n"
  elif (( two_tb_hits == 1 && four_tb_hits == 1 )) && [[ -n "${sys_candidate}" && -n "${data_candidate}" && "${sys_candidate}" != "${data_candidate}" ]]; then
    INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_SYS="${sys_candidate}"
    INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_DATA="${data_candidate}"
    comment+="# - Auto-filled canonical two-disk mapping from the detected approx. 2 TB + 4 TB hardware pair.\n"
    comment+="#   DISK_SYS  => ${sys_candidate} (${sys_info:-unknown})\n"
    comment+="#   DISK_DATA => ${data_candidate} (${data_info:-unknown})\n"
  else
    comment+="# - Canonical two-disk auto-fill was not applied. Review the candidates above and replace any remaining REPLACE_WITH values manually.\n"
  fi

  printf -v INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK '%b' "${comment}"
}

write_install_layout_config_template_or_die() {
  local out_path="${1:-}"
  [[ -n "${out_path}" ]] || die "write_install_layout_config_template_or_die requires a non-empty path"
  mkdir -p "$(dirname -- "${out_path}")"
  install_template_write_maybe_refuse_existing_target "${out_path}" "install layout config template"

  populate_install_layout_template_autodetect_context

  local tmp_path=""
  tmp_path="$(install_template_mktemp_or_die "${out_path}")"

  cat >"${tmp_path}" <<EOF_INSTALL_LAYOUT_CONFIG
# Penelope install layout config template
# Phase-2 seam:
# - This file overrides the shipped inline install layout defaults.
# - It is evaluated by the destructive full-install / reinstall provisioning path and by --verify-layout-contract.
# - Non-destructive maintenance submodes must not consume this file.
# - Current shipped implementation supports INSTALL_LAYOUT_PROFILE=two-disk, single-disk, three-disk, or four-disk.
# - The shipped default example is the two-disk profile with approx. 2 TB for DISK_SYS and approx. 4 TB for DISK_DATA.
${INSTALL_LAYOUT_TEMPLATE_AUTODETECT_COMMENT_BLOCK}INSTALL_LAYOUT_CONFIG_SCHEMA_VERSION="1"
INSTALL_LAYOUT_PROFILE="two-disk"

# Device placement:
# - two-disk: set DISK_SYS and DISK_DATA; leave DISK_HOME/DISK_ARCHIVE/DISK_BACKUP empty
#   shipped default example: DISK_SYS ~= 2 TB, DISK_DATA ~= 4 TB
# - single-disk: set DISK_SYS and leave DISK_HOME/DISK_DATA/DISK_ARCHIVE/DISK_BACKUP empty
# - three-disk: set DISK_SYS, DISK_HOME, and DISK_DATA; leave DISK_ARCHIVE/DISK_BACKUP empty
#   current shipped meaning: system on DISK_SYS, home on DISK_HOME, archive+backup on DISK_DATA
# - four-disk: set DISK_SYS, DISK_HOME, DISK_ARCHIVE, and DISK_BACKUP; leave DISK_DATA empty
#   current shipped meaning: system on DISK_SYS, home on DISK_HOME, archive on DISK_ARCHIVE, backup on DISK_BACKUP
DISK_SYS="${INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_SYS}"
DISK_HOME=""
DISK_DATA="${INSTALL_LAYOUT_TEMPLATE_AUTODETECT_DISK_DATA}"
DISK_ARCHIVE=""
DISK_BACKUP=""

# Sizing defaults:
# - two-disk: tuned for the shipped default example; ROOT_SIZE_GIB and ARCHIVE_SIZE_GIB are applied; HOME/_backup use remaining capacity
# - single-disk: ROOT_SIZE_GIB, HOME_SIZE_GIB, ARCHIVE_SIZE_GIB are applied; _backup uses remaining capacity
# - three-disk: ROOT uses remaining capacity on DISK_SYS; HOME uses remaining capacity
#   on DISK_HOME; ARCHIVE_SIZE_GIB is applied on DISK_DATA and _backup uses the
#   remaining capacity there
# - four-disk: ROOT_SIZE_GIB is applied on DISK_SYS; HOME/ARCHIVE/BACKUP consume
#   the remaining capacity on their dedicated disks; HOME_SIZE_GIB/ARCHIVE_SIZE_GIB
#   are ignored for four-disk
EFI_SIZE_MIB=512
BOOT_SIZE_MIB=1536
ROOT_SIZE_GIB=220
HOME_SIZE_GIB=200
ARCHIVE_SIZE_GIB=1024
EOF_INSTALL_LAYOUT_CONFIG

  chmod 644 "${tmp_path}" || { rm -f -- "${tmp_path}"; die "Could not set mode 0644 on layout config template temp file: ${tmp_path}"; }
  mv -f -- "${tmp_path}" "${out_path}" || { rm -f -- "${tmp_path}"; die "Could not move layout config template into place: ${out_path}"; }

  printf '%s
' "Wrote install layout config template: ${out_path}"
  local self_cmd layout_q companion_bootstrap_path companion_bootstrap_q
  self_cmd="${SELF_CMD}"
  layout_q="$(penelope_quote_path_for_display "${out_path}")"
  companion_bootstrap_path="$(dirname -- "${out_path}")/penelope-install.bootstrap.conf"
  companion_bootstrap_q="$(penelope_quote_path_for_display "${companion_bootstrap_path}")"
  printf '%s
' "Next steps:"
  printf '  1. Review %s and replace any remaining REPLACE_WITH values before runtime.
' "${layout_q}"
  if [[ -f "${companion_bootstrap_path}" ]]; then
    printf '%s
' '  2. Ensure the matching bootstrap config is edited for the intended next step:'
    printf '%s
' '     no REPLACE_WITH values; set CRED_MASTER_PW for verify when preserved'
    printf '     encrypted roles are in scope; set CRED_LOGIN_PW before a real install: %s
' "${companion_bootstrap_q}"
  else
    printf '  2. Write and edit the matching bootstrap config first: %s --write-bootstrap-config-template %s
' "${self_cmd}" "${companion_bootstrap_q}"
  fi
  printf '  3. Optional config-evolution audit for reused older configs: %s --audit-config-evolution --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${companion_bootstrap_q}" "${layout_q}"
  printf '  4. Optional preflight: sudo -E %s --verify-layout-contract --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${companion_bootstrap_q}" "${layout_q}"
  printf '  5. Real install:       sudo -E %s --bootstrap-config %s --layout-config %s
' "${self_cmd}" "${companion_bootstrap_q}" "${layout_q}"
}

load_install_layout_config_file_or_die() {
  local cfg="${INSTALL_LAYOUT_CONFIG_FILE:-}"
  reset_install_layout_config_seen_state
  [[ -n "${cfg}" ]] || return 0
  [[ -f "${cfg}" ]] || die "Install layout config file not found: ${cfg}"
  [[ -r "${cfg}" ]] || die "Install layout config file is not readable: ${cfg}"

  local line line_no=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no + 1))
    apply_install_layout_config_line_or_die "${line_no}" "${line}"
  done < "${cfg}"
}

refresh_install_layout_derived_devices() {
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      EFI_DEV="$(part_dev "${DISK_SYS}" 1)"
      BOOT_DEV="$(part_dev "${DISK_SYS}" 2)"
      ROOT_LUKS_DEV="$(part_dev "${DISK_SYS}" 3)"
      HOME_LUKS_DEV="$(part_dev "${DISK_SYS}" 4)"
      ARCHIVE_LUKS_DEV="$(part_dev "${DISK_DATA}" 1)"
      BACKUP_DEV="$(part_dev "${DISK_DATA}" 2)"
      ;;
    single-disk)
      EFI_DEV="$(part_dev "${DISK_SYS}" 1)"
      BOOT_DEV="$(part_dev "${DISK_SYS}" 2)"
      ROOT_LUKS_DEV="$(part_dev "${DISK_SYS}" 3)"
      HOME_LUKS_DEV="$(part_dev "${DISK_SYS}" 4)"
      ARCHIVE_LUKS_DEV="$(part_dev "${DISK_SYS}" 5)"
      BACKUP_DEV="$(part_dev "${DISK_SYS}" 6)"
      ;;
    three-disk)
      EFI_DEV="$(part_dev "${DISK_SYS}" 1)"
      BOOT_DEV="$(part_dev "${DISK_SYS}" 2)"
      ROOT_LUKS_DEV="$(part_dev "${DISK_SYS}" 3)"
      HOME_LUKS_DEV="$(part_dev "${DISK_HOME}" 1)"
      ARCHIVE_LUKS_DEV="$(part_dev "${DISK_DATA}" 1)"
      BACKUP_DEV="$(part_dev "${DISK_DATA}" 2)"
      ;;
    four-disk)
      EFI_DEV="$(part_dev "${DISK_SYS}" 1)"
      BOOT_DEV="$(part_dev "${DISK_SYS}" 2)"
      ROOT_LUKS_DEV="$(part_dev "${DISK_SYS}" 3)"
      HOME_LUKS_DEV="$(part_dev "${DISK_HOME}" 1)"
      ARCHIVE_LUKS_DEV="$(part_dev "${DISK_ARCHIVE}" 1)"
      BACKUP_DEV="$(part_dev "${DISK_BACKUP}" 1)"
      ;;
    *)
      die "Cannot derive devices for unsupported INSTALL_LAYOUT_PROFILE='${INSTALL_LAYOUT_PROFILE}'"
      ;;
  esac
}

validate_positive_integer_or_die() {
  local value="${1:-}" label="${2:-value}"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "${label} must be a positive integer (got: ${value:-<empty>})"
}

validate_install_layout_sizes_or_die() {
  validate_positive_integer_or_die "${EFI_SIZE_MIB}" "EFI_SIZE_MIB"
  validate_positive_integer_or_die "${BOOT_SIZE_MIB}" "BOOT_SIZE_MIB"
  validate_positive_integer_or_die "${ROOT_SIZE_GIB}" "ROOT_SIZE_GIB"
  case "${INSTALL_LAYOUT_PROFILE}" in
    single-disk)
      validate_positive_integer_or_die "${HOME_SIZE_GIB}" "HOME_SIZE_GIB"
      validate_positive_integer_or_die "${ARCHIVE_SIZE_GIB}" "ARCHIVE_SIZE_GIB"
      ;;
    two-disk|three-disk)
      validate_positive_integer_or_die "${ARCHIVE_SIZE_GIB}" "ARCHIVE_SIZE_GIB"
      ;;
    four-disk)
      :
      ;;
  esac
}

initialize_install_layout_for_full_install_or_die() {
  [[ -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]] || die "--layout-config is required for the full install provisioning path and for --verify-layout-contract"
  load_install_layout_config_file_or_die
  validate_install_layout_profile_or_die "${INSTALL_LAYOUT_PROFILE}"
  assert_install_layout_no_template_placeholders_or_die
  validate_install_layout_sizes_or_die
  refresh_install_layout_derived_devices
  assert_install_layout_devices_or_die
  assert_install_layout_policy_supported_or_die
}

# Dropbear (initramfs) / operator bootstrap derived names
DROPBEAR_KEY_NAME=""
ADMIN_SSH_KEY_NAME=""
KEY_STAGE_DIR=""
# Mount root
TARGET="/mnt/root"

# ================== HELPERS ==================
# Logging and utility functions are now provided by penelope-common.sh:
#   ts(), log(), warn(), die()
#   require_cmd(), ensure_dir()
# See penelope-common.sh for implementation details.

validate_install_layout_profile_or_die() {
  local profile="${1:-}"
  case "${profile}" in
    two-disk|single-disk|three-disk|four-disk)
      ;;
    custom)
      die "INSTALL_LAYOUT_PROFILE='${profile}' is reserved for a future explicit layout implementation; current shipped values are: two-disk, single-disk, three-disk, four-disk."
      ;;
    *)
      die "Unknown INSTALL_LAYOUT_PROFILE='${profile}' (expected: two-disk, single-disk, three-disk, or four-disk)."
      ;;
  esac
}

assert_install_layout_devices_or_die() {
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      [[ -n "${DISK_SYS}" ]] || die "DISK_SYS must not be empty for INSTALL_LAYOUT_PROFILE=two-disk"
      [[ -z "${DISK_HOME}" ]] || die "INSTALL_LAYOUT_PROFILE=two-disk requires DISK_HOME to be empty"
      [[ -n "${DISK_DATA}" ]] || die "DISK_DATA must not be empty for INSTALL_LAYOUT_PROFILE=two-disk"
      [[ -z "${DISK_ARCHIVE}" ]] || die "INSTALL_LAYOUT_PROFILE=two-disk requires DISK_ARCHIVE to be empty"
      [[ -z "${DISK_BACKUP}" ]] || die "INSTALL_LAYOUT_PROFILE=two-disk requires DISK_BACKUP to be empty"
      [[ "${DISK_SYS}" != "${DISK_DATA}" ]] || die "INSTALL_LAYOUT_PROFILE=two-disk requires two distinct device paths (DISK_SYS != DISK_DATA)"
      ;;
    single-disk)
      [[ -n "${DISK_SYS}" ]] || die "DISK_SYS must not be empty for INSTALL_LAYOUT_PROFILE=single-disk"
      [[ -z "${DISK_HOME}" ]] || die "INSTALL_LAYOUT_PROFILE=single-disk requires DISK_HOME to be empty"
      [[ -z "${DISK_DATA}" ]] || die "INSTALL_LAYOUT_PROFILE=single-disk requires DISK_DATA to be empty"
      [[ -z "${DISK_ARCHIVE}" ]] || die "INSTALL_LAYOUT_PROFILE=single-disk requires DISK_ARCHIVE to be empty"
      [[ -z "${DISK_BACKUP}" ]] || die "INSTALL_LAYOUT_PROFILE=single-disk requires DISK_BACKUP to be empty"
      ;;
    three-disk)
      [[ -n "${DISK_SYS}" ]] || die "DISK_SYS must not be empty for INSTALL_LAYOUT_PROFILE=three-disk"
      [[ -n "${DISK_HOME}" ]] || die "DISK_HOME must not be empty for INSTALL_LAYOUT_PROFILE=three-disk"
      [[ -n "${DISK_DATA}" ]] || die "DISK_DATA must not be empty for INSTALL_LAYOUT_PROFILE=three-disk"
      [[ -z "${DISK_ARCHIVE}" ]] || die "INSTALL_LAYOUT_PROFILE=three-disk requires DISK_ARCHIVE to be empty"
      [[ -z "${DISK_BACKUP}" ]] || die "INSTALL_LAYOUT_PROFILE=three-disk requires DISK_BACKUP to be empty"
      if [[ "${DISK_SYS}" == "${DISK_HOME}" ||
            "${DISK_SYS}" == "${DISK_DATA}" ||
            "${DISK_HOME}" == "${DISK_DATA}" ]]; then
        die "INSTALL_LAYOUT_PROFILE=three-disk requires three distinct device paths (DISK_SYS, DISK_HOME, DISK_DATA)"
      fi
      ;;
    four-disk)
      [[ -n "${DISK_SYS}" ]] || die "DISK_SYS must not be empty for INSTALL_LAYOUT_PROFILE=four-disk"
      [[ -n "${DISK_HOME}" ]] || die "DISK_HOME must not be empty for INSTALL_LAYOUT_PROFILE=four-disk"
      [[ -z "${DISK_DATA}" ]] || die "INSTALL_LAYOUT_PROFILE=four-disk requires DISK_DATA to be empty"
      [[ -n "${DISK_ARCHIVE}" ]] || die "DISK_ARCHIVE must not be empty for INSTALL_LAYOUT_PROFILE=four-disk"
      [[ -n "${DISK_BACKUP}" ]] || die "DISK_BACKUP must not be empty for INSTALL_LAYOUT_PROFILE=four-disk"
      if [[ "${DISK_SYS}" == "${DISK_HOME}" ||
            "${DISK_SYS}" == "${DISK_ARCHIVE}" ||
            "${DISK_SYS}" == "${DISK_BACKUP}" ||
            "${DISK_HOME}" == "${DISK_ARCHIVE}" ||
            "${DISK_HOME}" == "${DISK_BACKUP}" ||
            "${DISK_ARCHIVE}" == "${DISK_BACKUP}" ]]; then
        die "INSTALL_LAYOUT_PROFILE=four-disk requires four distinct device paths (DISK_SYS, DISK_HOME, DISK_ARCHIVE, DISK_BACKUP)"
      fi
      ;;
  esac
}

assert_install_layout_no_template_placeholders_or_die() {
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      require_non_placeholder_install_scalar_or_die "DISK_SYS" "${DISK_SYS}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_DATA" "${DISK_DATA}" "layout-config"
      ;;
    single-disk)
      require_non_placeholder_install_scalar_or_die "DISK_SYS" "${DISK_SYS}" "layout-config"
      ;;
    three-disk)
      require_non_placeholder_install_scalar_or_die "DISK_SYS" "${DISK_SYS}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_HOME" "${DISK_HOME}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_DATA" "${DISK_DATA}" "layout-config"
      ;;
    four-disk)
      require_non_placeholder_install_scalar_or_die "DISK_SYS" "${DISK_SYS}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_HOME" "${DISK_HOME}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_ARCHIVE" "${DISK_ARCHIVE}" "layout-config"
      require_non_placeholder_install_scalar_or_die "DISK_BACKUP" "${DISK_BACKUP}" "layout-config"
      ;;
  esac
}

log_install_layout_contract() {
  if [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE}" ]]; then
    log "Install bootstrap config source: ${INSTALL_BOOTSTRAP_CONFIG_FILE}"
  elif [[ "${INSTALL_OPERATION_MODE}" == "initramfs-only" || "${INSTALL_OPERATION_MODE}" == "managed-artifacts-only" ]]; then
    log "Install bootstrap config source: inferred from running system context"
  else
    log "Install bootstrap config source: inline shipped placeholders"
  fi
  log "Install layout profile: INSTALL_LAYOUT_PROFILE=${INSTALL_LAYOUT_PROFILE}"
  if [[ -n "${INSTALL_LAYOUT_CONFIG_FILE}" ]]; then
    log "Install layout config source: ${INSTALL_LAYOUT_CONFIG_FILE}"
  else
    log "Install layout config source: inline shipped defaults"
  fi
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      log "  logical storage roles: /boot/efi,/boot,/,/home on DISK_SYS; /_archive,/_backup on DISK_DATA"
      log "  sizing defaults: ROOT_SIZE_GIB=${ROOT_SIZE_GIB} ARCHIVE_SIZE_GIB=${ARCHIVE_SIZE_GIB}"
      log "  sizing defaults: EFI_SIZE_MIB=${EFI_SIZE_MIB} BOOT_SIZE_MIB=${BOOT_SIZE_MIB}"
      ;;
    single-disk)
      log "  logical storage roles: /boot/efi,/boot,/,/home,/_archive,/_backup all on DISK_SYS"
      log "  sizing defaults: ROOT_SIZE_GIB=${ROOT_SIZE_GIB} HOME_SIZE_GIB=${HOME_SIZE_GIB} ARCHIVE_SIZE_GIB=${ARCHIVE_SIZE_GIB}"
      log "  sizing defaults: EFI_SIZE_MIB=${EFI_SIZE_MIB} BOOT_SIZE_MIB=${BOOT_SIZE_MIB}"
      ;;
    three-disk)
      log "  logical storage roles: /boot/efi,/boot,/ on DISK_SYS; /home on DISK_HOME; /_archive,/_backup on DISK_DATA"
      log "  sizing defaults: DISK_SYS and DISK_HOME consume remaining capacity after their profile partitions"
      log "  sizing defaults: ARCHIVE_SIZE_GIB=${ARCHIVE_SIZE_GIB} EFI_SIZE_MIB=${EFI_SIZE_MIB} BOOT_SIZE_MIB=${BOOT_SIZE_MIB}"
      ;;
    four-disk)
      log "  logical storage roles: /boot/efi,/boot,/ on DISK_SYS; /home on DISK_HOME; /_archive on DISK_ARCHIVE; /_backup on DISK_BACKUP"
      log "  sizing defaults: ROOT_SIZE_GIB=${ROOT_SIZE_GIB} on DISK_SYS"
      log "  sizing defaults: DISK_HOME, DISK_ARCHIVE, and DISK_BACKUP consume remaining capacity after their profile partitions"
      log "  sizing defaults: EFI_SIZE_MIB=${EFI_SIZE_MIB} BOOT_SIZE_MIB=${BOOT_SIZE_MIB}"
      ;;
  esac
}

validate_hostname_or_die() {
  local hn="${1:-}"
  [[ -n "$hn" ]] || die "TARGET_HOST must not be empty" 2
  # Strict but practical: lower-case letters, digits, hyphen; 1..63; no leading/trailing hyphen.
  if ! [[ "$hn" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Invalid TARGET_HOST (expected RFC1123-like hostname label): '$hn'" 2
  fi
}

validate_username_or_die() {
  local un="${1:-}"
  [[ -n "$un" ]] || die "ADMIN_USER must not be empty" 2
  # Linux user name: starts with [a-z_], then [a-z0-9_-], length 1..31 (typical).
  if ! [[ "$un" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
    die "Invalid ADMIN_USER: '$un' (expected: ^[a-z_][a-z0-9_-]{0,30}$)" 2
  fi
}

# --- Recreation policy helpers ---
normalize_list() {
  # lower-case, remove whitespace
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r\n'
}

list_has_token() {
  local list token
  list="$(normalize_list "$1")"
  token="$(normalize_list "$2")"
  [[ ",${list}," == *",${token},"* ]]
}

validate_recreation_targets() {
  local list
  list="$(normalize_list "${RECREATION_TARGET_LIST}")"
  [[ -n "$list" ]] || die "RECREATION_TARGET_LIST is empty (expected: all or a comma-separated list including system)."

  # allow all as a shortcut
  if list_has_token "$list" "all"; then
    return 0
  fi

  # must contain system
  if ! list_has_token "$list" "system"; then
    die "RECREATION_TARGET_LIST must contain 'system' or 'all' (current: ${RECREATION_TARGET_LIST})."
  fi

  # validate tokens
  local tok
  IFS=',' read -r -a toks <<<"$list"
  for tok in "${toks[@]}"; do
    case "$tok" in
      system|home|_archive|_backup) : ;;
      "") : ;;
      *) die "Invalid token in RECREATION_TARGET_LIST: '$tok' (allowed: system,home,_archive,_backup,all)." ;;
    esac
  done
}

init_recreation_policy() {
  validate_recreation_targets

  local list
  list="$(normalize_list "${RECREATION_TARGET_LIST}")"

  if list_has_token "$list" "all"; then
    RECREATE_SYSTEM=1
    RECREATE_HOME=1
    RECREATE_ARCHIVE=1
    RECREATE_BACKUP=1
  else
    RECREATE_SYSTEM=1  # enforced by validation
    RECREATE_HOME=$([[ ",${list}," == *",home,"* ]] && echo 1 || echo 0)
    RECREATE_ARCHIVE=$([[ ",${list}," == *",_archive,"* ]] && echo 1 || echo 0)
    RECREATE_BACKUP=$([[ ",${list}," == *",_backup,"* ]] && echo 1 || echo 0)
  fi

  log "Recreation policy: RECREATION_TARGET_LIST=${RECREATION_TARGET_LIST}" \
    "(system=${RECREATE_SYSTEM} home=${RECREATE_HOME} _archive=${RECREATE_ARCHIVE} _backup=${RECREATE_BACKUP})"
  log "Policy note: 'system' includes refreshing /boot and /boot/efi (always)."

  if profile_requires_fixed_layout_preserve_verification; then
    log "Policy note: $(layout_profile_fixed_layout_contract_description_or_die "${INSTALL_LAYOUT_PROFILE}")"
  fi

  # Operator visibility: explicitly state preserved targets
  if [[ "${RECREATE_HOME}" == "0" ]]; then log "-> Preserve: /home (no wipefs/luksFormat/mkfs)"; fi
  if [[ "${RECREATE_ARCHIVE}" == "0" ]]; then log "-> Preserve: /_archive (no wipefs/luksFormat/mkfs)"; fi
  if [[ "${RECREATE_BACKUP}" == "0" ]]; then log "-> Preserve: /_backup (no wipefs/mkfs)"; fi
}

assert_install_layout_policy_supported_or_die() {
  # Reserved policy seam: profile, device, size, preserve-target, and placeholder
  # constraints are enforced by the preceding install layout validators. Keep this
  # hook explicit so future layout policy gates have one stable insertion point.
  return 0
}

test_luks_password_or_die() {
  local dev="$1"
  local label="$2"
  [[ -b "$dev" ]] || die "Device missing for LUKS check: $dev ($label)."

  if ! cryptsetup isLuks "$dev" >/dev/null 2>&1; then
    die "Preserve target '$label' expects LUKS, but $dev is not a LUKS device."
  fi

  local name
  name="penelope_check_$(basename "$dev")_$$"
  if ! ( case $- in
    *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } ;;
    *)  printf '%s' "$CRED_MASTER_PW" ;;
  esac | cryptsetup open --key-file - "$dev" "$name" >/dev/null 2>&1 ); then
    die "CRED_MASTER_PW does NOT match the existing LUKS partition $dev ($label). Preserve mode is not possible."
  fi

  log "-> Preserve: CRED_MASTER_PW OK for $label ($dev)"
  cryptsetup close "$name" >/dev/null 2>&1 || true
}

layout_profile_preserve_next_steps_or_die() {
  local profile="$1"
  case "$profile" in
    single-disk)
      echo "Keep INSTALL_LAYOUT_PROFILE=single-disk; keep the existing single-disk role" \
        "partition order/sizing unchanged for preserved targets, or switch to" \
        "RECREATION_TARGET_LIST=all / a separate migration workflow."
      ;;
    two-disk)
      echo "Keep preserved disks on the shipped two-disk role layout without" \
        "repartitioning/resizing, or recreate the drifting disk in this run / use" \
        "RECREATION_TARGET_LIST=all / a separate migration workflow."
      ;;
    three-disk)
      echo "Keep preserved home/data disks on the shipped three-disk role layout" \
        "without repartitioning/resizing, or recreate the drifting preserved disk" \
        "in this run / use RECREATION_TARGET_LIST=all / a separate migration workflow."
      ;;
    four-disk)
      echo "Keep preserved home/archive/backup disks on the shipped four-disk role" \
        "layout without repartitioning/resizing, or recreate the drifting preserved" \
        "disk in this run / use RECREATION_TARGET_LIST=all / a separate migration workflow."
      ;;
    *)
      die "No fixed-layout preserve next-step hint registered for install layout profile '$profile'."
      ;;
  esac
}

layout_preserve_drift_die() {
  local reason="$1"
  local profile="$2"
  local contract next_steps preserve_targets verification_targets message

  contract="$(layout_profile_fixed_layout_contract_description_or_die "$profile")"
  next_steps="$(layout_profile_preserve_next_steps_or_die "$profile")"
  preserve_targets="$(preserved_role_targets_csv_or_none)"
  verification_targets="$(fixed_layout_verification_targets_csv_or_none)"

  message="${profile} selective preserve/recreate requires a verified fixed-layout contract. "
  message+="Reason: ${reason}. "
  message+="Preserve targets: ${preserve_targets}. "
  message+="Verification targets: ${verification_targets}. "
  message+="Contract: ${contract} "
  message+="Next step: ${next_steps}"
  die "${message}"
}

profile_requires_fixed_layout_preserve_verification() {
  # Any selective preserve/recreate run (i.e. at least one target remains) may require
  # profile-specific fixed-layout verification before destructive steps.
  if [[ "${RECREATE_HOME:-1}" == "1" && "${RECREATE_ARCHIVE:-1}" == "1" && "${RECREATE_BACKUP:-1}" == "1" ]]; then
    return 1
  fi
  case "${INSTALL_LAYOUT_PROFILE}" in
    single-disk|two-disk|three-disk|four-disk) return 0 ;;
    *) return 1 ;;
  esac
}

layout_profile_fixed_layout_contract_description_or_die() {
  local profile="$1"
  case "$profile" in
    single-disk)
      echo "single-disk selective preserve/recreate is allowed only in fixed-layout" \
        "mode (same profile, unchanged role-partition order/mapping, no" \
        "repartitioning/resizing, existing role layout must verify before destructive steps)."
      ;;
    two-disk)
      echo "two-disk selective preserve/recreate is allowed only when each preserved" \
        "disk still matches the shipped two-disk role-partition contract closely" \
        "enough that no repartitioning/resizing is required on that preserved disk." \
        "Fully recreated disks may still be repartitioned."
      ;;
    three-disk)
      echo "three-disk selective preserve/recreate is allowed only when each preserved" \
        "disk still matches the shipped three-disk role-partition contract closely" \
        "enough that no repartitioning/resizing is required on that preserved disk." \
        "The system disk is always recreated; preserved home/data disks must verify" \
        "before destructive steps."
      ;;
    four-disk)
      echo "four-disk selective preserve/recreate is allowed only when each preserved" \
        "disk still matches the shipped four-disk role-partition contract closely" \
        "enough that no repartitioning/resizing is required on that preserved disk." \
        "The system disk is always recreated; preserved home/archive/backup disks" \
        "must verify before destructive steps."
      ;;
    *)
      die "No fixed-layout preserve contract description registered for install layout profile '$profile'."
      ;;
  esac
}

layout_profile_verification_targets_or_die() {
  local profile="$1"
  local targets=()
  case "$profile" in
    single-disk)
      targets+=("sys")
      ;;
    two-disk)
      [[ "${RECREATE_HOME}" == "0" ]] && targets+=("sys")
      if [[ "${RECREATE_ARCHIVE}" == "0" || "${RECREATE_BACKUP}" == "0" ]]; then
        targets+=("data")
      fi
      ;;
    three-disk)
      [[ "${RECREATE_HOME}" == "0" ]] && targets+=("home")
      if [[ "${RECREATE_ARCHIVE}" == "0" || "${RECREATE_BACKUP}" == "0" ]]; then
        targets+=("data")
      fi
      ;;
    four-disk)
      [[ "${RECREATE_HOME}" == "0" ]] && targets+=("home")
      [[ "${RECREATE_ARCHIVE}" == "0" ]] && targets+=("archive")
      [[ "${RECREATE_BACKUP}" == "0" ]] && targets+=("backup")
      ;;
    *)
      die "No fixed-layout verification target dispatcher registered for install layout profile '$profile'."
      ;;
  esac
  [[ ${#targets[@]} -gt 0 ]] || die "No preserved disk targets require fixed-layout verification for install layout profile '$profile'."
  printf '%s
' "${targets[@]}"
}

layout_profile_target_disk_or_die() {
  local profile="$1"
  local target="$2"
  case "$profile:$target" in
    single-disk:sys|two-disk:sys) echo "${DISK_SYS}" ;;
    two-disk:data|three-disk:data) echo "${DISK_DATA}" ;;
    three-disk:home|four-disk:home) echo "${DISK_HOME}" ;;
    four-disk:archive) echo "${DISK_ARCHIVE}" ;;
    four-disk:backup) echo "${DISK_BACKUP}" ;;
    *) die "No fixed-layout target disk mapping registered for install layout profile '$profile' target '$target'." ;;
  esac
}


layout_profile_target_roles_csv_or_die() {
  local profile="$1"
  local target="$2"
  case "$profile:$target" in
    single-disk:sys) echo "/boot/efi,/boot,/,/home,/_archive,/_backup" ;;
    two-disk:sys) echo "/boot/efi,/boot,/,/home" ;;
    two-disk:data|three-disk:data) echo "/_archive,/_backup" ;;
    three-disk:home|four-disk:home) echo "/home" ;;
    four-disk:archive) echo "/_archive" ;;
    four-disk:backup) echo "/_backup" ;;
    *) die "No fixed-layout role summary registered for install layout profile '$profile' target '$target'." ;;
  esac
}

layout_profile_target_expected_partlabels_csv_or_die() {
  local profile="$1"
  local target="$2"
  local expected_count partnum
  local -a labels=()
  expected_count="$(layout_profile_expected_partition_count_or_die "$profile" "$target")"
  for (( partnum=1; partnum<=expected_count; partnum++ )); do
    labels+=("$(layout_profile_expected_partlabel_or_die "$profile" "$target" "$partnum")")
  done
  (IFS=,; echo "${labels[*]}")
}

layout_profile_target_size_contract_summary_or_die() {
  local profile="$1"
  local target="$2"
  case "$profile:$target" in
    single-disk:sys)
      echo "p1=EFI_SIZE_MIB,p2=BOOT_SIZE_MIB,p3=ROOT_SIZE_GIB,p4=HOME_SIZE_GIB,p5=ARCHIVE_SIZE_GIB,p6=remaining"
      ;;
    two-disk:sys)
      echo "p1=EFI_SIZE_MIB,p2=BOOT_SIZE_MIB,p3=ROOT_SIZE_GIB,p4=remaining"
      ;;
    two-disk:data|three-disk:data)
      echo "p1=ARCHIVE_SIZE_GIB,p2=remaining"
      ;;
    three-disk:home|four-disk:home|four-disk:archive|four-disk:backup)
      echo "p1=remaining"
      ;;
    *)
      die "No fixed-layout size-contract summary registered for install layout profile '$profile' target '$target'."
      ;;
  esac
}

recreated_role_targets_csv_or_none() {
  local -a targets=("system")
  [[ "${RECREATE_HOME:-0}" == "1" ]] && targets+=("home")
  [[ "${RECREATE_ARCHIVE:-0}" == "1" ]] && targets+=("_archive")
  [[ "${RECREATE_BACKUP:-0}" == "1" ]] && targets+=("_backup")
  (IFS=,; echo "${targets[*]}")
}

preserved_role_targets_csv_or_none() {
  local -a targets=()
  [[ "${RECREATE_HOME:-1}" == "0" ]] && targets+=("home")
  [[ "${RECREATE_ARCHIVE:-1}" == "0" ]] && targets+=("_archive")
  [[ "${RECREATE_BACKUP:-1}" == "0" ]] && targets+=("_backup")
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "none"
  else
    (IFS=,; echo "${targets[*]}")
  fi
}

fixed_layout_verification_targets_csv_or_none() {
  local -a targets=()
  if profile_requires_fixed_layout_preserve_verification; then
    mapfile -t targets < <(layout_profile_verification_targets_or_die "${INSTALL_LAYOUT_PROFILE}")
  fi
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "none"
  else
    (IFS=,; echo "${targets[*]}")
  fi
}

layout_profile_expected_partition_count_or_die() {
  local profile="$1"
  local target="$2"
  case "$profile:$target" in
    single-disk:sys) echo 6 ;;
    two-disk:sys) echo 4 ;;
    two-disk:data|three-disk:data) echo 2 ;;
    three-disk:home|four-disk:home|four-disk:archive|four-disk:backup) echo 1 ;;
    *) die "No fixed-layout partition-count contract registered for install layout profile '$profile' target '$target'." ;;
  esac
}

layout_profile_expected_size_bytes_or_empty() {
  local profile="$1"
  local target="$2"
  local partnum="$3"
  case "$profile:$target" in
    single-disk:sys)
      case "$partnum" in
        1) echo $(( EFI_SIZE_MIB * 1024 * 1024 )) ;;
        2) echo $(( BOOT_SIZE_MIB * 1024 * 1024 )) ;;
        3) echo $(( ROOT_SIZE_GIB * 1024 * 1024 * 1024 )) ;;
        4) echo $(( HOME_SIZE_GIB * 1024 * 1024 * 1024 )) ;;
        5) echo $(( ARCHIVE_SIZE_GIB * 1024 * 1024 * 1024 )) ;;
        6) echo "" ;;
        *) die "No expected single-disk size mapping for partition number $partnum." ;;
      esac
      ;;
    two-disk:sys)
      case "$partnum" in
        1) echo $(( EFI_SIZE_MIB * 1024 * 1024 )) ;;
        2) echo $(( BOOT_SIZE_MIB * 1024 * 1024 )) ;;
        3) echo $(( ROOT_SIZE_GIB * 1024 * 1024 * 1024 )) ;;
        4) echo "" ;;
        *) die "No expected two-disk system-disk size mapping for partition number $partnum." ;;
      esac
      ;;
    two-disk:data|three-disk:data)
      case "$partnum" in
        1) echo $(( ARCHIVE_SIZE_GIB * 1024 * 1024 * 1024 )) ;;
        2) echo "" ;;
        *) die "No expected ${profile} data-disk size mapping for partition number $partnum." ;;
      esac
      ;;
    three-disk:home)
      case "$partnum" in
        1) echo "" ;;
        *) die "No expected three-disk home-disk size mapping for partition number $partnum." ;;
      esac
      ;;
    four-disk:home|four-disk:archive|four-disk:backup)
      case "$partnum" in
        1) echo "" ;;
        *) die "No expected ${profile} ${target}-disk size mapping for partition number $partnum." ;;
      esac
      ;;
    *)
      die "No fixed-layout size contract registered for install layout profile '$profile' target '$target'."
      ;;
  esac
}

layout_profile_expected_partlabel_or_die() {
  local profile="$1"
  local target="$2"
  local partnum="$3"
  case "$profile:$target" in
    single-disk:sys)
      case "$partnum" in
        1) echo "EFI" ;;
        2) echo "BOOT" ;;
        3) echo "ROOT_LUKS" ;;
        4) echo "HOME_LUKS" ;;
        5) echo "ARCHIVE_LUKS" ;;
        6) echo "_BACKUP" ;;
        *) die "No expected single-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    two-disk:sys)
      case "$partnum" in
        1) echo "EFI" ;;
        2) echo "BOOT" ;;
        3) echo "ROOT_LUKS" ;;
        4) echo "HOME_LUKS" ;;
        *) die "No expected two-disk system-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    two-disk:data|three-disk:data)
      case "$partnum" in
        1) echo "ARCHIVE_LUKS" ;;
        2) echo "_BACKUP" ;;
        *) die "No expected ${profile} data-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    three-disk:home)
      case "$partnum" in
        1) echo "HOME_LUKS" ;;
        *) die "No expected three-disk home-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    four-disk:home)
      case "$partnum" in
        1) echo "HOME_LUKS" ;;
        *) die "No expected four-disk home-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    four-disk:archive)
      case "$partnum" in
        1) echo "ARCHIVE_LUKS" ;;
        *) die "No expected four-disk archive-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    four-disk:backup)
      case "$partnum" in
        1) echo "_BACKUP" ;;
        *) die "No expected four-disk backup-disk PARTLABEL mapping for partition number $partnum." ;;
      esac
      ;;
    *)
      die "No fixed-layout PARTLABEL contract registered for install layout profile '$profile' target '$target'."
      ;;
  esac
}

verify_partition_partlabel_or_die() {
  local dev="$1"
  local expected="$2"
  local profile="$3"
  local target="$4"
  [[ -b "$dev" ]] || layout_preserve_drift_die "expected partition device $dev for PARTLABEL verification on ${profile}/${target}, but it is missing" "$profile"
  command -v blkid >/dev/null 2>&1 || die "blkid is required for fixed-layout verification."
  local actual
  actual="$(blkid -o value -s PARTLABEL "$dev" 2>/dev/null || true)"
  [[ -n "$actual" ]] || layout_preserve_drift_die "expected PARTLABEL=${expected} on ${dev} for ${profile}/${target}, but blkid returned no PARTLABEL" "$profile"
  [[ "$actual" == "$expected" ]] || layout_preserve_drift_die "expected PARTLABEL=${expected} on ${dev} for ${profile}/${target}, but found PARTLABEL=${actual}" "$profile"
}

verify_partition_size_close_or_die() {
  local dev="$1"
  local expected_bytes="$2"
  local label="$3"
  local profile="$4"
  local target="$5"
  [[ -b "$dev" ]] || layout_preserve_drift_die "expected partition device ${dev} for size verification on ${profile}/${target}, but it is missing" "$profile"
  command -v blockdev >/dev/null 2>&1 || die "blockdev is required for fixed-layout verification."
  local actual_bytes diff tolerance_bytes
  actual_bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || true)"
  [[ "$actual_bytes" =~ ^[0-9]+$ ]] || die "Could not read partition size for $dev ($label)."
  diff=$(( actual_bytes - expected_bytes ))
  if (( diff < 0 )); then
    diff=$(( -diff ))
  fi
  tolerance_bytes=$(( 16 * 1024 * 1024 ))
  if (( diff > tolerance_bytes )); then
    local reason
    reason="${label} on ${dev} for ${profile}/${target} expected about ${expected_bytes} bytes "
    reason+="but found ${actual_bytes} bytes (tolerance ${tolerance_bytes})"
    layout_preserve_drift_die "${reason}" "$profile"
  fi
}

verify_profile_fixed_layout_or_die() {
  local profile="$1"
  local list partnum dev expected_label expected_bytes actual_count expected_count disk target roles_summary expected_labels size_summary target_summary
  local -a targets=()
  list="$(normalize_list "${RECREATION_TARGET_LIST}")"
  [[ "$list" != "all" ]] || return 0

  mapfile -t targets < <(layout_profile_verification_targets_or_die "$profile")
  [[ ${#targets[@]} -gt 0 ]] || die "No fixed-layout preserve verifier targets registered for install layout profile '$profile'."
  log "-> ${profile} preserve contract: $(layout_profile_fixed_layout_contract_description_or_die "$profile")"
  log "-> ${profile} preserved verification targets: ${targets[*]}"
  log "-> ${profile} next-step hint on drift: $(layout_profile_preserve_next_steps_or_die "$profile")"

  for target in "${targets[@]}"; do
    disk="$(layout_profile_target_disk_or_die "$profile" "$target")"
    log "-> ${profile} preserve mode: verifying reusable fixed-layout contract for ${target} disk before destructive steps"
    [[ -n "$disk" ]] || die "${profile} fixed-layout verification requires a concrete disk path for target '${target}'."
    [[ -b "$disk" ]] || die "${profile} fixed-layout verification expected disk $disk for target '${target}', but it does not exist as a block device."

    expected_count="$(layout_profile_expected_partition_count_or_die "$profile" "$target")"
    roles_summary="$(layout_profile_target_roles_csv_or_die "$profile" "$target")"
    expected_labels="$(layout_profile_target_expected_partlabels_csv_or_die "$profile" "$target")"
    size_summary="$(layout_profile_target_size_contract_summary_or_die "$profile" "$target")"
    target_summary="-> ${profile}/${target}: disk=${disk} roles=${roles_summary} "
    target_summary+="expected_partitions=${expected_count} "
    target_summary+="expected_partlabels=${expected_labels} "
    target_summary+="size_contract=${size_summary}"
    log "${target_summary}"
    if command -v lsblk >/dev/null 2>&1; then
      actual_count="$(lsblk -lnpo TYPE "$disk" 2>/dev/null | grep -c '^part$' || true)"
      if [[ "$actual_count" != "$expected_count" ]]; then
        layout_preserve_drift_die           "expected exactly ${expected_count} partitions on ${disk} for ${profile}/${target}, found ${actual_count:-0}"           "$profile"
      fi
    fi

    for (( partnum=1; partnum<=expected_count; partnum++ )); do
      dev="$(part_dev "$disk" "$partnum")"
      [[ -b "$dev" ]] || layout_preserve_drift_die "expected partition ${dev} (part ${partnum}) for ${profile}/${target}, but it is missing" "$profile"
      expected_label="$(layout_profile_expected_partlabel_or_die "$profile" "$target" "$partnum")"
      verify_partition_partlabel_or_die "$dev" "$expected_label" "$profile" "$target"
      expected_bytes="$(layout_profile_expected_size_bytes_or_empty "$profile" "$target" "$partnum")"
      if [[ -n "$expected_bytes" ]]; then
        verify_partition_size_close_or_die "$dev" "$expected_bytes" "$expected_label" "$profile" "$target"
      fi
    done
    log "-> ${profile}/${target}: verification OK (${disk})"
  done

  log "-> ${profile} fixed-layout verification OK: preserved disks match" \
    "registered partition count/order, PARTLABEL, and configured size contract."
}

verify_preserved_targets_or_die() {
  if profile_requires_fixed_layout_preserve_verification; then
    verify_profile_fixed_layout_or_die "${INSTALL_LAYOUT_PROFILE}"
  fi

  # If we preserve encrypted targets, ensure CRED_MASTER_PW can open them.
  if [[ "${RECREATE_HOME}" == "0" ]]; then
    log "-> Preserve: /home remains unchanged. Checking CRED_MASTER_PW against $HOME_LUKS_DEV"
    test_luks_password_or_die "$HOME_LUKS_DEV" "home"
  fi
  if [[ "${RECREATE_ARCHIVE}" == "0" ]]; then
    log "-> Preserve: /_archive remains unchanged. Checking CRED_MASTER_PW against $ARCHIVE_LUKS_DEV"
    test_luks_password_or_die "$ARCHIVE_LUKS_DEV" "_archive"
  fi

  # _backup is unencrypted; verify the preserve-path filesystem contract early.
  if [[ "${RECREATE_BACKUP}" == "0" ]]; then
    [[ -b "$BACKUP_DEV" ]] || die "Preserve target _backup expects device $BACKUP_DEV, but it does not exist."
    if command -v blkid >/dev/null 2>&1; then
      local btype blabel buuid
      btype="$(blkid -o value -s TYPE "$BACKUP_DEV" 2>/dev/null || true)"
      blabel="$(blkid -o value -s LABEL "$BACKUP_DEV" 2>/dev/null || true)"
      buuid="$(blkid -o value -s UUID "$BACKUP_DEV" 2>/dev/null || true)"
      if [[ -n "$btype" && "$btype" != "ext4" ]]; then
        # Severity: fatal. Preserve mode with wrong _backup FS type can break expected backup workflow after install.
        die "Preserve target _backup expects ext4, but TYPE=${btype} is set on $BACKUP_DEV."
      fi
      if [[ -z "$buuid" ]]; then
        # Severity: fatal. The installed-system mount contract for /_backup is UUID-based.
        die "Preserve target _backup expects a readable UUID on $BACKUP_DEV, but blkid returned no UUID."
      fi
      if [[ "$blabel" != "_backup" ]]; then
        # Severity: fatal. Preserve mode requires the canonical _backup LABEL, even if the current value is empty.
        die "Preserve target _backup expects LABEL=_backup, but LABEL=${blabel:-<empty>} is set on $BACKUP_DEV."
      fi
    fi
  fi
}

preflight_layout_snapshot() {
  log "-> Preflight: Layout Snapshot (lsblk/blkid/sgdisk)"
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_DATA}" || true
      fi
      if command -v blkid >/dev/null 2>&1; then
        blkid \
          "$DISK_SYS" "$DISK_DATA" "$EFI_DEV" "$BOOT_DEV" \
          "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" \
          2>/dev/null || true
      fi
      if command -v sgdisk >/dev/null 2>&1; then
        sgdisk -p "${DISK_SYS}" || true
        sgdisk -p "${DISK_DATA}" || true
      fi
      ;;
    three-disk)
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_HOME}" "${DISK_DATA}" || true
      fi
      if command -v blkid >/dev/null 2>&1; then
        blkid \
          "$DISK_SYS" "$DISK_HOME" "$DISK_DATA" "$EFI_DEV" "$BOOT_DEV" \
          "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" \
          2>/dev/null || true
      fi
      if command -v sgdisk >/dev/null 2>&1; then
        sgdisk -p "${DISK_SYS}" || true
        sgdisk -p "${DISK_HOME}" || true
        sgdisk -p "${DISK_DATA}" || true
      fi
      ;;
    four-disk)
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_HOME}" "${DISK_ARCHIVE}" "${DISK_BACKUP}" || true
      fi
      if command -v blkid >/dev/null 2>&1; then
        blkid \
          "$DISK_SYS" "$DISK_HOME" "$DISK_ARCHIVE" "$DISK_BACKUP" \
          "$EFI_DEV" "$BOOT_DEV" "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" \
          "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" \
          2>/dev/null || true
      fi
      if command -v sgdisk >/dev/null 2>&1; then
        sgdisk -p "${DISK_SYS}" || true
        sgdisk -p "${DISK_HOME}" || true
        sgdisk -p "${DISK_ARCHIVE}" || true
        sgdisk -p "${DISK_BACKUP}" || true
      fi
      ;;
    single-disk)
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" || true
      fi
      if command -v blkid >/dev/null 2>&1; then
        blkid "$DISK_SYS" "$EFI_DEV" "$BOOT_DEV"           "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV"           "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" 2>/dev/null || true
      fi
      if command -v sgdisk >/dev/null 2>&1; then
        sgdisk -p "${DISK_SYS}" || true
      fi
      ;;
  esac
}

print_install_plan() {
  log "-> Install plan (summary)"
  log_install_layout_contract

  local sys_info
  local home_info
  local data_info
  local archive_info
  local backup_info
  sys_info="$(disk_identity_for_display_or_empty "$DISK_SYS")"
  home_info="$(disk_identity_for_display_or_empty "$DISK_HOME")"
  data_info="$(disk_identity_for_display_or_empty "$DISK_DATA")"
  archive_info="$(disk_identity_for_display_or_empty "$DISK_ARCHIVE")"
  backup_info="$(disk_identity_for_display_or_empty "$DISK_BACKUP")"

  log "Targets: TARGET_HOST=${TARGET_HOST} ADMIN_USER=${ADMIN_USER}"
  log "Disks:"
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      log "  DISK_SYS=${DISK_SYS} (${sys_info:-unknown})"
      log "  DISK_DATA=${DISK_DATA} (${data_info:-unknown})"
      ;;
    single-disk)
      log "  DISK_SYS=${DISK_SYS} (${sys_info:-unknown})"
      ;;
    three-disk)
      log "  DISK_SYS=${DISK_SYS} (${sys_info:-unknown})"
      log "  DISK_HOME=${DISK_HOME} (${home_info:-unknown})"
      log "  DISK_DATA=${DISK_DATA} (${data_info:-unknown})"
      ;;
    four-disk)
      log "  DISK_SYS=${DISK_SYS} (${sys_info:-unknown})"
      log "  DISK_HOME=${DISK_HOME} (${home_info:-unknown})"
      log "  DISK_ARCHIVE=${DISK_ARCHIVE} (${archive_info:-unknown})"
      log "  DISK_BACKUP=${DISK_BACKUP} (${backup_info:-unknown})"
      ;;
  esac

  log "Devices:"
  log "  EFI_DEV=${EFI_DEV} BOOT_DEV=${BOOT_DEV}"
  log "  ROOT_LUKS_DEV=${ROOT_LUKS_DEV} HOME_LUKS_DEV=${HOME_LUKS_DEV}"
  log "  ARCHIVE_LUKS_DEV=${ARCHIVE_LUKS_DEV} BACKUP_DEV=${BACKUP_DEV}"

  log "Policy: RECREATION_TARGET_LIST=${RECREATION_TARGET_LIST}"
  log "  system=${RECREATE_SYSTEM} home=${RECREATE_HOME} _archive=${RECREATE_ARCHIVE} _backup=${RECREATE_BACKUP}"
  log "Requested recreate targets: $(recreated_role_targets_csv_or_none)"
  log "Requested preserve targets: $(preserved_role_targets_csv_or_none)"
  log "Fixed-layout verification targets: $(fixed_layout_verification_targets_csv_or_none)"

  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "Plan: DISK_SYS will be wiped (partition table + signatures)."
        log "      EFI/BOOT/ROOT/HOME will be recreated (luksFormat + mkfs)."
      else
        log "Plan: DISK_SYS partition table preserved (fixed-layout verification required)."
        log "      EFI/BOOT/ROOT refreshed; HOME preserved (no luksFormat/mkfs)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          log "Plan: DISK_DATA will be wiped (partition table + signatures)."
          log "      _archive and _backup will be recreated."
        else
          log "Plan: DISK_DATA partition table preserved (fixed-layout verification required)."
          log "      _archive will be recreated; _backup preserved."
        fi
      else
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          log "Plan: _backup will be reformatted on ${BACKUP_DEV}."
          log "      _archive preserved (no luksFormat/mkfs)."
        else
          log "Plan: DISK_DATA preserved (fixed-layout verification required; _archive and _backup unchanged)."
        fi
      fi
      ;;
    single-disk)
      if [[ "$(normalize_list "${RECREATION_TARGET_LIST}")" == "all" ]]; then
        log "Plan: single-disk full recreation."
        log "      DISK_SYS will be wiped (partition table + signatures)."
        log "      EFI/BOOT/ROOT/HOME/_archive/_backup will be recreated."
      else
        log "Plan: single-disk fixed-layout preserve/recreate."
        log "      Reusable profile-verification scaffold runs before destructive steps; partition table stays unchanged."
        log "      /boot/efi, /boot, and / are always refreshed as part of system."
        if [[ "${RECREATE_HOME}" == "1" ]]; then
          log "      /home will be recreated on its existing partition."
        else
          log "      /home will be preserved on its existing partition."
        fi
        if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
          log "      /_archive will be recreated on its existing partition."
        else
          log "      /_archive will be preserved on its existing partition."
        fi
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          log "      /_backup will be recreated on its existing partition."
        else
          log "      /_backup will be preserved on its existing partition."
        fi
      fi
      ;;
    three-disk)
      log "Plan: three-disk verification-first preserve/recreate."
      log "      DISK_SYS is always wiped and recreated for EFI/BOOT/ROOT."
      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "      DISK_HOME will be wiped and recreated for HOME."
      else
        log "      DISK_HOME preserved (fixed-layout verification required); HOME unchanged."
      fi
      if [[ "${RECREATE_ARCHIVE}" == "1" && "${RECREATE_BACKUP}" == "1" ]]; then
        log "      DISK_DATA will be wiped and recreated for _archive/_backup."
      elif [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
        log "      DISK_DATA partition table preserved (fixed-layout verification required); _archive recreated, _backup preserved."
      elif [[ "${RECREATE_BACKUP}" == "1" ]]; then
        log "      DISK_DATA partition table preserved (fixed-layout verification required); _archive preserved, _backup recreated."
      else
        log "      DISK_DATA preserved (fixed-layout verification required); _archive and _backup unchanged."
      fi
      ;;
    four-disk)
      log "Plan: four-disk verification-first preserve/recreate."
      log "      DISK_SYS is always wiped and recreated for EFI/BOOT/ROOT."
      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "      DISK_HOME will be wiped and recreated for HOME."
      else
        log "      DISK_HOME preserved (fixed-layout verification required); HOME unchanged."
      fi
      if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
        log "      DISK_ARCHIVE will be wiped and recreated for _archive."
      else
        log "      DISK_ARCHIVE preserved (fixed-layout verification required); _archive unchanged."
      fi
      if [[ "${RECREATE_BACKUP}" == "1" ]]; then
        log "      DISK_BACKUP will be wiped and recreated for _backup."
      else
        log "      DISK_BACKUP preserved (fixed-layout verification required); _backup unchanged."
      fi
      ;;
  esac

  log "Destructive steps will start after confirmation."
}

confirm_plan_or_exit() {
  if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
    warn "NON_INTERACTIVE=1: proceeding without confirmation."
    return 0
  fi

  local reply
  if [[ -r /dev/tty ]]; then
    >&2 printf '%s' 'Do you want to apply these changes? (yes/no): '
    read -r reply </dev/tty || die "Failed to read confirmation from /dev/tty."
  else
    die "No /dev/tty for confirmation. Set NON_INTERACTIVE=1 to proceed."
  fi

  if [[ "${reply}" != "yes" ]]; then
    die "Aborted by user."
  fi
}

error_diag_snapshot() {
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      echo "DIAG: lsblk -f ${DISK_SYS} ${DISK_DATA}" >&2
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_DATA}" >&2 || true
      fi
      ;;
    three-disk)
      echo "DIAG: lsblk -f ${DISK_SYS} ${DISK_HOME} ${DISK_DATA}" >&2
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_HOME}" "${DISK_DATA}" >&2 || true
      fi
      ;;
    four-disk)
      echo "DIAG: lsblk -f ${DISK_SYS} ${DISK_HOME} ${DISK_ARCHIVE} ${DISK_BACKUP}" >&2
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" "${DISK_HOME}" "${DISK_ARCHIVE}" "${DISK_BACKUP}" >&2 || true
      fi
      ;;
    single-disk)
      echo "DIAG: lsblk -f ${DISK_SYS}" >&2
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -f "${DISK_SYS}" >&2 || true
      fi
      ;;
  esac
  echo "DIAG: findmnt (relevant mounts)" >&2
  if command -v findmnt >/dev/null 2>&1; then
    local relevant_mount_re
    relevant_mount_re="(${TARGET}|/dev/mapper|${DISK_SYS}${DISK_HOME:+|${DISK_HOME}}${DISK_DATA:+|${DISK_DATA}}${DISK_ARCHIVE:+|${DISK_ARCHIVE}}${DISK_BACKUP:+|${DISK_BACKUP}})"
    findmnt -rn | grep -E "${relevant_mount_re}" >&2 || true
  fi
  echo "DIAG: blkid (best effort)" >&2
  if command -v blkid >/dev/null 2>&1; then
    case "${INSTALL_LAYOUT_PROFILE}" in
      two-disk)
        blkid "$DISK_SYS" "$DISK_DATA" "$EFI_DEV" "$BOOT_DEV"           "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" 2>/dev/null >&2 || true
        ;;
      three-disk)
        blkid "$DISK_SYS" "$DISK_HOME" "$DISK_DATA" "$EFI_DEV" "$BOOT_DEV"           "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" 2>/dev/null >&2 || true
        ;;
      four-disk)
        blkid \
          "$DISK_SYS" "$DISK_HOME" "$DISK_ARCHIVE" "$DISK_BACKUP" \
          "$EFI_DEV" "$BOOT_DEV" "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" \
          "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" \
          2>/dev/null >&2 || true
        ;;
      single-disk)
        blkid "$DISK_SYS" "$EFI_DEV" "$BOOT_DEV"           "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV" 2>/dev/null >&2 || true
        ;;
    esac
  fi
}

umount_if_mounted() {
  local dev="$1"
  [[ -b "$dev" ]] || return 0
  local mps
  mps="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)"
  [[ -n "$mps" ]] || return 0
  log "-> Unmount detected mount(s) for $dev: $(echo "$mps" | tr '\n' ' ')"
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    umount "$mp" >/dev/null 2>&1 || true
  done <<<"$mps"
}

unmount_target_devices_best_effort() {
  # In Live-USB scenarios, the desktop may automount partitions. Ensure our target devices are unmounted
  # before wipefs/mkfs/cryptsetup and before mounting into $TARGET.
  log "-> Best-effort unmount of target devices (avoid automount conflicts)"
  for dev in "$EFI_DEV" "$BOOT_DEV" "$ROOT_LUKS_DEV" "$HOME_LUKS_DEV" "$ARCHIVE_LUKS_DEV" "$BACKUP_DEV"; do
    umount_if_mounted "$dev"
  done
}

on_err() {
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-<unknown>}"

  penelope_log_trap_error "${ec}" "${line}" "${cmd}" 400 "(chroot heredoc omitted)"
  >&2 echo "[$(ts)] ERROR: logfile=${LOGFILE}"
  if declare -F umount_chroot_support_fs_best_effort >/dev/null 2>&1; then
    umount_chroot_support_fs_best_effort || true
  fi
  error_diag_snapshot
  exit "${ec}"
}

install_on_signal() {
  local sig="${1:?signal required}"
  local ec=""
  ec="$(penelope_signal_exit_code_for_name "${sig}")"
  warn "Received ${sig}; aborting penelope-install."
  if declare -F umount_chroot_support_fs_best_effort >/dev/null 2>&1; then
    umount_chroot_support_fs_best_effort || true
  fi
  exit "${ec}"
}
trap on_err ERR
trap 'install_on_signal INT' INT
trap 'install_on_signal TERM' TERM

verify_shell_syntax_copy() {
  local path="$1"
  local label="$2"
  local syntax_out
  if [[ ! -f "${path}" ]]; then
    warn "${label}: missing (${path})"
    return 0
  fi
  if syntax_out="$(bash -n "${path}" 2>&1)"; then
    ok "${label}: shell syntax OK"
  else
    syntax_out="${syntax_out//$'\n'/; }"
    if ((${#syntax_out} > 400)); then
      syntax_out="${syntax_out:0:400}<TRUNCATED>"
    fi
    warn "${label}: shell syntax check failed (${path}): ${syntax_out:-no stderr output}"
  fi
}

verify_required_file() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]]; then
    ok "${label}: present"
  else
    warn "${label}: missing (${path})"
  fi
}

verify_literal_in_file() {
  local path="$1"
  local literal="$2"
  local label="$3"
  if [[ ! -f "${path}" ]]; then
    warn "${label}: file missing (${path})"
    return 0
  fi
  if grep -qF "${literal}" "${path}" 2>/dev/null; then
    ok "${label}"
  else
    warn "${label}: expected literal missing in $(basename "${path}")"
  fi
}

verify_samba_array_passwords_sanitized() {
  local path="$1"
  local block="$2"
  local bad
  if [[ ! -f "${path}" ]]; then
    warn "Recovery bundle sanitized ${block} passwords: file missing (${path})"
    return 0
  fi
  bad="$(awk -v block="${block}" '
    $0 ~ ("^" block "=\(") { inarr=1; next }
    inarr && $0 ~ /^\)/ { inarr=0; next }
    inarr && $0 ~ /^[[:space:]]*"/ {
      line=$0
      sub(/^[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      n=split(line, a, ":")
      if (block == "CRED_SAMBA_ARCHIVE_USERS") {
        if (n < 2 || a[2] != "change-me") print line
      } else if (block == "CRED_MANAGED_SAMBA_SHARES") {
        if (n < 5 || a[2] != "change-me") print line
      }
    }
  ' "${path}" || true)"
  if [[ -z "${bad}" ]]; then
    ok "Recovery bundle sanitized ${block} passwords"
  else
    bad="${bad//$'\n'/; }"
    warn "Recovery bundle contains non-sanitized entries in ${block}: ${bad}"
  fi
}

verify_samba_include_wired() {
  local main_conf="$1"
  local include_path="$2"
  local escaped_path include_re
  if [[ ! -f "${main_conf}" ]]; then
    warn "Samba main config: missing (${main_conf})"
    return 0
  fi
  escaped_path="$(printf '%s' "$include_path" | sed 's/[][(){}.^$*+?|\/]/\\&/g')"
  include_re="^[[:space:]]*include[[:space:]]*=[[:space:]]*\"?${escaped_path}\"?[[:space:]]*([#;].*)?$"
  if grep -Eq -- "${include_re}" "${main_conf}" 2>/dev/null; then
    ok "Samba main config includes Penelope managed include"
  else
    warn "Samba main config missing Penelope include wiring (${include_path})"
  fi
}

verify_samba_config_valid() {
  local testparm_output

  if ! command -v testparm >/dev/null 2>&1; then
    warn "Samba config validation: testparm not available"
    return 0
  fi

  if testparm_output="$(testparm -s 2>&1)"; then
    ok "Samba config validation via testparm -s"
    if grep -Fq "Weak crypto is allowed by GnuTLS" <<<"${testparm_output}"; then
      warn "Security watchpoint: testparm reports weak GnuTLS crypto is allowed."
      warn "Penelope verifies SMB3 and NTLMv2-only, but this host-level Samba/GnuTLS compatibility warning remains visible on this platform."
    fi
  else
    warn "Samba config validation failed (testparm -s)"
  fi
}

verify_samba_security_baseline() {
  local include_path="${SAMBA_MANAGED_INCLUDE}"
  verify_literal_in_file "${include_path}" 'server min protocol = SMB3_00' "Samba security baseline: server min protocol SMB3_00"
  verify_literal_in_file "${include_path}" 'client min protocol = SMB3_00' "Samba security baseline: client min protocol SMB3_00"
  verify_literal_in_file "${include_path}" 'ntlm auth = ntlmv2-only' "Samba security baseline: NTLMv2 only"
}

verify_systemd_unit_enabled_active() {
  local unit="$1"
  local label="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "${label}: systemctl not available"
    return 0
  fi
  if systemctl is-enabled --quiet "${unit}" >/dev/null 2>&1; then
    ok "${label}: enabled"
  else
    warn "${label}: not enabled"
  fi
  if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
    ok "${label}: active"
  else
    warn "${label}: not active"
  fi
}

setup_logging() {
  # Enable logging only after root escalation to avoid permission problems.
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
  if ! touch "$LOGFILE" 2>/dev/null; then
    LOGFILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S)-$$.log"
    touch "$LOGFILE" || true
  fi
  chmod 0644 "$LOGFILE" 2>/dev/null || true
  >&2 echo "[$(ts)] INFO: Logfile: $LOGFILE"
  exec > >(tee -a "$LOGFILE") 2>&1
  log "Logging to $LOGFILE"
}

# Best-effort: clean up stale artifacts from a previous run without rebooting.
cleanup_previous_run() {
  log "-> Cleaning up any previous run"

  # Recursively unmount if still mounted
  if mountpoint -q "$TARGET"; then
    log "   - Recursively unmounting $TARGET"
    umount -R "$TARGET" >/dev/null 2>&1 || true
  fi

  # If bind mounts still exist, recursively unmount everything
  umount -R "$TARGET" >/dev/null 2>&1 || true

  # Close mapper devices (only if they exist)
  for m in "$MAPPER_ROOT" "$MAPPER_HOME" "$MAPPER_ARCHIVE"; do
    if [[ -e "/dev/mapper/$m" ]]; then
      log "   - Closing LUKS mapping $m"
      cryptsetup close "$m" >/dev/null 2>&1 || true
      # If still "in use": dmsetup best-effort
      dmsetup remove -f "$m" >/dev/null 2>&1 || true
    fi
  done

  # udev settle
  udevadm settle >/dev/null 2>&1 || true
}

# Robustly ensure required tools are present
install_live_deps() {
  log "-> Installing required packages on the live system"

  # Reuse the previously selected fastest mirror on the live system.
  # install_live_deps establishes the installer tool contract before
  # repository/vendor preflights run.
  local live_suite="noble"
  local live_mirror="${PENELOPE_APT_MIRROR_BASE:-http://archive.ubuntu.com/ubuntu}"
  local live_sources="/tmp/penelope-apt-live.sources.list"

  cat >"${live_sources}" <<EOF_LIVE_APT_SOURCES
deb ${live_mirror} ${live_suite} main restricted universe multiverse
deb ${live_mirror} ${live_suite}-updates main restricted universe multiverse
deb ${live_mirror} ${live_suite}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${live_suite}-security main restricted universe multiverse
EOF_LIVE_APT_SOURCES

  log "Live APT: using sources from ${live_sources} (mirror=${live_mirror})"

  # Run APT with a temporary source list (no cdrom, no default lists)
  local -a apt_live_opts
  apt_live_opts=(
    -o "Dir::Etc::sourcelist=${live_sources}"
    -o "Dir::Etc::sourceparts=-"
  )

  apt-get "${apt_live_opts[@]}" update -y
  local apt_live_pkgs
  apt_live_pkgs=(
    debootstrap
    cryptsetup
    gdisk
    util-linux
    ethtool
    dosfstools
    e2fsprogs
    parted
    curl
    ca-certificates
    gnupg
    p7zip-full
    openssh-client
    psmisc
  )
  apt-get "${apt_live_opts[@]}" install -y --no-install-recommends "${apt_live_pkgs[@]}"

  command -v debootstrap >/dev/null 2>&1 || die "debootstrap missing despite installation. Live image may be defective."
  command -v curl >/dev/null 2>&1 || die "curl missing despite installation. Live image may be defective."
}


fetch_https_url_to_file_or_die() {
  local label="$1"
  local url="$2"
  local dest="$3"
  local tmp="${dest}.tmp"
  local attempt

  command -v curl >/dev/null 2>&1 || die "curl is required before ${label}: ${url}"

  rm -f "${tmp}"
  for attempt in 1 2 3; do
    log "${label}: curl attempt ${attempt}/3"
    if curl -4 -fsSL \
      --connect-timeout 10 \
      --max-time 45 \
      --retry 2 \
      --retry-delay 2 \
      "${url}" \
      -o "${tmp}"; then
      if [[ -s "${tmp}" ]]; then
        mv -f "${tmp}" "${dest}"
        return 0
      fi
      warn "${label}: curl produced an empty file: ${url}"
    fi

    rm -f "${tmp}"
    if [[ "${attempt}" != "3" ]]; then
      log "${label}: failed on attempt ${attempt}/3; retrying"
      sleep 5
    fi
  done

  die "${label}: download failed after retries: ${url}"
}

preflight_anydesk_external_repository_or_die() {
  log "-> Preflight: AnyDesk external repository is reachable before destructive steps"

  local release_probe="/tmp/penelope-anydesk-release-${RUN_TS}.txt"

  fetch_https_url_to_file_or_die "AnyDesk GPG key preflight" "${ANYDESK_GPG_KEY_URL}" "${ANYDESK_STAGED_GPG_KEY}"
  chmod 0644 "${ANYDESK_STAGED_GPG_KEY}"

  fetch_https_url_to_file_or_die "AnyDesk APT Release preflight" "${ANYDESK_APT_RELEASE_URL}" "${release_probe}"
  rm -f "${release_probe}"

  log "AnyDesk external repository preflight succeeded; staged GPG key: ${ANYDESK_STAGED_GPG_KEY}"
}

stage_anydesk_gpg_key_into_target() {
  if [[ ! -s "${ANYDESK_STAGED_GPG_KEY}" ]]; then
    die "Missing staged AnyDesk GPG key from live preflight: ${ANYDESK_STAGED_GPG_KEY}"
  fi

  log "-> Stage AnyDesk GPG key into target system"
  install -D -m 0644 "${ANYDESK_STAGED_GPG_KEY}" "${TARGET}${ANYDESK_TARGET_STAGED_GPG_KEY}"
}

detect_live_network() {
  log "== Live network detection (for initramfs/Dropbear) =="

  NET_IFACE=""
  NET_MODULES=""
  INITRAMFS_IFACE=""
  INITRAMFS_IFACE_REASON=""

  local preferred_if default_if ifaces iface carrier wireless driver module

  preferred_if="${PENELOPE_INITRAMFS_IFACE:-}"
  default_if="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"

  # Candidate interfaces (exclude loopback & common virtual interfaces)
  ifaces="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | \
  grep -Ev '^(lo|docker[0-9]*|veth.*|virbr.*|br-.*|vmnet.*|wg.*|tun.*|tap.*)$' || true)"

  if [[ -n "$preferred_if" ]]; then
    if [[ -d "/sys/class/net/${preferred_if}" ]]; then
      INITRAMFS_IFACE="$preferred_if"
      INITRAMFS_IFACE_REASON="PENELOPE_INITRAMFS_IFACE override"
      log "   - Using operator-provided interface: ${INITRAMFS_IFACE}"
    else
      warn "PENELOPE_INITRAMFS_IFACE='${preferred_if}' does not exist under /sys/class/net. Ignoring override."
    fi
  fi

  # Prefer: wired interface with carrier=1 (link up)
  if [[ -z "$INITRAMFS_IFACE" ]]; then
    for iface in $ifaces; do
      if [[ -e "/sys/class/net/${iface}/carrier" ]]; then
        carrier="$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)"
      else
        carrier="0"
      fi
      [[ -d "/sys/class/net/${iface}/wireless" ]] && wireless="yes" || wireless="no"
      if [[ "$carrier" == "1" && "$wireless" == "no" ]]; then
        INITRAMFS_IFACE="$iface"
        INITRAMFS_IFACE_REASON="wired carrier=1"
        break
      fi
    done
  fi

  # Next: default route interface (if not wireless)
  if [[ -z "$INITRAMFS_IFACE" && -n "$default_if" && -d "/sys/class/net/${default_if}" && \
    ! -d "/sys/class/net/${default_if}/wireless" ]]; then
    INITRAMFS_IFACE="$default_if"
    INITRAMFS_IFACE_REASON="default route (non-wireless)"
  fi

  # Next: any non-wireless interface
  if [[ -z "$INITRAMFS_IFACE" ]]; then
    for iface in $ifaces; do
      if [[ -d "/sys/class/net/${iface}" && ! -d "/sys/class/net/${iface}/wireless" ]]; then
        INITRAMFS_IFACE="$iface"
        INITRAMFS_IFACE_REASON="first non-wireless candidate"
        break
      fi
    done
  fi

  # LAN-only: do not force a Wi-Fi fallback. If no Ethernet was found, INITRAMFS_IFACE stays empty.

  if [[ -z "$INITRAMFS_IFACE" ]]; then
    warn "No suitable network interface detected. Initramfs networking/DHCP may fail."
    return 0
  fi

  NET_IFACE="$INITRAMFS_IFACE"

  INITRAMFS_MAC="$(cat "/sys/class/net/${NET_IFACE}/address" 2>/dev/null || true)"
  INITRAMFS_DRIVER=""

  # Determine driver module for the selected interface
  module=""
  if [[ -e "/sys/class/net/${NET_IFACE}/device/driver/module" ]]; then
    module="$(basename "$(readlink -f "/sys/class/net/${NET_IFACE}/device/driver/module" 2>/dev/null || true)" || true)"
  fi
  if [[ -z "$module" && -x /usr/sbin/ethtool ]]; then
    driver="$(/usr/sbin/ethtool -i "${NET_IFACE}" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}' || true)"
    [[ -n "$driver" ]] && module="$driver"
  fi

  if [[ -n "$module" ]]; then
    NET_MODULES="$module"
    INITRAMFS_DRIVER="$module"
  fi

  log "   - Default-route interface: ${default_if:-<none>}"
  log "   - Selected initramfs interface: ${INITRAMFS_IFACE} (reason: ${INITRAMFS_IFACE_REASON})"
  log "   - MAC: ${INITRAMFS_MAC:-<unknown>} | driver/module: ${INITRAMFS_DRIVER:-<unknown>}"
  if [[ -d "/sys/class/net/${INITRAMFS_IFACE}/wireless" ]]; then
    warn "Selected interface '${INITRAMFS_IFACE}' appears to be a Wi-Fi interface." \
      "Remote unlock in initramfs via Wi-Fi is often unreliable (WPA, etc.)." \
      "If possible, use Ethernet or set PENELOPE_INITRAMFS_IFACE."
  fi

  # Inventory for logging
  log "   - Interface inventory:"
  for iface in $ifaces; do
    if [[ -e "/sys/class/net/${iface}/carrier" ]]; then
      carrier="$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)"
    else
      carrier="0"
    fi
    [[ -d "/sys/class/net/${iface}/wireless" ]] && wireless="yes" || wireless="no"
    driver="<unknown>"
    if [[ -e "/sys/class/net/${iface}/device/driver/module" ]]; then
      driver="$(basename "$(
        readlink -f "/sys/class/net/${iface}/device/driver/module" 2>/dev/null || true
      )" || echo "<unknown>")"
    fi
    log "     * ${iface}: carrier=${carrier} wireless=${wireless} driver=${driver}"
  done

  if [[ -n "$NET_MODULES" ]]; then
    log "   - Network driver module (for initramfs): ${NET_MODULES}"
  else
    warn "Could not determine a network driver module for '${NET_IFACE}'." \
      "Initramfs may still load the NIC via MODULES=most, but diagnosis is harder."
  fi

  # Extra hardware context (helps debugging "not visible in router" cases)
  if command -v lspci >/dev/null 2>&1; then
    log "   - lspci network excerpt:"
    lspci -nnk | awk '
    BEGIN{IGNORECASE=1}
    /Ethernet controller|Network controller|Wireless|Wi-Fi/ {show=1}
    show==1 {print}
    show==1 && /^$/ {show=0}
    ' | sed 's/^/     /'
  fi
}

# SSH key pairs + 7z archives beside the effective bootstrap-config
generate_keypair_and_7z() {
  local live_user="${SUDO_USER:-ubuntu}"
  local live_home
  live_home="$(getent passwd "${live_user}" | cut -d: -f6 || true)"
  [[ -n "${live_home}" ]] || die "Could not determine HOME for live user '${live_user}'."

  [[ -n "${INSTALL_BOOTSTRAP_CONFIG_FILE:-}" ]] || die "INSTALL_BOOTSTRAP_CONFIG_FILE is empty; cannot place generated key archives."
  local artifact_dir
  artifact_dir="$(cd "$(dirname "${INSTALL_BOOTSTRAP_CONFIG_FILE}")" && pwd -P)" ||     die "Could not resolve the bootstrap-config directory for generated key archives."

  local unlock_archive="${artifact_dir}/${TARGET_HOST}_unlock_keys.7z"
  local admin_archive="${artifact_dir}/${ADMIN_USER}_ssh_keys.7z"

  # Always start with fresh archives: a previous aborted run can leave truncated/corrupt files.
  rm -f "${unlock_archive}" "${admin_archive}"

  # Minimal post-check to avoid shipping broken archives (common failure mode: truncated or empty 7z).
  verify_7z_archive() {
    local archive="$1"
    local expect1="$2"
    local expect2="$3"

    if [[ ! -s "${archive}" ]]; then
      die "7z archive is empty or missing: ${archive}"
    fi

    local sz
    sz="$(stat -c '%s' "${archive}" 2>/dev/null || echo 0)"
    if (( sz < 300 )); then
      warn "7z archive is very small (may still be valid, but is unusual): ${archive} (size=${sz})"
    fi

    # Integrity test (no output unless failing).
    local out rc
    local _xtrace=0
    case "$-" in *x*) _xtrace=1; set +x;; esac
    if out="$(7z t -p"${CRED_MASTER_PW}" "${archive}" 2>&1)"; then
      :
    else
      rc=$?
      if (( _xtrace == 1 )); then
        set -x
      fi
      warn "7z test failed: rc=${rc} archive=${archive}"
      if [[ -n "${out}" ]]; then
        printf '%s\n' "${out}" | sed 's/^/[7z] /' | head -n 80
      fi
      die "7z archive is not valid: ${archive}"
    fi
    if (( _xtrace == 1 )); then
      set -x
    fi

    # Sanity: expected file names should be present in the listing.
    _xtrace=0
    case "$-" in *x*) _xtrace=1; set +x;; esac
    if out="$(7z l -p"${CRED_MASTER_PW}" "${archive}" 2>&1)"; then
      :
    else
      rc=$?
      if (( _xtrace == 1 )); then
        set -x
      fi
      warn "7z list failed: rc=${rc} archive=${archive}"
      printf '%s\n' "${out}" | sed 's/^/[7z] /' | head -n 80
      die "Could not list 7z archive: ${archive}"
    fi
    if (( _xtrace == 1 )); then
      set -x
    fi
    if ! grep -Fq "${expect1}" <<<"${out}" || ! grep -Fq "${expect2}" <<<"${out}"; then
      warn "7z list missing expected paths: archive=${archive}"
      printf '%s
' "${out}" | sed 's/^/[7z] /' | head -n 120
      die "7z archive does not contain the expected files: ${archive}"
    fi
    log "7z ok: archive=$(basename "${archive}") size=${sz} bytes 7z-test=ok"
  }


  local keydir_unlock="${live_home}/.${DROPBEAR_KEY_NAME}"
  local keydir_admin="${live_home}/.${ADMIN_SSH_KEY_NAME}"

  rm -rf "${keydir_unlock}" "${keydir_admin}"
  mkdir -p "${keydir_unlock}" "${keydir_admin}"
  chown -R "${live_user}:${live_user}" "${keydir_unlock}" "${keydir_admin}"
  chmod 700 "${keydir_unlock}" "${keydir_admin}"

  log "Generating Dropbear unlock key pair: ${DROPBEAR_KEY_NAME}"
  sudo -u "${live_user}" ssh-keygen -t ed25519 -N "" \
    -f "${keydir_unlock}/${DROPBEAR_KEY_NAME}" -C "${TARGET_HOST}-unlock" >/dev/null

  log "Generating SSH key pair for '${ADMIN_USER}': ${ADMIN_SSH_KEY_NAME}"
  sudo -u "${live_user}" ssh-keygen -t ed25519 -N "" \
    -f "${keydir_admin}/${ADMIN_SSH_KEY_NAME}" -C "${ADMIN_USER}@${TARGET_HOST}" >/dev/null

  log "Packing unlock key pair: $(basename "${unlock_archive}") (7z, encrypted)"
  local z_out z_rc
  z_rc=0
  local _xtrace=0
  case "$-" in *x*) _xtrace=1; set +x;; esac
  z_out="$(7z a -t7z -mhe=on -p"${CRED_MASTER_PW}" "${unlock_archive}" \
    "${keydir_unlock}/${DROPBEAR_KEY_NAME}" "${keydir_unlock}/${DROPBEAR_KEY_NAME}.pub" 2>&1)" || z_rc=$?
  if (( _xtrace == 1 )); then
    set -x
  fi
  z_rc="${z_rc:-0}"
  if (( z_rc != 0 )); then
    warn "7z create unlock archive failed: rc=${z_rc} archive=${unlock_archive}"
    printf '%s\n' "${z_out}" | sed 's/^/[7z] /' | head -n 120
    die "7z create failed: ${unlock_archive}"
  fi
  verify_7z_archive "${unlock_archive}" "${DROPBEAR_KEY_NAME}" "${DROPBEAR_KEY_NAME}.pub"


  log "Packing SSH key pair: $(basename "${admin_archive}") (7z, encrypted)"
  z_rc=0
  _xtrace=0
  case "$-" in *x*) _xtrace=1; set +x;; esac
  z_out="$(7z a -t7z -mhe=on -p"${CRED_MASTER_PW}" "${admin_archive}" \
    "${keydir_admin}/${ADMIN_SSH_KEY_NAME}" "${keydir_admin}/${ADMIN_SSH_KEY_NAME}.pub" 2>&1)" || z_rc=$?
  if (( _xtrace == 1 )); then
    set -x
  fi
  z_rc="${z_rc:-0}"
  if (( z_rc != 0 )); then
    warn "7z create admin archive failed: rc=${z_rc} archive=${admin_archive}"
    printf '%s\n' "${z_out}" | sed 's/^/[7z] /' | head -n 120
    die "7z create failed: ${admin_archive}"
  fi
  verify_7z_archive "${admin_archive}" "${ADMIN_SSH_KEY_NAME}" "${ADMIN_SSH_KEY_NAME}.pub"


  chown "${live_user}:${live_user}" "${unlock_archive}" "${admin_archive}"
  chmod 600 "${unlock_archive}" "${admin_archive}"

  export UNLOCK_PUB="${keydir_unlock}/${DROPBEAR_KEY_NAME}.pub"
  export ADMIN_PRIV="${keydir_admin}/${ADMIN_SSH_KEY_NAME}"
  export ADMIN_PUB="${keydir_admin}/${ADMIN_SSH_KEY_NAME}.pub"
  export UNLOCK_ARCHIVE_PATH="${unlock_archive}"
  export ADMIN_SSH_ARCHIVE_PATH="${admin_archive}"
  export INSTALL_ARTIFACT_OUTPUT_DIR="${artifact_dir}"
}

wipe_and_partition() {
  case "${INSTALL_LAYOUT_PROFILE}" in
    two-disk)
      # Decide whether we can repartition or must preserve existing layouts.
      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_SYS (recreate: system+home)"
        sgdisk --zap-all "$DISK_SYS" >/dev/null 2>&1 || true
        wipefs -a "$DISK_SYS" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_SYS (home stays). Recreate: system (/) including /boot and /boot/efi"           "(always)."
        for p in 1 2 3 4; do
          local dev
          dev="$(part_dev "$DISK_SYS" "$p")"
          [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (preserve mode)."
        done
        # Only touch the partitions that belong to 'system' (EFI, /boot, /)
        wipefs -a "$EFI_DEV" >/dev/null 2>&1 || true
        wipefs -a "$BOOT_DEV" >/dev/null 2>&1 || true
        wipefs -a "$ROOT_LUKS_DEV" >/dev/null 2>&1 || true
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" && "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_DATA (recreate: _archive+_backup)"
        sgdisk --zap-all "$DISK_DATA" >/dev/null 2>&1 || true
        wipefs -a "$DISK_DATA" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_DATA (one or more targets stay)."
        for p in 1 2; do
          local dev
          dev="$(part_dev "$DISK_DATA" "$p")"
          [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (preserve mode)."
        done
        if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
          wipefs -a "$ARCHIVE_LUKS_DEV" >/dev/null 2>&1 || true
        fi
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          wipefs -a "$BACKUP_DEV" >/dev/null 2>&1 || true
        fi
      fi

      udevadm settle >/dev/null 2>&1 || true

      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Partitioning $DISK_SYS (system disk; profile=${INSTALL_LAYOUT_PROFILE})"
        sgdisk -o "$DISK_SYS" >/dev/null
        sgdisk -n "1:1MiB:+${EFI_SIZE_MIB}MiB"   -t 1:EF00 -c 1:"EFI"        "$DISK_SYS" >/dev/null
        sgdisk -n "2:0:+${BOOT_SIZE_MIB}MiB"     -t 2:8300 -c 2:"BOOT"       "$DISK_SYS" >/dev/null
        sgdisk -n "3:0:+${ROOT_SIZE_GIB}GiB"     -t 3:8300 -c 3:"ROOT_LUKS"  "$DISK_SYS" >/dev/null
        sgdisk -n 4:0:0                        -t 4:8300 -c 4:"HOME_LUKS"  "$DISK_SYS" >/dev/null
      else
        log "-> Partitioning on $DISK_SYS remains unchanged (preserve)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" && "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Partitioning $DISK_DATA (data disk)"
        sgdisk -o "$DISK_DATA" >/dev/null
        sgdisk -n "1:1MiB:+${ARCHIVE_SIZE_GIB}GiB" -t 1:8300 -c 1:"ARCHIVE_LUKS" "$DISK_DATA" >/dev/null
        sgdisk -n 2:0:0                          -t 2:8300 -c 2:"_BACKUP"      "$DISK_DATA" >/dev/null
      else
        log "-> Partitioning on $DISK_DATA remains unchanged (preserve)."
      fi

      partprobe "$DISK_SYS" "$DISK_DATA" >/dev/null 2>&1 || true
      ;;
    single-disk)
      if [[ "$(normalize_list "${RECREATION_TARGET_LIST}")" == "all" ]]; then
        log "-> Deleting partition table and signatures on $DISK_SYS (single-disk full recreation)"
        sgdisk --zap-all "$DISK_SYS" >/dev/null 2>&1 || true
        wipefs -a "$DISK_SYS" >/dev/null 2>&1 || true

        udevadm settle >/dev/null 2>&1 || true

        log "-> Partitioning $DISK_SYS (single-disk profile)"
        sgdisk -o "$DISK_SYS" >/dev/null
        sgdisk -n "1:1MiB:+${EFI_SIZE_MIB}MiB"       -t 1:EF00 -c 1:"EFI"          "$DISK_SYS" >/dev/null
        sgdisk -n "2:0:+${BOOT_SIZE_MIB}MiB"         -t 2:8300 -c 2:"BOOT"         "$DISK_SYS" >/dev/null
        sgdisk -n "3:0:+${ROOT_SIZE_GIB}GiB"         -t 3:8300 -c 3:"ROOT_LUKS"    "$DISK_SYS" >/dev/null
        sgdisk -n "4:0:+${HOME_SIZE_GIB}GiB"         -t 4:8300 -c 4:"HOME_LUKS"    "$DISK_SYS" >/dev/null
        sgdisk -n "5:0:+${ARCHIVE_SIZE_GIB}GiB"      -t 5:8300 -c 5:"ARCHIVE_LUKS" "$DISK_SYS" >/dev/null
        sgdisk -n 6:0:0                            -t 6:8300 -c 6:"_BACKUP"      "$DISK_SYS" >/dev/null

        partprobe "$DISK_SYS" >/dev/null 2>&1 || true
      else
        log "-> Preserve single-disk partition table (fixed-layout verified). Recreate: system incl. /boot and /boot/efi; selected role partitions are refreshed in place only."
        wipefs -a "$EFI_DEV" >/dev/null 2>&1 || true
        wipefs -a "$BOOT_DEV" >/dev/null 2>&1 || true
        wipefs -a "$ROOT_LUKS_DEV" >/dev/null 2>&1 || true
        if [[ "${RECREATE_HOME}" == "1" ]]; then
          wipefs -a "$HOME_LUKS_DEV" >/dev/null 2>&1 || true
        fi
        if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
          wipefs -a "$ARCHIVE_LUKS_DEV" >/dev/null 2>&1 || true
        fi
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          wipefs -a "$BACKUP_DEV" >/dev/null 2>&1 || true
        fi
      fi
      ;;
    three-disk)
      log "-> Deleting partition table and signatures on $DISK_SYS (three-disk system disk)"
      sgdisk --zap-all "$DISK_SYS" >/dev/null 2>&1 || true
      wipefs -a "$DISK_SYS" >/dev/null 2>&1 || true

      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_HOME (three-disk home disk; recreate: home)"
        sgdisk --zap-all "$DISK_HOME" >/dev/null 2>&1 || true
        wipefs -a "$DISK_HOME" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_HOME (HOME stays intact)."
        local dev
        dev="$(part_dev "$DISK_HOME" 1)"
        [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (three-disk preserve home)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" && "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_DATA (three-disk data disk; recreate: _archive+_backup)"
        sgdisk --zap-all "$DISK_DATA" >/dev/null 2>&1 || true
        wipefs -a "$DISK_DATA" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_DATA (one or more data targets stay)."
        local dev
        for p in 1 2; do
          dev="$(part_dev "$DISK_DATA" "$p")"
          [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (three-disk preserve data)."
        done
        if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
          wipefs -a "$ARCHIVE_LUKS_DEV" >/dev/null 2>&1 || true
        fi
        if [[ "${RECREATE_BACKUP}" == "1" ]]; then
          wipefs -a "$BACKUP_DEV" >/dev/null 2>&1 || true
        fi
      fi

      udevadm settle >/dev/null 2>&1 || true

      log "-> Partitioning $DISK_SYS (three-disk system disk)"
      sgdisk -o "$DISK_SYS" >/dev/null
      sgdisk -n "1:1MiB:+${EFI_SIZE_MIB}MiB"   -t 1:EF00 -c 1:"EFI"        "$DISK_SYS" >/dev/null
      sgdisk -n "2:0:+${BOOT_SIZE_MIB}MiB"     -t 2:8300 -c 2:"BOOT"       "$DISK_SYS" >/dev/null
      sgdisk -n 3:0:0                        -t 3:8300 -c 3:"ROOT_LUKS"  "$DISK_SYS" >/dev/null

      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Partitioning $DISK_HOME (three-disk home disk)"
        sgdisk -o "$DISK_HOME" >/dev/null
        sgdisk -n 1:1MiB:0                   -t 1:8300 -c 1:"HOME_LUKS"  "$DISK_HOME" >/dev/null
      else
        log "-> Partitioning on $DISK_HOME remains unchanged (preserve)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" && "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Partitioning $DISK_DATA (three-disk data disk)"
        sgdisk -o "$DISK_DATA" >/dev/null
        sgdisk -n "1:1MiB:+${ARCHIVE_SIZE_GIB}GiB" -t 1:8300 -c 1:"ARCHIVE_LUKS" "$DISK_DATA" >/dev/null
        sgdisk -n 2:0:0                          -t 2:8300 -c 2:"_BACKUP"      "$DISK_DATA" >/dev/null
      else
        log "-> Partitioning on $DISK_DATA remains unchanged (preserve)."
      fi

      partprobe "$DISK_SYS" "$DISK_HOME" "$DISK_DATA" >/dev/null 2>&1 || true
      ;;
    four-disk)
      log "-> Deleting partition table and signatures on $DISK_SYS (four-disk system disk)"
      sgdisk --zap-all "$DISK_SYS" >/dev/null 2>&1 || true
      wipefs -a "$DISK_SYS" >/dev/null 2>&1 || true

      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_HOME (four-disk home disk; recreate: home)"
        sgdisk --zap-all "$DISK_HOME" >/dev/null 2>&1 || true
        wipefs -a "$DISK_HOME" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_HOME (HOME stays intact)."
        local dev
        dev="$(part_dev "$DISK_HOME" 1)"
        [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (four-disk preserve home)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_ARCHIVE (four-disk archive disk; recreate: _archive)"
        sgdisk --zap-all "$DISK_ARCHIVE" >/dev/null 2>&1 || true
        wipefs -a "$DISK_ARCHIVE" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_ARCHIVE (_archive stays intact)."
        local dev
        dev="$(part_dev "$DISK_ARCHIVE" 1)"
        [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (four-disk preserve archive)."
      fi

      if [[ "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Deleting partition table and signatures on $DISK_BACKUP (four-disk backup disk; recreate: _backup)"
        sgdisk --zap-all "$DISK_BACKUP" >/dev/null 2>&1 || true
        wipefs -a "$DISK_BACKUP" >/dev/null 2>&1 || true
      else
        log "-> Preserve partition table on $DISK_BACKUP (_backup stays intact)."
        local dev
        dev="$(part_dev "$DISK_BACKUP" 1)"
        [[ -b "$dev" ]] || die "Expected partition missing: ${dev} (four-disk preserve backup)."
      fi

      udevadm settle >/dev/null 2>&1 || true

      log "-> Partitioning $DISK_SYS (four-disk system disk)"
      sgdisk -o "$DISK_SYS" >/dev/null
      sgdisk -n "1:1MiB:+${EFI_SIZE_MIB}MiB"   -t 1:EF00 -c 1:"EFI"        "$DISK_SYS" >/dev/null
      sgdisk -n "2:0:+${BOOT_SIZE_MIB}MiB"     -t 2:8300 -c 2:"BOOT"       "$DISK_SYS" >/dev/null
      sgdisk -n "3:0:+${ROOT_SIZE_GIB}GiB"     -t 3:8300 -c 3:"ROOT_LUKS"  "$DISK_SYS" >/dev/null

      if [[ "${RECREATE_HOME}" == "1" ]]; then
        log "-> Partitioning $DISK_HOME (four-disk home disk)"
        sgdisk -o "$DISK_HOME" >/dev/null
        sgdisk -n 1:1MiB:0                     -t 1:8300 -c 1:"HOME_LUKS"  "$DISK_HOME" >/dev/null
      else
        log "-> Partitioning on $DISK_HOME remains unchanged (preserve)."
      fi

      if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
        log "-> Partitioning $DISK_ARCHIVE (four-disk archive disk)"
        sgdisk -o "$DISK_ARCHIVE" >/dev/null
        sgdisk -n 1:1MiB:0                     -t 1:8300 -c 1:"ARCHIVE_LUKS" "$DISK_ARCHIVE" >/dev/null
      else
        log "-> Partitioning on $DISK_ARCHIVE remains unchanged (preserve)."
      fi

      if [[ "${RECREATE_BACKUP}" == "1" ]]; then
        log "-> Partitioning $DISK_BACKUP (four-disk backup disk)"
        sgdisk -o "$DISK_BACKUP" >/dev/null
        sgdisk -n 1:1MiB:0                     -t 1:8300 -c 1:"_BACKUP"      "$DISK_BACKUP" >/dev/null
      else
        log "-> Partitioning on $DISK_BACKUP remains unchanged (preserve)."
      fi

      partprobe "$DISK_SYS" "$DISK_HOME" "$DISK_ARCHIVE" "$DISK_BACKUP" >/dev/null 2>&1 || true
      ;;
  esac

  udevadm settle >/dev/null 2>&1 || true
}

setup_luks_and_fs() {
  log "-> Set up system partitions (system always includes /boot and /boot/efi)"
  log "   - LUKS2: / (always), /home (optional), /_archive (optional)"
  log "   - Filesystems: /boot/efi and /boot are always rewritten (system implies refresh)."

  # Ensure mappings are not left open from previous runs (best effort).
  for name in "$MAPPER_ROOT" "$MAPPER_HOME" "$MAPPER_ARCHIVE"; do
    if [[ -e "/dev/mapper/$name" ]]; then
      cryptsetup close "$name" >/dev/null 2>&1 || true
    fi
  done

  # Root is always recreated (system is mandatory)
  local root_dev="$ROOT_LUKS_DEV"
  local root_name="$MAPPER_ROOT"
  log "   - Recreate ROOT: $root_dev -> $root_name"
  case $- in
    *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$root_dev" ;;
    *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$root_dev" ;;
  esac
  case $- in
    *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup open --key-file - "$root_dev" "$root_name" ;;
    *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup open --key-file - "$root_dev" "$root_name" ;;
  esac

  # Home: recreate or preserve
  local home_dev="$HOME_LUKS_DEV"
  local home_name="$MAPPER_HOME"
  if [[ "${RECREATE_HOME}" == "1" ]]; then
    log "   - Recreate HOME: $home_dev -> $home_name"
    case $- in
      *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$home_dev" ;;
      *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$home_dev" ;;
    esac
  else
    log "   - Preserve HOME: $home_dev -> $home_name (no luksFormat/mkfs)"
  fi
  case $- in
    *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup open --key-file - "$home_dev" "$home_name" ;;
    *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup open --key-file - "$home_dev" "$home_name" ;;
  esac

  # Archive: recreate or preserve
  local arch_dev="$ARCHIVE_LUKS_DEV"
  local arch_name="$MAPPER_ARCHIVE"
  if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
    log "   - Recreate _archive: $arch_dev -> $arch_name"
    case $- in
      *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$arch_dev" ;;
      *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup luksFormat --type luks2 --batch-mode --key-file - "$arch_dev" ;;
    esac
  else
    log "   - Preserve _archive: $arch_dev -> $arch_name (no luksFormat/mkfs)"
  fi
  case $- in
    *x*) { set +x; printf '%s' "$CRED_MASTER_PW"; set -x; } | cryptsetup open --key-file - "$arch_dev" "$arch_name" ;;
    *)  printf '%s' "$CRED_MASTER_PW" | cryptsetup open --key-file - "$arch_dev" "$arch_name" ;;
  esac

  log "-> Creating filesystems (system: always; home/_archive/_backup: only when recreated)"
  # system implies refreshing /boot and /boot/efi (always)
  mkfs.fat -F32 "$EFI_DEV"
  mkfs.ext4 -F -L boot      "$BOOT_DEV"
  mkfs.ext4 -F -L root      "$ROOT_MAPPER"

  if [[ "${RECREATE_HOME}" == "1" ]]; then
    mkfs.ext4 -F -L home      "$HOME_MAPPER"
  fi
  if [[ "${RECREATE_ARCHIVE}" == "1" ]]; then
    mkfs.ext4 -F -L _archive  "$ARCHIVE_MAPPER"
  fi
  if [[ "${RECREATE_BACKUP}" == "1" ]]; then
    mkfs.ext4 -F -L _backup   "$BACKUP_DEV"
  else
    log "-> Preserve: /_backup remains unchanged (no mkfs on $BACKUP_DEV)"
  fi

  log "-> Waiting for device synchronization (udevadm settle)"
  # After luksFormat/mkfs, the device nodes must be fully available,
  # before blkid extracts the UUIDs (used later for fstab/crypttab).
  # Avoid race conditions: udevadm settle with timeout plus sleep fallback.
  if ! udevadm settle --timeout=10 2>/dev/null; then
    warn "udevadm settle timeout; using sleep 2 as fallback"
    sleep 2
  fi
}

mount_target() {
  log "-> Mounting target tree at $TARGET"
  mkdir -p "$TARGET"
  mount "$ROOT_MAPPER" "$TARGET"

  log "   - Create mount points in the target system"
  # IMPORTANT: mount /boot first, then create /boot/efi
  # (otherwise the directory is shadowed by the /boot mount)
  mkdir -p "$TARGET/boot" "$TARGET/home" "$TARGET/_archive" "$TARGET/_backup"

  log "   - Mounting additional filesystems"
  mount "$BOOT_DEV" "$TARGET/boot"
  mkdir -p "$TARGET/boot/efi"
  mount "$EFI_DEV" "$TARGET/boot/efi"
  mount "$HOME_MAPPER" "$TARGET/home"
  mount "$ARCHIVE_MAPPER" "$TARGET/_archive"
  mount "$BACKUP_DEV" "$TARGET/_backup"
}

do_debootstrap() {
  log "-> Installing Ubuntu base system via debootstrap"
  debootstrap --arch amd64 noble "$TARGET" "${PENELOPE_APT_MIRROR_BASE}"
}

bind_mounts_for_chroot() {
  log "-> Bind mounts for chroot"
  for fs in dev dev/pts proc sys run; do
    mkdir -p "$TARGET/$fs"
    mount --bind "/$fs" "$TARGET/$fs"
  done

  # EFI variables for grub-install (only if present on the live system)
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "$TARGET/sys/firmware/efi/efivars"
    mount -t efivarfs efivarfs "$TARGET/sys/firmware/efi/efivars" >/dev/null 2>&1 || true
  fi
}

collect_uuids() {
  log "-> Collecting UUIDs (fstab/crypttab) with retry logic"
  export EFI_UUID BOOT_UUID ROOT_UUID HOME_UUID ARCHIVE_UUID BACKUP_UUID
  export LUKS_ROOT_UUID LUKS_HOME_UUID LUKS_ARCHIVE_UUID

  # Helper: extract UUID with retries (max 5 attempts, 1s wait)
  # Args: device_path, variable_name
  extract_uuid_with_retry() {
    local dev="${1:?device required}"
    local varname="${2:?varname required}"
    local uuid=""
    local max_attempts=5

    for attempt in $(seq 1 $max_attempts); do
      uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
      if [[ -n "$uuid" ]]; then
        log "   - ${varname}: ${uuid} (${dev})"
        printf -v "${varname}" "%s" "${uuid}"
        return 0
      fi
      if (( attempt < max_attempts )); then
        warn "UUID for ${dev} not yet available, retry ${attempt}/${max_attempts}"
        sleep 1
      fi
    done

    die "UUID extraction failed for ${dev} (variable: ${varname}) after ${max_attempts} attempts. Device not ready or filesystem missing."
  }

  # Filesysteme (nach mkfs)
  extract_uuid_with_retry "$EFI_DEV" "EFI_UUID"
  extract_uuid_with_retry "$BOOT_DEV" "BOOT_UUID"
  extract_uuid_with_retry "$BACKUP_DEV" "BACKUP_UUID"

  # Mapper Devices (nach cryptsetup open)
  extract_uuid_with_retry "$ROOT_MAPPER" "ROOT_UUID"
  extract_uuid_with_retry "$HOME_MAPPER" "HOME_UUID"
  extract_uuid_with_retry "$ARCHIVE_MAPPER" "ARCHIVE_UUID"

  # LUKS Container (raw devices)
  extract_uuid_with_retry "$ROOT_LUKS_DEV" "LUKS_ROOT_UUID"
  extract_uuid_with_retry "$HOME_LUKS_DEV" "LUKS_HOME_UUID"
  extract_uuid_with_retry "$ARCHIVE_LUKS_DEV" "LUKS_ARCHIVE_UUID"
}

stage_keys_into_target() {
  log "-> Copy public keys into the target system (/root/${KEY_STAGE_DIR})"
  mkdir -p "${TARGET}/root/${KEY_STAGE_DIR}"
  chmod 700 "${TARGET}/root/${KEY_STAGE_DIR}"

  install -m 600 "${UNLOCK_PUB}" "${TARGET}/root/${KEY_STAGE_DIR}/${DROPBEAR_KEY_NAME}.pub"
  install -m 600 "${ADMIN_PUB}"  "${TARGET}/root/${KEY_STAGE_DIR}/${ADMIN_SSH_KEY_NAME}.pub"
}

stage_common_lib_into_target() {
  log "-> Install penelope-common.sh library to target system"
  local lib_file="${TARGET}/usr/local/lib/penelope/common.sh"

  penelope_refresh_installed_common_lib "${SCRIPT_DIR}/penelope-common.sh" "${lib_file}"
  log "   - Installed: ${lib_file}"

  if [[ ! -f "${lib_file}" ]]; then
    die "Failed to install penelope-common.sh to target"
  fi
}

cleanup_live_key_material() {
  # Remove unencrypted key material from the live-user HOME (the 7z archives stay).
  # Precondition: generate_keypair_and_7z and stage_keys_into_target completed successfully.
  if [[ -n "${UNLOCK_PUB:-}" ]]; then
    rm -rf "$(dirname "${UNLOCK_PUB}")" || true
  fi
  if [[ -n "${ADMIN_PRIV:-}" ]]; then
    rm -rf "$(dirname "${ADMIN_PRIV}")" || true
  fi
}

mount_chroot_support_fs() {
  # Make chroot more robust: provide /dev, /proc, /sys, /run inside $TARGET.
  # Best effort and idempotent.
  mkdir -p "${TARGET}/dev" "${TARGET}/dev/pts" "${TARGET}/proc" "${TARGET}/sys" "${TARGET}/run"

  if ! mountpoint -q "${TARGET}/dev"; then
    log "   - bind-mount /dev -> ${TARGET}/dev"
    mount --bind /dev "${TARGET}/dev"
  fi
  if ! mountpoint -q "${TARGET}/dev/pts"; then
    log "   - mount devpts -> ${TARGET}/dev/pts"
    mount -t devpts devpts "${TARGET}/dev/pts"
  fi
  if ! mountpoint -q "${TARGET}/proc"; then
    log "   - mount proc -> ${TARGET}/proc"
    mount -t proc proc "${TARGET}/proc"
  fi
  if ! mountpoint -q "${TARGET}/sys"; then
    log "   - mount sysfs -> ${TARGET}/sys"
    mount -t sysfs sysfs "${TARGET}/sys"
  fi
  if ! mountpoint -q "${TARGET}/run"; then
    log "   - bind-mount /run -> ${TARGET}/run"
    mount --bind /run "${TARGET}/run"
  fi
}

umount_chroot_support_fs_best_effort() {
  # Unmount in reverse order (best effort).
  [[ -n "${TARGET:-}" ]] || return 0
  [[ -d "${TARGET}" ]] || return 0

  local mp
  for mp in "${TARGET}/run" "${TARGET}/sys" "${TARGET}/proc" "${TARGET}/dev/pts" "${TARGET}/dev"; do
    if mountpoint -q "$mp"; then
      umount "$mp" >/dev/null 2>&1 || umount -l "$mp" >/dev/null 2>&1 || true
    fi
  done
}

configure_in_chroot() {
  log "-> Configure target system (chroot)"

  mount_chroot_support_fs

  local chroot_rc
  if env -i \
  DEBIAN_FRONTEND=noninteractive \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  CRED_MASTER_PW="$CRED_MASTER_PW" CRED_LOGIN_PW="$CRED_LOGIN_PW" ADMIN_USER="$ADMIN_USER" TARGET_HOST="$TARGET_HOST" VERSION="$VERSION" \
  DROPBEAR_PORT="${DROPBEAR_PORT:-$DROPBEAR_PORT_DEFAULT}" NET_MODULES="$NET_MODULES" PENELOPE_APT_MIRROR="$PENELOPE_APT_MIRROR" \
  INITRAMFS_IFACE="$INITRAMFS_IFACE" INITRAMFS_MAC="${INITRAMFS_MAC:-}" INITRAMFS_DRIVER="${INITRAMFS_DRIVER:-}" \
  EFI_UUID="$EFI_UUID" BOOT_UUID="$BOOT_UUID" ROOT_UUID="$ROOT_UUID" HOME_UUID="$HOME_UUID" \
  ARCHIVE_UUID="$ARCHIVE_UUID" BACKUP_UUID="$BACKUP_UUID" \
  LUKS_ROOT_UUID="$LUKS_ROOT_UUID" LUKS_HOME_UUID="$LUKS_HOME_UUID" LUKS_ARCHIVE_UUID="$LUKS_ARCHIVE_UUID" \
  DROPBEAR_KEY_NAME="$DROPBEAR_KEY_NAME" ADMIN_SSH_KEY_NAME="$ADMIN_SSH_KEY_NAME" KEY_STAGE_DIR="$KEY_STAGE_DIR" \
  MAPPER_ROOT="$MAPPER_ROOT" MAPPER_HOME="$MAPPER_HOME" MAPPER_ARCHIVE="$MAPPER_ARCHIVE" BACKUP_DEV="$BACKUP_DEV" \
  INITRAMFS_DEBUG_RETRY="$INITRAMFS_DEBUG_RETRY" \
  chroot "$TARGET" /bin/bash -s <<'CHROOT_EOF'
set -Eeuo pipefail

export TZ="${TZ:-Europe/Berlin}"

# Source Penelope common library
if [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  source "/usr/local/lib/penelope/common.sh"
else
  >&2 echo "ERROR: penelope-common.sh not found at /usr/local/lib/penelope/common.sh"
  exit 1
fi

penelope_initramfs_strict_smoke_test() {
  log "-> Strict smoke test: initramfs scripts/hooks syntax + risk scan (0 findings required)"

  # Syntax-check all Penelope-managed initramfs scripts/hooks using /bin/sh (dash-compatible).
  local err
  err="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-smoke.XXXXXX")"
  : >"${err}"

  local fail
  fail=0

  local f
  while IFS= read -r -d '' f; do
    [[ -f "${f}" ]] || continue

    # Only check Penelope-managed files (name contains penelope OR content contains penelope marker)
    if [[ "${f}" != *penelope* ]]; then
      if command -v grep >/dev/null 2>&1; then
        grep -qi "penelope" "${f}" 2>/dev/null || continue
      else
        continue
      fi
    fi

    if ! /bin/sh -n "${f}" 2>>"${err}"; then
      warn "initramfs syntax smoke test FAILED for: ${f}"
      fail=1
    fi
  done < <(find /etc/initramfs-tools/scripts /etc/initramfs-tools/hooks -type f -print0 2>/dev/null || true)

  if [[ "${fail}" -ne 0 ]]; then
    warn "initramfs syntax smoke test collected errors:"
    cat "${err}" >&2 || true
    rm -f "${err}" || true
    die "initramfs syntax smoke test failed"
  fi

  rm -f "${err}" || true

  # Severity: FATAL (later boot/remote-unlock reliability depends on a clean initramfs script set).
  # Risk scan must be strictly clean (0 findings).
  export PENELOPE_INITRAMFS_RISK_STRICT=1
  if ! scan_initramfs_for_unguarded_commands "/"; then
    die "initramfs risk scan strict failed (unguarded risky commands detected)"
  fi

  log "Strict smoke test OK (syntax=ok, risk_scan=0_findings)"
}

# Verifier failure policy inside chroot: fail-fast (fatal) for remaining verifier checks.

# Dropbear forced command path (usrmerge-safe). May be overridden later.
FORCE_CMD="${DROPBEAR_FORCE_CMD:-/bin/penelope-cryptroot-unlock-wrapper}"

# Override logging functions with [chroot] prefix for better visibility
log(){ >&2 echo "   [$(ts)] INFO: [chroot] $*"; }
warn(){ >&2 echo "   [$(ts)] WARNING: [chroot] $*"; }
die(){ local msg="${1:-Unknown error}"; local ec="${2:-1}"; >&2 echo "   [$(ts)] ERROR: [chroot] ${msg}"; exit "$ec"; }

on_err() {
  ec=$?
  line=${LINENO:-?}
  cmd="${BASH_COMMAND//$'\n'/; }"
  cmd="${cmd//$'\r'/ }"
  # Do not include full heredocs in the error message (too large / too sensitive)
  if [[ "$cmd" == *'<<'* ]]; then cmd="(heredoc omitted)"; fi
  if ((${#cmd}>240)); then cmd="${cmd:0:240}<TRUNCATED>"; fi
  echo "   [$(ts)] ERROR: [chroot] exit=${ec} line=${line} cmd=${cmd}" >&2
  exit "$ec"
}
trap on_err ERR

write_log_functions_block() {
  local out="${1:?missing output path}"
  cat >"$out" <<'EOF_CHROOT_LOG_FUNCTIONS'
ts() { date +'%H:%M:%S' 2>/dev/null || echo "00:00:00"; }

_log_write() {
  if type log_append >/dev/null 2>&1; then
    log_append "$1"
  else
    echo "$1" >&2
  fi
}

log() { _log_write "[$(ts)] INFO: $*"; }

warn() { _log_write "[$(ts)] WARNING: $*"; }

# have <cmd> - check if command exists (initramfs-safe helper)
have() { command -v "${1:?cmd required}" >/dev/null 2>&1; }

die() {
  local msg="${1:-Unknown error}"
  local ec="${2:-1}"
  _log_write "[$(ts)] ERROR: ${msg}"
  exit "$ec"
}

EOF_CHROOT_LOG_FUNCTIONS
}

# write_log_functions_block_bash() and write_log_functions_block_sh()
# are now provided by penelope-common.sh

# write_common_guards_block_bash(), write_common_guards_block_sh(),
# and inject_block_into_file() are now provided by penelope-common.sh

inject_log_functions_macro_if_present() {
  local f="${1:?missing path}"

  if grep -q '^___PENELOPE_LOG_FUNCTIONS___$' "$f"; then
    local block_file
    if ! command -v mktemp >/dev/null 2>&1; then
      die "inject_log_functions_macro_if_present: mktemp is required"
    fi
    block_file="$(mktemp "${TMPDIR:-/tmp}/penelope-logfuncs.XXXXXX")"
    write_log_functions_block "$block_file"
    inject_block_into_file "$f" "___PENELOPE_LOG_FUNCTIONS___" "$block_file"
    rm -f "$block_file" 2>/dev/null || true

    if grep -q '^___PENELOPE_LOG_FUNCTIONS___$' "$f"; then
      die "log functions macro token still present after injection: $f"
    fi
  fi
}

# inject_common_guards_macro_if_present() is now provided by penelope-common.sh

stamp_install_version() {
  local f="$1"
  [[ -n "$f" ]] || die "stamp_install_version: missing path"
  [[ -f "$f" ]] || die "stamp_install_version: file not found: $f"

  inject_log_functions_macro_if_present "$f"

  inject_common_guards_macro_if_present "$f"

  if ! grep -q "___PENELOPE_INSTALL_VERSION___" "$f"; then
    die "missing version placeholder token in: $f"
  fi

  sed -i "s/___PENELOPE_INSTALL_VERSION___/${VERSION}/g" "$f"
  if grep -q "___PENELOPE_INSTALL_VERSION___" "$f"; then
    die "version placeholder was not substituted: $f"
  fi

  # Optional: stamp common library version if placeholder token is present.
  if grep -q "___PENELOPE_COMMON_VERSION___" "$f"; then
    sed -i "s/___PENELOPE_COMMON_VERSION___/${PENELOPE_COMMON_VERSION}/g" "$f"
    if grep -q "___PENELOPE_COMMON_VERSION___" "$f"; then
      die "common version placeholder was not substituted: $f"
    fi
  fi

  if ! grep -qE "^# Version: ${VERSION}([[:space:]]|$)" "$f"; then
    die "missing or mismatched Version header in: $f"
  fi
}


annotate_generated_common_sources_for_shellcheck() {
  local f="${1:?missing path}"
  local tmp=""
  local line=""
  local prev_line=""
  local original_mode=""

  [[ -f "${f}" ]] || die "annotate_generated_common_sources_for_shellcheck: file not found: ${f}"
  if command -v stat >/dev/null 2>&1; then
    original_mode="$(stat -c %a "${f}" 2>/dev/null || true)"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-shellcheck-sources.XXXXXX")"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "  source \"\$(dirname \"\${BASH_SOURCE[0]}\")/penelope-common.sh\"")
        if [[ "${prev_line}" != *'shellcheck disable=SC109'* ]]; then
          printf '%s\n' '  # Runtime sibling common library; generated artifact can run from a bundle/workdir copy.' >>"${tmp}"
          printf '%s\n' '  # shellcheck disable=SC1090,SC1091' >>"${tmp}"
        fi
        ;;
      "  source \"/usr/local/lib/penelope/common.sh\"")
        if [[ "${prev_line}" != *'shellcheck disable=SC109'* ]]; then
          printf '%s\n' '  # Runtime installed common library; validated by the installer-owned artifact refresh path.' >>"${tmp}"
          printf '%s\n' '  # shellcheck disable=SC1091' >>"${tmp}"
        fi
        ;;
    esac
    printf '%s\n' "${line}" >>"${tmp}"
    prev_line="${line}"
  done <"${f}"

  mv -f "${tmp}" "${f}" || {
    rm -f "${tmp}" 2>/dev/null || true
    die "annotate_generated_common_sources_for_shellcheck: failed to update ${f}"
  }
  if [[ -n "${original_mode}" ]]; then
    chmod "${original_mode}" "${f}" || die "annotate_generated_common_sources_for_shellcheck: failed to restore mode ${original_mode} on ${f}"
  fi
}

finalize_generated_shell_file() {
  local f="${1:?missing path}"

  [[ -f "${f}" ]] || die "finalize_generated_shell_file: file not found: ${f}"

  # Normalize macro lines to avoid indentation/trailing-space issues (strict token matchers expect exact line).
  sed -i -E 's/^[[:space:]]*(__PENELOPE_(LOG_FUNCTIONS|COMMON_GUARDS|SOURCE_COMMON)__)[[:space:]]*$/\1/' "${f}" 2>/dev/null || true

  # Ensure all known macros are expanded before token checks.
  inject_known_macros_if_present "${f}"
  annotate_generated_common_sources_for_shellcheck "${f}"

  # Stamp installer version header (also ensures the version placeholder exists and is substituted).
  stamp_install_version "${f}"

  apply_placeholders "${f}"

  validate_generated_file "${f}"
  ensure_no_unexpanded_tokens "${f}"
  validate_shell_script "${f}"

  # One-line summary for operator visibility in install logs
  local token_count
  token_count="$( (grep -oE '__PENELOPE_[A-Z_]*__' "${f}" 2>/dev/null || true) | wc -l | tr -d ' 	' )"
  if [[ "${token_count}" != "0" ]]; then
    local token_preview
    token_preview="$( (grep -oE '__PENELOPE_[A-Z_]*__' "${f}" 2>/dev/null || true) | head -n 3 | tr '\n' ' ' | sed -E 's/[[:space:]]+$//' )"
    log "finalize_warn: path=${f} macro_tokens_preview=${token_preview:-<none>}"
  fi

  local mode owner
  mode=""
  owner=""
  if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c %a "${f}" 2>/dev/null || true)"
    owner="$(stat -c %u:%g "${f}" 2>/dev/null || true)"
  fi
  log "finalize_ok: path=${f} macros=ok tokens=${token_count} syntax=ok mode=${mode:-?} owner=${owner:-?}"
}

normalize_mode_for_compare() {
  local mode="${1:-}"
  while [[ -n "${mode}" && "${mode}" == 0* ]]; do
    mode="${mode#0}"
  done
  if [[ -z "${mode}" ]]; then
    mode="0"
  fi
  printf '%s' "${mode}"
}

finalize_generated_executable_shell_file() {
  local f="${1:?missing path}"
  local mode="${2:?missing mode}"
  local expected_mode=""
  local actual_mode=""
  local owner=""

  [[ -f "${f}" ]] || die "finalize_generated_executable_shell_file: file not found: ${f}"

  chmod "${mode}" "${f}" || die "Failed to set executable mode ${mode} on ${f} before finalize."
  finalize_generated_shell_file "${f}"
  chmod "${mode}" "${f}" || die "Failed to restore executable mode ${mode} on ${f} after finalize."

  expected_mode="$(normalize_mode_for_compare "${mode}")"

  if command -v stat >/dev/null 2>&1; then
    actual_mode="$(stat -c %a "${f}" 2>/dev/null || true)"
    owner="$(stat -c %u:%g "${f}" 2>/dev/null || true)"
    [[ "${actual_mode}" == "${expected_mode}" ]] || die "Executable shell artifact ended with unexpected mode for ${f}: ${actual_mode:-?} (expected ${expected_mode})."
  fi

  [[ -x "${f}" ]] || die "Executable shell artifact is not executable after finalize: ${f}"
  log "executable_ok: path=${f} mode=${actual_mode:-${expected_mode}} owner=${owner:-?}"
}

# escape_sed_replacement() is now provided by penelope-common.sh

# apply_placeholders() is now provided by penelope-common.sh

# validate_shell_script() is now provided by penelope-common.sh

# validate_systemd_unit() is now provided by penelope-common.sh

# validate_generated_file() is now provided by penelope-common.sh

enable_unit() {
  local unit="$1"
  [[ -n "$unit" ]] || die "enable_unit: missing unit name"

  if ! command -v systemctl >/dev/null 2>&1; then
    # Severity: fatal. This affects service enablement semantics in chroot (not the initramfs risk-scan path).
    die "systemctl not available; cannot enable unit: ${unit}"
    return 0
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  if SYSTEMD_OFFLINE=1 systemctl enable "$unit" >/dev/null 2>&1; then
    log "-> ${unit} enabled via systemctl"
  else
    # Severity: fatal for required service enablement in the generated target system.
    die "systemctl enable failed: ${unit}"
  fi

  # Best-effort post-check (works in many chroot/offline scenarios).
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    log "OK: unit is enabled: ${unit}"
  else
    warn "Unit does not appear to be enabled (is-enabled != enabled): ${unit}"
  fi
}

log "Configure apt sources (mirror selection)"
APT_SUITE="noble"
APT_MIRROR_BASE="${PENELOPE_APT_MIRROR_BASE:-}"
if [[ -z "${APT_MIRROR_BASE}" ]]; then
  APT_MIRROR_BASE="$(apt_select_ubuntu_mirror "${PENELOPE_APT_MIRROR:-}" "${APT_SUITE}")"
fi
log "apt mirror selected: ${APT_MIRROR_BASE}"

cat > /etc/apt/sources.list <<APT_EOF
# Version: ___PENELOPE_INSTALL_VERSION___
deb ${APT_MIRROR_BASE} ${APT_SUITE} main restricted universe multiverse
deb ${APT_MIRROR_BASE} ${APT_SUITE}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${APT_SUITE}-security main restricted universe multiverse
APT_EOF
stamp_install_version /etc/apt/sources.list
validate_generated_file /etc/apt/sources.list

log "Write crypttab early - avoids warnings from initramfs hooks during apt installs"
cat > /etc/crypttab <<'CRYPTTAB_EARLY_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_MAPPER_ROOT___   UUID=___PENELOPE_LUKS_ROOT_UUID___   none luks,discard
___PENELOPE_MAPPER_HOME___   UUID=___PENELOPE_LUKS_HOME_UUID___   none luks,discard
___PENELOPE_MAPPER_ARCHIVE___ UUID=___PENELOPE_LUKS_ARCHIVE_UUID___ none luks,discard
CRYPTTAB_EARLY_EOF
apply_placeholders /etc/crypttab
stamp_install_version /etc/crypttab
validate_generated_file /etc/crypttab

apt-get update -y

log "== Pre-seed: initramfs network + Dropbear keys (before package installation) =="

log "Initramfs target interface: ${INITRAMFS_IFACE:-<empty>} | NET_MODULES: ${NET_MODULES:-<empty>}"

# Re-derive driver/module name inside the target system if needed (fallback).
if [[ -z "${INITRAMFS_DRIVER:-}" && -n "${INITRAMFS_IFACE:-}" ]]; then
  if command -v ethtool >/dev/null 2>&1; then
    d="$(ethtool -i "${INITRAMFS_IFACE}" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}' || true)"
    [[ -n "$d" ]] && INITRAMFS_DRIVER="$d"
  fi
  if [[ -z "${INITRAMFS_DRIVER:-}" && -L "/sys/class/net/${INITRAMFS_IFACE}/device/driver/module" ]]; then
    INITRAMFS_DRIVER="$(basename "$(
      readlink -f "/sys/class/net/${INITRAMFS_IFACE}/device/driver/module" 2>/dev/null || true
    )" || true)"
  fi
fi

# Persist install-time NIC evidence for later correlation (copied into initramfs as /conf/penelope-netinfo-install.conf).
mkdir -p /etc/penelope 2>/dev/null || true
INSTALL_NETINFO_FILE="/etc/penelope/netinfo-install.conf"
TARGET_KVER_CAND="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n 1 || true)"
{
  echo "install_version=${VERSION}"
  echo "live_kernel_release=$(uname -r 2>/dev/null || true)"
  echo "target_kernel_candidate=${TARGET_KVER_CAND}"
  echo "install_iface=${INITRAMFS_IFACE:-}"
  echo "install_mac=${INITRAMFS_MAC:-}"
  echo "install_driver=${INITRAMFS_DRIVER:-}"
  echo "install_net_modules=${NET_MODULES:-}"
} >"${INSTALL_NETINFO_FILE}" 2>/dev/null || true
chmod 0644 "${INSTALL_NETINFO_FILE}" 2>/dev/null || true
log "Install netinfo persisted: ${INSTALL_NETINFO_FILE}" \
  "(iface=${INITRAMFS_IFACE:-<empty>} driver=${INITRAMFS_DRIVER:-<empty>}" \
  "live_kver=$(uname -r 2>/dev/null || true) target_kver=${TARGET_KVER_CAND:-<empty>})"

if [[ -z "${INITRAMFS_IFACE:-}" ]]; then
  warn "INITRAMFS_IFACE is empty. Initramfs will then choose the interface automatically; on multi-NIC systems this may be the wrong NIC." \
    "Set PENELOPE_INITRAMFS_IFACE on the live system if needed, and verify Dropbear reachability after the first reboot."
fi

# Preinstall Dropbear initramfs authorized_keys so update-initramfs hooks during package installation
# do not let them silently point nowhere
mkdir -p /etc/dropbear/initramfs
chmod 700 /etc/dropbear/initramfs

if [[ -s "/root/${KEY_STAGE_DIR}/${DROPBEAR_KEY_NAME}.pub" ]]; then
  install -m 600 "/root/${KEY_STAGE_DIR}/${DROPBEAR_KEY_NAME}.pub" /etc/dropbear/initramfs/authorized_keys
  log "Dropbear initramfs authorized_keys preinstalled: /etc/dropbear/initramfs/authorized_keys"
else
  warn "Dropbear public key missing: /root/${KEY_STAGE_DIR}/${DROPBEAR_KEY_NAME}.pub" \
    "(remote unlock via SSH will not work)"
fi

if command -v ssh-keygen >/dev/null 2>&1 && [[ -s /etc/dropbear/initramfs/authorized_keys ]]; then
  if ! ssh-keygen -l -f /etc/dropbear/initramfs/authorized_keys >/dev/null 2>&1; then
    warn "authorized_keys is syntactically invalid (ssh-keygen -l fails)." \
      "Dropbear login in initramfs will not work."
    log "authorized_keys (first line): $(head -n1 /etc/dropbear/initramfs/authorized_keys || true)"
  fi
fi

# initramfs-tools: do NOT pre-create or edit /etc/initramfs-tools/initramfs.conf (dpkg conffile).
# For dropbear-initramfs / remote unlock, place our settings in conf.d.
mkdir -p /etc/initramfs-tools/conf.d

# If a minimal/broken initramfs.conf without COMPRESS= already exists after aborted runs:
# move it aside and remove it so mkinitramfs does not fail and dpkg needs no interaction.
if [[ -f /etc/initramfs-tools/initramfs.conf ]] && ! grep -qE '^COMPRESS=' /etc/initramfs-tools/initramfs.conf; then
  TS="$(date +%Y%m%d-%H%M%S)"
  warn "Found an existing /etc/initramfs-tools/initramfs.conf without COMPRESS=;" \
    "backing it up to /root/penelope-initramfs.conf.bak.${TS} and removing it."
  cp -a /etc/initramfs-tools/initramfs.conf "/root/penelope-initramfs.conf.bak.${TS}" || true
  rm -f /etc/initramfs-tools/initramfs.conf
fi
# --- Penelope: initramfs network and NIC preseed (idempotent) ---
mkdir -p /etc/initramfs-tools/conf.d

# Cleanup: remove old Penelope config before writing the new files.
rm -f /etc/initramfs-tools/conf.d/penelope-network.conf \
  /etc/initramfs-tools/conf.d/penelope-netselect.conf 2>/dev/null || true

PEN_INITRAMFS_CONF="/etc/initramfs-tools/conf.d/penelope-network.conf"
{
  echo "# Generated by penelope-install ${VERSION}"
  echo "# Early initramfs networking for dropbear-initramfs (remote LUKS unlock)"
  echo "# Selected interface at install time: ${INITRAMFS_IFACE:-unknown}"
  echo "# MAC: ${INITRAMFS_MAC:-unknown} | Driver: ${INITRAMFS_DRIVER:-${NET_MODULES:-unknown}}"
  echo "IP=dhcp"
  echo "DEVICE=${INITRAMFS_IFACE:-}"
  echo "MODULES=most"
  } > "$PEN_INITRAMFS_CONF"
  chmod 0644 "$PEN_INITRAMFS_CONF"
  log "initramfs-tools conf.d written: $PEN_INITRAMFS_CONF"
  sed -n '1,120p' "$PEN_INITRAMFS_CONF" | sed 's/^/      /' || true

  PEN_NETSELECT_CONF="/etc/initramfs-tools/conf.d/penelope-netselect.conf"
  {
    echo "# Generated by penelope-install ${VERSION}"
    printf 'PENELOPE_ETH_IFACE="%s"
    ' "${INITRAMFS_IFACE:-}"
    printf 'PENELOPE_ETH_MAC="%s"
    ' "${INITRAMFS_MAC:-}"
    printf 'PENELOPE_NET_MODULE="%s"
    ' "${INITRAMFS_DRIVER:-${NET_MODULES:-}}"
    echo 'PENELOPE_LINK_WAIT="60"'
    echo 'PENELOPE_DHCP_TIMEOUT="60"'
    } > "$PEN_NETSELECT_CONF"
    chmod 0644 "$PEN_NETSELECT_CONF"
    log "initramfs netselect conf.d written: $PEN_NETSELECT_CONF"
    sed -n '1,120p' "$PEN_NETSELECT_CONF" | sed 's/^/      /' || true

    # Force network module(s) into the initramfs (without destroying unrelated content).
    mkdir -p /etc/initramfs-tools
    touch /etc/initramfs-tools/modules
    if [[ -n "${NET_MODULES:-}" ]]; then
      # Remove any previous Penelope block if present
      sed -i '/^# --- penelope begin ---$/,/^# --- penelope end ---$/d' /etc/initramfs-tools/modules 2>/dev/null || true
      # Ensure exactly one blank line before the block (no accumulation across reruns)
      if [[ -s /etc/initramfs-tools/modules ]] && [[ -n "$(tail -n1 /etc/initramfs-tools/modules 2>/dev/null)" ]]; then
        echo >> /etc/initramfs-tools/modules
      fi
      {
        echo "# --- penelope begin ---"
        for m in ${NET_MODULES}; do
          echo "$m"
        done
        echo "# --- penelope end ---"
      } >> /etc/initramfs-tools/modules
      # One-time cleanup: remove extra blank lines at end of file (without other changes)
      tmp_modules="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-modules.XXXXXX" 2>/dev/null || true)"
      if [[ -n "${tmp_modules:-}" ]]; then
        if ! awk '{lines[NR]=$0} $0 ~ /[^[:space:]]/ {last=NR} END {for(i=1;i<=last;i++) print lines[i]}' \
          /etc/initramfs-tools/modules > "$tmp_modules" 2>/dev/null; then
          warn "Cleanup /etc/initramfs-tools/modules: awk failed (skipping trim)."
        else
          if ! cat "$tmp_modules" > /etc/initramfs-tools/modules 2>/dev/null; then
            warn "Cleanup /etc/initramfs-tools/modules: write-back failed."
          fi
        fi
        rm -f "$tmp_modules" 2>/dev/null || true
      else
        warn "Cleanup /etc/initramfs-tools/modules: mktemp failed (skipping trim)."
      fi

      fi

      log "initramfs-tools config (pre-install):"

      if [[ -f /etc/initramfs-tools/initramfs.conf ]]; then
        log "   - /etc/initramfs-tools/initramfs.conf exists (pre-install). Relevant keys:"
        grep -nE '^(COMPRESS|MODULES|IP|DEVICE)=' /etc/initramfs-tools/initramfs.conf 2>/dev/null \
          | sed 's/^/      /' || true
      else
        log "   - /etc/initramfs-tools/initramfs.conf not present yet (ok)."
      fi
      if [[ -f /etc/initramfs-tools/conf.d/penelope-network.conf ]]; then
        log "   - /etc/initramfs-tools/conf.d/penelope-network.conf:"
        sed -n '1,120p' /etc/initramfs-tools/conf.d/penelope-network.conf | sed 's/^/      /' || true
      fi

      log "Installing packages (desktop, HWE, GRUB, crypto, Dropbear, SSH, snapd, KeePassXC, ShellCheck)"
      DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confnew \
      ubuntu-desktop linux-generic-hwe-24.04 \
      grub-efi-amd64-signed shim-signed \
      cryptsetup cryptsetup-initramfs cryptsetup-bin keyutils \
      dropbear-initramfs openssh-server \
      snapd \
      curl ca-certificates gnupg git \
      keepassxc \
      psmisc \
      iputils-arping \
      p7zip-full \
      shellcheck


      log "OpenSSH: disabling password login (sshd_config.d drop-in)"
      mkdir -p /etc/ssh/sshd_config.d
      cat > /etc/ssh/sshd_config.d/50-penelope-hardening.conf <<'EOF_SSHD_HARDENING'
# Version: ___PENELOPE_INSTALL_VERSION___
# Penelope hardening for OpenSSH server
# Notes:
# - Prefer key-based auth only.
# - Keep settings in a dedicated drop-in so package updates don't overwrite it.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF_SSHD_HARDENING
      stamp_install_version /etc/ssh/sshd_config.d/50-penelope-hardening.conf
      validate_generated_file /etc/ssh/sshd_config.d/50-penelope-hardening.conf
      chmod 0644 /etc/ssh/sshd_config.d/50-penelope-hardening.conf

      log "Installing ops tool: penelope-rotate-masterpw-dropbear"
      install -d -m 0755 /usr/local/sbin
      cat > /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh <<'ROT_EOF'
#!/usr/bin/env bash
# penelope-rotate-masterpw-dropbear.sh
# Version: ___PENELOPE_INSTALL_VERSION___
# Penelope - Rotate CRED_MASTER_PW (LUKS) + rotate Dropbear unlock key (for initramfs SSH unlock)
#
# Usage:
#   sudo /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh
#
# Exit Codes:
#   0: success
#   1: general error
#   2: invalid parameters
#
# Behavior:
# - Changes the LUKS passphrase for all LUKS devices referenced in /etc/crypttab via 'cryptsetup luksChangeKey'
#   (interactive - the passphrase is NOT stored in the script).
# - Generates a new Dropbear unlock key (ed25519) temporarily in /run (tmpfs) and exports it as a 7z archive (AES-256).
# - Replaces /etc/dropbear/initramfs/authorized_keys and regenerates the initramfs.

# Source Penelope common library
# Fallback order: installed location -> script directory -> error
if [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  source "/usr/local/lib/penelope/common.sh"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"
else
  >&2 echo "[$(date +'%H:%M:%S')] ERROR: penelope-common.sh not found"
  >&2 echo "  Expected locations:"
  >&2 echo "    /usr/local/lib/penelope/common.sh"
  >&2 echo "    \$(dirname \"\${BASH_SOURCE[0]}\")/penelope-common.sh"
  exit 1
fi

if (( BASH_VERSINFO[0] < 4 )); then
  >&2 echo "ERROR: Bash 4.0 or higher required."
  exit 2
fi

set -Eeuo pipefail

# ================== CONFIGURATION ==================
# Default: detect hostname/user automatically. Optional overrides:
#   TARGET_HOST="asterix" ADMIN_USER="obelix" /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh
readonly BUNDLE_VERSION="___PENELOPE_INSTALL_VERSION___"
TARGET_HOST="${TARGET_HOST:-$(hostname -s)}"

resolve_invoking_admin_user() {
  if [[ -n "${ADMIN_USER:-}" && "${ADMIN_USER}" != "root" ]]; then
    printf '%s\n' "${ADMIN_USER}"
    return 0
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi
  if command -v logname >/dev/null 2>&1; then
    local _ln=""
    _ln="$(logname 2>/dev/null || true)"
    if [[ -n "${_ln}" && "${_ln}" != "root" ]]; then
      printf '%s\n' "${_ln}"
      return 0
    fi
  fi
  return 1
}

readonly SCRIPT_VERSION="${BUNDLE_VERSION}"
readonly DROPBEAR_PORT_DEFAULT="___PENELOPE_DROPBEAR_PORT___"
: "${DROPBEAR_PORT:=${DROPBEAR_PORT_DEFAULT}}"
DROPBEAR_KEY_NAME="${TARGET_HOST}_unlock"

ts() { date +"%H:%M:%S"; }
# log(), warn(), and die() come from penelope-common.sh.

on_err() {
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-<unknown>}"

  cmd="${cmd//$'\n'/ }"
  cmd="${cmd//$'\r'/ }"

  # Do not include sensitive details in the error log (e.g. 7z -p<pass>)
  if [[ "$cmd" == *"7z "* && "$cmd" == *" -p"* ]]; then
    cmd="(7z command omitted: password redacted)"
  fi

  if ((${#cmd} > 240)); then
    cmd="${cmd:0:240}<TRUNCATED>"
  fi

  >&2 echo "[$(ts)] ERROR: exit=${ec} line=${line} cmd=${cmd}"
  exit "${ec}"
}

cleanup() {
  # Best-effort cleanup; never raise new errors
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]]; then
    rm -rf "${TMPDIR}" >/dev/null 2>&1 || true
  fi
}

trap on_err ERR
trap cleanup EXIT


# The target desktop (for the export archive) is resolved later.
# The rotation itself only needs root; missing user context must not block the core flow.
TARGET_USER=""
TARGET_HOME=""
TARGET_DESKTOP=""
EXPORT_BASE_DEFAULT="/root"

require_root

log "=== Penelope Rotate (v${SCRIPT_VERSION}) - $(ts) ==="
echo
log "This script rotates:"
log "  1) LUKS passphrase (CRED_MASTER_PW) for all LUKS devices from /etc/crypttab (interactive)"
log "  2) Dropbear unlock key for initramfs SSH unlock (authorized_keys + initramfs rebuild)"
echo

command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup not found."
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found."
command -v update-initramfs >/dev/null 2>&1 || die "update-initramfs not found."

if ! command -v 7z >/dev/null 2>&1; then
  die "7z not found. Please install it: sudo apt-get update && sudo apt-get install -y p7zip-full"
fi

# Preflight: DROPBEAR_PORT validieren (numeric, 1..65535)
if [[ ! "${DROPBEAR_PORT}" =~ ^[0-9]+$ ]] || (( DROPBEAR_PORT < 1 || DROPBEAR_PORT > 65535 )); then
  die "Invalid DROPBEAR_PORT='${DROPBEAR_PORT}' (expected 1..65535)."
fi

# Prepare export target (convenience function); the core rotation may also run without user context.
if TARGET_USER="$(resolve_invoking_admin_user)"; then
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"
  [[ -n "${TARGET_HOME}" ]] || TARGET_HOME="/home/${TARGET_USER}"
  TARGET_DESKTOP="${TARGET_HOME}/Desktop"
  if install -d -m 0755 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_DESKTOP}" 2>/dev/null; then
    log "Export target (admin Desktop): ${TARGET_DESKTOP} [user=${TARGET_USER}]"
  else
    warn "Could not create or write the Desktop directory: ${TARGET_DESKTOP}; falling back to ${EXPORT_BASE_DEFAULT}."
    TARGET_DESKTOP="${EXPORT_BASE_DEFAULT}"
  fi
else
  warn "No admin-user context detected (no ADMIN_USER/SUDO_USER/logname). Export falls back to ${EXPORT_BASE_DEFAULT}."
  TARGET_DESKTOP="${EXPORT_BASE_DEFAULT}"
fi


if [[ ! -f /etc/crypttab ]]; then
  die "/etc/crypttab not found - cannot determine LUKS devices automatically."
fi

# LUKS Devices aus crypttab ermitteln
mapfile -t CRYPT_DEVS < <(
  awk 'NF>=2 && $1 !~ /^#/ {print $2}' /etc/crypttab \
  | sed 's/[[:space:]]\+$//' \
  | grep -v '^none$' \
  | sort -u
)

if [[ "${#CRYPT_DEVS[@]}" -le 0 ]]; then
  die "No devices found in /etc/crypttab."
fi

resolve_dev() {
  local spec="${1}"
  if [[ "${spec}" =~ ^UUID= ]]; then
    local uuid="${spec#UUID=}"
    blkid -U "${uuid}" 2>/dev/null || true
  else
    echo "${spec}"
  fi
}

log "Detected crypttab devices:"
for d in "${CRYPT_DEVS[@]}"; do
  rd="$(resolve_dev "${d}")"
  echo "  - $d -> ${rd:-<not resolvable>}"
done
echo

warn "Note: LUKS rotation happens before export/initramfs rebuild and is not automatically rollback-capable."
log "Step 1/2: rotate the LUKS passphrase (cryptsetup luksChangeKey - interactive per device)."
log "Note: you will be asked for the old passphrase and the new passphrase (twice) per device."
echo

for spec in "${CRYPT_DEVS[@]}"; do
  dev="$(resolve_dev "${spec}")"
  [[ -n "${dev}" ]] || die "Could not resolve device: $spec"
  [[ -b "${dev}" ]] || die "No block device: $dev (from $spec)"

  if cryptsetup isLuks "${dev}" >/dev/null 2>&1; then
    log "-> LUKS ChangeKey: $dev"
    cryptsetup luksChangeKey "${dev}"
    log "   OK: $dev"
  else
    warn "Device is not LUKS: $dev (skipped)"
  fi
done

echo
log "Step 2/2: Rotate Dropbear unlock key and regenerate initramfs."
echo

# Password for the 7z export (recommended: new CRED_MASTER_PW)
read -r -s -p "Password for 7z archive (recommended: new CRED_MASTER_PW): " ARCH_PW
echo
[[ -n "${ARCH_PW}" ]] || die "Empty password is not allowed."
read -r -s -p "Repeat password: " ARCH_PW2
echo
[[ "${ARCH_PW}" == "${ARCH_PW2}" ]] || die "Passwords do not match."

TMPDIR="$(mktemp -d -p /run penelope-rotate-unlock.XXXXXX)"
chmod 0700 "${TMPDIR}"

KEY_PRIV="${TMPDIR}/${DROPBEAR_KEY_NAME}"
KEY_PUB="${TMPDIR}/${DROPBEAR_KEY_NAME}.pub"

ssh-keygen -t ed25519 -N "" -f "${KEY_PRIV}" -C "penelope-initramfs-unlock@$(hostname)" >/dev/null
chmod 0600 "${KEY_PRIV}"
chmod 0644 "${KEY_PUB}"

PUB_LINE="$(tr -d '\r' < "${KEY_PUB}" | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
echo "${PUB_LINE}" | grep -qE '^ssh-ed25519[[:space:]]+[A-Za-z0-9+/=]+' \
  || die "New public key has unexpected format."

# Paths: Ubuntu/Debian dropbear-initramfs
DROP_DIR="/etc/dropbear/initramfs"
install -d -m 0755 "${DROP_DIR}"

install -o root -g root -m 0600 /dev/null "${DROP_DIR}/authorized_keys"
printf '%s\n' "${PUB_LINE}" > "${DROP_DIR}/authorized_keys"
chown root:root "${DROP_DIR}/authorized_keys"
chmod 0600 "${DROP_DIR}/authorized_keys"

# Ensure / update dropbear.conf (forced-command wrapper for deterministic unlock telemetry)
# The wrapper logs SSH unlock (including client IP) and marks the unlock method before it execs cryptroot-unlock.
FORCE_CMD=""
if [[ -x /bin/penelope-cryptroot-unlock-wrapper ]]; then
  FORCE_CMD="/bin/penelope-cryptroot-unlock-wrapper"
elif [[ -x /usr/bin/penelope-cryptroot-unlock-wrapper ]]; then
  FORCE_CMD="/usr/bin/penelope-cryptroot-unlock-wrapper"
elif [[ -x /usr/bin/cryptroot-unlock ]]; then
  FORCE_CMD="/usr/bin/cryptroot-unlock"
  warn "Wrapper not found; falling back to ${FORCE_CMD} (SSH-unlock telemetry may be reduced)."
elif [[ -x /lib/cryptsetup/cryptroot-unlock ]]; then
  FORCE_CMD="/lib/cryptsetup/cryptroot-unlock"
  warn "Wrapper not found; falling back to ${FORCE_CMD} (SSH-unlock telemetry may be reduced)."
else
  die "Neither penelope-cryptroot-unlock-wrapper nor cryptroot-unlock was found."
fi

install -o root -g root -m 0644 /dev/null "${DROP_DIR}/dropbear.conf"

# Write dropbear.conf (no install-time placeholders in the script; port/command are set at runtime)
if [[ -z "${DROPBEAR_PORT:-}" ]]; then
  die "DROPBEAR_PORT is empty; cannot write dropbear.conf safely."
fi
if [[ -z "${FORCE_CMD:-}" ]]; then
  die "FORCE_CMD is empty; cannot write dropbear.conf safely."
fi
log "Dropbear forced command: ${FORCE_CMD}"

cat > "${DROP_DIR}/dropbear.conf" <<EOF_DROPBEAR_CONF
# Version: ${SCRIPT_VERSION}
DROPBEAR_OPTIONS="-p ${DROPBEAR_PORT} -s -j -k -I 60 -c ${FORCE_CMD}"
EOF_DROPBEAR_CONF

# Sanity checks
if ! grep -qE "^# Version: ${SCRIPT_VERSION}([[:space:]]|$)" "${DROP_DIR}/dropbear.conf"; then
  die "missing or mismatched Version header in: ${DROP_DIR}/dropbear.conf"
fi
if ! grep -qF "DROPBEAR_OPTIONS=\"-p ${DROPBEAR_PORT} " "${DROP_DIR}/dropbear.conf"; then
  die "dropbear.conf does not contain the expected port: ${DROP_DIR}/dropbear.conf"
fi
if ! grep -qF " -c ${FORCE_CMD}\"" "${DROP_DIR}/dropbear.conf"; then
  die "dropbear.conf does not contain the expected forced command: ${DROP_DIR}/dropbear.conf"
fi
chown root:root "${DROP_DIR}/dropbear.conf"
chmod 0644 "${DROP_DIR}/dropbear.conf"

# Compatibility (older paths)
if [[ ! -e /etc/dropbear-initramfs ]]; then
  ln -s "${DROP_DIR}" /etc/dropbear-initramfs 2>/dev/null || true
fi

# Export 7z (AES-256, headers encrypted)
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_7Z="${TARGET_DESKTOP:-/root}/${TARGET_HOST}_unlock_keys_${STAMP}.7z"
rm -f "${OUT_7Z}"

# Avoid embedding absolute paths into the archive: add files from within TMPDIR.
key_priv_bn="$(basename "${KEY_PRIV}")"
key_pub_bn="$(basename "${KEY_PUB}")"

log "-> 7z export: ${OUT_7Z}"
(
  cd "${TMPDIR}"
  7z a -t7z -mhe=on -p"${ARCH_PW}" "${OUT_7Z}" "${key_priv_bn}" "${key_pub_bn}" >/dev/null
)

# Log archive size (bytes) deterministically (no 7z spam).
out_size=""
if command -v stat >/dev/null 2>&1; then
  out_size="$(stat -c %s "${OUT_7Z}" 2>/dev/null || true)"
else
  out_size="$(wc -c < "${OUT_7Z}" 2>/dev/null | tr -d ' ' || true)"
fi
log "   7z-archive size=${out_size:-?} bytes"

# Verify archive integrity and expected file list (quiet).
7z t -p"${ARCH_PW}" "${OUT_7Z}" >/dev/null

list_paths="$(
  7z l -slt -p"${ARCH_PW}" "${OUT_7Z}" 2>/dev/null \
    | grep '^Path = ' \
    | sed 's/^Path = //'
)"
echo "${list_paths}" | grep -qx "${key_priv_bn}" || die "7z list check failed: missing ${key_priv_bn}"
echo "${list_paths}" | grep -qx "${key_pub_bn}"  || die "7z list check failed: missing ${key_pub_bn}"
log "   7z-test=ok"
if [[ -n "${TARGET_USER:-}" && "${TARGET_USER}" != "root" ]]; then
  chown "${TARGET_USER}:${TARGET_USER}" "${OUT_7Z}" 2>/dev/null || warn "Could not change ownership of ${OUT_7Z} to ${TARGET_USER}."
fi

unset ARCH_PW ARCH_PW2

# initramfs rebuild
log "-> update-initramfs -u -k all"
penelope_initramfs_strict_smoke_test
update-initramfs -u -k all

log "DONE."
echo
echo "A new Dropbear unlock key has been activated (authorized_keys + initramfs)."
echo "Export archive (AES-256) is located here:"
echo "  $OUT_7Z"
echo
echo "Important:"
echo "  - Copy the 7z archive to secure offline storage immediately (USB / password manager)."
echo "  - The old unlock key will no longer work after the next boot."
echo
log "=== End ==="
ROT_EOF
      chown root:root /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh
      chmod 0750 /usr/local/sbin/penelope-rotate-masterpw-dropbear.sh
      finalize_generated_executable_shell_file "/usr/local/sbin/penelope-rotate-masterpw-dropbear.sh" 0750

      log "Installing ops tool: penelope-verify-security"
      install -d -m 0755 /usr/local/sbin
      cat > /usr/local/sbin/penelope-verify-security.sh <<'VERIFY_EOF'
#!/usr/bin/env bash
# penelope-verify-security.sh
# Version: ___PENELOPE_INSTALL_VERSION___
# Penelope - Security/setup verification (run on the installed system)
#
# Usage:
#   sudo -E /usr/local/sbin/penelope-verify-security.sh
#
# Optional (override):
#   TARGET_HOST="asterix" ADMIN_USER="obelix" sudo -E /usr/local/sbin/penelope-verify-security.sh
#
# Exit Codes:
#   0: success (no fatal checks)
#   1: general error

___PENELOPE_SOURCE_COMMON___

if (( BASH_VERSINFO[0] < 4 )); then
  >&2 echo "ERROR: Bash 4.0 or higher required."
  exit 1
fi

set -Eeuo pipefail
readonly BUNDLE_VERSION="___PENELOPE_INSTALL_VERSION___"
readonly SCRIPT_VERSION="${BUNDLE_VERSION}"

TARGET_HOST="${TARGET_HOST:-$(hostname -s)}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-$(id -un)}}"

ts() { date +"%H:%M:%S"; }

ok() { log "OK: $*"; }
info() { log "$*"; }
# warn() and die() come from penelope-common.sh

on_err() {
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-<unknown>}"
  cmd="${cmd//$'\n'/ }"
  cmd="${cmd//$'\r'/ }"
  if ((${#cmd} > 240)); then
    cmd="${cmd:0:240}<TRUNCATED>"
  fi
  >&2 echo "[$(ts)] ERROR: exit=${ec} line=${line} cmd=${cmd}"
  exit "${ec}"
}

trap on_err ERR

verify_shell_syntax_copy() {
  local path="$1"
  local label="$2"
  local syntax_out
  if [[ ! -f "${path}" ]]; then
    warn "${label}: missing (${path})"
    return 0
  fi
  if syntax_out="$(bash -n "${path}" 2>&1)"; then
    ok "${label}: shell syntax OK"
  else
    syntax_out="${syntax_out//$'\n'/; }"
    if ((${#syntax_out} > 400)); then
      syntax_out="${syntax_out:0:400}<TRUNCATED>"
    fi
    warn "${label}: shell syntax check failed (${path}): ${syntax_out:-no stderr output}"
  fi
}

verify_shellcheck_available() {
  if command -v shellcheck >/dev/null 2>&1; then
    ok "ShellCheck validation tool installed: $(command -v shellcheck)"
  else
    warn "ShellCheck validation tool missing. Full penelope-install should install the shellcheck package; restore the Penelope validation baseline before relying on global shell checks."
  fi
}

verify_required_file() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]]; then
    ok "${label}: present"
  else
    warn "${label}: missing (${path})"
  fi
}

verify_literal_in_file() {
  local path="$1"
  local literal="$2"
  local label="$3"
  if [[ ! -f "${path}" ]]; then
    warn "${label}: file missing (${path})"
    return 0
  fi
  if grep -qF "${literal}" "${path}" 2>/dev/null; then
    ok "${label}"
  else
    warn "${label}: expected literal missing in $(basename "${path}")"
  fi
}

verify_samba_array_passwords_sanitized() {
  local path="$1"
  local block="$2"
  local bad
  if [[ ! -f "${path}" ]]; then
    warn "Recovery bundle sanitized ${block} passwords: file missing (${path})"
    return 0
  fi
  bad="$(awk -v block="${block}" '
    $0 ~ ("^" block "=\(") { inarr=1; next }
    inarr && $0 ~ /^\)/ { inarr=0; next }
    inarr && $0 ~ /^[[:space:]]*"/ {
      line=$0
      sub(/^[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      n=split(line, a, ":")
      if (block == "CRED_SAMBA_ARCHIVE_USERS") {
        if (n < 2 || a[2] != "change-me") print line
      } else if (block == "CRED_MANAGED_SAMBA_SHARES") {
        if (n < 5 || a[2] != "change-me") print line
      }
    }
  ' "${path}" || true)"
  if [[ -z "${bad}" ]]; then
    ok "Recovery bundle sanitized ${block} passwords"
  else
    bad="${bad//$'\n'/; }"
    warn "Recovery bundle contains non-sanitized entries in ${block}: ${bad}"
  fi
}

verify_backup_recovery_dir_has_no_secret_files() {
  local dir="$1"
  local label_prefix="$2"
  local found=""
  local rel=""

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if [[ -e "${dir}/${rel}" ]]; then
      if [[ -n "${found}" ]]; then
        found+="; "
      fi
      found+="${rel}"
    fi
  done <<'EOF_VERIFY_BACKUP_RECOVERY_FORBIDDEN'
system.secret
home.secret
_archive.secret
system_pw
home_pw
_archive_pw
system_pw.prev
home_pw.prev
_archive_pw.prev
EOF_VERIFY_BACKUP_RECOVERY_FORBIDDEN

  if [[ -z "${found}" ]]; then
    ok "${label_prefix} recovery area contains no backup secret files"
  else
    warn "${label_prefix} recovery area contains unexpected backup secret-bearing files: ${found}"
  fi
}

verify_backup_recovery_copy() {
  local path="$1"
  local label_prefix="$2"
  local dir=""

  if [[ ! -f "${path}" ]]; then
    return 0
  fi

  verify_shell_syntax_copy "${path}" "${label_prefix}"
  if grep -qE '^CRED_INITIAL_RESTIC_(SYSTEM|HOME|ARCHIVE)_PASSWORD=' "${path}"; then
    verify_literal_in_file "${path}" 'CRED_INITIAL_RESTIC_SYSTEM_PASSWORD="change-me"' "${label_prefix} sanitizes CRED_INITIAL_RESTIC_SYSTEM_PASSWORD"
    verify_literal_in_file "${path}" 'CRED_INITIAL_RESTIC_HOME_PASSWORD="change-me"' "${label_prefix} sanitizes CRED_INITIAL_RESTIC_HOME_PASSWORD"
    verify_literal_in_file "${path}" 'CRED_INITIAL_RESTIC_ARCHIVE_PASSWORD="change-me"' "${label_prefix} sanitizes CRED_INITIAL_RESTIC_ARCHIVE_PASSWORD"
    return 0
  fi

  verify_literal_in_file "${path}" 'readonly BACKUP_SETUP_CONFIG_SCHEMA_VERSION="1"' "${label_prefix} uses external backup bootstrap config tree"
  verify_literal_in_file "${path}" "readonly BACKUP_SETUP_SECRETS_DIR=\"\${BACKUP_SETUP_CONFIG_DIR}/secrets.d\"" "${label_prefix} exposes external backup secrets-dir contract"
  dir="$(dirname "${path}")"
  verify_backup_recovery_dir_has_no_secret_files "${dir}" "${label_prefix}"
}

verify_samba_recovery_copy() {
  local path="$1"
  local label_prefix="$2"

  if [[ ! -f "${path}" ]]; then
    return 0
  fi

  verify_shell_syntax_copy "${path}" "${label_prefix}"
  verify_samba_array_passwords_sanitized "${path}" "CRED_SAMBA_ARCHIVE_USERS"
  verify_samba_array_passwords_sanitized "${path}" "CRED_MANAGED_SAMBA_SHARES"
}

verify_samba_include_wired() {
  local main_conf="$1"
  local include_path="$2"
  local escaped_path include_re

  if [[ ! -f "${main_conf}" ]]; then
    warn "Samba main config: missing (${main_conf})"
    return 0
  fi

  escaped_path="$(printf '%s' "${include_path}" | sed 's/[][(){}.^$*+?|\/]/\\&/g')"
  include_re="^[[:space:]]*include[[:space:]]*=[[:space:]]*\"?${escaped_path}\"?[[:space:]]*([#;].*)?$"

  if grep -Eq -- "${include_re}" "${main_conf}" 2>/dev/null; then
    ok "Samba main config includes Penelope managed include"
  else
    warn "Samba main config missing Penelope include wiring (${include_path})"
  fi
}

verify_samba_config_valid() {
  local testparm_output

  if ! command -v testparm >/dev/null 2>&1; then
    warn "Samba config validation: testparm not available"
    return 0
  fi

  if testparm_output="$(testparm -s 2>&1)"; then
    ok "Samba config validation via testparm -s"
    if grep -Fq "Weak crypto is allowed by GnuTLS" <<<"${testparm_output}"; then
      warn "Security watchpoint: testparm reports weak GnuTLS crypto is allowed."
      warn "Penelope verifies SMB3 and NTLMv2-only, but this host-level Samba/GnuTLS compatibility warning remains visible on this platform."
    fi
  else
    warn "Samba config validation failed (testparm -s)"
  fi
}

verify_samba_security_baseline() {
  local include_path="${SAMBA_MANAGED_INCLUDE}"
  verify_literal_in_file "${include_path}" 'server min protocol = SMB3_00' "Samba security baseline: server min protocol SMB3_00"
  verify_literal_in_file "${include_path}" 'client min protocol = SMB3_00' "Samba security baseline: client min protocol SMB3_00"
  verify_literal_in_file "${include_path}" 'ntlm auth = ntlmv2-only' "Samba security baseline: NTLMv2 only"
}

verify_systemd_unit_enabled_active() {
  local unit="$1"
  local label="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "${label}: systemctl not available"
    return 0
  fi
  if systemctl is-enabled --quiet "${unit}" >/dev/null 2>&1; then
    ok "${label}: enabled"
  else
    warn "${label}: not enabled"
  fi
  if systemctl is-active --quiet "${unit}" >/dev/null 2>&1; then
    ok "${label}: active"
  else
    warn "${label}: not active"
  fi
}

verify_windows_discovery_service() {
  if ! command -v wsdd2 >/dev/null 2>&1; then
    warn "Windows Explorer network discovery: wsdd2 not installed"
    return 0
  fi
  verify_systemd_unit_enabled_active "wsdd2.service" "Windows Explorer network discovery service"
}

require_root
systemctl daemon-reload >/dev/null 2>&1 || true  # best-effort: pick up unit changes


NON_SAMBA_PROFILE_MARKER="/etc/penelope/non-samba-profile"
SAMBA_MAIN_CONF="/etc/samba/smb.conf"
SAMBA_MANAGED_INCLUDE="/etc/samba/smb.conf.d/penelope-shares.conf"

echo "=== Penelope Verify Security (v${SCRIPT_VERSION}) - $(ts) ==="
echo "Note: audit/report tool (warnings do not lead to a nonzero exit)."
echo
info "Host=${TARGET_HOST}  Admin=${ADMIN_USER}"
info "Recovery verification phases:"
info "  - after install: local penelope-install.sh and penelope-common.sh should already be staged"
info "  - after penelope-backup-setup: local penelope-backup-setup.sh should be staged"
info "  - after penelope-samba-setup on a normal Penelope server: local penelope-samba-setup.sh should be staged"
info "  - if Samba is intentionally omitted: create ${NON_SAMBA_PROFILE_MARKER} with a short reason before late verify"
info "  - after the first successful internal backup sync: /_backup/<HOST_SCOPE_NAME>/_recovery should exist"
echo

# 0) Penelope validation tool baseline
verify_shellcheck_available

echo

# 1) UEFI / Secure Boot
if [[ -d /sys/firmware/efi ]]; then
  ok "UEFI mode detected (/sys/firmware/efi present)"
else
  warn "Not in UEFI mode? (/sys/firmware/efi missing) - check Secure Boot / EFI setup."
fi

if command -v mokutil >/dev/null 2>&1; then
  SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
  if echo "${SB_STATE}" | grep -qi "enabled"; then
    ok "Secure Boot: ENABLED (mokutil)"
  else
    warn "Secure Boot Status unklar/disabled (mokutil): ${SB_STATE:-<no output>}"
  fi
else
  info "mokutil not installed - check Secure Boot status in BIOS/UEFI or via 'apt install mokutil'."
fi

echo

# 2) SSHD password login (effective configuration)
if command -v sshd >/dev/null 2>&1; then
  SSHD_T="$(sshd -T 2>/dev/null || true)"
  if [[ -z "${SSHD_T}" ]]; then
    warn "SSHD: could not read the effective configuration via 'sshd -T'"
    PA=""
    KBDI=""
  else
    PA="$(printf '%s\n' "${SSHD_T}" | awk '$1=="passwordauthentication"{print $2; exit}')"
    KBDI="$(printf '%s\n' "${SSHD_T}" | awk '$1=="kbdinteractiveauthentication"{print $2; exit}')"
  fi
  if [[ "${PA:-}" == "no" ]]; then
    ok "SSHD: PasswordAuthentication no"
  else
    warn "SSHD: PasswordAuthentication is '${PA:-unknown}'"
  fi
  if [[ "${KBDI:-}" == "no" ]]; then
    ok "SSHD: KbdInteractiveAuthentication no"
  else
    warn "SSHD: KbdInteractiveAuthentication is '${KBDI:-unknown}'"
  fi
else
  info "sshd not found - if OpenSSH server is not used, that is fine."
fi

echo

# 3) Dropbear-initramfs (remote unlock)
DROP_DIR="/etc/dropbear/initramfs"
if [[ ! -d "${DROP_DIR}" && -L /etc/dropbear-initramfs ]]; then
  DROP_DIR="/etc/dropbear-initramfs"
fi

if [[ -d "${DROP_DIR}" ]]; then
  ok "Dropbear-initramfs directory found: ${DROP_DIR}"

  if [[ -f "${DROP_DIR}/authorized_keys" ]]; then
    st="$(stat -c 'owner=%U group=%G mode=%a size=%s' "${DROP_DIR}/authorized_keys" 2>/dev/null || true)"
    info "authorized_keys: ${st}"
    if [[ "$(stat -c '%a' "${DROP_DIR}/authorized_keys")" == "600" ]]; then
      ok "authorized_keys permissions: 600"
    else
      warn "authorized_keys permissions are not 600"
    fi
    if [[ -s "${DROP_DIR}/authorized_keys" ]]; then
      ok "authorized_keys is not empty"
    else
      warn "authorized_keys is empty"
    fi
    if head -n 1 "${DROP_DIR}/authorized_keys" | grep -qE '^ssh-(ed25519|rsa|ecdsa)[[:space:]]+'; then
      ok "authorized_keys format: OpenSSH public key detected"
    else
      warn "authorized_keys format looks implausible - SSH unlock in initramfs will probably not" \
        "work."
    fi
  else
    warn "authorized_keys missing under ${DROP_DIR}"
  fi

  if [[ -f "${DROP_DIR}/dropbear.conf" ]]; then
    ok "dropbear.conf present"
    info "dropbear.conf content:"
    sed 's/^/       /' "${DROP_DIR}/dropbear.conf" || true
  else
    warn "dropbear.conf missing under ${DROP_DIR} (check DROPBEAR_OPTIONS/port/restrictions)"
  fi
else
  warn "Dropbear-initramfs directory not found - remote unlock will not work."
fi

echo

# 4) GRUB kernel cmdline: ip= (for initramfs DHCP)
if [[ -f /etc/default/grub ]]; then
  if grep -qE 'GRUB_CMDLINE_LINUX_DEFAULT="[^"]*ip=' /etc/default/grub || \
    grep -qE 'GRUB_CMDLINE_LINUX="[^"]*ip=' /etc/default/grub; then
    ok "GRUB: found ip= parameter (DHCP for initramfs)"
  else
    warn "GRUB: no ip= parameter found - initramfs networking for SSH unlock may be missing."
  fi
else
  warn "/etc/default/grub missing - unusual."
fi

echo

# 5) Ports (running system)
info "Open TCP ports (running system):"
info "Note: This host-status inventory intentionally includes all visible TCP listeners."
info "Note: Expected access services such as AnyDesk are shown here as status, not as warnings."
PORTS_OUT="$(ss -lntp 2>/dev/null || true)"
printf '%s
' "${PORTS_OUT}" | sed 's/^/       /' || true

# Dropbear should NOT run on the running system (initramfs only).
# Therefore: search generically for dropbear listeners without hard-coding the port.
if printf '%s\n' "${PORTS_OUT}" | grep -qE 'LISTEN[[:space:]].*dropbear'; then
  warn "Dropbear process(es) active on the running system (should only be active in initramfs). Check initramfs cleanup/hook."
  DROPBEAR_LINES="$(printf '%s\n' "${PORTS_OUT}" | grep -E 'LISTEN[[:space:]].*dropbear' || true)"
  info "Dropbear Listener:"
  printf '%s
' "${DROPBEAR_LINES}" | sed 's/^/       /' || true

  # Extract PIDs (best effort) and print cmdline
  PIDS="$(printf '%s
' "${DROPBEAR_LINES}" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
  for PID in ${PIDS}; do
    if [[ -r "/proc/${PID}/cmdline" ]]; then
      CMD="$(tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null || true)"
      CMD="$(printf '%s' "${CMD}" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
      info "Dropbear pid=${PID} cmdline: ${CMD:-<unknown>}"
    else
      info "Dropbear pid=${PID} cmdline: <not readable>"
    fi
  done
else
  ok "No Dropbear on the running system"
  info "Note: Dropbear should run only in initramfs (before unlock)."
fi

echo

# 6) LUKS targets from /etc/crypttab
if [[ -f /etc/crypttab ]]; then
  info "crypttab entries:"
  sed 's/^/       /' /etc/crypttab || true

  if grep -qE '^[^#].*_crypt[[:space:]]' /etc/crypttab; then
    ok "crypttab contains _crypt targets"
  else
    warn "crypttab contains no _crypt targets (unexpected)"
  fi
else
  warn "/etc/crypttab missing - LUKS auto-unlock/boot behavior may differ."
fi

echo

# 7) Recovery stage / recovery bundle
info "Recovery stage directory: ${PENELOPE_RECOVERY_STAGE_DIR}"
if [[ -d "${PENELOPE_RECOVERY_STAGE_DIR}" ]]; then
  ok "Recovery stage directory present"
  verify_required_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-install.sh" "Recovery stage install copy"
  verify_required_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-common.sh" "Recovery stage common copy"
  verify_shell_syntax_copy "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-install.sh" "Recovery stage install copy"
  verify_shell_syntax_copy "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-common.sh" "Recovery stage common copy"
  verify_literal_in_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-install.sh" 'CRED_MASTER_PW="change-me"' "Recovery stage install copy sanitizes CRED_MASTER_PW"
  verify_literal_in_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-install.sh" 'CRED_LOGIN_PW="change-me"' "Recovery stage install copy sanitizes CRED_LOGIN_PW"

  if [[ -f /usr/local/sbin/penelope-backup.sh ]]; then
    verify_required_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-backup-setup.sh" "Recovery stage backup setup copy"
  else
    info "Recovery stage backup copy not yet expected (backup setup not installed)."
  fi
  verify_backup_recovery_copy "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-backup-setup.sh" "Recovery stage backup setup copy"

  if [[ -f "${SAMBA_MANAGED_INCLUDE}" ]]; then
    ok "Managed Samba include present (${SAMBA_MANAGED_INCLUDE})"
    verify_required_file "${SAMBA_MAIN_CONF}" "Samba main config"
    verify_samba_include_wired "${SAMBA_MAIN_CONF}" "${SAMBA_MANAGED_INCLUDE}"
    verify_samba_config_valid
    verify_samba_security_baseline
    verify_systemd_unit_enabled_active "smbd" "Samba service"
    verify_windows_discovery_service
    verify_required_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-samba-setup.sh" "Recovery stage samba setup copy"
  elif [[ -f "${NON_SAMBA_PROFILE_MARKER}" ]]; then
    info "Managed Samba include absent, but explicit non-Samba profile marker present (${NON_SAMBA_PROFILE_MARKER})"
  elif [[ -f /usr/local/sbin/penelope-backup.sh || -f /etc/penelope/backup.conf ]]; then
    warn "Managed Samba include absent (${SAMBA_MANAGED_INCLUDE})."
    warn "On a normal Penelope server, late verify after backup setup is expected after penelope-samba-setup."
    warn "For an intentional non-Samba host, create ${NON_SAMBA_PROFILE_MARKER} with a short reason."
  else
    info "Managed Samba include not yet expected before backup setup has been installed."
  fi
  if [[ -f "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-samba-setup.sh" ]]; then
    verify_samba_recovery_copy "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-samba-setup.sh" "Recovery stage samba setup copy"
  elif [[ -f "${NON_SAMBA_PROFILE_MARKER}" ]]; then
    info "Recovery stage samba copy intentionally absent on explicit non-Samba host (${NON_SAMBA_PROFILE_MARKER})."
  elif [[ ! -f "${SAMBA_MANAGED_INCLUDE}" ]]; then
    info "Recovery stage samba copy not present yet (expected before samba setup has staged it)."
  fi
else
  warn "Recovery stage directory missing (${PENELOPE_RECOVERY_STAGE_DIR})"
fi

if [[ -f /etc/penelope/backup.conf ]]; then
  RECOVERY_HOST_SCOPE="$(read_kv_value_from_file_or_default /etc/penelope/backup.conf HOST_SCOPE_NAME "${TARGET_HOST}")"
  INTERNAL_RECOVERY_DIR="/_backup/${RECOVERY_HOST_SCOPE}/_recovery"
  info "Expected internal recovery bundle: ${INTERNAL_RECOVERY_DIR}"
  if [[ -d "${INTERNAL_RECOVERY_DIR}" ]]; then
    ok "Internal recovery bundle present"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/penelope-install.sh" "Internal recovery bundle install copy"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/penelope-backup-setup.sh" "Internal recovery bundle backup copy"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/penelope-common.sh" "Internal recovery bundle common copy"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/penelope-offline-recover.sh" "Internal recovery bundle offline recover copy"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/README-RECOVERY.txt" "Internal recovery bundle README"
    verify_required_file "${INTERNAL_RECOVERY_DIR}/manifest.txt" "Internal recovery bundle manifest"

    verify_shell_syntax_copy "${INTERNAL_RECOVERY_DIR}/penelope-install.sh" "Internal recovery bundle install copy"
    verify_shell_syntax_copy "${INTERNAL_RECOVERY_DIR}/penelope-common.sh" "Internal recovery bundle common copy"
    verify_shell_syntax_copy "${INTERNAL_RECOVERY_DIR}/penelope-offline-recover.sh" "Internal recovery bundle offline recover copy"

    verify_literal_in_file "${INTERNAL_RECOVERY_DIR}/penelope-install.sh" 'CRED_MASTER_PW="change-me"' "Internal recovery install copy sanitizes CRED_MASTER_PW"
    verify_literal_in_file "${INTERNAL_RECOVERY_DIR}/penelope-install.sh" 'CRED_LOGIN_PW="change-me"' "Internal recovery install copy sanitizes CRED_LOGIN_PW"
    verify_backup_recovery_copy "${INTERNAL_RECOVERY_DIR}/penelope-backup-setup.sh" "Internal recovery bundle backup copy"

    if [[ -f "${INTERNAL_RECOVERY_DIR}/penelope-samba-setup.sh" ]]; then
      verify_samba_recovery_copy "${INTERNAL_RECOVERY_DIR}/penelope-samba-setup.sh" "Internal recovery bundle samba copy"
    elif [[ -f "${NON_SAMBA_PROFILE_MARKER}" ]]; then
      info "Internal recovery bundle samba copy intentionally absent on explicit non-Samba host (${NON_SAMBA_PROFILE_MARKER})."
    else
      info "Internal recovery bundle samba copy not present yet (expected until samba setup has been staged and a backup synced the bundle)."
    fi
  else
    info "Internal recovery bundle not present yet (expected after the first successful internal backup sync)."
  fi
else
  info "backup.conf not present; internal recovery bundle location cannot yet be derived (normal before backup setup or before backup.conf has been restored)."
fi

echo
echo "=== Verification completed ==="
VERIFY_EOF
      chown root:root /usr/local/sbin/penelope-verify-security.sh
      chmod 0750 /usr/local/sbin/penelope-verify-security.sh
      finalize_generated_executable_shell_file "/usr/local/sbin/penelope-verify-security.sh" 0750

      log "Set hostname"
      echo "${TARGET_HOST}" > /etc/hostname
      cat > /etc/hosts <<'HOSTS_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
127.0.0.1   localhost
127.0.1.1   ___PENELOPE_HOST___
HOSTS_EOF
      apply_placeholders /etc/hosts
      stamp_install_version /etc/hosts
      validate_generated_file /etc/hosts

      log "Creating admin user (${ADMIN_USER})"
      if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "${ADMIN_USER}"
      fi
      case $- in
        *x*) { set +x; printf '%s:%s\n' "$ADMIN_USER" "$CRED_LOGIN_PW"; set -x; } | chpasswd ;;
        *)  printf '%s:%s\n' "$ADMIN_USER" "$CRED_LOGIN_PW" | chpasswd ;;
      esac
      usermod -aG sudo,adm "${ADMIN_USER}"

      log "Locale en_US.UTF-8"
      sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
      locale-gen
      update-locale LANG=en_US.UTF-8 LC_MESSAGES=en_US.UTF-8

      log "Keyboard layout: de-DE"
      cat > /etc/default/keyboard <<'KBD_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBD_EOF
      stamp_install_version /etc/default/keyboard
      validate_generated_file /etc/default/keyboard

      log "Timezone Europe/Berlin"
      ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
      dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

      log "Disabling Wayland (X11 for AnyDesk)"
      if [[ -f /etc/gdm3/custom.conf ]]; then
        sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf || true
        grep -q '^WaylandEnable=false' /etc/gdm3/custom.conf || echo 'WaylandEnable=false' >> /etc/gdm3/custom.conf
      fi

      log "GNOME defaults: dark mode + night light (system-wide defaults)"
      # These settings are defaults (they apply only if the user has not set their own values yet).
      # Dark Mode:
      #   org.gnome.desktop.interface color-scheme 'prefer-dark'
      # Night Light:
      #   enabled, manual 20:00-07:00, temperature 3700K
      install -m 0755 -d /etc/dconf/profile
      if [[ ! -f /etc/dconf/profile/user ]]; then
        cat > /etc/dconf/profile/user <<'DCONF_PROFILE_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
user-db:user
system-db:local
DCONF_PROFILE_EOF
        stamp_install_version /etc/dconf/profile/user
        validate_generated_file /etc/dconf/profile/user
      fi

      install -m 0755 -d /etc/dconf/db/local.d
      cat > /etc/dconf/db/local.d/00-${TARGET_HOST}-ui <<'DCONF_DEFAULTS_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/settings-daemon/plugins/color]
night-light-enabled=true
night-light-schedule-automatic=false
night-light-schedule-from=20.0
night-light-schedule-to=7.0
night-light-temperature=uint32 3700
DCONF_DEFAULTS_EOF
      stamp_install_version "/etc/dconf/db/local.d/00-${TARGET_HOST}-ui"
      validate_generated_file "/etc/dconf/db/local.d/00-${TARGET_HOST}-ui"

      dconf update || true

      log "Writing fstab"
      if [[ -z "${BACKUP_UUID:-}" ]]; then
        die "BACKUP_UUID is empty; cannot add /_backup to fstab safely. Check $BACKUP_DEV and blkid."
      fi

      cat > /etc/fstab <<'FSTAB_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
UUID=___PENELOPE_ROOT_UUID___    /         ext4 defaults,noatime 0 1
UUID=___PENELOPE_HOME_UUID___    /home     ext4 defaults,noatime 0 2
UUID=___PENELOPE_ARCHIVE_UUID___ /_archive ext4 defaults,noatime 0 2
UUID=___PENELOPE_BACKUP_UUID___ /_backup  ext4 defaults,noatime,nofail 0 2
UUID=___PENELOPE_BOOT_UUID___    /boot     ext4 defaults        0 2
UUID=___PENELOPE_EFI_UUID___     /boot/efi vfat umask=0077      0 1
FSTAB_EOF
      apply_placeholders /etc/fstab
      stamp_install_version /etc/fstab
      validate_generated_file /etc/fstab

      if [[ ! -x /lib/cryptsetup/scripts/decrypt_keyctl ]]; then
        die "decrypt_keyctl is missing or not executable under /lib/cryptsetup/scripts/decrypt_keyctl; cannot write crypttab safely for single-prompt unlock."
      fi

      log "Writing crypttab (decrypt_keyctl: single prompt only)"
      cat > /etc/crypttab <<'CRYPTTAB_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_MAPPER_ROOT___ UUID=___PENELOPE_LUKS_ROOT_UUID___   none luks,discard,keyscript=/lib/cryptsetup/scripts/decrypt_keyctl
___PENELOPE_MAPPER_HOME___ UUID=___PENELOPE_LUKS_HOME_UUID___   none luks,discard,keyscript=/lib/cryptsetup/scripts/decrypt_keyctl
___PENELOPE_MAPPER_ARCHIVE___ UUID=___PENELOPE_LUKS_ARCHIVE_UUID___ none luks,discard,keyscript=/lib/cryptsetup/scripts/decrypt_keyctl
CRYPTTAB_EOF
      apply_placeholders /etc/crypttab
      stamp_install_version /etc/crypttab
      validate_generated_file /etc/crypttab

      log "initramfs: prepare SSH unlock wrapper (forced command)"

      # The wrapper lives under /bin on the target system and is copied into initramfs by the hook.
      install -o root -g root -m 0755 /dev/null /bin/penelope-cryptroot-unlock-wrapper
      cat > /bin/penelope-cryptroot-unlock-wrapper <<'EOF_PENELOPE_CRYPTROOT_UNLOCK_WRAPPER'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
# Purpose:
#   - Log SSH-based unlock attempts (incl. client IP) deterministically.
#   - Mark unlock method (ssh) for later correlation (local-bottom).
#   - Exec cryptroot-unlock unchanged.
___PENELOPE_LOG_FUNCTIONS___
set -eu

# Be defensive: early initramfs may not have /dev/null yet.
STDERR_SINK="/proc/self/fd/2"
[ -c /dev/null ] && STDERR_SINK="/dev/null"

ts() { date +'%H:%M:%S' 2>"$STDERR_SINK" || echo "00:00:00"; }

BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>"$STDERR_SINK" || true

LOG="$BASE/penelope-initramfs-unlock.log"
LOG_PUB="/run/penelope-initramfs-unlock.log"
touch "$LOG" "$LOG_PUB" 2>"$STDERR_SINK" || true

append() {
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG" 2>"$STDERR_SINK" || true
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG_PUB" 2>"$STDERR_SINK" || true
}

# Extract best-effort client info (differs by ssh server).
SSH_CONN="${SSH_CONNECTION:-}"
SSH_CLIENT_V="${SSH_CLIENT:-}"
DB_IP="${DROPBEAR_CLIENT_IP:-}"
DB_PORT="${DROPBEAR_CLIENT_PORT:-}"

client_ip=""
client_port=""

if [ -n "$SSH_CONN" ]; then
  # SSH_CONNECTION: "<client_ip> <client_port> <server_ip> <server_port>"
  set -- $SSH_CONN
  client_ip="${1:-}"
  client_port="${2:-}"
elif [ -n "$SSH_CLIENT_V" ]; then
  # SSH_CLIENT: "<client_ip> <client_port> <server_port>"
  set -- $SSH_CLIENT_V
  client_ip="${1:-}"
  client_port="${2:-}"
elif [ -n "$DB_IP" ]; then
  client_ip="$DB_IP"
  client_port="$DB_PORT"
fi

method_file="$BASE/unlock.method"
ssh_file="$BASE/ssh-unlock.last"
ssh_event_file="$BASE/ssh-unlock.event"
echo "ssh" >"$method_file" 2>"$STDERR_SINK" || true

ev_ts="$(ts)"

{
  echo "method=ssh"
  echo "event_ts=${ev_ts}"
  echo "event_client_ip=${client_ip:-}"
  echo "event_client_port=${client_port:-}"
  echo "last_seen_ts=${ev_ts}"
  echo "last_seen_client_ip=${client_ip:-}"
  echo "last_seen_client_port=${client_port:-}"
  echo "ssh_connection=${SSH_CONN}"
  echo "ssh_client=${SSH_CLIENT_V}"
  echo "dropbear_client_ip=${DB_IP}"
  echo "dropbear_client_port=${DB_PORT}"
} >"$ssh_file" 2>"$STDERR_SINK" || true
cp -f "$ssh_file" "$ssh_event_file" 2>"$STDERR_SINK" || true

append "unlock: method=ssh client_ip=${client_ip:-<unknown>} client_port=${client_port:-<unknown>}"

# Locate cryptroot-unlock (initramfs usually has it in /bin due to hook copy_exec).
CR="/bin/cryptroot-unlock"
if [ -x "$CR" ]; then
  exec "$CR"
fi
CR="/usr/bin/cryptroot-unlock"
[ -x "$CR" ] && exec "$CR"
CR="/sbin/cryptroot-unlock"
[ -x "$CR" ] && exec "$CR"

append "unlock: ERROR cryptroot-unlock not found"
exit 127
EOF_PENELOPE_CRYPTROOT_UNLOCK_WRAPPER
      chmod 0755 /bin/penelope-cryptroot-unlock-wrapper
      finalize_generated_executable_shell_file /bin/penelope-cryptroot-unlock-wrapper 0755

      log "Configure Dropbear initramfs (key-only, restrictive)"
      # Determine forced-command path (usrmerge-safe); prefer wrapper for SSH unlock logging
      if [[ -x /bin/penelope-cryptroot-unlock-wrapper ]]; then
        DROPBEAR_FORCE_CMD="/bin/penelope-cryptroot-unlock-wrapper"
      elif [[ -x /usr/bin/penelope-cryptroot-unlock-wrapper ]]; then
        DROPBEAR_FORCE_CMD="/usr/bin/penelope-cryptroot-unlock-wrapper"
      elif [[ -x /usr/bin/cryptroot-unlock ]]; then
        DROPBEAR_FORCE_CMD="/usr/bin/cryptroot-unlock"
      elif [[ -x /bin/cryptroot-unlock ]]; then
        DROPBEAR_FORCE_CMD="/bin/cryptroot-unlock"
      elif [[ -x /lib/cryptsetup/cryptroot-unlock ]]; then
        DROPBEAR_FORCE_CMD="/lib/cryptsetup/cryptroot-unlock"
      else
        warn "Dropbear forced-command candidates were not executable; dumping current candidate state before abort."
        for candidate in \
          /bin/penelope-cryptroot-unlock-wrapper \
          /usr/bin/penelope-cryptroot-unlock-wrapper \
          /usr/bin/cryptroot-unlock \
          /bin/cryptroot-unlock \
          /lib/cryptsetup/cryptroot-unlock; do
          if [[ -e "${candidate}" ]]; then
            ls -l "${candidate}" >&2 || true
          else
            warn "missing candidate: ${candidate}"
          fi
        done
        die "Neither penelope-cryptroot-unlock-wrapper nor cryptroot-unlock found; cannot set Dropbear forced command safely."
      fi
      log "Dropbear forced command: ${DROPBEAR_FORCE_CMD}"
      # Ubuntu: dropbear-initramfs nutzt /etc/dropbear/initramfs/*
      rm -rf /etc/dropbear-initramfs || true
      mkdir -p /etc/dropbear/initramfs

      # Read public key (strip CRLF) and write it with a newline
      PUB_UNLOCK="$(tr -d '\r' < /root/${KEY_STAGE_DIR}/${DROPBEAR_KEY_NAME}.pub)"
      printf '%s\n' "${PUB_UNLOCK}" > /etc/dropbear/initramfs/authorized_keys
      chmod 0600 /etc/dropbear/initramfs/authorized_keys

      : "${DROPBEAR_FORCE_CMD:=/usr/bin/cryptroot-unlock}"
      cat > /etc/dropbear/initramfs/dropbear.conf <<'DROP_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
# -p PORT  : Port
# -s       : Disable password login
# -j       : Disable local port forwarding
# -k       : Disable remote port forwarding
# -I SEC   : Idle Timeout
# -c CMD   : Forced command
DROPBEAR_OPTIONS="-p ___PENELOPE_DROPBEAR_PORT___ -s -j -k -I 60 -c ___PENELOPE_DROPBEAR_FORCE_CMD___"
DROP_EOF
      apply_placeholders /etc/dropbear/initramfs/dropbear.conf
      stamp_install_version /etc/dropbear/initramfs/dropbear.conf
      validate_generated_file /etc/dropbear/initramfs/dropbear.conf
      chmod 0644 /etc/dropbear/initramfs/dropbear.conf
      # initramfs debug/network scripts are installed in consolidated form further below.
      log "initramfs: cleanup prior Penelope initramfs artifacts (avoid version mixing)"
      initramfs_cleanup_penelope_artifacts

      log "initramfs: installing Dropbear DHCP guard override (prevents long retry loops)"
      mkdir -p /etc/initramfs-tools/scripts/init-premount

      cat > "/etc/initramfs-tools/scripts/init-premount/dropbear" <<'EOF_INITPREMOUNT_DROPBEAR_OVERRIDE'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
# Penelope override for dropbear-initramfs init-premount script.
# Goal: avoid long DHCP retry loops when dhcpcd gets a lease but hook exit code is non-zero.
___PENELOPE_LOG_FUNCTIONS___
set -eu

# Some initramfs environments execute very early, before /dev/null exists.
# Redirections to /dev/null must never prevent directory creation or logging.
STDERR_SINK="/proc/self/fd/2"
ensure_dev_null() {
  # best-effort: never fail strict boot because /dev/null is missing
  [ -c /dev/null ] && return 0
  mkdir -p /dev 2>"$STDERR_SINK" || true
  command -v mknod >"$STDERR_SINK" 2>"$STDERR_SINK" || return 0
  mknod -m 666 /dev/null c 1 3 2>"$STDERR_SINK" || true
  return 0
}
ensure_dev_null || true
if [ -c /dev/null ]; then STDERR_SINK="/dev/null"; fi

ts() { date +'%H:%M:%S' 2>"$STDERR_SINK" || echo "00:00:00"; }

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>"$STDERR_SINK" || true

LOG="$BASE/penelope-initramfs-dropbear.log"
LOG_PUB="/run/penelope-initramfs-dropbear.log"
touch "$LOG" "$LOG_PUB" 2>"$STDERR_SINK" || true

# Capture stderr early (collect transient errors like "head: not found")
exec 2>>"$LOG"

append() {
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG" 2>"$STDERR_SINK" || true
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG_PUB" 2>"$STDERR_SINK" || true
}

strip_quotes() {
  v="${1:-}"
  v="${v#\"}"
  v="${v%\"}"
  v="${v#\'}"
  v="${v%\'}"
  printf '%s' "$v"
}

DEVICE=""
IP_MODE=""
if [ -r /conf/param.conf ]; then
  while IFS= read -r _l; do
    case "$_l" in
      DEVICE=*) DEVICE="${_l#DEVICE=}" ;;
      IP=*) IP_MODE="${_l#IP=}" ;;
    esac
  done < /conf/param.conf 2>"$STDERR_SINK" || true
fi

DEVICE="$(strip_quotes "$DEVICE")"
IP_MODE="$(strip_quotes "$IP_MODE")"
[ -n "$IP_MODE" ] || IP_MODE="dhcp"

if [ -z "$DEVICE" ]; then
  # Best-effort fallback: first non-lo interface
  if [ -d /sys/class/net ]; then
    for n in /sys/class/net/*; do
      bn="${n##*/}"
      [ "$bn" = "lo" ] && continue
      DEVICE="$bn"
      break
    done
  fi
fi

append "dropbear_override: start iface=${DEVICE:-<none>} ip_mode=${IP_MODE:-<none>}"

# Bring link up (best-effort)
if command -v ip >"$STDERR_SINK" 2>&1 && [ -n "${DEVICE:-}" ]; then
  ip link set dev "$DEVICE" up >"$STDERR_SINK" 2>&1 || true
fi

ipv4_local_detect() {
  # Prefer 'ip' output if available; otherwise fall back to /proc/net/fib_trie parsing.
  if command -v ip >"$STDERR_SINK" 2>&1 && [ -n "${DEVICE:-}" ]; then
    # Use a simple sed parse to avoid awk dependency.
    if command -v sed >"$STDERR_SINK" 2>&1; then
      _ip4="$(ip -4 addr show dev "$DEVICE" 2>"$STDERR_SINK" | sed -n 's/^[[:space:]]*inet[[:space:]]\([0-9.]*\)\/.*/\1/p' | sed -n '1p' 2>"$STDERR_SINK")"
      _ip4="$(printf '%s' "${_ip4:-}" | tr -d '[:space:]')"
      case "${_ip4}" in
        ""|127.*|0.*|169.254.*) : ;;
        *) printf '%s' "${_ip4}"; return 0 ;;
      esac
    fi
  fi

  [ -r /proc/net/fib_trie ] || return 1
  while IFS= read -r ln; do
    case "$ln" in
      *"/32 host LOCAL"*)
        a="${ln##*-- }"
        a="${a%%/*}"
        a="$(printf '%s' "${a:-}" | tr -d '[:space:]')"
        case "$a" in
          ""|127.*|0.*|169.254.*) continue ;;
        esac
        printf '%s' "$a"
        return 0
        ;;
    esac
  done < /proc/net/fib_trie 2>"$STDERR_SINK"
  return 1
}


default_route_detect() {
  # Returns gateway hex for the default route on the given iface, or fails.
  _iface="${1:-}"
  [ -n "$_iface" ] || return 1
  [ -r /proc/net/route ] || return 1
  while IFS= read -r _ln; do
    case "$_ln" in
      Iface*|"" ) continue ;;
    esac
    set -- $_ln
    [ $# -ge 4 ] || continue
    _r_if="$1"
    _r_dst="$2"
    _r_gw="$3"
    _r_flags="$4"
    [ "$_r_if" = "$_iface" ] || continue
    [ "$_r_dst" = "00000000" ] || continue
    # Route must be UP (bit 0 set)
    _fl=$((16#$_r_flags))
    [ $((_fl & 1)) -ne 0 ] || continue
    [ "$_r_gw" != "00000000" ] || continue
    printf '%s' "$_r_gw"
    return 0
  done < /proc/net/route 2>"$STDERR_SINK"
  return 1
}

hex_to_ipv4() {
  # Convert little-endian hex (as in /proc/net/route) to dotted IPv4.
  _h="${1:-}"
  [ -n "$_h" ] || return 1
  case "$_h" in
    *[!0-9A-Fa-f]* ) return 1 ;;
  esac
  _v=$((16#$_h))
  _b1=$((_v & 255))
  _b2=$(((_v >> 8) & 255))
  _b3=$(((_v >> 16) & 255))
  _b4=$(((_v >> 24) & 255))
  printf '%s.%s.%s.%s' "$_b1" "$_b2" "$_b3" "$_b4"
}

arp_hello_after_dhcp() {
  _iface="${1:-}"
  _ipv4="${2:-}"
  _gw="${3:-}"
  [ -n "$_iface" ] || return 0
  [ -n "$_ipv4" ] || return 0

  if command -v arping >"$STDERR_SINK" 2>&1; then
    append "arp_hello: arping -U -I ${_iface} ${_ipv4}"
    arping -q -c 2 -U -I "$_iface" "$_ipv4" >"$STDERR_SINK" 2>&1 || true  # best-effort: router presence hint
    return 0
  fi

  if [ -n "$_gw" ] && command -v ping >"$STDERR_SINK" 2>&1; then
    append "arp_hello: ping -c 1 ${_gw}"
    ping -c 1 -W 1 "$_gw" >"$STDERR_SINK" 2>&1 || true  # best-effort: router presence hint
    return 0
  fi

  append "arp_hello: skipped(no arping/ping)"
  return 0
}

KEEPALIVE_PIDFILE="$BASE/keepalive.pid"
KEEPALIVE_STATEFILE="$BASE/keepalive.last"

keepalive_start() {
  _iface="${1:-}"
  _ipv4="${2:-}"
  _gw="${3:-}"
  [ -n "$_iface" ] || return 0
  [ -n "$_ipv4" ] || return 0

  # FRITZ!Box tends to mark hosts inactive if they only answered inbound traffic.
  # To keep router presence stable while waiting for LUKS unlock, we generate small outbound traffic.
  _interval=60

  _ping="no"
  _arping="no"
  command -v ping >"$STDERR_SINK" 2>&1 && _ping="yes"
  command -v arping >"$STDERR_SINK" 2>&1 && _arping="yes"
  append "keepalive: tools ping=${_ping} arping=${_arping}"

  if [ -r "$KEEPALIVE_PIDFILE" ]; then
    _pid="$(cat "$KEEPALIVE_PIDFILE" 2>"$STDERR_SINK" || true)"
    case "$_pid" in
      ''|*[!0-9]*) _pid="" ;;
    esac
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>"$STDERR_SINK"; then
      append "keepalive: already_running pid=${_pid} interval=${_interval}s"
      return 0
    fi
    rm -f "$KEEPALIVE_PIDFILE" 2>"$STDERR_SINK" || true
  fi

  # One-time outbound "hello burst" right after DHCP helps some routers (FRITZ!Box) update their active-host cache.
  # Best-effort: never fail boot if this doesn't work.
  if command -v arping >"$STDERR_SINK" 2>&1; then
    if [ -n "$_gw" ]; then
      _rc=0
      arping -q -c 2 -I "$_iface" "$_gw" >"$STDERR_SINK" 2>&1 || _rc=$?
      append "keepalive: hello_burst method=arping-gw rc=${_rc} gw=${_gw}"
    fi
    _rc=0
    arping -q -c 2 -U -I "$_iface" "$_ipv4" >"$STDERR_SINK" 2>&1 || _rc=$?
    append "keepalive: hello_burst method=garp rc=${_rc} ipv4=${_ipv4}"
  elif [ -n "$_gw" ] && command -v ping >"$STDERR_SINK" 2>&1; then
    _rc=0
    ping -c 1 -W 1 "$_gw" >"$STDERR_SINK" 2>&1 || _rc=$?
    append "keepalive: hello_burst method=ping rc=${_rc} gw=${_gw}"
  fi

  if [ -n "$_gw" ] && command -v ping >"$STDERR_SINK" 2>&1; then
    append "keepalive: start method=ping interval=${_interval}s iface=${_iface} ipv4=${_ipv4} gw=${_gw}"
    _rc=0
    ping -c 1 -W 1 "$_gw" >"$STDERR_SINK" 2>&1 || _rc=$?
    append "keepalive: first_send method=ping rc=${_rc}"
    (
      while :; do
        printf '%s method=ping iface=%s ipv4=%s gw=%s\n' "$(ts)" "$_iface" "$_ipv4" "$_gw" >"$KEEPALIVE_STATEFILE" 2>"$STDERR_SINK" || true
        ping -c 1 -W 1 "$_gw" >"$STDERR_SINK" 2>&1 || true  # best-effort: keep router entry active
        sleep "$_interval" || true
      done
    ) &
    echo "$!" >"$KEEPALIVE_PIDFILE" 2>"$STDERR_SINK" || true
    return 0
  fi

  if [ -n "$_gw" ] && command -v arping >"$STDERR_SINK" 2>&1; then
    append "keepalive: start method=arping-gw interval=${_interval}s iface=${_iface} ipv4=${_ipv4} gw=${_gw}"
    _rc=0
    arping -q -c 1 -I "$_iface" "$_gw" >"$STDERR_SINK" 2>&1 || _rc=$?
    append "keepalive: first_send method=arping-gw rc=${_rc}"
    (
      while :; do
        printf '%s method=arping-gw iface=%s ipv4=%s gw=%s\n' "$(ts)" "$_iface" "$_ipv4" "$_gw" >"$KEEPALIVE_STATEFILE" 2>"$STDERR_SINK" || true
        arping -q -c 1 -I "$_iface" "$_gw" >"$STDERR_SINK" 2>&1 || true  # best-effort: keep router entry active
        sleep "$_interval" || true
      done
    ) &
    echo "$!" >"$KEEPALIVE_PIDFILE" 2>"$STDERR_SINK" || true
    return 0
  fi

  if command -v arping >"$STDERR_SINK" 2>&1; then
    append "keepalive: start method=garp interval=${_interval}s iface=${_iface} ipv4=${_ipv4}"
    _rc=0
    arping -q -c 1 -U -I "$_iface" "$_ipv4" >"$STDERR_SINK" 2>&1 || _rc=$?
    append "keepalive: first_send method=garp rc=${_rc}"
    (
      while :; do
        printf '%s method=garp iface=%s ipv4=%s\n' "$(ts)" "$_iface" "$_ipv4" >"$KEEPALIVE_STATEFILE" 2>"$STDERR_SINK" || true
        arping -q -c 1 -U -I "$_iface" "$_ipv4" >"$STDERR_SINK" 2>&1 || true  # best-effort: keep router entry active
        sleep "$_interval" || true
      done
    ) &
    echo "$!" >"$KEEPALIVE_PIDFILE" 2>"$STDERR_SINK" || true
    return 0
  fi

  append "keepalive: skipped(no ping/arping)"
}

pre_ipv4=""
pre_ipv4_present="no"
if pre_ipv4="$(ipv4_local_detect 2>"$STDERR_SINK")"; then
  pre_ipv4_present="yes"
fi
append "dropbear_override: pre_dhcp ipv4_present=${pre_ipv4_present} ipv4=${pre_ipv4:-<none>}"

dhcp_rc=0
case "$IP_MODE" in
  dhcp|DHCP)
    if command -v dhcpcd >"$STDERR_SINK" 2>&1 && [ -n "${DEVICE:-}" ]; then
      append "dhcp: begin (dhcpcd oneshot, hooks disabled: resolv.conf/hostname/wpa_supplicant)"
      TARGET_HOST="___PENELOPE_TARGET_HOST___"
      : "${TARGET_HOST:?TARGET_HOST missing}"
      HOSTNAME="$TARGET_HOST"
      append "dhcp: hostname=${HOSTNAME}"
      append "dhcp: cmd=dhcpcd -1KL -t 30 -4 -h ${HOSTNAME} -C resolv.conf -C hostname -C wpa_supplicant ${DEVICE}"
      dhcp_rc=0
      if dhcpcd -1KL -t 30 -4 -h "$HOSTNAME" -C resolv.conf -C hostname -C wpa_supplicant "$DEVICE" >>"$LOG" 2>&1; then
        dhcp_rc=0
      else
        dhcp_rc=$?
      fi
      append "dhcp: end rc=${dhcp_rc}"
    else
      append "dhcp: skipped(no dhcpcd or iface)"
      dhcp_rc=0
    fi
    ;;
  *)
    append "dhcp: skipped(ip_mode=${IP_MODE})"
    dhcp_rc=0
    ;;
esac

post_ipv4=""
post_ipv4_present="no"
if post_ipv4="$(ipv4_local_detect 2>"$STDERR_SINK")"; then
  post_ipv4_present="yes"
fi
append "dropbear_override: post_dhcp ipv4_present=${post_ipv4_present} ipv4=${post_ipv4:-<none>}"

post_gw_hex=""
post_gw_present="no"
if post_gw_hex="$(default_route_detect "${DEVICE:-}" 2>"$STDERR_SINK")"; then
  post_gw_present="yes"
fi
append "dropbear_override: post_dhcp default_route_present=${post_gw_present} gw_hex=${post_gw_hex:-<none>}"

post_gw=""
if [ "$post_gw_present" = "yes" ]; then
  post_gw="$(hex_to_ipv4 "$post_gw_hex" 2>"$STDERR_SINK" || true)"
fi

if [ "$dhcp_rc" -eq 0 ] && [ "$post_ipv4_present" = "yes" ]; then
  arp_hello_after_dhcp "${DEVICE:-}" "$post_ipv4" "${post_gw:-}"
  keepalive_start "${DEVICE:-}" "$post_ipv4" "${post_gw:-}"
fi

if [ "$dhcp_rc" -ne 0 ]; then
  if [ "$post_ipv4_present" = "yes" ] && [ "$post_gw_present" = "yes" ]; then
    append "dhcp_guard: rc=${dhcp_rc} but ipv4+default_route present -> treating as success"
    dhcp_rc=0
  else
    append "dhcp_guard: rc=${dhcp_rc} ipv4_present=${post_ipv4_present} default_route_present=${post_gw_present} -> treating as failure (no retries)"
  fi
fi

CONF=""
for cf in /etc/dropbear/dropbear.conf /etc/dropbear-initramfs/dropbear.conf /etc/dropbear/initramfs/dropbear.conf; do
  [ -r "$cf" ] || continue
  CONF="$cf"
  break
done

DROPBEAR_OPTIONS=""
if [ -n "$CONF" ]; then
  DROPBEAR_OPTIONS="$(
    (
      # shellcheck source=/dev/null
      . "$CONF" 2>"$STDERR_SINK" || true
      printf '%s' "${DROPBEAR_OPTIONS:-}"
    ) 2>"$STDERR_SINK" || true
  )"
fi

DB_BIN=""
for b in /usr/sbin/dropbear /sbin/dropbear /bin/dropbear dropbear; do
  if command -v "$b" >"$STDERR_SINK" 2>&1; then
    DB_BIN="$(command -v "$b" 2>"$STDERR_SINK" || true)"
    break
  fi
done

if [ -n "$DB_BIN" ]; then
  append "dropbear: start bin=${DB_BIN} conf=${CONF:-<none>}"
  if [ -n "$DROPBEAR_OPTIONS" ]; then
    set -- $DROPBEAR_OPTIONS
  else
    set --
  fi
  "$DB_BIN" "$@" >>"$LOG" 2>&1 || append "WARNING: dropbear start failed rc=$?"
# Diagnostics (best-effort): port, keys, IP, listening socket
DB_PORT=""
if [ -n "$DROPBEAR_OPTIONS" ]; then
  # naive parse: first '-p <port>'
  set -- $DROPBEAR_OPTIONS
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-p" ]; then
      DB_PORT="$a"
      break
    fi
    prev="$a"
  done
fi
[ -n "$DB_PORT" ] || DB_PORT="<unknown>"
AK="/etc/dropbear/initramfs/authorized_keys"
if [ -r "$AK" ]; then
  # Best-effort: only diagnostics. Do not leak key material.
  ak_lines=0
  while IFS= read -r _line || [ -n "${_line:-}" ]; do
    # count non-empty lines only
    case "${_line}" in
      *[![:space:]]*) ak_lines=$((ak_lines + 1)) ;;
    esac
  done <"$AK" 2>"$STDERR_SINK" || true
  append "dropbear: authorized_keys present path=$AK lines=${ak_lines}"
else
  append "dropbear: authorized_keys missing path=$AK"
fi

if command -v ip >"$STDERR_SINK" 2>&1; then
  if [ -n "$DEVICE" ]; then
    ip4="$(
      ip -4 -o addr show dev "$DEVICE" 2>"$STDERR_SINK" | {
        IFS= read -r _l || true
        set -- ${_l:-}
        printf '%s' "${4:-}"
      } || true
    )"
    append "dropbear: iface=$DEVICE ip4=${ip4:-<none>}"
  fi

  gw="$(
    ip -4 route show default 2>"$STDERR_SINK" | {
      IFS= read -r _r || true
      gw=""
      prev=""
      for w in ${_r:-}; do
        if [ "$prev" = "via" ]; then
          gw="$w"
          break
        fi
        prev="$w"
      done
      printf '%s' "$gw"
    } || true
  )"
  append "dropbear: gw4=${gw:-<none>}"
fi

if command -v ss >"$STDERR_SINK" 2>&1; then
  # Best-effort: diagnostics only. Avoid brittle parsing tools in initramfs.
  lsock="$(
    ss -ltn 2>"$STDERR_SINK" | {
      while IFS= read -r line; do
        case "$line" in
          *":${DB_PORT} "*) printf '%s' "$line"; break ;;
        esac
      done
    } || true
  )"
  append "dropbear: listen_check tool=ss port=${DB_PORT} hit=$([ -n "$lsock" ] && echo yes || echo no)"
elif command -v netstat >"$STDERR_SINK" 2>&1; then
  lsock="$(
    netstat -ltn 2>"$STDERR_SINK" | {
      while IFS= read -r line; do
        case "$line" in
          *":${DB_PORT} "*) printf '%s' "$line"; break ;;
        esac
      done
    } || true
  )"
  append "dropbear: listen_check tool=netstat port=${DB_PORT} hit=$([ -n "$lsock" ] && echo yes || echo no)"
else
  append "dropbear: listen_check tool=none port=${DB_PORT}"
fi
else
  append "WARNING: dropbear binary not found"
fi

append "dropbear_override: done dhcp_rc=${dhcp_rc}"
exit 0
EOF_INITPREMOUNT_DROPBEAR_OVERRIDE
      chmod 0755 "/etc/initramfs-tools/scripts/init-premount/dropbear"
      if [[ -z "${TARGET_HOST:-}" ]]; then
        die "TARGET_HOST is empty; cannot write initramfs dropbear override safely."
      fi
      sed -i "s/___PENELOPE_TARGET_HOST___/${TARGET_HOST}/g" "/etc/initramfs-tools/scripts/init-premount/dropbear"
      if grep -q "___PENELOPE_TARGET_HOST___" "/etc/initramfs-tools/scripts/init-premount/dropbear"; then
        die "initramfs dropbear override: ___PENELOPE_TARGET_HOST___ not replaced."
      fi
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-premount/dropbear" 0755

      log "initramfs: set hostname early (for DHCP/Dropbear)"
      mkdir -p /etc/initramfs-tools/scripts/init-top /etc/initramfs-tools/hooks

      # init-top: set kernel hostname before network scripts (so DHCP sees the name)
      cat > "/etc/initramfs-tools/scripts/init-top/00-${TARGET_HOST}-hostname" <<'EOF_INITTOP_HOSTNAME'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""

prereqs(){ echo "$PREREQ"; }

case "${1:-}" in
  prereqs) prereqs; exit 0;;
esac

BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>/dev/null || true
LOG_STAGE="$BASE/penelope-initramfs-stage.log"
touch "$LOG_STAGE" 2>/dev/null || true
exec 2>>"$LOG_STAGE"

# Goal: set the hostname already in initramfs so DHCP/logs stay consistent.
HN_FILE="/etc/hostname"
HN=""
if [ -r "$HN_FILE" ]; then
  IFS= read -r HN < "$HN_FILE" 2>/dev/null || HN=""
fi
[ -n "$HN" ] || HN="___PENELOPE_HOST___"

echo "$HN" > /proc/sys/kernel/hostname 2>/dev/null || true
if command -v hostname >/dev/null 2>&1; then
  hostname "$HN" 2>/dev/null || true
fi
EOF_INITTOP_HOSTNAME
      sed -i "s/___PENELOPE_HOST___/${TARGET_HOST}/g" "/etc/initramfs-tools/scripts/init-top/00-${TARGET_HOST}-hostname"
      chmod 0755 "/etc/initramfs-tools/scripts/init-top/00-${TARGET_HOST}-hostname"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-top/00-${TARGET_HOST}-hostname" 0755

      # hook: copy /etc/hostname into the initramfs
      cat > "/etc/initramfs-tools/hooks/${TARGET_HOST}-hostname" <<'EOF_HOOK_HOSTNAME'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e

PREREQ=""
prereqs(){ echo "$PREREQ"; }

case "${1:-}" in
  prereqs) prereqs; exit 0;;
esac

# Goal: ensure that /etc/hostname and our early hostname script land in the initrd.
. /usr/share/initramfs-tools/hook-functions

mkdir -p "${DESTDIR}/etc" "${DESTDIR}/scripts/init-top"
cp -a /etc/hostname "${DESTDIR}/etc/hostname"
cp -a "/etc/initramfs-tools/scripts/init-top/00-___PENELOPE_HOST___-hostname" "${DESTDIR}/scripts/init-top/00-___PENELOPE_HOST___-hostname"
EOF_HOOK_HOSTNAME

      # Replace placeholder in the hook
      sed -i "s/___PENELOPE_HOST___/${TARGET_HOST}/g" "/etc/initramfs-tools/hooks/${TARGET_HOST}-hostname"
      chmod 0755 "/etc/initramfs-tools/hooks/${TARGET_HOST}-hostname"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/${TARGET_HOST}-hostname" 0755

      log "initramfs: copy tools for diagnostics into initramfs (ip/ethtool, best-effort)"
      mkdir -p /etc/initramfs-tools/hooks
      cat > "/etc/initramfs-tools/hooks/penelope-tools" <<'EOF_HOOK_PENELOPE_TOOLS'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""
prereqs(){ echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# iproute2 (ip) and ethtool are very helpful for diagnostics in initramfs
[ -x /usr/sbin/ip ] && copy_exec /usr/sbin/ip /sbin || true
[ -x /usr/sbin/ethtool ] && copy_exec /usr/sbin/ethtool /sbin || true
# ping (gateway reachability check)
[ -x /bin/ping ] && copy_exec /bin/ping /bin || true
[ -x /usr/bin/ping ] && copy_exec /usr/bin/ping /bin || true
# arping (for router visibility / gratuitous ARP after DHCP)
# Place into /bin so it's on PATH in initramfs across distros.
[ -x /usr/bin/arping ] && copy_exec /usr/bin/arping /bin || true
[ -x /bin/arping ] && copy_exec /bin/arping /bin || true
[ -x /usr/sbin/arping ] && copy_exec /usr/sbin/arping /bin || true
[ -x /sbin/arping ] && copy_exec /sbin/arping /bin || true
# cryptroot-unlock is usually provided by cryptsetup-initramfs; copy explicitly for robustness
[ -x /usr/bin/cryptroot-unlock ] && copy_exec /usr/bin/cryptroot-unlock /bin || true
EOF_HOOK_PENELOPE_TOOLS
      chmod 0755 "/etc/initramfs-tools/hooks/penelope-tools"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/penelope-tools" 0755

      # Hook: copy wrapper into the initramfs (it then lives under /bin/.., matching dropbear.conf -c).
      cat > "/etc/initramfs-tools/hooks/penelope-cryptroot-unlock-wrapper" <<'EOF_HOOK_PENELOPE_UNLOCK_WRAPPER'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""
prereqs(){ echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

if [ -x /bin/penelope-cryptroot-unlock-wrapper ]; then
  copy_file file /bin/penelope-cryptroot-unlock-wrapper /bin/penelope-cryptroot-unlock-wrapper || true
fi
exit 0
EOF_HOOK_PENELOPE_UNLOCK_WRAPPER
      chmod 0755 "/etc/initramfs-tools/hooks/penelope-cryptroot-unlock-wrapper"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/penelope-cryptroot-unlock-wrapper" 0755

      # local-bottom: write the unlock method (SSH vs local) deterministically into the stage/unlock log.
      mkdir -p /etc/initramfs-tools/scripts/local-bottom
      cat > "/etc/initramfs-tools/scripts/local-bottom/99-penelope-unlock-method" <<'EOF_LOCALBOTTOM_UNLOCK_METHOD'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

STDERR_SINK="/proc/self/fd/2"
[ -c /dev/null ] && STDERR_SINK="/dev/null"

ts() { date +'%H:%M:%S' 2>"$STDERR_SINK" || echo "00:00:00"; }

BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>"$STDERR_SINK" || true

STAGE="$BASE/penelope-initramfs-stage.log"
LOG="$BASE/penelope-initramfs-unlock.log"
LOG_PUB="/run/penelope-initramfs-unlock.log"
touch "$STAGE" "$LOG" "$LOG_PUB" 2>"$STDERR_SINK" || true

append() {
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG" 2>"$STDERR_SINK" || true
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG_PUB" 2>"$STDERR_SINK" || true
  printf '%s %s\n' "$(ts)" "$*" >>"$STAGE" 2>"$STDERR_SINK" || true
}

method="local"
client_ip=""
client_port=""

if [ -r "$BASE/unlock.method" ]; then
  IFS= read -r method < "$BASE/unlock.method" 2>"$STDERR_SINK" || method="local"
fi

if [ "$method" = "ssh" ]; then
  _ssh_meta=""
  if [ -r "$BASE/ssh-unlock.event" ]; then
    _ssh_meta="$BASE/ssh-unlock.event"
  elif [ -r "$BASE/ssh-unlock.last" ]; then
    _ssh_meta="$BASE/ssh-unlock.last"
  fi
  if [ -n "${_ssh_meta:-}" ]; then
    # shellcheck source=/dev/null
    . "$_ssh_meta" 2>"$STDERR_SINK" || true
    client_ip="${event_client_ip:-${last_seen_client_ip:-${client_ip:-}}}"
    client_port="${event_client_port:-${last_seen_client_port:-${client_port:-}}}"
  fi
fi

append "UNLOCK: method=${method} client_ip=${client_ip:-<none>} client_port=${client_port:-<none>}"
# Ensure dropbear does not survive switch_root into the real system.
# This can happen on some initramfs setups when dropbear is started early
# and not stopped before pivot/switch_root.
kill_dropbear() {
  # TERM first (best effort)
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    c="$(cat "$p/comm" 2>"$STDERR_SINK" || true)"
    [ "$c" = "dropbear" ] || continue
    pid="${p#/proc/}"
    append "cleanup: stopping dropbear pid=${pid}"
    kill -TERM "$pid" 2>"$STDERR_SINK" || true
  done

  sleep 1 2>"$STDERR_SINK" || true

  # KILL remaining
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    c="$(cat "$p/comm" 2>"$STDERR_SINK" || true)"
    [ "$c" = "dropbear" ] || continue
    pid="${p#/proc/}"
    append "cleanup: killing dropbear pid=${pid}"
    kill -KILL "$pid" 2>"$STDERR_SINK" || true
  done
  return 0
}
kill_dropbear || true
exit 0
EOF_LOCALBOTTOM_UNLOCK_METHOD
      chmod 0755 "/etc/initramfs-tools/scripts/local-bottom/99-penelope-unlock-method"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/local-bottom/99-penelope-unlock-method" 0755

      log "initramfs: copy firmware files for network modules (fix for remote unlock)"
      mkdir -p /etc/initramfs-tools/hooks
      cat > "/etc/initramfs-tools/hooks/penelope-network-firmware" <<'EOF_HOOK_NETWORK_FIRMWARE'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
# Purpose: Copy network module firmware files into initramfs
# This ensures the network card can initialize properly during early boot (dropbear/SSH remote unlock)
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""
prereqs(){ echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# NET_MODULES should be set by the installer (e.g., "r8169")
NET_MODULES="___PENELOPE_NET_MODULES___"

if [ -z "$NET_MODULES" ]; then
  echo "WARNING: NET_MODULES not set, cannot copy network firmware" >&2
  exit 0
fi

# For each network module, find and copy required firmware
for module in $NET_MODULES; do
  # Find the module file in the target kernel
  module_file=""
  if [ -n "${version:-}" ]; then
    # initramfs-tools sets $version to the target kernel version
    module_file="$(find "/lib/modules/${version}" -name "${module}.ko*" 2>/dev/null | { IFS= read -r _mf || true; printf '%s' "${_mf}"; })" || true
  fi

  # If module file not found, try current kernel
  if [ -z "$module_file" ]; then
    module_file="$(find "/lib/modules/$(uname -r)" -name "${module}.ko*" 2>/dev/null | { IFS= read -r _mf || true; printf '%s' "${_mf}"; })" || true
  fi

  if [ -z "$module_file" ]; then
    echo "WARNING: Module file for $module not found, cannot determine firmware requirements" >&2
    continue
  fi

  # Extract firmware requirements using modinfo
  # modinfo -F firmware returns one firmware filename per line
  firmware_list="$(modinfo -F firmware "$module_file" 2>/dev/null)" || true

  if [ -z "$firmware_list" ]; then
    echo "INFO: Module $module has no firmware dependencies" >&2
    continue
  fi

  echo "INFO: Copying firmware for module $module" >&2

  # Copy each required firmware file
  # Keep logging compact but deterministic (counts + decompression notices).
  total=0
  copied=0
  decompressed=0
  missing=0

  for fw in $firmware_list; do
    [ -n "$fw" ] || continue
    total=$((total + 1))

    # Prefer initramfs-tools helper (handles distro-specific firmware layout/compression)
    if type manual_add_firmware >/dev/null 2>&1; then
      if manual_add_firmware "$fw" 2>/dev/null; then
        copied=$((copied + 1))
        continue
      fi
      echo "WARNING: manual_add_firmware failed: $fw (trying direct copy)" >&2
    fi

    # Check if firmware file exists (may be compressed)
    # Search both /usr/lib/firmware (Ubuntu 24.04 UsrMerge) and /lib/firmware (legacy/symlink)
    fw_path=""
    for base in "/lib/firmware" "/usr/lib/firmware"; do
      if [ -f "$base/$fw" ]; then
        fw_path="$base/$fw"
        break
      elif [ -f "$base/${fw}.zst" ]; then
        fw_path="$base/${fw}.zst"
        break
      elif [ -f "$base/${fw}.xz" ]; then
        fw_path="$base/${fw}.xz"
        break
      elif [ -f "$base/${fw}.gz" ]; then
        fw_path="$base/${fw}.gz"
        break
      fi
    done

    if [ -n "$fw_path" ]; then
      # copy_file is provided by hook-functions
      # Syntax: copy_file <type> <source> [<destination>]
      # Prefer initramfs-tools helper. If direct copy fails and the firmware is compressed,
      # decompress to the expected target path inside ${DESTDIR}.
      if copy_file firmware "$fw_path" >/dev/null 2>&1; then
        copied=$((copied + 1))
      else
        case "$fw_path" in
          *.zst)
            if type zstd >/dev/null 2>&1; then
              out_path="${DESTDIR}/usr/lib/firmware/${fw}"
              mkdir -p "$(dirname "$out_path")"
              if zstd -d -c "$fw_path" >"$out_path" 2>/dev/null; then
                decompressed=$((decompressed + 1))
                echo "INFO: Decompressed firmware into initramfs: ${fw} (from .zst)" >&2
              else
                echo "WARNING: Failed to decompress firmware (.zst): $fw_path" >&2
              fi
            else
              echo "WARNING: zstd missing; cannot decompress firmware: $fw_path" >&2
            fi
            ;;
          *.xz)
            if type xz >/dev/null 2>&1; then
              out_path="${DESTDIR}/usr/lib/firmware/${fw}"
              mkdir -p "$(dirname "$out_path")"
              if xz -d -c "$fw_path" >"$out_path" 2>/dev/null; then
                decompressed=$((decompressed + 1))
                echo "INFO: Decompressed firmware into initramfs: ${fw} (from .xz)" >&2
              else
                echo "WARNING: Failed to decompress firmware (.xz): $fw_path" >&2
              fi
            else
              echo "WARNING: xz missing; cannot decompress firmware: $fw_path" >&2
            fi
            ;;
          *.gz)
            if type gzip >/dev/null 2>&1; then
              out_path="${DESTDIR}/usr/lib/firmware/${fw}"
              mkdir -p "$(dirname "$out_path")"
              if gzip -d -c "$fw_path" >"$out_path" 2>/dev/null; then
                decompressed=$((decompressed + 1))
                echo "INFO: Decompressed firmware into initramfs: ${fw} (from .gz)" >&2
              else
                echo "WARNING: Failed to decompress firmware (.gz): $fw_path" >&2
              fi
            else
              echo "WARNING: gzip missing; cannot decompress firmware: $fw_path" >&2
            fi
            ;;
          *)
            echo "WARNING: Failed to copy firmware: $fw_path" >&2
            ;;
        esac
      fi
    else
      missing=$((missing + 1))
      echo "WARNING: Firmware file not found: $fw" >&2
    fi
  done

  echo "INFO: Firmware summary for ${module}: total=${total} copied=${copied} decompressed=${decompressed} missing=${missing}" >&2

done

exit 0
EOF_HOOK_NETWORK_FIRMWARE
      sed -i "s/___PENELOPE_NET_MODULES___/${NET_MODULES}/g" "/etc/initramfs-tools/hooks/penelope-network-firmware"
      chmod 0755 "/etc/initramfs-tools/hooks/penelope-network-firmware"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/penelope-network-firmware" 0755

            log "Create buildinfo for initramfs debug (copied into initrd)"
      install -d -m 0755 /etc/penelope
      BUILDINFO_TS="$(date -Iseconds 2>/dev/null || date 2>/dev/null || echo unknown)"
      {
        echo "# Version: ___PENELOPE_INSTALL_VERSION___"
        echo "timestamp=${BUILDINFO_TS}"
        echo "host=${TARGET_HOST}"
        echo "kernel=$(uname -r 2>/dev/null || true)"
        echo "dropbear_port=${DROPBEAR_PORT:-${DROPBEAR_PORT_DEFAULT:-}}"
        echo "dropbear_force_cmd=${DROPBEAR_FORCE_CMD:-}"
        echo "packages:"
        echo "  initramfs-tools=$(dpkg-query -W -f='${Version}' initramfs-tools 2>/dev/null || echo unknown)"
        echo "  dropbear-initramfs=$(dpkg-query -W -f='${Version}' dropbear-initramfs 2>/dev/null || echo unknown)"
        echo "  cryptsetup-initramfs=$(dpkg-query -W -f='${Version}' cryptsetup-initramfs 2>/dev/null || echo unknown)"
      } > /etc/penelope/buildinfo
      stamp_install_version /etc/penelope/buildinfo
      chmod 0644 /etc/penelope/buildinfo
      validate_generated_file /etc/penelope/buildinfo

      # Initramfs debug defaults (copied into initramfs /conf/..).
      # Controls DHCP/Dropbear retry/backoff in initramfs. Can be overridden per-boot with kernel cmdline penelope_debug_retry=1.
      cat > /etc/penelope/initramfs-debug.conf <<EOF_PENELOPE_INITRAMFS_DEBUG
INITRAMFS_DEBUG_RETRY=${INITRAMFS_DEBUG_RETRY:-0}
EOF_PENELOPE_INITRAMFS_DEBUG
      chmod 0644 /etc/penelope/initramfs-debug.conf
      validate_generated_file /etc/penelope/initramfs-debug.conf

      cat > "/etc/initramfs-tools/hooks/penelope-buildinfo" <<'EOF_HOOK_PENELOPE_BUILDINFO'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Include build info into initramfs for easier offline analysis.
if [ -r /etc/penelope/buildinfo ]; then
  copy_file file /etc/penelope/buildinfo /conf/penelope-buildinfo || true
fi

# Include initramfs build manifest (generated at install time) into initramfs.
if [ -r /etc/penelope/initramfs-manifest ]; then
  copy_file file /etc/penelope/initramfs-manifest /conf/penelope-initramfs-manifest || true
fi

# Include install-time NIC evidence into initramfs for correlation.
if [ -r /etc/penelope/netinfo-install.conf ]; then
  copy_file file /etc/penelope/netinfo-install.conf /conf/penelope-netinfo-install.conf || true
fi

# Include initramfs debug defaults (generated at install time) into initramfs.
if [ -r /etc/penelope/initramfs-debug.conf ]; then
  copy_file file /etc/penelope/initramfs-debug.conf /conf/penelope-initramfs-debug.conf || true
fi

exit 0
EOF_HOOK_PENELOPE_BUILDINFO
      chmod 0755 "/etc/initramfs-tools/hooks/penelope-buildinfo"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/penelope-buildinfo" 0755

log "Enabling initramfs debug logging (for analysis if SSH unlock is not reachable)"
      mkdir -p \
        /etc/initramfs-tools/scripts/init-top \
        /etc/initramfs-tools/scripts/init-premount \
        /etc/initramfs-tools/scripts/init-bottom

      cat > "/etc/initramfs-tools/scripts/init-top/10-${TARGET_HOST}-diag" <<'EOF_INITTOP_DIAG'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

HN="unknown"
if [ -r /etc/hostname ]; then
  IFS= read -r HN < /etc/hostname || true
fi
[ -n "${HN}" ] || HN="unknown"
BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>/dev/null || true
LOG="$BASE/${HN}-initramfs-diag.log"
STABLE="$BASE/penelope-initramfs-diag.log"
STAGE="$BASE/penelope-initramfs-stage.log"
: >"$STABLE" 2>/dev/null || true
: >"$STAGE" 2>/dev/null || true

# Capture stderr to stable diag log (so boot errors survive post-boot)
exec 2>>"$STABLE"

INSTALL_VERSION="___PENELOPE_INSTALL_VERSION___"
COMMON_VERSION="___PENELOPE_COMMON_VERSION___"

BOOT_ID_FILE="$BASE/boot.id"
BOOT_TS_FILE="$BASE/boot.ts"
BOOT_ID=""
BOOT_TS=""

boot_meta_init() {
  if [ -r "$BOOT_ID_FILE" ]; then IFS= read -r BOOT_ID < "$BOOT_ID_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/sys/kernel/random/uuid ]; then IFS= read -r BOOT_ID < /proc/sys/kernel/random/uuid 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && command -v date >/dev/null 2>&1; then BOOT_ID="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u _r < /proc/uptime 2>/dev/null || _u=""; [ -n "$_u" ] && BOOT_ID="uptime:${_u}"; fi
  [ -n "${BOOT_ID:-}" ] || BOOT_ID="unknown"
  printf '%s\n' "$BOOT_ID" >"$BOOT_ID_FILE" 2>/dev/null || true

  if [ -r "$BOOT_TS_FILE" ]; then IFS= read -r BOOT_TS < "$BOOT_TS_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_TS:-}" ] && command -v date >/dev/null 2>&1; then BOOT_TS="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_TS:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u2 _r2 < /proc/uptime 2>/dev/null || _u2=""; [ -n "$_u2" ] && BOOT_TS="uptime:${_u2}"; fi
  [ -n "${BOOT_TS:-}" ] || BOOT_TS="unknown"
  printf '%s\n' "$BOOT_TS" >"$BOOT_TS_FILE" 2>/dev/null || true
}

ensure_log_header() {
  _f="$1"
  [ -n "$_f" ] || return 0
  touch "$_f" 2>/dev/null || true
  _first=""
  if [ -r "$_f" ]; then IFS= read -r _first < "$_f" 2>/dev/null || _first=""; fi
  if [ "$_first" != "PENELOPE_INITRAMFS_LOG_BEGIN" ]; then
    _tmp="${_f}.tmp.$$"
    {
      echo "PENELOPE_INITRAMFS_LOG_BEGIN"
      echo "install_version=${INSTALL_VERSION}"
      echo "common_version=${COMMON_VERSION}"
      echo "host=${HN}"
      echo "boot_id=${BOOT_ID}"
      echo "ts=${BOOT_TS}"
      echo "PENELOPE_INITRAMFS_LOG_END"
      cat "$_f" 2>/dev/null || true
    } >"$_tmp" 2>/dev/null || true
    cat "$_tmp" >"$_f" 2>/dev/null || true
    rm -f "$_tmp" 2>/dev/null || true
  fi
}

boot_meta_init
# Ensure headers are always present even if later scripts append only
touch "$LOG" 2>/dev/null || true
ensure_log_header "$LOG"
ensure_log_header "$STABLE"
ensure_log_header "$STAGE"

stage() {
  # Stage timeline for fast correlation across scripts.
  echo "[$(ts)] STAGE: $*" >>"$STAGE" 2>/dev/null || true
}

stage "init-top: start"

have() { command -v "$1" >/dev/null 2>&1; }

{
  echo "=== initramfs diag: init-top ==="
  if have date; then date -Iseconds 2>/dev/null || date 2>/dev/null || true; fi
  echo "cmdline: $(cat /proc/cmdline 2>/dev/null || true)"
  echo "hostname file: ${HN}"
  echo "kernel hostname: $(cat /proc/sys/kernel/hostname 2>/dev/null || true)"
  echo

  echo "## command inventory (initramfs)"
  for c in sh busybox cat dmesg grep sed awk ip ipconfig dropbear cryptroot-unlock udhcpc arping ps ss netstat ifconfig route uname date; do
    if have "$c"; then
      echo "OK: $c -> $(command -v "$c" 2>/dev/null || echo ok)"
    else
      echo "MISSING: $c"
    fi
  done
  echo

  echo "## selftest: arping availability (initramfs)"
  if have arping; then
    echo "SELFTEST: arping=present path=$(command -v arping 2>/dev/null || echo ok)"
  else
    echo "SELFTEST: arping=missing"
  fi
  echo

echo "## busybox applets (initramfs)"
if have busybox; then
  busybox --list 2>/dev/null | while IFS= read -r applet; do
    [ -n "$applet" ] || continue
    echo "busybox_applet: $applet"
  done
else
  echo "MISSING: busybox"
fi
echo

  echo "## kernel cmdline ip= check (DHCP hostname should match /etc/hostname)"
  CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
  IPTOK=""
  for w in $CMDLINE; do
    case "$w" in
      ip=*) IPTOK="${w#ip=}"; break ;;
    esac
  done
  if [ -n "${IPTOK}" ]; then
    case "$IPTOK" in
      *"::${HN}::"*) echo "OK: ip= contains hostname '${HN}': ip=${IPTOK}" ;;
      *) warn "ip= does NOT contain hostname '${HN}': ip=${IPTOK}" ;;
    esac
  else
    echo "INFO: no ip= parameter present"
  fi
  echo

  echo "## /conf/initramfs.conf"
  cat /conf/initramfs.conf 2>/dev/null || true
  echo

  echo "## penelope buildinfo (/conf/penelope-buildinfo)"
  cat /conf/penelope-buildinfo 2>/dev/null || echo "(missing)"
  echo

  echo "## penelope initramfs build manifest (/conf/penelope-initramfs-manifest)"
  cat /conf/penelope-initramfs-manifest 2>/dev/null || echo "(missing)"
  echo

  echo "## net devices (/sys/class/net)"
  if have ls; then
    ls -l /sys/class/net 2>/dev/null || true
  else
    for p in /sys/class/net/*; do echo "${p}"; done
  fi
  echo

  echo "## dropbear (initramfs) inventory"
  if have ls; then ls -al /etc/dropbear 2>/dev/null || true; fi
  echo

  echo "## modules (first 80)"
  if [ -r /proc/modules ]; then
    if have head; then
      cat /proc/modules 2>/dev/null | head -n 80 || true
    else
      cat /proc/modules 2>/dev/null || true
    fi
  fi
  echo

  echo "## dmesg (tail 160)"
  if have dmesg; then
    if have tail; then
      dmesg 2>/dev/null | tail -n 160 || true
    else
      dmesg 2>/dev/null || true
    fi
  fi
  echo
} >>"$LOG" 2>/dev/null || true

# Ensure stable filename for easier retrieval
cp -f "$LOG" "$STABLE" 2>/dev/null || true
stage "init-top: done"

EOF_INITTOP_DIAG
      chmod 0755 "/etc/initramfs-tools/scripts/init-top/10-${TARGET_HOST}-diag"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-top/10-${TARGET_HOST}-diag" 0755

      # Brings LAN up reliably already in initramfs (before Dropbear), including carrier wait, DHCP, and the "DEVICE=" fix.
      cat > "/etc/initramfs-tools/scripts/init-premount/05-penelope-netup" <<'EOF_INITPREMOUNT_NETUP'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

set -eu

BASE="/run/initramfs/penelope"
PUB="/run"
mkdir -p "$BASE" "$PUB" 2>/dev/null || true

LOG_MAIN="$BASE/penelope-initramfs-diag.log"
LOG_NETUP="$BASE/penelope-initramfs-netup.log"
LOG_STAGE="$BASE/penelope-initramfs-stage.log"

# Public/stable names (so a plain 'find / -name penelope*log' finds them)
LOG_MAIN_PUB="$PUB/penelope-initramfs-diag.log"
LOG_NETUP_PUB="$PUB/penelope-initramfs-netup.log"
LOG_STAGE_PUB="$PUB/penelope-initramfs-stage.log"

NET_STATE="$BASE/net.state"
NET_STATE_PUB="$PUB/penelope-initramfs-net.state"

touch "$LOG_MAIN" "$LOG_NETUP" "$LOG_STAGE" "$LOG_MAIN_PUB" "$LOG_NETUP_PUB" "$LOG_STAGE_PUB" "$NET_STATE" "$NET_STATE_PUB" 2>/dev/null || true

# Capture stderr to netup log (remote-first: keep console clean and preserve evidence)
exec 2>>"$LOG_NETUP"

INSTALL_VERSION="___PENELOPE_INSTALL_VERSION___"
COMMON_VERSION="___PENELOPE_COMMON_VERSION___"

HN="unknown"
if [ -r /etc/hostname ]; then IFS= read -r HN < /etc/hostname 2>/dev/null || true; fi
[ -n "${HN}" ] || HN="unknown"

BOOT_ID_FILE="$BASE/boot.id"
BOOT_TS_FILE="$BASE/boot.ts"
BOOT_ID=""
BOOT_TS=""

boot_meta_init() {
  if [ -r "$BOOT_ID_FILE" ]; then IFS= read -r BOOT_ID < "$BOOT_ID_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/sys/kernel/random/uuid ]; then IFS= read -r BOOT_ID < /proc/sys/kernel/random/uuid 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && command -v date >/dev/null 2>&1; then BOOT_ID="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u _r < /proc/uptime 2>/dev/null || _u=""; [ -n "$_u" ] && BOOT_ID="uptime:${_u}"; fi
  [ -n "${BOOT_ID:-}" ] || BOOT_ID="unknown"
  printf '%s\n' "$BOOT_ID" >"$BOOT_ID_FILE" 2>/dev/null || true

  if [ -r "$BOOT_TS_FILE" ]; then IFS= read -r BOOT_TS < "$BOOT_TS_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_TS:-}" ] && command -v date >/dev/null 2>&1; then BOOT_TS="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_TS:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u2 _r2 < /proc/uptime 2>/dev/null || _u2=""; [ -n "$_u2" ] && BOOT_TS="uptime:${_u2}"; fi
  [ -n "${BOOT_TS:-}" ] || BOOT_TS="unknown"
  printf '%s\n' "$BOOT_TS" >"$BOOT_TS_FILE" 2>/dev/null || true
}

ensure_log_header() {
  _f="$1"
  [ -n "$_f" ] || return 0
  touch "$_f" 2>/dev/null || true
  _first=""
  if [ -r "$_f" ]; then IFS= read -r _first < "$_f" 2>/dev/null || _first=""; fi
  if [ "$_first" != "PENELOPE_INITRAMFS_LOG_BEGIN" ]; then
    _tmp="${_f}.tmp.$$"
    {
      echo "PENELOPE_INITRAMFS_LOG_BEGIN"
      echo "install_version=${INSTALL_VERSION}"
      echo "common_version=${COMMON_VERSION}"
      echo "host=${HN}"
      echo "boot_id=${BOOT_ID}"
      echo "ts=${BOOT_TS}"
      echo "PENELOPE_INITRAMFS_LOG_END"
      cat "$_f" 2>/dev/null || true
    } >"$_tmp" 2>/dev/null || true
    cat "$_tmp" >"$_f" 2>/dev/null || true
    rm -f "$_tmp" 2>/dev/null || true
  fi
}

boot_meta_init
ensure_log_header "$LOG_STAGE"
ensure_log_header "$LOG_STAGE_PUB"
ensure_log_header "$LOG_MAIN"
ensure_log_header "$LOG_MAIN_PUB"
ensure_log_header "$LOG_NETUP"
ensure_log_header "$LOG_NETUP_PUB"

# DHCP/router identity evidence (best-effort). Filled by dhcp_identity().
ID_DHCP_HOSTNAME=""
ID_IP_PARAM=""
ID_IP_HOSTNAME_FIELD=""
ID_IP_DEVICE_FIELD=""
ID_DHCP_CLIENTID_KIND=""
ID_DHCP_CLIENTID=""

stage() {
  echo "[$(ts)] STAGE: $*" >>"$LOG_STAGE" 2>/dev/null || true
  echo "[$(ts)] STAGE: $*" >>"$LOG_STAGE_PUB" 2>/dev/null || true
}
have() { command -v "$1" >/dev/null 2>&1; }

indent_lines() {
  # Prefix every incoming line with three spaces (no sed dependency).
  while IFS= read -r _l || [ -n "${_l:-}" ]; do
    echo "   ${_l:-}"
  done
}

cmdline_has_word() {
  # Usage: cmdline_has_word "key=value"
  _w="${1:-}"
  [ -n "${_w}" ] || return 1
  [ -r /proc/cmdline ] || return 1
  _cmdline_words="$(cat /proc/cmdline 2>/dev/null || true)"
  for _x in ${_cmdline_words}; do
    [ "${_x}" = "${_w}" ] && return 0
  done
  return 1
}

iface_has_ipv4() {
  # true if interface has at least one IPv4 address.
  [ -n "$(ip -4 -o addr show dev "$1" 2>/dev/null || true)" ]
}

param_conf_set() {
  # Ensure KEY=VALUE exists in /conf/param.conf (pure sh, no grep/sed).
  _k="${1:?key}"
  _v="${2:-}"
  _f="/conf/param.conf"
  _t="/conf/param.conf.tmp.$$"
  _found=0

  if [ -r "${_f}" ]; then
    while IFS= read -r _line || [ -n "${_line:-}" ]; do
      case "${_line}" in
        "${_k}="*)
          echo "${_k}=${_v}" >>"${_t}"
          _found=1
          ;;
        *)
          echo "${_line}" >>"${_t}"
          ;;
      esac
    done <"${_f}"
  fi

  if [ "${_found}" -eq 0 ]; then
    echo "${_k}=${_v}" >>"${_t}"
  fi

  mv "${_t}" "${_f}" 2>/dev/null || true
}

append() {
  # Unified network log + main diag log (also write to public/stable names)
  echo "[$(ts)] $*" >>"$LOG_NETUP" 2>/dev/null || true
  echo "[$(ts)] $*" >>"$LOG_NETUP_PUB" 2>/dev/null || true
  echo "[$(ts)] $*" >>"$LOG_MAIN" 2>/dev/null || true
  echo "[$(ts)] $*" >>"$LOG_MAIN_PUB" 2>/dev/null || true
}

is_wireless() { [ -d "/sys/class/net/$1/wireless" ]; }
read_sys() { cat "$1" 2>/dev/null || true; }

iface_driver() {
  # prints driver name or empty
  if [ -L "/sys/class/net/$1/device/driver" ] && have readlink; then
    p="$(readlink "/sys/class/net/$1/device/driver" 2>/dev/null || true)"; echo "${p##*/}"
  else
    echo ""
  fi
}

iface_module() {
  if [ -L "/sys/class/net/$1/device/driver/module" ] && have readlink; then
    p="$(readlink "/sys/class/net/$1/device/driver/module" 2>/dev/null || true)"; echo "${p##*/}"
  else
    echo ""
  fi
}

dump_iface() {
  [ "$1" = "lo" ] && return 0
  is_wireless "$1" && return 0
  mac="$(read_sys "/sys/class/net/$1/address")"
  oper="$(read_sys "/sys/class/net/$1/operstate")"
  car="$(read_sys "/sys/class/net/$1/carrier")"
  ifidx="$(read_sys "/sys/class/net/$1/ifindex")"
  drv="$(iface_driver "$1")"
  mod="$(iface_module "$1")"
  devpath=""
  if [ -L "/sys/class/net/$1/device" ] && have readlink; then
    devpath="$(readlink "/sys/class/net/$1/device" 2>/dev/null || true)"
  fi
  append "iface=$1 mac=${mac:-?} operstate=${oper:-?} carrier=${car:-?} ifindex=${ifidx:-?} driver=${drv:-?} module=${mod:-?} devpath=${devpath:-?}"
}

dump_ifaces() {
  append "interface inventory (sysfs):"
  for p in /sys/class/net/*; do
    dump_iface "${p##*/}" || true
  done
}

# DHCP identity / router visibility helpers
# Goal: make it explicit *which* hostname/client identity we are likely to send in DHCP, and on which MAC/IFACE.
# This does not change behaviour; it only logs and provides evidence for troubleshooting.
dhcp_identity() {
  _if="${1:-}"
  _mac=""
  [ -n "$_if" ] && _mac="$(read_sys "/sys/class/net/$_if/address")"

  _khn=""
  if [ -r /proc/sys/kernel/hostname ]; then _khn="$(cat /proc/sys/kernel/hostname 2>/dev/null || true)"; fi
  if [ -z "$_khn" ] && have hostname; then _khn="$(hostname 2>/dev/null || true)"; fi
  _etchn="$(cat /etc/hostname 2>/dev/null || true)"

  _cmd="$(cat /proc/cmdline 2>/dev/null || true)"
  _ipparam=""
  _iphn=""
  _ipdev=""
  for w in $_cmd; do
    case "$w" in
      ip=*) _ipparam="${w#ip=}"; break ;;
    esac
  done
  if [ -n "$_ipparam" ]; then
    # ip=client-ip:server-ip:gw-ip:netmask:hostname:device:autoconf:<OMITTED>
    oldifs="$IFS"
    IFS=':'
    read -r _ipf1 _ipf2 _ipf3 _ipf4 _iphn _ipdev _iprest <<EOF_IP_PARAM
$_ipparam
EOF_IP_PARAM
    IFS="$oldifs"
  fi

  # Choose a practical DHCP hostname candidate for router visibility.
  _dhcp_hn="${_iphn:-}"
  [ -n "$_dhcp_hn" ] || _dhcp_hn="${_etchn:-}"
  [ -n "$_dhcp_hn" ] || _dhcp_hn="${_khn:-}"

  # Extract a best-effort client identity hint (dhcpcd only). This is not guaranteed
  # to reflect the actual on-wire client-id, but it is useful for correlation.
  _cid_kind=""
  _cid_val=""
  if [ -r /etc/dhcpcd.conf ] && have grep; then
    _line="$(grep -E '^(clientid|duid)\b' /etc/dhcpcd.conf 2>/dev/null | { IFS= read -r _l || true; printf '%s\n' "${_l:-}"; } || true)"
    if [ -n "$_line" ]; then
      # Example: "clientid 01:aa:bb:cc:dd:ee:ff" or "duid <OMITTED>"
      set -- $_line
      _cid_kind="${1:-}"
      _cid_val="${2:-}"
    fi
  fi

  # Export identity evidence for net.state (single source of truth).
  ID_DHCP_HOSTNAME="${_dhcp_hn:-}"
  ID_IP_PARAM="${_ipparam:-}"
  ID_IP_HOSTNAME_FIELD="${_iphn:-}"
  ID_IP_DEVICE_FIELD="${_ipdev:-}"
  ID_DHCP_CLIENTID_KIND="${_cid_kind:-}"
  ID_DHCP_CLIENTID="${_cid_val:-}"

  append "dhcp_identity: iface=${_if:-?} mac=${_mac:-?}" \
    "expected_mac=${mac:-<none>} dhcp_hostname=${_dhcp_hn:-<none>}" \
    "dhcp_clientid_kind=${_cid_kind:-<none>} dhcp_clientid=${_cid_val:-<none>}" \
    "kernel_hostname=${_khn:-<none>} etc_hostname=${_etchn:-<none>}" \
    "ip_param=${_ipparam:-<none>} ip_hostname_field=${_iphn:-<none>}" \
    "ip_device_field=${_ipdev:-<none>}"

  # Also show which DHCP client binaries are present (dropbear-initramfs may choose its own).
  _tools=""
  have ipconfig && _tools="${_tools} ipconfig"
  have udhcpc && _tools="${_tools} udhcpc"
  have dhcpcd && _tools="${_tools} dhcpcd"
  append "dhcp_identity: dhcp_tools_present:${_tools:- <none>}"

  # dhcpcd identity hints (if present).
  if [ -r /etc/dhcpcd.conf ] && have grep; then
    append "dhcp_identity: /etc/dhcpcd.conf identity lines (filtered)"
    grep -E '^(hostname|clientid|duid|option[[:space:]]+host_name)\b' /etc/dhcpcd.conf 2>/dev/null | indent_lines >>"$LOG_NETUP" 2>/dev/null || true
    grep -E '^(hostname|clientid|duid|option[[:space:]]+host_name)\b' /etc/dhcpcd.conf 2>/dev/null | indent_lines >>"$LOG_NETUP_PUB" 2>/dev/null || true
  fi
}

# Log how the selected DHCP implementation is expected to receive hostname/client identity.
# This is purely diagnostic and does not change behaviour.
log_dropbear_dhcp_impl() {
  _s="${1:-}"
  [ -r "$_s" ] || { append "dropbear_dhcp_impl: skipped(script not readable: ${_s:-<none>})"; return 0; }

  if have grep; then
    append "dropbear_dhcp_impl: hints from ${_s} (dhcpcd/udhcpc/ipconfig/dhclient/hostname/clientid)"
    # Keep the output compact and evidence-oriented.
    grep -nE '(dhcpcd|udhcpc|ipconfig|dhclient|host_name|hostname|clientid|duid)' "$_s" 2>/dev/null \
      | { i=0; while IFS= read -r _l; do printf '%s\n' "$_l"; i=$((i+1)); [ "$i" -ge 80 ] && break; done; } \
      | indent_lines >>"$LOG_NETUP" 2>/dev/null || true
    grep -nE '(dhcpcd|udhcpc|ipconfig|dhclient|host_name|hostname|clientid|duid)' "$_s" 2>/dev/null \
      | { i=0; while IFS= read -r _l; do printf '%s\n' "$_l"; i=$((i+1)); [ "$i" -ge 80 ] && break; done; } \
      | indent_lines >>"$LOG_NETUP_PUB" 2>/dev/null || true
  else
    append "dropbear_dhcp_impl: skipped(no grep)"
  fi
}

log_ipconfig_handoff() {
  # ipconfig (klibc) reads hostname/device from kernel cmdline 'ip=<FIELDS>:hostname:device:<FIELDS>'.
  if [ -n "${ID_IP_DEVICE_FIELD:-}" ] && [ "${ID_IP_DEVICE_FIELD:-}" != "<none>" ] && [ "${ID_IP_DEVICE_FIELD:-}" != "" ] && [ "${ID_IP_DEVICE_FIELD:-}" != "${1:-}" ]; then
    append "dhcp_handoff: WARN ip= device field '${ID_IP_DEVICE_FIELD}' != selected iface '${1:-<none>}'"
  fi
  append "dhcp_handoff: client=ipconfig" \
    "hostname_from_ip_field5='${ID_IP_HOSTNAME_FIELD:-<none>}'" \
    "candidate_hostname='${ID_DHCP_HOSTNAME:-<none>}' ip_param='${ID_IP_PARAM:-<none>}'"
}

log_dhcpcd_handoff() {
  # dhcpcd derives hostname from /etc/hostname unless overridden in /etc/dhcpcd.conf.
  append "dhcp_handoff: client=dhcpcd hostname_candidate='${ID_DHCP_HOSTNAME:-<none>}'" \
    "(sources: ip_field5='${ID_IP_HOSTNAME_FIELD:-<none>}' /etc/hostname / kernel hostname);" \
    "clientid_hint='${ID_DHCP_CLIENTID_KIND:-<none>} ${ID_DHCP_CLIENTID:-<none>}'"
}

choose_iface() {
  if [ -n "${iface:-}" ] && [ -d "/sys/class/net/$iface" ] && [ "$iface" != "lo" ] && ! is_wireless "$iface"; then
    echo "$iface"; return 0
  fi

  if [ -n "${mac:-}" ]; then
    for d in /sys/class/net/*; do
      n="$(basename "$d")"
      [ "$n" = "lo" ] && continue
      is_wireless "$n" && continue
      a="$(cat "$d/address" 2>/dev/null || true)"
      [ "$a" = "$mac" ] && { echo "$n"; return 0; }
    done
  fi

  for d in /sys/class/net/*; do
    n="$(basename "$d")"
    [ "$n" = "lo" ] && continue
    is_wireless "$n" && continue
    c="$(cat "$d/carrier" 2>/dev/null || echo 0)"
    [ "$c" = "1" ] && { echo "$n"; return 0; }
  done

  for d in /sys/class/net/*; do
    n="$(basename "$d")"
    [ "$n" = "lo" ] && continue
    is_wireless "$n" && continue
    echo "$n"; return 0
  done
  return 1
}

CONF="/conf/conf.d/penelope-netselect.conf"
if [ -r "$CONF" ]; then
  # shellcheck source=/dev/null
  . "$CONF"
fi

iface="${PENELOPE_ETH_IFACE:-}"
mac="${PENELOPE_ETH_MAC:-}"
mod="${PENELOPE_NET_MODULE:-}"
link_wait="${PENELOPE_LINK_WAIT:-60}"
dhcp_timeout="${PENELOPE_DHCP_TIMEOUT:-60}"

stage "init-premount: netup start (iface=${iface:-<none>} mac=${mac:-<none>} mod=${mod:-<none>})"
append "Start. conf: iface='${iface:-}' mac='${mac:-}' mod='${mod:-}' link_wait=${link_wait} dhcp_timeout=${dhcp_timeout}"

dump_ifaces

# Pre dmesg snapshot (helps to catch rename/driver/firmware issues early)
if have dmesg && have tail; then
  append "dmesg tail (pre-netup, last 80)"
  dmesg 2>/dev/null | tail -n 80 >>"$LOG_NETUP" 2>/dev/null || true
fi

if [ -n "${mod:-}" ] && have modprobe; then
  append "modprobe: $mod"
  for m in $mod; do
    if modprobe -q "$m" >>"$LOG_NETUP" 2>&1; then
      append "modprobe ok: $m"
    else
      warn "modprobe '$m' failed"
      append "modprobe failed: $m"
    fi
  done
fi

sel="$(choose_iface 2>/dev/null || true)"
if [ -z "$sel" ]; then
  warn "no suitable LAN interface found (lo/wlan excluded)"
  append "FAIL: no suitable LAN interface found"
  stage "init-premount: netup fail (no iface)"
  exit 0
fi

append "Selected IFACE='$sel' (mac=$(read_sys "/sys/class/net/${sel}/address"))"
stage "init-premount: netup selected iface=$sel"

# Log DHCP identity and router-visibility-relevant metadata for the selected interface.
dhcp_identity "$sel"

if have ip; then
  ip link set dev "$sel" up >>"$LOG_NETUP" 2>&1 || { warn "ip link up failed"; append "WARN: ip link up failed"; }
else
  warn "'ip' not available"
  append "WARN: 'ip' not available"
fi

append "carrier_wait: iface=$sel max=${link_wait}s"
i=0
while [ "$i" -lt "$link_wait" ]; do
  c="$(read_sys "/sys/class/net/$sel/carrier")"
  [ -n "$c" ] || c="0"
  append "carrier_wait: t=${i}s carrier=${c}"
  [ "$c" = "1" ] && break
  sleep 1
  i=$((i + 1))
done
c="$(read_sys "/sys/class/net/$sel/carrier")"
[ -n "$c" ] || c="0"
append "carrier_final: iface=$sel carrier=$c after=${i}s operstate=$(read_sys "/sys/class/net/${sel}/operstate")"
stage "init-premount: netup carrier=$c after=${i}s"

# Link settle delay: some NIC/PHYs report carrier up before autoneg is fully stable.
# A short settle sleep reduces DHCP/dropbear race conditions.
if [ "$c" = "1" ]; then
  settle_sec="3"
  append "link_settle: seconds=${settle_sec} (after carrier up)"
  stage "init-premount: netup link_settle=${settle_sec}s"
  sleep "$settle_sec" 2>/dev/null || true
fi

# DHCP: IMPORTANT: dropbear-initramfs also does networking (ipconfig/dhcpcd).
# Running two DHCP clients in initramfs can lead to conflicting leases / address churn and make router visibility flaky.
# Therefore: if dropbear init-premount script exists, we only bring link up + set DEVICE/IP and defer DHCP to dropbear.
attempt_used="none"

DROPBEAR_SCRIPT="/scripts/init-premount/dropbear"
if [ -x "$DROPBEAR_SCRIPT" ]; then
  append "dhcp: skipped in netup (deferred to dropbear-initramfs: ${DROPBEAR_SCRIPT})"
  log_dhcpcd_handoff
  log_dropbear_dhcp_impl "$DROPBEAR_SCRIPT"
  append "dhcp_handoff: deferred-to-dropbear hostname_candidate='${ID_DHCP_HOSTNAME:-<none>}'"
  attempt_used="deferred"
  stage "init-premount: netup dhcp=deferred-to-dropbear"
  append "dhcp_final: ipv4_present=deferred attempt_used=${attempt_used}"
else
  # DHCP: raw output + exit code + resulting IP/route/neigh
  if have ipconfig; then
    log_ipconfig_handoff "$sel"
    # DHCP timing: use /proc/uptime when available (deterministic, no wallclock required)
    _u0=""
    if [ -r /proc/uptime ]; then
      _u0="$( { IFS= read -r _l || true; printf '%s' "${_l%% *}"; } < /proc/uptime 2>/dev/null || true)"
    fi

    append "dhcp: begin (ipconfig -t ${dhcp_timeout} ${sel})"
    echo "=== DHCP BEGIN: ipconfig -t ${dhcp_timeout} ${sel} ===" >>"$LOG_NETUP" 2>/dev/null || true
    if ipconfig -t "$dhcp_timeout" "$sel" >>"$LOG_NETUP" 2>&1; then
      rc=0
    else
      rc=$?
      warn "ipconfig dhcp failed (rc=$rc)"
    fi
    echo "=== DHCP END rc=${rc} ===" >>"$LOG_NETUP" 2>/dev/null || true

    _u1=""
    _dt=""
    if [ -r /proc/uptime ]; then
      _u1="$( { IFS= read -r _l2 || true; printf '%s' "${_l2%% *}"; } < /proc/uptime 2>/dev/null || true)"
      if [ -n "${_u0:-}" ] && [ -n "${_u1:-}" ] && have awk; then
        _dt="$(awk -v a="$_u0" -v b="$_u1" 'BEGIN{printf "%.3f", (b-a)}' 2>/dev/null || true)"
      fi
    fi
    append "dhcp: end rc=${rc} t=${_dt:-?}s uptime0=${_u0:-?} uptime1=${_u1:-?}"

    # Best-effort result line: show IP and default gateway on the selected interface.
    _ip4=""
    _gw4=""
    if have ip; then
      _ip4="$(
        ip -4 -o addr show dev "$sel" 2>/dev/null |
          { IFS= read -r _x || true; printf '%s' "${_x##* }"; } |
          { IFS=/ read -r _a _b || true; printf '%s' "${_a:-}"; } 2>/dev/null || true
      )"
      _gw4="$(
        ip -4 route show default 2>/dev/null |
          { IFS= read -r _r || true; set -- $_r; printf '%s' "${3:-}"; } 2>/dev/null || true
      )"
    fi
    append "dhcp_result: iface=${sel} ip4=${_ip4:-<none>} gw4=${_gw4:-<none>}"

    # Best-effort neighbor/ARP snapshot (helps correlate router UI 'inactive' vs actual L2 presence).
    if have ip; then
      # Best-effort: Neighbor snapshot is for diagnostics only. Never fail boot on this.
      _neigh="$(
        ip neigh show dev "$sel" 2>/dev/null | {
          n=0
          out=""
          while IFS= read -r line; do
            n=$((n + 1))
            out="${out}${line};"
            [ "$n" -ge 3 ] && break
          done
          out="${out%;}"
          printf '%s' "$out"
        } || true
      )"
      append "neigh_snapshot: iface=${sel} lines<=3 ${_neigh:-<empty>}"
    fi


    # Give the kernel a moment to apply the address (race observed on some systems)
    if have ip; then
      j=0
      while [ "$j" -lt 5 ]; do
        iface_has_ipv4 "$sel" && break
        sleep 1
        j=$((j + 1))
      done
    fi

    ipv4_present="unknown"
    attempt_used="1"
    if have ip; then
      if iface_has_ipv4 "$sel"; then
        ipv4_present="yes"
        stage "init-premount: netup dhcp=ok"
      else
        ipv4_present="no"
        stage "init-premount: netup dhcp=no-ipv4"
      fi
      append "dhcp_attempt: attempt=1 rc=${rc} ipv4_present=${ipv4_present}"
    else
      ipv4_present="unknown(no ip)"
      stage "init-premount: netup dhcp=unknown(no-ip)"
      append "dhcp_attempt: attempt=1 rc=${rc} ipv4_present=${ipv4_present}"
    fi

    # Optional debug retry/backoff (diagnostic aid): enable with kernel cmdline 'penelope_debug_retry=1'
    debug_retry="0"
    # Enable via kernel cmdline: penelope_debug_retry=1
    if cmdline_has_word 'penelope_debug_retry=1'; then
      debug_retry="1"
    fi
    # Or enable via install-time defaults copied into initramfs: /conf/penelope-initramfs-debug.conf
    if [ "$debug_retry" != "1" ] && [ -r /conf/penelope-initramfs-debug.conf ]; then
      # shellcheck source=/dev/null
      . /conf/penelope-initramfs-debug.conf 2>/dev/null || true
      if [ "${INITRAMFS_DEBUG_RETRY:-0}" = "1" ]; then
        debug_retry="1"
      fi
    fi
    append "debug_retry=${debug_retry} (dhcp)"

    # Exactly one retry (attempt=2) in debug mode if no IPv4 was acquired.
    if [ "$debug_retry" = "1" ] && [ "${ipv4_present}" != "yes" ] && have ip; then
      attempt_used="2"
      backoff="2"
      append "dhcp_retry: attempt=2 backoff=${backoff}s"
      stage "init-premount: netup dhcp_retry attempt=2"
      sleep "$backoff" 2>/dev/null || true
      echo "=== DHCP RETRY BEGIN (attempt=2): ipconfig -t ${dhcp_timeout} ${sel} ===" >>"$LOG_NETUP" 2>/dev/null || true
      rc2=0
      if ipconfig -t "$dhcp_timeout" "$sel" >>"$LOG_NETUP" 2>&1; then
        rc2=0
      else
        rc2=$?
        warn "ipconfig dhcp retry failed (attempt=2, rc=$rc2)"
      fi
      echo "=== DHCP RETRY END attempt=2 rc=${rc2} ===" >>"$LOG_NETUP" 2>/dev/null || true
      append "dhcp_retry: end attempt=2 rc=${rc2}"
      if iface_has_ipv4 "$sel"; then
        ipv4_present="yes"
        append "dhcp_attempt: attempt=2 rc=${rc2} ipv4_present=yes"
        stage "init-premount: netup dhcp=ok (attempt=2)"
      else
        ipv4_present="no"
        append "dhcp_attempt: attempt=2 rc=${rc2} ipv4_present=no"
        stage "init-premount: netup dhcp=no-ipv4 (attempt=2)"
      fi
    fi

    append "dhcp_final: ipv4_present=${ipv4_present} attempt_used=${attempt_used}"
  else
    warn "ipconfig not available"
    append "WARN: ipconfig not available"
    stage "init-premount: netup dhcp=skipped(no-ipconfig)"
  fi
fi

# Ensure /conf/param.conf exists (some initramfs builds create it only later)
touch /conf/param.conf 2>/dev/null || true
if [ -w /conf/param.conf ]; then
  param_conf_set "DEVICE" "${sel}"
  # Maintain the standard IP=dhcp marker if missing.
  param_conf_set "IP" "dhcp"
fi

# Post-DHCP network state snapshot (router visibility debugging)
if have ip; then
  append "ip addr show dev ${sel}"
  ip addr show "$sel" >>"$LOG_NETUP" 2>&1 || true
  append "ip route"
  ip route show >>"$LOG_NETUP" 2>&1 || true
  append "ip neigh show dev ${sel}"
  if ip neigh show dev "$sel" >/dev/null 2>&1; then
    ip neigh show dev "$sel" >>"$LOG_NETUP" 2>&1 || true
  else
    append "ip neigh: unsupported in this initramfs ip implementation"
  fi
fi
if [ -r /proc/net/arp ]; then
  append "/proc/net/arp (first 30)"
  {
    i=0
    while IFS= read -r _l; do
      printf '%s\n' "$_l"
      i=$((i + 1))
      [ "$i" -ge 30 ] && break
    done < /proc/net/arp 2>/dev/null || true
  } >>"$LOG_NETUP" 2>/dev/null || true
fi

# Gateway reachability check (router ping) - best-effort diagnostics.
# Note: ICMP may be blocked by the router/firewall; in that case ping can fail even though DHCP worked.
gw=""
# Prefer parsing the default route via 'ip' (best-effort, avoid awk dependency).
if have ip; then
  def="$(ip route show default 2>/dev/null | { IFS= read -r _l || true; printf '%s\n' "${_l:-}"; } || true)"
  if [ -n "$def" ]; then
    prev=""
    for t in $def; do
      if [ "$prev" = "via" ]; then
        gw="$t"
        break
      fi
      prev="$t"
    done
  fi
fi
# Fallback: /proc/net/route (no awk): parse default gateway in pure POSIX sh.
hex_le_to_ipv4() {
  h="$1"
  [ -n "$h" ] || return 0
  [ ${#h} -eq 8 ] || return 0
  b4="${h%??????}"
  r="${h#??}"
  b3="${r%????}"
  r2="${r#??}"
  b2="${r2%??}"
  b1="${r2#??}"
  printf '%s.%s.%s.%s\n' "$((16#${b1}))" "$((16#${b2}))" "$((16#${b3}))" "$((16#${b4}))"
}

if [ -z "$gw" ] && [ -r /proc/net/route ]; then
  while IFS= read -r _ln; do
    case "$_ln" in
      Iface*Destination*) continue ;;
    esac
    set -- $_ln
    _if="${1:-}"
    _dest="${2:-}"
    _gwhex="${3:-}"
    if [ "$_if" = "$sel" ] && [ "$_dest" = "00000000" ] && [ "$_gwhex" != "00000000" ]; then
      gw="$(hex_le_to_ipv4 "$_gwhex" 2>/dev/null || true)"
      [ -n "$gw" ] && break
    fi
  done < /proc/net/route 2>/dev/null || true
fi

# Normalized ping result for net.state: ok|fail|skipped
gw_ping_res="skipped"

if [ -n "$gw" ]; then
  append "gw_detected: iface=${sel} gw=${gw}"
  if have ping; then
    # Try -W (iputils), fall back to -w (busybox). Keep it simple and deterministic.
    if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then
      gw_ping_res="ok"
      append "gw_ping: gw=${gw} rc=0 result=ok"
    else
      ping_rc=$?
      if ping -c 1 -w 1 "$gw" >/dev/null 2>&1; then
        gw_ping_res="ok"
        append "gw_ping: gw=${gw} rc=0 result=ok"
      else
        ping_rc=$?
        gw_ping_res="fail"
        append "gw_ping: gw=${gw} rc=${ping_rc} result=fail (ICMP blocked or L2/route issue)"
      fi
    fi
  else
    gw_ping_res="skipped"
    append "gw_ping: skipped(no ping in initramfs)"
  fi
else
  gw_ping_res="skipped"
  append "gw_ping: skipped(no default gateway)"
fi

# dmesg focused extract (driver/link/firmware/rename)
if have dmesg && have grep; then
  append "dmesg filtered (r8169/rtl/firmware/link/renamed)"
  dmesg 2>/dev/null | grep -Ei 'r8169|rtl|firmware|link (is )?(up|down)|renamed from|enp|eth' >>"$LOG_NETUP" 2>/dev/null || true
fi

# Best-effort IPv4 extraction for human/operator visibility (router may not show the lease fast enough).
# Avoid 'ip -o' and awk dependencies: parse "ip addr show" output with shell tokenization.
ipv4_addr="none"
if [ -n "${sel:-}" ]; then
  # Prefer /run/net-<iface>.conf written by ipconfig/ipconfig-static.
  ipv4_addr=""
  if [ -r "/run/net-${sel}.conf" ]; then
    while IFS= read -r _l; do
      case "$_l" in
        IPV4ADDR=*) ipv4_addr="${_l#IPV4ADDR=}" ;;
      esac
    done < "/run/net-${sel}.conf" 2>/dev/null || true
  fi

  # Fallback: parse 'ip addr show dev <iface>' without grep/head.
  if [ -z "${ipv4_addr:-}" ] && have ip; then
    ipv4_line="$(ip addr show dev "$sel" 2>/dev/null | { while IFS= read -r _l; do case "$_l" in *' inet '*) printf '%s\n' "$_l"; break ;; esac; done; } || true)"
    if [ -n "$ipv4_line" ]; then
      set -- $ipv4_line
      if [ "${1:-}" = "inet" ] && [ -n "${2:-}" ]; then
        ipv4_addr="${2%%/*}"
      fi
    fi
  fi

  # Fallback: some environments expose 'src <ip>' in route output.
  if [ -z "${ipv4_addr:-}" ] && have ip; then
    src_line="$(ip route show dev "$sel" 2>/dev/null | { while IFS= read -r _l; do case "$_l" in *' src '*) printf '%s\n' "$_l"; break ;; esac; done; } || true)"
    if [ -n "$src_line" ]; then
      prev=""
      for t in $src_line; do
        if [ "$prev" = "src" ]; then
          ipv4_addr="$t"
          break
        fi
        prev="$t"
      done
    fi
  fi

  [ -n "${ipv4_addr:-}" ] || ipv4_addr="none"

  # If DHCP is deferred to dropbear, we cannot know the IPv4 yet. Use a stable marker instead of "none".
  if [ "${attempt_used:-}" = "deferred" ] && [ "${ipv4_addr:-none}" = "none" ]; then
    ipv4_addr="deferred"
  fi
fi
append "ipv4_final: iface=${sel:-?} ipv4=${ipv4_addr}"
stage "init-premount: netup ipv4=${ipv4_addr}"

# Write a single source of truth network state file for later stage summary (init-bottom).
# Key=value format, best-effort. Used for quick triage without fragile parsing.
upt="?"
if [ -r /proc/uptime ]; then
  _upt_first=""
  _upt_rest=""
  read -r _upt_first _upt_rest < /proc/uptime 2>/dev/null || true
  upt="${_upt_first:-?}"
fi
mac_addr="$(read_sys "/sys/class/net/${sel}/address")"
krel=""
if [ -r /proc/sys/kernel/osrelease ]; then IFS= read -r krel < /proc/sys/kernel/osrelease 2>/dev/null || true; fi
drv_now="$(iface_driver "${sel}")"
mod_now="$(iface_module "${sel}")"
devpath_now=""
if [ -L "/sys/class/net/${sel}/device" ] && have readlink; then
  devpath_now="$(readlink "/sys/class/net/${sel}/device" 2>/dev/null || true)"
fi

# Optional: install-time NIC evidence copied into initramfs.
install_iface=""
install_driver=""
install_live_kver=""
install_target_kver=""
if [ -r /conf/penelope-netinfo-install.conf ]; then
  while IFS= read -r _l || [ -n "${_l:-}" ]; do
    case "$_l" in
      install_iface=*) install_iface="${_l#install_iface=}" ;;
      install_driver=*) install_driver="${_l#install_driver=}" ;;
      live_kernel_release=*) install_live_kver="${_l#live_kernel_release=}" ;;
      target_kernel_candidate=*) install_target_kver="${_l#target_kernel_candidate=}" ;;
    esac
  done < /conf/penelope-netinfo-install.conf 2>/dev/null || true
fi
if [ -z "${install_target_kver:-}" ] && [ -n "${krel:-}" ]; then
  install_target_kver="$krel"
fi

stage "netinfo: krel=${krel:-?} iface=${sel:-?} driver=${drv_now:-?}" \
  "module=${mod_now:-?} devpath=${devpath_now:-?}" \
  "installer_iface=${install_iface:-?} installer_driver=${install_driver:-?}" \
  "installer_live_kver=${install_live_kver:-?}" \
  "installer_target_kver=${install_target_kver:-?}"

{
  echo "penelope_install_version=${INSTALL_VERSION}"
  echo "penelope_common_version=${COMMON_VERSION}"
  echo "boot_id=${BOOT_ID}"
  echo "boot_ts=${BOOT_TS}"
  echo "kernel_release=${krel:-}"
  echo "iface=${sel:-}"
  echo "iface_driver=${drv_now:-}"
  echo "iface_module=${mod_now:-}"
  echo "iface_devpath=${devpath_now:-}"
  echo "mac=${mac_addr:-}"
  echo "expected_mac=${mac:-}"
  echo "installer_iface=${install_iface:-}"
  echo "installer_driver=${install_driver:-}"
  echo "installer_live_kernel_release=${install_live_kver:-}"
  echo "installer_target_kernel_candidate=${install_target_kver:-}"
  echo "dhcp_hostname=${ID_DHCP_HOSTNAME:-}"
  echo "dhcp_clientid_kind=${ID_DHCP_CLIENTID_KIND:-}"
  echo "dhcp_clientid=${ID_DHCP_CLIENTID:-}"
  echo "ip_cmdline=${ID_IP_PARAM:-}"
  echo "ip_hostname_field=${ID_IP_HOSTNAME_FIELD:-}"
  echo "ip_device_field=${ID_IP_DEVICE_FIELD:-}"
  echo "carrier=${c:-}"
  echo "dhcp_attempt_used=${attempt_used:-}"
  echo "ipv4=${ipv4_addr:-}"
  echo "gw=${gw:-}"
  echo "gw_ping=${gw_ping_res:-}"
  echo "ts_uptime=${upt}"
} >"$NET_STATE" 2>/dev/null || true
cp -f "$NET_STATE" "$NET_STATE_PUB" 2>/dev/null || true

# Also print a one-liner to the local console so the operator can see the SSH target without router UI.
if [ "${ipv4_addr}" != "none" ] && [ "${ipv4_addr}" != "deferred" ] && [ -w /dev/console ]; then
  host="___PENELOPE_HOST___"
  port="___PENELOPE_DROPBEAR_PORT___"
  if [ -r /conf/penelope-buildinfo ]; then
    h=""
    p=""
    while IFS= read -r _l; do
      case "$_l" in
        host=*) h="${_l#host=}" ;;
        dropbear_port=*) p="${_l#dropbear_port=}" ;;
      esac
    done < /conf/penelope-buildinfo 2>/dev/null || true
    [ -n "$h" ] && host="$h"
    [ -n "$p" ] && port="$p"
  fi
  hint_line="${host} initramfs: iface=${sel:-?} mac=${mac_addr:-?} carrier=${c:-?}"
  hint_line="${hint_line} dhcp_attempt_used=${attempt_used:-?} ip=${ipv4_addr}"
  hint_line="${hint_line} gw=${gw:-?} gw_ping=${gw_ping_res:-?}"
  hint_line="${hint_line} ssh: ssh -p ${port} root@${ipv4_addr}"
  echo "$hint_line" > /dev/console 2>/dev/null || true
  echo "[$(ts)] CONSOLE_HINT: $hint_line" >>"$LOG_STAGE" 2>/dev/null || true
  echo "[$(ts)] CONSOLE_HINT: $hint_line" >>"$LOG_STAGE_PUB" 2>/dev/null || true
fi

append "Done."
# Keepalive correlation (dropbear override may have started it after DHCP)
_kpid=""
if [ -r "$BASE/keepalive.pid" ]; then
  _kpid="$(cat "$BASE/keepalive.pid" 2>/dev/null || true)"
fi
case "${_kpid:-}" in
  ''|*[!0-9]*) _kpid="" ;;
esac
if [ -n "$_kpid" ] && kill -0 "$_kpid" 2>/dev/null; then
  append "netup: keepalive_pid=${_kpid} status=running"
else
  append "netup: keepalive_pid=${_kpid:-<none>} status=not_running"
fi

# Local self-check: does initramfs have arping?
if command -v arping >/dev/null 2>&1; then
  append "netup: arping=present path=$(command -v arping)"
else
  append "netup: arping=missing"
fi
stage "init-premount: netup done"
exit 0
EOF_INITPREMOUNT_NETUP
      chmod 0755 "/etc/initramfs-tools/scripts/init-premount/05-penelope-netup"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-premount/05-penelope-netup" 0755

      cat > "/etc/initramfs-tools/scripts/init-premount/50-${TARGET_HOST}-netdiag" <<'EOF_INITPREMOUNT_NETDIAG'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

HN="unknown"
if [ -r /etc/hostname ]; then
  IFS= read -r HN < /etc/hostname || true
fi
[ -n "${HN}" ] || HN="unknown"
BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>/dev/null || true
LOG="$BASE/${HN}-initramfs-diag.log"
STABLE="$BASE/penelope-initramfs-diag.log"
DROP_LOG="$BASE/penelope-initramfs-dropbear.log"
STAGE="$BASE/penelope-initramfs-stage.log"
touch "$STABLE" "$DROP_LOG" "$STAGE" 2>/dev/null || true

# Capture stderr to stable diag log (init-premount stage)
exec 2>>"$STABLE"

stage() { echo "[$(ts)] STAGE: $*" >>"$STAGE" 2>/dev/null || true; }
drop_append() { echo "$*" >>"$DROP_LOG" 2>/dev/null || true; }

stage "init-premount: netdiag start"

have() { command -v "$1" >/dev/null 2>&1; }

indent_lines() {
  while IFS= read -r _l || [ -n "${_l:-}" ]; do
    echo "   ${_l:-}"
  done
}

{
  echo "=== initramfs diag: init-premount ==="
  if have date; then date -Iseconds 2>/dev/null || date 2>/dev/null || true; fi
  echo

  echo "## ipconfig status"
  if have ipconfig; then ipconfig -s 2>/dev/null || true; else echo "ipconfig not available"; fi
  echo

  echo "## ip addr / route (if available)"
  if have ip; then
    ip -br link 2>/dev/null || true
    ip -br addr 2>/dev/null || true
    ip route 2>/dev/null || true
  elif have ifconfig; then
    ifconfig -a 2>/dev/null || true
    if have route; then route -n 2>/dev/null || true; fi
  else
    echo "neither ip nor ifconfig available"
  fi
  echo

  echo "## net devices + drivers (sysfs)"
  for p in /sys/class/net/*; do
    iface="${p##*/}"
    [ "$iface" = "lo" ] && continue
    echo "iface=${iface}"
    if [ -e "/sys/class/net/${iface}/address" ]; then
      echo "  mac=$(cat /sys/class/net/${iface}/address 2>/dev/null || true)"
    fi
    if [ -L "/sys/class/net/${iface}/device/driver" ]; then
      drv="$(readlink /sys/class/net/${iface}/device/driver 2>/dev/null || true)"
      echo "  driver=${drv##*/}"
    else
      echo "  driver=(none)"
    fi
    if [ -L "/sys/class/net/${iface}/device/driver/module" ]; then
      mp="$(readlink /sys/class/net/${iface}/device/driver/module 2>/dev/null || true)"
      echo "  module=${mp##*/}"
    else
      echo "  module=(none)"
    fi
  done
  echo

  echo "## NIC module check (loaded vs present in initramfs)"
  KREL="$(uname -r 2>/dev/null || true)"
  MODDEP="/lib/modules/${KREL}/modules.dep"
  for p in /sys/class/net/*; do
    iface="${p##*/}"
    [ "$iface" = "lo" ] && continue

    MOD=""
    if [ -L "/sys/class/net/${iface}/device/driver/module" ]; then
      mp="$(readlink /sys/class/net/${iface}/device/driver/module 2>/dev/null || true)"
      MOD="${mp##*/}"
    fi

    if [ -z "$MOD" ]; then
      echo "${iface}: module=(none) loaded=? in-initramfs=?"
      continue
    fi

    LOADED="?"
    if [ -r /proc/modules ] && have grep; then
      if grep -q "^${MOD} " /proc/modules 2>/dev/null; then LOADED="yes"; else LOADED="no"; fi
    fi

    PRESENT="?"
    if [ -f "$MODDEP" ] && have grep; then
      if grep -q "/${MOD}\.ko" "$MODDEP" 2>/dev/null; then PRESENT="yes"; else PRESENT="no"; fi
    fi

    echo "${iface}: module=${MOD} loaded=${LOADED} in-initramfs=${PRESENT}"
  done
  echo

  echo "## dmesg anomalies (firmware/error/timeout)"
  if have dmesg; then
    if have grep; then
      if have tail; then
        dmesg 2>/dev/null |
          grep -iE 'firmware|microcode|failed|error|timeout|timed out|no such device|unknown symbol|r8169|rtl|link (is )?(up|down)|renamed from|enp|eth' |
          tail -n 140 || true
      else
        dmesg 2>/dev/null |
          grep -iE 'firmware|microcode|failed|error|timeout|timed out|no such device|unknown symbol|r8169|rtl|link (is )?(up|down)|renamed from|enp|eth' || true
      fi
    else
      if have tail; then dmesg 2>/dev/null | tail -n 200 || true; else dmesg 2>/dev/null || true; fi
    fi
  fi
  echo

echo
echo "=== dhcp fallback (only if no global IPv4 present) ==="
HAS_GLOBAL_IPV4="0"
if have ip; then
  # If no global IPv4 exists, output is empty.
  if ip -4 addr show scope global 2>/dev/null | { IFS= read -r _l || true; [ -n "${_l:-}" ]; }; then
    HAS_GLOBAL_IPV4="1"
  fi
fi

if [ "${HAS_GLOBAL_IPV4}" != "1" ]; then
  echo "No global IPv4 detected. Trying ipconfig DHCP fallback: ipconfig DHCP"
  if have ipconfig; then
    # Try all non-lo interfaces; ipconfig will pick usable links
    ipconfig -t 10 -c dhcp 2>&1 || true
  else
    echo "ipconfig not available in initramfs."
  fi
  if have ip; then
    ip addr show 2>/dev/null || true
    ip route 2>/dev/null || true
  fi
else
  echo "Global IPv4 already present; skipping."
fi

echo
echo "=== listeners / dropbear ==="
# Extract Dropbear port from config (best effort)
PORT="___PENELOPE_DROPBEAR_PORT___"
for cf in /etc/dropbear/dropbear.conf /etc/dropbear-initramfs/dropbear.conf /etc/dropbear/initramfs/dropbear.conf; do
  [ -r "$cf" ] || continue

  opt=""
  while IFS= read -r _l; do
    case "$_l" in
      DROPBEAR_OPTIONS=*)
        opt="${_l#DROPBEAR_OPTIONS=}"
        opt="${opt%\"}"
        opt="${opt#\"}"
        ;;
    esac
  done < "$cf" 2>/dev/null || true

  if [ -n "$opt" ]; then
    # Parse "-p <PORT>" and "-p<PORT>" forms
    set -- $opt
    prev=""
    for tok in "$@"; do
      if [ "$prev" = "-p" ]; then
        PORT="$tok"
        break
      fi
      case "$tok" in
        -p[0-9]*)
          PORT="${tok#-p}"
          break
          ;;
      esac
      prev="$tok"
    done
  fi
  break
done
echo "expected dropbear port: ${PORT}"

if have ps; then
  if have grep; then
    ps w 2>/dev/null | grep -E '[d]ropbear' || true
  else
    ps w 2>/dev/null || true
  fi
fi
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -lntp 2>/dev/null || true
else
  echo "no ss/netstat; using /proc/net/tcp"
  if [ -r /proc/net/tcp ]; then
    echo "tcp LISTEN sockets (first 40):"
    if have awk; then
      awk '$4=="0A"{print $2 " inode=" $10}' /proc/net/tcp 2>/dev/null | { i=0; while IFS= read -r _l; do printf '%s
' "$_l"; i=$((i+1)); [ "$i" -ge 40 ] && break; done; } 2>/dev/null || true
    else
      { i=0; while IFS= read -r _l; do printf '%s
' "$_l"; i=$((i+1)); [ "$i" -ge 40 ] && break; done; } < /proc/net/tcp 2>/dev/null || true
    fi
  fi
  if [ -r /proc/net/tcp6 ]; then
    echo "tcp6 LISTEN sockets (first 40):"
    if have awk; then
      awk '$4=="0A"{print $2 " inode=" $10}' /proc/net/tcp 2>/dev/null | { i=0; while IFS= read -r _l; do printf '%s
' "$_l"; i=$((i+1)); [ "$i" -ge 40 ] && break; done; } 2>/dev/null || true
    else
      { i=0; while IFS= read -r _l; do printf '%s
' "$_l"; i=$((i+1)); [ "$i" -ge 40 ] && break; done; } < /proc/net/tcp 2>/dev/null || true
    fi
  fi
fi
} >>"$LOG" 2>/dev/null || true

# Ensure stable filename for easier retrieval
cp -f "$LOG" "$STABLE" 2>/dev/null || true
EOF_INITPREMOUNT_NETDIAG
      chmod 0755 "/etc/initramfs-tools/scripts/init-premount/50-${TARGET_HOST}-netdiag"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-premount/50-${TARGET_HOST}-netdiag" 0755

      cat > "/etc/initramfs-tools/scripts/init-premount/60-penelope-dropbear-precheck" <<'EOF_INITPREMOUNT_DROPBEAR_PRECHECK'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

BASE="/run/initramfs/penelope"
PUB="/run"
mkdir -p "$BASE" "$PUB" 2>/dev/null || true

LOG_MAIN="$BASE/penelope-initramfs-diag.log"
LOG_DROP="$BASE/penelope-initramfs-dropbear.log"

# Public/stable names (helps retrieval both in initramfs and post-boot)
LOG_MAIN_PUB="$PUB/penelope-initramfs-diag.log"
LOG_DROP_PUB="$PUB/penelope-initramfs-dropbear.log"
touch "$LOG_MAIN" "$LOG_DROP" "$LOG_MAIN_PUB" "$LOG_DROP_PUB" 2>/dev/null || true

# Capture stderr to dropbear log (precheck phase)
exec 2>>"$LOG_DROP"

INSTALL_VERSION="___PENELOPE_INSTALL_VERSION___"
COMMON_VERSION="___PENELOPE_COMMON_VERSION___"

HN="unknown"
if [ -r /etc/hostname ]; then IFS= read -r HN < /etc/hostname 2>/dev/null || true; fi
[ -n "${HN}" ] || HN="unknown"

BOOT_ID_FILE="$BASE/boot.id"
BOOT_TS_FILE="$BASE/boot.ts"
BOOT_ID=""
BOOT_TS=""

boot_meta_init() {
  if [ -r "$BOOT_ID_FILE" ]; then IFS= read -r BOOT_ID < "$BOOT_ID_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/sys/kernel/random/uuid ]; then IFS= read -r BOOT_ID < /proc/sys/kernel/random/uuid 2>/dev/null || true; fi
  if [ -z "${BOOT_ID:-}" ] && command -v date >/dev/null 2>&1; then BOOT_ID="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_ID:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u _r < /proc/uptime 2>/dev/null || _u=""; [ -n "$_u" ] && BOOT_ID="uptime:${_u}"; fi
  [ -n "${BOOT_ID:-}" ] || BOOT_ID="unknown"
  printf "%s\n" "$BOOT_ID" >"$BOOT_ID_FILE" 2>/dev/null || true

  if [ -r "$BOOT_TS_FILE" ]; then IFS= read -r BOOT_TS < "$BOOT_TS_FILE" 2>/dev/null || true; fi
  if [ -z "${BOOT_TS:-}" ] && command -v date >/dev/null 2>&1; then BOOT_TS="$(date +%s 2>/dev/null || true)"; fi
  if [ -z "${BOOT_TS:-}" ] && [ -r /proc/uptime ]; then IFS=. read -r _u2 _r2 < /proc/uptime 2>/dev/null || _u2=""; [ -n "$_u2" ] && BOOT_TS="uptime:${_u2}"; fi
  [ -n "${BOOT_TS:-}" ] || BOOT_TS="unknown"
  printf "%s\n" "$BOOT_TS" >"$BOOT_TS_FILE" 2>/dev/null || true
}

ensure_log_header() {
  _f="$1"
  [ -n "$_f" ] || return 0
  touch "$_f" 2>/dev/null || true
  _first=""
  if [ -r "$_f" ]; then IFS= read -r _first < "$_f" 2>/dev/null || _first=""; fi
  if [ "$_first" != "PENELOPE_INITRAMFS_LOG_BEGIN" ]; then
    _tmp="${_f}.tmp.$$"
    {
      echo "PENELOPE_INITRAMFS_LOG_BEGIN"
      echo "install_version=${INSTALL_VERSION}"
      echo "common_version=${COMMON_VERSION}"
      echo "host=${HN}"
      echo "boot_id=${BOOT_ID}"
      echo "ts=${BOOT_TS}"
      echo "PENELOPE_INITRAMFS_LOG_END"
      cat "$_f" 2>/dev/null || true
    } >"$_tmp" 2>/dev/null || true
    cat "$_tmp" >"$_f" 2>/dev/null || true
    rm -f "$_tmp" 2>/dev/null || true
  fi
}

boot_meta_init
ensure_log_header "$LOG_MAIN"
ensure_log_header "$LOG_MAIN_PUB"
ensure_log_header "$LOG_DROP"
ensure_log_header "$LOG_DROP_PUB"

append_drop() {
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG_DROP" 2>/dev/null || true
  printf '%s %s\n' "$(ts)" "$*" >>"$LOG_DROP_PUB" 2>/dev/null || true
}

# Find dropbear.conf and read DROPBEAR_OPTIONS robustly (best-effort).
CONF=""
for cf in /etc/dropbear/dropbear.conf /etc/dropbear-initramfs/dropbear.conf /etc/dropbear/initramfs/dropbear.conf; do
  [ -r "$cf" ] || continue
  CONF="$cf"
  break
done

DROPBEAR_OPTIONS=""
if [ -n "${CONF}" ]; then
  # Read in subshell to avoid side effects.
  DROPBEAR_OPTIONS="$(
    (
      # shellcheck source=/dev/null
      . "$CONF" 2>/dev/null || true
      printf '%s' "${DROPBEAR_OPTIONS:-}"
    ) 2>/dev/null || true
  )"
fi

PORT="___PENELOPE_DROPBEAR_PORT___"
FORCE_CMD=""

strip_quotes() {
  v="$1"
  v="${v#\"}"
  v="${v%\"}"
  v="${v#\'}"
  v="${v%\'}"
  printf '%s' "$v"
}

if [ -n "${DROPBEAR_OPTIONS}" ]; then
  # Parse options via shell tokenization (avoid external parsing fragility).
  # Note: if DROPBEAR_OPTIONS contains literal quotes, strip_quotes() removes surrounding ones.
  set -- $DROPBEAR_OPTIONS
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p)
        shift
        [ "$#" -gt 0 ] && PORT="$1"
        ;;
      -p*)
        PORT="${1#-p}"
        ;;
      -c)
        shift
        [ "$#" -gt 0 ] && FORCE_CMD="$(strip_quotes "$1")"
        ;;
      -c*)
        FORCE_CMD="$(strip_quotes "${1#-c}")"
        ;;
    esac
    shift || break
  done
fi

append_drop "=== dropbear precheck (before /scripts/init-premount/dropbear) ==="
append_drop "conf=${CONF:-<none>}"
append_drop "DROPBEAR_OPTIONS=${DROPBEAR_OPTIONS:-<none>}"
append_drop "port=${PORT} force_cmd=${FORCE_CMD:-<none>}"

# Fingerprint the initramfs dropbear script (runtime path). This helps correlate DHCP behaviour with the exact script revision.
append_drop "dropbear_script: path=/scripts/init-premount/dropbear"
if [ -x /scripts/init-premount/dropbear ]; then
  if have ls; then
    _ls_line="$(ls -l /scripts/init-premount/dropbear 2>/dev/null || true)"
    append_drop "dropbear_script_ls: ${_ls_line:-<none>}"
  else
    append_drop "dropbear_script_ls: skipped(no ls)"
  fi

  if have sha256sum; then
    _sha_line="$(sha256sum /scripts/init-premount/dropbear 2>/dev/null || true)"
    _sha="${_sha_line%% *}"
    [ -n "${_sha}" ] || _sha="<none>"
    append_drop "dropbear_script_sha256: ${_sha}"
  else
    append_drop "dropbear_script_sha256: skipped(no sha256sum)"
  fi

  append_drop "dropbear_script_head:"
  _i=0
  while IFS= read -r _line; do
    _i=$((_i + 1))
    append_drop "  ${_i}: ${_line}"
    [ "${_i}" -ge 12 ] && break
  done < /scripts/init-premount/dropbear 2>/dev/null || true
else
  append_drop "WARNING: /scripts/init-premount/dropbear not found/executable"
fi

# DHCP identity snapshot (helps correlate router MAC/hostname visibility with initramfs behaviour).
_if=""
if [ -r /conf/param.conf ]; then
  while IFS= read -r _l; do
    case "$_l" in
      DEVICE=*)
        _if="${_l#DEVICE=}"
        ;;
    esac
  done < /conf/param.conf 2>/dev/null || true
fi

if [ -z "${_if}" ]; then
  for _p in /sys/class/net/*; do
    _b="${_p##*/}"
    [ "$_b" = "lo" ] && continue
    _if="$_b"
    break
  done
fi

_mac=""
[ -n "$_if" ] && _mac="$(cat /sys/class/net/$_if/address 2>/dev/null || true)"
_khn="$(cat /proc/sys/kernel/hostname 2>/dev/null || true)"
_etchn="$(cat /etc/hostname 2>/dev/null || true)"
_cmd="$(cat /proc/cmdline 2>/dev/null || true)"

_ipparam=""
for _arg in $_cmd; do
  case "$_arg" in
    ip=*)
      _ipparam="${_arg#ip=}"
      break
      ;;
  esac
done

_iphn=""
_ipdev=""
if [ -n "$_ipparam" ]; then
  IFS=':' read -r _a _b _c _d _iphn _ipdev _rest <<EOF_DROPBEAR_PRECHECK_IP_PARAM
${_ipparam}
EOF_DROPBEAR_PRECHECK_IP_PARAM
fi

append_drop "dhcp_identity: iface=${_if:-?} mac=${_mac:-?}" \
  "kernel_hostname=${_khn:-<none>} etc_hostname=${_etchn:-<none>}" \
  "ip_param=${_ipparam:-<none>} ip_hostname_field=${_iphn:-<none>}" \
  "ip_device_field=${_ipdev:-<none>}"

# authorized_keys inventory (paths + sizes; do NOT print content)
append_drop "authorized_keys candidates (ls -l, best-effort):"
for f in \
  /etc/dropbear/authorized_keys \
  /etc/dropbear-initramfs/authorized_keys \
  /etc/dropbear/initramfs/authorized_keys \
  /root/.ssh/authorized_keys \
  /root-*/.ssh/authorized_keys \
; do
  [ -e "$f" ] || continue
  if command -v ls >/dev/null 2>&1; then
    ls -l "$f" 2>/dev/null | indent_lines >>"$LOG_DROP" 2>/dev/null || true
    ls -l "$f" 2>/dev/null | indent_lines >>"$LOG_DROP_PUB" 2>/dev/null || true
  else
    append_drop "   present: $f"
  fi
done

# authorized_keys locations (do NOT print content)
AK=""
for ak in \
  /etc/dropbear/authorized_keys \
  /etc/dropbear-initramfs/authorized_keys \
  /etc/dropbear/initramfs/authorized_keys \
  /root/.ssh/authorized_keys \
  /root-*/.ssh/authorized_keys \
; do
  [ -r "$ak" ] || continue
  AK="$ak"
  break
done

if [ -n "$AK" ]; then
  if [ -s "$AK" ]; then
    append_drop "authorized_keys: ${AK} (size=$(wc -c <"$AK" 2>/dev/null || echo ?))"
    if have sha256sum; then
      _sha_line="$(sha256sum "$AK" 2>/dev/null || true)"
      _sha="${_sha_line%% *}"
      [ -n "${_sha}" ] || _sha="<none>"
      append_drop "authorized_keys sha256: ${_sha}"
    fi
  else
    append_drop "WARNING: authorized_keys exists but is empty: ${AK}"
  fi
else
  append_drop "WARNING: authorized_keys not found in expected initramfs locations"
fi

# forced command presence
if [ -n "${FORCE_CMD}" ]; then
  if [ -x "$FORCE_CMD" ]; then
    append_drop "OK: forced command exists and is executable: $FORCE_CMD"
  else
    append_drop "WARNING: forced command not executable/missing: $FORCE_CMD"
    if have ls; then
      ls -l "$FORCE_CMD" 2>/dev/null | indent_lines >>"$LOG_DROP" 2>/dev/null || true
    fi
  fi
else
  append_drop "WARNING: no -c (forced command) found in DROPBEAR_OPTIONS"
fi

# listener/proc checks (informational; dropbear not expected to be running yet)
LISTENING="unknown"
append_drop "listener_check: skipped (strict initramfs; optional checks disabled)"

append_drop "dropbear_precheck: done"
exit 0

EOF_INITPREMOUNT_DROPBEAR_PRECHECK
      chmod 0755 "/etc/initramfs-tools/scripts/init-premount/60-penelope-dropbear-precheck"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-premount/60-penelope-dropbear-precheck" 0755

      cat > "/etc/initramfs-tools/scripts/init-premount/zz-${TARGET_HOST}-postdropbear-diag" <<'EOF_INITPREMOUNT_POSTDROPBEAR_DIAG'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

BASE="/run/initramfs/penelope"
mkdir -p "$BASE" 2>/dev/null || true

STAGE="$BASE/penelope-initramfs-stage.log"
STAGE_PUB="/run/penelope-initramfs-stage.log"
DIAG="$BASE/penelope-initramfs-diag.log"
DROP="$BASE/penelope-initramfs-dropbear.log"

touch "$STAGE" "$STAGE_PUB" "$DIAG" "$DROP" 2>/dev/null || true

# Capture stderr into stage log so transient boot errors are persisted.
exec 2>>"$STAGE"

stage() { printf '%s %s\n' "$(ts)" "$*" >>"$STAGE" 2>/dev/null || true; }
diag()  { printf '%s %s\n' "$(ts)" "$*" >>"$DIAG" 2>/dev/null || true; }
drop()  { printf '%s %s\n' "$(ts)" "$*" >>"$DROP" 2>/dev/null || true; }

param_get() {
  k="$1"; f="$2"
  [ -r "$f" ] || { printf '%s' ""; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "${k}="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done <"$f" 2>/dev/null || true
  printf '%s' ""
  return 0
}

cmdline_has_word() {
  w="$1"
  for x in $(cat /proc/cmdline 2>/dev/null || true); do
    [ "$x" = "$w" ] && return 0
  done
  return 1
}

hex_le_to_ipv4() {
  h="$1"
  [ -n "$h" ] || { printf '%s' ""; return 0; }
  # Expect 8 hex chars (little endian), e.g. 01B2A8C0 -> 192.168.178.1
  case "$h" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) : ;;
    *) printf '%s' ""; return 0 ;;
  esac
  t="${h%??}"; b1="${h#$t}"; h="$t"
  t="${h%??}"; b2="${h#$t}"; h="$t"
  t="${h%??}"; b3="${h#$t}"; h="$t"
  b4="$h"

  o1="$(printf '%d' "0x$b1" 2>/dev/null || printf '%s' "")"
  o2="$(printf '%d' "0x$b2" 2>/dev/null || printf '%s' "")"
  o3="$(printf '%d' "0x$b3" 2>/dev/null || printf '%s' "")"
  o4="$(printf '%d' "0x$b4" 2>/dev/null || printf '%s' "")"
  [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || { printf '%s' ""; return 0; }
  printf '%s' "${o1}.${o2}.${o3}.${o4}"
  return 0
}

default_gw_ipv4() {
  [ -r /proc/net/route ] || { printf '%s' ""; return 0; }
  while IFS= read -r iface dest gw _rest; do
    # skip header
    [ "$iface" = "Iface" ] && continue
    [ "$dest" = "00000000" ] || continue
    ip="$(hex_le_to_ipv4 "$gw")"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done < /proc/net/route 2>/dev/null || true
  printf '%s' ""
  return 0
}

# Update net.state written by netup (single source of truth). This ensures deferred DHCP state becomes accurate.
net_state_set() {
  _key="$1"
  _val="$2"
  _file="$3"
  [ -n "${_key:-}" ] || return 0
  [ -n "${_file:-}" ] || return 0
  [ -r "${_file}" ] || return 0

  _tmp="${_file}.tmp.$$"
  _found="0"
  {
    while IFS= read -r _line; do
      case "${_line}" in
        "${_key}="*)
          printf '%s\n' "${_key}=${_val}"
          _found="1"
          ;;
        *)
          printf '%s\n' "${_line}"
          ;;
      esac
    done <"${_file}" 2>/dev/null || true

    if [ "${_found}" != "1" ]; then
      printf '%s\n' "${_key}=${_val}"
    fi
  } >"${_tmp}" 2>/dev/null || true

  cat "${_tmp}" >"${_file}" 2>/dev/null || true
  rm -f "${_tmp}" 2>/dev/null || true
  return 0
}

first_ipv4_for_iface() {
  ifc="$1"
  [ -n "$ifc" ] || { printf '%s' ""; return 0; }
  have ip || { printf '%s' ""; return 0; }
  line="$(ip -4 -o addr show dev "$ifc" 2>/dev/null | { IFS= read -r _l || true; printf '%s' "$_l"; } || true)"
  [ -n "$line" ] || { printf '%s' ""; return 0; }

  prev=""
  for tkn in $line; do
    if [ "$prev" = "inet" ]; then
      printf '%s' "${tkn%%/*}"
      return 0
    fi
    prev="$tkn"
  done
  printf '%s' ""
  return 0
}

is_port_listening_proc() {
  port="$1"
  hx="$(printf '%04X' "$port" 2>/dev/null || true)"
  [ -n "$hx" ] || return 1

  for pf in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$pf" ] || continue
    first=1
    while IFS= read -r line; do
      if [ "$first" = "1" ]; then
        first=0
        continue
      fi

      read -r _tcp_sl la _tcp_ra _tcp_state _tcp_rest <<EOF_TCP_LINE
$line
EOF_TCP_LINE
      [ "${_tcp_state:-}" = "0A" ] || continue  # LISTEN
      [ -n "${la:-}" ] || continue
      ph="${la##*:}"
      [ "$ph" = "$hx" ] && return 0
    done <"$pf" 2>/dev/null || true
  done

  return 1
}

# Determine interface from /conf (written by netup)
IFACE="$(param_get "DEVICE" "/conf/param.conf")"
[ -n "$IFACE" ] || IFACE="unknown"

# Determine IPv4 (prefer /run/net-<iface>.conf, then ip)
IPV4="none"
IPV4_SRC="none"
if [ "$IFACE" != "unknown" ] && [ -r "/run/net-${IFACE}.conf" ]; then
  # shellcheck source=/dev/null
  . "/run/net-${IFACE}.conf" 2>/dev/null || true
  if [ -n "${IPV4ADDR:-}" ] && [ "${IPV4ADDR:-}" != "0.0.0.0" ]; then
    IPV4="${IPV4ADDR}"
    IPV4_SRC="run-net-conf"
  fi
fi
if [ "$IPV4" = "none" ] || [ "$IPV4" = "0.0.0.0" ]; then
  ip2="$(first_ipv4_for_iface "$IFACE")"
  if [ -n "$ip2" ]; then
    IPV4="$ip2"
    IPV4_SRC="ip"
  fi
fi

GW="$(default_gw_ipv4)"
[ -n "$GW" ] || GW="?"

# Ensure /run/net-<iface>.conf exists for downstream consumers.
if [ "$IFACE" != "unknown" ] && [ "$IPV4" != "none" ] && [ "$IPV4" != "0.0.0.0" ]; then
  _run_conf="/run/net-${IFACE}.conf"
  if [ ! -r "$_run_conf" ]; then
    printf '%s
' "IPV4ADDR=${IPV4}" >"$_run_conf" 2>/dev/null || true
  fi
fi

# Update net.state written by netup so deferred DHCP becomes visible in init-bottom summary.
_state="${BASE}/net.state"
_state_pub="/run/penelope-initramfs-net.state"
if [ -r "$_state" ] && [ "$IPV4" != "none" ] && [ "$IPV4" != "0.0.0.0" ]; then
  net_state_set "ipv4" "$IPV4" "$_state"
  net_state_set "gw" "$GW" "$_state"
  net_state_set "postdropbear_ipv4_src" "$IPV4_SRC" "$_state"
  cp -f "$_state" "$_state_pub" 2>/dev/null || true
fi

PORT="___PENELOPE_DROPBEAR_PORT___"
LISTENING="unknown"
if is_port_listening_proc "$PORT"; then
  LISTENING="yes"
else
  LISTENING="no"
fi

DEBUG_RETRY="no"
if cmdline_has_word "penelope_debug_retry=1"; then
  DEBUG_RETRY="yes"
fi
if [ "$DEBUG_RETRY" != "yes" ] && [ -r /conf/penelope-initramfs-debug.conf ]; then
  # shellcheck source=/dev/null
  . /conf/penelope-initramfs-debug.conf 2>/dev/null || true
  [ "${INITRAMFS_DEBUG_RETRY:-0}" = "1" ] && DEBUG_RETRY="yes"
fi

stage "postdropbear: iface=${IFACE} ipv4=${IPV4} ipv4_src=${IPV4_SRC} gw=${GW} port=${PORT} listening=${LISTENING} debug_retry=${DEBUG_RETRY}"
diag  "postdropbear: iface=${IFACE} ipv4=${IPV4} ipv4_src=${IPV4_SRC} gw=${GW} port=${PORT} listening=${LISTENING} debug_retry=${DEBUG_RETRY}"

# Ensure stable name for easier retrieval
cp -f "$STAGE" "$STAGE_PUB" 2>/dev/null || true

exit 0

EOF_INITPREMOUNT_POSTDROPBEAR_DIAG
      chmod 0755 "/etc/initramfs-tools/scripts/init-premount/zz-${TARGET_HOST}-postdropbear-diag"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-premount/zz-${TARGET_HOST}-postdropbear-diag" 0755

      cat > "/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag" <<'EOF_INITBOTTOM_SAVE_DIAG'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -eu

prereqs() { echo ""; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

# /root is the mounted, unlocked root filesystem (initramfs-tools)
HN="unknown"
if [ -r /root/etc/hostname ]; then
  IFS= read -r HN < /root/etc/hostname || true
elif [ -r /etc/hostname ]; then
  IFS= read -r HN < /etc/hostname || true
elif [ -r /proc/sys/kernel/hostname ]; then
  IFS= read -r HN < /proc/sys/kernel/hostname || true
fi
[ -n "${HN}" ] || HN="unknown"

SRC_BASE="/run/initramfs/penelope"
mkdir -p "$SRC_BASE" 2>/dev/null || true

SRC_DIAG="$SRC_BASE/penelope-initramfs-diag.log"
SRC_STAGE="$SRC_BASE/penelope-initramfs-stage.log"
SRC_NETUP="$SRC_BASE/penelope-initramfs-netup.log"
SRC_DROPBEAR="$SRC_BASE/penelope-initramfs-dropbear.log"
SRC_UNLOCK="$SRC_BASE/penelope-initramfs-unlock.log"

OUT_DIAG="/run/penelope-initramfs-diag.log"
OUT_STAGE="/run/penelope-initramfs-stage.log"
OUT_NETUP="/run/penelope-initramfs-netup.log"
OUT_DROPBEAR="/run/penelope-initramfs-dropbear.log"
OUT_UNLOCK="/run/penelope-initramfs-unlock.log"

touch "$SRC_DIAG" "$SRC_STAGE" "$SRC_NETUP" "$SRC_DROPBEAR" "$SRC_UNLOCK" 2>/dev/null || true
touch "$OUT_DIAG" "$OUT_STAGE" "$OUT_NETUP" "$OUT_DROPBEAR" "$OUT_UNLOCK" 2>/dev/null || true

# Capture stderr to stage log during logcopy
exec 2>>"$OUT_STAGE"

log_append() {
  # Messages already contain timestamp/prefix via log functions.
  printf '%s\n' "$*" >>"$SRC_DIAG" 2>/dev/null || true
}
log "init-bottom reached; preparing to persist initramfs diagnostics (HN=${HN})."

PRIMARY_DIR="/root/var/log/${HN}/initramfs"
FALLBACK_MNT="/root/_backup"
FALLBACK_DIR="${FALLBACK_MNT}/var/log/${HN}/initramfs"

is_writable_dir() {
  d="$1"
  mkdir -p "$d" 2>/dev/null || return 1
  touch "$d/.penelope_w" 2>/dev/null || return 1
  rm -f "$d/.penelope_w" 2>/dev/null || true
  return 0
}

is_mounted() {
  m="$1"
  [ -r /proc/mounts ] || return 1
  while IFS=' ' read -r _dev _mp _fs _opts _rest; do
    [ "${_mp:-}" = "$m" ] && return 0
  done < /proc/mounts
  return 1
}

resolve_spec_to_dev() {
  spec="$1"
  case "$spec" in
    UUID=*) v="${spec#UUID=}"; [ -e "/dev/disk/by-uuid/$v" ] && readlink -f "/dev/disk/by-uuid/$v" && return 0 ;;
    LABEL=*) v="${spec#LABEL=}"; [ -e "/dev/disk/by-label/$v" ] && readlink -f "/dev/disk/by-label/$v" && return 0 ;;
    PARTUUID=*) v="${spec#PARTUUID=}"; \
      [ -e "/dev/disk/by-partuuid/$v" ] && \
      readlink -f "/dev/disk/by-partuuid/$v" && \
      return 0 ;;
    PARTLABEL=*) v="${spec#PARTLABEL=}"; \
      [ -e "/dev/disk/by-partlabel/$v" ] && \
      readlink -f "/dev/disk/by-partlabel/$v" && \
      return 0 ;;
    /dev/*) [ -e "$spec" ] && echo "$spec" && return 0 ;;
  esac
  return 1
}

mount_backup_if_needed() {
  # Determine backup device from fstab mountpoint "/_backup" (preferred), else by-label.
  spec=""
  fstype=""
  if [ -r /root/etc/fstab ]; then
    while read -r dev mp fs opts dump pass; do
      case "$dev" in ""|\#*) continue ;; esac
      [ "$mp" = "/_backup" ] || continue
      spec="$dev"; fstype="$fs"; break
    done < /root/etc/fstab
  fi

  # Wait briefly for udev to populate /dev/disk/by-* (initramfs).
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle 2>/dev/null || true
  fi
  i=0
  while [ $i -lt 10 ]; do
    [ -e /dev/disk/by-partlabel/_BACKUP ] && break
    [ -e /dev/disk/by-label/_backup ] && break
    sleep 0.2 2>/dev/null || true
    i=$((i+1))
  done

  dev=""
  if [ -n "$spec" ]; then
    dev="$(resolve_spec_to_dev "$spec" 2>/dev/null || true)"
  fi
  if [ -z "$dev" ]; then
    for p in \
      /dev/disk/by-partlabel/_BACKUP \
      /dev/disk/by-partlabel/_backup \
      /dev/disk/by-label/_backup \
      /dev/disk/by-label/backup \
      /dev/disk/by-partlabel/backup; do
      [ -e "$p" ] || continue
      dev="$(readlink -f "$p" 2>/dev/null || true)"
      [ -n "$dev" ] && break
    done
  fi
  [ -n "$dev" ] || return 1

  mkdir -p "$FALLBACK_MNT" 2>/dev/null || true
  if ! is_mounted "$FALLBACK_MNT"; then
    if [ -n "$fstype" ] && [ "$fstype" != "auto" ] && [ "$fstype" != "0" ]; then
      if ! mount -t "$fstype" -o rw "$dev" "$FALLBACK_MNT" 2>/dev/null; then
        mount -o rw "$dev" "$FALLBACK_MNT" 2>/dev/null || true
      fi
    else
      mount -o rw "$dev" "$FALLBACK_MNT" 2>/dev/null || true
    fi
  fi
  is_mounted "$FALLBACK_MNT" || return 1
  log "Mounted /_backup fallback at $FALLBACK_MNT (dev=$dev spec=${spec:-<none>} fs=${fstype:-auto})."
  return 0
}

TARGET_DIR=""
if is_writable_dir "$PRIMARY_DIR"; then
  TARGET_DIR="$PRIMARY_DIR"
  log "Using primary target dir: $TARGET_DIR"
else
  warn "Primary target dir not writable: $PRIMARY_DIR"
  if mount_backup_if_needed && is_writable_dir "$FALLBACK_DIR"; then
    TARGET_DIR="$FALLBACK_DIR"
    log "Using fallback target dir on /_backup: $TARGET_DIR"
  else
    warn "Could not use /_backup fallback (mount or write failed). Leaving diagnostics in initramfs."
  fi
fi

if [ -z "$TARGET_DIR" ]; then
  exit 0
fi
ts_file="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"

copy_if_exists() {
  src="$1"
  dst="$2"
  if [ -s "$src" ]; then
    cp -f "$src" "$dst" 2>/dev/null || true
    chmod 0600 "$dst" 2>/dev/null || true
    log "Copied: $src -> $dst"
  else
    log "missing/empty: $src"
  fi
}

# Append a single-block summary to stage.log for quick triage (router visibility vs. dropbear).
# Format (end of stage.log):
#   SUMMARY NET: carrier/dhcp_attempt_used/ip
#   SUMMARY DROPBEAR: port/listening/retry_used

# Ensure dropbear_port/dropbear_listening are persisted in net.state (deterministic, procfs-only).
# This guarantees SUMMARY DROPBEAR correctness even if earlier stages could not determine listeners.
# Best-effort gateway parsing for late summary reconciliation (route may appear after netup snapshot).
gw_from_ip_route_default() {
  command -v ip >/dev/null 2>&1 || { printf '%s' ""; return 0; }
  _def="$(ip route show default 2>/dev/null | { IFS= read -r _l || true; printf '%s\n' "${_l:-}"; } || true)"
  [ -n "${_def:-}" ] || { printf '%s' ""; return 0; }
  _prev=""
  for _t in $_def; do
    if [ "$_prev" = "via" ]; then
      printf '%s' "$_t"
      return 0
    fi
    _prev="$_t"
  done
  printf '%s' ""
}

gw_hex_le_to_ipv4() {
  _h="$1"
  [ -n "$_h" ] || { printf '%s' ""; return 0; }
  [ ${#_h} -eq 8 ] || { printf '%s' ""; return 0; }
  _b4="${_h%??????}"
  _r="${_h#??}"
  _b3="${_r%????}"
  _r2="${_r#??}"
  _b2="${_r2%??}"
  _b1="${_r2#??}"
  printf '%s.%s.%s.%s' "$((16#${_b1}))" "$((16#${_b2}))" "$((16#${_b3}))" "$((16#${_b4}))"
}

gw_from_proc_net_route_for_iface() {
  _iface="$1"
  [ -n "${_iface:-}" ] || { printf '%s' ""; return 0; }
  [ -r /proc/net/route ] || { printf '%s' ""; return 0; }
  while IFS= read -r _ln; do
    case "$_ln" in
      Iface*Destination*) continue ;;
    esac
    set -- $_ln
    _if="${1:-}"
    _dest="${2:-}"
    _gwhex="${3:-}"
    if [ "$_if" = "$_iface" ] && [ "$_dest" = "00000000" ] && [ "$_gwhex" != "00000000" ]; then
      gw_hex_le_to_ipv4 "$_gwhex"
      return 0
    fi
  done < /proc/net/route 2>/dev/null || true
  printf '%s' ""
}

refresh_dropbear_state_into_net_state() {
  state_file="/run/initramfs/penelope/net.state"
  # Best-effort: never fail init-bottom.
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  [ -e "$state_file" ] || : >"$state_file" 2>/dev/null || true

  port=""
  force_cmd=""
  iface_cur=""
  gw_cur=""
  if [ -r "$state_file" ]; then
    while IFS='=' read -r k v; do
      [ "$k" = "dropbear_port" ] && port="${v:-}"
      [ "$k" = "iface" ] && iface_cur="${v:-}"
      [ "$k" = "gw" ] && gw_cur="${v:-}"
    done < "$state_file"
  fi
  [ -n "$port" ] || port="___PENELOPE_DROPBEAR_PORT___"

  # Try to parse dropbear options for an explicit port override.
  opt=""
  for cf in /etc/dropbear/dropbear.conf /etc/dropbear-initramfs/dropbear.conf /etc/dropbear/initramfs/dropbear.conf; do
    [ -r "$cf" ] || continue
    opt="$( (
      # shellcheck source=/dev/null
      . "$cf" 2>/dev/null || true
      printf '%s' "${DROPBEAR_OPTIONS:-}"
    ) 2>/dev/null || true )"
    [ -n "$opt" ] || continue
    set -- $opt
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          shift
          [ "$#" -gt 0 ] && port="$1"
          ;;
        -p*)
          port="${1#-p}"
          ;;
        -c)
          shift
          if [ "$#" -gt 0 ]; then
            force_cmd="$1"
            force_cmd="${force_cmd#\"}"
            force_cmd="${force_cmd%\"}"
            force_cmd="${force_cmd#\'}"
            force_cmd="${force_cmd%\'}"
          fi
          ;;
        -c*)
          force_cmd="${1#-c}"
          force_cmd="${force_cmd#\"}"
          force_cmd="${force_cmd%\"}"
          force_cmd="${force_cmd#\'}"
          force_cmd="${force_cmd%\'}"
          ;;
      esac
      shift || break
    done
    break
  done

  HX="$(printf '%04X' "$port" 2>/dev/null || true)"
  listen="unknown"
  if [ -n "$HX" ]; then
    for pf in /proc/net/tcp /proc/net/tcp6; do
      [ -r "$pf" ] || continue
      while IFS= read -r line; do
        case "$line" in
          sl*) continue ;;
        esac
        set -- $line
        [ "${4:-}" = "0A" ] || continue
        la="${2:-}"
        lp="${la##*:}"
        if command -v tr >/dev/null 2>&1; then
          lp="$(printf '%s' "$lp" | tr '[:lower:]' '[:upper:]' 2>/dev/null || printf '%s' "$lp")"
        fi
        if [ "$lp" = "$HX" ]; then
          listen="yes"
          break 2
        fi
      done < "$pf"
    done
    [ "$listen" = "yes" ] || listen="no"
  fi

  checked_at="unknown"
  if command -v date >/dev/null 2>&1; then
    checked_at="$(date +%s 2>/dev/null || true)"
  fi
  if [ -z "${checked_at}" ] && [ -r /proc/uptime ]; then
    ua=""
    if IFS=" " read -r _u _rest < /proc/uptime 2>/dev/null; then
      ua="${_u%%.*}"
    fi
    [ -n "${ua}" ] && checked_at="uptime:${ua}"
  fi

  # Reconcile gateway late (route may have been set after netup snapshot but before logcopy/init-bottom).
  gw_fix="${gw_cur:-}"
  case "${gw_fix:-}" in ""|"?"|"none")
    gw_fix="$(gw_from_ip_route_default 2>/dev/null || true)"
    if [ -z "${gw_fix:-}" ] && [ -n "${iface_cur:-}" ]; then
      gw_fix="$(gw_from_proc_net_route_for_iface "$iface_cur" 2>/dev/null || true)"
    fi
    ;;
  esac

  tmp="${state_file}.tmp"
  : >"$tmp" 2>/dev/null || true
  if [ -r "$state_file" ]; then
    while IFS= read -r line; do
      case "$line" in
        dropbear_port=*|dropbear_listening=*|dropbear_listening_source=*|dropbear_listening_checked_at=*|dropbear_force_cmd_effective=*)
          continue
          ;;
        gw=*)
          [ -n "${gw_fix:-}" ] && continue
          ;;
      esac
      printf '%s\n' "$line" >>"$tmp" 2>/dev/null || true
    done < "$state_file" 2>/dev/null || true
  fi
  echo "dropbear_port=${port}" >>"$tmp" 2>/dev/null || true
  echo "dropbear_listening=${listen}" >>"$tmp" 2>/dev/null || true
  echo "dropbear_listening_source=proc-net-tcp" >>"$tmp" 2>/dev/null || true
  echo "dropbear_listening_checked_at=${checked_at}" >>"$tmp" 2>/dev/null || true
  echo "dropbear_force_cmd_effective=${force_cmd:-}" >>"$tmp" 2>/dev/null || true
  [ -n "${gw_fix:-}" ] && echo "gw=${gw_fix}" >>"$tmp" 2>/dev/null || true
  mv "$tmp" "$state_file" 2>/dev/null || cp -f "$tmp" "$state_file" 2>/dev/null || true
}
refresh_dropbear_state_into_net_state
append_stage_summary() {
  # Best-effort: never fail init-bottom.
  [ -n "${SRC_STAGE:-}" ] || return 0
  [ -f "$SRC_STAGE" ] || return 0

  state_file="/run/initramfs/penelope/net.state"

  iface="?"
  mac="?"
  expected_mac="?"
  dhcp_hostname="?"
  dhcp_clientid_kind=""
  dhcp_clientid=""
  carrier="?"
  dhcp_attempt_used="?"
  ipv4="none"
  gw="?"
  gw_ping="skipped"
  dport="___PENELOPE_DROPBEAR_PORT___"
  dfcmd=""
  dlisten="unknown"
  dlisten_src=""
  dlisten_at=""
  dretry="0"

  if [ -r "$state_file" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        iface) iface="${v:-}";;
        mac) mac="${v:-}";;
        expected_mac) expected_mac="${v:-}";;
        dhcp_hostname) dhcp_hostname="${v:-}";;
        dhcp_clientid_kind) dhcp_clientid_kind="${v:-}";;
        dhcp_clientid) dhcp_clientid="${v:-}";;
        carrier) carrier="${v:-}";;
        dhcp_attempt_used) dhcp_attempt_used="${v:-}";;
        ipv4) ipv4="${v:-}";;
        gw) gw="${v:-}";;
        gw_ping) gw_ping="${v:-}";;
        dropbear_port) dport="${v:-}";;
        dropbear_force_cmd_effective) dfcmd="${v:-}";;
        dropbear_listening) dlisten="${v:-}";;
        dropbear_listening_source) dlisten_src="${v:-}";;
        dropbear_listening_checked_at) dlisten_at="${v:-}";;
        dropbear_retry_used) dretry="${v:-}";;
      esac
    done < "$state_file"
  fi

  [ -n "${iface:-}" ] || iface="?"
  [ -n "${mac:-}" ] || mac="?"
  [ -n "${expected_mac:-}" ] || expected_mac="?"
  [ -n "${dhcp_hostname:-}" ] || dhcp_hostname="?"
  [ -n "${carrier:-}" ] || carrier="?"
  [ -n "${dhcp_attempt_used:-}" ] || dhcp_attempt_used="?"
  [ -n "${ipv4:-}" ] || ipv4="none"
  [ -n "${gw:-}" ] || gw="?"
  [ -n "${gw_ping:-}" ] || gw_ping="skipped"
  [ -n "${dport:-}" ] || dport="___PENELOPE_DROPBEAR_PORT___"
  [ -n "${dfcmd:-}" ] || dfcmd="<none>"
  [ -n "${dlisten:-}" ] || dlisten="unknown"
  [ -n "${dlisten_src:-}" ] || dlisten_src=""
  [ -n "${dlisten_at:-}" ] || dlisten_at=""
  [ -n "${dretry:-}" ] || dretry="0"

  cid=""
  if [ -n "${dhcp_clientid_kind:-}" ] || [ -n "${dhcp_clientid:-}" ]; then
    cid="${dhcp_clientid_kind:-cid}:${dhcp_clientid:-}"
  fi
  [ -n "$cid" ] || cid="default"
  echo "[$(ts)] SUMMARY NET: iface=${iface} mac=${mac} expected_mac=${expected_mac}" \
    "dhcp_hostname=${dhcp_hostname} dhcp_clientid=${cid} carrier=${carrier}" \
    "dhcp_attempt_used=${dhcp_attempt_used} ipv4=${ipv4} gw=${gw}" \
    "gw_ping=${gw_ping}" >>"$SRC_STAGE" 2>/dev/null || true
  dsrc="${dlisten_src:-}"
  dat="${dlisten_at:-}"
  if [ "$dsrc" = "proc-net-tcp" ]; then dsrc="proc"; fi
  dmeta=""
  if [ -n "$dsrc" ] || [ -n "$dat" ]; then
    [ -n "$dsrc" ] || dsrc="?"
    [ -n "$dat" ] || dat="?"
    dmeta="(src=${dsrc},at=${dat})"
  fi
  echo "[$(ts)] SUMMARY DROPBEAR: port=${dport} force_cmd=${dfcmd} listening=${dlisten}${dmeta} retry_used=${dretry}" >>"$SRC_STAGE" 2>/dev/null || true

  if [ -r "$SRC_UNLOCK" ]; then
    _ul=""
    while IFS= read -r _line || [ -n "$_line" ]; do
      case "$_line" in
        *" UNLOCK: "*) _ul="$_line" ;;
      esac
    done <"$SRC_UNLOCK"
    if [ -z "${_ul:-}" ]; then
      while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
          *" unlock: "*) _ul="$_line" ;;
        esac
      done <"$SRC_UNLOCK"
    fi
    if [ -n "${_ul:-}" ]; then
      case "$_ul" in
        *" UNLOCK: "*) _umsg="${_ul#* UNLOCK: }" ;;
        *" unlock: "*) _umsg="${_ul#* unlock: }" ;;
        *) _umsg="$_ul" ;;
      esac
      echo "[$(ts)] SUMMARY UNLOCK: ${_umsg}" >>"$SRC_STAGE" 2>/dev/null || true
    fi
  fi
}
append_stage_summary

copy_if_exists "$SRC_DIAG"  "$TARGET_DIR/initramfs-${ts_file}.log"
copy_if_exists "$SRC_DIAG"  "$TARGET_DIR/latest.log"
copy_if_exists "$SRC_STAGE" "$TARGET_DIR/stage-${ts_file}.log"
copy_if_exists "$SRC_NETUP" "$TARGET_DIR/netup-${ts_file}.log"
copy_if_exists "$SRC_DROPBEAR" "$TARGET_DIR/dropbear-${ts_file}.log"
copy_if_exists "$SRC_UNLOCK" "$TARGET_DIR/unlock-${ts_file}.log"

# Ensure logs are available under /run/penelope-*.log for post-boot logcopy
cp -f "$SRC_DIAG" "$OUT_DIAG" 2>/dev/null || true
cp -f "$SRC_STAGE" "$OUT_STAGE" 2>/dev/null || true
cp -f "$SRC_NETUP" "$OUT_NETUP" 2>/dev/null || true
cp -f "$SRC_DROPBEAR" "$OUT_DROPBEAR" 2>/dev/null || true
cp -f "$SRC_UNLOCK" "$OUT_UNLOCK" 2>/dev/null || true
chmod 0600 "$OUT_DIAG" "$OUT_STAGE" "$OUT_NETUP" "$OUT_DROPBEAR" 2>/dev/null || true

# Basis-Infos separat
{
  echo "=== penelope initramfs diag: init-bottom ==="
  date -Iseconds 2>/dev/null || true
  echo "hostname(rootfs): ${HN}"
  echo "cmdline: $(cat /proc/cmdline 2>/dev/null || true)"
  echo "kernel: $(uname -r 2>/dev/null || true)"
} >"$TARGET_DIR/init-bottom.txt" 2>/dev/null || true
chmod 0600 "$TARGET_DIR/init-bottom.txt" 2>/dev/null || true

# Final safety: ensure dropbear does not survive into the real system.
# If dropbear remains running, it can be adopted by PID 1 after switch_root.
for p in /proc/[0-9]*; do
  [ -r "$p/comm" ] || continue
  c="$(cat "$p/comm" 2>/dev/null || true)"
  [ "$c" = "dropbear" ] || continue
  pid="${p#/proc/}"
  log "cleanup(init-bottom): stopping dropbear pid=${pid}"
  kill -TERM "$pid" 2>/dev/null || true
done
sleep 1 2>/dev/null || true
for p in /proc/[0-9]*; do
  [ -r "$p/comm" ] || continue
  c="$(cat "$p/comm" 2>/dev/null || true)"
  [ "$c" = "dropbear" ] || continue
  pid="${p#/proc/}"
  log "cleanup(init-bottom): killing dropbear pid=${pid}"
  kill -KILL "$pid" 2>/dev/null || true
done
EOF_INITBOTTOM_SAVE_DIAG

      # Sanity check (severity=fatal verifier check): init-bottom script must start with a valid shebang
      if ! head -n1 "/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag" 2>/dev/null \
        | grep -qx "#!/bin/sh"; then
        msg="initramfs init-bottom script has missing/incorrect shebang: "\
"/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag"
        sed -n '1,5p' "/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag" >&2 || true
        die "$msg"
      fi

      chmod 0755 "/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/scripts/init-bottom/99-${TARGET_HOST}-save-diag" 0755

      # Hook: copy the scripts into the initrd reliably
      cat > "/etc/initramfs-tools/hooks/${TARGET_HOST}-initramfs-diag" <<'EOF_HOOK_INITRAMFS_DIAG'
#!/bin/sh
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_LOG_FUNCTIONS___
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec "/etc/initramfs-tools/scripts/init-top/10-___PENELOPE_HOST___-diag" "/scripts/init-top/10-___PENELOPE_HOST___-diag"
copy_exec "/etc/initramfs-tools/scripts/init-premount/05-penelope-netup" "/scripts/init-premount/05-penelope-netup"
copy_exec "/etc/initramfs-tools/scripts/init-premount/50-___PENELOPE_HOST___-netdiag" "/scripts/init-premount/50-___PENELOPE_HOST___-netdiag"
copy_exec "/etc/initramfs-tools/scripts/init-premount/60-penelope-dropbear-precheck" "/scripts/init-premount/60-penelope-dropbear-precheck"
copy_exec "/etc/initramfs-tools/scripts/init-premount/zz-___PENELOPE_HOST___-postdropbear-diag" \
  "/scripts/init-premount/zz-___PENELOPE_HOST___-postdropbear-diag"
copy_exec "/etc/initramfs-tools/scripts/init-bottom/99-___PENELOPE_HOST___-save-diag" "/scripts/init-bottom/99-___PENELOPE_HOST___-save-diag"
EOF_HOOK_INITRAMFS_DIAG

      sed -i "s/___PENELOPE_HOST___/${TARGET_HOST}/g" "/etc/initramfs-tools/hooks/${TARGET_HOST}-initramfs-diag"
      chmod 0755 "/etc/initramfs-tools/hooks/${TARGET_HOST}-initramfs-diag"
      finalize_generated_executable_shell_file "/etc/initramfs-tools/hooks/${TARGET_HOST}-initramfs-diag" 0755
      log "Note: the initramfs debug log is stored under /var/log/${TARGET_HOST}/initramfs/ after boot" \
        "(for example latest.log and penelope-initramfs-diag.log)."

      log "initramfs networking via DHCP (for SSH unlock)"
      # Extend the GRUB cmdline (make the hostname visible in initramfs)
      IP_KPARAM="ip=::::${TARGET_HOST}::dhcp"

      # Prefer GRUB_CMDLINE_LINUX (not _DEFAULT) to avoid touching "quiet splash".
      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if grep -q '^GRUB_CMDLINE_LINUX=.*ip=' /etc/default/grub; then
          # Replace an existing ip=<PARAMS> fragment regardless of its previous shape
          sed -i -E "s/^(GRUB_CMDLINE_LINUX=\"[^\"]*)ip=[^ ]*/\1${IP_KPARAM}/" /etc/default/grub
        else
          # Append ip=<PARAMS>
          sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 ${IP_KPARAM}\"/" /etc/default/grub
        fi
      else
        echo "GRUB_CMDLINE_LINUX=\"${IP_KPARAM}\"" >> /etc/default/grub
      fi

      # initramfs-tools network configuration for initramfs (remote unlock via dropbear-initramfs)
      mkdir -p /etc/initramfs-tools/conf.d
      PEN_INITRAMFS_CONF="/etc/initramfs-tools/conf.d/penelope-network.conf"
      {
        echo "# Generated by penelope-install ${VERSION}"
        echo "# Early initramfs networking for dropbear-initramfs (remote LUKS unlock)"
        echo "IP=dhcp"
        echo "# Detected primary interface at install time: ${INITRAMFS_IFACE:-unknown}"
        if [[ -n "${INITRAMFS_IFACE:-}" ]]; then
          echo "DEVICE=${INITRAMFS_IFACE}"
        else
          echo "# DEVICE left unset intentionally: initramfs must auto-select a usable NIC"
        fi
        echo "MODULES=most"
        } > "$PEN_INITRAMFS_CONF"
        chmod 0644 "$PEN_INITRAMFS_CONF"
        log "initramfs-tools conf.d aktualisiert: $PEN_INITRAMFS_CONF"
        sed -n '1,80p' "$PEN_INITRAMFS_CONF" | sed 's/^/   | /'

        # Sanity: initramfs.conf must contain COMPRESS= (otherwise mkinitramfs/update-initramfs aborts)
        if [[ -f /etc/initramfs-tools/initramfs.conf ]]; then
          if ! grep -qE '^COMPRESS=' /etc/initramfs-tools/initramfs.conf; then
            warn "initramfs.conf does not contain COMPRESS=; setting fallback COMPRESS=gzip" \
              "(um mkinitramfs-Abbruch zu verhindern)."
            echo 'COMPRESS=gzip' >> /etc/initramfs-tools/initramfs.conf
          fi
        else
          warn "/etc/initramfs-tools/initramfs.conf missing (unexpected)."
        fi

        log "initramfs: setting MODULES=most via /etc/initramfs-tools/conf.d/penelope-network.conf" \
          "(no changes to the dpkg conffile initramfs.conf)."

        if [[ -n "${NET_MODULES:-}" ]]; then
          touch /etc/initramfs-tools/modules
          for m in ${NET_MODULES}; do
            grep -qxF "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
          done
        fi

        log "Installing SSH key for ${ADMIN_USER} (from live-generated public key)"
        mkdir -p "/home/${ADMIN_USER}/.ssh"
        chmod 700 "/home/${ADMIN_USER}/.ssh"
        cat "/root/${KEY_STAGE_DIR}/${ADMIN_SSH_KEY_NAME}.pub" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
        chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
        chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"

        log "Set up AnyDesk repository cleanly (GPG keyring)"
        install -m 0755 -d /etc/apt/keyrings

        fetch_anydesk_gpg_key() {
          local staged="/etc/penelope/install-cache/keys.anydesk.com.asc"
          local dest="/etc/apt/keyrings/keys.anydesk.com.asc"

          [[ -s "${staged}" ]] || die "Missing staged AnyDesk GPG key from live preflight: ${staged}"
          log "Using staged AnyDesk GPG key from live preflight: ${staged}"
          install -m 0644 "${staged}" "${dest}"
        }

        apt_get_update_for_anydesk() {
          local attempt
          for attempt in 1 2 3; do
            log "AnyDesk APT metadata refresh: attempt ${attempt}/3"
            if apt-get -o Acquire::ForceIPv4=true update -y; then
              return 0
            fi
            if [[ "${attempt}" != "3" ]]; then
              log "AnyDesk APT metadata refresh failed on attempt ${attempt}/3; retrying"
              sleep 5
            fi
          done

          die "AnyDesk APT metadata refresh failed after retries"
        }

        fetch_anydesk_gpg_key
        chmod a+r /etc/apt/keyrings/keys.anydesk.com.asc
        cat > /etc/apt/sources.list.d/anydesk-stable.list <<'ANY_EOF'
# Version: ___PENELOPE_INSTALL_VERSION___
deb [signed-by=/etc/apt/keyrings/keys.anydesk.com.asc] https://deb.anydesk.com all main
ANY_EOF
        stamp_install_version /etc/apt/sources.list.d/anydesk-stable.list
        validate_generated_file /etc/apt/sources.list.d/anydesk-stable.list

        log "Installing AnyDesk (required)"
        apt_get_update_for_anydesk
        apt-get -o Acquire::ForceIPv4=true install -y anydesk
        command -v anydesk >/dev/null 2>&1 || die "AnyDesk installation failed: anydesk binary not found"

        log "Enabling AnyDesk service"
        systemctl enable --now anydesk.service >/dev/null 2>&1 || die "AnyDesk service could not be enabled"
        # In chroot, systemd is typically not PID 1, so "systemctl is-active" is meaningless and may be ignored.
        # We only enforce service activation when systemd is actually running.
        if [ -d /run/systemd/system ]; then
          systemctl is-active --quiet anydesk.service || die "AnyDesk service is not active"
        else
          log "AnyDesk Service status check: skipped (no systemd in chroot)"
        fi

        log "AnyDesk unattended/full access: set manually in the GUI after installation (set-password + 'no confirmation')"
        # Note: Penelope intentionally does not automate an AnyDesk password to avoid persisting secrets in cleartext.
        # Expected: without manual GUI configuration, the client typically shows 'sessions disabled' or requires acceptance.

        # AnyDesk CLI is service-context sensitive; ID/status are reliable as root when the service is running.
        ANYDESK_ID="$(anydesk --get-id 2>/dev/null || true)"
        ANYDESK_STATUS="$(anydesk --get-status 2>/dev/null || true)"
        log "AnyDesk status nach Installation: id=${ANYDESK_ID:-<empty>} status=${ANYDESK_STATUS:-<empty>}"

        log "Cleanup AnyDesk user config for ${ADMIN_USER} (best-effort)"
        rm -rf "/home/${ADMIN_USER}/.anydesk"           "/home/${ADMIN_USER}/.config/AnyDesk"           "/home/${ADMIN_USER}/.config/anydesk" 2>/dev/null || true
        chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}" || true

        log "AnyDesk desktop icon for ${ADMIN_USER} (best-effort)"
        if [[ -f /usr/share/applications/anydesk.desktop ]]; then
          install -d -m 0755 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/Desktop"
          cp -f /usr/share/applications/anydesk.desktop "/home/${ADMIN_USER}/Desktop/AnyDesk.desktop"
          chmod 0755 "/home/${ADMIN_USER}/Desktop/AnyDesk.desktop"
          chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/Desktop/AnyDesk.desktop"
          command -v gio >/dev/null 2>&1 && gio set "/home/${ADMIN_USER}/Desktop/AnyDesk.desktop" metadata::trusted true >/dev/null 2>&1 || true
        fi


        log "Ensure Firefox: firstboot script (run manually; installs snap if needed)"
        # Firstboot setup (AnyDesk / Firefox / admin session) - intentionally manual after the first GNOME login
        cat > "/usr/local/sbin/${TARGET_HOST}-firstboot.sh" <<'FB_EOF'
#!/usr/bin/env bash
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_SOURCE_COMMON___
#
# NOTE: This script is intended for manual execution after the first GNOME login
#       of the admin user.
# Usage: sudo /usr/local/sbin/___PENELOPE_HOST___-firstboot.sh
# Purpose: post-install firstboot tasks for the admin user (for example AnyDesk / Firefox -
#        follow-up work) intentionally separate from the automatic initramfs log-copy path.
#

set -Eeuo pipefail

# ERR trap callback; ShellCheck cannot see indirect trap invocation.
# shellcheck disable=SC2317
on_err() {
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-<unknown>}"
  cmd="${cmd//$'\n'/ }"
  log_error "ERROR: exit=${ec} line=${line} cmd=${cmd}"
  exit "${ec}"
}
trap on_err ERR

readonly FIRSTBOOT_SENTINEL="/var/lib/penelope/.firstboot-done"
if [[ -f "${FIRSTBOOT_SENTINEL}" ]]; then
  log "Firstboot already completed (${FIRSTBOOT_SENTINEL}); exiting."
  exit 0
fi

require_root
systemctl daemon-reload >/dev/null 2>&1 || true  # best-effort: pick up unit changes

resolve_invoking_admin_user() {
  local cand=""
  if [[ -n "${ADMIN_USER:-}" && "${ADMIN_USER}" != "root" ]]; then
    cand="${ADMIN_USER}"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    cand="${SUDO_USER}"
  elif command -v logname >/dev/null 2>&1; then
    cand="$(logname 2>/dev/null || true)"
    if [[ "${cand}" == "root" ]]; then
      cand=""
    fi
  fi
  [[ -n "${cand}" ]] || return 1
  printf '%s\n' "${cand}"
}

# NOTE: AnyDesk CLI --get-id/--get-status may require root when AnyDesk runs as system service.
if command -v anydesk >/dev/null 2>&1; then
  ANYDESK_ID="$(anydesk --get-id 2>/dev/null || true)"
  ANYDESK_STATUS="$(anydesk --get-status 2>/dev/null || true)"
  log "AnyDesk firstboot check: id=${ANYDESK_ID:-<empty>} status=${ANYDESK_STATUS:-<empty>}"
fi

# Run once (manual, no systemd service)
# AnyDesk is installed via APT (no snap fallback).

if ! ADMIN_USER_RESOLVED="$(resolve_invoking_admin_user)"; then
  log_error "Could not determine the admin user (SUDO_USER/logname)."
  log_error "Please run as the target admin via sudo or set ADMIN_USER=<name>."
  exit 1
fi
log "Firstboot Admin-User: ${ADMIN_USER_RESOLVED}"

# Prepare autologin / AnyDesk for the admin user
if loginctl enable-linger "${ADMIN_USER_RESOLVED}" >/dev/null 2>&1; then
  log "loginctl enable-linger: enabled for ${ADMIN_USER_RESOLVED}"
else
  log_warn "loginctl enable-linger: not enabled (unsupported/failed) for ${ADMIN_USER_RESOLVED}"
fi

# Pull in Firefox snap later (if not already present)
if command -v snap >/dev/null 2>&1; then
  if snap list firefox >/dev/null 2>&1; then
    log "Firefox snap: already present"
  else
    if snap install firefox >/dev/null 2>&1; then
      log "Firefox snap: installiert"
    else
      log_warn "Firefox snap: installation failed (store offline?)"
    fi
  fi
else
  log_warn "snap not present; skipped Firefox snap check"
fi

install -d -m 0755 "/var/lib/penelope"
touch "${FIRSTBOOT_SENTINEL}"
log "Firstboot sentinel written: ${FIRSTBOOT_SENTINEL}"

exit 0
FB_EOF

        # Replace placeholder
        apply_placeholders "/usr/local/sbin/${TARGET_HOST}-firstboot.sh"
        chmod +x "/usr/local/sbin/${TARGET_HOST}-firstboot.sh"
        finalize_generated_executable_shell_file "/usr/local/sbin/${TARGET_HOST}-firstboot.sh" 0755

        # No systemd firstboot service: firstboot is intentionally run manually (after GNOME login).
        log "Firstboot: run manually after the first GNOME login: sudo /usr/local/sbin/${TARGET_HOST}-firstboot.sh"

        systemctl enable ssh >/dev/null 2>&1 || true  # optional: ignore if already enabled

        # Persistente Logverzeichnisse
        install -d -m 0750 "/var/log/${TARGET_HOST}/initramfs" "/var/log/${TARGET_HOST}/install"
        install -d -m 0755 "/home/${ADMIN_USER}/install-logs" || true  # optional: non-fatal if home not ready
        chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/install-logs" 2>/dev/null || true  # optional: best-effort

        # Post-boot: copy initramfs logs (including the Dropbear phase) reliably to /var/log/${TARGET_HOST}/initramfs
        cat > "/usr/local/sbin/penelope-copy-initramfs-logs.sh" <<'EOF_SCRIPT_COPY_INITRAMFS_LOGS'
#!/usr/bin/env bash
# Version: ___PENELOPE_INSTALL_VERSION___
___PENELOPE_SOURCE_COMMON___
#
# NOTE: This script is started automatically during a normal boot by
#          penelope-initramfs-logcopy.service runs it.
# Invocation (manual, debug/forcing only):
#   sudo /usr/local/sbin/penelope-copy-initramfs-logs.sh
# Purpose: persist initramfs / Dropbear / network logs into /var/log/___PENELOPE_HOST___/initramfs
#        (or fallback /_backup/var/log/___PENELOPE_HOST___/initramfs).
#

set -Eeuo pipefail

# ERR trap callback; ShellCheck cannot see indirect trap invocation.
# shellcheck disable=SC2317
on_err() {
  local ec=$?
  local line="${BASH_LINENO[0]:-?}"
  local cmd="${BASH_COMMAND:-<unknown>}"
  cmd="${cmd//$'\n'/ }"
  echo "[ERROR] exit=${ec} line=${line} cmd=${cmd}" >&2
  exit "${ec}"
}
trap on_err ERR


require_root
systemctl daemon-reload >/dev/null 2>&1 || true  # best-effort: pick up unit changes

HN="$(cat /etc/hostname 2>/dev/null || hostname -s || echo unknown)"
PRIMARY="/var/log/${HN}/initramfs"
FALLBACK="/_backup/var/log/${HN}/initramfs"

TS="$(date +%Y%m%d-%H%M%S)"

MODE="${PENELOPE_LOGCOPY_MODE:-history_symlink}"
case "${MODE}" in
  history_symlink|stable_only) ;;
  *) MODE="history_symlink" ;;
esac

choose_dest() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || return 1
  touch "$d/.penelope_w" 2>/dev/null || return 1
  rm -f "$d/.penelope_w" 2>/dev/null || true
  echo "$d"
  return 0
}

DEST=""
if DEST="$(choose_dest "$PRIMARY")"; then
  :
elif [[ -d "/_backup" ]] || mkdir -p "/_backup" 2>/dev/null; then
  # If /_backup is not mounted yet, we still try to write there; mount is handled by the system's fstab later.
  if DEST="$(choose_dest "$FALLBACK")"; then
    :
  fi
fi

if [[ -z "$DEST" ]]; then
  echo "[WARN] No writable destination for initramfs logs; best-effort skip (PRIMARY=$PRIMARY, FALLBACK=$FALLBACK)" >&2
  exit 0
fi

# Prefix with "penelope-" so a simple 'find -name "penelope*log"' also catches the logcopy meta-log.
LOGFILE="${DEST}/penelope-logcopy-${TS}.log"
exec >>"$LOGFILE" 2>&1

echo "=== penelope initramfs logcopy (post-boot) @ $(date -Iseconds 2>/dev/null || date) ==="
echo "dest: $DEST"
echo "mode: ${MODE}"
echo

SRC_VOLATILE="/run/initramfs/penelope"
SRC2_GLOB="/run/penelope-*.log"

extract_kv() {
  local file="$1" key="$2"
  local line=""
  [[ -r "$file" ]] || { echo ""; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "${key}="*) echo "${line#*=}"; return 0 ;;
    esac
  done <"$file" 2>/dev/null || true
  echo ""
}

# Boot/run identity: prefer net.state, fall back to stage header.
META_SRC=""
if [[ -r "${SRC_VOLATILE}/net.state" ]]; then
  META_SRC="${SRC_VOLATILE}/net.state"
elif [[ -r "${SRC_VOLATILE}/penelope-initramfs-stage.log" ]]; then
  META_SRC="${SRC_VOLATILE}/penelope-initramfs-stage.log"
fi

BOOT_ID=""
BOOT_TS=""
PENELOPE_INSTALL_VERSION_META=""
PENELOPE_COMMON_VERSION_META=""
if [[ -n "$META_SRC" ]]; then
  BOOT_ID="$(extract_kv "$META_SRC" boot_id)"
  # net.state keys
  PENELOPE_INSTALL_VERSION_META="$(extract_kv "$META_SRC" penelope_install_version)"
  PENELOPE_COMMON_VERSION_META="$(extract_kv "$META_SRC" penelope_common_version)"
  BOOT_TS="$(extract_kv "$META_SRC" boot_ts)"
  # stage header keys (fallback)
  [[ -z "$PENELOPE_INSTALL_VERSION_META" ]] && PENELOPE_INSTALL_VERSION_META="$(extract_kv "$META_SRC" install_version)"
  [[ -z "$PENELOPE_COMMON_VERSION_META" ]] && PENELOPE_COMMON_VERSION_META="$(extract_kv "$META_SRC" common_version)"
  [[ -z "$BOOT_TS" ]] && BOOT_TS="$(extract_kv "$META_SRC" ts)"
fi

BOOT_ID="${BOOT_ID:-unknown}"
BOOT_TS="${BOOT_TS:-unknown}"
PENELOPE_INSTALL_VERSION_META="${PENELOPE_INSTALL_VERSION_META:-unknown}"
PENELOPE_COMMON_VERSION_META="${PENELOPE_COMMON_VERSION_META:-unknown}"

mk_hist_name() {
  local bn="$1"
  case "$bn" in
    penelope-initramfs-*.log)
      echo "${bn%.log}-${BOOT_ID}-${TS}.log"
      ;;
    net.state)
      echo "net.state-${BOOT_ID}-${TS}"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Avoid iterating over a literal pattern when no files match.
shopt -s nullglob

copy_one() {
  local src="$1"
  local dst="$2"
  # Copy only if non-empty; empties are still reported explicitly in the caller.
  if [[ -s "$src" ]]; then
    cp -f "$src" "$dst" 2>/dev/null || return 1
    chmod 0640 "$dst" 2>/dev/null || true
    return 0
  fi
  return 2
}

copy_history_and_link() {
  local src="$1" bn="$2"
  local hn="" dst="" stable=""

  if [[ "${MODE}" == "stable_only" ]]; then
    dst="${DEST}/${bn}"
    if [[ -s "$src" ]]; then
      cp -f "$src" "$dst" 2>/dev/null || return 1
      chmod 0640 "$dst" 2>/dev/null || true
      echo "stable: $src -> $dst"
      return 0
    fi
    return 2
  fi

  hn="$(mk_hist_name "$bn")"
  [[ -z "$hn" ]] && return 1

  dst="${DEST}/${hn}"

  # Copy only if non-empty; empties are still reported explicitly in the caller.
  if [[ -s "$src" ]]; then
    cp -f "$src" "$dst" 2>/dev/null || return 1
    chmod 0640 "$dst" 2>/dev/null || true
  else
    return 2
  fi

  # stable filename points to history file to avoid duplicate content
  stable="${DEST}/${bn}"
  if [[ -e "$stable" && ! -L "$stable" ]]; then
    rm -f "$stable" 2>/dev/null || true
  fi
  ln -sfn "$(basename "$dst")" "$stable" 2>/dev/null || true

  echo "history+link: $src -> $dst ; $(basename "$stable") -> $(basename "$dst")"
  return 0
}

file_size() {
  local p="$1"
  if [[ -e "$p" ]]; then
    stat -c '%s' "$p" 2>/dev/null || echo "?"
  else
    echo "-"
  fi
}

mkdir -p "$DEST" 2>/dev/null || true

echo "sources:"
echo "  SRC_VOLATILE: ${SRC_VOLATILE} (exists=$( [[ -d "$SRC_VOLATILE" ]] && echo 1 || echo 0 ))"
src2_files=()
for f in /run/penelope-*.log; do
  src2_files+=("${f}")
done
echo "  SRC2_GLOB:    ${SRC2_GLOB} (matches=${#src2_files[@]})"
echo

latest_target=""
copied_any=0
declare -A copied=()

# Enumerate and copy from SRC_VOLATILE first (more trustworthy than /run during userspace boot).
if [[ -d "$SRC_VOLATILE" ]]; then
  echo "SRC_VOLATILE listing (ls -al):"
  ls -al "$SRC_VOLATILE" 2>/dev/null || true
  echo
  for f in "$SRC_VOLATILE"/*; do
    [[ -e "$f" ]] || continue
    bn="$(basename "$f")"
    sz="$(file_size "$f")"

    hn="$(mk_hist_name "$bn")"
    if [[ -n "$hn" ]]; then
      hist="${DEST}/${hn}"
      if copy_history_and_link "$f" "$bn"; then
        echo "copied: $f (size=$sz) -> $hist"
        latest_target="${DEST}/${bn}"
        copied_any=1
        copied["$bn"]=1
      else
        rc=$?
        if [[ $rc -eq 2 ]]; then
          echo "skip(empty): $f (size=$sz)"
        else
          echo "copy_failed(rc=$rc): $f (size=$sz) -> $hist"
        fi
      fi
      continue
    fi

    out="${DEST}/${bn}"
    if copy_one "$f" "$out"; then
      echo "copied: $f (size=$sz) -> $out"
      latest_target="$out"
      copied_any=1
      copied["$bn"]=1
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        echo "skip(empty): $f (size=$sz)"
      else
        echo "copy_failed(rc=$rc): $f (size=$sz) -> $out"
      fi
    fi
  done
fi

echo

for f in "${src2_files[@]}"; do
  [[ -e "$f" ]] || continue
  bn="$(basename "$f")"
  [[ -n "${copied[$bn]:-}" ]] && continue
  sz="$(file_size "$f")"

  hn="$(mk_hist_name "$bn")"
  if [[ -n "$hn" ]]; then
    hist="${DEST}/${hn}"
    if copy_history_and_link "$f" "$bn"; then
      echo "copied: $f (size=$sz) -> $hist"
      latest_target="${DEST}/${bn}"
      copied_any=1
      copied["$bn"]=1
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        echo "skip(empty): $f (size=$sz)"
      else
        echo "copy_failed(rc=$rc): $f (size=$sz) -> $hist"
      fi
    fi
    continue
  fi

  out="${DEST}/${bn}"
  if copy_one "$f" "$out"; then
    echo "copied: $f (size=$sz) -> $out"
    latest_target="$out"
    copied_any=1
    copied["$bn"]=1
  else
    rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "skip(empty): $f (size=$sz)"
    else
      echo "copy_failed(rc=$rc): $f (size=$sz) -> $out"
    fi
  fi
done

# Prefer stage/dropbear/diag as "latest" for quick access
for cand in penelope-initramfs-stage.log penelope-initramfs-dropbear.log penelope-initramfs-diag.log; do
  if [[ -s "${DEST}/${cand}" ]]; then
    latest_target="${DEST}/${cand}"
    break
  fi
done

if [[ -n "$latest_target" ]]; then
  ln -sfn "$(basename "$latest_target")" "${DEST}/latest.log" 2>/dev/null || true
  echo
  echo "latest: ${DEST}/latest.log -> $(readlink -f "${DEST}/latest.log" 2>/dev/null || true)"
else
  echo
  echo "latest: not set (no non-empty logs copied)"
fi

# Record last boot identity/version markers for operator convenience
echo "$BOOT_ID" > "${DEST}/LATEST_BOOT_ID" 2>/dev/null || true
echo "$PENELOPE_INSTALL_VERSION_META" > "${DEST}/LATEST_PENELOPE_INSTALL_VERSION" 2>/dev/null || true
echo "$PENELOPE_COMMON_VERSION_META" > "${DEST}/LATEST_PENELOPE_COMMON_VERSION" 2>/dev/null || true

# Clean up volatile sources only if we actually copied something (otherwise keep evidence for debugging).
if [[ "${PENELOPE_KEEP_INITRAMFS_LOGS:-0}" != "1" ]]; then
  if [[ "$copied_any" -eq 1 ]]; then
    rm -rf "$SRC_VOLATILE" 2>/dev/null || true
    if [[ ${#src2_files[@]} -gt 0 ]]; then
      rm -f "${src2_files[@]}" 2>/dev/null || true
    fi
  else
    echo "cleanup: skipped (nothing copied; keeping sources)"
  fi
fi

exit 0
EOF_SCRIPT_COPY_INITRAMFS_LOGS
        chmod 0755 "/usr/local/sbin/penelope-copy-initramfs-logs.sh"
        finalize_generated_executable_shell_file "/usr/local/sbin/penelope-copy-initramfs-logs.sh" 0755

        cat > "/etc/systemd/system/penelope-initramfs-logcopy.service" <<'EOF_UNIT_INITRAMFS_LOGCOPY'
# Version: ___PENELOPE_INSTALL_VERSION___
[Unit]
Description=Penelope: initramfs diagnostics to /var/log/___PENELOPE_HOST___/initramfs
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/penelope-copy-initramfs-logs.sh

[Install]
WantedBy=multi-user.target
EOF_UNIT_INITRAMFS_LOGCOPY

        apply_placeholders "/etc/systemd/system/penelope-initramfs-logcopy.service"
        stamp_install_version "/etc/systemd/system/penelope-initramfs-logcopy.service"
        validate_generated_file "/etc/systemd/system/penelope-initramfs-logcopy.service"
        ensure_no_unexpanded_tokens "/etc/systemd/system/penelope-initramfs-logcopy.service"
        validate_systemd_unit "/etc/systemd/system/penelope-initramfs-logcopy.service"
        enable_unit "penelope-initramfs-logcopy.service"

        log "GRUB-Menue sichtbar (3 Sekunden)"
        if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
          sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        else
          echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
        fi
        if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
          sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
        else
          echo 'GRUB_TIMEOUT=3' >> /etc/default/grub
        fi

        TARGET_KVER="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n 1 || true)"
        if [[ -z "${TARGET_KVER}" ]]; then
          TARGET_KVER="$(uname -r 2>/dev/null || true)"
        fi
        log "initramfs: target kernel for modinfo checks: ${TARGET_KVER:-<unknown>}"

        log "Final check: force NIC modules before update-initramfs"
        if [[ -n "${NET_MODULES:-}" ]]; then
          for m in ${NET_MODULES}; do
            module_path=""

            if command -v modinfo >/dev/null 2>&1; then
              if [[ -n "${TARGET_KVER:-}" ]]; then
                module_path="$(modinfo -n -k "${TARGET_KVER}" "${m}" 2>/dev/null || true)"
              fi
              if [[ -z "${module_path}" ]]; then
                module_path="$(modinfo -n "${m}" 2>/dev/null || true)"
              fi
            fi

            if [[ -z "${module_path}" && -n "${TARGET_KVER:-}" ]]; then
              module_path="$(
                find "/lib/modules/${TARGET_KVER}" -type f -name "${m}.ko*" 2>/dev/null \
                  | head -n 1 || true
              )"
            fi

            if [[ -n "${module_path}" ]]; then
              if ! grep -qxF "${m}" /etc/initramfs-tools/modules 2>/dev/null; then
                echo "${m}" >> /etc/initramfs-tools/modules
                log "initramfs: NIC module added to /etc/initramfs-tools/modules: ${m}"
              else
                log "initramfs: NIC module already present in /etc/initramfs-tools/modules: ${m}"
              fi
            else
              warn "initramfs: NIC module not found as an external module: ${m} (possibly built in)"
            fi
          done
          log "initramfs: /etc/initramfs-tools/modules (tail):"
          tail -n 30 /etc/initramfs-tools/modules 2>/dev/null || true
        fi

        log "Initramfs build manifest (pre-build): writing /etc/penelope/initramfs-manifest"
        mkdir -p /etc/penelope
        {
          echo "=== penelope initramfs build manifest (PRE) ==="
          echo "MANIFEST_SCHEMA=1"
          echo "EXPECTED_GRUB_IP=ip=::::${TARGET_HOST}::dhcp"
          date -Iseconds 2>/dev/null || date 2>/dev/null || true
          echo
          echo "## /etc/penelope/buildinfo"
          cat /etc/penelope/buildinfo 2>/dev/null || echo "(missing)"
          echo
          echo "## selected interface (install-time)"
          echo "INITRAMFS_IFACE=${INITRAMFS_IFACE:-}"
          echo "INITRAMFS_MAC=${INITRAMFS_MAC:-}"
          echo "INITRAMFS_DRIVER=${INITRAMFS_DRIVER:-}"
          echo "NET_MODULES=${NET_MODULES:-}"
          echo
          echo "## dropbear-initramfs (on-disk config)"
          if [ -r /etc/dropbear/initramfs/dropbear.conf ]; then
            echo "--- /etc/dropbear/initramfs/dropbear.conf ---"
            cat /etc/dropbear/initramfs/dropbear.conf 2>/dev/null || true
            DB_PORT="$(grep -Eo '(^|[[:space:]])-p[[:space:]]*[0-9]+' /etc/dropbear/initramfs/dropbear.conf 2>/dev/null | head -n1 | awk '{print $2}' || true)"
            DB_FCMD="$(grep -Eo '(^|[[:space:]])-c[[:space:]]*[^[:space:]]+' /etc/dropbear/initramfs/dropbear.conf 2>/dev/null | head -n1 | awk '{print $2}' || true)"
            echo "DROPBEAR_PORT_EFFECTIVE=${DB_PORT:-}"
            echo "DROPBEAR_FORCE_CMD_EFFECTIVE=${DB_FCMD:-}"
          else
            echo "(missing: /etc/dropbear/initramfs/dropbear.conf)"
          fi
          echo
          echo "## authorized_keys fingerprint (no key material)"
          if command -v ssh-keygen >/dev/null 2>&1 && [ -r /etc/dropbear/initramfs/authorized_keys ]; then
            ssh-keygen -l -f /etc/dropbear/initramfs/authorized_keys 2>/dev/null || true
          else
            echo "(ssh-keygen missing or authorized_keys missing)"
          fi
          echo
          echo "## initramfs-tools network config"
          if [ -r /etc/initramfs-tools/conf.d/penelope-network.conf ]; then
            echo "--- /etc/initramfs-tools/conf.d/penelope-network.conf ---"
            cat /etc/initramfs-tools/conf.d/penelope-network.conf 2>/dev/null || true
          else
            echo "(missing: /etc/initramfs-tools/conf.d/penelope-network.conf)"
          fi
          echo
          echo "## initramfs scripts/hooks (relevant subset)"
          echo "[hooks]"
          ls -1 /etc/initramfs-tools/hooks 2>/dev/null | egrep -i '(penelope|dropbear|crypt|ipconfig|net|hostname)' | sort || true
          echo
          echo "[scripts]"
          find /etc/initramfs-tools/scripts -maxdepth 2 -type f 2>/dev/null | egrep -i '(penelope|dropbear|netup|netdiag|postdropbear|save-diag|hostname|diag)' | sort || true
          echo
          echo "## firmware requirements (best-effort from modinfo)"
          if command -v modinfo >/dev/null 2>&1 && [ -n "${NET_MODULES:-}" ]; then
            fw_raw=""
            if [ -n "${TARGET_KVER:-}" ]; then
              fw_raw="$(modinfo -k "${TARGET_KVER}" -F firmware ${NET_MODULES} 2>/dev/null || true)"
            fi
            if [ -z "${fw_raw}" ]; then
              fw_raw="$(modinfo -F firmware ${NET_MODULES} 2>/dev/null || true)"
            fi
            fw_list="$(awk 'NF' <<<"${fw_raw}" | sort -u || true)"
            if [ -n "${fw_list}" ]; then
              echo "${fw_list}" | sed 's/^/  - /'
            else
              echo "(none reported by modinfo)"
            fi
          else
            echo "(modinfo missing or NET_MODULES empty)"
          fi
          echo "=== end manifest (PRE) ==="
        } > /etc/penelope/initramfs-manifest
        chmod 0644 /etc/penelope/initramfs-manifest
        log "Initramfs build manifest (PRE) written: /etc/penelope/initramfs-manifest"
        log "== Manifest (PRE) =="
        sed 's/^/      /' /etc/penelope/initramfs-manifest 2>/dev/null || true

        log "Updating initramfs and GRUB"
        log "== update-initramfs (including dropbear/cryptroot) =="

        # Best-effort: Some Ubuntu firmware packages ship *.fw.zst; mkinitramfs sometimes expects plain *.fw.
        # To reduce noisy "Failed to copy <firmware>.fw.zst" warnings, we opportunistically decompress required
        # firmware listed in the PRE manifest (if present). This is non-fatal by design.
        #
        # Deterministic Logging Contract (for install log triage):
#   initramfs: fw_preflight total=<n> zst_present=<n> plain_present=<n> unpacked=<n> unpack_failed=<n> missing=<n> zstd=<present|missing> fw_root_real=<path>
#   initramfs: fw_preflight missing examples: <up to 10>
#   initramfs: fw_preflight unpack failed examples: <up to 10>
#
# Notes:
# - We probe both /lib/firmware and /usr/lib/firmware (usrmerge variants).
# - We always write the decompressed *.fw to /lib/firmware/<fw> (which is typically a symlink to /usr/lib/firmware on usrmerged systems).
if [ -r /etc/penelope/initramfs-manifest ]; then
  fw_needed="$(
    awk '
      $0 ~ /^## firmware requirements/ {in_fw=1; next}
      in_fw && $0 ~ /^=== end manifest/ {exit}
      in_fw && $0 ~ /^  -[[:space:]]+/ {sub(/^  -[[:space:]]+/, ""); print}
    ' /etc/penelope/initramfs-manifest 2>/dev/null | awk 'NF' | sort -u
  )"

  if [ -n "${fw_needed}" ]; then
    fw_total="$(printf '%s
' "${fw_needed}" | wc -l | tr -d ' ')"
    zstd_status="missing"
    if command -v zstd >/dev/null 2>&1; then
      zstd_status="present"
    fi

    # If zstd is missing, try to install it (best-effort). We intentionally do not hard-fail here,
    # because firmware decompression is an optimization to reduce initramfs noise and improve robustness.
    if [ "${zstd_status}" = "missing" ]; then
      warn "initramfs: zstd missing; trying best-effort install (non-fatal)"
      if apt-get update -y >/dev/null 2>&1 && apt-get install -y zstd >/dev/null 2>&1; then
        log "initramfs: zstd installiert (best-effort)"
        zstd_status="present"
      else
        warn "initramfs: zstd installation failed (non-fatal); firmware .zst will not be unpacked"
      fi
    fi

    fw_root_real="$(readlink -f /lib/firmware 2>/dev/null || echo /lib/firmware)"
    plain_present=0
    zst_present=0
    unpacked=0
    unpack_failed=0
    missing=0
    missing_examples=""
    unpack_fail_examples=""

    while IFS= read -r fw; do
      [ -n "${fw}" ] || continue

      fw_plain_lib="/lib/firmware/${fw}"
      fw_zst_lib="${fw_plain_lib}.zst"
      fw_plain_usr="/usr/lib/firmware/${fw}"
      fw_zst_usr="${fw_plain_usr}.zst"

      # 1) Plain present (either location)
      if [ -e "${fw_plain_lib}" ] || [ -e "${fw_plain_usr}" ]; then
        plain_present=$((plain_present+1))
        continue
      fi

      # 2) Compressed present (either location)
      fw_zst_src=""
      if [ -e "${fw_zst_lib}" ]; then
        fw_zst_src="${fw_zst_lib}"
      elif [ -e "${fw_zst_usr}" ]; then
        fw_zst_src="${fw_zst_usr}"
      fi

      if [ -n "${fw_zst_src}" ]; then
        zst_present=$((zst_present+1))
        if [ "${zstd_status}" = "present" ]; then
          mkdir -p "$(dirname "${fw_plain_lib}")" 2>/dev/null || true
          if zstd -d -q -c -- "${fw_zst_src}" >"${fw_plain_lib}" 2>/dev/null; then
            unpacked=$((unpacked+1))
            log "initramfs: Firmware entpackt: ${fw} (src=$(basename "${fw_zst_src}"))"
          else
            unpack_failed=$((unpack_failed+1))
            warn "initramfs: firmware unpack failed (non-fatal): ${fw_zst_src} -> ${fw_plain_lib}"
            if [ "$(printf '%s' "${unpack_fail_examples}" | wc -l | tr -d ' ')" -lt 10 ]; then
              unpack_fail_examples="${unpack_fail_examples}${fw} (src=${fw_zst_src})
"
            fi
          fi
        fi
      else
        missing=$((missing+1))
        if [ "$(printf '%s' "${missing_examples}" | wc -l | tr -d ' ')" -lt 10 ]; then
          missing_examples="${missing_examples}${fw} (checked=/lib/firmware,/usr/lib/firmware)
"
        fi
      fi
    done <<<"${fw_needed}"

    log "initramfs: fw_preflight total=${fw_total} zst_present=${zst_present}" \
      "plain_present=${plain_present} unpacked=${unpacked}" \
      "unpack_failed=${unpack_failed} missing=${missing}" \
      "zstd=${zstd_status} fw_root_real=${fw_root_real}"

    if [ "${missing}" -gt 0 ] && [ -n "${missing_examples}" ]; then
      warn "initramfs: fw_preflight missing examples:"
      printf '%s' "${missing_examples}" | sed 's/^/  - /'
    fi
    if [ "${unpack_failed}" -gt 0 ] && [ -n "${unpack_fail_examples}" ]; then
      warn "initramfs: fw_preflight unpack failed examples:"
      printf '%s' "${unpack_fail_examples}" | sed 's/^/  - /'
    fi
  fi
fi
penelope_initramfs_strict_smoke_test

        # Capture update-initramfs output deterministically to triage firmware copy warnings
        _penelope_uinit_out="$(mktemp -t penelope-update-initramfs.XXXXXX.log)"
        if ! ( set -o pipefail; update-initramfs -u -k all 2>&1 | tee "${_penelope_uinit_out}" ); then
          warn "update-initramfs failed; debug output follows."
          log "   - update-initramfs output (last 200 lines):"
          tail -n 200 "${_penelope_uinit_out}" 2>/dev/null || true
          log "   - /etc/initramfs-tools/initramfs.conf (relevant keys/head):"
          if [[ -f /etc/initramfs-tools/initramfs.conf ]]; then
            grep -nE '^(COMPRESS|MODULES|DEVICE|IP)=' /etc/initramfs-tools/initramfs.conf 2>/dev/null \
              | sed 's/^/      /' || true
            sed -n '1,200p' /etc/initramfs-tools/initramfs.conf | sed 's/^/      /' || true
          else
            log "      (file missing)"
          fi
          log "   - /etc/initramfs-tools/conf.d:"
          ls -la /etc/initramfs-tools/conf.d 2>/dev/null || true
          if [[ -f /etc/initramfs-tools/conf.d/penelope-network.conf ]]; then
            sed -n '1,120p' /etc/initramfs-tools/conf.d/penelope-network.conf | sed 's/^/      /' || true
          fi
          log "   - dpkg -l initramfs-tools dropbear-initramfs cryptsetup-initramfs:"
          dpkg -l initramfs-tools dropbear-initramfs cryptsetup-initramfs 2>/dev/null || true
          log "   - last /var/log/dpkg.log lines:"
          tail -n 120 /var/log/dpkg.log 2>/dev/null || true
          rm -f "${_penelope_uinit_out}" 2>/dev/null || true
          exit 20
        fi

        # If update-initramfs printed firmware warnings, probe them deterministically (no noise)
        _penelope_fw_warn_lines="$(grep -E 'WARNING: (Failed to copy firmware:|Firmware file not found:)' "${_penelope_uinit_out}" 2>/dev/null || true)"
        if [[ -n "${_penelope_fw_warn_lines}" ]]; then
          _penelope_fw_root_real="$(readlink -f /lib/firmware 2>/dev/null || echo /lib/firmware)"
          _penelope_fw_warn_count="$(printf '%s\n' "${_penelope_fw_warn_lines}" | wc -l | tr -d ' ')"
          warn "initramfs: update-initramfs firmware warnings detected: count=${_penelope_fw_warn_count} fw_root_real=${_penelope_fw_root_real}"
          warn "initramfs: firmware warning examples (up to 10) with existence/provenance:"
          _penelope_fw_ex=0
          while IFS= read -r _penelope_line; do
            _penelope_fw_ex=$(( _penelope_fw_ex + 1 ))
            if [ "${_penelope_fw_ex}" -gt 10 ]; then
              break
            fi

            # Extract firmware reference
            _penelope_ref="$(
              printf '%s\n' "${_penelope_line}" \
                | sed -nE 's/^.*(Failed to copy firmware:|Firmware file not found:)[[:space:]]*//p' \
                | tr -d '\r'
            )"

            # Build probe candidates across usrmerge variants
            _penelope_cands=""
            if [[ "${_penelope_ref}" == /* ]]; then
              _penelope_cands="${_penelope_ref}"
              if [[ "${_penelope_ref}" == /lib/firmware/* ]]; then
                _penelope_cands="${_penelope_cands} /usr/lib/firmware/${_penelope_ref#/lib/firmware/}"
              elif [[ "${_penelope_ref}" == /usr/lib/firmware/* ]]; then
                _penelope_cands="${_penelope_cands} /lib/firmware/${_penelope_ref#/usr/lib/firmware/}"
              fi
            else
              _penelope_cands="/lib/firmware/${_penelope_ref} /usr/lib/firmware/${_penelope_ref}"
            fi

            # Probe (first existing candidate wins for details)
            _penelope_found="no"
            _penelope_detail="(missing in /lib/firmware and /usr/lib/firmware)"
            for _penelope_p in ${_penelope_cands}; do
              if [[ -e "${_penelope_p}" ]]; then
                _penelope_found="yes"
                _penelope_rl="$(readlink -f "${_penelope_p}" 2>/dev/null || echo '-')"
                _penelope_ls="$(ls -l "${_penelope_p}" 2>/dev/null | tr -d '\r' || true)"
                _penelope_sz="$(stat -c '%s' "${_penelope_p}" 2>/dev/null || echo '-')"
                _penelope_mode="$(stat -c '%a' "${_penelope_p}" 2>/dev/null || echo '-')"
                _penelope_detail="exists=yes size=${_penelope_sz} mode=${_penelope_mode} real=${_penelope_rl} ls='${_penelope_ls}'"
                break
              fi
            done

            warn "  - fw='${_penelope_ref}' ${_penelope_detail}"
          done <<<"${_penelope_fw_warn_lines}"
        fi

        rm -f "${_penelope_uinit_out}" 2>/dev/null || true
        log "== grub-install =="
        if ! grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck; then
          warn "grub-install failed; attempting diagnostics"
          log "   - EFI vars:"
          ls -la /sys/firmware/efi/efivars 2>/dev/null | head -20 || true
          log "   - /boot/efi contents:"
          ls -la /boot/efi 2>/dev/null || true
          log "   - /boot/efi/EFI:"
          ls -laR /boot/efi/EFI 2>/dev/null || true
          die "GRUB installation failed. The system will not be able to boot."
        fi

        log "== update-grub =="
        if ! update-grub; then
          warn "update-grub failed"
          log "   - /boot/grub/ contents:"
          ls -la /boot/grub/ 2>/dev/null || true
          log "   - grub.cfg (first 50 lines):"
          head -50 /boot/grub/grub.cfg 2>/dev/null || true
          die "GRUB config generation failed."
        fi

        log "Cleaning up (removing key staging)"
        rm -rf /root/${KEY_STAGE_DIR} || true

        log "Initramfs/GRUB verification: hostname + Dropbear + authorized_keys + IP (proof in log)"

        echo
        echo "## On-disk initramfs-tools"
        echo "--- /etc/initramfs-tools/initramfs.conf (DEVICE/IP) ---"
        if [ -f /etc/initramfs-tools/initramfs.conf ]; then
          grep -E '^(DEVICE=|IP=)' /etc/initramfs-tools/initramfs.conf 2>/dev/null || true
        else
          echo "(missing) /etc/initramfs-tools/initramfs.conf"
        fi
        echo "--- /etc/initramfs-tools/conf.d/penelope-network.conf (DEVICE/IP) ---"
        if [ -f /etc/initramfs-tools/conf.d/penelope-network.conf ]; then
          grep -E '^(DEVICE=|IP=)' /etc/initramfs-tools/conf.d/penelope-network.conf 2>/dev/null || true
        else
          echo "(missing) /etc/initramfs-tools/conf.d/penelope-network.conf"
        fi

        echo
        echo "## On-disk Dropbear (initramfs)"
        ls -al /etc/dropbear/initramfs || true
        echo "--- /etc/dropbear/initramfs/dropbear.conf ---"
        cat /etc/dropbear/initramfs/dropbear.conf 2>/dev/null || true
        echo "--- /etc/dropbear/initramfs/authorized_keys (first line) ---"
        sed -n '1p' /etc/dropbear/initramfs/authorized_keys 2>/dev/null || true

        echo
        INITRD="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)"
        echo "INITRD=${INITRD}"
        echo "INITRAMFS_IFACE=${INITRAMFS_IFACE:-<empty>}"
        echo "NET_MODULES=${NET_MODULES:-<empty>}"

# Initrd inventory: materialize once into a temp file to avoid huge shell variables
# (large initrd listings can cause truncation/false negatives in verification).
INITRD_LIST_FILE=""
if command -v lsinitramfs >/dev/null 2>&1; then
  INITRD_LIST_FILE="$(mktemp "${TMPDIR:-/tmp}/penelope-initrd-list.XXXXXX" 2>/dev/null || true)"
  if [ -n "${INITRD_LIST_FILE}" ]; then
    if ! lsinitramfs "${INITRD}" > "${INITRD_LIST_FILE}" 2>/dev/null; then
      rm -f "${INITRD_LIST_FILE}" 2>/dev/null || true
      INITRD_LIST_FILE=""
    fi
  fi
fi
if [ -z "${INITRD_LIST_FILE}" ]; then
  warn "lsinitramfs not available or initrd list could not be created"
fi

cleanup_initrd_list_file() {
  if [ -n "${INITRD_LIST_FILE:-}" ]; then
    rm -f "${INITRD_LIST_FILE}" 2>/dev/null || true
    INITRD_LIST_FILE=""
  fi
}
trap cleanup_initrd_list_file EXIT

        echo "initramfs-tools config (relevant):"
        if [[ -f /etc/initramfs-tools/initramfs.conf ]]; then
          echo "--- /etc/initramfs-tools/initramfs.conf ---"
          grep -nE '^(COMPRESS|MODULES|IP|DEVICE)=' /etc/initramfs-tools/initramfs.conf 2>/dev/null || true
        else
          warn "/etc/initramfs-tools/initramfs.conf missing"
        fi
        echo "--- /etc/initramfs-tools/conf.d/penelope-network.conf ---"
        cat /etc/initramfs-tools/conf.d/penelope-network.conf 2>/dev/null || true

        echo "Initrd: dropbear Artefakte (lsinitramfs grep):"
        if [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ]; then
          LSINIT_RE="(dropbear|authorized_keys|cryptroot-unlock|ipconfig|dhcpc|penelope-network\.conf)"
          LSINIT_RE="${LSINIT_RE}|(conf/conf\.d|penelope-buildinfo|penelope-initramfs-manifest)"
          LSINIT_RE="${LSINIT_RE}|(penelope-dropbear-precheck|penelope-netup|penelope-initramfs-)"
          awk -v re="${LSINIT_RE}" \
            'BEGIN{c=0} $0 ~ re {print; c++; if(c>=80) exit}' \
            "${INITRD_LIST_FILE}" || true
        else
          warn "lsinitramfs not available"
        fi


echo
echo "Initrd: REQUIRED artifacts (strict gate for Dropbear remote unlock)"
if [ -z "${INITRD:-}" ] || [ ! -r "${INITRD}" ]; then
  die "Initramfs verification: INITRD not found/readable: ${INITRD:-<empty>}"
fi
if [ -z "${INITRD_LIST_FILE:-}" ] || [ ! -r "${INITRD_LIST_FILE}" ]; then
  die "Initramfs verification: lsinitramfs inventory missing (INITRD_LIST_FILE empty/not readable)"
fi

_missing=0

# Helper: require at least one matching path in initrd inventory for a given artefact.
# Why? lsinitramfs paths differ across initramfs-tools/dropbear-initramfs versions
# (e.g. root/.ssh vs root-<RANDOM>/.ssh). This must not cause false negatives.
require_any_initrd() {
  local label="$1"
  shift
  local re
  local hit=""
  for re in "$@"; do
    hit="$(grep -E -m1 "${re}" "${INITRD_LIST_FILE}" 2>/dev/null || true)"
    if [ -n "${hit}" ]; then
      echo "OK(initrd): ${label} (${hit})"
      return 0
    fi
  done
  warn "MISSING(initrd): ${label}"
  _missing=1
  return 1
}

# Attention: paths in lsinitramfs are typically stored without a leading slash.
# dropbear-initramfs stores its config, depending on version/build, under:
# - etc/dropbear/dropbear.conf (typical)
# - etc/dropbear/initramfs/dropbear.conf (some layouts)
# authorized_keys is often located under root*/.ssh/authorized_keys, sometimes also under etc/dropbear/*.
require_any_initrd "dropbear" \
  '(^|/)usr/sbin/dropbear$'

require_any_initrd "dropbear.conf" \
  '(^|/)etc/dropbear/dropbear\.conf$' \
  '(^|/)etc/dropbear/initramfs/dropbear\.conf$'

require_any_initrd "cryptroot-unlock" \
  '(^|/)usr/bin/cryptroot-unlock$' \
  '(^|/)usr/sbin/cryptroot-unlock$' \
  '(^|/)bin/cryptroot-unlock$' \
  'cryptroot-unlock$'

require_any_initrd "decrypt_keyctl" \
  '(^|/)lib/cryptsetup/scripts/decrypt_keyctl$' \
  '(^|/)usr/lib/cryptsetup/scripts/decrypt_keyctl$'

require_any_initrd "authorized_keys" \
  '(^|/)root/\.ssh/authorized_keys$' \
  '(^|/)root-[^/]+/\.ssh/authorized_keys$' \
  '(^|/)etc/dropbear/authorized_keys$' \
  '(^|/)etc/dropbear/initramfs/authorized_keys$'

if [ "${_missing}" -ne 0 ]; then
  die "Initramfs verification failed: Dropbear/authorized_keys/dropbear.conf/decrypt_keyctl missing in initrd. Remote unlock after reboot would not be reliable."
fi

# Check whether the detected NIC modules are present in the initrd (tolerant regarding .ko.*)
        if [[ -n "${NET_MODULES:-}" && -f "$INITRD" ]] && command -v lsinitramfs >/dev/null 2>&1; then
          # Note: with 'set -o pipefail', 'lsinitramfs | grep -m1' can produce false positives (SIGPIPE).
          # Therefore use the materialized inventory (INITRD_LIST_FILE) and match against it without a pipe.

          for m in ${NET_MODULES}; do
            if grep -E -m1 "/${m}\.ko(\.[a-z0-9]+)?$" "${INITRD_LIST_FILE}" >/dev/null 2>&1; then
              echo "OK: NIC module present in initrd: ${m}"
              grep -E -m1 "/${m}\.ko(\.[a-z0-9]+)?$" "${INITRD_LIST_FILE}" || true
            else
              warn "NIC module NOT found in initrd: ${m} (remote unlock may fail because the driver is missing)"
            fi
          done

          # Firmware check (best-effort).
          # Why best-effort? modinfo can report firmware lists that contain entries
          # that do not exist on a specific system/kernel tree. This is not a
          # hard install criterion, but we log proof (ok/missing),
          # because missing NIC firmware can break remote unlock/networking during the initramfs phase.
          if command -v modinfo >/dev/null 2>&1; then
            fw_raw=""
            if [[ -n "${TARGET_KVER:-}" ]]; then
              fw_raw="$(modinfo -k "${TARGET_KVER}" -F firmware ${NET_MODULES} 2>/dev/null || true)"
            fi
            if [[ -z "${fw_raw}" ]]; then
              fw_raw="$(modinfo -F firmware ${NET_MODULES} 2>/dev/null || true)"
            fi
            fw_list="$(awk 'NF' <<<"${fw_raw}" | sort -u || true)"
            if [[ -n "${fw_list}" ]]; then
              echo "Firmware requirements for ${NET_MODULES}:"
              echo "${fw_list}" | sed 's/^/  - /'
              ok_fw=0
              miss_fw=0
              missing_fw=()
              while read -r fw; do
                [[ -z "${fw}" ]] && continue
                fw_re="$(printf '%s' "${fw}" | sed -e 's/[][(){}.^$+*?|\/]/\\&/g')"
                # lsinitramfs typically lists paths without a leading slash; firmware may live under lib/ or usr/lib/.
                if grep -Eq "(^|/)(usr/)?lib/firmware/.*/${fw_re}(\.zst|\.xz|\.gz)?$" "${INITRD_LIST_FILE}"; then
                  ok_fw=$((ok_fw+1))
                else
                  miss_fw=$((miss_fw+1))
                  if [ ${#missing_fw[@]} -lt 10 ]; then
                    missing_fw+=("${fw}")
                  fi
                fi
              done <<<"${fw_list}"

              echo "Firmware-Proof(initrd): ok=${ok_fw} missing=${miss_fw} (best-effort)"
              if [ "${ok_fw}" -eq 0 ]; then
                warn "None of the firmware files reported by modinfo were found in the initrd (ok=0). Remote unlock may fail because NIC firmware is missing."
              fi
              if [ "${miss_fw}" -gt 0 ]; then
                warn "Firmware not in initrd (showing up to 10 examples):"
                for fw in "${missing_fw[@]}"; do
                  warn "  missing: ${fw}"
                done
              fi
            fi
          fi
          # NOTE: do not remove INITRD_LIST_FILE here; it is reused later for POST manifest and strict verification.
          # Cleanup happens via trap cleanup_initrd_list_file EXIT.

      if [ -z "${INITRD}" ] || [ ! -r "${INITRD}" ]; then
            echo "ERROR: No initrd found under /boot; verification not possible."
            exit 1
          fi

          GRUB_CMDLINE_LINUX="$(grep -E '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -n1 || true)"
          echo "${GRUB_CMDLINE_LINUX}"

          EXPECTED_IP="ip=::::${TARGET_HOST}::dhcp"
          FAIL=0

          if echo "${GRUB_CMDLINE_LINUX}" | grep -Fq "${EXPECTED_IP}"; then
            echo "[OK]   GRUB_CMDLINE_LINUX contains exactly: ${EXPECTED_IP}"
          else
            echo "[FAIL] GRUB_CMDLINE_LINUX does NOT contain: ${EXPECTED_IP}"
            FAIL=1
          fi

          if grep -R -nF "${EXPECTED_IP}" /boot/grub/grub.cfg >/dev/null 2>&1; then
            echo "[OK]   grub.cfg contains: ${EXPECTED_IP}"
          else
            echo "[FAIL] grub.cfg does NOT contain: ${EXPECTED_IP}"
            FAIL=1
          fi

          # Initrd: inventory is stored in INITRD_LIST_FILE (see above) to avoid truncation/false negatives.

          # Build-Manifest (POST): initrd contents proof (modules/firmware) in one block
          POST_MANIFEST_DIR="/var/log/penelope"
          POST_MANIFEST="${POST_MANIFEST_DIR}/initramfs-build-manifest.post"
          mkdir -p "${POST_MANIFEST_DIR}" 2>/dev/null || true
          {
            echo "=== penelope initramfs build manifest (POST) ==="
            date -Iseconds 2>/dev/null || date 2>/dev/null || true
            echo
            echo "INITRD=${INITRD}"
            echo "TARGET_KVER=${TARGET_KVER:-}"
            echo "INITRAMFS_IFACE=${INITRAMFS_IFACE:-}"
            echo "INITRAMFS_MAC=${INITRAMFS_MAC:-}"
            echo "INITRAMFS_DRIVER=${INITRAMFS_DRIVER:-}"
            echo "NET_MODULES=${NET_MODULES:-}"
            echo
            echo "## initrd: core inventory (filtered)"
INITRD_INV_RE='^(conf/initramfs\.conf|etc/(dropbear|hostname)|root-.*\.ssh/authorized_keys|'
INITRD_INV_RE="${INITRD_INV_RE}scripts/init-(top|premount|bottom)/|"
INITRD_INV_RE="${INITRD_INV_RE}usr/(sbin/dropbear|bin/ipconfig|bin/cryptroot-unlock)|"
INITRD_INV_RE="${INITRD_INV_RE}conf/penelope-(buildinfo|initramfs-manifest))"
if [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ]; then
  grep -E "$INITRD_INV_RE" "${INITRD_LIST_FILE}" || true
else
  echo "(initrd list missing)"
fi
echo
echo "## initrd: NIC module presence (best-effort)"
for m in ${NET_MODULES:-}; do
  if [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ] &&                  grep -E "/${m}\.ko(\.[a-z0-9]+)?$" "${INITRD_LIST_FILE}" >/dev/null 2>&1; then
    echo "OK: module in initrd: ${m}"
    awk -v m="${m}" '$0 ~ "/" m "\\.ko(\\.[a-z0-9]+)?$" {print; exit}' "${INITRD_LIST_FILE}" || true
  else
    echo "MISSING: module not found in initrd: ${m}"
  fi
done
echo
echo "## initrd: firmware presence for NIC modules (best-effort)"
if command -v modinfo >/dev/null 2>&1 && [ -n "${NET_MODULES:-}" ]; then
  fw_raw=""
  if [ -n "${TARGET_KVER:-}" ]; then
    fw_raw="$(modinfo -k "${TARGET_KVER}" -F firmware ${NET_MODULES} 2>/dev/null || true)"
  fi
  if [ -z "${fw_raw}" ]; then
    fw_raw="$(modinfo -F firmware ${NET_MODULES} 2>/dev/null || true)"
  fi
  fw_list="$(awk 'NF' <<<"${fw_raw}" | sort -u || true)"
  if [ -n "${fw_list}" ]; then
    ok_fw=0
    miss_fw=0
    missing_fw=()

    while read -r fw; do
      [ -z "$fw" ] && continue

      fw_re="$(printf '%s' "$fw" | sed -e 's/[][(){}.^$+*?|\\/]/\\&/g')"
      present="no"

      if [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ]; then
        # If modinfo already returns a relative path (e.g. rtl_nic/foo.fw), check exact path first.
        if grep -Eq "(^|\\./)(usr/)?lib/firmware/${fw_re}(\\.zst|\\.xz|\\.gz)?$" "${INITRD_LIST_FILE}"; then
          present="yes"
        else
          # If firmware name is not a path, allow any subdir under lib/firmware.
          case "$fw" in
            */*) : ;;
            *)
              if grep -Eq "(^|\\./)(usr/)?lib/firmware/.*/${fw_re}(\\.zst|\\.xz|\\.gz)?$" "${INITRD_LIST_FILE}"; then
                present="yes"
              fi
              ;;
          esac
        fi
      fi

      if [ "$present" = "yes" ]; then
        ok_fw=$((ok_fw+1))
      else
        miss_fw=$((miss_fw+1))
        if [ ${#missing_fw[@]} -lt 10 ]; then
          missing_fw+=("${fw}")
        fi
      fi
    done <<<"${fw_list}"

    echo "Firmware-Proof(initrd): ok=${ok_fw} missing=${miss_fw} (best-effort)"
    if [ "${miss_fw}" -gt 0 ]; then
      echo "Missing examples (up to 10):"
      for fw in "${missing_fw[@]}"; do
        echo "  - ${fw}"
      done
    fi
  else
    echo "(none reported by modinfo)"
  fi
else
  echo "(modinfo missing or NET_MODULES empty)"
fi
echo
echo "=== end manifest (POST) ==="

          } > "${POST_MANIFEST}" 2>/dev/null || true
          chmod 0644 "${POST_MANIFEST}" 2>/dev/null || true
          echo
          echo "## penelope initramfs build manifest (POST) written: ${POST_MANIFEST}"
          sed 's/^/   | /' "${POST_MANIFEST}" 2>/dev/null || true

          has_initrd_path(){
            # accepts both "foo/bar" and "./foo/bar"
            [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ] || return 1
            grep -Fqx -- "${1}" "${INITRD_LIST_FILE}" && return 0
            grep -Fqx -- "./${1}" "${INITRD_LIST_FILE}"
          }

          for P in \
          "conf/initramfs.conf" \
          "conf/penelope-buildinfo" \
          "conf/penelope-initramfs-manifest" \
          "etc/hostname" \
          "scripts/init-top/00-${TARGET_HOST}-hostname" \
          "scripts/init-top/10-${TARGET_HOST}-diag" \
          "scripts/init-premount/50-${TARGET_HOST}-netdiag" \
          "scripts/init-premount/zz-${TARGET_HOST}-postdropbear-diag" \
          "scripts/init-bottom/99-${TARGET_HOST}-save-diag" \
          "etc/dropbear/dropbear.conf"
          do
            if has_initrd_path "${P}"; then
              echo "[OK]   initrd contains: ${P}"
            else
              echo "[FAIL] initrd does NOT contain ${P}"
              FAIL=1
            fi

          done
          # Network-driver correlation (STRICT): live install vs. target initramfs
          INSTALL_NETINFO="/etc/penelope/netinfo-install.conf"
          INSTALL_DRIVER=""
          if [ -f "${INSTALL_NETINFO}" ]; then
            INSTALL_DRIVER="$(grep -E '^install_driver=' "${INSTALL_NETINFO}" 2>/dev/null | tail -n1 | cut -d= -f2-)"
          fi
          if [ -n "${INSTALL_DRIVER}" ]; then
            # Derive kernel release from INITRD (initrd.img-<kver>)
            KREL="$(basename "${INITRD}" | sed 's/^initrd\.img-//')"
            # Backfill install-time netinfo target kernel candidate (for later correlation) if still empty.
            if [ -f "${INSTALL_NETINFO}" ] && grep -q '^target_kernel_candidate=$' "${INSTALL_NETINFO}" 2>/dev/null; then
              sed -i "s|^target_kernel_candidate=$|target_kernel_candidate=${KREL}|" "${INSTALL_NETINFO}" 2>/dev/null || true
              echo "[OK]   install-netinfo: target_kernel_candidate backfilled: ${KREL}"
            fi
            echo "netdriver proof: install_driver=${INSTALL_DRIVER} target_krel=${KREL}"

            # Built-in module?
            BUILTIN_LIST="/lib/modules/${KREL}/modules.builtin"
            # modules.builtin typically contains paths such as "kernel/<module-path>/r8169.ko" (without leading slash)
            if [ -f "${BUILTIN_LIST}" ] && grep -qE "(^|/)${INSTALL_DRIVER}\.ko$" "${BUILTIN_LIST}" 2>/dev/null; then
              echo "[OK]   target kernel: ${INSTALL_DRIVER} is built in (modules.builtin)"
            else
              # Present as a module? (query modinfo for the target kernel)
              MODPATH="$(modinfo -n -k "${KREL}" "${INSTALL_DRIVER}" 2>/dev/null || true)"
              if [ -n "${MODPATH}" ] && [ -e "${MODPATH}" ]; then
                :
              else
                # Fallback (deterministic): direct search in the target module tree
                MODPATH="$(find "/lib/modules/${KREL}" -type f -name "${INSTALL_DRIVER}.ko*" 2>/dev/null | LC_ALL=C sort | head -n1 || true)"
              fi
              if [ -z "${MODPATH}" ] || [ ! -e "${MODPATH}" ]; then
                echo "[FAIL] target kernel: module ${INSTALL_DRIVER} not found (modinfo -n -k ${KREL} / find /lib/modules/${KREL})"
                FAIL=1
              else
                RELPATH="${MODPATH#/}"
                # Ubuntu initramfs may place modules under usr/lib/modules/.. (usrmerge).
                # Therefore check both possible prefixes deterministically.
                ALT_RELPATH=""
                case "${RELPATH}" in
                  lib/modules/*) ALT_RELPATH="usr/${RELPATH}" ;;
                  usr/lib/modules/*) ALT_RELPATH="${RELPATH#usr/}" ;;
                esac

                if has_initrd_path "${RELPATH}" \
                  || has_initrd_path "${RELPATH}.zst" \
                  || has_initrd_path "${RELPATH}.xz" \
                  || has_initrd_path "${RELPATH%.zst}" \
                  || has_initrd_path "${RELPATH%.xz}" \
                  || { [ -n "${ALT_RELPATH}" ] && (
                       has_initrd_path "${ALT_RELPATH}" \
                    || has_initrd_path "${ALT_RELPATH}.zst" \
                    || has_initrd_path "${ALT_RELPATH}.xz" \
                    || has_initrd_path "${ALT_RELPATH%.zst}" \
                    || has_initrd_path "${ALT_RELPATH%.xz}"
                  ); }; then
                  echo "[OK]   initrd contains NIC driver: ${RELPATH}${ALT_RELPATH:+ (or ${ALT_RELPATH})}"
                else
                  echo "[FAIL] initrd does NOT contain NIC driver: ${RELPATH}${ALT_RELPATH:+ (or ${ALT_RELPATH})}"
                  FAIL=1
                fi
              fi
            fi
          else
            echo "netdriver proof: install_driver=<unknown> (no /etc/penelope/netinfo-install.conf or empty)"
          fi


          echo "initrd Dropbear/SSH inventory (grep):"
          INITRD_INV_RE='^(conf/initramfs\.conf|etc/(dropbear|hostname)|root-.*\.ssh/authorized_keys|'
          INITRD_INV_RE="${INITRD_INV_RE}scripts/init-(top|premount|bottom)/|"
          INITRD_INV_RE="${INITRD_INV_RE}usr/(sbin/dropbear|bin/ipconfig|bin/cryptroot-unlock)|conf/penelope-(buildinfo|initramfs-manifest))"
          if [ -n "${INITRD_LIST_FILE:-}" ] && [ -r "${INITRD_LIST_FILE}" ]; then
            grep -E "$INITRD_INV_RE" "${INITRD_LIST_FILE}" || true
          fi

          # Dropbear.conf content (best-effort)
          if has_initrd_path "etc/dropbear/dropbear.conf"; then
            echo "--- initrd:/etc/dropbear/dropbear.conf ---"
            lsinitramfs "${INITRD}" "etc/dropbear/dropbear.conf" 2>/dev/null || true
          fi

          # authorized_keys: find path and compare the first line (key type + key material)
          AK_PATH="$(awk '/\.ssh\/authorized_keys$/{print; exit}' "${INITRD_LIST_FILE}" 2>/dev/null || true)"
          echo "initrd authorized_keys path: ${AK_PATH:-<not found>}"
          if [ -z "${AK_PATH}" ]; then
            echo "[FAIL] initrd does NOT contain authorized_keys"
            FAIL=1
          else
            echo "[OK]   initrd contains authorized_keys"
            EXPECTED_AK="$(
              awk 'NR==1{print $1" "$2}' /etc/dropbear/initramfs/authorized_keys 2>/dev/null |
                tr -d $'\r' || true
            )"

            # Robust: read initrd authorized_keys across varying lsinitramfs variants; never fatal.
            read_initramfs_file() {
              local initrd="$1" path="$2"
              path="${path#/}"  # initrd paths are typically stored without a leading slash
              local out=""

              if command -v lsinitramfs >/dev/null 2>&1; then
                # Variante A: lsinitramfs -f <file> <initrd>
                if out="$(lsinitramfs -f "$path" "$initrd" 2>/dev/null)" && [ -n "$out" ]; then
                  printf '%s' "$out"
                  return 0
                fi

                # Variante B: lsinitramfs <initrd> <file>
                if out="$(lsinitramfs "$initrd" "$path" 2>/dev/null)" && [ -n "$out" ]; then
                  printf '%s' "$out"
                  return 0
                fi
              fi

              if command -v unmkinitramfs >/dev/null 2>&1; then
                local tmp
                tmp="$(mktemp -d "${TMPDIR:-/tmp}/penelope-install-work.XXXXXX")"
                if unmkinitramfs "$initrd" "$tmp" >/dev/null 2>&1; then
                  if [ -f "$tmp/main/$path" ]; then
                    out="$(cat "$tmp/main/$path" 2>/dev/null || true)"
                  elif [ -f "$tmp/$path" ]; then
                    out="$(cat "$tmp/$path" 2>/dev/null || true)"
                  fi
                fi
                rm -rf "$tmp" >/dev/null 2>&1 || true
              fi

              printf '%s' "$out"
              return 0
            }

            INITRD_AK_RAW="$(read_initramfs_file "${INITRD}" "${AK_PATH}" || true)"
            INITRD_AK="$(printf '%s\n' "${INITRD_AK_RAW}" | awk 'NR==1{print $1" "$2}' | tr -d $'\r' || true)"

            echo "authorized_keys (initrd, first line):"
            echo "${INITRD_AK:-<empty>}"

            if [ -n "${INITRD_AK}" ] && [ "${INITRD_AK}" = "${EXPECTED_AK}" ]; then
              echo "[OK]   authorized_keys in the initrd matches /etc/dropbear/initramfs/authorized_keys"
            else
              echo "[FAIL] authorized_keys in the initrd does NOT match the file under "\
"/etc/dropbear/initramfs/authorized_keys"
              echo "        expected: ${EXPECTED_AK:-<empty>}"
              FAIL=1
            fi
          fi

          if [ "${FAIL}" -eq 0 ]; then
            echo
            echo "[OK]   Initramfs/GRUB verification successful."
          else
            echo
            # Severity: fatal. This verifier is distinct from other unconditional fatal checks (e.g. chroot initramfs risk scan),
            # but it is itself fail-fast in the installer.
            warn "Initramfs/GRUB verification failed."
            echo "Verifier classification: $(penelope_verifier_mode_label)"
            echo "ERROR: Verifier failure (severity=fatal) -> abort."
            exit 1
          fi
          echo "Initramfs/GRUB verification: end"

          fi

          log "chroot complete"

CHROOT_EOF
  then
    chroot_rc=0
  else
    chroot_rc=$?
  fi

  umount_chroot_support_fs_best_effort

  return "${chroot_rc}"
}

final_message() {
  local artifact_dir="${INSTALL_ARTIFACT_OUTPUT_DIR:-$(cd "$(dirname "${INSTALL_BOOTSTRAP_CONFIG_FILE}")" && pwd -P 2>/dev/null || printf '.')}"
  local unlock_archive_path="${UNLOCK_ARCHIVE_PATH:-${artifact_dir}/${TARGET_HOST}_unlock_keys.7z}"
  local admin_archive_path="${ADMIN_SSH_ARCHIVE_PATH:-${artifact_dir}/${ADMIN_USER}_ssh_keys.7z}"

  # Unquoted heredoc: expansion required for dynamic hints and paths.
  cat <<EOF_USAGE

[$(date +%H:%M:%S)] === Installation completed (penelope-install ${VERSION}) ===

The following files are now beside the bootstrap config used for this install run:
  - ${unlock_archive_path}           (Dropbear unlock key pair)
  - ${admin_archive_path}       (SSH key pair for '${ADMIN_USER}')
Both archives are encrypted with CRED_MASTER_PW.

Remote-Unlock (initramfs):
  ssh -i ~/.ssh/${DROPBEAR_KEY_NAME} -p ${DROPBEAR_PORT} root@<${TARGET_HOST}-IP>
Then enter CRED_MASTER_PW once; all LUKS containers will open.

${INITRAMFS_IFACE:+Initramfs network pinning: DEVICE=${INITRAMFS_IFACE}}
${INITRAMFS_IFACE:-WARNING: No fixed initramfs NIC detected; DEVICE stays unset and initramfs auto-selects an interface. Verify Dropbear reachability especially carefully after the first reboot.}

Initramfs diagnostic log (persisted after boot):
  sudo ls -l /var/log/${TARGET_HOST}/initramfs/
  sudo less /var/log/${TARGET_HOST}/initramfs/latest.log

Note: Firefox is pulled in on the first full boot via '${TARGET_HOST}-firstboot' (snap) if needed.
The automatic initramfs log-copy path stays separate from that: penelope-initramfs-logcopy.service writes to /var/log/${TARGET_HOST}/initramfs/ after boot.

Important backup rule before and after reboot:
  - Back up the generated key archives and the effectively used install configurations externally right away.
  - This now includes both the real bootstrap config (ADMIN_USER/TARGET_HOST/CRED_*) and the real layout config.
  - Record relevant secrets in KeePassXC or an equivalent secure vault and verify the backup.
  - Do not treat loose workdir copies or a KeePass database stored only on this server as the sole source of truth.
  - For later reinstall/preserve runs, first run --verify-layout-contract with the real bootstrap config and layout config before any destructive start.

Next required steps after reboot:
  1. Log in as '${ADMIN_USER}' on the installed system.
  2. sudo /usr/local/sbin/${TARGET_HOST}-firstboot.sh
  3. sudo -E /usr/local/sbin/penelope-verify-security.sh      # early verify
  4. Run the backup-setup bundle from the prepared workdir
     (penelope-backup-setup-<version>.sh + penelope-common.sh)
  5. In the normal case, then run the samba-setup bundle
     (penelope-samba-setup-<version>.sh + penelope-common.sh)
     Skip only for an explicit non-Samba special profile; then
     create /etc/penelope/non-samba-profile with a short justification.
  6. sudo -E /usr/local/sbin/penelope-verify-security.sh      # late verify

Verification/inspection commands on the installed system:
  - sudo -E /usr/local/sbin/penelope-verify-security.sh
  - sudo ls -l /var/log/${TARGET_HOST}/initramfs/
  - sudo less /var/log/${TARGET_HOST}/initramfs/latest.log

When you are ready:
  sudo reboot
EOF_USAGE
}


persist_sanitized_recovery_stage() {
  [[ -n "${TARGET:-}" ]] || return 0
  [[ -d "${TARGET}" ]] || return 0

  local stage_dir
  local tmp_install
  local dest_install
  local rc

  stage_dir="$(penelope_recovery_stage_dir_for_target "${TARGET}")"
  tmp_install="${stage_dir}/penelope-install.sh.tmp.$$"
  dest_install="${stage_dir}/penelope-install.sh"

  penelope_ensure_recovery_stage_dir "${stage_dir}" || die "Failed to create recovery stage dir in target: ${stage_dir}"

  sed -E \
    -e 's/^(CRED_MASTER_PW=)"[^"]*"/\1"change-me"/' \
    -e 's/^(CRED_LOGIN_PW=)"[^"]*"/\1"change-me"/' \
    "${BASH_SOURCE[0]}" > "${tmp_install}" || die "Failed to sanitize installer for recovery stage"

  penelope_publish_recovery_stage_file "${tmp_install}" "${dest_install}" 0755 || die "Failed to stage sanitized installer copy"

  if penelope_stage_common_for_recovery "${stage_dir}" "${SCRIPT_DIR}"; then
    :
  else
    rc=$?
    if [[ ${rc} -eq 1 ]]; then
      warn "penelope-common.sh not found for installer recovery stage; common copy not refreshed"
    else
      die "Failed to stage penelope-common for recovery stage"
    fi
  fi

  log "Recovery stage updated in target: ${stage_dir}"
}

persist_install_log() {
  # Persist the installer log into the target system so it is available after the first boot.
  # Target tree:
  #   /var/log/${TARGET_HOST}/install/penelope-install-$VERSION-<timestamp>.log
  #   /var/log/${TARGET_HOST}/install/latest.log -> most recently copied log
  #
  # Additionally create /var/log/${TARGET_HOST}/initramfs (for the post-boot log-copy service).

  [[ -n "${TARGET:-}" ]] || return 0
  [[ -d "${TARGET}" ]] || return 0

  local ts
  ts="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"
  local base="${TARGET}/var/log/${TARGET_HOST}"
  local dest_dir="${base}/install"

  mkdir -p "${dest_dir}" "${base}/initramfs" || true
  chmod 0755 "${base}" 2>/dev/null || true

  if [[ -f "${LOGFILE:-}" ]]; then
    local dest="${dest_dir}/penelope-install-${VERSION}-${ts}.log"
    cp -a "${LOGFILE}" "${dest}" 2>/dev/null || true
    chmod 0640 "${dest}" 2>/dev/null || true
    ln -sfn "$(basename "${dest}")" "${dest_dir}/latest.log" 2>/dev/null || true
    log "Installer log persisted: ${dest}"
  else
    warn "Installer log not found: LOGFILE='${LOGFILE:-<empty>}'"
  fi
}

post_install_token_scan() {
  # Scan the target system for any unexpanded Penelope macro tokens.
  # This must remain strict to guarantee from-scratch stability.
  [[ -n "${TARGET:-}" ]] || return 0
  [[ -d "${TARGET}" ]] || return 0

  log "Post-install: token scan in target system (unexpanded tokens must be 0)"

  local failed=0
  local roots=()

  # Focus on Penelope-managed locations (avoid scanning the full rootfs).
  roots+=("${TARGET}/etc/initramfs-tools/scripts")
  roots+=("${TARGET}/etc/initramfs-tools/hooks")
  roots+=("${TARGET}/etc/dropbear/initramfs")
  roots+=("${TARGET}/etc/systemd/system")
  roots+=("${TARGET}/usr/local/sbin")
  roots+=("${TARGET}/etc/crypttab")
  roots+=("${TARGET}/etc/hosts")
  roots+=("${TARGET}/etc/hostname")

  for r in "${roots[@]}"; do
    if [[ -d "${r}" ]]; then
      if ! scan_tree_for_unexpanded_tokens "${r}"; then
        failed=1
      fi
    elif [[ -f "${r}" ]]; then
      if ! ensure_no_unexpanded_tokens "${r}"; then
        failed=1
      fi
    fi
  done

  if [[ "${failed}" -ne 0 ]]; then
    die "Post-install token scan failed: found unexpanded token strings in the target system."
  fi

  log "Post-install token scan: OK (no tokens found)"
}

post_install_initramfs_risk_scan() {
  log "Post-install scan: initramfs risk check (strict, 0 findings required)"

  # This scan runs on the full live system (not inside initramfs) and validates
  # that generated initramfs scripts/hooks do not rely on commands that may be
  # missing in minimal initramfs images.
  if ! PENELOPE_INITRAMFS_RISK_STRICT=1 scan_initramfs_for_unguarded_commands "${TARGET}"; then
    die "Initramfs risk scan failed: unguarded risky command usage detected in Penelope-managed initramfs scripts/hooks"
  fi

  log "Post-install scan: initramfs risk check OK (0 findings)"
}


current_runtime_host_for_logs() {
  local host=""
  if [[ -r /etc/hostname ]]; then
    host="$(tr -d '[:space:]' </etc/hostname 2>/dev/null || true)"
  fi
  if [[ -z "${host}" ]] && command -v hostname >/dev/null 2>&1; then
    host="$(hostname 2>/dev/null || true)"
    host="${host%%.*}"
  fi
  [[ -n "${host}" ]] || host="penelope"
  printf '%s
' "${host}"
}

assert_plausible_initramfs_only_target() {
  [[ -r /etc/os-release ]] || die "initramfs-only mode requires /etc/os-release on the target system"
  [[ -d /etc/initramfs-tools ]] || die "initramfs-only mode requires /etc/initramfs-tools on the target system"
  [[ -r /etc/crypttab ]] || die "initramfs-only mode requires /etc/crypttab on the target system"
  [[ -d /lib/modules ]] || die "initramfs-only mode requires /lib/modules on the target system"
  [[ -d /boot ]] || die "initramfs-only mode requires /boot on the target system"
  command -v update-initramfs >/dev/null 2>&1 || die "initramfs-only mode requires update-initramfs"
  command -v lsinitramfs >/dev/null 2>&1 || die "initramfs-only mode requires lsinitramfs"
}

collect_initramfs_only_kernel_versions() {
  local selected="${INITRAMFS_ONLY_KVER:-all}"
  local -a kernels=()
  local line

  if [[ "${selected}" == "all" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      kernels+=("${line}")
    done < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V)
  else
    [[ -d "/lib/modules/${selected}" ]] || die "--kver target not found under /lib/modules: ${selected}"
    kernels+=("${selected}")
  fi

  ((${#kernels[@]} > 0)) || die "initramfs-only mode found no installed kernels"
  printf '%s
' "${kernels[@]}"
}

persist_initramfs_only_log_bundle() {
  local host="$1"
  local manifest_src="$2"
  persist_install_mode_log_bundle "initramfs-only" "${host}" "${manifest_src}"
}

persist_verify_layout_contract_log_bundle() {
  local host="$1"
  local manifest_src="$2"
  persist_install_mode_log_bundle "verify-layout-contract" "${host}" "${manifest_src}"
}

persist_install_mode_log_bundle() {
  local mode="$1"
  local host="$2"
  local manifest_src="$3"
  local ts
  ts="${RUN_TS:-$(date +%Y%m%d-%H%M%S)}"

  local base="/var/log/${host}/install"
  mkdir -p "${base}" || true

  if [[ -f "${LOGFILE:-}" ]]; then
    local dest_log="${base}/penelope-install-${VERSION}-${mode}-${ts}.log"
    cp -a "${LOGFILE}" "${dest_log}" 2>/dev/null || true
    chmod 0640 "${dest_log}" 2>/dev/null || true
    ln -sfn "$(basename "${dest_log}")" "${base}/latest-${mode}.log" 2>/dev/null || true
    log "${mode} log persisted: ${dest_log}"
  fi

  if [[ -f "${manifest_src}" ]]; then
    local dest_manifest="${base}/penelope-install-${VERSION}-${mode}-${ts}.manifest"
    cp -a "${manifest_src}" "${dest_manifest}" 2>/dev/null || true
    chmod 0644 "${dest_manifest}" 2>/dev/null || true
    ln -sfn "$(basename "${dest_manifest}")" "${base}/latest-${mode}.manifest" 2>/dev/null || true
    log "${mode} manifest persisted: ${dest_manifest}"
  fi
}


# Top-level generated-artifact finalizer used by managed-artifacts-only mode.
# The full-install chroot path contains an equivalent generated copy for target-side
# provisioning. Keep this host-side copy in sync with the target-side finalizer.
stamp_install_version() {
  local f="$1"
  [[ -n "$f" ]] || die "stamp_install_version: missing path"
  [[ -f "$f" ]] || die "stamp_install_version: file not found: $f"

  inject_log_functions_macro_if_present "$f"
  inject_common_guards_macro_if_present "$f"

  if ! grep -q "___PENELOPE_INSTALL_VERSION___" "$f"; then
    die "missing version placeholder token in: $f"
  fi

  sed -i "s/___PENELOPE_INSTALL_VERSION___/${VERSION}/g" "$f"
  if grep -q "___PENELOPE_INSTALL_VERSION___" "$f"; then
    die "version placeholder was not substituted: $f"
  fi

  if grep -q "___PENELOPE_COMMON_VERSION___" "$f"; then
    sed -i "s/___PENELOPE_COMMON_VERSION___/${PENELOPE_COMMON_VERSION}/g" "$f"
    if grep -q "___PENELOPE_COMMON_VERSION___" "$f"; then
      die "common version placeholder was not substituted: $f"
    fi
  fi

  if ! grep -qE "^# Version: ${VERSION}([[:space:]]|$)" "$f"; then
    die "missing or mismatched Version header in: $f"
  fi
}


annotate_generated_common_sources_for_shellcheck() {
  local f="${1:?missing path}"
  local tmp=""
  local line=""
  local prev_line=""
  local original_mode=""

  [[ -f "${f}" ]] || die "annotate_generated_common_sources_for_shellcheck: file not found: ${f}"
  if command -v stat >/dev/null 2>&1; then
    original_mode="$(stat -c %a "${f}" 2>/dev/null || true)"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-shellcheck-sources.XXXXXX")"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "  source \"\$(dirname \"\${BASH_SOURCE[0]}\")/penelope-common.sh\"")
        if [[ "${prev_line}" != *'shellcheck disable=SC109'* ]]; then
          printf '%s\n' '  # Runtime sibling common library; generated artifact can run from a bundle/workdir copy.' >>"${tmp}"
          printf '%s\n' '  # shellcheck disable=SC1090,SC1091' >>"${tmp}"
        fi
        ;;
      "  source \"/usr/local/lib/penelope/common.sh\"")
        if [[ "${prev_line}" != *'shellcheck disable=SC109'* ]]; then
          printf '%s\n' '  # Runtime installed common library; validated by the installer-owned artifact refresh path.' >>"${tmp}"
          printf '%s\n' '  # shellcheck disable=SC1091' >>"${tmp}"
        fi
        ;;
    esac
    printf '%s\n' "${line}" >>"${tmp}"
    prev_line="${line}"
  done <"${f}"

  mv -f "${tmp}" "${f}" || {
    rm -f "${tmp}" 2>/dev/null || true
    die "annotate_generated_common_sources_for_shellcheck: failed to update ${f}"
  }
  if [[ -n "${original_mode}" ]]; then
    chmod "${original_mode}" "${f}" || die "annotate_generated_common_sources_for_shellcheck: failed to restore mode ${original_mode} on ${f}"
  fi
}

finalize_generated_shell_file() {
  local f="${1:?missing path}"
  [[ -f "${f}" ]] || die "finalize_generated_shell_file: file not found: ${f}"

  sed -i -E 's/^[[:space:]]*(__PENELOPE_(LOG_FUNCTIONS|COMMON_GUARDS|SOURCE_COMMON)__)[[:space:]]*$/\1/' "${f}" 2>/dev/null || true
  inject_known_macros_if_present "${f}"
  annotate_generated_common_sources_for_shellcheck "${f}"
  stamp_install_version "${f}"
  apply_placeholders "${f}"
  validate_generated_file "${f}"
  ensure_no_unexpanded_tokens "${f}"
  validate_shell_script "${f}"

  local token_count mode owner
  token_count="$( (grep -oE '__PENELOPE_[A-Z_]*__' "${f}" 2>/dev/null || true) | wc -l | tr -d ' \t' )"
  mode=""
  owner=""
  if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c %a "${f}" 2>/dev/null || true)"
    owner="$(stat -c %u:%g "${f}" 2>/dev/null || true)"
  fi
  log "finalize_ok: path=${f} macros=ok tokens=${token_count} syntax=ok mode=${mode:-?} owner=${owner:-?}"
}

normalize_mode_for_compare() {
  local mode="${1:-}"
  while [[ -n "${mode}" && "${mode}" == 0* ]]; do
    mode="${mode#0}"
  done
  if [[ -z "${mode}" ]]; then
    mode="0"
  fi
  printf '%s' "${mode}"
}

finalize_generated_executable_shell_file() {
  local f="${1:?missing path}"
  local mode="${2:?missing mode}"
  local expected_mode=""
  local actual_mode=""
  local owner=""

  [[ -f "${f}" ]] || die "finalize_generated_executable_shell_file: file not found: ${f}"
  chmod "${mode}" "${f}" || die "Failed to set executable mode ${mode} on ${f} before finalize."
  finalize_generated_shell_file "${f}"
  chmod "${mode}" "${f}" || die "Failed to restore executable mode ${mode} on ${f} after finalize."

  expected_mode="$(normalize_mode_for_compare "${mode}")"
  if command -v stat >/dev/null 2>&1; then
    actual_mode="$(stat -c %a "${f}" 2>/dev/null || true)"
    owner="$(stat -c %u:%g "${f}" 2>/dev/null || true)"
    [[ "${actual_mode}" == "${expected_mode}" ]] || die "Executable shell artifact ended with unexpected mode for ${f}: ${actual_mode:-?} (expected ${expected_mode})."
  fi
  [[ -x "${f}" ]] || die "Executable shell artifact is not executable after finalize: ${f}"
  log "executable_ok: path=${f} mode=${actual_mode:-${expected_mode}} owner=${owner:-?}"
}

extract_self_heredoc_payload() {
  local delimiter="${1:?missing delimiter}"
  local out="${2:?missing output path}"
  local self="${BASH_SOURCE[0]:-${0}}"
  local start_single=""
  local start_double=""
  local start_plain=""

  [[ -f "${self}" ]] || die "extract_self_heredoc_payload: script source not found: ${self}"

  start_single="<<'${delimiter}'"
  start_double="<<\"${delimiter}\""
  start_plain="<<${delimiter}"

  if ! awk \
    -v start_single="${start_single}" \
    -v start_double="${start_double}" \
    -v start_plain="${start_plain}" \
    -v delimiter="${delimiter}" '
    index($0, start_single) || index($0, start_double) || index($0, start_plain) { found=1; next }
    found && $0 == delimiter { done=1; exit }
    found { print }
    END { if (!found || !done) exit 42 }
  ' "${self}" > "${out}"; then
    die "failed to extract heredoc payload from self: delimiter=${delimiter}"
  fi
}

resolve_runtime_dropbear_force_cmd() {
  if [[ -x /bin/penelope-cryptroot-unlock-wrapper ]]; then
    printf '%s\n' "/bin/penelope-cryptroot-unlock-wrapper"
  elif [[ -x /usr/bin/penelope-cryptroot-unlock-wrapper ]]; then
    printf '%s\n' "/usr/bin/penelope-cryptroot-unlock-wrapper"
  elif [[ -x /usr/bin/cryptroot-unlock ]]; then
    printf '%s\n' "/usr/bin/cryptroot-unlock"
  elif [[ -x /bin/cryptroot-unlock ]]; then
    printf '%s\n' "/bin/cryptroot-unlock"
  elif [[ -x /lib/cryptsetup/cryptroot-unlock ]]; then
    printf '%s\n' "/lib/cryptsetup/cryptroot-unlock"
  else
    die "managed-artifacts-only: no suitable cryptroot unlock command found"
  fi
}

validate_sshd_dropin_if_possible() {
  local path="${1:?missing path}"
  [[ -f "${path}" ]] || die "validate_sshd_dropin_if_possible: file not found: ${path}"

  if command -v sshd >/dev/null 2>&1; then
    if sshd -t >/dev/null 2>&1; then
      log "sshd config validation OK: ${path}"
    else
      die "sshd config validation failed after refresh: ${path}"
    fi
  else
    warn "sshd not available; skipping sshd config validation for ${path}"
  fi
}

render_managed_text_artifact_from_self() {
  local target="${1:?missing target}"
  local delimiter="${2:?missing delimiter}"
  local mode="${3:?missing mode}"
  local flavor="${4:?missing flavor}"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-install-tmp.XXXXXX")"

  extract_self_heredoc_payload "${delimiter}" "${tmp}"

  case "${flavor}" in
    stamped-text)
      stamp_install_version "${tmp}"
      validate_generated_file "${tmp}"
      ensure_no_unexpanded_tokens "${tmp}"
      ;;
    dropbear-conf)
      apply_placeholders "${tmp}"
      stamp_install_version "${tmp}"
      validate_generated_file "${tmp}"
      ensure_no_unexpanded_tokens "${tmp}"
      ;;
    *)
      rm -f "${tmp}"
      die "render_managed_text_artifact_from_self: unsupported flavor ${flavor}"
      ;;
  esac

  chmod "${mode}" "${tmp}"
  printf '%s\n' "${tmp}"
}

render_managed_shell_artifact_from_self() {
  local target="${1:?missing target}"
  local delimiter="${2:?missing delimiter}"
  local mode="${3:?missing mode}"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-install-tmp.XXXXXX")"

  extract_self_heredoc_payload "${delimiter}" "${tmp}"
  chmod "${mode}" "${tmp}"
  finalize_generated_executable_shell_file "${tmp}" "${mode}"
  printf '%s\n' "${tmp}"
}

publish_managed_candidate_file() {
  local target="${1:?missing target}"
  local candidate="${2:?missing candidate}"
  local mode="${3:?missing mode}"
  local validator="${4:-none}"
  local dir
  dir="$(dirname "${target}")"

  install -d -m 0755 "${dir}"

  if [[ -f "${target}" ]] && cmp -s "${candidate}" "${target}"; then
    log "managed-artifacts-only: unchanged ${target}"
    printf '%s\n' "unchanged"
  else
    install -o root -g root -m "${mode}" "${candidate}" "${target}"
    log "managed-artifacts-only: refreshed ${target}"
    case "${validator}" in
      sshd-dropin)
        validate_sshd_dropin_if_possible "${target}"
        ;;
      none)
        :
        ;;
      *)
        die "publish_managed_candidate_file: unsupported validator ${validator}"
        ;;
    esac
    printf '%s\n' "changed"
  fi
}

assert_plausible_managed_artifacts_target() {
  [[ -r /etc/os-release ]] || die "managed-artifacts-only mode requires /etc/os-release on the target system"
  [[ -d /lib/modules ]] || die "managed-artifacts-only mode requires /lib/modules on the target system"
  [[ -d /boot ]] || die "managed-artifacts-only mode requires /boot on the target system"
  [[ -d /etc/initramfs-tools ]] || die "managed-artifacts-only mode requires /etc/initramfs-tools on the target system"
  command -v update-initramfs >/dev/null 2>&1 || die "managed-artifacts-only mode requires update-initramfs"
  command -v lsinitramfs >/dev/null 2>&1 || die "managed-artifacts-only mode requires lsinitramfs"
  if [[ ! -r /etc/penelope/buildinfo && ! -r /usr/local/lib/penelope/common.sh ]]; then
    die "managed-artifacts-only mode requires an installed Penelope target context (/etc/penelope/buildinfo or /usr/local/lib/penelope/common.sh)"
  fi
}

persist_managed_artifacts_log_bundle() {
  local host="$1"
  local manifest_src="$2"
  persist_install_mode_log_bundle "managed-artifacts-only" "${host}" "${manifest_src}"
}

write_verify_layout_contract_manifest_or_die() {
  local manifest="$1"
  local normalized requires_fixed_layout contract_summary next_step_hint targets_csv recreate_targets preserve_targets
  local target target_disk target_roles target_partlabels target_size_contract target_partition_count
  local -a manifest_targets=()
  normalized="$(normalize_list "${RECREATION_TARGET_LIST}")"
  recreate_targets="$(recreated_role_targets_csv_or_none)"
  preserve_targets="$(preserved_role_targets_csv_or_none)"
  if profile_requires_fixed_layout_preserve_verification; then
    requires_fixed_layout="yes"
    contract_summary="$(layout_profile_fixed_layout_contract_description_or_die "${INSTALL_LAYOUT_PROFILE}")"
    next_step_hint="$(layout_profile_preserve_next_steps_or_die "${INSTALL_LAYOUT_PROFILE}")"
    mapfile -t manifest_targets < <(layout_profile_verification_targets_or_die "${INSTALL_LAYOUT_PROFILE}")
    targets_csv="$(IFS=,; echo "${manifest_targets[*]}")"
  else
    requires_fixed_layout="no"
    contract_summary="n/a"
    next_step_hint="n/a"
    targets_csv="none"
  fi
  {
    cat <<EOF_VERIFY_LAYOUT_MANIFEST
=== penelope verify-layout-contract manifest ===
mode=verify-layout-contract
version=${VERSION}
bootstrap_config_source=${INSTALL_BOOTSTRAP_CONFIG_FILE:-inline-shipped-placeholders}
layout_config_source=${INSTALL_LAYOUT_CONFIG_FILE:-inline-shipped-defaults}
target_host=${TARGET_HOST}
admin_user=${ADMIN_USER}
install_layout_profile=${INSTALL_LAYOUT_PROFILE}
recreation_target_list=${RECREATION_TARGET_LIST}
recreation_target_list_normalized=${normalized}
recreate_system=${RECREATE_SYSTEM}
recreate_home=${RECREATE_HOME}
recreate_archive=${RECREATE_ARCHIVE}
recreate_backup=${RECREATE_BACKUP}
requested_recreate_targets=${recreate_targets}
requested_preserve_targets=${preserve_targets}
fixed_layout_verification_required=${requires_fixed_layout}
fixed_layout_verification_targets=${targets_csv}
fixed_layout_contract_summary=${contract_summary}
fixed_layout_next_step_hint=${next_step_hint}
EOF_VERIFY_LAYOUT_MANIFEST
    if [[ ${#manifest_targets[@]} -gt 0 ]]; then
      for target in "${manifest_targets[@]}"; do
        target_disk="$(layout_profile_target_disk_or_die "${INSTALL_LAYOUT_PROFILE}" "${target}")"
        target_roles="$(layout_profile_target_roles_csv_or_die "${INSTALL_LAYOUT_PROFILE}" "${target}")"
        target_partlabels="$(layout_profile_target_expected_partlabels_csv_or_die "${INSTALL_LAYOUT_PROFILE}" "${target}")"
        target_size_contract="$(layout_profile_target_size_contract_summary_or_die "${INSTALL_LAYOUT_PROFILE}" "${target}")"
        target_partition_count="$(layout_profile_expected_partition_count_or_die "${INSTALL_LAYOUT_PROFILE}" "${target}")"
        echo "fixed_layout_target.${target}.disk=${target_disk}"
        echo "fixed_layout_target.${target}.roles=${target_roles}"
        echo "fixed_layout_target.${target}.expected_partition_count=${target_partition_count}"
        echo "fixed_layout_target.${target}.expected_partlabels=${target_partlabels}"
        echo "fixed_layout_target.${target}.size_contract=${target_size_contract}"
      done
    fi
  } >"${manifest}"
}

run_verify_layout_contract_mode() {
  local manifest runtime_host self_cmd bootstrap_q layout_q fixed_layout_status secret_gating_summary login_pw_followup next_command_header

  initialize_install_layout_for_full_install_or_die
  setup_logging

  self_cmd="${SELF_CMD}"
  bootstrap_q="$(penelope_quote_path_for_display "${INSTALL_BOOTSTRAP_CONFIG_FILE}")"
  layout_q="$(penelope_quote_path_for_display "${INSTALL_LAYOUT_CONFIG_FILE}")"

  echo "=== Penelope: verify-layout-contract starting (v${VERSION}) ==="
  log "Install operation mode: verify-layout-contract"
  log "verify-layout-contract inputs:"
  log "  bootstrap_config=${INSTALL_BOOTSTRAP_CONFIG_FILE}"
  log "  layout_config=${INSTALL_LAYOUT_CONFIG_FILE}"
  log "  TARGET_HOST=${TARGET_HOST} ADMIN_USER=${ADMIN_USER}"
  log "  INSTALL_LAYOUT_PROFILE=${INSTALL_LAYOUT_PROFILE} RECREATION_TARGET_LIST=${RECREATION_TARGET_LIST}"
  if [[ "${verify_layout_contract_master_password_required:-}" == "1" ]]; then
    secret_gating_summary="bootstrap identity validated; CRED_MASTER_PW required and validated; CRED_LOGIN_PW intentionally not required in verify mode"
    log "  verify secret gating: CRED_MASTER_PW required for preserved encrypted-role verification; CRED_LOGIN_PW intentionally not required"
  else
    secret_gating_summary="bootstrap identity validated; install-time secrets not required for this verify scope"
    log "  verify secret gating: no preserved encrypted-role verification requires CRED_MASTER_PW; CRED_LOGIN_PW intentionally not required"
  fi
  if [[ "${CRED_LOGIN_PW}" == "change-me" ]]; then
    login_pw_followup="  - edit ${bootstrap_q} and set CRED_LOGIN_PW before the real install"
    next_command_header="Next steps:"
  else
    login_pw_followup=""
    next_command_header="Next command:"
  fi

  init_recreation_policy
  verify_preserved_targets_or_die
  preflight_layout_snapshot
  print_install_plan

  runtime_host="${TARGET_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)}"
  manifest="$(mktemp "${TMPDIR:-/tmp}/penelope-install-verify-layout-contract.XXXXXX")"
  write_verify_layout_contract_manifest_or_die "${manifest}"
  persist_verify_layout_contract_log_bundle "${runtime_host}" "${manifest}"

  if profile_requires_fixed_layout_preserve_verification; then
    fixed_layout_status="required and passed"
    log "verify-layout-contract: fixed-layout verification was required and succeeded."
    log "verify-layout-contract contract: $(layout_profile_fixed_layout_contract_description_or_die "${INSTALL_LAYOUT_PROFILE}")"
    log "verify-layout-contract next step if drift is found in a later real run: $(layout_profile_preserve_next_steps_or_die "${INSTALL_LAYOUT_PROFILE}")"
  else
    fixed_layout_status="not required for the current recreation policy"
    log "verify-layout-contract: no preserved targets required fixed-layout verification for the current recreation policy."
  fi

  log "verify-layout-contract manifest (${manifest}):"
  sed 's/^/      /' "${manifest}" || true

  cat <<EOF_VERIFY_LAYOUT_DONE

[$(date +%H:%M:%S)] === verify-layout-contract completed (penelope-install ${VERSION}) ===
Verification checkpoints completed:
  - bootstrap config loaded from ${bootstrap_q}
  - ${secret_gating_summary}
  - layout config loaded from ${layout_q}
  - layout placeholders rejected and layout profile accepted: ${INSTALL_LAYOUT_PROFILE}
  - recreate/preserve policy accepted: ${RECREATION_TARGET_LIST}
  - fixed-layout verification: ${fixed_layout_status}
No destructive install step was executed.
Ready for destructive install only if:
  - the printed plan matches the intended disk mapping and recreate/preserve targets
  - ${TARGET_HOST} / ${ADMIN_USER} are the intended host and operator account
  - you reviewed the persisted manifest/log bundle under /var/log/${runtime_host}/install/
${login_pw_followup}
${next_command_header}
  sudo -E ${self_cmd} --bootstrap-config ${bootstrap_q} --layout-config ${layout_q}
EOF_VERIFY_LAYOUT_DONE

  rm -f "${manifest}"
}

run_managed_artifacts_only_mode() {
  local runtime_host
  local manifest tmp status
  local -a changed_paths=()
  local -a unchanged_paths=()
  local -a initramfs_changed_paths=()
  local -a rebuilt_initrds=()
  local -a kernels=()
  local kver initrd inventory_rc
  local dropbear_runtime_force_cmd=""

  require_root
  setup_logging
  runtime_host="$(current_runtime_host_for_logs)"

  echo "=== Penelope: managed-artifacts-only refresh starting (v${VERSION}) ==="
  log "FAST_ITERATION_MODE=1"
  log "Install operation mode: managed-artifacts-only"
  log "Runtime host for log persistence: ${runtime_host}"
  log "Allowed artifact classes: initramfs/dropbear subset, installer-owned ops tools, installer-owned firstboot/logcopy helpers, installer-owned sshd drop-in"
  log "Skipped planes: cleanup_previous_run, live dependency install, network probing," \
    "key generation, recreation-policy validation, disk unmount/wipe/partition," \
    "luksFormat/mkfs, mount_target, debootstrap, chroot provisioning," \
    "recovery-stage refresh"

  assert_plausible_managed_artifacts_target

  dropbear_runtime_force_cmd="$(resolve_runtime_dropbear_force_cmd)"
  DROPBEAR_FORCE_CMD="${dropbear_runtime_force_cmd}"
  export DROPBEAR_FORCE_CMD

  local candidate target delimiter mode flavor validator
  local -a artifact_specs=(
    "/etc/ssh/sshd_config.d/50-penelope-hardening.conf|EOF_SSHD_HARDENING|0644|text|stamped-text|sshd-dropin"
    "/usr/local/sbin/penelope-rotate-masterpw-dropbear.sh|ROT_EOF|0750|shell|-|none"
    "/usr/local/sbin/penelope-verify-security.sh|VERIFY_EOF|0750|shell|-|none"
    "/usr/local/sbin/${TARGET_HOST}-firstboot.sh|FB_EOF|0755|shell|-|none"
    "/usr/local/sbin/penelope-copy-initramfs-logs.sh|EOF_SCRIPT_COPY_INITRAMFS_LOGS|0755|shell|-|none"
    "/bin/penelope-cryptroot-unlock-wrapper|EOF_PENELOPE_CRYPTROOT_UNLOCK_WRAPPER|0755|shell|-|none"
    "/etc/dropbear/initramfs/dropbear.conf|DROP_EOF|0644|text|dropbear-conf|none"
    "/etc/initramfs-tools/scripts/init-premount/dropbear|EOF_INITPREMOUNT_DROPBEAR_OVERRIDE|0755|shell|-|none"
  )

  local spec kind
  for spec in "${artifact_specs[@]}"; do
    IFS='|' read -r target delimiter mode kind flavor validator <<< "${spec}"
    if [[ "${kind}" == "shell" ]]; then
      candidate="$(render_managed_shell_artifact_from_self "${target}" "${delimiter}" "${mode}")"
    else
      candidate="$(render_managed_text_artifact_from_self "${target}" "${delimiter}" "${mode}" "${flavor}")"
    fi

    status="$(publish_managed_candidate_file "${target}" "${candidate}" "${mode}" "${validator}")"
    rm -f "${candidate}"

    if [[ "${status}" == "changed" ]]; then
      changed_paths+=("${target}")
      case "${target}" in
        /bin/penelope-cryptroot-unlock-wrapper|/etc/dropbear/initramfs/dropbear.conf|/etc/initramfs-tools/scripts/init-premount/dropbear)
          initramfs_changed_paths+=("${target}")
          ;;
      esac
    else
      unchanged_paths+=("${target}")
    fi
  done

  if [[ ! -e /etc/dropbear-initramfs ]]; then
    if ln -s /etc/dropbear/initramfs /etc/dropbear-initramfs 2>/dev/null; then
      changed_paths+=("/etc/dropbear-initramfs -> /etc/dropbear/initramfs")
      log "managed-artifacts-only: created compatibility symlink /etc/dropbear-initramfs -> /etc/dropbear/initramfs"
    else
      warn "managed-artifacts-only: could not create compatibility symlink /etc/dropbear-initramfs"
    fi
  fi

  if ! PENELOPE_INITRAMFS_RISK_STRICT=1 scan_initramfs_for_unguarded_commands "/"; then
    die "managed-artifacts-only mode: initramfs risk scan failed"
  fi
  log "Managed-artifacts pre-build scan: initramfs risk check OK (0 findings)"

  if ((${#initramfs_changed_paths[@]} > 0)); then
    while IFS= read -r kver; do
      [[ -n "${kver}" ]] || continue
      kernels+=("${kver}")
    done < <(collect_initramfs_only_kernel_versions)

    log "managed-artifacts-only: rebuilding initramfs because initramfs-owned artifacts changed"
    log "update-initramfs command: update-initramfs -u -k ${INITRAMFS_ONLY_KVER}"
    if ! update-initramfs -u -k "${INITRAMFS_ONLY_KVER}"; then
      die "managed-artifacts-only mode: update-initramfs failed"
    fi
    log "update-initramfs exit code: 0"

    for kver in "${kernels[@]}"; do
      initrd="/boot/initrd.img-${kver}"
      if [[ -f "${initrd}" ]]; then
        rebuilt_initrds+=("${initrd}")
      else
        warn "managed-artifacts-only mode: expected initrd missing after update-initramfs: ${initrd}"
      fi
    done
  else
    log "managed-artifacts-only: no initramfs-owned artifact changed; update-initramfs skipped"
  fi

  manifest="$(mktemp "${TMPDIR:-/tmp}/penelope-install-manifest.XXXXXX")"
  {
    echo "=== penelope managed-artifacts-only manifest ==="
    echo "version=${VERSION}"
    echo "mode=managed-artifacts-only"
    echo "runtime_host=${runtime_host}"
    echo "kver_request=${INITRAMFS_ONLY_KVER}"
    echo "dropbear_force_cmd=${DROPBEAR_FORCE_CMD}"
    echo "changed_paths:"
    if ((${#changed_paths[@]} == 0)); then
      echo "  - <none>"
    else
      for target in "${changed_paths[@]}"; do
        echo "  - ${target}"
      done
    fi
    echo "unchanged_paths:"
    if ((${#unchanged_paths[@]} == 0)); then
      echo "  - <none>"
    else
      for target in "${unchanged_paths[@]}"; do
        echo "  - ${target}"
      done
    fi
    echo "initramfs_rebuilt_paths:"
    if ((${#rebuilt_initrds[@]} == 0)); then
      echo "  - <none>"
    else
      for initrd in "${rebuilt_initrds[@]}"; do
        echo "  - ${initrd}"
      done
    fi
  } > "${manifest}"

  for initrd in "${rebuilt_initrds[@]}"; do
    echo "## lsinitramfs inventory (${initrd})" >> "${manifest}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-install-tmp.XXXXXX")"
    if lsinitramfs "${initrd}" > "${tmp}" 2>/dev/null; then
      grep -E 'dropbear|authorized_keys|cryptroot-unlock|penelope-' "${tmp}" >> "${manifest}" || true
    else
      inventory_rc=$?
      rm -f "${tmp}"
      die "managed-artifacts-only mode: lsinitramfs failed for ${initrd} (rc=${inventory_rc})"
    fi
    rm -f "${tmp}"
  done

  log "Managed-artifacts-only manifest (${manifest}):"
  sed 's/^/      /' "${manifest}" || true
  persist_managed_artifacts_log_bundle "${runtime_host}" "${manifest}"
  rm -f "${manifest}"

  cat <<EOF_MANAGED_ARTIFACTS_DONE

[$(date +%H:%M:%S)] === Managed-artifacts-only refresh completed (penelope-install ${VERSION}) ===
Changed:
$(if ((${#changed_paths[@]} == 0)); then printf '  - <none>\n'; else printf '  - %s\n' "${changed_paths[@]}"; fi)
Unchanged:
$(if ((${#unchanged_paths[@]} == 0)); then printf '  - <none>\n'; else printf '  - %s\n' "${unchanged_paths[@]}"; fi)
Rebuilt initrds:
$(if ((${#rebuilt_initrds[@]} == 0)); then printf '  - <none>\n'; else printf '  - %s\n' "${rebuilt_initrds[@]}"; fi)

This mode skipped all destructive install planes. Reload/restart individual services separately if the refreshed artifact class requires it.
EOF_MANAGED_ARTIFACTS_DONE
}

run_initramfs_only_mode() {
  local runtime_host
  local -a kernels=()
  local -a updated_paths=()
  local manifest tmp_list kver initrd inventory_rc

  require_root
  setup_logging
  runtime_host="$(current_runtime_host_for_logs)"

  echo "=== Penelope: initramfs-only refresh starting (v${VERSION}) ==="
  log "FAST_ITERATION_MODE=1"
  log "Install operation mode: initramfs-only"
  log "Runtime host for log persistence: ${runtime_host}"
  log "Skipped planes: cleanup_previous_run, live dependency install, network probing," \
    "key generation, recreation-policy validation, disk unmount/wipe/partition," \
    "luksFormat/mkfs, mount_target, debootstrap, chroot provisioning," \
    "recovery-stage refresh"

  assert_plausible_initramfs_only_target

  if [[ -f /etc/dropbear/initramfs/dropbear.conf ]]; then
    log "Initramfs-only precheck: /etc/dropbear/initramfs/dropbear.conf present"
  else
    warn "Initramfs-only precheck: /etc/dropbear/initramfs/dropbear.conf missing"
  fi

  if [[ -f /etc/dropbear/initramfs/authorized_keys ]]; then
    log "Initramfs-only precheck: /etc/dropbear/initramfs/authorized_keys present"
  else
    warn "Initramfs-only precheck: /etc/dropbear/initramfs/authorized_keys missing"
  fi

  while IFS= read -r kver; do
    [[ -n "${kver}" ]] || continue
    kernels+=("${kver}")
  done < <(collect_initramfs_only_kernel_versions)

  log "Kernel inventory (/lib/modules):"
  for kver in "${kernels[@]}"; do
    log "  - ${kver}"
  done

  if ! PENELOPE_INITRAMFS_RISK_STRICT=1 scan_initramfs_for_unguarded_commands "/"; then
    die "initramfs-only mode: initramfs risk scan failed"
  fi
  log "Initramfs-only pre-build scan: initramfs risk check OK (0 findings)"

  log "update-initramfs command: update-initramfs -u -k ${INITRAMFS_ONLY_KVER}"
  if ! update-initramfs -u -k "${INITRAMFS_ONLY_KVER}"; then
    die "initramfs-only mode: update-initramfs failed"
  fi
  log "update-initramfs exit code: 0"

  manifest="$(mktemp "${TMPDIR:-/tmp}/penelope-install-manifest.XXXXXX")"
  {
    echo "=== penelope initramfs-only manifest ==="
    echo "version=${VERSION}"
    echo "mode=initramfs-only"
    echo "runtime_host=${runtime_host}"
    echo "kver_request=${INITRAMFS_ONLY_KVER}"
    echo "updated_paths:"
  } >"${manifest}"

  for kver in "${kernels[@]}"; do
    initrd="/boot/initrd.img-${kver}"
    if [[ -f "${initrd}" ]]; then
      updated_paths+=("${initrd}")
      echo "  - ${initrd}" >>"${manifest}"
      echo "## lsinitramfs inventory (${initrd})" >>"${manifest}"
      tmp_list="$(mktemp "${TMPDIR:-/tmp}/penelope-initrd-list.XXXXXX")"
      if lsinitramfs "${initrd}" >"${tmp_list}" 2>/dev/null; then
        grep -E 'dropbear|authorized_keys|cryptroot-unlock|penelope-' "${tmp_list}" >>"${manifest}" || true
      else
        inventory_rc=$?
        rm -f "${tmp_list}"
        die "initramfs-only mode: lsinitramfs failed for ${initrd} (rc=${inventory_rc})"
      fi
      rm -f "${tmp_list}"
    else
      warn "initramfs-only mode: expected initrd missing after update-initramfs: ${initrd}"
      echo "  - MISSING ${initrd}" >>"${manifest}"
    fi
  done

  if ((${#updated_paths[@]} == 0)); then
    rm -f "${manifest}"
    die "initramfs-only mode: no initrd images were found after rebuild"
  fi

  log "Initramfs-only updated paths:"
  for initrd in "${updated_paths[@]}"; do
    log "  - ${initrd}"
  done

  log "Initramfs-only manifest (${manifest}):"
  sed 's/^/      /' "${manifest}" || true
  persist_initramfs_only_log_bundle "${runtime_host}" "${manifest}"
  rm -f "${manifest}"

  cat <<EOF_INITRAMFS_ONLY_DONE

[$(date +%H:%M:%S)] === Initramfs-only refresh completed (penelope-install ${VERSION}) ===
Rebuilt kernels:
$(printf '  - %s
' "${updated_paths[@]}")

This mode skipped all destructive install planes. Reboot the system to use the refreshed initramfs.
EOF_INITRAMFS_ONLY_DONE
}

main() {
  if [[ "${INSTALL_OPERATION_MODE}" == "write-bootstrap-config-template" ]]; then
    write_install_bootstrap_config_template_or_die "${INSTALL_BOOTSTRAP_TEMPLATE_OUTPUT}"
    return 0
  fi

  if [[ "${INSTALL_OPERATION_MODE}" == "write-layout-config-template" ]]; then
    write_install_layout_config_template_or_die "${INSTALL_LAYOUT_TEMPLATE_OUTPUT}"
    return 0
  fi

  if [[ "${INSTALL_OPERATION_MODE}" == "audit-config-evolution" ]]; then
    run_install_config_evolution_audit_mode
    return 0
  fi

  initialize_install_bootstrap_context_or_die
  require_root "${SELF_CMD}"

  if [[ "${INSTALL_OPERATION_MODE}" == "initramfs-only" ]]; then
    run_initramfs_only_mode
    return 0
  fi

  if [[ "${INSTALL_OPERATION_MODE}" == "managed-artifacts-only" ]]; then
    run_managed_artifacts_only_mode
    return 0
  fi

  initialize_install_layout_for_full_install_or_die
  validate_required_operator_edited_secrets

  if [[ "${INSTALL_OPERATION_MODE}" == "verify-layout-contract" ]]; then
    run_verify_layout_contract_mode
    return 0
  fi

  setup_logging
  echo "=== Penelope: fully automated installation starting - do not interrupt! (v${VERSION}) ==="

  initialize_apt_mirror_selection
  cleanup_previous_run
  install_live_deps
  preflight_anydesk_external_repository_or_die
  detect_live_network
  generate_keypair_and_7z
  init_recreation_policy
  verify_preserved_targets_or_die
  preflight_layout_snapshot
  print_install_plan
  confirm_plan_or_exit
  unmount_target_devices_best_effort
  wipe_and_partition
  setup_luks_and_fs
  mount_target
  do_debootstrap
  stage_anydesk_gpg_key_into_target
  bind_mounts_for_chroot
  collect_uuids
  stage_keys_into_target
  stage_common_lib_into_target
  configure_in_chroot
  post_install_token_scan
  post_install_initramfs_risk_scan
  persist_sanitized_recovery_stage
  # Persist installer log into target system (for analysis after reboot)
  persist_install_log
  cleanup_live_key_material
  final_message
}

main "$@"
