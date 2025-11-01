#!/usr/bin/env bash
#
# Proxmox DR Deployment Orchestrator
#
# This script runs on your Mac/workstation and handles:
# - Reading configuration
# - Testing SSH connectivity
# - Copying DR scripts to Proxmox
# - Executing remote setup
# - Cleaning up
#
# Usage: ./deploy.sh
#

set -euo pipefail

# ==============================================================================
# CONSTANTS
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/config/proxmox-config.env"
readonly REMOTE_DIR_PREFIX="/tmp/proxmox-dr"
readonly LIB_LOCAL_DIR="${SCRIPT_DIR}/lib-local"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ==============================================================================
# LOGGING
# ==============================================================================

log_info() {
    echo -e "${GREEN}[DEPLOY]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[DEPLOY]${NC} $1"
}

log_error() {
    echo -e "${RED}[DEPLOY]${NC} $1"
}

log_section() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
    echo ""
}

# ==============================================================================
# ERROR HANDLING
# ==============================================================================

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Deployment failed with exit code: $exit_code"
        if [[ -n "${REMOTE_DIR:-}" ]] && [[ -n "${SSH_TARGET:-}" ]]; then
            log_info "Cleaning up remote directory: $REMOTE_DIR"
            local ssh_key_opt
            ssh_key_opt=$(get_ssh_key_option)
            ssh $ssh_key_opt -o ConnectTimeout=5 "$SSH_TARGET" "rm -rf '$REMOTE_DIR'" 2>/dev/null || true
        fi
    fi
}

trap cleanup_on_error EXIT

# ==============================================================================
# LIBRARY LOADING
# ==============================================================================

load_local_libraries() {
    if [[ ! -d "$LIB_LOCAL_DIR" ]]; then
        return 0
    fi

    for lib_file in "$LIB_LOCAL_DIR"/*.sh; do
        if [[ -f "$lib_file" ]]; then
            # shellcheck disable=SC1090
            source "$lib_file"
        fi
    done
}

# ==============================================================================
# CONFIGURATION
# ==============================================================================

load_configuration() {
    log_section "Loading Configuration"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Create it by copying the example:"
        log_info "  cp ${SCRIPT_DIR}/config/proxmox-config.env.example ${SCRIPT_DIR}/config/proxmox-config.env"
        log_info "  nano ${SCRIPT_DIR}/config/proxmox-config.env"
        exit 1
    fi

    log_info "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"

    # Required variables for deployment
    local required_vars=(
        "PROXMOX_HOST"
        "SSH_USER"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi

    # Set defaults
    SSH_PORT="${SSH_PORT:-22}"

    SSH_TARGET="${SSH_USER}@${PROXMOX_HOST}"

    log_info "Proxmox Host: ${PROXMOX_HOST}"
    log_info "SSH User: ${SSH_USER}"
    log_info "SSH Port: ${SSH_PORT}"
}

# ==============================================================================
# SSH CONNECTIVITY
# ==============================================================================

get_ssh_key_option() {
    if [[ -f "$HOME/.ssh/homelab_admin" ]]; then
        echo "-i $HOME/.ssh/homelab_admin"
    fi
}

test_ssh_connection() {
    log_section "Testing SSH Connection"

    log_info "Testing connection to ${SSH_TARGET}:${SSH_PORT}..."

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    if ! ssh $ssh_key_opt -o ConnectTimeout=10 -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_TARGET" "echo 'SSH connection successful'" &>/dev/null; then
        log_error "Failed to connect to Proxmox host"
        log_error "Please check:"
        log_error "  1. Proxmox host is reachable: ping ${PROXMOX_HOST}"
        log_error "  2. SSH is enabled on Proxmox"
        log_error "  3. SSH keys are configured (or password auth is enabled)"
        log_error "  4. Firewall allows SSH on port ${SSH_PORT}"
        exit 1
    fi

    log_info "SSH connection successful"
}

# ==============================================================================
# FILE TRANSFER
# ==============================================================================

copy_files_to_proxmox() {
    log_section "Copying Files to Proxmox"

    # Create remote directory with timestamp
    REMOTE_DIR="${REMOTE_DIR_PREFIX}-$(date +%s)"

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    log_info "Creating remote directory: $REMOTE_DIR"
    ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "mkdir -p '$REMOTE_DIR'"

    log_info "Copying DR scripts to Proxmox..."

    # Build rsync SSH command with key if available
    local rsync_ssh_cmd="ssh -p ${SSH_PORT}"
    if [[ -n "$ssh_key_opt" ]]; then
        rsync_ssh_cmd="ssh $ssh_key_opt -p ${SSH_PORT}"
    fi

    # Copy entire proxmox-dr directory to remote
    # Exclude .git and other unnecessary files
    rsync -az --progress \
        --exclude='.git' \
        --exclude='.DS_Store' \
        --exclude='*.md' \
        --exclude='config/proxmox-config.env' \
        -e "$rsync_ssh_cmd" \
        "$SCRIPT_DIR/" \
        "${SSH_TARGET}:${REMOTE_DIR}/"

    # Copy config file separately (to ensure it's there)
    log_info "Copying configuration file..."
    scp $ssh_key_opt -P "$SSH_PORT" "$CONFIG_FILE" "${SSH_TARGET}:${REMOTE_DIR}/config/proxmox-config.env"

    # Copy .env file for Control VM if it exists
    local control_vm_env="${SCRIPT_DIR}/../control-vm/docker-compose/.env"
    if [[ -f "$control_vm_env" ]]; then
        log_info "Copying Control VM .env file..."
        ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "mkdir -p '${REMOTE_DIR}/control-vm-config'"
        scp $ssh_key_opt -P "$SSH_PORT" "$control_vm_env" "${SSH_TARGET}:${REMOTE_DIR}/control-vm-config/.env"
    else
        log_warn "Control VM .env file not found at $control_vm_env"
    fi

    log_info "Files copied successfully"
}

# ==============================================================================
# REMOTE EXECUTION
# ==============================================================================

execute_remote_setup() {
    log_section "Executing Remote Setup"

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    log_info "Making scripts executable..."
    ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "chmod +x '${REMOTE_DIR}/run-setup.sh' '${REMOTE_DIR}/lib/'*.sh"

    # Read SSH public key content to pass to remote script
    local ssh_pub_key_content=""
    if [[ -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
        ssh_pub_key_content=$(cat "${SSH_PUBLIC_KEY_PATH}")
    fi

    log_info "Starting Proxmox DR setup on remote host..."
    log_info "This will take 15-30 minutes. Output will stream below."
    echo ""

    # Execute remote script and stream output
    # Use -t to allocate pseudo-TTY for colored output
    # Export SSH key content as environment variable for remote script
    if ssh $ssh_key_opt -t -p "$SSH_PORT" "$SSH_TARGET" "export SSH_PUBLIC_KEY_CONTENT='${ssh_pub_key_content}' && cd '${REMOTE_DIR}' && ./run-setup.sh"; then
        log_info "Remote setup completed successfully"
        return 0
    else
        log_error "Remote setup failed"
        log_warn "Remote files are preserved at: ${REMOTE_DIR}"
        log_warn "To debug: ssh $ssh_key_opt -p ${SSH_PORT} ${SSH_TARGET} 'cd ${REMOTE_DIR} && ./run-setup.sh'"
        return 1
    fi
}

# ==============================================================================
# CLEANUP
# ==============================================================================

cleanup_remote_files() {
    log_section "Cleaning Up"

    local ssh_key_opt
    ssh_key_opt=$(get_ssh_key_option)

    if [[ -n "${REMOTE_DIR:-}" ]]; then
        log_info "Removing remote directory: $REMOTE_DIR"
        ssh $ssh_key_opt -p "$SSH_PORT" "$SSH_TARGET" "rm -rf '$REMOTE_DIR'" || true
        log_info "Cleanup complete"
    fi
}

# ==============================================================================
# SUMMARY
# ==============================================================================

print_summary() {
    log_section "Deployment Complete!"

    echo "Proxmox host: ${PROXMOX_HOST}"
    echo "Control VM: ${CONTROL_VM_IP:-check config}"
    echo ""
    echo "Next steps:"
    echo "  1. SSH to Control VM: ssh ${CONTROL_VM_USER:-admin}@${CONTROL_VM_IP:-<ip>}"
    echo "  2. Navigate to IaC repo: cd /opt/homelab-iac"
    echo "  3. Start using Terraform/Ansible to deploy services"
    echo ""
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    log_section "Proxmox DR Deployment Orchestrator"

    load_configuration
    load_local_libraries
    setup_ssh_keys
    test_ssh_connection
    copy_files_to_proxmox

    if execute_remote_setup; then
        cleanup_remote_files
        print_summary
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
