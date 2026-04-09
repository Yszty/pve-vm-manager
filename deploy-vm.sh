#!/bin/bash

# =========================
# CONFIG
# =========================

STORAGE="Storage"
BRIDGE="vmbr0"
VLAN=79

IP_FILE="used_ips.txt"
IP_PREFIX="213.210.35"
MASK="/25"
GW="213.210.35.2"

USER="debian"
SSHKEY="$HOME/yszty-h.pub"
IMAGE="/mnt/temp_drive/import/debian-13-generic-amd64.qcow2"

touch "$IP_FILE"

# =========================
# IP ALLOCATION LOGIC
# =========================

LAST_OCTET=$(awk -F. '{print $4}' "$IP_FILE" | sort -n | tail -1)

if [ -z "$LAST_OCTET" ]; then
  NEW_OCTET=3
else
  NEW_OCTET=$((LAST_OCTET + 1))
fi

if [ "$NEW_OCTET" -gt 126 ]; then
  echo "BŁĄD: Osiągnięto limit adresów dla maski /25 (.126)!"
  exit 1
fi

IP="$IP_PREFIX.$NEW_OCTET"

# =========================
# ASK FOR VM NAME
# =========================

read -p "Podaj nazwę VM: " NAME

# =========================
# FIND HIGHEST VMID + 10
# =========================

VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)
[ -z "$VMID" ] && VMID=1000
VMID=$((VMID + 10))

echo "Tworzę VM $NAME z ID: $VMID i IP: $IP"

# =========================
# CREATE VM
# =========================

qm create $VMID \
  --name "$NAME" \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=$BRIDGE,tag=$VLAN \
  --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0

# =========================
# IMPORT & RESIZE DISK
# =========================

qm importdisk $VMID $IMAGE $STORAGE

qm set $VMID \
  --scsi0 $STORAGE:vm-$VMID-disk-0 \
  --boot order=scsi0

# Zmiana rozmiaru na 40GB
qm resize $VMID scsi0 40G

# =========================
# CLOUD-INIT CONFIG
# =========================

qm set $VMID --ide2 $STORAGE:cloudinit

qm set $VMID \
  --ciuser $USER \
  --ipconfig0 ip="$IP$MASK",gw=$GW \
  --sshkey "$SSHKEY" \
  --nameserver $GW \
 
# =========================
# SAVE IP & START VM
# =========================

echo "$IP" >> "$IP_FILE"
qm start $VMID

echo "VM $NAME ($VMID) deployed successfully 🚀"
echo "Adres IP: $IP"
echo "Dysk: 40GB"