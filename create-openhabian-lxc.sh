#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# openHABian LXC (amd64) for Proxmox - fully automated
# - Static IP: 192.168.1.232/24 (openHAB on :8080)
# - Hostname forced to: OpenHabian (GUI will show: 150 (OpenHabian))
# - Passwords: openhabian (user + root)
# - Java 21 JDK: OFFICIAL Eclipse Adoptium/Temurin tar.gz (no apt repo)
# - Fix for systemd/openhab status=127: JAVA_HOME/PATH drop-in override
# ==========================================================

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

# Static IP requested
IP_CIDR="${IP_CIDR:-192.168.1.232/24}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # where templates live (usually local)
ROOTFS_STORAGE="${ROOTFS_STORAGE:-}"           # auto: local-zfs -> local
UNPRIVILEGED="${UNPRIVILEGED:-1}"
NESTING="${NESTING:-1}"

# 0 = like screenshot (banner + prompt)
# 1 = auto run openhabian-config on tty1 after login
AUTO_OPENHABIAN_CONFIG="${AUTO_OPENHABIAN_CONFIG:-0}"

# =======================
# Helpers
# =======================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need pct; need pveam; need pvesm; need awk; need grep; need tail; need sed

echo "== openHABian LXC (amd64) Installer =="

if pct status "$CTID" >/dev/null 2>&1; then
  echo "ERROR: CTID $CTID already exists."
  exit 1
fi

# Auto select rootfs storage
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

echo "[1/12] Updating template catalog..."
pveam update >/dev/null

echo "[2/12] Selecting latest Debian 12 amd64 template..."
TEMPLATE="$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' \
  | tail -n1 || true)"

if [[ -z "$TEMPLATE" ]]; then
  echo "ERROR: Could not find Debian 12 amd64 template."
  echo "Try: pveam available --section system | grep debian-12"
  exit 1
fi

echo " - Template:          $TEMPLATE"
echo " - Template storage:  $TEMPLATE_STORAGE"
echo " - Rootfs storage:    $ROOTFS_STORAGE"
echo " - Hostname:          $HOSTNAME"
echo " - Network:           ${IP_CIDR} gw ${GATEWAY} (bridge ${BRIDGE})"
echo " - openHAB UI:        http://${IP_CIDR%/*}:8080"

echo "[3/12] Downloading template (if missing)..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || true

FEATURES=""
[[ "$NESTING" == "1" ]] && FEATURES="nesting=1"

NETCFG="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"

echo "[4/12] Creating container CT $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
  --net0 "$NETCFG" \
  --nameserver "${DNS1} ${DNS2}" \
  --password "$PASSWORD" \
  --unprivileged "$UNPRIVILEGED" \
  --features "$FEATURES"

# Extra safety: force hostname at Proxmox level (GUI label uses this)
pct set "$CTID" --hostname "$HOSTNAME"

echo "[5/12] Starting container..."
pct start "$CTID"
sleep 5

echo "[6/12] Force hostname inside container (/etc/hostname + /etc/hosts)..."
pct exec "$CTID" -- bash -lc "
set -e
echo '$HOSTNAME' > /etc/hostname
hostname '$HOSTNAME' || true
# ensure /etc/hosts has 127.0.1.1 mapping
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1\t$HOSTNAME/' /etc/hosts
else
  echo -e '127.0.1.1\t$HOSTNAME' >> /etc/hosts
fi
"

echo "[7/12] Base packages + user openhabian..."
pct exec "$CTID" -- bash -lc "
set -e
apt-get update -y
apt-get install -y curl git sudo ca-certificates wget tar gpg whiptail locales unzip iproute2
id -u openhabian >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo openhabian
echo 'root:${PASSWORD}' | chpasswd
echo 'openhabian:${PASSWORD}' | chpasswd
printf '%s ALL=(ALL) NOPASSWD:ALL\n' openhabian > /etc/sudoers.d/90-openhabian
chmod 440 /etc/sudoers.d/90-openhabian
"

echo "[8/12] Installing Java 21 JDK (OFFICIAL Eclipse Adoptium/Temurin tar.gz)..."
pct exec "$CTID" -- bash -lc "
set -e
mkdir -p /opt/java
cd /opt/java

ARCH=\$(dpkg --print-architecture)
if [ \"\$ARCH\" != \"amd64\" ]; then
  echo \"Unsupported arch: \$ARCH\"
  exit 1
fi

JDK_URL='https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse'
wget -O temurin21.tar.gz \"\$JDK_URL\"
tar -xzf temurin21.tar.gz
rm -f temurin21.tar.gz

JDK_DIR=\$(ls -d /opt/java/jdk-21* 2>/dev/null | head -n1)
if [ -z \"\$JDK_DIR\" ]; then
  echo 'Failed to locate extracted JDK in /opt/java'
  exit 1
fi

update-alternatives --install /usr/bin/java  java  \"\$JDK_DIR/bin/java\"  2100
update-alternatives --install /usr/bin/javac javac \"\$JDK_DIR/bin/javac\" 2100
update-alternatives --set java  \"\$JDK_DIR/bin/java\"
update-alternatives --set javac \"\$JDK_DIR/bin/javac\"

cat > /etc/profile.d/java.sh <<EOF
export JAVA_HOME=\$JDK_DIR
export PATH=\\\$JAVA_HOME/bin:\\\$PATH
EOF
chmod +x /etc/profile.d/java.sh

. /etc/profile.d/java.sh
java -version
"

echo "[9/12] Wiring Java 21 into systemd for openHAB (fix status=127)..."
pct exec "$CTID" -- bash -lc '
set -e
JDK_DIR="$(ls -d /opt/java/jdk-21* 2>/dev/null | head -n1)"
[ -n "$JDK_DIR" ] || { echo "ERROR: JDK_DIR not found"; exit 1; }

mkdir -p /etc/systemd/system/openhab.service.d
cat > /etc/systemd/system/openhab.service.d/override.conf <<EOF
[Service]
Environment="JAVA_HOME=${JDK_DIR}"
Environment="PATH=${JDK_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

systemctl daemon-reload
'

echo "[10/12] Installing openHABian (clone repo) + unattended setup..."
pct exec "$CTID" -- bash -lc "
set -e
rm -rf /opt/openhabian
git clone --depth 1 https://github.com/openhab/openhabian.git /opt/openhabian

cat > /etc/openhabian.conf <<'EOF'
hw=x86
hwarch=amd64
osrelease=debian
EOF

bash /opt/openhabian/openhabian-setup.sh unattended
"

echo "[11/12] Enabling + starting openHAB..."
pct exec "$CTID" -- bash -lc '
set -e
systemctl daemon-reload || true
systemctl enable openhab || true
systemctl restart openhab || true

# Give it time to open ports on first start
sleep 5

echo "openhab.service status:"
systemctl status openhab --no-pager || true

echo "Listening ports (8080/8443):"
ss -tulpn | grep -E ":(8080|8443)" || true
'

echo "[12/12] Console behavior (optional auto openhabian-config on tty1)..."
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
echo "CTID:        $CTID"
echo "GUI name:    $CTID ($HOSTNAME)"
echo "Hostname:    $HOSTNAME"
echo "IP:          ${IP_CIDR%/*}"
echo "Login:       openhabian / $PASSWORD"
echo "Root pass:   $PASSWORD"
echo "openHAB UI:  http://${IP_CIDR%/*}:8080"
echo "Menu:        sudo openhabian-config"
