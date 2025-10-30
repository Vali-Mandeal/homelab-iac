#!/usr/bin/env bash
# ==============================================================================
# Control VM Health Check Script
# ==============================================================================
# Purpose: Verify all services are running and healthy
# Usage: ./health-check.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly COMPOSE_DIR="/opt/homelab-iac/control-vm/docker-compose"
readonly BACKUP_MOUNT="/mnt/backup"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Health check results
declare -i TOTAL_CHECKS=0
declare -i PASSED_CHECKS=0
declare -i FAILED_CHECKS=0

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_CHECKS++))
    ((TOTAL_CHECKS++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_CHECKS++))
    ((TOTAL_CHECKS++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

check_service_running() {
    local service_name="$1"
    local container_name="$2"

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_pass "Service running: ${service_name}"
        return 0
    else
        log_fail "Service not running: ${service_name}"
        return 1
    fi
}

check_service_healthy() {
    local service_name="$1"
    local container_name="$2"

    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "${container_name}" 2>/dev/null || echo "none")

    if [[ "${health_status}" == "healthy" ]]; then
        log_pass "Service healthy: ${service_name}"
        return 0
    elif [[ "${health_status}" == "none" ]]; then
        log_warn "No health check defined for: ${service_name}"
        ((TOTAL_CHECKS++))
        return 0
    else
        log_fail "Service unhealthy (${health_status}): ${service_name}"
        return 1
    fi
}

check_port_listening() {
    local service_name="$1"
    local port="$2"

    if nc -z localhost "${port}" 2>/dev/null; then
        log_pass "Port listening: ${service_name} (${port})"
        return 0
    else
        log_fail "Port not listening: ${service_name} (${port})"
        return 1
    fi
}

check_http_endpoint() {
    local service_name="$1"
    local url="$2"
    local expected_code="${3:-200}"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "${expected_code}" ]] || [[ "${http_code}" =~ ^2[0-9]{2}$ ]]; then
        log_pass "HTTP endpoint responding: ${service_name} (${http_code})"
        return 0
    else
        log_fail "HTTP endpoint failed: ${service_name} (${http_code})"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# System Checks
# ------------------------------------------------------------------------------

check_system() {
    log_info "Running system checks..."

    # Disk space
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ ${disk_usage} -lt 80 ]]; then
        log_pass "Disk space: ${disk_usage}% used"
    else
        log_fail "Disk space critical: ${disk_usage}% used"
    fi

    # Memory
    local mem_usage
    mem_usage=$(free | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}')
    if [[ ${mem_usage} -lt 90 ]]; then
        log_pass "Memory usage: ${mem_usage}%"
    else
        log_warn "Memory usage high: ${mem_usage}%"
        ((TOTAL_CHECKS++))
    fi

    # Backup mount
    if mountpoint -q "${BACKUP_MOUNT}"; then
        log_pass "Backup mount available: ${BACKUP_MOUNT}"
    else
        log_fail "Backup mount not available: ${BACKUP_MOUNT}"
    fi

    echo ""
}

# ------------------------------------------------------------------------------
# Docker Checks
# ------------------------------------------------------------------------------

check_docker() {
    log_info "Running Docker checks..."

    # Docker daemon
    if systemctl is-active --quiet docker; then
        log_pass "Docker daemon running"
    else
        log_fail "Docker daemon not running"
    fi

    # Docker Compose
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
            log_pass "Docker Compose available"
        else
            log_fail "Docker Compose not available"
        fi
    fi

    echo ""
}

# ------------------------------------------------------------------------------
# Service Checks
# ------------------------------------------------------------------------------

check_services() {
    log_info "Running service checks..."

    cd "${COMPOSE_DIR}" || {
        log_fail "Compose directory not found: ${COMPOSE_DIR}"
        return 1
    }

    # Check all services
    local services=(
        "MkDocs:mkdocs"
        "Portainer:portainer"
        "Vault:vault"
        "Registry:registry"
        "AWX PostgreSQL:awx-postgres"
        "AWX Redis:awx-redis"
        "AWX Web:awx-web"
        "AWX Task:awx-task"
    )

    for service in "${services[@]}"; do
        local name="${service%%:*}"
        local container="${service##*:}"
        check_service_running "${name}" "${container}"
        check_service_healthy "${name}" "${container}"
    done

    echo ""
}

# ------------------------------------------------------------------------------
# Network Checks
# ------------------------------------------------------------------------------

check_network() {
    log_info "Running network checks..."

    # Port checks
    check_port_listening "MkDocs" 8000
    check_port_listening "Portainer" 9000
    check_port_listening "Vault" 8200
    check_port_listening "Registry" 5000
    check_port_listening "AWX" 8080

    echo ""
}

# ------------------------------------------------------------------------------
# HTTP Endpoint Checks
# ------------------------------------------------------------------------------

check_endpoints() {
    log_info "Running HTTP endpoint checks..."

    # Wait a moment for services to respond
    sleep 2

    check_http_endpoint "MkDocs" "http://localhost:8000" "200"
    check_http_endpoint "Portainer" "http://localhost:9000" "200"
    check_http_endpoint "Vault UI" "http://localhost:8200/ui" "200"
    check_http_endpoint "Registry" "http://localhost:5000/v2/" "200"
    check_http_endpoint "AWX" "http://localhost:8080/api/v2/ping/" "200"

    echo ""
}

# ------------------------------------------------------------------------------
# Tools Checks
# ------------------------------------------------------------------------------

check_tools() {
    log_info "Running IaC tools checks..."

    # Terraform
    if command -v terraform &> /dev/null; then
        log_pass "Terraform installed: $(terraform version | head -n1 | awk '{print $2}')"
    else
        log_fail "Terraform not installed"
    fi

    # Ansible
    if command -v ansible &> /dev/null; then
        log_pass "Ansible installed: $(ansible --version | head -n1 | awk '{print $3}')"
    else
        log_fail "Ansible not installed"
    fi

    # Packer
    if command -v packer &> /dev/null; then
        log_pass "Packer installed: $(packer version | awk '{print $2}')"
    else
        log_fail "Packer not installed"
    fi

    # Git
    if command -v git &> /dev/null; then
        log_pass "Git installed: $(git --version | awk '{print $3}')"
    else
        log_fail "Git not installed"
    fi

    echo ""
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

show_summary() {
    echo ""
    echo "========================================================================"
    echo "Health Check Summary"
    echo "========================================================================"
    echo ""
    echo "Total Checks:  ${TOTAL_CHECKS}"
    echo -e "Passed:        ${GREEN}${PASSED_CHECKS}${NC}"
    echo -e "Failed:        ${RED}${FAILED_CHECKS}${NC}"
    echo ""

    local pass_percentage=0
    if [[ ${TOTAL_CHECKS} -gt 0 ]]; then
        pass_percentage=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    fi

    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        echo -e "${GREEN}✓ All checks passed! Control VM is healthy.${NC}"
        echo ""
        return 0
    elif [[ ${pass_percentage} -ge 80 ]]; then
        echo -e "${YELLOW}⚠ Most checks passed but some issues detected (${pass_percentage}% success)${NC}"
        echo -e "${YELLOW}  Review failed checks above${NC}"
        echo ""
        return 1
    else
        echo -e "${RED}✗ Critical issues detected (${pass_percentage}% success)${NC}"
        echo -e "${RED}  Immediate attention required${NC}"
        echo ""
        return 2
    fi
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================================================"
    echo "Control VM Health Check"
    echo "========================================================================"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Hostname:  $(hostname)"
    echo "IP:        $(hostname -I | awk '{print $1}')"
    echo ""

    check_system
    check_docker
    check_services
    check_network
    check_endpoints
    check_tools

    show_summary
}

# Run main function
main "$@"
