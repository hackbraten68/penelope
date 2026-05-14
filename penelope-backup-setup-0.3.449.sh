#!/usr/bin/env bash
# penelope-backup-setup.sh
# Version: (see readonly VERSION below)
#
# Idempotent setup/update of the Penelope restic backup tooling on the installed
# target host.
#
# Canonical operator flow:
# - write-config   scaffold /etc/penelope/backup-setup and exit
# - edit externally under /etc/penelope/backup-setup
# - verify-config  print the non-destructive apply plan
# - apply          install/update live backup tooling and state
#
# Normal reruns are expected and should update tooling without silently replacing
# established operator configuration or reinitializing existing secrets.
#
# Installs/updates:
# - /usr/local/sbin/penelope-backup.sh            (runner)
# - /usr/local/sbin/penelope-backup-verify.sh     (backup verification helper)
# - /usr/local/sbin/penelope-backup-find-snapshot.sh (read-only helper to locate newest snapshot containing a path)
# - /usr/local/sbin/penelope-usb-disk-setup.sh       (guided USB backup disk setup and registration)
# - /usr/local/sbin/penelope-rotate-external-restic-passwords.sh (rotate external USB repo passwords to current local values)
# - /usr/local/sbin/penelope-offline-recover.sh  (offline full recovery; Live-USB/Rescue)
# - /etc/penelope/backup.conf                     (configuration)
# - /etc/penelope/usb-backup-disks.conf           (USB UUID allow-list + template)
# - /etc/cron.d/penelope-backup                   (daily internal backup, no catch-up)
# - /etc/logrotate.d/penelope-backup              (rotates host-scoped backup logs)
#
# Repositories:
# - internal: /_backup/<HOST_SCOPE_NAME>/{system,home,_archive}
# - external: <USB_MOUNT_BASE>/<UUID>/<HOST_SCOPE_NAME>/{system,home,_archive}
#
# Backup cadence (default):
# - Every day at CRON_HOUR:CRON_MINUTE a run is executed (default: 18:00).
# - Cadence is semantic (restic is always incremental/deduplicating):
#     Monday/Thursday are default full-marker weekdays.
#     The first successful snapshot per scope in the current configured cycle is tagged full.
#     Later snapshots in the same configured cycle are tagged incr.
# - Retention keeps the last configured full-marker cycles as whole cycles.
#
# Usage:
#   sudo -E ./${0##*/} write-config
#   sudo -E ./${0##*/} verify-config [--keep-config|--reset-config] [--keep-secrets|--init-secrets]
#   sudo -E ./${0##*/} apply         [--keep-config|--reset-config] [--keep-secrets|--init-secrets]
#
set -Eeuo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/penelope-common.sh"

export TZ="${TZ:-Europe/Berlin}"

# ================== INIT TEMPLATE DEFAULTS ==================
# FIRST EDIT SECTION:
# This inline block is no longer the live operator edit surface for backup-setup.
# 'write-config' uses these non-secret defaults only to scaffold the external
# bootstrap tree under /etc/penelope/backup-setup.
#
# After that, the bootstrap tree is the operator-edited source for fresh create/reset
# of /etc/penelope/backup.conf and for initialization-only restic secret files when
# /root/.config/restic/* are missing or empty.
#
# Normal reruns keep /etc/penelope/backup.conf and /root/.config/restic/* as the
# canonical live state and do not require the bootstrap tree merely to update tooling.
INITIAL_BACKUP_HOST_SCOPE_NAME=""
DEFAULT_CRON_HOUR="18"
DEFAULT_CRON_MINUTE="0"
DEFAULT_BACKUP_DASHBOARD_DIR="/var/lib/penelope/backup-dashboard"

if (( BASH_VERSINFO[0] < 4 )); then
  >&2 echo "ERROR: Bash 4.0 or higher required"
  exit 1
fi

readonly VERSION="0.3.449"
readonly PROJECT="penelope"
readonly SAMBA_OPERATOR_CONFIG_DIR="/etc/${PROJECT}/samba-setup"
readonly BACKUP_SETUP_CONFIG_DIR="/etc/${PROJECT}/backup-setup"
readonly BACKUP_SETUP_CONFIG_FILE="${BACKUP_SETUP_CONFIG_DIR}/backup-setup.conf"
readonly BACKUP_SETUP_SECRETS_DIR="${BACKUP_SETUP_CONFIG_DIR}/secrets.d"
readonly BACKUP_SETUP_SECRET_SYSTEM="${BACKUP_SETUP_SECRETS_DIR}/system.secret"
readonly BACKUP_SETUP_SECRET_HOME="${BACKUP_SETUP_SECRETS_DIR}/home.secret"
readonly BACKUP_SETUP_SECRET_ARCHIVE="${BACKUP_SETUP_SECRETS_DIR}/_archive.secret"
readonly BACKUP_SETUP_EXAMPLES_DIR="${BACKUP_SETUP_CONFIG_DIR}/examples"
readonly BACKUP_SETUP_EXAMPLE_CONFIG_FILE="${BACKUP_SETUP_EXAMPLES_DIR}/backup-setup.conf.example"
readonly BACKUP_SETUP_EXAMPLE_SECRETS_DIR="${BACKUP_SETUP_EXAMPLES_DIR}/secrets.d"
readonly BACKUP_SETUP_EXAMPLE_SECRET_SYSTEM="${BACKUP_SETUP_EXAMPLE_SECRETS_DIR}/system.secret.example"
readonly BACKUP_SETUP_EXAMPLE_SECRET_HOME="${BACKUP_SETUP_EXAMPLE_SECRETS_DIR}/home.secret.example"
readonly BACKUP_SETUP_EXAMPLE_SECRET_ARCHIVE="${BACKUP_SETUP_EXAMPLE_SECRETS_DIR}/_archive.secret.example"
readonly BACKUP_SETUP_CONFIG_SCHEMA_VERSION="1"
readonly BACKUP_SETUP_SCRIPT_SOURCE_PATH="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
export BACKUP_SETUP_SCRIPT_SOURCE_PATH

penelope_bundle_startup \
  "penelope-backup-setup" "${VERSION}" "${SCRIPT_DIR}/penelope-common.sh" \
  "${BASH_SOURCE[0]:-}" "source preflight scan failed" \
  warn \
  log \
  require_cmd \
  require_cmd_many \
  validate_shell_script \
  validate_systemd_unit \
  ensure_no_unexpanded_tokens \
  validate_secret_not_placeholder \
  read_kv_value_from_file \
  read_kv_value_from_file_or_default \
  uuid_in_allowlist \
  read_present_allowlisted_uuids \
  usb_dev_for_uuid \
  usb_fstype_for_dev \
  unmount_all_mounts_for_dev \
  dev_is_mounted_anywhere \
  ensure_expected_penelope_mount_layout \
  penelope_ensure_recovery_stage_dir \
  penelope_stage_common_for_recovery \
  penelope_publish_recovery_stage_file \
  penelope_refresh_installed_common_lib \
  ensure_penelope_run_dir \
  current_boot_id \
  proc_start_time \
  write_pid_dir_lock_metadata \
  acquire_pid_dir_lock \
  release_pid_dir_lock \
  pid_dir_lock_is_active_runtime \
  penelope_log_trap_error \
  penelope_signal_exit_code_for_name

SELF_CMD="$(penelope_resolved_script_invocation_for_display "penelope-backup-setup.sh" "${0:-${BASH_SOURCE[0]:-penelope-backup-setup.sh}}")"
readonly SELF_CMD


# -------------------- options --------------------
# Config handling:
# - merge (default): keep existing config, append missing keys from the current template
# - keep: do not modify existing config (except permission fixes); create if missing
# - reset: backup and rewrite config from template (dangerous)
CONFIG_MODE="merge"   # merge|keep|reset
SECRETS_MODE="init"   # init|keep
COMMAND=""

usage() {
  local self_cmd
  self_cmd="${SELF_CMD}"
  cat <<EOF_USAGE_MAIN
Usage:
  sudo -E ${self_cmd} write-config
  sudo -E ${self_cmd} verify-config [--keep-config|--reset-config] [--keep-secrets|--init-secrets]
  sudo -E ${self_cmd} apply         [--keep-config|--reset-config] [--keep-secrets|--init-secrets]
  ${self_cmd} --help

Commands:
  write-config   Scaffold /etc/penelope/backup-setup and exit.
  verify-config  Non-destructively validate the backup setup config/secret inputs and print the apply plan.
  apply          Apply live backup setup changes on the installed host.

Options (verify-config/apply only):
  --keep-config  Keep existing backup.conf as-is (append nothing). Create it if missing.
  --reset-config Backup and rewrite backup.conf from the current bootstrap config tree.
  --keep-secrets Do not create missing restic password files. Abort if missing/empty.
  --init-secrets Create missing/empty restic password files from bootstrap secrets.d (default).
  -h, --help     Show this help.

Notes:
  - write-config only scaffolds the external bootstrap tree.
  - verify-config is non-destructive and does not install packages, rewrite live artifacts, or initialize repos.
  - apply is the only live-write entrypoint. It installs/updates runner, cron, logrotate,
    systemd/udev integration, and ensures required directories exist.
  - Configuration and secrets are preserved by default.
  - The bootstrap tree is used for fresh create/reset and missing-secret initialization only.
EOF_USAGE_MAIN
}

parse_args() {
  while (( $# > 0 )); do
    case "${1}" in
      -h|--help)
        usage
        exit 0
        ;;
      write-config|verify-config|apply)
        if [[ -n "${COMMAND}" ]]; then
          die "Only one command is allowed (got: ${COMMAND} and ${1})."
        fi
        COMMAND="${1}"
        shift
        ;;
      --keep-config)
        CONFIG_MODE="keep"
        shift
        ;;
      --reset-config)
        CONFIG_MODE="reset"
        shift
        ;;
      --keep-secrets)
        SECRETS_MODE="keep"
        shift
        ;;
      --init-secrets)
        SECRETS_MODE="init"
        shift
        ;;
      *)
        if [[ -z "${COMMAND}" && "${1}" != --* ]]; then
          die "Unknown command: ${1}. Use verify-config."
        fi
        die "Unknown argument: ${1}."
        ;;
    esac
  done

  [[ -n "${COMMAND}" ]] || die "Missing command."

  if [[ "${COMMAND}" != "write-config" ]] && [[ -n "${BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR}" ]]; then
    die "${BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR}"
  fi

  case "${COMMAND}" in
    write-config)
      if [[ "${CONFIG_MODE}" != "merge" || "${SECRETS_MODE}" != "init" ]]; then
        die "write-config does not accept config/secret mode options. Use verify-config or apply."
      fi
      ;;
    verify-config|apply)
      ;;
    *)
      die "Internal error: unknown COMMAND=${COMMAND}"
      ;;
  esac
}

upgrade_backup_setup_operator_config_tree_if_needed() {
  local config_file="${1:?config file required}"
  local current=""

  current="$(read_kv_value_from_file "${config_file}" "config_schema_version" || true)"
  if [[ -z "${current}" ]]; then
    die "Missing config_schema_version in backup bootstrap config: ${config_file}"
  fi
  case "${current}" in
    "${BACKUP_SETUP_CONFIG_SCHEMA_VERSION}")
      return 0
      ;;
    *)
      die "Unsupported backup bootstrap config schema_version=${current} in ${config_file} (expected ${BACKUP_SETUP_CONFIG_SCHEMA_VERSION})"
      ;;
  esac
}


backup_setup_config_default_line() {
  local key="${1:?key required}"
  case "${key}" in
    config_schema_version) printf 'config_schema_version="%s"\n' "${BACKUP_SETUP_CONFIG_SCHEMA_VERSION}" ;;
    HOST_SCOPE_NAME) printf 'HOST_SCOPE_NAME="%s"\n' "${INITIAL_BACKUP_HOST_SCOPE_NAME:-${TARGET_HOST}}" ;;
    CRON_HOUR) printf 'CRON_HOUR="%s"\n' "${DEFAULT_CRON_HOUR}" ;;
    CRON_MINUTE) printf 'CRON_MINUTE="%s"\n' "${DEFAULT_CRON_MINUTE}" ;;
    BACKUP_DASHBOARD_DIR) printf 'BACKUP_DASHBOARD_DIR="%s"\n' "${DEFAULT_BACKUP_DASHBOARD_DIR}" ;;
    *) die "Internal error: unsupported backup setup config default key: ${key}" ;;
  esac
}

validate_backup_setup_operator_config_file() {
  local config_file="${1:?config file required}"
  local line key lineno=0

  [[ -f "${config_file}" ]] || die "Missing backup setup config: ${config_file}"
  [[ -s "${config_file}" ]] || die "Empty backup setup config: ${config_file}"
  ensure_no_unexpanded_tokens "${config_file}"
  bash -n "${config_file}" >/dev/null 2>&1 || die "Shell syntax check failed for ${config_file}"
  upgrade_backup_setup_operator_config_tree_if_needed "${config_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    [[ "${line}" == \#* ]] && continue
    [[ "${line}" == *=* ]] || die "Invalid key=value line in ${config_file}:${lineno}: ${line}"
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "${key}" in
      config_schema_version|HOST_SCOPE_NAME|CRON_HOUR|CRON_MINUTE|BACKUP_DASHBOARD_DIR)
        ;;
      *)
        die "Unknown backup setup config key in ${config_file}:${lineno}: ${key}"
        ;;
    esac
  done < "${config_file}"
}

merge_backup_setup_config_defaults() {
  local -a keys=(
    config_schema_version
    HOST_SCOPE_NAME
    CRON_HOUR
    CRON_MINUTE
    BACKUP_DASHBOARD_DIR
  )
  local -a missing=()
  local key added_at

  if [[ ! -f "${BACKUP_SETUP_CONFIG_FILE}" ]]; then
    write_backup_setup_bootstrap_config
    return 0
  fi

  validate_backup_setup_operator_config_file "${BACKUP_SETUP_CONFIG_FILE}"
  chmod 600 "${BACKUP_SETUP_CONFIG_FILE}" 2>/dev/null || true

  for key in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${BACKUP_SETUP_CONFIG_FILE}"; then
      missing+=("${key}")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log "Backup setup config exists: ${BACKUP_SETUP_CONFIG_FILE} (no missing keys)"
    return 0
  fi

  added_at="$(date +'%Y-%m-%d %H:%M:%S')"
  log "Backup setup config exists: ${BACKUP_SETUP_CONFIG_FILE} (adding missing keys: ${missing[*]})"
  {
    echo
    echo "# --- Added by penelope-backup-setup ${VERSION} on ${added_at} ---"
    for key in "${missing[@]}"; do
      backup_setup_config_default_line "${key}"
    done
  } >> "${BACKUP_SETUP_CONFIG_FILE}"
  chmod 600 "${BACKUP_SETUP_CONFIG_FILE}" 2>/dev/null || true
  validate_backup_setup_operator_config_file "${BACKUP_SETUP_CONFIG_FILE}"
}

validate_backup_setup_active_secret_file() {
  local path="${1:?secret path required}"
  local label="${2:?secret label required}"
  local value=""

  [[ -f "${path}" ]] || die "Missing active backup setup secret: ${path} (run write-config and replace the placeholder first)"
  [[ -r "${path}" ]] || die "Active backup setup secret is not readable: ${path}"
  value="$(head -n 1 "${path}" | tr -d '\r\n')"
  [[ -n "${value}" ]] || die "Empty active backup setup secret: ${path}"
  validate_secret_not_placeholder "backup setup ${label} secret ${path}" "${value}"
}

validate_backup_setup_active_secrets() {
  validate_backup_setup_active_secret_file "${BACKUP_SETUP_SECRET_SYSTEM}" "system"
  validate_backup_setup_active_secret_file "${BACKUP_SETUP_SECRET_HOME}" "home"
  validate_backup_setup_active_secret_file "${BACKUP_SETUP_SECRET_ARCHIVE}" "_archive"
}

refresh_backup_setup_package_owned_examples() {
  ensure_dir "${BACKUP_SETUP_CONFIG_DIR}" 0755 root root
  write_backup_setup_example_files
}

bootstrap_secret_path_for_restic_file() {
  local file="${1:?pw file required}"
  case "${file}" in
    "${RESTIC_PW_SYSTEM}") printf '%s
' "${BACKUP_SETUP_SECRET_SYSTEM}" ;;
    "${RESTIC_PW_HOME}") printf '%s
' "${BACKUP_SETUP_SECRET_HOME}" ;;
    "${RESTIC_PW_ARCHIVE}") printf '%s
' "${BACKUP_SETUP_SECRET_ARCHIVE}" ;;
    *) return 1 ;;
  esac
}

bootstrap_secret_value_for_restic_file() {
  local file="${1:?pw file required}"
  local secret_path=""
  local value=""

  secret_path="$(bootstrap_secret_path_for_restic_file "${file}")" || die "Internal error: unknown bootstrap secret target for ${file}"
  [[ -f "${secret_path}" ]] || die "Missing bootstrap secret file: ${secret_path} (run write-config and edit it first)"
  value="$(head -n 1 "${secret_path}" | tr -d '
')"
  [[ -n "${value}" ]] || die "Empty bootstrap secret file: ${secret_path}"
  validate_secret_not_placeholder "bootstrap secret ${secret_path}" "${value}"
  printf '%s' "${value}"
}

load_bootstrap_placeholders() {
  local host_scope_value=""
  local cron_hour_value=""
  local cron_minute_value=""
  local dashboard_value=""

  [[ -f "${BACKUP_SETUP_CONFIG_FILE}" ]] || die "Missing ${BACKUP_SETUP_CONFIG_FILE} (run write-config and edit it first)"
  validate_backup_setup_operator_config_file "${BACKUP_SETUP_CONFIG_FILE}"

  host_scope_value="$(read_kv_value_from_file "${BACKUP_SETUP_CONFIG_FILE}" "HOST_SCOPE_NAME" || true)"
  cron_hour_value="$(read_kv_value_from_file "${BACKUP_SETUP_CONFIG_FILE}" "CRON_HOUR" || true)"
  cron_minute_value="$(read_kv_value_from_file "${BACKUP_SETUP_CONFIG_FILE}" "CRON_MINUTE" || true)"
  dashboard_value="$(read_kv_value_from_file "${BACKUP_SETUP_CONFIG_FILE}" "BACKUP_DASHBOARD_DIR" || true)"

  [[ -n "${host_scope_value}" ]] || die "Missing HOST_SCOPE_NAME in ${BACKUP_SETUP_CONFIG_FILE}"
  [[ -n "${cron_hour_value}" ]] || die "Missing CRON_HOUR in ${BACKUP_SETUP_CONFIG_FILE}"
  [[ -n "${cron_minute_value}" ]] || die "Missing CRON_MINUTE in ${BACKUP_SETUP_CONFIG_FILE}"
  [[ -n "${dashboard_value}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${BACKUP_SETUP_CONFIG_FILE}"

  validate_host_scope_name "${host_scope_value}" "backup bootstrap config"
  PLACEHOLDER_HOST_SCOPE_NAME="${host_scope_value}"
  PLACEHOLDER_CRON_HOUR="${cron_hour_value}"
  PLACEHOLDER_CRON_MINUTE="${cron_minute_value}"
  PLACEHOLDER_BACKUP_DASHBOARD_DIR="${dashboard_value}"
}

write_backup_setup_bootstrap_config() {
  (
    umask 077
    cat > "${BACKUP_SETUP_CONFIG_FILE}" <<EOF_BACKUP_SETUP_BOOTSTRAP
# Generated by penelope-backup-setup ${VERSION}
# Backup bootstrap config (operator-edited, root-only)
# Used for creating/resetting /etc/penelope/backup.conf and for deriving
# HOST_SCOPE_NAME before backup.conf exists again.
config_schema_version="${BACKUP_SETUP_CONFIG_SCHEMA_VERSION}"
HOST_SCOPE_NAME="${INITIAL_BACKUP_HOST_SCOPE_NAME:-${TARGET_HOST}}"
CRON_HOUR="${DEFAULT_CRON_HOUR}"
CRON_MINUTE="${DEFAULT_CRON_MINUTE}"
BACKUP_DASHBOARD_DIR="${DEFAULT_BACKUP_DASHBOARD_DIR}"
EOF_BACKUP_SETUP_BOOTSTRAP
  ) || die "Failed to scaffold backup bootstrap config: ${BACKUP_SETUP_CONFIG_FILE}"
  chmod 600 "${BACKUP_SETUP_CONFIG_FILE}" 2>/dev/null || true
}

write_backup_setup_bootstrap_secret_if_missing() {
  local path="${1:?path required}"
  local label="${2:?label required}"
  if [[ -f "${path}" ]]; then
    chmod 600 "${path}" 2>/dev/null || true
    return 0
  fi
  (
    umask 077
    printf 'change-me
' > "${path}"
  ) || die "Failed to scaffold ${label}: ${path}"
  chmod 600 "${path}" 2>/dev/null || true
}

write_backup_setup_example_file() {
  local path="${1:?path required}"
  local mode="${2:?mode required}"
  local content="${3:?content required}"

  printf '%s\n' "${content}" > "${path}" || die "Failed to write backup setup example: ${path}"
  chown root:root "${path}" || die "Failed to chown backup setup example: ${path}"
  chmod "${mode}" "${path}" || die "Failed to chmod backup setup example: ${path}"
}

write_backup_setup_example_files() {
  ensure_dir "${BACKUP_SETUP_EXAMPLES_DIR}" 0755 root root
  ensure_dir "${BACKUP_SETUP_EXAMPLE_SECRETS_DIR}" 0755 root root

  write_backup_setup_example_file "${BACKUP_SETUP_EXAMPLE_CONFIG_FILE}" 0644 "$(cat <<EOF_BACKUP_SETUP_CONFIG_EXAMPLE
# Backup bootstrap config example for penelope-backup-setup ${VERSION}
# Copy intended values into ${BACKUP_SETUP_CONFIG_FILE}; this file is not active state.
config_schema_version="${BACKUP_SETUP_CONFIG_SCHEMA_VERSION}"
HOST_SCOPE_NAME="${TARGET_HOST}"
CRON_HOUR="${DEFAULT_CRON_HOUR}"
CRON_MINUTE="${DEFAULT_CRON_MINUTE}"
BACKUP_DASHBOARD_DIR="${DEFAULT_BACKUP_DASHBOARD_DIR}"
EOF_BACKUP_SETUP_CONFIG_EXAMPLE
)"

  write_backup_setup_example_file "${BACKUP_SETUP_EXAMPLE_SECRET_SYSTEM}" 0644 "$(cat <<'EOF_SYSTEM_SECRET_EXAMPLE'
change-me
EOF_SYSTEM_SECRET_EXAMPLE
)"
  write_backup_setup_example_file "${BACKUP_SETUP_EXAMPLE_SECRET_HOME}" 0644 "$(cat <<'EOF_HOME_SECRET_EXAMPLE'
change-me
EOF_HOME_SECRET_EXAMPLE
)"
  write_backup_setup_example_file "${BACKUP_SETUP_EXAMPLE_SECRET_ARCHIVE}" 0644 "$(cat <<'EOF_ARCHIVE_SECRET_EXAMPLE'
change-me
EOF_ARCHIVE_SECRET_EXAMPLE
)"
}

init_backup_setup_config_tree() {
  ensure_dir "${BACKUP_SETUP_CONFIG_DIR}" 0755 root root
  ensure_dir "${BACKUP_SETUP_SECRETS_DIR}" 0700 root root

  merge_backup_setup_config_defaults

  write_backup_setup_bootstrap_secret_if_missing "${BACKUP_SETUP_SECRET_SYSTEM}" "bootstrap system secret"
  write_backup_setup_bootstrap_secret_if_missing "${BACKUP_SETUP_SECRET_HOME}" "bootstrap home secret"
  write_backup_setup_bootstrap_secret_if_missing "${BACKUP_SETUP_SECRET_ARCHIVE}" "bootstrap archive secret"
  write_backup_setup_example_files
}

# -------------------- logging --------------------
# Logging and utility functions are now provided by penelope-common.sh:
#   ts(), log(), warn(), die()
#   require_root(), require_cmd(), ensure_dir(), ensure_file()
# See penelope-common.sh for implementation details.

# write_log_functions_block_bash(), write_log_functions_block_sh(),
# write_common_guards_block_bash(), write_common_guards_block_sh(),
# inject_block_into_file(), inject_log_functions_macro_if_present(),
# inject_common_guards_macro_if_present(), and inject_known_macros_if_present()
# are now provided by penelope-common.sh

# validate_shell_script(), validate_systemd_unit(), validate_generated_file(),
# and ensure_no_unexpanded_tokens() are now provided by penelope-common.sh

stamp_setup_version() {
  local file="${1:?file required}"
  local label="${2:-file}"

  # Substitute setup version placeholder.
  sed -i "s/___PENELOPE_SETUP_VERSION___/${VERSION}/g" "${file}"

  if grep -q "___PENELOPE_SETUP_VERSION___" "${file}"; then
    die "${label}: version placeholder not substituted (${file})"
  fi

  # Enforce that installed artifacts carry the setup version.
  # Active operator-state files may intentionally use creation-time wording
  # instead of a live "# Version:" header, but they still must carry the setup
  # version that created the template.
  if [[ "${label}" == "usb-allowlist" ]]; then
    if ! grep -qE "^# Template version at creation time: ${VERSION}\b" "${file}"; then
      die "${label}: missing or mismatched '# Template version at creation time: ${VERSION}' header (${file})"
    fi
    return 0
  fi

  if ! grep -qE "^# Version: ${VERSION}\b" "${file}"; then
    die "${label}: missing or mismatched '# Version: ${VERSION}' header (${file})"
  fi
}

# escape_sed_replacement() is now provided by penelope-common.sh

apply_placeholders() {
  # Substitute simple placeholders in generated artifacts.
  # Keep this deterministic and minimal: only explicit tokens listed here are replaced.
  local file="${1:?file required}"

  local project_esc
  project_esc="$(escape_sed_replacement "${PROJECT}")"
  sed -i "s/___PENELOPE_PROJECT___/${project_esc}/g" "${file}"

  local rendered_host_scope="${PLACEHOLDER_HOST_SCOPE_NAME:-${HOST_SCOPE_NAME}}"
  local host_scope_esc
  host_scope_esc="$(escape_sed_replacement "${rendered_host_scope}")"
  sed -i "s/___PENELOPE_INITIAL_HOST_SCOPE_NAME___/${host_scope_esc}/g" "${file}"

  local backup_log_esc
  backup_log_esc="$(escape_sed_replacement "${BACKUP_LOG}")"
  sed -i "s/___PENELOPE_BACKUP_LOG___/${backup_log_esc}/g" "${file}"

  if [[ -n "${PLACEHOLDER_CRON_HOUR:-}" ]]; then
    local cron_hour_esc
    cron_hour_esc="$(escape_sed_replacement "${PLACEHOLDER_CRON_HOUR}")"
    sed -i "s/___PENELOPE_DEFAULT_CRON_HOUR___/${cron_hour_esc}/g" "${file}"
    sed -i "s/___PENELOPE_CRON_HOUR___/${cron_hour_esc}/g" "${file}"
  fi
  if [[ -n "${PLACEHOLDER_CRON_MINUTE:-}" ]]; then
    local cron_minute_esc
    cron_minute_esc="$(escape_sed_replacement "${PLACEHOLDER_CRON_MINUTE}")"
    sed -i "s/___PENELOPE_DEFAULT_CRON_MINUTE___/${cron_minute_esc}/g" "${file}"
    sed -i "s/___PENELOPE_CRON_MINUTE___/${cron_minute_esc}/g" "${file}"
  fi
  if [[ -n "${PLACEHOLDER_BACKUP_DASHBOARD_DIR:-}" ]]; then
    local dashboard_dir_esc
    dashboard_dir_esc="$(escape_sed_replacement "${PLACEHOLDER_BACKUP_DASHBOARD_DIR}")"
    sed -i "s#___PENELOPE_DEFAULT_BACKUP_DASHBOARD_DIR___#${dashboard_dir_esc}#g" "${file}"
  fi
}

annotate_generated_shellcheck_sources() {
  local file="${1:?file required}"
  local label="${2:-file}"

  [[ -f "${file}" ]] || die "${label}: generated file missing before ShellCheck source annotation: ${file}"
  head -n 1 "${file}" | grep -qx '#!/usr/bin/env bash' || return 0

  python3 - "${file}" <<'PY_SHELLCHECK_SOURCE_ANNOTATIONS'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

replacements = [
    (
        '''if [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"''',
        '''if [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  # Runtime sibling common library; setup validates that the installed helper can find it.
  # shellcheck disable=SC1090,SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"''',
    ),
    (
        '''if [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  # shellcheck source=/usr/local/lib/penelope/common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"''',
        '''if [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  # Runtime sibling common library; setup validates that the installed helper can find it.
  # shellcheck disable=SC1090,SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"''',
    ),
    (
        '''elif [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  source "/usr/local/lib/penelope/common.sh"''',
        '''elif [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  # Runtime installed common library; this host path is validated by backup-setup apply.
  # shellcheck disable=SC1091
  source "/usr/local/lib/penelope/common.sh"''',
    ),
    (
        '''elif [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  # shellcheck source=/usr/local/lib/penelope/common.sh
  source "/usr/local/lib/penelope/common.sh"''',
        '''elif [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  # Runtime installed common library; this host path is validated by backup-setup apply.
  # shellcheck disable=SC1091
  source "/usr/local/lib/penelope/common.sh"''',
    ),
    (
        '''  # shellcheck source=/etc/penelope/backup.conf
  source "${CONF_FILE}"''',
        '''  # shellcheck source=/dev/null
  source "${CONF_FILE}"''',
    ),
    (
        '''# shellcheck source=/etc/penelope/backup.conf
source "${BACKUP_CONF}"''',
        '''# shellcheck source=/dev/null
source "${BACKUP_CONF}"''',
    ),
]

changed = False
for old, new in replacements:
    if old in text and new not in text:
        text = text.replace(old, new)
        changed = True

if changed:
    path.write_text(text, encoding="utf-8")
PY_SHELLCHECK_SOURCE_ANNOTATIONS
}

# Override install_file_from_heredoc() from penelope-common.sh
# This backup-setup-specific version adds placeholder substitution and version stamping
# that use script-global variables (PROJECT, INITIAL_HOST_SCOPE_NAME, VERSION, etc.)
install_file_from_heredoc() {
  # Usage:
  #   install_file_from_heredoc <path> <mode> <owner> <group> <label>
  #   Content is read from stdin (typically via a single-quoted heredoc).
  #
  local path="${1:?path required}"
  local mode="${2:?mode required}"
  local owner="${3:?owner required}"
  local group="${4:?group required}"
  local label="${5:-file}"

  local dir
  dir="$(dirname "${path}")"
  install -d -m 0755 -o root -g root "${dir}"

  local tmp
  tmp="$(mktemp "${dir}/.$(basename -- "${path}").tmp.XXXXXX")" || die "Failed to create temporary ${label}: ${path}"

  # Read file content into a temporary file and publish atomically only after validation.
  if ! cat > "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to write temporary ${label}: ${path}"
  fi

  # Keep the temp file private until render/validation has succeeded. Some
  # validation helpers call die(); run the render/validation phase in a subshell
  # so failures can still remove the unpublished temp file here.
  if ! (
    inject_known_macros_if_present "${tmp}"
    annotate_generated_shellcheck_sources "${tmp}" "${label}"
    apply_placeholders "${tmp}"
    stamp_setup_version "${tmp}" "${label}"
    validate_generated_file "${tmp}"
    ensure_no_unexpanded_tokens "${tmp}"
  ); then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to render or validate ${label}: ${path}"
  fi

  # Apply final ownership/mode only after validation, then publish with atomic mv.
  chown "${owner}:${group}" "${tmp}" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to set owner/group on temporary ${label}: ${path}"
  }
  chmod "${mode}" "${tmp}" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to set mode on temporary ${label}: ${path}"
  }
  mv -f -- "${tmp}" "${path}" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to publish ${label}: ${path}"
  }
}

emit_generated_bash4_guard() {
  cat <<'EOF_GENERATED_BASH4_GUARD'
if (( BASH_VERSINFO[0] < 4 )); then
  >&2 echo "ERROR: Bash 4.0 or higher required"
  exit 1
fi
EOF_GENERATED_BASH4_GUARD
}

emit_generated_project_prelude() {
  emit_generated_bash4_guard
  cat <<'EOF_GENERATED_PROJECT_PRELUDE'
readonly PROJECT="___PENELOPE_PROJECT___"
EOF_GENERATED_PROJECT_PRELUDE
}

emit_generated_common_project_prelude() {
  cat <<'EOF_GENERATED_COMMON_PROJECT_HEAD'
___PENELOPE_SOURCE_COMMON___
EOF_GENERATED_COMMON_PROJECT_HEAD
  echo
  emit_generated_project_prelude
}

validate_host_scope_name() {
  local host_scope="${1:?host scope required}"
  local source="${2:-HOST_SCOPE_NAME}"
  [[ "${host_scope}" =~ ^[a-z0-9][a-z0-9_-]{0,61}$ ]] || die "Invalid HOST_SCOPE_NAME from ${source}: ${host_scope} (expected ^[a-z0-9][a-z0-9_-]{0,61}$)."
}

emit_generated_backup_conf_context_helpers() {
  cat <<'EOF_GENERATED_BACKUP_CONF_CONTEXT_HELPERS'
default_target_host() {
  printf '%s\n' "${PENELOPE_TARGET_HOST:-$(hostname -s)}"
}

validate_host_scope_name() {
  local host_scope="${1:?host scope required}"
  local source="${2:-HOST_SCOPE_NAME}"
  [[ "${host_scope}" =~ ^[a-z0-9][a-z0-9_-]{0,61}$ ]] || die "Invalid HOST_SCOPE_NAME from ${source}: ${host_scope} (expected ^[a-z0-9][a-z0-9_-]{0,61}$)."
}

resolve_host_scope_name_from_conf() {
  local conf_file="${1:-}"
  local target_host="${2:?target host required}"
  local host_scope=""
  local source="target_host"
  local conf_host_scope=""

  if [[ -n "${PENELOPE_HOST_SCOPE_NAME:-}" ]]; then
    host_scope="${PENELOPE_HOST_SCOPE_NAME}"
    source="PENELOPE_HOST_SCOPE_NAME"
  fi

  if [[ -n "${conf_file}" && -f "${conf_file}" ]]; then
    conf_host_scope="$(read_required_kv_value_from_conf "${conf_file}" "HOST_SCOPE_NAME")"
    [[ "${conf_host_scope}" != *"___PENELOPE_"* ]] || die "HOST_SCOPE_NAME in ${conf_file} still contains placeholder markers."
    host_scope="${conf_host_scope}"
    source="${conf_file}:HOST_SCOPE_NAME"
  fi

  host_scope="${host_scope:-${target_host}}"
  validate_host_scope_name "${host_scope}" "${source}"
  printf '%s\n' "${host_scope}"
}

validate_backup_dashboard_dir_value() {
  local dash_dir="${1:?dashboard dir required}"
  local source="${2:-BACKUP_DASHBOARD_DIR}"
  [[ -n "${dash_dir}" ]] || die "Empty BACKUP_DASHBOARD_DIR from ${source}."
  [[ "${dash_dir}" == /* ]] || die "BACKUP_DASHBOARD_DIR from ${source} must be an absolute path (got: ${dash_dir})."
}

validate_positive_integer_value() {
  local value="${1:?value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} from ${source} must be a positive integer (got: ${value})."
  (( value > 0 )) || die "${name} from ${source} must be greater than zero."
}

validate_nonnegative_integer_value() {
  local value="${1:?value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} from ${source} must be a non-negative integer (got: ${value})."
}

validate_bool_01_value() {
  local value="${1:?value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ "${value}" == "0" || "${value}" == "1" ]] || die "${name} from ${source} must be 0 or 1 (got: ${value})."
}

validate_absolute_path_value() {
  local value="${1:?value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ -n "${value}" ]] || die "${name} from ${source} must not be empty."
  [[ "${value}" == /* ]] || die "${name} from ${source} must be an absolute path (got: ${value})."
}

validate_octal_umask_value() {
  local value="${1:?value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ "${value}" =~ ^[0-7]{3,4}$ ]] || die "${name} from ${source} must be a 3- or 4-digit octal umask (got: ${value})."
}

validate_iso_date_or_empty_value() {
  local value="${1-}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "${name} from ${source} must be a strict ISO date in YYYY-MM-DD format (got: ${value})."
  date -u -d "${value}" +%F >/dev/null 2>&1 || die "${name} from ${source} must be a valid ISO date (got: ${value})."
}

validate_full_backup_weekdays_value() {
  local value="${1:?weekday value required}"
  local name="${2:?name required}"
  local source="${3:-${name}}"
  local normalized=""
  local item=""
  local -a weekdays=()

  normalized="${value,,}"
  normalized="${normalized//[[:space:]]/}"
  [[ -n "${normalized}" ]] || die "${name} from ${source} must not be empty."

  IFS=',' read -r -a weekdays <<< "${normalized}"
  for item in "${weekdays[@]}"; do
    [[ -n "${item}" ]] || die "${name} from ${source} contains an empty weekday entry (got: ${value})."
    case "${item}" in
      mon|tue|wed|thu|fri|sat|sun) : ;;
      *) die "${name} from ${source} must contain comma-separated weekdays from mon,tue,wed,thu,fri,sat,sun (got: ${value})." ;;
    esac
  done
}

read_required_kv_value_from_conf() {
  local conf_file="${1:?config file required}"
  local key="${2:?key required}"
  local value=""
  value="$(read_kv_value_from_file "${conf_file}" "${key}" || true)"
  [[ -n "${value}" ]] || die "Missing required ${key} in ${conf_file}."
  printf '%s
' "${value}"
}

require_usb_allowlist_file() {
  local conf_path="${1:?allowlist path required}"
  [[ -f "${conf_path}" ]] || die "Missing USB allow-list: ${conf_path}"
}

resolve_backup_dashboard_dir_from_conf() {
  local conf_file="${1:-}"
  local default_dir="${2:?default dir required}"
  local dash_dir=""
  local source="default dashboard dir"
  if [[ -n "${conf_file}" && -f "${conf_file}" ]]; then
    dash_dir="$(read_required_kv_value_from_conf "${conf_file}" "BACKUP_DASHBOARD_DIR")"
    source="${conf_file}:BACKUP_DASHBOARD_DIR"
  else
    dash_dir="${default_dir}"
  fi
  validate_backup_dashboard_dir_value "${dash_dir}" "${source}"
  printf '%s
' "${dash_dir}"
}

resolve_backup_log_path() {
  local host_scope="${1:?host scope required}"
  printf '/var/log/%s/backup/backup.log\n' "${host_scope}"
}

load_backup_runtime_context_from_conf() {
  local conf_file="${1:-}"
  local default_dashboard_dir="${2:?default dashboard dir required}"
  local resolved_target_host=""

  resolved_target_host="$(default_target_host)"
  [[ -n "${resolved_target_host}" ]] || die "Unable to resolve TARGET_HOST from runtime context."

  TARGET_HOST="${resolved_target_host}"
  HOST_SCOPE_NAME="$(resolve_host_scope_name_from_conf "${conf_file}" "${TARGET_HOST}")"
  BACKUP_DASHBOARD_DIR="$(resolve_backup_dashboard_dir_from_conf "${conf_file}" "${default_dashboard_dir}")"
  LOG_DIR="/var/log/${HOST_SCOPE_NAME}/backup"
  BACKUP_LOG="$(resolve_backup_log_path "${HOST_SCOPE_NAME}")"
  : "${LOG_DIR}"
}

resolve_internal_backup_stale_after_hours_from_conf() {
  local conf_file="${1:-}"
  local default_value="${2:?default stale-after-hours value required}"
  local value=""
  local source="default stale-after-hours"
  if [[ -n "${conf_file}" && -f "${conf_file}" ]]; then
    value="$(read_required_kv_value_from_conf "${conf_file}" "INTERNAL_BACKUP_STALE_AFTER_HOURS")"
    source="${conf_file}:INTERNAL_BACKUP_STALE_AFTER_HOURS"
  else
    value="${default_value}"
  fi
  validate_positive_integer_value "${value}" "INTERNAL_BACKUP_STALE_AFTER_HOURS" "${source}"
  printf '%s
' "${value}"
}

validate_loaded_backup_runtime_controls_from_env() {
  validate_backup_dashboard_dir_value "${BACKUP_DASHBOARD_DIR:-}" "loaded backup.conf:BACKUP_DASHBOARD_DIR"
  validate_positive_integer_value "${INTERNAL_BACKUP_STALE_AFTER_HOURS:-}" "INTERNAL_BACKUP_STALE_AFTER_HOURS" "loaded backup.conf:INTERNAL_BACKUP_STALE_AFTER_HOURS"
  validate_bool_01_value "${FORCE_UNMOUNT_EXTERNAL:-}" "FORCE_UNMOUNT_EXTERNAL" "loaded backup.conf:FORCE_UNMOUNT_EXTERNAL"
  validate_bool_01_value "${WRITE_USB_SUCCESS_MARKER:-}" "WRITE_USB_SUCCESS_MARKER" "loaded backup.conf:WRITE_USB_SUCCESS_MARKER"
  validate_bool_01_value "${ENABLE_PRUNE:-}" "ENABLE_PRUNE" "loaded backup.conf:ENABLE_PRUNE"
  validate_full_backup_weekdays_value "${FULL_BACKUP_WEEKDAYS_INTERNAL:-}" "FULL_BACKUP_WEEKDAYS_INTERNAL" "loaded backup.conf:FULL_BACKUP_WEEKDAYS_INTERNAL"
  validate_full_backup_weekdays_value "${FULL_BACKUP_WEEKDAYS_EXTERNAL:-}" "FULL_BACKUP_WEEKDAYS_EXTERNAL" "loaded backup.conf:FULL_BACKUP_WEEKDAYS_EXTERNAL"
  validate_nonnegative_integer_value "${KEEP_CYCLES_INTERNAL:-}" "KEEP_CYCLES_INTERNAL" "loaded backup.conf:KEEP_CYCLES_INTERNAL"
  validate_nonnegative_integer_value "${KEEP_CYCLES_EXTERNAL:-}" "KEEP_CYCLES_EXTERNAL" "loaded backup.conf:KEEP_CYCLES_EXTERNAL"
  validate_nonnegative_integer_value "${KEEP_UNTAGGED_LAST:-}" "KEEP_UNTAGGED_LAST" "loaded backup.conf:KEEP_UNTAGGED_LAST"
  validate_absolute_path_value "${USB_MOUNT_BASE:-}" "USB_MOUNT_BASE" "loaded backup.conf:USB_MOUNT_BASE"
  validate_octal_umask_value "${USB_FS_UMASK:-}" "USB_FS_UMASK" "loaded backup.conf:USB_FS_UMASK"
}
EOF_GENERATED_BACKUP_CONF_CONTEXT_HELPERS
}


emit_generated_backup_dashboard_file_helpers() {
  cat <<'EOF_GENERATED_DASHBOARD_FILE_HELPERS'
ensure_backup_dashboard() {
  local dash_dir="${1:-${BACKUP_DASHBOARD_DIR:-}}"
  [[ -n "${dash_dir}" ]] || return 0
  install -d -m 0755 -o root -g root "${dash_dir}"
}

clear_backup_dashboard_files() {
  [[ "$#" -gt 0 ]] || return 0
  rm -f -- "$@"
}

make_backup_dashboard_tmp_file() {
  local dash_dir="${1:?dashboard dir required}"
  ensure_backup_dashboard "${dash_dir}" || return 1
  mktemp "${dash_dir}/.penelope-dashboard.XXXXXX"
}

# normalize_disk_name_token is provided by penelope-common.sh. Keep this dashboard
# helper block focused on dashboard paths and files so allow-list validation has a
# single implementation.

usb_signal_file_path() {
  local signal_kind="${1:?signal kind required}"
  local disk_name="${2:?disk name required}"
  local dash_dir="${3:-${BACKUP_DASHBOARD_DIR:-}}"
  local token=""
  token="$(normalize_disk_name_token "${disk_name}")"
  case "${signal_kind}" in
    running)  printf '%s/USB_BACKUP_RUNNING_DO_NOT_REMOVE_%s.txt\n' "${dash_dir}" "${token}" ;;
    ready)    printf '%s/USB_BACKUP_READY_TO_REMOVE_%s.txt\n' "${dash_dir}" "${token}" ;;
    reattach_and_wait) printf '%s/USB_BACKUP_REATTACH_AND_WAIT_%s.txt\n' "${dash_dir}" "${token}" ;;
    hold)     printf '%s/USB_BACKUP_DO_NOT_REMOVE_%s_CONTACT_OPERATOR.txt\n' "${dash_dir}" "${token}" ;;
    *) return 1 ;;
  esac
}

usb_legacy_retry_signal_file_path() {
  local disk_name="${1:?disk name required}"
  local dash_dir="${2:-${BACKUP_DASHBOARD_DIR:-}}"
  local token=""
  token="$(normalize_disk_name_token "${disk_name}")"
  printf '%s/USB_BACKUP_REATTACH_AND_RETRY_%s.txt\n' "${dash_dir}" "${token}"
}

usb_external_status_json_path() {
  local disk_name="${1:?disk name required}"
  local dash_dir="${2:-${BACKUP_DASHBOARD_DIR:-}}"
  local token=""
  token="$(normalize_disk_name_token "${disk_name}")"
  printf '%s/last-external-%s.json\n' "${dash_dir}" "${token}"
}

internal_backup_dashboard_file_path() {
  local file_kind="${1:?file kind required}"
  local dash_dir="${2:-${BACKUP_DASHBOARD_DIR:-}}"
  case "${file_kind}" in
    running)   printf '%s/INTERNAL_BACKUP_RUNNING.txt\n' "${dash_dir}" ;;
    ok)        printf '%s/INTERNAL_BACKUP_OK.txt\n' "${dash_dir}" ;;
    error)     printf '%s/INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt\n' "${dash_dir}" ;;
    stale)     printf '%s/INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt\n' "${dash_dir}" ;;
    last_json) printf '%s/last-internal.json\n' "${dash_dir}" ;;
    *) return 1 ;;
  esac
}

load_internal_backup_dashboard_file_paths() {
  local dash_dir="${1:-${BACKUP_DASHBOARD_DIR:-}}"
  INTERNAL_RUNNING_FILE="$(internal_backup_dashboard_file_path running "${dash_dir}")"
  INTERNAL_OK_FILE="$(internal_backup_dashboard_file_path ok "${dash_dir}")"
  INTERNAL_ERROR_FILE="$(internal_backup_dashboard_file_path error "${dash_dir}")"
  INTERNAL_STALE_FILE="$(internal_backup_dashboard_file_path stale "${dash_dir}")"
  LAST_INTERNAL_JSON="$(internal_backup_dashboard_file_path last_json "${dash_dir}")"
  : "${INTERNAL_RUNNING_FILE}" "${INTERNAL_OK_FILE}" "${INTERNAL_ERROR_FILE}" "${INTERNAL_STALE_FILE}" "${LAST_INTERNAL_JSON}"
}

usb_signal_header() {
  local signal_kind="${1:?signal kind required}"
  local disk_name="${2:?disk name required}"
  local token=""
  token="$(normalize_disk_name_token "${disk_name}")"
  case "${signal_kind}" in
    running)  printf 'USB_BACKUP_RUNNING_DO_NOT_REMOVE_%s\n' "${token}" ;;
    ready)    printf 'USB_BACKUP_READY_TO_REMOVE_%s\n' "${token}" ;;
    reattach_and_wait) printf 'USB_BACKUP_REATTACH_AND_WAIT_%s\n' "${token}" ;;
    hold)     printf 'USB_BACKUP_DO_NOT_REMOVE_%s_CONTACT_OPERATOR\n' "${token}" ;;
    *) return 1 ;;
  esac
}

write_backup_dashboard_notice_file() {
  local out="${1:?output file required}"
  local header="${2:?header required}"
  shift 2

  [[ -n "${out}" ]] || return 0
  local dash_dir="${BACKUP_DASHBOARD_DIR:-$(dirname "${out}")}"
  local tmp=""
  tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || return 1
  {
    echo "${header}"
    echo "timestamp=$(ts)"
    [[ -n "${TARGET_HOST:-}" ]] && echo "host=${TARGET_HOST}"
    [[ -n "${HOST_SCOPE_NAME:-}" ]] && echo "host_scope_name=${HOST_SCOPE_NAME}"
    [[ -n "${RUN_ID:-}" ]] && echo "run_id=${RUN_ID}"
    if [[ "$#" -gt 0 ]]; then
      printf '%s\n' "$@"
    fi
    [[ -n "${BACKUP_LOG:-}" ]] && echo "log=${BACKUP_LOG}"
  } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  chmod 0644 "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
  mv -f "${tmp}" "${out}" || { rm -f -- "${tmp}"; return 1; }
}

append_backup_dashboard_event_line() {
  local out="${1:?output file required}"
  local mode_name="${2:?mode required}"
  local event="${3:?event required}"
  local message="${4:-}"
  local uuid="${5:-}"
  local targets="${6:-}"
  local kind="${7:-}"
  local cycle_id="${8:-}"

  [[ -n "${out}" ]] || return 0
  local dash_dir="${BACKUP_DASHBOARD_DIR:-$(dirname "${out}")}"
  ensure_backup_dashboard "${dash_dir}" || return 1
  {
    printf 'timestamp=%s event=%s mode=%s host=%s host_scope_name=%s run_id=%s uuid=%s targets=%s kind=%s cycle_id=%s log_file=%s message=%q
' \
      "$(ts)" "${event}" "${mode_name}" "${TARGET_HOST:-}" "${HOST_SCOPE_NAME:-}" \
      "${RUN_ID:-}" "${uuid}" "${targets}" "${kind}" "${cycle_id}" "${BACKUP_LOG:-}" "${message}"
  } >> "${out}" || return 1
  if ! chmod 0644 "${out}" 2>/dev/null; then
    warn "Backup-Dashboard event log exists but is not readable as expected: ${out}"
  fi
}

write_backup_dashboard_status_json_file() {
  # Args: <out> <mode> <status> <message> <uuid> <uuids_csv> <kind> <event> <include_run_context> <include_disk_name>
  local out="${1:?output file required}"
  local mode_name="${2:?mode required}"
  local status="${3:?status required}"
  local message="${4:-}"
  local uuid="${5:-}"
  local uuids_csv="${6:-}"
  local kind="${7:-}"
  local event="${8:-}"
  local include_run_context="${9:-0}"
  local include_disk_name="${10:-0}"

  [[ -n "${out}" ]] || return 0
  local dash_dir="${BACKUP_DASHBOARD_DIR:-$(dirname "${out}")}"
  local tmp=""
  tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || return 1

  python3 - \
    "${tmp}" "${mode_name}" "${status}" "${message}" "${uuid}" "${uuids_csv}" \
    "${kind}" "${event}" "${include_run_context}" "${include_disk_name}" <<'PY_DASHBOARD_STATUS_JSON_FILE'
import json, os, sys, time
(
    out,
    mode_name,
    status,
    message,
    uuid,
    uuids_csv,
    kind,
    event,
    include_run_context,
    include_disk_name,
) = sys.argv[1:11]

host_scope_name = os.environ.get("HOST_SCOPE_NAME", "")
log_file = os.environ.get("BACKUP_LOG", "")
if not log_file and host_scope_name:
    log_file = f"/var/log/{host_scope_name}/backup/backup.log"

data = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": os.environ.get("TARGET_HOST", ""),
    "host_scope_name": host_scope_name,
    "mode": mode_name,
    "status": status,
    "message": message,
    "log_file": log_file,
}
if uuid or include_run_context == "1":
    data["uuid"] = uuid
if kind:
    data["kind"] = kind
if event:
    data["event"] = event
if include_disk_name == "1":
    data["disk_name"] = os.environ.get("RUN_DISK_NAME") or os.environ.get("DISK_NAME", "")
if include_run_context == "1":
    data["run_id"] = os.environ.get("RUN_ID", "")
    data["targets"] = os.environ.get("RUN_TARGETS", "")
    data["force"] = os.environ.get("RUN_FORCE", "0")
    if mode_name == "external":
        data["external_safe_to_remove"] = os.environ.get("EXTERNAL_SAFE_TO_REMOVE", "")
    data["cycle_id"] = os.environ.get("RUN_CYCLE_ID", "")
    data["uuids"] = [u for u in uuids_csv.split(",") if u]
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY_DASHBOARD_STATUS_JSON_FILE
  local rc=$?
  if (( rc != 0 )); then
    rm -f -- "${tmp}"
    return "${rc}"
  fi
  chmod 0644 "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
  mv -f "${tmp}" "${out}" || { rm -f -- "${tmp}"; return 1; }
}
EOF_GENERATED_DASHBOARD_FILE_HELPERS
}

emit_generated_usb_allowlist_validation_helpers() {
  cat <<'EOF_GENERATED_USB_ALLOWLIST_VALIDATION_HELPERS'
assert_usb_allowlist_uuid_value() {
  local uuid="${1:?uuid required}"
  local context="${2:-USB allow-list UUID}"
  if [[ ! "${uuid}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    die "${context} must look like a filesystem UUID (letters/digits with optional hyphens): ${uuid}"
  fi
}

assert_usb_allowlist_disk_name_value() {
  local disk_name="${1:?disk name required}"
  local context="${2:-USB allow-list DISK_NAME}"
  if (( ${#disk_name} > 16 )); then
    die "${context} '${disk_name}' is too long (${#disk_name} characters). Choose at most 16 characters so DISK_NAME and filesystem LABEL can stay identical."
  fi
  if [[ ! "${disk_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "${context} '${disk_name}' is invalid. Use letters, digits, dot, underscore, or hyphen; start with a letter or digit."
  fi
}

validate_usb_allowlist_disk_names() {
  local conf_path="${1:?allowlist path required}"
  [[ -f "${conf_path}" ]] || return 0
  local line_no=0 raw uuid name token
  local message=""
  local -A seen_tokens=()
  local -A seen_uuids=()
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    line_no=$((line_no + 1))
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    uuid="${raw%%[[:space:]]*}"
    name="${raw#"${uuid}"}"
    name="${name#"${name%%[![:space:]]*}"}"
    [[ -n "${uuid}" ]] || die "Invalid USB allow-list line ${line_no} in ${conf_path}: missing UUID."
    assert_usb_allowlist_uuid_value "${uuid}" "Invalid USB allow-list line ${line_no} in ${conf_path}: UUID"
    [[ -n "${name}" ]] || die "Invalid USB allow-list line ${line_no} in ${conf_path}: DISK_NAME is mandatory."
    assert_usb_allowlist_disk_name_value "${name}" "Invalid USB allow-list line ${line_no} in ${conf_path}: DISK_NAME"
    if [[ -n "${seen_uuids[${uuid}]:-}" ]]; then
      message="Duplicate UUID '${uuid}' in ${conf_path}: line ${line_no}"
      message+=" conflicts with earlier line ${seen_uuids[${uuid}]}."
      message+=" Keep exactly one <UUID> <DISK_NAME> entry per registered disk."
      die "${message}"
    fi
    token="$(normalize_disk_name_token "${name}")"
    if [[ -n "${seen_tokens[${token}]:-}" && "${seen_tokens[${token}]}" != "${uuid}" ]]; then
      message="Duplicate DISK_NAME token '${token}' in ${conf_path}:"
      message+=" UUID ${uuid} conflicts with UUID ${seen_tokens[${token}]}."
      message+=" Choose unique disk names."
      die "${message}"
    fi
    seen_uuids["${uuid}"]="${line_no}"
    seen_tokens["${token}"]="${uuid}"
  done < "${conf_path}"
}

count_usb_allowlist_entries() {
  local conf_path="${1:?allowlist path required}"
  [[ -f "${conf_path}" ]] || {
    printf '0
'
    return 0
  }
  local raw count=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    count=$((count + 1))
  done < "${conf_path}"
  printf '%s
' "${count}"
}

EOF_GENERATED_USB_ALLOWLIST_VALIDATION_HELPERS
}

emit_generated_usb_allowlist_helpers() {
  emit_generated_usb_allowlist_validation_helpers
  cat <<'EOF_GENERATED_USB_ALLOWLIST_HELPERS'
read_usb_allowlist_name_for_uuid() {
  local conf_path="${1:?allowlist path required}"
  local uuid="${2:?uuid required}"
  [[ -f "${conf_path}" ]] || return 0
  local raw entry_uuid name
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    name="${raw#"${entry_uuid}"}"
    name="${name#"${name%%[![:space:]]*}"}"
    if [[ "${entry_uuid}" == "${uuid}" ]]; then
      printf '%s
' "${name}"
      return 0
    fi
  done < "${conf_path}"
}

require_usb_allowlist_name_for_uuid() {
  local conf_path="${1:?allowlist path required}"
  local uuid="${2:?uuid required}"
  local name=""
  name="$(read_usb_allowlist_name_for_uuid "${conf_path}" "${uuid}")"
  [[ -n "${name}" ]] || die "Allow-list entry for UUID ${uuid} must define a non-empty DISK_NAME in ${conf_path}."
  printf '%s
' "${name}"
}

require_usb_allowlist_uuid_for_disk_name() {
  local conf_path="${1:?allowlist path required}"
  local disk_name="${2:?disk name required}"
  local match_count=0
  local matched_uuid=""
  local raw entry_uuid entry_name

  assert_usb_allowlist_disk_name_value "${disk_name}" "DISK_NAME"
  validate_usb_allowlist_disk_names "${conf_path}"
  [[ -f "${conf_path}" ]] || die "Missing USB allow-list: ${conf_path}"

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    entry_name="${raw#"${entry_uuid}"}"
    entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
    entry_name="${entry_name%%[[:space:]]*}"
    if [[ "${entry_name}" == "${disk_name}" ]]; then
      match_count=$((match_count + 1))
      matched_uuid="${entry_uuid}"
    fi
  done < "${conf_path}"

  if (( match_count != 1 )); then
    die "DISK_NAME '${disk_name}' must match exactly one entry in ${conf_path}; matched ${match_count}."
  fi
  printf '%s
' "${matched_uuid}"
}

ensure_unique_usb_allowlist_disk_name() {
  local conf_path="${1:?allowlist path required}"
  local uuid="${2:?uuid required}"
  local disk_name="${3:?disk name required}"
  local wanted_token=""
  local raw entry_uuid entry_name entry_token
  assert_usb_allowlist_disk_name_value "${disk_name}" "DISK_NAME"
  wanted_token="$(normalize_disk_name_token "${disk_name}")"
  [[ -n "${wanted_token}" ]] || die "DISK_NAME is required."
  [[ -f "${conf_path}" ]] || return 0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    entry_name="${raw#"${entry_uuid}"}"
    entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
    [[ -n "${entry_name}" ]] || continue
    entry_token="$(normalize_disk_name_token "${entry_name}")"
    if [[ "${entry_token}" == "${wanted_token}" && "${entry_uuid}" != "${uuid}" ]]; then
      die "DISK_NAME '${disk_name}' conflicts with existing registered disk '${entry_name}' (UUID ${entry_uuid}) in ${conf_path}. Choose a unique disk name and physical label."
    fi
  done < "${conf_path}"
}
EOF_GENERATED_USB_ALLOWLIST_HELPERS
}


emit_generated_runtime_lock_helpers() {
  cat <<'EOF_GENERATED_RUNTIME_LOCK_HELPERS'
# Runtime lock helpers are provided by penelope-common.sh. This block is kept so
# generated scripts retain a stable assembly point without shadowing common code.
EOF_GENERATED_RUNTIME_LOCK_HELPERS
}

emit_generated_backup_runner_target_repo_helpers() {
  cat <<'EOF_GENERATED_BACKUP_RUNNER_TARGET_REPO_HELPERS'
all_backup_targets() {
  printf '%s
' "system" "home" "_archive"
}

repo_relpath_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system|home)
      printf '%s
' "${target}"
      ;;
    _archive)
      printf '%s
' "_archive"
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

backup_source_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s
' '/'
      ;;
    home)
      printf '%s
' '/home'
      ;;
    _archive)
      printf '%s
' '/_archive'
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

normalize_absolute_path_for_prefix_check() {
  local path="${1:?path required}"
  [[ "${path}" == /* ]] || die "Path must be absolute for backup source-set safety check: ${path}"
  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done
  printf '%s
' "${path}"
}

path_is_same_or_below() {
  local candidate root
  candidate="$(normalize_absolute_path_for_prefix_check "${1:?candidate path required}")"
  root="$(normalize_absolute_path_for_prefix_check "${2:?root path required}")"

  [[ "${candidate}" == "${root}" ]] && return 0
  if [[ "${root}" == "/" ]]; then
    [[ "${candidate}" == /* ]]
    return $?
  fi
  [[ "${candidate}" == "${root}/"* ]]
}

ensure_backup_repo_not_inside_unprotected_source() {
  local name="${1:?name required}"
  local source="${2:?source required}"
  local repo="${3:?repo required}"
  shift 3

  if ! path_is_same_or_below "${repo}" "${source}"; then
    return 0
  fi

  local arg exclude_path
  for arg in "$@"; do
    case "${arg}" in
      --exclude=/*)
        exclude_path="${arg#--exclude=}"
        if path_is_same_or_below "${repo}" "${exclude_path}"; then
          return 0
        fi
        ;;
    esac
  done

  die "${name}: backup repository path is inside the source tree without a covering absolute --exclude path: repo=${repo} source=${source}"
}

restic_password_file_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s
' '/root/.config/restic/system_pw'
      ;;
    home)
      printf '%s
' '/root/.config/restic/home_pw'
      ;;
    _archive)
      printf '%s
' '/root/.config/restic/_archive_pw'
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

backup_label_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s
' 'SYSTEM'
      ;;
    home)
      printf '%s
' 'HOME'
      ;;
    _archive)
      printf '%s
' 'ARCHIVE'
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

fix_repo_perms() {
  local path="${1:?repo path required}"

  [[ -e "${path}" ]] || return 0

  chown -R root:root "${path}" 2>/dev/null || true
  chmod -R go-rwx "${path}" 2>/dev/null || true
  if [[ -d "${path}" ]]; then
    chmod 700 "${path}" 2>/dev/null || true
  fi
}
EOF_GENERATED_BACKUP_RUNNER_TARGET_REPO_HELPERS
}

emit_generated_backup_runner_recovery_context_constants() {
  cat <<'EOF_GENERATED_BACKUP_RUNNER_RECOVERY_CONTEXT_CONSTANTS'
readonly SAMBA_OPERATOR_CONFIG_DIR="/etc/${PROJECT}/samba-setup"
readonly BACKUP_SETUP_CONFIG_DIR="/etc/${PROJECT}/backup-setup"
EOF_GENERATED_BACKUP_RUNNER_RECOVERY_CONTEXT_CONSTANTS
}

emit_generated_backup_runner_recovery_bundle_helpers() {
  cat <<'EOF_GENERATED_BACKUP_RUNNER_RECOVERY_BUNDLE_HELPERS'
sanitize_backup_setup_copy_for_recovery() {
  local src="${1:?source required}"
  local out="${2:?output required}"

  cat "${src}" > "${out}" || die "Failed to stage non-secret backup setup copy for recovery stage"

  grep -q "^readonly BACKUP_SETUP_SECRETS_DIR=\"\${BACKUP_SETUP_CONFIG_DIR}/secrets.d\"$" "${out}" || \
    die "Sanitized backup setup copy is missing the externalized secrets-dir contract: ${out}"
  if grep -qE '^CRED_INITIAL_RESTIC_(SYSTEM|HOME|ARCHIVE)_PASSWORD=' "${out}"; then
    die "Sanitized backup setup copy still embeds legacy inline restic init secrets: ${out}"
  fi
}

persist_sanitized_recovery_stage() {
  # In the outer setup script this function is sourced from a generated-helper temp file;
  # prefer the real setup-script path so recovery staging does not copy that temp source.
  local src="${BACKUP_SETUP_SCRIPT_SOURCE_PATH:-${BASH_SOURCE[0]:-${0}}}"
  local stage_dir="${PENELOPE_RECOVERY_STAGE_DIR}"
  local tmp="${stage_dir}/penelope-backup-setup.sh.tmp.$$"
  local dest="${stage_dir}/penelope-backup-setup.sh"

  penelope_ensure_recovery_stage_dir "${stage_dir}"
  install -m 0600 /dev/null "${tmp}" || die "Failed to create temporary sanitized backup setup copy: ${tmp}"

  sanitize_backup_setup_copy_for_recovery "${src}" "${tmp}"

  penelope_publish_recovery_stage_file "${tmp}" "${dest}" 0755 || die "Failed to stage sanitized backup setup copy"

  penelope_stage_common_for_recovery "${stage_dir}" "${SCRIPT_DIR}" || die "Failed to stage penelope-common for recovery stage"
}

all_recovery_bundle_entries() {
  cat <<EOF_RECOVERY_BUNDLE_ENTRIES
${PENELOPE_RECOVERY_STAGE_DIR}/penelope-install.sh|penelope-install.sh|optional
${PENELOPE_RECOVERY_STAGE_DIR}/penelope-backup-setup.sh|penelope-backup-setup.sh|required
${PENELOPE_RECOVERY_STAGE_DIR}/penelope-samba-setup.sh|penelope-samba-setup.sh|optional
${PENELOPE_RECOVERY_STAGE_DIR}/penelope-common.sh|penelope-common.sh|required
/usr/local/sbin/penelope-offline-recover.sh|penelope-offline-recover.sh|required
/usr/local/sbin/penelope-backup.sh|penelope-backup.sh|required
/usr/local/sbin/penelope-backup-verify.sh|penelope-backup-verify.sh|optional
/usr/local/sbin/penelope-backup-find-snapshot.sh|penelope-backup-find-snapshot.sh|optional
/usr/local/sbin/penelope-rotate-external-restic-passwords.sh|penelope-rotate-external-restic-passwords.sh|optional
/usr/local/sbin/penelope-usb-disk-setup.sh|penelope-usb-disk-setup.sh|optional
/usr/local/sbin/penelope-refresh-backup-dashboard.sh|penelope-refresh-backup-dashboard.sh|optional
EOF_RECOVERY_BUNDLE_ENTRIES
}

copy_recovery_bundle_file() {
  local src="${1:?source required}"
  local dest="${2:?dest required}"
  local requirement="${3:?requirement required}"

  if [[ ! -f "${src}" ]]; then
    if [[ "${requirement}" == "required" ]]; then
      die "Recovery bundle source missing: ${src}"
    fi
    return 0
  fi

  if [[ "$(basename -- "${dest}")" == *.sh ]]; then
    install -m 0755 -o root -g root "${src}" "${dest}" 2>/dev/null || cp -f "${src}" "${dest}" || die "Failed to stage recovery bundle file: ${src}"
  else
    install -m 0644 -o root -g root "${src}" "${dest}" 2>/dev/null || cp -f "${src}" "${dest}" || die "Failed to stage recovery bundle file: ${src}"
  fi
}

recovery_bundle_assert_non_secret() {
  local dir="${1:?bundle dir required}"
  local label="${2:?label required}"
  local backup_copy="${dir}/penelope-backup-setup.sh"
  local path=""
  local -a forbidden=()

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    forbidden+=("$(basename -- "${path}")")
  done < <(
    find "${dir}" -maxdepth 1 -type f \
      \( -name '*.secret' -o -name 'backup.conf' -o -name 'usb-backup-disks.conf' \
         -o -name 'system_pw' -o -name 'home_pw' -o -name '_archive_pw' \
         -o -name 'system_pw.prev' -o -name 'home_pw.prev' -o -name '_archive_pw.prev' \) \
      -print 2>/dev/null | LC_ALL=C sort
  )

  if (( ${#forbidden[@]} > 0 )); then
    die "${label} unexpectedly contains backup secret-bearing or live-state file(s): ${forbidden[*]}"
  fi

  if [[ -f "${backup_copy}" ]]; then
    validate_shell_script "${backup_copy}"
    grep -q "^readonly BACKUP_SETUP_SECRETS_DIR=\"\${BACKUP_SETUP_CONFIG_DIR}/secrets.d\"$" "${backup_copy}" || \
      die "${label} backup setup copy is missing the externalized secrets-dir contract: ${backup_copy}"
    if grep -qE '^CRED_INITIAL_RESTIC_(SYSTEM|HOME|ARCHIVE)_PASSWORD=' "${backup_copy}"; then
      die "${label} backup setup copy still embeds legacy inline restic init secrets: ${backup_copy}"
    fi
  fi
}

write_recovery_bundle_readme() {
  local bundle_dir="${1:?bundle dir required}"
  local location="${2:?location required}"
  local out="${bundle_dir}/README-RECOVERY.txt"

  cat > "${out}" <<EOF_RECOVERY_README
Penelope recovery bundle
========================

Generated by: /usr/local/sbin/penelope-backup.sh
Bundle version: ${RECOVERY_BUNDLE_VERSION}
Generated at: $(ts)
Target host: ${TARGET_HOST}
Host scope: ${HOST_SCOPE_NAME}
Backup location: ${location}

This directory is synced beside the repositories under:
  _recovery/

It intentionally contains recovery tooling only.
It does NOT contain restic passwords or other secrets.
Fetch effective credentials from KeePass or another external secure vault.

The setup-script copies in this bundle are sanitized:
  - penelope-install.sh
  - penelope-backup-setup.sh
  - penelope-samba-setup.sh (if the Samba setup has been run on this system)

Their credential placeholders are reset to "change-me" when such inline fields still exist.
For backup-setup in the current release, initialization secrets live outside the script in
${BACKUP_SETUP_CONFIG_DIR}/secrets.d and are not copied into _recovery. Retrieve effective values
from KeePass before using them.

Samba restore model (current Penelope design):
  - The canonical live Samba operator config remains ${SAMBA_OPERATOR_CONFIG_DIR}.
  - Restore ${SAMBA_OPERATOR_CONFIG_DIR} from the system backup/repository when present.
  - Treat this _recovery directory as tooling-only; do NOT treat it as the live Samba config location.
  - Generated/runtime Samba output should be regenerated later by penelope-samba-setup apply after a successful verify-config.

Minimal Samba restore runbook:
  1. Restore ${SAMBA_OPERATOR_CONFIG_DIR} from the chosen system snapshot onto the target host.
  2. Copy this _recovery directory to a temporary local workspace (for example Desktop or /tmp).
  3. Use the sanitized penelope-samba-setup.sh copy from that workspace to inspect the restored config first:
       ./penelope-samba-setup.sh --config-dir ${SAMBA_OPERATOR_CONFIG_DIR} list-users
       ./penelope-samba-setup.sh --config-dir ${SAMBA_OPERATOR_CONFIG_DIR} list-shares
  4. Rehydrate ${SAMBA_OPERATOR_CONFIG_DIR}/secrets.d/*.secret with effective values from KeePass.
  5. Run ./penelope-samba-setup.sh --config-dir ${SAMBA_OPERATOR_CONFIG_DIR} verify-config
     from the temporary workspace to validate the restored live config tree first.
  6. Run sudo -E ./penelope-samba-setup.sh --config-dir ${SAMBA_OPERATOR_CONFIG_DIR} apply
     from the temporary workspace to regenerate derived Samba runtime state on the target host.
  7. Do NOT write edited copies with real credentials back into _recovery.

Typical Live-USB usage:
  1. Mount the backup medium.
  2. Change into the matching <HOST_SCOPE_NAME>/_recovery directory.
  3. Copy this entire directory to the Live session (for example Desktop or /tmp).
  4. Edit the sanitized setup copies locally with values from KeePass.
  5. Use the copied tools as needed (for example ./penelope-install.sh or ./penelope-offline-recover.sh).
  6. Do NOT write edited copies with real credentials back into _recovery.
  7. The sibling repositories live next to this directory:
       ../system
       ../home
       ../_archive
EOF_RECOVERY_README

  chmod 0644 "${out}" 2>/dev/null || true
}

write_recovery_bundle_manifest() {
  local bundle_dir="${1:?bundle dir required}"
  local location="${2:?location required}"
  local out="${bundle_dir}/manifest.txt"
  local src name requirement

  {
    printf 'generated_at=%s\n' "$(ts)"
    printf 'bundle_version=%s\n' "${RECOVERY_BUNDLE_VERSION}"
    printf 'target_host=%s\n' "${TARGET_HOST}"
    printf 'host_scope_name=%s\n' "${HOST_SCOPE_NAME}"
    printf 'backup_location=%s\n' "${location}"
    printf 'bundle_dir=%s\n' "${bundle_dir}"
    printf 'canonical_samba_config_dir=%s\n' "${SAMBA_OPERATOR_CONFIG_DIR}"
    printf 'recovery_bundle_contains_live_samba_config=false\n'
    printf 'files:\n'
  } > "${out}"

  while IFS='|' read -r src name requirement; do
    [[ -n "${src}" ]] || continue
    if [[ -f "${bundle_dir}/${name}" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        printf '  %s  %s\n' "$(sha256sum "${bundle_dir}/${name}" | awk '{print $1}')" "${name}" >> "${out}"
      else
        printf '  %s\n' "${name}" >> "${out}"
      fi
    fi
  done < <(all_recovery_bundle_entries)

  chmod 0644 "${out}" 2>/dev/null || true
}

sync_recovery_bundle_to_base() {
  local base="${1:?base required}"
  local location="${2:?location required}"
  local bundle_dir="${base}/_recovery"
  local tmp_dir="${bundle_dir}.tmp.$$"
  local old_dir="${bundle_dir}.old.$$"
  local src name requirement
  local stale_dir=""
  local stale_pid=""

  rm -rf "${tmp_dir}" "${old_dir}"
  install -d -m 0700 -o root -g root "${tmp_dir}" 2>/dev/null || mkdir -p "${tmp_dir}" || die "Failed to create temporary recovery bundle dir: ${tmp_dir}"

  while IFS='|' read -r src name requirement; do
    [[ -n "${src}" ]] || continue
    copy_recovery_bundle_file "${src}" "${tmp_dir}/${name}" "${requirement}"
  done < <(all_recovery_bundle_entries)

  write_recovery_bundle_readme "${tmp_dir}" "${location}"
  write_recovery_bundle_manifest "${tmp_dir}" "${location}"
  recovery_bundle_assert_non_secret "${tmp_dir}" "Recovery bundle staging area ${tmp_dir}"

  if [[ -e "${bundle_dir}" ]]; then
    mv "${bundle_dir}" "${old_dir}" || die "Failed to rotate previous recovery bundle: ${bundle_dir}"
  fi
  if ! mv "${tmp_dir}" "${bundle_dir}"; then
    if [[ -e "${old_dir}" ]]; then
      mv "${old_dir}" "${bundle_dir}" || warn "Could not restore previous recovery bundle after publish failure: ${old_dir} -> ${bundle_dir}"
    fi
    die "Failed to publish recovery bundle at ${bundle_dir}"
  fi
  rm -rf "${old_dir}"

  for stale_dir in "${bundle_dir}.tmp."* "${bundle_dir}.old."*; do
    [[ -e "${stale_dir}" ]] || continue
    [[ "${stale_dir}" == "${tmp_dir}" || "${stale_dir}" == "${old_dir}" ]] && continue
    [[ -d "${stale_dir}" ]] || continue
    stale_pid="${stale_dir##*.}"
    [[ "${stale_pid}" =~ ^[0-9]+$ ]] || continue
    if kill -0 "${stale_pid}" 2>/dev/null; then
      warn "Preserving stale recovery temp from still-live pid ${stale_pid}: ${stale_dir}"
      continue
    fi
    rm -rf -- "${stale_dir}" || warn "Failed to remove stale recovery temp dir: ${stale_dir}"
  done

  log "Recovery bundle synced: ${bundle_dir}"
}
EOF_GENERATED_BACKUP_RUNNER_RECOVERY_BUNDLE_HELPERS
}

# The backup-setup bundle itself also uses a subset of the generated USB/dashboard
# helpers directly during verify/apply. Load those constant helper definitions into
# the current shell once so the outer script and the generated helper scripts share
# the same implementation. Use an explicit temporary source file so
# the generated helper block is syntax-checked before it enters the running shell.
render_generated_backup_setup_helper_source() {
  printf '%s\n' '#!/usr/bin/env bash' || return 1
  emit_generated_backup_conf_context_helpers || return 1
  emit_generated_backup_dashboard_file_helpers || return 1
  emit_generated_usb_allowlist_helpers || return 1
  emit_generated_backup_runner_recovery_bundle_helpers || return 1
}

source_generated_backup_setup_helpers() {
  local tmp=""
  local syntax_output=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/penelope-backup-setup-generated-helpers.XXXXXX")" || die "Failed to allocate temporary generated-helper file"

  if ! ( render_generated_backup_setup_helper_source ) >"${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to render generated backup-setup helper block"
  fi

  if ! syntax_output="$(bash -n "${tmp}" 2>&1)"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Bash syntax error in generated backup-setup helper block ${tmp}: ${syntax_output}"
  fi

  # shellcheck source=/dev/null
  if ! source "${tmp}"; then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to source generated backup-setup helper block: ${tmp}"
  fi

  rm -f -- "${tmp}" 2>/dev/null || true
}

source_generated_backup_setup_helpers

backup_dashboard_seed_message_for_mode() {
  local mode_name="${1:?backup-dashboard mode required}"
  case "${mode_name}" in
    ops)
      printf '%s
' "No backup-related operator event has been recorded yet."
      ;;
    *)
      printf '%s
' "Backup has not run yet."
      ;;
  esac
}

finalize_backup_dashboard_seed_artifact() {
  local path="${1:?path required}"
  local label="${2:?label required}"
  chown root:root "${path}" || die "Failed to chown ${label}: ${path}"
  chmod 0644 "${path}" || die "Failed to chmod ${label}: ${path}"
  ensure_no_unexpanded_tokens "${path}"
}

preserve_or_prepare_backup_dashboard_seed_artifact() {
  local path="${1:?path required}"
  local label="${2:?label required}"
  local kind="${3:?kind required}"

  if [[ -f "${path}" ]]; then
    log "Dashboard ${kind} exists: ${path} (preserved)"
    chown root:root "${path}" || die "Failed to chown ${label}: ${path}"
    chmod 0644 "${path}" || die "Failed to chmod ${label}: ${path}"
    return 1
  fi

  return 0
}

render_backup_dashboard_seed_event_log() {
  local path="${1:?path required}"
  local mode_name="${2:?backup-dashboard mode required}"
  local seed_message="${3:?seed message required}"

  {
    printf '# Penelope backup-dashboard events (%s)\n' "${mode_name}"
    printf '%s\n' '# Fields: timestamp event mode host host_scope_name run_id uuid targets kind cycle_id log_file message'
    printf "timestamp=%s event=not-run-yet mode=%s host=%s host_scope_name=%s " \
      "$(ts)" "${mode_name}" "${TARGET_HOST}" "${HOST_SCOPE_NAME}"
    printf "run_id= uuid= targets=all kind= cycle_id= log_file=%s message='%s'\n" \
      "${BACKUP_LOG}" "${seed_message}"
  } > "${path}"
}

render_backup_dashboard_seed_status_json() {
  local path="${1:?path required}"
  local mode_name="${2:?backup-dashboard mode required}"
  local seed_message="${3:?seed message required}"

  cat > "${path}" <<EOF_DASHBOARD_STATUS_JSON
{
  "status": "not-run-yet",
  "mode": "${mode_name}",
  "host": "${TARGET_HOST}",
  "host_scope_name": "${HOST_SCOPE_NAME}",
  "message": "${seed_message}",
  "log_file": "${BACKUP_LOG}"
}
EOF_DASHBOARD_STATUS_JSON
}

install_backup_dashboard_seed_artifact() {
  local path="${1:?path required}"
  local label="${2:?label required}"
  local mode_name="${3:?backup-dashboard mode required}"
  local kind="${4:?kind required}"
  local render_fn="${5:?render function required}"
  local seed_message=""

  if ! preserve_or_prepare_backup_dashboard_seed_artifact "${path}" "${label}" "${kind}"; then
    return 0
  fi

  seed_message="$(backup_dashboard_seed_message_for_mode "${mode_name}")"
  "${render_fn}" "${path}" "${mode_name}" "${seed_message}"
  finalize_backup_dashboard_seed_artifact "${path}" "${label}"
}

readonly RECOVERY_BUNDLE_VERSION="${VERSION}"
: "${RECOVERY_BUNDLE_VERSION:?recovery bundle version required}"

# Recovery-bundle helpers are generated and sourced above from
# emit_generated_backup_runner_recovery_bundle_helpers(). The backup setup script
# and the installed backup runner intentionally share that single rendered helper
# block so the _recovery README, manifest, and non-secret checks cannot drift.

# -------------------- main config --------------------
readonly ETC_DIR="/etc/${PROJECT}"
readonly BACKUP_CONF="${ETC_DIR}/backup.conf"
readonly USB_CONF="${ETC_DIR}/usb-backup-disks.conf"

# Determine stable backup scope:
# - TARGET_HOST reflects the current installation host (or explicit override).
# - HOST_SCOPE_NAME is the stable backup identity used for logs, repository layout, and restic snapshot hostname metadata.
# - Precedence: backup.conf -> PENELOPE_HOST_SCOPE_NAME -> INITIAL_BACKUP_HOST_SCOPE_NAME -> TARGET_HOST.
TARGET_HOST="${PENELOPE_TARGET_HOST:-$(hostname -s)}"
BOOTSTRAP_INITIAL_HOST_SCOPE_NAME=""
if [[ -f "${BACKUP_SETUP_CONFIG_FILE}" ]]; then
  BOOTSTRAP_INITIAL_HOST_SCOPE_NAME="$(read_kv_value_from_file "${BACKUP_SETUP_CONFIG_FILE}" "HOST_SCOPE_NAME" || true)"
fi
INITIAL_HOST_SCOPE_NAME="${BOOTSTRAP_INITIAL_HOST_SCOPE_NAME:-${INITIAL_BACKUP_HOST_SCOPE_NAME:-${TARGET_HOST}}}"
readonly INITIAL_HOST_SCOPE_NAME
HOST_SCOPE_NAME="${INITIAL_HOST_SCOPE_NAME}"
HOST_SCOPE_SOURCE="default-target-host"
BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR=""
if [[ -n "${INITIAL_BACKUP_HOST_SCOPE_NAME:-}" ]]; then
  HOST_SCOPE_SOURCE="initial-backup-host-scope"
fi
if [[ -n "${BOOTSTRAP_INITIAL_HOST_SCOPE_NAME:-}" ]]; then
  HOST_SCOPE_SOURCE="bootstrap-config"
fi
if [[ -n "${PENELOPE_HOST_SCOPE_NAME:-}" ]]; then
  HOST_SCOPE_NAME="${PENELOPE_HOST_SCOPE_NAME}"
  HOST_SCOPE_SOURCE="env"
fi
if [[ -f "${BACKUP_CONF}" ]]; then
  host_scope_value=""
  host_scope_value="$(read_kv_value_from_file "${BACKUP_CONF}" "HOST_SCOPE_NAME" || true)"
  if [[ -z "${host_scope_value}" ]]; then
    BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR="Missing HOST_SCOPE_NAME in ${BACKUP_CONF}."
  elif [[ "${host_scope_value}" == *"___PENELOPE_"* ]]; then
    BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR="HOST_SCOPE_NAME in ${BACKUP_CONF} still contains placeholder markers."
  else
    HOST_SCOPE_NAME="${host_scope_value}"
    HOST_SCOPE_SOURCE="backup.conf"
  fi
fi
validate_host_scope_name "${HOST_SCOPE_NAME}" "${HOST_SCOPE_SOURCE}"
readonly TARGET_HOST
readonly HOST_SCOPE_NAME
readonly HOST_SCOPE_SOURCE
readonly BACKUP_CONF_HOST_SCOPE_PRECHECK_ERROR

readonly VARLIB_DIR="/var/lib/${PROJECT}/backup"
readonly LOG_DIR="/var/log/${HOST_SCOPE_NAME}/backup"
readonly BACKUP_LOG="${LOG_DIR}/backup.log"
readonly BACKUP_RUNTIME_RUN_DIR="/run/${PROJECT}"
readonly BACKUP_RUN_LOCK_DIR="${BACKUP_RUNTIME_RUN_DIR}/backup-run.lock.d"
readonly CRON_FILE="/etc/cron.d/${PROJECT}-backup"
readonly LOGROTATE_FILE="/etc/logrotate.d/${PROJECT}-backup"
PLACEHOLDER_HOST_SCOPE_NAME=""
PLACEHOLDER_CRON_HOUR=""
PLACEHOLDER_CRON_MINUTE=""
PLACEHOLDER_BACKUP_DASHBOARD_DIR=""

# Internal repositories
readonly INTERNAL_REPO_BASE="/_backup/${HOST_SCOPE_NAME}"
readonly INTERNAL_REPO_SYSTEM="${INTERNAL_REPO_BASE}/system"
readonly INTERNAL_REPO_HOME="${INTERNAL_REPO_BASE}/home"
readonly INTERNAL_REPO_ARCHIVE="${INTERNAL_REPO_BASE}/_archive"

# Restic password files
readonly RESTIC_CONFIG_DIR="/root/.config/restic"
readonly RESTIC_PW_SYSTEM="${RESTIC_CONFIG_DIR}/system_pw"
readonly RESTIC_PW_HOME="${RESTIC_CONFIG_DIR}/home_pw"
readonly RESTIC_PW_ARCHIVE="${RESTIC_CONFIG_DIR}/_archive_pw"

all_backup_targets() {
  printf '%s\n' "system" "home" "_archive"
}

repo_relpath_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system|home)
      printf '%s\n' "${target}"
      ;;
    _archive)
      printf '%s\n' "_archive"
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

backup_source_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s\n' '/'
      ;;
    home)
      printf '%s\n' '/home'
      ;;
    _archive)
      printf '%s\n' '/_archive'
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

normalize_absolute_path_for_prefix_check() {
  local path="${1:?path required}"
  [[ "${path}" == /* ]] || die "Path must be absolute for backup source-set safety check: ${path}"
  while [[ "${path}" != "/" && "${path}" == */ ]]; do
    path="${path%/}"
  done
  printf '%s\n' "${path}"
}

path_is_same_or_below() {
  local candidate root
  candidate="$(normalize_absolute_path_for_prefix_check "${1:?candidate path required}")"
  root="$(normalize_absolute_path_for_prefix_check "${2:?root path required}")"

  [[ "${candidate}" == "${root}" ]] && return 0
  if [[ "${root}" == "/" ]]; then
    [[ "${candidate}" == /* ]]
    return $?
  fi
  [[ "${candidate}" == "${root}/"* ]]
}

ensure_backup_repo_not_inside_unprotected_source() {
  local name="${1:?name required}"
  local source="${2:?source required}"
  local repo="${3:?repo required}"
  shift 3

  if ! path_is_same_or_below "${repo}" "${source}"; then
    return 0
  fi

  local arg exclude_path
  for arg in "$@"; do
    case "${arg}" in
      --exclude=/*)
        exclude_path="${arg#--exclude=}"
        if path_is_same_or_below "${repo}" "${exclude_path}"; then
          return 0
        fi
        ;;
    esac
  done

  die "${name}: backup repository path is inside the source tree without a covering absolute --exclude path: repo=${repo} source=${source}"
}

restic_password_file_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s\n' "${RESTIC_PW_SYSTEM}"
      ;;
    home)
      printf '%s\n' "${RESTIC_PW_HOME}"
      ;;
    _archive)
      printf '%s\n' "${RESTIC_PW_ARCHIVE}"
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}

backup_label_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      printf '%s\n' 'SYSTEM'
      ;;
    home)
      printf '%s\n' 'HOME'
      ;;
    _archive)
      printf '%s\n' 'ARCHIVE'
      ;;
    *)
      die "Unknown backup target: ${target}"
      ;;
  esac
}


# -------------------- repo init + perms --------------------
fix_repo_perms() {
  local path="${1:?repo path required}"

  [[ -e "${path}" ]] || return 0

  # Best effort: on POSIX filesystems enforce root:root and remove group/world access.
  chown -R root:root "${path}" 2>/dev/null || true
  chmod -R go-rwx "${path}" 2>/dev/null || true

  # Ensure the repository root itself is not left more permissive than 0700.
  if [[ -d "${path}" ]]; then
    chmod 700 "${path}" 2>/dev/null || true
  fi
}

verify_existing_repo_password_or_die() {
  local repo_path="${1:?repo path required}"
  local pw_file="${2:?pw file required}"
  local message=""

  [[ -f "${repo_path}/config" ]] || return 0
  if [[ ! -s "${pw_file}" ]]; then
    die "Existing restic repo ${repo_path} requires a non-empty password file at ${pw_file}. Restore the correct password file first and rerun with --keep-secrets."
  fi

  export RESTIC_REPOSITORY="${repo_path}"
  export RESTIC_PASSWORD_FILE="${pw_file}"
  if ! restic snapshots --json >/dev/null 2>&1; then
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    message="Existing restic repo ${repo_path} is not readable with ${pw_file}."
    message+=" Restore the matching password file"
    message+=" (for example from KeePass or preserved credential material)"
    message+=" and rerun with --keep-secrets."
    die "${message}"
  fi
  unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

restic_check_repo_no_lock() {
  local repo_path="${1:?repo path required}"
  local pw_file="${2:?pw file required}"
  local label="${3:-repo}"
  local severity="${4:-warn}"
  local context="${5:-restic integrity check}"

  export RESTIC_REPOSITORY="${repo_path}"
  export RESTIC_PASSWORD_FILE="${pw_file}"
  if ! restic check --no-lock >/dev/null 2>&1; then
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    if [[ "${severity}" == "die" ]]; then
      die "${context} failed for ${label} restic repository: ${repo_path}"
    fi
    warn "${context} failed for ${label} restic repository: ${repo_path}"
    return 1
  fi
  unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

# pid_dir_lock_is_active_runtime is provided by penelope-common.sh.

active_backup_runner_pids() {
  local proc=""
  local pid=""
  local cmdline=""

  for proc in /proc/[0-9]*; do
    [[ -r "${proc}/cmdline" ]] || continue
    pid="${proc##*/}"
    [[ "${pid}" == "$$" ]] && continue
    cmdline="$(tr '\0' ' ' < "${proc}/cmdline" 2>/dev/null || true)"
    [[ -n "${cmdline}" ]] || continue
    [[ "${cmdline}" == *'/usr/local/sbin/penelope-backup.sh'* ]] || continue
    printf '%s\n' "${pid}"
  done
}

guard_no_active_backup_runner() {
  local lock_dir="${BACKUP_RUN_LOCK_DIR}"
  local pids=""

  if pid_dir_lock_is_active_runtime "${lock_dir}" "penelope-backup runner"; then
    local lock_pid=""
    lock_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
    if [[ -n "${lock_pid}" && "${lock_pid}" != "$$" ]]; then
      die "Active penelope-backup runner detected (lock ${lock_dir}, pid ${lock_pid}). Refusing to rewrite backup runtime artifacts during an active backup run."
    fi
    die "Active penelope-backup runner detected (lock ${lock_dir}). Refusing to rewrite backup runtime artifacts during an active backup run."
  fi

  pids="$(active_backup_runner_pids | paste -sd, -)"
  if [[ -n "${pids}" ]]; then
    die "Active penelope-backup runner detected (pid(s): ${pids}). Refusing to rewrite backup runtime artifacts during an active backup run."
  fi
}

BACKUP_RUNTIME_UPDATE_LOCK_HELD="0"

acquire_backup_runtime_update_lock() {
  acquire_pid_dir_lock "${BACKUP_RUN_LOCK_DIR}" "backup run"
  BACKUP_RUNTIME_UPDATE_LOCK_HELD="1"
}

release_backup_runtime_update_lock() {
  local rc=0
  if [[ "${BACKUP_RUNTIME_UPDATE_LOCK_HELD:-0}" != "1" ]]; then
    BACKUP_RUNTIME_UPDATE_LOCK_HELD="0"
    return 0
  fi

  if ! release_pid_dir_lock "${BACKUP_RUN_LOCK_DIR}"; then
    warn "Failed to release backup runtime-update lock: ${BACKUP_RUN_LOCK_DIR}"
    rc=1
  fi
  BACKUP_RUNTIME_UPDATE_LOCK_HELD="0"
  return "${rc}"
}

backup_setup_on_err() {
  local line="${1:-?}"
  local cmd="${2:-<unknown>}"
  local ec="${3:-1}"
  penelope_log_trap_error "${ec}" "${line}" "${cmd}" 400 "(heredoc omitted)"
  exit "${ec}"
}

backup_setup_on_signal() {
  local sig="${1:?signal required}"
  local ec=""
  ec="$(penelope_signal_exit_code_for_name "${sig}")"
  warn "Received ${sig}; aborting penelope-backup-setup."
  exit "${ec}"
}

current_internal_scope_has_any_repo() {
  local repo_path=""
  for repo_path in "${INTERNAL_REPO_SYSTEM}" "${INTERNAL_REPO_HOME}" "${INTERNAL_REPO_ARCHIVE}"; do
    [[ -f "${repo_path}/config" ]] && return 0
  done
  return 1
}

internal_scope_contains_restic_repo() {
  local path="${1:?path required}"
  [[ -f "${path}/config" ]] || return 1
  [[ -d "${path}/data" ]] || return 1
  [[ -d "${path}/index" ]] || return 1
  [[ -d "${path}/snapshots" ]] || return 1
  [[ -d "${path}/keys" ]] || return 1
  return 0
}

list_existing_internal_repo_scopes() {
  local scope_dir scope_name found repo_name
  [[ -d "/_backup" ]] || return 0

  while IFS= read -r -d '' scope_dir; do
    found="0"
    for repo_name in system home _archive; do
      if internal_scope_contains_restic_repo "${scope_dir}/${repo_name}"; then
        found="1"
        break
      fi
    done
    if [[ "${found}" == "1" ]]; then
      scope_name="$(basename "${scope_dir}")"
      printf '%s
' "${scope_name}"
    fi
  done < <(find "/_backup" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

evaluate_preserved_internal_repo_bootstrap_guard() {
  local context="${1:?context required}"
  local emit_ok_log="${2:-0}"
  local scopes=()
  local joined=""
  local scope=""
  local message=""

  mountpoint -q "/_backup" 2>/dev/null || return 0

  mapfile -t scopes < <(list_existing_internal_repo_scopes | sort -u)
  if (( ${#scopes[@]} == 0 )); then
    if [[ "${emit_ok_log}" == "1" ]]; then
      log "${context}: mounted /_backup contains no existing internal Penelope repo scopes."
      log "${context}: apply would initialize or validate HOST_SCOPE_NAME=${HOST_SCOPE_NAME} using the current live/bootstrap state."
    fi
    return 0
  fi

  joined="$(printf '%s ' "${scopes[@]}")"
  joined="${joined% }"

  if [[ "${HOST_SCOPE_SOURCE}" == "default-target-host" ]]; then
    message="Mounted /_backup already contains internal Penelope repo scope(s): ${joined}. "
    message+="Refusing blind bootstrap with default HOST_SCOPE_NAME=${HOST_SCOPE_NAME}. "
    message+="Restore /etc/penelope/backup.conf and matching restic password files first, "
    message+="or rerun with PENELOPE_HOST_SCOPE_NAME set to a detected existing scope "
    message+="after confirming the intended scope."
    die "${message}"
  fi

  for scope in "${scopes[@]}"; do
    if [[ "${scope}" == "${HOST_SCOPE_NAME}" ]]; then
      if [[ "${emit_ok_log}" == "1" ]]; then
        log "${context}: mounted /_backup already contains internal Penelope repo scope(s): ${joined}."
        log "${context}: apply path=reattach/update existing scope HOST_SCOPE_NAME=${HOST_SCOPE_NAME} (source=${HOST_SCOPE_SOURCE})."
      fi
      return 0
    fi
  done

  message="Mounted /_backup already contains internal Penelope repo scope(s): ${joined}. "
  message+="Refusing to initialize a new internal scope HOST_SCOPE_NAME=${HOST_SCOPE_NAME} "
  message+="(source=${HOST_SCOPE_SOURCE}) on a non-empty preserved backup partition. "
  message+="Restore the correct /etc/penelope/backup.conf or rerun with "
  message+="PENELOPE_HOST_SCOPE_NAME set to a detected existing scope after confirming "
  message+="the matching restic password files. If you intentionally want a fresh internal scope, "
  message+="use an empty /_backup instead of mixing new repos with preserved ones."
  die "${message}"
}

guard_preserved_internal_repo_bootstrap() {
  evaluate_preserved_internal_repo_bootstrap_guard "apply" "0"
}

verify_preserved_internal_repo_bootstrap_plan() {
  evaluate_preserved_internal_repo_bootstrap_guard "verify-config" "1"
}

init_repo() {
  local repo_path="${1:?repo path required}"
  local pw_file="${2:?pw file required}"

  mkdir -p "${repo_path}"

  export RESTIC_REPOSITORY="${repo_path}"
  export RESTIC_PASSWORD_FILE="${pw_file}"

  if [[ -f "${repo_path}/config" ]]; then
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    verify_existing_repo_password_or_die "${repo_path}" "${pw_file}"
    restic_check_repo_no_lock "${repo_path}" "${pw_file}" "existing" "warn" "Existing repo integrity check"
    log "Restic repo exists and password check succeeded: ${repo_path}"
  else
    log "Initializing restic repo: ${repo_path}"
    restic init
    unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
  fi

  fix_repo_perms "${repo_path}"
}

# -------------------- write config templates --------------------
backup_file() {
  local file="${1:?file required}"
  local stamp
  stamp="$(date +'%Y%m%d-%H%M%S')"
  cp -a "${file}" "${file}.bak.${stamp}"
}

fix_backup_conf_perms() {
  [[ -f "${BACKUP_CONF}" ]] || return 0
  chown root:root "${BACKUP_CONF}" 2>/dev/null || true
  chmod 600 "${BACKUP_CONF}" 2>/dev/null || true
}

render_backup_conf_to_path() {
  local dest="${1:?destination path required}"
  local label="${2:-backup.conf}"

  (
    umask 077
    backup_conf_template > "${dest}"
  ) || die "Failed to render ${label}: ${dest}"

  apply_placeholders "${dest}"
  stamp_setup_version "${dest}" "${label}"
  ensure_no_unexpanded_tokens "${dest}"
}

render_backup_conf() {
  render_backup_conf_to_path "${BACKUP_CONF}" "backup.conf"
  fix_backup_conf_perms
}

backup_conf_template() {
  # Quoted heredoc: no shell expansion in template content.
  cat <<'EOF_BACKUP_CONF_TEMPLATE'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
# Penelope backup configuration (root-only)
#
# Notes:
# - This file is read by /usr/local/sbin/penelope-backup.sh.
# - Operator rule on a running system: after changing live backup.conf keys that affect
#   installed backup behavior or rendered artifacts, rerun penelope-backup-setup via
#     sudo -E ./penelope-backup-setup-<version>.sh verify-config
#     sudo -E ./penelope-backup-setup-<version>.sh apply
# - Typical examples: CRON_HOUR/CRON_MINUTE (rewrites /etc/cron.d/penelope-backup),
#   BACKUP_DASHBOARD_DIR (runner/helper/runtime paths), and other live backup.conf keys
#   that change installed runtime behavior.
# - Example: to move the daily internal backup from its default to 20:00, set
#     CRON_HOUR="20"
#     CRON_MINUTE="0"
#   in /etc/penelope/backup.conf, then rerun verify-config and apply.
# - Cron output stays intentionally concise, but it may include small status suffixes
#   such as dashboard-publish-incomplete or cleanup-incomplete in addition to
#   STARTED / SUCCESS / FAILED. Detailed logs go to
#   /var/log/<HOST_SCOPE_NAME>/backup/backup.log and verify.log.
#
# Daily schedule (no catch-up):
CRON_HOUR="___PENELOPE_DEFAULT_CRON_HOUR___"
CRON_MINUTE="___PENELOPE_DEFAULT_CRON_MINUTE___"

# Stable host scope name (used for host-scoped log paths, external repository subdirectories, and restic snapshot hostname metadata).
# Initialized by backup-setup; keep stable even if you rename the system hostname.
HOST_SCOPE_NAME="___PENELOPE_INITIAL_HOST_SCOPE_NAME___"

# Backup-Dashboard (canonical readonly status files for operators/clients).
# The runner/helper write status files:
# - last-internal.json
# - last-external-<disk>.json
# - INTERNAL_BACKUP_RUNNING.txt
# - INTERNAL_BACKUP_OK.txt
# - INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt
# - INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt
# - USB_BACKUP_RUNNING_DO_NOT_REMOVE_<disk>.txt (per allow-listed USB backup disk while the external backup is in progress)
# - USB_BACKUP_READY_TO_REMOVE_<disk>.txt (per allow-listed USB backup disk when the run finished successfully and is safe to remove)
# - USB_BACKUP_REATTACH_AND_WAIT_<disk>.txt (per allow-listed USB backup disk when the same disk should be reattached and then left attached for the next retry)
# - USB_BACKUP_DO_NOT_REMOVE_<disk>_CONTACT_OPERATOR.txt (per allow-listed USB backup disk when operator attention is required)
BACKUP_DASHBOARD_DIR="___PENELOPE_DEFAULT_BACKUP_DASHBOARD_DIR___"

# Mark the internal Backup-Dashboard state as stale when no successful internal backup has
# been seen within this many hours. Dashboard-only communication model: clients see
# the status file and contact the operator; no mail is sent automatically.
INTERNAL_BACKUP_STALE_AFTER_HOURS="48"

# Auto-run external backups on post-boot USB insert (udev/systemd). 1=enabled, 0=disabled
ENABLE_USB_AUTORUN="1"

# Write a success marker file to the USB root after a successful external run.
# Example: PENELOPE_BACKUP_OK_YYYYMMDD-HHMMSS.txt
WRITE_USB_SUCCESS_MARKER="1"


# Semantic cadence:
#  - Default full-marker weekdays: Monday and Thursday. Normal daily runs after the first
#    successful full marker in the current weekday cycle are tagged incr.
#  - A cycle is identified by the date of the most recent configured full-marker weekday
#    (YYYYMMDD). The full/incr marker is a Penelope retention-cycle tag; Restic still
#    stores deduplicating snapshots.
FULL_BACKUP_WEEKDAYS_INTERNAL="mon,thu"
FULL_BACKUP_WEEKDAYS_EXTERNAL="mon,thu"

# Retention in full-cycles (whole cycles are deleted together).
KEEP_CYCLES_INTERNAL="2"
KEEP_CYCLES_EXTERNAL="2"

# Restic prune is executed when retention runs.
# Set to 0 if you want to prune manually.
ENABLE_PRUNE="1"

# Optional: keep a small number of untagged/manual snapshots.
# 0 disables management of untagged snapshots.
KEEP_UNTAGGED_LAST="0"

# USB mount base (external backups mount under <base>/<UUID>)
USB_MOUNT_BASE="/_usbbackup"

# When mounting non-POSIX filesystems (exfat/ntfs), apply restrictive umask for privacy.
USB_FS_UMASK="077"

# If set to 1, the runner should enforce a controlled mount/unmount policy for allow-listed USB disks
# (mount under USB_MOUNT_BASE, unmount at the end for safe removal). Some runner versions may treat this
# as advisory; keep it enabled for the intended server-operator workflow.
# 0 = do not enforce controlled mount/unmount (use existing mounts, do not unmount).
FORCE_UNMOUNT_EXTERNAL="1"

# External on-disk lock heartbeat interval (seconds). The runner refreshes the on-disk USB lock on this cadence.
USB_LOCK_HEARTBEAT_INTERVAL_SECONDS="180"

# External on-disk lock TTL (seconds). Keep this close to the heartbeat cadence so stale-lock detection converges
# quickly after crash/reboot/heartbeat failure. Default: 600s (~3x the 180s heartbeat interval plus slack).
USB_LOCK_TTL_SECONDS="600"
EOF_BACKUP_CONF_TEMPLATE
}

backup_conf_default_line() {
  local key="${1:?key required}"
  case "${key}" in
    CRON_HOUR) echo "CRON_HOUR=\"${DEFAULT_CRON_HOUR}\"" ;;
    CRON_MINUTE) echo "CRON_MINUTE=\"${DEFAULT_CRON_MINUTE}\"" ;;
    HOST_SCOPE_NAME) echo "HOST_SCOPE_NAME=\"${HOST_SCOPE_NAME}\"" ;;
    BACKUP_DASHBOARD_DIR) echo "BACKUP_DASHBOARD_DIR=\"${DEFAULT_BACKUP_DASHBOARD_DIR}\"" ;;
    INTERNAL_BACKUP_STALE_AFTER_HOURS) echo 'INTERNAL_BACKUP_STALE_AFTER_HOURS="48"' ;;
    ENABLE_USB_AUTORUN) echo 'ENABLE_USB_AUTORUN="1"' ;;
    WRITE_USB_SUCCESS_MARKER) echo 'WRITE_USB_SUCCESS_MARKER="1"' ;;
    FULL_BACKUP_WEEKDAYS_INTERNAL) echo 'FULL_BACKUP_WEEKDAYS_INTERNAL="mon,thu"' ;;
    FULL_BACKUP_WEEKDAYS_EXTERNAL) echo 'FULL_BACKUP_WEEKDAYS_EXTERNAL="mon,thu"' ;;
    KEEP_CYCLES_INTERNAL) echo 'KEEP_CYCLES_INTERNAL="2"' ;;
    KEEP_CYCLES_EXTERNAL) echo 'KEEP_CYCLES_EXTERNAL="2"' ;;
    ENABLE_PRUNE) echo 'ENABLE_PRUNE="1"' ;;
    KEEP_UNTAGGED_LAST) echo 'KEEP_UNTAGGED_LAST="0"' ;;
    USB_MOUNT_BASE) echo 'USB_MOUNT_BASE="/_usbbackup"' ;;
    USB_FS_UMASK) echo 'USB_FS_UMASK="077"' ;;
    FORCE_UNMOUNT_EXTERNAL) echo 'FORCE_UNMOUNT_EXTERNAL="1"' ;;
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS) echo 'USB_LOCK_HEARTBEAT_INTERVAL_SECONDS="180"' ;;
    USB_LOCK_TTL_SECONDS) echo 'USB_LOCK_TTL_SECONDS="600"' ;;
    *)
      die "Internal error: unknown config key default: ${key}"
      ;;
  esac
}

merge_backup_conf_defaults() {
  local -a keys=(
    CRON_HOUR
    CRON_MINUTE
    HOST_SCOPE_NAME
    BACKUP_DASHBOARD_DIR
    INTERNAL_BACKUP_STALE_AFTER_HOURS
    ENABLE_USB_AUTORUN
    WRITE_USB_SUCCESS_MARKER
    FULL_BACKUP_WEEKDAYS_INTERNAL
    FULL_BACKUP_WEEKDAYS_EXTERNAL
    KEEP_CYCLES_INTERNAL
    KEEP_CYCLES_EXTERNAL
    ENABLE_PRUNE
    KEEP_UNTAGGED_LAST
    USB_MOUNT_BASE
    USB_FS_UMASK
    FORCE_UNMOUNT_EXTERNAL
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS
    USB_LOCK_TTL_SECONDS
  )
  local -a missing=()
  local added_at key

  [[ -f "${BACKUP_CONF}" ]] || die "Missing config for merge: ${BACKUP_CONF}"

  fix_backup_conf_perms

  for key in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}=" "${BACKUP_CONF}"; then
      missing+=("${key}")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log "Config exists: ${BACKUP_CONF} (no missing keys)"
    return 0
  fi

  added_at="$(date +'%Y-%m-%d %H:%M:%S')"
  log "Config exists: ${BACKUP_CONF} (adding missing keys: ${missing[*]})"
  {
    echo
    echo "# --- Added by penelope-backup-setup ${VERSION} on ${added_at} ---"
    for key in "${missing[@]}"; do
      backup_conf_default_line "${key}"
    done
  } >> "${BACKUP_CONF}"

  fix_backup_conf_perms
  ensure_no_unexpanded_tokens "${BACKUP_CONF}"
}

count_missing_backup_conf_defaults() {
  local conf_path="${1:?config path required}"
  local -a keys=(
    CRON_HOUR
    CRON_MINUTE
    HOST_SCOPE_NAME
    BACKUP_DASHBOARD_DIR
    INTERNAL_BACKUP_STALE_AFTER_HOURS
    ENABLE_USB_AUTORUN
    WRITE_USB_SUCCESS_MARKER
    FULL_BACKUP_WEEKDAYS_INTERNAL
    FULL_BACKUP_WEEKDAYS_EXTERNAL
    KEEP_CYCLES_INTERNAL
    KEEP_CYCLES_EXTERNAL
    ENABLE_PRUNE
    KEEP_UNTAGGED_LAST
    USB_MOUNT_BASE
    USB_FS_UMASK
    FORCE_UNMOUNT_EXTERNAL
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS
    USB_LOCK_TTL_SECONDS
  )
  local count=0
  local key

  [[ -f "${conf_path}" ]] || die "Missing config for missing-key count: ${conf_path}"
  for key in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}=" "${conf_path}"; then
      count=$((count + 1))
    fi
  done
  printf '%s
' "${count}"
}


backup_conf_current_keys() {
  printf '%s
' \
    CRON_HOUR \
    CRON_MINUTE \
    HOST_SCOPE_NAME \
    BACKUP_DASHBOARD_DIR \
    INTERNAL_BACKUP_STALE_AFTER_HOURS \
    ENABLE_USB_AUTORUN \
    WRITE_USB_SUCCESS_MARKER \
    FULL_BACKUP_WEEKDAYS_INTERNAL \
    FULL_BACKUP_WEEKDAYS_EXTERNAL \
    KEEP_CYCLES_INTERNAL \
    KEEP_CYCLES_EXTERNAL \
    ENABLE_PRUNE \
    KEEP_UNTAGGED_LAST \
    USB_MOUNT_BASE \
    USB_FS_UMASK \
    FORCE_UNMOUNT_EXTERNAL \
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS \
    USB_LOCK_TTL_SECONDS
}

backup_conf_obsolete_current_keys() {
  printf '%s
' \
    CYCLE_LEN_DAYS_INTERNAL \
    CYCLE_LEN_DAYS_EXTERNAL \
    CYCLE_ANCHOR_DATE_INTERNAL \
    CYCLE_ANCHOR_DATE_EXTERNAL
}

validate_backup_conf_has_no_obsolete_current_keys() {
  local conf_path="${1:?config path required}"
  local key=""
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${conf_path}"; then
      die "Obsolete backup.conf key ${key} is not part of the current Penelope backup contract: ${conf_path}"
    fi
  done < <(backup_conf_obsolete_current_keys)
}

rewrite_backup_conf_current_only() {
  local conf_path="${1:?config path required}"
  local tmp=""
  local conf_dir=""
  local old_host_scope=""
  local old_cron_hour=""
  local old_cron_minute=""
  local old_dashboard=""

  [[ -f "${conf_path}" ]] || die "Missing config for current-only rewrite: ${conf_path}"
  conf_dir="$(dirname "${conf_path}")"
  tmp="$(mktemp "${conf_dir}/backup.conf.current.XXXXXX")" || die "Failed to create current backup.conf temp file in ${conf_dir}"

  old_host_scope="$(read_kv_value_from_file "${conf_path}" "HOST_SCOPE_NAME" || true)"
  old_cron_hour="$(read_kv_value_from_file "${conf_path}" "CRON_HOUR" || true)"
  old_cron_minute="$(read_kv_value_from_file "${conf_path}" "CRON_MINUTE" || true)"
  old_dashboard="$(read_kv_value_from_file "${conf_path}" "BACKUP_DASHBOARD_DIR" || true)"

  PLACEHOLDER_HOST_SCOPE_NAME="${old_host_scope:-${HOST_SCOPE_NAME}}"
  PLACEHOLDER_CRON_HOUR="${old_cron_hour:-${DEFAULT_CRON_HOUR}}"
  PLACEHOLDER_CRON_MINUTE="${old_cron_minute:-${DEFAULT_CRON_MINUTE}}"
  PLACEHOLDER_BACKUP_DASHBOARD_DIR="${old_dashboard:-${DEFAULT_BACKUP_DASHBOARD_DIR}}"

  if ! ( render_backup_conf_to_path "${tmp}" "backup.conf current-only rewrite candidate" ); then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to render current-only backup.conf candidate: ${tmp}"
  fi

  if ! python3 - "${conf_path}" "${tmp}" <<'PY_REWRITE_BACKUP_CONF_CURRENT_ONLY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
current_keys = [
    'CRON_HOUR',
    'CRON_MINUTE',
    'HOST_SCOPE_NAME',
    'BACKUP_DASHBOARD_DIR',
    'INTERNAL_BACKUP_STALE_AFTER_HOURS',
    'ENABLE_USB_AUTORUN',
    'WRITE_USB_SUCCESS_MARKER',
    'FULL_BACKUP_WEEKDAYS_INTERNAL',
    'FULL_BACKUP_WEEKDAYS_EXTERNAL',
    'KEEP_CYCLES_INTERNAL',
    'KEEP_CYCLES_EXTERNAL',
    'ENABLE_PRUNE',
    'KEEP_UNTAGGED_LAST',
    'USB_MOUNT_BASE',
    'USB_FS_UMASK',
    'FORCE_UNMOUNT_EXTERNAL',
    'USB_LOCK_HEARTBEAT_INTERVAL_SECONDS',
    'USB_LOCK_TTL_SECONDS',
]

raw_values = {}
for line in source.read_text(encoding='utf-8').splitlines():
    m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line)
    if not m:
        continue
    key, rhs = m.group(1), m.group(2)
    if key in current_keys and key not in raw_values:
        raw_values[key] = rhs.strip()

lines = dest.read_text(encoding='utf-8').splitlines()
seen = set()
for idx, line in enumerate(lines):
    m = re.match(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=)(.*)$', line)
    if not m:
        continue
    key = m.group(2)
    if key in raw_values:
        lines[idx] = f'{key}={raw_values[key]}'
        seen.add(key)

missing = [key for key in raw_values if key not in seen]
if missing:
    lines.append('')
    lines.append('# --- Preserved current values from previous backup.conf ---')
    for key in missing:
        lines.append(f'{key}={raw_values[key]}')

dest.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY_REWRITE_BACKUP_CONF_CURRENT_ONLY
  then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to preserve current values in backup.conf candidate: ${tmp}"
  fi

  if ! ( validate_backup_conf_candidate_for_verify "${tmp}" ); then
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Current-only backup.conf candidate failed validation: ${tmp}"
  fi
  if cmp -s "${tmp}" "${conf_path}"; then
    rm -f -- "${tmp}"
    log "Config exists: ${conf_path} (already current-only)"
    fix_backup_conf_perms
    return 0
  fi

  mv -f -- "${tmp}" "${conf_path}"
  fix_backup_conf_perms
  log "Config normalized to current-only backup.conf contract: ${conf_path}"
}

backup_conf_candidate_with_current_defaults() {
  local source_conf="${1:?source backup.conf required}"
  local candidate="${2:?candidate backup.conf path required}"

  cp -a "${source_conf}" "${candidate}" || die "Failed to copy backup.conf candidate from ${source_conf} to ${candidate}"
  local -a keys=(
    CRON_HOUR
    CRON_MINUTE
    HOST_SCOPE_NAME
    BACKUP_DASHBOARD_DIR
    INTERNAL_BACKUP_STALE_AFTER_HOURS
    ENABLE_USB_AUTORUN
    WRITE_USB_SUCCESS_MARKER
    FULL_BACKUP_WEEKDAYS_INTERNAL
    FULL_BACKUP_WEEKDAYS_EXTERNAL
    KEEP_CYCLES_INTERNAL
    KEEP_CYCLES_EXTERNAL
    ENABLE_PRUNE
    KEEP_UNTAGGED_LAST
    USB_MOUNT_BASE
    USB_FS_UMASK
    FORCE_UNMOUNT_EXTERNAL
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS
    USB_LOCK_TTL_SECONDS
  )
  local -a missing=()
  local key

  for key in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}=" "${candidate}"; then
      missing+=("${key}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    {
      echo
      echo "# --- Current defaults added for verify-config candidate by penelope-backup-setup ${VERSION} ---"
      for key in "${missing[@]}"; do
        backup_conf_default_line "${key}"
      done
    } >> "${candidate}"
  fi
  rewrite_backup_conf_current_only "${candidate}"
}

validate_backup_conf_candidate_for_verify() {
  local conf_path="${1:?config path required}"
  bash -n "${conf_path}" >/dev/null 2>&1 || die "Shell syntax check failed for backup.conf candidate: ${conf_path}"
  ensure_no_unexpanded_tokens "${conf_path}"
  validate_backup_conf_has_no_obsolete_current_keys "${conf_path}"
  validate_backup_conf_schedule_runtime "${conf_path}"
  validate_backup_conf_runtime_controls_runtime "${conf_path}"
  validate_backup_conf_policy_controls_runtime "${conf_path}"
}

validate_existing_backup_conf_for_verify() {
  local conf_path="${1:?config path required}"
  [[ -f "${conf_path}" ]] || die "Missing live backup config: ${conf_path}"
  [[ -s "${conf_path}" ]] || die "Empty live backup config: ${conf_path}"
  ensure_no_unexpanded_tokens "${conf_path}"
  validate_backup_conf_has_no_obsolete_current_keys "${conf_path}"
  bash -n "${conf_path}" >/dev/null 2>&1 || die "Shell syntax check failed for ${conf_path}"
}

validate_backup_conf_schedule_runtime() {
  local conf_path="${1:?config path required}"
  local cron_hour=""
  local cron_minute=""

  cron_hour="$(read_kv_value_from_file "${conf_path}" "CRON_HOUR" || true)"
  [[ -n "${cron_hour}" ]] || die "Missing CRON_HOUR in ${conf_path}."
  cron_minute="$(read_kv_value_from_file "${conf_path}" "CRON_MINUTE" || true)"
  [[ -n "${cron_minute}" ]] || die "Missing CRON_MINUTE in ${conf_path}."

  [[ "${cron_hour}" =~ ^[0-9]+$ ]] || die "CRON_HOUR must be an integer in ${conf_path} (got: ${cron_hour})"
  [[ "${cron_minute}" =~ ^[0-9]+$ ]] || die "CRON_MINUTE must be an integer in ${conf_path} (got: ${cron_minute})"
  (( cron_hour >= 0 && cron_hour <= 23 )) || die "CRON_HOUR must be between 0 and 23 in ${conf_path} (got: ${cron_hour})"
  (( cron_minute >= 0 && cron_minute <= 59 )) || die "CRON_MINUTE must be between 0 and 59 in ${conf_path} (got: ${cron_minute})"
}

validate_backup_conf_runtime_controls_runtime() {
  local conf_path="${1:?config path required}"
  local backup_dashboard_dir=""
  local internal_backup_stale_after_hours=""
  local enable_usb_autorun=""
  local force_unmount_external=""
  local usb_lock_heartbeat=""
  local usb_lock_ttl=""

  backup_dashboard_dir="$(read_kv_value_from_file "${conf_path}" "BACKUP_DASHBOARD_DIR" || true)"
  [[ -n "${backup_dashboard_dir}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${conf_path}."
  internal_backup_stale_after_hours="$(read_kv_value_from_file "${conf_path}" "INTERNAL_BACKUP_STALE_AFTER_HOURS" || true)"
  [[ -n "${internal_backup_stale_after_hours}" ]] || die "Missing INTERNAL_BACKUP_STALE_AFTER_HOURS in ${conf_path}."
  enable_usb_autorun="$(read_kv_value_from_file "${conf_path}" "ENABLE_USB_AUTORUN" || true)"
  [[ -n "${enable_usb_autorun}" ]] || die "Missing ENABLE_USB_AUTORUN in ${conf_path}."
  force_unmount_external="$(read_kv_value_from_file "${conf_path}" "FORCE_UNMOUNT_EXTERNAL" || true)"
  [[ -n "${force_unmount_external}" ]] || die "Missing FORCE_UNMOUNT_EXTERNAL in ${conf_path}."
  usb_lock_heartbeat="$(read_kv_value_from_file "${conf_path}" "USB_LOCK_HEARTBEAT_INTERVAL_SECONDS" || true)"
  [[ -n "${usb_lock_heartbeat}" ]] || die "Missing USB_LOCK_HEARTBEAT_INTERVAL_SECONDS in ${conf_path}."
  usb_lock_ttl="$(read_kv_value_from_file "${conf_path}" "USB_LOCK_TTL_SECONDS" || true)"
  [[ -n "${usb_lock_ttl}" ]] || die "Missing USB_LOCK_TTL_SECONDS in ${conf_path}."

  [[ -n "${backup_dashboard_dir}" ]] || die "BACKUP_DASHBOARD_DIR must not be empty in ${conf_path}."
  [[ "${backup_dashboard_dir}" == /* ]] || die "BACKUP_DASHBOARD_DIR must be an absolute path in ${conf_path} (got: ${backup_dashboard_dir})"
  if [[ ! "${internal_backup_stale_after_hours}" =~ ^[0-9]+$ ]]; then
    die "INTERNAL_BACKUP_STALE_AFTER_HOURS must be a positive integer in ${conf_path} (got: ${internal_backup_stale_after_hours})"
  fi
  (( internal_backup_stale_after_hours > 0 )) || die "INTERNAL_BACKUP_STALE_AFTER_HOURS must be greater than zero in ${conf_path}."
  [[ "${enable_usb_autorun}" == "0" || "${enable_usb_autorun}" == "1" ]] || die "ENABLE_USB_AUTORUN must be 0 or 1 in ${conf_path} (got: ${enable_usb_autorun})"
  [[ "${force_unmount_external}" == "0" || "${force_unmount_external}" == "1" ]] || die "FORCE_UNMOUNT_EXTERNAL must be 0 or 1 in ${conf_path} (got: ${force_unmount_external})"
  [[ "${usb_lock_heartbeat}" =~ ^[0-9]+$ ]] || die "USB_LOCK_HEARTBEAT_INTERVAL_SECONDS must be a positive integer in ${conf_path} (got: ${usb_lock_heartbeat})"
  [[ "${usb_lock_ttl}" =~ ^[0-9]+$ ]] || die "USB_LOCK_TTL_SECONDS must be a positive integer in ${conf_path} (got: ${usb_lock_ttl})"
  (( usb_lock_heartbeat > 0 )) || die "USB_LOCK_HEARTBEAT_INTERVAL_SECONDS must be greater than zero in ${conf_path}."
  (( usb_lock_ttl > usb_lock_heartbeat )) || die "USB_LOCK_TTL_SECONDS must be greater than USB_LOCK_HEARTBEAT_INTERVAL_SECONDS in ${conf_path}."
}


validate_backup_conf_policy_controls_runtime() {
  local conf_path="${1:?config path required}"
  local write_usb_success_marker=""
  local full_backup_weekdays_internal=""
  local full_backup_weekdays_external=""
  local keep_cycles_internal=""
  local keep_cycles_external=""
  local enable_prune=""
  local keep_untagged_last=""
  local usb_mount_base=""
  local usb_fs_umask=""

  write_usb_success_marker="$(read_kv_value_from_file "${conf_path}" "WRITE_USB_SUCCESS_MARKER" || true)"
  [[ -n "${write_usb_success_marker}" ]] || die "Missing WRITE_USB_SUCCESS_MARKER in ${conf_path}."
  full_backup_weekdays_internal="$(read_kv_value_from_file "${conf_path}" "FULL_BACKUP_WEEKDAYS_INTERNAL" || true)"
  [[ -n "${full_backup_weekdays_internal}" ]] || die "Missing FULL_BACKUP_WEEKDAYS_INTERNAL in ${conf_path}."
  full_backup_weekdays_external="$(read_kv_value_from_file "${conf_path}" "FULL_BACKUP_WEEKDAYS_EXTERNAL" || true)"
  [[ -n "${full_backup_weekdays_external}" ]] || die "Missing FULL_BACKUP_WEEKDAYS_EXTERNAL in ${conf_path}."
  keep_cycles_internal="$(read_kv_value_from_file "${conf_path}" "KEEP_CYCLES_INTERNAL" || true)"
  [[ -n "${keep_cycles_internal}" ]] || die "Missing KEEP_CYCLES_INTERNAL in ${conf_path}."
  keep_cycles_external="$(read_kv_value_from_file "${conf_path}" "KEEP_CYCLES_EXTERNAL" || true)"
  [[ -n "${keep_cycles_external}" ]] || die "Missing KEEP_CYCLES_EXTERNAL in ${conf_path}."
  enable_prune="$(read_kv_value_from_file "${conf_path}" "ENABLE_PRUNE" || true)"
  [[ -n "${enable_prune}" ]] || die "Missing ENABLE_PRUNE in ${conf_path}."
  keep_untagged_last="$(read_kv_value_from_file "${conf_path}" "KEEP_UNTAGGED_LAST" || true)"
  [[ -n "${keep_untagged_last}" ]] || die "Missing KEEP_UNTAGGED_LAST in ${conf_path}."
  usb_mount_base="$(read_kv_value_from_file "${conf_path}" "USB_MOUNT_BASE" || true)"
  [[ -n "${usb_mount_base}" ]] || die "Missing USB_MOUNT_BASE in ${conf_path}."
  usb_fs_umask="$(read_kv_value_from_file "${conf_path}" "USB_FS_UMASK" || true)"
  [[ -n "${usb_fs_umask}" ]] || die "Missing USB_FS_UMASK in ${conf_path}."

  if [[ "${write_usb_success_marker}" != "0" && "${write_usb_success_marker}" != "1" ]]; then
    die "WRITE_USB_SUCCESS_MARKER must be 0 or 1 in ${conf_path} (got: ${write_usb_success_marker})"
  fi
  [[ "${enable_prune}" == "0" || "${enable_prune}" == "1" ]] || die "ENABLE_PRUNE must be 0 or 1 in ${conf_path} (got: ${enable_prune})"

  validate_full_backup_weekdays_value "${full_backup_weekdays_internal}" "FULL_BACKUP_WEEKDAYS_INTERNAL" "${conf_path}"
  validate_full_backup_weekdays_value "${full_backup_weekdays_external}" "FULL_BACKUP_WEEKDAYS_EXTERNAL" "${conf_path}"
  [[ "${keep_cycles_internal}" =~ ^[0-9]+$ ]] || die "KEEP_CYCLES_INTERNAL must be a non-negative integer in ${conf_path} (got: ${keep_cycles_internal})"
  [[ "${keep_cycles_external}" =~ ^[0-9]+$ ]] || die "KEEP_CYCLES_EXTERNAL must be a non-negative integer in ${conf_path} (got: ${keep_cycles_external})"
  [[ "${keep_untagged_last}" =~ ^[0-9]+$ ]] || die "KEEP_UNTAGGED_LAST must be a non-negative integer in ${conf_path} (got: ${keep_untagged_last})"

  [[ -n "${usb_mount_base}" ]] || die "USB_MOUNT_BASE must not be empty in ${conf_path}."
  [[ "${usb_mount_base}" == /* ]] || die "USB_MOUNT_BASE must be an absolute path in ${conf_path} (got: ${usb_mount_base})"
  [[ "${usb_fs_umask}" =~ ^[0-7]{3,4}$ ]] || die "USB_FS_UMASK must be a 3- or 4-digit octal umask in ${conf_path} (got: ${usb_fs_umask})"

}


verify_bootstrap_tree_for_render() {
  local tmp_conf=""

  load_bootstrap_placeholders
  tmp_conf="$(mktemp "${TMPDIR:-/tmp}/penelope-backup-conf.XXXXXX")" || die "Failed to create temporary backup.conf candidate"

  if ! (
    render_backup_conf_to_path "${tmp_conf}" "backup.conf candidate"
    bash -n "${tmp_conf}" >/dev/null 2>&1 || die "Shell syntax check failed for rendered backup.conf candidate"
    validate_backup_conf_schedule_runtime "${tmp_conf}"
    validate_backup_conf_runtime_controls_runtime "${tmp_conf}"
    validate_backup_conf_policy_controls_runtime "${tmp_conf}"
  ); then
    rm -f "${tmp_conf}" 2>/dev/null || true
    die "verify-config: rendered bootstrap backup.conf candidate failed validation: ${tmp_conf}"
  fi

  rm -f "${tmp_conf}" 2>/dev/null || true

  log "verify-config: bootstrap candidate valid for rendering backup.conf"
  log "  candidate HOST_SCOPE_NAME=${PLACEHOLDER_HOST_SCOPE_NAME}"
  log "  candidate CRON schedule=${PLACEHOLDER_CRON_HOUR}:${PLACEHOLDER_CRON_MINUTE}"
  log "  candidate BACKUP_DASHBOARD_DIR=${PLACEHOLDER_BACKUP_DASHBOARD_DIR}"
}

verify_restic_secret_plan() {
  local file="${1:?pw file required}"
  local label="${2:?label required}"
  local bootstrap_secret=""

  case "${SECRETS_MODE}" in
    keep)
      if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        die "verify-config: missing restic password file for ${label}: ${file} (--keep-secrets would fail)"
      fi
      log "verify-config: restic password ${label}: keep existing ${file}"
      ;;
    init)
      if [[ -f "${file}" ]] && [[ -s "${file}" ]]; then
        log "verify-config: restic password ${label}: existing ${file} would remain unchanged"
      else
        bootstrap_secret="$(bootstrap_secret_path_for_restic_file "${file}")" || die "Internal error: unknown bootstrap secret target for ${file}"
        bootstrap_secret_value_for_restic_file "${file}" >/dev/null
        log "verify-config: restic password ${label}: would initialize missing/empty ${file} from ${bootstrap_secret}"
      fi
      ;;
    *)
      die "Internal error: unknown SECRETS_MODE=${SECRETS_MODE}"
      ;;
  esac
}

verify_backup_setup_config() {
  local missing_count="0"

  require_root "sudo $0"
  log "=== Penelope backup setup verify-config ${VERSION} start (TARGET_HOST=${TARGET_HOST}) ==="
  log "Modes: CONFIG_MODE=${CONFIG_MODE}, SECRETS_MODE=${SECRETS_MODE}"
  log "verify-config: live HOST_SCOPE_NAME=${HOST_SCOPE_NAME} (source=${HOST_SCOPE_SOURCE})"

  validate_backup_setup_operator_config_file "${BACKUP_SETUP_CONFIG_FILE}"
  validate_backup_setup_active_secrets

  case "${CONFIG_MODE}" in
    keep)
      if [[ -f "${BACKUP_CONF}" ]]; then
        validate_existing_backup_conf_for_verify "${BACKUP_CONF}"
        validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
        validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
        validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
        log "verify-config: backup.conf plan=keep existing ${BACKUP_CONF}"
      else
        log "verify-config: backup.conf missing -> keep-config would still create it from bootstrap tree"
        verify_bootstrap_tree_for_render
        log "verify-config: backup.conf plan=create from bootstrap tree"
      fi
      ;;
    merge)
      if [[ -f "${BACKUP_CONF}" ]]; then
        local tmp_conf=""
        tmp_conf="$(mktemp "${TMPDIR:-/tmp}/penelope-backup-conf-verify.XXXXXX")" || die "Failed to create backup.conf verify candidate"
        if ! (
          backup_conf_candidate_with_current_defaults "${BACKUP_CONF}" "${tmp_conf}"
          validate_backup_conf_candidate_for_verify "${tmp_conf}"
        ); then
          rm -f "${tmp_conf}" 2>/dev/null || true
          die "verify-config: backup.conf merge candidate failed validation: ${tmp_conf}"
        fi
        missing_count="$(count_missing_backup_conf_defaults "${BACKUP_CONF}")"
        rm -f "${tmp_conf}" 2>/dev/null || true
        log "verify-config: backup.conf plan=merge existing ${BACKUP_CONF}"
        log "verify-config: backup.conf missing-key count=${missing_count}"
      else
        verify_bootstrap_tree_for_render
        log "verify-config: backup.conf plan=create from bootstrap tree"
      fi
      ;;
    reset)
      verify_bootstrap_tree_for_render
      if [[ -f "${BACKUP_CONF}" ]]; then
        validate_existing_backup_conf_for_verify "${BACKUP_CONF}"
        validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
        validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
        validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
        log "verify-config: backup.conf plan=reset existing ${BACKUP_CONF} from bootstrap tree (backup file would be created)"
      else
        log "verify-config: backup.conf missing -> reset-config would create it from bootstrap tree"
      fi
      ;;
    *)
      die "Internal error: unknown CONFIG_MODE=${CONFIG_MODE}"
      ;;
  esac

  verify_restic_secret_plan "${RESTIC_PW_SYSTEM}" "system"
  verify_restic_secret_plan "${RESTIC_PW_HOME}" "home"
  verify_restic_secret_plan "${RESTIC_PW_ARCHIVE}" "archive"
  verify_preserved_internal_repo_bootstrap_plan

  if [[ -f "${USB_CONF}" ]]; then
    ensure_no_unexpanded_tokens "${USB_CONF}"
    validate_usb_allowlist_disk_names "${USB_CONF}"
    log "verify-config: usb allow-list template exists and is semantically valid: ${USB_CONF}"
  else
    log "verify-config: usb allow-list template would be created: ${USB_CONF}"
  fi

  log "verify-config: apply would also refresh installed backup tooling, scheduling, Backup-Dashboard scaffolding, and sanitized recovery-stage copies"
  log "verify-config: no live artifacts were changed"
  log "=== Penelope backup setup verify-config completed ==="
}

write_backup_conf() {
  if [[ ! -f "${BACKUP_CONF}" ]]; then
    log "Creating config from bootstrap tree: ${BACKUP_CONF}"
    load_bootstrap_placeholders
    render_backup_conf
    return 0
  fi

  case "${CONFIG_MODE}" in
    keep)
      log "Config exists: ${BACKUP_CONF} (kept)"
      ensure_no_unexpanded_tokens "${BACKUP_CONF}"
      fix_backup_conf_perms
      ;;
    merge)
      rewrite_backup_conf_current_only "${BACKUP_CONF}"
      ;;
    reset)
      warn "Resetting config from bootstrap tree: ${BACKUP_CONF} (backup will be created)"
      backup_file "${BACKUP_CONF}"
      load_bootstrap_placeholders
      render_backup_conf
      ;;
    *)
      die "Internal error: unknown CONFIG_MODE=${CONFIG_MODE}"
      ;;
  esac
}

install_backup_dashboard_event_log() {
  local path="${1:?backup-dashboard event log required}"
  local label="${2:-backup-dashboard-event-log}"
  local mode_name="${3:?backup-dashboard mode required}"
  install_backup_dashboard_seed_artifact "${path}" "${label}" "${mode_name}" "event log" "render_backup_dashboard_seed_event_log"
}

repair_preserved_backup_dashboard_status_json_if_needed() {
  local path="${1:?backup-dashboard status json required}"
  local label="${2:-backup-dashboard-status-json}"
  local mode_name="${3:?backup-dashboard mode required}"
  local seed_message=""
  local tmp=""
  local repair_result=""

  [[ -f "${path}" ]] || return 0

  seed_message="$(backup_dashboard_seed_message_for_mode "${mode_name}")"
  tmp="$(make_backup_dashboard_tmp_file "$(dirname "${path}")")" || die "Failed to allocate temp file for ${label}: ${path}"
  repair_result="$(python3 - "${path}" "${tmp}" "${mode_name}" "${TARGET_HOST}" "${HOST_SCOPE_NAME}" "${BACKUP_LOG}" "${seed_message}" <<'PY_REPAIR_DASHBOARD_STATUS_JSON'
import json
import os
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
tmp = Path(sys.argv[2])
expected_mode, expected_host, expected_scope, expected_log, seed_message = sys.argv[3:8]

changed = False
parse_failed = False

try:
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        data = {}
        parse_failed = True
        changed = True
except Exception:
    data = {}
    parse_failed = True
    changed = True


def nonempty_str(value):
    return isinstance(value, str) and bool(value.strip())

if data.get('mode') != expected_mode:
    data['mode'] = expected_mode
    changed = True
if data.get('host') != expected_host:
    data['host'] = expected_host
    changed = True
if data.get('host_scope_name') != expected_scope:
    data['host_scope_name'] = expected_scope
    changed = True
if data.get('log_file') != expected_log:
    data['log_file'] = expected_log
    changed = True
if not nonempty_str(data.get('status')):
    data['status'] = 'not-run-yet'
    changed = True
if not nonempty_str(data.get('message')):
    if parse_failed:
        data['message'] = 'Repaired invalid backup-dashboard status JSON during penelope-backup-setup rerun.'
    else:
        data['message'] = seed_message
    changed = True
if not nonempty_str(data.get('timestamp')):
    data['timestamp'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    changed = True

if changed:
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write('\n')
    print('repaired-invalid' if parse_failed else 'repaired')
else:
    print('unchanged')
PY_REPAIR_DASHBOARD_STATUS_JSON
)" || {
    rm -f -- "${tmp}" 2>/dev/null || true
    die "Failed to normalize preserved backup-dashboard status JSON: ${path}"
  }

  case "${repair_result}" in
    unchanged)
      rm -f -- "${tmp}" 2>/dev/null || true
      ;;
    repaired|repaired-invalid)
      chown root:root "${tmp}" || { rm -f -- "${tmp}"; die "Failed to chown repaired ${label}: ${tmp}"; }
      chmod 0644 "${tmp}" || { rm -f -- "${tmp}"; die "Failed to chmod repaired ${label}: ${tmp}"; }
      mv -f -- "${tmp}" "${path}" || { rm -f -- "${tmp}"; die "Failed to install repaired ${label}: ${path}"; }
      log "Repaired preserved backup-dashboard status json: ${path}"
      ;;
    *)
      rm -f -- "${tmp}" 2>/dev/null || true
      die "Unexpected repair result for ${label}: ${path} (${repair_result})"
      ;;
  esac

  finalize_backup_dashboard_seed_artifact "${path}" "${label}"
}

repair_existing_backup_dashboard_status_json_glob() {
  local pattern="${1:?glob pattern required}"
  local label_prefix="${2:-backup-dashboard status json}"
  local mode_name="${3:?backup-dashboard mode required}"
  local path=""

  shopt -s nullglob
  for path in ${pattern}; do
    repair_preserved_backup_dashboard_status_json_if_needed "${path}" "${label_prefix}" "${mode_name}"
  done
  shopt -u nullglob
}

install_backup_dashboard_status_json() {
  local path="${1:?backup-dashboard status json required}"
  local label="${2:-backup-dashboard-status-json}"
  local mode_name="${3:?backup-dashboard mode required}"

  if [[ -f "${path}" ]]; then
    log "Dashboard status json exists: ${path} (preserved)"
    repair_preserved_backup_dashboard_status_json_if_needed "${path}" "${label}" "${mode_name}"
    return 0
  fi

  install_backup_dashboard_seed_artifact "${path}" "${label}" "${mode_name}" "status json" "render_backup_dashboard_seed_status_json"
}

install_backup_dashboard_dir() {
  local dash_dir=""

  dash_dir="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
  [[ -n "${dash_dir}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${BACKUP_CONF}"
  BACKUP_DASHBOARD_DIR="${dash_dir}"

  log "Ensuring canonical Backup-Dashboard dir: ${dash_dir}"
  install -d -m 0755 -o root -g root "${dash_dir}" || die "Failed to create Backup-Dashboard dir: ${dash_dir}"
  install_backup_dashboard_event_log "${dash_dir}/events-internal.log" "backup-dashboard internal event log" "internal"
  install_backup_dashboard_event_log "${dash_dir}/events-external.log" "backup-dashboard external event log" "external"
  install_backup_dashboard_event_log "${dash_dir}/events-ops.log" "backup-dashboard ops event log" "ops"
  install_backup_dashboard_status_json "${dash_dir}/last-internal.json" "backup-dashboard internal status json" "internal"
  install_backup_dashboard_status_json "${dash_dir}/last-ops.json" "backup-dashboard ops status json" "ops"
  repair_existing_backup_dashboard_status_json_glob "${dash_dir}/last-external-*.json" "backup-dashboard external status json" "external"
}
repair_usb_allowlist_active_header() {
  [[ -f "${USB_CONF}" ]] || return 0
  if ! grep -q '^# Version:' "${USB_CONF}"; then
    return 0
  fi

  local usb_conf_dir=""
  local tmp_allowlist=""
  usb_conf_dir="$(dirname "${USB_CONF}")"
  tmp_allowlist="$(mktemp "${usb_conf_dir}/usb-backup-disks.conf.tmp.XXXXXX")" || die "Failed to create USB allow-list temp file in ${usb_conf_dir}"
  chmod 600 "${tmp_allowlist}" 2>/dev/null || true
  chown root:root "${tmp_allowlist}" 2>/dev/null || true

  if ! awk '
    BEGIN { replaced = 0 }
    /^# Version:[[:space:]]*/ && replaced == 0 {
      sub(/^# Version:[[:space:]]*/, "# Template version at creation time: ")
      replaced = 1
    }
    { print }
  ' "${USB_CONF}" > "${tmp_allowlist}"; then
    rm -f -- "${tmp_allowlist}" 2>/dev/null || true
    die "Failed to rewrite USB allow-list header candidate: ${tmp_allowlist}"
  fi

  if ! ( validate_usb_allowlist_disk_names "${tmp_allowlist}" ); then
    rm -f -- "${tmp_allowlist}" 2>/dev/null || true
    die "USB allow-list header candidate failed validation: ${tmp_allowlist}"
  fi
  mv -f -- "${tmp_allowlist}" "${USB_CONF}"
  chmod 600 "${USB_CONF}" 2>/dev/null || true
  chown root:root "${USB_CONF}" 2>/dev/null || true
  log "USB allow-list active header clarified: ${USB_CONF}"
}

write_usb_conf_template() {
  if [[ -f "${USB_CONF}" ]]; then
    repair_usb_allowlist_active_header
    log "Config exists: ${USB_CONF} (preserved)"
    return 0
  fi

  log "Creating USB allow-list template: ${USB_CONF}"
  (
    umask 077
    install_file_from_heredoc "${USB_CONF}" 0600 root root "usb-allowlist" <<'EOF_USB_ALLOWLIST_CONF'
# Template version at creation time: ___PENELOPE_SETUP_VERSION___
# Allowed USB disks for external backups.
#
# Format required by the parser: "<UUID> <DISK_NAME>".
# DISK_NAME is mandatory, locally unique, label-safe, and at most 16 characters.
# Safe characters: letters, digits, dot, underscore, hyphen; start with a letter or digit.
# Keep DISK_NAME identical to the physical filesystem label for new Penelope USB backup disks.
#
# Recommended guided setup:
#   sudo /usr/local/sbin/penelope-usb-disk-setup.sh
#
# How to get the UUID manually:
#   lsblk -f
#   blkid
#
# Example entries:
# 1111-2222 Backup-A
# 3333-4444 Backup-C
#
# Empty file => external backups are not configured and will abort with a clear error.
EOF_USB_ALLOWLIST_CONF
  ) || die "Failed to scaffold USB allow-list template: ${USB_CONF}"
}

# -------------------- install runner --------------------
install_runner() {
  local runner_path="/usr/local/sbin/penelope-backup.sh"

  log "Installing runner: ${runner_path}"
  {
    cat <<'EOF_BACKUP_RUNNER_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-backup.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
#
# Run restic backups (internal/external) with Penelope full/incr retention-cycle tags.
# By default, full markers are Monday/Thursday and later snapshots in the same cycle are incr.
#
# Usage:
#   sudo /usr/local/sbin/penelope-backup.sh
#   sudo PENELOPE_BACKUP_SKIP_AUTO_VERIFY=1 /usr/local/sbin/penelope-backup.sh --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>] [--targets <list>] [--force] [--force-full]
#   sudo /usr/local/sbin/penelope-backup.sh --list --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>] [--targets <list>]
#   sudo /usr/local/sbin/penelope-backup.sh --cancel --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>]
#
# Targets (--targets, comma-separated): system, home, _archive, all (default: all)
# If multiple allowlisted USB disks are present and --uuid is omitted:
#   - with TTY: interactive selection
#   - without TTY: abort (use --uuid)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

EOF_BACKUP_RUNNER_SCRIPT
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_backup_dashboard_file_helpers
    emit_generated_usb_allowlist_helpers
    emit_generated_runtime_lock_helpers
    emit_generated_backup_runner_target_repo_helpers
    emit_generated_backup_runner_recovery_context_constants
    emit_generated_backup_runner_recovery_bundle_helpers
    cat <<'EOF_BACKUP_RUNNER_SCRIPT'
TARGET_HOST="${PENELOPE_TARGET_HOST:-$(hostname -s)}"
HOST_SCOPE_NAME="${PENELOPE_HOST_SCOPE_NAME:-${TARGET_HOST}}"
readonly ETC_DIR="/etc/${PROJECT}"
readonly CONF_FILE="${ETC_DIR}/backup.conf"
readonly USB_CONF="${ETC_DIR}/usb-backup-disks.conf"
readonly RECOVERY_BUNDLE_VERSION="___PENELOPE_SETUP_VERSION___"

# Preserve original stderr for "cron-visible" critical errors if desired.
exec 3>&2

# Runtime context (for concise cron output and Backup-Dashboard).
RUN_MODE="unknown"
RUN_UUID=""
RUN_TARGETS="all"
RUN_FORCE="0"
RUN_FORCE_FULL="0"
RUN_CANCEL="0"
RUN_LIST="0"
RUN_ID=""
RUN_DISK_NAME=""
RUN_DISK_TOKEN=""
RUN_KIND=""
RUN_CYCLE_ID=""
PROCESSED_UUIDS=""
EXTERNAL_SAFE_TO_REMOVE="1"
EXTERNAL_SUCCESS_FINALIZED="0"
RUN_MOUNT_PATH=""
USB_LOCK_FILE=""
USB_LOCK_OWNED="0"
HEARTBEAT_PID=""
BACKUP_RUN_LOCK_DIR=""
BACKUP_RUN_LOCK_LABEL=""
BACKUP_RUN_MODE_FILE=""
BACKUP_RUN_UUID_FILE=""
BACKUP_RUN_SUCCESS_FINALIZED_FILE=""
BACKUP_TARGET_LAST_ERROR=""
FAILURE_ALREADY_PUBLISHED="0"
RUN_STARTED="0"
DASHBOARD_PUBLISH_FAILED="0"

cron_note() {
  >&3 echo "[$(ts)] INFO: $*"
}

log_context_prefix() {
  local -a fields=()
  [[ -n "${RUN_ID:-}" ]] && fields+=("run=${RUN_ID}")
  [[ -n "${RUN_MODE:-}" && "${RUN_MODE}" != "unknown" ]] && fields+=("mode=${RUN_MODE}")
  [[ -n "${RUN_UUID:-}" ]] && fields+=("uuid=${RUN_UUID}")
  [[ -n "${RUN_DISK_TOKEN:-}" ]] && fields+=("disk=${RUN_DISK_TOKEN}")
  [[ -n "${RUN_TARGETS:-}" ]] && fields+=("targets=${RUN_TARGETS}")
  if [[ "${#fields[@]}" -eq 0 ]]; then
    return 0
  fi
  printf '[%s] ' "${fields[*]}"
}

log_append() {
  local msg="$*"
  local prefix=""
  prefix="$(log_context_prefix)"
  if [[ -z "${prefix}" ]]; then
    >&2 echo "${msg}"
    return 0
  fi
  if [[ "${msg}" == *': '* ]]; then
    >&2 echo "${msg%%: *}: ${prefix}${msg#*: }"
  else
    >&2 echo "${prefix}${msg}"
  fi
}

join_by() {
  local sep="${1:-, }"
  shift || true
  local out=""
  local item=""
  for item in "$@"; do
    [[ -n "${item}" ]] || continue
    if [[ -n "${out}" ]]; then
      out+="${sep}"
    fi
    out+="${item}"
  done
  printf '%s\n' "${out}"
}

backup_run_internal_lock_dir() {
  printf '%s
' "/run/${PROJECT}/backup-run-internal.lock.d"
}

backup_run_external_lock_dir_for_uuid() {
  local uuid="${1:?uuid required}"
  printf '%s
' "/run/${PROJECT}/backup-run-external-${uuid}.lock.d"
}

configure_backup_run_lock_paths() {
  local mode="${1:?mode required}"
  local uuid="${2:-}"
  case "${mode}" in
    internal)
      BACKUP_RUN_LOCK_DIR="$(backup_run_internal_lock_dir)"
      BACKUP_RUN_LOCK_LABEL="internal backup run"
      ;;
    external)
      [[ -n "${uuid}" ]] || die "configure_backup_run_lock_paths requires UUID for external mode"
      BACKUP_RUN_LOCK_DIR="$(backup_run_external_lock_dir_for_uuid "${uuid}")"
      BACKUP_RUN_LOCK_LABEL="external backup run for UUID ${uuid}"
      ;;
    *)
      die "Unknown backup run mode for lock path configuration: ${mode}"
      ;;
  esac
  BACKUP_RUN_MODE_FILE="${BACKUP_RUN_LOCK_DIR}/mode"
  BACKUP_RUN_UUID_FILE="${BACKUP_RUN_LOCK_DIR}/uuid"
  BACKUP_RUN_SUCCESS_FINALIZED_FILE="${BACKUP_RUN_LOCK_DIR}/success-finalized"
}

internal_backup_run_is_active_runtime() {
  local lock_dir=""
  lock_dir="$(backup_run_internal_lock_dir)"
  pid_dir_lock_is_active_runtime "${lock_dir}" "internal backup run"
}

any_external_backup_run_is_active_runtime() {
  local dir=""
  shopt -s nullglob
  for dir in "/run/${PROJECT}"/backup-run-external-*.lock.d; do
    if pid_dir_lock_is_active_runtime "${dir}" "external backup run"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

acquire_backup_run_lock() {
  [[ -n "${BACKUP_RUN_LOCK_DIR:-}" ]] || die "Backup run lock dir is not configured"
  acquire_pid_dir_lock "${BACKUP_RUN_LOCK_DIR}" "${BACKUP_RUN_LOCK_LABEL:-backup run}"
}

release_backup_run_lock() {
  if ! release_pid_dir_lock "${BACKUP_RUN_LOCK_DIR}"; then
    warn "Failed to release ${BACKUP_RUN_LOCK_LABEL:-backup run} lock: ${BACKUP_RUN_LOCK_DIR}"
    return 1
  fi
  return 0
}

write_backup_run_mode_marker() {
  [[ -d "${BACKUP_RUN_LOCK_DIR}" ]] || die "Backup run lock dir missing before mode marker write: ${BACKUP_RUN_LOCK_DIR}"
  printf '%s\n' "${RUN_MODE}" > "${BACKUP_RUN_MODE_FILE}" || die "Failed to write backup run mode marker: ${BACKUP_RUN_MODE_FILE}"
}

write_backup_run_uuid_marker() {
  local uuid="${1:-}"
  [[ -d "${BACKUP_RUN_LOCK_DIR}" ]] || die "Backup run lock dir missing before uuid marker write: ${BACKUP_RUN_LOCK_DIR}"
  if [[ -n "${uuid}" ]]; then
    printf '%s\n' "${uuid}" > "${BACKUP_RUN_UUID_FILE}" || die "Failed to write backup run uuid marker: ${BACKUP_RUN_UUID_FILE}"
  else
    rm -f -- "${BACKUP_RUN_UUID_FILE}" 2>/dev/null || true
  fi
}

clear_backup_run_mode_marker() {
  if ! rm -f -- "${BACKUP_RUN_MODE_FILE}" 2>/dev/null; then
    warn "Failed to clear backup run mode marker: ${BACKUP_RUN_MODE_FILE}"
    return 1
  fi
  return 0
}

clear_backup_run_uuid_marker() {
  if ! rm -f -- "${BACKUP_RUN_UUID_FILE}" 2>/dev/null; then
    warn "Failed to clear backup run uuid marker: ${BACKUP_RUN_UUID_FILE}"
    return 1
  fi
  return 0
}

write_backup_run_success_finalized_marker() {
  [[ -d "${BACKUP_RUN_LOCK_DIR}" ]] || die "Backup run lock dir missing before success-finalized marker write: ${BACKUP_RUN_LOCK_DIR}"
  printf '%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "${BACKUP_RUN_SUCCESS_FINALIZED_FILE}" \
    || die "Failed to write backup run success-finalized marker: ${BACKUP_RUN_SUCCESS_FINALIZED_FILE}"
}

backup_run_success_finalized_marker_present() {
  local lock_dir="${1:?lock dir required}"
  [[ -f "${lock_dir}/success-finalized" ]]
}

clear_backup_run_success_finalized_marker() {
  if ! rm -f -- "${BACKUP_RUN_SUCCESS_FINALIZED_FILE}" 2>/dev/null; then
    warn "Failed to clear backup run success-finalized marker: ${BACKUP_RUN_SUCCESS_FINALIZED_FILE}"
    return 1
  fi
  return 0
}

# Backup-Dashboard: canonical status files for non-interactive monitoring.
BACKUP_DASHBOARD_DIR=""
READY_FILE=""
REATTACH_AND_WAIT_FILE=""
LEGACY_REATTACH_AND_RETRY_FILE=""
DO_NOT_REMOVE_FILE=""
RUNNING_FILE=""
INTERNAL_RUNNING_FILE=""
INTERNAL_OK_FILE=""
INTERNAL_ERROR_FILE=""
INTERNAL_STALE_FILE=""

emit_ops_backup_dashboard_helpers() {
  local uuid_fallback_var="${1:?uuid fallback var required}"
  local include_disk_name="${2:-0}"

  cat <<EOF_OPS_HELPERS
ensure_ops_backup_dashboard() {
  ensure_backup_dashboard "\${BACKUP_DASHBOARD_DIR}"
}

write_ops_backup_dashboard_event() {
  local event="\${1:?event required}"
  local message="\${2:-}"
  local uuid="\${3:-\${${uuid_fallback_var}}}"
  local status_file="\${BACKUP_DASHBOARD_DIR}/events-ops.log"
  append_backup_dashboard_event_line "\${status_file}" "ops" "\${event}" "\${message}" "\${uuid}" "all" "\${OPS_KIND}" "" || true
}

write_ops_backup_dashboard_json() {
  local status="\${1:?status required}"
  local event="\${2:?event required}"
  local message="\${3:-}"
  local uuid="\${4:-\${${uuid_fallback_var}}}"
  local out="\${BACKUP_DASHBOARD_DIR}/last-ops.json"
  ensure_ops_backup_dashboard
  write_backup_dashboard_status_json_file "\${out}" "ops" "\${status}" "\${message}" "\${uuid}" "" "\${OPS_KIND}" "\${event}" "0" "${include_disk_name}"
}

write_ops_backup_dashboard_status() {
  local status="\${1:?status required}"
  local event="\${2:?event required}"
  local message="\${3:-}"
  local uuid="\${4:-\${${uuid_fallback_var}}}"
  write_ops_backup_dashboard_event "\${event}" "\${message}" "\${uuid}"
  write_ops_backup_dashboard_json "\${status}" "\${event}" "\${message}" "\${uuid}"
}
EOF_OPS_HELPERS
}


write_backup_dashboard_event() {
  local event="${1:?event required}"
  local message="${2:-}"
  local status_file="${BACKUP_DASHBOARD_DIR}/events-${RUN_MODE}.log"

  [[ -n "${BACKUP_DASHBOARD_DIR}" ]] || return 0
  append_backup_dashboard_event_line "${status_file}" "${RUN_MODE}" "${event}" "${message}" "${RUN_UUID}" "${RUN_TARGETS}" "${RUN_KIND}" "${RUN_CYCLE_ID}"
}

write_backup_dashboard_json() {
  # Args: <status> <message> <uuids_csv>
  local status="${1:?status required}"
  local message="${2:-}"
  local uuids_csv="${3:-}"

  [[ -n "${BACKUP_DASHBOARD_DIR}" ]] || return 0
  ensure_backup_dashboard

  local out=""
  if [[ "${RUN_MODE}" == "external" ]]; then
    [[ -n "${RUN_DISK_NAME:-}" ]] || die "Missing RUN_DISK_NAME for external Backup-Dashboard status JSON."
    out="$(usb_external_status_json_path "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  else
    out="${BACKUP_DASHBOARD_DIR}/last-${RUN_MODE}.json"
  fi
  write_backup_dashboard_status_json_file "${out}" "${RUN_MODE}" "${status}" "${message}" "${RUN_UUID}" "${uuids_csv}" "${RUN_KIND}" "" "1" "1"
}

set_external_signal_paths() {
  [[ "${RUN_MODE:-}" == "external" ]] || return 0
  [[ -n "${RUN_UUID:-}" ]] || die "Missing RUN_UUID for external Backup-Dashboard signals."
  [[ -n "${RUN_DISK_NAME:-}" ]] || die "Allow-list entry for UUID ${RUN_UUID} must define DISK_NAME."
  RUN_DISK_TOKEN="$(normalize_disk_name_token "${RUN_DISK_NAME}")"
  READY_FILE="$(usb_signal_file_path ready "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  REATTACH_AND_WAIT_FILE="$(usb_signal_file_path reattach_and_wait "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  LEGACY_REATTACH_AND_RETRY_FILE="$(usb_legacy_retry_signal_file_path "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  DO_NOT_REMOVE_FILE="$(usb_signal_file_path hold "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  RUNNING_FILE="$(usb_signal_file_path running "${RUN_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
}

restore_external_signal_backups() {
  local backups_manifest="${1:-}"
  local path=""
  local tmp=""
  local rc=0
  while IFS=$'	' read -r path tmp; do
    [[ -n "${path}" && -n "${tmp}" ]] || continue
    if ! cp -p -- "${tmp}" "${path}" 2>/dev/null && ! cat -- "${tmp}" > "${path}"; then
      warn "Failed to restore external dashboard signal backup: ${tmp} -> ${path}"
      rc=1
      continue
    fi
    if ! chmod 0644 "${path}" 2>/dev/null; then
      warn "Failed to restore mode on external dashboard signal: ${path}"
      rc=1
    fi
    if ! rm -f -- "${tmp}" 2>/dev/null; then
      warn "Failed to remove consumed external dashboard signal backup: ${tmp}"
      rc=1
    fi
  done <<< "${backups_manifest}"
  return ${rc}
}

cleanup_external_signal_backups() {
  local backups_manifest="${1:-}"
  local path=""
  local tmp=""
  local rc=0
  while IFS=$'	' read -r path tmp; do
    [[ -n "${tmp}" ]] || continue
    if ! rm -f -- "${tmp}" 2>/dev/null; then
      warn "Failed to remove external dashboard signal backup: ${tmp}"
      rc=1
    fi
  done <<< "${backups_manifest}"
  return ${rc}
}

write_external_signal_file_with_rollback() {
  local out="${1:?output file required}"
  local header="${2:?header required}"
  shift 2

  local -a notice_lines=()
  while (( $# > 0 )); do
    if [[ "$1" == "--clear" ]]; then
      shift
      break
    fi
    notice_lines+=("$1")
    shift
  done
  local -a clear_paths=("$@")

  local dash_dir="${BACKUP_DASHBOARD_DIR:-$(dirname "${out}")}"
  local backups_manifest=""
  local path=""
  local tmp=""
  local -a backup_paths=("${out}" "${clear_paths[@]}")

  for path in "${backup_paths[@]}"; do
    [[ -n "${path}" && -f "${path}" ]] || continue
    tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || {
      cleanup_external_signal_backups "${backups_manifest}" || warn "Failed to clean up external dashboard signal backups after temp-file allocation failure"
      return 1
    }
    cp -p -- "${path}" "${tmp}" 2>/dev/null || {
      if ! rm -f -- "${tmp}"; then
        warn "Failed to remove incomplete external dashboard signal backup temp file: ${tmp}"
      fi
      cleanup_external_signal_backups "${backups_manifest}" || warn "Failed to clean up external dashboard signal backups after copy failure"
      return 1
    }
    backups_manifest+="${path}"$'	'"${tmp}"$'
'
  done

  for path in "${clear_paths[@]}"; do
    [[ -n "${path}" ]] || continue
    rm -f -- "${path}" || {
      restore_external_signal_backups "${backups_manifest}" || warn "Failed to restore external dashboard signal backups"
      return 1
    }
  done

  if write_backup_dashboard_notice_file "${out}" "${header}" "${notice_lines[@]}"; then
    cleanup_external_signal_backups "${backups_manifest}" || warn "Failed to remove external dashboard signal backups after publishing $(basename -- "${out}")"
    return 0
  fi

  restore_external_signal_backups "${backups_manifest}" || warn "Failed to restore external dashboard signal backups"
  return 1
}

write_ready_file() {
  local uuids_csv="${1:-}"
  [[ -n "${READY_FILE}" ]] || return 0
  write_external_signal_file_with_rollback \
    "${READY_FILE}" \
    "$(usb_signal_header ready "${RUN_DISK_NAME}")" \
    "uuids=${uuids_csv}" \
    "targets=${RUN_TARGETS}" \
    "disk_name=${RUN_DISK_NAME}" \
    "message=The USB backup drive may now be removed." \
    --clear \
    "${RUNNING_FILE:-}" \
    "${REATTACH_AND_WAIT_FILE:-}" \
    "${LEGACY_REATTACH_AND_RETRY_FILE:-}" \
    "${DO_NOT_REMOVE_FILE:-}"
}

clear_ready_file() {
  [[ -n "${READY_FILE}" ]] || return 0
  clear_backup_dashboard_files "${READY_FILE}"
}

write_reattach_and_wait_file() {
  local message="${1:-The USB backup drive is not currently attached. Reattach the same disk and wait for the next retry.}"
  [[ -n "${REATTACH_AND_WAIT_FILE}" ]] || return 0
  write_external_signal_file_with_rollback \
    "${REATTACH_AND_WAIT_FILE}" \
    "$(usb_signal_header reattach_and_wait "${RUN_DISK_NAME}")" \
    "disk_name=${RUN_DISK_NAME}" \
    "message=${message}" \
    --clear \
    "${RUNNING_FILE:-}" \
    "${READY_FILE:-}" \
    "${DO_NOT_REMOVE_FILE:-}" \
    "${LEGACY_REATTACH_AND_RETRY_FILE:-}"
}

clear_reattach_and_wait_file() {
  [[ -n "${REATTACH_AND_WAIT_FILE}" || -n "${LEGACY_REATTACH_AND_RETRY_FILE}" ]] || return 0
  clear_backup_dashboard_files "${REATTACH_AND_WAIT_FILE}" "${LEGACY_REATTACH_AND_RETRY_FILE}"
}

write_do_not_remove_file() {
  local message="${1:-Backup did not complete successfully. Do not remove the USB backup drive. Contact the operator.}"
  [[ -n "${DO_NOT_REMOVE_FILE}" ]] || return 0
  write_external_signal_file_with_rollback \
    "${DO_NOT_REMOVE_FILE}" \
    "$(usb_signal_header hold "${RUN_DISK_NAME}")" \
    "disk_name=${RUN_DISK_NAME}" \
    "message=${message}" \
    --clear \
    "${RUNNING_FILE:-}" \
    "${READY_FILE:-}" \
    "${REATTACH_AND_WAIT_FILE:-}" \
    "${LEGACY_REATTACH_AND_RETRY_FILE:-}"
}

clear_do_not_remove_file() {
  [[ -n "${DO_NOT_REMOVE_FILE}" ]] || return 0
  clear_backup_dashboard_files "${DO_NOT_REMOVE_FILE}"
}

write_running_file() {
  local uuids_csv="${1:-}"
  [[ -n "${RUNNING_FILE}" ]] || return 0
  write_external_signal_file_with_rollback \
    "${RUNNING_FILE}" \
    "$(usb_signal_header running "${RUN_DISK_NAME}")" \
    "uuids=${uuids_csv}" \
    "targets=${RUN_TARGETS}" \
    "disk_name=${RUN_DISK_NAME}" \
    "message=The USB backup drive was detected. Backup is currently running. Do NOT remove the USB backup drive yet." \
    --clear \
    "${READY_FILE:-}" \
    "${REATTACH_AND_WAIT_FILE:-}" \
    "${LEGACY_REATTACH_AND_RETRY_FILE:-}" \
    "${DO_NOT_REMOVE_FILE:-}"
}

clear_running_file() {
  [[ -n "${RUNNING_FILE}" ]] || return 0
  clear_backup_dashboard_files "${RUNNING_FILE}"
}

external_dashboard_contract_ready() {
  [[ "${RUN_MODE:-}" == "external" ]] || return 1
  [[ -n "${BACKUP_DASHBOARD_DIR:-}" ]] || return 1
  [[ -n "${RUN_DISK_NAME:-}" ]] || return 1
  [[ -n "${RUNNING_FILE:-}" ]] || return 1
  [[ -n "${REATTACH_AND_WAIT_FILE:-}" ]] || return 1
  [[ -n "${LEGACY_REATTACH_AND_RETRY_FILE:-}" ]] || return 1
  [[ -n "${DO_NOT_REMOVE_FILE:-}" ]] || return 1
  return 0
}

failure_dashboard_json_contract_ready() {
  if [[ "${RUN_MODE:-}" == "external" ]]; then
    external_dashboard_contract_ready
    return $?
  fi
  [[ -n "${BACKUP_DASHBOARD_DIR:-}" ]]
}

publish_failure_state_once() {
  local fail_msg="${1:?failure message required}"
  local publish_rc=0

  if [[ "${FAILURE_ALREADY_PUBLISHED:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "${RUN_MODE:-}" ]]; then
    cron_note "penelope-backup ${RUN_MODE} FAILED (see /var/log/${HOST_SCOPE_NAME}/backup/backup.log)"
  else
    cron_note "penelope-backup FAILED"
  fi

  write_backup_dashboard_event "failed" "${fail_msg}" || {
    >&2 echo "[$(ts)] WARN: Failed to append Backup-Dashboard failure event (${RUN_MODE:-unknown})."
    publish_rc=1
  }

  if failure_dashboard_json_contract_ready; then
    write_backup_dashboard_json "failed" "${fail_msg}" "${PROCESSED_UUIDS:-${RUN_UUID}}" || {
      >&2 echo "[$(ts)] WARN: Failed to write Backup-Dashboard failure status JSON (${RUN_MODE:-unknown})."
      publish_rc=1
    }
  elif [[ "${RUN_MODE:-}" == "external" && -n "${BACKUP_DASHBOARD_DIR:-}" ]]; then
    warn "External Backup-Dashboard status JSON skipped because the external dashboard contract was not fully initialized yet."
    publish_rc=1
  fi

  FAILURE_ALREADY_PUBLISHED="1"
  return "${publish_rc}"
}

clear_internal_running_file() {
  [[ -n "${INTERNAL_RUNNING_FILE}" ]] || return 0
  clear_backup_dashboard_files "${INTERNAL_RUNNING_FILE}"
}

clear_internal_status_files() {
  clear_backup_dashboard_files "${INTERNAL_OK_FILE:-}" "${INTERNAL_ERROR_FILE:-}" "${INTERNAL_STALE_FILE:-}"
}

restore_runner_internal_status_backups() {
  local manifest="${1:-}"
  local path=""
  local backup=""
  local rc=0
  while IFS=$'	' read -r path backup; do
    [[ -n "${path}" && -n "${backup}" ]] || continue
    if ! mv -f -- "${backup}" "${path}" && ! cp -p -- "${backup}" "${path}" 2>/dev/null; then
      warn "Failed to restore internal dashboard status backup: ${backup} -> ${path}"
      rc=1
      continue
    fi
    if [[ -e "${backup}" ]] && ! rm -f -- "${backup}"; then
      warn "Failed to remove consumed internal dashboard status backup: ${backup}"
      rc=1
    fi
  done <<< "${manifest}"
  return ${rc}
}

cleanup_runner_internal_status_backups() {
  local manifest="${1:-}"
  local path=""
  local backup=""
  local rc=0
  while IFS=$'	' read -r path backup; do
    [[ -n "${backup}" ]] || continue
    if ! rm -f -- "${backup}"; then
      warn "Failed to remove internal dashboard status backup: ${backup}"
      rc=1
    fi
  done <<< "${manifest}"
  return ${rc}
}

backup_runner_internal_status_files() {
  local dash_dir="${BACKUP_DASHBOARD_DIR:-${DEFAULT_BACKUP_DASHBOARD_DIR}}"
  local backups_manifest=""
  local path=""
  local tmp=""
  local -a paths=(
    "${INTERNAL_RUNNING_FILE:-}"
    "${INTERNAL_OK_FILE:-}"
    "${INTERNAL_ERROR_FILE:-}"
    "${INTERNAL_STALE_FILE:-}"
  )

  for path in "${paths[@]}"; do
    [[ -n "${path}" && -f "${path}" ]] || continue
    tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || {
      cleanup_runner_internal_status_backups "${backups_manifest}" || warn "Failed to clean up internal dashboard status backups after temp-file allocation failure"
      return 1
    }
    cp -p -- "${path}" "${tmp}" 2>/dev/null || {
      if ! rm -f -- "${tmp}" 2>/dev/null; then
        warn "Failed to remove incomplete internal dashboard status backup temp file: ${tmp}"
      fi
      cleanup_runner_internal_status_backups "${backups_manifest}" || warn "Failed to clean up internal dashboard status backups after copy failure"
      return 1
    }
    backups_manifest+="${path}"$'	'"${tmp}"$'
'
  done

  printf '%s' "${backups_manifest}"
}

write_internal_running_file() {
  local internal_status_backups=""
  [[ -n "${INTERNAL_RUNNING_FILE}" ]] || return 0
  internal_status_backups="$(backup_runner_internal_status_files)" || return 1
  clear_internal_status_files || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  if write_backup_dashboard_notice_file \
      "${INTERNAL_RUNNING_FILE}" \
      "INTERNAL_BACKUP_RUNNING" \
      "message=The internal backup is currently running."; then
    cleanup_runner_internal_status_backups "${internal_status_backups}" \
      || warn "Failed to remove internal dashboard status backups after writing INTERNAL_BACKUP_RUNNING.txt"
    return 0
  fi

  restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
  return 1
}

write_internal_ok_file_after_success() {
  local internal_status_backups=""
  local success_timestamp=""
  [[ -n "${INTERNAL_OK_FILE:-}" ]] || return 1

  success_timestamp="${RUN_FINISHED_ISO:-$(date +%Y-%m-%dT%H:%M:%S%z)}"
  internal_status_backups="$(backup_runner_internal_status_files)" || return 1
  clear_internal_running_file || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  clear_internal_status_files || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  if write_backup_dashboard_notice_file \
      "${INTERNAL_OK_FILE}" \
      "INTERNAL_BACKUP_OK" \
      "last_status=success" \
      "last_timestamp=${success_timestamp}" \
      "message=The last internal backup completed successfully."; then
    cleanup_runner_internal_status_backups "${internal_status_backups}" \
      || warn "Failed to remove internal dashboard status backups after writing INTERNAL_BACKUP_OK.txt"
    return 0
  fi

  restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
  return 1
}

write_internal_error_file_after_success_status_failure() {
  local internal_status_backups=""
  [[ -n "${INTERNAL_ERROR_FILE:-}" ]] || return 1
  internal_status_backups="$(backup_runner_internal_status_files)" || return 1
  clear_internal_running_file || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  clear_internal_status_files || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  if write_backup_dashboard_notice_file \
      "${INTERNAL_ERROR_FILE}" \
      "INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR" \
      "message=The internal backup completed, but the Backup-Dashboard success status could not be published. Contact the operator."; then
    cleanup_runner_internal_status_backups "${internal_status_backups}" \
      || warn "Failed to remove internal dashboard status backups after writing INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt"
    return 0
  fi
  restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
  return 1
}

write_internal_error_file_after_failure() {
  local failure_message="${1:-The internal backup did not complete successfully. Contact the operator.}"
  local internal_status_backups=""
  local failure_timestamp=""
  [[ -n "${INTERNAL_ERROR_FILE:-}" ]] || return 1

  failure_timestamp="${RUN_FINISHED_ISO:-$(date +%Y-%m-%dT%H:%M:%S%z)}"
  internal_status_backups="$(backup_runner_internal_status_files)" || return 1
  clear_internal_running_file || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  clear_internal_status_files || {
    restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  if write_backup_dashboard_notice_file \
      "${INTERNAL_ERROR_FILE}" \
      "INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR" \
      "last_status=failed" \
      "last_timestamp=${failure_timestamp}" \
      "message=The internal backup failed or was canceled. Contact the operator." \
      "details=${failure_message}"; then
    cleanup_runner_internal_status_backups "${internal_status_backups}" \
      || warn "Failed to remove internal dashboard status backups after writing INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt"
    return 0
  fi

  restore_runner_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
  return 1
}

refresh_internal_backup_dashboard_state() {
  local helper="/usr/local/sbin/penelope-refresh-backup-dashboard.sh"
  if [[ ! -x "${helper}" ]]; then
    warn "Failed to refresh internal Backup-Dashboard state: missing helper ${helper}"
    return 1
  fi
  "${helper}" || {
    warn "Failed to refresh internal Backup-Dashboard state"
    return 1
  }
}

warn_dashboard_publish_failure() {
  local context="${1:?context required}"
  DASHBOARD_PUBLISH_FAILED="1"
  warn "Backup-Dashboard update failed: ${context}"
}

write_internal_last_status_json_fallback() {
  local status="${1:?status required}"
  local message="${2:-}"
  local uuids_csv="${3:-}"
  local out="${LAST_INTERNAL_JSON:?last-internal.json path required}"
  local dash_dir="${BACKUP_DASHBOARD_DIR:?backup dashboard dir required}"
  local tmp=""

  tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || return 1
  python3 - \
    "${tmp}" \
    "${status}" \
    "${message}" \
    "${RUN_UUID:-}" \
    "${uuids_csv}" \
    "${RUN_KIND:-}" \
    "${TARGET_HOST:-}" \
    "${HOST_SCOPE_NAME:-}" \
    "${BACKUP_LOG:-}" <<'PY_INTERNAL_LAST_STATUS_JSON_FALLBACK'
import datetime as dt
import json
import sys

out, status, message, run_uuid, uuids_csv, kind, host, scope, log_file = sys.argv[1:10]

def csv_list(raw: str):
    raw = (raw or '').strip()
    if not raw:
        return []
    return [part for part in raw.split(',') if part]

data = {
    'event': '',
    'host': host,
    'host_scope_name': scope,
    'kind': kind,
    'log_file': log_file,
    'message': message,
    'mode': 'internal',
    'status': status,
    'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(),
}
if run_uuid:
    data['uuid'] = run_uuid
uuids = csv_list(uuids_csv)
if uuids:
    data['uuids'] = uuids
with open(out, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY_INTERNAL_LAST_STATUS_JSON_FALLBACK
  chmod 0644 "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
  mv -f -- "${tmp}" "${out}" || { rm -f -- "${tmp}"; return 1; }
}

require_external_dashboard_action() {
  local context="${1:?context required}"
  shift
  "$@" || die "External Backup-Dashboard contract violation: ${context} failed for disk '${RUN_DISK_NAME:-unknown}' in ${BACKUP_DASHBOARD_DIR:-unset}."
}

write_usb_success_marker() {
  local mnt="${1:?mnt required}"
  [[ "${WRITE_USB_SUCCESS_MARKER}" == "1" ]] || return 0
  local stamp
  local marker=""
  stamp="$(date +'%Y%m%d-%H%M%S')"
  marker="${mnt}/PENELOPE_BACKUP_OK_${stamp}.txt"
  if ! {
    echo "PENELOPE_BACKUP_OK"
    echo "timestamp=$(ts)"
    echo "host=${TARGET_HOST}"
    echo "host_scope_name=${HOST_SCOPE_NAME}"
    echo "mode=external"
    echo "kind=${RUN_KIND}"
    echo "cycle_id=${RUN_CYCLE_ID}"
  } > "${marker}"; then
    rm -f -- "${marker}" 2>/dev/null || true
    return 1
  fi
  if ! chmod 0644 "${marker}" 2>/dev/null; then
    rm -f -- "${marker}" 2>/dev/null || true
    return 1
  fi
  sync || warn "sync failed after writing USB success marker: ${marker}"
}


external_existing_run_wait_seconds() {
  local wait_seconds="${PENELOPE_USB_BACKUP_EXISTING_RUN_WAIT_SECONDS:-120}"
  [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || wait_seconds="120"
  printf '%s
' "${wait_seconds}"
}

external_existing_run_poll_seconds() {
  local poll_seconds="${PENELOPE_USB_BACKUP_EXISTING_RUN_POLL_SECONDS:-2}"
  [[ "${poll_seconds}" =~ ^[0-9]+$ ]] || poll_seconds="2"
  (( poll_seconds > 0 )) || poll_seconds="2"
  printf '%s
' "${poll_seconds}"
}

lock_usb_uuid() {
  local uuid="${1:?uuid required}"
  local wait_seconds=""
  local poll_seconds=""
  local elapsed=0

  if try_acquire_single_uuid_run_lock "${uuid}" "/run/penelope"; then
    return 0
  fi

  wait_seconds="$(external_existing_run_wait_seconds)"
  poll_seconds="$(external_existing_run_poll_seconds)"
  warn "Another Penelope external backup for UUID ${uuid} is already active; waiting up to ${wait_seconds} seconds before refusing to start a parallel writer."
  warn "To cancel an autorun backup intentionally: sudo systemctl stop \"penelope-usb-backup@${uuid}.service\""

  while (( elapsed < wait_seconds )); do
    sleep "${poll_seconds}" || true
    elapsed=$(( elapsed + poll_seconds ))
    if try_acquire_single_uuid_run_lock "${uuid}" "/run/penelope"; then
      warn "Previous external backup for UUID ${uuid} finished after ${elapsed} seconds; continuing without parallel writers."
      return 0
    fi
  done

  die "Another Penelope external backup for UUID ${uuid} is still active after ${wait_seconds} seconds; refusing to start a parallel writer."
}

release_uuid_lock() {
  if ! release_single_uuid_run_lock; then
    warn "Failed to release USB UUID lock: ${UUID_LOCK_PATH:-unknown}"
    return 1
  fi
  return 0
}


new_run_id() {
  local kernel_uuid
  kernel_uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  [[ -n "${kernel_uuid}" ]] || die "Unable to generate run id from /proc/sys/kernel/random/uuid"
  printf '%s
' "${kernel_uuid//-/}"
}

usb_lock_path() {
  local mnt="${1:?mnt required}"
  echo "${mnt}/.penelope-backup-lock.json"
}

usb_lock_status() {
  # Args: <lock_path>  (prints: MISSING|INVALID|ACTIVE|STALE and optionally a one-line summary on stderr)
  local lock_path="${1:?lock path required}"
  python3 - "${lock_path}" <<'PY_USB_LOCK_STATUS'
import json, os, sys, time
p = sys.argv[1]
if not os.path.exists(p):
  print("MISSING")
  sys.exit(0)
try:
  with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
except Exception:
  print("INVALID")
  sys.exit(0)

now = int(time.time())
boot_id = ""
try:
  with open("/proc/sys/kernel/random/boot_id","r",encoding="utf-8") as f:
    boot_id = f.read().strip()
except Exception:
  boot_id = ""

pid = d.get("pid")
expires_at = d.get("expires_at")
last_seen_at = d.get("last_seen_at")
lock_boot = d.get("boot_id","")
run_id = d.get("run_id","")
host = d.get("host_scope_name","")
uuid = d.get("uuid","")
targets = d.get("targets","")
mode = d.get("mode","")

def is_int(x):
  try:
    int(x); return True
  except Exception:
    return False

stale = False
reason = ""
if lock_boot and boot_id and lock_boot != boot_id:
  stale = True
  reason = "boot_id_mismatch"
elif is_int(expires_at) and now > int(expires_at):
  stale = True
  reason = "ttl_expired"
elif is_int(pid):
  pid_i = int(pid)
  if pid_i > 0 and not os.path.exists(f"/proc/{pid_i}"):
    stale = True
    reason = "pid_missing"

if stale:
  print("STALE")
  sys.stderr.write(f"stale_reason={reason} run_id={run_id} host={host} uuid={uuid} targets={targets} mode={mode}\n")
  sys.exit(0)

print("ACTIVE")
sys.stderr.write(f"run_id={run_id} host={host} uuid={uuid} targets={targets} mode={mode}\n")
PY_USB_LOCK_STATUS
}

usb_lock_write() {
  # Args: <lock_path> <uuid> <disk_name> <targets>
  local lock_path="${1:?lock path required}"
  local uuid="${2:?uuid required}"
  local disk_name="${3:-}"
  local targets="${4:-}"
  local ttl="${USB_LOCK_TTL_SECONDS:?USB_LOCK_TTL_SECONDS must be loaded before usb_lock_write}"

  local now epoch_expires
  now="$(date +%s)"
  epoch_expires="$(( now + ttl ))"

  local tmp="${lock_path}.tmp"
  python3 - "${tmp}" "${RUN_ID}" "$$" "${uuid}" "${disk_name}" "${targets}" "${RUN_MODE}" "${TARGET_HOST}" "${now}" "${epoch_expires}" <<'PY_USB_LOCK_WRITE'
import json, os, sys, time
out, run_id, pid_s, uuid, disk_name, targets, mode, host, now_s, exp_s = sys.argv[1:]
now = int(now_s); exp = int(exp_s)
boot_id = ""
try:
  with open("/proc/sys/kernel/random/boot_id","r",encoding="utf-8") as f:
    boot_id = f.read().strip()
except Exception:
  boot_id = ""

data = {
  "run_id": run_id,
  "pid": int(pid_s),
  "boot_id": boot_id,
  "started_at": now,
  "last_seen_at": now,
  "expires_at": exp,
  "host_scope_name": host,
  "uuid": uuid,
  "disk_name": disk_name,
  "targets": targets,
  "mode": mode,
}
with open(out, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, sort_keys=True)
  f.write("\n")
PY_USB_LOCK_WRITE
  mv -f "${tmp}" "${lock_path}"
  chmod 0644 "${lock_path}" || true
}

usb_lock_touch() {
  # Args: <lock_path>
  local lock_path="${1:?lock path required}"
  local ttl="${USB_LOCK_TTL_SECONDS:?USB_LOCK_TTL_SECONDS must be loaded before usb_lock_touch}"
  python3 - "${lock_path}" "${ttl}" <<'PY_USB_LOCK_TOUCH'
import json, sys, time, os
p, ttl_s = sys.argv[1], sys.argv[2]
ttl = int(ttl_s)
now = int(time.time())
try:
  with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
except Exception as exc:
  sys.stderr.write(f"usb lock touch read failed: {exc}\n")
  sys.exit(1)

d["last_seen_at"] = now
d["expires_at"] = now + ttl
tmp = p + ".tmp"
try:
  with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write("\n")
  os.replace(tmp, p)
except Exception as exc:
  try:
    os.unlink(tmp)
  except Exception:
    pass
  sys.stderr.write(f"usb lock touch write failed: {exc}\n")
  sys.exit(1)
PY_USB_LOCK_TOUCH
}

usb_lock_heartbeat_assert_running() {
  if [[ -n "${HEARTBEAT_PID:-}" ]] && ! kill -0 "${HEARTBEAT_PID}" 2>/dev/null; then
    die "USB lock heartbeat process exited unexpectedly."
  fi
}

usb_lock_acquire() {
  # Args: <mnt> <uuid> <disk_name> <targets>
  local mnt="${1:?mnt required}"
  local uuid="${2:?uuid required}"
  local disk_name="${3:-}"
  local targets="${4:-}"

  local lock_path
  lock_path="$(usb_lock_path "${mnt}")"
  USB_LOCK_FILE="${lock_path}"

  local status
  local summary=""
  summary="$(usb_lock_status "${lock_path}" 2>&1)"
  status="$(echo "${summary}" | head -n 1)"
  local meta
  meta="$(echo "${summary}" | tail -n +2 | head -n 1 || true)"

  if [[ "${status}" == "ACTIVE" ]]; then
    if [[ "${RUN_FORCE}" == "1" ]]; then
      warn "External on-disk lock present; overriding due to --force (${meta})"
    else
      die "External on-disk lock present (${meta}). Use --force to override."
    fi
  elif [[ "${status}" == "INVALID" ]]; then
    if [[ "${RUN_FORCE}" == "1" ]]; then
      warn "Invalid external lock file; overriding due to --force"
    else
      warn "Invalid external lock file found; treating as stale and replacing."
    fi
  elif [[ "${status}" == "STALE" ]]; then
    warn "Stale external lock found; replacing (${meta})"
  fi

  usb_lock_write "${lock_path}" "${uuid}" "${disk_name}" "${targets}"
  USB_LOCK_OWNED="1"
}

usb_lock_release() {
  # Args: <mnt>
  local mnt="${1:?mnt required}"
  local lock_path
  lock_path="$(usb_lock_path "${mnt}")"
  if [[ "${USB_LOCK_OWNED}" == "1" && -f "${lock_path}" ]]; then
    rm -f "${lock_path}" 2>/dev/null || true
  fi
  USB_LOCK_OWNED="0"
  USB_LOCK_FILE=""
}

usb_lock_heartbeat_start() {
  # Args: <mnt>
  local mnt="${1:?mnt required}"
  local lock_path
  local interval="${USB_LOCK_HEARTBEAT_INTERVAL_SECONDS:?USB_LOCK_HEARTBEAT_INTERVAL_SECONDS must be loaded before usb_lock_heartbeat_start}"
  local parent_pid="$$"
  lock_path="$(usb_lock_path "${mnt}")"

  (
    # The heartbeat must not inherit and hold the parent UUID flock.
    exec 9>&- 2>/dev/null || true
    while true; do
      sleep "${interval}" || exit 0
      if ! usb_lock_touch "${lock_path}"; then
        warn "USB lock heartbeat update failed for ${lock_path}; terminating the current backup process group."
        kill -TERM -- "-${parent_pid}" 2>/dev/null || kill -TERM "${parent_pid}" 2>/dev/null || true
        exit 1
      fi
    done
  ) &
  HEARTBEAT_PID="$!"
}

usb_lock_heartbeat_stop() {
  if [[ -n "${HEARTBEAT_PID}" ]]; then
    kill "${HEARTBEAT_PID}" 2>/dev/null || true
    wait "${HEARTBEAT_PID}" 2>/dev/null || true
    HEARTBEAT_PID=""
  fi
}



usb_mounted_by_us_marker() {
  local uuid="${1:?uuid required}"
  echo "/run/penelope/usb-mounted-by-us-${uuid}.flag"
}

usb_mark_mounted_by_us() {
  local uuid="${1:?uuid required}"
  local mark
  mark="$(usb_mounted_by_us_marker "${uuid}")"
  install -d -m 0700 -o root -g root "/run/penelope" || return 1
  : > "${mark}" 2>/dev/null || return 1
}

finalize_mounted_usb_by_us_or_die() {
  local uuid="${1:?uuid required}"
  local dev="${2:?device required}"
  local mnt="${3:?mount path required}"

  if usb_mark_mounted_by_us "${uuid}"; then
    printf '%s
' "${mnt}"
    return 0
  fi

  sync || true
  if umount "${mnt}" 2>/dev/null; then
    die "Mounted ${dev} at ${mnt} but failed to record penelope mounted-by-us marker; unmounted again to avoid inconsistent auto-unmount state."
  fi

  die "Mounted ${dev} at ${mnt} but failed to record penelope mounted-by-us marker and failed to unmount ${mnt}; manual cleanup required."
}

usb_was_mounted_by_us() {
  local uuid="${1:?uuid required}"
  [[ -f "$(usb_mounted_by_us_marker "${uuid}")" ]]
}

usb_mount_is_current_penelope_managed() {
  local uuid="${1:?uuid required}"
  local dev="${2:?device required}"
  local expected_mount_path="${3:?expected mount path required}"
  local target=""
  local count=0

  while IFS= read -r target; do
    [[ -n "${target}" ]] || continue
    (( count += 1 ))
    [[ "${target}" == "${expected_mount_path}" ]] || return 1
  done < <(findmnt -n -o TARGET --source "${dev}" 2>/dev/null || true)

  (( count == 1 )) || return 1
  usb_was_mounted_by_us "${uuid}"
}

usb_clear_mounted_by_us() {
  local uuid="${1:?uuid required}"
  rm -f "$(usb_mounted_by_us_marker "${uuid}")" 2>/dev/null || true
}


backup_cancel_wait_seconds() {
  local wait_seconds="${PENELOPE_BACKUP_CANCEL_WAIT_SECONDS:-120}"
  [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || wait_seconds="120"
  printf '%s
' "${wait_seconds}"
}

backup_cancel_poll_seconds() {
  local poll_seconds="${PENELOPE_BACKUP_CANCEL_POLL_SECONDS:-2}"
  [[ "${poll_seconds}" =~ ^[0-9]+$ ]] || poll_seconds="2"
  (( poll_seconds > 0 )) || poll_seconds="2"
  printf '%s
' "${poll_seconds}"
}

active_pid_from_backup_run_lock() {
  local lock_dir="${1:?lock dir required}"
  local label="${2:?label required}"
  local pid=""

  if ! pid_dir_lock_is_active "${lock_dir}" "${label}"; then
    return 1
  fi
  pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  [[ "${pid}" != "$$" ]] || return 1
  printf '%s
' "${pid}"
}

wait_for_pid_to_exit_after_cancel() {
  local pid="${1:?pid required}"
  local label="${2:?label required}"
  local wait_seconds=""
  local poll_seconds=""
  local elapsed=0

  wait_seconds="$(backup_cancel_wait_seconds)"
  poll_seconds="$(backup_cancel_poll_seconds)"
  while kill -0 "${pid}" 2>/dev/null; do
    if (( elapsed >= wait_seconds )); then
      warn "${label} is still active after ${wait_seconds} seconds (pid ${pid})."
      return 1
    fi
    sleep "${poll_seconds}" || true
    elapsed=$(( elapsed + poll_seconds ))
  done
  log "${label} exited after cancel request."
}

request_backup_pid_cancel() {
  local pid="${1:?pid required}"
  local label="${2:?label required}"

  if ! kill -0 "${pid}" 2>/dev/null; then
    log "${label} is no longer active."
    return 0
  fi

  warn "Requesting graceful cancellation of ${label} (pid ${pid})."
  if ! kill -TERM -- "-${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || {
      warn "Failed to send TERM to ${label} (pid ${pid})."
      return 1
    }
  fi
  wait_for_pid_to_exit_after_cancel "${pid}" "${label}"
}

restic_repo_pids_csv() {
  local repo="${1:?repo required}"
  active_restic_repo_pids "${repo}" | paste -sd, -
}

external_restic_processes_are_active() {
  local uuid="${1:?uuid required}"
  local base="${USB_MOUNT_BASE}/${uuid}/${HOST_SCOPE_NAME}"
  local target=""
  local repo=""
  local pids=""

  while IFS= read -r target; do
    repo="${base}/$(repo_relpath_for_target "${target}")"
    pids="$(restic_repo_pids_csv "${repo}")"
    if [[ -n "${pids}" ]]; then
      return 0
    fi
  done < <(all_backup_targets)
  return 1
}

warn_relevant_external_restic_processes() {
  local uuid="${1:?uuid required}"
  local base="${USB_MOUNT_BASE}/${uuid}/${HOST_SCOPE_NAME}"
  local target=""
  local repo=""
  local pids=""
  local found=0

  while IFS= read -r target; do
    repo="${base}/$(repo_relpath_for_target "${target}")"
    pids="$(restic_repo_pids_csv "${repo}")"
    if [[ -n "${pids}" ]]; then
      warn "Restic process(es) still active for external ${target} repo ${repo}: pid(s) ${pids}"
      found=1
    fi
  done < <(all_backup_targets)
  (( found == 0 )) && log "No active restic processes found for external UUID ${uuid}."
}

cleanup_external_mount_after_cancel_if_idle() {
  local uuid="${1:?uuid required}"
  local mnt="${USB_MOUNT_BASE}/${uuid}"
  local dev=""
  local mounted_at=""

  dev="$(usb_dev_for_uuid "${uuid}" 2>/dev/null || true)"
  if [[ -z "${dev}" ]]; then
    warn "Could not resolve USB block device for UUID ${uuid} during cancel cleanup. Inspect mount state manually."
    return 1
  fi

  if external_restic_processes_are_active "${uuid}"; then
    warn "External restic process remains active for UUID ${uuid}; leaving USB mount state unchanged."
    return 1
  fi

  if ! dev_is_mounted_anywhere "${dev}"; then
    log "External USB mount is not present for UUID ${uuid}."
    return 0
  fi

  mounted_at="$(mounted_targets_for_dev_display "${dev}")"
  if [[ "${FORCE_UNMOUNT_EXTERNAL}" != "1" ]]; then
    log "External USB device ${dev} remains mounted at ${mounted_at}; FORCE_UNMOUNT_EXTERNAL=0, so cancel will not unmount it."
    return 0
  fi

  log "No relevant backup/restic process remains for UUID ${uuid}; FORCE_UNMOUNT_EXTERNAL=1 => unmounting ${dev} from ${mounted_at:-current mountpoint}."
  sync || true
  if ! unmount_all_mounts_for_dev "${dev}"; then
    warn "Failed to unmount USB ${uuid} (${dev}) after cancel. Manual unmount required before removal."
    return 1
  fi
  usb_clear_mounted_by_us "${uuid}"

  if dev_is_mounted_anywhere "${dev}"; then
    mounted_at="$(mounted_targets_for_dev_display "${dev}")"
    warn "USB ${uuid} (${dev}) remains mounted at ${mounted_at:-unknown mountpoint} after cancel cleanup."
    return 1
  fi

  log "External USB mount released after cancel for UUID ${uuid}."
}

warn_relevant_internal_restic_processes() {
  local base="/_backup/${HOST_SCOPE_NAME}"
  local target=""
  local repo=""
  local pids=""
  local found=0

  while IFS= read -r target; do
    repo="${base}/$(repo_relpath_for_target "${target}")"
    pids="$(restic_repo_pids_csv "${repo}")"
    if [[ -n "${pids}" ]]; then
      warn "Restic process(es) still active for internal ${target} repo ${repo}: pid(s) ${pids}"
      found=1
    fi
  done < <(all_backup_targets)
  (( found == 0 )) && log "No active restic processes found for internal backup repositories."
}

cancel_external_backup_run() {
  local uuid="${1:?uuid required}"
  local disk_name="${2:-}"
  local unit="penelope-usb-backup@${uuid}.service"
  local lock_dir=""
  local pid=""
  local rc=0

  log "Cancel requested for external backup disk ${disk_name:-unknown} (UUID ${uuid})."

  lock_dir="$(backup_run_external_lock_dir_for_uuid "${uuid}")"
  if pid="$(active_pid_from_backup_run_lock "${lock_dir}" "external backup run")"; then
    if backup_run_success_finalized_marker_present "${lock_dir}"; then
      log "External backup for UUID ${uuid} has already completed success finalization; not sending a late cancel signal."
    else
      if command -v systemctl >/dev/null 2>&1; then
        log "Requesting systemd stop for ${unit} when present."
        systemctl stop "${unit}" 2>/dev/null || true
      fi
      request_backup_pid_cancel "${pid}" "external backup for UUID ${uuid}" || rc=1
    fi
  else
    if command -v systemctl >/dev/null 2>&1; then
      log "Requesting systemd stop for ${unit} when present."
      systemctl stop "${unit}" 2>/dev/null || true
    fi
    log "No active Penelope external backup run lock found for UUID ${uuid}."
  fi

  warn_relevant_external_restic_processes "${uuid}"
  if ! cleanup_external_mount_after_cancel_if_idle "${uuid}"; then
    rc=1
  fi
  return "${rc}"
}

cancel_internal_backup_run() {
  local lock_dir=""
  local pid=""
  local rc=0

  log "Cancel requested for internal backup."
  lock_dir="$(backup_run_internal_lock_dir)"
  if pid="$(active_pid_from_backup_run_lock "${lock_dir}" "internal backup run")"; then
    request_backup_pid_cancel "${pid}" "internal backup" || rc=1
  else
    log "No active Penelope internal backup run lock found."
  fi

  warn_relevant_internal_restic_processes
  if findmnt /_backup >/dev/null 2>&1; then
    log "/_backup remains mounted. Do not unmount /_backup to cancel an internal backup."
  else
    warn "/_backup is not mounted; inspect the internal backup role before the next backup."
  fi
  return "${rc}"
}

run_cancel_command() {
  case "${RUN_MODE}" in
    internal)
      cancel_internal_backup_run
      ;;
    external)
      [[ -n "${RUN_UUID}" ]] || die "--cancel --mode external requires --uuid <UUID> or --disk-name <DISK_NAME>."
      cancel_external_backup_run "${RUN_UUID}" "${RUN_DISK_NAME:-}"
      ;;
    *)
      die "Unknown cancel mode: ${RUN_MODE}. Use internal or external."
      ;;
  esac
}

die() {
  local msg="${1:-Unknown error}"
  local ec="${2:-1}"
  >&2 echo "[$(ts)] ERROR: ${msg}"

  if [[ "${RUN_MODE:-}" == "external" && "${RUN_STARTED:-0}" != "1" ]]; then
    case "${msg}" in
      "Another backup run seems to be running"* )
        skip_message="External backup start skipped because another backup run is already active."
        skip_message+=" The current per-disk dashboard truth remains unchanged"
        skip_message+=" until a later external run actually starts."
        warn "${skip_message}"
        exit 0
        ;;
      "USB backup already running for UUID "*|"External backup activity already holds the USB lock for UUID "* )
        skip_message="External backup start skipped because the same USB backup disk already has active backup work."
        skip_message+=" The current per-disk dashboard truth remains unchanged"
        skip_message+=" until a later external run actually starts."
        warn "${skip_message}"
        exit 0
        ;;
    esac
  fi

  # Defer failure publication to on_exit(). Publishing here can partially fail,
  # set FAILURE_ALREADY_PUBLISHED=1, and suppress the later cleanup-aware retry.
  exit "$ec"
}

backup_runner_on_signal() {
  local sig="${1:?signal required}"
  local ec=""
  if [[ "${RUN_MODE:-}" == "external" && "${EXTERNAL_SUCCESS_FINALIZED:-0}" == "1" ]]; then
    warn "Received ${sig} after external backup success finalization; ignoring late cancellation signal."
    return 0
  fi
  ec="$(penelope_signal_exit_code_for_name "${sig}")"
  LAST_FATAL_MESSAGE="signal ${sig}"
  warn "Received ${sig}; aborting penelope-backup."
  exit "${ec}"
}

print_help() {
  cat >&2 <<'HELP_MAIN'
Usage:
  sudo /usr/local/sbin/penelope-backup.sh
  sudo /usr/local/sbin/penelope-backup.sh --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>] [--targets <list>] [--force] [--force-full]
  sudo /usr/local/sbin/penelope-backup.sh --list --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>] [--targets <list>]
  sudo /usr/local/sbin/penelope-backup.sh --cancel --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>]

Options:
  --mode       internal | external
  --uuid       USB UUID (external only)
  --disk-name  registered DISK_NAME from /etc/penelope/usb-backup-disks.conf (external only)
  --targets    system,home,_archive,all   (comma-separated; default: all)
  --force      override an on-disk external USB lock after operator review
  --force-full force penelope_kind=full for this run in the currently configured cycle
  --list       list Restic snapshots for the selected Penelope backup scope(s)
  --cancel     cancel the active Penelope backup selected by --mode and, for external, --uuid/--disk-name
  -h|--help    show this help

Notes:
  --disk-name resolves only through the local USB allow-list. It does not scan filesystem labels.
  --force-full does not change FULL_BACKUP_WEEKDAYS_*, retention policy, or future cycle calculation.
  --list shows Penelope tags such as penelope_kind=full or penelope_kind=incr; Restic snapshots remain deduplicating snapshots.
  --cancel sends a graceful TERM request and refuses broad process killing.
  If multiple allowlisted USB disks are present and neither --uuid nor --disk-name is provided:
    - with a TTY: interactive selection
    - without a TTY: abort (use --uuid or --disk-name)
HELP_MAIN
}

parse_cli() {
  # Defaults
  RUN_MODE="internal"
  RUN_UUID=""
  RUN_DISK_NAME_SELECTOR=""
  RUN_TARGETS="all"
  RUN_FORCE="0"
  RUN_FORCE_FULL="0"
  RUN_CANCEL="0"
  RUN_LIST="0"

  if [[ $# -eq 0 ]]; then
    RUN_TARGETS="$(targets_normalize "${RUN_TARGETS}")"
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --mode)
        RUN_MODE="${2:-}"
        shift 2
        ;;
      --uuid)
        RUN_UUID="${2:-}"
        shift 2
        ;;
      --disk-name)
        [[ $# -ge 2 ]] || die "--disk-name requires a DISK_NAME"
        RUN_DISK_NAME_SELECTOR="${2}"
        shift 2
        ;;
      --targets)
        RUN_TARGETS="${2:-}"
        shift 2
        ;;
      --list)
        RUN_LIST="1"
        shift
        ;;
      --force-full)
        RUN_FORCE_FULL="1"
        shift
        ;;
      --cancel)
        RUN_CANCEL="1"
        shift
        ;;
      -f|--force)
        RUN_FORCE="1"
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        die "Unknown option: ${1}"
        ;;
    esac
  done

  [[ -n "${RUN_MODE}" ]] || die "Missing --mode (internal|external)"
  if [[ "${RUN_MODE}" != "internal" && "${RUN_MODE}" != "external" ]]; then
    die "Unknown mode: ${RUN_MODE}. Use: internal | external"
  fi

  if [[ "${RUN_MODE}" == "internal" ]]; then
    [[ -z "${RUN_UUID}" ]] || die "--uuid is only valid with --mode external"
    [[ -z "${RUN_DISK_NAME_SELECTOR}" ]] || die "--disk-name is only valid with --mode external"
  fi

  if [[ "${RUN_CANCEL}" == "1" && "${RUN_LIST}" == "1" ]]; then
    die "Use either --list or --cancel, not both."
  fi

  if [[ "${RUN_FORCE_FULL}" == "1" && "${RUN_LIST}" == "1" ]]; then
    die "--force-full is only valid for backup runs, not --list."
  fi
  if [[ "${RUN_FORCE_FULL}" == "1" && "${RUN_CANCEL}" == "1" ]]; then
    die "--force-full is only valid for backup runs, not --cancel."
  fi

  if [[ "${RUN_CANCEL}" == "1" && "${RUN_TARGETS}" != "all" ]]; then
    die "--cancel does not accept --targets; cancel selects the active run by --mode and optional external disk selector."
  fi

  RUN_TARGETS="$(targets_normalize "${RUN_TARGETS}")"
}

targets_normalize() {
  local in="${1:-all}"
  in="${in,,}"
  in="${in//[[:space:]]/}"
  [[ -n "${in}" ]] || in="all"

  local out=""
  local item
  IFS=',' read -r -a _items <<< "${in}"
  for item in "${_items[@]}"; do
    [[ -n "${item}" ]] || continue
    case "${item}" in
      all)
        echo "all"
        return 0
        ;;
      system|home|_archive)
        case ",${out}," in
          *",${item},"*) : ;;
          *) out="${out}${out:+,}${item}" ;;
        esac
        ;;
      *)
        die "Unknown --targets entry: ${item} (allowed: system,home,_archive,all)"
        ;;
    esac
  done

  [[ -n "${out}" ]] || out="all"
  echo "${out}"
}

target_enabled() {
  local t="${1:?target required}"
  [[ "${RUN_TARGETS}" == "all" ]] && return 0
  case ",${RUN_TARGETS}," in
    *",${t},"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}


pick_uuid_interactive() {
  # Args: UUID list
  local -a uuids=("$@")
  local -a labels=()
  local uuid name
  for uuid in "${uuids[@]}"; do
    name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
    if [[ -n "${name}" ]]; then
      labels+=("${uuid}  (${name})")
    else
      labels+=("${uuid}")
    fi
  done

  >&2 echo "Multiple allowlisted USB disks detected. Please select one:"
  local PS3="Select USB disk (1-${#labels[@]}): "
  select _choice in "${labels[@]}"; do
    if [[ -n "${_choice}" && "${REPLY}" =~ ^[0-9]+$ && "${REPLY}" -ge 1 && "${REPLY}" -le "${#uuids[@]}" ]]; then
      echo "${uuids[$((REPLY-1))]}"
      return 0
    fi
    >&2 echo "Invalid selection. Try again."
  done
}

resolve_external_uuid() {
  if [[ -n "${RUN_UUID}" ]]; then
    echo "${RUN_UUID}"
    return 0
  fi

  mapfile -t _present < <(read_present_allowlisted_uuids "${USB_CONF}")
  if (( ${#_present[@]} == 0 )); then
    die "No allowlisted USB disks detected. Insert one of the configured disks in ${USB_CONF} or pass --uuid <UUID> / --disk-name <DISK_NAME>."
  fi
  if (( ${#_present[@]} == 1 )); then
    echo "${_present[0]}"
    return 0
  fi

  if is_tty; then
    pick_uuid_interactive "${_present[@]}"
    return 0
  fi

  die "Multiple allowlisted USB disks detected. Non-interactive run requires --uuid <UUID> or --disk-name <DISK_NAME>."
}

on_err() {
  local lineno="${1:-?}"
  local cmd="${2:-}"
  die "Unhandled error at line ${lineno}: ${cmd}"
}

trap 'on_err ${LINENO} "${BASH_COMMAND}"' ERR

load_conf() {
  [[ -f "${CONF_FILE}" ]] || die "Missing config: ${CONF_FILE} (run penelope-backup-setup)"
  unset \
    USB_LOCK_HEARTBEAT_INTERVAL_SECONDS \
    USB_LOCK_TTL_SECONDS \
    INTERNAL_BACKUP_STALE_AFTER_HOURS \
    FORCE_UNMOUNT_EXTERNAL \
    WRITE_USB_SUCCESS_MARKER \
    ENABLE_PRUNE \
    FULL_BACKUP_WEEKDAYS_INTERNAL \
    FULL_BACKUP_WEEKDAYS_EXTERNAL \
        KEEP_CYCLES_INTERNAL \
    KEEP_CYCLES_EXTERNAL \
    KEEP_UNTAGGED_LAST \
    USB_MOUNT_BASE \
    USB_FS_UMASK \
        HOST_SCOPE_NAME \
    BACKUP_DASHBOARD_DIR \
    LOG_DIR \
    BACKUP_LOG
  # shellcheck source=/dev/null
  source "${CONF_FILE}"
  load_backup_runtime_context_from_conf "${CONF_FILE}" "/var/lib/${PROJECT}/backup-dashboard"
  export TARGET_HOST HOST_SCOPE_NAME
}

validate_usb_lock_timing_config() {
  local interval="${USB_LOCK_HEARTBEAT_INTERVAL_SECONDS-}"
  local ttl="${USB_LOCK_TTL_SECONDS-}"

  [[ -n "${interval}" ]] || die "Missing USB_LOCK_HEARTBEAT_INTERVAL_SECONDS in ${CONF_FILE}."
  [[ -n "${ttl}" ]] || die "Missing USB_LOCK_TTL_SECONDS in ${CONF_FILE}."

  [[ "${interval}" =~ ^[0-9]+$ ]] || die "USB_LOCK_HEARTBEAT_INTERVAL_SECONDS must be a positive integer (got: ${interval})."
  [[ "${ttl}" =~ ^[0-9]+$ ]] || die "USB_LOCK_TTL_SECONDS must be a positive integer (got: ${ttl})."
  (( interval > 0 )) || die "USB_LOCK_HEARTBEAT_INTERVAL_SECONDS must be greater than zero."
  (( ttl > interval )) || die "USB_LOCK_TTL_SECONDS must be greater than USB_LOCK_HEARTBEAT_INTERVAL_SECONDS."
}

ensure_log() {
  install -d -m 0750 -o root -g adm "${LOG_DIR}"
  touch "${BACKUP_LOG}"
  chown root:adm "${BACKUP_LOG}"
  chmod 0640 "${BACKUP_LOG}"
  # Redirect all stdout/stderr into the backup log (cron stays quiet).
  exec >>"${BACKUP_LOG}" 2>&1
}

restic_env() {
  local repo="${1:?repo required}"
  local pw_file="${2:?pw file required}"
  export RESTIC_REPOSITORY="${repo}"
  export RESTIC_PASSWORD_FILE="${pw_file}"
}

restic_unset() {
  unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

active_restic_repo_pids() {
  local repo="${1:?repo required}"
  local proc=""
  local pid=""
  local cmdline_flat=""
  local env_repo=""
  local arg=""
  local repo_arg=""
  local next_is_repo="0"

  for proc in /proc/[0-9]*; do
    [[ -r "${proc}/cmdline" ]] || continue
    pid="${proc##*/}"
    [[ "${pid}" == "$$" ]] && continue

    cmdline_flat="$(tr '\0' ' ' < "${proc}/cmdline" 2>/dev/null || true)"
    [[ -n "${cmdline_flat}" ]] || continue
    [[ "${cmdline_flat}" == *restic* ]] || continue

    env_repo="$(tr '\0' '\n' < "${proc}/environ" 2>/dev/null | sed -n 's/^RESTIC_REPOSITORY=//p' | head -n 1 || true)"
    if [[ "${env_repo}" == "${repo}" ]]; then
      printf '%s\n' "${pid}"
      continue
    fi

    repo_arg=""
    next_is_repo="0"
    while IFS= read -r arg; do
      [[ -n "${arg}" ]] || continue
      if [[ "${next_is_repo}" == "1" ]]; then
        repo_arg="${arg}"
        break
      fi
      case "${arg}" in
        --repo|-r)
          next_is_repo="1"
          ;;
        --repo=*)
          repo_arg="${arg#--repo=}"
          break
          ;;
        -r?*)
          repo_arg="${arg#-r}"
          break
          ;;
      esac
    done < <(tr '\0' '\n' < "${proc}/cmdline" 2>/dev/null || true)

    if [[ "${repo_arg}" == "${repo}" ]]; then
      printf '%s\n' "${pid}"
    fi
  done
}

prepare_restic_repo_for_writes() {
  local name="${1:?name required}"
  local repo="${2:?repo required}"
  local repo_pids=""

  if restic snapshots --json >/dev/null 2>&1; then
    return 0
  fi

  if ! restic snapshots --json --no-lock >/dev/null 2>&1; then
    BACKUP_TARGET_LAST_ERROR="${name}: restic repository is not readable before backup: ${repo}"
    return 1
  fi

  repo_pids="$(active_restic_repo_pids "${repo}" | paste -sd, -)"
  if [[ -n "${repo_pids}" ]]; then
    BACKUP_TARGET_LAST_ERROR="${name}: restic repository appears busy (pid(s): ${repo_pids}); refusing automatic unlock recovery."
    return 1
  fi

  log "${name}: previous run appears to have left a stale restic lock; attempting controlled unlock recovery for ${repo}"
  if ! restic unlock >/dev/null 2>&1; then
    BACKUP_TARGET_LAST_ERROR="${name}: restic unlock failed during automatic crash recovery."
    return 1
  fi

  log "${name}: running post-unlock integrity check for ${repo}"
  if ! restic check --no-lock >/dev/null 2>&1; then
    BACKUP_TARGET_LAST_ERROR="${name}: post-unlock restic check failed."
    return 1
  fi

  if ! restic snapshots --json >/dev/null 2>&1; then
    BACKUP_TARGET_LAST_ERROR="${name}: repository is still not writable after unlock recovery."
    return 1
  fi

  log "${name}: automatic stale-lock recovery completed successfully."
}

date_to_epoch_days() {
  # Convert YYYY-MM-DD to epoch days (UTC) for stable arithmetic.
  local d="${1:?date required}"
  local epoch_seconds
  epoch_seconds="$(date -u -d "${d}" +%s 2>/dev/null)" || die "Invalid ISO date: ${d}"
  printf '%s
' "$(( epoch_seconds / 86400 ))"
}

epoch_days_to_yyyymmdd() {
  local days="${1:?days required}"
  local epoch_seconds
  epoch_seconds="$(( days * 86400 ))"
  date -u -d "@${epoch_seconds}" +%Y%m%d 2>/dev/null || die "Invalid epoch days: ${days}"
}

weekday_number_to_name() {
  local num="${1:?weekday number required}"
  case "${num}" in
    1) echo "mon" ;;
    2) echo "tue" ;;
    3) echo "wed" ;;
    4) echo "thu" ;;
    5) echo "fri" ;;
    6) echo "sat" ;;
    7) echo "sun" ;;
    *) die "Invalid weekday number: ${num}" ;;
  esac
}

weekday_list_contains() {
  local list="${1:?weekday list required}"
  local needle="${2:?weekday required}"
  local normalized=""

  normalized="${list,,}"
  normalized="${normalized//[[:space:]]/}"
  case ",${normalized}," in
    *",${needle},"*) return 0 ;;
    *) return 1 ;;
  esac
}

compute_cycle_id() {
  local full_weekday_list="${1:?weekday list required}"
  local today_iso=""
  local today_days=""
  local offset=""
  local candidate_days=""
  local candidate_epoch=""
  local candidate_weekday_num=""
  local candidate_weekday=""

  today_iso="$(date +%F)"
  today_days="$(date_to_epoch_days "${today_iso}")"

  for offset in 0 1 2 3 4 5 6; do
    candidate_days=$(( today_days - offset ))
    candidate_epoch=$(( candidate_days * 86400 ))
    candidate_weekday_num="$(date -u -d "@${candidate_epoch}" +%u 2>/dev/null)" || die "Failed to resolve weekday for epoch day ${candidate_days}."
    candidate_weekday="$(weekday_number_to_name "${candidate_weekday_num}")"
    if weekday_list_contains "${full_weekday_list}" "${candidate_weekday}"; then
      epoch_days_to_yyyymmdd "${candidate_days}"
      return 0
    fi
  done

  die "Unable to compute cycle id from FULL_BACKUP_WEEKDAYS value: ${full_weekday_list}"
}

repo_has_full_marker_for_cycle() {
  local repo="${1:?repo required}"
  local pw_file="${2:?password file required}"
  local mode="${3:?mode required}"
  local cycle_id="${4:?cycle id required}"
  local snapshots_json=""

  [[ -f "${repo}/config" ]] || return 1

  restic_env "${repo}" "${pw_file}"
  if ! snapshots_json="$(restic snapshots --json --no-lock 2>/dev/null)"; then
    restic_unset
    warn "Could not inspect existing snapshots for ${repo}; using penelope_kind=full for this target."
    return 1
  fi
  restic_unset

  PENELOPE_SNAPSHOTS_JSON="${snapshots_json}" python3 - "${mode}" "${cycle_id}" <<'PY_HAS_FULL_MARKER'
import json
import os
import sys

mode = sys.argv[1]
cycle_id = sys.argv[2]
try:
    snapshots = json.loads(os.environ.get("PENELOPE_SNAPSHOTS_JSON", "[]"))
except Exception:
    sys.exit(1)

for snap in snapshots:
    tags = snap.get("tags") or []
    if (
        f"penelope_mode={mode}" in tags
        and f"penelope_cycle={cycle_id}" in tags
        and "penelope_kind=full" in tags
    ):
        sys.exit(0)
sys.exit(1)
PY_HAS_FULL_MARKER
}

select_backup_kind_for_target() {
  local repo="${1:?repo required}"
  local pw_file="${2:?password file required}"
  local mode="${3:?mode required}"
  local cycle_id="${4:?cycle id required}"

  if [[ "${RUN_FORCE_FULL}" == "1" ]]; then
    echo "full"
    return 0
  fi

  if repo_has_full_marker_for_cycle "${repo}" "${pw_file}" "${mode}" "${cycle_id}"; then
    echo "incr"
  else
    echo "full"
  fi
}


apply_retention_by_cycle() {
  local keep_cycles="${1:?keep cycles required}"
  local keep_untagged_last="${2:?keep untagged last required}"

  local del_ids=""
  local helper_rc
  if del_ids="$(
    python3 - <<'PY_RESTIC_RETENTION_FILTER' "${keep_cycles}" "${keep_untagged_last}" 2>&1
import json
import subprocess
import sys

keep_cycles = int(sys.argv[1])
keep_untagged_last = int(sys.argv[2])

try:
  raw = subprocess.check_output(["restic", "snapshots", "--json"], text=True, stderr=subprocess.STDOUT)
except subprocess.CalledProcessError as exc:
  detail = (exc.output or "").strip().replace("\n", " | ")
  print(f"RETENTION_ERROR restic snapshots failed rc={exc.returncode} detail={detail or '-'}")
  sys.exit(1)

try:
  data = json.loads(raw)
except json.JSONDecodeError as exc:
  print(f"RETENTION_ERROR invalid restic snapshots JSON detail={exc}")
  sys.exit(1)

def get_tag(tags, prefix):
  for t in tags or []:
    if t.startswith(prefix):
      return t.split("=", 1)[1]
  return None

cycle_to_ids = {}
full_cycle_ids = set()
untagged = []
for s in data:
  tags = s.get("tags") or []
  cycle = get_tag(tags, "penelope_cycle=")
  kind = get_tag(tags, "penelope_kind=")
  short_id = s.get("short_id")
  if not short_id:
    continue
  if cycle:
    cycle_to_ids.setdefault(cycle, []).append(short_id)
    if kind == "full":
      full_cycle_ids.add(cycle)
  else:
    untagged.append((s.get("time") or "", short_id))

full_cycles_sorted = sorted(full_cycle_ids)
if not full_cycles_sorted:
  keep_set = set(cycle_to_ids.keys())
  delete_tagged = []
  print("RETENTION_SKIP no penelope_kind=full snapshots found; keeping all tagged snapshots")
else:
  keep_n = max(0, min(keep_cycles, len(full_cycles_sorted)))
  keep_set = set(full_cycles_sorted[-keep_n:]) if keep_n > 0 else set()
  delete_tagged = []
  for c, ids in cycle_to_ids.items():
    if c not in keep_set:
      delete_tagged.extend(ids)

print("FULL_CYCLES_FOUND", len(full_cycles_sorted))
print("KEEP_CYCLE_IDS", ",".join(sorted(keep_set)) if keep_set else "-")
print("TAGGED_SNAPSHOTS", sum(len(v) for v in cycle_to_ids.values()))
print("TAGGED_DELETE_COUNT", len(delete_tagged))

delete_untagged = []
if keep_untagged_last > 0 and untagged:
  untagged_sorted = sorted(untagged, key=lambda x: x[0])
  keep_untagged_ids = set([sid for _, sid in untagged_sorted[-keep_untagged_last:]])
  delete_untagged = [sid for _, sid in untagged_sorted if sid not in keep_untagged_ids]
  print("UNTAGGED_FOUND", len(untagged_sorted))
  print("UNTAGGED_KEEP_LAST", keep_untagged_last)
  print("UNTAGGED_DELETE_COUNT", len(delete_untagged))
else:
  print("UNTAGGED_FOUND", len(untagged))
  print("UNTAGGED_KEEP_LAST", keep_untagged_last)
  print("UNTAGGED_DELETE_COUNT", 0)

delete_all = delete_tagged + delete_untagged
print("DELETE_COUNT", len(delete_all))
print("DELETE_IDS", " ".join(delete_all))
PY_RESTIC_RETENTION_FILTER
  )"; then
    helper_rc=0
  else
    helper_rc=$?
  fi

  while read -r line; do
    [[ -n "${line}" ]] || continue
    log "Retention: ${line}"
  done <<< "${del_ids}"

  if (( helper_rc != 0 )); then
    warn "Retention helper failed (rc=${helper_rc})."
    return 1
  fi

  local ids
  ids="$(awk '/^DELETE_IDS /{sub(/^DELETE_IDS /,""); print; exit}' <<< "${del_ids}")"

  if [[ -n "${ids}" ]]; then
    log "Retention: forgetting snapshots (prune handled separately): ${ids}"
    local -a ids_argv=()
    read -r -a ids_argv <<< "${ids}"
    if ! restic forget "${ids_argv[@]}"; then
      warn "Retention: restic forget failed for snapshot set: ${ids}"
      return 1
    fi
  else
    log "Retention: nothing to delete."
  fi
}

restic_output_reports_lock_conflict() {
  local output="${1:-}"

  grep -Eiq 'repo already locked|repository is already locked|unable to create lock|lock was created at' <<< "${output}"
}

run_restic_prune_once() {
  local prune_output=""
  local prune_rc=0

  RESTIC_PRUNE_LAST_OUTPUT=""
  if prune_output="$(restic prune 2>&1)"; then
    RESTIC_PRUNE_LAST_OUTPUT="${prune_output}"
    [[ -z "${prune_output}" ]] || printf '%s\n' "${prune_output}"
    return 0
  else
    prune_rc="$?"
  fi

  RESTIC_PRUNE_LAST_OUTPUT="${prune_output}"
  [[ -z "${prune_output}" ]] || printf '%s\n' "${prune_output}"
  return "${prune_rc}"
}

maybe_prune() {
  local name="${1:?name required}"
  local enable_prune="${2:?enable prune required}"
  local repo="${3:?repo required}"
  local repo_pids=""
  local unlock_output=""

  if [[ "${enable_prune}" != "1" ]]; then
    return 0
  fi

  log "Running restic prune (enable_prune=1)"
  if run_restic_prune_once; then
    return 0
  fi

  if ! restic_output_reports_lock_conflict "${RESTIC_PRUNE_LAST_OUTPUT-}"; then
    warn "restic prune reported an error"
    return 1
  fi

  warn "restic prune reported a repository lock conflict; checking for stale-lock recovery."
  repo_pids="$(active_restic_repo_pids "${repo}" | paste -sd, -)"
  if [[ -n "${repo_pids}" ]]; then
    warn "${name}: repository appears busy during prune (pid(s): ${repo_pids}); refusing automatic unlock recovery."
    return 1
  fi

  log "${name}: no active restic process found for ${repo}; attempting controlled unlock before one prune retry."
  if unlock_output="$(restic unlock 2>&1)"; then
    [[ -z "${unlock_output}" ]] || printf '%s\n' "${unlock_output}"
  else
    [[ -z "${unlock_output}" ]] || printf '%s\n' "${unlock_output}"
    warn "${name}: restic unlock failed during prune stale-lock recovery."
    return 1
  fi

  log "${name}: retrying restic prune once after controlled unlock."
  if run_restic_prune_once; then
    log "${name}: restic prune succeeded after stale-lock recovery."
    return 0
  fi

  warn "restic prune reported an error after stale-lock recovery retry"
  return 1
}

show_latest_snapshots_or_die_on_interrupt() {
  local name="${1:?name required}"
  local snapshots_output=""
  local restic_rc=0

  log "${name}: latest snapshots:"

  if snapshots_output="$(restic snapshots --latest 10 --no-lock 2>&1)"; then
    printf '%s\n' "${snapshots_output}" | tail -n 25 || true
    return 0
  else
    restic_rc="$?"
  fi

  case "${restic_rc}" in
    130|143)
      LAST_FATAL_MESSAGE="${name}: interrupted while listing latest snapshots."
      die "${LAST_FATAL_MESSAGE}" "${restic_rc}"
      ;;
    *)
      warn "${name}: latest snapshot listing failed after successful backup (restic exit=${restic_rc}); continuing."
      if [[ -n "${snapshots_output}" ]]; then
        printf '%s\n' "${snapshots_output}" | tail -n 25 || true
      fi
      ;;
  esac
}


do_backup_one() {
  local name="${1:?name required}"
  local source="${2:?source required}"
  local repo="${3:?repo required}"
  local pw_file="${4:?pw file required}"
  local mode="${5:?mode required}"
  local kind="${6:?kind required}"
  local cycle_id="${7:?cycle id required}"
  shift 7
  local excludes=("$@")

  BACKUP_TARGET_LAST_ERROR=""
  restic_env "${repo}" "${pw_file}"

  log "=== ${name}: backup start (mode=${mode} kind=${kind} cycle=${cycle_id} repo=${repo} src=${source}) ==="

  ensure_backup_repo_not_inside_unprotected_source "${name}" "${source}" "${repo}" "${excludes[@]}"

  if [[ ! -f "${repo}/config" ]]; then
    log "${name}: repo missing, init: ${repo}"
    if ! restic init; then
      BACKUP_TARGET_LAST_ERROR="${name}: restic init failed."
      restic_unset
      return 1
    fi
    fix_repo_perms "${repo}"
  else
    if ! prepare_restic_repo_for_writes "${name}" "${repo}"; then
      restic_unset
      return 1
    fi
  fi

  if restic backup "${source}" \
      --host "${HOST_SCOPE_NAME}" \
      --tag "penelope_mode=${mode}" \
      --tag "penelope_kind=${kind}" \
      --tag "penelope_cycle=${cycle_id}" \
      "${excludes[@]}"; then
    log "${name}: backup finished OK."
  else
    BACKUP_TARGET_LAST_ERROR="${name}: backup failed."
    restic_unset
    return 1
  fi

  if [[ "${mode}" == "internal" ]]; then
    if ! apply_retention_by_cycle "${KEEP_CYCLES_INTERNAL}" "${KEEP_UNTAGGED_LAST}"; then
      BACKUP_TARGET_LAST_ERROR="${name}: retention processing failed."
      restic_unset
      return 1
    fi
  else
    if ! apply_retention_by_cycle "${KEEP_CYCLES_EXTERNAL}" "${KEEP_UNTAGGED_LAST}"; then
      BACKUP_TARGET_LAST_ERROR="${name}: retention processing failed."
      restic_unset
      return 1
    fi
  fi

  if ! maybe_prune "${name}" "${ENABLE_PRUNE}" "${repo}"; then
    BACKUP_TARGET_LAST_ERROR="${name}: prune failed."
    restic_unset
    return 1
  fi

  show_latest_snapshots_or_die_on_interrupt "${name}"

  restic_unset
}


mount_usb() {
  local uuid="${1:?uuid required}"
  local mount_base="${2:?mount base required}"

  local dev
  dev="$(usb_dev_for_uuid "${uuid}")"
  [[ -n "${dev}" ]] || die "USB UUID not found: ${uuid}"

  local fstype
  fstype="$(usb_fstype_for_dev "${dev}")"
  [[ -n "${fstype}" ]] || die "Could not determine filesystem type for ${dev} (UUID=${uuid})"

  local mnt="${mount_base}/${uuid}"
  install -d -m 0700 -o root -g root "${mnt}"

  # If the device is already mounted (e.g., by an automounter), behavior depends on FORCE_UNMOUNT_EXTERNAL:
  # - FORCE_UNMOUNT_EXTERNAL=1: take over control (unmount all existing mounts for this device,
  #   then mount at our controlled path)
  # - FORCE_UNMOUNT_EXTERNAL=0: reuse the existing mount only when the current device state is
  #   unambiguous. If multiple current mounts exist, refuse reuse instead of choosing an arbitrary
  #   target. Later auto-unmount remains conditional: Penelope only treats the current device mount
  #   state as auto-unmountable when the device has exactly one current mount and that mount is
  #   Penelope's controlled path for this UUID, with the mounted-by-us marker still present.
  local existing_mnt=""
  local existing_mounts=()
  mapfile -t existing_mounts < <(findmnt -n -o TARGET --source "${dev}" 2>/dev/null || true)
  if (( ${#existing_mounts[@]} > 0 )); then
    existing_mnt="${existing_mounts[0]}"
    local existing_mounts_display=""
    existing_mounts_display="$(printf '%s
' "${existing_mounts[@]}" | paste -sd ', ' -)"
    if [[ "${FORCE_UNMOUNT_EXTERNAL}" == "1" ]]; then
      local msg
      msg="USB ${uuid} (${dev}) already mounted at ${existing_mounts_display}."
      msg="${msg} FORCE_UNMOUNT_EXTERNAL=1 => taking over (unmounting existing mounts)."
      log "${msg}"
      unmount_all_mounts_for_dev "${dev}" || die "Failed to unmount existing mounts for ${dev} (UUID=${uuid})"
      if dev_is_mounted_anywhere "${dev}"; then
        die "USB ${uuid} (${dev}) remains mounted after takeover attempt."
      fi
    else
      if (( ${#existing_mounts[@]} > 1 )); then
        die "USB ${uuid} (${dev}) is mounted at multiple targets (${existing_mounts_display}). Refusing ambiguous reuse while FORCE_UNMOUNT_EXTERNAL=0."
      fi
      if usb_mount_is_current_penelope_managed "${uuid}" "${dev}" "${mnt}"; then
        warn "USB ${uuid} (${dev}) already mounted at ${existing_mnt}. Reusing the single current Penelope-managed controlled mount; a later auto-unmount retry remains allowed."
      else
        warn "USB ${uuid} (${dev}) already mounted at ${existing_mnt}. Reusing a non-Penelope or path-mismatched current mount; will NOT auto-unmount."
      fi
      echo "${existing_mnt}"
      return 0
    fi
  fi

  if is_mounted "${mnt}"; then
    echo "${mnt}"
    return 0
  fi

  local opts="nosuid,nodev,noexec,noatime"
  # For non-POSIX FS, enforce privacy with umask (files will appear 0700/0600).
  if [[ "${fstype}" == "exfat" || "${fstype}" == "ntfs" || "${fstype}" == "fuseblk" || "${fstype}" == "vfat" ]]; then
    opts="${opts},uid=0,gid=0,umask=${USB_FS_UMASK}"
  fi

  log "Mounting USB ${uuid} (${dev}, type=${fstype}) at ${mnt} (opts=${opts})"

  if mount -o "${opts}" "${dev}" "${mnt}"; then
    finalize_mounted_usb_by_us_or_die "${uuid}" "${dev}" "${mnt}"
    return 0
  fi

  # Fallbacks for filesystems where auto-detection can be flaky across kernels/busybox variants.
  if [[ "${fstype}" == "exfat" ]]; then
    if mount -t exfat -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      finalize_mounted_usb_by_us_or_die "${uuid}" "${dev}" "${mnt}"
      return 0
    fi
    if mount -t exfat-fuse -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      finalize_mounted_usb_by_us_or_die "${uuid}" "${dev}" "${mnt}"
      return 0
    fi
  fi

  die "Failed to mount ${dev} at ${mnt} (type=${fstype})"
}

run_backup_targets_for_base() {
  local base="${1:?base required}"
  local location="${2:?location required}"
  local cycle_id="${3:?cycle id required}"
  local label_suffix="${4:-}"
  local target=""
  local repo_path=""
  local source_path=""
  local pw_file=""
  local label=""
  local detail=""
  local target_kind=""
  local -a ok_labels=()
  local -a fail_labels=()
  local -a fail_details=()

  while IFS= read -r target; do
    repo_path="${base}/$(repo_relpath_for_target "${target}")"
    mkdir -p "${repo_path}"
  done < <(all_backup_targets)
  fix_repo_perms "${base}" || true

  while IFS= read -r target; do
    target_enabled "${target}" || continue
    repo_path="${base}/$(repo_relpath_for_target "${target}")"
    source_path="$(backup_source_for_target "${target}")"
    pw_file="$(restic_password_file_for_target "${target}")"
    label="$(backup_label_for_target "${target}")${label_suffix}"
    target_kind="$(select_backup_kind_for_target "${repo_path}" "${pw_file}" "${location}" "${cycle_id}")"

    if [[ "${target}" == "system" ]]; then
      if do_backup_one \
          "${label}" "${source_path}" "${repo_path}" "${pw_file}" \
          "${location}" "${target_kind}" "${cycle_id}" \
          --exclude=/home \
          --exclude=/_archive \
          --exclude=/_backup \
          --exclude="${USB_MOUNT_BASE}" \
          --exclude=/proc \
          --exclude=/dev \
          --exclude=/sys \
          --exclude=/run \
          --exclude=/tmp \
          --exclude=/mnt \
          --exclude=/media; then
        ok_labels+=("${label}")
      else
        detail="${BACKUP_TARGET_LAST_ERROR:-${label}: target failed.}"
        fail_labels+=("${label}")
        fail_details+=("${detail}")
        warn "${detail}"
      fi
      continue
    fi

    if do_backup_one "${label}" "${source_path}" "${repo_path}" "${pw_file}" "${location}" "${target_kind}" "${cycle_id}"; then
      ok_labels+=("${label}")
    else
      detail="${BACKUP_TARGET_LAST_ERROR:-${label}: target failed.}"
      fail_labels+=("${label}")
      fail_details+=("${detail}")
      warn "${detail}"
    fi
  done < <(all_backup_targets)

  if (( ${#ok_labels[@]} > 0 )); then
    log "Backup target summary: succeeded: $(join_by '; ' "${ok_labels[@]}")"
  fi
  if (( ${#fail_labels[@]} > 0 )); then
    log "Backup target summary: failed: $(join_by '; ' "${fail_details[@]}")"
    die "Backup target failure(s): $(join_by '; ' "${fail_labels[@]}")"
  fi
}

list_backup_snapshots_for_base() {
  local base="${1:?base required}"
  local mode="${2:?mode required}"
  local target=""
  local repo_path=""
  local pw_file=""
  local shown=0
  local failed=0

  printf 'Penelope backup snapshots\n'
  printf 'Mode: %s\n' "${mode}"
  printf 'Host scope: %s\n' "${HOST_SCOPE_NAME}"
  if [[ "${mode}" == "external" ]]; then
    printf 'USB UUID: %s\n' "${RUN_UUID}"
    printf 'DISK_NAME: %s\n' "${RUN_DISK_NAME}"
  fi
  printf 'Repository base: %s\n' "${base}"
  printf '\n'
  printf 'Penelope tags: penelope_kind=full marks a cycle full marker; penelope_kind=incr marks a later snapshot in that configured cycle.\n'
  printf 'Restic still stores deduplicating snapshots; full/incr are Penelope retention-cycle tags.\n'

  while IFS= read -r target; do
    target_enabled "${target}" || continue
    shown=1
    repo_path="${base}/$(repo_relpath_for_target "${target}")"
    pw_file="$(restic_password_file_for_target "${target}")"

    printf '\n== %s ==\n' "${target}"
    printf 'Repository: %s\n' "${repo_path}"
    if [[ ! -d "${repo_path}" ]]; then
      printf 'ERROR: repository directory is missing: %s\n' "${repo_path}" >&2
      failed=1
      continue
    fi

    restic_env "${repo_path}" "${pw_file}"
    if ! restic snapshots --no-lock; then
      printf 'ERROR: failed to list snapshots for target %s.\n' "${target}" >&2
      failed=1
    fi
    restic_unset
  done < <(all_backup_targets)

  if (( shown == 0 )); then
    printf 'ERROR: no enabled backup targets selected by --targets=%s.\n' "${RUN_TARGETS}" >&2
    return 1
  fi
  return "${failed}"
}

cleanup_external_mount_after_list() {
  local uuid="${RUN_UUID:?RUN_UUID required}"
  local mnt="${RUN_MOUNT_PATH:?RUN_MOUNT_PATH required}"
  local dev=""

  dev="$(usb_dev_for_uuid "${uuid}" || true)"
  if [[ -z "${dev}" ]]; then
    warn "Could not resolve USB block device for UUID=${uuid} during external list cleanup; remove only after manual inspection."
    return 1
  fi

  if [[ "${FORCE_UNMOUNT_EXTERNAL}" == "1" ]]; then
    if is_mounted "${mnt}"; then
      log "FORCE_UNMOUNT_EXTERNAL=1 => unmounting ${mnt} after backup snapshot list (UUID=${uuid})"
      sync || true
      if ! umount "${mnt}"; then
        warn "Failed to unmount ${mnt} after backup snapshot list."
        return 1
      fi
      usb_clear_mounted_by_us "${uuid}"
    fi
  elif usb_mount_is_current_penelope_managed "${uuid}" "${dev}" "${USB_MOUNT_BASE}/${uuid}"; then
    log "Unmounting ${mnt} after backup snapshot list"
    sync || true
    if ! umount "${mnt}"; then
      warn "Failed to unmount ${mnt} after backup snapshot list."
      return 1
    fi
    usb_clear_mounted_by_us "${uuid}"
  else
    log "Not unmounting ${mnt} after backup snapshot list (current device mount state is not exactly the single penelope-managed controlled path)."
  fi

  EXTERNAL_SAFE_TO_REMOVE="1"
  settle_external_device_unmounted_or_hold "${uuid}" "${dev}"
}

run_list_command() {
  local uuid=""
  local mnt=""
  local rc=0

  ensure_expected_penelope_mount_layout "continue"

  case "${RUN_MODE}" in
    internal)
      if internal_backup_run_is_active_runtime; then
        die "An internal backup is active; refusing to list internal snapshots while that run may still be changing the repositories."
      fi
      list_backup_snapshots_for_base "/_backup/${HOST_SCOPE_NAME}" "internal"
      ;;
    external)
      uuid="${RUN_UUID:?RUN_UUID required}"
      RUN_DISK_NAME="${RUN_DISK_NAME:-$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")}"
      PROCESSED_UUIDS="${uuid}"
      set_external_signal_paths
      mnt="$(mount_usb "${uuid}" "${USB_MOUNT_BASE}")"
      RUN_MOUNT_PATH="${mnt}"
      if ! list_backup_snapshots_for_base "${mnt}/${HOST_SCOPE_NAME}" "external"; then
        rc=1
      fi
      if ! cleanup_external_mount_after_list; then
        rc=1
      fi
      if [[ "${EXTERNAL_SAFE_TO_REMOVE}" == "1" && "${rc}" -eq 0 ]]; then
        write_ready_file "${uuid}" || warn "Failed to publish READY after external backup snapshot list."
      elif [[ "${EXTERNAL_SAFE_TO_REMOVE}" != "1" ]]; then
        write_do_not_remove_file \
          "Backup snapshot listing finished, but the USB backup drive is still mounted or safe-removal cleanup did not complete. Do NOT remove it. Contact the operator." \
          || warn "Failed to publish HOLD after unsafe external backup snapshot list."
      fi
      return "${rc}"
      ;;
    *)
      die "Unknown list mode: ${RUN_MODE}. Use internal or external."
      ;;
  esac
}


run_internal() {
  ensure_expected_penelope_mount_layout "smoke test"

  local cycle_id
  cycle_id="$(compute_cycle_id "${FULL_BACKUP_WEEKDAYS_INTERNAL}")"
  RUN_CYCLE_ID="${cycle_id}"
  if [[ "${RUN_FORCE_FULL}" == "1" ]]; then
    RUN_KIND="full"
  else
    RUN_KIND="auto"
  fi

  local base="/_backup/${HOST_SCOPE_NAME}"
  run_backup_targets_for_base "${base}" "internal" "${cycle_id}"

  log "INTERNAL backup done."
}

run_external() {
  ensure_expected_penelope_mount_layout "continue"
  local cycle_id
  cycle_id="$(compute_cycle_id "${FULL_BACKUP_WEEKDAYS_EXTERNAL}")"
  RUN_CYCLE_ID="${cycle_id}"
  if [[ "${RUN_FORCE_FULL}" == "1" ]]; then
    RUN_KIND="full"
  else
    RUN_KIND="auto"
  fi

  local uuid="${RUN_UUID}"
  if [[ -z "${uuid}" ]]; then
    uuid="$(resolve_external_uuid)"
    RUN_UUID="${uuid}"
  fi
  [[ -n "${uuid}" ]] || die "No USB UUID selected."

  PROCESSED_UUIDS="${uuid}"

  local mnt
  mnt="$(mount_usb "${uuid}" "${USB_MOUNT_BASE}")"

  RUN_DISK_NAME="${RUN_DISK_NAME:-$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")}"
  set_external_signal_paths

  usb_lock_acquire "${mnt}" "${uuid}" "${RUN_DISK_NAME}" "${RUN_TARGETS}"
  usb_lock_heartbeat_start "${mnt}"

  # A later external run for the same allow-listed disk supersedes any earlier
  # per-disk READY/REATTACH_AND_WAIT/HOLD/RUNNING dashboard truth for that same disk
  # only once the current run has really started. Delay RUNNING/started
  # publication until the disk is mounted and the per-disk USB lock/heartbeat
  # is active, so pre-start mount/lock failures do not erase the previous
  # per-disk dashboard truth.
  refresh_internal_backup_dashboard_state || warn_dashboard_publish_failure "refresh internal Backup-Dashboard state before external run"
  require_external_dashboard_action "write RUNNING signal" write_running_file "${uuid}"
  if ! write_backup_dashboard_json "started" "" "${uuid}"; then
    warn "Backup-Dashboard update failed: write external started status JSON"
  fi
  RUN_STARTED="1"
  cron_note "penelope-backup external STARTED"
  write_backup_dashboard_event "started" "" || warn_dashboard_publish_failure "append events-external.log for started"

  local base="${mnt}/${HOST_SCOPE_NAME}"

  run_backup_targets_for_base "${base}" "external" "${cycle_id}" "-USB-${uuid}"
  usb_lock_heartbeat_assert_running

  usb_lock_heartbeat_stop
  usb_lock_release "${mnt}"

  RUN_MOUNT_PATH="${mnt}"
  EXTERNAL_SAFE_TO_REMOVE="0"
  log "USB backup done for ${uuid}."

  log "EXTERNAL backup done."
}

auto_post_backup_verify_enabled() {
  [[ "${PENELOPE_BACKUP_SKIP_AUTO_VERIFY:-0}" != "1" ]] || return 1
  [[ -x "/usr/local/sbin/penelope-backup-verify.sh" ]] || return 1
  return 0
}

run_post_backup_verify_if_enabled() {
  local mode="${1:?mode required}"

  auto_post_backup_verify_enabled || return 0

  case "${mode}" in
    internal)
      log "Automatic post-backup verify: internal"
      TARGET_HOST="${TARGET_HOST}" \
      HOST_SCOPE_NAME="${HOST_SCOPE_NAME}" \
      PENELOPE_BACKUP_VERIFY_SKIP_RUNTIME_SIGNALS=1 \
        /usr/local/sbin/penelope-backup-verify.sh --mode internal
      ;;
    external)
      [[ -n "${RUN_UUID:-}" ]] || die "Automatic external post-backup verify requires RUN_UUID."
      log "Automatic post-backup verify: external UUID=${RUN_UUID}"
      TARGET_HOST="${TARGET_HOST}" \
      HOST_SCOPE_NAME="${HOST_SCOPE_NAME}" \
      PENELOPE_BACKUP_VERIFY_SKIP_RUNTIME_SIGNALS=1 \
        /usr/local/sbin/penelope-backup-verify.sh --mode external --uuid "${RUN_UUID}"
      ;;
    *)
      die "Unknown post-backup verify mode: ${mode}"
      ;;
  esac
}

mounted_targets_for_dev_display() {
  local dev="${1:?device required}"
  local targets=""
  targets="$(findmnt -rn -o TARGET --source "${dev}" 2>/dev/null || true)"
  [[ -n "${targets}" ]] || return 0
  printf '%s
' "${targets}" | paste -sd ', ' -
}

settle_external_device_unmounted_or_hold() {
  local uuid="${1:?uuid required}"
  local dev="${2:?device required}"
  local settle_seconds="10"
  local poll_seconds="1"
  local elapsed=0
  local mounted_at=""

  while (( elapsed <= settle_seconds )); do
    if dev_is_mounted_anywhere "${dev}"; then
      mounted_at="$(mounted_targets_for_dev_display "${dev}")"
      if [[ "${FORCE_UNMOUNT_EXTERNAL}" != "1" ]]; then
        warn "USB ${uuid} (${dev}) is still mounted at ${mounted_at}; FORCE_UNMOUNT_EXTERNAL=0 so it is not safe to remove yet."
        EXTERNAL_SAFE_TO_REMOVE="0"
        return 0
      fi
      log "USB ${uuid} (${dev}) is mounted at ${mounted_at} after Penelope release; FORCE_UNMOUNT_EXTERNAL=1 => unmounting before READY."
      sync || true
      if ! unmount_all_mounts_for_dev "${dev}"; then
        mounted_at="$(mounted_targets_for_dev_display "${dev}")"
        warn "Failed to unmount USB ${uuid} (${dev}) from ${mounted_at:-unknown mountpoint}; remove only after manual unmount."
        EXTERNAL_SAFE_TO_REMOVE="0"
        return 0
      fi
      usb_clear_mounted_by_us "${uuid}"
    fi

    (( elapsed >= settle_seconds )) && break
    sleep "${poll_seconds}"
    (( elapsed += poll_seconds ))
  done

  if dev_is_mounted_anywhere "${dev}"; then
    mounted_at="$(mounted_targets_for_dev_display "${dev}")"
    warn "USB ${uuid} (${dev}) is still mounted at ${mounted_at:-unknown mountpoint} after ${settle_seconds}s release settle; not safe to remove."
    EXTERNAL_SAFE_TO_REMOVE="0"
  else
    log "USB ${uuid} (${dev}) final release check passed: no mount remains; READY may be published."
  fi
}

finalize_external_mount_after_verify() {
  local uuid="${RUN_UUID:?RUN_UUID required}"
  local mnt="${RUN_MOUNT_PATH:?RUN_MOUNT_PATH required}"
  local dev=""

  if [[ "${PENELOPE_BACKUP_VERIFY_HOLD_MOUNT:-0}" == "1" ]]; then
    log "PENELOPE_BACKUP_VERIFY_HOLD_MOUNT=1 => keeping ${mnt} mounted for immediate verify (UUID=${uuid})"
    EXTERNAL_SAFE_TO_REMOVE="0"
    return 0
  fi

  EXTERNAL_SAFE_TO_REMOVE="1"
  dev="$(usb_dev_for_uuid "${uuid}")"
  if [[ -z "${dev}" ]]; then
    warn "Could not resolve USB block device for UUID=${uuid} during final release check; remove only after manual inspection."
    EXTERNAL_SAFE_TO_REMOVE="0"
    return 0
  fi

  if [[ "${FORCE_UNMOUNT_EXTERNAL}" == "1" ]]; then
    if is_mounted "${mnt}"; then
      log "FORCE_UNMOUNT_EXTERNAL=1 => unmounting ${mnt} (UUID=${uuid})"
      sync || true
      if ! umount "${mnt}"; then
        warn "Failed to unmount ${mnt} (remove only after unmount)."
        EXTERNAL_SAFE_TO_REMOVE="0"
      else
        usb_clear_mounted_by_us "${uuid}"
      fi
    fi
  else
    if usb_mount_is_current_penelope_managed "${uuid}" "${dev}" "${USB_MOUNT_BASE}/${uuid}"; then
      log "Unmounting ${mnt}"
      sync || true
      if ! umount "${mnt}"; then
        warn "Failed to unmount ${mnt} (remove only after unmount)."
        EXTERNAL_SAFE_TO_REMOVE="0"
      else
        usb_clear_mounted_by_us "${uuid}"
      fi
    else
      log "Not unmounting ${mnt} (current device mount state is not exactly the single penelope-managed controlled path)."
    fi
  fi

  settle_external_device_unmounted_or_hold "${uuid}" "${dev}"
}

cleanup_external_mount_after_failed_run_if_idle() {
  local uuid="${RUN_UUID:-}"
  local mnt="${RUN_MOUNT_PATH:-}"
  local dev=""
  local mounted_at=""

  EXTERNAL_SAFE_TO_REMOVE="0"
  [[ "${RUN_MODE:-}" == "external" ]] || return 0
  [[ -n "${uuid}" ]] || return 0
  [[ -n "${mnt}" ]] || mnt="${USB_MOUNT_BASE}/${uuid}"

  dev="$(usb_dev_for_uuid "${uuid}" 2>/dev/null || true)"
  if [[ -z "${dev}" ]]; then
    warn "Could not resolve USB block device for UUID ${uuid} during failed external cleanup. Manual mount inspection required."
    return 1
  fi

  if external_restic_processes_are_active "${uuid}"; then
    warn "Relevant restic process remains active for UUID ${uuid}; leaving external mount state unchanged after failed run."
    return 1
  fi

  if ! dev_is_mounted_anywhere "${dev}"; then
    return 0
  fi

  mounted_at="$(mounted_targets_for_dev_display "${dev}")"
  if [[ "${FORCE_UNMOUNT_EXTERNAL}" != "1" ]]; then
    warn "External backup failed and USB ${uuid} (${dev}) is still mounted at ${mounted_at}; FORCE_UNMOUNT_EXTERNAL=0 so it was not unmounted."
    return 0
  fi

  log "External backup failed or was canceled; no relevant restic process remains. FORCE_UNMOUNT_EXTERNAL=1 => unmounting ${dev} from ${mounted_at:-current mountpoint}."
  sync || true
  if ! unmount_all_mounts_for_dev "${dev}"; then
    mounted_at="$(mounted_targets_for_dev_display "${dev}")"
    warn "Failed to unmount USB ${uuid} (${dev}) after failed external run; still mounted at ${mounted_at:-unknown mountpoint}."
    return 1
  fi
  usb_clear_mounted_by_us "${uuid}"
}

on_exit() {
  local rc=$?
  local dashboard_publish_failed="${DASHBOARD_PUBLISH_FAILED:-0}"
  local had_dashboard_publish_failure="${dashboard_publish_failed}"

  if ! usb_lock_heartbeat_stop; then
    warn "Failed to stop USB lock heartbeat during exit cleanup."
    dashboard_publish_failed=1
  fi

  if [[ "${rc}" -ne 0 ]]; then
    # Failure-exit cleanup should be visible when it cannot complete.
    if [[ "${USB_LOCK_OWNED:-0}" == "1" && -n "${USB_LOCK_FILE:-}" ]]; then
      if ! rm -f "${USB_LOCK_FILE}" 2>/dev/null; then
        warn "Failed to remove owned USB lock file during failure exit cleanup: ${USB_LOCK_FILE}"
        dashboard_publish_failed=1
      fi
    fi

    local external_contract_ready=0
    local external_started=0

    if [[ "${RUN_MODE:-}" == "external" && "${RUN_STARTED:-0}" == "1" ]]; then
      external_started=1
      EXTERNAL_SAFE_TO_REMOVE="0"
      cleanup_external_mount_after_failed_run_if_idle || dashboard_publish_failed=1
      if external_dashboard_contract_ready; then
        external_contract_ready=1
      fi
    fi

    local fail_msg="${LAST_FATAL_MESSAGE:-exit=${rc}}"
    publish_failure_state_once "${fail_msg}" || dashboard_publish_failed=1
    if [[ "${RUN_MODE:-}" == "internal" ]]; then
      RUN_FINISHED_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
      write_internal_error_file_after_failure "${fail_msg}" || {
        dashboard_publish_failed=1
        warn_dashboard_publish_failure "write INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt after internal failure"
      }
    fi
    if [[ "${RUN_MODE:-}" == "external" ]]; then
      if (( external_started == 1 )); then
        if (( external_contract_ready == 1 )); then
          if [[ -n "${RUN_UUID:-}" ]] && ! usb_dev_for_uuid "${RUN_UUID}" >/dev/null 2>&1; then
            write_reattach_and_wait_file "The USB backup drive is no longer attached. Reattach the same disk and wait for the next retry." || dashboard_publish_failed=1
          else
            write_do_not_remove_file "Backup did not complete successfully. Do NOT remove the USB backup drive. Contact the operator." || dashboard_publish_failed=1
          fi
        else
          warn "External Backup-Dashboard cleanup skipped because the external dashboard contract was not fully initialized yet."
        fi
      else
        warn "External per-disk Backup-Dashboard cleanup skipped because this external run did not reach RUNNING publication yet."
      fi
      refresh_internal_backup_dashboard_state || dashboard_publish_failed=1
    fi
    if (( dashboard_publish_failed )); then
      >&2 printf '[%s] WARN: %s %s and %s.\n' \
        "$(ts)" \
        "Backup-Dashboard failure handling was incomplete; inspect" \
        "${BACKUP_DASHBOARD_DIR:-/var/lib/penelope/backup-dashboard}" \
        "${BACKUP_LOG:-/var/log/${HOST_SCOPE_NAME}/backup/backup.log}"
      if [[ -n "${RUN_MODE:-}" ]]; then
        cron_note "penelope-backup ${RUN_MODE} FAILED (dashboard publish incomplete; inspect backup.log)"
      fi
    fi
  fi

  clear_backup_run_success_finalized_marker || dashboard_publish_failed=1
  clear_backup_run_uuid_marker || dashboard_publish_failed=1
  clear_backup_run_mode_marker || dashboard_publish_failed=1
  release_uuid_lock || dashboard_publish_failed=1
  release_backup_run_lock || dashboard_publish_failed=1

  if (( dashboard_publish_failed )) && (( had_dashboard_publish_failure == 0 )); then
    >&2 printf '[%s] WARN: %s %s and %s.\n' \
      "$(ts)" \
      "Backup-Dashboard cleanup was incomplete during exit handling; inspect" \
      "${BACKUP_DASHBOARD_DIR:-/var/lib/penelope/backup-dashboard}" \
      "${BACKUP_LOG:-/var/log/${HOST_SCOPE_NAME}/backup/backup.log}"
    if [[ -n "${RUN_MODE:-}" ]]; then
      if [[ "${rc}" -ne 0 ]]; then
        cron_note "penelope-backup ${RUN_MODE} FAILED (cleanup incomplete; inspect backup.log)"
      else
        cron_note "penelope-backup ${RUN_MODE} SUCCESS (cleanup incomplete; inspect backup.log)"
      fi
    fi
  fi
}

release_early_startup_locks() {
  release_uuid_lock || warn "Failed to release early USB UUID lock during startup cleanup."
  release_backup_run_lock || warn "Failed to release early backup run lock during startup cleanup."
}

main() {
  parse_cli "$@"

  require_root "sudo $0"
  require_cmd_many restic python3 mountpoint findmnt blkid

  local mode="${RUN_MODE}"
  local uuid_arg="${RUN_UUID}"
  if [[ "${mode}" == "internal" && "${RUN_FORCE}" == "1" ]]; then
    warn "--force is only meaningful for external mode; ignoring for internal."
    RUN_FORCE="0"
  fi
  RUN_ID="$(new_run_id)"
  export RUN_MODE RUN_UUID RUN_TARGETS RUN_FORCE RUN_FORCE_FULL RUN_CANCEL RUN_LIST RUN_ID RUN_DISK_NAME RUN_KIND RUN_CYCLE_ID EXTERNAL_SAFE_TO_REMOVE EXTERNAL_SUCCESS_FINALIZED

  # Install an early lock-only EXIT trap before acquiring any runtime locks.
  # This prevents leaked UUID/runtime run locks if a later lock acquisition fails
  # before the full on_exit handler is armed.
  trap 'release_early_startup_locks' EXIT

  # If USB disk setup or USB password rotation is in progress, do not start an
  # external backup. This avoids accidental external runs while a disk is being
  # partitioned/formatted/registered or while external repo passwords are being
  # rotated. The guard applies to both udev-triggered and manually started
  # external runs.
  local setup_lock="/run/penelope/usb-disk-setup.lock.d"
  local rotation_lock="/run/penelope/usb-password-rotation.lock.d"
  if [[ "${mode}" == "external" ]]; then
    if pid_dir_lock_is_active "${setup_lock}" "USB disk setup"; then
      exit 0
    fi
    if pid_dir_lock_is_active "${rotation_lock}" "USB password rotation"; then
      exit 0
    fi
  fi

  # External UUID handling:
  # - Validate the USB allow-list before consuming it for UUID matching or selection.
  # - If a UUID was provided (udev/systemd trigger), silently ignore unknown UUIDs.
  # - If no UUID was provided, select exactly one present allowlisted disk (TTY: interactive; non-TTY: abort).
  if [[ "${mode}" == "external" ]]; then
    require_usb_allowlist_file "${USB_CONF}"
    validate_usb_allowlist_disk_names "${USB_CONF}"
    if [[ -n "${uuid_arg}" && -n "${RUN_DISK_NAME_SELECTOR}" ]]; then
      die "Use either --uuid <UUID> or --disk-name <DISK_NAME>, not both."
    fi
    if [[ -n "${RUN_DISK_NAME_SELECTOR}" ]]; then
      uuid_arg="$(require_usb_allowlist_uuid_for_disk_name "${USB_CONF}" "${RUN_DISK_NAME_SELECTOR}")"
      RUN_UUID="${uuid_arg}"
    elif [[ -n "${uuid_arg}" ]]; then
      if ! uuid_in_allowlist "${USB_CONF}" "${uuid_arg}"; then
        exit 0
      fi
    else
      uuid_arg="$(resolve_external_uuid)"
      RUN_UUID="${uuid_arg}"
    fi
    RUN_DISK_NAME="$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid_arg}")"
    if [[ "${RUN_CANCEL}" != "1" ]]; then
      lock_usb_uuid "${uuid_arg}"
    fi
  fi

  if [[ "${RUN_LIST}" == "1" ]]; then
    load_conf
    validate_loaded_backup_runtime_controls_from_env
    run_list_command
    exit $?
  fi

  if [[ "${RUN_CANCEL}" == "1" ]]; then
    load_conf
    validate_loaded_backup_runtime_controls_from_env
    run_cancel_command
    exit $?
  fi

  configure_backup_run_lock_paths "${mode}" "${uuid_arg}"
  if [[ "${mode}" == "external" ]]; then
    if internal_backup_run_is_active_runtime; then
      die "Another internal backup seems to be running. External backups are serialized against internal runs; different allow-listed USB disks may run in parallel."
    fi
  else
    if any_external_backup_run_is_active_runtime; then
      die "Another external backup seems to be running. Internal backups are serialized against active external runs."
    fi
  fi

  acquire_backup_run_lock
  trap on_exit EXIT
  write_backup_run_mode_marker
  if [[ "${mode}" == "external" ]]; then
    write_backup_run_uuid_marker "${uuid_arg}"
  else
    clear_backup_run_uuid_marker
  fi

  load_conf
  validate_usb_lock_timing_config
  validate_loaded_backup_runtime_controls_from_env

  READY_FILE=""
  DO_NOT_REMOVE_FILE=""
  RUNNING_FILE=""
  load_internal_backup_dashboard_file_paths "${BACKUP_DASHBOARD_DIR}"
  if [[ "${mode}" == "external" ]]; then
    validate_usb_allowlist_disk_names "${USB_CONF}"
    RUN_UUID="${uuid_arg}"
    RUN_DISK_NAME="$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${RUN_UUID}")"
    set_external_signal_paths
  fi

  ensure_log

  if [[ "${mode}" != "external" ]]; then
    cron_note "penelope-backup ${mode} STARTED"
    RUN_STARTED="1"
    write_backup_dashboard_event "started" "" || warn_dashboard_publish_failure "append events-${mode}.log for started"
    local internal_started_json_written="0"
    if write_backup_dashboard_json "started" "" "${uuid_arg}"; then
      internal_started_json_written="1"
    else
      warn "Backup-Dashboard update failed: write last-internal.json started status"
    fi
    if ! write_internal_running_file; then
      warn_dashboard_publish_failure "write INTERNAL_BACKUP_RUNNING.txt"
      if [[ "${internal_started_json_written}" == "1" ]]; then
        clear_backup_dashboard_files "${LAST_INTERNAL_JSON:-}" ||           warn_dashboard_publish_failure "clear last-internal.json started status after running marker failure"
        warn "Rolled back last-internal.json started status because INTERNAL_BACKUP_RUNNING.txt was not written."
      else
        warn "INTERNAL_BACKUP_RUNNING.txt was not written, and no last-internal.json started status had been published to roll back."
      fi
    fi
  fi

  case "${mode}" in
    internal) run_internal ;;
    external) run_external ;;
    *)
      die "Unknown mode: ${mode}. Use: internal | external [UUID]"
      ;;
  esac

  local dashboard_publish_failed="${DASHBOARD_PUBLISH_FAILED:-0}"

  if [[ "${mode}" == "internal" ]]; then
    local internal_success_json_ready="0"
    run_post_backup_verify_if_enabled "internal"
    sync_recovery_bundle_to_base "/_backup/${HOST_SCOPE_NAME}" "internal"

    if write_backup_dashboard_json "success" "" "${PROCESSED_UUIDS:-${uuid_arg}}"; then
      internal_success_json_ready="1"
    else
      warn "Backup-Dashboard primary last-internal.json success write failed; attempting fallback writer."
      if write_internal_last_status_json_fallback "success" "" "${PROCESSED_UUIDS:-${uuid_arg}}"; then
        internal_success_json_ready="1"
        warn "Recovered internal last-internal.json success status via fallback writer."
      else
        dashboard_publish_failed=1
        warn_dashboard_publish_failure "write last-internal.json success status"
        warn_dashboard_publish_failure "write fallback last-internal.json success status"
      fi
    fi
    RUN_FINISHED_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
    if [[ "${internal_success_json_ready}" == "1" ]]; then
      write_internal_ok_file_after_success || {
        dashboard_publish_failed=1
        warn_dashboard_publish_failure "write INTERNAL_BACKUP_OK.txt after internal success"
      }
    else
      warn "Skipping internal Backup-Dashboard refresh after internal success because no success status JSON could be written."
      if ! write_internal_error_file_after_success_status_failure; then
        dashboard_publish_failed=1
        warn_dashboard_publish_failure "write INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt after internal success status publish failure"
      fi
    fi
  fi
  if [[ "${mode}" == "external" ]]; then
    run_post_backup_verify_if_enabled "external"
    sync_recovery_bundle_to_base "${RUN_MOUNT_PATH}/${HOST_SCOPE_NAME}" "external uuid=${RUN_UUID}"

    if ! write_usb_success_marker "${RUN_MOUNT_PATH}"; then
      warn "Failed to write USB success marker on ${RUN_MOUNT_PATH}; continuing with dashboard-led success handling."
    fi

    finalize_external_mount_after_verify
    EXTERNAL_SUCCESS_FINALIZED="1"
    write_backup_run_success_finalized_marker

    if ! write_backup_dashboard_json "success" "" "${PROCESSED_UUIDS:-${uuid_arg}}"; then
      dashboard_publish_failed=1
      warn_dashboard_publish_failure "write external success status JSON"
    fi

    if [[ "${EXTERNAL_SAFE_TO_REMOVE}" == "1" ]]; then
      require_external_dashboard_action "write READY signal" write_ready_file "${PROCESSED_UUIDS:-${uuid_arg}}"
    else
      warn "External backup finished, but a USB device is still mounted or verify requires operator attention. Per-disk USB_BACKUP_READY_TO_REMOVE_<disk>.txt will NOT be written."
      require_external_dashboard_action \
        "write HOLD signal after unsafe external completion" \
        write_do_not_remove_file \
        "Backup finished, but the USB backup drive is still mounted or verify requires operator attention. Do NOT remove it. Contact the operator."
    fi
    refresh_internal_backup_dashboard_state || {
      dashboard_publish_failed=1
      warn_dashboard_publish_failure "refresh internal Backup-Dashboard state after external success"
    }
  fi

  write_backup_dashboard_event "success" "" || {
    dashboard_publish_failed=1
    warn_dashboard_publish_failure "append events-${mode}.log for success"
  }
  if (( dashboard_publish_failed )); then
    cron_note "penelope-backup ${mode} SUCCESS (dashboard publish incomplete; inspect backup.log)"
  else
    cron_note "penelope-backup ${mode} SUCCESS"
  fi
}

trap 'backup_runner_on_signal INT' INT
trap 'backup_runner_on_signal TERM' TERM

main "$@"

EOF_BACKUP_RUNNER_SCRIPT
  } | install_file_from_heredoc "${runner_path}" 0750 root root "runner"
}

install_backup_verify() {
  local tool_path="/usr/local/sbin/penelope-backup-verify.sh"
  local legacy_path="/usr/local/sbin/penelope-backup-smoke-test.sh"

  log "Installing backup verify tool: ${tool_path}"
  {
    cat <<'EOF_BACKUP_VERIFY_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-backup-verify.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
#
# Backup verification helper for the internal backup domain:
# - writes fresh per-target sentinel files
# - runs one internal backup now
# - verifies Backup-Dashboard internal runtime signals after that run
# - verifies restic repository integrity for system/home/_archive
# - restores the fresh sentinel files from the latest snapshots and compares them
# - restores /etc/hostname from the latest system snapshot as a small real restore probe
# - publishes a structured verify result to the Backup-Dashboard
#
# Usage:
#   sudo /usr/local/sbin/penelope-backup-verify.sh
#
EOF_BACKUP_VERIFY_SCRIPT
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_backup_dashboard_file_helpers
    emit_generated_usb_allowlist_validation_helpers
    emit_generated_backup_runner_target_repo_helpers
    cat <<'EOF_BACKUP_VERIFY_SCRIPT'

backup_verify_usage() {
  cat <<'EOF_BACKUP_VERIFY_USAGE'
Usage:
  sudo /usr/local/sbin/penelope-backup-verify.sh [--mode internal] [--run-now]
  sudo /usr/local/sbin/penelope-backup-verify.sh --mode external [--uuid <UUID>|--disk-name <DISK_NAME>] [--run-now]

Purpose:
  Verify the latest internal or external backup state.

Default behavior:
  - read-only verify of the latest available snapshot set
  - repository integrity check(s)
  - restore probe for /etc/hostname from the latest system snapshot

Optional:
  --run-now
      Write fresh verify sentinels, run a new backup now for the selected mode,
      then verify the freshly written snapshot set.
  --disk-name <DISK_NAME>
      External mode only. Resolve the registered disk through the USB allow-list;
      filesystem labels are not scanned or trusted as authorization.
EOF_BACKUP_VERIFY_USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  backup_verify_usage
  exit 0
fi

readonly BACKUP_CONF="/etc/${PROJECT}/backup.conf"
readonly USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
[[ -f "${BACKUP_CONF}" ]] || die "Missing config: ${BACKUP_CONF}"
unset \
  INTERNAL_BACKUP_STALE_AFTER_HOURS \
  FORCE_UNMOUNT_EXTERNAL \
  WRITE_USB_SUCCESS_MARKER \
  ENABLE_PRUNE \
  KEEP_CYCLES_INTERNAL \
  KEEP_CYCLES_EXTERNAL \
  KEEP_UNTAGGED_LAST \
  USB_MOUNT_BASE \
  USB_FS_UMASK \
  HOST_SCOPE_NAME \
  BACKUP_DASHBOARD_DIR \
  LOG_DIR \
  BACKUP_LOG
# shellcheck source=/dev/null
source "${BACKUP_CONF}"
load_backup_runtime_context_from_conf "${BACKUP_CONF}" "/var/lib/penelope/backup-dashboard"
validate_loaded_backup_runtime_controls_from_env

readonly TARGET_HOST
readonly HOST_SCOPE_NAME
readonly LOG_DIR
readonly BACKUP_LOG
readonly BACKUP_DASHBOARD_DIR
readonly USB_MOUNT_BASE
readonly FORCE_UNMOUNT_EXTERNAL
readonly VERIFY_LOG="${LOG_DIR}/verify.log"
readonly VERIFY_STATUS_JSON="${BACKUP_DASHBOARD_DIR}/last-verify.json"
readonly VERIFY_RUNNING_FILE="${BACKUP_DASHBOARD_DIR}/BACKUP_VERIFY_RUNNING.txt"
readonly VERIFY_OK_FILE="${BACKUP_DASHBOARD_DIR}/BACKUP_VERIFY_OK.txt"
readonly VERIFY_ERROR_FILE="${BACKUP_DASHBOARD_DIR}/BACKUP_VERIFY_ERROR_CONTACT_OPERATOR.txt"

VERIFY_MODE="internal"
VERIFY_RUN_NOW="0"
VERIFY_UUID=""
VERIFY_DISK_NAME=""
VERIFY_DISK_NAME_SELECTOR=""
VERIFY_RUN_ID=""
VERIFY_START_ISO=""
VERIFY_FAILURE_PUBLISHED="0"
VERIFY_SYSTEM_SNAPSHOT_ID=""
VERIFY_HOME_SNAPSHOT_ID=""
VERIFY_ARCHIVE_SNAPSHOT_ID=""
VERIFY_EXTERNAL_HELD_MOUNT="0"
VERIFY_EXTERNAL_REPO_BASE=""
VERIFY_SKIP_RUNTIME_SIGNALS="${PENELOPE_BACKUP_VERIFY_SKIP_RUNTIME_SIGNALS:-0}"

read_usb_allowlist_name_for_uuid() {
  local conf_path="${1:?allowlist path required}"
  local uuid="${2:?uuid required}"
  [[ -f "${conf_path}" ]] || return 0
  local raw entry_uuid name
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    name="${raw#"${entry_uuid}"}"
    name="${name#"${name%%[![:space:]]*}"}"
    if [[ "${entry_uuid}" == "${uuid}" ]]; then
      printf '%s
' "${name}"
      return 0
    fi
  done < "${conf_path}"
}

require_usb_allowlist_name_for_uuid() {
  local conf_path="${1:?allowlist path required}"
  local uuid="${2:?uuid required}"
  local name=""
  name="$(read_usb_allowlist_name_for_uuid "${conf_path}" "${uuid}")"
  [[ -n "${name}" ]] || die "Allow-list entry for UUID ${uuid} must define a non-empty DISK_NAME in ${conf_path}."
  printf '%s
' "${name}"
}

require_usb_allowlist_uuid_for_disk_name() {
  local conf_path="${1:?allowlist path required}"
  local disk_name="${2:?disk name required}"
  local match_count=0
  local matched_uuid=""
  local raw entry_uuid entry_name

  assert_usb_allowlist_disk_name_value "${disk_name}" "DISK_NAME"
  validate_usb_allowlist_disk_names "${conf_path}"
  [[ -f "${conf_path}" ]] || die "Missing USB allow-list: ${conf_path}"

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    entry_name="${raw#"${entry_uuid}"}"
    entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
    entry_name="${entry_name%%[[:space:]]*}"
    if [[ "${entry_name}" == "${disk_name}" ]]; then
      match_count=$((match_count + 1))
      matched_uuid="${entry_uuid}"
    fi
  done < "${conf_path}"

  if (( match_count != 1 )); then
    die "DISK_NAME '${disk_name}' must match exactly one entry in ${conf_path}; matched ${match_count}."
  fi
  printf '%s
' "${matched_uuid}"
}

usb_mounted_by_us_marker() {
  local uuid="${1:?uuid required}"
  echo "/run/penelope/usb-mounted-by-us-${uuid}.flag"
}

usb_mark_mounted_by_us() {
  local uuid="${1:?uuid required}"
  local mark=""
  mark="$(usb_mounted_by_us_marker "${uuid}")"
  install -d -m 0700 -o root -g root "/run/penelope" || return 1
  : > "${mark}" 2>/dev/null || return 1
}

usb_clear_mounted_by_us() {
  local uuid="${1:?uuid required}"
  rm -f "$(usb_mounted_by_us_marker "${uuid}")" 2>/dev/null || true
}

verify_external_device_mounts_display() {
  local dev="${1:?device required}"
  findmnt -n -o TARGET --source "${dev}" 2>/dev/null | paste -sd ', ' -
}

verify_external_controlled_mount_path() {
  printf '%s/%s
' "${USB_MOUNT_BASE}" "${VERIFY_UUID}"
}

verify_external_default_repo_base() {
  printf '%s/%s/%s
' "${USB_MOUNT_BASE}" "${VERIFY_UUID}" "${HOST_SCOPE_NAME}"
}

verify_external_repo_base_has_repos() {
  local base="${1:?repo base required}"
  [[ -f "${base}/system/config" && -f "${base}/home/config" && -f "${base}/_archive/config" ]]
}

publish_external_verify_hold_signal() {
  local ready_file=""
  local hold_file=""
  local running_file=""
  local reattach_file=""
  [[ "${VERIFY_MODE}" == "external" ]] || return 0
  [[ -n "${VERIFY_DISK_NAME:-}" ]] || return 1
  ready_file="$(usb_signal_file_path ready "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  running_file="$(usb_signal_file_path running "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_file="$(usb_signal_file_path reattach_and_wait "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  clear_backup_dashboard_files "${ready_file}" "${running_file}" "${reattach_file}" || true
  write_backup_dashboard_notice_file     "${hold_file}"     "$(usb_signal_header hold "${VERIFY_DISK_NAME}")"     "uuid=${VERIFY_UUID}"     "disk_name=${VERIFY_DISK_NAME}"     "message=External backup verify is using the USB backup drive. Do NOT remove it."
}

verify_mount_external_usb() {
  local uuid="${1:?uuid required}"
  local dev=""
  local fstype=""
  local mnt=""
  local opts="nosuid,nodev,noexec,noatime"
  local existing_mounts=()
  local existing_mounts_display=""

  dev="$(usb_dev_for_uuid "${uuid}")"
  [[ -n "${dev}" ]] || die "External verify UUID is allowlisted but not currently connected: ${uuid}"
  fstype="$(usb_fstype_for_dev "${dev}")"
  [[ -n "${fstype}" ]] || die "Could not determine filesystem type for ${dev} (UUID=${uuid})"
  mnt="$(verify_external_controlled_mount_path)"

  mapfile -t existing_mounts < <(findmnt -n -o TARGET --source "${dev}" 2>/dev/null || true)
  if (( ${#existing_mounts[@]} > 0 )); then
    existing_mounts_display="$(printf '%s
' "${existing_mounts[@]}" | paste -sd ', ' -)"
    if [[ "${FORCE_UNMOUNT_EXTERNAL}" != "1" ]]; then
      if (( ${#existing_mounts[@]} == 1 )); then
        VERIFY_EXTERNAL_REPO_BASE="${existing_mounts[0]}/${HOST_SCOPE_NAME}"
        if verify_external_repo_base_has_repos "${VERIFY_EXTERNAL_REPO_BASE}"; then
          verify_log_info "External verify reusing existing USB mount at ${existing_mounts[0]} (UUID=${uuid})."
          return 0
        fi
      fi
      die "External verify repo is not accessible at ${USB_MOUNT_BASE}/${uuid}; USB ${uuid} is mounted at ${existing_mounts_display:-unknown mountpoint} and FORCE_UNMOUNT_EXTERNAL=0 prevents takeover."
    fi
    verify_log_info "External verify taking over USB ${uuid} (${dev}) mounted at ${existing_mounts_display}; FORCE_UNMOUNT_EXTERNAL=1."
    unmount_all_mounts_for_dev "${dev}" || die "External verify failed to unmount existing mounts for ${dev} (UUID=${uuid})."
    if dev_is_mounted_anywhere "${dev}"; then
      die "External verify takeover failed: USB ${uuid} (${dev}) remains mounted."
    fi
  fi

  install -d -m 0700 -o root -g root "${mnt}"
  if [[ "${fstype}" == "exfat" || "${fstype}" == "ntfs" || "${fstype}" == "fuseblk" || "${fstype}" == "vfat" ]]; then
    opts="${opts},uid=0,gid=0,umask=${USB_FS_UMASK}"
  fi

  verify_log_info "Mounting USB ${uuid} (${dev}, type=${fstype}) for external verify at ${mnt} (opts=${opts})"
  if ! mount -o "${opts}" "${dev}" "${mnt}"; then
    if [[ "${fstype}" == "exfat" ]] && mount -t exfat -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      :
    elif [[ "${fstype}" == "exfat" ]] && mount -t exfat-fuse -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      :
    else
      die "External verify failed to mount ${dev} at ${mnt} (type=${fstype})."
    fi
  fi
  usb_mark_mounted_by_us "${uuid}" || die "External verify mounted ${dev} at ${mnt} but failed to record mounted-by-us marker."
  VERIFY_EXTERNAL_HELD_MOUNT="1"
  VERIFY_EXTERNAL_REPO_BASE="${mnt}/${HOST_SCOPE_NAME}"
  publish_external_verify_hold_signal || true
}

ensure_external_verify_repo_base() {
  local default_base=""
  [[ "${VERIFY_MODE}" == "external" ]] || return 0
  default_base="$(verify_external_default_repo_base)"
  VERIFY_EXTERNAL_REPO_BASE="${default_base}"
  if verify_external_repo_base_has_repos "${VERIFY_EXTERNAL_REPO_BASE}"; then
    return 0
  fi
  verify_mount_external_usb "${VERIFY_UUID}"
  verify_external_repo_base_has_repos "${VERIFY_EXTERNAL_REPO_BASE}" || die "Verify repo not accessible after mounting external USB disk: ${VERIFY_EXTERNAL_REPO_BASE}"
}

settle_external_verify_device_unmounted_or_hold() {
  local uuid="${1:?uuid required}"
  local dev="${2:?device required}"
  local settle_seconds="5"
  local attempt=""
  local mounted_at=""

  for attempt in $(seq 1 "${settle_seconds}"); do
    if ! dev_is_mounted_anywhere "${dev}"; then
      VERIFY_EXTERNAL_SAFE_TO_REMOVE="1"
      return 0
    fi
    mounted_at="$(verify_external_device_mounts_display "${dev}")"
    if [[ "${FORCE_UNMOUNT_EXTERNAL}" != "1" ]]; then
      verify_log_warn "USB ${uuid} (${dev}) is still mounted at ${mounted_at}; FORCE_UNMOUNT_EXTERNAL=0 so it is not safe to remove yet."
      VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
      return 0
    fi
    verify_log_info "USB ${uuid} (${dev}) is mounted at ${mounted_at} after external verify release; FORCE_UNMOUNT_EXTERNAL=1 => unmounting before READY."
    sync || true
    if ! unmount_all_mounts_for_dev "${dev}"; then
      mounted_at="$(verify_external_device_mounts_display "${dev}")"
      verify_log_warn "Failed to unmount USB ${uuid} (${dev}) from ${mounted_at:-unknown mountpoint}; remove only after manual unmount."
      VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
      return 0
    fi
    usb_clear_mounted_by_us "${uuid}"
    sleep 1 || true
  done

  if dev_is_mounted_anywhere "${dev}"; then
    mounted_at="$(verify_external_device_mounts_display "${dev}")"
    verify_log_warn "USB ${uuid} (${dev}) is still mounted at ${mounted_at:-unknown mountpoint} after ${settle_seconds}s external verify release settle; not safe to remove."
    VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
  else
    VERIFY_EXTERNAL_SAFE_TO_REMOVE="1"
  fi
}

parse_verify_args() {
  while (( $# > 0 )); do
    case "${1}" in
      -h|--help)
        backup_verify_usage
        exit 0
        ;;
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires internal or external"
        case "${2}" in
          internal|external) VERIFY_MODE="${2}" ;;
          *) die "Unsupported verify mode: ${2} (expected internal|external)" ;;
        esac
        shift 2
        ;;
      --uuid)
        [[ $# -ge 2 ]] || die "--uuid requires a filesystem UUID"
        VERIFY_UUID="${2}"
        shift 2
        ;;
      --disk-name)
        [[ $# -ge 2 ]] || die "--disk-name requires a DISK_NAME"
        VERIFY_DISK_NAME_SELECTOR="${2}"
        shift 2
        ;;
      --run-now)
        VERIFY_RUN_NOW="1"
        shift
        ;;
      *)
        die "Unknown argument: ${1}"
        ;;
    esac
  done

  if [[ "${VERIFY_MODE}" == "external" ]]; then
    [[ -f "${USB_CONF}" ]] || die "Missing USB allow-list: ${USB_CONF}"
    if [[ -n "${VERIFY_UUID}" && -n "${VERIFY_DISK_NAME_SELECTOR}" ]]; then
      die "Use either --uuid <UUID> or --disk-name <DISK_NAME>, not both."
    fi
    if [[ -n "${VERIFY_DISK_NAME_SELECTOR}" ]]; then
      VERIFY_UUID="$(require_usb_allowlist_uuid_for_disk_name "${USB_CONF}" "${VERIFY_DISK_NAME_SELECTOR}")"
    fi
    [[ -n "${VERIFY_UUID}" ]] || die "External verify requires --uuid <UUID> or --disk-name <DISK_NAME>."
    assert_usb_allowlist_uuid_value "${VERIFY_UUID}" "External verify UUID"
    validate_usb_allowlist_disk_names "${USB_CONF}"
    uuid_in_allowlist "${USB_CONF}" "${VERIFY_UUID}" || die "UUID is not allowlisted in ${USB_CONF}: ${VERIFY_UUID}"
    VERIFY_DISK_NAME="$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${VERIFY_UUID}")"
  else
    [[ -z "${VERIFY_UUID}" ]] || die "--uuid is only valid with --mode external"
    [[ -z "${VERIFY_DISK_NAME_SELECTOR}" ]] || die "--disk-name is only valid with --mode external"
  fi
}

backup_verify_now_iso() {
  date +%Y-%m-%dT%H:%M:%S%z
}

generate_verify_run_id() {
  python3 - <<'PY_GENERATE_VERIFY_RUN_ID'
import secrets
print(secrets.token_hex(16))
PY_GENERATE_VERIFY_RUN_ID
}

ensure_verify_log() {
  ensure_dir "${LOG_DIR}" 0750 root adm
  ensure_file "${VERIFY_LOG}" 0640 root adm
}

verify_log_info() {
  local msg="$*"
  log "${msg}"
  {
    printf '[%s] INFO: %s
' "$(ts)" "${msg}"
  } >> "${VERIFY_LOG}" 2>/dev/null || true
}

verify_log_warn() {
  local msg="$*"
  warn "${msg}"
  {
    printf '[%s] WARN: %s
' "$(ts)" "${msg}"
  } >> "${VERIFY_LOG}" 2>/dev/null || true
}

verify_log_error() {
  local msg="$*"
  {
    printf '[%s] ERROR: %s
' "$(ts)" "${msg}"
  } >> "${VERIFY_LOG}" 2>/dev/null || true
}

verify_notice_header() {
  local kind="${1:?kind required}"
  case "${kind}" in
    running) printf '%s
' 'PENELOPE_BACKUP_VERIFY_RUNNING' ;;
    ok) printf '%s
' 'PENELOPE_BACKUP_VERIFY_OK' ;;
    error) printf '%s
' 'PENELOPE_BACKUP_VERIFY_ERROR_CONTACT_OPERATOR' ;;
    *) die "Unknown verify notice kind: ${kind}" ;;
  esac
}

write_verify_notice_file() {
  local out="${1:?output file required}"
  local kind="${2:?notice kind required}"
  local message="${3:-}"
  local tmp=""

  ensure_backup_dashboard "${BACKUP_DASHBOARD_DIR}"
  tmp="$(make_backup_dashboard_tmp_file "${BACKUP_DASHBOARD_DIR}")" || return 1
  {
    verify_notice_header "${kind}"
    echo "timestamp=$(backup_verify_now_iso)"
    echo "host=${TARGET_HOST}"
    echo "host_scope_name=${HOST_SCOPE_NAME}"
    echo "verify_run_id=${VERIFY_RUN_ID}"
    echo "verify_mode=${VERIFY_MODE}"
    echo "verify_log=${VERIFY_LOG}"
    echo "backup_log=${BACKUP_LOG}"
    [[ -n "${VERIFY_UUID}" ]] && echo "verify_uuid=${VERIFY_UUID}"
    [[ -n "${VERIFY_DISK_NAME}" ]] && echo "verify_disk_name=${VERIFY_DISK_NAME}"
    [[ -n "${message}" ]] && echo "message=${message}"
  } > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  chmod 0644 "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
  mv -f "${tmp}" "${out}" || { rm -f -- "${tmp}"; return 1; }
}

clear_verify_markers() {
  rm -f -- "${VERIFY_RUNNING_FILE}" "${VERIFY_OK_FILE}" "${VERIFY_ERROR_FILE}" 2>/dev/null || true
}

verify_scope_repo_base() {
  if [[ "${VERIFY_MODE}" == "internal" ]]; then
    printf '/_backup/%s
' "${HOST_SCOPE_NAME}"
    return 0
  fi
  if [[ -n "${VERIFY_EXTERNAL_REPO_BASE:-}" ]]; then
    printf '%s
' "${VERIFY_EXTERNAL_REPO_BASE}"
    return 0
  fi
  printf '%s/%s/%s
' "${USB_MOUNT_BASE}" "${VERIFY_UUID}" "${HOST_SCOPE_NAME}"
}

sentinel_path_for_target() {
  local target="${1:?target required}"
  case "${target}" in
    system) printf '%s
' '/penelope-backup-verify.txt' ;;
    home) printf '%s
' '/home/penelope-backup-verify.txt' ;;
    _archive) printf '%s
' '/_archive/penelope-backup-verify.txt' ;;
    *) die "Unknown verify target: ${target}" ;;
  esac
}

repo_path_for_target() {
  local target="${1:?target required}"
  local base=""
  base="$(verify_scope_repo_base)"
  printf '%s/%s
' "${base}" "$(repo_relpath_for_target "${target}")"
}

snapshot_id_for_target_var_name() {
  local target="${1:?target required}"
  case "${target}" in
    system) printf '%s
' 'VERIFY_SYSTEM_SNAPSHOT_ID' ;;
    home) printf '%s
' 'VERIFY_HOME_SNAPSHOT_ID' ;;
    _archive) printf '%s
' 'VERIFY_ARCHIVE_SNAPSHOT_ID' ;;
    *) die "Unknown verify target: ${target}" ;;
  esac
}

active_restic_repo_pids() {
  local repo="${1:?repo required}"
  local proc=""
  local pid=""
  local env_repo=""
  local repo_arg=""
  local next_is_repo="0"

  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ -r "${proc}/cmdline" ]] || continue
    [[ -r "${proc}/environ" ]] || continue

    if ! tr '\0' '
' < "${proc}/cmdline" 2>/dev/null | grep -Eq '^restic$|/restic$'; then
      continue
    fi

    env_repo="$(tr '\0' '
' < "${proc}/environ" 2>/dev/null | awk -F= '/^RESTIC_REPOSITORY=/{print substr($0, index($0,$2))}' | head -n 1 || true)"
    if [[ "${env_repo}" == "${repo}" ]]; then
      printf '%s
' "${pid}"
      continue
    fi

    repo_arg=""
    next_is_repo="0"
    while IFS= read -r arg; do
      [[ -n "${arg}" ]] || continue
      if [[ "${next_is_repo}" == "1" ]]; then
        repo_arg="${arg}"
        break
      fi
      case "${arg}" in
        --repo|-r) next_is_repo="1" ;;
        --repo=*) repo_arg="${arg#--repo=}"; break ;;
        -r?*) repo_arg="${arg#-r}"; break ;;
      esac
    done < <(tr '\0' '
' < "${proc}/cmdline" 2>/dev/null || true)

    if [[ "${repo_arg}" == "${repo}" ]]; then
      printf '%s
' "${pid}"
    fi
  done
}

reconcile_restic_repo_lock_for_verify() {
  local target="${1:?target required}"
  local repo="${2:?repo required}"
  local pw="${3:?pw file required}"
  local repo_pids=""

  repo_pids="$(active_restic_repo_pids "${repo}" | paste -sd, -)"
  if [[ -n "${repo_pids}" ]]; then
    die "Backup verify refuses pre-run unlock for ${target}: restic repository appears busy (pid(s): ${repo_pids})"
  fi

  verify_log_info "Pre-verify stale-lock reconciliation (${target}): ${repo}"
  if ! RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw}" restic unlock >/dev/null 2>&1; then
    die "Backup verify could not reconcile stale restic locks for ${target}: ${repo}"
  fi
}

restic_json_first_snapshot_id() {
  python3 -c 'import json, sys; data = json.load(sys.stdin);
if not data: raise SystemExit(1)
print(data[0].get("id", ""))'
}

latest_snapshot_id() {
  local repo="${1:?repo required}"
  local pw="${2:?pw file required}"
  RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw}" \
    restic snapshots --no-lock --latest 1 --json | \
    restic_json_first_snapshot_id
}

restic_repo_check() {
  local repo="${1:?repo required}"
  local pw="${2:?pw file required}"
  RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw}" \
    restic check --no-lock
}

restore_include_from_latest() {
  local repo="${1:?repo required}"
  local pw="${2:?pw file required}"
  local target_dir="${3:?target dir required}"
  local include_path="${4:?include path required}"
  RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw}" \
    restic restore --no-lock latest --target "${target_dir}" --include "${include_path}" >/dev/null
}

write_verify_sentinel_for_target() {
  local target="${1:?target required}"
  local path=""
  local parent=""
  local tmp=""

  path="$(sentinel_path_for_target "${target}")"
  parent="$(dirname -- "${path}")"
  ensure_dir "${parent}" 0755 root root

  tmp="${path}.tmp.$$"
  cat > "${tmp}" <<EOF_VERIFY_SENTINEL
penelope_backup_verify=1
verify_run_id=${VERIFY_RUN_ID}
timestamp=${VERIFY_START_ISO}
verify_mode=${VERIFY_MODE}
target_host=${TARGET_HOST}
host_scope_name=${HOST_SCOPE_NAME}
target=${target}
verify_uuid=${VERIFY_UUID}
sentinel_path=${path}
EOF_VERIFY_SENTINEL
  chown root:root "${tmp}" || die "Failed to chown verify sentinel: ${tmp}"
  chmod 0644 "${tmp}" || die "Failed to chmod verify sentinel: ${tmp}"
  mv -f "${tmp}" "${path}" || die "Failed to publish verify sentinel: ${path}"
}

refresh_internal_backup_dashboard_state_for_verify() {
  local helper="/usr/local/sbin/penelope-refresh-backup-dashboard.sh"
  if [[ ! -x "${helper}" ]]; then
    verify_log_warn "Backup-Dashboard refresh helper missing during verify: ${helper}"
    return 1
  fi
  if ! "${helper}" >/dev/null 2>&1; then
    verify_log_warn "Backup-Dashboard refresh helper failed during verify reconciliation."
    return 1
  fi
  return 0
}

internal_runtime_signals_match_success() {
  local dash_dir="${1:?dashboard dir required}"
  local last_json="${2:?last json required}"
  [[ -f "${last_json}" ]] || return 1
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_RUNNING.txt" ]] || return 1
  [[ -f "${dash_dir}/INTERNAL_BACKUP_OK.txt" ]] || return 1
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt" ]] || return 1
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt" ]] || return 1
  python3 - "${last_json}" "${TARGET_HOST}" "${HOST_SCOPE_NAME}" "${BACKUP_LOG}" <<'PY_VERIFY_INTERNAL_RUNTIME_SIGNALS'
import json, sys
path, expected_host, expected_scope, expected_log = sys.argv[1:5]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
assert data.get('mode') == 'internal'
assert data.get('status') == 'success'
assert data.get('host') == expected_host
assert data.get('host_scope_name') == expected_scope
assert data.get('log_file') == expected_log
PY_VERIFY_INTERNAL_RUNTIME_SIGNALS
}

verify_internal_runtime_signals() {
  local dash_dir="${BACKUP_DASHBOARD_DIR:?backup dashboard dir required}"
  local last_json=""
  local attempt=""
  local attempts=8
  last_json="$(internal_backup_dashboard_file_path last_json "${dash_dir}")"
  for attempt in $(seq 1 "${attempts}"); do
    if internal_runtime_signals_match_success "${dash_dir}" "${last_json}"; then
      return 0
    fi
    refresh_internal_backup_dashboard_state_for_verify || true
    if internal_runtime_signals_match_success "${dash_dir}" "${last_json}"; then
      return 0
    fi
    if (( attempt < attempts )); then sleep 1; fi
  done
  [[ -f "${last_json}" ]] || die "Missing internal Backup-Dashboard status JSON: ${last_json}"
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_RUNNING.txt" ]] || die "Internal backup running marker still present after completed run and dashboard refresh retries"
  [[ -f "${dash_dir}/INTERNAL_BACKUP_OK.txt" ]] || die "Missing internal backup OK marker after completed run"
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt" ]] || die "Unexpected internal backup error marker after successful run"
  [[ ! -f "${dash_dir}/INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt" ]] || die "Unexpected internal backup stale marker immediately after successful run"
  internal_runtime_signals_match_success "${dash_dir}" "${last_json}" || die "Internal Backup-Dashboard runtime signals did not converge to a clean success state"
}

verify_external_runtime_signals() {
  local dash_dir="${BACKUP_DASHBOARD_DIR:?backup dashboard dir required}"
  local last_json=""
  local running_file=""
  VERIFY_DISK_NAME="${VERIFY_DISK_NAME:-$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${VERIFY_UUID}")}"
  last_json="$(usb_external_status_json_path "${VERIFY_DISK_NAME}" "${dash_dir}")"
  running_file="$(usb_signal_file_path running "${VERIFY_DISK_NAME}" "${dash_dir}")"
  [[ -f "${last_json}" ]] || die "Missing external Backup-Dashboard status JSON: ${last_json}"
  if [[ "${PENELOPE_BACKUP_VERIFY_ALLOW_EXTERNAL_RUNNING:-0}" != "1" ]]; then
    [[ ! -f "${running_file}" ]] || die "External backup running marker still present after verify target run: ${running_file}"
  fi
  python3 - "${last_json}" "${TARGET_HOST}" "${HOST_SCOPE_NAME}" "${BACKUP_LOG}" "${VERIFY_UUID}" <<'PY_VERIFY_EXTERNAL_RUNTIME_SIGNALS'
import json, sys
path, expected_host, expected_scope, expected_log, expected_uuid = sys.argv[1:6]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
assert data.get('mode') == 'external'
assert data.get('status') == 'success'
assert data.get('host') == expected_host
assert data.get('host_scope_name') == expected_scope
assert data.get('log_file') == expected_log
if data.get('uuid'):
    assert data.get('uuid') == expected_uuid
PY_VERIFY_EXTERNAL_RUNTIME_SIGNALS
}

verify_target_restore_roundtrip() {
  local target="${1:?target required}"
  local repo=""
  local pw=""
  local sentinel=""
  local snapshot_id=""
  local snapshot_var=""
  local tmp=""
  local restored=""

  repo="$(repo_path_for_target "${target}")"
  pw="$(restic_password_file_for_target "${target}")"
  sentinel="$(sentinel_path_for_target "${target}")"
  [[ -f "${repo}/config" ]] || die "Verify repo not accessible for ${target}: ${repo}"

  verify_log_info "Repository integrity check (${target}): ${repo}"
  restic_repo_check "${repo}" "${pw}"
  snapshot_id="$(latest_snapshot_id "${repo}" "${pw}")"
  [[ -n "${snapshot_id}" ]] || die "No latest snapshot id returned for ${target}: ${repo}"
  snapshot_var="$(snapshot_id_for_target_var_name "${target}")"
  printf -v "${snapshot_var}" '%s' "${snapshot_id}"

  if [[ "${VERIFY_RUN_NOW}" != "1" ]]; then
    verify_log_info "Latest snapshot present (${target}): ${snapshot_id}"
    return 0
  fi

  [[ -f "${sentinel}" ]] || die "Verify sentinel missing on live filesystem for ${target}: ${sentinel}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/penelope-backup-work.XXXXXX")"
  restore_include_from_latest "${repo}" "${pw}" "${tmp}" "${sentinel}"
  restored="${tmp}${sentinel}"
  if [[ ! -f "${restored}" ]]; then
    rm -rf -- "${tmp}"
    die "Verify restore FAILED for ${target}: ${sentinel} not found in latest snapshot ${snapshot_id}"
  fi
  if ! cmp -s "${sentinel}" "${restored}"; then
    rm -rf -- "${tmp}"
    die "Verify restore FAILED for ${target}: restored sentinel content mismatch for latest snapshot ${snapshot_id}"
  fi
  rm -rf -- "${tmp}"
  verify_log_info "Verify restore OK (${target}): ${sentinel} from snapshot ${snapshot_id}"
}

restore_system_probe() {
  local repo=""
  local pw=""
  local tmp=""
  repo="$(repo_path_for_target system)"
  pw="$(restic_password_file_for_target system)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/penelope-backup-work.XXXXXX")"
  verify_log_info "Restore probe: restoring /etc/hostname from latest system snapshot into ${tmp}"
  if ! restore_include_from_latest "${repo}" "${pw}" "${tmp}" "/etc/hostname"; then
    rm -rf -- "${tmp}"
    die "Restore probe FAILED: unable to restore /etc/hostname from latest system snapshot"
  fi
  if [[ ! -f "${tmp}/etc/hostname" ]]; then
    rm -rf -- "${tmp}"
    die "Restore probe FAILED: ${tmp}/etc/hostname missing"
  fi
  verify_log_info "Restore probe OK: ${tmp}/etc/hostname exists."
  rm -rf -- "${tmp}"
}

cleanup_external_mount_after_verify() {
  local mnt=""
  local dev=""
  mnt="$(verify_external_controlled_mount_path)"
  VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
  if [[ "${VERIFY_MODE}" != "external" || "${VERIFY_EXTERNAL_HELD_MOUNT}" != "1" ]]; then
    return 0
  fi
  dev="$(usb_dev_for_uuid "${VERIFY_UUID}" || true)"
  if [[ -z "${dev}" ]]; then
    verify_log_warn "Could not resolve USB block device for UUID=${VERIFY_UUID} during external verify cleanup; remove only after manual inspection."
    VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
    return 0
  fi
  if [[ "${FORCE_UNMOUNT_EXTERNAL}" == "1" && -d "${mnt}" ]] && mountpoint -q "${mnt}"; then
    sync || true
    if umount "${mnt}"; then
      usb_clear_mounted_by_us "${VERIFY_UUID}" || true
      verify_log_info "Unmounted external verify mount after successful verify: ${mnt}"
    else
      VERIFY_EXTERNAL_SAFE_TO_REMOVE="0"
      verify_log_warn "Failed to unmount external verify mount after verify: ${mnt}"
      return 1
    fi
  fi
  settle_external_verify_device_unmounted_or_hold "${VERIFY_UUID}" "${dev}"
}

publish_external_verify_ready_signal_if_safe() {
  local ready_file=""
  local running_file=""
  local hold_file=""
  local reattach_file=""
  if [[ "${VERIFY_MODE}" != "external" || "${VERIFY_EXTERNAL_HELD_MOUNT}" != "1" ]]; then
    return 0
  fi
  [[ -n "${VERIFY_DISK_NAME:-}" ]] || return 1
  ready_file="$(usb_signal_file_path ready "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  running_file="$(usb_signal_file_path running "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_file="$(usb_signal_file_path reattach_and_wait "${VERIFY_DISK_NAME}" "${BACKUP_DASHBOARD_DIR}")"
  if [[ "${VERIFY_EXTERNAL_SAFE_TO_REMOVE}" == "1" ]]; then
    clear_backup_dashboard_files "${running_file}" "${hold_file}" "${reattach_file}" || return 1
    write_backup_dashboard_notice_file \
      "${ready_file}" \
      "$(usb_signal_header ready "${VERIFY_DISK_NAME}")" \
      "uuid=${VERIFY_UUID}" \
      "disk_name=${VERIFY_DISK_NAME}" \
      "message=The USB backup drive may now be removed."
    return $?
  fi
  clear_backup_dashboard_files "${ready_file}" || true
  write_backup_dashboard_notice_file \
    "${hold_file}" \
    "$(usb_signal_header hold "${VERIFY_DISK_NAME}")" \
    "uuid=${VERIFY_UUID}" \
    "disk_name=${VERIFY_DISK_NAME}" \
    "message=Backup verify completed, but the USB backup drive is still mounted or safe-removal cleanup did not complete. Do NOT remove it. Contact the operator."
}

write_backup_verify_status_json() {
  local status="${1:?status required}"
  local message="${2:-}"
  local tmp=""
  ensure_backup_dashboard "${BACKUP_DASHBOARD_DIR}"
  tmp="$(make_backup_dashboard_tmp_file "${BACKUP_DASHBOARD_DIR}")" || return 1
  python3 - \
    "${tmp}" "${status}" "${message}" "${VERIFY_RUN_ID:-}" "${VERIFY_START_ISO:-}" \
    "${VERIFY_LOG}" "${BACKUP_LOG}" "${VERIFY_SYSTEM_SNAPSHOT_ID:-}" \
    "${VERIFY_HOME_SNAPSHOT_ID:-}" "${VERIFY_ARCHIVE_SNAPSHOT_ID:-}" \
    "${VERIFY_MODE}" "${VERIFY_RUN_NOW}" "${VERIFY_UUID:-}" "${VERIFY_DISK_NAME:-}" \
    "${TARGET_HOST}" "${HOST_SCOPE_NAME}" <<'PY_BACKUP_VERIFY_STATUS_JSON'
import json, sys, time
(
    out,
    status,
    message,
    verify_run_id,
    verify_started_at,
    verify_log,
    backup_log,
    system_snapshot_id,
    home_snapshot_id,
    archive_snapshot_id,
    verify_mode,
    verify_run_now,
    verify_uuid,
    verify_disk_name,
    target_host,
    host_scope_name,
) = sys.argv[1:17]
data = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "host": target_host,
    "host_scope_name": host_scope_name,
    "mode": "verify",
    "status": status,
    "message": message,
    "verify_run_id": verify_run_id,
    "verify_started_at": verify_started_at,
    "verify_log": verify_log,
    "backup_log": backup_log,
    "verify_mode": verify_mode,
    "verify_run_now": verify_run_now,
    "verify_uuid": verify_uuid,
    "verify_disk_name": verify_disk_name,
    "system_snapshot_id": system_snapshot_id,
    "home_snapshot_id": home_snapshot_id,
    "archive_snapshot_id": archive_snapshot_id,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY_BACKUP_VERIFY_STATUS_JSON
  chmod 0644 "${tmp}" 2>/dev/null || { rm -f -- "${tmp}"; return 1; }
  mv -f "${tmp}" "${VERIFY_STATUS_JSON}" || { rm -f -- "${tmp}"; return 1; }
}

publish_backup_verify_running() {
  clear_verify_markers
  write_verify_notice_file "${VERIFY_RUNNING_FILE}" "running" "Backup verify is running." || true
  write_backup_verify_status_json "running" "Backup verify is running." || true
}

publish_backup_verify_failure() {
  local message="${1:-Backup verify failed.}"
  [[ "${VERIFY_FAILURE_PUBLISHED}" == "1" ]] && return 0
  VERIFY_FAILURE_PUBLISHED="1"
  rm -f -- "${VERIFY_RUNNING_FILE}" "${VERIFY_OK_FILE}" 2>/dev/null || true
  cleanup_external_mount_after_verify || true
  write_verify_notice_file "${VERIFY_ERROR_FILE}" "error" "${message}" || true
  write_backup_verify_status_json "failed" "${message}" || true
  verify_log_error "${message}"
}

publish_backup_verify_success() {
  local message="${1:-Backup verify completed successfully.}"
  cleanup_external_mount_after_verify || true
  publish_external_verify_ready_signal_if_safe || true
  rm -f -- "${VERIFY_RUNNING_FILE}" "${VERIFY_ERROR_FILE}" 2>/dev/null || true
  write_verify_notice_file "${VERIFY_OK_FILE}" "ok" "${message}" || true
  write_backup_verify_status_json "success" "${message}" || true
}

backup_verify_on_err() {
  local line="${1:-?}"
  local cmd="${2:-<unknown>}"
  local ec="${3:-1}"
  publish_backup_verify_failure "Unhandled error at line ${line}: ${cmd}" || true
  penelope_log_trap_error "${ec}" "${line}" "${cmd}" 320 || true
  exit "${ec}"
}

backup_verify_on_signal() {
  local sig="${1:?signal required}"
  local ec=""
  ec="$(penelope_signal_exit_code_for_name "${sig}")"
  publish_backup_verify_failure "Received ${sig}; backup verify aborted." || true
  warn "Received ${sig}; aborting penelope-backup-verify."
  exit "${ec}"
}

trap 'backup_verify_on_err ${LINENO} "${BASH_COMMAND}" $?' ERR
trap 'backup_verify_on_signal INT' INT
trap 'backup_verify_on_signal TERM' TERM

main() {
  local target=""
  parse_verify_args "$@"
  require_root
  require_cmd_many restic python3 mountpoint cmp findmnt blkid mount umount
  ensure_expected_penelope_mount_layout "continue"
  ensure_verify_log
  VERIFY_RUN_ID="$(generate_verify_run_id)"
  VERIFY_START_ISO="$(backup_verify_now_iso)"

  if [[ "${VERIFY_MODE}" == "external" ]]; then
    verify_log_info "penelope-backup-verify STARTED (mode=external uuid=${VERIFY_UUID} run_id=${VERIFY_RUN_ID})"
  else
    verify_log_info "penelope-backup-verify STARTED (mode=internal run_id=${VERIFY_RUN_ID})"
  fi
  publish_backup_verify_running

  if [[ "${VERIFY_RUN_NOW}" == "1" ]]; then
    for target in $(all_backup_targets); do
      write_verify_sentinel_for_target "${target}"
      verify_log_info "Wrote fresh verify sentinel (${target}): $(sentinel_path_for_target "${target}")"
    done
    if [[ "${VERIFY_MODE}" == "internal" ]]; then
      for target in $(all_backup_targets); do
        reconcile_restic_repo_lock_for_verify "${target}" "$(repo_path_for_target "${target}")" "$(restic_password_file_for_target "${target}")"
      done
      verify_log_info "Running one internal backup now for backup verify."
      PENELOPE_BACKUP_SKIP_AUTO_VERIFY=1 /usr/local/sbin/penelope-backup.sh --mode internal
      verify_internal_runtime_signals
      verify_log_info "Internal Backup-Dashboard runtime signals verified."
    else
      verify_log_info "Running one external backup now for backup verify (UUID=${VERIFY_UUID})."
      PENELOPE_BACKUP_SKIP_AUTO_VERIFY=1 PENELOPE_BACKUP_VERIFY_HOLD_MOUNT=1 /usr/local/sbin/penelope-backup.sh --mode external --uuid "${VERIFY_UUID}"
      VERIFY_EXTERNAL_HELD_MOUNT="1"
      verify_external_runtime_signals
      verify_log_info "External Backup-Dashboard runtime signals verified (UUID=${VERIFY_UUID})."
    fi
  else
    if [[ "${VERIFY_SKIP_RUNTIME_SIGNALS}" == "1" ]]; then
      verify_log_info "Skipping Backup-Dashboard runtime signal assertions for this verify run because PENELOPE_BACKUP_VERIFY_SKIP_RUNTIME_SIGNALS=1."
    elif [[ "${VERIFY_MODE}" == "internal" ]]; then
      verify_internal_runtime_signals
      verify_log_info "Internal Backup-Dashboard runtime signals verified."
    else
      verify_external_runtime_signals
      verify_log_info "External Backup-Dashboard runtime signals verified (UUID=${VERIFY_UUID})."
    fi
  fi

  if [[ "${VERIFY_MODE}" == "external" ]]; then
    ensure_external_verify_repo_base
  fi

  for target in $(all_backup_targets); do
    verify_target_restore_roundtrip "${target}"
  done
  restore_system_probe
  publish_backup_verify_success "Backup verify completed successfully."
  verify_log_info "penelope-backup-verify SUCCESS (run_id=${VERIFY_RUN_ID})"
}

main "$@"
EOF_BACKUP_VERIFY_SCRIPT
  } | install_file_from_heredoc "${tool_path}" 0750 root root "backup-verify"

  if [[ -e "${legacy_path}" ]]; then
    log "Removing legacy smoke test: ${legacy_path}"
    rm -f -- "${legacy_path}" || die "Failed to remove legacy smoke test: ${legacy_path}"
  fi
}

install_usb_disk_setup() {
  local tool_path="/usr/local/sbin/penelope-usb-disk-setup.sh"

  log "Installing USB disk setup tool: ${tool_path}"
  {
    cat <<'EOF_USB_DISK_SETUP_SCRIPT_HEAD'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-usb-disk-setup.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
#
# Modes:
# - Guided mode (default): list connected USB disks, protect internal disks, then choose the safe action
# - Prepare-new mode: prepare and register a new/disposable USB backup disk (destructive)
# - Register-existing mode: register an existing Penelope USB backup disk without reformatting it
# - Rename-disk mode: rename an already registered disk and optionally its filesystem label
# - List-registered mode: list local USB allow-list entries without scanning labels
# - Deregister mode: non-destructively remove one local USB allow-list entry
#
# Guided mode:
# - Shows protected internal disks and selectable USB disks before any choice is made
# - Treats already registered disks as idempotent success and prints the UUID
# - Keeps operator-chosen DISK_NAME and filesystem LABEL identical for newly prepared disks
# - Requires an exact destructive confirmation phrase before erasing anything
# - Preserves foreign host scopes and works only in the current HOST_SCOPE_NAME scope
# - Shows disk capacity, existing host scopes, and an internal backup footprint estimate
#
# Prepare-new mode:
# - Selects a connected USB disk from the guided disk list
# - Destroys existing partitioning only after exact confirmation
# - Creates GPT + 1 partition
# - Formats the partition (default: ext4; optional: exfat)
# - Appends the filesystem UUID plus DISK_NAME to: /etc/penelope/usb-backup-disks.conf
#
# Register-existing mode:
# - Selects an already connected USB disk
# - Does NOT reformat or modify the filesystem label
# - Reads the existing filesystem UUID
# - Verifies that a plausible Penelope backup structure already exists on disk
# - Accepts disks with current and/or foreign HOST_SCOPE_NAME scopes after explicit operator choice
# - Appends the UUID plus DISK_NAME to: /etc/penelope/usb-backup-disks.conf
#
# Deregister mode removes only the local allow-list entry and related per-disk dashboard signals.
# It does not erase disks, delete repositories, or modify backup data.
#
# This script does NOT start a backup. To start manually:
#   sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid <UUID>
# Or trigger auto-run by unplugging and re-plugging the disk (if enabled via udev).
#
# Usage:
#   sudo /usr/local/sbin/penelope-usb-disk-setup.sh [--guided|--prepare-new|--register-existing|--rename-disk|--list-registered|--deregister] [--uuid <UUID>|--disk-name <DISK_NAME>] [--force]
#
# Options:
#   -g, --guided             Guided mode (default): select a connected USB disk and choose the safe action
#   -n, --prepare-new        Prepare and register a new/disposable disk (destructive)
#   -r, --register-existing  Register an existing Penelope backup disk without formatting
#       --rename-disk        Rename an already registered USB backup disk
#       --list-registered    List registered USB backup disks from the local allow-list
#       --deregister         Remove one local allow-list entry without erasing the disk or repositories
#       --uuid <UUID>        Select a registered disk by UUID for --deregister
#       --disk-name <NAME>   Select a registered disk by DISK_NAME for --deregister
#   -f, --force              Try harder to unmount automounted/busy partitions (retries + lazy unmount).
#                            Still refuses to proceed if mounts remain.
#
# Environment overrides:
#   FS_TYPE=ext4|exfat     (default: ext4; prepare-new mode only)
#   USB_CONF=/etc/penelope/usb-backup-disks.conf
#   DISK_NAME="backup-01"  (optional in interactive mode; prompted if omitted)
#                            For newly prepared disks, DISK_NAME also becomes the filesystem LABEL.
#   AUTO_UNMOUNT=1         (default: 1; attempt to unmount/power-off after preparation)
#   TIMEOUT_SEC=60
#
EOF_USB_DISK_SETUP_SCRIPT_HEAD
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_backup_dashboard_file_helpers
    emit_generated_usb_allowlist_helpers
    emit_generated_runtime_lock_helpers
    cat <<'EOF_USB_DISK_SETUP_SCRIPT_HEAD'
FORCE_UNMOUNT_BUSY=0
MODE="guided"
LABEL="${LABEL:-}"
DEREGISTER_UUID=""
DEREGISTER_DISK_NAME=""
DEREGISTER_SELECTOR_KIND=""
readonly DISK_NAME_MAX_LEN=16

usage() {
  cat <<'USAGE_USB_SETUP'
Usage:
  sudo /usr/local/sbin/penelope-usb-disk-setup.sh [--guided|--prepare-new|--register-existing|--rename-disk|--list-registered|--deregister] [--uuid <UUID>|--disk-name <DISK_NAME>] [--force]

Options:
  -g, --guided             Guided mode (default): select a connected USB disk and choose the safe action.
  -n, --prepare-new        Prepare and register a new/disposable disk (destructive).
  -r, --register-existing  Register an existing Penelope backup disk without formatting.
      --rename-disk        Rename an already registered USB backup disk.
      --list-registered    List registered USB backup disks from the local allow-list.
      --deregister         Remove one local allow-list entry without erasing the disk or repositories.
      --uuid <UUID>        Select a registered disk by UUID for --deregister.
      --disk-name <NAME>   Select a registered disk by DISK_NAME for --deregister.
  -f, --force              Try harder to unmount automounted/busy partitions (retries + lazy unmount).
                           The script still refuses to proceed if any mountpoints remain after these attempts.
  -h, --help               Show this help and exit.
USAGE_USB_SETUP
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--guided)
        MODE="guided"
        shift
        ;;
      -n|--prepare-new)
        MODE="prepare-new"
        shift
        ;;
      -r|--register-existing)
        MODE="register-existing"
        shift
        ;;
      --rename-disk)
        MODE="rename-disk"
        shift
        ;;
      --list-registered)
        MODE="list-registered"
        shift
        ;;
      --deregister)
        MODE="deregister"
        shift
        ;;
      --uuid)
        [[ $# -ge 2 ]] || { >&2 echo "ERROR: --uuid requires a value"; exit 2; }
        DEREGISTER_UUID="$2"
        DEREGISTER_SELECTOR_KIND="uuid"
        shift 2
        ;;
      --disk-name)
        [[ $# -ge 2 ]] || { >&2 echo "ERROR: --disk-name requires a value"; exit 2; }
        DEREGISTER_DISK_NAME="$2"
        DEREGISTER_SELECTOR_KIND="disk-name"
        shift 2
        ;;
      -f|--force)
        FORCE_UNMOUNT_BUSY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        >&2 echo "ERROR: Unknown argument: $1 (use --help)"; exit 2
        ;;
    esac
  done
}

readonly DEFAULT_USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
readonly USB_CONF="${USB_CONF:-${DEFAULT_USB_CONF}}"
readonly FS_TYPE="${FS_TYPE:-ext4}"
DISK_NAME="${DISK_NAME:-}"
readonly AUTO_UNMOUNT="${AUTO_UNMOUNT:-1}"
readonly TIMEOUT_SEC="${TIMEOUT_SEC:-60}"
readonly CONF_FILE="/etc/${PROJECT}/backup.conf"

TARGET_HOST="$(default_target_host)"
HOST_SCOPE_NAME="${TARGET_HOST}"
BACKUP_DASHBOARD_DIR="/var/lib/${PROJECT}/backup-dashboard"
BACKUP_LOG="/var/log/${HOST_SCOPE_NAME}/backup/backup.log"
OPS_KIND="usb-disk-setup"
OPS_EVENT_UUID=""
OPS_EVENT_FINALIZED="0"

readonly RUN_DIR="/run/penelope"
readonly USB_SETUP_LOCK_DIR="${RUN_DIR}/usb-disk-setup.lock.d"

# Hold per-UUID backup locks (to avoid races with penelope-backup udev triggers on allowlisted disks).
BACKUP_LOCK_FDS=()
BACKUP_LOCK_DIRS=()

EOF_USB_DISK_SETUP_SCRIPT_HEAD
  cat <<'EOF_OPS_HELPERS_USB_SETUP'
ensure_ops_backup_dashboard() {
  ensure_backup_dashboard "${BACKUP_DASHBOARD_DIR}"
}

write_ops_backup_dashboard_event() {
  local event="${1:?event required}"
  local message="${2:-}"
  local uuid="${3:-${OPS_EVENT_UUID}}"
  local status_file="${BACKUP_DASHBOARD_DIR}/events-ops.log"
  append_backup_dashboard_event_line "${status_file}" "ops" "${event}" "${message}" "${uuid}" "all" "${OPS_KIND}" "" || true
}

write_ops_backup_dashboard_json() {
  local status="${1:?status required}"
  local event="${2:?event required}"
  local message="${3:-}"
  local uuid="${4:-${OPS_EVENT_UUID}}"
  local out="${BACKUP_DASHBOARD_DIR}/last-ops.json"
  ensure_ops_backup_dashboard
  write_backup_dashboard_status_json_file "${out}" "ops" "${status}" "${message}" "${uuid}" "" "${OPS_KIND}" "${event}" "0" "1"
}

write_ops_backup_dashboard_status() {
  local status="${1:?status required}"
  local event="${2:?event required}"
  local message="${3:-}"
  local uuid="${4:-${OPS_EVENT_UUID}}"
  write_ops_backup_dashboard_event "${event}" "${message}" "${uuid}"
  write_ops_backup_dashboard_json "${status}" "${event}" "${message}" "${uuid}"
}
EOF_OPS_HELPERS_USB_SETUP
  cat <<'EOF_USB_DISK_SETUP_SCRIPT_TAIL'

ops_on_exit() {
  local rc="${1:-0}"
  if (( rc != 0 )) && [[ "${OPS_EVENT_FINALIZED}" != "1" ]]; then
    write_ops_backup_dashboard_status "failed" "usb-disk-setup-failed" "USB disk setup failed. Inspect terminal output and contact the operator if needed." "${OPS_EVENT_UUID}"
    OPS_EVENT_FINALIZED="1"
  fi
}

cleanup_usb_setup() {
  local rc="${1:-0}"
  release_backup_locks
  if ! release_pid_dir_lock "${USB_SETUP_LOCK_DIR}"; then
    warn "Failed to release USB disk setup lock: ${USB_SETUP_LOCK_DIR}"
  fi
  ops_on_exit "${rc}"
}

refresh_usb_autorun_rules_after_allowlist_change() {
  local refresher="/usr/local/sbin/penelope-refresh-usb-autorun-rules.sh"
  if [[ -x "${refresher}" ]]; then
    "${refresher}" || die "Failed to refresh USB autorun udev rules after allow-list change: ${refresher}"
    log "Refreshed USB autorun udev rules from ${USB_CONF}."
    return 0
  fi
  warn "USB autorun rules refresher is not installed; rerun penelope-backup-setup apply before relying on USB autorun."
}

validate_operator_disk_name() {
  local disk_name="${1:?disk name required}"
  if [[ -z "${disk_name}" ]]; then
    die "DISK_NAME must not be empty."
  fi
  if (( ${#disk_name} > DISK_NAME_MAX_LEN )); then
    die "DISK_NAME '${disk_name}' is too long (${#disk_name} characters). Choose at most ${DISK_NAME_MAX_LEN} characters so DISK_NAME and filesystem LABEL can stay identical."
  fi
  if [[ ! "${disk_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "DISK_NAME '${disk_name}' is invalid. Use letters, digits, dot, underscore, or hyphen; start with a letter or digit."
  fi
}

try_validate_operator_disk_name_for_prompt() {
  local disk_name="${1:-}"
  local error=""
  if [[ -z "${disk_name}" ]]; then
    >&2 echo "Please enter a non-empty disk name."
    return 1
  fi
  if (( ${#disk_name} > DISK_NAME_MAX_LEN )); then
    >&2 echo "DISK_NAME is too long (${#disk_name} characters). Choose at most ${DISK_NAME_MAX_LEN} characters."
    return 1
  fi
  if [[ ! "${disk_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    error="Use letters, digits, dot, underscore, or hyphen; start with a letter or digit."
    >&2 echo "Invalid DISK_NAME '${disk_name}'. ${error}"
    return 1
  fi
  return 0
}

ensure_disk_name() {
  local suggested="${1:-}"
  local prompt_hint="${2:-disk name}"

  if [[ "${DISK_NAME}" =~ [^[:space:]] ]]; then
    validate_operator_disk_name "${DISK_NAME}"
    return 0
  fi

  [[ -t 0 ]] || die "DISK_NAME is required in non-interactive mode (export DISK_NAME=backup-01 before running the tool)."

  local entered=""
  >&2 echo
  >&2 echo "Assign an operator-chosen USB backup disk name now."
  >&2 echo "For newly prepared disks this name is also used as the filesystem label."
  >&2 echo "Allowed: letters, digits, dot, underscore, hyphen; maximum ${DISK_NAME_MAX_LEN} characters."
  while true; do
    if [[ -n "${suggested}" ]]; then
      read -r -p "${prompt_hint} [${suggested}]: " entered
      if [[ ! "${entered}" =~ [^[:space:]] ]]; then
        entered="${suggested}"
      fi
    else
      read -r -p "${prompt_hint}: " entered
    fi
    if try_validate_operator_disk_name_for_prompt "${entered}"; then
      DISK_NAME="${entered}"
      return 0
    fi
  done
}

resolve_label_for_prepare_new() {
  validate_operator_disk_name "${DISK_NAME}"
  if [[ "${LABEL}" =~ [^[:space:]] && "${LABEL}" != "${DISK_NAME}" ]]; then
    die "For newly prepared Penelope USB backup disks, DISK_NAME and filesystem LABEL must be identical. Got DISK_NAME='${DISK_NAME}' and LABEL='${LABEL}'."
  fi
  LABEL="${DISK_NAME}"
}

acquire_setup_lock() {
  acquire_pid_dir_lock "${USB_SETUP_LOCK_DIR}" "USB disk setup"
  trap 'release_backup_locks; if ! release_pid_dir_lock "${USB_SETUP_LOCK_DIR}"; then warn "Failed to release USB disk setup lock: ${USB_SETUP_LOCK_DIR}"; fi' EXIT
}

backup_lock_path_for_uuid() {
  local uuid="${1:?uuid required}"
  echo "${RUN_DIR}/usb-backup-${uuid}.lock"
}

acquire_backup_lock_for_uuid() {
  # Best-effort: matches penelope-backup's per-UUID runtime lock semantics.
  # Returns 0 if lock acquired, 1 if already locked.
  local uuid="${1:?uuid required}"
  local lock_path
  lock_path="$(backup_lock_path_for_uuid "${uuid}")"

  ensure_penelope_run_dir "${RUN_DIR}" || return 1

  if command -v flock >/dev/null 2>&1; then
    local fd
    exec {fd}>"${lock_path}" || return 1
    if flock -n "${fd}"; then
      BACKUP_LOCK_FDS+=("${fd}")
      return 0
    fi
    exec {fd}>&-
    return 1
  fi

  if mkdir "${lock_path}.d" 2>/dev/null; then
    BACKUP_LOCK_DIRS+=("${lock_path}.d")
    return 0
  fi
  return 1
}

release_backup_locks() {
  local fd d
  for fd in "${BACKUP_LOCK_FDS[@]}"; do
    [[ -n "${fd}" ]] || continue
    exec {fd}>&- 2>/dev/null || true
  done
  BACKUP_LOCK_FDS=()

  for d in "${BACKUP_LOCK_DIRS[@]}"; do
    [[ -n "${d}" ]] || continue
    rmdir "${d}" 2>/dev/null || true
  done
  BACKUP_LOCK_DIRS=()
}

acquire_backup_locks_for_disk_preflight() {
  # Prevent races with penelope-backup udev/systemd triggers by taking per-UUID locks
  # for any UUIDs currently present on this disk that are already allowlisted.
  local dev="${1:?dev required}"

  local uuids
  uuids="$(lsblk -nr -o UUID "${dev}" 2>/dev/null | awk 'NF{print $1}' | sort -u)"
  [[ -n "${uuids}" ]] || return 0

  local u
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    if uuid_in_allowlist "${USB_CONF}" "${u}"; then
      if acquire_backup_lock_for_uuid "${u}"; then
        log "Acquired backup lock for allowlisted UUID on target disk: ${u}"
      else
        local msg
        msg="A backup appears to be running for UUID ${u}."
        msg="${msg} Hint: sudo systemctl status penelope-usb-backup@${u}.service"
        msg="${msg} (and check /var/log/${HOST_SCOPE_NAME}/backup/backup.log)."
        die "${msg}"
      fi
    fi
  done <<<"${uuids}"
}

strip_ws() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

first_partition_for_disk_or_empty() {
  local dev="${1:?disk required}"
  lsblk -ln -o NAME,TYPE "${dev}" 2>/dev/null | awk '$2=="part" {print "/dev/"$1; exit}'
}

block_device_to_parent_disk() {
  local dev="${1:?block device required}"
  local resolved=""
  local type=""
  local parent=""
  resolved="$(readlink -f -- "${dev}" 2>/dev/null || true)"
  [[ -n "${resolved}" ]] || return 1
  dev="${resolved}"
  while [[ -b "${dev}" ]]; do
    type="$(lsblk -dn -o TYPE "${dev}" 2>/dev/null | awk 'NF{print $1; exit}')"
    if [[ "${type}" == "disk" ]]; then
      printf '%s\n' "${dev}"
      return 0
    fi
    parent="$(lsblk -dn -o PKNAME "${dev}" 2>/dev/null | awk 'NF{print $1; exit}')"
    [[ -n "${parent}" ]] || break
    dev="/dev/${parent}"
  done
  return 1
}

parent_disk_for_mountpoint() {
  local mountpoint="${1:?mountpoint required}"
  local source=""
  source="$(findmnt -n -o SOURCE --target "${mountpoint}" 2>/dev/null | awk 'NF{print $1; exit}')"
  [[ -n "${source}" ]] || return 1
  block_device_to_parent_disk "${source}"
}

protected_internal_disk_lines() {
  local -a mountpoints=("/" "/boot" "/boot/efi" "/home" "/_archive" "/_backup")
  local -A reasons=()
  local mp disk current

  for mp in "${mountpoints[@]}"; do
    findmnt -n --target "${mp}" >/dev/null 2>&1 || continue
    disk="$(parent_disk_for_mountpoint "${mp}" 2>/dev/null || true)"
    [[ -n "${disk}" ]] || continue
    current="${reasons[${disk}]:-}"
    if [[ -n "${current}" ]]; then
      reasons["${disk}"]="${current}, ${mp}"
    else
      reasons["${disk}"]="${mp}"
    fi
  done

  for disk in "${!reasons[@]}"; do
    printf '%s\t%s\n' "${disk}" "${reasons[${disk}]}"
  done | sort
}

print_protected_internal_disks() {
  local lines=""
  lines="$(protected_internal_disk_lines || true)"
  >&2 echo
  >&2 echo "Protected disks, not selectable:"
  if [[ -z "${lines}" ]]; then
    >&2 echo "  <none detected>"
    return 0
  fi
  while IFS=$'\t' read -r dev reasons; do
    [[ -n "${dev}" ]] || continue
    >&2 echo "  ${dev}  internal: ${reasons}"
  done <<< "${lines}"
}

is_protected_internal_disk() {
  local dev="${1:?disk required}"
  local disk=""
  local protected=""
  disk="$(block_device_to_parent_disk "${dev}" 2>/dev/null || true)"
  [[ -n "${disk}" ]] || return 1
  while IFS=$'\t' read -r protected _reasons; do
    [[ -n "${protected}" ]] || continue
    if [[ "${protected}" == "${disk}" ]]; then
      return 0
    fi
  done < <(protected_internal_disk_lines || true)
  return 1
}

usb_disk_detail_line() {
  # Output: <dev>\t<size>\t<model>\t<serial>\t<partition>\t<label>\t<uuid>\t<registered>
  local dev="${1:?disk required}"
  local size model serial part label uuid registered
  size="$(lsblk -dn -o SIZE "${dev}" 2>/dev/null | strip_ws || true)"
  model="$(lsblk -dn -o MODEL "${dev}" 2>/dev/null | strip_ws || true)"
  serial="$(lsblk -dn -o SERIAL "${dev}" 2>/dev/null | strip_ws || true)"
  part="$(first_partition_for_disk_or_empty "${dev}" || true)"
  label="-"
  uuid="-"
  registered="no"
  if [[ -n "${part}" ]]; then
    label="$(label_for_partition "${part}" || true)"
    uuid="$(blkid -s UUID -o value "${part}" 2>/dev/null || true)"
    [[ -n "${label}" ]] || label="-"
    [[ -n "${uuid}" ]] || uuid="-"
    if [[ "${uuid}" != "-" ]] && uuid_in_allowlist "${USB_CONF}" "${uuid}"; then
      registered="yes"
    fi
  else
    part="-"
  fi
  [[ -n "${model}" ]] || model="-"
  [[ -n "${serial}" ]] || serial="-"
  [[ -n "${size}" ]] || size="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${dev}" "${size}" "${model}" "${serial}" "${part}" "${label}" "${uuid}" "${registered}"
}

list_usb_disks() {
  # Output lines: <dev>\t<size>\t<model>\t<serial>\t<partition>\t<label>\t<uuid>\t<registered>
  # Filters USB transport disks (including USB-SSD enclosures that may report RM=0).
  local dev
  while IFS= read -r dev; do
    [[ -n "${dev}" ]] || continue
    usb_disk_detail_line "${dev}"
  done < <(lsblk -dn -o NAME,TRAN,TYPE 2>/dev/null | awk '$2=="usb" && $3=="disk" {print "/dev/"$1}' | sort)
}

list_usb_disk_devs() {
  list_usb_disks | awk -F'\t' '{print $1}'
}

disk_has_root_mount() {
  local dev="${1:?disk required}"
  # Refuse to operate on a disk that currently hosts the root filesystem.
  lsblk -ln "${dev}" -o MOUNTPOINT 2>/dev/null | awk '$1=="/" {found=1} END{exit(found?0:1)}'
}

choose_existing_usb_disk() {
  local -a lines=()
  mapfile -t lines < <(list_usb_disks | sort || true)
  [[ "${#lines[@]}" -gt 0 ]] || die "No USB disks detected. Attach the USB disk and rerun."

  print_protected_internal_disks
  >&2 echo
  >&2 echo "Selectable USB disks:"
  local idx=1
  local dev size model serial part label uuid registered line choice
  local -a candidates=()
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r dev size model serial part label uuid registered <<< "${line}"
    if is_protected_internal_disk "${dev}"; then
      continue
    fi
    candidates+=("${line}")
    >&2 echo "  [${idx}] ${dev}  size=${size}  model=${model}  serial=${serial}"
    >&2 echo "      partition=${part}  label=${label}  uuid=${uuid}  registered=${registered}"
    ((idx++))
  done
  [[ "${#candidates[@]}" -gt 0 ]] || die "No selectable USB disks remain after protecting internal Penelope disks."

  >&2 echo
  read -r -p "Select USB disk number: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Invalid selection."
  (( choice >= 1 && choice < idx )) || die "Selection out of range."

  IFS=$'\t' read -r dev size model serial part label uuid registered <<< "${candidates[choice-1]}"

  if is_protected_internal_disk "${dev}"; then
    die "Refusing to operate on protected internal disk: ${dev}."
  fi
  if disk_has_root_mount "${dev}"; then
    die "Refusing to operate on ${dev}: it appears to host the root filesystem (/)."
  fi

  # Preflight: prevent races with penelope-backup auto-start on already-allowlisted disks.
  acquire_backup_locks_for_disk_preflight "${dev}"

  echo "${dev}"
}

pick_new_disk() {
  log "USB disk setup guided selection. Attach the USB disk before selecting it."
  choose_existing_usb_disk
}

part_for_disk() {
  local dev="${1:?disk required}"
  if [[ "${dev}" =~ [0-9]$ ]]; then
    echo "${dev}p1"
  else
    echo "${dev}1"
  fi
}

existing_partition_for_disk() {
  local dev="${1:?disk required}"
  local part
  part="$(lsblk -ln -o NAME,TYPE "${dev}" 2>/dev/null | awk '$2=="part" {print "/dev/"$1; exit}')"
  [[ -n "${part}" ]] || die "No partition found on ${dev}."
  echo "${part}"
}

uuid_for_partition() {
  local part="${1:?partition required}"
  local uuid
  uuid="$(blkid -s UUID -o value "${part}" 2>/dev/null || true)"
  [[ -n "${uuid}" ]] || die "No filesystem UUID found on ${part}."
  echo "${uuid}"
}

label_for_partition() {
  local part="${1:?partition required}"
  blkid -s LABEL -o value "${part}" 2>/dev/null || true
}

unmount_children() {
  local dev="${1:?disk required}"
  local lines
  lines="$(lsblk -ln "${dev}" -o NAME,MOUNTPOINT | tail -n +2 || true)"
  [[ -n "${lines}" ]] || return 0
  while read -r name mp; do
    [[ -n "${mp}" ]] || continue
    log "Unmounting /dev/${name} from ${mp}"
    umount "/dev/${name}" || true
  done <<< "${lines}"
}

disk_remaining_mounts() {
  # Echo '<source><tab><mountpoint>' for mounted partitions of a disk; return 0 if any are mounted.
  local dev="${1:?disk required}"
  local names=""
  names="$(lsblk -ln "${dev}" -o NAME | tail -n +2 2>/dev/null || true)"

  local out=""
  local name=""
  while read -r name; do
    [[ -n "${name}" ]] || continue
    local src="/dev/${name}"
    local mp=""
    while IFS= read -r mp; do
      [[ -n "${mp}" ]] || continue
      out+="${src}"$'\t'"${mp}"$'\n'
    done < <(findmnt -n -o TARGET --source "${src}" 2>/dev/null || true)
  done <<< "${names}"

  [[ -n "${out}" ]] || return 1
  printf "%s" "${out}"
  return 0
}

print_remaining_mounts_table() {
  local mounts_text="${1:-}"
  local src=""
  local mp=""
  while IFS=$'\t' read -r src mp; do
    [[ -n "${src}" ]] || continue
    >&2 echo "  ${src} -> ${mp}"
  done <<< "${mounts_text}"
}

print_busy_diagnostics() {
  local dev="${1:?dev required}"

  >&2 echo
  >&2 echo "----- Busy diagnostics for ${dev} -----"

  # Remaining mounted partitions (if any)
  local mounts=""
  mounts="$(disk_remaining_mounts "${dev}" 2>/dev/null || true)"
  if [[ -n "${mounts}" ]]; then
    >&2 echo "Mounted partitions:"
    print_remaining_mounts_table "${mounts}"
  else
    >&2 echo "Mounted partitions: none detected"
  fi

  # Which mountpoints still reference the block device itself (if any)
  if command -v findmnt >/dev/null 2>&1; then
    local dev_mnts=""
    dev_mnts="$(findmnt -rn --source "${dev}" -o TARGET 2>/dev/null || true)"
    if [[ -n "${dev_mnts}" ]]; then
      >&2 echo "Mountpoints for ${dev}:"
      printf '%s
' "${dev_mnts}" | sed 's/^/  /' >&2
    fi
  fi

  # Process diagnostics (optional)
  if command -v fuser >/dev/null 2>&1; then
    >&2 echo "Processes using ${dev} (fuser -mv):"
    fuser -mv "${dev}" >&2 || true

    if [[ -n "${mounts}" ]]; then
      >&2 echo "Processes using remaining mountpoints (fuser -vm):"
      while IFS=$'\t' read -r _src mp; do
        [[ -n "${mp}" ]] || continue
        fuser -vm "${mp}" >&2 || true
      done <<< "${mounts}"
    fi
  else
    >&2 echo "Tip: install 'psmisc' to get process diagnostics via 'fuser'."
  fi

  >&2 echo "--------------------------------------"
  >&2 echo
}

die_device_busy() {
  local dev="${1:?dev required}"
  local ctx="${2:-operation}"
  local details="${3:-}"
  [[ -n "${details}" ]] && >&2 echo "${details}"
  print_busy_diagnostics "${dev}"
  local msg
  msg="Device ${dev} is still busy (${ctx}). Close any File Manager windows that opened the disk,"
  msg="${msg} wait a few seconds, then rerun."
  msg="${msg} You may also rerun with --force to attempt a stronger unmount."
  die "${msg}"
}

run_cmd_busy_aware() {
  # Usage: run_cmd_busy_aware <dev> <context> <command> [args]
  local dev="${1:?dev required}"
  local ctx="${2:?context required}"
  shift 2
  local out=""
  if ! out="$("$@" 2>&1)"; then
    if echo "${out}" | grep -qiE 'device or resource busy|resource busy|busy'; then
      die_device_busy "${dev}" "${ctx}" "${out}"
    fi
    die "Command failed (${ctx}): $* :: ${out}"
  fi
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

unmount_with_retries() {
  # Try to unmount all mounted partitions of a disk, retrying to cope with desktop automount/indexers.
  local dev="${1:?disk required}"
  local attempts="${2:-5}"
  local sleep_s="${3:-1}"

  local i=1
  while (( i <= attempts )); do
    unmount_children "${dev}"
    if ! disk_remaining_mounts "${dev}" >/dev/null; then
      return 0
    fi
    sleep "${sleep_s}" || true
    ((i++))
  done

  return 1
}

force_unmount_disk_partitions() {
  # Last-resort unmount: try normal umount, then lazy umount for remaining mounts.
  local dev="${1:?disk required}"

  local names
  names="$(lsblk -ln "${dev}" -o NAME | tail -n +2 2>/dev/null || true)"
  [[ -n "${names}" ]] || return 0

  # First pass: normal umount for any mounted partitions.
  while read -r name; do
    [[ -n "${name}" ]] || continue
    local src="/dev/${name}"
    local mnts
    mnts="$(findmnt -n -o TARGET --source "${src}" 2>/dev/null || true)"
    [[ -n "${mnts}" ]] || continue
    while read -r mp; do
      [[ -n "${mp}" ]] || continue
      warn "Force unmount: trying umount ${src} (${mp})"
      umount "${src}" 2>/dev/null || true
    done <<< "${mnts}"
  done <<< "${names}"

  # Second pass: lazy umount anything still mounted.
  while read -r name; do
    [[ -n "${name}" ]] || continue
    local src="/dev/${name}"
    local mnts
    mnts="$(findmnt -n -o TARGET --source "${src}" 2>/dev/null || true)"
    [[ -n "${mnts}" ]] || continue
    while read -r mp; do
      [[ -n "${mp}" ]] || continue
      warn "Force unmount: trying lazy umount -l ${src} (${mp})"
      umount -l "${src}" 2>/dev/null || true
    done <<< "${mnts}"
  done <<< "${names}"
}

handle_busy_mounts() {
  # Returns 0 if mounts are cleared (or already absent), else 1.
  local dev="${1:?disk required}"

  # Initial retries (helps with automount/indexers).
  if unmount_with_retries "${dev}" 5 1; then
    return 0
  fi

  local still=""
  still="$(disk_remaining_mounts "${dev}" || true)"
  warn "Some partitions are still mounted:"
  print_remaining_mounts_table "${still}"

  # Non-interactive: only proceed with force if flag is set.
  if ! is_tty; then
    if (( FORCE_UNMOUNT_BUSY == 1 )); then
      warn "Non-interactive mode: attempting --force unmount."
      force_unmount_disk_partitions "${dev}"
      unmount_with_retries "${dev}" 3 1 || true
      disk_remaining_mounts "${dev}" >/dev/null && return 1 || return 0
    fi
    return 1
  fi

  # Interactive prompt.
  while true; do
    >&2 echo
    >&2 echo "Busy mountpoints detected. Choose an action:"
    >&2 echo "  [Enter] Abort (recommended)"
    >&2 echo "  r       Retry unmount (wait/retry)"
    >&2 echo "  f       Force-unmount (includes lazy unmount), then continue only if mounts are gone"
    >&2 echo "  l       List remaining mountpoints"
    read -r -p "> " ans || ans=""
    case "${ans}" in
      "")
        return 1
        ;;
      r|R)
        log "Retrying unmount"
        unmount_with_retries "${dev}" 5 1 || true
        if ! disk_remaining_mounts "${dev}" >/dev/null; then
          return 0
        fi
        still="$(disk_remaining_mounts "${dev}" || true)"
        warn "Still mounted:"
        print_remaining_mounts_table "${still}"
        ;;
      f|F)
        warn "Attempting force-unmount (lazy unmount as last resort)"
        force_unmount_disk_partitions "${dev}"
        unmount_with_retries "${dev}" 3 1 || true
        if disk_remaining_mounts "${dev}" >/dev/null; then
          still="$(disk_remaining_mounts "${dev}" || true)"
          warn "Mountpoints still present after force-unmount; refusing to proceed:"
          print_remaining_mounts_table "${still}"
          return 1
        fi
        return 0
        ;;
      l|L)
        still="$(disk_remaining_mounts "${dev}" || true)"
        print_remaining_mounts_table "${still}"
        ;;
      *)
        >&2 echo "Please enter: r, f, l, or press Enter to abort."
        ;;
    esac
  done
}

unmount_uuid_if_mounted() {
  local uuid="${1:?uuid required}"
  local dev="${2:?disk required}"

  [[ "${AUTO_UNMOUNT}" == "1" ]] || return 0

  local part="/dev/disk/by-uuid/${uuid}"
  local -a mounts=()
  local mounts_display=""
  mapfile -t mounts < <(findmnt -rn -o TARGET --source "${part}" 2>/dev/null || true)
  (( ${#mounts[@]} > 0 )) || return 0

  mounts_display="$(printf '%s
' "${mounts[@]}" | paste -sd ', ' -)"
  log "Unmounting newly prepared disk (${part}) from ${mounts_display}"
  unmount_all_mounts_for_dev "${part}" || true

  if dev_is_mounted_anywhere "${part}"; then
    warn "Newly prepared disk (${part}) remains mounted after auto-unmount attempt; skipping optional power-off."
    return 0
  fi

  if command -v udisksctl >/dev/null 2>&1; then
    log "Powering off ${dev} (optional safe removal)"
    udisksctl power-off -b "${dev}" >/dev/null 2>&1 || true
  fi
}


ask_yes_no_exact() {
  local prompt="${1:?prompt required}"
  local answer=""
  [[ -t 0 ]] || die "Interactive Yes/No confirmation required: ${prompt}"
  while true; do
    read -r -p "${prompt} Type Yes or No: " answer </dev/tty || answer=""
    case "${answer}" in
      Yes)
        return 0
        ;;
      No)
        return 1
        ;;
      *)
        >&2 echo "Please type exactly Yes or No. Uppercase and lowercase matter."
        ;;
    esac
  done
}

count_disk_partitions() {
  local dev="${1:?disk required}"
  lsblk -ln -o TYPE "${dev}" 2>/dev/null | awk '$1=="part" {count++} END{print count+0}'
}

human_du() {
  local path="${1:?path required}"
  du -sh -- "${path}" 2>/dev/null | awk 'NF{print $1; exit}' || true
}

internal_backup_footprint_estimate_kib() {
  local repo_base="/_backup/${HOST_SCOPE_NAME}"
  local target=""
  local total="0"
  [[ -d "${repo_base}" ]] || { printf '0\n'; return 0; }
  for target in system home _archive; do
    if [[ -d "${repo_base}/${target}" ]]; then
      total="$(( total + $(du -sk -- "${repo_base}/${target}" 2>/dev/null | awk 'NF{print $1; exit}' || echo 0) ))"
    fi
  done
  printf '%s\n' "${total}"
}

print_internal_backup_footprint_estimate() {
  local repo_base="/_backup/${HOST_SCOPE_NAME}"
  local target=""
  local estimate_kib=""
  >&2 echo
  >&2 echo "Internal backup footprint estimate for this host:"
  if [[ ! -d "${repo_base}" ]]; then
    >&2 echo "  ${repo_base}: not present yet"
    return 0
  fi
  for target in system home _archive; do
    if [[ -d "${repo_base}/${target}" ]]; then
      >&2 echo "  ${target}: $(human_du "${repo_base}/${target}")"
    else
      >&2 echo "  ${target}: not present"
    fi
  done
  estimate_kib="$(internal_backup_footprint_estimate_kib)"
  >&2 echo "  estimated total KiB: ${estimate_kib}"
  >&2 echo "  source: ${repo_base}"
}

mount_partition_for_inspection() {
  local part="${1:?partition required}"
  local mountpoint_var="${2:?mountpoint variable name required}"
  local mounted_by_us_var="${3:?mounted-by-us variable name required}"
  local detected_mountpoint=""
  local detected_mounted_by_us="0"
  local temp_root="${RUN_DIR}/usb-disk-setup-inspect.$$"
  local -a mountpoints=()

  mapfile -t mountpoints < <(findmnt -n -o TARGET --source "${part}" 2>/dev/null)
  case "${#mountpoints[@]}" in
    0)
      require_cmd mount
      mkdir -p "${temp_root}"
      if ! mount -o ro "${part}" "${temp_root}" 2>/dev/null; then
        rmdir "${temp_root}" 2>/dev/null || true
        return 1
      fi
      detected_mountpoint="${temp_root}"
      detected_mounted_by_us="1"
      ;;
    1)
      detected_mountpoint="${mountpoints[0]}"
      ;;
    *)
      die "Ambiguous mount state for ${part}: multiple active mount targets detected (${mountpoints[*]}). Unmount stale/duplicate targets first and rerun inspection."
      ;;
  esac

  printf -v "${mountpoint_var}" '%s' "${detected_mountpoint}"
  printf -v "${mounted_by_us_var}" '%s' "${detected_mounted_by_us}"
}

unmount_inspection_mount() {
  local mountpoint="${1:?mountpoint required}"
  local mounted_by_us="${2:?mounted-by-us required}"
  if [[ "${mounted_by_us}" == "1" ]]; then
    umount "${mountpoint}" 2>/dev/null || true
    rmdir "${mountpoint}" 2>/dev/null || true
  fi
}

print_selected_disk_capacity_summary() {
  local part="${1:?partition required}"
  local mountpoint=""
  local mounted_by_us="0"
  local scope=""
  local scopes=""
  local free_kib=""
  local estimate_kib=""
  if ! mount_partition_for_inspection "${part}" mountpoint mounted_by_us; then
    warn "Could not mount ${part} read-only for capacity/scope inspection."
    return 0
  fi

  >&2 echo
  >&2 echo "Selected disk capacity:"
  df -h --output=size,used,avail,pcent,target "${mountpoint}" 2>/dev/null | sed 's/^/  /' >&2 || true
  free_kib="$(df -Pk "${mountpoint}" 2>/dev/null | awk 'NR==2 {print $4; exit}')"

  >&2 echo
  >&2 echo "Detected Penelope host scopes on this disk:"
  scopes="$(find "${mountpoint}" -mindepth 2 -maxdepth 2 -type d \( -name system -o -name home -o -name _archive \) -printf '%P\n' 2>/dev/null \
    | awk -F/ 'NF==2 {print $1}' | sort -u || true)"
  if [[ -z "${scopes}" ]]; then
    >&2 echo "  <none detected>"
  else
    while IFS= read -r scope; do
      [[ -n "${scope}" ]] || continue
      >&2 echo "  ${scope}: $(human_du "${mountpoint}/${scope}")"
    done <<< "${scopes}"
  fi

  unmount_inspection_mount "${mountpoint}" "${mounted_by_us}"
  print_internal_backup_footprint_estimate
  estimate_kib="$(internal_backup_footprint_estimate_kib)"
  if [[ "${free_kib}" =~ ^[0-9]+$ && "${estimate_kib}" =~ ^[0-9]+$ ]] && (( estimate_kib > 0 && free_kib < estimate_kib )); then
    warn "Free space on the selected disk is below the current internal-backup footprint estimate. The first external backup may fail due to insufficient space."
  fi
}

format_scope_list_one_line() {
  local scopes_text="${1:-}"
  printf '%s\n' "${scopes_text}" | awk 'NF{print}' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

classify_scope_set() {
  local scopes_text="${1:-}"
  local has_current="0"
  local has_foreign="0"
  local scope=""
  if [[ -z "$(printf '%s\n' "${scopes_text}" | awk 'NF{print; exit}')" ]]; then
    printf '%s\n' "no-penelope-structure"
    return 0
  fi
  while IFS= read -r scope; do
    [[ -n "${scope}" ]] || continue
    if [[ "${scope}" == "${HOST_SCOPE_NAME}" ]]; then
      has_current="1"
    else
      has_foreign="1"
    fi
  done <<< "${scopes_text}"
  if [[ "${has_current}" == "1" && "${has_foreign}" == "1" ]]; then
    printf '%s\n' "current-and-foreign-scopes"
  elif [[ "${has_current}" == "1" ]]; then
    printf '%s\n' "current-scope-only"
  else
    printf '%s\n' "foreign-scope-only"
  fi
}

confirm_add_current_host_to_existing_disk() {
  local uuid="${1:?uuid required}"
  local scopes="${2:-}"
  local class="${3:?class required}"
  >&2 echo
  >&2 echo "Existing Penelope backup structure detected on selected disk."
  >&2 echo "  current HOST_SCOPE_NAME: ${HOST_SCOPE_NAME}"
  >&2 echo "  partition UUID:          ${uuid}"
  >&2 echo "  scope classification:    ${class}"
  >&2 echo "  detected scopes:         $(format_scope_list_one_line "${scopes}")"
  >&2 echo
  >&2 echo "Penelope will register this disk for this host without deleting existing scopes."
  >&2 echo "Normal external backups will write only below the current HOST_SCOPE_NAME scope."
  ask_yes_no_exact "Add this host to the existing disk without deleting old backups?" \
    || die "Aborted by user."
}

require_single_or_empty_partition_for_guided() {
  local dev="${1:?disk required}"
  local count=""
  count="$(count_disk_partitions "${dev}")"
  if (( count > 1 )); then
    >&2 echo
    >&2 echo "Selected disk has ${count} partitions. Guided registration supports empty disks or one data partition."
    >&2 echo "To reinitialize this disk as a new Penelope USB backup disk, the destructive erase confirmation will still be required."
    if ask_yes_no_exact "Treat ${dev} as a new/disposable disk and reinitialize it?"; then
      return 1
    fi
    die "Aborted by user because disk layout is ambiguous."
  fi
  return 0
}

set_filesystem_label() {
  local part="${1:?partition required}"
  local new_label="${2:?new label required}"
  local fstype=""
  validate_operator_disk_name "${new_label}"
  fstype="$(blkid -s TYPE -o value "${part}" 2>/dev/null || true)"
  case "${fstype}" in
    ext2|ext3|ext4)
      require_cmd e2label
      e2label "${part}" "${new_label}"
      ;;
    exfat)
      if command -v exfatlabel >/dev/null 2>&1; then
        exfatlabel "${part}" "${new_label}"
      elif command -v tune.exfat >/dev/null 2>&1; then
        tune.exfat -L "${new_label}" "${part}"
      else
        die "Cannot rename exFAT filesystem label: install exfatprogs or rename the label manually."
      fi
      ;;
    *)
      die "Unsupported filesystem type for label rename on ${part}: ${fstype:-unknown}."
      ;;
  esac
}

maybe_relabel_existing_partition_to_disk_name() {
  local part="${1:?partition required}"
  local current_label="${2:-}"
  local uuid="${3:?uuid required}"
  local display_label="${current_label:-<none>}"
  [[ -n "${DISK_NAME}" ]] || die "DISK_NAME is required before label comparison."
  if [[ "${current_label}" == "${DISK_NAME}" ]]; then
    return 0
  fi
  >&2 echo
  >&2 echo "Filesystem label and DISK_NAME differ."
  >&2 echo "  partition:        ${part}"
  >&2 echo "  partition UUID:   ${uuid}"
  >&2 echo "  filesystem label: ${display_label}"
  >&2 echo "  DISK_NAME:        ${DISK_NAME}"
  if ask_yes_no_exact "Rename filesystem label to ${DISK_NAME} now?"; then
    set_filesystem_label "${part}" "${DISK_NAME}"
    log "Filesystem label on ${part} renamed to ${DISK_NAME}"
  else
    warn "Keeping existing filesystem label '${display_label}' while registering DISK_NAME '${DISK_NAME}'."
  fi
}

update_allowlist_disk_name() {
  local uuid="${1:?uuid required}"
  local old_name="${2:?old name required}"
  local new_name="${3:?new name required}"
  local usb_conf_dir=""
  local tmp_allowlist=""
  validate_operator_disk_name "${new_name}"
  validate_usb_allowlist_disk_names "${USB_CONF}"
  ensure_unique_usb_allowlist_disk_name "${USB_CONF}" "${uuid}" "${new_name}"

  usb_conf_dir="$(dirname "${USB_CONF}")"
  tmp_allowlist="$(mktemp "${usb_conf_dir}/usb-backup-disks.conf.tmp.XXXXXX")"
  chmod 600 "${tmp_allowlist}" 2>/dev/null || true
  chown root:root "${tmp_allowlist}" 2>/dev/null || true

  awk -v uuid="${uuid}" -v old="${old_name}" -v new="${new_name}" '
    /^[[:space:]]*($|#)/ { print; next }
    $1 == uuid && $2 == old { print uuid " " new; next }
    { print }
  ' "${USB_CONF}" > "${tmp_allowlist}"

  validate_usb_allowlist_disk_names "${tmp_allowlist}"
  mv -f -- "${tmp_allowlist}" "${USB_CONF}"
  chmod 600 "${USB_CONF}" 2>/dev/null || true
  chown root:root "${USB_CONF}" 2>/dev/null || true
  refresh_usb_autorun_rules_after_allowlist_change
}

confirm_destruction() {
  local dev="${1:?disk required}"
  local part expected confirm
  part="$(part_for_disk "${dev}")"
  validate_operator_disk_name "${DISK_NAME}"
  expected="erase ${dev} for ${DISK_NAME}"

  >&2 echo
  >&2 echo "Selected device: ${dev}"
  lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT,FSTYPE,LABEL,UUID "${dev}" >&2 || true
  >&2 echo
  >&2 echo "Planned changes:"
  >&2 echo "  - Wipe signatures and partition table on ${dev}"
  >&2 echo "  - Create GPT + 1 partition (${part})"
  >&2 echo "  - Format ${part} as ${FS_TYPE} (label: ${LABEL})"
  >&2 echo "  - Append filesystem UUID to: ${USB_CONF}"
  >&2 echo "  - Store disk name alongside UUID: ${DISK_NAME}"
  >&2 echo
  >&2 echo "DESTRUCTIVE ACTION: all existing data on ${dev} will be erased."
  >&2 echo

  if [[ ! -r /dev/tty ]]; then
    die "No controlling TTY is available for destructive USB disk confirmation. Rerun interactively."
  fi

  confirm=""
  read -r -p "Type exactly '${expected}' to continue: " confirm </dev/tty || true
  [[ "${confirm}" == "${expected}" ]] || die "Aborted by user."
}

format_disk() {
  local dev="${1:?disk required}"
  local part
  part="$(part_for_disk "${dev}")"

  confirm_destruction "${dev}"

  # Try to clear any automounts; if they remain, offer retry/force-unmount.
  # Still refuses to proceed if mounts persist.
  if ! handle_busy_mounts "${dev}"; then
    die "Please close any open files (or disable automount), then rerun the setup. (Use --force to try harder.)"
  fi

  require_cmd_many wipefs parted udevadm blkid

  log "Wiping signatures on ${dev}"
  local wipe_out=""
  if ! wipe_out="$(wipefs -a "${dev}" 2>&1)"; then
    if echo "${wipe_out}" | grep -qiE 'device or resource busy|resource busy|busy'; then
      die_device_busy "${dev}" "wipefs" "${wipe_out}"
    fi
    warn "wipefs failed (ignored): ${wipe_out}"
  fi

  log "Creating GPT and single partition"
  run_cmd_busy_aware "${dev}" "parted mklabel" parted -s "${dev}" mklabel gpt
  run_cmd_busy_aware "${dev}" "parted mkpart" parted -s "${dev}" mkpart primary 1MiB 100%
  # For best Windows compatibility on GPT (exFAT), mark as "Microsoft basic data".
  if [[ "${FS_TYPE}" == "exfat" ]]; then
    parted -s "${dev}" set 1 msftdata on || true
  fi
  partprobe "${dev}" || true
  if ! udevadm settle --timeout=10 2>/dev/null; then
    warn "udevadm settle timeout after partprobe; using sleep 2 as fallback"
    sleep 2
  fi

  local _attempt
  for _attempt in {1..10}; do
    [[ -b "${part}" ]] && break
    sleep 1
  done
  [[ -b "${part}" ]] || die "Partition not detected: ${part}"

  case "${FS_TYPE}" in
    ext4)
      require_cmd mkfs.ext4
      log "Formatting ${part} as ext4 (label: ${LABEL})"
      mkfs.ext4 -F -L "${LABEL}" "${part}" >&2
      ;;
    exfat)
      require_cmd mkfs.exfat
      log "Formatting ${part} as exFAT (label: ${LABEL})"
      mkfs.exfat -n "${LABEL}" "${part}" >&2
      ;;
    *)
      die "Unsupported FS_TYPE=${FS_TYPE}. Supported: ext4 | exfat"
      ;;
  esac

  # Wait for device synchronization after mkfs
  if ! udevadm settle --timeout=10 2>/dev/null; then
    warn "udevadm settle timeout after mkfs; using sleep 2 as fallback"
    sleep 2
  fi

  # UUID extraction with retry logic (max 5 attempts, 1s intervals)
  local uuid=""
  local max_attempts=5
  local attempt
  for attempt in $(seq 1 $max_attempts); do
    uuid="$(blkid -s UUID -o value "${part}" 2>/dev/null || true)"
    if [[ -n "${uuid}" ]]; then
      log "UUID extracted: ${uuid} (${part})"
      echo "${uuid}"
      return 0
    fi
    if (( attempt < max_attempts )); then
      warn "UUID for ${part} not yet available, retry ${attempt}/${max_attempts}"
      sleep 1
    fi
  done

  die "UUID extraction failed for ${part} after ${max_attempts} attempts. Device not ready or filesystem creation failed."
}

detect_existing_penelope_scopes() {
  local part="${1:?partition required}"
  local mountpoint=""
  local mounted_by_us="0"
  local scopes=""

  if ! mount_partition_for_inspection "${part}" mountpoint mounted_by_us; then
    return 0
  fi

  scopes="$(find "${mountpoint}" -mindepth 2 -maxdepth 2 -type d \( -name system -o -name home -o -name _archive \) -printf '%P\n' 2>/dev/null \
    | awk -F/ 'NF==2 {print $1}' | sort -u || true)"

  unmount_inspection_mount "${mountpoint}" "${mounted_by_us}"
  printf '%s\n' "${scopes}"
}

inspect_existing_penelope_structure() {
  local part="${1:?partition required}"
  local scopes=""
  scopes="$(detect_existing_penelope_scopes "${part}")"
  [[ -n "${scopes}" ]] || die "No plausible Penelope backup structure found on ${part}. Use guided setup or --prepare-new for a new/disposable disk, or verify the existing disk contents first."
  printf "%s\n" "${scopes}"
}

scope_list_contains() {
  local wanted="${1:?scope required}"
  local candidate=""
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == "${wanted}" ]]; then
      return 0
    fi
  done
  return 1
}

die_existing_disk_scope_mismatch() {
  local expected_scope="${1:?expected scope required}"
  local scopes_text="${2:-}"
  local joined=""
  local message=""
  joined="$(printf '%s\n' "${scopes_text}" | awk 'NF{print}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -z "${joined}" ]]; then
    message="Existing USB backup disk does not contain the current HOST_SCOPE_NAME=${expected_scope} "
    message+="and no host-scope directories were detected. Register the correct disk for this system "
    message+="or use --prepare-new for a new disk."
    die "${message}"
  fi
  message="Existing USB backup disk does not contain the current HOST_SCOPE_NAME=${expected_scope}. "
  message+="Detected host-scope directories: ${joined}. Register the correct disk for this system "
  message+="instead of allow-listing a foreign scope by mistake."
  die "${message}"
}

append_uuid_allowlist() {
  local uuid="${1:?uuid required}"
  local existing_name=""

  [[ -n "${DISK_NAME}" ]] || die "DISK_NAME is mandatory."
  assert_usb_allowlist_uuid_value "${uuid}" "Refusing to register invalid filesystem UUID"

  mkdir -p "$(dirname "${USB_CONF}")"
  if [[ ! -f "${USB_CONF}" ]]; then
    install -m 0600 -o root -g root /dev/null "${USB_CONF}"
  fi

  validate_usb_allowlist_disk_names "${USB_CONF}"
  ensure_unique_usb_allowlist_disk_name "${USB_CONF}" "${uuid}" "${DISK_NAME}"
  existing_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  if [[ -n "${existing_name}" ]]; then
    if [[ "${existing_name}" == "${DISK_NAME}" ]]; then
      log "UUID already present in allow-list: ${uuid} (${DISK_NAME})"
      return 0
    fi
    die "UUID ${uuid} is already registered in ${USB_CONF} with DISK_NAME '${existing_name}'. Refusing to overwrite it with '${DISK_NAME}'."
  fi

  local usb_conf_dir="" tmp_allowlist=""
  usb_conf_dir="$(dirname "${USB_CONF}")"
  tmp_allowlist="$(mktemp "${usb_conf_dir}/usb-backup-disks.conf.tmp.XXXXXX")"
  chmod 600 "${tmp_allowlist}" 2>/dev/null || true
  chown root:root "${tmp_allowlist}" 2>/dev/null || true
  cp -- "${USB_CONF}" "${tmp_allowlist}"

  log "Registering UUID in ${USB_CONF}: ${uuid} ${DISK_NAME}"
  echo "${uuid} ${DISK_NAME}" >> "${tmp_allowlist}"
  validate_usb_allowlist_disk_names "${tmp_allowlist}"

  mv -f -- "${tmp_allowlist}" "${USB_CONF}"
  tmp_allowlist=""

  chmod 600 "${USB_CONF}" 2>/dev/null || true
  chown root:root "${USB_CONF}" 2>/dev/null || true
  refresh_usb_autorun_rules_after_allowlist_change
}

print_next_steps() {
  local dev="${1:?disk required}"
  local part="${2:?partition required}"
  local uuid="${3:?uuid required}"
  local label_value="${4:-}"
  local mode_summary="${5:?mode summary required}"

  >&2 echo
  log "Done. ${mode_summary}"
  >&2 echo "  device: ${dev}"
  >&2 echo "  part:   ${part}"
  >&2 echo "  uuid:   ${uuid}"
  if [[ -n "${DISK_NAME}" ]]; then
    >&2 echo "  name:   ${DISK_NAME}"
    >&2 echo "  physical label to apply now: ${DISK_NAME}"
  fi
  if [[ -n "${label_value}" ]]; then
    >&2 echo "  label:  ${label_value}"
  fi
  if [[ "${MODE}" == "prepare-new" ]]; then
    >&2 echo "  fs:     ${FS_TYPE}"
  fi
  >&2 echo "  allow:  ${USB_CONF}"
  >&2 echo
  >&2 echo "Registered disks on this system:"
  >&2 echo "  sudo cat ${USB_CONF}"
  >&2 echo
  >&2 echo "Manual backup run:"
  >&2 echo "  sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid ${uuid}"
  >&2 echo
  >&2 echo "Auto-run (if enabled):"
  >&2 echo "  1) Unplug the disk"
  >&2 echo "  2) Plug it in again (udev will trigger penelope-usb-backup@${uuid}.service)"
  >&2 echo
  >&2 echo "Optional safe removal (if mounted by the system):"
  >&2 echo "  sudo umount /dev/disk/by-uuid/${uuid}  # if mounted"
  if command -v udisksctl >/dev/null 2>&1; then
    >&2 echo "  sudo udisksctl power-off -b ${dev}"
  fi
}

complete_already_registered_disk() {
  local dev="${1:?disk required}"
  local part="${2:?partition required}"
  local uuid="${3:?uuid required}"
  local label_value="${4:-}"
  local existing_name=""
  existing_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  [[ -n "${existing_name}" ]] || die "UUID ${uuid} is registered but has no DISK_NAME in ${USB_CONF}."
  DISK_NAME="${existing_name}"
  OPS_EVENT_UUID="${uuid}"
  if [[ -n "${part}" && -b "${part}" ]]; then
    print_selected_disk_capacity_summary "${part}"
  fi
  refresh_usb_autorun_rules_after_allowlist_change
  write_ops_backup_dashboard_status "success" "usb-disk-setup-idempotent" "USB backup disk already registered; no changes needed." "${uuid}"
  OPS_EVENT_FINALIZED="1"
  print_next_steps "${dev}" "${part}" "${uuid}" "${label_value}" "USB backup disk already registered; no changes needed:"
}

prepare_selected_disk_as_new() {
  local dev="${1:?disk required}"
  local uuid part
  ensure_disk_name "" "Disk name / filesystem label"
  resolve_label_for_prepare_new

  if disk_has_root_mount "${dev}"; then
    die "Refusing to operate on ${dev}: it appears to host the root filesystem (/)."
  fi

  uuid="$(format_disk "${dev}")"
  part="$(part_for_disk "${dev}")"
  append_uuid_allowlist "${uuid}"
  OPS_EVENT_UUID="${uuid}"
  sync || true
  unmount_uuid_if_mounted "${uuid}" "${dev}"
  write_ops_backup_dashboard_status "success" "usb-disk-setup-success" "Prepared and registered a new USB backup disk." "${uuid}"
  OPS_EVENT_FINALIZED="1"
  print_next_steps "${dev}" "${part}" "${uuid}" "${LABEL}" "Prepared and registered USB backup disk:"
}

register_selected_existing_disk() {
  local dev="${1:?disk required}"
  local part="${2:?partition required}"
  local uuid="${3:?uuid required}"
  local label_value="${4:-}"
  local scopes="${5:-}"
  local class=""
  if [[ -n "${label_value}" ]]; then
    log "Existing filesystem label on ${part}: ${label_value}"
  else
    log "Existing filesystem label on ${part}: <none>"
  fi
  log "Detected host-scope directories on existing disk: $(format_scope_list_one_line "${scopes}")"

  class="$(classify_scope_set "${scopes}")"
  case "${class}" in
    current-scope-only|current-and-foreign-scopes|foreign-scope-only)
      confirm_add_current_host_to_existing_disk "${uuid}" "${scopes}" "${class}"
      ;;
    *)
      die "No plausible Penelope backup structure found on ${part}. Use guided setup or --prepare-new for a new/disposable disk."
      ;;
  esac

  print_selected_disk_capacity_summary "${part}"
  ensure_disk_name "${label_value}" "Disk name / filesystem label"
  maybe_relabel_existing_partition_to_disk_name "${part}" "${label_value}" "${uuid}"
  label_value="$(label_for_partition "${part}" || true)"
  append_uuid_allowlist "${uuid}"
  OPS_EVENT_UUID="${uuid}"
  sync || true
  write_ops_backup_dashboard_status \
    "success" \
    "usb-disk-setup-success" \
    "Registered an existing Penelope USB backup disk without reformatting." \
    "${uuid}"
  OPS_EVENT_FINALIZED="1"
  print_next_steps "${dev}" "${part}" "${uuid}" "${label_value}" "Registered existing USB backup disk without reformatting:"
}

guided_setup() {
  local dev part uuid label_value scopes partition_count
  dev="$(choose_existing_usb_disk)"
  partition_count="$(count_disk_partitions "${dev}")"
  if (( partition_count > 1 )); then
    if ! require_single_or_empty_partition_for_guided "${dev}"; then
      log "Selected disk will be reinitialized as a new/disposable USB backup disk after exact confirmation."
      prepare_selected_disk_as_new "${dev}"
      return 0
    fi
  fi

  part="$(first_partition_for_disk_or_empty "${dev}" || true)"
  if [[ -n "${part}" ]]; then
    uuid="$(blkid -s UUID -o value "${part}" 2>/dev/null || true)"
    label_value="$(label_for_partition "${part}" || true)"
  else
    uuid=""
    label_value=""
  fi

  if [[ -n "${uuid}" ]] && uuid_in_allowlist "${USB_CONF}" "${uuid}"; then
    complete_already_registered_disk "${dev}" "${part}" "${uuid}" "${label_value}"
    return 0
  fi

  if [[ -z "${part}" || -z "${uuid}" ]]; then
    log "Selected disk has no usable filesystem UUID yet; it will be treated as a new/disposable USB backup disk."
    prepare_selected_disk_as_new "${dev}"
    return 0
  fi

  scopes="$(detect_existing_penelope_scopes "${part}")"
  if [[ -n "${scopes}" ]]; then
    register_selected_existing_disk "${dev}" "${part}" "${uuid}" "${label_value}" "${scopes}"
    return 0
  fi

  print_selected_disk_capacity_summary "${part}"
  >&2 echo
  >&2 echo "No plausible Penelope backup structure was detected on ${part}."
  >&2 echo "Preparing this disk as a new Penelope USB backup disk will erase all existing data on ${dev}."
  if ask_yes_no_exact "Treat this disk as new/disposable and continue to the exact erase confirmation?"; then
    prepare_selected_disk_as_new "${dev}"
    return 0
  fi
  die "Aborted by user."
}


print_registered_usb_disks() {
  validate_usb_allowlist_disk_names "${USB_CONF}"
  if [[ ! -f "${USB_CONF}" ]] || [[ "$(count_usb_allowlist_entries "${USB_CONF}")" == "0" ]]; then
    echo "No registered Penelope USB backup disks found in ${USB_CONF}."
    return 0
  fi

  echo "Registered Penelope USB backup disks from ${USB_CONF}:"
  printf '%-38s  %s\n' "UUID" "DISK_NAME"
  printf '%-38s  %s\n' "--------------------------------------" "---------"
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      uuid=$1
      name=$2
      if (uuid != "" && name != "") {
        printf "%-38s  %s\n", uuid, name
      }
    }
  ' "${USB_CONF}"
}

resolve_registered_disk_for_deregister() {
  local match_count=0
  local raw entry_uuid entry_name
  DEREGISTER_RESOLVED_UUID=""
  DEREGISTER_RESOLVED_DISK_NAME=""

  validate_usb_allowlist_disk_names "${USB_CONF}"
  [[ -f "${USB_CONF}" ]] || die "USB allow-list not found: ${USB_CONF}"

  if [[ -n "${DEREGISTER_UUID}" && -n "${DEREGISTER_DISK_NAME}" ]]; then
    die "Use exactly one selector for --deregister: --uuid <UUID> or --disk-name <DISK_NAME>."
  fi
  if [[ -z "${DEREGISTER_UUID}" && -z "${DEREGISTER_DISK_NAME}" ]]; then
    die "--deregister requires exactly one selector: --uuid <UUID> or --disk-name <DISK_NAME>."
  fi

  if [[ -n "${DEREGISTER_UUID}" ]]; then
    assert_usb_allowlist_uuid_value "${DEREGISTER_UUID}" "--uuid"
  fi
  if [[ -n "${DEREGISTER_DISK_NAME}" ]]; then
    validate_operator_disk_name "${DEREGISTER_DISK_NAME}"
  fi

  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    entry_uuid="${raw%%[[:space:]]*}"
    entry_name="${raw#"${entry_uuid}"}"
    entry_name="${entry_name#"${entry_name%%[![:space:]]*}"}"
    entry_name="${entry_name%%[[:space:]]*}"
    if [[ -n "${DEREGISTER_UUID}" && "${entry_uuid}" != "${DEREGISTER_UUID}" ]]; then
      continue
    fi
    if [[ -n "${DEREGISTER_DISK_NAME}" && "${entry_name}" != "${DEREGISTER_DISK_NAME}" ]]; then
      continue
    fi
    match_count=$((match_count + 1))
    DEREGISTER_RESOLVED_UUID="${entry_uuid}"
    DEREGISTER_RESOLVED_DISK_NAME="${entry_name}"
  done < "${USB_CONF}"

  if (( match_count != 1 )); then
    if [[ -n "${DEREGISTER_UUID}" ]]; then
      die "Expected exactly one registered USB disk with UUID ${DEREGISTER_UUID} in ${USB_CONF}; found ${match_count}."
    fi
    die "Expected exactly one registered USB disk with DISK_NAME ${DEREGISTER_DISK_NAME} in ${USB_CONF}; found ${match_count}."
  fi
}

confirm_deregister_registered_disk() {
  local uuid="${1:?uuid required}"
  local disk_name="${2:?disk name required}"
  local expected=""
  local entered=""

  if [[ "${DEREGISTER_SELECTOR_KIND}" == "disk-name" ]]; then
    expected="deregister ${disk_name}"
  else
    expected="deregister ${uuid}"
  fi

  >&2 echo
  >&2 echo "Deregister Penelope USB backup disk from this host:"
  >&2 echo "  uuid: ${uuid}"
  >&2 echo "  name: ${disk_name}"
  >&2 echo "  allow-list: ${USB_CONF}"
  >&2 echo
  >&2 echo "This is non-destructive: it removes only the local allow-list entry and per-disk dashboard signals."
  >&2 echo "It does not format the disk, delete repositories, or erase backup data."
  >&2 echo

  if [[ ! -r /dev/tty ]]; then
    die "No controlling TTY is available for deregister confirmation. Rerun interactively."
  fi

  read -r -p "Type exactly '${expected}' to continue: " entered </dev/tty || true
  [[ "${entered}" == "${expected}" ]] || die "Aborted by user."
}

remove_allowlist_entry_for_uuid() {
  local uuid="${1:?uuid required}"
  local expected_name="${2:?disk name required}"
  local usb_conf_dir=""
  local tmp_allowlist=""

  usb_conf_dir="$(dirname "${USB_CONF}")"
  tmp_allowlist="$(mktemp "${usb_conf_dir}/usb-backup-disks.conf.tmp.XXXXXX")"
  chmod 600 "${tmp_allowlist}" 2>/dev/null || true
  chown root:root "${tmp_allowlist}" 2>/dev/null || true

  awk -v uuid="${uuid}" -v expected_name="${expected_name}" '
    BEGIN { removed=0 }
    /^[[:space:]]*($|#)/ { print; next }
    {
      if ($1 == uuid && $2 == expected_name) {
        removed++
        next
      }
      print
    }
    END {
      if (removed != 1) {
        exit 42
      }
    }
  ' "${USB_CONF}" > "${tmp_allowlist}" || {
    rm -f -- "${tmp_allowlist}" 2>/dev/null || true
    die "Failed to remove exactly one allow-list entry for UUID ${uuid} (${expected_name}) from ${USB_CONF}."
  }

  validate_usb_allowlist_disk_names "${tmp_allowlist}"
  mv -f -- "${tmp_allowlist}" "${USB_CONF}"
  tmp_allowlist=""
  chmod 600 "${USB_CONF}" 2>/dev/null || true
  chown root:root "${USB_CONF}" 2>/dev/null || true
  refresh_usb_autorun_rules_after_allowlist_change
}

clear_deregistered_disk_dashboard_signals() {
  local disk_name="${1:?disk name required}"
  local ready_file running_file hold_file reattach_file retry_file last_external_json
  ensure_ops_backup_dashboard
  ready_file="$(usb_signal_file_path ready "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  running_file="$(usb_signal_file_path running "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_file="$(usb_signal_file_path reattach_and_wait "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  retry_file="$(usb_legacy_retry_signal_file_path "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  last_external_json="$(usb_external_status_json_path "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  clear_backup_dashboard_files \
    "${ready_file}" \
    "${running_file}" \
    "${hold_file}" \
    "${reattach_file}" \
    "${retry_file}" \
    "${last_external_json}"
}

deregister_registered_disk() {
  local uuid="" disk_name=""
  resolve_registered_disk_for_deregister
  uuid="${DEREGISTER_RESOLVED_UUID}"
  disk_name="${DEREGISTER_RESOLVED_DISK_NAME}"
  OPS_EVENT_UUID="${uuid}"

  if acquire_backup_lock_for_uuid "${uuid}"; then
    log "Acquired backup lock for deregister preflight: ${uuid}"
  else
    die "A backup appears to be running for UUID ${uuid}. Stop the backup first, then retry deregistration."
  fi

  confirm_deregister_registered_disk "${uuid}" "${disk_name}"
  remove_allowlist_entry_for_uuid "${uuid}" "${disk_name}"
  clear_deregistered_disk_dashboard_signals "${disk_name}"
  write_ops_backup_dashboard_status "success" "usb-disk-setup-deregistered" "Deregistered USB backup disk ${disk_name}; backup data was not erased." "${uuid}"
  OPS_EVENT_FINALIZED="1"

  log "Deregistered USB backup disk ${disk_name} (${uuid}) from ${USB_CONF}."
  >&2 echo
  >&2 echo "The disk and repositories were not modified. To use this disk again on this host, register it again."
}

rename_registered_disk() {
  local dev part uuid label_value old_name new_name
  dev="$(choose_existing_usb_disk)"
  part="$(existing_partition_for_disk "${dev}")"
  uuid="$(uuid_for_partition "${part}")"
  label_value="$(label_for_partition "${part}")"
  old_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  [[ -n "${old_name}" ]] || die "Selected disk UUID ${uuid} is not registered in ${USB_CONF}; register it before renaming."
  DISK_NAME=""
  ensure_disk_name "${old_name}" "New disk name / filesystem label"
  new_name="${DISK_NAME}"
  if [[ "${new_name}" == "${old_name}" ]]; then
    log "DISK_NAME is already ${old_name}; allow-list rename not needed."
  else
    >&2 echo
    >&2 echo "Rename registered USB backup disk:"
    >&2 echo "  uuid:     ${uuid}"
    >&2 echo "  old name: ${old_name}"
    >&2 echo "  new name: ${new_name}"
    ask_yes_no_exact "Update ${USB_CONF} from ${old_name} to ${new_name}?" || die "Aborted by user."
    update_allowlist_disk_name "${uuid}" "${old_name}" "${new_name}"
    log "Updated ${USB_CONF}: ${uuid} ${new_name}"
  fi
  maybe_relabel_existing_partition_to_disk_name "${part}" "${label_value}" "${uuid}"
  label_value="$(label_for_partition "${part}" || true)"
  OPS_EVENT_UUID="${uuid}"
  write_ops_backup_dashboard_status "success" "usb-disk-setup-success" "Renamed a registered USB backup disk." "${uuid}"
  OPS_EVENT_FINALIZED="1"
  print_next_steps "${dev}" "${part}" "${uuid}" "${label_value}" "Renamed registered USB backup disk:"
}

main() {
  parse_cli "$@"
  require_root "sudo -E $0"
  [[ -f "${CONF_FILE}" ]] || die "Missing config: ${CONF_FILE}"
  load_backup_runtime_context_from_conf "${CONF_FILE}" "${BACKUP_DASHBOARD_DIR}"
  acquire_setup_lock
  trap 'cleanup_usb_setup $?' EXIT

  if [[ "${MODE}" != "list-registered" ]]; then
    write_ops_backup_dashboard_status "started" "usb-disk-setup-started" "USB disk setup started (mode=${MODE})." "${OPS_EVENT_UUID}"
  fi

  if [[ "${MODE}" != "deregister" && ( -n "${DEREGISTER_UUID}" || -n "${DEREGISTER_DISK_NAME}" ) ]]; then
    die "--uuid and --disk-name are valid only with --deregister."
  fi

  require_cmd_many lsblk awk comm findmnt blkid
  validate_usb_allowlist_disk_names "${USB_CONF}"

  local dev part uuid label_value scopes

  case "${MODE}" in
    guided)
      guided_setup
      ;;
    prepare-new)
      dev="$(pick_new_disk)"
      prepare_selected_disk_as_new "${dev}"
      ;;
    register-existing)
      dev="$(choose_existing_usb_disk)"
      part="$(existing_partition_for_disk "${dev}")"
      if (( $(count_disk_partitions "${dev}") != 1 )); then
        die "Register-existing mode requires exactly one data partition on ${dev}."
      fi
      uuid="$(uuid_for_partition "${part}")"
      label_value="$(label_for_partition "${part}")"
      if uuid_in_allowlist "${USB_CONF}" "${uuid}"; then
        complete_already_registered_disk "${dev}" "${part}" "${uuid}" "${label_value}"
        return 0
      fi
      scopes="$(inspect_existing_penelope_structure "${part}")"
      register_selected_existing_disk "${dev}" "${part}" "${uuid}" "${label_value}" "${scopes}"
      ;;
    rename-disk)
      rename_registered_disk
      ;;
    list-registered)
      print_registered_usb_disks
      ;;
    deregister)
      deregister_registered_disk
      ;;
    *)
      die "Unsupported mode: ${MODE}"
      ;;
  esac
}

main "$@"
EOF_USB_DISK_SETUP_SCRIPT_TAIL
  } | install_file_from_heredoc "${tool_path}" 0750 root root "usb-disk-setup"
}

# -------------------- cron + logrotate --------------------
remove_usb_autorun_artifacts() {
  local unit_path="/etc/systemd/system/penelope-usb-backup@.service"
  local arm_unit_path="/etc/systemd/system/penelope-usb-autorun-arm.service"
  local reconcile_unit_path="/etc/systemd/system/penelope-usb-autorun-reconcile.service"
  local attach_unit_path="/etc/systemd/system/penelope-usb-attach-dashboard@.service"
  local detach_unit_path="/etc/systemd/system/penelope-usb-detach-dashboard@.service"
  local gate_path="/usr/local/sbin/penelope-usb-autorun-gate.sh"
  local rules_refresher_path="/usr/local/sbin/penelope-refresh-usb-autorun-rules.sh"
  local rules_path="/etc/udev/rules.d/99-penelope-usb-backup.rules"
  local initramfs_stamp_path="/var/lib/${PROJECT}/usb-autorun-udev-rules.initramfs.sha256"
  local removed_any="0"

  if [[ -e "${unit_path}" ]]; then
    rm -f -- "${unit_path}" || die "Failed to remove USB auto-run unit: ${unit_path}"
    removed_any="1"
  fi
  if [[ -e "${arm_unit_path}" ]]; then
    rm -f -- "${arm_unit_path}" || die "Failed to remove USB auto-run arm unit: ${arm_unit_path}"
    removed_any="1"
  fi
  if [[ -e "${reconcile_unit_path}" ]]; then
    rm -f -- "${reconcile_unit_path}" || die "Failed to remove USB auto-run reconcile unit: ${reconcile_unit_path}"
    removed_any="1"
  fi
  if [[ -e "${attach_unit_path}" ]]; then
    rm -f -- "${attach_unit_path}" || die "Failed to remove USB attach cleanup unit: ${attach_unit_path}"
    removed_any="1"
  fi
  if [[ -e "${detach_unit_path}" ]]; then
    rm -f -- "${detach_unit_path}" || die "Failed to remove USB detach cleanup unit: ${detach_unit_path}"
    removed_any="1"
  fi
  if [[ -e "${gate_path}" ]]; then
    rm -f -- "${gate_path}" || die "Failed to remove USB auto-run gate helper: ${gate_path}"
    removed_any="1"
  fi
  if [[ -e "${rules_refresher_path}" ]]; then
    rm -f -- "${rules_refresher_path}" || die "Failed to remove USB auto-run rules refresher: ${rules_refresher_path}"
    removed_any="1"
  fi
  if [[ -e "${rules_path}" ]]; then
    rm -f -- "${rules_path}" || die "Failed to remove USB auto-run udev rules: ${rules_path}"
    removed_any="1"
  fi
  if [[ -e "${initramfs_stamp_path}" ]]; then
    rm -f -- "${initramfs_stamp_path}" || die "Failed to remove USB auto-run initramfs fingerprint: ${initramfs_stamp_path}"
    removed_any="1"
  fi

  if [[ "${removed_any}" != "1" ]]; then
    log "USB auto-run disabled and no managed udev/systemd artifacts were present."
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if [[ -d /run/systemd/system ]]; then
      systemctl daemon-reload || die "Failed to reload systemd after removing USB auto-run units"
    else
      warn "USB auto-run artifacts were removed, but no live systemd runtime is available for daemon-reload."
    fi
  else
    warn "USB auto-run artifacts were removed, but systemctl is unavailable; skipped daemon-reload."
  fi

  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || die "Failed to reload udev rules after removing USB auto-run rules"
  else
    warn "USB auto-run artifacts were removed, but udevadm is unavailable; skipped rules reload."
  fi

  refresh_initramfs_after_usb_autorun_rule_change "${rules_path}" "USB auto-run udev rules removed"

  log "USB auto-run artifacts removed (udev/systemd integration disabled)."
}

install_usb_autorun_gate() {
  local gate_path="/usr/local/sbin/penelope-usb-autorun-gate.sh"

  log "Installing USB auto-run gate helper: ${gate_path}"
  {
    cat <<'EOF_USB_AUTORUN_GATE_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-usb-autorun-gate.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
set -Eeuo pipefail

export TZ="${TZ:-Europe/Berlin}"
EOF_USB_AUTORUN_GATE_SCRIPT
    emit_generated_common_project_prelude
    cat <<'EOF_USB_AUTORUN_GATE_SCRIPT'
readonly USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
readonly RUN_DIR="/run/${PROJECT}/usb-autorun"
readonly BOOT_PRESENT_DIR="${RUN_DIR}/boot-present"
readonly ARMED_FILE="${RUN_DIR}/armed"
readonly BACKUP_LOG="/var/log/${PROJECT}/backup/backup.log"

usage() {
  cat >&2 <<'EOF_USB_AUTORUN_GATE_USAGE'
Usage:
  penelope-usb-autorun-gate.sh --arm
  penelope-usb-autorun-gate.sh --check-add <UUID>
  penelope-usb-autorun-gate.sh --reconcile-removals
EOF_USB_AUTORUN_GATE_USAGE
}

gate_log() {
  local level="${1:?level required}"
  local message="${2:?message required}"
  local line=""
  line="[$(ts)] ${level}: USB autorun gate: ${message}"
  printf '%s
' "${line}" >&2
  if [[ -f "${BACKUP_LOG}" && -w "${BACKUP_LOG}" ]]; then
    printf '%s
' "${line}" >> "${BACKUP_LOG}" || true
  fi
}

ensure_gate_dirs() {
  install -d -m 0700 -o root -g root "${RUN_DIR}" "${BOOT_PRESENT_DIR}"
}

validate_gate_uuid() {
  local uuid="${1:?uuid required}"
  [[ "${uuid}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid UUID token for USB autorun gate: ${uuid}"
}

boot_present_marker_for_uuid() {
  local uuid="${1:?uuid required}"
  validate_gate_uuid "${uuid}"
  printf '%s/%s
' "${BOOT_PRESENT_DIR}" "${uuid}"
}

uuid_currently_present() {
  local uuid="${1:?uuid required}"
  blkid -U "${uuid}" >/dev/null 2>&1
}

mark_uuid_boot_present() {
  local uuid="${1:?uuid required}"
  local marker=""
  marker="$(boot_present_marker_for_uuid "${uuid}")"
  : > "${marker}"
  chmod 0600 "${marker}" 2>/dev/null || true
}

reconcile_removed_boot_present_markers() {
  local marker=""
  local uuid=""
  shopt -s nullglob
  for marker in "${BOOT_PRESENT_DIR}"/*; do
    uuid="$(basename -- "${marker}")"
    validate_gate_uuid "${uuid}"
    if ! uuid_currently_present "${uuid}"; then
      rm -f -- "${marker}"
      gate_log "INFO" "UUID ${uuid} was removed after boot-present suppression; future inserts may auto-run."
    fi
  done
  shopt -u nullglob
}

arm_autorun_gate() {
  local uuid=""
  local present_count=0

  ensure_gate_dirs
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=15 2>/dev/null || gate_log "WARN" "udevadm settle timed out while arming; continuing with current device view."
  fi

  reconcile_removed_boot_present_markers
  while IFS= read -r uuid; do
    [[ -n "${uuid}" ]] || continue
    validate_gate_uuid "${uuid}"
    mark_uuid_boot_present "${uuid}"
    present_count=$((present_count + 1))
  done < <(read_present_allowlisted_uuids "${USB_CONF}" || true)

  {
    printf 'armed_at=%s
' "$(date -Is)"
    printf 'boot_present_count=%s
' "${present_count}"
  } > "${ARMED_FILE}"
  chmod 0600 "${ARMED_FILE}" 2>/dev/null || true
  gate_log "INFO" "armed; suppressed ${present_count} allow-listed UUID(s) already present at arm time."
}

check_add_event() {
  local uuid="${1:?uuid required}"
  local marker=""

  ensure_gate_dirs
  validate_gate_uuid "${uuid}"

  if ! uuid_in_allowlist "${USB_CONF}" "${uuid}"; then
    # Non-allow-listed UUIDs are normal during boot enumeration and must stay quiet.
    exit 1
  fi

  reconcile_removed_boot_present_markers
  marker="$(boot_present_marker_for_uuid "${uuid}")"

  if [[ ! -f "${ARMED_FILE}" ]]; then
    mark_uuid_boot_present "${uuid}"
    gate_log "INFO" "suppressed pre-arm add event for allow-listed UUID ${uuid}; this prevents reboot enumeration from starting an external backup."
    exit 1
  fi

  if [[ -f "${marker}" ]]; then
    gate_log "INFO" "suppressed boot-present add event for allow-listed UUID ${uuid}; unplug and reinsert or run the external backup manually."
    exit 1
  fi

  gate_log "INFO" "accepted post-boot insert for allow-listed UUID ${uuid}."
}

main() {
  local command="${1:-}"
  case "${command}" in
    --arm)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      arm_autorun_gate
      ;;
    --check-add)
      [[ $# -eq 2 ]] || { usage; exit 2; }
      check_add_event "${2}"
      ;;
    --reconcile-removals)
      [[ $# -eq 1 ]] || { usage; exit 2; }
      ensure_gate_dirs
      reconcile_removed_boot_present_markers
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}
main "$@"
EOF_USB_AUTORUN_GATE_SCRIPT
  } | install_file_from_heredoc "${gate_path}" 0750 root root "USB auto-run gate helper"
}

refresh_initramfs_after_usb_autorun_rule_change() {
  local rules_path="${1:-/etc/udev/rules.d/99-penelope-usb-backup.rules}"
  local reason="${2:-USB auto-run udev rule state changed}"
  local state_dir="/var/lib/${PROJECT}"
  local stamp_path="${state_dir}/usb-autorun-udev-rules.initramfs.sha256"
  local current_hash="absent"
  local previous_hash=""

  if [[ -f "${rules_path}" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
      die "Cannot fingerprint USB auto-run udev rules because sha256sum is unavailable."
    fi
    current_hash="$(sha256sum "${rules_path}" | awk '{print $1}')"
    [[ -n "${current_hash}" ]] || die "Failed to fingerprint USB auto-run udev rules: ${rules_path}"
  fi

  install -d -m 0755 -o root -g root "${state_dir}"
  if [[ -f "${stamp_path}" ]]; then
    previous_hash="$(cat "${stamp_path}" 2>/dev/null || true)"
  fi

  if [[ "${previous_hash}" == "${current_hash}" ]]; then
    log "USB auto-run udev rule state already reflected in initramfs (fingerprint unchanged)."
    return 0
  fi

  if ! command -v update-initramfs >/dev/null 2>&1; then
    warn "update-initramfs is unavailable; USB auto-run udev rule state changed but initramfs could not be refreshed. Boot-time udev enumeration may still use stale rules until the initramfs is rebuilt manually."
    return 0
  fi

  log "Refreshing initramfs after USB auto-run udev rule change (${reason}): update-initramfs -u -k all"
  update-initramfs -u -k all || die "Failed to refresh initramfs after USB auto-run udev rule change."
  printf '%s\n' "${current_hash}" > "${stamp_path}"
  chmod 0644 "${stamp_path}" 2>/dev/null || true
  chown root:root "${stamp_path}" 2>/dev/null || true
}

install_usb_autorun_rules_refresher() {
  local refresher_path="/usr/local/sbin/penelope-refresh-usb-autorun-rules.sh"

  log "Installing USB auto-run rules refresher: ${refresher_path}"
  {
    cat <<'EOF_USB_AUTORUN_RULES_REFRESHER_HEAD'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-refresh-usb-autorun-rules.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
# Regenerate static udev rules from /etc/penelope/usb-backup-disks.conf.
set -Eeuo pipefail

export TZ="${TZ:-Europe/Berlin}"
EOF_USB_AUTORUN_RULES_REFRESHER_HEAD
    emit_generated_common_project_prelude
    emit_generated_usb_allowlist_validation_helpers
    cat <<'EOF_USB_AUTORUN_RULES_REFRESHER_TAIL'
readonly USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
readonly RULES_PATH="/etc/udev/rules.d/99-penelope-usb-backup.rules"
readonly INITRAMFS_STAMP_PATH="/var/lib/${PROJECT}/usb-autorun-udev-rules.initramfs.sha256"
RELOAD_UDEV="1"

usage() {
  cat >&2 <<'EOF_USB_AUTORUN_RULES_REFRESHER_USAGE'
Usage:
  penelope-refresh-usb-autorun-rules.sh [--no-reload]
EOF_USB_AUTORUN_RULES_REFRESHER_USAGE
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-reload)
        RELOAD_UDEV="0"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  done
}

emit_allowlisted_uuid_static_rules() {
  local conf_path="${1:?allowlist required}"
  local raw uuid name
  [[ -f "${conf_path}" ]] || return 0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    uuid="${raw%%[[:space:]]*}"
    name="${raw#"${uuid}"}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%%[[:space:]]*}"
    assert_usb_allowlist_uuid_value "${uuid}" "USB autorun udev rule UUID"
    assert_usb_allowlist_disk_name_value "${name}" "USB autorun udev rule DISK_NAME"
    printf 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_UUID}=="%s", ENV{PENELOPE_USB_BACKUP_ALLOWLISTED}="1", ENV{UDISKS_IGNORE}="1"\n' "${uuid}"
    printf 'ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_UUID}=="%s", TAG+="systemd", ENV{SYSTEMD_WANTS}+="penelope-usb-backup@%s.service"\n' "${uuid}" "${uuid}"
  done < "${conf_path}"
}

write_rules() {
  local tmp=""
  local rules_dir=""
  validate_usb_allowlist_disk_names "${USB_CONF}"
  rules_dir="$(dirname -- "${RULES_PATH}")"
  install -d -m 0755 -o root -g root "${rules_dir}"
  tmp="$(mktemp "${rules_dir}/99-penelope-usb-backup.rules.tmp.XXXXXX")"
  chmod 0644 "${tmp}" 2>/dev/null || true
  chown root:root "${tmp}" 2>/dev/null || true
  {
    cat <<'EOF_UDEV_RULES_STATIC_HEAD'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
# Managed by Penelope.
# This file is generated from /etc/penelope/usb-backup-disks.conf.
# Only statically allow-listed UUIDs below may request penelope-usb-backup@.service.
# Registered Penelope backup disks are also marked UDISKS_IGNORE=1 to avoid desktop automount.
# Re-run penelope-refresh-usb-autorun-rules.sh after allow-list changes.
EOF_UDEV_RULES_STATIC_HEAD
    emit_allowlisted_uuid_static_rules "${USB_CONF}"
    cat <<'EOF_UDEV_RULES_STATIC_TAIL'
# Reconcile autorun boot-present suppression after block-device removal.
# Remove events may not carry ID_FS_UUID and systemd device wants are not reliable for
# remove-event work, so udev directly runs the fast gate sweep. The helper only clears
# transient /run markers for allow-listed UUIDs that blkid no longer sees.
ACTION=="remove", SUBSYSTEM=="block", RUN+="/usr/local/sbin/penelope-usb-autorun-gate.sh --reconcile-removals"
# Reconcile external dashboard signals after partition removal; the refresh helper sweeps
# allow-listed absent disks because remove events may not carry filesystem UUID metadata.
ACTION=="remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}+="penelope-backup-dashboard-refresh.service"
EOF_UDEV_RULES_STATIC_TAIL
  } > "${tmp}"
  mv -f -- "${tmp}" "${RULES_PATH}"
  chmod 0644 "${RULES_PATH}" 2>/dev/null || true
  chown root:root "${RULES_PATH}" 2>/dev/null || true
}

refresh_initramfs_if_rules_changed() {
  local state_dir=""
  local current_hash="absent"
  local previous_hash=""

  if [[ -f "${RULES_PATH}" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
      die "Cannot fingerprint USB autorun udev rules because sha256sum is unavailable."
    fi
    current_hash="$(sha256sum "${RULES_PATH}" | awk '{print $1}')"
    [[ -n "${current_hash}" ]] || die "Failed to fingerprint USB autorun udev rules: ${RULES_PATH}"
  fi

  state_dir="$(dirname -- "${INITRAMFS_STAMP_PATH}")"
  install -d -m 0755 -o root -g root "${state_dir}"
  if [[ -f "${INITRAMFS_STAMP_PATH}" ]]; then
    previous_hash="$(cat "${INITRAMFS_STAMP_PATH}" 2>/dev/null || true)"
  fi

  if [[ "${previous_hash}" == "${current_hash}" ]]; then
    log "USB autorun udev rule state already reflected in initramfs (fingerprint unchanged)."
    return 0
  fi

  if ! command -v update-initramfs >/dev/null 2>&1; then
    warn "update-initramfs is unavailable; USB autorun udev rule state changed but initramfs could not be refreshed. Boot-time udev enumeration may still use stale rules until the initramfs is rebuilt manually."
    return 0
  fi

  log "Refreshing initramfs after USB autorun udev rule change: update-initramfs -u -k all"
  update-initramfs -u -k all || die "Failed to refresh initramfs after USB autorun udev rule change."
  printf '%s
' "${current_hash}" > "${INITRAMFS_STAMP_PATH}"
  chmod 0644 "${INITRAMFS_STAMP_PATH}" 2>/dev/null || true
  chown root:root "${INITRAMFS_STAMP_PATH}" 2>/dev/null || true
}

main() {
  parse_cli "$@"
  require_root "sudo $0"
  write_rules
  refresh_initramfs_if_rules_changed
  if [[ "${RELOAD_UDEV}" == "1" ]]; then
    if command -v udevadm >/dev/null 2>&1; then
      udevadm control --reload-rules
    else
      warn "udevadm is unavailable; USB autorun rules were regenerated but not reloaded."
    fi
  fi
}

main "$@"
EOF_USB_AUTORUN_RULES_REFRESHER_TAIL
  } | install_file_from_heredoc "${refresher_path}" 0750 root root "USB auto-run rules refresher"
}

install_usb_autorun() {
  # Auto-run external backup on insertion of a registered USB filesystem partition.
  # The udev rules are statically materialized from ${USB_CONF}; the systemd gate still
  # suppresses registered disks that were already present during boot/arming.
  local runner_path="/usr/local/sbin/penelope-backup.sh"
  local gate_path="/usr/local/sbin/penelope-usb-autorun-gate.sh"
  local rules_refresher_path="/usr/local/sbin/penelope-refresh-usb-autorun-rules.sh"
  local unit_path="/etc/systemd/system/penelope-usb-backup@.service"
  local arm_unit_path="/etc/systemd/system/penelope-usb-autorun-arm.service"
  local stale_reconcile_unit_path="/etc/systemd/system/penelope-usb-autorun-reconcile.service"
  local detach_unit_path="/etc/systemd/system/penelope-usb-detach-dashboard@.service"
  local rules_path="/etc/udev/rules.d/99-penelope-usb-backup.rules"

  local enable_usb_autorun="1"
  validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
  validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
  validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
  if [[ -f "${BACKUP_CONF}" ]]; then
    enable_usb_autorun="$(read_kv_value_from_file "${BACKUP_CONF}" "ENABLE_USB_AUTORUN" || true)"
  [[ -n "${enable_usb_autorun}" ]] || die "Missing ENABLE_USB_AUTORUN in ${BACKUP_CONF}"
  fi

  if [[ "${enable_usb_autorun}" != "1" ]]; then
    log "USB auto-run disabled (ENABLE_USB_AUTORUN=0). Removing managed udev/systemd integration."
    remove_usb_autorun_artifacts
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    die "USB auto-run requires systemctl on the installed host."
  fi

  if [[ ! -d /run/systemd/system ]]; then
    die "USB auto-run requires a live systemd runtime on the installed host."
  fi

  if ! command -v udevadm >/dev/null 2>&1; then
    die "USB auto-run requires udevadm on the installed host."
  fi

  # Referencer guard: the systemd unit ExecStart must point to an executable script.
  [[ -x "${runner_path}" ]] || die "USB auto-run requires an executable runner: ${runner_path}"

  install_usb_autorun_gate
  [[ -x "${gate_path}" ]] || die "USB auto-run requires an executable gate helper: ${gate_path}"
  install_usb_autorun_rules_refresher
  [[ -x "${rules_refresher_path}" ]] || die "USB auto-run requires an executable rules refresher: ${rules_refresher_path}"

  if [[ -e "${stale_reconcile_unit_path}" ]]; then
    log "Removing obsolete USB auto-run reconcile systemd unit: ${stale_reconcile_unit_path}"
    rm -f -- "${stale_reconcile_unit_path}" || die "Failed to remove obsolete USB auto-run reconcile systemd unit: ${stale_reconcile_unit_path}"
  fi

  log "Installing USB auto-run systemd unit: ${unit_path}"
  install_file_from_heredoc "${unit_path}" 0644 root root "systemd-unit" <<'EOF_SYSTEMD_UNIT_AUTORUN'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
[Unit]
Description=Penelope USB backup (UUID %i)
After=local-fs.target penelope-usb-autorun-arm.service
Wants=local-fs.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=XDG_CACHE_HOME=/root/.cache
ExecCondition=/usr/local/sbin/penelope-usb-autorun-gate.sh --check-add %i
ExecStartPre=/usr/bin/install -d -m 0700 -o root -g root /root/.cache
ExecStart=/usr/local/sbin/penelope-backup.sh --mode external --uuid %i
EOF_SYSTEMD_UNIT_AUTORUN

  log "Installing USB auto-run arm systemd unit: ${arm_unit_path}"
  install_file_from_heredoc "${arm_unit_path}" 0644 root root "systemd-unit" <<'EOF_SYSTEMD_UNIT_AUTORUN_ARM'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
[Unit]
Description=Penelope USB auto-run gate arming
After=local-fs.target systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/penelope-usb-autorun-gate.sh --arm

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD_UNIT_AUTORUN_ARM


  log "Installing USB detach cleanup systemd unit: ${detach_unit_path}"
  install_file_from_heredoc "${detach_unit_path}" 0644 root root "systemd-unit" <<'EOF_SYSTEMD_UNIT_DETACH'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
[Unit]
Description=Penelope USB backup-dashboard detach cleanup (UUID %i)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/penelope-refresh-backup-dashboard.sh --reconcile-absent-uuid %i
EOF_SYSTEMD_UNIT_DETACH

  log "Refreshing USB auto-run udev rules from allow-list: ${rules_path}"
  "${rules_refresher_path}" --no-reload

  systemctl daemon-reload
  udevadm control --reload-rules
  refresh_initramfs_after_usb_autorun_rule_change "${rules_path}" "static allow-list USB autorun rules refreshed"
  systemctl enable --now penelope-usb-autorun-arm.service
  log "USB auto-run installed (udev/systemd, boot-present gate armed; systemd auto-run is statically materialized from the allow-list; initramfs is refreshed when rule fingerprints change; remove reconciliation uses udev RUN; allow-listed backup disks are marked UDISKS_IGNORE for desktop automount)."
}



install_backup_dashboard_refresh_monitor() {
  local tool_path="/usr/local/sbin/penelope-refresh-backup-dashboard.sh"
  local service_path="/etc/systemd/system/penelope-backup-dashboard-refresh.service"
  local timer_path="/etc/systemd/system/penelope-backup-dashboard-refresh.timer"

  PLACEHOLDER_BACKUP_DASHBOARD_DIR="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
  [[ -n "${PLACEHOLDER_BACKUP_DASHBOARD_DIR}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${BACKUP_CONF}"

  log "Installing backup-dashboard refresh helper: ${tool_path}"
  {
    cat <<'EOF_DASHBOARD_REFRESH_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-refresh-backup-dashboard.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
set -Eeuo pipefail

export TZ="${TZ:-Europe/Berlin}"
EOF_DASHBOARD_REFRESH_SCRIPT
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_backup_dashboard_file_helpers
    emit_generated_usb_allowlist_helpers
    emit_generated_runtime_lock_helpers
    cat <<'EOF_DASHBOARD_REFRESH_SCRIPT'
readonly BACKUP_CONF="/etc/${PROJECT}/backup.conf"
readonly USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
readonly DEFAULT_BACKUP_DASHBOARD_DIR="___PENELOPE_DEFAULT_BACKUP_DASHBOARD_DIR___"
readonly DEFAULT_STALE_HOURS="48"
backup_run_internal_lock_dir() {
  printf '%s
' "/run/${PROJECT}/backup-run-internal.lock.d"
}

backup_run_external_lock_dir_for_uuid() {
  local uuid="${1:?uuid required}"
  printf '%s
' "/run/${PROJECT}/backup-run-external-${uuid}.lock.d"
}
RECONCILE_ABSENT_UUID=""

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reconcile-absent-uuid)
        RECONCILE_ABSENT_UUID="${2:-}"
        shift 2
        ;;
      -h|--help)
        >&2 echo "Usage: $0 [--reconcile-absent-uuid <UUID>]"
        exit 0
        ;;
      *)
        >&2 echo "ERROR: Unknown argument: $1"
        exit 2
        ;;
    esac
  done
}

external_backup_run_matches_uuid() {
  local uuid="${1:?uuid required}"
  local lock_dir="" mode_file="" uuid_file=""
  lock_dir="$(backup_run_external_lock_dir_for_uuid "${uuid}")"
  mode_file="${lock_dir}/mode"
  uuid_file="${lock_dir}/uuid"
  if ! pid_dir_lock_is_active "${lock_dir}" "external backup run"; then
    return 1
  fi
  [[ -f "${mode_file}" ]] || return 1
  [[ "$(cat "${mode_file}" 2>/dev/null || true)" == "external" ]] || return 1
  [[ -f "${uuid_file}" ]] || return 1
  [[ "$(cat "${uuid_file}" 2>/dev/null || true)" == "${uuid}" ]]
}

mounted_usb_lock_status_for_uuid() {
  local uuid="${1:?uuid required}"
  local dev="" mnt="" lock_path=""
  local -a mounts=()

  dev="$(usb_dev_for_uuid "${uuid}" 2>/dev/null || true)"
  [[ -n "${dev}" ]] || {
    printf 'MISSING
'
    return 0
  }

  if ! command -v findmnt >/dev/null 2>&1; then
    printf 'MISSING
'
    return 0
  fi

  mapfile -t mounts < <(findmnt -n -o TARGET --source "${dev}" 2>/dev/null || true)
  case ${#mounts[@]} in
    0)
      printf 'MISSING
'
      return 0
      ;;
    1)
      mnt="${mounts[0]}"
      ;;
    *)
      printf 'INVALID
'
      return 0
      ;;
  esac

  lock_path="${mnt}/.penelope-backup-lock.json"
  python3 - "${lock_path}" "${uuid}" <<'PY_MOUNTED_USB_LOCK_STATUS'
import json, os, sys, time
p = sys.argv[1]
want_uuid = sys.argv[2]
if not os.path.exists(p):
  print("MISSING")
  raise SystemExit(0)
try:
  with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)
except Exception:
  print("INVALID")
  raise SystemExit(0)

if str(d.get("uuid", "") or "") != want_uuid:
  print("INVALID")
  raise SystemExit(0)
if str(d.get("mode", "") or "") not in ("", "external"):
  print("INVALID")
  raise SystemExit(0)

now = int(time.time())
boot_id = ""
try:
  with open("/proc/sys/kernel/random/boot_id", "r", encoding="utf-8") as f:
    boot_id = f.read().strip()
except Exception:
  boot_id = ""

pid = d.get("pid")
expires_at = d.get("expires_at")
lock_boot = d.get("boot_id", "")

def is_int(x):
  try:
    int(x)
    return True
  except Exception:
    return False

stale = False
if lock_boot and boot_id and lock_boot != boot_id:
  stale = True
elif is_int(expires_at) and now > int(expires_at):
  stale = True
elif is_int(pid):
  pid_i = int(pid)
  if pid_i > 0 and not os.path.exists(f"/proc/{pid_i}"):
    stale = True

print("STALE" if stale else "ACTIVE")
PY_MOUNTED_USB_LOCK_STATUS
}

restore_refresh_external_signal_backups() {
  local manifest="${1:-}"
  local path=""
  local backup=""
  local rc=0
  while IFS=$'	' read -r path backup; do
    [[ -n "${path}" && -n "${backup}" ]] || continue
    if ! mv -f -- "${backup}" "${path}" && ! cp -p -- "${backup}" "${path}" 2>/dev/null; then
      warn "Failed to restore refresh external dashboard signal backup ${backup} -> ${path}"
      rc=1
      continue
    fi
    if [[ -e "${backup}" ]]; then
      warn "Refresh external dashboard signal backup cleanup incomplete after restore: ${backup}"
      rc=1
    fi
  done <<< "${manifest}"
  return ${rc}
}

cleanup_refresh_external_signal_backups() {
  local manifest="${1:-}"
  local path=""
  local backup=""
  local rc=0
  while IFS=$'	' read -r path backup; do
    [[ -n "${backup}" ]] || continue
    if ! rm -f -- "${backup}"; then
      warn "Failed to remove refresh external dashboard signal backup ${backup}"
      rc=1
    fi
  done <<< "${manifest}"
  return ${rc}
}

backup_refresh_external_signal_files() {
  local backups_manifest=""
  local path=""
  local tmp=""
  local dash_dir="${BACKUP_DASHBOARD_DIR:?backup dashboard dir required}"

  for path in "$@"; do
    [[ -n "${path}" && -f "${path}" ]] || continue
    tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || {
      cleanup_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to remove refresh external dashboard signal backups after temp-file allocation failure"
      return 1
    }
    cp -p -- "${path}" "${tmp}" 2>/dev/null || {
      rm -f -- "${tmp}" 2>/dev/null || true
      cleanup_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to remove refresh external dashboard signal backups after copy failure"
      return 1
    }
    backups_manifest+="${path}"$'	'"${tmp}"$'
'
  done

  printf '%s' "${backups_manifest}"
}

write_refresh_external_signal_with_rollback() {
  local out="${1:?output path required}"
  local header="${2:?header required}"
  shift 2

  local -a notice_lines=()
  local -a clear_paths=()
  local backups_manifest=""

  while (( $# > 0 )); do
    if [[ "$1" == "--clear" ]]; then
      shift
      clear_paths=("$@")
      break
    fi
    notice_lines+=("$1")
    shift
  done

  backups_manifest="$(backup_refresh_external_signal_files "${out}" "${clear_paths[@]}")" || return 1

  rm -f -- "${out}" || {
    restore_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to restore refresh external dashboard signal backups"
    return 1
  }
  for path in "${clear_paths[@]}"; do
    [[ -n "${path}" ]] || continue
    rm -f -- "${path}" || {
      restore_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to restore refresh external dashboard signal backups"
      return 1
    }
  done

  if write_backup_dashboard_notice_file "${out}" "${header}" "${notice_lines[@]}"; then
    cleanup_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to remove refresh external dashboard signal backups after successful signal publish"
    return 0
  fi

  restore_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to restore refresh external dashboard signal backups"
  return 1
}

clear_refresh_external_signals_with_rollback() {
  local backups_manifest=""
  backups_manifest="$(backup_refresh_external_signal_files "$@")" || return 1

  if clear_backup_dashboard_files "$@"; then
    cleanup_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to remove refresh external dashboard signal backups after successful signal clear"
    return 0
  fi

  restore_refresh_external_signal_backups "${backups_manifest}" || warn "Failed to restore refresh external dashboard signal backups"
  return 1
}

reconcile_present_disk_running_state() {
  local uuid="${1:?uuid required}"
  local disk_name="" running_file="" ready_file="" hold_file="" reattach_and_wait_file="" legacy_retry_file=""
  uuid_in_allowlist "${USB_CONF}" "${uuid}" || return 0
  if ! usb_dev_for_uuid "${uuid}" >/dev/null 2>&1; then
    return 0
  fi
  disk_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  [[ -n "${disk_name}" ]] || return 0

  running_file="$(usb_signal_file_path running "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  [[ -f "${running_file}" ]] || return 0
  if external_backup_run_matches_uuid "${uuid}"; then
    return 0
  fi

  local mounted_lock_state=""
  mounted_lock_state="$(mounted_usb_lock_status_for_uuid "${uuid}" 2>/dev/null || true)"
  case "${mounted_lock_state}" in
    ACTIVE)
      return 0
      ;;
    INVALID|"")
      warn "Ambiguous mounted USB lock state for UUID ${uuid}; preserving current per-disk RUNNING dashboard truth until the lock state becomes clear."
      return 0
      ;;
    MISSING|STALE)
      ;;
    *)
      warn "Unexpected mounted USB lock state '${mounted_lock_state}' for UUID ${uuid}; preserving current per-disk RUNNING dashboard truth until the lock state becomes clear."
      return 0
      ;;
  esac

  ready_file="$(usb_signal_file_path ready "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_and_wait_file="$(usb_signal_file_path reattach_and_wait "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  legacy_retry_file="$(usb_legacy_retry_signal_file_path "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  if [[ -f "${hold_file}" ]]; then
    clear_refresh_external_signals_with_rollback "${running_file}" "${ready_file}" "${reattach_and_wait_file}" "${legacy_retry_file}" || return 1
    return 0
  fi

  write_refresh_external_signal_with_rollback \
    "${hold_file}" \
    "$(usb_signal_header hold "${disk_name}")" \
    "disk_name=${disk_name}" \
    "message=Backup did not complete successfully. Do NOT remove the USB backup drive. Contact the operator." \
    --clear \
    "${running_file}" \
    "${ready_file}" \
    "${reattach_and_wait_file}" \
    "${legacy_retry_file}"
}


reconcile_present_disk_wait_state() {
  local uuid="${1:?uuid required}"
  local disk_name="" ready_file="" running_file="" hold_file="" reattach_and_wait_file="" legacy_retry_file=""
  local desired_wait_message="The USB backup drive is attached. Leave the same disk connected and wait for the next retry."
  uuid_in_allowlist "${USB_CONF}" "${uuid}" || return 0
  if ! usb_dev_for_uuid "${uuid}" >/dev/null 2>&1; then
    return 0
  fi
  disk_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  [[ -n "${disk_name}" ]] || return 0

  ready_file="$(usb_signal_file_path ready "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  running_file="$(usb_signal_file_path running "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_and_wait_file="$(usb_signal_file_path reattach_and_wait "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  legacy_retry_file="$(usb_legacy_retry_signal_file_path "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"

  if [[ -f "${hold_file}" || -f "${running_file}" || -f "${ready_file}" ]]; then
    clear_refresh_external_signals_with_rollback "${reattach_and_wait_file}" "${legacy_retry_file}" || return 1
    return 0
  fi

  if [[ ! -f "${reattach_and_wait_file}" && ! -f "${legacy_retry_file}" ]]; then
    return 0
  fi

  if [[ -f "${reattach_and_wait_file}" && ! -f "${legacy_retry_file}" ]] && grep -Fqx "message=${desired_wait_message}" "${reattach_and_wait_file}" 2>/dev/null; then
    return 0
  fi

  write_refresh_external_signal_with_rollback \
    "${reattach_and_wait_file}" \
    "$(usb_signal_header reattach_and_wait "${disk_name}")" \
    "disk_name=${disk_name}" \
    "message=${desired_wait_message}" \
    --clear \
    "${legacy_retry_file}"
}

reconcile_absent_disk_dashboard_state() {
  local uuid="${1:?uuid required}"
  local requested_absent="${2:-0}"
  local disk_name="" ready_file="" running_file="" hold_file="" reattach_and_wait_file="" legacy_retry_file=""
  local absent_wait_message="The USB backup drive is not currently attached. Reattach the same disk and wait for the next retry."
  uuid_in_allowlist "${USB_CONF}" "${uuid}" || return 0
  if [[ "${requested_absent}" != "1" ]] && usb_dev_for_uuid "${uuid}" >/dev/null 2>&1; then
    return 0
  fi
  disk_name="$(read_usb_allowlist_name_for_uuid "${USB_CONF}" "${uuid}")"
  [[ -n "${disk_name}" ]] || return 0

  ready_file="$(usb_signal_file_path ready "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  running_file="$(usb_signal_file_path running "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  hold_file="$(usb_signal_file_path hold "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  reattach_and_wait_file="$(usb_signal_file_path reattach_and_wait "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"
  legacy_retry_file="$(usb_legacy_retry_signal_file_path "${disk_name}" "${BACKUP_DASHBOARD_DIR}")"

  if [[ -f "${hold_file}" ]]; then
    clear_refresh_external_signals_with_rollback "${ready_file}" "${running_file}" "${reattach_and_wait_file}" "${legacy_retry_file}" || return 1
    return 0
  fi

  if [[ -f "${running_file}" ]]; then
    write_refresh_external_signal_with_rollback \
      "${reattach_and_wait_file}" \
      "$(usb_signal_header reattach_and_wait "${disk_name}")" \
      "disk_name=${disk_name}" \
      "message=${absent_wait_message}" \
      --clear \
      "${running_file}" \
      "${ready_file}" \
      "${legacy_retry_file}"
  else
    if [[ -f "${reattach_and_wait_file}" || -f "${legacy_retry_file}" ]]; then
      if [[ -f "${reattach_and_wait_file}" ]] \
          && grep -Fqx "message=${absent_wait_message}" "${reattach_and_wait_file}" 2>/dev/null \
          && [[ ! -f "${legacy_retry_file}" ]]; then
        clear_refresh_external_signals_with_rollback "${ready_file}" || return 1
      else
        write_refresh_external_signal_with_rollback \
          "${reattach_and_wait_file}" \
          "$(usb_signal_header reattach_and_wait "${disk_name}")" \
          "disk_name=${disk_name}" \
          "message=${absent_wait_message}" \
          --clear \
          "${legacy_retry_file}" \
          "${ready_file}" || return 1
      fi
    else
      clear_refresh_external_signals_with_rollback "${ready_file}" "${legacy_retry_file}" || return 1
    fi
  fi
}


sweep_present_disk_wait_states() {
  [[ -f "${USB_CONF}" ]] || return 0
  local raw uuid sweep_rc=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    uuid="${raw%%[[:space:]]*}"
    [[ -n "${uuid}" ]] || continue
    if ! reconcile_present_disk_wait_state "${uuid}"; then
      warn "Failed to reconcile present external WAIT dashboard state for UUID ${uuid}; continuing with remaining dashboard refresh work."
      sweep_rc=1
    fi
  done < "${USB_CONF}"
  return ${sweep_rc}
}

sweep_absent_disk_dashboard_states() {
  [[ -f "${USB_CONF}" ]] || return 0
  local raw uuid sweep_rc=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    uuid="${raw%%[[:space:]]*}"
    [[ -n "${uuid}" ]] || continue
    if ! reconcile_absent_disk_dashboard_state "${uuid}"; then
      warn "Failed to reconcile absent external dashboard state for UUID ${uuid}; continuing with remaining dashboard refresh work."
      sweep_rc=1
    fi
  done < "${USB_CONF}"
  return ${sweep_rc}
}

sweep_present_disk_running_states() {
  [[ -f "${USB_CONF}" ]] || return 0
  local raw uuid sweep_rc=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%%#*}"
    [[ "${raw}" =~ [^[:space:]] ]] || continue
    uuid="${raw%%[[:space:]]*}"
    [[ -n "${uuid}" ]] || continue
    if ! reconcile_present_disk_running_state "${uuid}"; then
      warn "Failed to reconcile present external RUNNING dashboard state for UUID ${uuid}; continuing with remaining dashboard refresh work."
      sweep_rc=1
    fi
  done < "${USB_CONF}"
  return ${sweep_rc}
}

clear_internal_status_files() {
  clear_backup_dashboard_files \
    "${INTERNAL_OK_FILE}" \
    "${INTERNAL_ERROR_FILE}" \
    "${INTERNAL_STALE_FILE}"
}

restore_internal_status_backups() {
  local backups_manifest="${1:-}"
  local path=""
  local tmp=""
  local rc=0
  while IFS=$'	' read -r path tmp; do
    [[ -n "${path}" && -n "${tmp}" ]] || continue
    if ! cp -p -- "${tmp}" "${path}" 2>/dev/null && ! cat -- "${tmp}" > "${path}"; then
      warn "Failed to restore internal dashboard status backup: ${tmp} -> ${path}"
      rc=1
      continue
    fi
    if ! chmod 0644 "${path}" 2>/dev/null; then
      warn "Failed to restore mode on internal dashboard status file: ${path}"
      rc=1
    fi
    if ! rm -f -- "${tmp}" 2>/dev/null; then
      warn "Failed to remove consumed internal dashboard status backup: ${tmp}"
      rc=1
    fi
  done <<< "${backups_manifest}"
  return ${rc}
}

cleanup_internal_status_backups() {
  local backups_manifest="${1:-}"
  local path=""
  local tmp=""
  local rc=0
  while IFS=$'	' read -r path tmp; do
    [[ -n "${tmp}" ]] || continue
    if ! rm -f -- "${tmp}" 2>/dev/null; then
      warn "Failed to remove internal dashboard status backup: ${tmp}"
      rc=1
    fi
  done <<< "${backups_manifest}"
  return ${rc}
}

backup_internal_status_files() {
  local dash_dir="${BACKUP_DASHBOARD_DIR:?backup dashboard dir required}"
  local backups_manifest=""
  local path=""
  local tmp=""
  local -a paths=(
    "${INTERNAL_RUNNING_FILE}"
    "${INTERNAL_OK_FILE}"
    "${INTERNAL_ERROR_FILE}"
    "${INTERNAL_STALE_FILE}"
  )

  for path in "${paths[@]}"; do
    [[ -f "${path}" ]] || continue
    tmp="$(make_backup_dashboard_tmp_file "${dash_dir}")" || {
      cleanup_internal_status_backups "${backups_manifest}" || warn "Failed to remove internal dashboard status backups after temp-file allocation failure"
      return 1
    }
    cp -p -- "${path}" "${tmp}" 2>/dev/null || {
      if ! rm -f -- "${tmp}" 2>/dev/null; then
        warn "Failed to remove incomplete internal dashboard status backup temp file: ${tmp}"
      fi
      cleanup_internal_status_backups "${backups_manifest}" || warn "Failed to remove internal dashboard status backups after copy failure"
      return 1
    }
    backups_manifest+="${path}"$'	'"${tmp}"$'
'
  done

  printf '%s' "${backups_manifest}"
}

write_internal_state_file() {
  local path="${1:?path required}"
  local title="${2:?title required}"
  local message="${3:-}"
  local last_status="${4:-}"
  local last_timestamp="${5:-}"
  local internal_status_backups=""

  internal_status_backups="$(backup_internal_status_files)" || return 1
  clear_backup_dashboard_files "${INTERNAL_RUNNING_FILE}" || {
    restore_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  clear_internal_status_files || {
    restore_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
    return 1
  }
  if write_backup_dashboard_notice_file \
      "${path}" \
      "${title}" \
      "threshold_hours=${STALE_AFTER_HOURS}" \
      "last_status=${last_status}" \
      "last_timestamp=${last_timestamp}" \
      "message=${message}"; then
    cleanup_internal_status_backups "${internal_status_backups}" \
      || warn "Failed to remove internal dashboard status backups after writing ${title}.txt"
    return 0
  fi

  restore_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
  return 1
}

parse_last_internal_json() {
  local json_path="${1:?json path required}"
  python3 - "${json_path}" <<'PY_PARSE_INTERNAL_JSON'
import datetime as dt
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("status=missing")
    print("timestamp=")
    print("age_hours=")
    print("message=")
    raise SystemExit(0)

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("status=invalid")
    print("timestamp=")
    print("age_hours=")
    print("message=Invalid last-internal.json")
    raise SystemExit(0)

status = str(data.get("status", "") or "")
timestamp = str(data.get("timestamp", "") or "")
message = str(data.get("message", "") or "")
age_hours = ""
if timestamp:
    try:
        ts = dt.datetime.fromisoformat(timestamp)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=dt.timezone.utc)
        now = dt.datetime.now(ts.tzinfo)
        age_hours = str(int((now - ts).total_seconds() // 3600))
    except Exception:
        age_hours = ""
print(f"status={status}")
print(f"timestamp={timestamp}")
print(f"age_hours={age_hours}")
print(f"message={message}")
PY_PARSE_INTERNAL_JSON
}

internal_backup_run_is_active() {
  local lock_dir="" mode_file=""
  lock_dir="$(backup_run_internal_lock_dir)"
  mode_file="${lock_dir}/mode"
  if ! pid_dir_lock_is_active "${lock_dir}" "internal backup run"; then
    return 1
  fi
  [[ -f "${mode_file}" ]] || return 1
  [[ "$(cat "${mode_file}" 2>/dev/null || true)" == "internal" ]]
}

internal_run_suppresses_final_dashboard_state() {
  internal_backup_run_is_active || return 1
  return 0
}

usb_allowlist_reconcile_ready() {
  if [[ ! -f "${USB_CONF}" ]]; then
    warn "Skipping external Backup-Dashboard absent-disk reconcile: missing USB allow-list ${USB_CONF}"
    return 1
  fi
  if ! ( validate_usb_allowlist_disk_names "${USB_CONF}" ); then
    warn "Skipping external Backup-Dashboard absent-disk reconcile: invalid USB allow-list ${USB_CONF}"
    return 1
  fi
  return 0
}

main() {
  parse_cli "$@"
  require_root
  [[ -f "${BACKUP_CONF}" ]] || die "Missing config: ${BACKUP_CONF}"

  load_backup_runtime_context_from_conf "${BACKUP_CONF}" "${DEFAULT_BACKUP_DASHBOARD_DIR}"
  STALE_AFTER_HOURS="$(resolve_internal_backup_stale_after_hours_from_conf "${BACKUP_CONF}" "${DEFAULT_STALE_HOURS}")"

  local usb_allowlist_ready="0"
  local refresh_rc="0"
  if usb_allowlist_reconcile_ready; then
    usb_allowlist_ready="1"
  else
    refresh_rc="1"
  fi
  load_internal_backup_dashboard_file_paths "${BACKUP_DASHBOARD_DIR}"

  if [[ -n "${RECONCILE_ABSENT_UUID}" ]]; then
    if [[ "${usb_allowlist_ready}" != "1" ]]; then
      warn "Cannot reconcile absent external dashboard state for UUID ${RECONCILE_ABSENT_UUID}: USB allow-list is not ready."
      exit 1
    fi
    if ! reconcile_absent_disk_dashboard_state "${RECONCILE_ABSENT_UUID}" "1"; then
      warn "Failed to reconcile absent external dashboard state for UUID ${RECONCILE_ABSENT_UUID}."
      exit 1
    fi
    exit 0
  fi

  if [[ "${usb_allowlist_ready}" == "1" ]]; then
    sweep_absent_disk_dashboard_states || refresh_rc="1"
    sweep_present_disk_wait_states || refresh_rc="1"
    sweep_present_disk_running_states || refresh_rc="1"
  fi

  if internal_run_suppresses_final_dashboard_state; then
    local internal_status_backups=""
    internal_status_backups="$(backup_internal_status_files)" || {
      warn "Failed to prepare rollback for active internal backup run dashboard state"
      exit 1
    }
    clear_internal_status_files || {
      restore_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
      warn "Failed to clear final internal dashboard states for active internal backup run"
      exit 1
    }
    if ! write_backup_dashboard_notice_file       "${INTERNAL_RUNNING_FILE}"       "INTERNAL_BACKUP_RUNNING"       "message=The internal backup is currently running."; then
      restore_internal_status_backups "${internal_status_backups}" || warn "Failed to restore internal dashboard status backups"
      warn "Failed to republish INTERNAL_BACKUP_RUNNING.txt for active internal backup run"
      exit 1
    fi
    cleanup_internal_status_backups "${internal_status_backups}" || {
      warn "Failed to remove internal dashboard status backups after republishing INTERNAL_BACKUP_RUNNING.txt for active internal backup run"
      refresh_rc="1"
    }
    exit "${refresh_rc}"
  fi
  local status="" timestamp="" age_hours="" message="" line=""
  while IFS= read -r line; do
    case "${line}" in
      status=*) status="${line#status=}" ;;
      timestamp=*) timestamp="${line#timestamp=}" ;;
      age_hours=*) age_hours="${line#age_hours=}" ;;
      message=*) message="${line#message=}" ;;
    esac
  done < <(parse_last_internal_json "${LAST_INTERNAL_JSON}")

  if [[ ( "${status}" == "missing" || "${status}" == "invalid" || -z "${status}" ) && -f "${INTERNAL_ERROR_FILE}" ]]; then
    if [[ -f "${INTERNAL_RUNNING_FILE}" ]]; then
      clear_backup_dashboard_files "${INTERNAL_RUNNING_FILE}"
    fi
    exit "${refresh_rc}"
  fi

  case "${status}" in
    success)
      if [[ -n "${age_hours}" ]] && (( age_hours >= STALE_AFTER_HOURS )); then
        write_internal_state_file \
          "${INTERNAL_STALE_FILE}" \
          "INTERNAL_BACKUP_STALE_CONTACT_OPERATOR" \
          "No fresh internal backup has been seen within ${STALE_AFTER_HOURS} hours. Contact the operator." \
          "${status}" \
          "${timestamp}"
      else
        write_internal_state_file \
          "${INTERNAL_OK_FILE}" \
          "INTERNAL_BACKUP_OK" \
          "The last internal backup completed successfully." \
          "${status}" \
          "${timestamp}"
      fi
      ;;
    failed)
      write_internal_state_file \
        "${INTERNAL_ERROR_FILE}" \
        "INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR" \
        "The last internal backup failed. Contact the operator." \
        "${status}" \
        "${timestamp}"
      ;;
    started)
      write_internal_state_file \
        "${INTERNAL_ERROR_FILE}" \
        "INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR" \
        "The last internal backup did not finish cleanly. Contact the operator." \
        "${status}" \
        "${timestamp}"
      ;;
    not-run-yet|missing|invalid|""|*)
      write_internal_state_file \
        "${INTERNAL_STALE_FILE}" \
        "INTERNAL_BACKUP_STALE_CONTACT_OPERATOR" \
        "No recent internal backup is available on this system. Contact the operator." \
        "${status}" \
        "${timestamp}"
      ;;
  esac
}

main "$@"
EOF_DASHBOARD_REFRESH_SCRIPT
  } | install_file_from_heredoc "${tool_path}" 0750 root root "dashboard-refresh"

  command -v systemctl >/dev/null 2>&1 || die "Backup-Dashboard refresh requires systemctl on the installed host."
  [[ -d /run/systemd/system ]] || die "Backup-Dashboard refresh requires a live systemd runtime on the installed host."

  log "Installing Backup-Dashboard refresh service: ${service_path}"
  install_file_from_heredoc "${service_path}" 0644 root root "systemd-unit" <<'EOF_DASHBOARD_REFRESH_SERVICE'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
[Unit]
Description=Penelope backup-dashboard refresh
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/penelope-refresh-backup-dashboard.sh
EOF_DASHBOARD_REFRESH_SERVICE

  log "Installing Backup-Dashboard refresh timer: ${timer_path}"
  install_file_from_heredoc "${timer_path}" 0644 root root "systemd-unit" <<'EOF_DASHBOARD_REFRESH_TIMER'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
[Unit]
Description=Refresh Penelope backup-dashboard status

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
AccuracySec=5min
Unit=penelope-backup-dashboard-refresh.service

[Install]
WantedBy=timers.target
EOF_DASHBOARD_REFRESH_TIMER

  systemctl daemon-reload
  systemctl enable --now penelope-backup-dashboard-refresh.timer
  /usr/local/sbin/penelope-refresh-backup-dashboard.sh
}

install_usb_password_rotation_tool() {
  local tool_path="/usr/local/sbin/penelope-rotate-external-restic-passwords.sh"

  log "Installing external password rotation tool: ${tool_path}"
  {
    cat <<'EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_HEAD'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-rotate-external-restic-passwords.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
#
# Rotate external USB restic repositories for the current HOST_SCOPE_NAME to the
# current local password files under /root/.config/restic.
#
# Behavior:
# - Pauses automatic USB backup starts while this tool is active.
# - Targets exactly one allowlisted USB filesystem UUID.
# - Operates only on repos below: <USB mount>/<HOST_SCOPE_NAME>/{system,home,_archive}
# - If a repo already accepts the current password file, it is left unchanged.
# - Otherwise the tool uses an old password source (default: *.prev) or prompts
#   interactively for the old repo password and rotates the repo to the current
#   local password value.
#
# Usage:
#   sudo /usr/local/sbin/penelope-rotate-external-restic-passwords.sh --uuid <UUID>
#   sudo /usr/local/sbin/penelope-rotate-external-restic-passwords.sh
#
# Optional old-password inputs:
#   --old-system-file <path>
#   --old-home-file <path>
#   --old-archive-file <path>
#
# Defaults:
#   system  -> /root/.config/restic/system_pw.prev
#   home    -> /root/.config/restic/home_pw.prev
#   archive -> /root/.config/restic/_archive_pw.prev
#
# If an old password file is missing or empty and the repo still requires the old
# password, the tool prompts interactively for that old password.
EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_HEAD
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_backup_dashboard_file_helpers
    emit_generated_usb_allowlist_helpers
    emit_generated_runtime_lock_helpers
    cat <<'EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_HEAD'
readonly CONF_FILE="/etc/${PROJECT}/backup.conf"
readonly USB_CONF="/etc/${PROJECT}/usb-backup-disks.conf"
readonly RESTIC_CONFIG_DIR="/root/.config/restic"

all_rotation_repo_types() {
  printf '%s\n' "system" "home" "archive"
}

current_password_file_for_repo_type() {
  local repo_type="${1:?repo type required}"
  case "${repo_type}" in
    system)
      printf '%s\n' "${RESTIC_CONFIG_DIR}/system_pw"
      ;;
    home)
      printf '%s\n' "${RESTIC_CONFIG_DIR}/home_pw"
      ;;
    archive)
      printf '%s\n' "${RESTIC_CONFIG_DIR}/_archive_pw"
      ;;
    *)
      die "Unknown rotation repo type: ${repo_type}"
      ;;
  esac
}

default_old_password_file_for_repo_type() {
  local repo_type="${1:?repo type required}"
  printf '%s.prev\n' "$(current_password_file_for_repo_type "${repo_type}")"
}

repo_relpath_for_rotation_type() {
  local repo_type="${1:?repo type required}"
  case "${repo_type}" in
    system|home)
      printf '%s\n' "${repo_type}"
      ;;
    archive)
      printf '%s\n' '_archive'
      ;;
    *)
      die "Unknown rotation repo type: ${repo_type}"
      ;;
  esac
}

readonly RUN_DIR="/run/penelope"
readonly ROTATION_LOCK_DIR="${RUN_DIR}/usb-password-rotation.lock.d"
validate_rotation_loaded_conf_runtime_controls() {
  validate_absolute_path_value "${USB_MOUNT_BASE:-}" "USB_MOUNT_BASE" "loaded backup.conf:USB_MOUNT_BASE"
  validate_bool_01_value "${FORCE_UNMOUNT_EXTERNAL:-}" "FORCE_UNMOUNT_EXTERNAL" "loaded backup.conf:FORCE_UNMOUNT_EXTERNAL"
}

RUN_UUID=""
RUN_OLD_SYSTEM_FILE="$(default_old_password_file_for_repo_type system)"
RUN_OLD_HOME_FILE="$(default_old_password_file_for_repo_type home)"
RUN_OLD_ARCHIVE_FILE="$(default_old_password_file_for_repo_type archive)"
HOST_SCOPE_NAME=""
TARGET_HOST=""
USB_MOUNT_BASE=""
FORCE_UNMOUNT_EXTERNAL=""
BACKUP_LOG=""
BACKUP_DASHBOARD_DIR=""
OPS_KIND="external-password-rotation"
OPS_EVENT_FINALIZED="0"
TEMP_SECRET_FILES=()
init_single_uuid_run_lock_state
MOUNTED_BY_US="0"
MOUNTED_PATH=""
USB_DEV=""
SHARED_OLD_PASSWORD_FILE=""
CURRENT_ROTATION_REPO=""
declare -A ROTATION_STATUS=(
  [system]="pending"
  [home]="pending"
  [archive]="pending"
)

usage() {
  cat <<'USAGE_ROTATE_EXTERNAL'
Usage:
  sudo /usr/local/sbin/penelope-rotate-external-restic-passwords.sh [--uuid <UUID>]
      [--old-system-file <path>] [--old-home-file <path>] [--old-archive-file <path>]

Behavior:
  - Uses the current local password files as the target password state.
  - Uses *.prev files by default as the old password state when a repo still needs it.
  - If no UUID is given, exactly one present allowlisted USB disk is selected.
    On a TTY the tool can wait for insertion and rescan.
USAGE_ROTATE_EXTERNAL
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uuid)
        [[ $# -ge 2 ]] || die "--uuid requires a value"
        RUN_UUID="$2"
        shift 2
        ;;
      --old-system-file)
        [[ $# -ge 2 ]] || die "--old-system-file requires a value"
        RUN_OLD_SYSTEM_FILE="$2"
        shift 2
        ;;
      --old-home-file)
        [[ $# -ge 2 ]] || die "--old-home-file requires a value"
        RUN_OLD_HOME_FILE="$2"
        shift 2
        ;;
      --old-archive-file)
        [[ $# -ge 2 ]] || die "--old-archive-file requires a value"
        RUN_OLD_ARCHIVE_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

ensure_nonempty_file() {
  local file="${1:?file required}"
  [[ -s "${file}" ]] || die "Required password file missing or empty: ${file}"
}

load_conf() {
  [[ -f "${CONF_FILE}" ]] || die "Missing config: ${CONF_FILE}"
  unset     USB_MOUNT_BASE     FORCE_UNMOUNT_EXTERNAL     HOST_SCOPE_NAME     BACKUP_DASHBOARD_DIR     LOG_DIR     BACKUP_LOG
  # shellcheck source=/dev/null
  source "${CONF_FILE}"
  load_backup_runtime_context_from_conf "${CONF_FILE}" "/var/lib/${PROJECT}/backup-dashboard"
}

EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_HEAD
  cat <<'EOF_OPS_HELPERS_ROTATE'
ensure_ops_backup_dashboard() {
  ensure_backup_dashboard "${BACKUP_DASHBOARD_DIR}"
}

write_ops_backup_dashboard_event() {
  local event="${1:?event required}"
  local message="${2:-}"
  local uuid="${3:-${RUN_UUID}}"
  local status_file="${BACKUP_DASHBOARD_DIR}/events-ops.log"
  append_backup_dashboard_event_line "${status_file}" "ops" "${event}" "${message}" "${uuid}" "all" "${OPS_KIND}" "" || true
}

write_ops_backup_dashboard_json() {
  local status="${1:?status required}"
  local event="${2:?event required}"
  local message="${3:-}"
  local uuid="${4:-${RUN_UUID}}"
  local out="${BACKUP_DASHBOARD_DIR}/last-ops.json"
  ensure_ops_backup_dashboard
  write_backup_dashboard_status_json_file "${out}" "ops" "${status}" "${message}" "${uuid}" "" "${OPS_KIND}" "${event}" "0" "0"
}

write_ops_backup_dashboard_status() {
  local status="${1:?status required}"
  local event="${2:?event required}"
  local message="${3:-}"
  local uuid="${4:-${RUN_UUID}}"
  write_ops_backup_dashboard_event "${event}" "${message}" "${uuid}"
  write_ops_backup_dashboard_json "${status}" "${event}" "${message}" "${uuid}"
}
EOF_OPS_HELPERS_ROTATE
  cat <<'EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_TAIL'

ops_on_exit() {
  local rc="${1:-0}"
  local summary=""
  local message=""
  summary="$(rotation_status_summary)"
  if (( rc != 0 )) && [[ "${OPS_EVENT_FINALIZED}" != "1" ]]; then
    message="External USB password rotation failed. Repo outcomes: ${summary}."
    if [[ -n "${CURRENT_ROTATION_REPO}" ]]; then
      message="${message} Failure occurred while processing repo=${CURRENT_ROTATION_REPO}."
    fi
    message="${message} Leave the disk attached and contact the operator if needed."
    log "External password rotation failed for UUID=${RUN_UUID} host_scope=${HOST_SCOPE_NAME}; repo outcomes: ${summary}"
    write_ops_backup_dashboard_status "failed" "external-password-rotation-failed" "${message}" "${RUN_UUID}"
    OPS_EVENT_FINALIZED="1"
  fi
}

list_host_scopes_at_mount() {
  local mount_path="${1:?mount path required}"
  [[ -d "${mount_path}" ]] || return 0
  find "${mount_path}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -u
}

die_scope_not_found() {
  local mount_path="${1:?mount path required}"
  local expected_scope="${2:?expected scope required}"
  mapfile -t found_scopes < <(list_host_scopes_at_mount "${mount_path}")
  if (( ${#found_scopes[@]} == 0 )); then
    die "No external backup scope found for HOST_SCOPE_NAME=${expected_scope} at ${mount_path} (found no host-scope directories on the disk root)."
  fi
  die "No external backup scope found for HOST_SCOPE_NAME=${expected_scope} at ${mount_path} (found scopes: ${found_scopes[*]})."
}

resolve_external_uuid() {
  if [[ -n "${RUN_UUID}" ]]; then
    uuid_in_allowlist "${USB_CONF}" "${RUN_UUID}" || die "UUID is not allowlisted in ${USB_CONF}: ${RUN_UUID}"
    while ! blkid -U "${RUN_UUID}" >/dev/null 2>&1; do
      if [[ -t 0 ]]; then
        printf 'Insert the registered USB backup disk with UUID %s and press Enter to rescan. ' "${RUN_UUID}" >&2
        read -r _dummy || true
      else
        die "USB UUID not present: ${RUN_UUID}"
      fi
    done
    printf '%s\n' "${RUN_UUID}"
    return 0
  fi

  while true; do
    mapfile -t present < <(read_present_allowlisted_uuids "${USB_CONF}")
    if (( ${#present[@]} == 1 )); then
      printf '%s\n' "${present[0]}"
      return 0
    fi
    if (( ${#present[@]} > 1 )); then
      if [[ -t 0 ]]; then
        >&2 echo "Multiple allowlisted USB disks detected. Please select one:"
        select pick in "${present[@]}"; do
          [[ -n "${pick}" ]] || { >&2 echo "Invalid selection."; continue; }
          printf '%s\n' "${pick}"
          return 0
        done
      fi
      die "Multiple allowlisted USB disks detected. Re-run with --uuid <UUID>."
    fi
    if [[ -t 0 ]]; then
      printf 'Insert one registered USB backup disk and press Enter to rescan. ' >&2
      read -r _dummy || true
      continue
    fi
    die "No present allowlisted USB disks detected."
  done
}

acquire_rotation_lock() {
  acquire_pid_dir_lock "${ROTATION_LOCK_DIR}" "USB password rotation"
}

lock_usb_uuid() {
  local uuid="${1:?uuid required}"
  acquire_single_uuid_run_lock "${uuid}" "External backup activity already holds the USB lock for UUID ${uuid}." "${RUN_DIR}"
}

release_uuid_lock() {
  if ! release_single_uuid_run_lock; then
    warn "Failed to release USB UUID lock: ${UUID_LOCK_PATH:-unknown}"
    return 1
  fi
  return 0
}

set_rotation_repo_status() {
  local repo_type="${1:?repo type required}"
  local status="${2:?status required}"
  [[ -n "${ROTATION_STATUS["${repo_type}"]+set}" ]] || die "Unknown rotation repo type: ${repo_type}"
  ROTATION_STATUS["${repo_type}"]="${status}"
}

rotation_repo_status() {
  local repo_type="${1:?repo type required}"
  [[ -n "${ROTATION_STATUS["${repo_type}"]+set}" ]] || die "Unknown rotation repo type: ${repo_type}"
  printf '%s
' "${ROTATION_STATUS["${repo_type}"]}"
}

rotation_status_summary() {
  local repo_type=""
  local status=""
  local parts=()
  while IFS= read -r repo_type; do
    status="$(rotation_repo_status "${repo_type}")"
    parts+=("${repo_type}=${status}")
  done < <(all_rotation_repo_types)
  printf '%s\n' "${parts[*]}"
}

mount_usb() {
  local uuid="${1:?uuid required}"
  local mount_base="${2:?mount base required}"

  USB_DEV="$(usb_dev_for_uuid "${uuid}")"
  [[ -n "${USB_DEV}" ]] || die "USB UUID not found: ${uuid}"

  local fstype
  fstype="$(usb_fstype_for_dev "${USB_DEV}")"
  [[ -n "${fstype}" ]] || die "Could not determine filesystem type for ${USB_DEV} (UUID=${uuid})"

  local mnt="${mount_base}/${uuid}"
  install -d -m 0700 -o root -g root "${mnt}"

  local existing_mnt=""
  local existing_mounts=()
  mapfile -t existing_mounts < <(findmnt -n -o TARGET --source "${USB_DEV}" 2>/dev/null || true)
  if (( ${#existing_mounts[@]} > 0 )); then
    existing_mnt="${existing_mounts[0]}"
    local existing_mounts_display=""
    existing_mounts_display="$(printf '%s\n' "${existing_mounts[@]}" | paste -sd ', ' -)"
    if [[ "${FORCE_UNMOUNT_EXTERNAL}" == "1" ]]; then
      log "USB ${uuid} (${USB_DEV}) already mounted at ${existing_mounts_display}; taking over control."
      unmount_all_mounts_for_dev "${USB_DEV}" || die "Failed to unmount existing mounts for ${USB_DEV}"
      dev_is_mounted_anywhere "${USB_DEV}" && die "USB ${uuid} (${USB_DEV}) remains mounted after takeover attempt."
    else
      if (( ${#existing_mounts[@]} > 1 )); then
        die "USB ${uuid} (${USB_DEV}) is mounted at multiple targets (${existing_mounts_display}). Refusing ambiguous reuse while FORCE_UNMOUNT_EXTERNAL=0."
      fi
      warn "USB ${uuid} (${USB_DEV}) already mounted at ${existing_mnt}; reusing existing mount."
      MOUNTED_BY_US="0"
      printf '%s\n' "${existing_mnt}"
      return 0
    fi
  fi

  if mountpoint -q "${mnt}"; then
    MOUNTED_BY_US="0"
    printf '%s\n' "${mnt}"
    return 0
  fi

  local opts="nosuid,nodev,noexec,noatime"
  if mount -o "${opts}" "${USB_DEV}" "${mnt}"; then
    MOUNTED_BY_US="1"
    printf '%s\n' "${mnt}"
    return 0
  fi

  if [[ "${fstype}" == "exfat" ]]; then
    if mount -t exfat -o "${opts}" "${USB_DEV}" "${mnt}" 2>/dev/null; then
      MOUNTED_BY_US="1"
      printf '%s\n' "${mnt}"
      return 0
    fi
    if mount -t exfat-fuse -o "${opts}" "${USB_DEV}" "${mnt}" 2>/dev/null; then
      MOUNTED_BY_US="1"
      printf '%s\n' "${mnt}"
      return 0
    fi
  fi

  die "Failed to mount ${USB_DEV} at ${mnt}"
}

cleanup() {
  local tmp=""
  local cleanup_failed=0
  for tmp in "${TEMP_SECRET_FILES[@]:-}"; do
    [[ -n "${tmp}" ]] || continue
    if [[ -e "${tmp}" ]]; then
      shred -u "${tmp}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
    fi
  done
  if [[ "${MOUNTED_BY_US}" == "1" && -n "${MOUNTED_PATH}" && -n "${USB_DEV}" ]]; then
    if mountpoint -q "${MOUNTED_PATH}"; then
      umount "${MOUNTED_PATH}" 2>/dev/null || true
    fi
    if dev_is_mounted_anywhere "${USB_DEV}"; then
      warn "USB device ${USB_DEV} is still mounted after rotation."
    fi
  fi
  release_uuid_lock || cleanup_failed=1
  if ! release_pid_dir_lock "${ROTATION_LOCK_DIR}"; then
    warn "Failed to release USB password rotation lock: ${ROTATION_LOCK_DIR}"
    cleanup_failed=1
  fi
  return "${cleanup_failed}"
}

repo_uses_password_file() {
  local repo="${1:?repo required}"
  local pw_file="${2:?pw_file required}"
  RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw_file}" restic snapshots --json >/dev/null 2>&1
}

prompt_old_password_to_temp() {
  local label="${1:?label required}"
  [[ "${label}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Unsafe repo label for temporary password file: ${label}"
  [[ -d "${RUN_DIR}" ]] || die "Runtime directory missing for temporary password file: ${RUN_DIR}"
  [[ -t 0 ]] || die "Old password for ${label} repo is required, but no TTY is available for prompting."
  local tmp
  tmp="$(mktemp "${RUN_DIR}/restic-old-${label}.XXXXXX")"
  chmod 0600 "${tmp}"
  local pw=""
  printf 'Enter previous password for external %s repo: ' "${label}" >&2
  read -r -s pw
  printf '\n' >&2
  printf '%s' "${pw}" > "${tmp}"
  pw=""
  TEMP_SECRET_FILES+=("${tmp}")
  printf '%s\n' "${tmp}"
}


configured_old_password_file_for_repo_type() {
  local repo_type="${1:?repo type required}"
  case "${repo_type}" in
    system)
      printf '%s\n' "${RUN_OLD_SYSTEM_FILE}"
      ;;
    home)
      printf '%s\n' "${RUN_OLD_HOME_FILE}"
      ;;
    archive)
      printf '%s\n' "${RUN_OLD_ARCHIVE_FILE}"
      ;;
    *)
      die "Unknown rotation repo type: ${repo_type}"
      ;;
  esac
}

resolve_old_password_source_for_repo() {
  local label="${1:?label required}"
  local repo="${2:?repo required}"
  local old_pw_file="${3:-}"

  if [[ -n "${old_pw_file}" && -s "${old_pw_file}" ]]; then
    if repo_uses_password_file "${repo}" "${old_pw_file}"; then
      printf '%s\n' "${old_pw_file}"
      return 0
    fi
    warn "${label}: configured previous password file does not match this repo; falling back to interactive previous-password flow."
  fi

  if [[ -n "${SHARED_OLD_PASSWORD_FILE}" && -s "${SHARED_OLD_PASSWORD_FILE}" ]]; then
    if repo_uses_password_file "${repo}" "${SHARED_OLD_PASSWORD_FILE}"; then
      printf '%s\n' "${SHARED_OLD_PASSWORD_FILE}"
      return 0
    fi
    warn "${label}: shared previous password does not match this repo; prompting for a repo-specific previous password."
  fi

  if [[ -z "${SHARED_OLD_PASSWORD_FILE}" || ! -s "${SHARED_OLD_PASSWORD_FILE}" ]]; then
    SHARED_OLD_PASSWORD_FILE="$(prompt_old_password_to_temp "${label}")"
    if repo_uses_password_file "${repo}" "${SHARED_OLD_PASSWORD_FILE}"; then
      printf '%s\n' "${SHARED_OLD_PASSWORD_FILE}"
      return 0
    fi
    warn "${label}: initial previous password does not match this repo; prompting for a repo-specific previous password."
  fi

  local repo_specific_old
  repo_specific_old="$(prompt_old_password_to_temp "${label}")"
  if repo_uses_password_file "${repo}" "${repo_specific_old}"; then
    printf '%s\n' "${repo_specific_old}"
    return 0
  fi

  warn "${label}: repo does not accept the provided previous password."
  return 1
}

rotate_one_repo() {
  local label="${1:?label required}"
  local repo="${2:?repo required}"
  local current_pw_file="${3:?current pw file required}"
  local old_pw_file="${4:-}"
  local old_source=""

  CURRENT_ROTATION_REPO="${label}"
  set_rotation_repo_status "${label}" "in-progress"

  if [[ ! -d "${repo}" || ! -f "${repo}/config" ]]; then
    warn "Skipping ${label}: repo not initialized at ${repo}"
    set_rotation_repo_status "${label}" "skipped-uninitialized"
    CURRENT_ROTATION_REPO=""
    return 0
  fi

  if repo_uses_password_file "${repo}" "${current_pw_file}"; then
    log "${label}: repo already accepts current password file; no rotation needed."
    set_rotation_repo_status "${label}" "already-current"
    CURRENT_ROTATION_REPO=""
    return 0
  fi

  if ! old_source="$(resolve_old_password_source_for_repo "${label}" "${repo}" "${old_pw_file}")"; then
    set_rotation_repo_status "${label}" "failed-old-password"
    die "Failed to resolve a working previous password for ${label} repo: ${repo}"
  fi

  log "${label}: rotating external repo ${repo} to the current local password value."
  if ! RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${old_source}" restic key passwd --new-password-file "${current_pw_file}"; then
    set_rotation_repo_status "${label}" "failed-rotation"
    die "Failed to rotate password for ${label} repo: ${repo}"
  fi

  if repo_uses_password_file "${repo}" "${current_pw_file}"; then
    log "${label}: verification with current password succeeded."
    set_rotation_repo_status "${label}" "rotated"
    CURRENT_ROTATION_REPO=""
    return 0
  fi

  set_rotation_repo_status "${label}" "failed-post-verify"
  die "${label}: repo still does not accept the current password after rotation: ${repo}"
}

main() {
  parse_cli "$@"

  require_root
  require_cmd_many restic blkid findmnt mount umount
  load_conf
  validate_rotation_loaded_conf_runtime_controls
  require_usb_allowlist_file "${USB_CONF}"
  validate_usb_allowlist_disk_names "${USB_CONF}"
  local repo_type=""
  while IFS= read -r repo_type; do
    ensure_nonempty_file "$(current_password_file_for_repo_type "${repo_type}")"
  done < <(all_rotation_repo_types)

  acquire_rotation_lock
  trap 'rc=$?; cleanup; ops_on_exit "${rc}"' EXIT

  local uuid
  uuid="$(resolve_external_uuid)"
  RUN_UUID="${uuid}"
  write_ops_backup_dashboard_status "started" "external-password-rotation-started" "External USB password rotation started for UUID=${uuid}." "${uuid}"
  lock_usb_uuid "${uuid}"

  log "External password rotation starting for UUID=${uuid} host_scope=${HOST_SCOPE_NAME}"

  MOUNTED_PATH="$(mount_usb "${uuid}" "${USB_MOUNT_BASE}")"
  local base="${MOUNTED_PATH}/${HOST_SCOPE_NAME}"
  [[ -d "${base}" ]] || die_scope_not_found "${MOUNTED_PATH}" "${HOST_SCOPE_NAME}"

  while IFS= read -r repo_type; do
    local current_pw_file=""
    local repo_path=""
    local old_pw_file=""
    current_pw_file="$(current_password_file_for_repo_type "${repo_type}")"
    repo_path="${base}/$(repo_relpath_for_rotation_type "${repo_type}")"
    old_pw_file="$(configured_old_password_file_for_repo_type "${repo_type}")"
    rotate_one_repo "${repo_type}" "${repo_path}" "${current_pw_file}" "${old_pw_file}"
  done < <(all_rotation_repo_types)

  local summary=""
  summary="$(rotation_status_summary)"
  log "External password rotation completed for UUID=${uuid} host_scope=${HOST_SCOPE_NAME}; repo outcomes: ${summary}"
  write_ops_backup_dashboard_status "success" "external-password-rotation-success" "External USB password rotation completed for UUID=${uuid}. Repo outcomes: ${summary}." "${uuid}"
  OPS_EVENT_FINALIZED="1"
}

main "$@"
EOF_ROTATE_EXTERNAL_PASSWORDS_SCRIPT_TAIL
  } | install_file_from_heredoc "${tool_path}" 0750 root root "rotate-external-restic-passwords"
}

# -------------------- install backup find-snapshot helper --------------------
install_backup_find_snapshot() {
  local tool_path="/usr/local/sbin/penelope-backup-find-snapshot.sh"

  log "Installing backup find-snapshot helper: ${tool_path}"
  {
    cat <<'EOF_BACKUP_FIND_SNAPSHOT_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-backup-find-snapshot.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
#
# Read-only recovery helper: find the newest Restic snapshot that still contains
# a given absolute path in Penelope's system/home/_archive backup repositories.
# This helper never restores data, deletes data, writes repository state, or
# changes retention. It only mounts an external backup disk read-only if needed.
#
# Usage:
#   sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /home/internal/project
#   sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode external --disk-name <DISK_NAME> --target _archive --path /_archive/p001
#
EOF_BACKUP_FIND_SNAPSHOT_SCRIPT
    emit_generated_common_project_prelude
    emit_generated_backup_conf_context_helpers
    emit_generated_usb_allowlist_helpers
    emit_generated_runtime_lock_helpers
    emit_generated_backup_runner_target_repo_helpers
    cat <<'EOF_BACKUP_FIND_SNAPSHOT_SCRIPT'

readonly ETC_DIR="/etc/${PROJECT}"
readonly CONF_FILE="${ETC_DIR}/backup.conf"
readonly USB_CONF="${ETC_DIR}/usb-backup-disks.conf"

TARGET_HOST="${PENELOPE_TARGET_HOST:-$(hostname -s)}"
HOST_SCOPE_NAME="${PENELOPE_HOST_SCOPE_NAME:-${TARGET_HOST}}"
FIND_MODE="internal"
FIND_UUID=""
FIND_DISK_NAME_SELECTOR=""
FIND_TARGET="auto"
FIND_PATH=""
FIND_JSON="0"
FIND_MOUNTED_BY_US="0"
FIND_MOUNT_PATH=""
FIND_LOCK_HELD="0"
init_single_uuid_run_lock_state

internal_backup_run_is_active_runtime() {
  local lock_dir="/run/${PROJECT}/backup-run-internal.lock.d"
  pid_dir_lock_is_active_runtime "${lock_dir}" "internal backup run"
}

print_help() {
  cat >&2 <<'HELP_FIND_SNAPSHOT'
Usage:
  sudo /usr/local/sbin/penelope-backup-find-snapshot.sh \
    --mode internal|external [--uuid <UUID>|--disk-name <DISK_NAME>] \
    --target system|home|_archive|auto --path <absolute-path> [--json]

Purpose:
  Find the newest Restic snapshot that still contains the requested path.
  This is a read-only recovery preparation helper. It does not restore, delete,
  prune, unlock, or modify any repository.

Targets:
  auto      infer home for /home paths, _archive for /_archive paths, system otherwise
  system    system repository; rejects /home, /_archive, /_backup, and volatile trees
  home      /home or a path below /home
  _archive  /_archive or a path below /_archive

Examples:
  sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /home/internal/project-x
  sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /_archive/p001
  sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target system --path /etc/penelope/backup.conf
  sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode external --disk-name penelope-01 --target auto --path /_archive/p001

Exit codes:
  0  snapshot found
  1  operational or configuration error
  2  no snapshot containing the path was found
HELP_FIND_SNAPSHOT
}

parse_cli() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --mode)
        FIND_MODE="${2:-}"
        shift 2
        ;;
      --uuid)
        FIND_UUID="${2:-}"
        shift 2
        ;;
      --disk-name)
        FIND_DISK_NAME_SELECTOR="${2:-}"
        shift 2
        ;;
      --target)
        FIND_TARGET="${2:-}"
        shift 2
        ;;
      --path)
        FIND_PATH="${2:-}"
        shift 2
        ;;
      --json)
        FIND_JSON="1"
        shift
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  case "${FIND_MODE}" in
    internal|external) : ;;
    *) die "--mode must be internal or external (got: ${FIND_MODE})" ;;
  esac
  case "${FIND_TARGET}" in
    system|home|_archive|auto) : ;;
    *) die "--target must be system, home, _archive, or auto (got: ${FIND_TARGET})" ;;
  esac
  [[ -n "${FIND_PATH}" ]] || die "--path <absolute-path> is required."
  [[ "${FIND_PATH}" == /* ]] || die "--path must be absolute: ${FIND_PATH}"
  if [[ "${FIND_MODE}" == "internal" ]]; then
    [[ -z "${FIND_UUID}" ]] || die "--uuid is only valid with --mode external."
    [[ -z "${FIND_DISK_NAME_SELECTOR}" ]] || die "--disk-name is only valid with --mode external."
  else
    [[ -z "${FIND_UUID}" || -z "${FIND_DISK_NAME_SELECTOR}" ]] || die "Use either --uuid or --disk-name, not both."
  fi
}

load_conf() {
  [[ -f "${CONF_FILE}" ]] || die "Missing config: ${CONF_FILE} (run penelope-backup-setup apply first)."
  unset \
    INTERNAL_BACKUP_STALE_AFTER_HOURS \
    FORCE_UNMOUNT_EXTERNAL \
    WRITE_USB_SUCCESS_MARKER \
    ENABLE_PRUNE \
    FULL_BACKUP_WEEKDAYS_INTERNAL \
    FULL_BACKUP_WEEKDAYS_EXTERNAL \
    KEEP_CYCLES_INTERNAL \
    KEEP_CYCLES_EXTERNAL \
    KEEP_UNTAGGED_LAST \
    USB_MOUNT_BASE \
    USB_FS_UMASK \
    HOST_SCOPE_NAME \
    BACKUP_DASHBOARD_DIR \
    LOG_DIR \
    BACKUP_LOG
  # shellcheck source=/dev/null
  source "${CONF_FILE}"
  load_backup_runtime_context_from_conf "${CONF_FILE}" "/var/lib/${PROJECT}/backup-dashboard"
  export TARGET_HOST HOST_SCOPE_NAME
  : "${LOG_DIR}" "${BACKUP_LOG}"
  validate_loaded_backup_runtime_controls_from_env
}

resolve_target_for_path() {
  local requested="${1:?target required}"
  local path="${2:?path required}"
  path="$(normalize_absolute_path_for_prefix_check "${path}")"

  if [[ "${requested}" != "auto" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  if path_is_same_or_below "${path}" "/home"; then
    printf '%s\n' "home"
    return 0
  fi
  if path_is_same_or_below "${path}" "/_archive"; then
    printf '%s\n' "_archive"
    return 0
  fi

  case "${path}" in
    /_backup|/_backup/*|/proc|/proc/*|/dev|/dev/*|/sys|/sys/*|/run|/run/*|/tmp|/tmp/*|/mnt|/mnt/*|/media|/media/*)
      die "Path is outside Penelope's recoverable source sets or belongs to a volatile/excluded tree: ${path}"
      ;;
  esac

  printf '%s\n' "system"
}

validate_path_for_target() {
  local target="${1:?target required}"
  local path="${2:?path required}"
  path="$(normalize_absolute_path_for_prefix_check "${path}")"

  case "${target}" in
    home)
      path_is_same_or_below "${path}" "/home" || die "Target home can only search /home or paths below /home (got: ${path})."
      ;;
    _archive)
      path_is_same_or_below "${path}" "/_archive" || die "Target _archive can only search /_archive or paths below /_archive (got: ${path})."
      ;;
    system)
      case "${path}" in
        /home|/home/*|/_archive|/_archive/*|/_backup|/_backup/*|/proc|/proc/*|/dev|/dev/*|/sys|/sys/*|/run|/run/*|/tmp|/tmp/*|/mnt|/mnt/*|/media|/media/*)
          die "Target system does not contain ${path}; choose --target auto/home/_archive where appropriate, and do not search volatile or backup-repository trees."
          ;;
      esac
      ;;
    *)
      die "Internal error: unexpected resolved target: ${target}"
      ;;
  esac
}

find_snapshot_mount_path_is_mounted() {
  local path="${1:?mount path required}"
  findmnt -n --target "${path}" >/dev/null 2>&1
}

mount_external_usb_readonly() {
  local uuid="${1:?uuid required}"
  local dev=""
  local fstype=""
  local mnt=""
  local existing_mounts=()
  local existing_mounts_display=""
  local opts="ro,nosuid,nodev,noexec,noatime"

  dev="$(usb_dev_for_uuid "${uuid}")"
  [[ -n "${dev}" ]] || die "External UUID is allowlisted but not currently connected: ${uuid}"
  fstype="$(usb_fstype_for_dev "${dev}")"
  [[ -n "${fstype}" ]] || die "Could not determine filesystem type for ${dev} (UUID=${uuid})."

  mapfile -t existing_mounts < <(findmnt -n -o TARGET --source "${dev}" 2>/dev/null || true)
  if (( ${#existing_mounts[@]} > 0 )); then
    existing_mounts_display="$(printf '%s\n' "${existing_mounts[@]}" | paste -sd ', ' -)"
    (( ${#existing_mounts[@]} == 1 )) || die "USB ${uuid} (${dev}) is mounted at multiple targets (${existing_mounts_display}); refusing ambiguous read-only snapshot search."
    FIND_MOUNTED_BY_US="0"
    printf '%s\n' "${existing_mounts[0]}"
    return 0
  fi

  mnt="${USB_MOUNT_BASE}/${uuid}"
  install -d -m 0700 -o root -g root "${mnt}"
  if mount -o "${opts}" "${dev}" "${mnt}"; then
    FIND_MOUNTED_BY_US="1"
    printf '%s\n' "${mnt}"
    return 0
  fi
  if [[ "${fstype}" == "exfat" ]]; then
    if mount -t exfat -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      FIND_MOUNTED_BY_US="1"
      printf '%s\n' "${mnt}"
      return 0
    fi
    if mount -t exfat-fuse -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
      FIND_MOUNTED_BY_US="1"
      printf '%s\n' "${mnt}"
      return 0
    fi
  fi

  die "Failed to mount ${dev} read-only at ${mnt}."
}

cleanup() {
  local rc=$?
  local cleanup_failed=0

  if [[ "${FIND_MOUNTED_BY_US}" == "1" && -n "${FIND_MOUNT_PATH}" ]]; then
    if find_snapshot_mount_path_is_mounted "${FIND_MOUNT_PATH}"; then
      umount "${FIND_MOUNT_PATH}" || cleanup_failed=1
    fi
  fi
  if [[ "${FIND_LOCK_HELD}" == "1" ]]; then
    release_single_uuid_run_lock || cleanup_failed=1
  fi

  if (( cleanup_failed )) && (( rc == 0 )); then
    rc=1
  fi
  exit "${rc}"
}

snapshot_rows_newest_first() {
  local repo="${1:?repo required}"
  local pw_file="${2:?password file required}"
  local snapshots_json=""

  snapshots_json="$(RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw_file}" restic snapshots --json --no-lock)" \
    || die "Failed to list snapshots for repository: ${repo}"

  printf '%s' "${snapshots_json}" | python3 -c '
import datetime
import json
import sys

def parse_time(value):
    text = str(value or "")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return 0.0

data = json.load(sys.stdin)
items = []
for item in data:
    sid = str(item.get("id") or "")
    if not sid:
        continue
    short_id = str(item.get("short_id") or sid[:8])
    time_value = str(item.get("time") or "")
    hostname = str(item.get("hostname") or "")
    items.append((parse_time(time_value), sid, short_id, time_value, hostname))
items.sort(key=lambda row: row[0], reverse=True)
for _, sid, short_id, time_value, hostname in items:
    print("\t".join([sid, short_id, time_value, hostname]))
'
}

emit_json_result() {
  local found="${1:?found required}"
  local mode="${2:?mode required}"
  local target="${3:?target required}"
  local path="${4:?path required}"
  local repo="${5:?repo required}"
  local snapshot_id="${6:-}"
  local snapshot_short_id="${7:-}"
  local snapshot_time="${8:-}"
  local snapshot_host="${9:-}"
  python3 - \
    "${found}" "${mode}" "${target}" "${path}" "${repo}" \
    "${snapshot_id}" "${snapshot_short_id}" "${snapshot_time}" "${snapshot_host}" \
    "${HOST_SCOPE_NAME}" "${FIND_UUID}" "${FIND_DISK_NAME_SELECTOR}" <<'PY_FIND_SNAPSHOT_JSON'
import json
import sys
(
    found,
    mode,
    target,
    path,
    repo,
    snapshot_id,
    snapshot_short_id,
    snapshot_time,
    snapshot_host,
    host_scope_name,
    uuid,
    disk_name,
) = sys.argv[1:13]
data = {
    "found": found == "true",
    "mode": mode,
    "target": target,
    "path": path,
    "repository": repo,
    "host_scope_name": host_scope_name,
}
if uuid:
    data["uuid"] = uuid
if disk_name:
    data["disk_name"] = disk_name
if found == "true":
    data["snapshot_id"] = snapshot_id
    data["snapshot_short_id"] = snapshot_short_id
    data["snapshot_time"] = snapshot_time
    data["snapshot_host"] = snapshot_host
json.dump(data, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY_FIND_SNAPSHOT_JSON
}

find_newest_snapshot_containing_path() {
  local repo="${1:?repo required}"
  local pw_file="${2:?password file required}"
  local mode="${3:?mode required}"
  local target="${4:?target required}"
  local path="${5:?path required}"
  local snapshot_id=""
  local short_id=""
  local time_value=""
  local snapshot_host=""

  [[ -d "${repo}" ]] || die "Repository directory is missing: ${repo}"
  [[ -f "${repo}/config" ]] || die "Repository config is missing: ${repo}/config"
  [[ -s "${pw_file}" ]] || die "Restic password file is missing or empty: ${pw_file}"

  while IFS=$'\t' read -r snapshot_id short_id time_value snapshot_host; do
    [[ -n "${snapshot_id}" ]] || continue
    if RESTIC_REPOSITORY="${repo}" RESTIC_PASSWORD_FILE="${pw_file}" restic ls --no-lock "${snapshot_id}" "${path}" >/dev/null 2>&1; then
      if [[ "${FIND_JSON}" == "1" ]]; then
        emit_json_result "true" "${mode}" "${target}" "${path}" "${repo}" "${snapshot_id}" "${short_id}" "${time_value}" "${snapshot_host}"
      else
        printf 'Newest snapshot containing path:\n'
        printf '  mode: %s\n' "${mode}"
        printf '  target: %s\n' "${target}"
        printf '  path: %s\n' "${path}"
        printf '  snapshot_short_id: %s\n' "${short_id}"
        printf '  snapshot_id: %s\n' "${snapshot_id}"
        printf '  snapshot_time: %s\n' "${time_value}"
        [[ -z "${snapshot_host}" ]] || printf '  snapshot_host: %s\n' "${snapshot_host}"
        printf '  host_scope_name: %s\n' "${HOST_SCOPE_NAME}"
        if [[ "${mode}" == "external" ]]; then
          printf '  uuid: %s\n' "${FIND_UUID}"
          [[ -z "${FIND_DISK_NAME_SELECTOR}" ]] || printf '  disk_name: %s\n' "${FIND_DISK_NAME_SELECTOR}"
        fi
        printf '  repository: %s\n' "${repo}"
      fi
      return 0
    fi
  done < <(snapshot_rows_newest_first "${repo}" "${pw_file}")

  if [[ "${FIND_JSON}" == "1" ]]; then
    emit_json_result "false" "${mode}" "${target}" "${path}" "${repo}"
  else
    printf 'No snapshot containing path was found.\n' >&2
    printf '  mode: %s\n' "${mode}" >&2
    printf '  target: %s\n' "${target}" >&2
    printf '  path: %s\n' "${path}" >&2
    printf '  repository: %s\n' "${repo}" >&2
  fi
  return 2
}

main() {
  parse_cli "$@"
  require_root "sudo /usr/local/sbin/penelope-backup-find-snapshot.sh"
  require_cmd_many restic python3 findmnt mount umount
  load_conf

  FIND_PATH="$(normalize_absolute_path_for_prefix_check "${FIND_PATH}")"
  FIND_TARGET="$(resolve_target_for_path "${FIND_TARGET}" "${FIND_PATH}")"
  validate_path_for_target "${FIND_TARGET}" "${FIND_PATH}"

  local base=""
  local repo=""
  local pw_file=""
  local rc=0

  case "${FIND_MODE}" in
    internal)
      ensure_expected_penelope_mount_layout "continue"
      if internal_backup_run_is_active_runtime; then
        die "An internal backup is active; wait before searching internal snapshots so the recovery candidate is stable."
      fi
      base="/_backup/${HOST_SCOPE_NAME}"
      ;;
    external)
      require_usb_allowlist_file "${USB_CONF}"
      validate_usb_allowlist_disk_names "${USB_CONF}"
      if [[ -n "${FIND_DISK_NAME_SELECTOR}" ]]; then
        FIND_UUID="$(require_usb_allowlist_uuid_for_disk_name "${USB_CONF}" "${FIND_DISK_NAME_SELECTOR}")"
      elif [[ -n "${FIND_UUID}" ]]; then
        uuid_in_allowlist "${USB_CONF}" "${FIND_UUID}" || die "USB UUID is not allowlisted in ${USB_CONF}: ${FIND_UUID}"
        FIND_DISK_NAME_SELECTOR="$(require_usb_allowlist_name_for_uuid "${USB_CONF}" "${FIND_UUID}")"
      else
        die "--mode external requires --uuid <UUID> or --disk-name <DISK_NAME>."
      fi
      if ! try_acquire_single_uuid_run_lock "${FIND_UUID}" "/run/${PROJECT}"; then
        die "External backup activity already holds the USB lock for UUID ${FIND_UUID}; wait or cancel that activity before searching snapshots."
      fi
      FIND_LOCK_HELD="1"
      trap cleanup EXIT
      FIND_MOUNT_PATH="$(mount_external_usb_readonly "${FIND_UUID}")"
      base="${FIND_MOUNT_PATH}/${HOST_SCOPE_NAME}"
      ;;
    *)
      die "Internal error: unknown mode: ${FIND_MODE}"
      ;;
  esac

  repo="${base}/$(repo_relpath_for_target "${FIND_TARGET}")"
  pw_file="$(restic_password_file_for_target "${FIND_TARGET}")"
  find_newest_snapshot_containing_path "${repo}" "${pw_file}" "${FIND_MODE}" "${FIND_TARGET}" "${FIND_PATH}" || rc=$?
  return "${rc}"
}

main "$@"
EOF_BACKUP_FIND_SNAPSHOT_SCRIPT
  } | install_file_from_heredoc "${tool_path}" 0750 root root "backup find-snapshot helper"
}

install_offline_recover() {
  local tool_path="/usr/local/sbin/penelope-offline-recover.sh"

  log "Installing offline recovery tool: ${tool_path}"
  install_file_from_heredoc "${tool_path}" 0750 root root \
    "offline-recover" <<'EOF_OFFLINE_RECOVER_SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/penelope-offline-recover.sh
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
___PENELOPE_SOURCE_COMMON___
# Offline full restore (Live-USB/Rescue) for Penelope targets: system, home, _archive.
#
# Policy:
# - Offline-only (refuses to run on an installed system).
# - Full restore without staging => mkfs(clean) on target mapper (always destructive).
# - Optional --recreate-luks (luksFormat) with extra confirmation.
# - Before any destructive step begins, the tool preflights repo layout, restic password, and
#   snapshot resolution for all selected targets.
# - Repo sources default to read-only mounts (internal and external); external can be RW via --usb-mount-rw.
#
# Usage:
#   sudo ./penelope-offline-recover.sh --repo internal --targets home,_archive --snapshot <SNAPSHOT_ID> \
#     --yes-i-know-this-wipes-data
#   sudo ./penelope-offline-recover.sh --repo external --targets all --snapshot latest \
#     --yes-i-know-this-wipes-data
#   sudo ./penelope-offline-recover.sh --repo external --uuid <FS_UUID> --host-scope <SCOPE> \
#     --targets system --snapshot latest --yes-i-know-this-wipes-data
#   sudo ./penelope-offline-recover.sh --repo internal --targets all --list
#
# Exit codes:
#   0  Success
#   2  Invalid parameters
#   10 Offline-only guard failed
#   11 Missing dependency
#   12 Required device/partition not found
#   13 Repo detection failed
#   14 Restore failed
#   15 Mount/layout guard failed

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="___PENELOPE_SETUP_VERSION___"

readonly MNT_BASE="/mnt/penelope-offline-recover"
readonly MNT_SYSROOT="${MNT_BASE}/sysroot"
readonly MNT_HOME="${MNT_BASE}/home"
readonly MNT_ARCHIVE="${MNT_BASE}/archive"
readonly MNT_USB_BASE="${MNT_BASE}/usb"
readonly MNT_INTERNAL_REPO="/_backup"
readonly LOG_DEFAULT="/tmp/penelope-offline-recover.log"

readonly ROOT_PARTLABEL="ROOT_LUKS"
readonly HOME_PARTLABEL="HOME_LUKS"
readonly ARCHIVE_PARTLABEL="ARCHIVE_LUKS"
readonly BOOT_PARTLABEL="BOOT"
readonly EFI_PARTLABEL="EFI"
readonly BACKUP_PARTLABEL="_BACKUP"

readonly EXFAT_UMASK_DEFAULT="0077"

RUN_REPO=""
RUN_TARGETS_RAW=""
RUN_TARGETS=()
RUN_UUID=""
RUN_HOST_SCOPE=""
RUN_SNAPSHOT_MODE=""
RUN_RECREATE_LUKS="0"
RUN_ACK_WIPE="0"
RUN_USB_RW="0"
RUN_NON_INTERACTIVE="0"
RUN_LIST="0"
RUN_LOG_PATH="${LOG_DEFAULT}"

MASTERPW=""

declare -A PREFLIGHT_REPO_PATHS=()
declare -A PREFLIGHT_RESTIC_PWS=()
declare -A PREFLIGHT_SNAPSHOT_IDS=()

MOUNTED_BY_US=()
MAPPERS_OPENED=()
USB_TEMP_MOUNTS=()


die() {
  local msg="${1:-Unknown error}"
  local ec="${2:-1}"
  >&2 echo "[$(ts)] ERROR: ${msg}"
  exit "$ec"
}

usage() {
  cat >&2 <<'USAGE_STDERR'
penelope-offline-recover.sh

Offline full restore (Live-USB). Destructive: formats target filesystems (mkfs), optional luksFormat.

Required (restore mode):
  --repo internal|external
  --targets system,home,_archive|all
  --snapshot latest|<snapshot_id>
  --yes-i-know-this-wipes-data

Optional:
  --list                            Non-destructive listing (scopes/repos/latest snapshots)
  --uuid <USB_FILESYSTEM_UUID>      External only (filesystem UUID); otherwise autodetect
  --host-scope <HOST_SCOPE_NAME>    Otherwise autodetect
  --recreate-luks                   Optional; destroys LUKS headers; extra confirmation
  --usb-mount-rw                    External repo mount RW; default is RO
  --non-interactive                 No menus; fail if ambiguous
  --log <path>                      Default: /tmp/penelope-offline-recover.log

Examples:
  sudo ./penelope-offline-recover.sh --repo internal --targets home,_archive --snapshot <SNAPSHOT_ID> --yes-i-know-this-wipes-data
  sudo ./penelope-offline-recover.sh --repo external --targets all --snapshot latest --yes-i-know-this-wipes-data
  sudo ./penelope-offline-recover.sh --repo internal --targets all --list
USAGE_STDERR
}

require_bash_version() {
  if (( BASH_VERSINFO[0] < 4 )); then
    die "Bash >= 4.0 required. Detected: ${BASH_VERSION}" 11
  fi
}

sanitize_one_line() {
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  if (( ${#s} > 260 )); then
    s="${s:0:260}<TRUNCATED>"
  fi
  echo "${s}"
}

array_remove_value_inplace() {
  local needle="${1:?needle required}"
  shift || true
  local -a src=("$@")
  local -a out=()
  local v
  for v in "${src[@]}"; do
    [[ -n "${v}" ]] || continue
    [[ "${v}" == "${needle}" ]] && continue
    out+=("${v}")
  done
  printf '%s\n' "${out[@]}"
}

cleanup() {
  # Unmount temp USB mounts first (those created during scanning).
  local mp=""
  for mp in "${USB_TEMP_MOUNTS[@]:-}"; do
    [[ -n "${mp}" ]] || continue
    if mountpoint -q "${mp}"; then
      umount "${mp}" >/dev/null 2>&1 || true
    fi
  done

  # Unmount mounts we created (reverse order).
  local i
  for (( i=${#MOUNTED_BY_US[@]}-1; i>=0; i-- )); do
    mp="${MOUNTED_BY_US[i]}"
    [[ -n "${mp}" ]] || continue
    if mountpoint -q "${mp}"; then
      umount "${mp}" >/dev/null 2>&1 || true
    fi
  done

  # Close mappers (reverse order).
  local name=""
  for (( i=${#MAPPERS_OPENED[@]}-1; i>=0; i-- )); do
    name="${MAPPERS_OPENED[i]}"
    if [[ -e "/dev/mapper/${name}" ]]; then
      cryptsetup close "${name}" >/dev/null 2>&1 || true
    fi
  done

  rm -rf "${MNT_BASE}" >/dev/null 2>&1 || true

  MASTERPW=""
}

on_err() {
  local code="$?"
  local cmd="${BASH_COMMAND:-}"
  cmd="$(sanitize_one_line "${cmd}")"
  >&2 echo "[$(ts)] ERROR: Unhandled error (exit=${code}) while running: ${cmd}"
  exit 14
}

trap cleanup EXIT
trap on_err ERR

maybe_udevadm_settle() {
  if command -v udevadm >/dev/null 2>&1; then
    if ! udevadm settle --timeout=10 2>/dev/null; then
      warn "udevadm settle timeout; using sleep 2 as fallback"
      sleep 2
    fi
  fi
}

parse_cli() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 2
  fi

  while [[ "$#" -gt 0 ]]; do
    case "${1}" in
      -h|--help)
        usage
        exit 0
        ;;
      --repo)
        RUN_REPO="${2:-}"
        shift 2
        ;;
      --targets)
        RUN_TARGETS_RAW="${2:-}"
        shift 2
        ;;
      --uuid)
        RUN_UUID="${2:-}"
        shift 2
        ;;
      --host-scope)
        RUN_HOST_SCOPE="${2:-}"
        shift 2
        ;;
      --snapshot)
        RUN_SNAPSHOT_MODE="${2:-}"
        shift 2
        ;;
      --recreate-luks)
        RUN_RECREATE_LUKS="1"
        shift
        ;;
      --yes-i-know-this-wipes-data)
        RUN_ACK_WIPE="1"
        shift
        ;;
      --usb-mount-rw)
        RUN_USB_RW="1"
        shift
        ;;
      --non-interactive)
        RUN_NON_INTERACTIVE="1"
        shift
        ;;
      --list)
        RUN_LIST="1"
        shift
        ;;
      --log)
        RUN_LOG_PATH="${2:-}"
        shift 2
        ;;
      *)
        usage
        die "Unknown argument: ${1}" 2
        ;;
    esac
  done

  [[ -n "${RUN_REPO}" ]] || die "--repo is required" 2
  if [[ "${RUN_REPO}" != "internal" && "${RUN_REPO}" != "external" ]]; then
    die "Invalid --repo=${RUN_REPO}. Expected: internal|external" 2
  fi

  # Targets: required for restore mode; optional for --list (default: all).
  if [[ -z "${RUN_TARGETS_RAW}" ]]; then
    if [[ "${RUN_LIST}" == "1" ]]; then
      RUN_TARGETS_RAW="all"
    else
      die "--targets is required" 2
    fi
  fi

  if [[ "${RUN_LIST}" != "1" && -z "${RUN_SNAPSHOT_MODE}" ]]; then
    die "--snapshot is required in restore mode. Use --snapshot latest only if that is the intended recovery point." 2
  fi
  if [[ -n "${RUN_SNAPSHOT_MODE}" ]] && [[ "${RUN_SNAPSHOT_MODE}" != "latest" && ! "${RUN_SNAPSHOT_MODE}" =~ ^[0-9a-fA-F]{8,}$ ]]; then
    die "Invalid --snapshot=${RUN_SNAPSHOT_MODE}. Expected: latest or snapshot id" 2
  fi
  if [[ "${RUN_REPO}" == "internal" && -n "${RUN_UUID}" ]]; then
    die "--uuid is only valid with --repo external" 2
  fi
  if [[ "${RUN_RECREATE_LUKS}" == "1" && "${RUN_LIST}" == "1" ]]; then
    die "--recreate-luks is incompatible with --list" 2
  fi
  if [[ "${RUN_RECREATE_LUKS}" == "1" && "${RUN_ACK_WIPE}" != "1" ]]; then
    die "--recreate-luks requires --yes-i-know-this-wipes-data" 2
  fi
}

parse_targets() {
  local raw="${1:?targets required}"
  local t

  if [[ "${raw}" == "all" ]]; then
    RUN_TARGETS=("system" "home" "_archive")
    return 0
  fi

  IFS=',' read -r -a RUN_TARGETS <<< "${raw}"
  if [[ "${#RUN_TARGETS[@]}" -eq 0 ]]; then
    die "Invalid --targets (empty)" 2
  fi
  for t in "${RUN_TARGETS[@]}"; do
    case "${t}" in
      system|home|_archive)
        ;;
      *)
        die "Invalid target: ${t}. Supported: system,home,_archive,all" 2
        ;;
    esac
  done
}

offline_guard() {
  local root_fstype overlay_root rofs_present cdrom_mounted initramfs_dir

  root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  overlay_root="0"
  [[ "${root_fstype}" == "overlay" ]] && overlay_root="1"
  rofs_present="0"
  [[ -d /rofs ]] && rofs_present="1"
  cdrom_mounted="0"
  findmnt -n /cdrom >/dev/null 2>&1 && cdrom_mounted="1"
  initramfs_dir="0"
  [[ -d /run/initramfs ]] && initramfs_dir="1"

  local msg
  msg="Offline guard: root_fstype=${root_fstype:-unknown} overlay=${overlay_root} rofs=${rofs_present}"
  msg="${msg} cdrom=${cdrom_mounted} initramfs_dir=${initramfs_dir}"
  log "${msg}"

  if [[ "${overlay_root}" == "1" || "${rofs_present}" == "1" || "${cdrom_mounted}" == "1" ]]; then
    return 0
  fi

  >&2 echo "[$(ts)] ERROR: This tool is offline-only (Live-USB/Rescue). Refusing to run on an installed system."
  local msg
  msg="Detected markers: root_fstype=${root_fstype:-unknown} overlay=${overlay_root}"
  msg="${msg} rofs=${rofs_present} cdrom=${cdrom_mounted} initramfs_dir=${initramfs_dir}"
  >&2 echo "[$(ts)] ERROR: ${msg}"
  exit 10
}

ensure_dirs() {
  mkdir -p "${MNT_BASE}" "${MNT_SYSROOT}" "${MNT_HOME}" "${MNT_ARCHIVE}" "${MNT_USB_BASE}"
}

print_partlabel_help() {
  >&2 echo "[$(ts)] ERROR: This recovery tool expects the Penelope partition layout with PARTLABELs."
  local msg
  msg="Expected PARTLABELs: ${ROOT_PARTLABEL}, ${HOME_PARTLABEL}, ${ARCHIVE_PARTLABEL},"
  msg="${msg} ${BOOT_PARTLABEL}, ${EFI_PARTLABEL}, ${BACKUP_PARTLABEL}"
  >&2 echo "[$(ts)] ERROR: ${msg}"
  >&2 echo "[$(ts)] ERROR: If these labels are missing, the system likely was not installed/partitioned via penelope-install,"
  >&2 echo "[$(ts)] ERROR: or labels were changed."
  >&2 echo "[$(ts)] ERROR: Useful diagnostics:"
  >&2 echo "[$(ts)] ERROR:   lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,UUID,MOUNTPOINT"
  >&2 echo "[$(ts)] ERROR:   blkid"
}

dev_by_partlabel() {
  local label="${1:?PARTLABEL required}"
  local p="/dev/disk/by-partlabel/${label}"
  if [[ -e "${p}" ]]; then
    readlink -f "${p}"
    return 0
  fi
  return 1
}

ensure_unique_device() {
  local label="${1:?label required}"
  local path="/dev/disk/by-partlabel/${label}"

  maybe_udevadm_settle

  if [[ ! -e "${path}" ]]; then
    >&2 echo "[$(ts)] ERROR: Missing PARTLABEL=${label} (${path} not present)."
    print_partlabel_help
    >&2 echo "[$(ts)] ERROR: lsblk output:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,UUID,MOUNTPOINT >&2 || true
    return 1
  fi
  local dev
  dev="$(readlink -f "${path}" 2>/dev/null || true)"
  if [[ -z "${dev}" || ! -b "${dev}" ]]; then
    >&2 echo "[$(ts)] ERROR: PARTLABEL=${label} exists, but does not resolve to a block device: ${dev:-<empty>}"
    return 1
  fi
  return 0
}

dev_existing_mountpoint() {
  local dev="${1:?dev required}"
  local -a mounts=()
  local mounts_display=""

  mapfile -t mounts < <(findmnt -nr -S "${dev}" -o TARGET 2>/dev/null || true)
  case ${#mounts[@]} in
    0)
      return 0
      ;;
    1)
      printf '%s
' "${mounts[0]}"
      return 0
      ;;
    *)
      mounts_display="$(printf '%s
' "${mounts[@]}" | paste -sd ', ' -)"
      die "Device ${dev} is mounted at multiple targets (${mounts_display}). Refusing ambiguous reuse." 15
      ;;
  esac
}

is_restic_repo() {
  local path="${1:?path required}"
  [[ -f "${path}/config" ]] || return 1
  [[ -d "${path}/data" ]] || return 1
  [[ -d "${path}/index" ]] || return 1
  [[ -d "${path}/snapshots" ]] || return 1
  [[ -d "${path}/keys" ]] || return 1
  return 0
}

fstype_of_dev() {
  local dev="${1:?dev required}"
  local t
  t="$(lsblk -nro FSTYPE "${dev}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${t}" ]]; then
    echo "${t}"
    return 0
  fi
  t="$(blkid -o value -s TYPE "${dev}" 2>/dev/null | head -n 1 || true)"
  echo "${t}"
}

mount_repo_if_needed() {
  local dev="${1:?dev required}"
  local mnt="${2:?mountpoint required}"
  local rw_flag="${3:-0}"

  mkdir -p "${mnt}"
  if mountpoint -q "${mnt}"; then
    return 0
  fi

  local opts="noatime"
  if [[ "${rw_flag}" == "0" ]]; then
    opts="${opts},ro"
  else
    # If exfat and RW, apply restrictive ownership/mode to avoid surprising permissions.
    local fstype
    fstype="$(fstype_of_dev "${dev}")"
    if [[ "${fstype}" == "exfat" ]]; then
      opts="${opts},uid=0,gid=0,umask=${EXFAT_UMASK_DEFAULT}"
    fi
  fi

  if mount -o "${opts}" "${dev}" "${mnt}"; then
    MOUNTED_BY_US+=("${mnt}")
    return 0
  fi

  # exFAT fallbacks if auto-detection fails.
  if mount -t exfat -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
    MOUNTED_BY_US+=("${mnt}")
    return 0
  fi
  if mount -t exfat-fuse -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
    MOUNTED_BY_US+=("${mnt}")
    return 0
  fi

  return 1
}

mount_repo_if_needed_temp() {
  local dev="${1:?dev required}"
  local mnt="${2:?mountpoint required}"
  local rw_flag="${3:-0}"

  mkdir -p "${mnt}"
  if mountpoint -q "${mnt}"; then
    return 0
  fi

  local opts="noatime"
  if [[ "${rw_flag}" == "0" ]]; then
    opts="${opts},ro"
  else
    local fstype
    fstype="$(fstype_of_dev "${dev}")"
    if [[ "${fstype}" == "exfat" ]]; then
      opts="${opts},uid=0,gid=0,umask=${EXFAT_UMASK_DEFAULT}"
    fi
  fi

  if mount -o "${opts}" "${dev}" "${mnt}"; then
    USB_TEMP_MOUNTS+=("${mnt}")
    return 0
  fi
  if mount -t exfat -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
    USB_TEMP_MOUNTS+=("${mnt}")
    return 0
  fi
  if mount -t exfat-fuse -o "${opts}" "${dev}" "${mnt}" 2>/dev/null; then
    USB_TEMP_MOUNTS+=("${mnt}")
    return 0
  fi
  return 1
}

mountpoint_is_read_only() {
  local mnt="${1:?mountpoint required}"
  local opts=""
  opts="$(findmnt -n -o OPTIONS --target "${mnt}" 2>/dev/null | head -n 1 || true)"
  [[ ",${opts}," == *,ro,* ]]
}

ensure_mountpoint_read_only() {
  local mnt="${1:?mountpoint required}"
  if ! mountpoint -q "${mnt}"; then
    die "Mountpoint is not mounted: ${mnt}" 15
  fi
  if mountpoint_is_read_only "${mnt}"; then
    return 0
  fi
  if ! mount -o remount,ro "${mnt}" >/dev/null 2>&1; then
    die "Failed to remount ${mnt} read-only." 15
  fi
  if ! mountpoint_is_read_only "${mnt}"; then
    die "Mountpoint ${mnt} is not read-only after remount attempt." 15
  fi
}

detect_internal_repo_root() {
  # Mount internal _BACKUP partition at /_backup (read-only default).
  ensure_unique_device "${BACKUP_PARTLABEL}" || die "Internal repo partition not found." 12
  local dev
  dev="$(dev_by_partlabel "${BACKUP_PARTLABEL}")"

  mkdir -p "${MNT_INTERNAL_REPO}"
  if mountpoint -q "${MNT_INTERNAL_REPO}"; then
    ensure_mountpoint_read_only "${MNT_INTERNAL_REPO}"
    log "Internal repo mountpoint already mounted at ${MNT_INTERNAL_REPO}."
  else
    if ! mount_repo_if_needed "${dev}" "${MNT_INTERNAL_REPO}" 0; then
      die "Failed to mount internal repo partition (${dev}) at ${MNT_INTERNAL_REPO}" 15
    fi
    log "Mounted internal repo (${dev}) at ${MNT_INTERNAL_REPO} (ro)."
  fi
  echo "${MNT_INTERNAL_REPO}"
}

resolve_repo_path() {
  local repo_root="${1:?repo_root required}"
  local host_scope="${2:?host_scope required}"
  local target="${3:?target required}"
  echo "${repo_root}/${host_scope}/${target}"
}

scan_scopes_for_targets() {
  local repo_root="${1:?repo_root required}"
  shift
  local targets=("$@")
  local scope
  local found=()

  if [[ ! -d "${repo_root}" ]]; then
    return 0
  fi

  while IFS= read -r -d '' scope; do
    local ok="1"
    local t
    for t in "${targets[@]}"; do
      if ! is_restic_repo "${scope}/${t}"; then
        ok="0"
        break
      fi
    done
    if [[ "${ok}" == "1" ]]; then
      found+=("$(basename "${scope}")")
    fi
  done < <(find "${repo_root}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  printf '%s\n' "${found[@]:-}"
}

choose_one_from_list() {
  local prompt="${1:?prompt required}"
  shift
  local items=("$@")
  local idx

  if [[ "${#items[@]}" -eq 0 ]]; then
    return 1
  fi
  if [[ "${#items[@]}" -eq 1 ]]; then
    echo "${items[0]}"
    return 0
  fi

  if [[ "${RUN_NON_INTERACTIVE}" == "1" ]]; then
    return 2
  fi
  if [[ ! -t 0 ]]; then
    return 2
  fi

  >&2 echo "${prompt}"
  for idx in "${!items[@]}"; do
    >&2 echo "  $((idx+1))) ${items[idx]}"
  done
  >&2 echo -n "Select (1-${#items[@]}): "
  read -r idx
  if [[ ! "${idx}" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#items[@]} )); then
    return 1
  fi
  echo "${items[idx-1]}"
}

detect_scope() {
  local repo_root="${1:?repo_root required}"
  local scopes=()
  local scope

  mapfile -t scopes < <(scan_scopes_for_targets "${repo_root}" "${RUN_TARGETS[@]}" || true)
  if [[ -n "${RUN_HOST_SCOPE}" ]]; then
    for scope in "${scopes[@]}"; do
      if [[ "${scope}" == "${RUN_HOST_SCOPE}" ]]; then
        log "Using provided host-scope: ${RUN_HOST_SCOPE}"
        echo "${RUN_HOST_SCOPE}"
        return 0
      fi
    done
    die "--host-scope=${RUN_HOST_SCOPE} not found in repo root ${repo_root} for targets (${RUN_TARGETS[*]})." 13
  fi

  if [[ "${#scopes[@]}" -eq 0 ]]; then
    die "No host-scope candidates found under ${repo_root} for targets (${RUN_TARGETS[*]})." 13
  fi

  if [[ "${#scopes[@]}" -eq 1 ]]; then
    log "Auto-selected host-scope: ${scopes[0]} (only candidate)"
    echo "${scopes[0]}"
    return 0
  fi

  scope="$(choose_one_from_list "Multiple host-scopes found. Choose one:" "${scopes[@]}")" || {
    if [[ "$?" -eq 2 ]]; then
      die "Multiple host-scopes found; please provide --host-scope (or run with TTY)." 13
    fi
    die "Invalid selection." 13
  }
  log "Selected host-scope: ${scope}"
  echo "${scope}"
}

sys_path_for_block() {
  local base="${1:?basename required}"
  readlink -f "/sys/class/block/${base}" 2>/dev/null || true
}

udev_id_bus() {
  local dev="${1:?dev required}"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm info --query=property --name "${dev}" 2>/dev/null | awk -F= '/^ID_BUS=/{print $2; exit}' || true
  fi
}

is_usb_partition_best_effort() {
  local part_dev="${1:?partition dev required}"
  local parent_name="${2:-}"
  local parent_tran="${3:-}"

  # Fast-path: lsblk already said it's USB.
  if [[ "${parent_tran}" == "usb" ]]; then
    return 0
  fi

  # Best-effort sysfs heuristic (covers some enclosures where lsblk TRAN is blank).
  local base
  base="$(basename "${part_dev}")"
  local p
  p="$(sys_path_for_block "${base}")"
  if [[ -n "${p}" && "${p}" == *"/usb"* ]]; then
    return 0
  fi

  if [[ -n "${parent_name}" ]]; then
    p="$(sys_path_for_block "${parent_name}")"
    if [[ -n "${p}" && "${p}" == *"/usb"* ]]; then
      return 0
    fi
  fi

  # udev property fallback.
  local bus
  bus="$(udev_id_bus "${part_dev}")"
  if [[ "${bus}" == "usb" ]]; then
    return 0
  fi
  if [[ -n "${parent_name}" ]]; then
    bus="$(udev_id_bus "/dev/${parent_name}")"
    if [[ "${bus}" == "usb" ]]; then
      return 0
    fi
  fi
  return 1
}

# External USB candidate listing.
# Outputs lines: <devpath> <fstype> <uuid> <parent_disk>
list_usb_part_candidates() {
  declare -A disk_tran=()
  local dline

  while IFS= read -r dline; do
    local name type tran
    name="$(awk '{print $1}' <<< "${dline}")"
    type="$(awk '{print $2}' <<< "${dline}")"
    tran="$(awk '{print $3}' <<< "${dline}")"
    [[ "${type}" == "disk" ]] || continue
    disk_tran["$(basename "${name}")"]="${tran}"
  done < <(lsblk -nrpo NAME,TYPE,TRAN 2>/dev/null || true)

  local line
  while IFS= read -r line; do
    # NAME TYPE PKNAME TRAN FSTYPE UUID
    local name type pkname tran fstype uuid parent_tran
    name="$(awk '{print $1}' <<< "${line}")"
    type="$(awk '{print $2}' <<< "${line}")"
    pkname="$(awk '{print $3}' <<< "${line}")"
    tran="$(awk '{print $4}' <<< "${line}")"
    fstype="$(awk '{print $5}' <<< "${line}")"
    uuid="$(awk '{print $6}' <<< "${line}")"

    [[ "${type}" == "part" ]] || continue
    [[ -n "${uuid}" ]] || continue
    case "${fstype}" in
      ext4|exfat)
        ;;
      *)
        continue
        ;;
    esac

    parent_tran="${tran}"
    if [[ -z "${parent_tran}" && -n "${pkname}" ]]; then
      parent_tran="${disk_tran["${pkname}"]:-}"
    fi
    if ! is_usb_partition_best_effort "${name}" "${pkname}" "${parent_tran}"; then
      continue
    fi

    echo "${name} ${fstype} ${uuid} ${pkname}"
  done < <(lsblk -nrpo NAME,TYPE,PKNAME,TRAN,FSTYPE,UUID 2>/dev/null || true)
}

detect_external_repo_root() {
  local wanted_uuid="${RUN_UUID}"  # filesystem UUID
  local candidates=()
  local diag_seen=()
  local diag_reject=()
  local line

  mkdir -p "${MNT_USB_BASE}"

  if [[ -n "${wanted_uuid}" ]]; then
    local dev="/dev/disk/by-uuid/${wanted_uuid}"
    if [[ ! -e "${dev}" ]]; then
      die "USB device with UUID=${wanted_uuid} not found at ${dev}." 12
    fi
    dev="$(readlink -f "${dev}")"

    local existing
    existing="$(dev_existing_mountpoint "${dev}")"
    if [[ -n "${existing}" ]]; then
      log "USB UUID=${wanted_uuid} already mounted at ${existing}; reusing (will validate layout)."
      [[ "${RUN_USB_RW}" == "0" ]] && ensure_mountpoint_read_only "${existing}"

      local scopes=()
      mapfile -t scopes < <(scan_scopes_for_targets "${existing}" "${RUN_TARGETS[@]}" || true)
      if [[ "${#scopes[@]}" -eq 0 ]]; then
        local msg
        msg="USB UUID=${wanted_uuid} mounted at ${existing}, but no matching Penelope repo layout"
        msg="${msg} for targets (${RUN_TARGETS[*]})."
        die "${msg}" 13
      fi

      echo "${existing}"
      return 0
    fi

    local mnt="${MNT_USB_BASE}/${wanted_uuid}"
    if ! mount_repo_if_needed "${dev}" "${mnt}" "${RUN_USB_RW}"; then
      die "Failed to mount USB device ${dev} at ${mnt}." 15
    fi
    [[ "${RUN_USB_RW}" == "0" ]] && ensure_mountpoint_read_only "${mnt}"

    local scopes=()
    mapfile -t scopes < <(scan_scopes_for_targets "${mnt}" "${RUN_TARGETS[@]}" || true)
    if [[ "${#scopes[@]}" -eq 0 ]]; then
      local msg
      msg="USB UUID=${wanted_uuid} mounted at ${mnt}, but no matching Penelope repo layout"
      msg="${msg} for targets (${RUN_TARGETS[*]})."
      die "${msg}" 13
    fi

    echo "${mnt}"
    return 0
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    local dev fstype uuid parent
    dev="$(awk '{print $1}' <<< "${line}")"
    fstype="$(awk '{print $2}' <<< "${line}")"
    uuid="$(awk '{print $3}' <<< "${line}")"
    parent="$(awk '{print $4}' <<< "${line}")"

    diag_seen+=("${dev} uuid=${uuid} fstype=${fstype} parent=${parent}")

    local existing
    existing="$(dev_existing_mountpoint "${dev}")"
    if [[ -n "${existing}" ]]; then
      [[ "${RUN_USB_RW}" == "0" ]] && ensure_mountpoint_read_only "${existing}"
      local scopes=()
      mapfile -t scopes < <(scan_scopes_for_targets "${existing}" "${RUN_TARGETS[@]}" || true)
      if [[ "${#scopes[@]}" -eq 0 ]]; then
        diag_reject+=("${dev} uuid=${uuid} (mounted at ${existing}, but no matching host-scope+targets)")
        continue
      fi
      candidates+=("${uuid}:${existing}:${dev}")
      continue
    fi

    local mnt="${MNT_USB_BASE}/${uuid}"
    if ! mount_repo_if_needed_temp "${dev}" "${mnt}" "${RUN_USB_RW}"; then
      diag_reject+=("${dev} uuid=${uuid} (mount failed)")
      continue
    fi
    [[ "${RUN_USB_RW}" == "0" ]] && ensure_mountpoint_read_only "${mnt}"

    local scopes=()
    mapfile -t scopes < <(scan_scopes_for_targets "${mnt}" "${RUN_TARGETS[@]}" || true)
    if [[ "${#scopes[@]}" -eq 0 ]]; then
      diag_reject+=("${dev} uuid=${uuid} (no matching host-scope+targets)")
      continue
    fi
    candidates+=("${uuid}:${mnt}:${dev}")
  done < <(list_usb_part_candidates || true)

  log "USB scan: seen partitions: ${#diag_seen[@]}"
  local s
  for s in "${diag_seen[@]}"; do
    log "USB seen: ${s}"
  done
  local r
  for r in "${diag_reject[@]}"; do
    log "USB rejected: ${r}"
  done

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    die "No usable external repo found on USB disks (matching restic layout)." 13
  fi

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    local one="${candidates[0]}"
    local mnt="${one#*:}"; mnt="${mnt%%:*}"
    local uuid="${one%%:*}"
    log "Auto-selected USB UUID=${uuid} at ${mnt} (only candidate)"

    # Promote temp mount to persistent mount tracking.
    mapfile -t USB_TEMP_MOUNTS < <(array_remove_value_inplace "${mnt}" "${USB_TEMP_MOUNTS[@]:-}")
    MOUNTED_BY_US+=("${mnt}")

    echo "${mnt}"
    return 0
  fi

  local options=()
  local c
  for c in "${candidates[@]}"; do
    local uuid="${c%%:*}"
    local rest="${c#*:}"
    local mnt="${rest%%:*}"
    local dev="${rest#*:}"
    options+=("UUID=${uuid} dev=${dev} mnt=${mnt}")
  done

  local sel
  sel="$(choose_one_from_list "Multiple USB candidates found. Choose one:" "${options[@]}")" || {
    if [[ "$?" -eq 2 ]]; then
      die "Multiple USB candidates found; please rerun with --uuid (or run with TTY)." 13
    fi
    die "Invalid selection." 13
  }

  local sel_uuid sel_mnt
  sel_uuid="$(awk '{print $1}' <<< "${sel}")"; sel_uuid="${sel_uuid#UUID=}"
  sel_mnt="$(awk '{print $3}' <<< "${sel}")"; sel_mnt="${sel_mnt#mnt=}"
  log "Selected USB UUID=${sel_uuid} at ${sel_mnt}"

  mapfile -t USB_TEMP_MOUNTS < <(array_remove_value_inplace "${sel_mnt}" "${USB_TEMP_MOUNTS[@]:-}")
  MOUNTED_BY_US+=("${sel_mnt}")

  echo "${sel_mnt}"
}

prompt_masterpw_if_needed() {
  if [[ "${RUN_LIST}" == "1" ]]; then
    return 0
  fi

  local needs="0"
  local t
  for t in "${RUN_TARGETS[@]}"; do
    if [[ "${t}" == "system" || "${t}" == "home" || "${t}" == "_archive" ]]; then
      needs="1"
      break
    fi
  done
  if [[ "${needs}" == "0" ]]; then
    return 0
  fi
  if [[ "${RUN_NON_INTERACTIVE}" == "1" ]]; then
    die "MASTERPW prompt requires interactive input; remove --non-interactive." 2
  fi
  if [[ ! -t 0 ]]; then
    die "MASTERPW prompt requires a TTY." 2
  fi
  >&2 echo -n "Enter MASTERPW (LUKS passphrase) for targets (${RUN_TARGETS[*]}): "
  read -r -s MASTERPW
  >&2 echo
  if [[ -z "${MASTERPW}" ]]; then
    die "MASTERPW must not be empty." 2
  fi
  if [[ "${RUN_RECREATE_LUKS}" == "1" ]]; then
    >&2 echo -n "Re-enter MASTERPW to confirm: "
    local confirm=""
    read -r -s confirm
    >&2 echo
    if [[ "${confirm}" != "${MASTERPW}" ]]; then
      die "MASTERPW confirmation mismatch." 2
    fi
    >&2 echo "Type YES to continue (this may destroy LUKS headers for selected targets):"
    local yes=""
    read -r yes
    if [[ "${yes}" != "YES" ]]; then
      die "Confirmation failed (expected YES)." 2
    fi
  fi
}

prompt_restic_pw() {
  local prompt="${1:?prompt required}"
  local pw=""
  if [[ "${RUN_NON_INTERACTIVE}" == "1" ]]; then
    die "Restic password prompt requires interactive input; remove --non-interactive." 2
  fi
  if [[ ! -t 0 ]]; then
    die "Restic password prompt requires a TTY." 2
  fi
  >&2 echo -n "Enter restic passphrase for ${prompt}: "
  read -r -s pw
  >&2 echo
  if [[ -z "${pw}" ]]; then
    die "Restic passphrase must not be empty." 2
  fi
  echo "${pw}"
}

require_ack_for_destructive() {
  if [[ "${RUN_ACK_WIPE}" != "1" ]]; then
    die "This operation wipes data (mkfs). Please provide --yes-i-know-this-wipes-data." 2
  fi
}

crypt_open() {
  local dev="${1:?dev required}"
  local name="${2:?name required}"
  if [[ -e "/dev/mapper/${name}" ]]; then
    die "Mapper already exists: /dev/mapper/${name}" 15
  fi
  printf '%s' "${MASTERPW}" | cryptsetup open --type luks "${dev}" "${name}" --key-file -
  MAPPERS_OPENED+=("${name}")
}

crypt_luksformat() {
  local dev="${1:?dev required}"
  printf '%s' "${MASTERPW}" | cryptsetup luksFormat --type luks2 --batch-mode "${dev}" --key-file -
}

mkfs_ext4() {
  local dev="${1:?dev required}"
  local label="${2:-}"
  if [[ -n "${label}" ]]; then
    mkfs.ext4 -F -L "${label}" "${dev}" >/dev/null
  else
    mkfs.ext4 -F "${dev}" >/dev/null
  fi
}

mkfs_vfat() {
  local dev="${1:?dev required}"
  local label="${2:-}"
  if [[ -n "${label}" ]]; then
    mkfs.vfat -F 32 -n "${label}" "${dev}" >/dev/null
  else
    mkfs.vfat -F 32 "${dev}" >/dev/null
  fi
}

mount_target() {
  local dev="${1:?dev required}"
  local mnt="${2:?mnt required}"
  mkdir -p "${mnt}"
  if mountpoint -q "${mnt}"; then
    die "Mountpoint already mounted: ${mnt}" 15
  fi
  mount "${dev}" "${mnt}"
  MOUNTED_BY_US+=("${mnt}")
}

device_sysfs_holders() {
  local dev="${1:?dev required}"
  local resolved base holder_dir holder
  resolved="$(readlink -f "${dev}" 2>/dev/null || printf '%s' "${dev}")"
  base="$(basename "${resolved}")"
  holder_dir="/sys/class/block/${base}/holders"
  [[ -d "${holder_dir}" ]] || return 0
  for holder in "${holder_dir}"/*; do
    [[ -e "${holder}" ]] || continue
    basename "${holder}"
  done
}

holder_display_path() {
  local holder="${1:?holder required}"
  local dm_name_file="/sys/class/block/${holder}/dm/name"
  if [[ -r "${dm_name_file}" ]]; then
    local dm_name=""
    dm_name="$(cat "${dm_name_file}" 2>/dev/null || true)"
    if [[ -n "${dm_name}" ]]; then
      printf '/dev/mapper/%s' "${dm_name}"
      return 0
    fi
  fi
  printf '/dev/%s' "${holder}"
}

emit_device_busy_diagnostics() {
  local dev="${1:?dev required}"
  local had_issue="0"

  if findmnt -n -S "${dev}" >/dev/null 2>&1; then
    had_issue="1"
    >&2 echo "[$(ts)] ERROR: Device ${dev} is currently mounted:"
    findmnt -n -S "${dev}" >&2 || true
  fi

  local holder holder_path
  while IFS= read -r holder; do
    [[ -n "${holder}" ]] || continue
    had_issue="1"
    holder_path="$(holder_display_path "${holder}")"
    >&2 echo "[$(ts)] ERROR: Device ${dev} currently has an active holder/mapper: ${holder_path}"
    findmnt -n -S "/dev/${holder}" >&2 2>/dev/null || true
    if [[ "${holder_path}" != "/dev/${holder}" ]]; then
      findmnt -n -S "${holder_path}" >&2 2>/dev/null || true
    fi
  done < <(device_sysfs_holders "${dev}" || true)

  [[ "${had_issue}" == "1" ]]
}

ensure_not_mounted_anywhere() {
  local dev="${1:?dev required}"
  if emit_device_busy_diagnostics "${dev}"; then
    return 1
  fi
  return 0
}


blkid_value() {
  local dev="${1:?device required}"
  local key="${2:?blkid key required}"
  blkid -o value -s "${key}" "${dev}" 2>/dev/null | head -n 1 || true
}

mounted_source_for() {
  local mnt="${1:?mountpoint required}"
  findmnt -n -o SOURCE --target "${mnt}" 2>/dev/null | head -n 1 || true
}

python_replace_or_append_by_field() {
  local file="${1:?file required}"
  local field_index="${2:?field index required}"
  local field_value="${3:?field value required}"
  local replacement="${4:?replacement required}"

  python3 - "${file}" "${field_index}" "${field_value}" "${replacement}" <<'PY_REPLACE_OR_APPEND_BY_FIELD'
from pathlib import Path
import sys

path = Path(sys.argv[1])
field_index = int(sys.argv[2])
field_value = sys.argv[3]
replacement = sys.argv[4]

lines = path.read_text().splitlines()
out = []
replaced = False
for line in lines:
    stripped = line.lstrip()
    if stripped and not stripped.startswith('#'):
        fields = stripped.split()
        if len(fields) > field_index and fields[field_index] == field_value:
            out.append(replacement)
            replaced = True
            continue
    out.append(line)
if not replaced:
    out.append(replacement)
path.write_text("\n".join(out) + "\n")
PY_REPLACE_OR_APPEND_BY_FIELD
}

restore_mount_line() {
  local file="${1:?file required}"
  local spec="${2:?spec required}"
  local mountpoint="${3:?mountpoint required}"
  local fstype="${4:?fstype required}"
  local opts="${5:?opts required}"
  local dump="${6:?dump required}"
  local passno="${7:?passno required}"

  python_replace_or_append_by_field "${file}" 1 "${mountpoint}" "${spec} ${mountpoint} ${fstype} ${opts} ${dump} ${passno}"
}

restore_crypttab_line() {
  local file="${1:?file required}"
  local mapper_name="${2:?mapper name required}"
  local luks_uuid="${3:?luks uuid required}"

  python_replace_or_append_by_field "${file}" 0 "${mapper_name}" "${mapper_name} UUID=${luks_uuid} none luks,discard,keyscript=/lib/cryptsetup/scripts/decrypt_keyctl"
}

run_targets_contains() {
  local needle="${1:?target required}"
  local value
  for value in "${RUN_TARGETS[@]}"; do
    if [[ "${value}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

current_encrypted_target_fs_uuid() {
  local luks_partlabel="${1:?luks partlabel required}"
  local mounted_mountpoint="${2:-}"
  local probe_mapper_name="${3:?probe mapper name required}"

  local source=""
  if [[ -n "${mounted_mountpoint}" ]] && mountpoint -q "${mounted_mountpoint}"; then
    source="$(mounted_source_for "${mounted_mountpoint}")"
    [[ -n "${source}" ]] || die "Could not determine mounted source for ${mounted_mountpoint}" 15
  else
    ensure_unique_device "${luks_partlabel}" || die "Missing target partition PARTLABEL=${luks_partlabel}" 12
    local dev
    dev="$(dev_by_partlabel "${luks_partlabel}")"
    crypt_open "${dev}" "${probe_mapper_name}"
    source="/dev/mapper/${probe_mapper_name}"
  fi

  local fs_uuid
  fs_uuid="$(blkid_value "${source}" UUID)"
  [[ -n "${fs_uuid}" ]] || die "Could not determine filesystem UUID from ${source}" 15
  echo "${fs_uuid}"
}

rewrite_restored_system_mount_config() {
  local sysroot="${1:?sysroot required}"
  local fstab_path="${sysroot}/etc/fstab"
  local crypttab_path="${sysroot}/etc/crypttab"

  [[ -f "${fstab_path}" ]] || die "Restored system is missing ${fstab_path}" 14
  [[ -f "${crypttab_path}" ]] || die "Restored system is missing ${crypttab_path}" 14

  local root_source boot_source efi_source
  root_source="$(mounted_source_for "${MNT_SYSROOT}")"
  boot_source="$(mounted_source_for "${MNT_SYSROOT}/boot")"
  efi_source="$(mounted_source_for "${MNT_SYSROOT}/boot/efi")"

  [[ -n "${root_source}" ]] || die "Could not determine mounted source for ${MNT_SYSROOT}" 15
  [[ -n "${boot_source}" ]] || die "Could not determine mounted source for ${MNT_SYSROOT}/boot" 15
  [[ -n "${efi_source}" ]] || die "Could not determine mounted source for ${MNT_SYSROOT}/boot/efi" 15

  local root_uuid boot_uuid efi_uuid
  root_uuid="$(blkid_value "${root_source}" UUID)"
  boot_uuid="$(blkid_value "${boot_source}" UUID)"
  efi_uuid="$(blkid_value "${efi_source}" UUID)"

  [[ -n "${root_uuid}" ]] || die "Could not determine root filesystem UUID from ${root_source}" 15
  [[ -n "${boot_uuid}" ]] || die "Could not determine boot filesystem UUID from ${boot_source}" 15
  [[ -n "${efi_uuid}" ]] || die "Could not determine EFI filesystem UUID from ${efi_source}" 15

  restore_mount_line "${fstab_path}" "UUID=${root_uuid}" "/" ext4 "defaults,noatime" 0 1
  restore_mount_line "${fstab_path}" "UUID=${boot_uuid}" "/boot" ext4 "defaults" 0 2
  restore_mount_line "${fstab_path}" "UUID=${efi_uuid}" "/boot/efi" vfat "umask=0077" 0 1

  local root_luks_uuid
  root_luks_uuid="$(blkid_value "$(dev_by_partlabel "${ROOT_PARTLABEL}")" UUID)"
  [[ -n "${root_luks_uuid}" ]] || die "Could not determine LUKS UUID for ${ROOT_PARTLABEL}" 15
  restore_crypttab_line "${crypttab_path}" "penelope_root_crypt" "${root_luks_uuid}"

  local backup_dev backup_uuid
  ensure_unique_device "${BACKUP_PARTLABEL}" || die "Missing BACKUP partition" 12
  backup_dev="$(dev_by_partlabel "${BACKUP_PARTLABEL}")"
  backup_uuid="$(blkid_value "${backup_dev}" UUID)"
  [[ -n "${backup_uuid}" ]] || die "Could not determine filesystem UUID for ${BACKUP_PARTLABEL}" 15
  restore_mount_line "${fstab_path}" "UUID=${backup_uuid}" "/_backup" ext4 "defaults,noatime" 0 2

  local home_uuid home_luks_uuid
  home_uuid="$(current_encrypted_target_fs_uuid "${HOME_PARTLABEL}" "${MNT_HOME}" "penelope-recover-home-probe-$$")"
  home_luks_uuid="$(blkid_value "$(dev_by_partlabel "${HOME_PARTLABEL}")" UUID)"
  [[ -n "${home_luks_uuid}" ]] || die "Could not determine LUKS UUID for ${HOME_PARTLABEL}" 15
  restore_mount_line "${fstab_path}" "UUID=${home_uuid}" "/home" ext4 "defaults,noatime" 0 2
  restore_crypttab_line "${crypttab_path}" "penelope_home_crypt" "${home_luks_uuid}"

  local archive_uuid archive_luks_uuid
  archive_uuid="$(current_encrypted_target_fs_uuid "${ARCHIVE_PARTLABEL}" "${MNT_ARCHIVE}" "penelope-recover-archive-probe-$$")"
  archive_luks_uuid="$(blkid_value "$(dev_by_partlabel "${ARCHIVE_PARTLABEL}")" UUID)"
  [[ -n "${archive_luks_uuid}" ]] || die "Could not determine LUKS UUID for ${ARCHIVE_PARTLABEL}" 15
  restore_mount_line "${fstab_path}" "UUID=${archive_uuid}" "/_archive" ext4 "defaults,noatime" 0 2
  restore_crypttab_line "${crypttab_path}" "penelope_archive_crypt" "${archive_luks_uuid}"

  log "SYSTEM: refreshed /etc/fstab and /etc/crypttab to current on-disk UUIDs for /, /boot, /boot/efi, /home, /_archive, and /_backup"
}

restic_json_first_short_id() {
  python3 -c 'import json, sys;
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(data[0]["short_id"] if data else "")'
}

restic_json_latest_summary() {
  python3 -c 'import json, sys;
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not data:
    print("")
    sys.exit(0)
entry = data[0]
print((str(entry.get("short_id", "")) + " " + str(entry.get("time", ""))).rstrip())'
}

restic_select_snapshot_id() {
  local repo_path="${1:?repo path required}"
  local restic_pw="${2:?restic pw required}"
  local mode="${3:?mode required}"

  local query_desc=""
  local id
  if [[ "${mode}" == "latest" ]]; then
    query_desc="latest snapshot"
    id="$(
      RESTIC_PASSWORD="${restic_pw}" restic -r "${repo_path}" snapshots --latest 1 --json |
        restic_json_first_short_id 2>/dev/null || true
    )"
  else
    query_desc="snapshot=${mode}"
    id="$(
      RESTIC_PASSWORD="${restic_pw}" restic -r "${repo_path}" snapshots "${mode}" --json |
        restic_json_first_short_id 2>/dev/null || true
    )"
  fi

  if [[ -z "${id}" ]]; then
    die "Failed to validate ${query_desc} for repo ${repo_path}" 13
  fi
  echo "${id}"
}

preflight_target_devices() {
  local target="${1:?target required}"
  case "${target}" in
    system)
      ensure_unique_device "${ROOT_PARTLABEL}" || die "Missing ROOT partition" 12
      ensure_unique_device "${BOOT_PARTLABEL}" || die "Missing BOOT partition" 12
      ensure_unique_device "${EFI_PARTLABEL}" || die "Missing EFI partition" 12

      local root_dev boot_dev efi_dev
      root_dev="$(dev_by_partlabel "${ROOT_PARTLABEL}")"
      boot_dev="$(dev_by_partlabel "${BOOT_PARTLABEL}")"
      efi_dev="$(dev_by_partlabel "${EFI_PARTLABEL}")"

      ensure_not_mounted_anywhere "${root_dev}" || die "ROOT device is mounted; refusing." 15
      ensure_not_mounted_anywhere "${boot_dev}" || die "BOOT device is mounted; refusing." 15
      ensure_not_mounted_anywhere "${efi_dev}" || die "EFI device is mounted; refusing." 15
      ;;
    home)
      ensure_unique_device "${HOME_PARTLABEL}" || die "Missing target partition PARTLABEL=${HOME_PARTLABEL}" 12
      local home_dev
      home_dev="$(dev_by_partlabel "${HOME_PARTLABEL}")"
      ensure_not_mounted_anywhere "${home_dev}" || die "Device ${home_dev} is mounted; refusing to proceed." 15
      ;;
    _archive)
      ensure_unique_device "${ARCHIVE_PARTLABEL}" || die "Missing target partition PARTLABEL=${ARCHIVE_PARTLABEL}" 12
      local archive_dev
      archive_dev="$(dev_by_partlabel "${ARCHIVE_PARTLABEL}")"
      ensure_not_mounted_anywhere "${archive_dev}" || die "Device ${archive_dev} is mounted; refusing to proceed." 15
      ;;
    *)
      die "Unsupported target for preflight: ${target}" 2
      ;;
  esac
}

preflight_selected_target_restore() {
  local target="${1:?target required}"
  local repo_root="${2:?repo_root required}"
  local host_scope="${3:?host_scope required}"

  preflight_target_devices "${target}"

  local repo_path
  repo_path="$(resolve_repo_path "${repo_root}" "${host_scope}" "${target}")"
  if ! is_restic_repo "${repo_path}"; then
    die "Repo path is not a valid restic repo: ${repo_path}" 13
  fi

  local restic_pw
  restic_pw="$(prompt_restic_pw "${repo_path}")"
  local snap
  snap="$(restic_select_snapshot_id "${repo_path}" "${restic_pw}" "${RUN_SNAPSHOT_MODE}")"

  PREFLIGHT_REPO_PATHS["${target}"]="${repo_path}"
  PREFLIGHT_RESTIC_PWS["${target}"]="${restic_pw}"
  PREFLIGHT_SNAPSHOT_IDS["${target}"]="${snap}"

  log "PREFLIGHT: target=${target} repo=${repo_path} snapshot=${snap} OK"
}

preflight_all_selected_targets() {
  local repo_root="${1:?repo_root required}"
  local host_scope="${2:?host_scope required}"

  log "PREFLIGHT: validating repo layout, restic passwords, snapshots, and target availability before destructive steps"

  local t
  for t in "${RUN_TARGETS[@]}"; do
    preflight_selected_target_restore "${t}" "${repo_root}" "${host_scope}"
  done

  log "PREFLIGHT: all selected targets validated; destructive restore may proceed"
}

restic_restore_to() {
  local repo_path="${1:?repo path required}"
  local restic_pw="${2:?restic pw required}"
  local snapshot_id="${3:?snapshot id required}"
  local target_mnt="${4:?target mount required}"

  RESTIC_PASSWORD="${restic_pw}" restic -r "${repo_path}" restore "${snapshot_id}" --target "${target_mnt}"
}

system_mount_guards() {
  local ok="1"
  if ! findmnt -n "${MNT_SYSROOT}" >/dev/null 2>&1; then ok="0"; fi
  if ! findmnt -n "${MNT_SYSROOT}/boot" >/dev/null 2>&1; then ok="0"; fi
  if ! findmnt -n "${MNT_SYSROOT}/boot/efi" >/dev/null 2>&1; then ok="0"; fi
  if [[ "${ok}" != "1" ]]; then
    >&2 echo "[$(ts)] ERROR: system restore requires /boot and /boot/efi mounted into the sysroot"
    >&2 echo "[$(ts)] ERROR: Detected mounts:"
    findmnt -n "${MNT_SYSROOT}" 2>/dev/null || true
    findmnt -n "${MNT_SYSROOT}/boot" 2>/dev/null || true
    findmnt -n "${MNT_SYSROOT}/boot/efi" 2>/dev/null || true
    return 1
  fi
  return 0
}

efi_loader_missing() {
  local sysroot="${1:?sysroot required}"
  local efi_dir="${sysroot}/boot/efi"
  if [[ ! -d "${efi_dir}/EFI" ]]; then
    return 0
  fi
  if find "${efi_dir}/EFI" -maxdepth 3 -type f -name '*.efi' -print -quit 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

post_restore_boot_refresh() {
  local sysroot="${1:?sysroot required}"
  log "SYSTEM: post-restore boot refresh (chroot): update-initramfs -u -k all"
  log "SYSTEM: post-restore boot refresh (chroot): update-grub"

  mkdir -p "${sysroot}/dev" "${sysroot}/dev/pts" "${sysroot}/proc" "${sysroot}/sys" "${sysroot}/run"

  if ! mountpoint -q "${sysroot}/dev"; then
    mount --bind /dev "${sysroot}/dev"
    MOUNTED_BY_US+=("${sysroot}/dev")
  fi
  if ! mountpoint -q "${sysroot}/dev/pts"; then
    mount --bind /dev/pts "${sysroot}/dev/pts" >/dev/null 2>&1 || mount -t devpts devpts "${sysroot}/dev/pts"
    MOUNTED_BY_US+=("${sysroot}/dev/pts")
  fi
  if ! mountpoint -q "${sysroot}/run"; then
    mount --bind /run "${sysroot}/run"
    MOUNTED_BY_US+=("${sysroot}/run")
  fi
  if ! mountpoint -q "${sysroot}/proc"; then
    mount -t proc proc "${sysroot}/proc"
    MOUNTED_BY_US+=("${sysroot}/proc")
  fi
  if ! mountpoint -q "${sysroot}/sys"; then
    mount -t sysfs sysfs "${sysroot}/sys"
    MOUNTED_BY_US+=("${sysroot}/sys")
  fi

  chroot "${sysroot}" /usr/bin/env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c 'set -Eeuo pipefail; update-initramfs -u -k all; update-grub'

  if efi_loader_missing "${sysroot}"; then
    local grub_present="0"
    if chroot "${sysroot}" /usr/bin/env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
      bash -c 'command -v grub-install >/dev/null 2>&1'; then
      grub_present="1"
    fi

    if [[ -d /sys/firmware/efi && "${grub_present}" == "1" ]]; then
      local cmd="grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck"
      warn "SYSTEM: EFI loader appears missing after restore; running grub-install (guard-triggered): ${cmd}"
      if ! chroot "${sysroot}" /usr/bin/env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
        bash -c "set -Eeuo pipefail; ${cmd}"; then
        >&2 echo "[$(ts)] ERROR: SYSTEM: grub-install failed; showing diagnostics"
        >&2 echo "[$(ts)] ERROR:   EFI vars:"
        find /sys/firmware/efi/efivars -maxdepth 1 -mindepth 1 -printf "%f\n" 2>/dev/null | LC_ALL=C sort | head -20 || true
        >&2 echo "[$(ts)] ERROR:   ${sysroot}/boot/efi content:"
        find "${sysroot}/boot/efi" -maxdepth 4 -printf "%p\n" 2>/dev/null | LC_ALL=C sort | head -50 || true
        die "GRUB installation failed during system restore. System may not boot." 16
      fi
      log "SYSTEM: grub-install succeeded; running update-grub"
      chroot "${sysroot}" /usr/bin/env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
        bash -c "set -Eeuo pipefail; update-grub"
    else
      warn "SYSTEM: EFI loader appears missing, but /sys/firmware/efi is unavailable"
      warn "SYSTEM: or grub-install missing; skipping grub-install."
    fi
  else
    log "SYSTEM: EFI loader present; grub-install not required (guard-based)."
  fi
}

restore_target_home_or_archive() {
  local target="${1:?target required}"
  local luks_label="${2:?luks partlabel required}"
  local mountpoint="${3:?mountpoint required}"
  local repo_root="${4:?repo_root required}"
  local host_scope="${5:?host_scope required}"

  require_ack_for_destructive

  log "START: restore target=${target}"

  ensure_unique_device "${luks_label}" || die "Missing target partition PARTLABEL=${luks_label}" 12
  local dev
  dev="$(dev_by_partlabel "${luks_label}")"

  ensure_not_mounted_anywhere "${dev}" || die "Device ${dev} is mounted; refusing to proceed." 15

  if [[ "${RUN_RECREATE_LUKS}" == "1" ]]; then
    warn "${target}: luksFormat ${dev} (destructive)"
    crypt_luksformat "${dev}"
  fi

  local mapper="penelope-recover-${target#_}-$$"
  log "${target}: cryptsetup open ${dev} -> ${mapper}"
  crypt_open "${dev}" "${mapper}"
  local mapdev="/dev/mapper/${mapper}"

  log "${target}: mkfs.ext4 ${mapdev} (label=${target})"
  mkfs_ext4 "${mapdev}" "${target}"
  maybe_udevadm_settle
  log "${target}: mount ${mapdev} -> ${mountpoint}"
  mount_target "${mapdev}" "${mountpoint}"

  local repo_path="${PREFLIGHT_REPO_PATHS[${target}]:-}"
  local restic_pw="${PREFLIGHT_RESTIC_PWS[${target}]:-}"
  local snap="${PREFLIGHT_SNAPSHOT_IDS[${target}]:-}"
  [[ -n "${repo_path}" && -n "${restic_pw}" && -n "${snap}" ]] ||     die "Missing preflight state for target=${target}. Aborting before restore." 13
  log "${target}: using preflighted repo=${repo_path} snapshot=${snap}"

  log "${target}: restic restore -> ${mountpoint}"
  if ! restic_restore_to "${repo_path}" "${restic_pw}" "${snap}" "${mountpoint}"; then
    die "Restic restore failed for ${target}" 14
  fi

  log "SUCCESS: restore target=${target}"
}

restore_target_system() {
  local repo_root="${1:?repo_root required}"
  local host_scope="${2:?host_scope required}"

  require_ack_for_destructive

  log "START: restore target=system"

  ensure_unique_device "${ROOT_PARTLABEL}" || die "Missing ROOT partition" 12
  ensure_unique_device "${BOOT_PARTLABEL}" || die "Missing BOOT partition" 12
  ensure_unique_device "${EFI_PARTLABEL}" || die "Missing EFI partition" 12

  local root_dev boot_dev efi_dev
  root_dev="$(dev_by_partlabel "${ROOT_PARTLABEL}")"
  boot_dev="$(dev_by_partlabel "${BOOT_PARTLABEL}")"
  efi_dev="$(dev_by_partlabel "${EFI_PARTLABEL}")"

  ensure_not_mounted_anywhere "${root_dev}" || die "ROOT device is mounted; refusing." 15
  ensure_not_mounted_anywhere "${boot_dev}" || die "BOOT device is mounted; refusing." 15
  ensure_not_mounted_anywhere "${efi_dev}" || die "EFI device is mounted; refusing." 15

  if [[ "${RUN_RECREATE_LUKS}" == "1" ]]; then
    warn "system: luksFormat ${root_dev} (destructive)"
    crypt_luksformat "${root_dev}"
  fi

  local mapper="penelope-recover-root-$$"
  log "system: cryptsetup open ${root_dev} -> ${mapper}"
  crypt_open "${root_dev}" "${mapper}"
  local mapdev="/dev/mapper/${mapper}"

  log "system: mkfs.ext4 ${mapdev} (label=root)"
  mkfs_ext4 "${mapdev}" root
  maybe_udevadm_settle
  log "system: mount ${mapdev} -> ${MNT_SYSROOT}"
  mount_target "${mapdev}" "${MNT_SYSROOT}"

  mkdir -p "${MNT_SYSROOT}/boot" "${MNT_SYSROOT}/boot/efi"

  log "system: mkfs.ext4 ${boot_dev} (label=boot)"
  mkfs_ext4 "${boot_dev}" boot
  maybe_udevadm_settle
  log "system: mount ${boot_dev} -> ${MNT_SYSROOT}/boot"
  mount_target "${boot_dev}" "${MNT_SYSROOT}/boot"

  log "system: mkfs.vfat ${efi_dev}"
  mkfs_vfat "${efi_dev}"
  maybe_udevadm_settle
  log "system: mount ${efi_dev} -> ${MNT_SYSROOT}/boot/efi"
  mount_target "${efi_dev}" "${MNT_SYSROOT}/boot/efi"

  system_mount_guards || die "Mount/layout guard failed for system restore." 15

  local repo_path="${PREFLIGHT_REPO_PATHS[system]:-}"
  local restic_pw="${PREFLIGHT_RESTIC_PWS[system]:-}"
  local snap="${PREFLIGHT_SNAPSHOT_IDS[system]:-}"
  [[ -n "${repo_path}" && -n "${restic_pw}" && -n "${snap}" ]] ||     die "Missing preflight state for target=system. Aborting before restore." 13
  log "system: using preflighted repo=${repo_path} snapshot=${snap}"

  log "system: restic restore -> ${MNT_SYSROOT}"
  if ! restic_restore_to "${repo_path}" "${restic_pw}" "${snap}" "${MNT_SYSROOT}"; then
    die "Restic restore failed for system" 14
  fi

  log "SUCCESS: restore target=system (mount config refresh pending until all selected targets are restored)"
}

list_mode() {
  local repo_root="${1:?repo_root required}"
  log "LIST: repo_root=${repo_root} targets=${RUN_TARGETS[*]}"

  local scopes=()
  mapfile -t scopes < <(scan_scopes_for_targets "${repo_root}" "${RUN_TARGETS[@]}" || true)

  if [[ "${#scopes[@]}" -eq 0 ]]; then
    die "LIST: no host-scope candidates found under ${repo_root} for targets (${RUN_TARGETS[*]})." 13
  fi

  log "LIST: found host-scopes: ${#scopes[@]}"
  local s
  for s in "${scopes[@]}"; do
    log "LIST: host-scope=${s}"
    local t
    for t in "${RUN_TARGETS[@]}"; do
      local repo_path=""
      repo_path="$(resolve_repo_path "${repo_root}" "${s}" "${t}")"
      if ! is_restic_repo "${repo_path}"; then
        warn "LIST: repo missing/invalid: ${repo_path}"
        continue
      fi
      log "LIST: repo ok: ${repo_path}"

      if [[ -t 0 && "${RUN_NON_INTERACTIVE}" != "1" ]]; then
        local restic_pw
        restic_pw="$(prompt_restic_pw "${repo_path} (for latest snapshot lookup)")"
        local summary
        summary="$(
          RESTIC_PASSWORD="${restic_pw}" restic -r "${repo_path}" snapshots --latest 1 --json |
            restic_json_latest_summary 2>/dev/null || true
        )"
        [[ -n "${summary}" ]] || summary="(no snapshots)"
        log "LIST: latest snapshot: ${summary}"
      else
        log "LIST: latest snapshot: (skipped; requires TTY)"
      fi
    done
  done
}

main() {
  require_bash_version
  parse_cli "$@"
  parse_targets "${RUN_TARGETS_RAW}"

  require_root "sudo ./penelope-offline-recover.sh"

  # Basic deps required even for non-destructive list mode.
  require_cmd_many findmnt lsblk find awk mount umount mountpoint restic python3 blkid

  mkdir -p "$(dirname "${RUN_LOG_PATH}")" 2>/dev/null || true
  : > "${RUN_LOG_PATH}" 2>/dev/null || true

  log "${SCRIPT_NAME} ${SCRIPT_VERSION} starting"

  offline_guard
  ensure_dirs

  local repo_root
  if [[ "${RUN_REPO}" == "internal" ]]; then
    repo_root="$(detect_internal_repo_root)"
  else
    repo_root="$(detect_external_repo_root)"
  fi

  if [[ "${RUN_LIST}" == "1" ]]; then
    log "Selected: repo=${RUN_REPO} repo_root=${repo_root} targets=${RUN_TARGETS[*]} usb_rw=${RUN_USB_RW} (list mode)"
    list_mode "${repo_root}"
    log "LIST: done"
    return 0
  fi

  require_cmd_many cryptsetup mkfs.ext4 mkfs.vfat chroot

  require_ack_for_destructive

  local host_scope
  host_scope="$(detect_scope "${repo_root}")"

  local selected_msg
  selected_msg="Selected: repo=${RUN_REPO} repo_root=${repo_root} host_scope=${host_scope} layout=scoped"
  selected_msg="${selected_msg} targets=${RUN_TARGETS[*]} snapshot=${RUN_SNAPSHOT_MODE}"
  selected_msg="${selected_msg} usb_rw=${RUN_USB_RW} recreate_luks=${RUN_RECREATE_LUKS}"
  log "${selected_msg}"

  preflight_all_selected_targets "${repo_root}" "${host_scope}"
  prompt_masterpw_if_needed

  local t
  local system_requested="0"
  for t in "${RUN_TARGETS[@]}"; do
    case "${t}" in
      system)
        system_requested="1"
        restore_target_system "${repo_root}" "${host_scope}"
        ;;
      home)
        restore_target_home_or_archive "home" "${HOME_PARTLABEL}" "${MNT_HOME}" "${repo_root}" "${host_scope}"
        ;;
      _archive)
        restore_target_home_or_archive "_archive" "${ARCHIVE_PARTLABEL}" "${MNT_ARCHIVE}" "${repo_root}" "${host_scope}"
        ;;
    esac
  done

  if [[ "${system_requested}" == "1" ]]; then
    rewrite_restored_system_mount_config "${MNT_SYSROOT}"
    post_restore_boot_refresh "${MNT_SYSROOT}"
  fi

  log "All requested targets restored successfully."
}

main "$@"
EOF_OFFLINE_RECOVER_SCRIPT
}

install_cron() {
  local cron_target="${CRON_FILE}"
  local cron_hour=""
  local cron_minute=""

  validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
  validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
  validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
  cron_hour="$(read_kv_value_from_file "${BACKUP_CONF}" "CRON_HOUR" || true)"
  cron_minute="$(read_kv_value_from_file "${BACKUP_CONF}" "CRON_MINUTE" || true)"
  [[ -n "${cron_hour}" ]] || die "Missing CRON_HOUR in ${BACKUP_CONF}"
  [[ -n "${cron_minute}" ]] || die "Missing CRON_MINUTE in ${BACKUP_CONF}"

  PLACEHOLDER_CRON_HOUR="${cron_hour}"
  PLACEHOLDER_CRON_MINUTE="${cron_minute}"
  PLACEHOLDER_BACKUP_DASHBOARD_DIR="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
  [[ -n "${PLACEHOLDER_BACKUP_DASHBOARD_DIR}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${BACKUP_CONF}"

  log "Installing cron schedule (daily, no catch-up): ${cron_hour}:${cron_minute} -> internal backup"
  install_file_from_heredoc "${cron_target}" 0644 root root "cron" <<'EOF_CRON_TEMPLATE'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
# Penelope daily internal backup (no catch-up).
# Any output is redirected by the runner into: ___PENELOPE_BACKUP_LOG___
MAILTO=""
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

___PENELOPE_DEFAULT_CRON_MINUTE___ ___PENELOPE_DEFAULT_CRON_HOUR___ * * * root /usr/local/sbin/penelope-backup.sh --mode internal
EOF_CRON_TEMPLATE

  command -v systemctl >/dev/null 2>&1 || die "Cron schedule installation requires systemctl on the installed host."
  [[ -d /run/systemd/system ]] || die "Cron schedule installation requires a live systemd runtime on the installed host."
  systemctl enable --now cron

  PLACEHOLDER_CRON_HOUR=""
  PLACEHOLDER_CRON_MINUTE=""
  PLACEHOLDER_BACKUP_DASHBOARD_DIR=""
}

install_logrotate() {
  local logrotate_target="${LOGROTATE_FILE}"

  log "Installing logrotate: ${logrotate_target}"
  install_file_from_heredoc "${logrotate_target}" 0644 root root "logrotate" <<'EOF_LOGROTATE_TEMPLATE'
# Managed by Penelope
# Last written by: penelope-backup-setup ___PENELOPE_SETUP_VERSION___
# Version: ___PENELOPE_SETUP_VERSION___
/var/log/___PENELOPE_INITIAL_HOST_SCOPE_NAME___/backup/backup.log /var/log/___PENELOPE_INITIAL_HOST_SCOPE_NAME___/backup/verify.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    su root adm
    create 0640 root adm
}
EOF_LOGROTATE_TEMPLATE
}

# -------------------- setup flow --------------------
install_common_lib() {
  penelope_refresh_installed_common_lib "${SCRIPT_DIR}/penelope-common.sh"
}

ensure_restic_pw() {
  local file="${1:?pw file required}"
  local initial_pw=""

  case "${SECRETS_MODE}" in
    keep)
      if [[ ! -f "${file}" ]] || [[ ! -s "${file}" ]]; then
        die "Missing restic password file: ${file} (--keep-secrets is set; refusing to create)."
      fi
      chmod 600 "${file}" 2>/dev/null || true
      return 0
      ;;
    init)
      if [[ -f "${file}" ]] && [[ -s "${file}" ]]; then
        chmod 600 "${file}" 2>/dev/null || true
        log "Password file exists: ${file} (unchanged)"
        return 0
      fi

      initial_pw="$(bootstrap_secret_value_for_restic_file "${file}")"
      log "Initializing restic password file from bootstrap secrets.d: ${file}"
      (
        umask 077
        printf '%s
' "${initial_pw}" > "${file}"
      ) || die "Failed to initialize restic password file: ${file}"
      chmod 600 "${file}"
      return 0
      ;;
    *)
      die "Internal error: unknown SECRETS_MODE=${SECRETS_MODE}"
      ;;
  esac
}

verify_installed_mode() {
  local path="${1:?path required}"
  local expected_mode="${2:?expected mode required}"
  local actual_mode=""

  [[ -e "${path}" ]] || die "Missing installed artifact: ${path}"
  actual_mode="$(stat -c '%a' "${path}")" || die "Failed to stat mode: ${path}"
  [[ "${actual_mode}" == "${expected_mode}" ]] || die "Unexpected mode for ${path}: ${actual_mode} (expected ${expected_mode})"
}

verify_installed_shell_script() {
  local path="${1:?path required}"

  [[ -f "${path}" ]] || die "Missing installed shell script: ${path}"
  [[ -x "${path}" ]] || die "Installed shell script is not executable: ${path}"
  ensure_no_unexpanded_tokens "${path}"
  validate_shell_script "${path}"
}

verify_installed_text_artifact() {
  local path="${1:?path required}"

  [[ -f "${path}" ]] || die "Missing installed text artifact: ${path}"
  [[ -s "${path}" ]] || die "Installed text artifact is empty: ${path}"
  ensure_no_unexpanded_tokens "${path}"
}

verify_path_absent() {
  local path="${1:?path required}"
  local label="${2:-artifact}"

  [[ ! -e "${path}" ]] || die "${label} must be absent: ${path}"
}

ensure_preserved_file() {
  local path="${1:?path required}"
  local mode="${2:?mode required}"
  local owner="${3:?owner required}"
  local group="${4:?group required}"
  local label="${5:-file}"

  if [[ ! -e "${path}" ]]; then
    install -m "${mode}" -o "${owner}" -g "${group}" /dev/null "${path}" \
      || die "Failed to create ${label}: ${path}"
    return 0
  fi

  [[ -f "${path}" ]] || die "Expected regular ${label}: ${path}"
  chown "${owner}:${group}" "${path}" || die "Failed to chown ${label}: ${path}"
  chmod "${mode}" "${path}" || die "Failed to chmod ${label}: ${path}"
}

verify_backup_dashboard_event_log() {
  local path="${1:?path required}"
  local expected_mode="${2:?expected mode required}"

  verify_installed_text_artifact "${path}"
  grep -qF "# Penelope backup-dashboard events (${expected_mode})" "${path}" \
    || die "Backup-dashboard event log missing mode header (${expected_mode}): ${path}"
  grep -qF '# Fields: timestamp event mode host host_scope_name run_id uuid targets kind cycle_id log_file message' "${path}" \
    || die "Backup-dashboard event log missing field header: ${path}"
  grep -qF "mode=${expected_mode}" "${path}" \
    || die "Backup-dashboard event log missing mode reference (${expected_mode}): ${path}"
  grep -qF "host_scope_name=${HOST_SCOPE_NAME}" "${path}" \
    || die "Backup-dashboard event log missing scope reference (${expected_mode}): ${path}"
  grep -qF "log_file=${BACKUP_LOG}" "${path}" \
    || die "Backup-dashboard event log missing log_file reference: ${path}"
}

verify_backup_dashboard_status_json() {
  local path="${1:?path required}"
  local expected_mode="${2:?expected mode required}"

  verify_installed_text_artifact "${path}"
  require_cmd python3
  python3 - \
    "${path}" \
    "${expected_mode}" \
    "${TARGET_HOST}" \
    "${HOST_SCOPE_NAME}" \
    "${BACKUP_LOG}" <<'PY_VERIFY_DASHBOARD_JSON' \
    || die "Invalid backup-dashboard status JSON: ${path}"
import json, sys
path, expected_mode, expected_host, expected_scope, expected_log = sys.argv[1:6]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
status = data.get('status')
message = data.get('message')
assert isinstance(status, str) and status.strip()
assert isinstance(message, str) and message.strip()
assert data.get('mode') == expected_mode
assert data.get('host') == expected_host
assert data.get('host_scope_name') == expected_scope
assert data.get('log_file') == expected_log
PY_VERIFY_DASHBOARD_JSON
}

verify_backup_dashboard_status_json_glob() {
  local pattern="${1:?glob pattern required}"
  local expected_mode="${2:?expected mode required}"
  local path
  shopt -s nullglob
  for path in ${pattern}; do
    verify_backup_dashboard_status_json "${path}" "${expected_mode}"
  done
  shopt -u nullglob
}

verify_backup_dashboard_status_json_mode_glob() {
  local pattern="${1:?glob pattern required}"
  local expected_mode="${2:?mode required}"
  local path
  shopt -s nullglob
  for path in ${pattern}; do
    verify_installed_mode "${path}" "${expected_mode}"
  done
  shopt -u nullglob
}

verify_restic_repository_accessible() {
  local repo_path="${1:?repo path required}"
  local pw_file="${2:?pw file required}"
  local label="${3:-repo}"

  [[ -d "${repo_path}" ]] || die "Missing ${label} restic repository directory: ${repo_path}"
  [[ -f "${repo_path}/config" ]] || die "Missing ${label} restic repository config: ${repo_path}/config"
  [[ -s "${pw_file}" ]] || die "Missing or empty password file for ${label} restic repository: ${pw_file}"

  RESTIC_REPOSITORY="${repo_path}" \
  RESTIC_PASSWORD_FILE="${pw_file}" \
    restic snapshots --json --no-lock >/dev/null 2>&1 \
    || die "Configured ${label} restic repository is not readable: ${repo_path}"
  restic_check_repo_no_lock "${repo_path}" "${pw_file}" "${label}" "die" "Verifier restic integrity check"
}

verify_backup_recovery_dir_has_no_secret_files() {
  local dir="${1:?dir required}"
  local label="${2:?label required}"
  local forbidden=()
  local rel=""

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if [[ -e "${dir}/${rel}" ]]; then
      forbidden+=("${rel}")
    fi
  done <<'EOF_BACKUP_RECOVERY_FORBIDDEN'
system.secret
home.secret
_archive.secret
system_pw
home_pw
_archive_pw
system_pw.prev
home_pw.prev
_archive_pw.prev
EOF_BACKUP_RECOVERY_FORBIDDEN

  if (( ${#forbidden[@]} > 0 )); then
    die "${label} unexpectedly contains backup secret-bearing file(s): ${forbidden[*]}"
  fi
}

verify_recovery_stage_backup_setup_sanitized() {
  local path="${1:?path required}"
  local dir=""

  [[ -f "${path}" ]] || die "Missing recovery-stage backup setup copy: ${path}"
  [[ -x "${path}" ]] || die "Recovery-stage backup setup copy is not executable: ${path}"
  verify_installed_mode "${path}" 755
  validate_shell_script "${path}"
  grep -q '^readonly BACKUP_SETUP_CONFIG_SCHEMA_VERSION="1"$' "${path}" \
    || die "Recovery-stage backup setup copy does not expose BACKUP_SETUP_CONFIG_SCHEMA_VERSION: ${path}"
  grep -q "^readonly BACKUP_SETUP_SECRETS_DIR=\"\${BACKUP_SETUP_CONFIG_DIR}/secrets.d\"$" "${path}" \
    || die "Recovery-stage backup setup copy does not expose the external backup secrets dir contract: ${path}"
  if grep -qE '^CRED_INITIAL_RESTIC_(SYSTEM|HOME|ARCHIVE)_PASSWORD=' "${path}"; then
    die "Recovery-stage backup setup copy still embeds legacy inline restic init secrets: ${path}"
  fi
  dir="$(dirname "${path}")"
  verify_backup_recovery_dir_has_no_secret_files "${dir}" "Recovery-stage backup setup area ${dir}"
}

verify_recovery_stage_common_file() {
  local path="${1:?path required}"

  [[ -f "${path}" ]] || die "Missing recovery-stage common copy: ${path}"
  [[ -s "${path}" ]] || die "Recovery-stage common copy is empty: ${path}"
  verify_installed_mode "${path}" 644
  validate_shell_script "${path}"
  grep -q '^readonly PENELOPE_COMMON_VERSION="' "${path}"     || die "Recovery-stage common copy does not expose PENELOPE_COMMON_VERSION: ${path}"
}

require_systemd_runtime_for_verify() {
  local context="${1:?context required}"
  require_cmd systemctl
  [[ -d /run/systemd/system ]] || die "systemd runtime not available; cannot verify ${context}"
}

verify_systemd_unit_loaded() {
  local unit="${1:?unit required}"
  local load_state=""

  require_systemd_runtime_for_verify "unit load state"
  load_state="$(systemctl show --property LoadState --value "${unit}" 2>/dev/null || true)"
  [[ "${load_state}" == "loaded" ]] || die "systemd unit not loaded: ${unit} (LoadState=${load_state:-unknown})"
}

verify_systemd_service_active() {
  local unit="${1:?unit required}"
  require_systemd_runtime_for_verify "service state"
  systemctl is-active --quiet "${unit}" || die "systemd service not active: ${unit}"
}

verify_systemd_service_enabled() {
  local unit="${1:?unit required}"
  require_systemd_runtime_for_verify "enablement"
  systemctl is-enabled --quiet "${unit}" || die "systemd service not enabled: ${unit}"
}

verify_internal_backup_dashboard_signal_state() {
  local dash_dir="${1:?dashboard dir required}"
  local running_file="${dash_dir}/INTERNAL_BACKUP_RUNNING.txt"
  local ok_file="${dash_dir}/INTERNAL_BACKUP_OK.txt"
  local error_file="${dash_dir}/INTERNAL_BACKUP_ERROR_CONTACT_OPERATOR.txt"
  local stale_file="${dash_dir}/INTERNAL_BACKUP_STALE_CONTACT_OPERATOR.txt"
  local count=0

  [[ ! -f "${running_file}" ]] || die "Unexpected internal backup running marker outside an active run: ${running_file}"

  if [[ -f "${ok_file}" ]]; then
    verify_installed_mode "${ok_file}" 644
    count=$((count + 1))
  fi
  if [[ -f "${error_file}" ]]; then
    verify_installed_mode "${error_file}" 644
    count=$((count + 1))
  fi
  if [[ -f "${stale_file}" ]]; then
    verify_installed_mode "${stale_file}" 644
    count=$((count + 1))
  fi

  (( count == 1 )) || die "Expected exactly one final internal backup dashboard signal (OK, ERROR_CONTACT_OPERATOR, or STALE_CONTACT_OPERATOR) in ${dash_dir}; found ${count}."
}

verify_backup_setup_installation() {
  local dash_dir=""
  local cron_hour=""
  local cron_minute=""
  local unit_path="/etc/systemd/system/penelope-usb-backup@.service"
  local arm_unit_path="/etc/systemd/system/penelope-usb-autorun-arm.service"
  local stale_reconcile_unit_path="/etc/systemd/system/penelope-usb-autorun-reconcile.service"
  local detach_unit_path="/etc/systemd/system/penelope-usb-detach-dashboard@.service"
  local gate_path="/usr/local/sbin/penelope-usb-autorun-gate.sh"
  local rules_refresher_path="/usr/local/sbin/penelope-refresh-usb-autorun-rules.sh"
  local rules_path="/etc/udev/rules.d/99-penelope-usb-backup.rules"
  local dashboard_refresh_service="/etc/systemd/system/penelope-backup-dashboard-refresh.service"
  local dashboard_refresh_timer="/etc/systemd/system/penelope-backup-dashboard-refresh.timer"

  log "-> Verify installed backup setup artifacts"

  [[ -f /usr/local/lib/penelope/common.sh ]] || die "Missing installed shared library: /usr/local/lib/penelope/common.sh"
  validate_shell_script /usr/local/lib/penelope/common.sh
  verify_installed_text_artifact "${BACKUP_CONF}"
  validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
  validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
  validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
  verify_installed_text_artifact "${USB_CONF}"
  validate_usb_allowlist_disk_names "${USB_CONF}"
  local usb_allowlist_entries="0"
  usb_allowlist_entries="$(count_usb_allowlist_entries "${USB_CONF}")"
  grep -q '^HOST_SCOPE_NAME=' "${BACKUP_CONF}" || die "Missing HOST_SCOPE_NAME in ${BACKUP_CONF}"

  verify_installed_mode "${BACKUP_LOG}" 640
  verify_installed_mode "${RESTIC_PW_SYSTEM}" 600
  verify_installed_mode "${RESTIC_PW_HOME}" 600
  verify_installed_mode "${RESTIC_PW_ARCHIVE}" 600
  [[ -s "${RESTIC_PW_SYSTEM}" ]] || die "Empty restic password file: ${RESTIC_PW_SYSTEM}"
  [[ -s "${RESTIC_PW_HOME}" ]] || die "Empty restic password file: ${RESTIC_PW_HOME}"
  [[ -s "${RESTIC_PW_ARCHIVE}" ]] || die "Empty restic password file: ${RESTIC_PW_ARCHIVE}"

  verify_installed_shell_script "/usr/local/sbin/penelope-backup.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-backup-verify.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-backup-find-snapshot.sh"
  verify_path_absent "/usr/local/sbin/penelope-backup-smoke-test.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-usb-disk-setup.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-rotate-external-restic-passwords.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-refresh-backup-dashboard.sh"
  verify_installed_shell_script "/usr/local/sbin/penelope-offline-recover.sh"

  verify_restic_repository_accessible "${INTERNAL_REPO_SYSTEM}" "${RESTIC_PW_SYSTEM}" "system"
  verify_restic_repository_accessible "${INTERNAL_REPO_HOME}" "${RESTIC_PW_HOME}" "home"
  verify_restic_repository_accessible "${INTERNAL_REPO_ARCHIVE}" "${RESTIC_PW_ARCHIVE}" "archive"

  verify_installed_text_artifact "${CRON_FILE}"
  cron_hour="$(read_kv_value_from_file "${BACKUP_CONF}" "CRON_HOUR" || true)"
  cron_minute="$(read_kv_value_from_file "${BACKUP_CONF}" "CRON_MINUTE" || true)"
  [[ -n "${cron_hour}" ]] || die "Missing CRON_HOUR in ${BACKUP_CONF}"
  [[ -n "${cron_minute}" ]] || die "Missing CRON_MINUTE in ${BACKUP_CONF}"
  grep -qE "^${cron_minute} ${cron_hour} \* \* \* root /usr/local/sbin/penelope-backup\.sh --mode internal$" "${CRON_FILE}" \
    || die "Cron schedule does not match backup.conf: ${CRON_FILE}"
  verify_systemd_service_enabled cron
  verify_systemd_service_active cron

  verify_installed_text_artifact "${LOGROTATE_FILE}"
  local verify_log="${LOG_DIR}/verify.log"
  grep -qF "${BACKUP_LOG}" "${LOGROTATE_FILE}" || die "Logrotate does not reference ${BACKUP_LOG}: ${LOGROTATE_FILE}"
  grep -qF "${verify_log}" "${LOGROTATE_FILE}" || die "Logrotate does not reference ${verify_log}: ${LOGROTATE_FILE}"
  verify_installed_text_artifact "${dashboard_refresh_service}"
  validate_systemd_unit "${dashboard_refresh_service}"
  verify_installed_text_artifact "${dashboard_refresh_timer}"
  validate_systemd_unit "${dashboard_refresh_timer}"
  verify_systemd_unit_loaded "penelope-backup-dashboard-refresh.service"
  verify_systemd_unit_loaded "penelope-backup-dashboard-refresh.timer"
  verify_systemd_service_enabled "penelope-backup-dashboard-refresh.timer"
  verify_systemd_service_active "penelope-backup-dashboard-refresh.timer"

  /usr/local/sbin/penelope-refresh-backup-dashboard.sh

  dash_dir="$(read_kv_value_from_file "${BACKUP_CONF}" "BACKUP_DASHBOARD_DIR" || true)"
  [[ -n "${dash_dir}" ]] || die "Missing BACKUP_DASHBOARD_DIR in ${BACKUP_CONF}"
  local enable_usb_autorun="1"
  enable_usb_autorun="$(read_kv_value_from_file "${BACKUP_CONF}" "ENABLE_USB_AUTORUN" || true)"
  [[ -n "${enable_usb_autorun}" ]] || die "Missing ENABLE_USB_AUTORUN in ${BACKUP_CONF}"
  verify_backup_dashboard_event_log "${dash_dir}/events-internal.log" "internal"
  verify_backup_dashboard_event_log "${dash_dir}/events-external.log" "external"
  verify_backup_dashboard_event_log "${dash_dir}/events-ops.log" "ops"
  verify_backup_dashboard_status_json "${dash_dir}/last-internal.json" "internal"
  verify_backup_dashboard_status_json_glob "${dash_dir}/last-external-*.json" "external"
  verify_backup_dashboard_status_json "${dash_dir}/last-ops.json" "ops"
  verify_internal_backup_dashboard_signal_state "${dash_dir}"
  verify_installed_mode "${dash_dir}/events-internal.log" 644
  verify_installed_mode "${dash_dir}/events-external.log" 644
  verify_installed_mode "${dash_dir}/events-ops.log" 644
  verify_installed_mode "${dash_dir}/last-ops.json" 644
  verify_installed_mode "${dash_dir}/last-internal.json" 644
  verify_backup_dashboard_status_json_mode_glob "${dash_dir}/last-external-*.json" 644

  verify_recovery_stage_backup_setup_sanitized "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-backup-setup.sh"
  verify_recovery_stage_common_file "${PENELOPE_RECOVERY_STAGE_DIR}/penelope-common.sh"

  if [[ "${enable_usb_autorun}" == "1" ]]; then
    verify_installed_shell_script "${gate_path}"
    verify_installed_shell_script "${rules_refresher_path}"
    verify_installed_text_artifact "${unit_path}"
    validate_systemd_unit "${unit_path}"
    verify_installed_text_artifact "${arm_unit_path}"
    validate_systemd_unit "${arm_unit_path}"
    verify_systemd_service_enabled "penelope-usb-autorun-arm.service"
    verify_path_absent "${stale_reconcile_unit_path}" "obsolete USB auto-run reconcile unit"
    verify_installed_text_artifact "${detach_unit_path}"
    validate_systemd_unit "${detach_unit_path}"
    # Template units are instantiated on demand (for example penelope-usb-backup@<UUID>.service).
    # Verifying the installed template files plus daemon-reload-backed syntax validity is the
    # correct apply-time check here; requiring LoadState=loaded for the bare @.service template
    # produces false negatives before any concrete instance has been activated.
    verify_installed_text_artifact "${rules_path}"
    if (( usb_allowlist_entries > 0 )); then
      grep -qF 'ENV{ID_FS_UUID}=="' "${rules_path}" \
        || die "USB auto-run udev rules do not contain static allow-list UUID matches: ${rules_path}"
      grep -qF 'ENV{UDISKS_IGNORE}="1"' "${rules_path}" \
        || die "USB auto-run udev rules do not mark allow-listed disks UDISKS_IGNORE=1: ${rules_path}"
      grep -qF 'ENV{SYSTEMD_WANTS}+="penelope-usb-backup@' "${rules_path}" \
        || die "USB auto-run udev rules do not contain static systemd wants entries: ${rules_path}"
    fi
    if grep -qF 'PROGRAM==' "${rules_path}"; then
      die "USB auto-run udev rules still contain an obsolete runtime PROGRAM gate: ${rules_path}"
    fi
    if grep -qF 'ENV{ID_FS_UUID}!="", TAG+="systemd", ENV{SYSTEMD_WANTS}+="penelope-usb-backup@' "${rules_path}"; then
      die "USB auto-run udev rules still contain an obsolete generic SYSTEMD_WANTS rule: ${rules_path}"
    fi
  else
    verify_path_absent "${gate_path}" "USB auto-run gate helper"
    verify_path_absent "${rules_refresher_path}" "USB auto-run rules refresher"
    verify_path_absent "${unit_path}" "USB auto-run unit"
    verify_path_absent "${arm_unit_path}" "USB auto-run arm unit"
    verify_path_absent "${stale_reconcile_unit_path}" "obsolete USB auto-run reconcile unit"
    verify_path_absent "${detach_unit_path}" "USB detach cleanup unit"
    verify_path_absent "${rules_path}" "USB auto-run udev rules"
  fi

  if (( usb_allowlist_entries == 0 )); then
    local usb_ready_message=""
    usb_ready_message="USB external backup side not configured yet: ${USB_CONF} currently has no registered <UUID> <DISK_NAME> entries."
    usb_ready_message+=" Internal daily backups are ready; external USB runs will abort cleanly until a disk is registered."
    log "${usb_ready_message}"
  else
    log "USB allow-list entries verified: ${usb_allowlist_entries}"
  fi
}

main() {
  trap 'backup_setup_on_err ${LINENO} "${BASH_COMMAND}" $?' ERR
  trap 'backup_setup_on_signal INT' INT
  trap 'backup_setup_on_signal TERM' TERM
  trap 'release_backup_runtime_update_lock' EXIT

  parse_args "$@"

  case "${COMMAND}" in
    write-config)
      require_root
      local self_cmd
      self_cmd="${SELF_CMD}"
      init_backup_setup_config_tree
      cat <<EOF_BACKUP_INIT_DONE
[$(ts)] Bootstrap config tree initialized: ${BACKUP_SETUP_CONFIG_DIR}
[$(ts)] Next steps:
[$(ts)]   1. Inspect the active seeded files: sudo ls -l ${BACKUP_SETUP_CONFIG_DIR} ${BACKUP_SETUP_SECRETS_DIR}
[$(ts)]   2. Optional examples are under ${BACKUP_SETUP_EXAMPLES_DIR}
[$(ts)]   3. Edit ${BACKUP_SETUP_CONFIG_FILE} and ${BACKUP_SETUP_SECRETS_DIR}/*.secret
[$(ts)]   4. Verify the config non-destructively: sudo -E ${self_cmd} verify-config
[$(ts)]   5. Real apply: sudo -E ${self_cmd} apply
[$(ts)]   6. Verify installed host after apply: sudo -E /usr/local/sbin/penelope-verify-security.sh
[$(ts)]   7. Once effective restic credentials are chosen, capture them in KeePass or an equivalent secure external vault; this server must not be the only relied-on copy.
EOF_BACKUP_INIT_DONE
      exit 0
      ;;
    verify-config)
      verify_backup_setup_config
      exit 0
      ;;
    apply)
      ;;
    *)
      die "Internal error: unknown COMMAND=${COMMAND}"
      ;;
  esac

  require_root
  require_cmd_many apt-get openssl mountpoint

  log "=== Penelope backup setup ${VERSION} start (TARGET_HOST=${TARGET_HOST}, HOST_SCOPE_NAME=${HOST_SCOPE_NAME}) ==="
  log "Modes: CONFIG_MODE=${CONFIG_MODE}, SECRETS_MODE=${SECRETS_MODE}"

  log "-> Guard against active backup runtime before package or runtime updates"
  guard_no_active_backup_runner
  acquire_backup_runtime_update_lock

  log "-> Install required packages"
  apt_install restic python3 parted e2fsprogs exfatprogs util-linux cryptsetup dosfstools cron logrotate

  log "-> Install shared library and base directories"
  install_common_lib
  ensure_dir "${ETC_DIR}" 0755 root root
  ensure_dir "${VARLIB_DIR}" 0700 root root
  ensure_dir "${LOG_DIR}" 0750 root adm
  ensure_preserved_file "${BACKUP_LOG}" 0640 root adm "backup log"

  log "-> Refresh package-owned backup setup examples"
  refresh_backup_setup_package_owned_examples

  log "-> Verify backup setup config preflight"
  verify_backup_setup_config

  log "-> Write configuration and templates"
  guard_preserved_internal_repo_bootstrap
  write_backup_conf
  validate_backup_conf_schedule_runtime "${BACKUP_CONF}"
  validate_backup_conf_runtime_controls_runtime "${BACKUP_CONF}"
  validate_backup_conf_policy_controls_runtime "${BACKUP_CONF}"
  write_usb_conf_template
  ensure_no_unexpanded_tokens "${USB_CONF}"
  validate_usb_allowlist_disk_names "${USB_CONF}"
  install_backup_dashboard_dir

  log "-> Ensure restic secrets and internal repositories"
  ensure_dir "${RESTIC_CONFIG_DIR}" 0700 root root
  ensure_restic_pw "${RESTIC_PW_SYSTEM}"
  ensure_restic_pw "${RESTIC_PW_HOME}"
  ensure_restic_pw "${RESTIC_PW_ARCHIVE}"

  log "IMPORTANT: store restic passwords securely (KeePass etc.):"
  log "  ${RESTIC_PW_SYSTEM}"
  log "  ${RESTIC_PW_HOME}"
  log "  ${RESTIC_PW_ARCHIVE}"

  # Internal repos must never be created unless /_backup is mounted.
  ensure_expected_penelope_mount_layout "continue"
  local recommend_immediate_internal_verify_run="0"
  if ! current_internal_scope_has_any_repo; then
    recommend_immediate_internal_verify_run="1"
  fi
  init_repo "${INTERNAL_REPO_SYSTEM}" "${RESTIC_PW_SYSTEM}"
  init_repo "${INTERNAL_REPO_HOME}" "${RESTIC_PW_HOME}"
  init_repo "${INTERNAL_REPO_ARCHIVE}" "${RESTIC_PW_ARCHIVE}"

  log "-> Install generated tools and scheduling"
  install_runner
  install_backup_dashboard_refresh_monitor
  install_usb_autorun
  install_backup_verify
  install_backup_find_snapshot
  install_usb_disk_setup
  install_usb_password_rotation_tool
  install_offline_recover
  install_cron
  install_logrotate
  persist_sanitized_recovery_stage
  verify_backup_setup_installation
  release_backup_runtime_update_lock

  log "=== Penelope backup setup apply completed ==="
  log "Config: ${BACKUP_CONF}"
  log "USB allow-list: ${USB_CONF}"
  local usb_allowlist_entries="0"
  usb_allowlist_entries="$(count_usb_allowlist_entries "${USB_CONF}")"
  if (( usb_allowlist_entries == 0 )); then
    log "External USB backup side not configured yet: ${USB_CONF} currently has no registered disks."
    log "  Internal daily backups are ready. External manual/autorun USB backups will abort cleanly until you register a disk."
  else
    log "Registered external USB backup disks: ${usb_allowlist_entries}"
  fi
  log "Detailed logs: ${BACKUP_LOG}; ${LOG_DIR}/verify.log"
  log "Canonical backup dashboard: ${BACKUP_DASHBOARD_DIR}"
  log "First backup proof on fresh internal bring-up: sudo /usr/local/sbin/penelope-backup.sh --mode internal"
  log "Read-only internal verify after at least one successful internal backup: sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal"
  log "Find newest internal snapshot containing a path: sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode internal --target auto --path /home/internal/<path>"
  log "Fresh internal verify proof run: sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal --run-now"
  log "External backup proof after registering a disk: sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid <UUID>"
  log "External backup proof by disk name: sudo /usr/local/sbin/penelope-backup.sh --mode external --disk-name <DISK_NAME>"
  log "List external backup snapshots by disk name: sudo /usr/local/sbin/penelope-backup.sh --list --mode external --disk-name <DISK_NAME>"
  log "Find newest external snapshot containing a path: sudo /usr/local/sbin/penelope-backup-find-snapshot.sh --mode external --disk-name <DISK_NAME> --target auto --path /_archive/p001"
  log "Read-only external verify after at least one successful external backup: sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --uuid <UUID>"
  log "Read-only external verify by disk name: sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --disk-name <DISK_NAME>"
  log "Fresh external verify proof run: sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --uuid <UUID> --run-now"
  log "Fresh external verify proof run by disk name: sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --disk-name <DISK_NAME> --run-now"
  log "Manual run (internal): sudo /usr/local/sbin/penelope-backup.sh --mode internal"
  log "Manual forced full marker (internal): sudo /usr/local/sbin/penelope-backup.sh --mode internal --force-full"
  log "Manual run (external): sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid <UUID>"
  log "Manual run (external by disk name): sudo /usr/local/sbin/penelope-backup.sh --mode external --disk-name <DISK_NAME>"
  log "Manual forced full marker (external by disk name): sudo /usr/local/sbin/penelope-backup.sh --mode external --disk-name <DISK_NAME> --force-full"
  log "Cancel active internal backup: sudo /usr/local/sbin/penelope-backup.sh --cancel --mode internal"
  log "Cancel active external backup: sudo /usr/local/sbin/penelope-backup.sh --cancel --mode external --disk-name <DISK_NAME>"
  log "USB disk setup guided mode: sudo /usr/local/sbin/penelope-usb-disk-setup.sh"
  log "USB disk setup explicit new/disposable disk: sudo /usr/local/sbin/penelope-usb-disk-setup.sh --prepare-new"
  log "USB disk setup explicit existing disk: sudo /usr/local/sbin/penelope-usb-disk-setup.sh --register-existing"
  log "USB disk setup rename registered disk: sudo /usr/local/sbin/penelope-usb-disk-setup.sh --rename-disk"
  log "USB disk setup list registered disks: sudo /usr/local/sbin/penelope-usb-disk-setup.sh --list-registered"
  log "USB disk setup deregister disk: sudo /usr/local/sbin/penelope-usb-disk-setup.sh --deregister --disk-name <DISK_NAME>"
  log "External password rotation: sudo /usr/local/sbin/penelope-rotate-external-restic-passwords.sh --uuid <UUID>"
  log "Backup-dashboard refresh helper: /usr/local/sbin/penelope-refresh-backup-dashboard.sh"
  log "Offline recovery help: /usr/local/sbin/penelope-offline-recover.sh --help"
  log "Next inspect commands:"
  log "  Dashboard quick check: sudo ls -1 ${BACKUP_DASHBOARD_DIR}"
  log "  Inspect latest internal result: sudo cat ${BACKUP_DASHBOARD_DIR}/last-internal.json"
  log "Next verify commands:"
  log "  Verify installed host: sudo -E /usr/local/sbin/penelope-verify-security.sh"
  if [[ "${recommend_immediate_internal_verify_run}" == "1" ]]; then
    log "  Recommended now on this fresh bring-up: sudo /usr/local/sbin/penelope-backup.sh --mode internal"
    log "  Why now: this early manual run exercises the same installed internal backup runner path that the daily schedule will use later, while the dataset is still small."
  else
    log "  Optional immediate internal run: sudo /usr/local/sbin/penelope-backup.sh --mode internal"
  fi
  log "Successful internal/external backups also sync a non-secret recovery bundle to <repo-base>/_recovery"
  log "The bundle includes sanitized or otherwise non-secret setup-script copies when available."
  log "For Samba recovery, restore ${SAMBA_OPERATOR_CONFIG_DIR} from the system backup; _recovery remains tooling-only."
}
main "$@"
