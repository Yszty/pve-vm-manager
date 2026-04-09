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
    echo "Usage: $0 [-n NAME] [-d DISK_GB] [-r RAM_GB] [-y]"
    echo "  -n  Virtual Machine name (required)"
    echo "  -d  Disk size in GB (default: 40)"
    echo "  -r  RAM size in GB (default: 2)"
    echo "  -y  Auto-confirm (non-interactive mode)"
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
  echo "ERROR: IP address limit reached for /25 subnet!"
  exit 1
fi
IP="$IP_PREFIX.$NEW_OCTET"

# =========================
# USER INPUTS & VALIDATION
# =========================
if [ -z "$NAME" ]; then
    read -p "Enter VM Name (required): " NAME
fi

# Name validation: starts with letter, only letters, numbers, and dashes
if [[ ! "$NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
    echo "ERROR: Invalid name '$NAME'."
    echo "Names must start with a letter and contain only letters, numbers, and hyphens (-)."
    exit 1
fi

if [ "$AUTO_CONFIRM" = false ]; then
    read -p "Enter Disk size (GB) [default $DISK_SIZE]: " INPUT_DISK
    DISK_SIZE=${INPUT_DISK:-$DISK_SIZE}

    read -p "Enter RAM size (GB) [default $RAM_SIZE]: " INPUT_RAM
    RAM_SIZE=${INPUT_RAM:-$RAM_SIZE}
fi

RAM_MB=$((RAM_SIZE * 1024))

# =========================
# FIND VMID
# =========================
# Finds the highest VMID below 90000 and adds 10
VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)
[ -z "$VMID" ] && VMID=1000
VMID=$((VMID + 10))

# =========================
# CONFIRMATION
# =========================
echo ""
echo "--- Deployment Configuration ---"
echo "VMID:     $VMID"
echo "Name:     $NAME"
echo "IP:       $IP$MASK"
echo "Disk:     ${DISK_SIZE}G"
echo "RAM:      ${RAM_MB}MB (${RAM_SIZE}GB)"
echo "--------------------------------"

if [ "$AUTO_CONFIRM" = false ]; then
    read -p "Proceed with deployment? [y/N]: " CONFIRM
    if [[ ! "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
fi

# =========================
# DEPLOYMENT
# =========================
echo "Starting deployment..."

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
  --nameserver "$GW"

# Save IP to tracking file and start VM
echo "$IP" >> "$IP_FILE"
qm start $VMID

echo "Success: VM $NAME ($VMID) deployed with IP $IP 🚀"