# Penelope – WinBoat / Windows Server 2025 (Kurz-Doku)

## Ziel

Auf dem Penelope-Server (Ubuntu, verschlüsselt, remote-unlock via Dropbear) läuft
zusätzlich eine Windows-Server-2025-VM als Container, damit kleines Team mit bis zu 5 Personen
per RDP (3389) oder Browser (8006) auf Windows zugreifen – ohne eigene
Windows-Rechner.

Stack: Docker (offizielles Repo) → `dockurr/windows` → Windows Server 2025.

## Voraussetzungen

- Host hat KVM: `ls -l /dev/kvm` (sonst VM-Performance miserabel).
- `DOCKER_INSTALL=1` in der Bootstrap-Config.
- Host-Ressourcen für kleines Team mit bis zu 5 Personen: 8–16 GB RAM, 4 Cores, 128 GB Disk für die VM.

## Konfiguration (Bootstrap-Config)

```ini
DOCKER_INSTALL="1"
DOCKER_REPO_CHANNEL="stable"
DOCKER_COMPOSE_PLUGIN="1"

WINBOAT_ENABLED="1"
WINBOAT_COMPOSE_DIR="/opt/penelope/winboat"
WINBOAT_AUTOSTART="0"        # 1 = beim Install sofort starten
WINBOAT_RAM_SIZE="8G"
WINBOAT_CPU_CORES="4"
WINBOAT_DISK_SIZE="128G"
```

## Was der Installer macht

1. Installiert Docker + Compose aus dem offiziellen Docker-Repo (im chroot).
2. Legt `/opt/penelope/winboat/` an und schreibt `docker-compose.yml`.
3. Falls `WINBOAT_AUTOSTART=1`: `docker compose up -d`.

## Betrieb nach dem Install

```bash
cd /opt/penelope/winboat
docker compose up -d
docker compose ps
docker compose logs -f
```

Zugriff: `http://<server-ip>:8006` oder RDP auf Port 3389.

## Datenhaltung

Mandantenakten/Dokumente **nicht** in der VM-Disk ablegen, sondern als SMB-Share
vom Penelope-Host mounten – hält die VM-Disk klein und Backups einfach.

## Troubleshooting

- KVM fehlt: Host-BIOS/Kernel prüfen.
- Container startet nicht: `docker compose logs`.
- Performance: RAM/CPU in Bootstrap-Config erhöhen, dann `docker compose up -d`.
EOF
git add penelope-winboat-setup.md && git commit -m "docs(winboat): setup guide for colleagues (rewritten)" && git log --oneline -3