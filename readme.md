bash -lc '
curl -fsSLo /tmp/proxmox-openhab.sh https://raw.githubusercontent.com/dexterbot80/proxmox/main/proxmox-debian13-openhab-lxc.sh &&
CTID=110 HOSTNAME=openhab STORAGE=local-zfs BRIDGE=vmbr0 \
IP_CIDR="192.168.1.232/24" GATEWAY="192.168.1.1" DNS="1.1.1.1 8.8.8.8" \
CT_PASSWORD="SchimbaAceastaParolaRoot" \
OS_USER="openhabian" OS_PASS="openhabian" \
bash /tmp/proxmox-openhab.sh
'
