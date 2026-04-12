# Powiadomienie e-mail po deployu (SMTP + curl)
#
# Odbiorcy: widoczny To = -e albo MAIL_TO_PUBLIC; oba mogą być puste.
# MAIL_ADMIN = Bcc, gdy jest widoczny To i adres różni się od To.
# Gdy brak To, ale jest MAIL_ADMIN — jedna wiadomość, To: = MAIL_ADMIN (tylko powiadomienie dla admina).
# Gdy brak To i brak MAIL_ADMIN — brak wysyłki (ciche pominięcie).

send_deploy_success_mail() {
    local smtp_host="${MAIL_SMTP_HOST:-}"
    [ -z "$smtp_host" ] && return 0

    local from_a="${MAIL_FROM:-${MAIL_SMTP_USER:-}}"
    local to_visible bcc_admin to_header _tl _al _only_admin

    to_visible="${OPT_MAIL_EXTRA:-}"
    if [ -z "$to_visible" ]; then
        to_visible="${MAIL_TO_PUBLIC:-}"
    fi
    bcc_admin="${MAIL_ADMIN:-}"

    if [ -z "$to_visible" ] && [ -z "$bcc_admin" ]; then
        return 0
    fi

    _only_admin=false
    if [ -z "$to_visible" ] && [ -n "$bcc_admin" ]; then
        to_visible="$bcc_admin"
        _only_admin=true
    fi

    if [ -z "$from_a" ]; then
        echo "WARNING: Brak MAIL_FROM (lub MAIL_SMTP_USER) — pomijam e-mail." >&2
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: Brak polecenia curl — nie wysłano e-maila (SMTP)." >&2
        return 0
    fi

    local port="${MAIL_SMTP_PORT:-587}"

    # Temat: [pełna domena] jeśli jest (strefa DNS / FQDN auto), inaczej [tylko nazwa VM].
    local subj _bracket
    if [ -n "${MAIL_SUBJECT:-}" ]; then
        subj="$MAIL_SUBJECT"
    else
        _bracket="${VM_NAME}"
        if [ -n "${OVH_DNS_AUTO_FQDN:-}" ]; then
            _bracket="$OVH_DNS_AUTO_FQDN"
        elif [ -n "${OVH_DNS_AUTO_ZONE:-}" ]; then
            _bracket="${VM_NAME}.${OVH_DNS_AUTO_ZONE}"
        fi
        subj="[${_bracket}] Instalacja serwera VPS"
    fi
    local body tmp _t _canon _www_fqdn

    body="Dzień dobry,
dziękujemy, że wybrałeś nasze usługi.
Informujemy, że Twój VPS został zainstalowany i jest gotowy do użycia!

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
        body="${body}Hasło:    ${GUEST_PASSWORD} (hasło musi zostać zmienione przy pierwszym logowaniu)
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
    to_header="$to_visible"
    {
        echo "From: $from_a"
        echo "To: $to_header"
        echo "Reply-To: ${MAIL_REPLY_TO:-support@hostier.pl}"
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

    if [ "$_only_admin" = true ]; then
        curl_args+=(--mail-rcpt "$bcc_admin")
    else
        curl_args+=(--mail-rcpt "$to_visible")
        _tl=$(echo "$to_visible" | tr '[:upper:]' '[:lower:]')
        if [ -n "$bcc_admin" ]; then
            _al=$(echo "$bcc_admin" | tr '[:upper:]' '[:lower:]')
            if [ "$_tl" != "$_al" ]; then
                curl_args+=(--mail-rcpt "$bcc_admin")
            fi
        fi
    fi

    if curl "${curl_args[@]}" --url "$smtp_url" --mail-from "$from_a" --upload-file "$tmp"; then
        if [ "$_only_admin" = true ]; then
            echo "E-mail wysłany (SMTP $smtp_host) — tylko MAIL_ADMIN (brak -e i MAIL_TO_PUBLIC): $bcc_admin"
        elif [ -n "$bcc_admin" ] && [ "$(echo "$to_visible" | tr '[:upper:]' '[:lower:]')" != "$(echo "$bcc_admin" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "E-mail wysłany (SMTP $smtp_host) — To: $to_visible, Bcc: $bcc_admin"
        elif [ -n "$bcc_admin" ]; then
            echo "E-mail wysłany (SMTP $smtp_host) — To: $to_visible (to samo co MAIL_ADMIN, jedna dostawa)"
        else
            echo "E-mail wysłany (SMTP $smtp_host) — To: $to_visible"
        fi
    else
        echo "WARNING: Wysyłka e-maila przez SMTP nie powiodła się (curl)." >&2
    fi
    rm -f "$tmp"
    return 0
}
