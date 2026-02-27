#!/usr/bin/env bash
set -euo pipefail

VMID="${VMID:-121}"
VMNAME="OpenHabian"
BRIDGE="${BRIDGE:-vmbr0}"
CORES=2
RAM_MB=4096
DISK_GB=32
CIUSER="openhabian"
CIPASS="openhabian"

IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/cache/debian-12-genericcloud-amd64.qcow2"

# auto storage detect
if pvesm status | awk '{print $1}' | grep -qx local-zfs; then
  STORAGE="local-zfs"
else
  STORAGE="local"
fi

if qm status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID există deja."
  exit 1
fi

mkdir -p /var/lib/vz/template/cache

echo "[1/6] Download Debian cloud..."
[[ -f "$IMG" ]] || wget -O "$IMG" "$IMG_URL"

echo "[2/6] Create VM..."
qm create "$VMID" \
  --name "$VMNAME" \
  --ostype l26 \
  --machine i440fx \
  --bios seabios \
  --cores "$CORES" \
  --memory "$RAM_MB" \
  --scsihw virtio-scsi-single \
  --agent 1 \
  --vga std

echo "[3/6] Import disk..."
qm importdisk "$VMID" "$IMG" "$STORAGE" --format qcow2
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --boot order=scsi0

echo "[4/6] Cloud-init..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --ciuser "$CIUSER"
qm set "$VMID" --cipassword "$CIPASS"
qm set "$VMID" --net0 virtio,bridge="$BRIDGE"
qm set "$VMID" --ipconfig0 ip=dhcp

qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "[5/6] Start VM..."
qm start "$VMID"

echo "[6/6] Installing openHABian inside guest (wait)..."

# wait guest agent
sleep 20

qm guest exec "$VMID" -- bash -lc "
apt update
apt install -y curl git sudo qemu-guest-agent
hostnamectl set-hostname OpenHabian
curl -fsSL https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh -o /opt/openhabian.sh
chmod +x /opt/openhabian.sh
/opt/openhabian.sh unattended
cat > /etc/profile.d/openhabian-tty1.sh <<'EOF'
#!/bin/bash
case \$- in *i*) ;; *) return ;; esac
[ \"\$(tty)\" = \"/dev/tty1\" ] || return
exec openhabian-config
EOF
chmod +x /etc/profile.d/openhabian-tty1.sh
"

echo "DONE."
echo "Login: openhabian / openhabian"
