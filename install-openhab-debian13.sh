#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override din env)
# =========================
OPENHAB_CHANNEL="${OPENHAB_CHANNEL:-stable}"   # stable | testing | unstable
INSTALL_ADDONS="${INSTALL_ADDONS:-1}"          # 1=yes, 0=no
HOLD_PACKAGES="${HOLD_PACKAGES:-0}"            # 1=yes, 0=no
OPENHAB_USER="${OPENHAB_USER:-openhab}"
OPENHAB_PASS="${OPENHAB_PASS:-openhab}"

# Java 21 (recommended)
JAVA_PKG="${JAVA_PKG:-openjdk-21-jre-headless}"

# =========================
# Static IP (OPTIONAL)
# =========================
# Dacă le lași goale, scriptul NU schimbă networking-ul.
# Exemplu:
# STATIC_IP_CIDR="192.168.1.50/24" GATEWAY4="192.168.1.1" DNS4="1.1.1.1 8.8.8.8" IFACE="eth0"
STATIC_IP_CIDR="${STATIC_IP_CIDR:-}"
GATEWAY4="${GATEWAY4:-}"
DNS4="${DNS4:-}"
IFACE="${IFACE:-eth0}"

log() { echo -e "\n[openhab-install] $*\n"; }
die() { echo "[openhab-install] ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Rulează ca root (ex: sudo bash ...)"
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl nu este disponibil. Ai nevoie de Debian LXC cu systemd activ."
  fi
}

validate_channel() {
  case "${OPENHAB_CHANNEL}" in
    stable|testing|unstable) ;;
    *) die "OPENHAB_CHANNEL invalid: ${OPENHAB_CHANNEL} (folosește stable|testing|unstable)";;
  esac
}

install_prereqs() {
  log "Update apt + pachete necesare"
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl gnupg perl
}

configure_static_ip() {
  [[ -n "${STATIC_IP_CIDR}" ]] || return 0

  [[ -n "${GATEWAY4}" ]] || die "Ai setat STATIC_IP_CIDR dar nu ai setat GATEWAY4"
  [[ -n "${DNS4}" ]] || die "Ai setat STATIC_IP_CIDR dar nu ai setat DNS4"

  log "Configurez IP static pe ${IFACE}: ${STATIC_IP_CIDR}, GW ${GATEWAY4}, DNS ${DNS4}"
  log "Notă: În Proxmox, metoda recomandată este să setezi IP-ul în config LXC (net0 ip/gw)."

  # 1) ifupdown: /etc/network/interfaces (cel mai comun pe multe template-uri LXC)
  if [[ -f /etc/network/interfaces ]]; then
    # dacă găsim dhcp pe iface, îl înlocuim
    if grep -Eq "iface[[:space:]]+${IFACE}[[:space:]]+inet[[:space:]]+dhcp" /etc/network/interfaces; then
      cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%F_%H%M%S)"

      perl -0777 -i -pe "
        s/auto[[:space:]]+${IFACE}[^\n]*\n//sg;
        s/allow-hotplug[[:space:]]+${IFACE}[^\n]*\n//sg;
      " /etc/network/interfaces

      # înlocuiește blocul iface dhcp cu static
      perl -0777 -i -pe "
        s/iface[[:space:]]+${IFACE}[[:space:]]+inet[[:space:]]+dhcp[[:space:]]*/iface ${IFACE} inet static\n    address ${STATIC_IP_CIDR}\n    gateway ${GATEWAY4}\n    dns-nameservers ${DNS4}\n\n/sg
      " /etc/network/interfaces

      # asigură auto iface
      if ! grep -Eq "auto[[:space:]]+${IFACE}" /etc/network/interfaces; then
        printf "auto %s\n" "${IFACE}" | cat - /etc/network/interfaces > /tmp/interfaces && mv /tmp/interfaces /etc/network/interfaces
      fi

      log "Scris config static în /etc/network/interfaces (backup creat)."
      systemctl restart networking 2>/dev/null || true
      return 0
    fi
  fi

  # 2) systemd-networkd
  if systemctl is-enabled systemd-networkd >/dev/null 2>&1 || systemctl is-active systemd-networkd >/dev/null 2>&1; then
    mkdir -p /etc/systemd/network
    cat > "/etc/systemd/network/10-${IFACE}.network" <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${STATIC_IP_CIDR}
Gateway=${GATEWAY4}
DNS=${DNS4}
EOF
    log "Scris /etc/systemd/network/10-${IFACE}.network"
    systemctl enable --now systemd-networkd >/dev/null 2>&1 || true
    systemctl restart systemd-networkd 2>/dev/null || true
    return 0
  fi

  die "Nu am detectat ifupdown sau systemd-networkd pentru a seta IP static. Configurează IP-ul din Proxmox (net0 ip/gw) sau manual în Debian."
}

install_java() {
  log "Instalez Java 21: ${JAVA_PKG}"
  apt-get install -y --no-install-recommends "${JAVA_PKG}"
}

add_openhab_repo_and_key() {
  log "Adaug cheia GPG openHAB în /usr/share/keyrings"
  local tmp_gpg
  tmp_gpg="$(mktemp)"
  curl -fsSL "https://openhab.jfrog.io/artifactory/api/gpg/key/public" | gpg --dearmor > "${tmp_gpg}"
  mkdir -p /usr/share/keyrings
  install -m 0644 "${tmp_gpg}" /usr/share/keyrings/openhab.gpg
  rm -f "${tmp_gpg}"

  log "Adaug repo openHAB (${OPENHAB_CHANNEL})"
  echo "deb [signed-by=/usr/share/keyrings/openhab.gpg] https://openhab.jfrog.io/artifactory/openhab-linuxpkg ${OPENHAB_CHANNEL} main" \
    > /etc/apt/sources.list.d/openhab.list
}

install_openhab() {
  log "Instalez openHAB"
  apt-get update -y
  apt-get install -y openhab

  if [[ "${INSTALL_ADDONS}" == "1" ]]; then
    log "Instalez openhab-addons (opțional)"
    apt-get install -y openhab-addons
  fi

  log "Enable + start openHAB"
  systemctl daemon-reload
  systemctl enable --now openhab.service
}

set_openhab_user_password() {
  log "Setez parola user-ului OS '${OPENHAB_USER}' -> '${OPENHAB_PASS}'"
  if ! id -u "${OPENHAB_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "${OPENHAB_USER}"
  fi
  echo "${OPENHAB_USER}:${OPENHAB_PASS}" | chpasswd
}

hold_packages_if_requested() {
  if [[ "${HOLD_PACKAGES}" == "1" ]]; then
    log "Pun pachetele pe hold (opțional)"
    apt-mark hold openhab || true
    [[ "${INSTALL_ADDONS}" == "1" ]] && apt-mark hold openhab-addons || true
  fi
}

print_summary() {
  log "Status serviciu openHAB:"
  systemctl --no-pager --full status openhab.service || true

  echo
  echo "======================"
  echo "Instalare completă ✅"
  echo "======================"
  echo "UI: http://IP-ul-containerului:8080"
  echo
  echo "OS user/parolă setate: ${OPENHAB_USER}/${OPENHAB_PASS}"
  echo "ATENȚIE: schimbă parola imediat."
  echo
  echo "Dacă ai setat IP static din script și ai pierdut conectivitatea, revino la consola Proxmox și verifică /etc/network/interfaces (backup *.bak.*)."
}

main() {
  require_root
  require_systemd
  validate_channel

  # IP static înainte de instalare (dacă e cerut)
  configure_static_ip

  install_prereqs
  install_java
  add_openhab_repo_and_key
  install_openhab
  set_openhab_user_password
  hold_packages_if_requested
  print_summary
}

main "$@"
