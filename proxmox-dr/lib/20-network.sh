#!/usr/bin/env bash
#
# Network Configuration Functions
# Configure network bridges and VLANs
#

configure_network_bridges() {
    log_section "Configuring Network Bridges"

    # Check if bridges already exist
    if grep -q "$PRIVATE_NETWORK_BRIDGE" /etc/network/interfaces 2>/dev/null; then
        log_info "Private network bridge $PRIVATE_NETWORK_BRIDGE already configured"
    else
        log_info "Private network bridge $PRIVATE_NETWORK_BRIDGE needs manual configuration"
        log_warn "Please configure $PRIVATE_NETWORK_BRIDGE in Proxmox GUI: Datacenter > Node > System > Network"
    fi

    if grep -q "$PUBLIC_NETWORK_BRIDGE" /etc/network/interfaces 2>/dev/null; then
        log_info "Public network bridge $PUBLIC_NETWORK_BRIDGE already configured"
    else
        log_info "Public network bridge $PUBLIC_NETWORK_BRIDGE needs manual configuration"
        log_warn "Please configure $PUBLIC_NETWORK_BRIDGE with VLAN tag $PUBLIC_VLAN_TAG in Proxmox GUI"
    fi

    log_info "Network bridge configuration complete"
}
