#!/usr/bin/env bash
#
# SSH Key Generation and Management
# This module runs on your LOCAL workstation (Mac)
# Handles SSH key generation and validation
#

# ==============================================================================
# CONSTANTS
# ==============================================================================

readonly SSH_KEY_TYPE="ed25519"
readonly SSH_KEY_PATH="$HOME/.ssh/homelab_admin"
readonly SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"
readonly SSH_AUTOMATION_KEY_PATH="$HOME/.ssh/homelab_control"
readonly SSH_AUTOMATION_PUB_KEY_PATH="${SSH_AUTOMATION_KEY_PATH}.pub"

# ==============================================================================
# KEY VALIDATION
# ==============================================================================

check_ssh_key_exists() {
    if [[ -f "$SSH_KEY_PATH" ]] && [[ -f "$SSH_PUB_KEY_PATH" ]]; then
        return 0
    else
        return 1
    fi
}

validate_ssh_key_permissions() {
    local key_path="$1"
    local current_perms
    current_perms=$(stat -f "%OLp" "$key_path" 2>/dev/null || stat -c "%a" "$key_path" 2>/dev/null)

    if [[ "$current_perms" != "600" ]]; then
        log_warn "Fixing permissions on $key_path"
        chmod 600 "$key_path"
    fi
}

# ==============================================================================
# KEY GENERATION
# ==============================================================================

generate_ssh_key() {
    local key_path="$1"
    local key_comment="$2"
    local use_passphrase="$3"

    log_info "Generating SSH key: $key_path"

    if [[ "$use_passphrase" == "true" ]]; then
        ssh-keygen -t "$SSH_KEY_TYPE" -C "$key_comment" -f "$key_path"
    else
        ssh-keygen -t "$SSH_KEY_TYPE" -C "$key_comment" -f "$key_path" -N ""
    fi

    if [[ $? -eq 0 ]]; then
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
        log_info "SSH key generated successfully"
        return 0
    else
        log_error "Failed to generate SSH key"
        return 1
    fi
}

prompt_generate_main_key() {
    log_section "SSH Key Setup"

    log_warn "No SSH key found at: $SSH_KEY_PATH"
    log_info "This key is required for accessing Proxmox and VMs"
    echo ""

    read -p "Generate SSH key now? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        log_info "You will be prompted for a passphrase (recommended for security)"
        log_info "Press Enter twice for no passphrase (not recommended)"
        echo ""

        if generate_ssh_key "$SSH_KEY_PATH" "homelab-admin@$(hostname)" "true"; then
            log_info "Main SSH key created: $SSH_KEY_PATH"
            return 0
        else
            return 1
        fi
    else
        log_error "SSH key is required to continue"
        log_info "Please generate one manually:"
        log_info "  ssh-keygen -t ed25519 -f $SSH_KEY_PATH"
        exit 1
    fi
}

generate_automation_key() {
    if [[ -f "$SSH_AUTOMATION_KEY_PATH" ]]; then
        log_info "Automation key already exists: $SSH_AUTOMATION_KEY_PATH"
        return 0
    fi

    log_info "Generating automation key for Terraform/Ansible..."

    if generate_ssh_key "$SSH_AUTOMATION_KEY_PATH" "homelab-control-vm" "false"; then
        log_info "Automation key created (no passphrase for automation)"
        return 0
    else
        log_warn "Failed to generate automation key (optional, can be created later)"
        return 1
    fi
}

# ==============================================================================
# SSH CONFIG MANAGEMENT
# ==============================================================================

create_ssh_config() {
    local ssh_config_file="$HOME/.ssh/config"

    if [[ -f "$ssh_config_file" ]] && grep -q "Host proxmox" "$ssh_config_file"; then
        log_info "SSH config already contains Proxmox entry"
        return 0
    fi

    log_info "Adding Proxmox to SSH config..."

    # Create config directory if it doesn't exist
    mkdir -p "$HOME/.ssh"

    # Append Proxmox config
    cat >> "$ssh_config_file" << EOF

# Proxmox Homelab Configuration (Auto-generated)
Host proxmox pve
    HostName ${PROXMOX_HOST}
    User ${SSH_USER}
    IdentityFile ${SSH_KEY_PATH}
    ServerAliveInterval 60
    ServerAliveCountMax 3

# Control VM (will be available after deployment)
Host control-vm control
    HostName ${CONTROL_VM_IP}
    User ${CONTROL_VM_USER}
    IdentityFile ${SSH_KEY_PATH}
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF

    chmod 600 "$ssh_config_file"
    log_info "SSH config updated: $ssh_config_file"
    log_info "You can now use: ssh proxmox"
    log_info "After deployment: ssh control-vm (or ssh control)"
}

# ==============================================================================
# KEY DEPLOYMENT
# ==============================================================================

deploy_ssh_key_to_proxmox() {
    log_section "Deploying SSH Key to Proxmox"

    log_info "Copying SSH public key to Proxmox host..."
    log_info "You will be prompted for the root password"
    echo ""

    # Try ssh-copy-id first (cleanest method)
    if command -v ssh-copy-id &> /dev/null; then
        if ssh-copy-id -i "$SSH_PUB_KEY_PATH" -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" 2>/dev/null; then
            log_info "SSH key deployed successfully"
            return 0
        fi
    fi

    # Fallback: manual copy via cat + ssh
    log_info "Using fallback method..."
    if cat "$SSH_PUB_KEY_PATH" | ssh -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" \
        "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"; then
        log_info "SSH key deployed successfully"
        return 0
    else
        log_error "Failed to deploy SSH key"
        log_info "You can manually copy it later:"
        log_info "  ssh-copy-id -i $SSH_PUB_KEY_PATH -p $SSH_PORT ${SSH_USER}@${PROXMOX_HOST}"
        return 1
    fi
}

test_ssh_key_authentication() {
    log_info "Testing SSH key authentication..."

    if ssh -i "$SSH_KEY_PATH" -o "PasswordAuthentication=no" -o "BatchMode=yes" -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}" "echo 'SSH key auth works'" &>/dev/null; then
        log_info "✓ SSH key authentication successful"
        return 0
    else
        log_warn "SSH key authentication not working yet"
        return 1
    fi
}

# ==============================================================================
# MAIN SETUP FLOW
# ==============================================================================

setup_ssh_keys() {
    log_section "SSH Key Setup"

    # Check if main key exists
    if ! check_ssh_key_exists; then
        prompt_generate_main_key
    else
        log_info "Found existing SSH key: $SSH_KEY_PATH"
        validate_ssh_key_permissions "$SSH_KEY_PATH"
    fi

    # Update SSH_PUBLIC_KEY_PATH in config to use our standard key
    export SSH_PUBLIC_KEY_PATH="$SSH_PUB_KEY_PATH"

    # Generate automation key (optional, non-blocking)
    generate_automation_key || true

    # Create SSH config for convenience
    create_ssh_config

    # Test if we can already connect with key
    if test_ssh_key_authentication; then
        log_info "SSH key already deployed to Proxmox"
        return 0
    fi

    # Need to deploy the key
    log_warn "SSH key not yet deployed to Proxmox"

    read -p "Deploy SSH key to Proxmox now? [Y/n]: " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        if deploy_ssh_key_to_proxmox; then
            # Verify it worked
            if test_ssh_key_authentication; then
                log_info "✓ SSH key setup complete"
                return 0
            else
                log_error "SSH key deployed but authentication still failing"
                return 1
            fi
        else
            return 1
        fi
    else
        log_warn "Skipping SSH key deployment"
        log_warn "You'll need to enter password for SSH connections"
        return 1
    fi
}
