# Cloud-init vendor (qm --cicustom vendor=…)

CI_KNOWN_PROFILES=(
    password-login-allowed
    password-login-not-allowed
)

ci_validate_profile() {
    local p="$1"
    if [ -z "$p" ] || [[ ! "$p" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: Nieprawidłowy profil vendor '${p:-(pusty)}' (dozwolone: litery, cyfry, . _ -)." >&2
        return 1
    fi
    return 0
}

ci_effective_profile() {
    if [ -n "${OPT_CI_VENDOR_PROFILE:-}" ]; then
        printf '%s' "$OPT_CI_VENDOR_PROFILE"
        return 0
    fi
    if [ -n "${CI_VENDOR_PROFILE:-}" ]; then
        printf '%s' "$CI_VENDOR_PROFILE"
        return 0
    fi
    if [ -n "${GUEST_PASSWORD:-}" ]; then
        printf '%s' "password-login-allowed"
    else
        printf '%s' "password-login-not-allowed"
    fi
}

ci_snippets_dir() {
    local _try
    IFS=':' read -r -a _parts <<< "${CI_SNIPPETS_PATH:-/var/lib/vz/snippets}"
    for _try in "${_parts[@]}"; do
        [ -z "$_try" ] && continue
        if [ -d "$_try" ]; then
            printf '%s\n' "$_try"
            return 0
        fi
    done
    return 1
}

ci_vendor_yaml() {
    local p="$1"
    local -a _lines=()
    case "$p" in
        password-login-allowed)
            _lines+=("ssh_pwauth: true")
            if [ -n "${GUEST_PASSWORD:-}" ]; then
                _lines+=("chpasswd:")
                _lines+=("  expire: true")
                _lines+=("  list: |")
                _lines+=("    ${GUEST_USERNAME}:${GUEST_PASSWORD}")
            else
                _lines+=("runcmd:")
                _lines+=("  - chage -d 0 ${GUEST_USERNAME}")
            fi
            ;;
        password-login-not-allowed)
            _lines+=("ssh_pwauth: false")
            ;;
        *)
            if [ -n "${GUEST_PASSWORD:-}" ]; then
                _lines+=("ssh_pwauth: true")
            else
                _lines+=("ssh_pwauth: false")
            fi
            ;;
    esac
    [ "${#_lines[@]}" -eq 0 ] && return 0
    echo "#cloud-config"
    printf '%s\n' "${_lines[@]}"
}

ci_apply_vendor() {
    local vmid="$1"
    local _prof _yaml _dir _stor _fn
    _prof=$(ci_effective_profile) || true
    ci_validate_profile "$_prof" || return 1
    _yaml=$(ci_vendor_yaml "$_prof") || true
    [ -z "$_yaml" ] && return 0

    _dir=$(ci_snippets_dir) || {
        echo "ERROR: Żaden katalog z CI_SNIPPETS_PATH nie istnieje: ${CI_SNIPPETS_PATH}" >&2
        return 1
    }
    _stor="${CI_SNIPPETS_STORAGE}"
    if [ -n "${CI_VENDOR_FILENAME_OVERRIDE:-}" ]; then
        _fn="${CI_VENDOR_FILENAME_OVERRIDE}"
    else
        _fn="${_prof}.yml"
    fi
    printf '%s\n' "$_yaml" > "${_dir}/${_fn}" || {
        echo "ERROR: Nie można zapisać vendor cloud-init: ${_dir}/${_fn}" >&2
        return 1
    }
    if ! qm set "$vmid" --cicustom "vendor=${_stor}:snippets/${_fn}"; then
        echo "ERROR: qm set --cicustom vendor=… nie powiodło się (storage ${_stor}, Snippets)." >&2
        return 1
    fi
    echo "Cloud-init: profile=${_prof} vendor=${_stor}:snippets/${_fn} (katalog: ${_dir})"
    return 0
}

ci_list_known_profiles() {
    local _p
    for _p in "${CI_KNOWN_PROFILES[@]}"; do
        printf '%s\n' "$_p"
    done
}

ci_bootstrap_template() {
    local p="$1"
    case "$p" in
        password-login-allowed)
            printf '%s\n' "#cloud-config" \
                "# chpasswd+expire — hasło wstawia deploy; GUEST_USERNAME z deploy.conf" \
                "ssh_pwauth: true" \
                "chpasswd:" \
                "  expire: true" \
                "  list: |" \
                "    ${GUEST_USERNAME}:<hasło>"
            ;;
        password-login-not-allowed)
            printf '%s\n' "#cloud-config" "ssh_pwauth: false"
            ;;
        *)
            printf '%s\n' "#cloud-config" "# profil ${p}"
            ;;
    esac
}

ci_run_bootstrap() {
    local _dir _p _fn _path
    _dir=$(ci_snippets_dir) || {
        echo "ERROR: Brak katalogu Snippets (CI_SNIPPETS_PATH): ${CI_SNIPPETS_PATH}" >&2
        return 1
    }
    echo "Cloud-init vendor — katalog Snippets: ${_dir}"
    echo "Profile (pliki: <profil>.yml):"
    while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        _fn="${_p}.yml"
        _path="${_dir}/${_fn}"
        if [ -f "$_path" ]; then
            echo "  ${_p}  →  ${_fn}  (już istnieje)"
        else
            echo "  ${_p}  →  ${_fn}  (tworzę)"
            ci_bootstrap_template "$_p" > "$_path" || {
                echo "ERROR: Nie można zapisać ${_path}" >&2
                return 1
            }
        fi
    done < <(ci_list_known_profiles)
    echo "Gotowe. Szczegóły: lib/cloudinit.sh (ci_vendor_yaml)."
    return 0
}
