#!/usr/bin/env bash
# ==============================================================================
# Control VM Backup Script
# ==============================================================================
# Purpose: Backup critical Control VM data to UNAS via SMB
# Schedule: Run daily via cron
# Retention: Keep last 7 daily backups
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly BACKUP_ROOT="/mnt/backup/control-vm/backups"
readonly COMPOSE_DIR="/opt/homelab-iac/control-vm/docker-compose"
readonly PROJECT_ROOT="/opt/homelab-iac"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
readonly RETENTION_DAYS=7

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_backup_mount() {
    if ! mountpoint -q /mnt/backup; then
        log_error "Backup mount not available at /mnt/backup"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Backup Functions
# ------------------------------------------------------------------------------

create_backup_dir() {
    log_info "Creating backup directory: ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
}

backup_docker_volumes() {
    log_info "Backing up Docker volumes..."

    local volumes_dir="${BACKUP_DIR}/docker-volumes"
    mkdir -p "${volumes_dir}"

    # Get list of volumes for our services
    local volumes=(
        "portainer-data"
        "vault-data"
        "vault-logs"
        "registry-data"
        "semaphore-postgres-data"
        "semaphore-data"
    )

    for volume in "${volumes[@]}"; do
        local volume_name="docker-compose_${volume}"
        if docker volume inspect "${volume_name}" &> /dev/null; then
            log_info "Backing up volume: ${volume}"
            docker run --rm \
                -v "${volume_name}:/source:ro" \
                -v "${volumes_dir}:/backup" \
                alpine \
                tar czf "/backup/${volume}.tar.gz" -C /source .
        else
            log_warn "Volume not found: ${volume_name}"
        fi
    done

    log_info "Docker volumes backed up"
}

backup_configurations() {
    log_info "Backing up configuration files..."

    local config_dir="${BACKUP_DIR}/configs"
    mkdir -p "${config_dir}"

    # Backup docker-compose files
    if [[ -d "${COMPOSE_DIR}" ]]; then
        cp -r "${COMPOSE_DIR}" "${config_dir}/docker-compose"
        # Remove .env from backup (contains secrets)
        rm -f "${config_dir}/docker-compose/.env"
        log_info "Docker Compose configs backed up (excluding .env)"
    fi

    # Backup Git repository metadata (but not entire repo)
    if [[ -d "${PROJECT_ROOT}/.git" ]]; then
        cd "${PROJECT_ROOT}"
        git remote -v > "${config_dir}/git-remotes.txt"
        git branch -a > "${config_dir}/git-branches.txt"
        git log --oneline -10 > "${config_dir}/git-recent-commits.txt"
        log_info "Git metadata backed up"
    fi
}

backup_terraform_state() {
    log_info "Backing up Terraform state..."

    local terraform_dir="${PROJECT_ROOT}/terraform"
    local backup_state_dir="${BACKUP_DIR}/terraform-state"

    if [[ -d "${terraform_dir}" ]]; then
        mkdir -p "${backup_state_dir}"

        # Backup state files
        find "${terraform_dir}" -name "*.tfstate*" -exec cp {} "${backup_state_dir}/" \;

        # Backup terraform lock file
        if [[ -f "${terraform_dir}/.terraform.lock.hcl" ]]; then
            cp "${terraform_dir}/.terraform.lock.hcl" "${backup_state_dir}/"
        fi

        log_info "Terraform state backed up"
    else
        log_warn "Terraform directory not found"
    fi
}

backup_ansible_inventory() {
    log_info "Backing up Ansible inventory..."

    local ansible_dir="${PROJECT_ROOT}/ansible"
    local backup_ansible_dir="${BACKUP_DIR}/ansible"

    if [[ -d "${ansible_dir}" ]]; then
        mkdir -p "${backup_ansible_dir}"

        # Backup inventory and group vars
        if [[ -d "${ansible_dir}/inventory" ]]; then
            cp -r "${ansible_dir}/inventory" "${backup_ansible_dir}/"
        fi

        # Backup ansible.cfg
        if [[ -f "${ansible_dir}/ansible.cfg" ]]; then
            cp "${ansible_dir}/ansible.cfg" "${backup_ansible_dir}/"
        fi

        log_info "Ansible inventory backed up"
    else
        log_warn "Ansible directory not found"
    fi
}

create_backup_manifest() {
    log_info "Creating backup manifest..."

    local manifest="${BACKUP_DIR}/MANIFEST.txt"

    cat > "${manifest}" <<EOF
Control VM Backup Manifest
==========================

Backup Timestamp: ${TIMESTAMP}
Backup Location: ${BACKUP_DIR}
Hostname: $(hostname)
IP Address: $(hostname -I | awk '{print $1}')

Backup Contents:
----------------
- Docker volumes (compressed archives)
- Configuration files (docker-compose, vault config)
- Terraform state files
- Ansible inventory
- Git metadata (remotes, branches, recent commits)

Restoration Notes:
------------------
1. Restore Docker volumes using docker-volume-restore.sh
2. Place Terraform state in ${PROJECT_ROOT}/terraform/
3. Place Ansible inventory in ${PROJECT_ROOT}/ansible/inventory/
4. Recreate .env file from .env.example with actual secrets

Services Backed Up:
-------------------
- MkDocs Live Server
- Portainer
- HashiCorp Vault
- Docker Registry
- Semaphore (Ansible UI + PostgreSQL)

EOF

    # Add file listing
    echo -e "\nBackup File Structure:" >> "${manifest}"
    tree -L 2 "${BACKUP_DIR}" >> "${manifest}" 2>/dev/null || \
        find "${BACKUP_DIR}" -type f >> "${manifest}"

    log_info "Backup manifest created"
}

cleanup_old_backups() {
    log_info "Cleaning up backups older than ${RETENTION_DAYS} days..."

    find "${BACKUP_ROOT}" -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true

    local backup_count
    backup_count=$(find "${BACKUP_ROOT}" -maxdepth 1 -type d | wc -l)
    backup_count=$((backup_count - 1)) # Subtract the root directory itself

    log_info "Old backups cleaned up. Total backups remaining: ${backup_count}"
}

create_latest_symlink() {
    log_info "Creating 'latest' symlink..."

    local latest_link="${BACKUP_ROOT}/latest"
    rm -f "${latest_link}"
    ln -s "${BACKUP_DIR}" "${latest_link}"

    log_info "Latest backup: ${latest_link} -> ${BACKUP_DIR}"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    log_info "Starting Control VM backup..."
    log_info "Timestamp: ${TIMESTAMP}"

    # Verify backup mount is available
    check_backup_mount

    # Create backup directory structure
    create_backup_dir

    # Execute backup tasks
    backup_docker_volumes
    backup_configurations
    backup_terraform_state
    backup_ansible_inventory

    # Create manifest
    create_backup_manifest

    # Cleanup old backups
    cleanup_old_backups

    # Create latest symlink
    create_latest_symlink

    # Calculate backup size
    local backup_size
    backup_size=$(du -sh "${BACKUP_DIR}" | awk '{print $1}')

    log_info "Backup complete!"
    log_info "Backup size: ${backup_size}"
    log_info "Backup location: ${BACKUP_DIR}"
}

# Run main function
main "$@"
