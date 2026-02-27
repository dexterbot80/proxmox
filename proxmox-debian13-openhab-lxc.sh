#!/usr/bin/env bash
set -euo pipefail

# =========================
# CONFIG (override via env)
# =========================
CTID="${CTID:-110}"
HOSTNAME="${HOSTNAME:-openhab}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"

# Static IP in Proxmox (recommended)
IP_CIDR="${IP_CIDR:-}"       # ex: 192.168.1.232/24  (optional, but recommended)
GATEWAY="${GATEWAY:-}"       # ex: 192.168.1.1       (required if IP_CIDR set)
DNS="${DNS:-1.1.1.1 8.8.8.8}"

# Container root password (required by pct create)
CT_PASSWORD="${CT_PASSWORD:-}"

# openHAB
OPENHAB_CHANNEL="${OPENHAB_CHANNEL:-stable}"   # stable | testing | unstable
INSTALL_ADDONS="${INSTALL_ADDONS:-1}"          # 1=yes, 0=no
JAVA_PKG="${JAVA_PKG:-openjdk-21-jre-headless}"

# Requested OS user/pass
OS_USER="${OS_USER:-openhabian}"
OS_PASS="${OS_PASS:-openhabian}"

log(){ echo -e "\n[openhab-lxc] $*\n"; }
die(){ echo "[openhab-lxc] ERROR: $*" >&2; exit 1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Rulează pe Proxmox ca root."; }

validate() {
  command -v pct >/dev/null 2>&1 || die "pct nu există. Rulează scriptul pe Proxmox."
  command -v pveam >/dev/null 2>&1 || die "pveam nu există. Rulează scriptul pe Proxmox."

  [[ -n "${CT_PASSWORD}" ]] || die "Setează CT_PASSWORD (parola root din container)."

  case "${OPENHAB_CHANNEL}" in stable|testing|unstable) ;; *) die "OPENHAB_CHANNEL invalid";; esac

  if [[ -n "${IP_CIDR}" || -n "${GATEWAY}" ]]; then
    [[ -n "${IP_CIDR}" && -n "${GATEWAY}" ]] || die "Dacă setezi IP_CIDR trebuie să setezi și GATEWAY."
  fi

  if pct status "${CTID}" >/dev/null 2>&1; then
    die "CTID ${CTID} există deja. Alege alt CTID."
  fi
}

pick_debian13_template() {
  # Ensure template list is fresh-ish
  pveam update >/dev/null 2>&1 || true

  local tmpl
  tmpl="$(pveam available --section system \
    | awk '{print $2}' \
    | grep -E '^debian-13-standard_.*\.tar\.zst$' \
    | sort -V \
    | tail -n 1 || true)"
  [[ -n "${tmpl}" ]] || die "Nu găsesc template Debian 13. Verifică: pveam available --section system"
  echo "${tmpl}"
}

ensure_template_downloaded() {
  local tmpl="$1"
  if ! pveam list local | awk '{print $1}' | grep -qx "${tmpl}"; then
    log "Download template Debian 13: ${tmpl}"
    pveam download local "${tmpl}"
  else
    log "Template Debian 13 deja există local: ${tmpl}"
  fi
}

create_container() {
  local tmpl="$1"
  log "Creez LXC Debian 13 (CTID=${CTID}, hostname=${HOSTNAME})"

  local net0="name=eth0,bridge=${BRIDGE}"
  if [[ -n "${IP_CIDR}" ]]; then
    net0="${net0},ip=${IP_CIDR},gw=${GATEWAY}"
  else
    net0="${net0},ip=dhcp"
  fi

  pct create "${CTID}" "local:vztmpl/${tmpl}" \
    --hostname "${HOSTNAME}" \
    --storage "${STORAGE}" \
    --net0 "${net0}" \
    --nameserver "${DNS}" \
    --password "${CT_PASSWORD}" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --onboot 1

  pct start "${CTID}"
}

wait_for_container() {
  log "Aștept containerul să răspundă la pct exec..."
  for _ in {1..40}; do
    if pct exec "${CTID}" -- true >/dev/null 2>&1; then
      log "Container OK."
      return 0
    fi
    sleep 2
  done
  die "Containerul nu răspunde. Verifică: pct status ${CTID} și pct console ${CTID}"
}

install_openhab_inside() {
  log "Instalez Java 21 + openHAB în container..."

  pct exec "${CTID}" -- bash -lc "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Java 21
apt-get install -y --no-install-recommends '${JAVA_PKG}'

# openHAB repo + key (keyring + signed-by)
tmp_gpg=\$(mktemp)
curl -fsSL 'https://openhab.jfrog.io/artifactory/api/gpg/key/public' | gpg --dearmor > \"\${tmp_gpg}\"
install -d /usr/share/keyrings
install -m 0644 \"\${tmp_gpg}\" /usr/share/keyrings/openhab.gpg
rm -f \"\${tmp_gpg}\"

echo 'deb [signed-by=/usr/share/keyrings/openhab.gpg] https://openhab.jfrog.io/artifactory/openhab-linuxpkg ${OPENHAB_CHANNEL} main' > /etc/apt/sources.list.d/openhab.list

apt-get update -y
apt-get install -y openhab
if [[ '${INSTALL_ADDONS}' == '1' ]]; then
  apt-get install -y openhab-addons
fi

# Initialize directories (as in helper script)
mkdir -p /var/lib/openhab/{tmp,etc,cache}
mkdir -p /etc/openhab
mkdir -p /var/log/openhab
chown -R openhab:openhab /var/lib/openhab /etc/openhab /var/log/openhab

systemctl daemon-reload
systemctl enable --now openhab

# Create requested OS user/pass
if ! id -u '${OS_USER}' >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash '${OS_USER}'
fi
echo '${OS_USER}:${OS_PASS}' | chpasswd

echo
systemctl --no-pager --full status openhab || true
"
}

summary() {
  log "Gata ✅"
  echo "CTID: ${CTID}"
  echo "Hostname: ${HOSTNAME}"
  if [[ -n "${IP_CIDR}" ]]; then
    echo "IP static: ${IP_CIDR}  (GW ${GATEWAY})"
    echo "openHAB UI: http://${IP_CIDR%/*}:8080"
  else
    echo "IP: DHCP (verifică în Proxmox UI sau: pct exec ${CTID} -- ip -4 a)"
  fi
  echo "OS user/parola: ${OS_USER}/${OS_PASS}"
}

main() {
  need_root
  validate
  local tmpl
  tmpl="$(pick_debian13_template)"
  ensure_template_downloaded "${tmpl}"
  create_container "${tmpl}"
  wait_for_container
  install_openhab_inside
  summary
}

main \"$@\"
