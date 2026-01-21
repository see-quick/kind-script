#!/usr/bin/env bash
# =============================================================================
# registry.sh - Container registry management functions
# =============================================================================

# Prevent multiple sourcing
[[ -n "${_REGISTRY_SH_LOADED:-}" ]] && return 0
readonly _REGISTRY_SH_LOADED=1

# Source common utilities
_REGISTRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_REGISTRY_LIB_DIR}/common.sh"

# =============================================================================
# Registry Container Management
# =============================================================================

# Check if registry container exists
registry_container_exists() {
    local name="${1:-${REGISTRY_NAME}}"
    ${DOCKER_CMD} inspect "${name}" >/dev/null 2>&1
}

# Check if registry container is running
registry_is_running() {
    local name="${1:-${REGISTRY_NAME}}"
    local state
    state=$(${DOCKER_CMD} inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || echo "false")
    [[ "${state}" == "true" ]]
}

# Get registry container IP address
registry_get_ip() {
    local name="${1:-${REGISTRY_NAME}}"
    local network="${2:-${NETWORK_NAME}}"

    ${DOCKER_CMD} inspect -f "{{.NetworkSettings.Networks.${network}.IPAddress}}" "${name}" 2>/dev/null
}

# Start existing registry container
registry_start() {
    local name="${1:-${REGISTRY_NAME}}"

    if ! registry_container_exists "${name}"; then
        return 1
    fi

    if registry_is_running "${name}"; then
        debug "Registry ${name} is already running"
        return 0
    fi

    info "Starting registry container: ${name}"
    ${DOCKER_CMD} start "${name}"
}

# Stop registry container
registry_stop() {
    local name="${1:-${REGISTRY_NAME}}"

    if ! registry_is_running "${name}"; then
        debug "Registry ${name} is not running"
        return 0
    fi

    info "Stopping registry container: ${name}"
    ${DOCKER_CMD} stop "${name}"
}

# Remove registry container
registry_remove() {
    local name="${1:-${REGISTRY_NAME}}"

    if ! registry_container_exists "${name}"; then
        debug "Registry ${name} does not exist"
        return 0
    fi

    if registry_is_running "${name}"; then
        registry_stop "${name}"
    fi

    info "Removing registry container: ${name}"
    ${DOCKER_CMD} rm "${name}"
}

# Create and start registry container (idempotent)
# Args: name port network registry_image host_ip
registry_create() {
    local name="${1:-${REGISTRY_NAME}}"
    local port="${2:-${REGISTRY_PORT}}"
    local network="${3:-${NETWORK_NAME}}"
    local image="${4:-${REGISTRY_IMAGE}}"
    local host_ip="${5:-}"

    # If already running, nothing to do
    if registry_is_running "${name}"; then
        info "Registry '${name}' is already running"
        return 0
    fi

    # If exists but not running, start it
    if registry_container_exists "${name}"; then
        info "Registry container exists, starting it"
        registry_start "${name}"
        return 0
    fi

    section "Creating Container Registry"
    info "Registry Name: ${name}"
    info "Registry Port: ${port}"
    info "Network: ${network}"
    info "Image: ${image}"

    # Build port mapping
    local port_mapping
    if [[ -n "${host_ip}" ]]; then
        if [[ "${host_ip}" == *:* ]]; then
            # IPv6
            port_mapping="[${host_ip}]:${port}:5000"
        else
            # IPv4
            port_mapping="${host_ip}:${port}:5000"
        fi
    else
        port_mapping="${port}:5000"
    fi

    debug "Port mapping: ${port_mapping}"

    # Create registry container
    if ! ${DOCKER_CMD} run \
        -d \
        --restart=always \
        -p "${port_mapping}" \
        --name "${name}" \
        --network "${network}" \
        "${image}"; then
        err_and_exit "Failed to create registry container"
    fi

    # Wait for registry to be ready
    info "Waiting for registry to be ready..."
    local health_check_host="${host_ip:-localhost}"
    if ! wait_for 60 2 registry_is_healthy "${name}" "${port}" "${health_check_host}"; then
        err "Registry failed to become healthy"
        return 1
    fi

    success "Registry '${name}' created and running"
}

# Check if registry is healthy (can accept connections)
# Args: name port host_ip
registry_is_healthy() {
    local name="${1:-${REGISTRY_NAME}}"
    local port="${2:-${REGISTRY_PORT}}"
    local host_ip="${3:-localhost}"

    # First check if container is running
    if ! registry_is_running "${name}"; then
        return 1
    fi

    # Try to connect to the registry API
    # Handle IPv6 addresses by wrapping in brackets
    local registry_url
    if [[ "${host_ip}" == *:* ]]; then
        registry_url="http://[${host_ip}]:${port}/v2/"
    else
        registry_url="http://${host_ip}:${port}/v2/"
    fi

    curl -sf "${registry_url}" >/dev/null 2>&1
}

# =============================================================================
# Kind Node Registry Configuration
# =============================================================================

# Configure containerd on kind nodes to use the registry
# Args: cluster_name registry_name registry_port host_address insecure network
registry_configure_nodes() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"
    local registry_name="${2:-${REGISTRY_NAME}}"
    local registry_port="${3:-${REGISTRY_PORT}}"
    local host_address="${4:-}"
    local insecure="${5:-false}"
    local network="${6:-${NETWORK_NAME}}"

    info "Configuring kind nodes to use registry"

    # Get the registry's internal IP on the Kind network
    # This is what the Kind nodes will use to access the registry
    local registry_internal_ip
    registry_internal_ip=$(${DOCKER_CMD} inspect -f "{{.NetworkSettings.Networks.${network}.IPAddress}}" "${registry_name}" 2>/dev/null)

    if [[ -z "${registry_internal_ip}" ]]; then
        err "Failed to get registry internal IP. Is the registry running and connected to network '${network}'?"
        return 1
    fi

    # Use internal IP with internal port (5000), not the external mapped port
    local registry_host="${registry_internal_ip}:5000"
    debug "Registry internal address: ${registry_host}"

    local registry_dir="/etc/containerd/certs.d/${registry_host}"

    local nodes
    nodes=$(kind get nodes --name "${cluster_name}" 2>/dev/null)

    for node in ${nodes}; do
        debug "Configuring registry on node: ${node}"

        # Check if already configured
        if ${DOCKER_CMD} exec "${node}" test -f "${registry_dir}/hosts.toml" 2>/dev/null; then
            debug "Node ${node} already has registry configuration"
            continue
        fi

        # Create directory and config
        ${DOCKER_CMD} exec "${node}" mkdir -p "${registry_dir}"

        if [[ "${insecure}" == "true" ]]; then
            cat <<EOF | ${DOCKER_CMD} exec -i "${node}" cp /dev/stdin "${registry_dir}/hosts.toml"
[host."http://${registry_name}:5000"]
  skip_verify = true
EOF
        else
            cat <<EOF | ${DOCKER_CMD} exec -i "${node}" cp /dev/stdin "${registry_dir}/hosts.toml"
[host."http://${registry_name}:5000"]
EOF
        fi
    done

    success "Registry configured on all nodes"
}

# Configure hosts file on kind nodes for IPv6 registry
# Args: cluster_name ipv6_address registry_dns
registry_configure_nodes_ipv6() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"
    local ipv6_address="${2}"
    local registry_dns="${3}"

    info "Configuring IPv6 registry DNS on kind nodes"

    local nodes
    nodes=$(kind get nodes --name "${cluster_name}" 2>/dev/null)

    for node in ${nodes}; do
        debug "Configuring IPv6 hosts on node: ${node}"

        # Check if already configured
        if ${DOCKER_CMD} exec "${node}" grep -q "${registry_dns}" /etc/hosts 2>/dev/null; then
            debug "Node ${node} already has IPv6 registry DNS"
            continue
        fi

        # Add hosts entry
        echo "${ipv6_address}    ${registry_dns}" | \
            ${DOCKER_CMD} exec -i "${node}" tee -a /etc/hosts >/dev/null
    done

    success "IPv6 registry DNS configured on all nodes"
}

# =============================================================================
# Container Runtime Configuration
# =============================================================================

# Check if insecure registry is already configured
is_insecure_registry_configured() {
    local registry_address="$1"

    if [[ "${DOCKER_CMD}" == "docker" ]]; then
        if [[ -f /etc/docker/daemon.json ]]; then
            grep -q "${registry_address}" /etc/docker/daemon.json 2>/dev/null
        else
            return 1
        fi
    elif [[ "${DOCKER_CMD}" == "podman" ]]; then
        grep -q "${registry_address}" /etc/containers/registries.conf 2>/dev/null
    else
        return 1
    fi
}

# Configure Docker daemon for insecure registry
docker_configure_insecure_registry() {
    local registry_address="$1"
    local ipv6_prefix="${2:-}"
    local registry_dns="${3:-}"

    if is_insecure_registry_configured "${registry_address}"; then
        info "Docker already configured for insecure registry: ${registry_address}"
        return 0
    fi

    info "Configuring Docker for insecure registry: ${registry_address}"

    local daemon_config
    if [[ -n "${ipv6_prefix}" ]]; then
        daemon_config=$(cat <<EOF
{
  "insecure-registries": ["[${ipv6_prefix}::1]:${REGISTRY_PORT}", "${registry_dns}:${REGISTRY_PORT}"],
  "experimental": true,
  "ip6tables": true,
  "fixed-cidr-v6": "${ipv6_prefix}::/80"
}
EOF
)
    else
        # Check if daemon.json exists and has content
        if [[ -f /etc/docker/daemon.json ]] && [[ -s /etc/docker/daemon.json ]]; then
            # Try to merge with existing config
            local existing_config
            existing_config=$(cat /etc/docker/daemon.json)

            # Simple check if already has insecure-registries
            if echo "${existing_config}" | grep -q "insecure-registries"; then
                warn "Docker daemon.json already has insecure-registries. Manual merge may be needed."
                return 0
            fi

            # Add insecure-registries to existing config (simple JSON manipulation)
            daemon_config=$(echo "${existing_config}" | ${SED_CMD} 's/}$/,\n  "insecure-registries": ["'"${registry_address}"'"]\n}/')
        else
            daemon_config=$(cat <<EOF
{
  "insecure-registries": ["${registry_address}"]
}
EOF
)
        fi
    fi

    echo "${daemon_config}" | maybe_sudo tee /etc/docker/daemon.json >/dev/null
    info "Restarting Docker daemon"
    maybe_sudo systemctl restart docker

    success "Docker configured for insecure registry"
}

# Configure Podman for insecure registry
podman_configure_insecure_registry() {
    local registry_address="$1"
    local ipv6_prefix="${2:-}"
    local registry_dns="${3:-}"

    if is_insecure_registry_configured "${registry_address}"; then
        info "Podman already configured for insecure registry: ${registry_address}"
        return 0
    fi

    info "Configuring Podman for insecure registry: ${registry_address}"

    local podman_config
    if [[ -n "${ipv6_prefix}" ]]; then
        podman_config=$(cat <<EOF
[registries.insecure]
registries = ["[${ipv6_prefix}::1]:${REGISTRY_PORT}", "${registry_dns}:${REGISTRY_PORT}"]
EOF
)
    else
        podman_config=$(cat <<EOF
[[registry]]
location = "${registry_address}"
insecure = true
EOF
)
    fi

    # Insert config after unqualified-search-registries line
    # Escape newlines for awk -v (which doesn't handle embedded newlines)
    local escaped_config="${podman_config//$'\n'/\\n}"
    maybe_sudo ${AWK_CMD} -v config="${escaped_config}" '
        BEGIN { inserted = 0; gsub(/\\n/, "\n", config) }
        /unqualified-search-registries/ && !inserted {
            print $0
            print config
            inserted = 1
            next
        }
        { print $0 }
    ' /etc/containers/registries.conf > /tmp/registries.conf

    maybe_sudo mv /tmp/registries.conf /etc/containers/registries.conf
    info "Restarting Podman"
    maybe_sudo systemctl restart podman

    success "Podman configured for insecure registry"
}

# Configure container runtime for insecure registry
configure_insecure_registry() {
    local registry_address="$1"
    local ipv6_prefix="${2:-}"
    local registry_dns="${3:-}"

    if [[ "${DOCKER_CMD}" == "docker" ]]; then
        docker_configure_insecure_registry "${registry_address}" "${ipv6_prefix}" "${registry_dns}"
    elif [[ "${DOCKER_CMD}" == "podman" ]]; then
        podman_configure_insecure_registry "${registry_address}" "${ipv6_prefix}" "${registry_dns}"
    else
        warn "Unknown container runtime: ${DOCKER_CMD}"
    fi
}
