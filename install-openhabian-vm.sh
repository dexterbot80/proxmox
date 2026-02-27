#!/usr/bin/env bash
set -euo pipefail

### ====== CONFIG (suprascrii cu env la rulare) ======
VMID="${VMID:-120}"
VMNAME="${VMNAME:-OpenHabian}"      # hostname + nume VM; ca să apară "OpenHabian login:"
STORAGE="${STORAGE:-local-lvm}"     # ex: local-lvm, local, zfs
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
DISK_GB="${DISK_GB:-32}"
VLAN_TAG="${VLAN_TAG:-}"           # ex: 20 (gol = fără VLAN)

# user/parola implicite (cum ai cerut)
CIUSER="${CIUSER:-openhabian}"
CIPASS="${CIPASS:-openhabian}"

SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}" # opțional: /root/.ssh/id_rsa.pub

# IP static opțional. Dacă sunt goale => DHCP
IP_CIDR="${IP_CIDR:-}"
GW="${GW:-}"

# Branch openHABian (opțional). Gol => default.
CLONEBRANCH="${CLONEBRANCH:-}"

# Debian 12 cloud (amd64)
IMG_URL="${IMG_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}"
IMG_NAME="${IMG_NAME:-debian-12-genericcloud-amd64.qcow2}"

# openHABian setup script (oficial)
OPENHABIAN_SETUP_URL="${OPENHABIAN_SETUP_URL:-https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh}"
### ===================================================

require() { command -v "$1" >/dev/null 2>&1 || { echo "Lipsește comanda: $1"; exit 1; }; }

require qm
require pvesm
require wget
require python3
require base64
require curl

if qm status "$VMID" >/dev/null 2>&1; then
  echo "Eroare: VMID $VMID există deja."
  exit 1
fi

# Pentru cicustom user=local:snippets/... trebuie ca storage-ul "local"
# să aibă bifat Content: "Snippets" în Proxmox GUI.
SNIPPETS_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPETS_DIR"

WORKDIR="/var/lib/vz/template/cache"
mkdir -p "$WORKDIR"

IMG="$WORKDIR/$IMG_NAME"

echo "[1/8] Descarc imaginea Debian cloud (amd64)..."
if [[ ! -f "$IMG" ]]; then
  wget -O "$IMG" "$IMG_URL"
else
  echo " - Imagine deja existentă: $IMG"
fi

echo "[2/8] Generez cloud-init user-data (openHABian unattended + tty1 login -> openhabian-config)..."
USERDATA="$SNIPPETS_DIR/${VMNAME}-userdata.yaml"
META="$SNIPPETS_DIR/${VMNAME}-meta.yaml"

SSH_KEY_BLOCK=""
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  if [[ ! -f "$SSH_PUBKEY_FILE" ]]; then
    echo "Eroare: SSH_PUBKEY_FILE nu există: $SSH_PUBKEY_FILE"
    exit 1
  fi
  SSH_KEY_CONTENT="$(<"$SSH_PUBKEY_FILE")"
  SSH_KEY_BLOCK=$'\n    ssh_authorized_keys:\n      - '"${SSH_KEY_CONTENT}"$'\n'
fi

IPCONFIG="ip=dhcp"
if [[ -n "$IP_CIDR" && -n "$GW" ]]; then
  IPCONFIG="ip=${IP_CIDR},gw=${GW}"
fi

# openhabian.conf minimal pentru unattended
OPENHABIAN_CONF_CONTENT=$'# minimal openhabian.conf for unattended\nhw=x86\nhwarch=amd64\nosrelease=debian\n'
if [[ -n "$CLONEBRANCH" ]]; then
  OPENHABIAN_CONF_CONTENT+=$"clonebranch=${CLONEBRANCH}\n"
fi
CONF_B64="$(printf "%s" "$OPENHABIAN_CONF_CONTENT" | base64 -w0)"

PASSHASH="$(python3 - <<PY
import crypt
print(crypt.crypt("${CIPASS}", crypt.mksalt(crypt.METHOD_SHA512)))
PY
)"

cat > "$USERDATA" <<EOF
#cloud-config
hostname: ${VMNAME}
manage_etc_hosts: true

users:
  - name: ${CIUSER}
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: false
    passwd: ${PASSHASH}${SSH_KEY_BLOCK}

package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - git
  - ca-certificates
  - sudo

runcmd:
  # agent
  - [ bash, -lc, "systemctl enable --now qemu-guest-agent || true" ]

  # hostname persistent (ca să vezi 'OpenHabian login:')
  - [ bash, -lc, "hostnamectl set-hostname ${VMNAME}" ]

  # openhabian.conf
  - [ bash, -lc, "echo '${CONF_B64}' | base64 -d > /etc/openhabian.conf" ]
  - [ bash, -lc, "chmod 0644 /etc/openhabian.conf" ]

  # openHABian unattended install
  - [ bash, -lc, "mkdir -p /opt/openhabian" ]
  - [ bash, -lc, "curl -fsSL '${OPENHABIAN_SETUP_URL}' -o /opt/openhabian/openhabian-setup.sh" ]
  - [ bash, -lc, "chmod +x /opt/openhabian/openhabian-setup.sh" ]
  - [ bash, -lc, "/opt/openhabian/openhabian-setup.sh unattended" ]

  # === LOGIN PROMPT pe tty1 + AUTO openhabian-config DUPĂ login ===
  # rulează doar în shell interactiv și doar pe /dev/tty1 (Proxmox Console)
  - [ bash, -lc, "cat > /etc/profile.d/openhabian-tty1.sh << 'EOS'\n#!/usr/bin/env bash\n# doar shell interactiv\ncase $- in *i*) ;; *) return ;; esac\n# doar consola locală tty1\n[ \"$(tty)\" = \"/dev/tty1\" ] || return\n# evită loop dacă se deschide subshell\n[ -n \"${OPENHABIAN_TTY1_STARTED:-}\" ] && return\nexport OPENHABIAN_TTY1_STARTED=1\n\n# pornește openhabian-config dacă există\nif command -v openhabian-config >/dev/null 2>&1; then\n  exec openhabian-config\nfi\nEOS" ]
  - [ bash, -lc, "chmod +x /etc/profile.d/openhabian-tty1.sh" ]
EOF

cat > "$META" <<EOF
instance-id: ${VMNAME}-${VMID}
local-hostname: ${VMNAME}
EOF

echo "[3/8] Creez VM-ul..."
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
  --serial0 socket \
  --vga serial0

echo "[4/8] Import disk și atașez..."
qm importdisk "$VMID" "$IMG" "$STORAGE" --format qcow2
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"

echo "[5/8] Network + Cloud-Init..."
NETCFG="virtio,bridge=${BRIDGE}"
if [[ -n "$VLAN_TAG" ]]; then
  NETCFG="${NETCFG},tag=${VLAN_TAG}"
fi
qm set "$VMID" --net0 "$NETCFG"

qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0

qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USERDATA"),meta=local:snippets/$(basename "$META")"
qm set "$VMID" --ciuser "$CIUSER" --cipassword "$CIPASS"
qm set "$VMID" --ipconfig0 "$IPCONFIG"

echo "[6/8] Resize disk la ${DISK_GB}G..."
qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "[7/8] Pornesc VM..."
qm start "$VMID"

echo
echo "[8/8] Gata."
echo "VMID: $VMID | Nume/hostname: $VMNAME | user/parola: ${CIUSER}/${CIPASS} | IP: $IPCONFIG"
echo "Proxmox Console (tty1): vei vedea prompt de login, iar după login pornește openhabian-config."
echo "openHAB UI: http://<IP_VM>:8080"
echo
echo "IP (după boot, când agentul pornește):"
echo "  qm guest cmd $VMID network-get-interfaces"
