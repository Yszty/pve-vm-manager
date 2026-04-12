# Klucz SSH w cloud-init: INJECT_SSH_PUBLIC_KEY, EFFECTIVE_SSH_PUBLIC_KEY_FILE

guest_auth_resolve() {
    INJECT_SSH_PUBLIC_KEY=true
    if [ "${OPT_NO_SSH_PUBLIC_KEY:-false}" = true ]; then
        INJECT_SSH_PUBLIC_KEY=false
    elif ! truthy "${CI_SSH_PUBLIC_KEY_ENABLED:-true}"; then
        INJECT_SSH_PUBLIC_KEY=false
    fi

    if [ -n "${GUEST_PASSWORD:-}" ]; then
        INJECT_SSH_PUBLIC_KEY=false
    fi
    if [ -n "${OPT_SSH_PUBLIC_KEY_PATH:-}" ] && [ "${OPT_NO_SSH_PUBLIC_KEY:-false}" != true ]; then
        INJECT_SSH_PUBLIC_KEY=true
    fi

    EFFECTIVE_SSH_PUBLIC_KEY_FILE="${OPT_SSH_PUBLIC_KEY_PATH:-$SSH_PUBLIC_KEY_FILE}"

    if [ "$INJECT_SSH_PUBLIC_KEY" = true ]; then
        if [ -z "${EFFECTIVE_SSH_PUBLIC_KEY_FILE:-}" ] || [ ! -r "$EFFECTIVE_SSH_PUBLIC_KEY_FILE" ]; then
            echo "ERROR: Brak czytelnego pliku klucza SSH (.pub): ${EFFECTIVE_SSH_PUBLIC_KEY_FILE:-(pusty)}. Użyj -k albo SSH_PUBLIC_KEY_FILE; wyłączenie: -K lub CI_SSH_PUBLIC_KEY_ENABLED=false." >&2
            exit 1
        fi
    fi
}
