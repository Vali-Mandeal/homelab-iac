# Bootstrap Scripts

This directory contains minimal scripts to deploy the management node VM on a fresh Proxmox installation.

## Quick Start

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your configuration (Proxmox IP, passwords, SSH keys, etc.)
   ```bash
   nano .env
   ```

3. Run the bootstrap script from your local machine:
   ```bash
   bash deploy-management-node.sh
   ```

## What It Does

1. Downloads Ubuntu cloud image to Proxmox
2. Creates a VM template (configurable VMID)
3. Clones the template to create management-node (configurable VMID and IP)
4. Installs Terraform, Ansible, Packer, Docker, and MkDocs
5. Clones the homelab-iac repository

## After Bootstrap

SSH into the management node:
```bash
ssh <your-ssh-user>@<your-mgmt-ip>
```

Navigate to the repo:
```bash
cd ~/homelab-iac
```

Start deploying infrastructure with Terraform and Ansible.

## Documentation

For detailed documentation, see the [docs/](../docs/) folder or run MkDocs locally.
