# Proxmox Disaster Recovery Script

Automated Proxmox setup from bare metal to fully configured infrastructure.

## What This Does

- Configures Proxmox repositories (disables enterprise, enables no-subscription)
- Sets up SSH key-based authentication
- Configures network bridges (private + public with VLAN tagging)
- Mounts NFS shares from UNAS
- Creates Ubuntu 24.04 cloud-init template
- Deploys Control VM with all IaC tools (Terraform, Ansible, Packer, Docker)
- Clones homelab-iac repository
- Starts Docker Compose stack (MkDocs, Portainer, AWX, Vault, Registry)

**Time:** 15-30 minutes, fully automated

## Usage

### One-Time Setup

```bash
cd proxmox-dr/config
cp proxmox-config.env.example proxmox-config.env
nano proxmox-config.env  # Edit with your settings
```

### Deploy (Zero Interaction)

```bash
cd proxmox-dr
./deploy.sh
```

That's it. The orchestrator handles everything:
1. Reads your config
2. Tests SSH connection to Proxmox
3. Copies all files to Proxmox
4. Executes setup remotely
5. Streams output to your terminal
6. Cleans up temp files

## Configuration

Edit `config/proxmox-config.env`:

```bash
# Connection (for deploy.sh)
PROXMOX_HOST="10.x.x.x"
SSH_USER="root"
SSH_PORT="22"

# Network
PROXMOX_HOST_IP="10.x.x.x"
PROXMOX_HOSTNAME="pve"
GATEWAY_IP="10.x.x.x"
PRIVATE_NETWORK_CIDR="10.x.x.0/24"
PUBLIC_NETWORK_CIDR="10.x.x.0/24"
PUBLIC_VLAN_TAG="4"

# Storage (UNAS)
UNAS_PRIVATE_IP="10.x.x.x"
UNAS_PUBLIC_IP="10.x.x.x"
NFS_PRIVATE_SHARE="your-private-share"
NFS_PUBLIC_SHARE="your-public-share"

# Control VM
CONTROL_VM_IP="10.x.x.x"
CONTROL_VM_CPUS="4"
CONTROL_VM_MEMORY="8192"
CONTROL_VM_DISK="100"
CONTROL_VM_USER="admin"

# SSH
SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_rsa.pub"

# GitHub (optional)
GITHUB_REPO_URL="https://github.com/yourusername/homelab-iac.git"
```

## Architecture

### Two-Script Design

**deploy.sh** (runs on your Mac):
- Orchestrator
- Reads config
- Tests SSH
- Copies files via rsync
- Executes run-setup.sh remotely
- Streams output

**run-setup.sh** (runs on Proxmox):
- Main DR script
- Sources modular lib files
- Executes setup steps
- Creates Control VM

### Modular Library

All functions split into focused modules:

```
lib/
├── 00-constants.sh       # All constants, no magic strings
├── 01-logging.sh         # Logging functions
├── 02-validation.sh      # Config validation
├── 10-ssh.sh             # SSH setup
├── 20-network.sh         # Network bridges
├── 30-storage.sh         # NFS mounts
├── 40-repositories.sh    # Proxmox repos
├── 50-template.sh        # VM template creation
├── 60-control-vm.sh      # Control VM deployment
├── 70-tools.sh           # IaC tools installation
├── 80-services.sh        # Docker Compose stack
├── 90-backup.sh          # Backup setup
└── 99-summary.sh         # Completion summary
```

Each file: ~50-80 lines, single responsibility, clean code.

### Secrets Management

- No hardcoded IPs or credentials
- Config file (`.env`) is gitignored
- SSH keys only (no password auth)
- All secrets via environment variables or config file

### Idempotent

Safe to run multiple times:
- Checks if resources exist before creating
- Asks for confirmation before destructive operations
- Can skip steps that are already done

## Troubleshooting

### Can't connect to Proxmox

Check:
- Proxmox IP is correct in config
- SSH is enabled on Proxmox
- SSH keys are configured or password auth enabled
- Firewall allows SSH

### SSH key not found

```bash
ssh-keygen -t rsa -b 4096
# Update SSH_PUBLIC_KEY_PATH in config
```

### NFS mount fails

Check:
- NAS is reachable: `ping <nas-ip>`
- NFS share name matches NAS config
- NFS is enabled on NAS

### Want to re-run specific steps

The script is idempotent - safe to run multiple times. It checks if resources exist before creating them.

### Debug remote execution

If deployment fails, remote files are preserved:

```bash
ssh root@<proxmox-ip>
cd /tmp/proxmox-dr-*
sudo ./run-setup.sh
```

## Customization

### Adding Custom Steps

1. Create new lib file: `lib/85-my-custom-step.sh`
2. Add functions with proper logging
3. Call from `run-setup.sh` main() function
4. Script auto-sources all lib/*.sh files

### Changing Defaults

Edit constants in `lib/00-constants.sh`

### Skipping Steps

Set in config:

```bash
DEPLOY_CONTROL_VM_STACK="false"  # Skip Docker Compose
BACKUP_TERRAFORM_STATE="false"   # Skip backup setup
```

## What Gets Created

- **Proxmox Configuration:** Repositories, SSH keys, network bridges, NFS mounts
- **VM Template (ID 9000):** Ubuntu 24.04 cloud-init template
- **Control VM (ID 100):** VM with IaC tools at configured IP
- **Docker Services:** MkDocs, Portainer, AWX, Vault, Registry
- **Cron Jobs:** Daily Terraform state backup

## Benefits

✅ **Zero interaction** - One command, full automation
✅ **Modular code** - 12 focused library files
✅ **No magic strings** - All constants defined
✅ **Fail fast** - Clear errors, easy debugging
✅ **Idempotent** - Safe to re-run
✅ **Clean architecture** - Easy to maintain and extend

## Full Documentation

See [docs/disaster-recovery/proxmox-dr.md](../docs/disaster-recovery/proxmox-dr.md) for complete documentation.

## License

MIT
