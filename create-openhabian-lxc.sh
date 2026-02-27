#!/usr/bin/env bash
set -euo pipefail

### ===== CONFIG (override via env) =====
CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-openhabian}"     # numele containerului
PASSWORD="${PASSWORD:-openhabian}"     # root + user openhabian
DISK_SIZE="${DISK_SIZE:-8}"            # GB
MEMORY="${MEMORY:-2048}"               # MB
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"

# Storage auto: template pe local, rootfs pe local-zfs dacă există
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"      # 1 recomandat
NESTING="${NESTING:-1}"                # necesar pentru unele setup-uri
### ====================================

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need pct; need pveam; need pvesm; need awk; need grep; need tail

echo "== openHABian LXC Installer =="

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CTID $CTID există deja."
  exit 1
fi

# autodetect rootfs storage
if [[ -z "$ROOTFS_STORAGE" ]]; then
  if pvesm status | awk 'NR>1{print $1}' | grep -qx "local-zfs"; then
    ROOTFS_STORAGE="local-zfs"
  else
    ROOTFS_STORAGE="local"
  fi
fi

# validate storages
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "Storage pentru template '$TEMPLATE_STORAGE' nu există. Available:"
  pvesm status; exit 1
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$ROOTFS_STORAGE"; then
  echo "Storage pentru rootfs '$ROOTFS_STORAGE' nu există. Available:"
  pvesm status; exit 1
fi

echo "[1/8] Update template index..."
pveam update >/dev/null

echo "[2/8] Detect latest Debian 12 amd64 template..."
TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
  | tail -n1 || true)"

if [[ -z "$TEMPLATE" ]]; then
  echo "Nu găsesc template Debian 12 amd64."
  echo "Rulează: pveam available --section system | grep debian-12"
  exit 1
fi

echo " - Template: $TEMPLATE"
echo " - Template storage: $TEMPLATE_STORAGE"
echo " - Rootfs storage:   $ROOTFS_STORAGE"

echo "[3/8] Download template (if needed)..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || true

echo "[4/8] Create LXC..."
FEATURES=""
[[ "$NESTING" == "1" ]] && FEATURES="nesting=1"

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --password "$PASSWORD" \
  --features "$FEATURES" \
  --unprivileged "$UNPRIVILEGED"

echo "[5/8] Start container..."
pct start "$CTID"
sleep 5

echo "[6/8] Bootstrap packages + create user openhabian..."
pct exec "$CTID" -- bash -lc "
set -e
apt-get update -y
apt-get install -y curl git sudo ca-certificates systemd whiptail locales
# user openhabian
id -u openhabian >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo openhabian
echo 'root:${PASSWORD}' | chpasswd
echo 'openhabian:${PASSWORD}' | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' openhabian > /etc/sudoers.d/90-openhabian
chmod 440 /etc/sudoers.d/90-openhabian
"

echo "[7/8] Install openHABian (unattended)... (poate dura 10-30 min)"
pct exec "$CTID" -- bash -lc "
set -e
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

echo "[8/8] Auto-start openhabian-config after login on tty1 (console)..."
pct exec "$CTID" -- bash -lc "
cat > /etc/profile.d/openhabian-config.sh <<'EOF'
#!/usr/bin/env bash
case \$- in *i*) ;; *) return ;; esac
[ \"\$(tty)\" = \"/dev/tty1\" ] || return
command -v openhabian-config >/dev/null 2>&1 && exec openhabian-config
EOF
chmod +x /etc/profile.d/openhabian-config.sh
"

echo
echo "✅ DONE"
echo "CTID: $CTID"
echo "Console login:"
echo "  user: openhabian"
echo "  pass: $PASSWORD"
echo "root pass: $PASSWORD"
echo "IP: pct exec $CTID -- hostname -I"
echo "openHAB UI: http://<IP>:8080"
