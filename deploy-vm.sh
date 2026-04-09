#!/bin/bash

# =========================
# CONFIG
# =========================

STORAGE="Storage"
BRIDGE="vmbr0"

IP="213.210.35.32/25"
GW="213.210.35.2"
VLAN=79

USER="debian"
SSHKEY="$HOME/yszty-h.pub"

IMAGE="/mnt/temp_drive/import/debian-13-nocloud-amd64.qcow2"

# =========================
# ASK FOR VM NAME
# =========================

read -p "Podaj nazwę VM: " NAME

# =========================
# FIND HIGHEST VMID + 10
# =========================

VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)

if [ -z "$VMID" ]; then
  VMID=1000
fi

VMID=$((VMID + 10))

echo "Używam VMID: $VMID"

# =========================
# CREATE VM
# =========================

qm create $VMID \
  --name $NAME \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=$BRIDGE,tag=$VLAN \
  --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0

# =========================
# IMPORT DISK
# =========================

qm importdisk $VMID $IMAGE $STORAGE

qm set $VMID \
  --scsi0 $STORAGE:vm-$VMID-disk-0 \
  --boot order=scsi0

# =========================
# CLOUD-INIT DRIVE
# =========================

qm set $VMID --ide2 $STORAGE:cloudinit

# =========================
# CLOUD-INIT CONFIG
# =========================

qm set $VMID \
  --ciuser $USER \
  --ipconfig0 ip=$IP,gw=$GW \
  --sshkey $SSHKEY \
  --nameserver $GW \
  --hostname $NAME

# =========================
# START VM
# =========================

qm start $VMID

echo "VM $NAME ($VMID) deployed successfully 🚀"