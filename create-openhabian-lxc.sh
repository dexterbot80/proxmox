#!/usr/bin/env bash
set -euo pipefail

CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-openhabian}"
DISK_SIZE="${DISK_SIZE:-8}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
PASSWORD="${PASSWORD:-openhabian}"

# autodetect dacă nu setezi
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"   # tu ai local
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-zfs}"   # tu ai local-zfs

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need pct; need pveam; need pvesm; need awk; need grep; need tail

echo "== openHABian LXC Installer =="

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CTID $CTID already exists!"
  exit 1
fi

# Validate storages exist
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "Template storage '$TEMPLATE_STORAGE' does not exist. Available:"
  pvesm status; exit 1
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$ROOTFS_STORAGE"; then
  echo "Rootfs storage '$ROOTFS_STORAGE' does not exist. Available:"
  pvesm status; exit 1
fi

echo "[1/7] Update template index..."
pveam update >/dev/null

echo "[2/7] Find latest Debian 12 amd64 template..."
TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
  | tail -n1 || true)"

if [[ -z "$TEMPLATE" ]]; then
  echo "Eroare: Nu găsesc template Debian 12 amd64."
  echo "Rulează: pveam available --section system | grep debian-12"
  exit 1
fi
echo " - Template: $TEMPLATE"
echo " - Template storage: $TEMPLATE_STORAGE"
echo " - Rootfs storage:   $ROOTFS_STORAGE"

echo "[3/7] Download template (if missing)..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || true

echo "[4/7] Create LXC..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --password "$PASSWORD" \
  --features "nesting=1" \
  --unprivileged 1

echo "[5/7] Start container..."
pct start "$CTID"
sleep 5

echo "[6/7] Install openHABian (unattended)..."
pct exec "$CTID" -- bash -lc "
set -e
apt-get update -y
apt-get install -y curl git sudo ca-certificates systemd whiptail
cat > /etc/openhabian.conf <<'EOF'
hw=x86
hwarch=amd64
osrelease=debian
EOF
curl -fsSL https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh -o /opt/openhabian-setup.sh
chmod +x /opt/openhabian-setup.sh
/opt/openhabian-setup.sh unattended
systemctl enable --now openhab || true
"

echo "[7/7] Done."
echo "CTID: $CTID"
echo "root password: $PASSWORD"
echo "IP: pct exec $CTID -- hostname -I"
echo "openHAB: http://<IP>:8080"
