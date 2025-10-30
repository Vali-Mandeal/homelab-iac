#!/usr/bin/env bash
#
# Control VM Deployment
# Deploy and configure Control VM
#

PROXMOX_AUTOMATION_KEY="${PROXMOX_AUTOMATION_KEY:-/root/.ssh/homelab_control}"
PROXMOX_AUTOMATION_PUB_KEY="${PROXMOX_AUTOMATION_PUB_KEY:-${PROXMOX_AUTOMATION_KEY}.pub}"

setup_proxmox_automation_key() {
    if [[ -f "$PROXMOX_AUTOMATION_KEY" ]]; then
        log_info "Proxmox automation key already exists"
        return 0
    fi

    log_info "Generating automation SSH key on Proxmox..."
    ssh-keygen -t ed25519 -C "proxmox-automation" -f "$PROXMOX_AUTOMATION_KEY" -N ""

    if [[ ! -f "$PROXMOX_AUTOMATION_PUB_KEY" ]]; then
        log_error "Failed to generate automation key"
        return 1
    fi

    log_info "Automation key generated successfully"
}

check_vm_exists() {
    local vm_id="$1"
    qm status "$vm_id" &>/dev/null
}

clone_vm_from_template() {
    local template_id="$1"
    local vm_id="$2"
    local vm_name="$3"

    log_info "Cloning Control VM from template..."
    qm clone "$template_id" "$vm_id" \
        --name "$vm_name" \
        --full
}

url_encode_ssh_key() {
    local input="$1"
    # URL encode using pure bash (no jq required)
    local output=""
    local length="${#input}"
    for (( i=0; i<length; i++ )); do
        local c="${input:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) output+="$c" ;;
            ' ') output+="%20" ;;
            *) output+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    echo "$output"
}

configure_vm_resources() {
    local vm_id="$1"

    log_info "Configuring Control VM resources..."

    # Collect SSH keys: admin key from Mac + automation key from Proxmox
    local temp_key_file="/tmp/cloudinit-sshkeys-${vm_id}.tmp"

    # Admin key (from Mac, for user access)
    if [[ -f "$SSH_PUBLIC_KEY_PATH" ]]; then
        cat "$SSH_PUBLIC_KEY_PATH" > "$temp_key_file"
    elif [[ -n "${SSH_PUBLIC_KEY_CONTENT:-}" ]]; then
        echo "$SSH_PUBLIC_KEY_CONTENT" > "$temp_key_file"
    else
        log_error "No admin SSH public key found"
        return 1
    fi

    # Automation key (from Proxmox, for automated access)
    if [[ -f "$PROXMOX_AUTOMATION_PUB_KEY" ]]; then
        cat "$PROXMOX_AUTOMATION_PUB_KEY" >> "$temp_key_file"
    else
        log_warn "Proxmox automation key not found, only admin key will be deployed"
    fi

    # Always use 'ubuntu' for cloud-init (what Ubuntu cloud images expect)
    # We'll create the custom user afterward if CONTROL_VM_USER is different
    local ciuser="ubuntu"

    # Use the temp file path directly - qm set will read and encode it
    qm set "$vm_id" \
        --cores "$CONTROL_VM_CPUS" \
        --memory "$CONTROL_VM_MEMORY" \
        --ipconfig0 "ip=${CONTROL_VM_IP}/24,gw=${GATEWAY_IP}" \
        --nameserver "$DNS_SERVERS" \
        --ciuser "$ciuser" \
        --sshkeys "$temp_key_file"

    rm -f "$temp_key_file"
}

resize_vm_disk() {
    local vm_id="$1"
    local disk_size="$2"

    log_info "Resizing disk to ${disk_size}G..."
    qm resize "$vm_id" scsi0 "${disk_size}G"
}

start_vm() {
    local vm_id="$1"

    log_info "Starting Control VM..."
    qm start "$vm_id"
}

wait_for_vm_ready() {
    local initial_user="${1:-ubuntu}"  # Default to ubuntu for cloud-init
    log_info "Waiting for Control VM to be ready (this may take 1-2 minutes)..."
    sleep "$VM_READY_INITIAL_WAIT"

    local retries=0
    while ! ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "${initial_user}@${CONTROL_VM_IP}" "echo 'VM ready'" &>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -ge $VM_READY_TIMEOUT ]]; then
            log_error "Control VM did not become ready in time"
            log_error "Check VM status with: qm status ${CONTROL_VM_ID:-$DEFAULT_CONTROL_VM_ID}"
            log_error "Tried connecting as: ${initial_user}@${CONTROL_VM_IP}"
            return 1
        fi
        sleep 10
        echo -n "."
    done
    echo ""

    # Fix cloud-init networking issues - add default route and DNS
    log_info "Configuring VM networking..."
    ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no "${initial_user}@${CONTROL_VM_IP}" "
        sudo ip route add default via ${GATEWAY_IP} 2>/dev/null || true
        sudo resolvectl dns eth0 ${DNS_SERVERS//,/ }
    " &>/dev/null || log_warn "Network configuration had some issues, continuing..."
}

create_admin_user() {
    local vm_ip="$1"
    local target_user="$2"

    if [[ "$target_user" == "ubuntu" ]]; then
        log_info "Using default ubuntu user, skipping admin user creation"
        return 0
    fi

    log_info "Creating '${target_user}' user on Control VM..."

    # Create the user, copy SSH keys, and set up sudo access
    ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no "ubuntu@${vm_ip}" "
        # Check if user already exists
        if id '${target_user}' &>/dev/null; then
            echo 'User ${target_user} already exists, setting up SSH access...'
        else
            # Create user with explicit primary group handling
            # If group exists, use it; otherwise create user normally
            if getent group '${target_user}' &>/dev/null; then
                sudo useradd -m -s /bin/bash -g '${target_user}' '${target_user}' 2>/dev/null || true
            else
                sudo useradd -m -s /bin/bash '${target_user}' 2>/dev/null || true
            fi
        fi

        # Add to sudo group
        sudo usermod -aG sudo '${target_user}' 2>/dev/null || true

        # Copy SSH keys from ubuntu user
        sudo mkdir -p /home/'${target_user}'/.ssh
        sudo cp ~/.ssh/authorized_keys /home/'${target_user}'/.ssh/ 2>/dev/null || true
        sudo chown -R '${target_user}':'${target_user}' /home/'${target_user}'/.ssh 2>/dev/null || true
        sudo chmod 700 /home/'${target_user}'/.ssh
        sudo chmod 600 /home/'${target_user}'/.ssh/authorized_keys 2>/dev/null || true

        # Allow passwordless sudo
        echo '${target_user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/'${target_user}' >/dev/null
        sudo chmod 440 /etc/sudoers.d/'${target_user}'

        echo 'User ${target_user} setup complete'
    " || {
        log_error "Failed to set up ${target_user} user"
        return 1
    }

    # Verify the new user works
    log_info "Verifying SSH access for '${target_user}'..."
    if ssh -i "$PROXMOX_AUTOMATION_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${target_user}@${vm_ip}" "whoami && echo 'SSH access verified'" &>/dev/null; then
        log_info "✓ User '${target_user}' created and SSH access verified"
        return 0
    else
        log_error "User setup completed but SSH access verification failed"
        log_error "Try manually: ssh -i /root/.ssh/homelab_control ${target_user}@${vm_ip}"
        return 1
    fi
}

deploy_control_vm() {
    log_section "Deploying Control VM"

    local template_id="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"
    local vm_id="${CONTROL_VM_ID:-$DEFAULT_CONTROL_VM_ID}"
    local vm_name="${CONTROL_VM_NAME:-$DEFAULT_CONTROL_VM_NAME}"
    local target_user="${CONTROL_VM_USER:-$DEFAULT_CONTROL_VM_USER}"

    # Generate automation SSH key on Proxmox for VM access
    setup_proxmox_automation_key

    if check_vm_exists "$vm_id"; then
        log_warn "Control VM $vm_id already exists - destroying and recreating with latest config..."

        local vm_status=$(qm status "$vm_id" | grep -oP 'status: \K\w+')
        if [[ "$vm_status" == "running" ]]; then
            qm stop "$vm_id"
            sleep 3
        fi

        qm destroy "$vm_id"
        sleep 2
    fi

    clone_vm_from_template "$template_id" "$vm_id" "$vm_name"
    configure_vm_resources "$vm_id"
    resize_vm_disk "$vm_id" "$CONTROL_VM_DISK"
    start_vm "$vm_id"

    # Remove old SSH host key from known_hosts (VM was destroyed/recreated)
    log_info "Removing old SSH host key for ${CONTROL_VM_IP}..."
    ssh-keygen -R "${CONTROL_VM_IP}" 2>/dev/null || true

    # Wait for ubuntu user (cloud-init default)
    wait_for_vm_ready "ubuntu"

    # Create custom user if different from ubuntu
    if [[ "$target_user" != "ubuntu" ]]; then
        create_admin_user "$CONTROL_VM_IP" "$target_user"
    fi

    log_info "Control VM deployed successfully at $CONTROL_VM_IP"
    if [[ "$target_user" != "ubuntu" ]]; then
        log_info "Access via: ssh ${target_user}@${CONTROL_VM_IP}"
    else
        log_info "Access via: ssh ubuntu@${CONTROL_VM_IP}"
    fi
}
