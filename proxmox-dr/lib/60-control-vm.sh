#!/usr/bin/env bash
#
# Control VM Deployment
# Deploy and configure Control VM
#

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

configure_vm_resources() {
    local vm_id="$1"

    log_info "Configuring Control VM resources..."
    qm set "$vm_id" \
        --cores "$CONTROL_VM_CPUS" \
        --memory "$CONTROL_VM_MEMORY" \
        --ipconfig0 "ip=${CONTROL_VM_IP}/24,gw=${GATEWAY_IP}" \
        --nameserver "$DNS_SERVERS" \
        --ciuser "$CONTROL_VM_USER" \
        --sshkeys "$SSH_PUBLIC_KEY_PATH"
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
    log_info "Waiting for Control VM to be ready (this may take 1-2 minutes)..."
    sleep "$VM_READY_INITIAL_WAIT"

    local retries=0
    while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "${CONTROL_VM_USER}@${CONTROL_VM_IP}" "echo 'VM ready'" &>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -ge $VM_READY_TIMEOUT ]]; then
            log_error "Control VM did not become ready in time"
            log_error "Check VM status with: qm status ${CONTROL_VM_ID:-$DEFAULT_CONTROL_VM_ID}"
            return 1
        fi
        sleep 10
        echo -n "."
    done
    echo ""
}

deploy_control_vm() {
    log_section "Deploying Control VM"

    local template_id="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"
    local vm_id="${CONTROL_VM_ID:-$DEFAULT_CONTROL_VM_ID}"
    local vm_name="${CONTROL_VM_NAME:-$DEFAULT_CONTROL_VM_NAME}"

    if check_vm_exists "$vm_id"; then
        log_warn "Control VM $vm_id already exists"
        log_info "Using existing Control VM"
        return 0
    fi

    clone_vm_from_template "$template_id" "$vm_id" "$vm_name"
    configure_vm_resources "$vm_id"
    resize_vm_disk "$vm_id" "$CONTROL_VM_DISK"
    start_vm "$vm_id"
    wait_for_vm_ready

    log_info "Control VM deployed successfully at $CONTROL_VM_IP"
}
