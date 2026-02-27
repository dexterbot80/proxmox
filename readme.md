curl -fsSL https://raw.githubusercontent.com/dexterbot80/proxmox/main/install-openhab-debian13.sh | sudo bash


curl -fsSL https://raw.githubusercontent.com/dexterbot80/proxmox/main/install-openhab-debian13.sh \
| sudo STATIC_IP_CIDR="192.168.1.232/24" GATEWAY4="192.168.1.1" DNS4="1.1.1.1 8.8.8.8" IFACE="eth0" bash
