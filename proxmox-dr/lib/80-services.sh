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

    log_info "Deploying AWX, MkDocs, Portainer, Vault, and Registry..."
    ssh_to_vm "$ssh_target" "
        cd /opt/homelab-iac/docker-compose 2>/dev/null || {
            echo 'Docker Compose directory not found, skipping stack deployment'
            exit 0
        }
        docker-compose -f control-vm-stack.yml up -d
    "

    log_info "Docker Compose stack deployed"
    print_service_urls
}

print_service_urls() {
    log_info "Access services at:"
    log_info "  - MkDocs: http://${CONTROL_VM_IP}:${SERVICE_MKDOCS_PORT}"
    log_info "  - Portainer: http://${CONTROL_VM_IP}:${SERVICE_PORTAINER_PORT}"
    log_info "  - AWX: http://${CONTROL_VM_IP}:${SERVICE_AWX_PORT}"
    log_info "  - Vault: http://${CONTROL_VM_IP}:${SERVICE_VAULT_PORT}"
    log_info "  - Registry: http://${CONTROL_VM_IP}:${SERVICE_REGISTRY_PORT}"
}
