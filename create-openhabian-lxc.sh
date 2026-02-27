#!/usr/bin/env bash
set -euo pipefail

### CONFIG (override via env)
CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-openhabian}"
DISK_SIZE="${DISK_SIZE:-8}"       # GB
MEMORY="${MEMORY:-2048}"          # MB
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
PASSWORD="${PASSWORD:-openhabian}"

# If empty => autodetect:
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"   # where templates live (usually local)
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"       # where container disk lives (prefer local-zfs)

echo "== openHABian LXC Installer =="

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need pct
need pveam
need pvesm
need awk
need grep
need sed

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CTID $CTID already exists!"
  exit 1
fi

# Autodetect storages
if [[ -z "$TEMPLATE_STORAGE" ]]; then
  if pvesm status | awk 'NR>1{print $1}' | grep -qx "local"; then
    TEMPLATE_STORAGE="local"
  else
    # fallback: first storage that supports vztmpl usually is local
    TEMPLATE_STORAGE="$(pvesm status | awk 'NR>1{print $1}' | head -n1)"
  fi
fi

if [[ -z "$ROOTFS_STORAGE" ]]; then
  if pvesm status | awk 'NR>1{print $1}' | grep -qx "local-zfs"; then
    ROOTFS_STORAGE="local-zfs"
  elif pvesm status | awk 'NR>1{print $1}' | grep -qx "local"; then
    ROOTFS_STORAGE="local"
  else
    ROOTFS_STORAGE="$(pvesm status | awk 'NR>1{print $1}' | head -n1)"
  fi
fi

# Validate storages exist
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "Template storage '$TEMPLATE_STORAGE' does not exist. Available:"
  pvesm status
  exit 1
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$ROOTFS_STORAGE"; then
  echo "Rootfs storage '$ROOTFS_STORAGE' does not exist. Available:"
  pvesm status
  exit 1
fi

echo "[1/7] Update template index..."
pveam update >/dev/null
echo " - OK"

echo "[2/7] Find latest Debian 12 amd64 template..."
# pick the last match from pveam available (usually latest)
TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
  | tail -n1 || true)"

if [[ -z "$TEMPLATE" ]]; then
  echo "Eroare: Nu găsesc template Debian 12 amd64 în 'pveam available'."
  echo "Rulează manual: pveam available --section system | grep debian-12"
  exit 1
fi

echo " - Using template: $TEMPLATE"
echo " - Template storage: $TEMPLATE_STORAGE"
echo " - Rootfs storage:   $ROOTFS_STORAGE"

echo "[3/7] Download template (if missing)..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || true
echo " - OK"

echo "[4/7] Create LXC (unprivileged, nesting=1)..."
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

echo "[6/7] Install openHABian (unattended)... (can take a while)"
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
echo "==========================================="
echo "openHABian installed in LXC!"
echo "CTID: $CTID"
echo "Login: root / $PASSWORD"
echo "Web UI: http://<container-ip>:8080"
echo "Tip: afla IP cu: pct exec $CTID -- hostname -I"
echo "==========================================="
