#!/usr/bin/env bash
#
# Backup Configuration
# Setup Terraform state backups
#

PROXMOX_AUTOMATION_KEY="${PROXMOX_AUTOMATION_KEY:-/root/.ssh/homelab_control}"

ssh_to_vm() {
    ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no "$@"
}

create_backup_directory() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"
}

create_backup_script() {
    local ssh_target="$1"
    local backup_dir="$2"

    ssh_to_vm "$ssh_target" "
        echo '#!/bin/bash' | sudo tee /usr/local/bin/backup-terraform-state.sh
        echo 'rsync -av /opt/homelab-iac/terraform/*.tfstate ${backup_dir}/ || true' | sudo tee -a /usr/local/bin/backup-terraform-state.sh
        sudo chmod +x /usr/local/bin/backup-terraform-state.sh
    "
}

add_backup_cron_job() {
    local ssh_target="$1"

    ssh_to_vm "$ssh_target" "
        (crontab -l 2>/dev/null; echo '0 2 * * * /usr/local/bin/backup-terraform-state.sh') | crontab -
    "
}

backup_terraform_state() {
    log_section "Backing Up Terraform State"

    if [[ "${BACKUP_TERRAFORM_STATE:-true}" != "true" ]]; then
        log_info "Skipping Terraform state backup (BACKUP_TERRAFORM_STATE=false)"
        return 0
    fi

    local backup_dir="${SMB_PRIVATE_MOUNT}/terraform-state-backups"
    local ssh_target="${CONTROL_VM_USER}@${CONTROL_VM_IP}"

    create_backup_directory "$backup_dir"
    log_info "Setting up automated Terraform state backup..."
    create_backup_script "$ssh_target" "$backup_dir"
    add_backup_cron_job "$ssh_target"

    log_info "Terraform state backup configured (daily at 2am)"
}
