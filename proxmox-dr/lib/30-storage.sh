#!/usr/bin/env bash
#
# Storage Configuration Functions
# NFS/SMB mount setup
#

install_nfs_client() {
    if dpkg -l | grep -q nfs-common; then
        return 0
    fi

    log_info "Installing nfs-common..."
    apt-get update -qq
    apt-get install -y nfs-common
}

create_mount_points() {
    mkdir -p "$PRIVATE_MOUNT_POINT"
    mkdir -p "$PUBLIC_MOUNT_POINT"
}

mount_nfs_share() {
    local mount_point="$1"
    local nfs_host="$2"
    local nfs_share="$3"
    local nfs_path="${nfs_host}:/var/nfs/shared/${nfs_share}"

    if mountpoint -q "$mount_point"; then
        log_info "NFS share already mounted at $mount_point"
        return 0
    fi

    log_info "Mounting NFS share: ${nfs_path}"
    mount -t nfs "$nfs_path" "$mount_point"
    log_info "NFS share mounted successfully at $mount_point"
}

add_mount_to_fstab() {
    local mount_point="$1"
    local nfs_host="$2"
    local nfs_share="$3"
    local fstab_entry="${nfs_host}:/var/nfs/shared/${nfs_share} ${mount_point} nfs defaults 0 0"

    if grep -q "$mount_point" "$FSTAB_FILE"; then
        return 0
    fi

    echo "$fstab_entry" >> "$FSTAB_FILE"
    log_info "NFS mount added to fstab: $mount_point"
}

setup_nfs_mounts() {
    log_section "Setting Up NFS Mounts to UNAS"

    install_nfs_client
    create_mount_points

    mount_nfs_share "$PRIVATE_MOUNT_POINT" "$UNAS_PRIVATE_IP" "$NFS_PRIVATE_SHARE"
    mount_nfs_share "$PUBLIC_MOUNT_POINT" "$UNAS_PUBLIC_IP" "$NFS_PUBLIC_SHARE"

    add_mount_to_fstab "$PRIVATE_MOUNT_POINT" "$UNAS_PRIVATE_IP" "$NFS_PRIVATE_SHARE"
    add_mount_to_fstab "$PUBLIC_MOUNT_POINT" "$UNAS_PUBLIC_IP" "$NFS_PUBLIC_SHARE"

    log_info "NFS mounts configured successfully"
}
