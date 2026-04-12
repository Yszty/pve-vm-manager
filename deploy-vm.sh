#!/bin/bash
#
# deploy-vm — Proxmox qm + cloud-init vendor + opcjonalnie OVH DNS i e-mail.
# Konfiguacja: deploy.conf (+ opcjonalnie deploy.local.conf).
# Moduły: lib/*.sh
#
export DEPLOY_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck source=lib/bool.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/bool.sh"
# shellcheck source=lib/load_config.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/load_config.sh"
# shellcheck source=lib/ovh.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/ovh.sh"
# shellcheck source=lib/mail.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/mail.sh"
# shellcheck source=lib/cloudinit.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/cloudinit.sh"
# shellcheck source=lib/guest_auth.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/guest_auth.sh"
# shellcheck source=lib/cli.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/cli.sh"
# shellcheck source=lib/deploy.sh
. "$DEPLOY_VM_SCRIPT_DIR/lib/deploy.sh"

deploy_run "$@"
