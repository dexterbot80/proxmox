#!/usr/bin/env bash
set -e

### CONFIGURARE (poți modifica aici sau din env)
CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-openhabian}"
STORAGE="${STORAGE:-local-lvm}"
DISK_SIZE="${DISK_SIZE:-8}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
PASSWORD="${PASSWORD:-openhabian}"

TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
TEMPLATE_STORAGE="local"

echo "== openHABian LXC Installer =="

if pct status $CTID >/dev/null 2>&1; then
  echo "CTID $CTID already exists!"
  exit 1
fi

echo "[1/6] Download Debian 12 template..."
pveam update
pveam download $TEMPLATE_STORAGE $TEMPLATE || true

echo "[2/6] Creating LXC container..."
pct create $CTID ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE} \
  --hostname $HOSTNAME \
  --cores $CORES \
  --memory $MEMORY \
  --rootfs ${STORAGE}:${DISK_SIZE} \
  --net0 name=eth0,bridge=${BRIDGE},ip=dhcp \
  --password $PASSWORD \
  --features nesting=1 \
  --unprivileged 1

echo "[3/6] Starting container..."
pct start $CTID
sleep 5

echo "[4/6] Installing dependencies..."
pct exec $CTID -- bash -c "
apt update
apt install -y curl git sudo systemd ca-certificates
"

echo "[5/6] Installing openHABian (unattended)..."
pct exec $CTID -- bash -c "
echo 'hw=x86' > /etc/openhabian.conf
echo 'hwarch=amd64' >> /etc/openhabian.conf
echo 'osrelease=debian' >> /etc/openhabian.conf
curl -fsSL https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh -o /opt/openhabian-setup.sh
chmod +x /opt/openhabian-setup.sh
/opt/openhabian-setup.sh unattended
"

echo "[6/6] Enabling openHAB..."
pct exec $CTID -- systemctl enable openhab --now || true

echo ""
echo "==========================================="
echo "openHABian installed successfully!"
echo "Container ID: $CTID"
echo "Login user: root"
echo "Password: $PASSWORD"
echo "Web UI: http://<container-ip>:8080"
echo "==========================================="
