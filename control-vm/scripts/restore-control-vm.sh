#!/usr/bin/env bash
# ==============================================================================
# Control VM Restore Script
# ==============================================================================
# Purpose: Restore Control VM data from most recent backup on UNAS
# Usage: Run during deployment (safe to run on fresh install or existing system)
# Behavior: If no backup exists, creates directory structure and exits gracefully
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly BACKUP_ROOT="/mnt/backup/control-vm/backups"
readonly COMPOSE_DIR="/opt/homelab-iac/control-vm/docker-compose"
readonly PROJECT_ROOT="/opt/homelab-iac"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    echo -e "${GREEN}[RESTORE]${NC} [$(get_timestamp)] $1"
}

log_warn() {
    echo -e "${YELLOW}[RESTORE]${NC} [$(get_timestamp)] $1"
}

log_error() {
    echo -e "${RED}[RESTORE]${NC} [$(get_timestamp)] $1"
}

log_blue() {
    echo -e "${BLUE}[RESTORE]${NC} [$(get_timestamp)] $1"
}

check_backup_mount() {
    if ! mountpoint -q /mnt/backup; then
        log_warn "Backup mount not available at /mnt/backup"
        log_warn "This is normal for a fresh deployment without SMB configured"
        return 1
    fi
    return 0
}

find_latest_backup() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        return 1
    fi

    # Find most recent backup directory (format: YYYYMMDD_HHMMSS)
    local latest=$(find "${BACKUP_ROOT}" -maxdepth 1 -type d -name "????????_??????" | sort -r | head -1)

    if [[ -z "${latest}" ]]; then
        return 1
    fi

    echo "${latest}"
    return 0
}

# ------------------------------------------------------------------------------
# Restore Functions
# ------------------------------------------------------------------------------

restore_docker_volumes() {
    local backup_dir="$1"
    local volumes_dir="${backup_dir}/docker-volumes"

    if [[ ! -d "${volumes_dir}" ]]; then
        log_warn "No Docker volumes found in backup"
        return 1
    fi

    log_info "Restoring Docker volumes..."

    # Stop containers before restore
    log_info "Stopping containers for clean restore..."
    cd "${COMPOSE_DIR}"
    docker compose stop 2>/dev/null || log_warn "No containers running"
    sleep 3

    local total_success=0
    local total_failed=0

    # Restore each volume backup
    for archive in "${volumes_dir}"/*.tar.gz; do
        if [[ ! -f "${archive}" ]]; then
            continue
        fi

        local volume_name=$(basename "${archive}" .tar.gz)
        local full_volume_name="docker-compose_${volume_name}"

        log_blue "Restoring volume: ${volume_name}"

        # Check if volume exists, create if not
        if ! docker volume inspect "${full_volume_name}" &>/dev/null; then
            log_blue "Creating volume: ${full_volume_name}"
            docker volume create "${full_volume_name}"
        fi

        # Restore volume data using temporary container
        if docker run --rm \
            -v "${full_volume_name}:/restore" \
            -v "${volumes_dir}:/backup" \
            alpine \
            sh -c "cd /restore && tar xzf /backup/${volume_name}.tar.gz" 2>/dev/null; then
            log_info "✓ Restored ${volume_name}"
            ((total_success++))
        else
            log_error "✗ Failed to restore ${volume_name}"
            ((total_failed++))
        fi
    done

    log_info "Volume restore complete: ${total_success} succeeded, ${total_failed} failed"

    # Restart containers
    log_info "Starting containers..."
    cd "${COMPOSE_DIR}"
    docker compose start 2>/dev/null || log_warn "Failed to start containers"

    return 0
}

restore_configurations() {
    local backup_dir="$1"
    local config_dir="${backup_dir}/configs"

    if [[ ! -d "${config_dir}" ]]; then
        log_warn "No configurations found in backup"
        return 0
    fi

    log_info "Restoring configuration files..."

    # Restore docker-compose configs (excluding .env which has secrets)
    if [[ -d "${config_dir}/docker-compose" ]]; then
        log_blue "Restoring Docker Compose configurations..."
        cp -r "${config_dir}/docker-compose"/* "${COMPOSE_DIR}/" 2>/dev/null || true
        log_info "✓ Docker Compose configs restored"
    fi

    return 0
}

restore_terraform_state() {
    local backup_dir="$1"
    local terraform_state_dir="${backup_dir}/terraform-state"
    local terraform_dir="${PROJECT_ROOT}/terraform"

    if [[ ! -d "${terraform_state_dir}" ]]; then
        log_warn "No Terraform state found in backup"
        return 0
    fi

    log_info "Restoring Terraform state..."
    mkdir -p "${terraform_dir}"

    cp "${terraform_state_dir}"/*.tfstate* "${terraform_dir}/" 2>/dev/null || true
    cp "${terraform_state_dir}"/.terraform.lock.hcl "${terraform_dir}/" 2>/dev/null || true

    log_info "✓ Terraform state restored"
    return 0
}

restore_ansible_inventory() {
    local backup_dir="$1"
    local ansible_backup_dir="${backup_dir}/ansible"
    local ansible_dir="${PROJECT_ROOT}/ansible"

    if [[ ! -d "${ansible_backup_dir}" ]]; then
        log_warn "No Ansible inventory found in backup"
        return 0
    fi

    log_info "Restoring Ansible inventory..."
    mkdir -p "${ansible_dir}"

    if [[ -d "${ansible_backup_dir}/inventory" ]]; then
        cp -r "${ansible_backup_dir}/inventory" "${ansible_dir}/" 2>/dev/null || true
    fi

    if [[ -f "${ansible_backup_dir}/ansible.cfg" ]]; then
        cp "${ansible_backup_dir}/ansible.cfg" "${ansible_dir}/" 2>/dev/null || true
    fi

    log_info "✓ Ansible inventory restored"
    return 0
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    log_info "=========================================="
    log_info "Control VM Restore Process"
    log_info "=========================================="

    # Check if backup mount is available
    if ! check_backup_mount; then
        log_info "No backup mount - creating directory structure for future backups"
        sudo mkdir -p "${BACKUP_ROOT}" 2>/dev/null || true
        log_info "Fresh deployment - nothing to restore"
        exit 0
    fi

    # Find latest backup
    local latest_backup
    if ! latest_backup=$(find_latest_backup); then
        log_info "No existing backups found in ${BACKUP_ROOT}"
        log_info "Fresh deployment - nothing to restore"
        exit 0
    fi

    log_info "Found backup: $(basename "${latest_backup}")"

    # Check if backup has MANIFEST
    if [[ -f "${latest_backup}/MANIFEST.txt" ]]; then
        log_blue "Backup manifest:"
        head -15 "${latest_backup}/MANIFEST.txt" | tail -10
    fi

    # Perform restoration
    restore_docker_volumes "${latest_backup}"
    restore_configurations "${latest_backup}"
    restore_terraform_state "${latest_backup}"
    restore_ansible_inventory "${latest_backup}"

    log_info "=========================================="
    log_info "Restore Complete!"
    log_info "Restored from: $(basename "${latest_backup}")"
    log_info "=========================================="
    log_warn "IMPORTANT: If you restored Vault data, you need the unseal keys"
    log_warn "Check your secure offline storage for Vault unseal keys"
}

main "$@"
