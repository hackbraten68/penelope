#!/usr/bin/env bash
# penelope-windows-vm-setup.sh
#
# Non-destructive setup bundle for the managed Windows Server VM (WinBoat/dockurr).
# Modes: --write-config, --verify-config, apply (default).
set -Eeuo pipefail

readonly VERSION="0.0.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_RUNTIME_PATH="${SCRIPT_DIR}/penelope-common.sh"

if [[ ! -f "${COMMON_RUNTIME_PATH}" ]]; then
  echo "ERROR: penelope-common.sh missing beside this bundle." >&2
  exit 127
fi
source "${COMMON_RUNTIME_PATH}"

SELF_CMD="$(penelope_resolved_script_invocation_for_display "penelope-windows-vm-setup.sh" "${0:-}")"
readonly SELF_CMD

CONFIG_FILE="${PENELOPE_WINDOWS_VM_CONFIG:-${SCRIPT_DIR}/penelope-windows-vm.bootstrap.conf}"
MODE="${1:-apply}"

write_config() {
  cat >"${CONFIG_FILE}" <<'EOF'
# Penelope Windows VM bootstrap config
WINDOWS_VM_ENABLED="1"
DOCKER_REPO_CHANNEL="stable"
WINBOAT_COMPOSE_DIR="/opt/penelope/winboat"
WINBOAT_AUTOSTART="0"
WINBOAT_RAM_SIZE="8G"
WINBOAT_CPU_CORES="4"
WINBOAT_DISK_SIZE="128G"
EOF
  chmod 600 "${CONFIG_FILE}"
  echo "Wrote config: ${CONFIG_FILE}"
}

verify_config() {
  [[ -f "${CONFIG_FILE}" ]] || { echo "Config missing: ${CONFIG_FILE}"; exit 1; }
  source "${CONFIG_FILE}"
  [[ "${WINDOWS_VM_ENABLED}" == "1" ]] || { echo "WINDOWS_VM_ENABLED != 1"; exit 1; }
  echo "Config OK"
}

apply() {
  source "${CONFIG_FILE}"
  [[ "${WINDOWS_VM_ENABLED}" == "1" ]] || { echo "Disabled"; exit 0; }

  # Docker
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} ${DOCKER_REPO_CHANNEL:-stable}" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  # Compose stack
  mkdir -p "${WINBOAT_COMPOSE_DIR}/windows"
  cat > "${WINBOAT_COMPOSE_DIR}/docker-compose.yml" <<EOF
services:
  windows:
    image: dockurr/windows
    container_name: windows-server-2025
    environment:
      VERSION: "2025"
      RAM_SIZE: "${WINBOAT_RAM_SIZE}"
      CPU_CORES: "${WINBOAT_CPU_CORES}"
      DISK_SIZE: "${WINBOAT_DISK_SIZE}"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "8006:8006"
      - "3389:3389/tcp"
      - "3389:3389/udp"
    volumes:
      - ${WINBOAT_COMPOSE_DIR}/windows:/storage
    restart: unless-stopped
EOF
  if [[ "${WINBOAT_AUTOSTART}" == "1" ]]; then
    (cd "${WINBOAT_COMPOSE_DIR}" && docker compose up -d)
  fi
  echo "Windows VM setup complete. Compose dir: ${WINBOAT_COMPOSE_DIR}"
}

case "${MODE}" in
  --write-config) write_config ;;
  --verify-config) verify_config ;;
  apply) apply ;;
  *) echo "Usage: $0 [--write-config|--verify-config|apply]"; exit 2 ;;
esac
EOF
chmod +x penelope-windows-vm-setup-0.0.1.sh && bash -n penelope-windows-vm-setup-0.0.1.sh && echo OK