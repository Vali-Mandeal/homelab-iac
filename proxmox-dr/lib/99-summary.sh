#!/usr/bin/env bash
#
# Summary & Completion
# Print deployment summary
#

print_summary() {
    log_section "Deployment Complete!"

    echo "Proxmox Host: $PROXMOX_HOST_IP"
    echo "Control VM: $CONTROL_VM_IP"
    echo ""
    echo "Next steps:"
    echo "  1. SSH to Control VM: ssh ${CONTROL_VM_USER}@${CONTROL_VM_IP}"
    echo "  2. Navigate to IaC repo: cd /opt/homelab-iac"
    echo "  3. Review documentation: http://${CONTROL_VM_IP}:${SERVICE_MKDOCS_PORT}"
    echo "  4. Start using Terraform/Ansible to deploy services"
    echo ""
    echo "Web Services (on Control VM):"
    echo "  - MkDocs Documentation: http://${CONTROL_VM_IP}:${SERVICE_MKDOCS_PORT}"
    echo "  - Portainer: http://${CONTROL_VM_IP}:${SERVICE_PORTAINER_PORT}"
    echo "  - AWX (Ansible UI): http://${CONTROL_VM_IP}:${SERVICE_AWX_PORT}"
    echo "  - Vault: http://${CONTROL_VM_IP}:${SERVICE_VAULT_PORT}"
    echo "  - Docker Registry: http://${CONTROL_VM_IP}:${SERVICE_REGISTRY_PORT}"
    echo ""
    echo "NFS Mounts (on Proxmox host):"
    echo "  - Private: ${PRIVATE_MOUNT_POINT}"
    echo "  - Public: ${PUBLIC_MOUNT_POINT}"
    echo ""
}
