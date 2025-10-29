#!/usr/bin/env bash
#
# Proxmox Repository Configuration
# Configure Proxmox repositories and package updates
#

disable_enterprise_repository() {
    if [[ ! -f "$PROXMOX_ENTERPRISE_REPO_FILE" ]]; then
        return 0
    fi

    if grep -q "^#" "$PROXMOX_ENTERPRISE_REPO_FILE"; then
        return 0
    fi

    log_info "Disabling enterprise repository..."
    sed -i 's/^deb/#deb/' "$PROXMOX_ENTERPRISE_REPO_FILE"
}

enable_no_subscription_repository() {
    if grep -q "pve-no-subscription" "$PROXMOX_NO_SUB_REPO_FILE" 2>/dev/null; then
        return 0
    fi

    log_info "Enabling no-subscription repository..."
    echo "$PROXMOX_NO_SUB_REPO" > "$PROXMOX_NO_SUB_REPO_FILE"
}

update_package_lists() {
    log_info "Updating package lists..."
    apt-get update -qq
}

configure_proxmox_repositories() {
    log_section "Configuring Proxmox Repositories"

    disable_enterprise_repository
    enable_no_subscription_repository
    update_package_lists

    log_info "Proxmox repositories configured"
}

upgrade_proxmox_packages() {
    log_section "Upgrading Proxmox Packages"

    log_info "Upgrading packages (this may take several minutes)..."
    apt-get dist-upgrade -y
    log_info "Packages upgraded successfully"
}
