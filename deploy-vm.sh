#!/bin/bash

# =========================
# CONFIG (Default)
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
# FLAGS HANDLING
# =========================
AUTO_CONFIRM=false
NAME=""
DISK_SIZE=40
RAM_SIZE=2

usage() {
    echo "Użycie: $0 [-n NAZWA] [-d DYSK_GB] [-r RAM_GB] [-y]"
    echo "  -n  Nazwa maszyny wirtualnej"
    echo "  -d  Rozmiar dysku w GB (domyślnie 40)"
    echo "  -r  Ilość RAM w GB (domyślnie 2)"
    echo "  -y  Automatyczne potwierdzenie (tryb nieinteraktywny)"
    exit 1
}

while getopts "n:d:r:y" opt; do
    case $opt in
        n) NAME=$OPTARG ;;
        d) DISK_SIZE=$OPTARG ;;
        r) RAM_SIZE=$OPTARG ;;
        y) AUTO_CONFIRM=true ;;
        *) usage ;;
    esac
done

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
# INTERACTIVE INPUTS (if flags are missing)
# =========================
if [ -z "$NAME" ]; then
    read -p "Podaj nazwę VM: " NAME
fi

if [ "$AUTO_CONFIRM" = false ]; then
    echo "Wybierz rozmiar dysku (GB) [domyślnie $DISK_SIZE]:"
    read -p "Rozmiar: " INPUT_DISK
    DISK_SIZE=${INPUT_DISK:-$DISK_SIZE}

    echo "Wybierz RAM (GB) [domyślnie $RAM_SIZE]:"
    read -p "RAM: " INPUT_RAM
    RAM_SIZE=${INPUT_RAM:-$RAM_SIZE}
fi

RAM_MB=$((RAM_SIZE * 1024))

# =========================
# FIND VMID
# =========================
VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)
[ -z "$VMID" ] && VMID=1000
VMID=$((VMID + 10))

# =========================
# CONFIRMATION
# =========================
echo ""
echo "--- Konfiguracja ---"
echo "VMID:  $VMID"
echo "Nazwa: $NAME"
echo "IP:    $IP$MASK"
echo "Dysk:  ${DISK_SIZE}G"
echo "RAM:   ${RAM_MB}MB (${RAM_SIZE}GB)"
echo "--------------------"

if [ "$AUTO_CONFIRM" = false ]; then
    read -p "Czy wszystko się zgadza? [y/N]: " CONFIRM
    if [[ ! "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
        echo "Anulowano."
        exit 0
    fi
fi

# =========================
# DEPLOYMENT
# =========================
echo "Rozpoczynam wdrażanie..."

qm create $VMID \
  --name "$NAME" \
  --memory $RAM_MB \
  --cores 2 \
  --net0 virtio,bridge=$BRIDGE,tag=$VLAN \
  --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0

qm importdisk $VMID $IMAGE $STORAGE
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0 --boot order=scsi0
qm resize $VMID scsi0 ${DISK_SIZE}G

qm set $VMID --ide2 $STORAGE:cloudinit
qm set $VMID \
  --ciuser "$USER" \
  --sshkey "$SSHKEY" \
  --ipconfig0 "ip=$IP$MASK,gw=$GW" \
  --nameserver "$GW" \
  --hostname "$NAME"

echo "$IP" >> "$IP_FILE"
qm start $VMID

echo "VM $NAME ($VMID) deployed successfully with IP $IP 🚀"