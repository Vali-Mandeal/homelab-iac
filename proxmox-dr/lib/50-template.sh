#!/usr/bin/env bash
#
# VM Template Creation
# Build Ubuntu cloud-init template
#

check_template_exists() {
    local template_id="$1"
    qm status "$template_id" &>/dev/null
}

download_ubuntu_cloud_image() {
    local image_file="$1"

    if [[ -f "$image_file" ]]; then
        return 0
    fi

    log_info "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress "$UBUNTU_CLOUD_IMAGE_URL" -O "$image_file"
}

create_template_vm() {
    local template_id="$1"

    log_info "Creating template VM $template_id..."
    qm create "$template_id" \
        --name "ubuntu-2404-template" \
        --memory 2048 \
        --cores 2 \
        --net0 "virtio,bridge=${PRIVATE_NETWORK_BRIDGE}"
}

import_disk_to_template() {
    local template_id="$1"
    local image_file="$2"

    log_info "Importing disk image..."
    qm importdisk "$template_id" "$image_file" "$CONTROL_VM_STORAGE" --format qcow2
}

configure_template_vm() {
    local template_id="$1"

    log_info "Configuring template..."
    qm set "$template_id" \
        --scsihw virtio-scsi-pci \
        --scsi0 "${CONTROL_VM_STORAGE}:vm-${template_id}-disk-0" \
        --ide2 "${CONTROL_VM_STORAGE}:cloudinit" \
        --boot c \
        --bootdisk scsi0 \
        --serial0 socket \
        --vga serial0 \
        --agent enabled=1
}

convert_vm_to_template() {
    local template_id="$1"

    log_info "Converting to template..."
    qm template "$template_id"
}

create_ubuntu_template() {
    log_section "Creating Ubuntu Cloud-Init Template"

    local template_id="${UBUNTU_TEMPLATE_ID:-$DEFAULT_UBUNTU_TEMPLATE_ID}"

    if check_template_exists "$template_id"; then
        log_warn "Template VM $template_id already exists"
        log_info "Using existing template"
        return 0
    fi

    local image_file="$UBUNTU_CLOUD_IMAGE_FILE"

    download_ubuntu_cloud_image "$image_file"
    create_template_vm "$template_id"
    import_disk_to_template "$template_id" "$image_file"
    configure_template_vm "$template_id"
    convert_vm_to_template "$template_id"

    log_info "Ubuntu template created successfully (ID: $template_id)"
}
