#!/bin/bash

# Konfiguracja: deploy.conf (obowiązkowy), szablon: deploy.conf.example
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_DEPLOY_CONF="$_SCRIPT_DIR/deploy.conf"
if [ ! -f "$_DEPLOY_CONF" ] || [ ! -r "$_DEPLOY_CONF" ]; then
    echo "ERROR: Brak pliku deploy.conf w katalogu skryptu ($_SCRIPT_DIR)." >&2
    echo "Utwórz konfigurację: cp \"$_SCRIPT_DIR/deploy.conf.example\" \"$_DEPLOY_CONF\"  potem edytuj deploy.conf." >&2
    exit 1
fi
# shellcheck source=deploy.conf
. "$_DEPLOY_CONF"
# Opcjonalne nadpisania (sekrety, host-specific) — plik w .gitignore, nie ginie przy git pull
_DEPLOY_LOCAL="$_SCRIPT_DIR/deploy.local.conf"
if [ -f "$_DEPLOY_LOCAL" ] && [ -r "$_DEPLOY_LOCAL" ]; then
    # shellcheck source=deploy.local.conf
    . "$_DEPLOY_LOCAL"
fi

for _req in STORAGE BRIDGE VLAN IP_FILE IP_PREFIX MASK GW USER SSHKEY IMAGE; do
    if [ -z "${!_req}" ]; then
        echo "ERROR: deploy.conf: ustaw niepustą wartość: $_req" >&2
        exit 1
    fi
done

# Domyślne rozmiary z deploy.conf (gdy nie podasz -d / -r); zapas w skrypcie: 40 / 2
DISK_GB_DEFAULT="${DISK_GB_DEFAULT:-40}"
RAM_GB_DEFAULT="${RAM_GB_DEFAULT:-2}"
DISK_SIZE="$DISK_GB_DEFAULT"
RAM_SIZE="$RAM_GB_DEFAULT"

OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_ENDPOINT="${OVH_ENDPOINT:-https://eu.api.ovh.com}"
OVH_DNS_TTL="${OVH_DNS_TTL:-3600}"
# OVH_DNS_WWW_CNAME — deploy.conf: po każdym A dodaj www.<host> -> CNAME (domyślnie włączone; "false" wyłącza).
OVH_DNS_WWW_CNAME="${OVH_DNS_WWW_CNAME:-true}"
# OVH_DNS_AUTO_ZONE / VM_NAME_PREFIX / VM_NAME — deploy.conf; pierwszy rekord A = NAME.strefa (domyślnie NAME = VM_NAME_PREFIX+VMID).
# OVH_DNS_FQDN / OVH_DNS_FQDNS — opcjonalny drugi (i kolejne) rekord(y). -f nadpisuje tylko opcjonalne.
# DEPLOY_VMID, DEPLOY_IP — deploy.conf; nadpisania: -i, -p. Hasło gościa: VM_USER_PASSWORD / -W / -w - (stdin)
SKIP_OVH_DNS=false
CLI_NAME=""
CLI_FQDN=""
CLI_VMID=""
CLI_IP=""
CLI_MAIL_EXTRA=""
CLI_VM_PASSWORD=""
CLI_VM_PASSWORD_STDIN=false
CLI_VM_PASSWORD_PROMPT=false

# SMTP (deploy.conf): MAIL_SMTP_HOST puste = bez e-maila po wdrożeniu
MAIL_SMTP_HOST="${MAIL_SMTP_HOST:-}"
MAIL_SMTP_PORT="${MAIL_SMTP_PORT:-587}"
MAIL_SMTP_USER="${MAIL_SMTP_USER:-}"
MAIL_SMTP_PASSWORD="${MAIL_SMTP_PASSWORD:-}"
MAIL_SMTP_STARTTLS="${MAIL_SMTP_STARTTLS:-true}"
MAIL_SMTP_INSECURE="${MAIL_SMTP_INSECURE:-false}"
# OVH / niektóre serwery: "login" → curl --login-options AUTH=LOGIN (często usuwa błąd 67 przy 587)
MAIL_SMTP_AUTH="${MAIL_SMTP_AUTH:-}"
MAIL_SMTP_DEBUG="${MAIL_SMTP_DEBUG:-false}"
MAIL_FROM="${MAIL_FROM:-}"
MAIL_ADMIN="${MAIL_ADMIN:-}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[deploy-vm]}"
# Hasło użytkownika VM (cloud-init / ciuser); puste = tylko SSH. Najbezpieczniej: -W albo VM_USER_PASSWORD w deploy.local.conf
VM_USER_PASSWORD="${VM_USER_PASSWORD:-}"

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

# Rekord CNAME (tworzy lub aktualizuje dla tej subdomeny); target zwykle FQDN z końcową kropką
ovh_dns_set_cname() {
    local zone="$1" sub="$2" target="$3"
    local list_resp list_code ids first_id post_resp post_code put_resp put_code
    local body_post body_put

    body_post=$(printf '{"fieldType":"CNAME","subDomain":"%s","target":"%s","ttl":%s}' "$sub" "$target" "$OVH_DNS_TTL")

    list_resp=$(ovh_http GET "/domain/zone/${zone}/record?fieldType=CNAME&subDomain=${sub}" "")
    list_code=$(echo "$list_resp" | tail -n1)
    list_body=$(echo "$list_resp" | sed '$d')
    if [ "$list_code" != "200" ]; then
        echo "WARNING: OVH list CNAME failed HTTP $list_code${list_body:+ — $list_body}" >&2
        return 1
    fi

    ids=$(echo "$list_body" | grep -oE '[0-9]+' || true)
    first_id=$(echo "$ids" | head -n1)

    if [ -n "$first_id" ]; then
        body_put=$(printf '{"target":"%s","subDomain":"%s","ttl":%s}' "$target" "$sub" "$OVH_DNS_TTL")
        put_resp=$(ovh_http PUT "/domain/zone/${zone}/record/${first_id}" "$body_put")
        put_code=$(echo "$put_resp" | tail -n1)
        put_body=$(echo "$put_resp" | sed '$d')
        if [ "$put_code" != "200" ]; then
            echo "WARNING: OVH PUT CNAME failed HTTP $put_code${put_body:+ — $put_body}" >&2
            return 1
        fi
    else
        post_resp=$(ovh_http POST "/domain/zone/${zone}/record" "$body_post")
        post_code=$(echo "$post_resp" | tail -n1)
        post_body=$(echo "$post_resp" | sed '$d')
        if [ "$post_code" != "200" ] && [ "$post_code" != "201" ]; then
            echo "WARNING: OVH POST CNAME failed HTTP $post_code${post_body:+ — $post_body}" >&2
            return 1
        fi
    fi

    ovh_zone_refresh "$zone" || true
    if [ -n "$sub" ]; then
        echo "OVH DNS: CNAME ${sub}.${zone} -> $target"
    else
        echo "OVH DNS: CNAME @.${zone} -> $target"
    fi
    return 0
}

# Lista stref DNS na koncie (JSON array) -> jedna strefa na linii, najdłuższe nazwy pierwsze (dopasowanie foo.co.uk)
ovh_fetch_zones_sorted() {
    local resp code body
    resp=$(ovh_http GET "/domain/zone" "")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [ "$code" != "200" ]; then
        echo "WARNING: OVH GET /domain/zone failed HTTP $code${body:+ — $body}" >&2
        return 1
    fi
    echo "$body" | grep -oE '"[^"]+"' | tr -d '"' \
        | while IFS= read -r line; do
            [ -z "$line" ] && continue
            lc=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            printf '%05d\t%s\n' "${#lc}" "$lc"
        done | sort -rn | cut -f2-
}

# FQDN + lista stref -> stdout: pierwsza linia zone, druga subDomain (pusta = @)
ovh_resolve_fqdn() {
    local fqdn="$1" zones_txt="$2"
    local fqdn_lc z sub z_lc
    fqdn_lc=$(echo "$fqdn" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    [ -z "$fqdn_lc" ] && return 1
    while IFS= read -r z; do
        [ -z "$z" ] && continue
        z_lc=$(echo "$z" | tr '[:upper:]' '[:lower:]')
        if [ "$fqdn_lc" = "$z_lc" ]; then
            printf '%s\n' "$z"
            printf '%s\n' ""
            return 0
        fi
        case "$fqdn_lc" in
            *."$z_lc")
                sub=${fqdn_lc%."$z_lc"}
                printf '%s\n' "$z"
                printf '%s\n' "$sub"
                return 0
                ;;
        esac
    done <<< "$zones_txt"
    return 1
}

# Etykieta subdomeny OVH (np. "www" lub "a.b") — ta sama reguła co przy walidacji rekordu A
ovh_dns_label_ok() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
}

ovh_dns_www_cname_enabled() {
    case "${OVH_DNS_WWW_CNAME,,}" in
        false | 0 | no) return 1 ;;
        *) return 0 ;;
    esac
}

# Jeden FQDN ze stref: rekord A, potem opcjonalnie www -> CNAME
ovh_dns_apply_records_for_fqdn() {
    local fqdn="$1" zones_txt="$2" ip="$3"
    local resolved z sd canon canon_lc www_sd

    resolved=$(ovh_resolve_fqdn "$fqdn" "$zones_txt") || resolved=""
    if [ -z "$resolved" ]; then
        echo "WARNING: FQDN '$fqdn' nie pasuje do żadnej strefy DNS na tym koncie OVH — pomijam ten rekord." >&2
        return 0
    fi
    z=$(printf '%s\n' "$resolved" | sed -n '1p')
    sd=$(printf '%s\n' "$resolved" | sed -n '2p')

    if [ -n "$sd" ] && ! ovh_dns_label_ok "$sd"; then
        echo "WARNING: Odrzucono subdomenę '$sd' (nieprawidłowa etykieta) dla '$fqdn'." >&2
        return 0
    fi

    if ! ovh_dns_set_a "$z" "$sd" "$ip"; then
        return 0
    fi

    ovh_dns_www_cname_enabled || return 0

    canon="${fqdn%.}"
    canon_lc=$(echo "$canon" | tr '[:upper:]' '[:lower:]')
    if [ -n "$sd" ]; then
        www_sd="www.${sd}"
    else
        www_sd="www"
    fi
    if ! ovh_dns_label_ok "$www_sd"; then
        echo "WARNING: Pomijam CNAME www dla '$fqdn' (nieprawidłowa etykieta '$www_sd')." >&2
        return 0
    fi
    ovh_dns_set_cname "$z" "$www_sd" "${canon_lc}." || true
}

# Powiadomienie po udanym wdrożeniu (wymaga curl; MAIL_SMTP_HOST + MAIL_FROM + MAIL_ADMIN)
deploy_send_success_mail() {
    local smtp_host="${MAIL_SMTP_HOST:-}"
    [ -z "$smtp_host" ] && return 0

    # Nadawca: jawny MAIL_FROM albo to samo co konto SMTP (OVH wymaga zgodności z loginem)
    local from_a="${MAIL_FROM:-${MAIL_SMTP_USER:-}}"
    local admin_a="${MAIL_ADMIN:-}"
    if [ -z "$from_a" ] || [ -z "$admin_a" ]; then
        echo "WARNING: MAIL_SMTP_HOST jest ustawiony, ale brakuje MAIL_FROM (lub MAIL_SMTP_USER) albo MAIL_ADMIN — pomijam e-mail." >&2
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: Brak polecenia curl — nie wysłano e-maila (SMTP)." >&2
        return 0
    fi

    local port="${MAIL_SMTP_PORT:-587}"
    local rcpts=() _r _k _to_hdr
    declare -A _seen_rcpt=()
    for _r in "$admin_a" "${CLI_MAIL_EXTRA:-}"; do
        [ -z "$_r" ] && continue
        _k=$(echo "$_r" | tr '[:upper:]' '[:lower:]')
        [ -n "${_seen_rcpt[$_k]:-}" ] && continue
        _seen_rcpt[$_k]=1
        rcpts+=("$_r")
    done
    [ "${#rcpts[@]}" -eq 0 ] && return 0

    local subj="${MAIL_SUBJECT_PREFIX} VM $NAME ($VMID) — $IP"
    local body tmp
    body="Wdrożenie zakończone pomyślnie.

Węzeł:    $(hostname 2>/dev/null || echo '?')
VM:       $NAME
VMID:     $VMID
IP:       $IP${MASK}
Dysk:     ${DISK_SIZE}G
RAM:      ${RAM_SIZE}GB
"
    if [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
        body="${body}
DNS (A):"
        for _t in "${OVH_DNS_TARGETS[@]}"; do
            body="${body}
  ${_t} -> $IP"
        done
    fi

    tmp=$(mktemp) || return 1
    _to_hdr=$(printf '%s, ' "${rcpts[@]}")
    _to_hdr=${_to_hdr%, }
    {
        echo "From: $from_a"
        echo "To: $_to_hdr"
        echo "Subject: $subj"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        printf '%s\n' "$body"
    } > "$tmp"

    local -a curl_args=()
    if [ "${MAIL_SMTP_DEBUG,,}" = "true" ] || [ "${MAIL_SMTP_DEBUG,,}" = "1" ] || [ "${MAIL_SMTP_DEBUG,,}" = "yes" ]; then
        curl_args+=(-v)
    else
        curl_args+=(-sS)
    fi
    if [ "${MAIL_SMTP_INSECURE,,}" = "true" ] || [ "${MAIL_SMTP_INSECURE,,}" = "1" ] || [ "${MAIL_SMTP_INSECURE,,}" = "yes" ]; then
        curl_args+=(-k)
    fi
    case "${MAIL_SMTP_AUTH,,}" in
        login) curl_args+=(--login-options AUTH=LOGIN) ;;
        plain) curl_args+=(--login-options AUTH=PLAIN) ;;
    esac
    if [ -n "${MAIL_SMTP_USER:-}" ]; then
        curl_args+=(-u "${MAIL_SMTP_USER}:${MAIL_SMTP_PASSWORD}")
    fi

    local smtp_url
    # 465 = SMTP przez SSL (smtps); bez dodatkowego --ssl-reqd — przy OVH 587+STARTTLS często trzeba MAIL_SMTP_AUTH=login lub przejść na 465
    if [ "$port" = "465" ]; then
        smtp_url="smtps://${smtp_host}:465"
    elif [ "${MAIL_SMTP_STARTTLS,,}" != "false" ] && [ "${MAIL_SMTP_STARTTLS,,}" != "0" ] && [ "${MAIL_SMTP_STARTTLS,,}" != "no" ]; then
        smtp_url="smtp://${smtp_host}:${port}"
        curl_args+=(--ssl-reqd)
    else
        smtp_url="smtp://${smtp_host}:${port}"
    fi

    for _r in "${rcpts[@]}"; do
        curl_args+=(--mail-rcpt "$_r")
    done

    if curl "${curl_args[@]}" --url "$smtp_url" --mail-from "$from_a" --upload-file "$tmp"; then
        echo "E-mail wysłany (SMTP $smtp_host) do: ${rcpts[*]}"
    else
        echo "WARNING: Wysyłka e-maila przez SMTP nie powiodła się (curl)." >&2
    fi
    rm -f "$tmp"
    return 0
}

# =========================
# FLAGS HANDLING
# =========================
AUTO_CONFIRM=false

usage() {
    echo "Usage: $0 [-n NAME] [-d DISK_GB] [-r RAM_GB] [-y] [-f FQDN] [-i VMID] [-p IP] [-W] [-w PASS|-] [-e EMAIL] [-D]"
    echo "  -n  Nazwa VM (nadpisuje domyślną: VM_NAME_PREFIX+VMID i pierwszy rekord DNS). Env / deploy.conf: VM_NAME"
    echo "  -d  Disk size in GB (default: $DISK_GB_DEFAULT)"
    echo "  -r  RAM size in GB (default: $RAM_GB_DEFAULT)"
    echo "  -y  Auto-confirm (non-interactive mode)"
    echo "  -f  OVH DNS: opcjonalny dodatkowy FQDN (drugi rekord); nadpisuje OVH_DNS_FQDN / OVH_DNS_FQDNS (pierwszy: NAME.strefa)"
    echo "  -i  Proxmox VMID (manual); default: losowy 1###### (cyfra 1 + 6 losowych cyfr). Env: DEPLOY_VMID"
    echo "  -p  Guest IPv4 (manual); default: next free from $IP_FILE under $IP_PREFIX.x. Env: DEPLOY_IP"
    echo "  -W  Hasło gościa — pytanie ciche (read -s); hasło nie jest w argv skryptu (najbezpieczniejsze z linii poleceń)"
    echo "  -w  '-' = jedna linia hasła ze stdin (nie w argv tego skryptu). Nie wpisuj hasła w poleceniu printf|… — trafi do historii!"
    echo "      Inny argument -w = jawne hasło w argv (ps, historia — tylko automatyzacja)"
    echo "  -e  Dodatkowy adres e-mail (poza MAIL_ADMIN); powiadomienie SMTP z deploy.conf"
    echo "  -D  Skip OVH DNS API for this run"
    exit 1
}

while getopts "n:d:r:yf:i:p:w:We:D" opt; do
    case $opt in
        n) CLI_NAME=$OPTARG ;;
        d) DISK_SIZE=$OPTARG ;;
        r) RAM_SIZE=$OPTARG ;;
        y) AUTO_CONFIRM=true ;;
        f) CLI_FQDN=$OPTARG ;;
        i) CLI_VMID=$OPTARG ;;
        p) CLI_IP=$OPTARG ;;
        w)
            if [ "$OPTARG" = "-" ]; then
                CLI_VM_PASSWORD_STDIN=true
            else
                CLI_VM_PASSWORD=$OPTARG
                echo "WARNING: hasło w argumencie -w jest widoczne w ps i w historii; użyj -W albo -w - ze stdin (np. plik: -w - < plik)." >&2
            fi
            ;;
        W) CLI_VM_PASSWORD_PROMPT=true ;;
        e) CLI_MAIL_EXTRA=$OPTARG ;;
        D) SKIP_OVH_DNS=true ;;
        *) usage ;;
    esac
done

# Hasło gościa: -W (read -s), -w - (stdin). -w - nie umieszcza hasła w argv deploy-vm.sh; i tak unikaj hasła w całym poleceniu (np. printf 'haslo'|…).
if [ "$CLI_VM_PASSWORD_PROMPT" = true ]; then
    CLI_VM_PASSWORD=""
    if [ -r /dev/tty ]; then
        read -r -s -p "Hasło użytkownika VM ($USER): " CLI_VM_PASSWORD </dev/tty || true
    else
        read -r -s -p "Hasło użytkownika VM ($USER): " CLI_VM_PASSWORD || true
    fi
    echo "" >&2
elif [ "$CLI_VM_PASSWORD_STDIN" = true ]; then
    CLI_VM_PASSWORD=""
    read -r CLI_VM_PASSWORD || true
fi

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
# DISK / RAM (interactive)
# =========================
if [ "$AUTO_CONFIRM" = false ]; then
    read -p "Enter Disk size (GB) [default $DISK_SIZE]: " INPUT_DISK
    DISK_SIZE=${INPUT_DISK:-$DISK_SIZE}

    read -p "Enter RAM size (GB) [default $RAM_SIZE]: " INPUT_RAM
    RAM_SIZE=${INPUT_RAM:-$RAM_SIZE}
fi

RAM_MB=$((RAM_SIZE * 1024))

# =========================
# FIND VMID (przed nazwą i DNS — nazwa = VM_NAME_PREFIX + VMID)
# =========================
# Priorytet: -i > DEPLOY_VMID (env) > auto: losowy 1 + 6 cyfr (1000000–1999999), aż trafisz wolny ID
if [ -n "$CLI_VMID" ]; then
    VMID=$CLI_VMID
elif [ -n "${DEPLOY_VMID:-}" ]; then
    VMID=$DEPLOY_VMID
else
    _vm_try=0
    _vm_max=80
    while [ "$_vm_try" -lt "$_vm_max" ]; do
        _vm_six=$(command -v shuf >/dev/null 2>&1 && shuf -i 0-999999 -n 1 || awk 'BEGIN{srand(); print int(rand() * 1000000)}')
        VMID=$((1000000 + _vm_six))
        if ! qm config "$VMID" &>/dev/null; then
            break
        fi
        _vm_try=$((_vm_try + 1))
    done
    if [ "$_vm_try" -ge "$_vm_max" ]; then
        echo "ERROR: Nie udało się wylosować wolnego VMID (zakres 1######) po $_vm_max próbach." >&2
        exit 1
    fi
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

VM_NAME_PREFIX="${VM_NAME_PREFIX:-server}"
# Nazwa VM: -n > VM_NAME (deploy.conf) > VM_NAME_PREFIX+VMID
NAME="${VM_NAME_PREFIX}${VMID}"
if [ -n "$CLI_NAME" ]; then
    NAME=$CLI_NAME
elif [ -n "${VM_NAME:-}" ]; then
    NAME=$VM_NAME
fi
if [[ ! "$NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    echo "ERROR: Nieprawidłowa nazwa VM '$NAME' (zaczyna się od litery; potem litery, cyfry, _ i -)." >&2
    exit 1
fi

# Rekordy A: (1) NAME.strefa; (2) opcjonalnie: -f > OVH_DNS_FQDNS > OVH_DNS_FQDN
OVH_DNS_OPTIONAL=()
if [ -n "$CLI_FQDN" ]; then
    OVH_DNS_OPTIONAL=("$CLI_FQDN")
elif [ -n "${OVH_DNS_FQDNS+x}" ] && [ "${#OVH_DNS_FQDNS[@]}" -gt 0 ]; then
    OVH_DNS_OPTIONAL=("${OVH_DNS_FQDNS[@]}")
elif [ -n "${OVH_DNS_FQDN:-}" ]; then
    OVH_DNS_OPTIONAL=("$OVH_DNS_FQDN")
fi

OVH_DNS_TARGETS=()
OVH_DNS_AUTO_FQDN=""
if [ "$SKIP_OVH_DNS" = false ]; then
    if [ -z "${OVH_DNS_AUTO_ZONE:-}" ]; then
        echo "ERROR: deploy.conf: ustaw OVH_DNS_AUTO_ZONE (pierwszy rekord A: <NAME>.<strefa>)." >&2
        exit 1
    fi
    OVH_DNS_AUTO_FQDN="${NAME}.${OVH_DNS_AUTO_ZONE}"
    OVH_DNS_TARGETS+=("$OVH_DNS_AUTO_FQDN")
fi
for _o in "${OVH_DNS_OPTIONAL[@]}"; do
    OVH_DNS_TARGETS+=("$_o")
done

# Hasło konta gościa (cloud-init): -W / -w / -w - > VM_USER_PASSWORD (deploy.conf)
GUEST_PASSWORD="${CLI_VM_PASSWORD:-${VM_USER_PASSWORD:-}}"

# =========================
# CONFIRMATION
# =========================
echo ""
echo "--- Deployment Configuration ---"
echo "VMID:     $VMID"
echo "Name:     $NAME"
echo "Guest:    $USER (cloud-init)"
if [ -n "$GUEST_PASSWORD" ]; then
    echo "Password: (ustawione — logowanie hasłem + SSH)"
else
    echo "Password: (brak — tylko klucz SSH)"
fi
echo "IP:       $IP$MASK"
echo "Disk:     ${DISK_SIZE}G"
echo "RAM:      ${RAM_MB}MB (${RAM_SIZE}GB)"
if [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
    for _t in "${OVH_DNS_TARGETS[@]}"; do
        echo "OVH DNS:  ${_t} -> $IP (A)"
        if ovh_dns_www_cname_enabled; then
            echo "OVH DNS:  www.${_t} -> CNAME ${_t}."
        fi
    done
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

if [ -n "$GUEST_PASSWORD" ]; then
    qm set "$VMID" --cipassword "$GUEST_PASSWORD"
fi

# Save IP to tracking file and start VM
echo "$IP" >> "$IP_FILE"
qm start $VMID

if [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ] \
    && [ -n "${OVH_APPLICATION_KEY:-}" ] && [ -n "${OVH_APPLICATION_SECRET:-}" ] && [ -n "${OVH_CONSUMER_KEY:-}" ]; then
    _zones_sorted=$(ovh_fetch_zones_sorted) || _zones_sorted=""
    if [ -z "$_zones_sorted" ]; then
        echo "WARNING: Nie udało się pobrać listy stref OVH (/domain/zone) — pomijam DNS." >&2
    else
        for _fqdn in "${OVH_DNS_TARGETS[@]}"; do
            ovh_dns_apply_records_for_fqdn "$_fqdn" "$_zones_sorted" "$IP"
        done
    fi
elif [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
    echo "WARNING: OVH DNS (FQDN) skonfigurowane, ale brak OVH_APPLICATION_KEY / OVH_APPLICATION_SECRET / OVH_CONSUMER_KEY — pomijam DNS." >&2
fi

echo "Success: VM $NAME ($VMID) deployed with IP $IP 🚀"
deploy_send_success_mail || true