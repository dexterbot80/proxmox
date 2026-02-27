#!/usr/bin/env bash
set -euo pipefail

### ================== CONFIG (override via env) ==================
VMID="${VMID:-121}"
VMNAME="${VMNAME:-OpenHabian}"              # hostname + VM name
STORAGE="${STORAGE:-}"                      # auto if empty: local-zfs -> local
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
DISK_GB="${DISK_GB:-32}"
VLAN_TAG="${VLAN_TAG:-}"                    # optional

CIUSER="${CIUSER:-openhabian}"
CIPASS="${CIPASS:-openhabian}"

# DHCP by default; for static set both:
IP_CIDR="${IP_CIDR:-}"
GW="${GW:-}"

# Debian 12 cloud image
IMG_URL="${IMG_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
IMG_NAME="${IMG_NAME:-debian-12-genericcloud-amd64.qcow2}"

# openHABian setup (official)
OPENHABIAN_SETUP_URL="${OPENHABIAN_SETUP_URL:-https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh}"
# Optional openHABian branch (leave empty for default)
CLONEBRANCH="${CLONEBRANCH:-}"
### ===============================================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Lipsește: $1"; exit 1; }; }
need qm
need pvesm
need wget
need curl
need openssl

if qm status "$VMID" >/dev/null 2>&1; then
  echo "Eroare: VMID $VMID există deja."
  exit 1
fi

# Auto-select storage for VM disk
if [[ -z "$STORAGE" ]]; then
  if pvesm status | awk 'NR>1{print $1}' | grep -qx "local-zfs"; then
    STORAGE="local-zfs"
  elif pvesm status | awk 'NR>1{print $1}' | grep -qx "local"; then
    STORAGE="local"
  else
    echo "Eroare: nu găsesc storage local-zfs/local. Vezi: pvesm status"
    exit 1
  fi
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  echo "Eroare: storage '$STORAGE' nu există. Disponibile:"
  pvesm status
  exit 1
fi

WORKDIR="/var/lib/vz/template/cache"
mkdir -p "$WORKDIR"
IMG="$WORKDIR/$IMG_NAME"

echo "[1/10] Descarc Debian cloud image (amd64)..."
if [[ ! -f "$IMG" ]]; then
  wget -O "$IMG" "$IMG_URL"
else
  echo " - deja există: $IMG"
fi

# Cloud-init IP config
IPCONFIG="ip=dhcp"
if [[ -n "$IP_CIDR" && -n "$GW" ]]; then
  IPCONFIG="ip=${IP_CIDR},gw=${GW}"
fi

echo "[2/10] Creez VM (VGA standard, fără serial)..."
qm create "$VMID" \
  --name "$VMNAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --cores "$CORES" \
  --memory "$RAM_MB" \
  --scsihw virtio-scsi-single \
  --agent 1 \
  --rng0 source=/dev/urandom \
  --vga std

echo "[3/10] Import disk pe storage: $STORAGE ..."
qm importdisk "$VMID" "$IMG" "$STORAGE" --format qcow2
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"

echo "[4/10] Cloud-Init drive + boot order..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "[5/10] Network..."
NETCFG="virtio,bridge=${BRIDGE}"
if [[ -n "$VLAN_TAG" ]]; then
  NETCFG="${NETCFG},tag=${VLAN_TAG}"
fi
qm set "$VMID" --net0 "$NETCFG"
qm set "$VMID" --ipconfig0 "$IPCONFIG"

echo "[6/10] Setez user/parola cloud-init: ${CIUSER}/${CIPASS} ..."
qm set "$VMID" --ciuser "$CIUSER" --cipassword "$CIPASS"

# password hash (sha512) for in-guest setup (we'll set again inside guest too)
PASSHASH="$(openssl passwd -6 "$CIPASS")"

echo "[7/10] Injectez automatizare FIRST-BOOT prin cloud-init (fără snippets)..."
# We write vendor-data via qm set --civendor (supported) is NOT available in all versions.
# Alternative: use qm set --cicustom needs snippets (we avoid).
# So we use cloud-init standard + run once after first boot by pushing a systemd unit via qm guest exec.
# => We'll start VM, wait qemu-guest-agent, then push files with qm guest exec + cat heredoc.
# This keeps everything snippet-free and works on Proxmox 8.x.

echo "[8/10] Pornesc VM..."
qm start "$VMID"

echo "[9/10] Aștept qemu-guest-agent (max ~5 min)..."
# Wait until guest agent responds
for i in {1..60}; do
  if qm guest ping "$VMID" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if ! qm guest ping "$VMID" >/dev/null 2>&1; then
  echo "Eroare: qemu-guest-agent nu răspunde încă."
  echo "Verifică în VM dacă pachetul qemu-guest-agent este instalat (cloud image de obicei îl are)."
  echo "Poți încerca manual: qm guest ping $VMID"
  exit 1
fi

echo "[10/10] Configurez automat în guest: hostname + openHABian unattended + auto openhabian-config pe tty1..."

# Helper to exec bash inside guest as root using guest agent
gexec() {
  local cmd="$1"
  qm guest exec "$VMID" -- bash -lc "$cmd" >/dev/null
}

# Ensure packages and guest agent (just in case)
gexec "apt-get update -y"
gexec "apt-get install -y qemu-guest-agent curl git sudo ca-certificates openssh-server"
gexec "systemctl enable --now qemu-guest-agent || true"

# Set hostname + /etc/hosts
gexec "hostnamectl set-hostname '$VMNAME'"
gexec "grep -q '127.0.1.1' /etc/hosts && sed -i \"s/^127\\.0\\.1\\.1.*/127.0.1.1 $VMNAME/\" /etc/hosts || echo \"127.0.1.1 $VMNAME\" >> /etc/hosts"

# Ensure user exists and has the right password (cloud-init should have, but we enforce)
gexec "id -u '$CIUSER' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo '$CIUSER'"
gexec "usermod -aG sudo '$CIUSER'"
gexec "usermod --password '$PASSHASH' '$CIUSER'"
gexec "printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$CIUSER' > /etc/sudoers.d/90-$CIUSER && chmod 440 /etc/sudoers.d/90-$CIUSER"

# Prepare openhabian.conf minimal
OPENHABIAN_CONF=$'# minimal openhabian.conf for unattended\nhw=x86\nhwarch=amd64\nosrelease=debian\n'
if [[ -n "$CLONEBRANCH" ]]; then
  OPENHABIAN_CONF+=$"clonebranch=${CLONEBRANCH}\n"
fi
OPENHABIAN_CONF_B64="$(printf "%s" "$OPENHABIAN_CONF" | base64 -w0)"

gexec "echo '$OPENHABIAN_CONF_B64' | base64 -d > /etc/openhabian.conf && chmod 0644 /etc/openhabian.conf"

# Create a one-shot systemd service that runs openhabian unattended once
gexec "cat > /etc/systemd/system/openhabian-unattended.service <<'EOF'
[Unit]
Description=openHABian unattended setup (one-shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc 'set -e; mkdir -p /opt/openhabian; curl -fsSL \"${OPENHABIAN_SETUP_URL}\" -o /opt/openhabian/openhabian-setup.sh; chmod +x /opt/openhabian/openhabian-setup.sh; /opt/openhabian/openhabian-setup.sh unattended'

[Install]
WantedBy=multi-user.target
EOF"

gexec "systemctl daemon-reload"
gexec "systemctl enable --now openhabian-unattended.service"

# Auto-start openhabian-config after login on tty1 (NOT SSH)
gexec "cat > /etc/profile.d/openhabian-tty1.sh <<'EOF'
#!/usr/bin/env bash
case \$- in *i*) ;; *) return ;; esac
[ \"\$(tty)\" = \"/dev/tty1\" ] || return
[ -n \"\${OPENHABIAN_TTY1_STARTED:-}\" ] && return
export OPENHABIAN_TTY1_STARTED=1
if command -v openhabian-config >/dev/null 2>&1; then
  exec openhabian-config
fi
EOF
chmod +x /etc/profile.d/openhabian-tty1.sh"

echo
echo "✅ Gata. VM $VMID a fost creat și configurat."
echo " - Storage disk: $STORAGE"
echo " - Login console: ${CIUSER} / ${CIPASS}"
echo " - În Proxmox Console (tty1): după login pornește openhabian-config"
echo " - openHAB UI: http://<IP_VM>:8080 (după ce se termină serviciul openhabian-unattended)"
echo
echo "Poți verifica progresul instalării în guest (din Proxmox):"
echo "  qm guest exec $VMID -- journalctl -u openhabian-unattended.service -f"
