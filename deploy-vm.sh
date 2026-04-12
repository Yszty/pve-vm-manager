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
# Nie ustawiaj tu prawdziwych kluczy w repozytorium — użyj export przed uruchomieniem albo pliku deploy.conf obok skryptu (patrz deploy.conf.example).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -r "$_SCRIPT_DIR/deploy.conf" ] && . "$_SCRIPT_DIR/deploy.conf"

OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_ENDPOINT="${OVH_ENDPOINT:-https://eu.api.ovh.com}"
OVH_DNS_TTL="${OVH_DNS_TTL:-3600}"
OVH_ZONE="${OVH_ZONE:-hostier.pl}"
# Opcjonalnie (env / deploy.conf): OVH_DNS_SUBDOMAIN — jawna etykieta; puste = apex (@). Nadpisuje -s.
# Opcjonalnie: DEPLOY_VMID — stałe VMID (nadpisuje -i).
# Opcjonalnie: DEPLOY_IP — pełny IPv4 gościa (nadpisuje -p); prefiks/pula jak poniżej — bez sprawdzania duplikatu w $IP_FILE.
SKIP_OVH_DNS=false
CLI_DNS_SUB=""
CLI_VMID=""
CLI_IP=""

touch "$IP_FILE"

# --- OVH API (v1): podpis i żądania ---
ovh_sign() {
    local method="$1" url="$2" body="${3:-}" ts sig_hex
    ts=$(date +%s)
    sig_hex=$(printf '%s' "${OVH_APPLICATION_SECRET}+${OVH_CONSUMER_KEY}+${method}+${url}+${body}+${ts}" \
        | LC_ALL=C openssl dgst -sha1 | LC_ALL=C sed 's/^.* //')
    printf '%s\n' "$ts" '$1$'"$sig_hex"
}

# Zwraca treść odpowiedzi, potem osobną linię z kodem HTTP (zawsze — nawet gdy JSON bez końcowego \n)
ovh_http() {
    local method="$1" path="$2" body="${3:-}"
    local url ts sig tmp code resp_body
    local -a _ovh_sign_lines
    url="${OVH_ENDPOINT%/}/1.0${path}"
    # ovh_sign drukuje 2 linie (timestamp, podpis) — pojedyncze read wczytuje tylko pierwszą; bez sig = 401
    mapfile -t _ovh_sign_lines < <(ovh_sign "$method" "$url" "$body")
    ts=${_ovh_sign_lines[0]}
    sig=${_ovh_sign_lines[1]}
    if [ -z "$ts" ] || [ -z "$sig" ]; then
        echo "WARNING: OVH signature failed (empty ts/sig); check openssl and OVH_* keys." >&2
        return 1
    fi
    tmp=$(mktemp) || return 1
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Ovh-Application: $OVH_APPLICATION_KEY" \
        -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
        -H "X-Ovh-Timestamp: $ts" \
        -H "X-Ovh-Signature: $sig" \
        ${body:+-d "$body"}) || code="000"
    resp_body=$(cat "$tmp")
    rm -f "$tmp"
    printf '%s\n' "$resp_body"
    printf '%s\n' "$code"
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
    if [ -n "$sub" ]; then
        echo "OVH DNS: A ${sub}.${zone} -> $ip"
    else
        echo "OVH DNS: A @ ${zone} -> $ip"
    fi
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
    echo "Usage: $0 [-n NAME] [-d DISK_GB] [-r RAM_GB] [-y] [-z OVH_ZONE] [-s SUBDOMAIN] [-i VMID] [-p IP] [-D]"
    echo "  -n  Virtual Machine name (required)"
    echo "  -d  Disk size in GB (default: 40)"
    echo "  -r  RAM size in GB (default: 2)"
    echo "  -y  Auto-confirm (non-interactive mode)"
    echo "  -z  OVH DNS zone (e.g. example.com); needs OVH_APPLICATION_* + OVH_CONSUMER_KEY"
    echo "  -s  OVH DNS subdomain label (default: VM name lowercased); env OVH_DNS_SUBDOMAIN, or empty for apex"
    echo "  -i  Proxmox VMID (manual); default: auto (max existing < 90000 + 10). Env: DEPLOY_VMID"
    echo "  -p  Guest IPv4 (manual); default: next free from $IP_FILE under $IP_PREFIX.x. Env: DEPLOY_IP"
    echo "  -D  Skip OVH DNS API for this run"
    exit 1
}

while getopts "n:d:r:yz:s:i:p:D" opt; do
    case $opt in
        n) NAME=$OPTARG ;;
        d) DISK_SIZE=$OPTARG ;;
        r) RAM_SIZE=$OPTARG ;;
        y) AUTO_CONFIRM=true ;;
        z) OVH_ZONE=$OPTARG ;;
        s) CLI_DNS_SUB=$OPTARG ;;
        i) CLI_VMID=$OPTARG ;;
        p) CLI_IP=$OPTARG ;;
        D) SKIP_OVH_DNS=true ;;
        *) usage ;;
    esac
done

# =========================
# IP ALLOCATION LOGIC
# =========================
# Priorytet: -p > DEPLOY_IP (env) > auto. Ręczny IP: nie weryfikujemy, czy jest już w $IP_FILE.
if [ -n "$CLI_IP" ]; then
    IP=$CLI_IP
elif [ -n "${DEPLOY_IP:-}" ]; then
    IP=$DEPLOY_IP
else
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
fi

if [ -n "$CLI_IP" ] || [ -n "${DEPLOY_IP:-}" ]; then
    if [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Invalid IPv4 address '$IP'."
        exit 1
    fi
    ip_head="${IP%.*}"
    if [ "$ip_head" != "$IP_PREFIX" ]; then
        echo "ERROR: IP must be under $IP_PREFIX.x (same prefix as IP_PREFIX in script)."
        exit 1
    fi
    mo="${IP##*.}"
    if [ "$mo" -lt 3 ] || [ "$mo" -gt 126 ]; then
        echo "ERROR: Last octet must be between 3 and 126 for this /25 pool (got .$mo)."
        exit 1
    fi
fi

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

# OVH DNS subdomain: -s > OVH_DNS_SUBDOMAIN (env, może być puste = apex) > nazwa VM
if [ -n "$CLI_DNS_SUB" ]; then
    DNS_SUB=$(echo "$CLI_DNS_SUB" | tr '[:upper:]' '[:lower:]')
elif [ -n "${OVH_DNS_SUBDOMAIN+x}" ]; then
    DNS_SUB=$(echo "$OVH_DNS_SUBDOMAIN" | tr '[:upper:]' '[:lower:]')
else
    DNS_SUB=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
fi
if [ -n "$DNS_SUB" ] && [[ ! "$DNS_SUB" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "ERROR: Invalid OVH subDomain '$DNS_SUB' (use letters, digits, hyphens, dots; or empty for apex via env)."
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
# Priorytet: -i > DEPLOY_VMID (env) > auto: najwyższy VMID < 90000 + 10
if [ -n "$CLI_VMID" ]; then
    VMID=$CLI_VMID
elif [ -n "${DEPLOY_VMID:-}" ]; then
    VMID=$DEPLOY_VMID
else
    VMID=$(qm list | awk 'NR>1 && $1 < 90000 {print $1}' | sort -n | tail -1)
    [ -z "$VMID" ] && VMID=1000
    VMID=$((VMID + 10))
fi

if [ -n "$CLI_VMID" ] || [ -n "${DEPLOY_VMID:-}" ]; then
    if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
        echo "ERROR: VMID must be a non-negative integer (got '$VMID')."
        exit 1
    fi
    if [ "$VMID" -lt 100 ] || [ "$VMID" -gt 999999999 ]; then
        echo "ERROR: VMID must be between 100 and 999999999 (Proxmox range)."
        exit 1
    fi
    if qm config "$VMID" &>/dev/null; then
        echo "ERROR: VMID $VMID is already in use (qm config exists)."
        exit 1
    fi
fi

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
    if [ -n "$DNS_SUB" ]; then
        echo "OVH DNS:  ${DNS_SUB}.${OVH_ZONE} -> $IP (A)"
    else
        echo "OVH DNS:  $OVH_ZONE (apex @) -> $IP (A)"
    fi
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
    ovh_dns_set_a "$OVH_ZONE" "$DNS_SUB" "$IP" || true
elif [ "$SKIP_OVH_DNS" = false ] && [ -n "$OVH_ZONE" ]; then
    echo "WARNING: OVH_ZONE is set but OVH_APPLICATION_KEY / OVH_APPLICATION_SECRET / OVH_CONSUMER_KEY are missing — skipping DNS." >&2
fi

echo "Success: VM $NAME ($VMID) deployed with IP $IP 🚀"