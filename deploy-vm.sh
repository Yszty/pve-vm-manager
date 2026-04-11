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

# OVH DNS (optional): ustaw zmienne środowiskowe lub użyj -z STREFA
# Wymagane: OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, OVH_CONSUMER_KEY
# Endpoint: https://eu.api.ovh.com (Europa) | https://ca.api.ovh.com (Kanada) | https://api.us.ovhcloud.com (USA)
OVH_APPLICATION_KEY="xxx"
OVH_APPLICATION_SECRET="yyy"
OVH_CONSUMER_KEY="zzz"
OVH_ENDPOINT="${OVH_ENDPOINT:-https://eu.api.ovh.com}"
OVH_DNS_TTL="${OVH_DNS_TTL:-3600}"
OVH_ZONE="${OVH_ZONE:-hostier.pl}"
SKIP_OVH_DNS=false

touch "$IP_FILE"

# --- OVH API (v1): podpis i żądania ---
ovh_sign() {
    local method="$1" url="$2" body="${3:-}" ts sig_hex
    ts=$(date +%s)
    sig_hex=$(echo -n "${OVH_APPLICATION_SECRET}+${OVH_CONSUMER_KEY}+${method}+${url}+${body}+${ts}" | openssl dgst -sha1 | awk '{print $2}')
    printf '%s\n' "$ts" '$1$'"$sig_hex"
}

# Zwraca treść odpowiedzi na stdout, kod HTTP w ostatniej linii (tylko cyfry)
ovh_http() {
    local method="$1" path="$2" body="${3:-}"
    local url ts sig tmp code
    url="${OVH_ENDPOINT%/}/1.0${path}"
    read -r ts sig < <(ovh_sign "$method" "$url" "$body")
    tmp=$(mktemp) || return 1
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Ovh-Application: $OVH_APPLICATION_KEY" \
        -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
        -H "X-Ovh-Timestamp: $ts" \
        -H "X-Ovh-Signature: $sig" \
        ${body:+-d "$body"}) || code="000"
    cat "$tmp"
    rm -f "$tmp"
    echo "$code"
}

ovh_zone_refresh() {
    local zone="$1" resp code
    resp=$(ovh_http POST "/domain/zone/${zone}/refresh" "")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
        echo "WARNING: OVH zone refresh zwrócił HTTP $code${body:+ — $body}" >&2
        return 1
    fi
    return 0
}

# Ustawia rekord A (tworzy lub aktualizuje istniejący dla tego subdomeny)
ovh_dns_set_a() {
    local zone="$1" sub="$2" ip="$3"
    local list_resp list_code ids first_id post_resp post_code put_resp put_code
    local body_post body_put

    body_post=$(printf '{"fieldType":"A","subDomain":"%s","target":"%s","ttl":%s}' "$sub" "$ip" "$OVH_DNS_TTL")

    list_resp=$(ovh_http GET "/domain/zone/${zone}/record?fieldType=A&subDomain=${sub}" "")
    list_code=$(echo "$list_resp" | tail -n1)
    list_body=$(echo "$list_resp" | sed '$d')
    if [ "$list_code" != "200" ]; then
        echo "WARNING: OVH list record failed HTTP $list_code${list_body:+ — $list_body}" >&2
        return 1
    fi

    ids=$(echo "$list_body" | grep -oE '[0-9]+' || true)
    first_id=$(echo "$ids" | head -n1)

    if [ -n "$first_id" ]; then
        body_put=$(printf '{"target":"%s","subDomain":"%s","ttl":%s}' "$ip" "$sub" "$OVH_DNS_TTL")
        put_resp=$(ovh_http PUT "/domain/zone/${zone}/record/${first_id}" "$body_put")
        put_code=$(echo "$put_resp" | tail -n1)
        put_body=$(echo "$put_resp" | sed '$d')
        if [ "$put_code" != "200" ]; then
            echo "WARNING: OVH PUT A record failed HTTP $put_code${put_body:+ — $put_body}" >&2
            return 1
        fi
    else
        post_resp=$(ovh_http POST "/domain/zone/${zone}/record" "$body_post")
        post_code=$(echo "$post_resp" | tail -n1)
        post_body=$(echo "$post_resp" | sed '$d')
        if [ "$post_code" != "200" ] && [ "$post_code" != "201" ]; then
            echo "WARNING: OVH POST A record failed HTTP $post_code${post_body:+ — $post_body}" >&2
            return 1
        fi
    fi

    ovh_zone_refresh "$zone" || true
    echo "OVH DNS: A ${sub}.${zone} -> $ip"
    return 0
}

# =========================
# FLAGS HANDLING
# =========================
AUTO_CONFIRM=false
NAME=""
DISK_SIZE=40
RAM_SIZE=2

usage() {
    echo "Usage: $0 [-n NAME] [-d DISK_GB] [-r RAM_GB] [-y] [-z OVH_ZONE] [-D]"
    echo "  -n  Virtual Machine name (required)"
    echo "  -d  Disk size in GB (default: 40)"
    echo "  -r  RAM size in GB (default: 2)"
    echo "  -y  Auto-confirm (non-interactive mode)"
    echo "  -z  OVH DNS zone (e.g. example.com); needs OVH_APPLICATION_* + OVH_CONSUMER_KEY"
    echo "  -D  Skip OVH DNS API for this run"
    exit 1
}

while getopts "n:d:r:yz:D" opt; do
    case $opt in
        n) NAME=$OPTARG ;;
        d) DISK_SIZE=$OPTARG ;;
        r) RAM_SIZE=$OPTARG ;;
        y) AUTO_CONFIRM=true ;;
        z) OVH_ZONE=$OPTARG ;;
        D) SKIP_OVH_DNS=true ;;
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
if [ "$SKIP_OVH_DNS" = false ] && [ -n "$OVH_ZONE" ]; then
    echo "OVH DNS:  $(echo "$NAME" | tr '[:upper:]' '[:lower:]').$OVH_ZONE -> $IP (A)"
fi
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

if [ "$SKIP_OVH_DNS" = false ] && [ -n "$OVH_ZONE" ] \
    && [ -n "${OVH_APPLICATION_KEY:-}" ] && [ -n "${OVH_APPLICATION_SECRET:-}" ] && [ -n "${OVH_CONSUMER_KEY:-}" ]; then
    DNS_SUB=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
    ovh_dns_set_a "$OVH_ZONE" "$DNS_SUB" "$IP" || true
elif [ "$SKIP_OVH_DNS" = false ] && [ -n "$OVH_ZONE" ]; then
    echo "WARNING: OVH_ZONE is set but OVH_APPLICATION_KEY / OVH_APPLICATION_SECRET / OVH_CONSUMER_KEY are missing — skipping DNS." >&2
fi

echo "Success: VM $NAME ($VMID) deployed with IP $IP 🚀"