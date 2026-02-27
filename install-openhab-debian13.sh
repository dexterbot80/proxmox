#!/usr/bin/env bash
set -euo pipefail

# --- Config (poți suprascrie din env) ---
OPENHAB_CHANNEL="${OPENHAB_CHANNEL:-stable}"   # stable | testing | unstable
INSTALL_ADDONS="${INSTALL_ADDONS:-1}"          # 1=yes, 0=no
HOLD_PACKAGES="${HOLD_PACKAGES:-0}"            # 1=yes, 0=no
OPENHAB_USER="${OPENHAB_USER:-openhab}"
OPENHAB_PASS="${OPENHAB_PASS:-openhab}"
JAVA_PKG="${JAVA_PKG:-openjdk-21-jre-headless}"

# --- Static IP (opțional) ---
# Exemplu:
# STATIC_IP_CIDR="192.168.1.50/24" GATEWAY4="192.168.1.1" DNS4="1.1.1.1 8.8.8.8"
STATIC_IP_CIDR="${STATIC_IP_CIDR:-}"   # gol = nu schimbă nimic
GATEWAY4="${GATEWAY4:-}"
DNS4="${DNS4:-}"
IFACE="${IFACE:-eth0}"

log() { echo -e "\n[openhab-install] $*\n"; }
die() { echo "[openhab-install] ERROR: $*" >&2; exit 1; }

if [[ "${EUID}" -ne 0 ]]; then
  die "Rulează ca root (ex: sudo bash install-openhab-debian13.sh)"
fi

if ! command -v systemctl >/dev/null 2>&1; then
  die "systemctl nu este disponibil. În LXC trebuie Debian cu systemd activ."
fi

configure_static_ip() {
  [[ -n "${STATIC_IP_CIDR}" ]] || return 0

  [[ -n "${GATEWAY4}" ]] || die "Ai setat STATIC_IP_CIDR dar nu ai setat GATEWAY4"
  [[ -n "${DNS4}" ]] || die "Ai setat STATIC_IP_CIDR dar nu ai setat DNS4"

  log "Configurez IP static pe interfața ${IFACE}: ${STATIC_IP_CIDR}, GW ${GATEWAY4}, DNS ${DNS4}"

  # 1) ifupdown (/etc/network/interfaces)
  if [[ -f /etc/network/interfaces ]]; then
    if grep -Eq "iface\s+${IFACE}\s+inet\s+dhcp" /etc/network/interfaces; then
      cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%F_%H%M%S)"
      # înlocuiește blocul dhcp cu static
      perl -0777 -i -pe "
        s/iface\s+${IFACE}\s+inet\s+dhcp\s*/iface ${IFACE} inet static\n    address ${STATIC_IP_CIDR}\n    gateway ${GATEWAY4}\n    dns-nameservers ${DNS4}\n\n/sg
      " /etc/network/interfaces
      log "Am scris config static în /etc/network/interfaces"
      # încearcă restart networking (dacă există)
      systemctl restart networking 2>/dev/null || true
      return 0
    fi
  fi

  # 2) systemd-networkd
  if systemctl is-enabled systemd-networkd >/dev/null 2>&1 || systemctl is-active systemd-networkd >/dev/null 2>&1; then
    mkdir -p /etc/systemd/network
    cat > /etc/systemd/network/10-${IFACE}.network <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${STATIC_IP_CIDR}
Gateway=${GATEWAY4}
DNS=${DNS4}
EOF
    log "Am scris /etc/systemd/network/10-${IFACE}.network"
    systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
    systemctl restart systemd-networkd 2>/dev/null || true
    return 0
  fi

  # 3) fallback: niciuna detectată
  die "N-am putut detecta ifupdown sau systemd-networkd pentru a seta IP static. Verifică manual networking-ul din template."
}

# rulează setarea IP static înainte de install (ca să ai rețea ok)
configure_static_ip

case "${OPENHAB_CHANNEL}" in
  stable|testing|unstable) ;;
  *) die "OPENHAB_CHANNEL invalid: ${OPENHAB_CHANNEL} (folosește stable|testing|unstable)";;
esac

log "Update apt + pachete necesare"
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg

log "Instalez Java 21"
apt-get install -y --no-install-recommends "${JAVA_PKG}"

log "Adaug cheia GPG openHAB în /usr/share/keyrings"
tmp_gpg="$(mktemp)"
curl -fsSL "https://openhab.jfrog.io/artifactory/api/gpg/key/public" | gpg --dearmor > "${tmp_gpg}"
mkdir -p /usr/share/keyrings
install -m 0644 "${tmp_gpg}" /usr/share/keyrings/openhab.gpg
rm -f "${tmp_gpg}"

log "Adaug repo openHAB (${OPENHAB_CHANNEL})"
echo "deb [signed-by=/usr/share/keyrings/openhab.gpg] https://openhab.jfrog.io/artifactory/openhab-linuxpkg ${OPENHAB_CHANNEL} main" \
  > /etc/apt/sources.list.d/openhab.list

log "Instalez openhab"
apt-get update -y
apt-get install -y openhab

if [[ "${INSTALL_ADDONS}" == "1" ]]; then
  log "Instalez openhab-addons"
  apt-get install -y openhab-addons
fi

log "Enable + start openHAB"
systemctl daemon-reload
systemctl enable --now openhab.service

log "Setez parola user-ului '${OPENHAB_USER}' -> '${OPENHAB_PASS}'"
if ! id -u "${OPENHAB_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/bash "${OPENHAB_USER}"
fi
echo "${OPENHAB_USER}:${OPENHAB_PASS}" | chpasswd

if [[ "${HOLD_PACKAGES}" == "1" ]]; then
  log "Pun pachetele pe hold (opțional)"
  apt-mark hold openhab || true
  [[ "${INSTALL_ADDONS}" == "1" ]] && apt-mark hold openhab-addons || true
fi

log "Status:"
systemctl --no-pager --full status openhab.service || true

echo
echo "Acces UI: http://IP-ul-containerului:8080"
