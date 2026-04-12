# Parsowanie opcji CLI (getopts)

AUTO_CONFIRM=false
SKIP_OVH_DNS=false

OPT_VM_NAME=""
OPT_EXTRA_FQDN=""
OPT_VMID=""
OPT_GUEST_IP=""
OPT_MAIL_EXTRA=""
OPT_GUEST_PASSWORD=""
OPT_GUEST_PASSWORD_STDIN=false
OPT_GUEST_PASSWORD_PROMPT=false
OPT_RANDOM_GUEST_PASSWORD=false
OPT_NO_SSH_PUBLIC_KEY=false
OPT_SSH_PUBLIC_KEY_PATH=""
OPT_CI_VENDOR_PROFILE=""
OPT_CI_BOOTSTRAP=false

usage() {
    echo "Składnia: $0 [-n NAZWA] [-d DYSK_GiB] [-r RAM_GiB] [-y] [-f FQDN] [-i VMID] [-p IP] [-k PLIK_PUB] [-W] [-w [HASŁO|-]] [-e EMAIL] [-P PROFIL] [-C] [-D]"
    echo "  -n  Nazwa VM (VM_NAME_PREFIX+VMID, pierwszy DNS). Opcjonalnie: VM_CUSTOM_NAME w deploy.conf"
    echo "  -d  Dysk (GiB), domyślnie: $DISK_GIB_DEFAULT"
    echo "  -r  RAM (GiB), domyślnie: $RAM_GIB_DEFAULT"
    echo "  -y  Deploy bez pytania"
    echo "  -f  Dodatkowy FQDN (OVH DNS); nadpisuje OVH_DNS_FQDN / OVH_DNS_FQDNS"
    echo "  -i  VMID (ręcznie); domyślnie losowy 1######. Env: DEPLOY_VMID"
    echo "  -p  IPv4 gościa; domyślnie z $IP_FILE. Env: DEPLOY_IP"
    echo "  -k  Ścieżka do .pub (cloud-init); z hasłem też dodaje klucz; nadpisuje SSH_PUBLIC_KEY_FILE"
    echo "  -W  Hasło gościa (read -s)"
    echo "  -w  Bez argumentu: losowe hasło 14 znaków (A–Z, a–z, 0–9). -w - = stdin; -w HASŁO lub -wHASŁO (widoczne w ps)"
    echo "  -e  Dodatkowy e-mail (poza MAIL_ADMIN)"
    echo "  -K  Bez klucza SSH w cloud-init (pierwszeństwo przed -k); w deploy.conf: CI_SSH_PUBLIC_KEY_ENABLED=false"
    echo "  -P  Profil vendor (cicustom); nadpisuje CI_VENDOR_PROFILE"
    echo "  -C  Lista profili + szablony .yml w Snippets; koniec"
    echo "  -D  Pomiń API OVH DNS"
    exit 1
}

parse_cli() {
    OPT_RANDOM_GUEST_PASSWORD=false
    local -a _pre=()
    local _i _j _n _next
    _i=1
    while [ "$_i" -le "$#" ]; do
        _n="${!_i}"
        if [ "$_n" = "-w" ]; then
            _next=""
            _j=$((_i + 1))
            if [ "$_j" -le "$#" ]; then
                _next="${!_j}"
            fi
            if [[ -z "$_next" ]]; then
                OPT_RANDOM_GUEST_PASSWORD=true
                _i=$((_i + 1))
            elif [ "$_next" = "-" ]; then
                _pre+=(-w -)
                _i=$((_i + 2))
            elif [[ "$_next" == -* ]]; then
                OPT_RANDOM_GUEST_PASSWORD=true
                _i=$((_i + 1))
            else
                _pre+=(-w "$_next")
                _i=$((_i + 2))
            fi
        else
            _pre+=("$_n")
            _i=$((_i + 1))
        fi
    done
    set -- "${_pre[@]}"
    OPTIND=1
    while getopts "n:d:r:yf:i:p:k:w:We:DKP:C" opt; do
        case $opt in
            n) OPT_VM_NAME=$OPTARG ;;
            d) DISK_SIZE=$OPTARG ;;
            r) RAM_SIZE=$OPTARG ;;
            y) AUTO_CONFIRM=true ;;
            f) OPT_EXTRA_FQDN=$OPTARG ;;
            i) OPT_VMID=$OPTARG ;;
            p) OPT_GUEST_IP=$OPTARG ;;
            k) OPT_SSH_PUBLIC_KEY_PATH=$OPTARG ;;
            w)
                if [ "$OPTARG" = "-" ]; then
                    OPT_GUEST_PASSWORD_STDIN=true
                else
                    OPT_GUEST_PASSWORD=$OPTARG
                    echo "WARNING: hasło w -w jest widoczne w ps; użyj -W albo -w - ze stdin." >&2
                fi
                ;;
            W) OPT_GUEST_PASSWORD_PROMPT=true ;;
            e) OPT_MAIL_EXTRA=$OPTARG ;;
            K) OPT_NO_SSH_PUBLIC_KEY=true ;;
            P) OPT_CI_VENDOR_PROFILE=$OPTARG ;;
            C) OPT_CI_BOOTSTRAP=true ;;
            D) SKIP_OVH_DNS=true ;;
            *) usage ;;
        esac
    done
}
