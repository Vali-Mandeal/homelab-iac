#!/usr/bin/env bash
#
# Docker Services Deployment
# Deploy Docker Compose stack on Control VM
#

PROXMOX_AUTOMATION_KEY="${PROXMOX_AUTOMATION_KEY:-/root/.ssh/homelab_control}"

ssh_to_vm() {
    ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no "$@"
}

deploy_control_vm_stack() {
    log_section "Deploying Control VM Docker Compose Stack"

    if [[ "${DEPLOY_CONTROL_VM_STACK:-true}" != "true" ]]; then
        log_info "Skipping Docker Compose stack deployment (DEPLOY_CONTROL_VM_STACK=false)"
        return 0
    fi

    local ssh_target="${CONTROL_VM_USER}@${CONTROL_VM_IP}"

    # Check if control-vm setup script exists
    log_info "Checking for Control VM setup script..."
    if ! ssh_to_vm "$ssh_target" "test -f /opt/homelab-iac/control-vm/scripts/setup-control-vm.sh"; then
        log_warn "Control VM setup script not found at /opt/homelab-iac/control-vm/scripts/setup-control-vm.sh"
        log_warn "Skipping Control VM services deployment"
        log_info "You can deploy services manually later by running:"
        log_info "  ssh ${ssh_target}"
        log_info "  cd /opt/homelab-iac/control-vm/scripts"
        log_info "  sudo ./setup-control-vm.sh"
        return 0
    fi

    log_info "Waiting for cloud-init to complete system updates..."
    ssh_to_vm "$ssh_target" "sudo cloud-init status --wait" || log_warn "cloud-init wait completed with warnings (this is normal)"

    log_info "Running Control VM setup script (this will take 15-30 minutes)..."
    log_info "Installing Docker, IaC tools, and deploying services..."

    # Run the setup script on Control VM with SMB credentials from config
    # Note: Setup script requires root, so we sudo it with -E to preserve environment
    log_info "Passing SMB credentials for automated backup configuration..."
    if ssh_to_vm "$ssh_target" "cd /opt/homelab-iac/control-vm/scripts && \
        sudo SMB_USERNAME='${SMB_USERNAME}' \
        SMB_PASSWORD='${SMB_PASSWORD}' \
        UNAS_PRIVATE_IP='${UNAS_PRIVATE_IP}' \
        AUTO_CONFIRM=true \
        ./setup-control-vm.sh"; then
        log_info "Control VM services deployed successfully"
        print_service_urls
    else
        log_error "Control VM setup script failed"
        log_warn "You can debug by SSHing to Control VM and checking logs:"
        log_warn "  ssh ${ssh_target}"
        log_warn "  cd /opt/homelab-iac/control-vm/scripts"
        log_warn "  sudo ./setup-control-vm.sh"
        return 1
    fi
}

print_service_urls() {
    log_info "Access services at:"
    log_info "  - MkDocs: http://${CONTROL_VM_IP}:8000"
    log_info "  - Portainer: http://${CONTROL_VM_IP}:9000"
    log_info "  - Semaphore: http://${CONTROL_VM_IP}:3000"
    log_info "  - Vault: http://${CONTROL_VM_IP}:8200"
    log_info "  - Registry: http://${CONTROL_VM_IP}:5000"
}
