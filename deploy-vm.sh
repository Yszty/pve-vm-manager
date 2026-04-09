#!/bin/bash

# =========================
# CONFIG
# =========================

STORAGE="Storage"
BRIDGE="vmbr0"
VLAN=79

# Plik z adresami IP
IP_FILE="used_ips.txt"
# Bazowy prefix i maska
IP_PREFIX="213.210.35"
MASK="/25"
GW="213.210.35.2"

USER="debian"
SSHKEY="$HOME/yszty-h.pub"
IMAGE="/mnt/temp_drive/import/debian-13-nocloud-amd64.qcow2"

# Tworzenie pliku, jeśli nie istnieje
touch "$IP_FILE"

# =========================
# IP ALLOCATION LOGIC
# =========================

# Wyciągamy najwyższy ostatni oktet z pliku
LAST_OCTET=$(awk -F. '{print $4}' "$IP_FILE" | sort -n | tail -1)

# Jeśli plik jest pusty, zacznij od .3 (skoro GW to .2)
if [ -z "$LAST_OCTET" ]; then
  NEW_OCTET=3
else
  NEW_OCTET=$((LAST_OCTET + 1))
fi

# Sprawdzenie limitu dla maski /25 (max adres użytkowy to .126)
if [ "$NEW_OCTET" -gt 126 ]; then
  echo "BŁĄD: Osiągnięto limit adresów dla maski /25 (.126)!"
  exit 1
fi

IP="$IP_PREFIX.$NEW_OCTET"
echo "Wyliczono adres IP: $IP$MASK"

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
  --name "$NAME" \
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
  --ipconfig0 ip="$IP$MASK",gw=$GW \
  --sshkey "$SSHKEY" \
  --nameserver $GW \
  --hostname "$NAME"

# =========================
# SAVE IP & START VM
# =========================

# Zapisujemy adres IP dopiero po udanej konfiguracji
echo "$IP" >> "$IP_FILE"

qm start $VMID

echo "VM $NAME ($VMID) deployed successfully with IP $IP 🚀"