#!/usr/bin/env bash
#
# Constants and Default Values
# All magic strings and default values defined here
#

# ==============================================================================
# VM IDs
# ==============================================================================

readonly DEFAULT_UBUNTU_TEMPLATE_ID="9000"
readonly DEFAULT_CONTROL_VM_ID="101"

# ==============================================================================
# UBUNTU CLOUD IMAGE
# ==============================================================================

# Default URL (can be overridden in config)
DEFAULT_UBUNTU_CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
readonly UBUNTU_CLOUD_IMAGE_FILE="/tmp/ubuntu-24.04-cloudimg.img"

# ==============================================================================
# IaC TOOL VERSIONS
# ==============================================================================

readonly DEFAULT_TERRAFORM_VERSION="1.9.8"
readonly DEFAULT_ANSIBLE_VERSION="2.17.5"
readonly DEFAULT_PACKER_VERSION="1.11.2"

# ==============================================================================
# NETWORK
# ==============================================================================

readonly DEFAULT_PRIVATE_NETWORK_BRIDGE="vmbr0"
readonly DEFAULT_PUBLIC_NETWORK_BRIDGE="vmbr1"
readonly DEFAULT_DNS_SERVERS="1.1.1.1 8.8.8.8"

# ==============================================================================
# STORAGE
# ==============================================================================

readonly SMB_PRIVATE_CREDENTIALS="/root/.smbcredentials_private"
readonly SMB_PUBLIC_CREDENTIALS="/root/.smbcredentials_public"
readonly DEFAULT_CONTROL_VM_STORAGE="local-lvm"

# ==============================================================================
# CONTROL VM DEFAULTS
# ==============================================================================

readonly DEFAULT_CONTROL_VM_NAME="control-vm"
readonly DEFAULT_CONTROL_VM_USER="admin"
readonly DEFAULT_CONTROL_VM_CPUS="4"
readonly DEFAULT_CONTROL_VM_MEMORY="8192"
readonly DEFAULT_CONTROL_VM_DISK="100"

# ==============================================================================
# PROXMOX REPOSITORIES
# ==============================================================================

readonly PROXMOX_ENTERPRISE_REPO_FILE="/etc/apt/sources.list.d/pve-enterprise.list"
readonly PROXMOX_NO_SUB_REPO_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
readonly PROXMOX_NO_SUB_REPO="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"

# ==============================================================================
# PATHS
# ==============================================================================

readonly PROXMOX_VERSION_FILE="/etc/pve/.version"
readonly SSH_CONFIG_FILE="/etc/ssh/sshd_config"
readonly FSTAB_FILE="/etc/fstab"

# ==============================================================================
# TIMEOUTS & RETRIES
# ==============================================================================

readonly SSH_CONNECT_TIMEOUT="5"
readonly VM_READY_TIMEOUT="20"
readonly VM_READY_INITIAL_WAIT="30"

# ==============================================================================
# DOCKER COMPOSE SERVICES
# ==============================================================================

readonly CONTROL_VM_STACK_FILE="/opt/homelab-iac/docker-compose/control-vm-stack.yml"

readonly SERVICE_MKDOCS_PORT="8000"
readonly SERVICE_PORTAINER_PORT="9000"
readonly SERVICE_AWX_PORT="8080"
readonly SERVICE_VAULT_PORT="8200"
readonly SERVICE_REGISTRY_PORT="5000"
