#!/usr/bin/env bash
# penelope-samba-setup
#
# Usage:
#   sudo -E ./${0##*/} write-config [--config-dir DIR]
#   sudo -E ./${0##*/} [--config-dir DIR] verify-config
#   sudo -E ./${0##*/} [--config-dir DIR] apply
#   ./${0##*/} [--config-dir DIR] list-users
#   ./${0##*/} [--config-dir DIR] list-shares
#   ./${0##*/} [--config-dir DIR] show-user USER
#   ./${0##*/} [--config-dir DIR] show-share SHARE
#   sudo -E ./${0##*/} [--config-dir DIR] add-user USER [--purpose client|service|admin] [--default-access yes|no] [--private-home yes|no] [--private-archive yes|no] [--path PATH] [--share SHARE]
#     [--mode ro|rw] (--password-file FILE | --password-stdin)
#   sudo -E ./${0##*/} [--config-dir DIR] disable-user USER
#   sudo -E ./${0##*/} [--config-dir DIR] remove-user USER
#   sudo -E ./${0##*/} [--config-dir DIR] enable-user USER
#   sudo -E ./${0##*/} [--config-dir DIR] add-share SHARE --user USER --path PATH [--mode ro|rw]
#   sudo -E ./${0##*/} [--config-dir DIR] remove-share SHARE
#   sudo -E ./${0##*/} [--config-dir DIR] disable-share SHARE
#   sudo -E ./${0##*/} [--config-dir DIR] enable-share SHARE
#   sudo -E ./${0##*/} [--config-dir DIR] set-password USER (--password-file FILE | --password-stdin)
#
# This setup script provisions local non-login users, Samba users, directories,
# and managed shares for a Penelope system. It can inspect the declared managed
# Samba model read-only, and it can perform targeted Day-2 config mutations on
# the external config tree (default: /etc/penelope/samba-setup) before applying the
# resulting state onto the running host.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/penelope-common.sh"

export TZ="${TZ:-Europe/Berlin}"

if (( BASH_VERSINFO[0] < 4 )); then
  >&2 echo "ERROR: Bash 4.0 or higher required"
  exit 1
fi

readonly VERSION="0.1.150"
readonly PROJECT="penelope"
readonly CONFIG_SCHEMA_VERSION_CURRENT="4"

penelope_bundle_startup \
  "penelope-samba-setup" "${VERSION}" "${SCRIPT_DIR}/penelope-common.sh" \
  "${BASH_SOURCE[0]:-}" "source preflight scan failed" \
  warn \
  log \
  have \
  require_root \
  require_cmd \
  require_cmd_many \
  ensure_dir \
  ensure_file \
  apt_install \
  validate_secret_not_placeholder \
  read_kv_value_from_file \
  read_kv_value_from_file_or_default \
  penelope_log_trap_error \
  penelope_refresh_installed_common_lib \
  penelope_signal_exit_code_for_name

SELF_CMD="$(penelope_resolved_script_invocation_for_display "penelope-samba-setup.sh" "${0:-${BASH_SOURCE[0]:-penelope-samba-setup.sh}}")"
readonly SELF_CMD


samba_setup_on_err() {
  local line="${1:-?}"
  local cmd="${2:-<unknown>}"
  local ec="${3:-1}"
  penelope_log_trap_error "${ec}" "${line}" "${cmd}" 320
  exit "${ec}"
}

samba_setup_on_signal() {
  local sig="${1:?signal required}"
  local ec=""
  ec="$(penelope_signal_exit_code_for_name "${sig}")"
  warn "Received ${sig}; aborting penelope-samba-setup."
  exit "${ec}"
}

trap 'samba_setup_on_err ${LINENO} "${BASH_COMMAND}" $?' ERR
trap 'samba_setup_on_signal INT' INT
trap 'samba_setup_on_signal TERM' TERM

# ================== INIT TEMPLATE CONFIGURATION ==================
# FIRST EDIT SECTION:
# This inline block is no longer the live operator source of truth.
# 'write-config' uses it only to seed the external config directory with the
# shipped default managed-user/share model and placeholder secrets.
# Normal inspect/verify/apply commands load their state from config files
# (default: /etc/penelope/samba-setup) and do not read this block as live config.
# Typical init-template contents:
#   - change CRED_BACKUP_DASHBOARD_PASSWORD (if dashboard export is enabled)
#   - add/remove entries in CRED_SAMBA_ARCHIVE_USERS
#   - add/remove entries in CRED_MANAGED_SAMBA_SHARES
#   - enable/disable ENABLE_BACKUP_DASHBOARD_SHARE
#   - add/remove entries in SAMBA_EXTRA_SHARES
#
# The values below preserve the shipped defaults so 'write-config' can materialize
# a first editable config/secrets tree. Afterwards the live source of truth is the
# external config directory; remove a share there and rerun the setup to remove it
# from the managed Samba config. This does not delete users, directories, or data
# automatically.
#
# Standard client users:
#   Format: "username:password"
#   Result: Linux non-login user + Samba user with access to the shared Penelope work shares.
#   These users do not get a private archive share by default.
#   Placeholder passwords like "change-me" are rejected.
CRED_SAMBA_CLIENT_USERS=(
  "penelope_client:change-me"
)

# Scanner/printer service users:
#   Format: "username:password"
#   Result: Linux non-login user + Samba user for devices that write into the shared scan inbox.
#   These users do not get access to rawin/internal/backup_dashboard by default.
#   Placeholder passwords like "change-me" are rejected.
CRED_SAMBA_SERVICE_USERS=(
  "scan:change-me"
)

# Archive users (shorthand):
#   Format: "username:password"
#   Result: Linux non-login user + Samba user, canonical archive path /_archive/<username>,
#           and the shipped default private share name archive_<username> (rw).
#   Shipped archive-user templates keep default_access=yes as the Windows-friendly
#   combined workstation/archive role. Operators may set default_access=no in the
#   generated users.d/<user>.conf when the archive credential should remain archive-only.
#   Placeholder passwords like "change-me" are rejected.
CRED_SAMBA_ARCHIVE_USERS=(
  "p001:change-me"
  "p002:change-me"
)

# Custom managed primary shares are intentionally not part of the shipped default model.
# Day-2 custom shares should be declared in shares.d/ after write-config.
CRED_MANAGED_SAMBA_SHARES=(
)

# Internal shared resource:
#   The fixed name "internal" is reserved for the built-in SMB share at /home/internal.
#   It is not a login-capable Samba principal and has no secret file; normal clients
#   reach this share through default_access=yes membership in the standard client group.
INTERNAL_USER="internal"

# Dedicated readonly Backup-Dashboard export user:
#   Username is fixed to "backup_dashboard" in this release.
#   It remains available as a technical account, but normal clients read the dashboard
#   through their own Penelope Samba identity.
#   Placeholder passwords like "change-me" are rejected when the dashboard export is enabled.
BACKUP_DASHBOARD_EXPORT_USER="backup_dashboard"
CRED_BACKUP_DASHBOARD_PASSWORD="change-me"

# Optional canonical Backup-Dashboard export:
#   1: render the fixed readonly Samba share backup_dashboard for BACKUP_DASHBOARD_EXPORT_USER
#      using the exact effective BACKUP_DASHBOARD_DIR from /etc/penelope/backup.conf
#   0: do not render the dedicated Backup-Dashboard export
#   The Backup-Dashboard export is a dedicated special case, not a general SAMBA_EXTRA_SHARES entry.
ENABLE_BACKUP_DASHBOARD_SHARE="1"

# Extra shares (secondary declaration surface):
#   Format: "path:share:user:mode"
#   path: absolute, no dot-segments, no duplicate aliases like /path/ vs /path
#   mode: ro | rw
#   user: a declared managed Samba user; fixed built-in share names are not principals
#   Extra shares do not provision additional users implicitly.
#   The canonical Backup-Dashboard tree is reserved for the dedicated backup_dashboard export
#   and must not be configured here.
#   Keep this list short and easy to scan.
SAMBA_EXTRA_SHARES=(
  # "/home/internal/scanner:scanner:internal:rw"
)

# Extra share auto-create policy:
#   ro: default publish-tree ownership/mode for missing readonly paths
#   rw: directory mode for missing read-write paths; owner/group always use share user
#       Samba write masks for rw shares are derived from this mode:
#         create mask    = RW_EXTRA_SHARE_CREATE_MODE & 0666
#         directory mask = RW_EXTRA_SHARE_CREATE_MODE
RO_EXTRA_SHARE_CREATE_OWNER="root"
RO_EXTRA_SHARE_CREATE_GROUP="root"
RO_EXTRA_SHARE_CREATE_MODE="0755"
RW_EXTRA_SHARE_CREATE_MODE="0700"


# -------------------- init seeds and config paths --------------------
declare -ar SEED_CRED_SAMBA_CLIENT_USERS=("${CRED_SAMBA_CLIENT_USERS[@]}")
declare -ar SEED_CRED_SAMBA_SERVICE_USERS=("${CRED_SAMBA_SERVICE_USERS[@]}")
declare -ar SEED_CRED_SAMBA_ARCHIVE_USERS=("${CRED_SAMBA_ARCHIVE_USERS[@]}")
declare -ar SEED_CRED_MANAGED_SAMBA_SHARES=("${CRED_MANAGED_SAMBA_SHARES[@]}")
readonly SEED_INTERNAL_USER="${INTERNAL_USER}"
readonly SEED_BACKUP_DASHBOARD_EXPORT_USER="${BACKUP_DASHBOARD_EXPORT_USER}"
readonly SEED_CRED_BACKUP_DASHBOARD_PASSWORD="${CRED_BACKUP_DASHBOARD_PASSWORD}"
readonly SEED_ENABLE_BACKUP_DASHBOARD_SHARE="${ENABLE_BACKUP_DASHBOARD_SHARE}"
readonly SEED_RO_EXTRA_SHARE_CREATE_OWNER="${RO_EXTRA_SHARE_CREATE_OWNER}"
readonly SEED_RO_EXTRA_SHARE_CREATE_GROUP="${RO_EXTRA_SHARE_CREATE_GROUP}"
readonly SEED_RO_EXTRA_SHARE_CREATE_MODE="${RO_EXTRA_SHARE_CREATE_MODE}"
readonly SEED_RW_EXTRA_SHARE_CREATE_MODE="${RW_EXTRA_SHARE_CREATE_MODE}"

readonly DEFAULT_OPERATOR_CONFIG_DIR="/etc/penelope/samba-setup"
OPERATOR_CONFIG_DIR="${DEFAULT_OPERATOR_CONFIG_DIR}"
OPERATOR_CONFIG_FILE=""
OPERATOR_USERS_DIR=""
OPERATOR_SHARES_DIR=""
OPERATOR_SECRETS_DIR=""
OPERATOR_EXAMPLES_DIR=""
OPERATOR_EXAMPLE_CONFIG_FILE=""
OPERATOR_EXAMPLE_USERS_DIR=""
OPERATOR_EXAMPLE_SHARES_DIR=""
OPERATOR_EXAMPLE_SECRETS_DIR=""
OPERATOR_CONFIG_SCHEMA_VERSION="${CONFIG_SCHEMA_VERSION_CURRENT}"

update_operator_config_paths() {
  OPERATOR_CONFIG_FILE="${OPERATOR_CONFIG_DIR}/samba-setup.conf"
  OPERATOR_USERS_DIR="${OPERATOR_CONFIG_DIR}/users.d"
  OPERATOR_SHARES_DIR="${OPERATOR_CONFIG_DIR}/shares.d"
  OPERATOR_SECRETS_DIR="${OPERATOR_CONFIG_DIR}/secrets.d"
  OPERATOR_EXAMPLES_DIR="${OPERATOR_CONFIG_DIR}/examples"
  OPERATOR_EXAMPLE_CONFIG_FILE="${OPERATOR_EXAMPLES_DIR}/samba-setup.conf.example"
  OPERATOR_EXAMPLE_USERS_DIR="${OPERATOR_EXAMPLES_DIR}/users.d"
  OPERATOR_EXAMPLE_SHARES_DIR="${OPERATOR_EXAMPLES_DIR}/shares.d"
  OPERATOR_EXAMPLE_SECRETS_DIR="${OPERATOR_EXAMPLES_DIR}/secrets.d"
}

update_operator_config_paths



main_config_default_line() {
  local key="${1:?key required}"
  case "${key}" in
    config_schema_version) printf 'config_schema_version=%s\n' "${CONFIG_SCHEMA_VERSION_CURRENT}" ;;
    enable_backup_dashboard_share) printf 'enable_backup_dashboard_share=%s\n' "${SEED_ENABLE_BACKUP_DASHBOARD_SHARE}" ;;
    standard_client_group) printf 'standard_client_group=%s\n' "${SEED_STANDARD_CLIENT_GROUP}" ;;
    scan_inbox_group) printf 'scan_inbox_group=%s\n' "${SEED_SCAN_INBOX_GROUP}" ;;
    shared_work_dir_mode) printf 'shared_work_dir_mode=%s\n' "${SEED_SHARED_WORK_DIR_MODE}" ;;
    shared_work_create_mask) printf 'shared_work_create_mask=%s\n' "${SEED_SHARED_WORK_CREATE_MASK}" ;;
    shared_work_directory_mask) printf 'shared_work_directory_mask=%s\n' "${SEED_SHARED_WORK_DIRECTORY_MASK}" ;;
    ro_extra_share_create_owner) printf 'ro_extra_share_create_owner=%s\n' "${SEED_RO_EXTRA_SHARE_CREATE_OWNER}" ;;
    ro_extra_share_create_group) printf 'ro_extra_share_create_group=%s\n' "${SEED_RO_EXTRA_SHARE_CREATE_GROUP}" ;;
    ro_extra_share_create_mode) printf 'ro_extra_share_create_mode=%s\n' "${SEED_RO_EXTRA_SHARE_CREATE_MODE}" ;;
    rw_extra_share_create_mode) printf 'rw_extra_share_create_mode=%s\n' "${SEED_RW_EXTRA_SHARE_CREATE_MODE}" ;;
    smb_server_min_protocol) printf 'smb_server_min_protocol=%s\n' "${SEED_SMB_SERVER_MIN_PROTOCOL}" ;;
    smb_client_min_protocol) printf 'smb_client_min_protocol=%s\n' "${SEED_SMB_CLIENT_MIN_PROTOCOL}" ;;
    smb_ntlm_auth) printf 'smb_ntlm_auth=%s\n' "${SEED_SMB_NTLM_AUTH}" ;;
    *) die "Internal error: unsupported Samba setup config default key: ${key}" ;;
  esac
}


merge_main_config_defaults() {
  local -a keys=(
    config_schema_version
    enable_backup_dashboard_share
    standard_client_group
    scan_inbox_group
    shared_work_dir_mode
    shared_work_create_mask
    shared_work_directory_mask
    ro_extra_share_create_owner
    ro_extra_share_create_group
    ro_extra_share_create_mode
    rw_extra_share_create_mode
    smb_server_min_protocol
    smb_client_min_protocol
    smb_ntlm_auth
  )
  local -a missing=()
  local key

  [[ -f "${OPERATOR_CONFIG_FILE}" ]] || return 0

  reset_operator_model_from_config_defaults
  load_main_config_file
  validate_operator_config_schema_version

  for key in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${OPERATOR_CONFIG_FILE}"; then
      missing+=("${key}")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log "Samba setup config exists: ${OPERATOR_CONFIG_FILE} (no missing keys)"
    return 0
  fi

  log "Samba setup config exists: ${OPERATOR_CONFIG_FILE} (adding missing keys: ${missing[*]})"
  {
    echo
    for key in "${missing[@]}"; do
      main_config_default_line "${key}"
    done
  } >> "${OPERATOR_CONFIG_FILE}"
  chown root:root "${OPERATOR_CONFIG_FILE}" || die "Failed to chown ${OPERATOR_CONFIG_FILE}"
  chmod 0644 "${OPERATOR_CONFIG_FILE}" || die "Failed to chmod ${OPERATOR_CONFIG_FILE}"

  reset_operator_model_from_config_defaults
  load_main_config_file
  validate_operator_config_schema_version
}

OPERATOR_DECLARED_USERS=()
OPERATOR_DECLARED_PRIMARY_SHARES=()
declare -A OPERATOR_USER_DEFAULT_ACCESS=()
declare -A OPERATOR_USER_PRIVATE_HOME=()
declare -A OPERATOR_USER_PRIVATE_ARCHIVE=()
declare -A OPERATOR_USER_HOME_PATH=()
declare -A OPERATOR_USER_HOME_SHARE=()
declare -A OPERATOR_USER_ARCHIVE_PATH=()
declare -A OPERATOR_USER_ARCHIVE_SHARE=()
declare -A OPERATOR_USER_EXTRA_GROUPS=()
declare -A SHARE_ALLOWED_USERS=()
declare -A SHARE_ALLOWED_GROUPS=()
declare -A SHARE_FORCE_GROUP=()

# -------------------- managed paths --------------------
readonly SAMBA_CONF_DIR="/etc/samba"
readonly SAMBA_DROPIN_DIR="${SAMBA_CONF_DIR}/smb.conf.d"
readonly SAMBA_MAIN_CONF="${SAMBA_CONF_DIR}/smb.conf"
readonly SAMBA_MANAGED_CONF="${SAMBA_DROPIN_DIR}/penelope-shares.conf"
readonly SAMBA_INCLUDE_LINE="include = ${SAMBA_MANAGED_CONF}"
readonly ARCHIVE_ROOT="/_archive"
readonly BACKUP_CONF="/etc/${PROJECT}/backup.conf"
readonly DEFAULT_CANONICAL_BACKUP_DASHBOARD_DIR="/var/lib/penelope/backup-dashboard"
readonly CANONICAL_BACKUP_DASHBOARD_SHARE_NAME="backup_dashboard"
readonly INTERNAL_HOME="/home/internal"
readonly BACKUP_DASHBOARD_EXPORT_ACCOUNT_HOME="/nonexistent"
readonly NONLOGIN_SHELL="/usr/sbin/nologin"
readonly INTERNAL_HOME_SHARE_NAME="internal"
readonly SHARED_RAWIN_SHARE_NAME="rawin"
readonly SHARED_RAWIN_DIR="/home/rawin"
readonly SHARED_SCAN_SHARE_NAME="scan"
readonly SHARED_SCAN_DIR="/home/scan"
SEED_STANDARD_CLIENT_GROUP="penelope_clients"
SEED_SCAN_INBOX_GROUP="penelope_scan_clients"
SEED_SHARED_WORK_DIR_MODE="2770"
SEED_SHARED_WORK_CREATE_MASK="0660"
SEED_SHARED_WORK_DIRECTORY_MASK="0770"
SEED_SMB_SERVER_MIN_PROTOCOL="SMB3_00"
SEED_SMB_CLIENT_MIN_PROTOCOL="SMB3_00"
SEED_SMB_NTLM_AUTH="ntlmv2-only"
STANDARD_CLIENT_GROUP="${SEED_STANDARD_CLIENT_GROUP}"
SCAN_INBOX_GROUP="${SEED_SCAN_INBOX_GROUP}"
SHARED_WORK_DIR_MODE="${SEED_SHARED_WORK_DIR_MODE}"
SHARED_WORK_CREATE_MASK="${SEED_SHARED_WORK_CREATE_MASK}"
SHARED_WORK_DIRECTORY_MASK="${SEED_SHARED_WORK_DIRECTORY_MASK}"
SMB_SERVER_MIN_PROTOCOL="${SEED_SMB_SERVER_MIN_PROTOCOL}"
SMB_CLIENT_MIN_PROTOCOL="${SEED_SMB_CLIENT_MIN_PROTOCOL}"
SMB_NTLM_AUTH="${SEED_SMB_NTLM_AUTH}"
readonly OPERATOR_USER="${SUDO_USER:-$(id -un)}"
CANONICAL_BACKUP_DASHBOARD_DIR=""
CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE="default"

backup_dashboard_export_requested() {
  [[ "$ENABLE_BACKUP_DASHBOARD_SHARE" == "1" ]]
}

set_default_backup_dashboard_dir_for_inspect() {
  local reason="${1:?reason required}"
  local resolved=""

  resolved="$(normalize_share_path "${DEFAULT_CANONICAL_BACKUP_DASHBOARD_DIR}")"
  warn "Inspecting with default Backup-Dashboard path ${resolved} because ${reason}"
  CANONICAL_BACKUP_DASHBOARD_DIR="${resolved}"
  CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE="default"
}

resolve_canonical_backup_dashboard_dir() {
  local mode="${1:-strict}"
  local resolved=""
  local configured=""
  local require_existing_dir=1

  case "${mode}" in
    strict|inspect)
      ;;
    *)
      die "Unsupported Backup-Dashboard resolution mode: ${mode}"
      ;;
  esac

  if [[ "${mode}" == "inspect" ]]; then
    require_existing_dir=0
  fi

  if backup_dashboard_export_requested; then
    if [[ -e "${BACKUP_CONF}" && ! -f "${BACKUP_CONF}" ]]; then
      if [[ "${mode}" == "strict" ]]; then
        die "${BACKUP_CONF} exists but is not a regular file"
      fi
      set_default_backup_dashboard_dir_for_inspect "${BACKUP_CONF} is not a regular file"
      return 0
    fi

    if [[ -f "${BACKUP_CONF}" && ! -r "${BACKUP_CONF}" ]]; then
      if [[ "${mode}" == "strict" ]]; then
        die "${BACKUP_CONF} exists but is not readable"
      fi
      set_default_backup_dashboard_dir_for_inspect \
        "${BACKUP_CONF} is not readable by the current user; run with sudo to inspect a non-default path"
      return 0
    fi

    if [[ -f "${BACKUP_CONF}" ]]; then
      resolved="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
      if [[ -n "${resolved}" ]] && [[ "${resolved}" != *"___PENELOPE_"* ]]; then
        resolved="$(normalize_share_path "${resolved}")"
        if (( require_existing_dir )) && [[ ! -d "${resolved}" ]]; then
          die "${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} export requires existing on-disk directory: ${resolved}"
        fi
        log "Canonical Backup-Dashboard path from ${BACKUP_CONF}: ${resolved}"
        CANONICAL_BACKUP_DASHBOARD_DIR="${resolved}"
        CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE="backup.conf"
        return 0
      fi

      if [[ "${mode}" == "strict" ]]; then
        die "${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} export requires a concrete BACKUP_DASHBOARD_DIR in ${BACKUP_CONF}"
      fi
    elif [[ "${mode}" == "strict" ]]; then
      die "${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} export requires existing ${BACKUP_CONF} with BACKUP_DASHBOARD_DIR set by penelope-backup-setup"
    fi

    if [[ "${mode}" == "inspect" ]]; then
      if [[ -f "${BACKUP_CONF}" ]]; then
        set_default_backup_dashboard_dir_for_inspect "${BACKUP_CONF} has no concrete BACKUP_DASHBOARD_DIR yet"
      else
        set_default_backup_dashboard_dir_for_inspect "${BACKUP_CONF} is not present yet"
      fi
      return 0
    fi
  fi

  if [[ -f "${BACKUP_CONF}" && -r "${BACKUP_CONF}" ]]; then
    configured="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
  fi
  if [[ -n "${configured}" ]] && [[ "${configured}" != *"___PENELOPE_"* ]]; then
    resolved="$(normalize_share_path "${configured}")"
    log "Canonical Backup-Dashboard path from ${BACKUP_CONF}: ${resolved}"
    CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE="backup.conf"
  else
    resolved="$(normalize_share_path "${DEFAULT_CANONICAL_BACKUP_DASHBOARD_DIR}")"
    if [[ -f "${BACKUP_CONF}" && -r "${BACKUP_CONF}" ]]; then
      log "Canonical Backup-Dashboard path defaulted to ${resolved} (missing concrete BACKUP_DASHBOARD_DIR in ${BACKUP_CONF})"
    fi
    CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE="default"
  fi

  CANONICAL_BACKUP_DASHBOARD_DIR="${resolved}"
}



persist_sanitized_recovery_stage() {
  local src="${BASH_SOURCE[0]}"
  local stage_dir="${PENELOPE_RECOVERY_STAGE_DIR}"
  local tmp="${stage_dir}/penelope-samba-setup.sh.tmp.$$"
  local dest="${stage_dir}/penelope-samba-setup.sh"
  local line entry user rest

  trap '[[ -n "${tmp:-}" && -e "${tmp:-}" ]] && rm -f "${tmp:-}"' RETURN

  penelope_ensure_recovery_stage_dir "${stage_dir}"
  install -m 0600 /dev/null "${tmp}" || die "Failed to create temporary sanitized samba setup copy: ${tmp}"

  local in_archive=0
  local in_managed=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "CRED_SAMBA_ARCHIVE_USERS=(" ]]; then
      in_archive=1
      printf '%s\n' "${line}" >> "${tmp}"
      continue
    fi
    if [[ "${line}" == "CRED_MANAGED_SAMBA_SHARES=(" ]]; then
      in_managed=1
      printf '%s\n' "${line}" >> "${tmp}"
      continue
    fi
    if (( in_archive )) && [[ "${line}" =~ ^[[:space:]]*\)[[:space:]]*$ ]]; then
      in_archive=0
      printf '%s\n' "${line}" >> "${tmp}"
      continue
    fi
    if (( in_managed )) && [[ "${line}" =~ ^[[:space:]]*\)[[:space:]]*$ ]]; then
      in_managed=0
      printf '%s\n' "${line}" >> "${tmp}"
      continue
    fi

    if [[ "${line}" =~ ^(CRED_BACKUP_DASHBOARD_PASSWORD=)\"[^\"]*\"(.*)$ ]]; then
      printf '%s"change-me"%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "${tmp}"
      continue
    fi

    if (( in_archive )) && [[ "${line}" =~ ^([[:space:]]*)\"([^\"]+)\"(.*)$ ]]; then
      entry="${BASH_REMATCH[2]}"
      user="${entry%%:*}"
      printf '%s"%s:change-me"%s\n' "${BASH_REMATCH[1]}" "${user}" "${BASH_REMATCH[3]}" >> "${tmp}"
      continue
    fi

    if (( in_managed )) && [[ "${line}" =~ ^([[:space:]]*)\"([^\"]+)\"(.*)$ ]]; then
      entry="${BASH_REMATCH[2]}"
      user="${entry%%:*}"
      rest="${entry#*:}"
      if [[ "${rest}" == "${entry}" || "${rest}" != *:* ]]; then
        printf '%s\n' "${line}" >> "${tmp}"
        continue
      fi
      rest="${rest#*:}"
      printf '%s"%s:change-me:%s"%s\n' "${BASH_REMATCH[1]}" "${user}" "${rest}" "${BASH_REMATCH[3]}" >> "${tmp}"
      continue
    fi

    printf '%s\n' "${line}" >> "${tmp}"
  done < "${src}"

  penelope_stage_common_for_recovery "${stage_dir}" "${SCRIPT_DIR}" || die "Failed to stage penelope-common for recovery stage"
  penelope_publish_recovery_stage_file "${tmp}" "${dest}" 0755 || die "Failed to stage sanitized samba setup copy"

  trap - RETURN
  log "Recovery stage updated: ${stage_dir}"
}


reset_operator_model_from_config_defaults() {
  OPERATOR_DECLARED_USERS=()
  OPERATOR_DECLARED_PRIMARY_SHARES=()
  OPERATOR_USER_DEFAULT_ACCESS=()
  OPERATOR_USER_PRIVATE_HOME=()
  OPERATOR_USER_PRIVATE_ARCHIVE=()
  OPERATOR_USER_HOME_PATH=()
  OPERATOR_USER_HOME_SHARE=()
  OPERATOR_USER_ARCHIVE_PATH=()
  OPERATOR_USER_ARCHIVE_SHARE=()
  OPERATOR_USER_EXTRA_GROUPS=()
  SHARE_ALLOWED_USERS=()
  SHARE_ALLOWED_GROUPS=()
  SHARE_FORCE_GROUP=()
  INTERNAL_USER="${SEED_INTERNAL_USER}"
  BACKUP_DASHBOARD_EXPORT_USER="${SEED_BACKUP_DASHBOARD_EXPORT_USER}"
  CRED_BACKUP_DASHBOARD_PASSWORD="change-me"
  ENABLE_BACKUP_DASHBOARD_SHARE="${SEED_ENABLE_BACKUP_DASHBOARD_SHARE}"
  STANDARD_CLIENT_GROUP="${SEED_STANDARD_CLIENT_GROUP}"
  SCAN_INBOX_GROUP="${SEED_SCAN_INBOX_GROUP}"
  SHARED_WORK_DIR_MODE="${SEED_SHARED_WORK_DIR_MODE}"
  SHARED_WORK_CREATE_MASK="${SEED_SHARED_WORK_CREATE_MASK}"
  SHARED_WORK_DIRECTORY_MASK="${SEED_SHARED_WORK_DIRECTORY_MASK}"
  SMB_SERVER_MIN_PROTOCOL="${SEED_SMB_SERVER_MIN_PROTOCOL}"
  SMB_CLIENT_MIN_PROTOCOL="${SEED_SMB_CLIENT_MIN_PROTOCOL}"
  SMB_NTLM_AUTH="${SEED_SMB_NTLM_AUTH}"
  SAMBA_EXTRA_SHARES=()
  RO_EXTRA_SHARE_CREATE_OWNER="${SEED_RO_EXTRA_SHARE_CREATE_OWNER}"
  RO_EXTRA_SHARE_CREATE_GROUP="${SEED_RO_EXTRA_SHARE_CREATE_GROUP}"
  RO_EXTRA_SHARE_CREATE_MODE="${SEED_RO_EXTRA_SHARE_CREATE_MODE}"
  RW_EXTRA_SHARE_CREATE_MODE="${SEED_RW_EXTRA_SHARE_CREATE_MODE}"
  OPERATOR_CONFIG_SCHEMA_VERSION="${CONFIG_SCHEMA_VERSION_CURRENT}"
}

operator_config_hint() {
  printf '%s\n' \
    "Run sudo -E ./${0##*/} write-config to create the template config tree, or use --config-dir DIR to point to an existing restored config directory."
}

trim_trailing_cr() {
  local value="$1"
  value="${value%$'\r'}"
  printf '%s\n' "$value"
}

trim_ascii_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

strip_optional_wrapping_double_quotes() {
  local value="$1"
  if (( ${#value} >= 2 )) && [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s\n' "$value"
}

load_simple_kv_file_into_assoc() {
  local file="$1"
  local out_ref_name="$2"
  local -n out_ref="${out_ref_name}"
  local line key value lineno=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((lineno+=1))
    line="$(trim_trailing_cr "${line}")"
    line="$(trim_ascii_whitespace "${line}")"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == \#* ]] && continue
    [[ "${line}" == *=* ]] || die "Invalid key=value line in ${file}:${lineno}: ${line}"
    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim_ascii_whitespace "${key}")"
    value="${value%%#*}"
    value="$(trim_ascii_whitespace "${value}")"
    [[ -n "${key}" ]] || die "Empty key in ${file}:${lineno}"
    # shellcheck disable=SC2034  # Bash nameref write; ShellCheck cannot see caller-visible associative-array output.
    out_ref["${key}"]="${value}"
  done < "${file}"
}

read_secret_file_or_placeholder() {
  local file="$1"

  if [[ ! -e "${file}" ]]; then
    printf 'change-me\n'
    return 0
  fi

  if [[ ! -r "${file}" ]]; then
    printf 'change-me\n'
    return 0
  fi

  local value
  value="$(<"${file}")"
  value="${value%$'\n'}"
  value="${value%$'\r'}"
  if [[ -z "${value}" ]]; then
    printf 'change-me\n'
  else
    printf '%s\n' "${value}"
  fi
}

load_main_config_file() {
  local -A kv=()
  load_simple_kv_file_into_assoc "${OPERATOR_CONFIG_FILE}" kv

  OPERATOR_CONFIG_SCHEMA_VERSION="${kv[config_schema_version]:-}"
  [[ -n "${OPERATOR_CONFIG_SCHEMA_VERSION}" ]] || die "Missing config_schema_version in ${OPERATOR_CONFIG_FILE}"

  for key in "${!kv[@]}"; do
    case "${key}" in
      config_schema_version)
        ;;
      enable_backup_dashboard_share)
        ENABLE_BACKUP_DASHBOARD_SHARE="${kv[$key]}"
        ;;
      standard_client_group)
        STANDARD_CLIENT_GROUP="${kv[$key]}"
        ;;
      scan_inbox_group)
        SCAN_INBOX_GROUP="${kv[$key]}"
        ;;
      shared_work_dir_mode)
        SHARED_WORK_DIR_MODE="${kv[$key]}"
        ;;
      shared_work_create_mask)
        SHARED_WORK_CREATE_MASK="${kv[$key]}"
        ;;
      shared_work_directory_mask)
        SHARED_WORK_DIRECTORY_MASK="${kv[$key]}"
        ;;
      ro_extra_share_create_owner)
        RO_EXTRA_SHARE_CREATE_OWNER="${kv[$key]}"
        ;;
      ro_extra_share_create_group)
        RO_EXTRA_SHARE_CREATE_GROUP="${kv[$key]}"
        ;;
      ro_extra_share_create_mode)
        RO_EXTRA_SHARE_CREATE_MODE="${kv[$key]}"
        ;;
      rw_extra_share_create_mode)
        RW_EXTRA_SHARE_CREATE_MODE="${kv[$key]}"
        ;;
      smb_server_min_protocol)
        SMB_SERVER_MIN_PROTOCOL="${kv[$key]}"
        ;;
      smb_client_min_protocol)
        SMB_CLIENT_MIN_PROTOCOL="${kv[$key]}"
        ;;
      smb_ntlm_auth)
        SMB_NTLM_AUTH="${kv[$key]}"
        ;;
      smb_lanman_auth|smb_client_lanman_auth|smb_client_plaintext_auth)
        die "Deprecated config key in ${OPERATOR_CONFIG_FILE}: ${key}. Remove this key; Penelope does not render deprecated LanMan/plaintext Samba options."
        ;;
      *)
        die "Unknown config key in ${OPERATOR_CONFIG_FILE}: ${key}"
        ;;
    esac
  done
}

validate_operator_config_schema_version() {
  case "${OPERATOR_CONFIG_SCHEMA_VERSION}" in
    "${CONFIG_SCHEMA_VERSION_CURRENT}")
      return 0
      ;;
    *)
      die "Unsupported Samba config schema version in ${OPERATOR_CONFIG_FILE}: ${OPERATOR_CONFIG_SCHEMA_VERSION} (supported: ${CONFIG_SCHEMA_VERSION_CURRENT})"
      ;;
  esac
}

split_declared_user_entry() {
  local entry="$1"
  local user password purpose tail

  IFS=':' read -r user password purpose tail <<< "$entry"
  if [[ -n "$tail" || -z "$user" || -z "$password" || -z "$purpose" ]]; then
    die "Invalid declared managed-user entry: ${entry} (expected user:password:purpose)"
  fi

  printf '%s\t%s\t%s\n' "$user" "$password" "$purpose"
}

split_declared_primary_share_entry() {
  local entry="$1"
  local user path share mode origin tail

  IFS=':' read -r user path share mode origin tail <<< "$entry"
  if [[ -n "$tail" || -z "$user" || -z "$path" || -z "$share" || -z "$mode" || -z "$origin" ]]; then
    die "Invalid declared primary-share entry: ${entry} (expected user:path:share:mode:origin)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$user" "$path" "$share" "$mode" "$origin"
}

validate_yes_no() {
  local value="$1"
  [[ "$value" == "yes" || "$value" == "no" ]]
}

validate_smb_protocol_value() {
  local value="$1"
  case "$value" in
    SMB2_02|SMB2_10|SMB3_00|SMB3_02|SMB3_11|SMB3)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_smb_ntlm_auth_value() {
  local value="$1"
  case "$value" in
    ntlmv2-only|mschapv2-and-ntlmv2-only|disabled)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bool_is_yes() {
  local value="$1"
  [[ "$value" == "yes" ]]
}

default_home_share_name_for_user() {
  local user="${1:?user required}"
  printf 'home_%s\n' "${user}"
}

append_private_shares_for_user() {
  local user="$1"
  local private_home private_archive home_path home_share archive_path archive_share

  private_home="${OPERATOR_USER_PRIVATE_HOME[$user]:-no}"
  private_archive="${OPERATOR_USER_PRIVATE_ARCHIVE[$user]:-no}"

  if bool_is_yes "$private_home"; then
    home_path="${OPERATOR_USER_HOME_PATH[$user]:-/home/${user}}"
    home_share="${OPERATOR_USER_HOME_SHARE[$user]:-$(default_home_share_name_for_user "$user")}"
    OPERATOR_DECLARED_PRIMARY_SHARES+=("${user}:${home_path}:${home_share}:rw:home_primary")
  fi

  if bool_is_yes "$private_archive"; then
    archive_path="${OPERATOR_USER_ARCHIVE_PATH[$user]:-${ARCHIVE_ROOT}/${user}}"
    archive_share="${OPERATOR_USER_ARCHIVE_SHARE[$user]:-$(default_archive_share_name_for_user "$user")}"
    OPERATOR_DECLARED_PRIMARY_SHARES+=("${user}:${archive_path}:${archive_share}:rw:archive_primary")
  fi
}

load_operator_user_file() {
  local file="$1"
  local -A kv=()
  local user purpose password default_access private_home private_archive extra_groups
  local home_path home_share archive_path archive_share

  load_simple_kv_file_into_assoc "${file}" kv

  user="${kv[user]:-}"
  purpose="${kv[purpose]:-client}"
  default_access="${kv[default_access]:-yes}"
  private_home="${kv[private_home]:-no}"
  private_archive="${kv[private_archive]:-no}"
  home_path="${kv[home_path]:-}"
  home_share="${kv[home_share]:-}"
  archive_path="${kv[archive_path]:-}"
  archive_share="${kv[archive_share]:-}"
  extra_groups="${kv[extra_groups]:-}"

  [[ -n "${user}" ]] || die "Managed user file must define user: ${file}"
  case "${purpose}" in
    client|service|admin)
      ;;
    *)
      die "Unsupported purpose in ${file}: ${purpose} (use client, service, or admin)"
      ;;
  esac
  validate_yes_no "${default_access}" || die "default_access must be yes or no in ${file}: ${default_access}"
  validate_yes_no "${private_home}" || die "private_home must be yes or no in ${file}: ${private_home}"
  validate_yes_no "${private_archive}" || die "private_archive must be yes or no in ${file}: ${private_archive}"

  for key in "${!kv[@]}"; do
    case "${key}" in
      user|purpose|default_access|private_home|private_archive|home_path|home_share|archive_path|archive_share|extra_groups)
        ;;
      *)
        die "Unknown key in managed user file ${file}: ${key}"
        ;;
    esac
  done

  password="$(read_secret_file_or_placeholder "${OPERATOR_SECRETS_DIR}/${user}.secret")"
  OPERATOR_DECLARED_USERS+=("${user}:${password}:${purpose}")
  OPERATOR_USER_DEFAULT_ACCESS["${user}"]="${default_access}"
  OPERATOR_USER_PRIVATE_HOME["${user}"]="${private_home}"
  OPERATOR_USER_PRIVATE_ARCHIVE["${user}"]="${private_archive}"
  OPERATOR_USER_HOME_PATH["${user}"]="${home_path}"
  OPERATOR_USER_HOME_SHARE["${user}"]="${home_share}"
  OPERATOR_USER_ARCHIVE_PATH["${user}"]="${archive_path}"
  OPERATOR_USER_ARCHIVE_SHARE["${user}"]="${archive_share}"
  OPERATOR_USER_EXTRA_GROUPS["${user}"]="${extra_groups}"

  append_private_shares_for_user "${user}"
}

load_declared_share_file() {
  local file="$1"
  local -A kv=()
  local kind path share user mode allowed_users allowed_groups force_group

  load_simple_kv_file_into_assoc "${file}" kv

  kind="${kv[kind]:-extra}"
  path="${kv[path]:-}"
  share="${kv[share]:-}"
  user="${kv[user]:-}"
  mode="${kv[mode]:-}"
  allowed_users="${kv[allowed_users]:-}"
  allowed_groups="${kv[allowed_groups]:-}"
  force_group="${kv[force_group]:-}"

  [[ -n "${path}" && -n "${share}" && -n "${user}" && -n "${mode}" ]] || \
    die "Managed share file must define kind, path, share, user, and mode: ${file}"

  for key in "${!kv[@]}"; do
    case "${key}" in
      kind|path|share|user|mode|allowed_users|allowed_groups|force_group)
        ;;
      *)
        die "Unknown key in managed share file ${file}: ${key}"
        ;;
    esac
  done

  case "${kind}" in
    extra)
      SAMBA_EXTRA_SHARES+=("${path}:${share}:${user}:${mode}")
      SHARE_ALLOWED_USERS["${share}"]="${allowed_users}"
      SHARE_ALLOWED_GROUPS["${share}"]="${allowed_groups}"
      SHARE_FORCE_GROUP["${share}"]="${force_group}"
      ;;
    *)
      die "Unsupported share kind in ${file}: ${kind} (use extra; private home/archive shares are configured in users.d)"
      ;;
  esac
}

load_operator_model_from_config_dir() {
  local file
  local had_user_file=0

  update_operator_config_paths
  [[ -f "${OPERATOR_CONFIG_FILE}" ]] || {
    operator_config_hint >&2
    die "Missing Samba config file: ${OPERATOR_CONFIG_FILE}"
  }

  reset_operator_model_from_config_defaults
  load_main_config_file
  validate_operator_config_schema_version

  CRED_BACKUP_DASHBOARD_PASSWORD="$(read_secret_file_or_placeholder "${OPERATOR_SECRETS_DIR}/${BACKUP_DASHBOARD_EXPORT_USER}.secret")"

  shopt -s nullglob
  for file in "${OPERATOR_USERS_DIR}"/*.conf; do
    [[ -e "${file}" ]] || continue
    had_user_file=1
    load_operator_user_file "${file}"
  done
  for file in "${OPERATOR_SHARES_DIR}"/*.conf; do
    [[ -e "${file}" ]] || continue
    load_declared_share_file "${file}"
  done
  shopt -u nullglob

  if (( ! had_user_file )); then
    warn "No managed user files found in ${OPERATOR_USERS_DIR}; only built-in internal shares remain active"
  fi
}

write_if_missing() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local content="$5"

  if [[ -e "${path}" ]]; then
    log "Keeping existing file: ${path}"
    return 0
  fi

  printf '%s\n' "${content}" > "${path}" || die "Failed to write ${path}"
  chown "${owner}:${group}" "${path}" || die "Failed to chown ${path}"
  chmod "${mode}" "${path}" || die "Failed to chmod ${path}"
  log "Created template: ${path}"
}

write_package_owned_example() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local content="$5"

  printf '%s\n' "${content}" > "${path}" || die "Failed to write ${path}"
  chown "${owner}:${group}" "${path}" || die "Failed to chown ${path}"
  chmod "${mode}" "${path}" || die "Failed to chmod ${path}"
  log "Wrote package-owned example: ${path}"
}

default_archive_share_name_for_user() {
  local user="${1:?user required}"
  printf 'archive_%s\n' "${user}"
}

seed_client_and_service_user_templates() {
  local entry user password user_file secret_file

  for entry in "${SEED_CRED_SAMBA_CLIENT_USERS[@]}"; do
    IFS=$'	' read -r user password <<< "$(split_simple_samba_user_entry "${entry}" "CRED_SAMBA_CLIENT_USERS")"
    user_file="${OPERATOR_USERS_DIR}/${user}.conf"
    secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
    write_if_missing "${user_file}" 0644 root root "$(cat <<EOF_USER
# Standard Penelope Samba client.
# This principal gets shared workspace access and no private home/archive by default.
user=${user}
purpose=client
default_access=yes
private_home=no
private_archive=no
extra_groups=
EOF_USER
)"
    write_if_missing "${secret_file}" 0600 root root "$(printf '%s
' "${password}")"
  done

  for entry in "${SEED_CRED_SAMBA_SERVICE_USERS[@]}"; do
    IFS=$'	' read -r user password <<< "$(split_simple_samba_user_entry "${entry}" "CRED_SAMBA_SERVICE_USERS")"
    user_file="${OPERATOR_USERS_DIR}/${user}.conf"
    secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
    write_if_missing "${user_file}" 0644 root root "$(cat <<EOF_USER
# Penelope Samba service/device principal.
# Scanner/printer devices use this principal to write into the scan inbox.
user=${user}
purpose=service
default_access=no
private_home=no
private_archive=no
extra_groups=${SCAN_INBOX_GROUP}
EOF_USER
)"
    write_if_missing "${secret_file}" 0600 root root "$(printf '%s
' "${password}")"
  done
}

seed_archive_user_templates() {
  local entry user password share user_file secret_file

  for entry in "${SEED_CRED_SAMBA_ARCHIVE_USERS[@]}"; do
    IFS=$'\t' read -r user password <<< "$(split_archive_user_entry "${entry}")"
    share="$(default_archive_share_name_for_user "${user}")"
    user_file="${OPERATOR_USERS_DIR}/${user}.conf"
    secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
    write_if_missing "${user_file}" 0644 root root "$(cat <<EOF_USER
# Managed archive Samba user principal.
# default_access=yes is the Windows-friendly combined workstation/archive role.
# Set default_access=no when this credential should remain archive-only.
# Remove this file and rerun verify-config, then apply, to remove the user from the declared model.
user=${user}
purpose=client
default_access=yes
private_home=no
private_archive=yes
archive_path=${ARCHIVE_ROOT}/${user}
archive_share=${share}
extra_groups=
EOF_USER
)"
    write_if_missing "${secret_file}" 0600 root root "$(printf '%s\n' "${password}")"
  done
}

seed_managed_principal_templates() {
  local entry user password path share mode
  local user_file share_file secret_file

  for entry in "${SEED_CRED_MANAGED_SAMBA_SHARES[@]}"; do
    IFS=$'\t' read -r user password path share mode <<< "$(split_managed_share_entry "${entry}")"
    user_file="${OPERATOR_USERS_DIR}/${user}.conf"
    share_file="${OPERATOR_SHARES_DIR}/${share}.conf"
    secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
    write_if_missing "${user_file}" 0644 root root "$(cat <<EOF_USER
# Managed Samba user principal.
# Remove this file and rerun verify-config, then apply, to remove the user from the declared model.
user=${user}
purpose=client
default_access=yes
private_home=no
private_archive=no
extra_groups=
EOF_USER
)"
    write_if_missing "${share_file}" 0644 root root "$(cat <<EOF_SHARE
# Managed extra Samba share.
# Remove this file and rerun verify-config, then apply, to remove the exported share from the declared model.
kind=extra
path=${path}
share=${share}
user=${user}
mode=${mode}
allowed_users=${user}
allowed_groups=
force_group=
EOF_SHARE
)"
    write_if_missing "${secret_file}" 0600 root root "$(printf '%s\n' "${password}")"
  done
}

refresh_operator_package_owned_examples() {
  update_operator_config_paths

  ensure_dir "${OPERATOR_EXAMPLES_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_USERS_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_SHARES_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_SECRETS_DIR}" 0755 root root

  write_package_owned_example "${OPERATOR_EXAMPLE_CONFIG_FILE}" 0644 root root "$(cat <<'EOF_MAIN_EXAMPLE'
# penelope-samba-setup package-owned example config
# Copy intended values into ../samba-setup.conf; this file is not active state.
# Files under examples/ are overwritten by write-config/apply and must not contain local-only edits.

config_schema_version=4
enable_backup_dashboard_share=1
standard_client_group=penelope_clients
scan_inbox_group=penelope_scan_clients
shared_work_dir_mode=2770
shared_work_create_mask=0660
shared_work_directory_mask=0770
smb_server_min_protocol=SMB3_00
smb_client_min_protocol=SMB3_00
smb_ntlm_auth=ntlmv2-only
ro_extra_share_create_owner=root
ro_extra_share_create_group=root
ro_extra_share_create_mode=0755
rw_extra_share_create_mode=0700
EOF_MAIN_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_USERS_DIR}/client-user.conf.example" 0644 root root "$(cat <<'EOF_CLIENT_EXAMPLE'
# Example additional standard Penelope client principal.
# The shipped default standard client principal is penelope_client.
# Add more client principals only when different workstations need distinct credentials.
# Client users get shared Penelope work shares and no private home/archive by default.
# user=workstation01
# purpose=client
# default_access=yes
# private_home=no
# private_archive=no
# extra_groups=
EOF_CLIENT_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_USERS_DIR}/archive-user.conf.example" 0644 root root "$(cat <<'EOF_ARCHIVE_EXAMPLE'
# Example archive user.
# Set default_access=yes for a Windows-friendly combined workstation/archive identity.
# Set default_access=no when this credential should remain archive-only.
# user=apollo
# purpose=client
# default_access=yes
# private_home=no
# private_archive=yes
# archive_path=/_archive/apollo
# archive_share=archive_apollo
# extra_groups=
EOF_ARCHIVE_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_USERS_DIR}/service-user.conf.example" 0644 root root "$(cat <<'EOF_SERVICE_EXAMPLE'
# Example additional service/device principal.
# The shipped default scanner/printer service principal is scan.
# Add more service users only when separate devices need distinct credentials.
# Service users are for devices such as scanners and do not get standard client shares by default.
# user=scanner01
# purpose=service
# default_access=no
# private_home=no
# private_archive=no
# extra_groups=penelope_scan_clients
EOF_SERVICE_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_USERS_DIR}/home-user.conf.example" 0644 root root "$(cat <<'EOF_HOME_EXAMPLE'
# Example user with private home but no private archive.
# user=alice
# purpose=client
# default_access=yes
# private_home=yes
# home_path=/home/alice
# home_share=home_alice
# private_archive=no
# extra_groups=
EOF_HOME_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_SHARES_DIR}/extra-share.conf.example" 0644 root root "$(cat <<'EOF_EXTRA_EXAMPLE'
# Example extra share for an already managed user.
# Activate by copying to ../shares.d/<name>.conf and filling in concrete values.
# Built-in shared resources rawin, scan, internal, and backup_dashboard are not declared here.
# kind=extra
# path=/srv/penelope/custom
# share=custom
# user=penelope_client
# mode=rw
# allowed_users=
# allowed_groups=penelope_clients
# force_group=penelope_clients
EOF_EXTRA_EXAMPLE
)"


  write_package_owned_example "${OPERATOR_EXAMPLE_SECRETS_DIR}/backup_dashboard.secret.example" 0644 root root "$(cat <<'EOF_BACKUP_DASHBOARD_SECRET_EXAMPLE'
change-me
EOF_BACKUP_DASHBOARD_SECRET_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_SECRETS_DIR}/penelope_client.secret.example" 0644 root root "$(cat <<'EOF_PENELOPE_CLIENT_SECRET_EXAMPLE'
change-me
EOF_PENELOPE_CLIENT_SECRET_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_SECRETS_DIR}/scan.secret.example" 0644 root root "$(cat <<'EOF_SCAN_SECRET_EXAMPLE'
change-me
EOF_SCAN_SECRET_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_SECRETS_DIR}/archive-user.secret.example" 0644 root root "$(cat <<'EOF_ARCHIVE_USER_SECRET_EXAMPLE'
change-me
EOF_ARCHIVE_USER_SECRET_EXAMPLE
)"

  write_package_owned_example "${OPERATOR_EXAMPLE_SECRETS_DIR}/home-user.secret.example" 0644 root root "$(cat <<'EOF_HOME_USER_SECRET_EXAMPLE'
change-me
EOF_HOME_USER_SECRET_EXAMPLE
)"
}

init_operator_config_dir() {
  local fresh_active_tree=0

  require_root "${SELF_CMD}"
  update_operator_config_paths

  if [[ ! -e "${OPERATOR_CONFIG_FILE}" && ! -d "${OPERATOR_USERS_DIR}" \
      && ! -d "${OPERATOR_SHARES_DIR}" && ! -d "${OPERATOR_SECRETS_DIR}" ]]; then
    fresh_active_tree=1
  fi

  log "Initializing Samba config directory: ${OPERATOR_CONFIG_DIR}"
  ensure_dir "${OPERATOR_CONFIG_DIR}" 0755 root root
  ensure_dir "${OPERATOR_USERS_DIR}" 0755 root root
  ensure_dir "${OPERATOR_SHARES_DIR}" 0755 root root
  ensure_dir "${OPERATOR_SECRETS_DIR}" 0700 root root
  ensure_dir "${OPERATOR_EXAMPLES_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_USERS_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_SHARES_DIR}" 0755 root root
  ensure_dir "${OPERATOR_EXAMPLE_SECRETS_DIR}" 0755 root root
  write_if_missing "${OPERATOR_CONFIG_FILE}" 0644 root root "$(cat <<EOF_MAIN
# penelope-samba-setup active config
# Built-in shared resources: rawin, scan, internal, backup_dashboard.
# Active values use key=value lines. Blank lines and # comments are ignored.

config_schema_version=${CONFIG_SCHEMA_VERSION_CURRENT}
enable_backup_dashboard_share=1
standard_client_group=penelope_clients
scan_inbox_group=penelope_scan_clients
shared_work_dir_mode=2770
shared_work_create_mask=0660
shared_work_directory_mask=0770
smb_server_min_protocol=SMB3_00
smb_client_min_protocol=SMB3_00
smb_ntlm_auth=ntlmv2-only
ro_extra_share_create_owner=root
ro_extra_share_create_group=root
ro_extra_share_create_mode=0755
rw_extra_share_create_mode=0700

# Optional future keys belong here as active key=value lines.
EOF_MAIN
)"
  merge_main_config_defaults

  if (( fresh_active_tree )); then
    seed_client_and_service_user_templates
    seed_archive_user_templates
    seed_managed_principal_templates

    if [[ "${SEED_ENABLE_BACKUP_DASHBOARD_SHARE}" == "1" ]]; then
      write_if_missing \
        "${OPERATOR_SECRETS_DIR}/${SEED_BACKUP_DASHBOARD_EXPORT_USER}.secret" \
        0600 \
        root \
        root \
        "$(printf '%s\n' "${SEED_CRED_BACKUP_DASHBOARD_PASSWORD}")"
    fi
  else
    log "Existing Samba config tree detected; preserving active users, shares, and secrets without seeding defaults"
  fi

  refresh_operator_package_owned_examples

  local self_cmd
  self_cmd="${SELF_CMD}"

  printf '%s\n' "Initialized Samba config templates in ${OPERATOR_CONFIG_DIR}"
  printf '\n'
  printf '%s\n' "Next steps:"
  printf '  1. Edit %s if you need non-default global settings.\n' "${OPERATOR_CONFIG_FILE}"
  printf '  2. Edit/create %s/*.conf and %s/*.conf.\n' "${OPERATOR_USERS_DIR}" "${OPERATOR_SHARES_DIR}"
  printf '     Optional examples are in %s.\n' "${OPERATOR_EXAMPLES_DIR}"
  printf '%s\n' "  3. Configure private_home/private_archive in users.d when a user needs private storage."
  printf '  4. Replace every change-me secret in %s.\n' "${OPERATOR_SECRETS_DIR}"
  printf '%s\n' "  5. On the normal Penelope server profile, run penelope-backup-setup first."
  printf '     Keep the shipped default Backup-Dashboard export enabled only after %s\n' "${BACKUP_CONF}"
  printf '%s\n' "     and the canonical Backup-Dashboard directory already exist."
  printf '%s\n' "  6. Inspect the declared model without changing the host (optional):"
  printf '       %s --config-dir %s list-users\n' "${self_cmd}" "${OPERATOR_CONFIG_DIR}"
  printf '       %s --config-dir %s list-shares\n' "${self_cmd}" "${OPERATOR_CONFIG_DIR}"
  printf '%s\n' "  7. Verify the config without changing the host:"
  printf '       %s --config-dir %s verify-config\n' "${self_cmd}" "${OPERATOR_CONFIG_DIR}"
  printf '  8. Apply the live state: sudo -E %s --config-dir %s apply\n' "${self_cmd}" "${OPERATOR_CONFIG_DIR}"
  printf '\n'
  printf '%s\n' "Notes:"
  printf '%s\n' "  - The shipped default enables the dedicated readonly Backup-Dashboard export."
  printf '%s\n' "  - Existing non-empty files were preserved."
  printf '%s\n' "  - Example templates live under ${OPERATOR_EXAMPLES_DIR}."
  printf '%s\n' "  - Files under examples/ are templates only and are never loaded as live state."
  printf '%s\n' "  - Once effective Samba passwords exist, capture them in KeePass or an"
  printf '%s\n' "    equivalent secure external vault; do not rely on this server as the only credential copy."
  printf '  - samba-setup.conf carries config_schema_version=%s.\n' \
    "${CONFIG_SCHEMA_VERSION_CURRENT}"
  printf '%s\n' "    Unsupported schema versions fail loudly in this pre-release series."
}



require_operator_config_tree() {
  update_operator_config_paths
  [[ -f "${OPERATOR_CONFIG_FILE}" ]] || {
    operator_config_hint >&2
    die "Missing Samba config file: ${OPERATOR_CONFIG_FILE}"
  }
  [[ -d "${OPERATOR_USERS_DIR}" ]] || die "Missing Samba users.d directory: ${OPERATOR_USERS_DIR}"
  [[ -d "${OPERATOR_SHARES_DIR}" ]] || die "Missing Samba shares.d directory: ${OPERATOR_SHARES_DIR}"
  [[ -d "${OPERATOR_SECRETS_DIR}" ]] || die "Missing Samba secrets.d directory: ${OPERATOR_SECRETS_DIR}"
}

active_user_file_path() {
  local user="$1"
  printf '%s\n' "${OPERATOR_USERS_DIR}/${user}.conf"
}

disabled_user_file_path() {
  local user="$1"
  printf '%s\n' "${OPERATOR_USERS_DIR}/${user}.conf.disabled"
}

active_share_file_path() {
  local share="$1"
  printf '%s\n' "${OPERATOR_SHARES_DIR}/${share}.conf"
}

disabled_share_file_path() {
  local share="$1"
  printf '%s\n' "${OPERATOR_SHARES_DIR}/${share}.conf.disabled"
}

write_owned_file() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local content="$5"
  local tmp="${path}.tmp.$$"

  install -m "${mode}" /dev/null "${tmp}" || die "Failed to create temporary file: ${tmp}"
  printf '%s\n' "${content}" > "${tmp}" || die "Failed to write ${tmp}"
  chown "${owner}:${group}" "${tmp}" || die "Failed to chown ${tmp}"
  chmod "${mode}" "${tmp}" || die "Failed to chmod ${tmp}"
  mv -f "${tmp}" "${path}" || die "Failed to move ${tmp} into place at ${path}"
}

move_live_file_to_disabled() {
  local path="$1"
  local disabled="${path}.disabled"

  [[ -e "${path}" ]] || die "Live config file does not exist: ${path}"
  [[ ! -e "${disabled}" ]] || die "Disabled target already exists: ${disabled}"
  mv -- "${path}" "${disabled}" || die "Failed to rename ${path} -> ${disabled}"
  log "Deactivated config file: ${path} -> ${disabled}"
}

move_disabled_file_to_live() {
  local disabled="$1"
  local path

  [[ "${disabled}" == *.disabled ]] || die "Disabled config file path must end in .disabled: ${disabled}"
  path="${disabled%.disabled}"
  [[ -e "${disabled}" ]] || die "Disabled config file does not exist: ${disabled}"
  [[ ! -e "${path}" ]] || die "Live target already exists: ${path}"
  mv -- "${disabled}" "${path}" || die "Failed to rename ${disabled} -> ${path}"
  log "Reactivated config file: ${disabled} -> ${path}"
}

read_new_password_from_source() {
  local context="$1"
  local user="$2"
  local password_file="$3"
  local password_stdin="$4"
  local value=""

  if [[ -n "${password_file}" && "${password_stdin}" == "1" ]]; then
    die "${context} for ${user} requires exactly one of --password-file or --password-stdin"
  fi
  if [[ -z "${password_file}" && "${password_stdin}" != "1" ]]; then
    die "${context} for ${user} requires one of --password-file or --password-stdin"
  fi

  if [[ -n "${password_file}" ]]; then
    [[ -r "${password_file}" ]] || die "Password file is not readable: ${password_file}"
    value="$(<"${password_file}")"
  else
    value="$(cat)"
  fi

  value="${value%$'\n'}"
  value="${value%$'\r'}"
  validate_secret_not_placeholder "${context} password for ${user}" "${value}"
  printf '%s\n' "${value}"
}

managed_user_exists_in_model() {
  local target_user="$1"
  local user password home kind

  while IFS=$'\t' read -r user password home kind; do
    [[ -n "${user}" ]] || continue
    [[ "${user}" == "${target_user}" ]] && return 0
  done < <(emit_managed_account_rows)

  return 1
}

find_share_row_in_model() {
  local target_share="$1"
  local share path user mode origin

  while IFS=$'\t' read -r share path user mode origin; do
    [[ -n "${share}" ]] || continue
    [[ "${share}" == "${target_share}" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "${share}" "${path}" "${user}" "${mode}" "${origin}"
    return 0
  done < <(emit_all_share_rows)

  return 1
}

emit_active_extra_share_file_rows() {
  local file
  local -A kv=()
  local share user

  shopt -s nullglob
  for file in "${OPERATOR_SHARES_DIR}"/*.conf; do
    [[ -e "${file}" ]] || continue
    kv=()
    load_simple_kv_file_into_assoc "${file}" kv
    share="${kv[share]:-}"
    user="${kv[user]:-}"
    printf '%s\t%s\t%s\n' "${file}" "${share}" "${user}"
  done
  shopt -u nullglob
}

emit_active_share_file_rows() {
  local file
  local -A kv=()
  local share user kind

  shopt -s nullglob
  for file in "${OPERATOR_SHARES_DIR}"/*.conf; do
    [[ -e "${file}" ]] || continue
    kv=()
    load_simple_kv_file_into_assoc "${file}" kv
    share="${kv[share]:-}"
    user="${kv[user]:-}"
    kind="${kv[kind]:-extra}"
    printf '%s	%s	%s	%s
' "${file}" "${share}" "${user}" "${kind}"
  done
  shopt -u nullglob
}

disable_share_files_for_user() {
  local target_user="$1"
  local file share user kind

  while IFS=$'	' read -r file share user kind; do
    [[ -n "${file}" ]] || continue
    [[ "${user}" == "${target_user}" ]] || continue
    move_live_file_to_disabled "${file}"
  done < <(emit_active_share_file_rows)
}

emit_disabled_share_file_rows() {
  local file
  local -A kv=()
  local share user kind

  shopt -s nullglob
  for file in "${OPERATOR_SHARES_DIR}"/*.conf.disabled; do
    [[ -e "${file}" ]] || continue
    kv=()
    load_simple_kv_file_into_assoc "${file}" kv
    share="${kv[share]:-}"
    user="${kv[user]:-}"
    kind="${kv[kind]:-extra}"
    printf '%s	%s	%s	%s
' "${file}" "${share}" "${user}" "${kind}"
  done
  shopt -u nullglob
}

enable_disabled_share_files_for_user() {
  local target_user="$1"
  local file share user kind

  while IFS=$'	' read -r file share user kind; do
    [[ -n "${file}" ]] || continue
    [[ "${user}" == "${target_user}" ]] || continue
    move_disabled_file_to_live "${file}"
  done < <(emit_disabled_share_file_rows)
}

run_mutation_preflight() {
  require_root "${SELF_CMD}"
  require_operator_config_tree
  load_operator_model_from_config_dir
  resolve_canonical_backup_dashboard_dir
  validate_operator_topology
}

run_add_user() {
  local user=""
  local purpose="client"
  local default_access="yes"
  local private_home="no"
  local private_archive="no"
  local home_path=""
  local home_share=""
  local archive_path=""
  local archive_share=""
  local extra_groups=""
  local password_file=""
  local password_stdin=0
  local password=""
  local user_file secret_file

  run_mutation_preflight

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purpose)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --purpose"
        purpose="$1"
        ;;
      --default-access)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --default-access"
        default_access="$1"
        ;;
      --private-home)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --private-home"
        private_home="$1"
        ;;
      --private-archive)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --private-archive"
        private_archive="$1"
        ;;
      --home-path)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --home-path"
        home_path="$1"
        ;;
      --home-share)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --home-share"
        home_share="$1"
        ;;
      --path|--archive-path)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after $1"
        archive_path="$1"
        private_archive="yes"
        ;;
      --share|--archive-share)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after $1"
        archive_share="$1"
        private_archive="yes"
        ;;
      --extra-groups)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --extra-groups"
        extra_groups="$1"
        ;;
      --password-file)
        shift
        [[ $# -gt 0 ]] || die "add-user requires an argument after --password-file"
        password_file="$1"
        ;;
      --password-stdin)
        password_stdin=1
        ;;
      --*)
        die "Unknown add-user option: $1"
        ;;
      *)
        [[ -z "${user}" ]] || die "add-user takes exactly one USER positional argument"
        user="$1"
        ;;
    esac
    shift || true
  done

  [[ -n "${user}" ]] || die "add-user requires exactly one USER positional argument"
  validate_username "${user}" || die "Invalid managed Samba username: ${user}"
  [[ "${user}" != "${INTERNAL_USER}" ]] || die "add-user must not target the fixed built-in user: ${user}"
  [[ "${user}" != "${BACKUP_DASHBOARD_EXPORT_USER}" ]] || die "add-user must not target the fixed built-in user: ${user}"
  ! managed_user_exists_in_model "${user}" || die "Managed Samba user already declared: ${user}"

  case "${purpose}" in
    client|service|admin)
      ;;
    *)
      die "Unsupported add-user purpose: ${purpose} (use client, service, or admin)"
      ;;
  esac
  validate_yes_no "${default_access}" || die "--default-access must be yes or no: ${default_access}"
  validate_yes_no "${private_home}" || die "--private-home must be yes or no: ${private_home}"
  validate_yes_no "${private_archive}" || die "--private-archive must be yes or no: ${private_archive}"

  if [[ "${private_home}" == "yes" ]]; then
    [[ -n "${home_path}" ]] || home_path="/home/${user}"
    [[ -n "${home_share}" ]] || home_share="$(default_home_share_name_for_user "${user}")"
    normalize_share_path "${home_path}" >/dev/null
    validate_share_name "${home_share}" || die "Invalid private home share name for ${user}: ${home_share}"
    validate_share_name_not_reserved "${home_share}" || die "Reserved private home share name for ${user}: ${home_share}"
    validate_declared_share_name_not_fixed_penelope_builtin "${home_share}"
    ! find_share_row_in_model "${home_share}" >/dev/null || die "Managed share already declared: ${home_share}"
  fi

  if [[ "${private_archive}" == "yes" ]]; then
    [[ -n "${archive_path}" ]] || archive_path="${ARCHIVE_ROOT}/${user}"
    [[ -n "${archive_share}" ]] || archive_share="$(default_archive_share_name_for_user "${user}")"
    [[ "${archive_path}" == "${ARCHIVE_ROOT}/${user}" ]] || die "Private archive must use canonical path ${ARCHIVE_ROOT}/${user}: ${archive_path}"
    [[ "${archive_share}" == "$(default_archive_share_name_for_user "${user}")" ]] || \
      die "Private archive must use canonical share name $(default_archive_share_name_for_user "${user}"): ${archive_share}"
    ! find_share_row_in_model "${archive_share}" >/dev/null || die "Managed share already declared: ${archive_share}"
  fi

  user_file="$(active_user_file_path "${user}")"
  secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
  [[ ! -e "${user_file}" ]] || die "Managed user file already exists: ${user_file}"
  [[ ! -e "$(disabled_user_file_path "${user}")" ]] || die "Disabled managed user file already exists for ${user}; inspect it before reusing the name"
  [[ ! -e "${secret_file}" ]] || die "Secret file already exists for ${user}: ${secret_file}"

  password="$(read_new_password_from_source "add-user" "${user}" "${password_file}" "${password_stdin}")"

  write_owned_file "${user_file}" 0644 root root "$(cat <<EOF_ADD_USER
# Managed Samba user principal.
user=${user}
purpose=${purpose}
default_access=${default_access}
private_home=${private_home}
private_archive=${private_archive}
EOF_ADD_USER
)"
  if [[ "${private_home}" == "yes" ]]; then
    {
      printf 'home_path=%s\n' "${home_path}"
      printf 'home_share=%s\n' "${home_share}"
    } >> "${user_file}"
  fi
  if [[ "${private_archive}" == "yes" ]]; then
    {
      printf 'archive_path=%s\n' "${archive_path}"
      printf 'archive_share=%s\n' "${archive_share}"
    } >> "${user_file}"
  fi
  printf 'extra_groups=%s\n' "${extra_groups}" >> "${user_file}"
  write_owned_file "${secret_file}" 0600 root root "$(printf '%s\n' "${password}")"

  run_apply "$@"
}


run_set_password() {
  local user=""
  local password_file=""
  local password_stdin=0
  local password=""
  local secret_file

  run_mutation_preflight

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password-file)
        shift
        [[ $# -gt 0 ]] || die "set-password requires an argument after --password-file"
        password_file="$1"
        ;;
      --password-stdin)
        password_stdin=1
        ;;
      --*)
        die "Unknown set-password option: $1"
        ;;
      *)
        [[ -z "${user}" ]] || die "set-password takes exactly one USER positional argument"
        user="$1"
        ;;
    esac
    shift || true
  done

  [[ -n "${user}" ]] || die "set-password requires exactly one USER positional argument"
  managed_user_exists_in_model "${user}" || die "Unknown managed Samba user: ${user}"
  password="$(read_new_password_from_source "set-password" "${user}" "${password_file}" "${password_stdin}")"
  secret_file="${OPERATOR_SECRETS_DIR}/${user}.secret"
  write_owned_file "${secret_file}" 0600 root root "$(printf '%s\n' "${password}")"

  run_apply "$@"
}

run_add_share() {
  local share=""
  local user=""
  local path=""
  local mode="rw"
  local share_file

  run_mutation_preflight

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        shift
        [[ $# -gt 0 ]] || die "add-share requires an argument after --user"
        user="$1"
        ;;
      --path)
        shift
        [[ $# -gt 0 ]] || die "add-share requires an argument after --path"
        path="$1"
        ;;
      --mode)
        shift
        [[ $# -gt 0 ]] || die "add-share requires an argument after --mode"
        mode="$1"
        ;;
      --*)
        die "Unknown add-share option: $1"
        ;;
      *)
        [[ -z "${share}" ]] || die "add-share takes exactly one SHARE positional argument"
        share="$1"
        ;;
    esac
    shift || true
  done

  [[ -n "${share}" ]] || die "add-share requires exactly one SHARE positional argument"
  [[ -n "${user}" ]] || die "add-share requires --user"
  [[ -n "${path}" ]] || die "add-share requires --path"
  managed_user_exists_in_model "${user}" || die "Unknown managed Samba user for add-share: ${user}"
  [[ "${user}" != "${BACKUP_DASHBOARD_EXPORT_USER}" ]] || die "Extra shares must not use the dedicated dashboard export user: ${user}"
  validate_share_name "${share}" || die "Invalid extra share name: ${share}"
  validate_share_name_not_reserved "${share}" || die "Reserved extra share name: ${share}"
  validate_declared_share_name_not_fixed_penelope_builtin "${share}"
  validate_share_mode "${mode}" || die "Invalid extra share mode: ${mode}"
  normalize_share_path "${path}" >/dev/null
  assert_share_path_has_no_symlink_components "${path}"
  assert_extra_share_does_not_touch_canonical_backup_dashboard_tree "${path}"
  ! find_share_row_in_model "${share}" >/dev/null || die "Managed share already declared: ${share}"

  share_file="$(active_share_file_path "${share}")"
  [[ ! -e "${share_file}" ]] || die "Extra share file already exists: ${share_file}"
  [[ ! -e "$(disabled_share_file_path "${share}")" ]] || die "Disabled extra share file already exists for ${share}; inspect it before reusing the name"

  write_owned_file "${share_file}" 0644 root root "$(cat <<EOF_ADD_SHARE
# Managed extra Samba share.
kind=extra
path=${path}
share=${share}
user=${user}
mode=${mode}
EOF_ADD_SHARE
)"

  run_apply "$@"
}

run_remove_user() {
  local user=""
  local user_file

  run_mutation_preflight

  [[ $# -eq 1 ]] || die "remove-user requires exactly one USER positional argument"
  user="$1"
  [[ "${user}" != "${INTERNAL_USER}" ]] || die "remove-user must not target the fixed built-in user: ${user}"
  [[ "${user}" != "${BACKUP_DASHBOARD_EXPORT_USER}" ]] || die "remove-user must not target the fixed built-in user: ${user}"
  user_file="$(active_user_file_path "${user}")"
  [[ -f "${user_file}" ]] || die "No active managed user file found for ${user}: ${user_file}"

  move_live_file_to_disabled "${user_file}"
  disable_share_files_for_user "${user}"
  run_apply "$@"
}

run_disable_user() {
  [[ $# -eq 1 ]] || die "disable-user requires exactly one USER positional argument"
  run_remove_user "$1"
}

run_enable_user() {
  local user=""
  local user_file

  run_mutation_preflight

  [[ $# -eq 1 ]] || die "enable-user requires exactly one USER positional argument"
  user="$1"
  [[ "${user}" != "${INTERNAL_USER}" ]] || die "enable-user must not target the fixed built-in user: ${user}"
  [[ "${user}" != "${BACKUP_DASHBOARD_EXPORT_USER}" ]] || die "enable-user must not target the fixed built-in user: ${user}"
  user_file="$(disabled_user_file_path "${user}")"
  [[ -f "${user_file}" ]] || die "No disabled managed user file found for ${user}: ${user_file}"
  [[ ! -e "$(active_user_file_path "${user}")" ]] || die "Active managed user file already exists for ${user}"

  move_disabled_file_to_live "${user_file}"
  enable_disabled_share_files_for_user "${user}"
  run_apply "$@"
}

run_disable_share() {
  local share=""
  local share_file

  run_mutation_preflight

  [[ $# -eq 1 ]] || die "disable-share requires exactly one SHARE positional argument"
  share="$1"
  share_file="$(active_share_file_path "${share}")"
  [[ -f "${share_file}" ]] || die "No active managed share file found for ${share}: ${share_file}"

  move_live_file_to_disabled "${share_file}"
  run_apply "$@"
}

run_remove_share() {
  [[ $# -eq 1 ]] || die "remove-share requires exactly one SHARE positional argument"
  run_disable_share "$1"
}

run_enable_share() {
  local share=""
  local disabled_share_file

  run_mutation_preflight

  [[ $# -eq 1 ]] || die "enable-share requires exactly one SHARE positional argument"
  share="$1"
  disabled_share_file="$(disabled_share_file_path "${share}")"
  [[ -f "${disabled_share_file}" ]] || die "No disabled managed share file found for ${share}: ${disabled_share_file}"

  move_disabled_file_to_live "${disabled_share_file}"
  run_apply "$@"
}

usage() {
  local self_cmd
  self_cmd="${SELF_CMD}"
  cat <<EOF_USAGE
Usage:
  sudo -E ${self_cmd} write-config [--config-dir DIR]
  sudo -E ${self_cmd} [--config-dir DIR] verify-config
  sudo -E ${self_cmd} [--config-dir DIR] apply
  ${self_cmd} [--config-dir DIR] list-users
  ${self_cmd} [--config-dir DIR] list-shares
  ${self_cmd} [--config-dir DIR] show-user USER
  ${self_cmd} [--config-dir DIR] show-share SHARE
  sudo -E ${self_cmd} [--config-dir DIR] add-user USER [--purpose client|service|admin] [--default-access yes|no] [--private-home yes|no] [--private-archive yes|no] [--path PATH] [--share SHARE]
      [--mode ro|rw] (--password-file FILE | --password-stdin)
  sudo -E ${self_cmd} [--config-dir DIR] disable-user USER
  sudo -E ${self_cmd} [--config-dir DIR] remove-user USER
  sudo -E ${self_cmd} [--config-dir DIR] enable-user USER
  sudo -E ${self_cmd} [--config-dir DIR] add-share SHARE --user USER --path PATH [--mode ro|rw]
  sudo -E ${self_cmd} [--config-dir DIR] remove-share SHARE
  sudo -E ${self_cmd} [--config-dir DIR] disable-share SHARE
  sudo -E ${self_cmd} [--config-dir DIR] enable-share SHARE
  sudo -E ${self_cmd} [--config-dir DIR] set-password USER (--password-file FILE | --password-stdin)

Commands:
  write-config   Create the active config/secrets template tree (with config_schema_version=${CONFIG_SCHEMA_VERSION_CURRENT}) and exit.
  verify-config  Validate the declared managed Samba model non-destructively.
  apply          Apply the declared managed Samba model from config files to the running system.
  list-users     Print the declared managed Samba users, share counts, and active/disabled state.
  list-shares    Print the declared managed Samba shares and their active/disabled state.
  show-user      Print one declared managed Samba user with its shares and state.
  show-share     Print one declared managed Samba share and state.
  add-user       Create one new managed principal file plus its secret and apply.
  remove-user    Deactivate one managed principal file (and its extra shares) by renaming them to .disabled, then apply.
  disable-user   Same non-destructive action as remove-user; useful when the intent is temporary deactivation.
  enable-user    Reactivate one disabled managed principal file and that user's disabled extra shares, then apply.
  add-share      Create one new extra-share file and apply.
  remove-share   Deactivate one declared share by renaming its live file(s) to .disabled, then apply.
  disable-share  Same non-destructive action as remove-share; useful when the intent is temporary deactivation.
  enable-share   Reactivate one disabled declared share without touching unrelated user files.
  set-password   Overwrite one secret file and apply so Samba picks up the new password.

Options:
  --config-dir DIR   Override the active config directory (default: /etc/penelope/samba-setup)
  --purpose PURPOSE  For add-user: client (default), service, or admin
  --default-access yes|no
                     For add-user: grant access to the standard Penelope shared workspace
  --private-home yes|no
                     For add-user: create/export a private home share
  --private-archive yes|no
                     For add-user: create/export a private archive share
  --path PATH        For add-user: private archive path; for add-share: absolute export path
  --share NAME       For add-user: private archive share name
  --mode MODE        For add-share: ro or rw (default: rw)
  --user USER        For add-share: owner of the extra share
  --password-file F  Read a new password from file F
  --password-stdin   Read a new password from stdin

Inspect commands are read-only: they validate and print the declared model
without provisioning accounts, rewriting smb.conf, or rotating passwords.
They read only the external config tree and tolerate missing/unreadable secrets
by treating them as change-me placeholders.

verify-config is also non-destructive. It validates the config tree, checks
password placeholders strictly, rejects unreferenced active secret files,
rejects share-name conflicts against active non-Penelope Samba shares when the
live config is inspectable, renders a managed-config candidate, and uses
testparm when available, but it does not provision accounts, rewrite smb.conf,
or reload Samba.

Write-side Day-2 commands mutate the external config tree first and then run
apply. They never delete Linux users, Samba accounts, home/data directories,
or secret-bearing files automatically. Deactivation is preserved as .disabled
files inside the config tree, and enable-user/enable-share rename them back to live
files before apply. Unsupported config_schema_version values fail loudly in this
pre-release series; no compatibility migration path is kept.

Apply (${VERSION}):
  - ensures Samba packages and Windows Explorer discovery support are installed
  - provisions local non-login Linux users and Samba users
  - creates declared user accounts, archive directories, shared work directories, and the shipped-default readonly Backup-Dashboard export account when enabled
  - renders managed Samba shares and wires them into smb.conf
  - validates the configuration and reloads Samba
  - enforces the standalone file-server service policy: smbd/nmbd/wsdd2 enabled, samba-ad-dc disabled
EOF_USAGE
}


ensure_samba_packages() {
  require_cmd_many getent useradd usermod groupadd systemctl runuser

  if have testparm && have pdbedit && have smbclient && have smbpasswd && have wsdd2; then
    log "Samba and Windows Explorer discovery packages already available"
    return 0
  fi

  log "Installing Samba and Windows Explorer discovery packages"
  apt_install samba smbclient wsdd2
  require_cmd_many testparm pdbedit smbclient smbpasswd wsdd2
}


systemd_unit_file_known() {
  local unit="$1"

  systemctl list-unit-files "${unit}" --no-pager --no-legend 2>/dev/null     | awk -v wanted="${unit}" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'
}


ensure_service_enabled_active() {
  local unit="$1"

  if ! systemctl enable --now "${unit}" >/dev/null; then
    die "Failed to enable/start required Samba standalone service: ${unit}"
  fi
  if ! systemctl is-active --quiet "${unit}"; then
    die "Required Samba standalone service is not active after enable/start: ${unit}"
  fi
  if ! systemctl is-enabled --quiet "${unit}"; then
    die "Required Samba standalone service is not enabled after enable/start: ${unit}"
  fi
}


ensure_service_disabled_inactive() {
  local unit="$1"

  if ! systemd_unit_file_known "${unit}"; then
    return 0
  fi

  if ! systemctl disable --now "${unit}" >/dev/null; then
    die "Failed to disable/stop service that is not used by Penelope standalone Samba: ${unit}"
  fi
  if systemctl is-active --quiet "${unit}"; then
    die "Service must be inactive for Penelope standalone Samba: ${unit}"
  fi
  if systemctl is-enabled --quiet "${unit}"; then
    die "Service must be disabled for Penelope standalone Samba: ${unit}"
  fi
}


ensure_standalone_samba_service_policy() {
  require_cmd systemctl

  log "Ensuring Samba standalone file-server services: smbd.service nmbd.service"
  ensure_service_enabled_active smbd.service
  ensure_service_enabled_active nmbd.service

  log "Ensuring Samba AD DC service is disabled for standalone file-server role"
  ensure_service_disabled_inactive samba-ad-dc.service
}

ensure_windows_discovery_service() {
  require_cmd_many systemctl wsdd2

  log "Ensuring Windows Explorer network discovery service: wsdd2.service"
  if ! systemctl enable --now wsdd2.service >/dev/null; then
    die "Failed to enable/start wsdd2.service for Windows Explorer network discovery"
  fi
  if systemctl is-active --quiet wsdd2.service; then
    log "Windows Explorer network discovery service active: wsdd2.service"
  else
    die "Windows Explorer network discovery service is not active after enable/start: wsdd2.service"
  fi
}

log_windows_discovery_status_for_verify() {
  if have wsdd2; then
    if systemctl is-active --quiet wsdd2.service 2>/dev/null; then
      log "  Windows Explorer network discovery: wsdd2.service active"
    else
      log "  Windows Explorer network discovery: wsdd2 installed; apply will enable/start wsdd2.service"
    fi
  else
    log "  Windows Explorer network discovery: wsdd2 not installed yet; apply will install/enable it"
  fi
}

validate_username() {
  local user="$1"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

validate_share_name() {
  local share="$1"

  [[ "$share" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$share" != "." && "$share" != ".." ]]
}

validate_share_name_not_reserved() {
  local share="$1"
  local lower

  lower="${share,,}"
  case "$lower" in
    global|homes|printers|print\$|ipc\$|admin\$)
      return 1
      ;;
  esac

  return 0
}

share_name_is_fixed_penelope_builtin() {
  local share="$1"
  local lower="${share,,}"

  case "$lower" in
    "${INTERNAL_HOME_SHARE_NAME,,}"|"${SHARED_RAWIN_SHARE_NAME,,}"|"${SHARED_SCAN_SHARE_NAME,,}"|"${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME,,}")
      return 0
      ;;
  esac

  return 1
}

validate_declared_share_name_not_fixed_penelope_builtin() {
  local share="$1"

  if share_name_is_fixed_penelope_builtin "$share"; then
    die "Share name is reserved for a fixed Penelope built-in export: ${share}"
  fi
}

validate_share_mode() {
  local mode="$1"
  [[ "$mode" == "ro" || "$mode" == "rw" ]]
}

validate_system_name() {
  local name="$1"
  [[ "$name" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]
}

validate_permission_mode() {
  local mode="$1"
  [[ "$mode" =~ ^0[0-7]{3}$|^[0-7]{4}$ ]]
}

derive_file_mode_from_directory_mode() {
  local mode="$1"
  local perm_bits file_bits

  validate_permission_mode "$mode" || die "Invalid directory mode for file-mode derivation: ${mode}"
  perm_bits=$(( 8#${mode#0} ))
  file_bits=$(( perm_bits & 8#0666 ))
  printf '0%03o\n' "${file_bits}"
}

normalize_share_path() {
  local path="$1"

  if [[ -z "$path" || "${path:0:1}" != "/" ]]; then
    die "Share path must be absolute: ${path}"
  fi

  if [[ "$path" == "." || "$path" == ".." || "$path" == *"/./"* || "$path" == *"/../"* || "$path" == *"/.." || "$path" == *"/." ]]; then
    die "Share path must not contain dot segments: ${path}"
  fi

  while [[ "$path" == *"//"* ]]; do
    path="${path//\/\//\/}"
  done

  if [[ "$path" != "/" ]]; then
    while [[ "$path" == */ ]]; do
      path="${path%/}"
    done
  fi

  if [[ "$path" == "/" ]]; then
    die "Share path must not be root: ${path}"
  fi

  printf '%s\n' "$path"
}

validate_password_value() {
  local user="$1"
  local password="$2"

  validate_secret_not_placeholder "Samba password for user ${user}" "${password}"
}

register_unique_name() {
  local kind="$1"
  local name="$2"
  local seen_ref_name="$3"
  local -n seen_names_ref="${seen_ref_name}"

  if [[ -n "${seen_names_ref["$name"]:-}" ]]; then
    die "Duplicate ${kind}: ${name}"
  fi
  seen_names_ref["$name"]="$kind"
}

register_unique_share_name() {
  local share="$1"
  local canonical="${share,,}"
  local seen_ref_name="$2"
  local -n seen_shares_ref="${seen_ref_name}"

  if [[ -n "${seen_shares_ref["$canonical"]:-}" ]]; then
    die "Duplicate share (case-insensitive): ${share}"
  fi
  seen_shares_ref["$canonical"]="$share"
}

emit_section_names_from_samba_config_stream() {
  local line section

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim_trailing_cr "${line}")"
    if [[ "${line}" =~ ^[[:space:]]*\[([^][]+)\][[:space:]]*([#;].*)?$ ]]; then
      section="$(trim_ascii_whitespace "${BASH_REMATCH[1]}")"
      [[ -n "${section}" ]] && printf '%s\n' "${section}"
    fi
  done
}

emit_section_names_from_samba_config_file_recursive() {
  local file="$1"
  local skip_file="$2"
  local seen_files_ref_name="$3"
  local -n seen_files_ref="${seen_files_ref_name}"
  local line include_path resolved_file resolved_skip

  [[ -r "${file}" ]] || return 0

  resolved_file="$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")"
  resolved_skip="$(readlink -f -- "${skip_file}" 2>/dev/null || printf '%s' "${skip_file}")"
  [[ "${resolved_file}" == "${resolved_skip}" ]] && return 0

  if [[ -n "${seen_files_ref[${resolved_file}]:-}" ]]; then
    return 0
  fi
  seen_files_ref["${resolved_file}"]=1

  emit_section_names_from_samba_config_stream < "${file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(trim_trailing_cr "${line}")"
    [[ "${line}" =~ ^[[:space:]]*include[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    include_path="${BASH_REMATCH[1]}"
    include_path="${include_path%%[;#]*}"
    include_path="$(trim_ascii_whitespace "${include_path}")"
    include_path="$(strip_optional_wrapping_double_quotes "${include_path}")"
    [[ -n "${include_path}" ]] || continue

    if [[ "${include_path}" == *%* ]]; then
      warn "Skipping literal include-tree share scan for dynamic Samba include path: ${include_path}"
      continue
    fi

    emit_section_names_from_samba_config_file_recursive "${include_path}" "${skip_file}" seen_files_ref
  done < "${file}"
}

emit_live_active_share_section_names() {
  if have testparm && [[ -r "${SAMBA_MAIN_CONF}" ]]; then
    testparm -s "${SAMBA_MAIN_CONF}" 2>/dev/null | emit_section_names_from_samba_config_stream
    return 0
  fi

  if [[ -r "${SAMBA_MAIN_CONF}" ]]; then
    local -A seen_files=()
    : "${#seen_files[@]}"
    emit_section_names_from_samba_config_file_recursive "${SAMBA_MAIN_CONF}" "${SAMBA_MANAGED_CONF}" seen_files
    return 0
  fi

  return 1
}

emit_current_managed_share_section_names() {
  [[ -r "${SAMBA_MANAGED_CONF}" ]] || return 0
  emit_section_names_from_samba_config_stream < "${SAMBA_MANAGED_CONF}"
}

validate_declared_share_names_do_not_conflict_with_active_external_samba() {
  local enforcement_mode="${1:-strict}"
  local share path user mode origin lower tmp_sections
  local -A current_managed_shares=()
  local -A external_active_shares=()

  if ! have testparm && [[ ! -r "${SAMBA_MAIN_CONF}" ]]; then
    case "${enforcement_mode}" in
      best-effort)
        log "Skipping external Samba share-name conflict scan because no inspectable active Samba config exists yet; apply will install or prepare Samba and validate the generated configuration"
        return 0
        ;;
      strict)
        die "Cannot inspect active Samba config for external share-name conflict enforcement: ${SAMBA_MAIN_CONF}"
        ;;
      *)
        die "Unsupported share-name conflict enforcement mode: ${enforcement_mode}"
        ;;
    esac
  fi

  while IFS= read -r share; do
    [[ -n "${share}" ]] || continue
    lower="${share,,}"
    [[ "${lower}" == "global" ]] && continue
    current_managed_shares["${lower}"]="${share}"
  done < <(emit_current_managed_share_section_names)

  tmp_sections="$(mktemp)" || die "Failed to allocate temporary share-section scan file"
  if ! emit_live_active_share_section_names > "${tmp_sections}"; then
    rm -f "${tmp_sections}" || true
    case "${enforcement_mode}" in
      best-effort)
        log "Skipping external Samba share-name conflict scan because no inspectable active Samba config exists yet; apply will install or prepare Samba and validate the generated configuration"
        return 0
        ;;
      strict)
        die "Cannot inspect active Samba config for external share-name conflict enforcement: ${SAMBA_MAIN_CONF}"
        ;;
      *)
        die "Unsupported share-name conflict enforcement mode: ${enforcement_mode}"
        ;;
    esac
  fi

  while IFS= read -r share; do
    [[ -n "${share}" ]] || continue
    lower="${share,,}"
    [[ "${lower}" == "global" ]] && continue
    [[ -n "${current_managed_shares[${lower}]:-}" ]] && continue
    external_active_shares["${lower}"]="${share}"
  done < "${tmp_sections}"
  rm -f "${tmp_sections}" || true

  while IFS=$'\t' read -r share path user mode origin; do
    [[ -n "${share}" ]] || continue
    lower="${share,,}"
    if [[ -n "${external_active_shares[${lower}]:-}" ]]; then
      die "Managed Samba share name conflicts with an active non-Penelope share outside ${SAMBA_MANAGED_CONF}: ${share}"
    fi
  done < <(emit_all_share_rows)
}


assert_extra_share_does_not_touch_canonical_backup_dashboard_tree() {
  local path="$1"

  if [[ "$path" != "$CANONICAL_BACKUP_DASHBOARD_DIR" && "$CANONICAL_BACKUP_DASHBOARD_DIR" == "$path"/* ]]; then
    die "Extra share path must not encompass the canonical Backup-Dashboard tree and leak neighboring data: ${path} includes ${CANONICAL_BACKUP_DASHBOARD_DIR}"
  fi

  if [[ "$path" == "$CANONICAL_BACKUP_DASHBOARD_DIR" || "$path" == "$CANONICAL_BACKUP_DASHBOARD_DIR"/* ]]; then
    local msg=""
    msg="Canonical Backup-Dashboard tree is reserved for the dedicated "
    msg+="${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} export; do not configure it "
    msg+="via SAMBA_EXTRA_SHARES: ${path}"
    die "${msg}"
  fi
}
register_non_overlapping_share_path() {
  local path="$1"
  local mode="$2"
  local seen_ref_name="$3"
  local -n seen_paths_ref="${seen_ref_name}"
  local existing

  for existing in "${!seen_paths_ref[@]}"; do
    if [[ "$path" == "$existing" ]]; then
      die "Duplicate share path: ${path}"
    fi

    if [[ "$mode" == "ro" && "$existing" == "$INTERNAL_HOME" && "$path" == "$INTERNAL_HOME"/* ]]; then
      die "Readonly child share under ${INTERNAL_HOME} is not allowed while the built-in ${INTERNAL_HOME_SHARE_NAME} share exports the same tree as rw: ${path}"
    fi

    if [[ "$path" == "$existing"/* || "$existing" == "$path"/* ]]; then
      die "Overlapping share paths are not allowed: ${path} conflicts with ${existing}"
    fi
  done

  # shellcheck disable=SC2034  # Bash nameref write; ShellCheck cannot see caller-visible output accumulator use.
  seen_paths_ref["$path"]="share path"
}

split_archive_user_entry() {
  local entry="$1"
  local user password tail

  IFS=':' read -r user password tail <<< "$entry"
  if [[ -n "$tail" || -z "$user" || -z "$password" ]]; then
    die "Invalid CRED_SAMBA_ARCHIVE_USERS entry: ${entry} (expected username:password)"
  fi

  printf '%s	%s
' "$user" "$password"
}

split_simple_samba_user_entry() {
  local entry="$1"
  local label="$2"
  local user password tail

  IFS=':' read -r user password tail <<< "$entry"
  if [[ -n "$tail" || -z "$user" || -z "$password" ]]; then
    die "Invalid ${label} entry: ${entry} (expected username:password)"
  fi

  printf '%s	%s
' "$user" "$password"
}

split_managed_share_entry() {
  local entry="$1"
  local user password path share mode tail

  IFS=':' read -r user password path share mode tail <<< "$entry"
  if [[ -n "$tail" || -z "$user" || -z "$password" || -z "$path" || -z "$share" || -z "$mode" ]]; then
    die "Invalid CRED_MANAGED_SAMBA_SHARES entry: ${entry} (expected username:password:path:share:mode)"
  fi

  printf '%s	%s	%s	%s	%s
' "$user" "$password" "$path" "$share" "$mode"
}

split_extra_share_entry() {
  local entry="$1"
  local path share user mode tail

  IFS=':' read -r path share user mode tail <<< "$entry"
  if [[ -n "$tail" || -z "$path" || -z "$share" || -z "$user" || -z "$mode" ]]; then
    die "Invalid SAMBA_EXTRA_SHARES entry: ${entry} (expected path:share:user:mode)"
  fi

  printf '%s	%s	%s	%s
' "$path" "$share" "$user" "$mode"
}

declared_user_kind_for_user() {
  local target_user="$1"
  local entry user password purpose

  for entry in "${OPERATOR_DECLARED_USERS[@]}"; do
    IFS=$'\t' read -r user password purpose <<< "$(split_declared_user_entry "${entry}")"
    [[ "${user}" == "${target_user}" ]] || continue
    printf '%s\n' "${purpose}"
    return 0
  done

  return 1
}

user_has_default_access() {
  local user="$1"
  [[ "${OPERATOR_USER_DEFAULT_ACCESS[$user]:-no}" == "yes" ]]
}

user_has_private_home() {
  local user="$1"
  [[ "${OPERATOR_USER_PRIVATE_HOME[$user]:-no}" == "yes" ]]
}

account_home_for_user() {
  local user="$1"
  if user_has_private_home "${user}"; then
    printf '%s\n' "${OPERATOR_USER_HOME_PATH[$user]:-/home/${user}}"
  else
    printf '/nonexistent\n'
  fi
}

emit_managed_account_rows() {
  local entry user password purpose home

  for entry in "${OPERATOR_DECLARED_USERS[@]}"; do
    IFS=$'\t' read -r user password purpose <<< "$(split_declared_user_entry "${entry}")"
    home="$(account_home_for_user "${user}")"
    printf '%s\t%s\t%s\t%s\n' "$user" "$password" "$home" "$purpose"
  done

  if backup_dashboard_export_requested; then
    printf '%s\t%s\t%s\t%s\n' \
      "$BACKUP_DASHBOARD_EXPORT_USER" "$CRED_BACKUP_DASHBOARD_PASSWORD" \
      "$BACKUP_DASHBOARD_EXPORT_ACCOUNT_HOME" "backup_dashboard_export"
  fi
}

emit_primary_share_rows() {
  local entry user path share mode origin

  for entry in "${OPERATOR_DECLARED_PRIMARY_SHARES[@]}"; do
    IFS=$'\t' read -r user path share mode origin <<< "$(split_declared_primary_share_entry "${entry}")"
    path="$(normalize_share_path "$path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$share" "$path" "$user" "$mode" "$origin"
  done

  printf '%s\t%s\t%s\t%s\t%s\n' "$SHARED_RAWIN_SHARE_NAME" "$SHARED_RAWIN_DIR" "root" "rw" "shared_rawin"
  printf '%s\t%s\t%s\t%s\t%s\n' "$SHARED_SCAN_SHARE_NAME" "$SHARED_SCAN_DIR" "root" "rw" "shared_scan"
  printf '%s\t%s\t%s\t%s\t%s\n' "$INTERNAL_HOME_SHARE_NAME" "$INTERNAL_HOME" "root" "rw" "internal_home"

  if backup_dashboard_export_requested; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$CANONICAL_BACKUP_DASHBOARD_SHARE_NAME" "$CANONICAL_BACKUP_DASHBOARD_DIR" \
      "$BACKUP_DASHBOARD_EXPORT_USER" "ro" "backup_dashboard_export"
  fi
}

emit_extra_share_rows() {
  local entry path share user mode

  for entry in "${SAMBA_EXTRA_SHARES[@]}"; do
    IFS=$'\t' read -r path share user mode <<< "$(split_extra_share_entry "$entry")"
    path="$(normalize_share_path "$path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$share" "$path" "$user" "$mode" "extra_export"
  done
}

emit_all_share_rows() {
  emit_primary_share_rows
  emit_extra_share_rows
}

emit_disabled_managed_account_rows() {
  local file
  local -A kv=()
  local user purpose private_home home

  shopt -s nullglob
  for file in "${OPERATOR_USERS_DIR}"/*.conf.disabled; do
    [[ -e "${file}" ]] || continue
    kv=()
    load_simple_kv_file_into_assoc "${file}" kv
    user="${kv[user]:-}"
    purpose="${kv[purpose]:-client}"
    private_home="${kv[private_home]:-no}"
    [[ -n "${user}" ]] || continue
    if [[ "${private_home}" == "yes" ]]; then
      home="${kv[home_path]:-/home/${user}}"
    else
      home="/nonexistent"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${user}" "-" "${home}" "${purpose}" "disabled"
  done
  shopt -u nullglob
}

emit_all_managed_account_rows_with_state() {
  local user password home kind state

  while IFS=$'	' read -r user password home kind; do
    [[ -n "${user}" ]] || continue
    printf '%s	%s	%s	%s	%s
' "${user}" "${password}" "${home}" "${kind}" "active"
  done < <(emit_managed_account_rows)

  while IFS=$'	' read -r user password home kind state; do
    [[ -n "${user}" ]] || continue
    printf '%s	%s	%s	%s	%s
' "${user}" "${password}" "${home}" "${kind}" "${state}"
  done < <(emit_disabled_managed_account_rows)
}

emit_disabled_primary_share_rows() {
  return 0
}

emit_disabled_extra_share_rows() {
  local file
  local -A kv=()
  local share path user mode

  shopt -s nullglob
  for file in "${OPERATOR_SHARES_DIR}"/*.conf.disabled; do
    [[ -e "${file}" ]] || continue
    kv=()
    load_simple_kv_file_into_assoc "${file}" kv
    [[ "${kv[kind]:-extra}" == "extra" ]] || continue
    share="${kv[share]:-}"
    path="${kv[path]:-}"
    user="${kv[user]:-}"
    mode="${kv[mode]:-rw}"
    [[ -n "${share}" ]] || continue
    path="$(normalize_share_path "${path}")"
    printf '%s	%s	%s	%s	%s	%s
' "${share}" "${path}" "${user}" "${mode}" "extra_export" "disabled"
  done
  shopt -u nullglob
}

emit_all_share_rows_with_state() {
  local share path user mode origin

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "${share}" ]] || continue
    printf '%s	%s	%s	%s	%s	%s
' "${share}" "${path}" "${user}" "${mode}" "${origin}" "active"
  done < <(emit_all_share_rows)

  emit_disabled_primary_share_rows
  emit_disabled_extra_share_rows
}

print_user_list() {
  local user password home kind state share path owner mode origin share_state
  local primary_count extra_count

  printf 'user	purpose	account_home	share_count	extra_share_count	state
'
  while IFS=$'	' read -r user password home kind state; do
    [[ -n "$user" ]] || continue
    primary_count=0
    extra_count=0

    while IFS=$'	' read -r share path owner mode origin share_state; do
      [[ -n "$share" ]] || continue
      [[ "$owner" == "$user" ]] || continue
      if [[ "$origin" == "extra_export" ]]; then
        ((extra_count+=1))
      else
        ((primary_count+=1))
      fi
    done < <(emit_all_share_rows_with_state)

    printf '%s	%s	%s	%s	%s	%s
' "$user" "$kind" "$home" "$primary_count" "$extra_count" "$state"
  done < <(emit_all_managed_account_rows_with_state)
}

print_share_list() {
  local share path user mode origin state

  printf 'share	path	user	mode	origin	state
'
  while IFS=$'	' read -r share path user mode origin state; do
    [[ -n "$share" ]] || continue
    printf '%s	%s	%s	%s	%s	%s
' "$share" "$path" "$user" "$mode" "$origin" "$state"
  done < <(emit_all_share_rows_with_state)
}

show_user() {
  local target_user="$1"
  local user password home kind state share path owner mode origin share_state
  local found=0
  local printed_share=0

  while IFS=$'	' read -r user password home kind state; do
    [[ -n "$user" ]] || continue
    [[ "$user" == "$target_user" ]] || continue
    found=1
    printf 'user: %s
' "$user"
    printf 'purpose: %s
' "$kind"
    printf 'home: %s
' "$home"
    printf 'state: %s
' "$state"
    printf 'shares:
'
    break
  done < <(emit_all_managed_account_rows_with_state)

  (( found )) || die "Unknown managed Samba user: ${target_user}"

  while IFS=$'	' read -r share path owner mode origin share_state; do
    [[ -n "$share" ]] || continue
    [[ "$owner" == "$target_user" ]] || continue
    printed_share=1
    printf '  - %s -> %s (mode=%s, origin=%s, state=%s)
' "$share" "$path" "$mode" "$origin" "$share_state"
  done < <(emit_all_share_rows_with_state)

  if (( ! printed_share )); then
    printf '  - none
'
  fi
}

show_share() {
  local target_share="$1"
  local share path user mode origin state

  while IFS=$'	' read -r share path user mode origin state; do
    [[ -n "$share" ]] || continue
    [[ "$share" == "$target_share" ]] || continue
    printf 'share: %s
' "$share"
    printf 'path: %s
' "$path"
    printf 'user: %s
' "$user"
    printf 'mode: %s
' "$mode"
    printf 'origin: %s
' "$origin"
    printf 'state: %s
' "$state"
    return 0
  done < <(emit_all_share_rows_with_state)

  die "Unknown managed Samba share: ${target_share}"
}

run_inspect_command() {
  local command="$1"

  load_operator_model_from_config_dir
  resolve_canonical_backup_dashboard_dir inspect
  validate_operator_topology

  case "$command" in
    list-users)
      [[ $# -eq 1 ]] || die "list-users does not take additional arguments"
      print_user_list
      ;;
    list-shares)
      [[ $# -eq 1 ]] || die "list-shares does not take additional arguments"
      print_share_list
      ;;
    show-user)
      [[ $# -eq 2 ]] || die "show-user requires exactly one USER argument"
      show_user "$2"
      ;;
    show-share)
      [[ $# -eq 2 ]] || die "show-share requires exactly one SHARE argument"
      show_share "$2"
      ;;
    *)
      die "Unsupported inspect command: ${command}"
      ;;
  esac
}

run_verify_config() {
  [[ $# -eq 0 ]] || die "verify-config does not take additional arguments"

  require_root "${SELF_CMD}"
  require_cmd getent
  require_operator_config_tree
  load_operator_model_from_config_dir
  resolve_canonical_backup_dashboard_dir
  validate_operator_config
  validate_configured_groups_safe
  validate_configured_accounts_safe
  validate_declared_share_names_do_not_conflict_with_active_external_samba best-effort

  local tmp_candidate self_cmd
  tmp_candidate="$(mktemp "${TMPDIR:-/tmp}/penelope-samba-verify.XXXXXX.conf")" || die "Failed to allocate temporary managed Samba config candidate"
  trap '[[ -n "${tmp_candidate:-}" && -e "${tmp_candidate:-}" ]] && rm -f "${tmp_candidate:-}"' RETURN

  render_managed_conf_to_path "${tmp_candidate}" best-effort

  self_cmd="${SELF_CMD}"
  log "Samba config verification succeeded"
  log "  Config dir: ${OPERATOR_CONFIG_DIR}"
  log "  Config schema: ${OPERATOR_CONFIG_SCHEMA_VERSION}"
  log "  Candidate managed config render: ok"
  log "  Samba security baseline: server_min=${SMB_SERVER_MIN_PROTOCOL} client_min=${SMB_CLIENT_MIN_PROTOCOL} ntlm_auth=${SMB_NTLM_AUTH}"
  log_windows_discovery_status_for_verify
  if backup_dashboard_export_requested; then
    log "  Backup-Dashboard export: enabled"
    log "    share=${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} path=${CANONICAL_BACKUP_DASHBOARD_DIR}"
    log "    user=${BACKUP_DASHBOARD_EXPORT_USER} mode=ro source=${CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE}"
  elif [[ "${CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE}" == "default" ]]; then
    log "  Backup-Dashboard export: disabled (source=default)"
  else
    log "  Backup-Dashboard export: disabled"
  fi
  log "  Next step: sudo -E ${self_cmd} --config-dir ${OPERATOR_CONFIG_DIR} apply"

  rm -f -- "${tmp_candidate}" || true
  trap - RETURN
}

run_apply() {
  [[ $# -eq 0 ]] || die "apply does not take additional arguments"

  require_root "${SELF_CMD}"
  require_cmd getent
  require_operator_config_tree
  load_operator_model_from_config_dir
  resolve_canonical_backup_dashboard_dir
  validate_operator_config
  validate_configured_groups_safe
  validate_configured_accounts_safe
  ensure_samba_packages
  log_samba_host_crypto_watchpoint_for_apply
  refresh_operator_package_owned_examples
  ensure_standalone_samba_service_policy
  ensure_windows_discovery_service
  penelope_refresh_installed_common_lib "${SCRIPT_DIR}/penelope-common.sh"
  validate_declared_share_names_do_not_conflict_with_active_external_samba strict
  ensure_base_directories
  ensure_samba_accounts
  log "Ensuring managed Samba config layout"
  ensure_dir "$SAMBA_DROPIN_DIR" 0755 root root
  ensure_file "$SAMBA_MANAGED_CONF" 0644 root root
  ensure_main_include
  render_managed_conf
  validate_and_reload_samba
  persist_sanitized_recovery_stage
  print_summary
}

validate_operator_topology() {
  local user password home kind share path mode origin entry
  local -A seen_users=()
  # shellcheck disable=SC2034  # Bash nameref target used by helper calls below; ShellCheck cannot model this indirection.
  local -A seen_shares=()
  # shellcheck disable=SC2034  # Bash nameref target used by helper calls below; ShellCheck cannot model this indirection.
  local -A seen_paths=()
  local -A primary_share_counts=()

  if ! validate_username "$INTERNAL_USER"; then
    die "Invalid INTERNAL_USER: ${INTERNAL_USER}"
  fi
  if [[ "$INTERNAL_USER" != "internal" ]]; then
    die "INTERNAL_USER is fixed to internal in this release: ${INTERNAL_USER}"
  fi

  if ! validate_username "$BACKUP_DASHBOARD_EXPORT_USER"; then
    die "Invalid BACKUP_DASHBOARD_EXPORT_USER: ${BACKUP_DASHBOARD_EXPORT_USER}"
  fi
  if [[ "$BACKUP_DASHBOARD_EXPORT_USER" != "backup_dashboard" ]]; then
    die "BACKUP_DASHBOARD_EXPORT_USER is fixed to backup_dashboard in this release: ${BACKUP_DASHBOARD_EXPORT_USER}"
  fi

  if ! validate_system_name "$RO_EXTRA_SHARE_CREATE_OWNER"; then
    die "Invalid RO_EXTRA_SHARE_CREATE_OWNER: ${RO_EXTRA_SHARE_CREATE_OWNER}"
  fi
  if ! validate_system_name "$RO_EXTRA_SHARE_CREATE_GROUP"; then
    die "Invalid RO_EXTRA_SHARE_CREATE_GROUP: ${RO_EXTRA_SHARE_CREATE_GROUP}"
  fi
  if ! validate_permission_mode "$RO_EXTRA_SHARE_CREATE_MODE"; then
    die "Invalid RO_EXTRA_SHARE_CREATE_MODE: ${RO_EXTRA_SHARE_CREATE_MODE}"
  fi
  if ! validate_permission_mode "$RW_EXTRA_SHARE_CREATE_MODE"; then
    die "Invalid RW_EXTRA_SHARE_CREATE_MODE: ${RW_EXTRA_SHARE_CREATE_MODE}"
  fi
  if ! validate_system_name "$STANDARD_CLIENT_GROUP"; then
    die "Invalid standard_client_group: ${STANDARD_CLIENT_GROUP}"
  fi
  if ! validate_system_name "$SCAN_INBOX_GROUP"; then
    die "Invalid scan_inbox_group: ${SCAN_INBOX_GROUP}"
  fi
  if ! validate_permission_mode "$SHARED_WORK_DIR_MODE"; then
    die "Invalid shared_work_dir_mode: ${SHARED_WORK_DIR_MODE}"
  fi
  if ! validate_permission_mode "$SHARED_WORK_CREATE_MASK"; then
    die "Invalid shared_work_create_mask: ${SHARED_WORK_CREATE_MASK}"
  fi
  if ! validate_permission_mode "$SHARED_WORK_DIRECTORY_MASK"; then
    die "Invalid shared_work_directory_mask: ${SHARED_WORK_DIRECTORY_MASK}"
  fi
  validate_smb_protocol_value "$SMB_SERVER_MIN_PROTOCOL" || die "Invalid smb_server_min_protocol: ${SMB_SERVER_MIN_PROTOCOL}"
  validate_smb_protocol_value "$SMB_CLIENT_MIN_PROTOCOL" || die "Invalid smb_client_min_protocol: ${SMB_CLIENT_MIN_PROTOCOL}"
  validate_smb_ntlm_auth_value "$SMB_NTLM_AUTH" || die "Invalid smb_ntlm_auth: ${SMB_NTLM_AUTH}"

  case "$ENABLE_BACKUP_DASHBOARD_SHARE" in
    0|1)
      ;;
    *)
      die "ENABLE_BACKUP_DASHBOARD_SHARE must be 0 or 1: ${ENABLE_BACKUP_DASHBOARD_SHARE}"
      ;;
  esac

  while IFS=$'	' read -r user password home kind; do
    [[ -n "$user" ]] || continue

    if ! validate_username "$user"; then
      die "Invalid managed Samba username: ${user}"
    fi
    register_unique_name "user" "$user" seen_users
  done < <(emit_managed_account_rows)

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue

    if ! validate_share_name "$share"; then
      die "Invalid managed share name: ${share}"
    fi
    if ! validate_share_name_not_reserved "$share"; then
      die "Managed share name must not use a reserved Samba section name: ${share}"
    fi
    case "$origin" in
      archive_primary|home_primary)
        validate_declared_share_name_not_fixed_penelope_builtin "$share"
        ;;
      shared_rawin|shared_scan|internal_home|backup_dashboard_export)
        ;;
      *)
        die "Unknown primary share origin in topology validation: ${origin}"
        ;;
    esac
    if ! validate_share_mode "$mode"; then
      die "Invalid managed share mode for ${share}: ${mode}"
    fi
    assert_share_path_has_no_symlink_components "$path"
    if [[ "$origin" == "home_primary" || "$origin" == "archive_primary" ]]; then
      assert_extra_share_does_not_touch_canonical_backup_dashboard_tree "$path"
    fi

    case "$origin" in
      archive_primary)
        [[ -n "${seen_users[$user]:-}" ]] || die "Archive primary share user must be a declared managed Samba user: ${user}"
        [[ "$path" == "${ARCHIVE_ROOT}/${user}" ]] || die "Archive primary share for ${user} must use canonical path ${ARCHIVE_ROOT}/${user}: ${path}"
        [[ "$mode" == "rw" ]] || die "Archive primary share for ${user} must use mode rw: ${mode}"
        ;;
      home_primary)
        [[ -n "${seen_users[$user]:-}" ]] || die "Home primary share user must be a declared managed Samba user: ${user}"
        ;;
      backup_dashboard_export)
        [[ -n "${seen_users[$user]:-}" ]] || die "Backup-Dashboard export user must be a declared managed Samba user: ${user}"
        ;;
      shared_rawin|shared_scan|internal_home)
        ;;
      *)
        die "Unknown primary share origin in topology validation: ${origin}"
        ;;
    esac

    if [[ -n "${seen_users[$user]:-}" ]]; then
      ((primary_share_counts[$user]+=1))
    fi
    register_unique_share_name "$share" seen_shares
    register_non_overlapping_share_path "$path" "$mode" seen_paths
  done < <(emit_primary_share_rows)


  if ! getent passwd "$RO_EXTRA_SHARE_CREATE_OWNER" >/dev/null 2>&1 && [[ -z "${seen_users[$RO_EXTRA_SHARE_CREATE_OWNER]:-}" ]]; then
    die "RO_EXTRA_SHARE_CREATE_OWNER must exist on this system or match a managed Samba user: ${RO_EXTRA_SHARE_CREATE_OWNER}"
  fi
  if ! getent group "$RO_EXTRA_SHARE_CREATE_GROUP" >/dev/null 2>&1 && [[ -z "${seen_users[$RO_EXTRA_SHARE_CREATE_GROUP]:-}" ]]; then
    die "RO_EXTRA_SHARE_CREATE_GROUP must exist on this system or match a managed Samba user/group: ${RO_EXTRA_SHARE_CREATE_GROUP}"
  fi

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue

    if ! validate_share_name "$share"; then
      die "Invalid extra share name: ${share}"
    fi
    if ! validate_share_name_not_reserved "$share"; then
      die "Extra share name must not use a reserved Samba section name: ${share}"
    fi
    validate_declared_share_name_not_fixed_penelope_builtin "$share"
    if ! validate_username "$user"; then
      die "Invalid extra share user: ${user}"
    fi
    if ! validate_share_mode "$mode"; then
      die "Invalid extra share mode for ${share}: ${mode}"
    fi
    if [[ -z "${seen_users[$user]:-}" ]]; then
      local msg=""
      msg="Extra share user must be a declared managed Samba user; "
      msg+="fixed built-in share names and the dedicated dashboard export user are not available for extra shares: ${user}"
      die "${msg}"
    fi
    if [[ "$user" == "$BACKUP_DASHBOARD_EXPORT_USER" ]]; then
      die "Extra share user must not be the dedicated dashboard export user: ${user}"
    fi

    local access_name
    for access_name in ${SHARE_ALLOWED_USERS[$share]:-}; do
      validate_username "$access_name" || die "Invalid allowed_users entry for ${share}: ${access_name}"
      [[ -n "${seen_users[$access_name]:-}" ]] || die "Extra share ${share} allowed_users references unmanaged user: ${access_name}"
    done
    for access_name in ${SHARE_ALLOWED_GROUPS[$share]:-}; do
      validate_system_name "$access_name" || die "Invalid allowed_groups entry for ${share}: ${access_name}"
    done
    if [[ -n "${SHARE_FORCE_GROUP[$share]:-}" ]]; then
      validate_system_name "${SHARE_FORCE_GROUP[$share]}" || die "Invalid force_group for ${share}: ${SHARE_FORCE_GROUP[$share]}"
    fi

    assert_share_path_has_no_symlink_components "$path"
    assert_extra_share_does_not_touch_canonical_backup_dashboard_tree "$path"
    register_unique_share_name "$share" seen_shares
    register_non_overlapping_share_path "$path" "$mode" seen_paths
  done < <(emit_extra_share_rows)
}

validate_operator_passwords() {
  local user password home kind

  if backup_dashboard_export_requested; then
    validate_password_value "$BACKUP_DASHBOARD_EXPORT_USER" "$CRED_BACKUP_DASHBOARD_PASSWORD"
  fi

  while IFS=$'	' read -r user password home kind; do
    [[ -n "$user" ]] || continue
    validate_password_value "$user" "$password"
  done < <(emit_managed_account_rows)
}


validate_active_secret_files_match_declared_model() {
  local user password home kind state file base secret_user
  local -A allowed_secret_users=()

  while IFS=$'	' read -r user password home kind state; do
    [[ -n "$user" ]] || continue
    allowed_secret_users["$user"]=1
  done < <(emit_all_managed_account_rows_with_state)

  shopt -s nullglob
  for file in "${OPERATOR_SECRETS_DIR}"/*.secret; do
    [[ -e "$file" ]] || continue
    base="${file##*/}"
    secret_user="${base%.secret}"
    if [[ -z "${allowed_secret_users[$secret_user]:-}" ]]; then
      shopt -u nullglob
      die "Unreferenced active Samba secret file: ${file}. Remove it or restore a matching users.d/*.conf[.disabled] entry; current-only RC configs must not keep unused active secrets."
    fi
  done
  shopt -u nullglob
}


validate_operator_config() {
  validate_operator_topology
  validate_operator_passwords
  validate_active_secret_files_match_declared_model
}


validate_existing_account_safe() {
  local user="$1"
  local expected_home="$2"
  local passwd_line uid home shell

  passwd_line="$(getent passwd "$user" || true)"
  [[ -n "$passwd_line" ]] || return 0

  IFS=':' read -r _ _ uid _ _ home shell <<< "$passwd_line"

  if [[ "$user" == "root" ]]; then
    die "Configured Samba user must not be root"
  fi

  if [[ "$OPERATOR_USER" != "root" && "$user" == "$OPERATOR_USER" ]]; then
    die "Configured Samba user must not match the invoking operator account: ${user}"
  fi

  if (( uid < 1000 )); then
    die "Configured Samba user must not reuse an existing system account: ${user} (uid=${uid})"
  fi

  case "$shell" in
    "$NONLOGIN_SHELL")
      ;;
    *)
      die "Configured Samba user must not reuse an existing login-capable account: ${user} (shell=${shell})"
      ;;
  esac

  if [[ -n "$home" && "$home" != "$expected_home" ]]; then
    warn "Existing non-login account ${user} will be repointed from ${home} to ${expected_home}"
  fi
}

validate_configured_accounts_safe() {
  local user password home kind
  local -A desired_home=()

  while IFS=$'	' read -r user password home kind; do
    [[ -n "$user" ]] || continue
    desired_home["$user"]="$home"
  done < <(emit_managed_account_rows)

  for user in "${!desired_home[@]}"; do
    validate_existing_account_safe "$user" "${desired_home[$user]}"
  done
}


validate_existing_group_safe() {
  local group="$1"
  local group_line gid

  group_line="$(getent group "$group" || true)"
  [[ -n "$group_line" ]] || return 0

  IFS=':' read -r _ _ gid _ <<< "$group_line"

  if [[ "$group" == "root" ]]; then
    die "Configured Samba group must not be root"
  fi

  if (( gid < 1000 )); then
    die "Configured Samba group must not reuse an existing system group: ${group} (gid=${gid})"
  fi

  if ! getent passwd "$group" >/dev/null 2>&1; then
    die "Configured Samba group must not reuse an existing local group without a matching local account: ${group}"
  fi
}

validate_existing_penelope_access_group_safe() {
  local group="$1"
  local group_line gid

  group_line="$(getent group "$group" || true)"
  [[ -n "$group_line" ]] || return 0

  IFS=':' read -r _ _ gid _ <<< "$group_line"

  if [[ "$group" == "root" ]]; then
    die "Penelope Samba access group must not be root"
  fi

  if (( gid < 1000 )); then
    die "Penelope Samba access group must not reuse an existing system group: ${group} (gid=${gid})"
  fi
}

validate_configured_groups_safe() {
  local user password home purpose group share
  local -A local_user_groups=()
  local -A access_groups=()

  while IFS=$'\t' read -r user password home purpose; do
    [[ -n "$user" ]] || continue
    local_user_groups["$user"]=1
  done < <(emit_managed_account_rows)

  access_groups["$STANDARD_CLIENT_GROUP"]=1
  access_groups["$SCAN_INBOX_GROUP"]=1

  for user in "${!OPERATOR_USER_EXTRA_GROUPS[@]}"; do
    for group in ${OPERATOR_USER_EXTRA_GROUPS[$user]}; do
      [[ -n "$group" ]] || continue
      access_groups["$group"]=1
    done
  done

  for share in "${!SHARE_ALLOWED_GROUPS[@]}" "${!SHARE_FORCE_GROUP[@]}"; do
    [[ -n "$share" ]] || continue
    for group in ${SHARE_ALLOWED_GROUPS[$share]:-} ${SHARE_FORCE_GROUP[$share]:-}; do
      [[ -n "$group" ]] || continue
      access_groups["$group"]=1
    done
  done

  for group in "${!local_user_groups[@]}"; do
    validate_existing_group_safe "$group"
  done
  for group in "${!access_groups[@]}"; do
    validate_existing_penelope_access_group_safe "$group"
  done
}


ensure_penelope_access_group() {
  local group="$1"

  if ! getent group "$group" >/dev/null 2>&1; then
    log "Creating Penelope Samba access group: ${group}"
    groupadd "$group"
  fi
}

user_kind_is_standard_client() {
  local kind="$1"
  [[ "$kind" == "client" || "$kind" == "admin" ]]
}


ensure_user_in_group() {
  local user="$1"
  local group="$2"

  if id -nG "$user" 2>/dev/null | tr ' ' '
' | grep -Fxq "$group"; then
    return 0
  fi

  log "Adding ${user} to Penelope Samba access group ${group}"
  usermod -a -G "$group" "$user"
}

ensure_penelope_access_group_memberships() {
  local user password home purpose group share

  ensure_penelope_access_group "$STANDARD_CLIENT_GROUP"
  ensure_penelope_access_group "$SCAN_INBOX_GROUP"

  for user in "${!OPERATOR_USER_EXTRA_GROUPS[@]}"; do
    for group in ${OPERATOR_USER_EXTRA_GROUPS[$user]}; do
      [[ -n "$group" ]] || continue
      ensure_penelope_access_group "$group"
    done
  done
  for share in "${!SHARE_ALLOWED_GROUPS[@]}" "${!SHARE_FORCE_GROUP[@]}"; do
    [[ -n "$share" ]] || continue
    for group in ${SHARE_ALLOWED_GROUPS[$share]:-} ${SHARE_FORCE_GROUP[$share]:-}; do
      [[ -n "$group" ]] || continue
      ensure_penelope_access_group "$group"
    done
  done

  while IFS=$'\t' read -r user password home purpose; do
    [[ -n "$user" ]] || continue

    if user_has_default_access "$user"; then
      ensure_user_in_group "$user" "$STANDARD_CLIENT_GROUP"
      ensure_user_in_group "$user" "$SCAN_INBOX_GROUP"
    fi

    for group in ${OPERATOR_USER_EXTRA_GROUPS[$user]:-}; do
      [[ -n "$group" ]] || continue
      ensure_user_in_group "$user" "$group"
    done
  done < <(emit_managed_account_rows)
}


ensure_shared_work_dir() {
  local path="$1"
  local group="$2"
  local dir_state

  assert_share_path_has_no_symlink_components "$path"

  if [[ -e "$path" && ! -d "$path" ]]; then
    die "Shared Penelope work path exists but is not a directory: ${path}"
  fi

  if [[ -d "$path" ]]; then
    dir_state="$(describe_directory_state "$path")"
    log "Ensuring shared Penelope work directory permissions: ${path} (${dir_state} -> root:${group} ${SHARED_WORK_DIR_MODE})"
  else
    log "Creating shared Penelope work directory: ${path}"
  fi

  ensure_dir "$path" "$SHARED_WORK_DIR_MODE" root "$group"
}

ensure_managed_local_accounts() {
  local user password home purpose

  while IFS=$'\t' read -r user password home purpose; do
    [[ -n "$user" ]] || continue

    if [[ "$purpose" == "backup_dashboard_export" ]]; then
      ensure_local_account_without_home "$user" "$home"
      continue
    fi

    if user_has_private_home "$user"; then
      ensure_local_account "$user" "$home"
    else
      ensure_local_account_without_home "$user" "$home"
    fi
  done < <(emit_managed_account_rows)
}


ensure_local_account() {
  local user="$1"
  local home="$2"

  assert_share_path_has_no_symlink_components "$home"

  if ! getent group "$user" >/dev/null 2>&1; then
    log "Creating local group for Samba ownership model: ${user}"
    groupadd "$user"
  fi

  if getent passwd "$user" >/dev/null 2>&1; then
    log "Ensuring local non-login account settings for ${user}"
    usermod -d "$home" -s "$NONLOGIN_SHELL" "$user"
  else
    log "Creating local non-login account: ${user}"
    useradd -m -d "$home" -s "$NONLOGIN_SHELL" -g "$user" "$user"
  fi

  ensure_dir "$home" 0750 "$user" "$user"
}

ensure_local_account_without_home() {
  local user="$1"
  local account_home="$2"

  if ! getent group "$user" >/dev/null 2>&1; then
    log "Creating local group for Samba ownership model: ${user}"
    groupadd "$user"
  fi

  if getent passwd "$user" >/dev/null 2>&1; then
    log "Ensuring local non-login account settings for ${user} (no managed home directory)"
    usermod -d "$account_home" -s "$NONLOGIN_SHELL" "$user"
  else
    log "Creating local non-login account without managed home directory: ${user}"
    useradd -M -d "$account_home" -s "$NONLOGIN_SHELL" -g "$user" "$user"
  fi
}

ensure_archive_dir() {
  local user="$1"
  local path="${ARCHIVE_ROOT}/${user}"

  assert_share_path_has_no_symlink_components "$path"
  ensure_dir "$path" 0700 "$user" "$user"
}

describe_directory_state() {
  local path="$1"
  local owner group mode

  owner="$(stat -c '%U' "$path" 2>/dev/null || printf 'unknown')"
  group="$(stat -c '%G' "$path" 2>/dev/null || printf 'unknown')"
  mode="$(stat -c '%a' "$path" 2>/dev/null || printf 'unknown')"

  printf '%s' "${owner}:${group} ${mode}"
}

ensure_extra_share_dir() {
  local path="$1"
  local user="$2"
  local mode="$3"
  local dir_state

  assert_share_path_has_no_symlink_components "$path"

  if [[ -e "$path" && ! -d "$path" ]]; then
    die "Extra share path exists but is not a directory: ${path}"
  fi

  if [[ -d "$path" ]]; then
    dir_state="$(describe_directory_state "$path")"
    log "Extra share directory already exists, leaving ownership and mode unchanged: ${path} (${dir_state}; expected access for ${user}:${mode})"
    return 0
  fi

  if [[ "$path" == "$CANONICAL_BACKUP_DASHBOARD_DIR" || "$path" == "$CANONICAL_BACKUP_DASHBOARD_DIR"/* ]]; then
    die "Canonical Backup-Dashboard path and its subpaths must already exist and must be created by penelope-backup-setup before Samba export: ${path}"
  fi

  if [[ "$mode" == "ro" ]]; then
    assert_ro_create_policy_supports_user_access "$user"
    log "Creating extra share directory for ro share: ${path}"
    log "Readonly auto-create policy: ${RO_EXTRA_SHARE_CREATE_OWNER}:${RO_EXTRA_SHARE_CREATE_GROUP} ${RO_EXTRA_SHARE_CREATE_MODE}"
    ensure_dir "$path" "$RO_EXTRA_SHARE_CREATE_MODE" "$RO_EXTRA_SHARE_CREATE_OWNER" "$RO_EXTRA_SHARE_CREATE_GROUP"
    return 0
  fi

  local share force_group share_candidate path_candidate user_candidate _mode_candidate _origin_candidate
  share=""
  while IFS=$'	' read -r share_candidate path_candidate user_candidate _mode_candidate _origin_candidate; do
    [[ "${path_candidate}" == "${path}" && "${user_candidate}" == "${user}" ]] || continue
    share="${share_candidate}"
    break
  done < <(emit_extra_share_rows)

  force_group=""
  if [[ -n "${share}" ]]; then
    force_group="${SHARE_FORCE_GROUP[$share]:-}"
  fi

  if [[ -n "$force_group" ]]; then
    log "Creating extra rw share directory with shared group ${force_group}: ${path}"
    ensure_dir "$path" "$SHARED_WORK_DIR_MODE" "$user" "$force_group"
    return 0
  fi

  assert_rw_create_policy_supports_user_access "$user"
  log "Creating extra share directory for rw share with default mode ${RW_EXTRA_SHARE_CREATE_MODE}: ${path}"
  ensure_dir "$path" "$RW_EXTRA_SHARE_CREATE_MODE" "$user" "$user"
}

assert_share_path_has_no_symlink_components() {
  local path="$1"
  local current="/"
  local component rest

  if [[ "${path:0:1}" != "/" ]]; then
    die "Share path must be absolute for symlink check: ${path}"
  fi

  rest="${path#/}"
  if [[ -z "$rest" ]]; then
    if [[ -L "/" ]]; then
      die "Share path must not traverse a symlinked path component: /"
    fi
    return 0
  fi

  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi

    if [[ "$current" == "/" ]]; then
      current="/${component}"
    else
      current+="/${component}"
    fi

    if [[ -L "$current" ]]; then
      die "Share path must not traverse a symlinked path component: ${current}"
    fi
  done
}

compute_dir_access_bits_for_user() {
  local user="$1"
  local owner="$2"
  local group="$3"
  local mode="$4"
  local user_uid owner_uid group_gid perm_bits user_group_id
  local -a user_groups

  user_uid="$(id -u "$user")"
  owner_uid="$(getent passwd "$owner" | cut -d: -f3)"
  group_gid="$(getent group "$group" | cut -d: -f3)"
  perm_bits=$(( 8#${mode#0} ))

  if [[ "$user_uid" == "$owner_uid" ]]; then
    printf '%s\n' "$(( (perm_bits >> 6) & 7 ))"
    return 0
  fi

  read -r -a user_groups <<< "$(id -G "$user")"
  for user_group_id in "${user_groups[@]}"; do
    if [[ "$user_group_id" == "$group_gid" ]]; then
      printf '%s\n' "$(( (perm_bits >> 3) & 7 ))"
      return 0
    fi
  done

  printf '%s\n' "$(( perm_bits & 7 ))"
}

assert_ro_create_policy_supports_user_access() {
  local user="$1"
  local perm_bits
  local message

  perm_bits="$(compute_dir_access_bits_for_user \
    "$user" \
    "$RO_EXTRA_SHARE_CREATE_OWNER" \
    "$RO_EXTRA_SHARE_CREATE_GROUP" \
    "$RO_EXTRA_SHARE_CREATE_MODE")"

  if (( (perm_bits & 4) == 0 || (perm_bits & 1) == 0 )); then
    message="RO extra share create policy would create an unreadable or untraversable directory for user ${user}: "
    message+="${RO_EXTRA_SHARE_CREATE_OWNER}:${RO_EXTRA_SHARE_CREATE_GROUP} ${RO_EXTRA_SHARE_CREATE_MODE}"
    die "${message}"
  fi
}

assert_rw_create_policy_supports_user_access() {
  local user="$1"
  local perm_bits
  local message

  perm_bits="$(compute_dir_access_bits_for_user \
    "$user" \
    "$user" \
    "$user" \
    "$RW_EXTRA_SHARE_CREATE_MODE")"

  if (( (perm_bits & 4) == 0 || (perm_bits & 2) == 0 || (perm_bits & 1) == 0 )); then
    message="RW extra share create policy would create a non-readable, non-writable, or non-traversable directory for user ${user}: "
    message+="${user}:${user} ${RW_EXTRA_SHARE_CREATE_MODE}"
    die "${message}"
  fi
}


check_share_path_access_as_user() {
  local path="$1"
  local user="$2"
  local mode="$3"
  local dir_state

  assert_share_path_has_no_symlink_components "$path"
  dir_state="$(describe_directory_state "$path")"

  if ! runuser -u "$user" -- test -d "$path"; then
    die "Configured share path is not accessible as a directory for user ${user}: ${path} (${dir_state}; required access profile: ${mode})"
  fi

  if [[ "$mode" == "rw" ]]; then
    if ! runuser -u "$user" -- test -r "$path"; then
      die "Configured rw share path is not readable for user ${user}: ${path} (${dir_state}; required: read+write+traverse)"
    fi
    if ! runuser -u "$user" -- test -w "$path"; then
      die "Configured rw share path is not writable for user ${user}: ${path} (${dir_state}; required: read+write+traverse)"
    fi
    if ! runuser -u "$user" -- test -x "$path"; then
      die "Configured rw share path is not traversable for user ${user}: ${path} (${dir_state}; required: read+write+traverse)"
    fi
    return 0
  fi

  if ! runuser -u "$user" -- test -r "$path"; then
    die "Configured ro share path is not readable for user ${user}: ${path} (${dir_state}; required: read+traverse)"
  fi
  if ! runuser -u "$user" -- test -x "$path"; then
    die "Configured ro share path is not traversable for user ${user}: ${path} (${dir_state}; required: read+traverse)"
  fi
}

ensure_samba_account_password() {
  local user="$1"
  local password="$2"

  if pdbedit -L -u "$user" >/dev/null 2>&1; then
    log "Updating Samba password for ${user}"
    ( set +x; printf '%s\n%s\n' "$password" "$password" | smbpasswd -s "$user" >/dev/null ) \
      || die "Failed to update Samba password for ${user}"
  else
    log "Creating Samba user: ${user}"
    ( set +x; printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a "$user" >/dev/null ) \
      || die "Failed to create Samba password entry for ${user}"
  fi
}

ensure_base_directories() {
  local user password home kind share path mode origin

  ensure_dir "$ARCHIVE_ROOT" 0755 root root
  ensure_managed_local_accounts
  ensure_penelope_access_group_memberships

  while IFS=$'	' read -r user password home kind; do
    [[ -n "$user" ]] || continue

    if [[ "$kind" == "backup_dashboard_export" ]]; then
      continue
    fi
    if user_has_private_home "$user"; then
      check_share_path_access_as_user "$home" "$user" "rw"
    fi
  done < <(emit_managed_account_rows)

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue

    case "$origin" in
      archive_primary)
        ensure_archive_dir "$user"
        check_share_path_access_as_user "$path" "$user" "rw"
        ;;
      home_primary)
        check_share_path_access_as_user "$path" "$user" "rw"
        ;;
      shared_rawin)
        ensure_shared_work_dir "$path" "$STANDARD_CLIENT_GROUP"
        ;;
      shared_scan)
        ensure_shared_work_dir "$path" "$SCAN_INBOX_GROUP"
        ;;
      internal_home)
        ensure_shared_work_dir "$path" "$STANDARD_CLIENT_GROUP"
        ;;
      backup_dashboard_export)
        if [[ -e "$path" && ! -d "$path" ]]; then
          die "Canonical Backup-Dashboard path exists but is not a directory: ${path}"
        fi
        if [[ ! -d "$path" ]]; then
          die "Dedicated ${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} export requires existing Backup-Dashboard directory from penelope-backup-setup: ${path}"
        fi
        check_share_path_access_as_user "$path" "$user" "ro"
        ;;
      *)
        die "Unknown primary share origin in ensure_base_directories: ${origin}"
        ;;
    esac
  done < <(emit_primary_share_rows)

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue
    ensure_extra_share_dir "$path" "$user" "$mode"
    check_share_path_access_as_user "$path" "$user" "$mode"
  done < <(emit_extra_share_rows)
}


ensure_samba_accounts() {
  local user password home kind

  while IFS=$'	' read -r user password home kind; do
    [[ -n "$user" ]] || continue
    ensure_samba_account_password "$user" "$password"
  done < <(emit_managed_account_rows)
}


samba_include_present() {
  local escaped_path

  escaped_path="$(printf '%s' "$SAMBA_MANAGED_CONF" | sed 's/[][(){}.^$*+?|\\/]/\\&/g')"
  grep -Eq "^[[:space:]]*include[[:space:]]*=[[:space:]]*\"?${escaped_path}\"?[[:space:]]*([#;].*)?$" "$SAMBA_MAIN_CONF"
}

insert_managed_include_after_global_section() {
  local input_path="$1"
  local output_path="$2"
  local include_line="$3"

  awk -v include_line="${include_line}" '
    BEGIN {
      in_global = 0
      inserted = 0
    }
    /^[[:space:]]*\[global\][[:space:]]*$/ {
      in_global = 1
      print
      next
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_global && !inserted) {
        print ""
        print "# Penelope managed Samba shares"
        print include_line
        inserted = 1
        in_global = 0
      }
      print
      next
    }
    {
      print
    }
    END {
      if (!inserted) {
        print ""
        print "# Penelope managed Samba shares"
        print include_line
      }
    }
  ' "${input_path}" > "${output_path}"
}

ensure_main_include() {
  local tmp_main

  if samba_include_present; then
    log "Managed include already present in ${SAMBA_MAIN_CONF}"
    return 0
  fi

  tmp_main="$(mktemp "${SAMBA_MAIN_CONF}.tmp.XXXXXX")" || die "Failed to allocate temporary Samba main config"
  insert_managed_include_after_global_section "${SAMBA_MAIN_CONF}" "${tmp_main}" "${SAMBA_INCLUDE_LINE}" || {
    rm -f "${tmp_main}" || true
    die "Failed to prepare Samba main config with Penelope managed include"
  }

  log "Adding managed include to ${SAMBA_MAIN_CONF} after the [global] section"
  cat "${tmp_main}" > "${SAMBA_MAIN_CONF}" || {
    rm -f "${tmp_main}" || true
    die "Failed to update Samba main config with Penelope managed include"
  }
  rm -f "${tmp_main}" || true
}

valid_users_for_share() {
  local share_name="$1"
  local user="$2"
  local origin="$3"
  local value=""
  local item

  case "$origin" in
    shared_rawin|internal_home)
      printf '@%s\n' "$STANDARD_CLIENT_GROUP"
      ;;
    shared_scan)
      printf '@%s\n' "$SCAN_INBOX_GROUP"
      ;;
    backup_dashboard_export)
      printf '@%s %s\n' "$STANDARD_CLIENT_GROUP" "$BACKUP_DASHBOARD_EXPORT_USER"
      ;;
    archive_primary|home_primary)
      printf '%s\n' "$user"
      ;;
    extra_export)
      value="$user"
      for item in ${SHARE_ALLOWED_USERS[$share_name]:-}; do
        value+=" ${item}"
      done
      for item in ${SHARE_ALLOWED_GROUPS[$share_name]:-}; do
        value+=" @${item}"
      done
      printf '%s\n' "$value"
      ;;
    *)
      printf '%s\n' "$user"
      ;;
  esac
}

share_force_group_for_block() {
  local share_name="$1"
  local origin="$2"

  case "$origin" in
    shared_rawin|internal_home)
      printf '%s\n' "$STANDARD_CLIENT_GROUP"
      ;;
    shared_scan)
      printf '%s\n' "$SCAN_INBOX_GROUP"
      ;;
    extra_export)
      printf '%s\n' "${SHARE_FORCE_GROUP[$share_name]:-}"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

write_share_block() {
  local out_path="$1"
  local share_name="$2"
  local path="$3"
  local user="$4"
  local mode="$5"
  local origin="$6"
  local read_only="yes"
  local create_mask directory_mask valid_users force_group

  if [[ "$mode" == "rw" ]]; then
    read_only="no"
  fi

  create_mask="$(derive_file_mode_from_directory_mode "$RW_EXTRA_SHARE_CREATE_MODE")"
  directory_mask="${RW_EXTRA_SHARE_CREATE_MODE}"
  force_group="$(share_force_group_for_block "$share_name" "$origin")"
  case "$origin" in
    shared_rawin|shared_scan|internal_home)
      create_mask="$SHARED_WORK_CREATE_MASK"
      directory_mask="$SHARED_WORK_DIRECTORY_MASK"
      ;;
  esac

  valid_users="$(valid_users_for_share "$share_name" "$user" "$origin")"

  cat >> "$out_path" <<EOF_SHARE
[$share_name]
  path = $path
  valid users = $valid_users
  browseable = yes
  read only = $read_only
  create mask = $create_mask
  directory mask = $directory_mask
EOF_SHARE

  if [[ -n "$force_group" ]]; then
    cat >> "$out_path" <<EOF_SHARE
  force group = $force_group
  force create mode = $create_mask
  force directory mode = $SHARED_WORK_DIRECTORY_MASK
EOF_SHARE
  fi

  printf '\n' >> "$out_path"
}


samba_testparm_output_has_weak_gnutls_crypto_allowed() {
  local output_path="${1:?output path required}"
  grep -Fq "Weak crypto is allowed by GnuTLS" "${output_path}"
}

log_testparm_weak_gnutls_crypto_watchpoint() {
  local label="${1:?validation label required}"
  local output_path="${2:?output path required}"

  if samba_testparm_output_has_weak_gnutls_crypto_allowed "${output_path}"; then
    warn "Security watchpoint: testparm reports weak GnuTLS crypto is allowed for ${label}."
    warn "Penelope keeps Samba constrained to SMB3 and NTLMv2-only, but this host-level GnuTLS/Samba compatibility warning remains visible on this platform."
  fi
}

run_testparm_with_weak_crypto_watchpoint() {
  local label="${1:?validation label required}"
  shift
  local output_path=""

  output_path="$(mktemp)" || die "Failed to allocate temporary testparm output file"
  if ! "$@" >"${output_path}" 2>&1; then
    cat "${output_path}" >&2 || true
    rm -f "${output_path}" || true
    die "testparm rejected ${label}"
  fi

  log_testparm_weak_gnutls_crypto_watchpoint "${label}" "${output_path}"
  rm -f "${output_path}" || true
}

log_samba_host_crypto_watchpoint_for_apply() {
  if ! have testparm; then
    log "Skipping Samba/GnuTLS crypto watchpoint because testparm is not installed yet; apply will install Samba first"
    return 0
  fi

  log "Checking Samba/GnuTLS crypto watchpoint before Penelope-managed Samba runtime changes"
  run_testparm_with_weak_crypto_watchpoint "host Samba/GnuTLS crypto preflight" testparm -s
}

validate_managed_conf_candidate() {
  local candidate_path="$1"
  local tmp_main escaped_live escaped_candidate

  [[ -r "${SAMBA_MAIN_CONF}" ]] || die "Missing readable Samba main config for validation: ${SAMBA_MAIN_CONF}"

  tmp_main="$(mktemp "${SAMBA_MAIN_CONF}.tmp.XXXXXX")" || die "Failed to allocate temporary Samba config for validation"
  escaped_live="$(printf '%s' "$SAMBA_MANAGED_CONF" | sed 's/[\/&]/\\&/g')"
  escaped_candidate="$(printf '%s' "$candidate_path" | sed 's/[\/&]/\\&/g')"

  if samba_include_present; then
    sed "s/${escaped_live}/${escaped_candidate}/g" "$SAMBA_MAIN_CONF" > "$tmp_main" || {
      rm -f "$tmp_main" || true
      die "Failed to prepare temporary Samba config validation input"
    }
  else
    insert_managed_include_after_global_section "${SAMBA_MAIN_CONF}" "${tmp_main}" "include = ${candidate_path}" || {
      rm -f "${tmp_main}" || true
      die "Failed to prepare temporary Samba config validation input"
    }
  fi

  log "Validating managed Samba config candidate"
  if ! run_testparm_with_weak_crypto_watchpoint "managed Samba config candidate" testparm -s "$tmp_main"; then
    rm -f "$tmp_main" || true
    die "testparm rejected managed Samba config candidate"
  fi

  rm -f "$tmp_main" || true
}

validate_managed_conf_candidate_if_possible() {
  local candidate_path="$1"

  if ! have testparm; then
    log "Deferred testparm candidate validation during verify-config because Samba is not installed yet; apply will install Samba and run the testparm/GnuTLS crypto watchpoint"
    return 0
  fi

  if [[ ! -r "${SAMBA_MAIN_CONF}" ]]; then
    log "Deferred testparm candidate validation during verify-config because ${SAMBA_MAIN_CONF} is not readable yet; apply will prepare Samba and run the testparm/GnuTLS crypto watchpoint"
    return 0
  fi

  validate_managed_conf_candidate "$candidate_path"
}

render_managed_conf_to_path() {
  local dest_path="$1"
  local validation_mode="${2:-strict}"
  local share path user mode origin tmp_managed

  tmp_managed="$(mktemp "${dest_path}.tmp.XXXXXX")" || die "Failed to allocate temporary managed Samba config"
  trap '[[ -n "${tmp_managed:-}" && -e "${tmp_managed:-}" ]] && rm -f "${tmp_managed:-}"' RETURN

  log "Rendering managed Samba shares candidate: ${dest_path}"
  cat > "$tmp_managed" <<EOF_MANAGED_CONF
# Managed by Penelope
# Last written by: penelope-samba-setup ${VERSION}
# Version: ${VERSION}
# Penelope managed Samba shares
#
# This file is managed by penelope-samba-setup.
# Edit the active files in the Samba config directory, rerun verify-config, then apply.

[global]
  access based share enum = yes
  server min protocol = ${SMB_SERVER_MIN_PROTOCOL}
  client min protocol = ${SMB_CLIENT_MIN_PROTOCOL}
  ntlm auth = ${SMB_NTLM_AUTH}

EOF_MANAGED_CONF

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue
    write_share_block "$tmp_managed" "$share" "$path" "$user" "$mode" "$origin"
  done < <(emit_primary_share_rows)

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue
    write_share_block "$tmp_managed" "$share" "$path" "$user" "$mode" "$origin"
  done < <(emit_extra_share_rows)

  case "$validation_mode" in
    strict)
      validate_managed_conf_candidate "$tmp_managed"
      ;;
    best-effort)
      validate_managed_conf_candidate_if_possible "$tmp_managed"
      ;;
    *)
      rm -f "$tmp_managed" || true
      die "Unsupported managed config validation mode: ${validation_mode}"
      ;;
  esac

  chown root:root "$tmp_managed" || die "Failed to chown ${tmp_managed}"
  chmod 0644 "$tmp_managed" || die "Failed to chmod ${tmp_managed}"
  mv -f "$tmp_managed" "$dest_path" || die "Failed to publish managed Samba config: ${dest_path}"
  trap - RETURN
}

render_managed_conf() {
  render_managed_conf_to_path "${SAMBA_MANAGED_CONF}" strict
}


validate_and_reload_samba() {
  log "Validating Samba configuration"
  run_testparm_with_weak_crypto_watchpoint "live Samba configuration" testparm -s

  log "Reloading smbd"
  if ! systemctl reload smbd; then
    log "Reload failed, restarting smbd"
    systemctl restart smbd
  fi
}

print_summary() {
  local share path user mode origin

  log "Samba provisioning finished"
  log "  Managed config: ${SAMBA_MANAGED_CONF}"
  log "  Samba services: smbd.service/nmbd.service enabled/active, samba-ad-dc.service disabled/inactive"
  log "  Windows Explorer network discovery: wsdd2.service enabled/active"
  if backup_dashboard_export_requested; then
    log "  Backup-Dashboard export: enabled"
    log "    share=${CANONICAL_BACKUP_DASHBOARD_SHARE_NAME} path=${CANONICAL_BACKUP_DASHBOARD_DIR}"
    log "    user=${BACKUP_DASHBOARD_EXPORT_USER} mode=ro source=${CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE}"
  elif [[ "${CANONICAL_BACKUP_DASHBOARD_DIR_SOURCE}" == "default" ]]; then
    log "  Backup-Dashboard export: disabled (source=default)"
  else
    log "  Backup-Dashboard export: disabled"
  fi
  log "  Shares:"

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue
    log "    ${share} -> ${path} (user=${user}, mode=${mode})"
  done < <(emit_primary_share_rows)

  while IFS=$'	' read -r share path user mode origin; do
    [[ -n "$share" ]] || continue
    log "    ${share} -> ${path} (user=${user}, mode=${mode})"
  done < <(emit_extra_share_rows)

  local self_cmd
  self_cmd="${SELF_CMD}"
  log "  Next inspect commands:"
  log "    Declared users: ${self_cmd} --config-dir ${OPERATOR_CONFIG_DIR} list-users"
  log "    Declared shares: ${self_cmd} --config-dir ${OPERATOR_CONFIG_DIR} list-shares"
  log "  Next verify commands:"
  log "    Verify installed host: sudo -E /usr/local/sbin/penelope-verify-security.sh"
  log "    Validate live Samba config: sudo testparm -s"
}


parse_cli_and_dispatch() {
  local command=""
  local -a positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-dir)
        shift
        [[ $# -gt 0 ]] || die "--config-dir requires a DIR argument"
        OPERATOR_CONFIG_DIR="$1"
        update_operator_config_paths
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      write-config|verify-config|apply|list-users|list-shares|show-user|show-share|\
add-user|disable-user|remove-user|enable-user|add-share|disable-share|\
remove-share|enable-share|set-password)
        [[ -z "${command}" ]] || die "Only one command may be specified"
        command="$1"
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift || true
  done

  [[ -n "${command}" ]] || {
    if [[ ${#positional[@]} -gt 0 ]]; then
      die "Unknown command: ${positional[0]}. Use verify-config."
    fi
    usage >&2
    die "Missing command"
  }

  case "${command}" in
    write-config)
      [[ ${#positional[@]} -eq 0 ]] || die "write-config does not take additional arguments"
      init_operator_config_dir
      ;;
    verify-config)
      [[ ${#positional[@]} -eq 0 ]] || die "verify-config does not take additional arguments"
      run_verify_config "${positional[@]}"
      ;;
    apply)
      [[ ${#positional[@]} -eq 0 ]] || die "apply does not take additional arguments"
      run_apply "${positional[@]}"
      ;;
    list-users|list-shares)
      [[ ${#positional[@]} -eq 0 ]] || die "${command} does not take additional arguments"
      run_inspect_command "${command}"
      ;;
    show-user|show-share)
      [[ ${#positional[@]} -eq 1 ]] || die "${command} requires exactly one argument"
      run_inspect_command "${command}" "${positional[0]}"
      ;;
    add-user)
      run_add_user "${positional[@]}"
      ;;
    disable-user)
      run_disable_user "${positional[@]}"
      ;;
    remove-user)
      run_remove_user "${positional[@]}"
      ;;
    enable-user)
      run_enable_user "${positional[@]}"
      ;;
    add-share)
      run_add_share "${positional[@]}"
      ;;
    remove-share)
      run_remove_share "${positional[@]}"
      ;;
    disable-share)
      run_disable_share "${positional[@]}"
      ;;
    enable-share)
      run_enable_share "${positional[@]}"
      ;;
    set-password)
      run_set_password "${positional[@]}"
      ;;
    *)
      die "Unknown command: ${command}. Use verify-config."
      ;;
  esac
}

parse_cli_and_dispatch "$@"
