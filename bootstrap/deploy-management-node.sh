#!/bin/bash
# Deploy Management Node to Proxmox
# This script runs from your LOCAL machine and deploys the management node to Proxmox

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${BLUE}[ℹ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    print_error "Configuration file .env not found!"
    print_info "Copy .env.example to .env and configure it:"
    print_info "  cp .env.example .env"
    print_info "  nano .env"
    exit 1
fi

source "$SCRIPT_DIR/.env"

# Validate required variables
REQUIRED_VARS=(
    "PROXMOX_HOST"
    "PROXMOX_USER"
    "PROXMOX_PASSWORD"
    "MGMT_NODE_VMID"
    "MGMT_NODE_NAME"
    "MGMT_NODE_IP"
    "MGMT_NODE_GATEWAY"
    "MGMT_NODE_NETMASK"
    "MGMT_NODE_CORES"
    "MGMT_NODE_MEMORY"
    "MGMT_NODE_DISK_SIZE"
    "BRIDGE"
    "DNS_SERVER"
    "STORAGE_POOL"
    "TEMPLATE_VMID"
    "TEMPLATE_NAME"
    "SSH_PUBLIC_KEY"
    "SSH_USER"
    "GITHUB_REPO"
    "GITHUB_BRANCH"
    "UBUNTU_IMAGE_URL"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable $var is not set in .env"
        exit 1
    fi
done

print_info "================================================"
print_info "  Management Node Deployment"
print_info "================================================"
print_info "Proxmox Host: $PROXMOX_HOST"
print_info "Management Node VM ID: $MGMT_NODE_VMID"
print_info "Management Node IP: $MGMT_NODE_IP"
print_info "================================================"
echo ""

# Test SSH connection to Proxmox
print_status "Testing connection to Proxmox..."
if ! sshpass -p "$PROXMOX_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "${PROXMOX_USER}@${PROXMOX_HOST}" "echo 'Connection successful'" > /dev/null 2>&1; then
    print_error "Cannot connect to Proxmox at $PROXMOX_HOST"
    print_info "Make sure sshpass is installed: brew install sshpass (macOS) or apt install sshpass (Linux)"
    exit 1
fi
print_status "Connected to Proxmox"

# Create temporary script to run on Proxmox
REMOTE_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -e

# Import variables
MGMT_NODE_VMID="{{MGMT_NODE_VMID}}"
MGMT_NODE_NAME="{{MGMT_NODE_NAME}}"
MGMT_NODE_IP="{{MGMT_NODE_IP}}"
MGMT_NODE_GATEWAY="{{MGMT_NODE_GATEWAY}}"
MGMT_NODE_VLAN="{{MGMT_NODE_VLAN}}"
MGMT_NODE_NETMASK="{{MGMT_NODE_NETMASK}}"
MGMT_NODE_CORES="{{MGMT_NODE_CORES}}"
MGMT_NODE_MEMORY="{{MGMT_NODE_MEMORY}}"
MGMT_NODE_DISK_SIZE="{{MGMT_NODE_DISK_SIZE}}"
DNS_SERVER="{{DNS_SERVER}}"
BRIDGE="{{BRIDGE}}"
STORAGE_POOL="{{STORAGE_POOL}}"
TEMPLATE_VMID="{{TEMPLATE_VMID}}"
TEMPLATE_NAME="{{TEMPLATE_NAME}}"
SSH_PUBLIC_KEY="{{SSH_PUBLIC_KEY}}"
SSH_USER="{{SSH_USER}}"
UBUNTU_IMAGE_URL="{{UBUNTU_IMAGE_URL}}"

echo "[1/6] Downloading Ubuntu cloud image..."
if [ ! -f /tmp/ubuntu-cloud.img ]; then
    wget -q --show-progress "${UBUNTU_IMAGE_URL}" -O /tmp/ubuntu-cloud.img
else
    echo "Cloud image already exists, skipping download"
fi

echo "[2/6] Creating VM template (ID ${TEMPLATE_VMID})..."
if qm status ${TEMPLATE_VMID} >/dev/null 2>&1; then
    echo "Template VM ${TEMPLATE_VMID} already exists, skipping creation"
else
    qm create ${TEMPLATE_VMID} \
        --name ${TEMPLATE_NAME} \
        --memory 2048 \
        --cores 2 \
        --net0 virtio,bridge=${BRIDGE}
    
    qm importdisk ${TEMPLATE_VMID} /tmp/ubuntu-cloud.img ${STORAGE_POOL}
    qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${STORAGE_POOL}:vm-${TEMPLATE_VMID}-disk-0
    qm set ${TEMPLATE_VMID} --boot c --bootdisk scsi0
    qm set ${TEMPLATE_VMID} --ide2 ${STORAGE_POOL}:cloudinit
    qm set ${TEMPLATE_VMID} --serial0 socket --vga serial0
    qm set ${TEMPLATE_VMID} --agent enabled=1
    qm template ${TEMPLATE_VMID}
    echo "Template created successfully"
fi

echo "[3/6] Checking for existing management-node VM (ID ${MGMT_NODE_VMID})..."
if qm status ${MGMT_NODE_VMID} >/dev/null 2>&1; then
    echo "Management node (VM ${MGMT_NODE_VMID}) already exists"
    read -p "Delete and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        qm stop ${MGMT_NODE_VMID} || true
        sleep 2
        qm destroy ${MGMT_NODE_VMID}
        echo "Deleted VM ${MGMT_NODE_VMID}"
    else
        echo "Keeping existing VM ${MGMT_NODE_VMID}"
        exit 0
    fi
fi

echo "[4/6] Creating management-node VM (ID ${MGMT_NODE_VMID})..."
qm clone ${TEMPLATE_VMID} ${MGMT_NODE_VMID} --name ${MGMT_NODE_NAME} --full

# Resize disk
qm resize ${MGMT_NODE_VMID} scsi0 ${MGMT_NODE_DISK_SIZE}

# Configure VM
qm set ${MGMT_NODE_VMID} --memory ${MGMT_NODE_MEMORY} --cores ${MGMT_NODE_CORES}
qm set ${MGMT_NODE_VMID} --ipconfig0 ip=${MGMT_NODE_IP}/${MGMT_NODE_NETMASK},gw=${MGMT_NODE_GATEWAY}
qm set ${MGMT_NODE_VMID} --nameserver ${DNS_SERVER}
qm set ${MGMT_NODE_VMID} --searchdomain local
qm set ${MGMT_NODE_VMID} --sshkeys <(echo "${SSH_PUBLIC_KEY}")
qm set ${MGMT_NODE_VMID} --ciuser ${SSH_USER}

# Set VLAN if specified
if [ -n "$MGMT_NODE_VLAN" ] && [ "$MGMT_NODE_VLAN" != "0" ]; then
    qm set ${MGMT_NODE_VMID} --net0 virtio,bridge=${BRIDGE},tag=${MGMT_NODE_VLAN}
fi

echo "[5/6] Starting management-node..."
qm start ${MGMT_NODE_VMID}

echo "[6/6] Waiting for VM to boot..."
sleep 30

# Wait for SSH to be ready
for i in {1..30}; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 ${SSH_USER}@${MGMT_NODE_IP} "echo 'VM is ready'" >/dev/null 2>&1; then
        echo "VM is ready!"
        break
    fi
    echo "Waiting for SSH... ($i/30)"
    sleep 5
done

echo "Management node VM created successfully!"
echo "IP Address: ${MGMT_NODE_IP}"
EOF
)

# Replace variables in script
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_VMID\}\}/$MGMT_NODE_VMID}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_NAME\}\}/$MGMT_NODE_NAME}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_IP\}\}/$MGMT_NODE_IP}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_GATEWAY\}\}/$MGMT_NODE_GATEWAY}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_VLAN\}\}/$MGMT_NODE_VLAN}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_NETMASK\}\}/$MGMT_NODE_NETMASK}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_CORES\}\}/$MGMT_NODE_CORES}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_MEMORY\}\}/$MGMT_NODE_MEMORY}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{MGMT_NODE_DISK_SIZE\}\}/$MGMT_NODE_DISK_SIZE}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{DNS_SERVER\}\}/$DNS_SERVER}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{BRIDGE\}\}/$BRIDGE}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{STORAGE_POOL\}\}/$STORAGE_POOL}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{TEMPLATE_VMID\}\}/$TEMPLATE_VMID}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{TEMPLATE_NAME\}\}/$TEMPLATE_NAME}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{SSH_PUBLIC_KEY\}\}/$SSH_PUBLIC_KEY}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{SSH_USER\}\}/$SSH_USER}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//\{\{UBUNTU_IMAGE_URL\}\}/$UBUNTU_IMAGE_URL}"

# Execute script on Proxmox
print_status "Deploying management node on Proxmox..."
sshpass -p "$PROXMOX_PASSWORD" ssh -o StrictHostKeyChecking=no \
    "${PROXMOX_USER}@${PROXMOX_HOST}" "bash -s" << EOF
$REMOTE_SCRIPT
EOF

print_status "VM deployed successfully!"
echo ""

# Install tools on management node
print_status "Installing management tools on VM..."
print_info "This may take 5-10 minutes..."

ssh -o StrictHostKeyChecking=no ${SSH_USER}@${MGMT_NODE_IP} 'bash -s' << 'TOOLS_INSTALL'
set -e

echo "Installing base packages..."
sudo apt update -qq
sudo apt install -y -qq git curl wget software-properties-common

echo "Installing Terraform..."
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update -qq
sudo apt install -y -qq terraform

echo "Installing Packer..."
sudo apt install -y -qq packer

echo "Installing Ansible..."
sudo apt install -y -qq ansible python3-pip

echo "Installing Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh > /dev/null
sudo usermod -aG docker $USER

echo "Installing MkDocs..."
sudo pip3 install --quiet mkdocs mkdocs-material

echo "All tools installed successfully!"
TOOLS_INSTALL

print_status "Tools installed successfully!"
echo ""

# Clone repository
print_status "Cloning homelab-iac repository..."
ssh -o StrictHostKeyChecking=no ${SSH_USER}@${MGMT_NODE_IP} << EOF
if [ -d ~/homelab-iac ]; then
    echo "Repository already exists, pulling latest changes..."
    cd ~/homelab-iac
    git pull
else
    git clone ${GITHUB_REPO} ~/homelab-iac
fi
cd ~/homelab-iac
git checkout ${GITHUB_BRANCH}
EOF

print_status "Repository cloned successfully!"
echo ""

print_info "================================================"
print_info "  Management Node Deployment Complete!"
print_info "================================================"
print_info "VM ID: ${MGMT_NODE_VMID}"
print_info "VM Name: ${MGMT_NODE_NAME}"
print_info "IP Address: ${MGMT_NODE_IP}"
print_info "Username: ${SSH_USER}"
print_info "Repository: ~/homelab-iac"
print_info ""
print_info "Connect to the management node:"
print_info "  ssh ${SSH_USER}@${MGMT_NODE_IP}"
print_info ""
print_info "Next steps:"
print_info "  1. SSH into the management node"
print_info "  2. Configure Terraform and Ansible"
print_info "  3. Deploy your infrastructure"
print_info "================================================"
