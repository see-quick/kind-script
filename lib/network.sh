#!/usr/bin/env bash
# =============================================================================
# network.sh - Network configuration functions
# =============================================================================

# Prevent multiple sourcing
[[ -n "${_NETWORK_SH_LOADED:-}" ]] && return 0
readonly _NETWORK_SH_LOADED=1

# Source common utilities
_NETWORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_NETWORK_LIB_DIR}/common.sh"

# =============================================================================
# Network Detection
# =============================================================================

# Get primary IPv4 address
get_host_ipv4() {
    local ip

    # Try different methods based on OS
    if [[ "${OS}" == "macos" ]]; then
        # macOS - get IP from primary interface
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
    else
        # Linux - try hostname command first
        ip=$(hostname -I 2>/dev/null | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | awk '$1 != "127.0.0.1" { print $1 }' | head -1)

        # Fallback to ip command
        if [[ -z "${ip}" ]]; then
            ip=$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}')
        fi
    fi

    # Final fallback
    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
    fi

    echo "${ip}"
}

# Get primary network interface
get_primary_interface() {
    if [[ "${OS}" == "macos" ]]; then
        # macOS
        route get default 2>/dev/null | awk '/interface:/ {print $2}'
    else
        # Linux
        ip route get 1 2>/dev/null | awk '{print $5; exit}'
    fi
}

# Check if IPv6 is enabled
ipv6_is_enabled() {
    if [[ "${OS}" == "linux" ]]; then
        local disabled
        disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
        [[ "${disabled}" == "0" ]]
    else
        # On macOS, check if we have an IPv6 address
        ifconfig 2>/dev/null | grep -q "inet6" && return 0
        return 1
    fi
}

# =============================================================================
# Docker/Podman Network Management
# =============================================================================

# Check if a container network exists
network_exists() {
    local network="${1}"
    ${DOCKER_CMD} network inspect "${network}" >/dev/null 2>&1
}

# Get network driver
network_get_driver() {
    local network="${1}"
    ${DOCKER_CMD} network inspect -f '{{.Driver}}' "${network}" 2>/dev/null
}

# Check if network has IPv6 enabled
network_has_ipv6() {
    local network="${1}"
    local ipv6_enabled
    ipv6_enabled=$(${DOCKER_CMD} network inspect -f '{{.EnableIPv6}}' "${network}" 2>/dev/null || echo "false")
    [[ "${ipv6_enabled}" == "true" ]]
}

# Create container network (idempotent)
# Args: network_name [enable_ipv6]
network_create() {
    local network="${1:-${NETWORK_NAME}}"
    local enable_ipv6="${2:-false}"

    # Check if network already exists
    if network_exists "${network}"; then
        # Check if IPv6 requirement matches
        if [[ "${enable_ipv6}" == "true" ]] && ! network_has_ipv6 "${network}"; then
            warn "Network '${network}' exists but doesn't have IPv6 enabled"
            warn "You may need to delete and recreate it with: ${DOCKER_CMD} network rm ${network}"
        fi
        info "Network '${network}' already exists"
        return 0
    fi

    info "Creating network: ${network}"

    local create_args=("network" "create")

    # Docker vs Podman handling
    if [[ "${DOCKER_CMD}" == "docker" ]]; then
        if [[ "${enable_ipv6}" == "true" ]]; then
            create_args+=("--ipv6")
        fi
    elif [[ "${DOCKER_CMD}" == "podman" ]]; then
        if [[ "${enable_ipv6}" == "true" ]]; then
            warn "IPv6 networks with Podman may have limited support"
            create_args+=("--ipv6")
        fi
    fi

    create_args+=("${network}")

    if ! ${DOCKER_CMD} "${create_args[@]}"; then
        err_and_exit "Failed to create network: ${network}"
    fi

    success "Network '${network}' created"
}

# Delete container network
network_delete() {
    local network="${1:-${NETWORK_NAME}}"

    if ! network_exists "${network}"; then
        debug "Network '${network}' does not exist"
        return 0
    fi

    info "Deleting network: ${network}"

    if ! ${DOCKER_CMD} network rm "${network}"; then
        warn "Failed to delete network '${network}' - it may be in use"
        return 1
    fi

    success "Network '${network}' deleted"
}

# Connect container to network
network_connect() {
    local network="${1}"
    local container="${2}"

    # Check if already connected
    if ${DOCKER_CMD} network inspect "${network}" | grep -q "\"${container}\""; then
        debug "Container '${container}' already connected to network '${network}'"
        return 0
    fi

    info "Connecting ${container} to network ${network}"
    ${DOCKER_CMD} network connect "${network}" "${container}"
}

# =============================================================================
# IPv6 Configuration
# =============================================================================

# Get IPv6 ULA prefix (Unique Local Address)
# These are similar to IPv4 private addresses but for IPv6
get_ipv6_ula_prefix() {
    # Default ULA prefix for kind clusters
    echo "fd01:2345:6789"
}

# Check if IPv6 address is already assigned to interface
ipv6_address_exists() {
    local address="${1}"
    local interface="${2:-eth0}"

    if [[ "${OS}" == "linux" ]]; then
        ip -6 addr show dev "${interface}" 2>/dev/null | grep -q "${address}"
    else
        ifconfig "${interface}" 2>/dev/null | grep -q "${address}"
    fi
}

# Assign IPv6 address to interface (idempotent)
ipv6_assign_address() {
    local address="${1}"
    local interface="${2:-eth0}"
    local prefix_len="${3:-64}"

    local full_address="${address}/${prefix_len}"

    if ipv6_address_exists "${address}" "${interface}"; then
        info "IPv6 address ${address} already assigned to ${interface}"
        return 0
    fi

    info "Assigning IPv6 address ${full_address} to ${interface}"

    if [[ "${OS}" == "linux" ]]; then
        maybe_sudo ip -6 addr add "${full_address}" dev "${interface}"
    else
        warn "IPv6 address assignment not supported on ${OS}"
        return 1
    fi

    success "IPv6 address assigned"
}

# Add IPv6 hosts entry (idempotent)
add_hosts_entry() {
    local ip="${1}"
    local hostname="${2}"
    local hosts_file="${3:-/etc/hosts}"

    # Check if entry already exists
    if grep -q "${hostname}" "${hosts_file}" 2>/dev/null; then
        info "Hosts entry for ${hostname} already exists"
        return 0
    fi

    info "Adding hosts entry: ${ip} ${hostname}"
    echo "${ip}    ${hostname}" | maybe_sudo tee -a "${hosts_file}" >/dev/null
    success "Hosts entry added"
}

# =============================================================================
# Cloud Provider Kind
# =============================================================================

# Detect if the container runtime is actually Podman (even if aliased as docker)
_is_runtime_podman() {
    if [[ "${DOCKER_CMD}" == "podman" ]]; then
        return 0
    fi
    if ${DOCKER_CMD} --version 2>/dev/null | grep -qi "podman"; then
        return 0
    fi
    return 1
}

# Get the Podman socket path appropriate for the current OS
_get_podman_socket_path() {
    # macOS: podman machine socket (VM-internal path, accessible from containers)
    if [[ "${OS}" == "macos" ]]; then
        echo "/run/podman/podman.sock"
        return 0
    fi
    # Linux: rootful socket
    if [[ -S "/run/podman/podman.sock" ]]; then
        echo "/run/podman/podman.sock"
        return 0
    fi
    # Linux: rootless socket
    local uid
    uid=$(id -u)
    if [[ -S "/run/user/${uid}/podman/podman.sock" ]]; then
        echo "/run/user/${uid}/podman/podman.sock"
        return 0
    fi
    # Fallback
    echo "/run/podman/podman.sock"
}

# Check if cloud-provider-kind container is running
cloud_provider_is_running() {
    local container_name="${1:-cloud-provider-kind}"
    local state
    state=$(${DOCKER_CMD} inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null || echo "false")
    [[ "${state}" == "true" ]]
}

# Check if cloud-provider-kind container exists
cloud_provider_exists() {
    local container_name="${1:-cloud-provider-kind}"
    ${DOCKER_CMD} inspect "${container_name}" >/dev/null 2>&1
}

# Run cloud-provider-kind (idempotent)
# This enables LoadBalancer service support in kind
cloud_provider_run() {
    local network="${1:-${NETWORK_NAME}}"
    local version="${2:-${KIND_CLOUD_PROVIDER_VERSION}}"
    local container_name="cloud-provider-kind"

    # Check if already running
    if cloud_provider_is_running "${container_name}"; then
        info "cloud-provider-kind is already running"
        return 0
    fi

    # If exists but not running, start it
    if cloud_provider_exists "${container_name}"; then
        info "Starting existing cloud-provider-kind container"
        ${DOCKER_CMD} start "${container_name}"
        return 0
    fi

    section "Starting Cloud Provider Kind"
    info "Version: ${version}"
    info "Network: ${network}"

    # Determine socket path and extra flags based on container runtime
    local socket_path="/var/run/docker.sock"
    local extra_flags=()

    if _is_runtime_podman; then
        socket_path=$(_get_podman_socket_path)
        extra_flags=(--privileged --user root)
        info "Detected Podman runtime, using socket: ${socket_path}"
    fi

    if ! ${DOCKER_CMD} run -d \
        --name "${container_name}" \
        --network "${network}" \
        "${extra_flags[@]}" \
        -v "${socket_path}:/var/run/docker.sock" \
        "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${version}"; then
        err "Failed to start cloud-provider-kind"
        return 1
    fi

    success "cloud-provider-kind started"
}

# Stop and remove cloud-provider-kind
cloud_provider_stop() {
    local container_name="cloud-provider-kind"

    if ! cloud_provider_exists "${container_name}"; then
        debug "cloud-provider-kind does not exist"
        return 0
    fi

    if cloud_provider_is_running "${container_name}"; then
        info "Stopping cloud-provider-kind"
        ${DOCKER_CMD} stop "${container_name}"
    fi

    info "Removing cloud-provider-kind container"
    ${DOCKER_CMD} rm "${container_name}"

    success "cloud-provider-kind removed"
}
