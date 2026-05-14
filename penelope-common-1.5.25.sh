#!/usr/bin/env bash
# penelope-common.sh
# Shared library for Penelope project scripts
#
# This library provides common functionality for all Penelope scripts:
# - Standardized logging (log, warn, die)
# - Utility functions (require_root, require_cmd, ensure_dir)
# - Heredoc generators for embedded scripts
# - Macro injection system for code generation
# - Validation functions for generated files
#
# Usage:
#   source /path/to/penelope-common.sh
#   log "Script started"
#   require_root
#   ensure_dir /var/lib/penelope 0755 root root
#
# License: MIT

set -Eeuo pipefail

readonly PENELOPE_COMMON_VERSION="1.5.25"

# Installation path for library on target systems
readonly PENELOPE_COMMON_INSTALL_PATH="/usr/local/lib/penelope/common.sh"


# penelope_read_common_version_from_file() - Extract PENELOPE_COMMON_VERSION from a common library file
# Usage: penelope_read_common_version_from_file <file>
penelope_read_common_version_from_file() {
  local file="${1:?file required}"
  local line=""
  local ver=""
  [[ -f "${file}" ]] || return 0
  line="$(grep -E '^(readonly )?PENELOPE_COMMON_VERSION="[^"]+"$' "${file}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${line}" ]]; then
    ver="${line#readonly }"
    ver="${ver#PENELOPE_COMMON_VERSION=\"}"
    ver="${ver%\"}"
  fi
  printf '%s' "${ver}"
}

# penelope_version_is_older_than() - Compare dotted versions using sort -V
# Returns success when <have> is strictly older than <want>
# Usage: penelope_version_is_older_than <have> <want>
penelope_version_is_older_than() {
  local have="${1:-}"
  local want="${2:-}"
  [[ -n "${have}" && -n "${want}" ]] || return 1
  [[ "${have}" == "${want}" ]] && return 1
  local first=""
  first="$(printf '%s\n%s\n' "${have}" "${want}" | LC_ALL=C sort -V | head -n 1)"
  [[ "${first}" == "${have}" ]]
}


# penelope_require_common_functions() - Verify that the loaded common library
# provides the required public helper functions for a bundle.
# Usage:
#   penelope_require_common_functions <bundle_name> <bundle_version> <loaded_common_path> fn1 fn2 [fnN]
# Exits with code 127 and a clear bundle-mismatch message when functions are missing.
penelope_require_common_functions() {
  local bundle_name="${1:?bundle name required}"
  local bundle_version="${2:?bundle version required}"
  local loaded_common_path="${3:?loaded common path required}"
  shift 3

  local common_ver missing fn
  common_ver="${PENELOPE_COMMON_VERSION:-unknown}"
  missing=""

  for fn in "$@"; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      if [[ -n "$missing" ]]; then
        missing+=", "
      fi
      missing+="$fn"
    fi
  done

  if [[ -n "$missing" ]]; then
    printf >&2 \
      "[%s] ERROR: Incompatible bundle: %s %s expects a newer penelope-common.sh API (loaded: %s, version: %s). Missing function(s): %s\n" \
      "$(date +%H:%M:%S)" \
      "$bundle_name" \
      "$bundle_version" \
      "$loaded_common_path" \
      "$common_ver" \
      "$missing"
    printf >&2 \
      "[%s] ERROR: Use a matching bundle (%s + penelope-common.sh from the same release version).\n" \
      "$(date +%H:%M:%S)" \
      "$bundle_name"
    exit 127
  fi
}


# penelope_bundle_startup() - Validate a bundle/common pairing and run the
# standard source preflight scan for the current script.
# Usage:
#   penelope_bundle_startup <bundle_name> <bundle_version> <loaded_common_path> <script_source> <preflight_failure_message> fn1 fn2 [fnN]
# Exits with code 127 for bundle/API mismatches and uses die() for preflight failures.
penelope_bundle_startup() {
  local bundle_name="${1:?bundle name required}"
  local bundle_version="${2:?bundle version required}"
  local loaded_common_path="${3:?loaded common path required}"
  local script_source="${4:?script source required}"
  local preflight_failure_message="${5:-source preflight scan failed}"
  shift 5

  penelope_require_common_functions \
    "$bundle_name" \
    "$bundle_version" \
    "$loaded_common_path" \
    die \
    penelope_preflight_scan_script_source \
    penelope_require_common_functions \
    penelope_resolved_script_invocation_for_display \
    "$@"

  if ! penelope_preflight_scan_script_source "$script_source"; then
    die "$preflight_failure_message"
  fi
}

# penelope_resolved_script_invocation_for_display() - Return a normalized
# bundle-local command path for the current script, suitable for help/usage examples.
# Usage:
#   penelope_resolved_script_invocation_for_display [fallback_name] [script_path]
penelope_resolved_script_invocation_for_display() {
  local fallback_name="${1:-penelope-script.sh}"
  local script_path="${2:-${0:-${BASH_SOURCE[0]:-${fallback_name}}}}"
  local base_name="${script_path##*/}"
  if [[ -z "$base_name" ]]; then
    base_name="$fallback_name"
  fi
  printf '%q' "./${base_name}"
}

# penelope_quote_path_for_display() - Shell-quote an arbitrary path for user-facing
# command examples or status output.
# Usage:
#   penelope_quote_path_for_display <path>
penelope_quote_path_for_display() {
  printf '%q' "$1"
}

# penelope_bundle_local_command_for_display() - Return a normalized
# bundle-local command path for a sibling tool when the resolved path is known, otherwise return a fallback.
# Usage:
#   penelope_bundle_local_command_for_display [resolved_path] [fallback_display]
penelope_bundle_local_command_for_display() {
  local path="${1:-}"
  local fallback="${2:-./penelope-tool.sh}"
  if [[ -n "$path" ]]; then
    printf '%q' "./${path##*/}"
  else
    printf '%s' "$fallback"
  fi
}

# penelope_sanitize_trap_command() - Collapse trap command text into a single
# log-safe line and optionally replace heredoc bodies with a fixed marker.
penelope_sanitize_trap_command() {
  local cmd="${1:-<unknown>}"
  local max_len="${2:-240}"
  local heredoc_marker="${3:-(heredoc omitted)}"
  cmd="${cmd//$'
'/ }"
  cmd="${cmd//$'
'/ }"
  if [[ "${cmd}" == *'<<'* ]]; then
    cmd="${heredoc_marker}"
  fi
  if [[ "${max_len}" =~ ^[0-9]+$ ]] && (( max_len > 0 )) && (( ${#cmd} > max_len )); then
    cmd="${cmd:0:max_len}<TRUNCATED>"
  fi
  printf '%s' "${cmd}"
}

# penelope_log_trap_error() - Emit a standardised outer-script trap message.
penelope_log_trap_error() {
  local ec="${1:-1}"
  local line="${2:-?}"
  local cmd="${3:-<unknown>}"
  local max_len="${4:-240}"
  local heredoc_marker="${5:-(heredoc omitted)}"
  local sanitized=""
  sanitized="$(penelope_sanitize_trap_command "${cmd}" "${max_len}" "${heredoc_marker}")"
  >&2 echo "[$(ts)] ERROR: exit=${ec} line=${line} cmd=${sanitized}"
}

# penelope_signal_exit_code_for_name() - Return the conventional shell exit code
# for a terminating signal name used by trap handlers.
penelope_signal_exit_code_for_name() {
  case "${1:-}" in
    INT) printf '130' ;;
    TERM) printf '143' ;;
    HUP) printf '129' ;;
    *) printf '1' ;;
  esac
}

# Canonical local staging directory for sanitized recovery copies.
# Scripts may copy sanitized setup bundles here; backup-setup then mirrors this
# staged bundle beside the repos under <base>/_recovery.
readonly PENELOPE_RECOVERY_STAGE_DIR="/var/lib/penelope/recovery-stage"

# penelope_refresh_installed_common_lib() - Install or refresh penelope-common.sh on a running system
# Usage: penelope_refresh_installed_common_lib <source_common> [target_common]
# Example:
#   penelope_refresh_installed_common_lib "${SCRIPT_DIR}/penelope-common.sh"
#
# Version policy:
# - Refuses to replace a newer installed common library with an older bundle copy
#   unless PENELOPE_ALLOW_COMMON_DOWNGRADE=1 is set intentionally.
penelope_refresh_installed_common_lib() {
  local source_common="${1:?source common path required}"
  local target_common="${2:-${PENELOPE_COMMON_INSTALL_PATH}}"
  local target_dir="${target_common%/*}"
  local tmp_file=""
  local source_ver=""
  local target_ver=""
  local allow_downgrade="${PENELOPE_ALLOW_COMMON_DOWNGRADE:-0}"

  [[ -f "${source_common}" ]] || die "penelope-common.sh not found: ${source_common}"

  source_ver="$(penelope_read_common_version_from_file "${source_common}")"
  [[ -n "${source_ver}" ]] || die "Failed to read PENELOPE_COMMON_VERSION from ${source_common}"

  if [[ -f "${target_common}" ]]; then
    target_ver="$(penelope_read_common_version_from_file "${target_common}")"
    if [[ -z "${target_ver}" ]]; then
      warn "Installed penelope-common.sh has no readable PENELOPE_COMMON_VERSION: ${target_common}"
    fi
  fi

  if [[ -n "${target_ver}" ]] && penelope_version_is_older_than "${source_ver}" "${target_ver}"; then
    if [[ "${allow_downgrade}" != "1" ]]; then
      local msg=""
      msg="Refusing to replace newer installed penelope-common.sh (${target_ver}) "
      msg+="with older bundle copy (${source_ver}) at ${target_common}. "
      msg+="Refresh the workdir from the newer release first, or set "
      msg+="PENELOPE_ALLOW_COMMON_DOWNGRADE=1 for an intentional downgrade."
      die "${msg}"
    fi
    warn "Allowing penelope-common.sh downgrade by override: ${target_ver} -> ${source_ver} (${target_common})"
  fi

  if [[ -n "${target_ver}" ]]; then
    log "-> Refresh installed shared library: ${target_common} (source=${source_ver}, installed=${target_ver})"
  else
    log "-> Refresh installed shared library: ${target_common} (source=${source_ver})"
  fi

  ensure_dir "${target_dir}" 0755 root root
  tmp_file="$(mktemp "${target_common}.penelope.XXXXXX")" || die "Failed to allocate temp file for penelope-common.sh installation"
  install -m 0644 "${source_common}" "${tmp_file}" || {
    rm -f -- "${tmp_file}" 2>/dev/null || true
    die "Failed to stage penelope-common.sh for installation: ${target_common}"
  }
  validate_shell_script "${tmp_file}"
  mv -f -- "${tmp_file}" "${target_common}" || {
    rm -f -- "${tmp_file}" 2>/dev/null || true
    die "Failed to install penelope-common.sh: ${target_common}"
  }
  [[ -f "${target_common}" ]] || die "Failed to install penelope-common.sh: ${target_common}"
}

# penelope_recovery_stage_dir_for_target() - Return recovery stage dir for a target root
# Usage: penelope_recovery_stage_dir_for_target [target_root]
# Examples:
#   penelope_recovery_stage_dir_for_target "/target" -> /target/var/lib/penelope/recovery-stage
#   penelope_recovery_stage_dir_for_target "/"       -> /var/lib/penelope/recovery-stage
penelope_recovery_stage_dir_for_target() {
  local target="${1:-/}"
  target="${target%/}"
  [[ -n "$target" ]] || target="/"
  if [[ "$target" == "/" ]]; then
    printf '%s\n' "${PENELOPE_RECOVERY_STAGE_DIR}"
  else
    printf '%s%s\n' "$target" "${PENELOPE_RECOVERY_STAGE_DIR}"
  fi
}

# penelope_ensure_recovery_stage_dir() - Ensure the canonical recovery stage dir exists
# Usage: penelope_ensure_recovery_stage_dir [dir]
penelope_ensure_recovery_stage_dir() {
  local dir="${1:-${PENELOPE_RECOVERY_STAGE_DIR}}"
  ensure_dir "$dir" 0700 root root
}

# penelope_stage_common_for_recovery() - Copy penelope-common.sh into a recovery stage dir
# Prefers a source next to the calling script, then falls back to the installed common.
# Returns:
#   0 -> copied successfully
#   1 -> no suitable common source found
#   2 -> install failed
# Usage: penelope_stage_common_for_recovery <dest_dir> [script_dir]
penelope_stage_common_for_recovery() {
  local dest_dir="${1:?destination directory required}"
  local script_dir="${2:-}"
  local common_source=""
  local dest="${dest_dir%/}/penelope-common.sh"

  if [[ -n "$script_dir" && -f "$script_dir/penelope-common.sh" ]]; then
    common_source="$script_dir/penelope-common.sh"
  elif [[ -f "${PENELOPE_COMMON_INSTALL_PATH}" ]]; then
    common_source="${PENELOPE_COMMON_INSTALL_PATH}"
  else
    return 1
  fi

  install -m 0644 "$common_source" "$dest" || return 2
  return 0
}

# penelope_publish_recovery_stage_file() - Publish a prepared temp file into the recovery stage
# Usage: penelope_publish_recovery_stage_file <tmp_file> <dest_file> [mode]
# Returns:
#   0 -> published successfully
#   1 -> install failed
# Temp file cleanup is best-effort and does not affect the return code.
penelope_publish_recovery_stage_file() {
  local tmp_file="${1:?temporary source file required}"
  local dest_file="${2:?destination file required}"
  local mode="${3:-0755}"

  install -m "$mode" "$tmp_file" "$dest_file" || return 1
  rm -f "$tmp_file" 2>/dev/null || true
  return 0
}

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
# Standardized logging interface used across all Penelope scripts.
# All functions write to stderr to keep stdout available for data output.
#
# Primary functions:
#   log()   - INFO level messages
#   warn()  - WARNING level messages
#   die()   - ERROR level messages with exit
#
# ============================================================================

# Function I/O contract (canonical Penelope default):
# - stdout is reserved for machine-readable payload or explicit user-facing data output
# - stderr is reserved for INFO/WARNING/ERROR logging
# - return/exit codes carry status only
# - complex function outputs should use caller-provided nameref/out parameters when needed

# ts() - Generate HH:MM:SS timestamp for log messages
# Returns "00:00:00" if date command fails (portability fallback)
ts() { date +'%H:%M:%S' 2>/dev/null || echo "00:00:00"; }

# log() - Log informational message to stderr
# Usage: log "message"
log() { >&2 echo "[$(ts)] INFO: $*"; }

# warn() - Log warning message to stderr
# Usage: warn "message"
warn() { >&2 echo "[$(ts)] WARNING: $*"; }

# die() - Log error message and exit with specified code
# Usage: die "message" [exit_code]
# Parameters:
#   $1 - Error message (default: "Unknown error")
#   $2 - Exit code (default: 1)
# Examples:
#   die "File not found"           # exits with code 1
#   die "Invalid argument" 2       # exits with code 2
die() {
  local msg="${1:-Unknown error}"
  local ec="${2:-1}"
  >&2 echo "[$(ts)] ERROR: ${msg}"
  exit "$ec"
}


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# require_root() - Ensure script is running as root (EUID=0)
# Usage: require_root [example_cmd]
# Dies with error message if not root. When example_cmd is provided, it is shown
# as the exact suggested command after "sudo -E".
require_root() {
  local example_cmd="${1:-}"
  if [[ "${EUID}" -ne 0 ]]; then
    if [[ -n "${example_cmd}" ]]; then
      die "This script must run as root. Example: sudo -E ${example_cmd}"
    fi
    die "This script must run as root. Example: sudo -E $0"
  fi
}

initramfs_cleanup_penelope_artifacts() {
  # Remove Penelope-managed initramfs scripts/hooks/conf.d from previous runs to avoid mixing versions.
  #
  # This is best-effort and intentionally conservative: it only removes files that clearly belong to Penelope.
  # The function is safe to run repeatedly.
  require_root "$0"

  local root="${1:-/}"
  root="${root%/}"

  local rel_dir abs_dir f bn
  local rel_dirs=(
    "etc/initramfs-tools/scripts/init-top"
    "etc/initramfs-tools/scripts/init-premount"
    "etc/initramfs-tools/scripts/init-bottom"
    "etc/initramfs-tools/hooks"
    "etc/initramfs-tools/conf.d"
  )

  for rel_dir in "${rel_dirs[@]}"; do
    abs_dir="${root}/${rel_dir}"
    [[ -d "$abs_dir" ]] || continue

    shopt -s nullglob
    for f in "$abs_dir"/*; do
      [[ -e "$f" ]] || continue
      bn="${f##*/}"

      # Fast path: filename contains penelope.
      if [[ "$bn" == *penelope* ]] || [[ "$bn" == *PENELOPE* ]]; then
        rm -f -- "$f" 2>/dev/null || true
        continue
      fi

      # Conservative content match: only remove if the file clearly references Penelope.
      if command -v grep >/dev/null 2>&1; then
        if grep -Iqi 'penelope' -- "$f" 2>/dev/null; then
          rm -f -- "$f" 2>/dev/null || true
          continue
        fi
      fi
    done
    shopt -u nullglob
  done
}


# require_cmd() - Ensure command/binary exists in PATH
# Dies if command not found
# Usage: require_cmd <command>
require_cmd() {
  local cmd="${1:?cmd required}"
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing dependency: ${cmd}"
}

# require_cmd_many() - Ensure multiple commands/binaries exist in PATH
# Dies if any command not found
# Usage: require_cmd_many <cmd1> [cmdN]
require_cmd_many() {
  local cmd=""
  (($# > 0)) || die "require_cmd_many needs at least one command"
  for cmd in "$@"; do
    require_cmd "${cmd}"
  done
}

# ensure_dir() - Create directory with specified ownership and permissions
# Uses install -d for atomic creation with correct permissions
# Usage: ensure_dir <path> <mode> <owner> <group>
# Example: ensure_dir /var/lib/penelope 0755 root root
ensure_dir() {
  local dir="${1:?dir required}"
  local mode="${2:?mode required}"
  local owner="${3:?owner required}"
  local group="${4:?group required}"

  install -d -m "${mode}" -o "${owner}" -g "${group}" "${dir}"
}

# ensure_file() - Create empty file with specified ownership and permissions
# Uses install for atomic creation with correct permissions
# Usage: ensure_file <path> <mode> <owner> <group>
# Example: ensure_file /etc/penelope/config 0600 root root
ensure_file() {
  local file="${1:?file required}"
  local mode="${2:?mode required}"
  local owner="${3:?owner required}"
  local group="${4:?group required}"

  install -m "${mode}" -o "${owner}" -g "${group}" /dev/null "${file}"
}

# have() - Check if command exists in PATH (non-fatal version of require_cmd)
# Returns 0 if command exists, 1 if not found
# Usage: if have git; then <OMITTED>; fi
have() { command -v "$1" >/dev/null 2>&1; }

# ensure_penelope_run_dir() - Ensure a Penelope runtime state directory exists
# Usage: ensure_penelope_run_dir [dir]
# Default: /run/penelope
ensure_penelope_run_dir() {
  local run_dir="${1:-/run/penelope}"
  install -d -m 0700 -o root -g root "${run_dir}"
}

# current_boot_id() - Return the current Linux boot ID when available
# Usage: current_boot_id
current_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

# proc_start_time() - Return the /proc start_time field for a PID
# Usage: proc_start_time <pid>
proc_start_time() {
  local pid="${1:?pid required}"
  awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true
}

# write_pid_dir_lock_metadata() - Write lock metadata for the current process
# Usage: write_pid_dir_lock_metadata <lock_dir>
write_pid_dir_lock_metadata() {
  local lock_dir="${1:?lock dir required}"
  local boot_id=""
  local start_time=""
  local tmp_pid=""
  local tmp_boot=""
  local tmp_start=""

  boot_id="$(current_boot_id 2>/dev/null || true)"
  [[ -n "${boot_id}" ]] || {
    rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }

  start_time="$(proc_start_time "$$" 2>/dev/null || true)"
  [[ -n "${start_time}" ]] || {
    rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }

  tmp_pid="$(mktemp "${lock_dir}/.pid.XXXXXX" 2>/dev/null)" || {
    rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  tmp_boot="$(mktemp "${lock_dir}/.boot_id.XXXXXX" 2>/dev/null)" || {
    rm -f "${tmp_pid}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  tmp_start="$(mktemp "${lock_dir}/.proc_start_time.XXXXXX" 2>/dev/null)" || {
    rm -f "${tmp_pid}" "${tmp_boot}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }

  printf '%s\n' "$$" > "${tmp_pid}" 2>/dev/null || {
    rm -f "${tmp_pid}" "${tmp_boot}" "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "${boot_id}" > "${tmp_boot}" 2>/dev/null || {
    rm -f "${tmp_pid}" "${tmp_boot}" "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "${start_time}" > "${tmp_start}" 2>/dev/null || {
    rm -f "${tmp_pid}" "${tmp_boot}" "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }

  mv -f "${tmp_pid}" "${lock_dir}/pid" 2>/dev/null || {
    rm -f "${tmp_pid}" "${tmp_boot}" "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  mv -f "${tmp_boot}" "${lock_dir}/boot_id" 2>/dev/null || {
    rm -f "${tmp_boot}" "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
  mv -f "${tmp_start}" "${lock_dir}/proc_start_time" 2>/dev/null || {
    rm -f "${tmp_start}" "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    return 1
  }
}

# acquire_pid_dir_lock() - Acquire a PID-directory lock with stale-lock cleanup
# Usage: acquire_pid_dir_lock <lock_dir> <label>
acquire_pid_dir_lock() {
  local lock_dir="${1:?lock dir required}"
  local label="${2:?label required}"
  local pid=""
  local lock_boot=""
  local lock_start=""
  local current_boot=""
  local current_start=""

  ensure_penelope_run_dir "$(dirname "${lock_dir}")" || die "Failed to prepare ${label} lock parent directory: $(dirname "${lock_dir}")"
  if mkdir "${lock_dir}" 2>/dev/null; then
    if write_pid_dir_lock_metadata "${lock_dir}"; then
      return 0
    fi
    rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
    rmdir "${lock_dir}" 2>/dev/null || true
    die "Failed to initialize ${label} lock metadata: ${lock_dir}"
  fi

  pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  lock_boot="$(cat "${lock_dir}/boot_id" 2>/dev/null || true)"
  lock_start="$(cat "${lock_dir}/proc_start_time" 2>/dev/null || true)"
  current_boot="$(current_boot_id)"

  if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
    if [[ -n "${lock_boot}" && -n "${current_boot}" && "${lock_boot}" != "${current_boot}" ]]; then
      warn "Removing stale ${label} lock from previous boot: ${lock_dir}"
    else
      current_start="$(proc_start_time "${pid}")"
      if [[ -n "${current_start}" && -n "${lock_start}" && "${current_start}" == "${lock_start}" ]]; then
        die "Another ${label} seems to be running (pid ${pid})."
      fi
      if kill -0 "${pid}" 2>/dev/null; then
        die "Another ${label} seems to be running (pid ${pid})."
      fi
      warn "Removing stale ${label} lock with inactive pid ${pid}: ${lock_dir}"
    fi
  else
    warn "Removing stale ${label} lock without valid pid metadata: ${lock_dir}"
  fi

  rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
  rmdir "${lock_dir}" 2>/dev/null || die "Failed to remove stale ${label} lock: ${lock_dir}"
  mkdir "${lock_dir}" 2>/dev/null || die "Another ${label} seems to be running (${lock_dir} exists)."
  if write_pid_dir_lock_metadata "${lock_dir}"; then
    return 0
  fi
  rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
  rmdir "${lock_dir}" 2>/dev/null || true
  die "Failed to initialize ${label} lock metadata: ${lock_dir}"
}

# release_pid_dir_lock() - Release a PID-directory lock acquired by acquire_pid_dir_lock
# Usage: release_pid_dir_lock [lock_dir]
release_pid_dir_lock() {
  local lock_dir="${1:-}"
  [[ -n "${lock_dir}" ]] || return 0

  if [[ ! -d "${lock_dir}" ]]; then
    return 0
  fi

  rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || return 1
  if [[ -d "${lock_dir}" ]]; then
    rmdir "${lock_dir}" 2>/dev/null || return 1
  fi
  return 0
}

# pid_dir_lock_is_active() - Check whether a PID-directory lock belongs to a live process
# Removes stale lock directories and returns non-zero for inactive or stale locks.
# Usage: pid_dir_lock_is_active <lock_dir> <label>
pid_dir_lock_is_active() {
  local lock_dir="${1:?lock dir required}"
  local label="${2:?label required}"
  local pid=""
  local lock_boot=""
  local lock_start=""
  local current_boot=""
  local current_start=""

  [[ -d "${lock_dir}" ]] || return 1

  pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  lock_boot="$(cat "${lock_dir}/boot_id" 2>/dev/null || true)"
  lock_start="$(cat "${lock_dir}/proc_start_time" 2>/dev/null || true)"
  current_boot="$(current_boot_id)"

  if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
    if [[ -n "${lock_boot}" && -n "${current_boot}" && "${lock_boot}" != "${current_boot}" ]]; then
      warn "Removing stale ${label} lock from previous boot: ${lock_dir}"
    else
      current_start="$(proc_start_time "${pid}")"
      if [[ -n "${current_start}" && -n "${lock_start}" && "${current_start}" == "${lock_start}" ]]; then
        return 0
      fi
      if kill -0 "${pid}" 2>/dev/null; then
        return 0
      fi
      warn "Removing stale ${label} lock with inactive pid ${pid}: ${lock_dir}"
    fi
  else
    warn "Removing stale ${label} lock without valid pid metadata: ${lock_dir}"
  fi

  rm -f "${lock_dir}/pid" "${lock_dir}/boot_id" "${lock_dir}/proc_start_time" 2>/dev/null || true
  rmdir "${lock_dir}" 2>/dev/null || die "Failed to remove stale ${label} lock: ${lock_dir}"
  return 1
}

# pid_dir_lock_is_active_runtime() - Backward-compatible runtime lock checker alias
# Usage: pid_dir_lock_is_active_runtime <lock_dir> <label>
pid_dir_lock_is_active_runtime() {
  pid_dir_lock_is_active "$@"
}

# init_single_uuid_run_lock_state() - Initialize script-local UUID lock state
# Usage: init_single_uuid_run_lock_state
init_single_uuid_run_lock_state() {
  UUID_LOCK_PATH=""
}

# try_acquire_single_uuid_run_lock() - Try to acquire a non-blocking UUID-scoped runtime lock
# Uses flock(1) when available and falls back to an atomic directory lock.
# Usage: try_acquire_single_uuid_run_lock <uuid> [lock_root]
try_acquire_single_uuid_run_lock() {
  local uuid="${1:?uuid required}"
  local lock_root="${2:-${RUN_DIR:-/run/${PROJECT:-penelope}}}"
  local lock_path=""

  ensure_penelope_run_dir "${lock_root}" || die "Failed to prepare UUID runtime lock directory: ${lock_root}"
  lock_path="${lock_root}/usb-backup-${uuid}.lock"
  UUID_LOCK_PATH="${lock_path}"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${lock_path}" || die "Failed to open UUID runtime lock file: ${lock_path}"
    flock -n 9 && return 0
    return 1
  fi

  mkdir "${lock_path}.d" 2>/dev/null || return 1
  UUID_LOCK_PATH="${lock_path}.d"
}

# acquire_single_uuid_run_lock() - Acquire a non-blocking UUID-scoped runtime lock or die
# Usage: acquire_single_uuid_run_lock <uuid> <message> [lock_root]
acquire_single_uuid_run_lock() {
  local uuid="${1:?uuid required}"
  local message="${2:?message required}"
  local lock_root="${3:-${RUN_DIR:-/run/${PROJECT:-penelope}}}"

  try_acquire_single_uuid_run_lock "${uuid}" "${lock_root}" || die "${message}"
}

# release_single_uuid_run_lock() - Release a UUID runtime lock acquired by try/acquire_single_uuid_run_lock
# Usage: release_single_uuid_run_lock
release_single_uuid_run_lock() {
  if [[ -n "${UUID_LOCK_PATH:-}" && "${UUID_LOCK_PATH}" == *.d ]]; then
    if ! rmdir "${UUID_LOCK_PATH}" 2>/dev/null; then
      return 1
    fi
    UUID_LOCK_PATH=""
    return 0
  fi

  # flock(1)-based locks are released by closing the descriptor. Do this explicitly
  # so long-running read-only commands do not observe a stale lock until shell exit.
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  UUID_LOCK_PATH=""
  return 0
}

# apt_install() - Install packages using apt-get
# Handles update and install with non-interactive frontend
# Usage: apt_install package1 package2 package3
# Example: apt_install git curl vim
apt_install() {
  local pkgs=("$@")
  log "Installing packages: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

# read_kv_value_from_file() - Parse key=value from configuration files
# Reads the value for a given key from a file
# Supports quoted and unquoted values
# Returns 1 if key not found
# Usage: value=$(read_kv_value_from_file /path/to/config.conf KEY_NAME)
# Example:
#   read_kv_value_from_file backup.conf REPOSITORY_PATH
#   Supports: KEY=value, KEY="value", KEY='value'
read_kv_value_from_file() {
  local file="${1:?file required}"
  local key="${2:?key required}"
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 1

  if [[ "${line}" =~ ^[[:space:]]*${key}=\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${line}" =~ ^[[:space:]]*${key}=\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${line}" =~ ^[[:space:]]*${key}=([^#[:space:]]+)[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}


# read_kv_value_from_file_or_default() - Read key=value from config files with default + placeholder guard
# Returns the resolved value for a given key from a file, or the provided default if the file/key is missing
# or the resolved value still contains placeholder markers like "___PENELOPE_PLACEHOLDER___".
# Usage: value=$(read_kv_value_from_file_or_default /path/to/config.conf KEY_NAME default-value)
read_kv_value_from_file_or_default() {
  local file="${1:?file required}"
  local key="${2:?key required}"
  (($# >= 3)) || die "read_kv_value_from_file_or_default requires a default value argument"
  local default_value="${3-}"
  local value=""

  if [[ -f "${file}" ]]; then
    value="$(read_kv_value_from_file "${file}" "${key}" || true)"
  fi

  local placeholder_re='___PENELOPE_[A-Z0-9_]+___'
  if [[ -n "${value}" ]] && [[ "${value}" =~ ${placeholder_re} ]]; then
    warn "Ignoring ${key} with Penelope placeholder token in ${file}"
    value=""
  fi

  if [[ -n "${value}" ]]; then
    printf '%s\n' "${value}"
    return 0
  fi

  printf '%s\n' "${default_value}"
}

# is_placeholder_secret_value() - Return success if the value is the canonical shipped placeholder or empty
# Rejects empty/whitespace-only values and the exact shipped placeholder "change-me".
# Usage: if is_placeholder_secret_value "$secret"; then handle_placeholder; fi
is_placeholder_secret_value() {
  local value="${1-}"

  if [[ -z "${value//[[:space:]]/}" ]]; then
    return 0
  fi

  [[ "${value}" == "change-me" ]]
}

# validate_secret_not_placeholder() - Fail fast if a required operator-edited secret is still empty or set to change-me
# Usage: validate_secret_not_placeholder CRED_MASTER_PW "${CRED_MASTER_PW}"
validate_secret_not_placeholder() {
  local name="${1:?name required}"
  local value="${2-}"

  if is_placeholder_secret_value "${value}"; then
    die "${name} must be set to a real operator-chosen secret before runtime (change-me or empty value rejected)."
  fi
}

# is_mounted() - Check if a path is a mountpoint
# Wrapper around mountpoint -q for cleaner API
# Returns 0 if mounted, 1 if not
# Usage: if is_mounted /mnt/backup; then <OMITTED>; fi
is_mounted() {
  local mnt="${1:?mountpoint required}"
  mountpoint -q "${mnt}"
}

# ensure_expected_penelope_mount_layout() - Validate Penelope's required mounted filesystem layout
# Verifies that /_backup and /_archive are mounted and /home is a separate mountpoint.
# Usage: ensure_expected_penelope_mount_layout [context]
# Example: ensure_expected_penelope_mount_layout "smoke test"
ensure_expected_penelope_mount_layout() {
  local context="${1:-continue}"
  if ! is_mounted "/_backup"; then
    warn "Mountpoint /_backup is not mounted. System does not match expected Penelope layout."
    die "Refusing to ${context} without mounted /_backup."
  fi
  if ! is_mounted "/_archive"; then
    warn "Mountpoint /_archive is not mounted. System does not match expected Penelope layout."
    die "Refusing to ${context} without mounted /_archive."
  fi
  if ! is_mounted "/home"; then
    warn "Mountpoint /home is not mounted as a separate filesystem. System does not match expected Penelope layout."
    die "Refusing to ${context} without mounted /home."
  fi
}


# normalize_disk_name_token() - Convert an operator disk name into a stable token
# Used for case-insensitive DISK_NAME matching and dashboard file suffixes.
# Usage: token=$(normalize_disk_name_token "backup-01")
normalize_disk_name_token() {
  local raw="${1:-}"
  local token=""
  token="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
  [[ -n "${token}" ]] || token="disk"
  printf '%s\n' "${token}"
}

# uuid_in_allowlist() - Check whether a UUID is present in an allowlist file
# Usage: uuid_in_allowlist /etc/penelope/usb-backup-disks.conf <uuid>
uuid_in_allowlist() {
  local conf_file="${1:?allowlist file required}"
  local uuid="${2:?uuid required}"
  [[ -f "${conf_file}" ]] || return 1
  awk -v u="${uuid}" '
    { sub(/#.*/, ""); }
    NF == 0 { next }
    $1 == u { found=1 }
    END { exit found ? 0 : 1 }
  ' "${conf_file}"
}

# read_present_allowlisted_uuids() - List allowlisted UUIDs that are currently present
# Usage: read_present_allowlisted_uuids /etc/penelope/usb-backup-disks.conf
read_present_allowlisted_uuids() {
  local conf_file="${1:?allowlist file required}"
  [[ -f "${conf_file}" ]] || return 0
  while read -r uuid _rest; do
    [[ -n "${uuid}" ]] || continue
    [[ "${uuid}" =~ ^# ]] && continue
    if blkid -U "${uuid}" >/dev/null 2>&1; then
      printf '%s\n' "${uuid}"
    fi
  done < <(awk '{ sub(/#.*/, ""); if (NF > 0) print $0 }' "${conf_file}")
}

# usb_dev_for_uuid() - Resolve a block device path for a filesystem UUID
# Usage: dev=$(usb_dev_for_uuid <uuid>)
usb_dev_for_uuid() {
  local uuid="${1:?uuid required}"
  blkid -U "${uuid}" 2>/dev/null || true
}

# usb_fstype_for_dev() - Read the filesystem type for a block device
# Usage: fstype=$(usb_fstype_for_dev /dev/sdb1)
usb_fstype_for_dev() {
  local dev="${1:?dev required}"
  blkid -s TYPE -o value "${dev}" 2>/dev/null || true
}

# unmount_all_mounts_for_dev() - Unmount all current mountpoints for a device, deepest first
# Usage: unmount_all_mounts_for_dev /dev/sdb1
unmount_all_mounts_for_dev() {
  local dev="${1:?dev required}"
  local mnts
  mnts="$(findmnt -rn -o TARGET --source "${dev}" 2>/dev/null || true)"
  [[ -n "${mnts}" ]] || return 0
  while read -r mp; do
    [[ -n "${mp}" ]] || continue
    umount "${mp}" || return 1
  done < <(echo "${mnts}" | awk '{print length, $0}' | sort -rn | cut -d" " -f2-)
}

# dev_is_mounted_anywhere() - Return success if the device is mounted at any target
# Usage: if dev_is_mounted_anywhere /dev/sdb1; then handle_mounted_device; fi
dev_is_mounted_anywhere() {
  local dev="${1:?dev required}"
  findmnt -n -o TARGET --source "${dev}" 2>/dev/null | grep -q .
}

# generate_pw() - Generate or preserve password file using openssl
# Creates a new random password file if it doesn't exist
# Preserves existing password file if present
# Usage: generate_pw /path/to/password.txt
# Example: generate_pw /root/.config/restic/backup_pw
generate_pw() {
  local file="${1:?pw file required}"
  if [[ -f "${file}" ]] && [[ -s "${file}" ]]; then
    log "Password file exists: ${file} (unchanged)"
    chmod 600 "${file}" || true
    return 0
  fi

  log "Generating password file: ${file}"
  (
    umask 077
    openssl rand -base64 32 > "${file}"
  )
  chmod 600 "${file}"
}

# part_dev() - Construct partition device path for different disk types
# Handles NVMe (p suffix), MMC (p suffix), SATA (no suffix), and by-id paths (-part suffix)
# Usage: part_dev <disk> <partition_number>
# Examples:
#   part_dev /dev/sda 1           -> /dev/sda1
#   part_dev /dev/nvme0n1 2       -> /dev/nvme0n1p2
#   part_dev /dev/mmcblk0 3       -> /dev/mmcblk0p3
#   part_dev /dev/disk/by-id/<DEVICE> 1 -> /dev/disk/by-id/<DEVICE>-part1
part_dev() {
  local disk="${1:?disk required}"
  local n="${2:?partition number required}"

  if [[ "${disk}" == /dev/disk/by-*/* ]]; then
    echo "${disk}-part${n}"
  elif [[ "${disk}" =~ [0-9]$ ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

# install_file_from_heredoc() - Install file from heredoc with processing
# Reads content from stdin (heredoc), processes macros, applies permissions
# NOTE: This generic version does NOT apply placeholders or version stamping
# Callers must handle those separately if needed
# Usage:
#   install_file_from_heredoc <path> <mode> <owner> <group> <<'EOF'
#   file content here
#   EOF
# Example:
#   install_file_from_heredoc /usr/local/bin/script.sh 0755 root root <<'EOF'
#   #!/usr/bin/env bash
#   ___PENELOPE_SOURCE_COMMON___
#   log "Hello"
#   EOF
install_file_from_heredoc() {
  local path="${1:?path required}"
  local mode="${2:?mode required}"
  local owner="${3:?owner required}"
  local group="${4:?group required}"

  local dir
  dir="$(dirname "${path}")"
  install -d -m 0755 -o root -g root "${dir}"

  # Read file content from stdin
  cat > "${path}"

  # Expand known macro tokens (if present)
  inject_known_macros_if_present "${path}"

  # Apply ownership and permissions
  chown "${owner}:${group}" "${path}"
  chmod "${mode}" "${path}"

  # Validate generated file
  validate_generated_file "${path}"
  ensure_no_unexpanded_tokens "${path}"
}

# ============================================================================
# HEREDOC GENERATORS FOR EMBEDDED SCRIPTS
# ============================================================================
# These functions generate standardized code blocks for injection into
# generated scripts. The output goes to stdout, typically redirected to
# a file or used with inject_block_into_file().
# ============================================================================

# write_log_functions_block_bash() - Generate bash logging functions
# Outputs log/warn/die functions suitable for bash scripts
# Includes support for optional log_append() hook
# Generated contract: payload stays on stdout; log/warn/die emit to stderr
# Usage: write_log_functions_block_bash > /tmp/logfuncs.sh
write_log_functions_block_bash() {
  cat <<'EOF_LOG_FUNCS_BASH'
ts() { date +'%H:%M:%S' 2>/dev/null || echo "00:00:00"; }

_log_emit() { >&2 echo "$*"; }

# Optional hook: if a script defines log_append() later, log() will route to it at call time.
_log_append_available() { declare -F log_append >/dev/null 2>&1; }

log() {
  local msg
  msg="[$(ts)] INFO: $*"
  if _log_append_available; then
    log_append "${msg}"
  else
    _log_emit "${msg}"
  fi
}

warn() {
  local msg
  msg="[$(ts)] WARNING: $*"
  if _log_append_available; then
    log_append "${msg}"
  else
    _log_emit "${msg}"
  fi
}

die() {
  local msg_text="${1:-Unknown error}"
  local ec="${2:-1}"
  local msg
  msg="[$(ts)] ERROR: ${msg_text}"
  if _log_append_available; then
    log_append "${msg}"
  else
    _log_emit "${msg}"
  fi
  exit "$ec"
}

EOF_LOG_FUNCS_BASH
}

# write_log_functions_block_sh() - Generate POSIX sh logging functions
# Outputs log/warn/die functions suitable for /bin/sh scripts
# Simpler implementation without bash-specific features
# Generated contract: payload stays on stdout; log/warn/die emit to stderr
# Usage: write_log_functions_block_sh > /tmp/logfuncs.sh
write_log_functions_block_sh() {
  cat <<'EOF_LOG_FUNCS_SH'
ts() { date +'%H:%M:%S' 2>/dev/null || echo "00:00:00"; }

have() { command -v "$1" >/dev/null 2>&1; }

log() { >&2 echo "[$(ts)] INFO: $*"; }
warn() { >&2 echo "[$(ts)] WARNING: $*"; }
die() { msg="${1:-Unknown error}"; ec="${2:-1}"; >&2 echo "[$(ts)] ERROR: ${msg}"; exit "$ec"; }

EOF_LOG_FUNCS_SH
}

# write_common_guards_block_bash() - Generate bash error handling guards
# Outputs strict mode settings and ERR trap for bash scripts
# Usage: write_common_guards_block_bash > /tmp/guards.sh
write_common_guards_block_bash() {
  cat <<'EOF_GUARDS_BASH'
set -Eeuo pipefail
IFS=$' \t\n'

_penelope_err_trap() {
  local line="${1:-?}"
  local cmd="${2:-<unknown>}"
  local ec="${3:-1}"
  >&2 echo "[ERROR] exit=${ec} line=${line} cmd=${cmd}"
  exit "${ec}"
}

trap '_penelope_err_trap ${LINENO} "${BASH_COMMAND}" $?' ERR
EOF_GUARDS_BASH
}

# write_common_guards_block_sh() - Generate POSIX sh error handling guards
# Outputs strict mode settings suitable for /bin/sh scripts
# Usage: write_common_guards_block_sh > /tmp/guards.sh
write_common_guards_block_sh() {
  cat <<'EOF_GUARDS_SH'
set -eu
IFS='
'
EOF_GUARDS_SH
}

# ============================================================================
# MACRO INJECTION SYSTEM
# ============================================================================
# The macro injection system allows generated scripts to use placeholder
# tokens like ___PENELOPE_LOG_FUNCTIONS___ that get replaced with actual
# code at generation time.
#
# Supported macros:
#   ___PENELOPE_LOG_FUNCTIONS___  - Replaced with log/warn/die functions
#   ___PENELOPE_COMMON_GUARDS___  - Replaced with set -Eeuo pipefail + trap
#
# The system automatically selects bash vs sh implementations based on
# the script's shebang line.
# ============================================================================

# inject_block_into_file() - Replace a token line in a file with content from another file
# Uses awk with getline for safe, robust replacement without shell injection risks
# The file is modified in-place
#
# Usage: inject_block_into_file <target_file> <token> <block_file>
# Parameters:
#   $1 - Target file containing the token to replace
#   $2 - Token string (entire line must match exactly)
#   $3 - Block file containing replacement content
#
# Example:
#   echo "___PENELOPE_PLACEHOLDER___" > script.sh
#   echo "replacement content" > block.txt
#   inject_block_into_file script.sh "___PENELOPE_PLACEHOLDER___" block.txt
#   # script.sh now contains "replacement content" instead of "___PENELOPE_PLACEHOLDER___"
inject_block_into_file() {
  local f="${1:?missing target file}"
  local token="${2:?missing token}"
  local block_file="${3:?missing block file}"
  local tmp

  [[ -f "$f" ]] || die "inject_block_into_file: file not found: $f"
  [[ -f "$block_file" ]] || die "inject_block_into_file: block file not found: $block_file"

  if ! command -v mktemp >/dev/null 2>&1; then
    die "inject_block_into_file: mktemp is required"
  fi

  # Use getline instead of system() to avoid shell injection vulnerabilities.
  # The token must occur at least once; direct callers must not silently no-op.
  tmp="$(mktemp "${f}.penelope.XXXXXX")"
  if ! awk -v tok="$token" -v blk="$block_file" '
    BEGIN { found = 0 }
    $0 == tok {
      found = 1
      while ((getline line < blk) > 0) print line
      close(blk)
      next
    }
    { print }
    END { if (!found) exit 42 }
  ' "$f" >"$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    die "inject_block_into_file: token not found or injection failed: $token in $f"
  fi

  mv "$tmp" "$f" || {
    rm -f "$tmp" 2>/dev/null || true
    die "inject_block_into_file: failed to overwrite: $f"
  }
}

_inject_shebang_selected_macro_if_present() {
  local file="${1:?file required}"
  local token="${2:?token required}"
  local bash_writer="${3:?bash writer required}"
  local sh_writer="${4:?sh writer required}"
  grep -q "^${token}$" "${file}" || return 0

  local shebang
  shebang="$(head -n 1 "${file}" || true)"

  local block
  block="$(mktemp "${TMPDIR:-/tmp}/penelope-macro.XXXXXX")"

  case "${shebang}" in
    '#!/usr/bin/env bash'|'#!/bin/bash'|'#!/usr/bin/bash')
      "${bash_writer}" > "${block}"
      ;;
    '#!/bin/sh')
      "${sh_writer}" > "${block}"
      ;;
    *)
      rm -f "${block}" 2>/dev/null || true
      die "Unsupported shebang for ${token}: ${shebang}"
      ;;
  esac

  inject_block_into_file "${file}" "${token}" "${block}"
  rm -f "${block}" 2>/dev/null || true

  if grep -q "^${token}$" "${file}"; then
    die "Macro token not replaced: ${token} (${file})"
  fi
}

# inject_log_functions_macro_if_present() - Replace ___PENELOPE_LOG_FUNCTIONS___ macro
# Detects script shebang and injects appropriate logging functions (bash vs sh)
# Does nothing if macro token not present in file
#
# Usage: inject_log_functions_macro_if_present <file>
# Example:
#   cat > script.sh <<'EOF'
#   #!/usr/bin/env bash
#   ___PENELOPE_LOG_FUNCTIONS___
#   log "Hello"
#   EOF
#   inject_log_functions_macro_if_present script.sh
#   # script.sh now contains full log/warn/die implementation
inject_log_functions_macro_if_present() {
  local file="${1:?file required}"
  _inject_shebang_selected_macro_if_present     "${file}"     "___PENELOPE_LOG_FUNCTIONS___"     write_log_functions_block_bash     write_log_functions_block_sh
}

# inject_common_guards_macro_if_present() - Replace ___PENELOPE_COMMON_GUARDS___ macro
# Detects script shebang and injects appropriate error handling (bash vs sh)
# Does nothing if macro token not present in file
#
# Usage: inject_common_guards_macro_if_present <file>
inject_common_guards_macro_if_present() {
  local file="${1:?file required}"
  _inject_shebang_selected_macro_if_present     "${file}"     "___PENELOPE_COMMON_GUARDS___"     write_common_guards_block_bash     write_common_guards_block_sh
}

# inject_source_common_macro_if_present() - Replace ___PENELOPE_SOURCE_COMMON___ macro
# Replaces the macro with a source statement that loads penelope-common.sh
# Prefers a sibling penelope-common.sh from the current bundle/workdir/recovery copy
# and falls back to the installed system library only when no local sibling copy exists.
# Does nothing if macro token not present in file
#
# Usage: inject_source_common_macro_if_present <file>
# Example:
#   cat > script.sh <<'EOF'
#   #!/usr/bin/env bash
#   ___PENELOPE_SOURCE_COMMON___
#   log "Hello"
#   EOF
#   inject_source_common_macro_if_present script.sh
#   # script.sh now contains source statement instead of macro
inject_source_common_macro_if_present() {
  local file="${1:?file required}"
  grep -q '^___PENELOPE_SOURCE_COMMON___$' "${file}" || return 0

  local block
  block="$(mktemp "${TMPDIR:-/tmp}/penelope-source.XXXXXX")"

  cat > "${block}" <<'EOF_SOURCE_COMMON'
# Source Penelope common library
# Fallback order: sibling bundle/workdir copy -> installed system copy -> error
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"
elif [[ -f "/usr/local/lib/penelope/common.sh" ]]; then
  source "/usr/local/lib/penelope/common.sh"
else
  >&2 echo "[$(date +'%H:%M:%S')] ERROR: penelope-common.sh not found"
  >&2 echo "  Expected locations:"
  >&2 echo "    \$(dirname \"\${BASH_SOURCE[0]}\")/penelope-common.sh"
  >&2 echo "    /usr/local/lib/penelope/common.sh"
  exit 1
fi
EOF_SOURCE_COMMON

  inject_block_into_file "${file}" "___PENELOPE_SOURCE_COMMON___" "${block}"
  rm -f "${block}" 2>/dev/null || true

  # Verify macro was replaced
  if grep -q '^___PENELOPE_SOURCE_COMMON___$' "${file}"; then
    die "Macro token not replaced: ___PENELOPE_SOURCE_COMMON___ (${file})"
  fi
}

# inject_known_macros_if_present() - Replace all known Penelope macros in one call
# Convenience function that calls all macro injection functions in sequence
#
# Supported macros:
#   ___PENELOPE_SOURCE_COMMON___   - Source statement for common library (recommended)
#   ___PENELOPE_LOG_FUNCTIONS___   - Inline logging functions (legacy)
#   ___PENELOPE_COMMON_GUARDS___   - Inline error guards (legacy)
#
# Usage: inject_known_macros_if_present <file>
# Example:
#   cat > script.sh <<'EOF'
#   #!/usr/bin/env bash
#   ___PENELOPE_SOURCE_COMMON___
#   log "Script started"
#   EOF
#   inject_known_macros_if_present script.sh
#   # All macros are now replaced with actual code
inject_known_macros_if_present() {
  local file="${1:?file required}"
  inject_source_common_macro_if_present "${file}"
  inject_log_functions_macro_if_present "${file}"
  inject_common_guards_macro_if_present "${file}"
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

# validate_shell_script() - Validate bash/sh script syntax
# Uses bash -n for syntax checking without execution
# Dies if syntax errors found
#
# Usage: validate_shell_script <file>
validate_shell_script() {
  local file="${1:?file required}"

  [[ -f "${file}" ]] || die "validate_shell_script: file not found: ${file}"

  local shebang
  shebang="$(head -n 1 "${file}" || true)"

  case "${shebang}" in
    '#!/usr/bin/env bash'|'#!/bin/bash'|'#!/usr/bin/bash')
      local syntax_output=""
      if ! syntax_output="$(bash -n "${file}" 2>&1)"; then
        die "Bash syntax error in ${file}: ${syntax_output}"
      fi
      ;;
    '#!/bin/sh')
      # Use bash in POSIX mode for sh scripts
      local syntax_output=""
      if ! syntax_output="$(bash --posix -n "${file}" 2>&1)"; then
        die "Shell syntax error in ${file}: ${syntax_output}"
      fi
      ;;
    *)
      warn "validate_shell_script: unsupported shebang, skipping: ${shebang} (${file})"
      ;;
  esac
}

# validate_systemd_unit() - Validate systemd unit file
# Uses systemd-analyze verify if available
# Dies if validation fails
#
# Usage: validate_systemd_unit <file>
validate_systemd_unit() {
  local file="${1:?file required}"
  local verify_output=""

  [[ -f "${file}" ]] || die "validate_systemd_unit: file not found: ${file}"

  if ! command -v systemd-analyze >/dev/null 2>&1; then
    warn "validate_systemd_unit: systemd-analyze not available, skipping validation"
    return 0
  fi

  if ! verify_output="$(systemd-analyze verify "${file}" 2>&1)"; then
    if [[ -n "${verify_output}" ]]; then
      while IFS= read -r line; do
        warn "systemd-analyze verify: ${line}"
      done <<< "${verify_output}"
    fi
    die "Invalid systemd unit: ${file}"
  fi
}

# validate_generated_file() - Basic validation that file exists and is non-empty
# Dies if file missing or empty
#
# Usage: validate_generated_file <file>
validate_generated_file() {
  local file="${1:?file required}"

  [[ -f "${file}" ]] || die "Generated file not found: ${file}"
  [[ -s "${file}" ]] || die "Generated file is empty: ${file}"
}

# ensure_no_unexpanded_tokens() - Check for unreplaced macro tokens
# Dies if any ___PENELOPE_*___ tokens remain in file
#
# Usage: ensure_no_unexpanded_tokens <file>
ensure_no_unexpanded_tokens() {
  local file="${1:?file required}"

  local token_re='___PENELOPE_[A-Z0-9_]+___'
  local standalone_re="^[[:space:]]*${token_re}[[:space:]]*$"
  local comment_re="^[[:space:]]*#.*${token_re}"

  # 1) Hard error: placeholder lines that should have been expanded (standalone token lines).
  if grep -nE "${standalone_re}" "${file}" >/dev/null 2>&1; then
    warn "Unexpanded macro token line(s) found in ${file}:"
    grep -nE "${standalone_re}" "${file}" >&2 || true
    die "File contains unexpanded macro token line(s): ${file}"
  fi

  # 2) Hard error: macro token strings in comments (avoid confusion / false assumptions).
  if grep -nE "${comment_re}" "${file}" >/dev/null 2>&1; then
    warn "Macro token string(s) found inside comment line(s) in ${file} (remove token mentions from comments):"
    grep -nE "${comment_re}" "${file}" >&2 || true
    die "File contains macro token string(s) in comments: ${file}"
  fi

  # 3) Catch-all: any remaining macro token strings in non-comment context.
  if grep -qE "${token_re}" "${file}"; then
    warn "Macro token string(s) found in ${file}:"
    grep -nE "${token_re}" "${file}" >&2 || true
    die "File contains macro token string(s): ${file}"
  fi
}

# scan_tree_for_unexpanded_tokens() - Recursively scan a directory tree for any
# unexpanded Penelope macro tokens.
#
# This is intended for post-install validation on the full system (not initramfs).
#
# Usage: scan_tree_for_unexpanded_tokens <rootdir>
scan_tree_for_unexpanded_tokens() {
  local root="${1:?rootdir required}"

  [[ -d "${root}" ]] || return 0

  local token_re='___PENELOPE_[A-Z0-9_]+___'

  if ! command -v grep >/dev/null 2>&1; then
    warn "scan_tree_for_unexpanded_tokens: grep not available; skipping scan for ${root}"
    return 0
  fi

  # -R recursive, -n line numbers, -I ignore binary, -E extended regex
  if grep -R -n -I -E "${token_re}" "${root}" >/dev/null 2>&1; then
    warn "Unexpanded token strings detected under: ${root}"
    grep -R -n -I -E "${token_re}" "${root}" >&2 || true
    return 1
  fi
  return 0
}




# scan_initramfs_for_unguarded_commands() - Scan Penelope-managed initramfs
# scripts/hooks for risky command usage that may break boot on minimal initramfs
# images.
#
# Rationale:
#   Remote-first means the system may become physically inaccessible after
#   deployment. Therefore initramfs scripts must not depend on utilities that
#   are often missing from minimal initramfs images.
#
# Policy:
#   - Only Penelope-managed files are checked:
#       * filename contains "penelope" OR
#       * file content contains a "penelope" marker
#   - Risky commands MUST be guarded by an explicit availability check:
#       if have <cmd>; then <OMITTED>; fi
#
# Risky commands checked:
#   head tail awk sed cut grep
#
# The default scan roots are:
#   <root>/etc/initramfs-tools/scripts
#   <root>/etc/initramfs-tools/hooks
#
# Usage: scan_initramfs_for_unguarded_commands <rootdir>
scan_initramfs_for_unguarded_commands() {
  local root="${1:?rootdir required}"

  local scripts_dir="${root%/}/etc/initramfs-tools/scripts"
  local hooks_dir="${root%/}/etc/initramfs-tools/hooks"

  # No-op if initramfs trees do not exist
  [[ -d "${scripts_dir}" || -d "${hooks_dir}" ]] || return 0

  if ! command -v awk >/dev/null 2>&1; then
    warn "scan_initramfs_for_unguarded_commands: awk not available; skipping"
    return 0
  fi
  if ! command -v find >/dev/null 2>&1; then
    warn "scan_initramfs_for_unguarded_commands: find not available; skipping"
    return 0
  fi
  if ! command -v grep >/dev/null 2>&1; then
    local _strict
    _strict="${PENELOPE_INITRAMFS_RISK_STRICT:-0}"
    if [[ "${_strict}" == "1" ]]; then
      warn "scan_initramfs_for_unguarded_commands: grep not available; strict mode requires grep"
      return 1
    fi
    warn "scan_initramfs_for_unguarded_commands: grep not available; skipping"
    return 0
  fi

  local strict
  strict="${PENELOPE_INITRAMFS_RISK_STRICT:-0}"

  local tmp_out
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-risk-out.XXXXXX")"

  local tmp_err
  tmp_err="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-risk-err.XXXXXX")"

  local tmp_awk
  tmp_awk="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-risk-awk.XXXXXX")"

  local fatal_rc=0
  local warn_rc=0

  cat >"${tmp_awk}" <<'EOF_AWK'
BEGIN {
  sp=0;
  bad_fatal=0;
  legacy_tick=sprintf("%c", 96);
}
function push(x) { stack[++sp]=x; }
function pop_frame() {
  while (sp > 0 && stack[sp] != "IF") sp--;
  if (sp > 0 && stack[sp] == "IF") sp--;
}
function guarded(cmd, i) {
  for (i=sp; i>=1; i--) if (stack[i] == cmd) return 1;
  return 0;
}
function mark_if_guards(l) {
  # Accept both "have <cmd>" and "command -v <cmd>" style guards.
  if (l ~ /have[[:space:]]+head([^[:alnum:]_]|$)/ || l ~ /command[[:space:]]+-v[[:space:]]+head([^[:alnum:]_]|$)/) push("head");
  if (l ~ /have[[:space:]]+tail([^[:alnum:]_]|$)/ || l ~ /command[[:space:]]+-v[[:space:]]+tail([^[:alnum:]_]|$)/) push("tail");
  if (l ~ /have[[:space:]]+awk([^[:alnum:]_]|$)/  || l ~ /command[[:space:]]+-v[[:space:]]+awk([^[:alnum:]_]|$)/)  push("awk");
  if (l ~ /have[[:space:]]+sed([^[:alnum:]_]|$)/  || l ~ /command[[:space:]]+-v[[:space:]]+sed([^[:alnum:]_]|$)/)  push("sed");
  if (l ~ /have[[:space:]]+cut([^[:alnum:]_]|$)/  || l ~ /command[[:space:]]+-v[[:space:]]+cut([^[:alnum:]_]|$)/)  push("cut");
  if (l ~ /have[[:space:]]+grep([^[:alnum:]_]|$)/ || l ~ /command[[:space:]]+-v[[:space:]]+grep([^[:alnum:]_]|$)/) push("grep");
}
function print_hit(cmd, ln) {
  printf "%s:%d: unguarded %s: %s\n", file, NR, cmd, ln
}
{
  line=$0
  sub(/\r$/, "", line)

  # ignore full-line comments
  if (line ~ /^[[:space:]]*#/) next

  # ignore "for x in a b c" command-lists (do not execute those tokens)
  if (line ~ /^[[:space:]]*for[[:space:]]+[^ ]+[[:space:]]+in[[:space:]]+/) next

  # detect if/elif guards
  if (line ~ /^[[:space:]]*(if|elif)[[:space:]]+/) {
    push("IF")
    mark_if_guards(line)
  }

  # detect command usage (word-ish)
  if (line ~ /(^|[[:space:];|&])head([[:space:]]|$)/ || line ~ /\$\([[:space:]]*head([[:space:]]|$)/ || line ~ (legacy_tick "head([[:space:]]|$)")) {
    if (!guarded("head")) {
      print_hit("head", line)
      bad_fatal=1
    }
  }
  if (line ~ /(^|[[:space:];|&])tail([[:space:]]|$)/ || line ~ /\$\([[:space:]]*tail([[:space:]]|$)/ || line ~ (legacy_tick "tail([[:space:]]|$)")) {
    if (!guarded("tail")) {
      print_hit("tail", line)
      bad_fatal=1
    }
  }

  # The following are recommended to guard, but not fatal by default
  if (line ~ /(^|[[:space:];|&])awk([[:space:]]|$)/ || line ~ /\$\([[:space:]]*awk([[:space:]]|$)/ || line ~ (legacy_tick "awk([[:space:]]|$)")) {
    if (!guarded("awk")) {
      print_hit("awk", line)
    }
  }
  if (line ~ /(^|[[:space:];|&])sed([[:space:]]|$)/ || line ~ /\$\([[:space:]]*sed([[:space:]]|$)/ || line ~ (legacy_tick "sed([[:space:]]|$)")) {
    if (!guarded("sed")) {
      print_hit("sed", line)
    }
  }
  if (line ~ /(^|[[:space:];|&])cut([[:space:]]|$)/ || line ~ /\$\([[:space:]]*cut([[:space:]]|$)/ || line ~ (legacy_tick "cut([[:space:]]|$)")) {
    if (!guarded("cut")) {
      print_hit("cut", line)
    }
  }
  if (line ~ /(^|[[:space:];|&])grep([[:space:]]|$)/ || line ~ /\$\([[:space:]]*grep([[:space:]]|$)/ || line ~ (legacy_tick "grep([[:space:]]|$)")) {
    if (!guarded("grep")) {
      print_hit("grep", line)
    }
  }

  # pop on fi
  if (line ~ /^[[:space:]]*fi([[:space:];]|$)/) pop_frame()
}
END { exit bad_fatal }
EOF_AWK

  _penelope_managed_file() {
    local f="$1"
    local b="${f##*/}"
    if [[ "${b}" == *penelope* ]]; then
      return 0
    fi
    if grep -qi "penelope" "${f}" 2>/dev/null; then
      return 0
    fi
    return 1
  }

  _scan_one_file() {
    local f="$1"
    awk -v file="$f" -f "${tmp_awk}" "$f" >>"${tmp_out}" 2>>"${tmp_err}"
    return $?
  }

  # Scan initramfs scripts (boot-critical) - unguarded head/tail are fatal
  if [[ -d "${scripts_dir}" ]]; then
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      _penelope_managed_file "$f" || continue
      if ! _scan_one_file "$f"; then
        fatal_rc=1
      fi
    done < <(find "${scripts_dir}" -type f -print0 2>/dev/null || true)
  fi

  # Scan initramfs hooks (build-time) - unguarded head/tail are warnings only
  if [[ -d "${hooks_dir}" ]]; then
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      _penelope_managed_file "$f" || continue
      if ! _scan_one_file "$f"; then
        warn_rc=1
      fi
    done < <(find "${hooks_dir}" -type f -print0 2>/dev/null || true)
  fi

  if [[ -s "${tmp_err}" ]]; then
    warn "Initramfs risk scan: scanner stderr output detected (treating as fatal):"
    cat "${tmp_err}" >&2 || true
    fatal_rc=1
  fi

  if [[ -s "${tmp_out}" ]]; then
    warn "Initramfs risk scan findings (Penelope-managed initramfs scripts/hooks):"
    warn "Commands checked: head tail awk sed cut grep"
    if [[ "${strict}" == "1" ]]; then
      warn "Strict mode enabled: ANY unguarded usage of these commands is fatal."
      fatal_rc=1
    else
      warn "Fatal (scripts only): head tail"
      warn "Recommended: guard awk sed cut grep in boot-critical paths"
    fi
    cat "${tmp_out}" >&2 || true
  fi

  rm -f "${tmp_out}" "${tmp_err}" "${tmp_awk}" || true

  if [[ "${strict}" == "1" && ${warn_rc} -ne 0 ]]; then
    fatal_rc=1
  fi

  if [[ ${fatal_rc} -ne 0 ]]; then
    warn "Initramfs risk scan failed: unguarded risky command usage detected in Penelope-managed initramfs scripts/hooks"
    warn "Rule: risky commands in initramfs scripts/hooks MUST be wrapped by: if have <cmd>; then <OMITTED>; fi"
    return 1
  fi

  if [[ ${warn_rc} -ne 0 ]]; then
    warn "Initramfs risk scan: warnings detected in initramfs hooks (build-time)."
  fi

  return 0
}
# penelope_initramfs_strict_smoke_test() - Strict validation of initramfs scripts/hooks
# Ensures:
# - Syntax of Penelope-managed initramfs scripts/hooks is valid for /bin/sh
# - Risk scan for unguarded risky commands has 0 findings (strict)
# Usage: penelope_initramfs_strict_smoke_test [rootdir]
penelope_initramfs_strict_smoke_test() {
  local root="${1:-/}"
  root="${root%/}"
  [[ -n "${root}" ]] || root="/"

  log "-> Strict smoke test: initramfs scripts/hooks syntax + risk scan (0 findings required)"

  local scripts_dir="${root}/etc/initramfs-tools/scripts"
  local hooks_dir="${root}/etc/initramfs-tools/hooks"

  if [[ ! -d "${scripts_dir}" && ! -d "${hooks_dir}" ]]; then
    warn "Strict smoke test: initramfs directories not found under: ${root} (skipping)"
    return 0
  fi

  local err
  err="$(mktemp "${TMPDIR:-/tmp}/penelope-initramfs-smoke.XXXXXX")"
  : >"${err}"

  local fail=0
  local f

  while IFS= read -r -d '' f; do
    [[ -f "${f}" ]] || continue

    # Only check Penelope-managed files (path contains 'penelope' OR content contains marker)
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
  done < <(find "${scripts_dir}" "${hooks_dir}" -type f -print0 2>/dev/null || true)

  if [[ "${fail}" -ne 0 ]]; then
    warn "initramfs syntax smoke test collected errors:"
    cat "${err}" >&2 || true
    rm -f "${err}" 2>/dev/null || true
    die "initramfs syntax smoke test failed"
  fi

  rm -f "${err}" 2>/dev/null || true

  # Risk scan must be strictly clean (0 findings).
  export PENELOPE_INITRAMFS_RISK_STRICT=1
  if ! scan_initramfs_for_unguarded_commands "${root}"; then
    die "initramfs risk scan strict failed (unguarded risky commands detected)"
  fi

  log "Strict smoke test OK (syntax=ok, risk_scan=0_findings)"
}



# ============================================================================
# SOURCE PREFLIGHT
# ============================================================================
# penelope_preflight_scan_script_source() - scan a script source for truncation
# markers and non-ASCII bytes that often indicate copy/paste or transport damage.
#
# Usage: penelope_preflight_scan_script_source <script-path>
# Return: 0 if clean (or scan impossible but non-fatal), 1 on findings
penelope_preflight_scan_script_source() {
  local self_path="${1:-}"
  local found=0
  local three_dots
  local unicode_ellipsis

  three_dots="$(printf '%s%s%s' '.' '.' '.')"
  unicode_ellipsis="$(printf '\342\200\246')"

  if [[ -z "${self_path}" || ! -f "${self_path}" ]]; then
    warn "preflight: cannot locate script file for scanning: ${self_path:-<empty>}"
    return 0
  fi

  if grep -nF "${three_dots}" "${self_path}" >/dev/null 2>&1; then
    warn "preflight: found forbidden triple-dot marker in source (showing first 20 matches)"
    grep -nF "${three_dots}" "${self_path}" | head -n 20 >&2 || true
    found=1
  fi

  if grep -nF "${unicode_ellipsis}" "${self_path}" >/dev/null 2>&1; then
    warn "preflight: found forbidden unicode ellipsis in source (showing first 20 matches)"
    grep -nF "${unicode_ellipsis}" "${self_path}" | head -n 20 >&2 || true
    found=1
  fi

  if echo "x" | grep -P 'x' >/dev/null 2>&1; then
    if grep -nP '[^\x00-\x7F]' "${self_path}" >/dev/null 2>&1; then
      warn "preflight: found non-ASCII bytes in source (showing first 20 matches)"
      grep -nP '[^\x00-\x7F]' "${self_path}" | head -n 20 >&2 || true
      found=1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PY_PREFLIGHT_ASCII' "${self_path}"; then
import sys
p = sys.argv[1]
data = open(p, 'rb').read()
sys.exit(0 if all(b < 128 for b in data) else 1)
PY_PREFLIGHT_ASCII
      :
    else
      warn "preflight: found non-ASCII bytes in source (python3 scan)"
      found=1
    fi
  else
    warn "preflight: cannot scan for non-ASCII bytes (no grep -P and no python3); skipping"
  fi

  (( found == 0 ))
}


# ============================================================================
# STRING MANIPULATION UTILITIES
# ============================================================================

# escape_sed_replacement() - Escape string for use as sed replacement text
# Escapes backslashes, forward slashes, and ampersands
#
# Usage: escaped=$(escape_sed_replacement "string/with&specials")
escape_sed_replacement() {
  local str="${1:-}"
  # Escape backslashes first, then forward slashes, then ampersands
  str="${str//\\/\\\\}"
  str="${str//\//\\/}"
  str="${str//&/\\&}"
  printf '%s\n' "${str}"
}

# apply_placeholders() - Replace placeholders in file with actual values
# Performs sed substitutions for common Penelope variables
#
# Usage: apply_placeholders <file> <name> <value> [<name2> <value2> <MORE_PAIRS>]
# Example: apply_placeholders script.sh TARGET_HOST penelope VERSION 1.0.0
apply_placeholders() {
  local file="${1:?file required}"

  [[ -f "${file}" ]] || die "apply_placeholders: file not found: ${file}"

  # Substitute the current project-wide placeholder set on a same-directory
  # work copy first, then publish with one final mv. This keeps the original
  # file intact if any placeholder value, sed operation, or validation fails.
  local file_dir=""
  local file_base=""
  local work_file=""
  file_dir="$(dirname -- "${file}")"
  file_base="$(basename -- "${file}")"
  work_file="$(mktemp "${file_dir}/.${file_base}.penelope.XXXXXX")" || die "apply_placeholders: failed to create temporary file for ${file}"
  cp -p -- "${file}" "${work_file}" || {
    rm -f "${work_file}" 2>/dev/null || true
    die "apply_placeholders: failed to copy ${file} to temporary file"
  }

  # Prefer an explicitly chosen dropbear port, otherwise fall back to default.
  local dropbear_port="${DROPBEAR_PORT:-${DROPBEAR_PORT_DEFAULT:-}}"

  # Target hostname (do NOT use/override external env var "HOST")
  local penelope_host="${TARGET_HOST:-}"

  local -a placeholder_specs=(
    "___PENELOPE_HOST___" "${penelope_host}" "TARGET_HOST"
    "___PENELOPE_TARGET_HOST___" "${penelope_host}" "TARGET_HOST"
    "___PENELOPE_ADMIN_USER___" "${ADMIN_USER:-}" "ADMIN_USER"
    "___PENELOPE_NET_MODULES___" "${NET_MODULES:-}" "NET_MODULES"
    "___PENELOPE_DROPBEAR_PORT___" "${dropbear_port:-}" "DROPBEAR_PORT/DROPBEAR_PORT_DEFAULT"
    "___PENELOPE_DROPBEAR_FORCE_CMD___" "${DROPBEAR_FORCE_CMD:-}" "DROPBEAR_FORCE_CMD"
    "___PENELOPE_ROOT_UUID___" "${ROOT_UUID:-}" "ROOT_UUID"
    "___PENELOPE_HOME_UUID___" "${HOME_UUID:-}" "HOME_UUID"
    "___PENELOPE_ARCHIVE_UUID___" "${ARCHIVE_UUID:-}" "ARCHIVE_UUID"
    "___PENELOPE_BACKUP_UUID___" "${BACKUP_UUID:-}" "BACKUP_UUID"
    "___PENELOPE_BOOT_UUID___" "${BOOT_UUID:-}" "BOOT_UUID"
    "___PENELOPE_EFI_UUID___" "${EFI_UUID:-}" "EFI_UUID"
    "___PENELOPE_MAPPER_ROOT___" "${MAPPER_ROOT:-}" "MAPPER_ROOT"
    "___PENELOPE_MAPPER_HOME___" "${MAPPER_HOME:-}" "MAPPER_HOME"
    "___PENELOPE_MAPPER_ARCHIVE___" "${MAPPER_ARCHIVE:-}" "MAPPER_ARCHIVE"
    "___PENELOPE_LUKS_ROOT_UUID___" "${LUKS_ROOT_UUID:-}" "LUKS_ROOT_UUID"
    "___PENELOPE_LUKS_HOME_UUID___" "${LUKS_HOME_UUID:-}" "LUKS_HOME_UUID"
    "___PENELOPE_LUKS_ARCHIVE_UUID___" "${LUKS_ARCHIVE_UUID:-}" "LUKS_ARCHIVE_UUID"
  )

  _repl_if_present() {
    local token="$1"
    local val="$2"
    local name="$3"

    if grep -q "${token}" "${work_file}"; then
      [[ -n "${val}" ]] || {
        rm -f "${work_file}" 2>/dev/null || true
        die "placeholder present but variable is empty: ${name} (token ${token}) in ${file}"
      }
      local esc
      esc="$(escape_sed_replacement "${val}")"
      sed -i "s/${token}/${esc}/g" "${work_file}" || {
        rm -f "${work_file}" 2>/dev/null || true
        die "apply_placeholders: failed to replace ${token} in ${file}"
      }
    fi
  }

  local i token val name
  for (( i=0; i<${#placeholder_specs[@]}; i+=3 )); do
    token="${placeholder_specs[i]}"
    val="${placeholder_specs[i+1]}"
    name="${placeholder_specs[i+2]}"
    _repl_if_present "${token}" "${val}" "${name}"
  done

  # Ensure that no placeholders remain in the work copy before publishing it.
  for (( i=0; i<${#placeholder_specs[@]}; i+=3 )); do
    token="${placeholder_specs[i]}"
    if grep -q "${token}" "${work_file}"; then
      rm -f "${work_file}" 2>/dev/null || true
      die "placeholder was not substituted: ${token} in ${file}"
    fi
  done

  mv -f -- "${work_file}" "${file}" || {
    rm -f "${work_file}" 2>/dev/null || true
    die "apply_placeholders: failed to publish temporary file for ${file}"
  }
}


# ============================================================================
# LIBRARY INITIALIZATION
# ============================================================================

# Verify this library was sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cat >&2 <<'USAGE'
ERROR: penelope-common.sh must be sourced, not executed directly.

Usage:
  source /path/to/penelope-common.sh

Example script:
  #!/usr/bin/env bash
  source "$(dirname "${BASH_SOURCE[0]}")/penelope-common.sh"

  require_root
  log "Script started"
  # <YOUR_CODE_HERE>

Available functions:
  Logging:        log, warn, die
  Utilities:      require_root, require_cmd, ensure_dir, ensure_file
                  have, apt_install, read_kv_value_from_file
                  read_kv_value_from_file_or_default
                  is_mounted, generate_pw, part_dev
                  ensure_penelope_run_dir, acquire_pid_dir_lock
                  release_pid_dir_lock, install_file_from_heredoc
                  penelope_refresh_installed_common_lib
  Heredoc Gen:    write_log_functions_block_{bash,sh}
                  write_common_guards_block_{bash,sh}
  Macro Inject:   inject_block_into_file
                  inject_log_functions_macro_if_present
                  inject_common_guards_macro_if_present
                  inject_source_common_macro_if_present
                  inject_known_macros_if_present
  Validation:     validate_shell_script, validate_systemd_unit
                  validate_generated_file, ensure_no_unexpanded_tokens
  Preflight:      penelope_preflight_scan_script_source
  String Utils:   escape_sed_replacement, apply_placeholders
USAGE
  printf >&2 "\nVersion: %s\n" "${PENELOPE_COMMON_VERSION}"
  exit 1
fi

# Library initialization is intentionally silent by default.
# Callers own user-facing startup/status output.


# ============================================================================
# APT MIRROR SELECTION (Ubuntu)
# ============================================================================
# Purpose:
# - Allow installers to select a working and fast Ubuntu mirror without external tools.
# - Operator can override via env var PENELOPE_APT_MIRROR.
#
# Contract:
# - Input may be a hostname (example: archive.ubuntu.com) or a full URL.
# - Output is a normalized base URL that ends with "/ubuntu" (no trailing slash).
# - On failure to probe mirrors, returns a safe default (archive.ubuntu.com).
#
# Usage:
#   apt_mirror="$(apt_select_ubuntu_mirror "${PENELOPE_APT_MIRROR:-}" "noble")"
#   echo "deb ${apt_mirror} noble main restricted universe multiverse" > /etc/apt/sources.list

apt_normalize_ubuntu_mirror() {
  local in="${1:-}"
  in="${in#"${in%%[![:space:]]*}"}"
  in="${in%"${in##*[![:space:]]}"}"

  if [[ -z "${in}" ]]; then
    echo ""
    return 0
  fi

  local url="${in}"
  case "${url}" in
    http://*|https://*) ;;
    *) url="http://${url}" ;;
  esac

  url="${url%/}"

  case "${url}" in
    */ubuntu) ;;
    */ubuntu/*) url="${url%%/ubuntu/*}/ubuntu" ;;
    *) url="${url}/ubuntu" ;;
  esac

  url="${url%/}"
  echo "${url}"
}

apt_mirror_probe_selfcheck() {
  # Local self-check only (no network):
  # - Log whether curl is available and its resolved path.
  # - Installer live deps establish curl as the deterministic HTTP probe tool.
  # - Do not opportunistically switch tools.
  local curl_path
  curl_path="$(command -v curl 2>/dev/null || true)"

  if [[ -n "${curl_path}" ]]; then
    log "apt_mirror_probe_selfcheck: curl=present path=${curl_path}"
  else
    log "apt_mirror_probe_selfcheck: curl=missing"
  fi
}

apt_probe_ubuntu_mirror_time() {
  local base="${1:?base required}"
  local suite="${2:?suite required}"
  local url="${base%/}/dists/${suite}/InRelease"

  # Deterministic probe logging contract:
  # - Always log tool + rc (+ time if available) for each probe attempt.
  # - Use curl only; the installer installs/checks curl explicitly.
  # - Force IPv4 (-4) to avoid flaky IPv6 during early boot on some networks.

  local rc t

  if ! command -v curl >/dev/null 2>&1; then
    log "apt_mirror_probe: tool=curl rc=127 t=? url=${url}"
    return 1
  fi

  if t="$(curl -4 -L --fail -s -o /dev/null \
    -w "%{time_total}" \
    --connect-timeout 2 \
    --max-time 8 \
    --retry 5 \
    --retry-delay 0 \
    "${url}" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi

  # Note: curl returns non-zero on failure; but we also guard against empty time output.
  if [[ ${rc} -ne 0 || -z "${t}" ]]; then
    log "apt_mirror_probe: tool=curl rc=${rc} t=? url=${url}"
    return 1
  fi

  log "apt_mirror_probe: tool=curl rc=0 t=${t} url=${url}"
  echo "${t}"
  return 0
}



apt_wait_for_network_ready() {
  local max_wait="${1:-20}"
  local dns_host="${2:-archive.ubuntu.com}"

  local i=0
  while [[ ${i} -lt ${max_wait} ]]; do
    local route_ok="0"
    local dns_ok="0"

    if command -v ip >/dev/null 2>&1; then
      if ip -4 route show default 2>/dev/null | grep -q '^default'; then
        route_ok="1"
      fi
    else
      # If 'ip' is unavailable, do not block on route detection.
      route_ok="1"
    fi

    if command -v getent >/dev/null 2>&1; then
      if getent ahostsv4 "${dns_host}" >/dev/null 2>&1; then
        dns_ok="1"
      fi
    elif command -v nslookup >/dev/null 2>&1; then
      if nslookup "${dns_host}" >/dev/null 2>&1; then
        dns_ok="1"
      fi
    else
      # No resolver tooling available: avoid blocking.
      dns_ok="1"
    fi

    if [[ "${route_ok}" == "1" && "${dns_ok}" == "1" ]]; then
      return 0
    fi

    sleep 1
    i=$((i + 1))
  done

  return 1
}

apt_wait_for_http_ready() {
  local max_wait="${1:-20}"
  local url="${2:?url required}"

  # Only used in Live environment before live dependencies may have been refreshed.
  # If curl is not present yet, do not block; later live dependency setup installs/checks curl.
  local i=0
  if ! command -v curl >/dev/null 2>&1; then
    log "apt_wait_for_http_ready: curl=missing; skipping HTTP readiness wait for ${url}"
    return 0
  fi

  while [[ ${i} -lt ${max_wait} ]]; do
    if curl -4 -L --fail -s -o /dev/null \
      --connect-timeout 2 \
      --max-time 6 \
      "${url}" 2>/dev/null; then
      return 0
    fi

    sleep 1
    i=$((i + 1))
  done

  return 1
}



apt_select_ubuntu_mirror() {
  local override="${1:-}"
  local suite="${2:-noble}"

  local def
  def="$(apt_normalize_ubuntu_mirror "archive.ubuntu.com")"

  local o
  o="$(apt_normalize_ubuntu_mirror "${override}")"
  if [[ -n "${o}" ]]; then
    echo "${o}"
    return 0
  fi

    # Local probe tool self-check (no network).
  apt_mirror_probe_selfcheck

# Wait for default route + DNS to be usable (avoid false negatives right after boot/link-up).
  if ! apt_wait_for_network_ready 25 "archive.ubuntu.com"; then
    warn "apt_select_ubuntu_mirror: network not ready after wait; continuing with best-effort probing"
  fi

  # Also ensure that basic outbound HTTP works before we measure mirrors.
  # This avoids the common "first run after boot" failure mode where DNS is up but HTTP fails transiently.
  if ! apt_wait_for_http_ready 25 "${def}/dists/${suite}/InRelease"; then
    warn "apt_select_ubuntu_mirror: HTTP not ready after wait; continuing with best-effort probing"
  fi

  # Give network stacks a brief chance to settle (ARP cache, resolver warmup).
  sleep 2

  # Candidate list: keep the default globally valid and allow operators to
  # provide site-local mirrors explicitly through PENELOPE_MIRROR_CANDIDATES.
  # The variable accepts whitespace- or comma-separated host/path entries.
  local candidates=()
  local configured_candidates="${PENELOPE_MIRROR_CANDIDATES:-}"
  local configured_candidate=""
  if [[ -n "${configured_candidates}" ]]; then
    while IFS= read -r configured_candidate; do
      [[ -n "${configured_candidate}" ]] || continue
      candidates+=("${configured_candidate}")
    done < <(printf '%s
' "${configured_candidates}" | tr ',[:space:]' '
')
  fi
  candidates+=("archive.ubuntu.com")

  local best_mirror=""
  local best_time=""

  local c base t
  local pass
  for pass in 1 2; do
    best_mirror=""
    best_time=""

    for c in "${candidates[@]}"; do
      base="$(apt_normalize_ubuntu_mirror "${c}")"
      [[ -n "${base}" ]] || continue

      if t="$(apt_probe_ubuntu_mirror_time "${base}" "${suite}")"; then
        # Compare floats using awk if available, otherwise first hit wins.
        if [[ -z "${best_time}" ]]; then
          best_time="${t}"
          best_mirror="${base}"
          continue
        fi

        if command -v awk >/dev/null 2>&1; then
          if awk -v a="${t}" -v b="${best_time}" 'BEGIN { exit !(a < b) }'; then
            best_time="${t}"
            best_mirror="${base}"
          fi
        fi
      fi
    done

    if [[ -n "${best_mirror}" ]]; then
      log "apt_select_ubuntu_mirror: suite=${suite} selected=${best_mirror} time_total=${best_time}s"
      echo "${best_mirror}"
      return 0
    fi

    # If we got here, probing failed across the board. This can still happen during early-boot transitions.
    # Retry once after a short pause instead of immediately falling back to the default mirror.
    warn "apt_select_ubuntu_mirror: no reachable mirror via probe (pass=${pass}); retrying"
    sleep 3
  done

  warn "apt_select_ubuntu_mirror: no reachable mirror via probe; using default ${def}"
  echo "${def}"
  return 0
}


