#!/usr/bin/env bash
set -euo pipefail

# =======================
# CONFIG (override via env)
# =======================
CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-OpenHabian}"
PASSWORD="${PASSWORD:-openhabian}"

CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"          # MB
DISK_SIZE="${DISK_SIZE:-16}"      # GB
BRIDGE="${BRIDGE:-vmbr0}"

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # usually 'local' holds templates
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"           # auto: local-zfs -> local
UNPRIVILEGED="${UNPRIVILEGED:-1}"
NESTING="${NESTING:-1}"

# 0 = like screenshot (banner + prompt, you run sudo openhabian-config manually)
# 1 = after login on tty1 it jumps into openhabian-config automatically
AUTO_OPENHABIAN_CONFIG="${AUTO_OPENHABIAN_CONFIG:-0}"

# =======================
# Helpers
# =======================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need pct
need pveam
need pvesm
need awk
need grep
need tail

echo "== openHABian LXC (amd64) One-Click Installer =="

# Fail fast if CT exists
if pct status "$CTID" >/dev/null 2>&1; then
  echo "ERROR: CTID $CTID already exists."
  exit 1
fi

# Auto rootfs storage selection
if [[ -z "$ROOTFS_STORAGE" ]]; then
  if pvesm status | awk 'NR>1{print $1}' | grep -qx "local-zfs"; then
    ROOTFS_STORAGE="local-zfs"
  else
    ROOTFS_STORAGE="local"
  fi
fi

# Validate storages
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$TEMPLATE_STORAGE"; then
  echo "ERROR: TEMPLATE_STORAGE '$TEMPLATE_STORAGE' does not exist. Available:"
  pvesm status
  exit 1
fi
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$ROOTFS_STORAGE"; then
  echo "ERROR: ROOTFS_STORAGE '$ROOTFS_STORAGE' does not exist. Available:"
  pvesm status
  exit 1
fi

echo "[1/9] Updating template catalog..."
pveam update >/dev/null

echo "[2/9] Selecting latest Debian 12 amd64 template..."
TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
  | tail -n1 || true)"

if [[ -z "$TEMPLATE" ]]; then
  echo "ERROR: Could not find Debian 12 amd64 template."
  echo "Try: pveam available --section system | grep debian-12"
  exit 1
fi

echo " - Template: $TEMPLATE"
echo " - Template storage: $TEMPLATE_STORAGE"
echo " - Rootfs storage:   $ROOTFS_STORAGE"

echo "[3/9] Downloading template (if missing)..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || true

FEATURES=""
[[ "$NESTING" == "1" ]] && FEATURES="nesting=1"

echo "[4/9] Creating container CT $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --password "$PASSWORD" \
  --unprivileged "$UNPRIVILEGED" \
  --features "$FEATURES"

echo "[5/9] Starting container..."
pct start "$CTID"
sleep 5

echo "[6/9] Bootstrapping base packages + user openhabian..."
pct exec "$CTID" -- bash -lc "
set -e
apt-get update -y
apt-get install -y curl git sudo ca-certificates wget tar gpg whiptail locales unzip
# create user
id -u openhabian >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo openhabian
echo 'root:${PASSWORD}' | chpasswd
echo 'openhabian:${PASSWORD}' | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' openhabian > /etc/sudoers.d/90-openhabian
chmod 440 /etc/sudoers.d/90-openhabian
"

echo "[7/9] Installing Java 21 JDK from OFFICIAL source (Eclipse Adoptium / Temurin) ..."
pct exec "$CTID" -- bash -lc "
set -e
mkdir -p /opt/java
cd /opt/java

ARCH=\$(dpkg --print-architecture)
if [ \"\$ARCH\" != \"amd64\" ]; then
  echo \"Unsupported arch for this script: \$ARCH\"
  exit 1
fi

# Official Adoptium API delivers latest GA Temurin 21 JDK for linux x64
JDK_URL='https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse'
wget -O temurin21.tar.gz \"\$JDK_URL\"

tar -xzf temurin21.tar.gz
rm -f temurin21.tar.gz

JDK_DIR=\$(ls -d /opt/java/jdk-21* 2>/dev/null | head -n1)
if [ -z \"\$JDK_DIR\" ]; then
  echo 'Failed to locate extracted JDK directory in /opt/java'
  exit 1
fi

# Register as system default Java
update-alternatives --install /usr/bin/java  java  \"\$JDK_DIR/bin/java\"  2100
update-alternatives --install /usr/bin/javac javac \"\$JDK_DIR/bin/javac\" 2100
update-alternatives --set java  \"\$JDK_DIR/bin/java\"
update-alternatives --set javac \"\$JDK_DIR/bin/javac\"

# Export JAVA_HOME
cat > /etc/profile.d/java.sh <<EOF
export JAVA_HOME=\$JDK_DIR
export PATH=\\\$JAVA_HOME/bin:\\\$PATH
EOF
chmod +x /etc/profile.d/java.sh

# Validate
. /etc/profile.d/java.sh
java -version
"

echo "[8/9] Installing openHABian (unattended) + enabling openHAB..."
pct exec "$CTID" -- bash -lc "
set -e
# minimal openhabian.conf for unattended
cat > /etc/openhabian.conf <<'EOF'
hw=x86
hwarch=amd64
osrelease=debian
EOF

curl -fsSL https://raw.githubusercontent.com/openhab/openhabian/main/openhabian-setup.sh -o /opt/openhabian-setup.sh
chmod +x /opt/openhabian-setup.sh

# run unattended (installs openHAB, config, services)
# JAVA is already 21, so 5.x upgrades work.
 /opt/openhabian-setup.sh unattended

systemctl daemon-reload || true
systemctl enable --now openhab || true
"

echo "[9/9] Console behavior (optional auto openhabian-config on tty1)..."
if [[ "$AUTO_OPENHABIAN_CONFIG" == "1" ]]; then
  pct exec "$CTID" -- bash -lc "
set -e
cat > /etc/profile.d/zz-openhabian-tty1.sh <<'EOF'
#!/usr/bin/env bash
case \$- in *i*) ;; *) return ;; esac
[ \"\$(tty)\" = \"/dev/tty1\" ] || return
command -v openhabian-config >/dev/null 2>&1 && exec openhabian-config
EOF
chmod +x /etc/profile.d/zz-openhabian-tty1.sh
"
fi

echo
echo "✅ SUCCESS"
echo "CTID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Login (console/ssh): openhabian / $PASSWORD"
echo "Root password: $PASSWORD"
echo "Get IP: pct exec $CTID -- hostname -I"
echo "openHAB UI: http://<IP>:8080"
echo "Run menu: sudo openhabian-config"
