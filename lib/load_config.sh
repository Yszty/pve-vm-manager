# Wczytanie deploy.conf i deploy.local.conf — zmienne dla pozostałych modułów.
# Wywołanie: po ustawieniu DEPLOY_VM_SCRIPT_DIR.

_DEPLOY_CONF="${DEPLOY_VM_SCRIPT_DIR}/deploy.conf"
if [ ! -f "$_DEPLOY_CONF" ] || [ ! -r "$_DEPLOY_CONF" ]; then
    echo "ERROR: Brak pliku deploy.conf w katalogu skryptu (${DEPLOY_VM_SCRIPT_DIR})." >&2
    echo "Utwórz: cp \"${DEPLOY_VM_SCRIPT_DIR}/deploy.conf.example\" \"$_DEPLOY_CONF\"" >&2
    exit 1
fi
# shellcheck source=deploy.conf
. "$_DEPLOY_CONF"
_DEPLOY_LOCAL="${DEPLOY_VM_SCRIPT_DIR}/deploy.local.conf"
if [ -f "$_DEPLOY_LOCAL" ] && [ -r "$_DEPLOY_LOCAL" ]; then
    # shellcheck source=deploy.local.conf
    . "$_DEPLOY_LOCAL"
fi

for _req in STORAGE BRIDGE VLAN IP_FILE IP_PREFIX MASK GW GUEST_USERNAME IMAGE; do
    if [ -z "${!_req}" ]; then
        echo "ERROR: deploy.conf: ustaw niepustą wartość: $_req" >&2
        exit 1
    fi
done

# Dysk i RAM: wartości domyślne w GiB (1024); zgodne z qm resize …G oraz RAM×1024→MiB (--memory).
# Stare nazwy DISK_GB_DEFAULT / RAM_GB_DEFAULT nadal działają jako fallback.
DISK_GIB_DEFAULT="${DISK_GIB_DEFAULT:-${DISK_GB_DEFAULT:-40}}"
RAM_GIB_DEFAULT="${RAM_GIB_DEFAULT:-${RAM_GB_DEFAULT:-2}}"

OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_ENDPOINT="${OVH_ENDPOINT:-https://eu.api.ovh.com}"
OVH_DNS_TTL="${OVH_DNS_TTL:-3600}"
OVH_DNS_WWW_CNAME="${OVH_DNS_WWW_CNAME:-true}"

CI_VENDOR_PROFILE="${CI_VENDOR_PROFILE:-}"
CI_SNIPPETS_STORAGE="${CI_SNIPPETS_STORAGE:-local}"
CI_SNIPPETS_PATH="${CI_SNIPPETS_PATH:-/var/lib/vz/snippets}"
CI_VENDOR_FILENAME_OVERRIDE="${CI_VENDOR_FILENAME_OVERRIDE:-}"

CI_SSH_PUBLIC_KEY_ENABLED="${CI_SSH_PUBLIC_KEY_ENABLED:-true}"

MAIL_SMTP_HOST="${MAIL_SMTP_HOST:-}"
MAIL_SMTP_PORT="${MAIL_SMTP_PORT:-587}"
MAIL_SMTP_USER="${MAIL_SMTP_USER:-}"
MAIL_SMTP_PASSWORD="${MAIL_SMTP_PASSWORD:-}"
MAIL_SMTP_STARTTLS="${MAIL_SMTP_STARTTLS:-true}"
MAIL_SMTP_INSECURE="${MAIL_SMTP_INSECURE:-false}"
MAIL_SMTP_AUTH="${MAIL_SMTP_AUTH:-}"
MAIL_SMTP_DEBUG="${MAIL_SMTP_DEBUG:-false}"
MAIL_FROM="${MAIL_FROM:-}"
MAIL_ADMIN="${MAIL_ADMIN:-}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[deploy-vm]}"

GUEST_PASSWORD_CONFIG="${GUEST_PASSWORD:-}"
VM_CUSTOM_NAME="${VM_CUSTOM_NAME:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"

touch "$IP_FILE"
