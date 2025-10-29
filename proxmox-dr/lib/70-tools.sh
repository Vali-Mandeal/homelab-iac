#!/usr/bin/env bash
#
# IaC Tools Installation
# Install Terraform, Ansible, Packer, Docker
#

install_base_packages() {
    local ssh_target="$1"
    log_info "Installing base packages..."
    ssh "$ssh_target" "sudo apt-get update -qq && sudo apt-get install -y curl wget git unzip python3-pip docker.io docker-compose"
}

add_user_to_docker_group() {
    local ssh_target="$1"
    local username="$2"
    log_info "Adding ${username} to docker group..."
    ssh "$ssh_target" "sudo usermod -aG docker ${username}"
}

install_terraform() {
    local ssh_target="$1"
    local version="$2"

    log_info "Installing Terraform ${version}..."
    ssh "$ssh_target" "
        wget -q https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_amd64.zip -O /tmp/terraform.zip &&
        sudo unzip -o /tmp/terraform.zip -d /usr/local/bin/ &&
        rm /tmp/terraform.zip &&
        terraform version
    "
}

install_ansible() {
    local ssh_target="$1"
    local version="$2"

    log_info "Installing Ansible ${version}..."
    ssh "$ssh_target" "sudo pip3 install --break-system-packages ansible==${version}"
}

install_packer() {
    local ssh_target="$1"
    local version="$2"

    log_info "Installing Packer ${version}..."
    ssh "$ssh_target" "
        wget -q https://releases.hashicorp.com/packer/${version}/packer_${version}_linux_amd64.zip -O /tmp/packer.zip &&
        sudo unzip -o /tmp/packer.zip -d /usr/local/bin/ &&
        rm /tmp/packer.zip &&
        packer version
    "
}

clone_homelab_repository() {
    local ssh_target="$1"
    local repo_url="$2"
    local username="$3"

    if [[ -z "$repo_url" ]]; then
        log_info "No GitHub repository URL configured, skipping clone"
        return 0
    fi

    log_info "Cloning homelab-iac repository..."
    ssh "$ssh_target" "
        mkdir -p /opt &&
        sudo git clone ${repo_url} /opt/homelab-iac &&
        sudo chown -R ${username}:${username} /opt/homelab-iac
    "
}

setup_control_vm() {
    log_section "Setting Up Control VM (Installing IaC Tools)"

    local ssh_target="${CONTROL_VM_USER}@${CONTROL_VM_IP}"
    local terraform_version="${TERRAFORM_VERSION:-$DEFAULT_TERRAFORM_VERSION}"
    local ansible_version="${ANSIBLE_VERSION:-$DEFAULT_ANSIBLE_VERSION}"
    local packer_version="${PACKER_VERSION:-$DEFAULT_PACKER_VERSION}"

    install_base_packages "$ssh_target"
    add_user_to_docker_group "$ssh_target" "$CONTROL_VM_USER"
    install_terraform "$ssh_target" "$terraform_version"
    install_ansible "$ssh_target" "$ansible_version"
    install_packer "$ssh_target" "$packer_version"
    clone_homelab_repository "$ssh_target" "${GITHUB_REPO_URL:-}" "$CONTROL_VM_USER"

    log_info "Control VM setup complete"
    log_info "SSH to Control VM: ssh ${ssh_target}"
}
