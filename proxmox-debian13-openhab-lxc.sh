#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override din env)
# =========================
CTID="${CTID:-}"
HOSTNAME="${HOSTNAME:-openhab}"
STORAGE="${STORAGE:-local-lvm}"     # ex: local-lvm, local, zfs, etc.
BRIDGE="${BRIDGE:-vmbr0}"
IP_CIDR="${IP_CIDR:-}"             # ex: 192.168.1.232/24
GATEWAY="${GATEWAY:-}"             # ex: 192.168.1.1
DNS="${DNS:-1.1.1.1 8.8.8.8}"
CT_PASSWORD="${CT_PASSWORD:-}"     # parola root din container (necesară la pct create)

OPENHAB_CHANNEL="${OPENHAB_CHANNEL:-stable}"   # stable | testing | unstable
INSTALL_ADDONS="${INSTALL_ADDONS:-1}"          # 1=yes, 0=no
JAVA_PKG="${JAVA_PKG:-openjdk-21-jre-headless}"

# User OS cerut de tine
OS_USER="${OS_USER:-openhabian}"
OS_PASS="${OS_PASS:-openhabian}"

log(){ echo -e "\n[proxmox-openhab] $*\n"; }
die(){ echo "[proxmox-openhab] ERROR: $*" >&2; exit 1; }

need_root(){
  [[ "${EUID}" -eq 0 ]] || die "Rulează pe Proxmox ca root."
}

validate(){
  command -v pct >/dev/null 2>&1 || die "pct nu există. Rulează scriptul pe host Proxmox."
  command -v pveam >/dev/null 2>&1 || die "pveam nu există. Rulează scriptul pe host Proxmox."

  [[ -n "${CTID}" ]] || die "Setează CTID (ex: CTID=101)"
  [[ -n "${CT_PASSWORD}" ]] || die "Setează CT_PASSWORD (parola root din container)"
  [[ -n "${IP_CIDR}" ]] || die "Setează IP_CIDR (ex: 192.168.1.232/24)"
  [[ -n "${GATEWAY}" ]] || die "Setează GATEWAY (ex: 192.168.1.1)"

  case "${OPENHAB_CHANNEL}" in
    stable|testing|unstable) ;;
    *) die "OPENHAB_CHANNEL invalid: ${OPENHAB_CHANNEL} (folosește stable|testing|unstable)";;
  esac

  if pct status "${CTID}" >/dev/null 2>&1; then
    die "CTID ${CTID} există deja. Alege alt CTID."
  fi
}

pick_debian13_template(){
  # Caută cel mai nou debian-13-standard_* din pveam available
  local tmpl
  tmpl="$(pveam available --section system \
    | awk '{print $2}' \
    | grep -E '^debian-13-standard_.*\.tar\.zst$' \
    | sort -V \
    | tail -n 1 || true)"
  [[ -n "${tmpl}" ]] || die "Nu găsesc template Debian 13 în pveam available. Fă update la template list: pveam update"
  echo "${tmpl}"
}

ensure_template_downloaded(){
  local tmpl="$1"
  if ! pveam list local | awk '{print $1}' | grep -qx "${tmpl}"; then
    log "Download template: ${tmpl} -> local"
    pveam download local "${tmpl}"
  else
    log "Template deja prezent: ${tmpl}"
  fi
}

create_container(){
  local tmpl="$1"
  log "Creez LXC Debian 13 (CTID=${CTID}, hostname=${HOSTNAME})"
  pct create "${CTID}" "local:vztmpl/${tmpl}" \
    --hostname "${HOSTNAME}" \
    --storage "${STORAGE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}" \
    --nameserver "${DNS}" \
    --password "${CT_PASSWORD}" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    --start 1
}

wait_for_container(){
  log "Aștept să pornească containerul și să răspundă la pct exec..."
  for i in {1..30}; do
    if pct exec "${CTID}" -- true >/dev/null 2>&1; then
      log "Container OK."
      return 0
    fi
    sleep 2
  done
  die "Containerul nu răspunde la pct exec. Verifică status: pct status ${CTID}"
}

install_openhab_inside(){
  log "Instalez Java 21 + openHAB în container (conform doc openHAB Linux/apt)..."

  pct exec "${CTID}" -- bash -lc "
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# prereqs
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

echo 'deb [signed-by=/usr/share/keyrings/openhab.gpg] https://openhab.jfrog.io/artifactory/openhab-linuxpkg ${OPENHAB_CHANNEL} main' \
  > /etc/apt/sources.list.d/openhab.list

apt-get update -y
apt-get install -y openhab
if [[ '${INSTALL_ADDONS}' == '1' ]]; then
  apt-get install -y openhab-addons
fi

systemctl daemon-reload
systemctl enable --now openhab.service

# user/parola OS: openhabian/openhabian
if ! id -u '${OS_USER}' >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash '${OS_USER}'
fi
echo '${OS_USER}:${OS_PASS}' | chpasswd

echo
echo 'openHAB service status:'
systemctl --no-pager --full status openhab.service || true
"
}

summary(){
  log "Gata ✅"
  echo "Container: CTID=${CTID}, hostname=${HOSTNAME}"
  echo "IP: ${IP_CIDR} (gw ${GATEWAY}, dns ${DNS})"
  echo "openHAB UI: http://${IP_CIDR%/*}:8080"
  echo "OS user/parola: ${OS_USER}/${OS_PASS}"
}

main(){
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

main "$@"
