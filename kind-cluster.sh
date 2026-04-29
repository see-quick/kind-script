#!/usr/bin/env bash
# =============================================================================
# kind-cluster.sh - Idempotent Kind cluster management script
# =============================================================================
#
# A robust, idempotent script for managing Kind (Kubernetes in Docker) clusters
# with local container registry support.
#
# Features:
#   - Fully idempotent - safe to run multiple times
#   - Supports Docker and Podman
#   - IPv4 and IPv6 networking
#   - Local container registry
#   - Cloud provider kind for LoadBalancer support
#   - Configurable via environment variables or CLI flags
#
# Usage:
#   ./kind-cluster.sh [command] [options]
#
# Commands:
#   create    Create cluster and all supporting infrastructure
#   delete    Delete cluster and cleanup
#   status    Show cluster status
#   help      Show this help message
#
# =============================================================================

set -euo pipefail

# Version
readonly VERSION="1.0.0"

# =============================================================================
# Script Location and Library Loading
# =============================================================================

# Resolve script directory (handle symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Source library modules
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=./lib/cluster.sh
source "${SCRIPT_DIR}/lib/cluster.sh"
# shellcheck source=./lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"
# shellcheck source=./lib/network.sh
source "${SCRIPT_DIR}/lib/network.sh"

# =============================================================================
# Default Configuration
# =============================================================================

# Kind Configuration
export KIND_VERSION="${KIND_VERSION:-v0.31.0}"
export KIND_CLOUD_PROVIDER_VERSION="${KIND_CLOUD_PROVIDER_VERSION:-v0.6.0}"

# Node Images
KIND_LATEST_DEFAULT_IMAGE="kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f"
KIND_OLDEST_DEFAULT_IMAGE="kindest/node:v1.27.16@sha256:2d21a61643eafc439905e18705b8186f3296384750a835ad7a005dceb9546d20"
export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-${KIND_LATEST_DEFAULT_IMAGE}}"

# Handle special image names
if [[ "${KIND_NODE_IMAGE}" == "latest" ]]; then
    KIND_NODE_IMAGE="${KIND_LATEST_DEFAULT_IMAGE}"
fi
if [[ "${KIND_NODE_IMAGE}" == "oldest" ]]; then
    KIND_NODE_IMAGE="${KIND_OLDEST_DEFAULT_IMAGE}"
fi

# Cluster Configuration
export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind-cluster}"
export CONTROL_NODES="${CONTROL_NODES:-1}"
export WORKER_NODES="${WORKER_NODES:-3}"
export IP_FAMILY="${IP_FAMILY:-ipv4}"

# Container Runtime
export DOCKER_CMD="${DOCKER_CMD:-docker}"

# Registry Configuration
export REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
export REGISTRY_PORT="${REGISTRY_PORT:-5001}"
export REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"
export ENABLE_REGISTRY="${ENABLE_REGISTRY:-true}"

# Network Configuration
export NETWORK_NAME="${NETWORK_NAME:-kind}"
export IPV6_ULA_PREFIX="${IPV6_ULA_PREFIX:-fd01:2345:6789}"
export IPV6_REGISTRY_DNS="${IPV6_REGISTRY_DNS:-myregistry.local}"

# Feature Flags
export ENABLE_CLOUD_PROVIDER="${ENABLE_CLOUD_PROVIDER:-true}"
export ENABLE_NODE_LABELS="${ENABLE_NODE_LABELS:-true}"
export ENABLE_ADMIN_BINDING="${ENABLE_ADMIN_BINDING:-true}"
export FORCE_RECREATE="${FORCE_RECREATE:-false}"
export CONFIGURE_INSECURE_REGISTRY="${CONFIGURE_INSECURE_REGISTRY:-false}"

# Multi-Zone Configuration
export ZONES="${ZONES:-0}"
export NODES_PER_ZONE="${NODES_PER_ZONE:-1}"

# Debug mode
export DEBUG="${DEBUG:-false}"

# =============================================================================
# CLI Argument Parsing
# =============================================================================

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
    create          Create Kind cluster with all components (default)
    delete          Delete Kind cluster and cleanup
    status          Show cluster and component status
    install-deps    Install kind and kubectl binaries
    version         Show version information
    help            Show this help message

Options:
    --name NAME                 Cluster name (default: ${KIND_CLUSTER_NAME})
    --control-planes N          Number of control plane nodes (default: ${CONTROL_NODES})
    --workers N                 Number of worker nodes (default: ${WORKER_NODES})
    --image IMAGE               Kind node image (default: latest)
                                Special values: 'latest', 'oldest'
    --ip-family FAMILY          IP family: ipv4, ipv6, dual (default: ${IP_FAMILY})
    --docker-cmd CMD            Container runtime: docker, podman (default: ${DOCKER_CMD})

    --registry-name NAME        Registry container name (default: ${REGISTRY_NAME})
    --registry-port PORT        Registry port (default: ${REGISTRY_PORT})
    --no-registry               Disable local registry
    --no-cloud-provider         Disable cloud-provider-kind (LoadBalancer support)
    --no-node-labels            Skip node labeling
    --no-admin-binding          Skip cluster admin binding
    --zones N                   Number of availability zones to simulate
    --nodes-per-zone N          Worker nodes per zone (default: 1)

    --force                     Force recreate if cluster exists
    --configure-insecure        Configure container runtime for insecure registry
    --debug                     Enable debug output

Environment Variables:
    All options can be set via environment variables:
    KIND_VERSION, KIND_NODE_IMAGE, KIND_CLUSTER_NAME,
    CONTROL_NODES, WORKER_NODES, IP_FAMILY, DOCKER_CMD,
    REGISTRY_NAME, REGISTRY_PORT, REGISTRY_IMAGE,
    ENABLE_REGISTRY, ENABLE_CLOUD_PROVIDER, DEBUG,
    ZONES, NODES_PER_ZONE

Examples:
    # Create cluster with defaults
    $(basename "$0") create

    # Create cluster with custom configuration
    $(basename "$0") create --name my-cluster --workers 5 --control-planes 3

    # Create cluster with IPv6
    $(basename "$0") create --ip-family ipv6

    # Create cluster using Podman
    DOCKER_CMD=podman $(basename "$0") create

    # Multi-zone cluster: 3 zones, 2 workers per zone
    $(basename "$0") create --zones 3 --nodes-per-zone 2

    # Delete cluster
    $(basename "$0") delete --name my-cluster

    # Check status
    $(basename "$0") status
EOF
}

print_version() {
    echo "kind-cluster.sh version ${VERSION}"
}

parse_args() {
    local command="${1:-create}"

    # Handle help as first argument
    if [[ "${command}" == "help" ]] || [[ "${command}" == "--help" ]] || [[ "${command}" == "-h" ]]; then
        print_usage
        exit 0
    fi

    # Handle version as first argument
    if [[ "${command}" == "version" ]] || [[ "${command}" == "--version" ]] || [[ "${command}" == "-v" ]]; then
        print_version
        exit 0
    fi

    # Shift past the command if it's a known command
    case "${command}" in
        create|delete|status|install-deps)
            shift || true
            ;;
        --*)
            # It's an option, not a command - default to create
            command="create"
            ;;
        *)
            # Unknown command
            err "Unknown command: ${command}"
            print_usage
            exit 1
            ;;
    esac

    # Parse remaining options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                KIND_CLUSTER_NAME="$2"
                shift 2
                ;;
            --control-planes)
                CONTROL_NODES="$2"
                _CONTROL_PLANES_EXPLICIT=true
                shift 2
                ;;
            --workers)
                WORKER_NODES="$2"
                _WORKERS_EXPLICIT=true
                shift 2
                ;;
            --image)
                KIND_NODE_IMAGE="$2"
                if [[ "${KIND_NODE_IMAGE}" == "latest" ]]; then
                    KIND_NODE_IMAGE="${KIND_LATEST_DEFAULT_IMAGE}"
                elif [[ "${KIND_NODE_IMAGE}" == "oldest" ]]; then
                    KIND_NODE_IMAGE="${KIND_OLDEST_DEFAULT_IMAGE}"
                fi
                shift 2
                ;;
            --ip-family)
                IP_FAMILY="$2"
                shift 2
                ;;
            --docker-cmd)
                DOCKER_CMD="$2"
                shift 2
                ;;
            --registry-name)
                REGISTRY_NAME="$2"
                shift 2
                ;;
            --registry-port)
                REGISTRY_PORT="$2"
                shift 2
                ;;
            --no-registry)
                ENABLE_REGISTRY="false"
                shift
                ;;
            --no-cloud-provider)
                ENABLE_CLOUD_PROVIDER="false"
                shift
                ;;
            --no-node-labels)
                ENABLE_NODE_LABELS="false"
                shift
                ;;
            --no-admin-binding)
                ENABLE_ADMIN_BINDING="false"
                shift
                ;;
            --zones)
                ZONES="$2"
                shift 2
                ;;
            --nodes-per-zone)
                NODES_PER_ZONE="$2"
                shift 2
                ;;
            --force)
                FORCE_RECREATE="true"
                shift
                ;;
            --configure-insecure)
                CONFIGURE_INSECURE_REGISTRY="true"
                shift
                ;;
            --debug)
                DEBUG="true"
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    # Set the command for the caller (don't use subshell)
    PARSED_COMMAND="${command}"
}

# =============================================================================
# Validation
# =============================================================================

validate_prerequisites() {
    section "Validating Prerequisites"

    # Check container runtime
    if ! command_exists "${DOCKER_CMD}"; then
        err_and_exit "Container runtime '${DOCKER_CMD}' not found. Please install Docker or Podman."
    fi
    info "Container runtime: ${DOCKER_CMD} $(${DOCKER_CMD} --version 2>/dev/null | head -1)"

    # Check if container runtime is running
    if ! ${DOCKER_CMD} info >/dev/null 2>&1; then
        err_and_exit "${DOCKER_CMD} is not running or not accessible"
    fi

    # Check kind
    if ! kind_is_installed; then
        warn "Kind is not installed. Run '$(basename "$0") install-deps' to install."
    else
        info "Kind: $(kind_get_version)"
    fi

    # Check kubectl
    if ! kubectl_is_installed; then
        warn "kubectl is not installed. Run '$(basename "$0") install-deps' to install."
    else
        info "kubectl: $(kubectl_get_version)"
    fi

    # Validate IP family
    case "${IP_FAMILY}" in
        ipv4|ipv6|dual)
            ;;
        *)
            err_and_exit "Invalid IP family: ${IP_FAMILY}. Must be: ipv4, ipv6, or dual"
            ;;
    esac

    # Podman IPv6 warning
    if [[ "${DOCKER_CMD}" == "podman" ]] && [[ "${IP_FAMILY}" != "ipv4" ]]; then
        warn "IPv6/dual stack with Podman has limited support in this script"
    fi

    # Check IPv6 system support if needed
    if [[ "${IP_FAMILY}" == "ipv6" ]] || [[ "${IP_FAMILY}" == "dual" ]]; then
        if [[ "${OS}" == "linux" ]] && ! ipv6_is_enabled; then
            err_and_exit "IPv6 is disabled on this system. Enable it with: sysctl net.ipv6.conf.all.disable_ipv6=0"
        fi
    fi

    # Validate zone configuration
    if [[ "${ZONES}" -lt 0 ]]; then
        err_and_exit "Invalid zones value: ${ZONES}. Must be >= 0"
    fi
    if [[ "${ZONES}" -gt 0 ]] && [[ "${NODES_PER_ZONE}" -lt 1 ]]; then
        err_and_exit "Invalid nodes-per-zone value: ${NODES_PER_ZONE}. Must be >= 1"
    fi

    # Error if --nodes-per-zone is set but --zones is not
    if [[ "${NODES_PER_ZONE}" -ne 1 ]] && [[ "${ZONES}" -eq 0 ]]; then
        err_and_exit "--nodes-per-zone requires --zones to be set"
    fi

    success "Prerequisites validated"
}

# =============================================================================
# Main Commands
# =============================================================================

cmd_install_deps() {
    section "Installing Dependencies"

    kind_install "${KIND_VERSION}"
    kubectl_install

    success "Dependencies installed"
}

cmd_create() {
    section "Creating Kind Cluster Environment"

    # Multi-zone mode: override control-plane and worker counts
    if [[ "${ZONES}" -gt 0 ]]; then
        # Warn if --workers or --control-planes were explicitly set on CLI
        if [[ "${_CONTROL_PLANES_EXPLICIT:-false}" == "true" ]]; then
            warn "--control-planes is ignored when --zones is specified (using ${ZONES} control planes)"
        fi
        if [[ "${_WORKERS_EXPLICIT:-false}" == "true" ]]; then
            warn "--workers is ignored when --zones is specified (using $((ZONES * NODES_PER_ZONE)) workers)"
        fi
        CONTROL_NODES="${ZONES}"
        WORKER_NODES=$(( ZONES * NODES_PER_ZONE ))
    fi

    # Print configuration
    info "Configuration:"
    info "  Cluster Name:     ${KIND_CLUSTER_NAME}"
    info "  Control Planes:   ${CONTROL_NODES}"
    info "  Worker Nodes:     ${WORKER_NODES}"
    info "  IP Family:        ${IP_FAMILY}"
    info "  Container Runtime: ${DOCKER_CMD}"
    info "  Registry:         ${ENABLE_REGISTRY} (${REGISTRY_NAME}:${REGISTRY_PORT})"
    info "  Cloud Provider:   ${ENABLE_CLOUD_PROVIDER}"
    if [[ "${ZONES}" -gt 0 ]]; then
        info "  Zones:            ${ZONES}"
        info "  Nodes/Zone:       ${NODES_PER_ZONE}"
        info "  Total CPs:        ${CONTROL_NODES} (1 per zone)"
        info "  Total Workers:    ${WORKER_NODES} (${NODES_PER_ZONE} per zone)"
    fi
    echo ""

    # Validate prerequisites
    validate_prerequisites

    # Ensure kind and kubectl are installed
    if ! kind_is_installed; then
        kind_install "${KIND_VERSION}"
    fi
    if ! kubectl_is_installed; then
        kubectl_install
    fi

    # Setup kube directory
    setup_kube_directory

    # Adjust inotify limits for multi-node clusters (Linux only)
    if [[ "${CONTROL_NODES}" -gt 1 ]] || [[ "${WORKER_NODES}" -gt 2 ]]; then
        adjust_inotify_limits
    fi

    # Load iptables modules for Podman
    load_iptables_modules

    # Create network
    local enable_ipv6="false"
    if [[ "${IP_FAMILY}" == "ipv6" ]] || [[ "${IP_FAMILY}" == "dual" ]]; then
        enable_ipv6="true"
    fi
    network_create "${NETWORK_NAME}" "${enable_ipv6}"

    # Get host IP for registry
    local host_ip
    host_ip=$(get_host_ipv4)
    debug "Host IP: ${host_ip}"

    # Note: Insecure registry configuration is done on Kind nodes after cluster creation

    # Handle IPv6 specific setup
    if [[ "${IP_FAMILY}" == "ipv6" ]]; then
        # Assign IPv6 address to interface
        local primary_interface
        primary_interface=$(get_primary_interface)
        if [[ -n "${primary_interface}" ]] && [[ "${OS}" == "linux" ]]; then
            ipv6_assign_address "${IPV6_ULA_PREFIX}::1" "${primary_interface}" "64"
        fi
    fi

    # Create Kind cluster
    cluster_create

    # Create registry if enabled
    if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
        if [[ "${IP_FAMILY}" == "ipv6" ]]; then
            registry_create "${REGISTRY_NAME}" "${REGISTRY_PORT}" "${NETWORK_NAME}" "${REGISTRY_IMAGE}" "${IPV6_ULA_PREFIX}::1"
            # Add DNS entry for registry
            add_hosts_entry "${IPV6_ULA_PREFIX}::1" "${IPV6_REGISTRY_DNS}"
            # Configure nodes for IPv6 registry
            registry_configure_nodes_ipv6 "${KIND_CLUSTER_NAME}" "${IPV6_ULA_PREFIX}::1" "${IPV6_REGISTRY_DNS}"
        else
            registry_create "${REGISTRY_NAME}" "${REGISTRY_PORT}" "${NETWORK_NAME}" "${REGISTRY_IMAGE}" "${host_ip}"
            # Configure nodes to use registry (with insecure flag if requested)
            registry_configure_nodes "${KIND_CLUSTER_NAME}" "${REGISTRY_NAME}" "${REGISTRY_PORT}" "${host_ip}" "${CONFIGURE_INSECURE_REGISTRY}" "${NETWORK_NAME}"
        fi
    fi

    # Create cluster admin binding
    if [[ "${ENABLE_ADMIN_BINDING}" == "true" ]]; then
        cluster_create_admin_binding "${KIND_CLUSTER_NAME}"
    fi

    # Label nodes
    if [[ "${ENABLE_NODE_LABELS}" == "true" ]]; then
        cluster_label_nodes "${KIND_CLUSTER_NAME}"
    fi

    # Start cloud provider kind
    if [[ "${ENABLE_CLOUD_PROVIDER}" == "true" ]]; then
        cloud_provider_run "${NETWORK_NAME}" "${KIND_CLOUD_PROVIDER_VERSION}"
    fi

    # Final status
    section "Cluster Ready"
    echo ""
    info "Cluster '${KIND_CLUSTER_NAME}' is ready!"
    echo ""
    info "To use the cluster:"
    info "  kubectl cluster-info --context kind-${KIND_CLUSTER_NAME}"
    echo ""

    if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
        info "Local registry available at:"
        if [[ "${IP_FAMILY}" == "ipv6" ]]; then
            info "  ${IPV6_REGISTRY_DNS}:${REGISTRY_PORT}"
        else
            info "  ${host_ip}:${REGISTRY_PORT}"
        fi
        echo ""
        info "To push images:"
        if [[ "${IP_FAMILY}" == "ipv6" ]]; then
            info "  docker tag my-image ${IPV6_REGISTRY_DNS}:${REGISTRY_PORT}/my-image"
            info "  docker push ${IPV6_REGISTRY_DNS}:${REGISTRY_PORT}/my-image"
        else
            info "  docker tag my-image ${host_ip}:${REGISTRY_PORT}/my-image"
            info "  docker push ${host_ip}:${REGISTRY_PORT}/my-image"
        fi
    fi
}

cmd_delete() {
    section "Deleting Kind Cluster Environment"

    # Stop and remove cloud provider
    if [[ "${ENABLE_CLOUD_PROVIDER}" == "true" ]]; then
        cloud_provider_stop
    fi

    # Remove registry
    if [[ "${ENABLE_REGISTRY}" == "true" ]]; then
        registry_remove "${REGISTRY_NAME}"
    fi

    # Delete cluster
    cluster_delete "${KIND_CLUSTER_NAME}"

    # Delete network
    network_delete "${NETWORK_NAME}"

    success "Cleanup complete"
}

cmd_status() {
    section "Cluster Status"

    # Cluster status
    echo -e "${BOLD}Cluster:${NC}"
    if cluster_exists "${KIND_CLUSTER_NAME}"; then
        echo -e "  Name: ${KIND_CLUSTER_NAME}"
        if cluster_is_ready "${KIND_CLUSTER_NAME}"; then
            echo -e "  Status: ${GREEN}Ready${NC}"
        else
            echo -e "  Status: ${YELLOW}Not Ready${NC}"
        fi

        # Node count
        local nodes
        nodes=$(cluster_get_nodes "${KIND_CLUSTER_NAME}" | wc -l)
        echo -e "  Nodes: ${nodes}"
    else
        echo -e "  Status: ${RED}Not Found${NC}"
    fi
    echo ""

    # Registry status
    echo -e "${BOLD}Registry:${NC}"
    if registry_container_exists "${REGISTRY_NAME}"; then
        echo -e "  Name: ${REGISTRY_NAME}"
        if registry_is_running "${REGISTRY_NAME}"; then
            echo -e "  Status: ${GREEN}Running${NC}"
            echo -e "  Port: ${REGISTRY_PORT}"
        else
            echo -e "  Status: ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  Status: ${RED}Not Found${NC}"
    fi
    echo ""

    # Cloud provider status
    echo -e "${BOLD}Cloud Provider:${NC}"
    if cloud_provider_exists; then
        if cloud_provider_is_running; then
            echo -e "  Status: ${GREEN}Running${NC}"
        else
            echo -e "  Status: ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "  Status: ${RED}Not Found${NC}"
    fi
    echo ""

    # Network status
    echo -e "${BOLD}Network:${NC}"
    if network_exists "${NETWORK_NAME}"; then
        echo -e "  Name: ${NETWORK_NAME}"
        echo -e "  Status: ${GREEN}Exists${NC}"
        if network_has_ipv6 "${NETWORK_NAME}"; then
            echo -e "  IPv6: ${GREEN}Enabled${NC}"
        else
            echo -e "  IPv6: Disabled"
        fi
    else
        echo -e "  Status: ${RED}Not Found${NC}"
    fi
    echo ""

    # Kubernetes info if cluster is ready
    if cluster_is_ready "${KIND_CLUSTER_NAME}"; then
        echo -e "${BOLD}Kubernetes:${NC}"
        kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}" 2>/dev/null | head -3
        echo ""

        echo -e "${BOLD}Nodes:${NC}"
        kubectl get nodes --context "kind-${KIND_CLUSTER_NAME}" 2>/dev/null

        # Zone topology information
        local zone_labels
        zone_labels=$(kubectl get nodes --context "kind-${KIND_CLUSTER_NAME}" \
            -o custom-columns=NODE:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone \
            --no-headers 2>/dev/null || echo "")

        # Check if any nodes have zone labels (filter out <none>)
        if echo "${zone_labels}" | grep -qv '<none>$'; then
            echo ""
            echo -e "${BOLD}Zones:${NC}"
            # Get unique zones and list nodes per zone
            local zones
            zones=$(echo "${zone_labels}" | awk '$2 != "<none>" {print $2}' | sort -u)
            for zone in ${zones}; do
                local zone_nodes
                zone_nodes=$(echo "${zone_labels}" | awk -v z="${zone}" '$2 == z {print $1}' | tr '\n' ', ' | sed 's/,$//')
                echo -e "  ${zone}: ${zone_nodes}"
            done
        fi
    fi
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Show help when no arguments provided
    if [[ $# -eq 0 ]]; then
        print_usage
        exit 0
    fi

    # Handle help and version as early exit (before parse_args captures stdout)
    if [[ "${1:-}" == "help" ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        print_usage
        exit 0
    fi

    if [[ "${1:-}" == "version" ]] || [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
        print_version
        exit 0
    fi

    # Parse arguments (sets PARSED_COMMAND and modifies global config variables)
    parse_args "$@"

    # Execute command
    case "${PARSED_COMMAND}" in
        create)
            cmd_create
            ;;
        delete)
            cmd_delete
            ;;
        status)
            cmd_status
            ;;
        install-deps)
            cmd_install_deps
            ;;
        *)
            err "Unknown command: ${PARSED_COMMAND}"
            print_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
