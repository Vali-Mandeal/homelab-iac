#!/usr/bin/env bash
# ==============================================================================
# Control VM Setup Script
# ==============================================================================
# Purpose: Initialize Control VM with all IaC tools and services
# Target: Ubuntu 24.04 LTS
# Network: Auto-detects IP address (private network)
# Usage: sudo ./setup-control-vm.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="/opt/homelab-iac"
readonly COMPOSE_DIR="${PROJECT_ROOT}/control-vm/docker-compose"
readonly BACKUP_MOUNT="/mnt/backup"
readonly UNAS_PRIVATE_IP="${UNAS_PRIVATE_IP:-10.100.100.100}"
readonly UNAS_SHARE="private_servers_data"
readonly SMB_USERNAME="${SMB_USERNAME:-proxmox.server}"
readonly SMB_PASSWORD="${SMB_PASSWORD:-}"
readonly CONTROL_VM_USER="${CONTROL_VM_USER:-admin}"

# Auto-detect Control VM IP (fallback to localhost if not found)
CONTROL_VM_IP="${CONTROL_VM_IP:-$(hostname -I | awk '{print $1}')}"
CONTROL_VM_IP="${CONTROL_VM_IP:-localhost}"
readonly CONTROL_VM_IP

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

prompt_continue() {
    local message="$1"
    # Skip prompt if running non-interactively or AUTO_CONFIRM is set
    if [[ "${AUTO_CONFIRM:-false}" == "true" ]] || [[ ! -t 0 ]]; then
        log_info "${message} (auto-confirmed)"
        return 0
    fi
    read -rp "${message} (y/n): " choice
    case "$choice" in
        y|Y ) return 0 ;;
        * ) log_info "Aborted by user"; exit 0 ;;
    esac
}

# ------------------------------------------------------------------------------
# System Update & Base Packages
# ------------------------------------------------------------------------------

update_system() {
    log_info "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        wget \
        git \
        vim \
        htop \
        net-tools \
        unzip \
        jq \
        python3-pip \
        cifs-utils \
        nfs-common \
        apache2-utils
    log_info "System packages updated"
}

# ------------------------------------------------------------------------------
# SMB Backup Mount Configuration
# ------------------------------------------------------------------------------

setup_backup_mount() {
    log_info "Setting up SMB backup mount..."

    # Create mount point
    mkdir -p "${BACKUP_MOUNT}"

    # Create credentials file (secure permissions)
    local creds_file="/root/.smb-credentials"

    # Auto-configure if SMB_PASSWORD is provided (from Proxmox DR or environment)
    if [[ -n "${SMB_PASSWORD}" ]]; then
        log_info "Auto-configuring SMB credentials from environment..."
        cat > "${creds_file}" <<EOF
username=${SMB_USERNAME}
password=${SMB_PASSWORD}
EOF
        chmod 600 "${creds_file}"
        log_info "SMB credentials configured automatically"
    elif [[ ! -f "${creds_file}" ]]; then
        # Fallback for manual setup - create template
        log_warn "SMB credentials file not found and SMB_PASSWORD not provided"
        log_warn "Creating template credentials file..."
        cat > "${creds_file}" <<EOF
username=${SMB_USERNAME}
password=CHANGEME
EOF
        chmod 600 "${creds_file}"
        log_error "Please edit ${creds_file} with the correct password"
        log_error "Or re-run with: SMB_PASSWORD=yourpassword sudo -E ./setup-control-vm.sh"
        prompt_continue "Have you updated the credentials file?"
    else
        log_info "SMB credentials file already exists: ${creds_file}"
    fi

    # Add to /etc/fstab if not already present
    # Note: Using vers=3.0 for SMB3, removed iocharset=utf8 (not available in Ubuntu 24.04)
    local fstab_entry="//${UNAS_PRIVATE_IP}/${UNAS_SHARE} ${BACKUP_MOUNT} cifs credentials=${creds_file},uid=0,gid=0,file_mode=0640,dir_mode=0750,vers=3.0,nofail 0 0"

    if ! grep -q "${BACKUP_MOUNT}" /etc/fstab; then
        log_info "Adding SMB mount to /etc/fstab..."
        echo "${fstab_entry}" >> /etc/fstab
    else
        log_info "SMB mount already in /etc/fstab"
    fi

    # Mount the share
    log_info "Mounting SMB share..."
    mount -a || log_warn "Mount failed - check credentials and network connectivity"

    # Verify mount
    if mountpoint -q "${BACKUP_MOUNT}"; then
        log_info "SMB backup mount successful: ${BACKUP_MOUNT}"
        df -h "${BACKUP_MOUNT}"
    else
        log_error "SMB mount failed - will continue but backups won't work"
    fi
}

# ------------------------------------------------------------------------------
# Docker Installation
# ------------------------------------------------------------------------------

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return 0
    fi

    log_info "Installing Docker..."

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Add CONTROL_VM_USER and current sudo user to docker group
    if [[ -n "${CONTROL_VM_USER:-}" ]]; then
        usermod -aG docker "${CONTROL_VM_USER}" || true
        log_info "Added ${CONTROL_VM_USER} to docker group"
    fi

    # Also add the user who ran sudo (if different)
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "${CONTROL_VM_USER:-}" ]]; then
        usermod -aG docker "${SUDO_USER}" || true
        log_info "Added ${SUDO_USER} to docker group"
    fi

    # Verify installation
    docker --version
    log_info "Docker installed successfully"
    log_warn "Users added to docker group - they need to log out and back in for group changes to take effect"
}

# ------------------------------------------------------------------------------
# IaC Tools Installation
# ------------------------------------------------------------------------------

install_terraform() {
    if command -v terraform &> /dev/null; then
        log_info "Terraform already installed: $(terraform version | head -n1)"
        return 0
    fi

    log_info "Installing Terraform..."

    # Add HashiCorp GPG key
    wget -O- https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    # Add HashiCorp repository
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/hashicorp.list

    # Install Terraform
    apt-get update
    apt-get install -y terraform

    # Verify installation
    terraform version
    log_info "Terraform installed successfully"
}

install_ansible() {
    if command -v ansible &> /dev/null; then
        log_info "Ansible already installed: $(ansible --version | head -n1)"
        return 0
    fi

    log_info "Installing Ansible..."

    # Add Ansible PPA
    add-apt-repository -y ppa:ansible/ansible
    apt-get update

    # Install Ansible
    apt-get install -y ansible

    # Verify installation
    ansible --version
    log_info "Ansible installed successfully"
}

install_packer() {
    if command -v packer &> /dev/null; then
        log_info "Packer already installed: $(packer version)"
        return 0
    fi

    log_info "Installing Packer..."

    # Packer is in the same HashiCorp repository as Terraform
    apt-get install -y packer

    # Verify installation
    packer version
    log_info "Packer installed successfully"
}

# ------------------------------------------------------------------------------
# Project Repository Setup
# ------------------------------------------------------------------------------

setup_project_repo() {
    log_info "Setting up project repository..."

    # Create project directory if it doesn't exist
    if [[ ! -d "${PROJECT_ROOT}" ]]; then
        mkdir -p "${PROJECT_ROOT}"
        log_info "Created ${PROJECT_ROOT}"
    fi

    # If this script is being run from the repo, we're already set up
    if [[ -d "${PROJECT_ROOT}/.git" ]]; then
        log_info "Git repository already present in ${PROJECT_ROOT}"
        cd "${PROJECT_ROOT}"
        git status
        return 0
    fi

    log_warn "No git repository found in ${PROJECT_ROOT}"
    log_info "Please clone your homelab-iac repository to ${PROJECT_ROOT}"
    log_info "Example: git clone <your-repo-url> ${PROJECT_ROOT}"
}

# ------------------------------------------------------------------------------
# Docker Compose Stack Setup
# ------------------------------------------------------------------------------

setup_docker_compose() {
    log_info "Setting up Docker Compose stack..."

    cd "${COMPOSE_DIR}" || {
        log_error "Compose directory not found: ${COMPOSE_DIR}"
        return 1
    }

    # Check for .env file
    if [[ ! -f ".env" ]]; then
        log_error "No .env file found. Please create one from .env.example:"
        log_error "  cp .env.example .env"
        log_error "  # Edit .env and replace CHANGEME values with your credentials"
        log_error "  # Generate random secrets: openssl rand -hex 32"
        return 1
    fi

    # Create registry auth directory and htpasswd file
    log_info "Setting up Docker Registry authentication..."
    mkdir -p configs/registry-auth

    if [[ ! -f "configs/registry-auth/htpasswd" ]]; then
        log_info "Creating registry htpasswd file..."
        local registry_user="admin"
        local registry_password=$(openssl rand -base64 16)

        # Use htpasswd non-interactively with -Bbn (bcrypt, batch mode, stdout)
        htpasswd -Bbn "${registry_user}" "${registry_password}" > configs/registry-auth/htpasswd

        # Save credentials to backup location
        if [[ -d "${BACKUP_MOUNT}" ]]; then
            mkdir -p "${BACKUP_MOUNT}/control-vm/credentials"
            local timestamp=$(date +%Y%m%d_%H%M%S)
            cat > "${BACKUP_MOUNT}/control-vm/credentials/docker-registry-${timestamp}.txt" <<EOF
Docker Registry Credentials
Generated: $(date)
Username: ${registry_user}
Password: ${registry_password}
EOF
            chmod 600 "${BACKUP_MOUNT}/control-vm/credentials/docker-registry-${timestamp}.txt"
            log_info "Registry credentials saved to ${BACKUP_MOUNT}/control-vm/credentials/"
        fi

        log_info "Registry authentication configured for user: ${registry_user}"
        log_info "Registry password: ${registry_password}"
    fi

    # Pull images
    log_info "Pulling Docker images (this may take a while)..."
    docker compose pull

    # Start services
    log_info "Starting services..."
    docker compose up -d

    # Fix Vault data directory permissions (Vault needs write access)
    log_info "Fixing Vault volume permissions..."
    docker compose stop vault
    docker run --rm -v docker-compose_vault-data:/vault/data alpine sh -c "chown -R 100:1000 /vault/data && chmod -R 755 /vault/data"
    docker compose start vault

    # Wait for services to be healthy
    log_info "Waiting for services to become healthy..."
    sleep 10

    # Semaphore creates admin user automatically from environment variables
    log_info "Semaphore admin user will be created automatically from .env credentials"

    # Show status
    docker compose ps

    log_info "Docker Compose stack deployed"
}

# ------------------------------------------------------------------------------
# Vault Initialization
# ------------------------------------------------------------------------------

initialize_vault() {
    log_info "Checking Vault status..."

    # Wait for Vault to be available
    local max_attempts=30
    local attempt=0

    while ! curl -sf http://localhost:8200/v2/sys/health > /dev/null; do
        ((attempt++))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "Vault did not become available in time"
            return 1
        fi
        log_info "Waiting for Vault to start... (attempt $attempt/$max_attempts)"
        sleep 2
    done

    # Check if Vault is already initialized
    local init_status
    init_status=$(curl -sf http://localhost:8200/v1/sys/init | jq -r '.initialized')

    if [[ "$init_status" == "true" ]]; then
        log_info "Vault is already initialized"
        log_warn "Root token and unseal keys should be in ${BACKUP_MOUNT}/control-vm/vault/"
        return 0
    fi

    log_info "Initializing Vault..."

    # Initialize Vault with 5 key shares, 3 required to unseal
    local vault_init
    vault_init=$(curl -sf --request POST \
        --data '{"secret_shares": 5, "secret_threshold": 3}' \
        http://localhost:8200/v1/sys/init)

    # Save initialization output to backup
    local vault_backup_dir="${BACKUP_MOUNT}/control-vm/vault"
    mkdir -p "${vault_backup_dir}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local init_file="${vault_backup_dir}/vault-init-${timestamp}.json"

    echo "${vault_init}" | jq '.' > "${init_file}"
    chmod 600 "${init_file}"

    log_info "Vault initialization complete"
    log_info "Root token and unseal keys saved to: ${init_file}"
    log_warn "CRITICAL: Backup this file securely - you cannot recover these keys!"

    # Extract root token for unsealing
    local root_token
    root_token=$(echo "${vault_init}" | jq -r '.root_token')

    # Unseal Vault (need 3 of 5 keys)
    log_info "Unsealing Vault..."
    for i in {0..2}; do
        local unseal_key
        unseal_key=$(echo "${vault_init}" | jq -r ".keys_base64[$i]")
        curl -s --request POST \
            --data "{\"key\": \"${unseal_key}\"}" \
            http://localhost:8200/v1/sys/unseal > /dev/null || {
            log_error "Failed to unseal with key $((i+1))"
            return 1
        }
        log_info "Unsealed with key $((i+1))/3"
    done

    log_info "Vault unsealed and ready to use"
    log_info "Access Vault UI at: http://${CONTROL_VM_IP}:8200"
    log_info "Root token: ${root_token}"
}

# ------------------------------------------------------------------------------
# Service URLs Display
# ------------------------------------------------------------------------------

show_service_urls() {
    cat <<EOF

${GREEN}============================================================================
Control VM Services Ready
============================================================================${NC}

Access the following services at:

${GREEN}Documentation:${NC}
  MkDocs Live Server:     http://${CONTROL_VM_IP}:8000

${GREEN}Infrastructure Management:${NC}
  Portainer:              http://${CONTROL_VM_IP}:9000
  Semaphore (Ansible UI): http://${CONTROL_VM_IP}:3000
  HashiCorp Vault:        http://${CONTROL_VM_IP}:8200

${GREEN}Development:${NC}
  Docker Registry:        http://${CONTROL_VM_IP}:5000

${GREEN}Backups:${NC}
  SMB Mount Point:        ${BACKUP_MOUNT}
  Vault Keys Location:    ${BACKUP_MOUNT}/control-vm/vault/

${GREEN}First-Time Setup Required:${NC}
  1. Portainer: Create admin account on first login
  2. Semaphore: Password auto-configured from .env file
  3. Vault: Use root token from ${BACKUP_MOUNT}/control-vm/vault/vault-init-*.json

${GREEN}============================================================================${NC}

EOF
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    log_info "Starting Control VM setup..."

    check_root

    log_info "This script will:"
    log_info "  1. Update system packages"
    log_info "  2. Install Docker"
    log_info "  3. Install IaC tools (Terraform, Ansible, Packer)"
    log_info "  4. Setup SMB backup mount to UNAS"
    log_info "  5. Restore from backup (if available)"
    log_info "  6. Deploy Docker Compose services stack"
    log_info "  7. Initialize HashiCorp Vault (if not restored)"

    prompt_continue "Do you want to continue?"

    # Execute setup steps
    update_system
    setup_backup_mount
    install_docker
    install_terraform
    install_ansible
    install_packer
    setup_project_repo

    # Restore from backup before deploying services
    if [[ -f "${SCRIPT_DIR}/restore-control-vm.sh" ]]; then
        log_info "Running restore script..."
        bash "${SCRIPT_DIR}/restore-control-vm.sh" || log_warn "Restore script failed or no backup found"
    fi

    setup_docker_compose
    initialize_vault

    show_service_urls

    log_info "Control VM setup complete!"
}

# Run main function
main "$@"
