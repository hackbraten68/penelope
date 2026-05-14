#!/usr/bin/env bash
# penelope-walkthrough-assistant.sh
#
# Optional operator-guided assistant for the canonical Penelope walkthrough.
#
# Purpose:
# - print screen-by-screen next steps for the current default operator flow
# - keep the core setup scripts as the real execution surface
# - avoid storing secrets or other sensitive runtime state
#
# This assistant is intentionally phase-oriented and idempotent:
# - live-usb  -> guidance for the Ubuntu Live-USB session before the first reboot
# - installed -> guidance for the installed system after reboot / remote unlock
# - status    -> print detected sibling bundle assets
#
# It does not execute destructive actions itself.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_RUNTIME_PATH="${SCRIPT_DIR}/penelope-common.sh"

find_latest_versioned_shell_file() {
  local dir="${1:?directory required}"
  local prefix="${2:?prefix required}"

  find "${dir}" -maxdepth 1 -type f -name "${prefix}-*.sh" -printf '%f\n' 2>/dev/null     | awk -v prefix="${prefix}" '
        $0 ~ ("^" prefix "-[0-9]+(\\.[0-9]+)+\\.sh$") { print }
      '     | LC_ALL=C sort -V     | tail -n 1 || true
}

if [[ ! -f "${COMMON_RUNTIME_PATH}" ]]; then
  VERSIONED_COMMON_PATH="$(find_latest_versioned_shell_file "${SCRIPT_DIR}" 'penelope-common')"
  if [[ -n "${VERSIONED_COMMON_PATH}" ]]; then
    cat >&2 <<EOF_MISSING_COMMON
ERROR: Runnable sibling penelope-common.sh is missing in this bundle/workdir.

This assistant expects the assembled runnable bundle/workdir.
Refresh the runtime library first, then rerun:
  cp -f ./${VERSIONED_COMMON_PATH} ./penelope-common.sh

If executable bits were not preserved after extraction, run this once too:
  chmod +x ./*.sh
EOF_MISSING_COMMON
  else
    cat >&2 <<EOF_MISSING_COMMON
ERROR: Missing sibling penelope-common.sh in this bundle/workdir.

Provide a matching penelope-common.sh beside the bundle scripts before rerunning this assistant.
EOF_MISSING_COMMON
  fi
  exit 127
fi

# shellcheck source=/dev/null
source "${COMMON_RUNTIME_PATH}"

readonly VERSION="0.0.51"
BUNDLE_DIR="${SCRIPT_DIR}"
BOOTSTRAP_CONFIG_FILE="${SCRIPT_DIR}/penelope-install.bootstrap.conf"
LAYOUT_CONFIG_FILE="${SCRIPT_DIR}/penelope-install.layout.conf"
COMMAND=""

penelope_bundle_startup \
  "penelope-walkthrough-assistant" "${VERSION}" "${SCRIPT_DIR}/penelope-common.sh" \
  "${BASH_SOURCE[0]:-}" "preflight: source preflight scan failed" \
  warn \
  log \
  die \
  read_kv_value_from_file \
  penelope_quote_path_for_display \
  penelope_bundle_local_command_for_display

SELF_CMD="$(penelope_resolved_script_invocation_for_display "penelope-walkthrough-assistant.sh" "${0:-${BASH_SOURCE[0]:-penelope-walkthrough-assistant.sh}}")"
readonly SELF_CMD


detect_latest_tool() {
  local prefix="$1"
  local found
  found="$(find_latest_versioned_shell_file "$BUNDLE_DIR" "$prefix")"
  if [[ -n "$found" ]]; then
    printf '%s/%s' "$BUNDLE_DIR" "$found"
  fi
}

detect_versioned_common_source() {
  local found
  found="$(find_latest_versioned_shell_file "$BUNDLE_DIR" 'penelope-common')"
  if [[ -n "$found" ]]; then
    printf '%s/%s' "$BUNDLE_DIR" "$found"
  fi
}

INSTALL_SCRIPT=""
BACKUP_SCRIPT=""
SAMBA_SCRIPT=""
COMMON_RUNTIME=""
COMMON_VERSIONED_SOURCE=""
COMMON_RUNTIME_VERSION=""
COMMON_VERSIONED_SOURCE_VERSION=""
COMMON_RUNTIME_NEEDS_REFRESH="0"

# Local duplicate of the common-library version reader is intentional here:
# status/missing-common diagnostics need to inspect a runnable/versioned common
# file before relying on a refreshed runtime library path.
common_version_from_file() {
  local file="$1"
  local line=""
  local ver=""
  [[ -f "$file" ]] || return 0
  line="$(grep -E '^(readonly )?PENELOPE_COMMON_VERSION="[^"]+"$' "$file" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    ver="${line#readonly }"
    ver="${ver#PENELOPE_COMMON_VERSION=\"}"
    ver="${ver%\"}"
  fi
  printf '%s' "$ver"
}

common_version_is_older_than() {
  local have="$1"
  local want="$2"
  [[ -n "$have" && -n "$want" ]] || return 1
  [[ "$have" == "$want" ]] && return 1
  local first
  first="$(printf '%s\n%s\n' "$have" "$want" | LC_ALL=C sort -V | head -n 1)"
  [[ "$first" == "$have" ]]
}

DISPLAY_TARGET_HOST=""
DISPLAY_ADMIN_USER=""

load_optional_operator_context() {
  DISPLAY_TARGET_HOST=""
  DISPLAY_ADMIN_USER=""

  if [[ -f "$BOOTSTRAP_CONFIG_FILE" ]]; then
    DISPLAY_TARGET_HOST="$(read_kv_value_from_file "$BOOTSTRAP_CONFIG_FILE" "TARGET_HOST" || true)"
    DISPLAY_ADMIN_USER="$(read_kv_value_from_file "$BOOTSTRAP_CONFIG_FILE" "ADMIN_USER" || true)"
  fi
}

display_target_host_token() {
  if [[ -n "$DISPLAY_TARGET_HOST" ]]; then
    printf '%s' "$DISPLAY_TARGET_HOST"
  else
    printf '%s' '<TARGET_HOST>'
  fi
}

display_admin_user_token() {
  if [[ -n "$DISPLAY_ADMIN_USER" ]]; then
    printf '%s' "$DISPLAY_ADMIN_USER"
  else
    printf '%s' '<ADMIN_USER>'
  fi
}

firstboot_script_for_display() {
  local matches=()

  if [[ -d /usr/local/sbin ]]; then
    mapfile -t matches < <(find /usr/local/sbin -maxdepth 1 -type f -name '*-firstboot.sh' -printf '%p\n' 2>/dev/null | LC_ALL=C sort || true)
    if (( ${#matches[@]} == 1 )); then
      printf '%s' "${matches[0]}"
      return 0
    fi
  fi

  if [[ -n "$DISPLAY_TARGET_HOST" ]]; then
    printf '%s' "/usr/local/sbin/${DISPLAY_TARGET_HOST}-firstboot.sh"
    return 0
  fi

  printf '%s' '/usr/local/sbin/<TARGET_HOST>-firstboot.sh'
}

refresh_detected_paths() {
  INSTALL_SCRIPT="$(detect_latest_tool 'penelope-install')"
  BACKUP_SCRIPT="$(detect_latest_tool 'penelope-backup-setup')"
  SAMBA_SCRIPT="$(detect_latest_tool 'penelope-samba-setup')"
  COMMON_RUNTIME=""
  COMMON_RUNTIME_VERSION=""
  COMMON_VERSIONED_SOURCE_VERSION=""
  COMMON_RUNTIME_NEEDS_REFRESH="0"
  if [[ -f "$BUNDLE_DIR/penelope-common.sh" ]]; then
    COMMON_RUNTIME="$BUNDLE_DIR/penelope-common.sh"
    COMMON_RUNTIME_VERSION="$(common_version_from_file "$COMMON_RUNTIME")"
  fi
  COMMON_VERSIONED_SOURCE="$(detect_versioned_common_source)"
  if [[ -n "$COMMON_VERSIONED_SOURCE" ]]; then
    COMMON_VERSIONED_SOURCE_VERSION="$(common_version_from_file "$COMMON_VERSIONED_SOURCE")"
  fi
  if [[ -n "$COMMON_RUNTIME" && -n "$COMMON_VERSIONED_SOURCE" ]]; then
    if common_version_is_older_than "$COMMON_RUNTIME_VERSION" "$COMMON_VERSIONED_SOURCE_VERSION"; then
      COMMON_RUNTIME_NEEDS_REFRESH="1"
    fi
  fi
}

usage() {
  local self_cmd
  self_cmd="${SELF_CMD}"
  cat <<EOF_USAGE
Usage:
  ${self_cmd} live-usb [--bundle-dir DIR] [--bootstrap-config PATH] [--layout-config PATH]
  ${self_cmd} installed [--bundle-dir DIR] [--bootstrap-config PATH] [--layout-config PATH]
  ${self_cmd} status [--bundle-dir DIR] [--bootstrap-config PATH] [--layout-config PATH]
  ${self_cmd} --help

Purpose:
  Print the current canonical operator walkthrough in two explicit phases:
    live-usb   Guidance for the Ubuntu Live-USB session before the first reboot.
    installed  Guidance for the installed system after reboot / remote unlock.
    status     Print detected sibling bundle assets and the current command paths.

Notes:
  - This assistant is a guide layer, not a replacement for penelope-install,
    penelope-backup-setup, or penelope-samba-setup.
  - It is safe to rerun. It stores no secrets and no relied-on secret state.
  - By default it uses the assistant's own directory as the bundle directory.
  - The current scaffold targets the canonical two-disk walkthrough:
      approx. 2 TB DISK_SYS + approx. 4 TB DISK_DATA.
EOF_USAGE
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      live-usb|installed|status)
        [[ -z "$COMMAND" ]] || die "Only one command is allowed: live-usb | installed | status"
        COMMAND="$1"
        shift
        ;;
      --bundle-dir)
        [[ $# -ge 2 ]] || die "--bundle-dir requires a directory path"
        BUNDLE_DIR="$2"
        shift 2
        ;;
      --bootstrap-config)
        [[ $# -ge 2 ]] || die "--bootstrap-config requires a path"
        BOOTSTRAP_CONFIG_FILE="$2"
        shift 2
        ;;
      --layout-config)
        [[ $# -ge 2 ]] || die "--layout-config requires a path"
        LAYOUT_CONFIG_FILE="$2"
        shift 2
        ;;
      *)
        die "Unknown argument: $1 (run ${SELF_CMD} --help for usage)"
        ;;
    esac
  done
  [[ -n "$COMMAND" ]] || die "Missing command: live-usb | installed | status (run ${SELF_CMD} --help for usage)"
}

common_bundle_note() {
  local bundle_q common_rt_q common_src_q
  bundle_q="$(penelope_quote_path_for_display "$BUNDLE_DIR")"
  if [[ -n "$COMMON_RUNTIME" ]]; then
    common_rt_q="$(penelope_quote_path_for_display "$COMMON_RUNTIME")"
    cat <<EOF_NOTE_RUNTIME_PRESENT
Bundle/runtime library:
  - Runnable sibling common file already present: ${common_rt_q}
  - Runtime common version: ${COMMON_RUNTIME_VERSION:-<unknown>}
EOF_NOTE_RUNTIME_PRESENT
    if [[ -n "$COMMON_VERSIONED_SOURCE" ]]; then
      common_src_q="$(penelope_quote_path_for_display "$COMMON_VERSIONED_SOURCE")"
      cat <<EOF_NOTE_VERSIONED_SOURCE
  - Latest versioned common in this workdir: ${common_src_q} (${COMMON_VERSIONED_SOURCE_VERSION:-<unknown>})
EOF_NOTE_VERSIONED_SOURCE
      if [[ "$COMMON_RUNTIME_NEEDS_REFRESH" == "1" ]]; then
        cat <<EOF_NOTE_REFRESH_WARNING
  - WARNING: The runnable sibling common file is older than the latest versioned common detected here.
  - Refresh the workdir runtime library before a real run:
      cp -f ${common_src_q} ${bundle_q}/penelope-common.sh
EOF_NOTE_REFRESH_WARNING
      fi
    fi
  elif [[ -n "$COMMON_VERSIONED_SOURCE" ]]; then
    common_src_q="$(penelope_quote_path_for_display "$COMMON_VERSIONED_SOURCE")"
    cat <<EOF_NOTE_VERSIONED_MISSING
Bundle/runtime library:
  - Runnable sibling common file is still missing in this directory.
  - Latest versioned common in this workdir: ${common_src_q} (${COMMON_VERSIONED_SOURCE_VERSION:-<unknown>})
  - Assemble the runnable bundle before the real script runs:
      cp -f ${common_src_q} ${bundle_q}/penelope-common.sh
EOF_NOTE_VERSIONED_MISSING
  else
    cat <<EOF_NOTE_NO_COMMON
Bundle/runtime library:
  - No sibling penelope-common.sh and no versioned penelope-common-*.sh were detected in this directory.
  - Provide a matching penelope-common.sh beside the bundle scripts before a real run.
EOF_NOTE_NO_COMMON
  fi
}

print_status() {
  local self_cmd install_q backup_q samba_q bootstrap_q layout_q bundle_q
  self_cmd="${SELF_CMD}"
  bundle_q="$(penelope_quote_path_for_display "$BUNDLE_DIR")"
  bootstrap_q="$(penelope_quote_path_for_display "$BOOTSTRAP_CONFIG_FILE")"
  layout_q="$(penelope_quote_path_for_display "$LAYOUT_CONFIG_FILE")"
  echo "Penelope walkthrough assistant ${VERSION}"
  echo "Command path: ${self_cmd}"
  echo "Bundle dir:    ${bundle_q}"
  echo "Bootstrap config: ${bootstrap_q}"
  echo "Layout config:    ${layout_q}"
  if [[ -n "$DISPLAY_TARGET_HOST" || -n "$DISPLAY_ADMIN_USER" ]]; then
    echo "Operator context from bootstrap config:"
    if [[ -n "$DISPLAY_TARGET_HOST" ]]; then
      echo "  - TARGET_HOST: ${DISPLAY_TARGET_HOST}"
    fi
    if [[ -n "$DISPLAY_ADMIN_USER" ]]; then
      echo "  - ADMIN_USER:  ${DISPLAY_ADMIN_USER}"
    fi
  fi
  echo
  common_bundle_note
  echo
  if [[ "$COMMON_RUNTIME_NEEDS_REFRESH" == "1" ]]; then
    echo "Status: WARNING - refresh penelope-common.sh in this workdir before a real run."
    echo
  fi
  if [[ -n "$INSTALL_SCRIPT" ]]; then
    install_q="$(penelope_quote_path_for_display "$INSTALL_SCRIPT")"
    echo "Detected install bundle: ${install_q}"
  else
    echo "Detected install bundle: <missing in bundle dir>"
  fi
  if [[ -n "$BACKUP_SCRIPT" ]]; then
    backup_q="$(penelope_quote_path_for_display "$BACKUP_SCRIPT")"
    echo "Detected backup bundle:  ${backup_q}"
  else
    echo "Detected backup bundle:  <missing in bundle dir>"
  fi
  if [[ -n "$SAMBA_SCRIPT" ]]; then
    samba_q="$(penelope_quote_path_for_display "$SAMBA_SCRIPT")"
    echo "Detected samba bundle:   ${samba_q}"
  else
    echo "Detected samba bundle:   <missing in bundle dir>"
  fi
  echo
  echo "This assistant only prints the next operator steps."
}

print_live_usb() {
  local self_cmd bundle_q bootstrap_q layout_q install_cmd backup_cmd samba_cmd target_host_token admin_user_token
  self_cmd="${SELF_CMD}"
  bundle_q="$(penelope_quote_path_for_display "$BUNDLE_DIR")"
  bootstrap_q="$(penelope_quote_path_for_display "$BOOTSTRAP_CONFIG_FILE")"
  layout_q="$(penelope_quote_path_for_display "$LAYOUT_CONFIG_FILE")"
  install_cmd="$(penelope_bundle_local_command_for_display "${INSTALL_SCRIPT}" "./penelope-install-<version>.sh")"
  backup_cmd="$(penelope_bundle_local_command_for_display "${BACKUP_SCRIPT}" "./penelope-backup-setup-<version>.sh")"
  samba_cmd="$(penelope_bundle_local_command_for_display "${SAMBA_SCRIPT}" "./penelope-samba-setup-<version>.sh")"
  target_host_token="$(display_target_host_token)"
  admin_user_token="$(display_admin_user_token)"

  cat <<EOF_LIVE
Penelope walkthrough assistant ${VERSION}
Phase: live-usb

This phase is for the Ubuntu Live-USB session.
Use it as a guide only. The real execution surface remains penelope-install.

Current canonical scenario:
  - INSTALL_LAYOUT_PROFILE="two-disk"
  - DISK_SYS   = approx. 2 TB M.2
  - DISK_DATA  = approx. 4 TB M.2

Detected bundle/workdir:
  - ${bundle_q}

Command style below assumes you are already working inside this bundle/workdir and therefore uses ./<script>.

EOF_LIVE
  common_bundle_note
  cat <<EOF_LIVE2

Recommended live-usb sequence:

1. Confirm context.
   - Boot Ubuntu Live-USB in UEFI mode.
   - Choose the physically correct keyboard layout.
   - Do NOT run the Ubuntu installer itself.
   - Open a terminal.

2. Keep one runnable Penelope bundle/workdir together.
   - If you already extracted the release zip into ${bundle_q}, continue there.
   - Otherwise extract the current release archive into one directory, cd into it, and run this assistant again.
   - If executable bits were not preserved after extraction, run once in that workdir:
       chmod +x ./*.sh

3. Identify the disks before editing any config.
   Commands:
     lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINT
     ls -l /dev/disk/by-id/
   Target mapping for this walkthrough:
     - DISK_SYS  = approx. 2 TB M.2
     - DISK_DATA = approx. 4 TB M.2
   Prefer stable /dev/disk/by-id/<device-id> paths.

4. Generate or review the external bootstrap config.
EOF_LIVE2
  if [[ -f "${BOOTSTRAP_CONFIG_FILE}" ]]; then
    cat <<EOF_BOOTSTRAP_EXISTS
   Existing bootstrap config detected: ${bootstrap_q}
   Commands:
     nano ${bootstrap_q}
   To intentionally regenerate this file after confirming it is not your effective config, use:
     ${install_cmd} --write-bootstrap-config-template ${bootstrap_q} --force
EOF_BOOTSTRAP_EXISTS
  else
    cat <<EOF_BOOTSTRAP_NEW
   Commands:
     ${install_cmd} --write-bootstrap-config-template ${bootstrap_q}
     nano ${bootstrap_q}
EOF_BOOTSTRAP_NEW
  fi
  cat <<EOF_LIVE2
   Set at least:
     - ADMIN_USER
     - TARGET_HOST
     - CRED_MASTER_PW
     - CRED_LOGIN_PW

5. Generate or review the external layout config.
EOF_LIVE2
  if [[ -f "${LAYOUT_CONFIG_FILE}" ]]; then
    cat <<EOF_LAYOUT_EXISTS
   Existing layout config detected: ${layout_q}
   Commands:
     nano ${layout_q}
   To intentionally regenerate this file after confirming it is not your effective config, use:
     ${install_cmd} --write-layout-config-template ${layout_q} --force
EOF_LAYOUT_EXISTS
  else
    cat <<EOF_LAYOUT_NEW
   Commands:
     ${install_cmd} --write-layout-config-template ${layout_q}
     nano ${layout_q}
EOF_LAYOUT_NEW
  fi
  cat <<EOF_LIVE2
   Expected behavior:
     - The template analyzes the currently visible hardware.
     - In the canonical clear case (one approx. 2 TB disk plus one approx. 4 TB disk),
       it auto-fills DISK_SYS and DISK_DATA with stable /dev/disk/by-id paths.
     - If the file still contains REPLACE_WITH values, stop and resolve them before runtime.
   For this walkthrough keep:
     - INSTALL_LAYOUT_PROFILE="two-disk"
     - DISK_SYS  = approx. 2 TB by-id path
     - DISK_DATA = approx. 4 TB by-id path
     - DISK_HOME / DISK_ARCHIVE / DISK_BACKUP empty

6. Optional forward-update review when reusing older operator-owned install configs.
   Command:
     ${install_cmd} --audit-config-evolution --bootstrap-config ${bootstrap_q} --layout-config ${layout_q}
   If the audit reports absent/older schema markers or missing current keys:
     - generate fresh templates at separate paths
     - merge the missing current keys into the effective config before runtime
     - do not overwrite an effective config blindly

7. Recommended non-destructive preflight.
   Command:
     sudo -E ${install_cmd} --verify-layout-contract --bootstrap-config ${bootstrap_q} --layout-config ${layout_q}
   Confirm that the printed plan treats the 2 TB disk as DISK_SYS and the 4 TB disk as DISK_DATA.
   The installer now refuses:
     - unedited REPLACE_WITH placeholders before long-running provisioning starts
     - external install configs that are missing current schema markers or current keys

8. Run the real install.
   Command:
     sudo -E ${install_cmd} --bootstrap-config ${bootstrap_q} --layout-config ${layout_q}

9. Before reboot, preserve the generated install artefacts outside the Live session.
   The installer writes the two encrypted 7z key archives beside the bootstrap config used for the run.
   Preserve at least:
     - ${target_host_token}_unlock_keys.7z (next to ${bootstrap_q})
     - ${admin_user_token}_ssh_keys.7z (next to ${bootstrap_q})
     - the real bootstrap config you used: ${bootstrap_q}
     - the real layout config you used: ${layout_q}
     - non-secret install notes such as the final by-id disk mapping
   Record the relied-on secrets in KeePass or an equivalent vault immediately.
   Do not rely on the server or a loose workdir copy as the only storage location.

10. Prepare the remote unlock test on a second device.
   - Extract ${target_host_token}_unlock_keys.7z on that second device before reboot.
   - The default Dropbear unlock key name inside the archive is usually ${target_host_token}_unlock.
   - After reboot, SSH to the initramfs environment and complete the unlock there.
   Example command shape:
     ssh -i <path-to-extracted-unlock-private-key> -p 2222 root@<ip-or-hostname>
   Then enter CRED_MASTER_PW when prompted by the unlock assistant.

11. Reboot and switch phases.
    - After the machine has been unlocked remotely and has booted fully, log in as the admin user.
    - Then run the installed-system phase from a bundle/workdir on the installed host:
        ${self_cmd} installed
      If this exact live-usb workdir will not be available after reboot:
        - extract the same release bundle again in a fresh installed-host workdir
        - recreate or refresh the runnable sibling penelope-common.sh there if needed
          (see the Bundle/runtime library note above)
        - run the assistant there

Related bundle commands for later installed-system work:
  - Backup bundle: ${backup_cmd}
  - Samba bundle:  ${samba_cmd}
EOF_LIVE2
}

print_installed() {
  local self_cmd bundle_q install_cmd backup_cmd samba_cmd firstboot_script_q
  self_cmd="${SELF_CMD}"
  bundle_q="$(penelope_quote_path_for_display "$BUNDLE_DIR")"
  install_cmd="$(penelope_bundle_local_command_for_display "${INSTALL_SCRIPT}" "./penelope-install-<version>.sh")"
  backup_cmd="$(penelope_bundle_local_command_for_display "${BACKUP_SCRIPT}" "./penelope-backup-setup-<version>.sh")"
  samba_cmd="$(penelope_bundle_local_command_for_display "${SAMBA_SCRIPT}" "./penelope-samba-setup-<version>.sh")"
  firstboot_script_q="$(firstboot_script_for_display)"

  cat <<EOF_INST
Penelope walkthrough assistant ${VERSION}
Phase: installed

This phase is for the running installed system after the first reboot.
It assumes the scratch install already finished and the host has booted successfully.
Bootstrap-config is no longer needed on the running system for the routine post-reboot guidance steps.

Detected bundle/workdir:
  - ${bundle_q}

Command style below assumes you are already working inside this bundle/workdir and therefore uses ./<script>.

EOF_INST
  common_bundle_note
  cat <<EOF_INST2

Recommended installed-system sequence:

1. Confirm the early boot path was really exercised.
   - Preferred: you already tested remote unlock from a second device during the first reboot.
   - If you skipped that test, schedule an early reboot soon and prove the Dropbear unlock path before you rely on the host.

2. Ensure you have a runnable bundle/workdir on the installed host.
   - If you already re-extracted the current release bundle into ${bundle_q}, continue there.
   - Otherwise extract the current release zip to one installed-host workdir, recreate or
     refresh the runnable sibling penelope-common.sh there if needed (see the
     Bundle/runtime library note above), cd into it, and run this assistant again.
   - If executable bits were not preserved after extraction, run once in that workdir:
       chmod +x ./*.sh

3. Run the mandatory manual firstboot step.
   Command:
     sudo ${firstboot_script_q}

4. Run the early installed-host verify checkpoint.
   Command:
     sudo -E /usr/local/sbin/penelope-verify-security.sh

5. Bring up backup tooling.
   Fresh bring-up on a newly installed host:
     sudo -E ${backup_cmd} write-config
     sudoedit /etc/penelope/backup-setup/backup-setup.conf
     sudoedit /etc/penelope/backup-setup/secrets.d/system.secret
     sudoedit /etc/penelope/backup-setup/secrets.d/home.secret
     sudoedit /etc/penelope/backup-setup/secrets.d/_archive.secret
     sudo -E ${backup_cmd} verify-config
     sudo -E ${backup_cmd} apply
   Recovery / reattach with already restored effective backup state:
     - /etc/penelope/backup-setup/ is the bootstrap/operator-input tree used by write-config on a fresh bring-up.
     - /etc/penelope/backup.conf is the applied live runtime config consumed by the installed backup tools.
     - If /etc/penelope/backup.conf and /root/.config/restic/* were already restored, treat them as the canonical live state.
     - Do not start with write-config just to regenerate placeholders over that restored state.
     - Instead run:
         sudo -E ${backup_cmd} verify-config --keep-config --keep-secrets
         sudo -E ${backup_cmd} apply --keep-config --keep-secrets
   If a newer bundle adds new template-only keys:
     - generate fresh templates into a separate scratch location
     - merge only the intended missing keys into the operator-owned config
     - do not blindly replace established live config or secrets
   On a mounted non-empty preserved /_backup, verify-config now shares the same
   scope guard as apply: blind bootstrap and explicit fresh new-scope creation are
   rejected there; reuse is accepted only when HOST_SCOPE_NAME already matches one of
   the detected existing scopes on disk.
   Canonical running-system flows:
     fresh bring-up: write-config -> external edit -> verify-config -> apply -> penelope-backup.sh --mode internal
     restored effective state: verify-config --keep-config --keep-secrets -> apply --keep-config --keep-secrets -> backup-verify --mode internal
   Running-system operator rule after live backup.conf edits:
     - If you change live backup settings that affect installed runtime behavior or rendered artifacts, rerun:
         sudo -E ${backup_cmd} verify-config
         sudo -E ${backup_cmd} apply
     - Typical examples: CRON_HOUR/CRON_MINUTE (cron regeneration) and BACKUP_DASHBOARD_DIR (dashboard/runtime path contract).
     - Example: move the daily internal backup from its default to 20:00 by editing /etc/penelope/backup.conf to
         CRON_HOUR="20"
         CRON_MINUTE="0"
       then rerun verify-config and apply.

6. Verify backup bring-up.
   Commands:
     sudo /usr/local/sbin/penelope-backup.sh --mode internal
     sudo /usr/local/sbin/penelope-backup-verify.sh --mode internal
     sudo cat /var/lib/penelope/backup-dashboard/last-verify.json
     sudo tail -n 50 /var/log/*/backup/verify.log
   Review 'last-verify.json' first.
   - Successful backups now chain a read-only verify automatically, so the internal
     run and verify result should both be visible after 'penelope-backup.sh --mode internal'.
   - The success-facing dashboard summary and synced _recovery bundle are published
     only after that chained verify succeeds.
   - If you later use 'backup-verify --mode internal --run-now', inspect
     'last-internal.json' / 'events-internal.log' for the underlying runtime history
     of that explicit proof run as well.
   - That explicit proof path now performs one fresh internal backup run plus one
     verify pass.

7. Prepare and register the first USB backup disk.
   Choose an operator disk name that fits your local rotation scheme. Examples:
     backup-01
     penelope-01
     offsite-blue
   The guided setup keeps the operator DISK_NAME and filesystem LABEL identical
   for newly prepared disks and rejects names that do not fit the label limits.
   Attach the USB disk, then run:
     sudo /usr/local/sbin/penelope-usb-disk-setup.sh
   Expected guided behavior:
     - protected internal disks are printed with mountpoint reasons and are not selectable
     - connected USB disks are printed with device, size, model, serial, partition, label, UUID, and registration state
     - existing filesystems show capacity, detected host scopes, and an internal-backup footprint estimate when available
     - an already registered disk is accepted idempotently and its UUID is printed
     - existing Penelope disks with foreign host scopes are registered only after explicit operator confirmation and are not erased
     - a new or disposable disk is erased only after the exact confirmation phrase shown by the tool
   Optional later rename operation:
     sudo /usr/local/sbin/penelope-usb-disk-setup.sh --rename-disk
   After successful registration, inspect the allowlist:
     sudo cat /etc/penelope/usb-backup-disks.conf
   For a first manual external proof run, replace backup-01 with the chosen DISK_NAME:
     UUID="\$(sudo awk '\$2=="backup-01"{print \$1; exit}' /etc/penelope/usb-backup-disks.conf)"
     echo "\${UUID}"
     sudo /usr/local/sbin/penelope-backup.sh --mode external --uuid "\${UUID}"
     sudo /usr/local/sbin/penelope-backup-verify.sh --mode external --uuid "\${UUID}"
     sudo ls -al /var/lib/penelope/backup-dashboard
     sudo tail -n 100 /var/log/*/backup/backup.log
   If USB autorun is enabled, do not start a manual external run at the same time
   as an autorun for the same disk. Use either the manual commands above or an
   unplug/replug autorun test, not both concurrently.
   For external disks, treat 'last-external-<DISK_NAME>.json' as the per-disk
   structured summary that is written only after the final
   READY/REATTACH_AND_WAIT/CONTACT_OPERATOR outcome for that same run is known.
   External USB operator signals (USB autorun is enabled by default via ENABLE_USB_AUTORUN=1):
     - RUNNING_DO_NOT_REMOVE: do not remove the disk
     - REATTACH_AND_WAIT: reinsert the same allow-listed disk and wait; the normal retry is usually expected on reinsert
     - READY_TO_REMOVE: safe to remove
     - CONTACT_OPERATOR: stop and contact the Operator
     - different allow-listed USB backup disks may run in parallel with each other; each keeps its own per-disk dashboard truth
     - internal backups remain serialized against active external runs
     - once a later retry for that same disk actually starts, it becomes the new
       per-disk truth; if it then finishes with READY_TO_REMOVE, the earlier
       CONTACT_OPERATOR state for that same disk is superseded

8. Bring up Samba on the installed host.
   Fresh bring-up on a host without an existing /etc/penelope/samba-setup tree:
     sudo -E ${samba_cmd} write-config
   Optional quick inspect of the scaffolded model:
     ${samba_cmd} list-users
     ${samba_cmd} list-shares
   The shipped default Samba model for this walkthrough is the current generated config model:
     - penelope_client is the standard Windows/Linux workstation identity without private storage
     - p001 and p002 are Windows-friendly archive workstation identities by default: standard workstation access plus private archive_p001/archive_p002 shares
     - set default_access=no in a p-user config when that identity must be archive-only and the client can manage separate SMB credentials cleanly
     - scan is the scanner/printer service identity and can write to the shared scan inbox
     - built-in shared resources rawin, scan, and internal are read/write work areas
     - internal is a shared resource at /home/internal, not a login-capable Samba identity and not a secret file
     - built-in backup_dashboard is readonly for standard clients and archive users
   If you keep that shipped default, the minimum edit set is usually the active secret files:
     sudoedit /etc/penelope/samba-setup/secrets.d/penelope_client.secret
     sudoedit /etc/penelope/samba-setup/secrets.d/scan.secret
     sudoedit /etc/penelope/samba-setup/secrets.d/p001.secret
     sudoedit /etc/penelope/samba-setup/secrets.d/p002.secret
     sudoedit /etc/penelope/samba-setup/secrets.d/backup_dashboard.secret
   Edit /etc/penelope/samba-setup/samba-setup.conf only when you want to change the shipped toggles or defaults:
     sudoedit /etc/penelope/samba-setup/samba-setup.conf
   If you also manage extra users or shares, edit the relevant files in:
     - /etc/penelope/samba-setup/users.d/
     - /etc/penelope/samba-setup/shares.d/
   Do this before verify-config/apply.
   Recovery / reattach with an already restored Samba config tree:
     - If /etc/penelope/samba-setup was already restored, treat it as the canonical source of truth.
     - Do not start with write-config just to regenerate placeholders over that restored tree.
     - Inspect first, then restore or fill any missing effective secrets from KeePass:
         ${samba_cmd} list-users
         ${samba_cmd} list-shares
   Then verify and apply:
     sudo -E ${samba_cmd} verify-config
     sudo -E ${samba_cmd} apply
   Share-name ownership guardrails now enforced by verify-config/apply:
     - operator-declared shares must not reuse the fixed Penelope built-in names rawin, scan, internal, or backup_dashboard
     - a declared Penelope share must not collide with an already active non-Penelope Samba share
   If a newer bundle adds new example or non-secret topology keys, review the
   fresh examples and merge only the intended missing keys into the operator-owned tree.
   Canonical running-system flows:
     fresh bring-up: write-config -> external edit -> verify-config -> apply
     restored config tree: inspect -> fill effective secrets -> verify-config -> apply

9. Verify Samba bring-up.
   Commands:
     ${samba_cmd} list-users
     ${samba_cmd} list-shares
     sudo -E /usr/local/sbin/penelope-verify-security.sh
     sudo testparm -s
     systemctl status smbd --no-pager

10. Final combined verify-all checkpoint.
   Confirm together:
     - install / initramfs / recovery-stage state via sudo -E /usr/local/sbin/penelope-verify-security.sh
     - backup runtime/dashboard state via the backup checks above
     - Samba declared model + runtime state via list-users, list-shares, testparm, and smbd status

11. Routine software-only updates later on.
    Keep the same bundle pattern and use the running-system update paths:
      - sudo -E ${install_cmd} --initramfs-only
      - sudo -E ${install_cmd} --managed-artifacts-only
      - rerun ${backup_cmd} via verify-config -> apply after external config edits
      - rerun ${samba_cmd} via verify-config -> apply after external config edits
    The assistant is a guide, not the updater itself.
EOF_INST2
}

main() {
  parse_args "$@"
  [[ -d "$BUNDLE_DIR" ]] || die "Bundle dir not found: $BUNDLE_DIR"
  refresh_detected_paths
  load_optional_operator_context

  case "$COMMAND" in
    status)
      print_status
      ;;
    live-usb)
      print_live_usb
      ;;
    installed)
      print_installed
      ;;
    *)
      die "Unsupported command: $COMMAND (run ${SELF_CMD} --help for usage)"
      ;;
  esac
}

main "$@"
