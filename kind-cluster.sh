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
export KIND_VERSION="${KIND_VERSION:-v0.29.0}"
export KIND_CLOUD_PROVIDER_VERSION="${KIND_CLOUD_PROVIDER_VERSION:-v0.6.0}"

# Node Images
KIND_LATEST_DEFAULT_IMAGE="kindest/node:v1.33.1@sha256:050072256b9a903bd914c0b2866828150cb229cea0efe5892e2b644d5dd3b34f"
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

    --force                     Force recreate if cluster exists
    --configure-insecure        Configure container runtime for insecure registry
    --debug                     Enable debug output

Environment Variables:
    All options can be set via environment variables:
    KIND_VERSION, KIND_NODE_IMAGE, KIND_CLUSTER_NAME,
    CONTROL_NODES, WORKER_NODES, IP_FAMILY, DOCKER_CMD,
    REGISTRY_NAME, REGISTRY_PORT, REGISTRY_IMAGE,
    ENABLE_REGISTRY, ENABLE_CLOUD_PROVIDER, DEBUG

Examples:
    # Create cluster with defaults
    $(basename "$0") create

    # Create cluster with custom configuration
    $(basename "$0") create --name my-cluster --workers 5 --control-planes 3

    # Create cluster with IPv6
    $(basename "$0") create --ip-family ipv6

    # Create cluster using Podman
    DOCKER_CMD=podman $(basename "$0") create

    # Delete cluster
    $(basename "$0") delete --name my-cluster

    # Check status
    $(basename "$0") status
EOF
}

parse_args() {
    local command="${1:-create}"

    # Handle help as first argument
    if [[ "${command}" == "help" ]] || [[ "${command}" == "--help" ]] || [[ "${command}" == "-h" ]]; then
        print_usage
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
                shift 2
                ;;
            --workers)
                WORKER_NODES="$2"
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

    # Export parsed values
    export KIND_CLUSTER_NAME CONTROL_NODES WORKER_NODES KIND_NODE_IMAGE
    export IP_FAMILY DOCKER_CMD REGISTRY_NAME REGISTRY_PORT
    export ENABLE_REGISTRY ENABLE_CLOUD_PROVIDER ENABLE_NODE_LABELS
    export ENABLE_ADMIN_BINDING FORCE_RECREATE CONFIGURE_INSECURE_REGISTRY DEBUG

    echo "${command}"
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

    # Print configuration
    info "Configuration:"
    info "  Cluster Name:     ${KIND_CLUSTER_NAME}"
    info "  Control Planes:   ${CONTROL_NODES}"
    info "  Worker Nodes:     ${WORKER_NODES}"
    info "  IP Family:        ${IP_FAMILY}"
    info "  Container Runtime: ${DOCKER_CMD}"
    info "  Registry:         ${ENABLE_REGISTRY} (${REGISTRY_NAME}:${REGISTRY_PORT})"
    info "  Cloud Provider:   ${ENABLE_CLOUD_PROVIDER}"
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

    # Configure insecure registry if requested
    if [[ "${CONFIGURE_INSECURE_REGISTRY}" == "true" ]] && [[ "${ENABLE_REGISTRY}" == "true" ]]; then
        if [[ "${IP_FAMILY}" == "ipv6" ]]; then
            configure_insecure_registry "" "${IPV6_ULA_PREFIX}" "${IPV6_REGISTRY_DNS}"
        else
            configure_insecure_registry "${host_ip}:${REGISTRY_PORT}"
        fi
    fi

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
            # Configure nodes to use registry
            registry_configure_nodes "${KIND_CLUSTER_NAME}" "${REGISTRY_NAME}" "${REGISTRY_PORT}" "${host_ip}"
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
    fi
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Handle help as early exit (before parse_args captures stdout)
    if [[ "${1:-}" == "help" ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        print_usage
        exit 0
    fi

    # Parse arguments and get command
    local command
    command=$(parse_args "$@")

    # Execute command
    case "${command}" in
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
            err "Unknown command: ${command}"
            print_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
