#!/usr/bin/env bash
#
# Storage Configuration Functions
# NFS and SMB/CIFS mount setup
#

# ==============================================================================
# PACKAGE INSTALLATION
# ==============================================================================

install_nfs_client() {
    if dpkg -l | grep -q nfs-common; then
        return 0
    fi

    log_info "Installing NFS client utilities..."
    apt-get update -qq
    apt-get install -y nfs-common
}

install_smb_client() {
    if dpkg -l | grep -q cifs-utils; then
        return 0
    fi

    log_info "Installing SMB/CIFS client utilities..."
    apt-get update -qq
    apt-get install -y cifs-utils
}

# ==============================================================================
# MOUNT POINT CREATION
# ==============================================================================

create_mount_points() {
    log_info "Creating mount point directories..."
    mkdir -p "$NFS_PUBLIC_MEDIA_MOUNT"
    mkdir -p "$SMB_PRIVATE_MOUNT"
    mkdir -p "$SMB_PUBLIC_MOUNT"
}

# ==============================================================================
# SMB CREDENTIALS MANAGEMENT
# ==============================================================================

create_smb_credentials_file() {
    local creds_file="$1"
    local username="$2"
    local password="$3"

    if [[ -f "$creds_file" ]]; then
        log_info "SMB credentials file already exists: $creds_file"
        return 0
    fi

    log_info "Creating SMB credentials file: $creds_file"
    cat > "$creds_file" << EOF
username=$username
password=$password
EOF
    chmod 600 "$creds_file"
    chown root:root "$creds_file"
}

# ==============================================================================
# NFS FSTAB CONFIGURATION
# ==============================================================================

add_nfs_to_fstab() {
    local mount_point="$1"
    local nfs_host="$2"
    local nfs_share="$3"
    local nfs_path="${nfs_host}:/var/nfs/shared/${nfs_share}"

    # Remove old entries to avoid duplicates
    if grep -q "$mount_point" "$FSTAB_FILE"; then
        log_info "Removing old fstab entry for $mount_point"
        sed -i "\|${mount_point}|d" "$FSTAB_FILE"
    fi

    # NFS mount options:
    # - vers=3: NFSv3 (UNAS compatibility)
    # - hard: Retry indefinitely (data integrity)
    # - intr: Allow keyboard interrupt
    # - timeo=600: 60-second timeout
    # - retrans=2: 2 retry attempts
    # - _netdev: Network filesystem (wait for network)
    # - nofail: Don't fail boot if unavailable
    # - x-systemd.automount: Self-healing remount
    # - auto: Mount at boot if NAS ready
    local nfs_options="vers=3,hard,intr,timeo=600,retrans=2,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,auto"
    local fstab_entry="${nfs_path} ${mount_point} nfs ${nfs_options} 0 0"

    echo "$fstab_entry" >> "$FSTAB_FILE"
    log_info "NFS mount added to fstab: $mount_point"
}

# ==============================================================================
# SMB FSTAB CONFIGURATION
# ==============================================================================

add_smb_to_fstab() {
    local mount_point="$1"
    local smb_host="$2"
    local smb_share="$3"
    local creds_file="$4"
    local uid="${5:-1234}"
    local gid="${6:-1234}"
    local smb_path="//${smb_host}/${smb_share}"

    # Remove old entries to avoid duplicates
    if grep -q "$mount_point" "$FSTAB_FILE"; then
        log_info "Removing old fstab entry for $mount_point"
        sed -i "\|${mount_point}|d" "$FSTAB_FILE"
    fi

    # SMB/CIFS mount options:
    # - credentials: Auth file (secure, chmod 600)
    # - uid/gid: Force ownership (avoids permission headaches!)
    # - file_mode/dir_mode: Permissions for files/dirs
    # - vers=3.0: SMB version 3.0
    # - _netdev: Network filesystem
    # - nofail: Don't fail boot
    # - x-systemd.automount: Self-healing remount
    # - auto: Mount at boot if NAS ready
    local smb_options="credentials=${creds_file},uid=${uid},gid=${gid},file_mode=0775,dir_mode=0775,vers=3.0,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,auto"
    local fstab_entry="${smb_path} ${mount_point} cifs ${smb_options} 0 0"

    echo "$fstab_entry" >> "$FSTAB_FILE"
    log_info "SMB mount added to fstab: $mount_point"
}

# ==============================================================================
# SYSTEMD AUTOMOUNT ACTIVATION
# ==============================================================================

enable_automount_units() {
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    log_info "Enabling systemd automount units..."

    # NFS public media mount
    local nfs_automount_unit
    nfs_automount_unit=$(systemd-escape -p --suffix=automount "$NFS_PUBLIC_MEDIA_MOUNT")
    systemctl enable "$nfs_automount_unit" 2>/dev/null || true
    systemctl start "$nfs_automount_unit" 2>/dev/null || true

    # SMB private mount
    local smb_private_automount_unit
    smb_private_automount_unit=$(systemd-escape -p --suffix=automount "$SMB_PRIVATE_MOUNT")
    systemctl enable "$smb_private_automount_unit" 2>/dev/null || true
    systemctl start "$smb_private_automount_unit" 2>/dev/null || true

    # SMB public mount
    local smb_public_automount_unit
    smb_public_automount_unit=$(systemd-escape -p --suffix=automount "$SMB_PUBLIC_MOUNT")
    systemctl enable "$smb_public_automount_unit" 2>/dev/null || true
    systemctl start "$smb_public_automount_unit" 2>/dev/null || true

    log_info "Systemd automount units configured"
}

# ==============================================================================
# MOUNT TESTING
# ==============================================================================

test_mount_accessibility() {
    log_info "Testing mount accessibility..."

    # Test NFS public media
    if timeout 10 ls "$NFS_PUBLIC_MEDIA_MOUNT" >/dev/null 2>&1; then
        log_info "✓ NFS public media mount accessible"
    else
        log_warn "NFS public media mount not accessible (will automount when NAS is online)"
    fi

    # Test SMB private
    if timeout 10 ls "$SMB_PRIVATE_MOUNT" >/dev/null 2>&1; then
        log_info "✓ SMB private mount accessible"
    else
        log_warn "SMB private mount not accessible (will automount when NAS is online)"
    fi

    # Test SMB public
    if timeout 10 ls "$SMB_PUBLIC_MOUNT" >/dev/null 2>&1; then
        log_info "✓ SMB public mount accessible"
    else
        log_warn "SMB public mount not accessible (will automount when NAS is online)"
    fi
}

# ==============================================================================
# MAIN SETUP FUNCTION
# ==============================================================================

setup_storage_mounts() {
    log_section "Setting Up Storage Mounts (NFS + SMB)"

    # Install client utilities
    install_nfs_client
    install_smb_client

    # Create mount points
    create_mount_points

    # Create SMB credentials files
    create_smb_credentials_file "$SMB_PRIVATE_CREDENTIALS" "$SMB_USERNAME" "$SMB_PASSWORD"
    create_smb_credentials_file "$SMB_PUBLIC_CREDENTIALS" "$SMB_USERNAME" "$SMB_PASSWORD"

    # Configure NFS mount
    log_info "Configuring NFS mount..."
    add_nfs_to_fstab "$NFS_PUBLIC_MEDIA_MOUNT" "$UNAS_PUBLIC_IP" "$NFS_PUBLIC_MEDIA_SHARE_NAME"

    # Configure SMB mounts (with credentials)
    log_info "Configuring SMB mount for private data..."
    add_smb_to_fstab "$SMB_PRIVATE_MOUNT" "$UNAS_PRIVATE_IP" "$SMB_PRIVATE_SHARE_NAME" "$SMB_PRIVATE_CREDENTIALS"

    log_info "Configuring SMB mount for public data..."
    add_smb_to_fstab "$SMB_PUBLIC_MOUNT" "$UNAS_PUBLIC_IP" "$SMB_PUBLIC_SHARE_NAME" "$SMB_PUBLIC_CREDENTIALS"

    # Enable systemd automount units
    enable_automount_units

    # Test accessibility
    test_mount_accessibility

    log_info "Storage mounts configured successfully"
    log_info "Summary:"
    log_info "  - NFS: $NFS_PUBLIC_MEDIA_MOUNT ($NFS_PUBLIC_MEDIA_SHARE_NAME)"
    log_info "  - SMB: $SMB_PRIVATE_MOUNT ($SMB_PRIVATE_SHARE_NAME)"
    log_info "  - SMB: $SMB_PUBLIC_MOUNT ($SMB_PUBLIC_SHARE_NAME)"
}
