# Główna ścieżka deploy VM

# (1) openssl rand -hex 7 → 14 znaków hex; (2) /dev/urandom → A–Z a–z 0–9.
# Komunikat „źródło: …” idzie na stderr (&2), żeby nie mieszać się z hasłem na stdout w $(…).
deploy_random_password_14() {
    local _p=""
    if command -v openssl >/dev/null 2>&1; then
        _p=$(openssl rand -hex 7 2>/dev/null | tr -d '\n')
        if [ "${#_p}" -eq 14 ]; then
            echo "deploy-vm: losowe hasło — źródło: openssl rand -hex 7" >&2
            printf '%s' "$_p"
            return 0
        fi
    fi
    if [ -r /dev/urandom ]; then
        _p=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 14)
    fi
    if [ "${#_p}" -eq 14 ]; then
        echo "deploy-vm: losowe hasło — źródło: /dev/urandom (A–Z a–z 0–9)" >&2
        printf '%s' "$_p"
        return 0
    fi
    echo "ERROR: Nie można wygenerować losowego hasła (openssl/urandom)." >&2
    return 1
}

deploy_run() {
    DISK_SIZE="$DISK_GIB_DEFAULT"
    RAM_SIZE="$RAM_GIB_DEFAULT"
    parse_cli "$@"

    if [ "$OPT_CI_BOOTSTRAP" = true ]; then
        ci_run_bootstrap || exit 1
        exit 0
    fi

    if [ "$OPT_GUEST_PASSWORD_PROMPT" = true ]; then
        OPT_GUEST_PASSWORD=""
        if [ -r /dev/tty ]; then
            read -r -s -p "Hasło użytkownika VM (${GUEST_USERNAME}): " OPT_GUEST_PASSWORD </dev/tty || true
        else
            read -r -s -p "Hasło użytkownika VM (${GUEST_USERNAME}): " OPT_GUEST_PASSWORD || true
        fi
        echo "" >&2
    elif [ "$OPT_GUEST_PASSWORD_STDIN" = true ]; then
        OPT_GUEST_PASSWORD=""
        read -r OPT_GUEST_PASSWORD || true
    elif [ "${OPT_RANDOM_GUEST_PASSWORD:-false}" = true ]; then
        OPT_GUEST_PASSWORD=$(deploy_random_password_14) || exit 1
        OPT_GUEST_PASSWORD=$(printf '%s' "$OPT_GUEST_PASSWORD" | tr -d '\r\n')
    fi

    if [ -n "$OPT_GUEST_IP" ]; then
        GUEST_IP=$OPT_GUEST_IP
    elif [ -n "${DEPLOY_IP:-}" ]; then
        GUEST_IP=$DEPLOY_IP
    else
        local last_octet new_octet
        last_octet=$(awk -F. '{print $4}' "$IP_FILE" | sort -n | tail -1)
        if [ -z "$last_octet" ]; then
            new_octet=3
        else
            new_octet=$((last_octet + 1))
        fi
        if [ "$new_octet" -gt 126 ]; then
            echo "ERROR: Limit adresów /25." >&2
            exit 1
        fi
        GUEST_IP="$IP_PREFIX.$new_octet"
    fi

    if [ -n "$OPT_GUEST_IP" ] || [ -n "${DEPLOY_IP:-}" ]; then
        if [[ ! "$GUEST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "ERROR: Nieprawidłowy IPv4: '$GUEST_IP'." >&2
            exit 1
        fi
        local ip_head mo
        ip_head="${GUEST_IP%.*}"
        if [ "$ip_head" != "$IP_PREFIX" ]; then
            echo "ERROR: IP musi być w $IP_PREFIX.x." >&2
            exit 1
        fi
        mo="${GUEST_IP##*.}"
        if [ "$mo" -lt 3 ] || [ "$mo" -gt 126 ]; then
            echo "ERROR: Ostatni oktet 3–126 (mam .$mo)." >&2
            exit 1
        fi
    fi

    if [ "$AUTO_CONFIRM" = false ]; then
        read -r -p "Rozmiar dysku (GiB) [${DISK_SIZE}]: " INPUT_DISK
        DISK_SIZE=${INPUT_DISK:-$DISK_SIZE}
        read -r -p "RAM (GiB) [${RAM_SIZE}]: " INPUT_RAM
        RAM_SIZE=${INPUT_RAM:-$RAM_SIZE}
    fi

    RAM_MIB=$((RAM_SIZE * 1024))

    if [ -n "$OPT_VMID" ]; then
        VMID=$OPT_VMID
    elif [ -n "${DEPLOY_VMID:-}" ]; then
        VMID=$DEPLOY_VMID
    else
        local _try _max _six
        _try=0
        _max=80
        while [ "$_try" -lt "$_max" ]; do
            _six=$(command -v shuf >/dev/null 2>&1 && shuf -i 0-999999 -n 1 || awk 'BEGIN{srand(); print int(rand() * 1000000)}')
            VMID=$((1000000 + _six))
            if ! qm config "$VMID" &>/dev/null; then
                break
            fi
            _try=$((_try + 1))
        done
        if [ "$_try" -ge "$_max" ]; then
            echo "ERROR: Brak wolnego VMID po $_max próbach." >&2
            exit 1
        fi
    fi

    if [ -n "$OPT_VMID" ] || [ -n "${DEPLOY_VMID:-}" ]; then
        if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
            echo "ERROR: VMID musi być liczbą (mam: '$VMID')." >&2
            exit 1
        fi
        if [ "$VMID" -lt 100 ] || [ "$VMID" -gt 999999999 ]; then
            echo "ERROR: VMID poza zakresem Proxmox." >&2
            exit 1
        fi
        if qm config "$VMID" &>/dev/null; then
            echo "ERROR: VMID $VMID zajęty." >&2
            exit 1
        fi
    fi

    VM_NAME_PREFIX="${VM_NAME_PREFIX:-server}"
    VM_NAME="${VM_NAME_PREFIX}${VMID}"
    if [ -n "$OPT_VM_NAME" ]; then
        VM_NAME=$OPT_VM_NAME
    elif [ -n "${VM_CUSTOM_NAME:-}" ]; then
        VM_NAME=$VM_CUSTOM_NAME
    fi
    if [[ ! "$VM_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "ERROR: Nieprawidłowa nazwa VM '$VM_NAME'." >&2
        exit 1
    fi

    OVH_DNS_OPTIONAL=()
    if [ -n "$OPT_EXTRA_FQDN" ]; then
        OVH_DNS_OPTIONAL=("$OPT_EXTRA_FQDN")
    elif [ -n "${OVH_DNS_FQDNS+x}" ] && [ "${#OVH_DNS_FQDNS[@]}" -gt 0 ]; then
        OVH_DNS_OPTIONAL=("${OVH_DNS_FQDNS[@]}")
    elif [ -n "${OVH_DNS_FQDN:-}" ]; then
        OVH_DNS_OPTIONAL=("$OVH_DNS_FQDN")
    fi

    OVH_DNS_TARGETS=()
    OVH_DNS_AUTO_FQDN=""
    if [ "$SKIP_OVH_DNS" = false ]; then
        if [ -z "${OVH_DNS_AUTO_ZONE:-}" ]; then
            echo "ERROR: deploy.conf: ustaw OVH_DNS_AUTO_ZONE." >&2
            exit 1
        fi
        OVH_DNS_AUTO_FQDN="${VM_NAME}.${OVH_DNS_AUTO_ZONE}"
        OVH_DNS_TARGETS+=("$OVH_DNS_AUTO_FQDN")
    fi
    local _o
    for _o in "${OVH_DNS_OPTIONAL[@]}"; do
        OVH_DNS_TARGETS+=("$_o")
    done

    GUEST_PASSWORD="${OPT_GUEST_PASSWORD:-${GUEST_PASSWORD_CONFIG:-}}"

    CI_VENDOR_PROFILE_EFFECTIVE=$(ci_effective_profile)
    if ! ci_validate_profile "$CI_VENDOR_PROFILE_EFFECTIVE"; then
        exit 1
    fi

    if [ "$CI_VENDOR_PROFILE_EFFECTIVE" = "password-login-allowed" ] && [ -n "${GUEST_PASSWORD:-}" ]; then
        if printf '%s' "$GUEST_PASSWORD" | grep -q $'\n'; then
            echo "ERROR: Hasło nie może zawierać znaku nowej linii (profil password-login-allowed)." >&2
            exit 1
        fi
    fi

    guest_auth_resolve

    if [ "$INJECT_SSH_PUBLIC_KEY" = false ] && [ -z "$GUEST_PASSWORD" ]; then
        echo "WARNING: Bez klucza SSH i bez hasła logowanie z sieci zwykle niemożliwe." >&2
    fi

    QM_SET_CIPASSWORD=false
    if [ -n "$GUEST_PASSWORD" ] && [ "$CI_VENDOR_PROFILE_EFFECTIVE" != "password-login-allowed" ]; then
        QM_SET_CIPASSWORD=true
    fi

    echo ""
    echo "--- Konfiguracja wdrożenia ---"
    echo "VMID:     $VMID"
    echo "Nazwa:    $VM_NAME"
    echo "Gość:     $GUEST_USERNAME (cloud-init)"
    if [ -n "$GUEST_PASSWORD" ]; then
        if [ "${OPT_RANDOM_GUEST_PASSWORD:-false}" = true ]; then
            echo "Hasło:    $GUEST_PASSWORD (losowe, 14 znaków)"
        else
            echo "Hasło:    (ustawione)"
        fi
    else
        echo "Hasło:    (brak)"
    fi
    if [ "$INJECT_SSH_PUBLIC_KEY" = true ]; then
        echo "Klucz SSH: $EFFECTIVE_SSH_PUBLIC_KEY_FILE"
    else
        echo "Klucz SSH: (pominięty)"
    fi
    echo "Profil vendor CI: $CI_VENDOR_PROFILE_EFFECTIVE (${CI_VENDOR_PROFILE_EFFECTIVE}.yml)"
    echo "IP:       $GUEST_IP$MASK"
    echo "Dysk:     ${DISK_SIZE} GiB"
    echo "RAM:      ${RAM_MIB} MiB (${RAM_SIZE} GiB)"
    if [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
        local _t
        for _t in "${OVH_DNS_TARGETS[@]}"; do
            echo "OVH DNS:  ${_t} -> $GUEST_IP (A)"
            if ovh_dns_www_cname_enabled; then
                echo "OVH DNS:  www.${_t} -> CNAME ${_t}."
            fi
        done
    fi
    echo "-------------------------------"

    if [ "$AUTO_CONFIRM" = false ]; then
        read -r -p "Kontynuować wdrożenie? [t/N]: " CONFIRM
        if [[ ! "${CONFIRM,,}" =~ ^(t|tak|y|yes)$ ]]; then
            echo "Anulowano."
            exit 0
        fi
    fi

    echo "Start wdrożenia..."

    qm create "$VMID" \
        --name "$VM_NAME" \
        --memory "$RAM_MIB" \
        --cores 2 \
        --net0 "virtio,bridge=$BRIDGE,tag=$VLAN" \
        --scsihw virtio-scsi-single \
        --serial0 socket --vga serial0

    qm importdisk "$VMID" "$IMAGE" "$STORAGE"
    qm set "$VMID" --scsi0 "$STORAGE:vm-$VMID-disk-0" --boot order=scsi0
    qm resize "$VMID" scsi0 "${DISK_SIZE}G"

    qm set "$VMID" --ide2 "$STORAGE:cloudinit"
    qm set "$VMID" \
        --ciuser "$GUEST_USERNAME" \
        --ipconfig0 "ip=$GUEST_IP$MASK,gw=$GW" \
        --nameserver "$GW"
    if [ "$INJECT_SSH_PUBLIC_KEY" = true ]; then
        qm set "$VMID" --sshkey "$EFFECTIVE_SSH_PUBLIC_KEY_FILE"
    fi

    if [ "$QM_SET_CIPASSWORD" = true ]; then
        qm set "$VMID" --cipassword "$GUEST_PASSWORD"
    fi

    ci_apply_vendor "$VMID" || exit 1

    echo "$GUEST_IP" >> "$IP_FILE"
    qm start "$VMID"

    if [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ] \
        && [ -n "${OVH_APPLICATION_KEY:-}" ] && [ -n "${OVH_APPLICATION_SECRET:-}" ] && [ -n "${OVH_CONSUMER_KEY:-}" ]; then
        local _zones_sorted _fqdn
        _zones_sorted=$(ovh_fetch_zones_sorted) || _zones_sorted=""
        if [ -z "$_zones_sorted" ]; then
            echo "WARNING: Nie udało się pobrać stref OVH — pomijam DNS." >&2
        else
            for _fqdn in "${OVH_DNS_TARGETS[@]}"; do
                ovh_dns_apply_records_for_fqdn "$_fqdn" "$_zones_sorted" "$GUEST_IP"
            done
        fi
    elif [ "$SKIP_OVH_DNS" = false ] && [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
        echo "WARNING: OVH DNS skonfigurowane, ale brak kluczy API — pomijam DNS." >&2
    fi

    echo "Sukces: VM $VM_NAME ($VMID), IP $GUEST_IP"
    send_deploy_success_mail || true
}
