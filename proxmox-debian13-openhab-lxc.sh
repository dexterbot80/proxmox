#!/usr/bin/env bash
set -euo pipefail

# ===============================
# DEFAULT VALUES
# ===============================
CTID=""
HOSTNAME="openhab"
STORAGE="local-lvm"
BRIDGE="vmbr0"
IP_CIDR=""
GATEWAY=""
DNS="1.1.1.1 8.8.8.8"
CT_PASSWORD=""
OPENHAB_CHANNEL="stable"
INSTALL_ADDONS="1"
JAVA_PKG="openjdk-21-jre-headless"
OS_USER="openhabian"
OS_PASS="openhabian"

# ===============================
# ARGUMENT PARSER
# ===============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --ip) IP_CIDR="$2"; shift 2 ;;
    --gw) GATEWAY="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --root-pass) CT_PASSWORD="$2"; shift 2 ;;
    --user) OS_USER="$2"; shift 2 ;;
    --user-pass) OS_PASS="$2"; shift 2 ;;
    --channel) OPENHAB_CHANNEL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

log(){ echo -e "\n[openhab-lxc] $*\n"; }
die(){ echo "[openhab-lxc] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root on Proxmox host"

command -v pct >/dev/null 2>&1 || die "pct not found"
command -v pveam >/dev/null 2>&1 || die "pveam not found"

[[ -n "$CTID" ]] || die "--ctid required"
[[ -n "$CT_PASSWORD" ]] || die "--root-pass required"

if [[ -n "$IP_CIDR" && -z "$GATEWAY" ]]; then
  die "--gw required when --ip is set"
fi

if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID $CTID already exists"
fi

log "Updating template list"
pveam update >/dev/null 2>&1 || true

log "Selecting Debian 13 template"
TEMPLATE=$(pveam available --section system \
  | awk '{print $2}' \
  | grep -E '^debian-13-standard_.*\.tar\.zst$' \
  | sort -V \
  | tail -n1)

[[ -n "$TEMPLATE" ]] || die "Debian 13 template not found"

if ! pveam list local | awk '{print $1}' | grep -qx "$TEMPLATE"; then
  log "Downloading Debian 13 template"
  pveam download local "$TEMPLATE"
fi

log "Creating LXC container"

NET="name=eth0,bridge=$BRIDGE"
if [[ -n "$IP_CIDR" ]]; then
  NET="$NET,ip=$IP_CIDR,gw=$GATEWAY"
else
  NET="$NET,ip=dhcp"
fi

pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --net0 "$NET" \
  --nameserver "$DNS" \
  --password "$CT_PASSWORD" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

pct start "$CTID"

log "Waiting for container..."
sleep 5

pct exec "$CTID" -- bash -lc "
set -e
export DEBIAN_FRONTEND=noninteractive

apt update -y
apt install -y ca-certificates curl gnupg

apt install -y $JAVA_PKG

tmp=\$(mktemp)
curl -fsSL https://openhab.jfrog.io/artifactory/api/gpg/key/public | gpg --dearmor > \$tmp
install -d /usr/share/keyrings
install -m 0644 \$tmp /usr/share/keyrings/openhab.gpg
rm -f \$tmp

echo 'deb [signed-by=/usr/share/keyrings/openhab.gpg] https://openhab.jfrog.io/artifactory/openhab-linuxpkg $OPENHAB_CHANNEL main' > /etc/apt/sources.list.d/openhab.list

apt update -y
apt install -y openhab

mkdir -p /var/lib/openhab/{tmp,etc,cache}
mkdir -p /etc/openhab
mkdir -p /var/log/openhab
chown -R openhab:openhab /var/lib/openhab /etc/openhab /var/log/openhab

systemctl enable --now openhab

if ! id -u $OS_USER >/dev/null 2>&1; then
  useradd -m -s /bin/bash $OS_USER
fi
echo \"$OS_USER:$OS_PASS\" | chpasswd
"

log "DONE"
echo "Container ID: $CTID"
if [[ -n "$IP_CIDR" ]]; then
  echo "OpenHAB UI: http://${IP_CIDR%/*}:8080"
else
  echo "IP via DHCP"
fi
echo "User: $OS_USER"
