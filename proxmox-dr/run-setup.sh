#!/usr/bin/env bash
#
# Proxmox Disaster Recovery Setup Script
#
# This script runs ON the Proxmox host (copied there by deploy.sh)
# and performs the complete DR setup.
#
# Usage: sudo ./run-setup.sh
#

set -euo pipefail

# ==============================================================================
# INITIALIZATION
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/proxmox-config.env"

# ==============================================================================
# LOAD MODULES
# ==============================================================================

# Source all library modules in order
for lib_file in "$SCRIPT_DIR/lib/"*.sh; do
    if [[ -f "$lib_file" ]]; then
        source "$lib_file"
    fi
done

# ==============================================================================
# CONFIGURATION
# ==============================================================================

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Loading configuration..."
    source "$CONFIG_FILE"

    # Set defaults for optional variables
    UBUNTU_TEMPLATE_ID="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"
    CONTROL_VM_ID="${CONTROL_VM_ID:-$DEFAULT_CONTROL_VM_ID}"
    CONTROL_VM_NAME="${CONTROL_VM_NAME:-$DEFAULT_CONTROL_VM_NAME}"
    CONTROL_VM_USER="${CONTROL_VM_USER:-$DEFAULT_CONTROL_VM_USER}"
    CONTROL_VM_CPUS="${CONTROL_VM_CPUS:-$DEFAULT_CONTROL_VM_CPUS}"
    CONTROL_VM_MEMORY="${CONTROL_VM_MEMORY:-$DEFAULT_CONTROL_VM_MEMORY}"
    CONTROL_VM_DISK="${CONTROL_VM_DISK:-$DEFAULT_CONTROL_VM_DISK}"
    CONTROL_VM_STORAGE="${CONTROL_VM_STORAGE:-$DEFAULT_CONTROL_VM_STORAGE}"
    PRIVATE_NETWORK_BRIDGE="${PRIVATE_NETWORK_BRIDGE:-$DEFAULT_PRIVATE_NETWORK_BRIDGE}"
    PUBLIC_NETWORK_BRIDGE="${PUBLIC_NETWORK_BRIDGE:-$DEFAULT_PUBLIC_NETWORK_BRIDGE}"
    TERRAFORM_VERSION="${TERRAFORM_VERSION:-$DEFAULT_TERRAFORM_VERSION}"
    ANSIBLE_VERSION="${ANSIBLE_VERSION:-$DEFAULT_ANSIBLE_VERSION}"
    PACKER_VERSION="${PACKER_VERSION:-$DEFAULT_PACKER_VERSION}"
    DNS_SERVERS="${DNS_SERVERS:-$DEFAULT_DNS_SERVERS}"
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

preflight_checks() {
    log_section "Pre-Flight Checks"

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        log_info "Try: sudo ./run-setup.sh"
        exit 1
    fi

    # Validate Proxmox environment
    if ! validate_proxmox_environment; then
        log_error "Not running on Proxmox VE"
        exit 1
    fi

    # Check required commands
    for cmd in wget ssh rsync; do
        if ! check_command "$cmd"; then
            exit 1
        fi
    done

    log_info "Pre-flight checks passed"
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    # Print banner
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║          Proxmox Disaster Recovery Setup                       ║"
    echo "║          Homelab Infrastructure                                ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    load_config

    preflight_checks

    validate_config

    log_info "Proxmox Host: $PROXMOX_HOSTNAME ($PROXMOX_HOST_IP)"
    log_info "Control VM will be deployed at: $CONTROL_VM_IP"
    echo ""

    configure_proxmox_repositories

    upgrade_proxmox_packages

    setup_ssh_access

    configure_network_bridges

    setup_storage_mounts

    create_ubuntu_template

    deploy_control_vm

    setup_control_vm

    deploy_control_vm_stack

    backup_terraform_state

    print_summary

    log_info "Proxmox DR setup completed successfully!"
}

# ==============================================================================
# SCRIPT ENTRY POINT
# ==============================================================================

trap 'log_error "Script failed at line $LINENO"' ERR

main "$@"
