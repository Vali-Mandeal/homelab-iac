# Homelab Infrastructure as Code

Personal homelab automation using Terraform, Ansible, and Packer.

## Current Status

**Implemented:**
- ✅ Bootstrap script to deploy management node on Proxmox
- ✅ Management node with Terraform, Ansible, Packer, Docker, MkDocs

**In Progress:**
- 🔄 Converting legacy bash scripts to Terraform/Ansible
- 🔄 Creating reusable modules and roles

## Quick Start

### Deploy Management Node

```bash
cd bootstrap
cp .env.example .env
# Edit .env with your Proxmox details
nano .env
bash deploy-management-node.sh
```

This creates a VM on Proxmox with all tools installed.

### After Bootstrap

SSH to management node and start deploying infrastructure:

```bash
ssh <user>@<management-ip>
cd ~/homelab-iac
```

## Structure

```
homelab-iac/
├── bootstrap/        # Deploy management node
├── terraform/        # Infrastructure provisioning (TODO)
├── ansible/          # Configuration management (TODO)
├── packer/           # VM templates (TODO)
└── docs/             # Documentation
```

## Migration from Legacy

Old bash scripts in `homelab-legacy/` are being converted to proper IaC.

See `bootstrap/README.md` for getting started.
