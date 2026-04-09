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
  echo "BŁĄD: Osiągnięto limit adresów dla maski /25!"
  exit 1
fi

IP="$IP_PREFIX.$NEW_OCTET"

# =========================
# USER INPUTS
# =========================

read -p "Podaj nazwę VM: " NAME

# Wybór Dysku
echo "Wybierz rozmiar dysku (GB): 25, 40, 80 lub wpisz własny (np. 100):"
read -p "Rozmiar [40]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-40}

# Wybór RAM
echo "Wybierz RAM (GB): 2, 4, 8 lub wpisz własny (np. 16):"
read -p "RAM [2]: " RAM_SIZE
RAM_SIZE=${RAM_SIZE:-2}
# Przeliczenie na MB dla qm
RAM_MB=$((RAM_SIZE * 1024))

# =========================
# FIND HIGHEST VMID + 10
# =========================

VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)
[ -z "$VMID" ] && VMID=1000
VMID=$((VMID + 10))

echo "--- Konfiguracja ---"
echo "VMID: $VMID | Nazwa: $NAME"
echo "IP:   $IP$MASK"
echo "Disk: ${DISK_SIZE}G | RAM: ${RAM_MB}MB"
echo "--------------------"

# =========================
# CREATE VM
# =========================

qm create $VMID \
  --name "$NAME" \
  --memory $RAM_MB \
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

# Zmiana rozmiaru na wybrany przez użytkownika
qm resize $VMID scsi0 ${DISK_SIZE}G

# =========================
# CLOUD-INIT CONFIG
# =========================

qm set $VMID --ide2 $STORAGE:cloudinit

# Naprawiona sekcja Cloud-Init
qm set $VMID \
  --ciuser "$USER" \
  --sshkey "$SSHKEY" \
  --ipconfig0 "ip=$IP$MASK,gw=$GW" \
  --nameserver "$GW" \


# =========================
# SAVE IP & START VM
# =========================

echo "$IP" >> "$IP_FILE"
qm start $VMID

echo "VM $NAME ($VMID) została pomyślnie uruchomiona! 🚀"