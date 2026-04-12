# Powiadomienie e-mail po deployu (SMTP + curl)

send_deploy_success_mail() {
    local smtp_host="${MAIL_SMTP_HOST:-}"
    [ -z "$smtp_host" ] && return 0

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
    for _r in "$admin_a" "${OPT_MAIL_EXTRA:-}"; do
        [ -z "$_r" ] && continue
        _k=$(echo "$_r" | tr '[:upper:]' '[:lower:]')
        [ -n "${_seen_rcpt[$_k]:-}" ] && continue
        _seen_rcpt[$_k]=1
        rcpts+=("$_r")
    done
    [ "${#rcpts[@]}" -eq 0 ] && return 0

    local subj="${MAIL_SUBJECT_PREFIX} VM $VM_NAME ($VMID) — $GUEST_IP"
    local body tmp _t _canon _www_fqdn

    body="Wdrożenie zakończone pomyślnie.

System:        ${GUEST_OS_LABEL:-?}
Nazwa serwera: $VM_NAME
IPv4:            $GUEST_IP${MASK}
Dysk:          ${DISK_SIZE} GiB
RAM:           ${RAM_MIB} MiB (${RAM_SIZE} GiB)
"
    body="${body}
Użytkownik: ${GUEST_USERNAME}
"
    if [ -n "${GUEST_PASSWORD:-}" ]; then
        body="${body}Hasło:    ${GUEST_PASSWORD}
"
    fi
    if [ "${INJECT_SSH_PUBLIC_KEY:-false}" = true ]; then
        body="${body}Logowanie: klucz publiczny SSH (cloud-init) — ${EFFECTIVE_SSH_PUBLIC_KEY_FILE}
"
    elif [ -z "${GUEST_PASSWORD:-}" ]; then
        body="${body}Logowanie: (brak hasła w deployu; bez wstrzykniętego klucza SSH)
"
    fi

    if [ "${#OVH_DNS_TARGETS[@]}" -gt 0 ]; then
        if [ "$SKIP_OVH_DNS" = true ]; then
            body="${body}
Uwaga: OVH pominięty (-D) — poniżej skonfigurowane FQDN (bez zapisu w API)."
        fi
        body="${body}
DNS (A):"
        for _t in "${OVH_DNS_TARGETS[@]}"; do
            body="${body}
  ${_t} -> $GUEST_IP"
        done
        if [ "$SKIP_OVH_DNS" = false ] && ovh_dns_www_cname_enabled; then
            body="${body}
DNS (CNAME):"
            for _t in "${OVH_DNS_TARGETS[@]}"; do
                _canon=$(printf '%s' "${_t%.}" | tr '[:upper:]' '[:lower:]')
                _www_fqdn="www.${_canon}"
                body="${body}
  ${_www_fqdn} -> ${_canon}"
            done
        fi
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
    if truthy "${MAIL_SMTP_DEBUG:-}"; then
        curl_args+=(-v)
    else
        curl_args+=(-sS)
    fi
    if truthy "${MAIL_SMTP_INSECURE:-}"; then
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
    if [ "$port" = "465" ]; then
        smtp_url="smtps://${smtp_host}:465"
    elif ! falsey "${MAIL_SMTP_STARTTLS}"; then
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
