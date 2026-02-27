curl -fsSL https://raw.githubusercontent.com/dexterbot80/proxmox/main/proxmox-debian13-openhab-lxc.sh | bash -s -- \
--ctid 110 \
--storage local-zfs \
--bridge vmbr0 \
--ip 192.168.1.232/24 \
--gw 192.168.1.1 \
--dns "1.1.1.1 8.8.8.8" \
--root-pass openhabian \
--user openhabian \
--user-pass openhabian
