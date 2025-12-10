#!/usr/bin/env bash
# =============================================================================
# cluster.sh - Kind cluster management functions
# =============================================================================

# Prevent multiple sourcing
[[ -n "${_CLUSTER_SH_LOADED:-}" ]] && return 0
readonly _CLUSTER_SH_LOADED=1

# Source common utilities
_CLUSTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${_CLUSTER_LIB_DIR}/common.sh"

# =============================================================================
# Kind Installation
# =============================================================================

# Check if kind is installed
kind_is_installed() {
    command_exists kind
}

# Get installed kind version
kind_get_version() {
    if kind_is_installed; then
        kind version | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# Install kind binary
# Args: version [optional, defaults to KIND_VERSION]
kind_install() {
    local version="${1:-${KIND_VERSION}}"
    local arch="${ARCH}"
    local os="${OS}"

    # Normalize OS name for download URL
    case "${os}" in
        macos) os="darwin" ;;
    esac

    # Check if already installed with correct version
    if kind_is_installed; then
        local installed_version
        installed_version=$(kind_get_version)
        if [[ "${installed_version}" == "${version}" ]]; then
            info "Kind ${version} is already installed"
            return 0
        else
            info "Kind ${installed_version} found, upgrading to ${version}"
        fi
    fi

    section "Installing Kind ${version}"

    local download_url="https://github.com/kubernetes-sigs/kind/releases/download/${version}/kind-${os}-${arch}"
    local tmp_file
    tmp_file=$(mktemp)

    info "Downloading kind from ${download_url}"
    if ! curl -fsSL -o "${tmp_file}" "${download_url}"; then
        rm -f "${tmp_file}"
        err_and_exit "Failed to download kind"
    fi

    chmod +x "${tmp_file}"

    # Install to /usr/local/bin
    local install_dir="/usr/local/bin"
    if [[ -w "${install_dir}" ]]; then
        mv "${tmp_file}" "${install_dir}/kind"
    else
        info "Installing to ${install_dir} requires sudo"
        maybe_sudo mv "${tmp_file}" "${install_dir}/kind"
    fi

    # Verify installation
    if kind_is_installed; then
        success "Kind $(kind_get_version) installed successfully"
    else
        err_and_exit "Kind installation failed"
    fi
}

# =============================================================================
# Kubectl Installation
# =============================================================================

# Check if kubectl is installed
kubectl_is_installed() {
    command_exists kubectl
}

# Get installed kubectl version
kubectl_get_version() {
    if kubectl_is_installed; then
        kubectl version --client -o json 2>/dev/null | grep -oE '"gitVersion":\s*"v[^"]+' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'
    fi
}

# Install kubectl binary
# Args: version [optional, defaults to stable]
kubectl_install() {
    local version="${1:-}"
    local arch="${ARCH}"
    local os="${OS}"

    # Normalize OS name for download URL
    case "${os}" in
        macos) os="darwin" ;;
    esac

    # Get stable version if not specified
    if [[ -z "${version}" ]]; then
        info "Fetching latest stable kubectl version"
        version=$(curl -fsSL "https://dl.k8s.io/release/stable.txt")
    fi

    # Check if already installed with correct version
    if kubectl_is_installed; then
        local installed_version
        installed_version=$(kubectl_get_version)
        if [[ "${installed_version}" == "${version}" ]]; then
            info "kubectl ${version} is already installed"
            return 0
        else
            info "kubectl ${installed_version} found, will install ${version}"
        fi
    fi

    section "Installing kubectl ${version}"

    local download_url="https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl"
    local tmp_file
    tmp_file=$(mktemp)

    info "Downloading kubectl from ${download_url}"
    if ! curl -fsSL -o "${tmp_file}" "${download_url}"; then
        rm -f "${tmp_file}"
        err_and_exit "Failed to download kubectl"
    fi

    chmod +x "${tmp_file}"

    # Install to /usr/local/bin
    local install_dir="/usr/local/bin"
    if [[ -w "${install_dir}" ]]; then
        mv "${tmp_file}" "${install_dir}/kubectl"
    else
        info "Installing to ${install_dir} requires sudo"
        maybe_sudo mv "${tmp_file}" "${install_dir}/kubectl"
    fi

    # Verify installation
    if kubectl_is_installed; then
        success "kubectl $(kubectl_get_version) installed successfully"
    else
        err_and_exit "kubectl installation failed"
    fi
}

# =============================================================================
# Cluster Management
# =============================================================================

# Check if a kind cluster exists
cluster_exists() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"
    kind get clusters 2>/dev/null | grep -qx "${cluster_name}"
}

# Check if cluster is running (all nodes ready)
cluster_is_ready() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"

    if ! cluster_exists "${cluster_name}"; then
        return 1
    fi

    # Switch to cluster context
    kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1 || return 1

    # Check if all nodes are ready
    local ready_count total_count
    total_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")

    [[ "${total_count}" -gt 0 ]] && [[ "${ready_count}" -eq "${total_count}" ]]
}

# Get cluster nodes
cluster_get_nodes() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"
    kind get nodes --name "${cluster_name}" 2>/dev/null
}

# Generate kind cluster configuration
# Args: control_planes worker_nodes ip_family registry_name registry_port
cluster_generate_config() {
    local control_planes="${1:-1}"
    local worker_nodes="${2:-3}"
    local ip_family="${3:-ipv4}"
    local registry_name="${4:-}"
    local registry_port="${5:-5001}"

    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
EOF

    # Add containerd config patches
    if [[ -n "${registry_name}" ]]; then
        if [[ "${ip_family}" == "ipv6" ]]; then
            cat <<EOF
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${registry_name}:${registry_port}"]
      endpoint = ["http://${registry_name}:${registry_port}"]
EOF
        else
            cat <<EOF
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF
        fi
    fi

    # Add nodes configuration
    echo "nodes:"
    for ((i = 0; i < control_planes; i++)); do
        echo "  - role: control-plane"
    done
    for ((i = 0; i < worker_nodes; i++)); do
        echo "  - role: worker"
    done

    # Add networking configuration
    cat <<EOF
networking:
  ipFamily: ${ip_family}
EOF
}

# Create kind cluster
# Uses global configuration variables
cluster_create() {
    local cluster_name="${KIND_CLUSTER_NAME}"
    local node_image="${KIND_NODE_IMAGE}"
    local control_planes="${CONTROL_NODES}"
    local worker_nodes="${WORKER_NODES}"
    local ip_family="${IP_FAMILY}"
    local registry_name="${REGISTRY_NAME:-}"
    local registry_port="${REGISTRY_PORT:-5001}"

    # Check if cluster already exists
    if cluster_exists "${cluster_name}"; then
        if cluster_is_ready "${cluster_name}"; then
            info "Cluster '${cluster_name}' already exists and is ready"
            return 0
        else
            warn "Cluster '${cluster_name}' exists but is not ready"
            if [[ "${FORCE_RECREATE:-false}" == "true" ]]; then
                info "Force recreate enabled, deleting existing cluster"
                cluster_delete "${cluster_name}"
            else
                err_and_exit "Cluster exists but not ready. Use --force to recreate"
            fi
        fi
    fi

    section "Creating Kind Cluster"
    info "Cluster Name: ${cluster_name}"
    info "Node Image: ${node_image}"
    info "Control Planes: ${control_planes}"
    info "Worker Nodes: ${worker_nodes}"
    info "IP Family: ${ip_family}"

    # Generate configuration
    local config_file
    config_file=$(mktemp)
    cluster_generate_config "${control_planes}" "${worker_nodes}" "${ip_family}" "${registry_name}" "${registry_port}" > "${config_file}"

    debug "Generated cluster config:"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        cat "${config_file}"
    fi

    # Create the cluster
    if ! kind create cluster \
        --name "${cluster_name}" \
        --image "${node_image}" \
        --config "${config_file}"; then
        rm -f "${config_file}"
        err_and_exit "Failed to create cluster"
    fi

    rm -f "${config_file}"

    # Wait for cluster to be ready
    info "Waiting for cluster to be ready..."
    if ! wait_for 300 5 cluster_is_ready "${cluster_name}"; then
        err_and_exit "Cluster failed to become ready within timeout"
    fi

    success "Cluster '${cluster_name}' created successfully"
}

# Delete kind cluster
cluster_delete() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"

    if ! cluster_exists "${cluster_name}"; then
        info "Cluster '${cluster_name}' does not exist"
        return 0
    fi

    section "Deleting Kind Cluster"
    info "Deleting cluster: ${cluster_name}"

    if ! kind delete cluster --name "${cluster_name}"; then
        err_and_exit "Failed to delete cluster"
    fi

    success "Cluster '${cluster_name}' deleted successfully"
}

# =============================================================================
# Cluster Configuration
# =============================================================================

# Setup kubeconfig directory
setup_kube_directory() {
    local kube_dir="${HOME}/.kube"

    if [[ ! -d "${kube_dir}" ]]; then
        info "Creating ${kube_dir} directory"
        mkdir -p "${kube_dir}"
    fi

    if [[ ! -f "${kube_dir}/config" ]]; then
        touch "${kube_dir}/config"
    fi

    chmod 700 "${kube_dir}"
    chmod 600 "${kube_dir}/config" 2>/dev/null || true
}

# Create cluster role binding for admin access
cluster_create_admin_binding() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"

    kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1

    # Check if binding already exists
    if kubectl get clusterrolebinding add-on-cluster-admin >/dev/null 2>&1; then
        info "Cluster admin role binding already exists"
        return 0
    fi

    info "Creating cluster admin role binding"
    kubectl create clusterrolebinding add-on-cluster-admin \
        --clusterrole=cluster-admin \
        --serviceaccount=kube-system:default

    success "Cluster admin role binding created"
}

# Label all nodes with rack-key=zone
cluster_label_nodes() {
    local cluster_name="${1:-${KIND_CLUSTER_NAME}}"
    local label="${2:-rack-key=zone}"

    kubectl config use-context "kind-${cluster_name}" >/dev/null 2>&1

    info "Labeling nodes with: ${label}"

    local nodes
    nodes=$(kubectl get nodes -o custom-columns=:.metadata.name --no-headers)

    for node in ${nodes}; do
        # Check if label already exists
        local existing_label
        existing_label=$(kubectl get node "${node}" -o jsonpath="{.metadata.labels.rack-key}" 2>/dev/null || echo "")

        if [[ -n "${existing_label}" ]]; then
            debug "Node ${node} already has rack-key label"
        else
            kubectl label node "${node}" "${label}" --overwrite
            debug "Labeled node: ${node}"
        fi
    done

    success "All nodes labeled"
}

# =============================================================================
# inotify Limits (for multi-node clusters)
# =============================================================================

# Check current inotify limits
get_inotify_limits() {
    local watches instances
    watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo "unknown")
    instances=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo "unknown")
    echo "max_user_watches=${watches} max_user_instances=${instances}"
}

# Adjust inotify limits for multi-node clusters
# Only runs on Linux
adjust_inotify_limits() {
    local target_watches="${1:-655360}"
    local target_instances="${2:-1280}"

    if [[ "${OS}" != "linux" ]]; then
        debug "Skipping inotify adjustment on non-Linux system"
        return 0
    fi

    local current_watches current_instances
    current_watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo "0")
    current_instances=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo "0")

    local needs_adjustment=false

    if [[ "${current_watches}" -lt "${target_watches}" ]]; then
        needs_adjustment=true
    fi

    if [[ "${current_instances}" -lt "${target_instances}" ]]; then
        needs_adjustment=true
    fi

    if [[ "${needs_adjustment}" == "false" ]]; then
        info "inotify limits are already sufficient (watches=${current_watches}, instances=${current_instances})"
        return 0
    fi

    info "Adjusting inotify limits (requires sudo)"
    info "Current: watches=${current_watches}, instances=${current_instances}"
    info "Target: watches=${target_watches}, instances=${target_instances}"

    # Apply immediately
    maybe_sudo sysctl -w "fs.inotify.max_user_watches=${target_watches}" >/dev/null
    maybe_sudo sysctl -w "fs.inotify.max_user_instances=${target_instances}" >/dev/null

    # Make persistent (check if already set)
    local sysctl_conf="/etc/sysctl.d/99-kind-inotify.conf"
    if [[ ! -f "${sysctl_conf}" ]]; then
        maybe_sudo tee "${sysctl_conf}" >/dev/null <<EOF
# Kind cluster inotify settings
fs.inotify.max_user_watches = ${target_watches}
fs.inotify.max_user_instances = ${target_instances}
EOF
    fi

    success "inotify limits adjusted"
}

# =============================================================================
# iptables Modules (for Podman)
# =============================================================================

# Load iptables kernel modules for Podman
load_iptables_modules() {
    if [[ "${DOCKER_CMD}" != "podman" ]]; then
        return 0
    fi

    if [[ "${OS}" != "linux" ]]; then
        return 0
    fi

    info "Loading iptables kernel modules for Podman"

    for module in ip_tables ip6_tables; do
        if ! lsmod | grep -q "^${module}"; then
            if ! maybe_sudo modprobe "${module}" 2>/dev/null; then
                warn "Failed to load ${module} module"
            fi
        else
            debug "${module} module already loaded"
        fi
    done
}
