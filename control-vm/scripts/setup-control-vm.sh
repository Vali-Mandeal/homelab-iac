#!/usr/bin/env bash
# ==============================================================================
# Control VM Setup Script
# ==============================================================================
# Purpose: Initialize Control VM with all IaC tools and services
# Target: Ubuntu 24.04 LTS
# Network: ${CONTROL_VM_IP} (private network)
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
readonly UNAS_PRIVATE_IP="${UNAS_PRIVATE_IP}"
readonly UNAS_SHARE="private_servers_data"
readonly SMB_USERNAME="YOUR_SMB_USERNAME"

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
    if [[ ! -f "${creds_file}" ]]; then
        log_warn "SMB credentials file not found. Creating template..."
        cat > "${creds_file}" <<EOF
username=${SMB_USERNAME}
password=CHANGEME
EOF
        chmod 600 "${creds_file}"
        log_error "Please edit ${creds_file} with the correct password"
        log_error "Password is: CHANGEME_SMB_PASSWORD"
        prompt_continue "Have you updated the credentials file?"
    fi

    # Add to /etc/fstab if not already present
    local fstab_entry="//${UNAS_PRIVATE_IP}/${UNAS_SHARE} ${BACKUP_MOUNT} cifs credentials=${creds_file},uid=0,gid=0,file_mode=0640,dir_mode=0750,iocharset=utf8 0 0"

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

    # Verify installation
    docker --version
    log_info "Docker installed successfully"
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
        log_warn ".env file not found"

        if [[ -f ".env.example" ]]; then
            cp .env.example .env
            log_info "Created .env from .env.example"
            log_error "Please edit .env file with secure passwords before continuing"
            log_info "Run: vim ${COMPOSE_DIR}/.env"
            prompt_continue "Have you configured the .env file?"
        else
            log_error "No .env.example file found"
            return 1
        fi
    fi

    # Create registry auth directory and htpasswd file
    log_info "Setting up Docker Registry authentication..."
    mkdir -p configs/registry-auth

    if [[ ! -f "configs/registry-auth/htpasswd" ]]; then
        log_info "Creating registry htpasswd file..."
        read -rp "Enter username for Docker Registry [bmad]: " registry_user
        registry_user=${registry_user:-bmad}
        htpasswd -Bc configs/registry-auth/htpasswd "${registry_user}"
        log_info "Registry authentication configured for user: ${registry_user}"
    fi

    # Pull images
    log_info "Pulling Docker images (this may take a while)..."
    docker compose pull

    # Start services
    log_info "Starting services..."
    docker compose up -d

    # Wait for services to be healthy
    log_info "Waiting for services to become healthy..."
    sleep 10

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
    init_status=$(curl -sf http://localhost:8200/v2/sys/init | jq -r '.initialized')

    if [[ "$init_status" == "true" ]]; then
        log_info "Vault is already initialized"
        log_warn "Root token and unseal keys should be in ${BACKUP_MOUNT}/vault/"
        return 0
    fi

    log_info "Initializing Vault..."

    # Initialize Vault with 5 key shares, 3 required to unseal
    local vault_init
    vault_init=$(curl -sf --request POST \
        --data '{"secret_shares": 5, "secret_threshold": 3}' \
        http://localhost:8200/v1/sys/init)

    # Save initialization output to backup
    local vault_backup_dir="${BACKUP_MOUNT}/vault"
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
        unseal_key=$(echo "${vault_init}" | jq -r ".unseal_keys_b64[$i]")
        curl -sf --request POST \
            --data "{\"key\": \"${unseal_key}\"}" \
            http://localhost:8200/v1/sys/unseal > /dev/null
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
  AWX (Ansible UI):       http://${CONTROL_VM_IP}:8080
  HashiCorp Vault:        http://${CONTROL_VM_IP}:8200

${GREEN}Development:${NC}
  Docker Registry:        http://${CONTROL_VM_IP}:5000

${GREEN}Backups:${NC}
  SMB Mount Point:        ${BACKUP_MOUNT}
  Vault Keys Location:    ${BACKUP_MOUNT}/vault/

${GREEN}First-Time Setup Required:${NC}
  1. Portainer: Create admin account on first login
  2. AWX: Login with credentials from .env file
  3. Vault: Use root token from ${BACKUP_MOUNT}/vault/vault-init-*.json

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
    log_info "  5. Deploy Docker Compose services stack"
    log_info "  6. Initialize HashiCorp Vault"

    prompt_continue "Do you want to continue?"

    # Execute setup steps
    update_system
    setup_backup_mount
    install_docker
    install_terraform
    install_ansible
    install_packer
    setup_project_repo
    setup_docker_compose
    initialize_vault

    show_service_urls

    log_info "Control VM setup complete!"
}

# Run main function
main "$@"
