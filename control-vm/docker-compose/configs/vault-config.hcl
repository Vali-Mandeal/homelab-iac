# ==============================================================================
# HashiCorp Vault Configuration - Production Mode
# ==============================================================================
# Location: /opt/homelab-iac/control-vm/docker-compose/configs/vault-config.hcl
# Purpose: Production-ready Vault configuration with file-based storage
# ==============================================================================

# Storage backend - File-based (simple, reliable for single-node deployment)
storage "file" {
  path = "/vault/data"
}

# Listener - HTTP (TLS termination can be added later via reverse proxy)
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = 1

  # Optional: Enable request logging for troubleshooting
  # telemetry {
  #   unauthenticated_metrics_access = false
  # }
}

# API address - How Vault advertises itself
api_addr = "http://${CONTROL_VM_IP}:8200"

# UI - Enable web interface
ui = true

# Disable mlock requirement in containerized environment
disable_mlock = true

# Log level - info is production default (debug for troubleshooting)
log_level = "info"

# Default lease TTL - 768 hours (32 days)
default_lease_ttl = "768h"

# Maximum lease TTL - 8760 hours (365 days)
max_lease_ttl = "8760h"
