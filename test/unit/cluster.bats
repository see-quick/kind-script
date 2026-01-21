#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/cluster.sh
# =============================================================================

load '../helpers/test_helper'

setup() {
    common_setup
    # Set required global variables
    export KIND_CLUSTER_NAME="test-cluster"
    export KIND_NODE_IMAGE="kindest/node:v1.29.0"
    export KIND_VERSION="v0.20.0"
    export CONTROL_NODES=1
    export WORKER_NODES=2
    export IP_FAMILY="ipv4"
    export REGISTRY_NAME="kind-registry"
    export REGISTRY_PORT="5001"
    export NETWORK_NAME="kind"

    source_lib "cluster.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# kind_is_installed Tests
# =============================================================================

@test "kind_is_installed: returns success when kind exists" {
    create_mock "kind" 0 "kind version"
    run kind_is_installed
    assert_success
}

@test "kind_is_installed: returns failure when kind missing" {
    # Create a function that mimics kind_is_installed but checks for nonexistent command
    check_nonexistent() {
        command -v "this_command_definitely_does_not_exist_12345" >/dev/null 2>&1
    }

    run check_nonexistent
    assert_failure
}

# =============================================================================
# kind_get_version Tests
# =============================================================================

@test "kind_get_version: extracts version correctly" {
    create_mock "kind" 0 "kind v0.20.0 go1.20.4 darwin/arm64"
    run kind_get_version
    assert_success
    assert_output "v0.20.0"
}

@test "kind_get_version: handles version with different format" {
    create_mock "kind" 0 "kind v0.21.0 go1.21.0 linux/amd64"
    run kind_get_version
    assert_success
    assert_output "v0.21.0"
}

# =============================================================================
# kubectl_is_installed Tests
# =============================================================================

@test "kubectl_is_installed: returns success when kubectl exists" {
    create_mock "kubectl" 0 ""
    run kubectl_is_installed
    assert_success
}

# =============================================================================
# cluster_generate_config Tests
# =============================================================================

@test "cluster_generate_config: generates basic IPv4 config" {
    run cluster_generate_config 1 2 "ipv4" "" ""
    assert_success
    assert_output_contains "kind: Cluster"
    assert_output_contains "apiVersion: kind.x-k8s.io/v1alpha4"
    assert_output_contains "role: control-plane"
    assert_output_contains "role: worker"
    assert_output_contains "ipFamily: ipv4"
}

@test "cluster_generate_config: generates IPv6 config" {
    run cluster_generate_config 1 1 "ipv6" "" ""
    assert_success
    assert_output_contains "ipFamily: ipv6"
}

@test "cluster_generate_config: generates dual-stack config" {
    run cluster_generate_config 1 1 "dual" "" ""
    assert_success
    assert_output_contains "ipFamily: dual"
}

@test "cluster_generate_config: includes correct number of control planes" {
    run cluster_generate_config 3 0 "ipv4" "" ""
    assert_success
    # Count control-plane occurrences
    local count
    count=$(echo "$output" | grep -c "role: control-plane" || echo "0")
    assert [ "$count" -eq 3 ]
}

@test "cluster_generate_config: includes correct number of workers" {
    run cluster_generate_config 1 5 "ipv4" "" ""
    assert_success
    local count
    count=$(echo "$output" | grep -c "role: worker" || echo "0")
    assert [ "$count" -eq 5 ]
}

@test "cluster_generate_config: includes registry config when provided" {
    run cluster_generate_config 1 1 "ipv4" "my-registry" "5001"
    assert_success
    assert_output_contains "containerdConfigPatches"
    assert_output_contains "config_path"
}

@test "cluster_generate_config: uses different registry config for IPv6" {
    run cluster_generate_config 1 1 "ipv6" "my-registry" "5001"
    assert_success
    assert_output_contains "containerdConfigPatches"
    assert_output_contains "registry.mirrors"
    assert_output_contains "my-registry:5001"
}

# =============================================================================
# cluster_exists Tests (with mocks)
# =============================================================================

@test "cluster_exists: returns success when cluster exists" {
    create_mock "kind" 0 "test-cluster"
    run cluster_exists "test-cluster"
    assert_success
}

@test "cluster_exists: returns failure when cluster not found" {
    create_mock "kind" 0 "other-cluster"
    run cluster_exists "test-cluster"
    assert_failure
}

@test "cluster_exists: returns failure when no clusters" {
    create_mock "kind" 0 ""
    run cluster_exists "test-cluster"
    assert_failure
}

# =============================================================================
# setup_kube_directory Tests
# =============================================================================

@test "setup_kube_directory: creates .kube directory if missing" {
    export HOME="${TEST_TEMP_DIR}"

    run setup_kube_directory
    assert_success
    assert [ -d "${TEST_TEMP_DIR}/.kube" ]
}

@test "setup_kube_directory: creates config file if missing" {
    export HOME="${TEST_TEMP_DIR}"
    mkdir -p "${TEST_TEMP_DIR}/.kube"

    run setup_kube_directory
    assert_success
    assert [ -f "${TEST_TEMP_DIR}/.kube/config" ]
}

@test "setup_kube_directory: sets correct permissions" {
    export HOME="${TEST_TEMP_DIR}"

    run setup_kube_directory
    assert_success

    # Check directory permissions (700)
    local dir_perms
    dir_perms=$(stat -f "%OLp" "${TEST_TEMP_DIR}/.kube" 2>/dev/null || stat -c "%a" "${TEST_TEMP_DIR}/.kube" 2>/dev/null)
    assert [ "$dir_perms" == "700" ]
}

# =============================================================================
# get_inotify_limits Tests (Linux only)
# =============================================================================

@test "get_inotify_limits: returns values on Linux" {
    if [[ "$(uname -s)" != "Linux" ]]; then
        skip "Test only runs on Linux"
    fi

    run get_inotify_limits
    assert_success
    assert_output_contains "max_user_watches="
    assert_output_contains "max_user_instances="
}

@test "get_inotify_limits: returns unknown on non-Linux" {
    if [[ "$(uname -s)" == "Linux" ]]; then
        skip "Test only runs on non-Linux"
    fi

    run get_inotify_limits
    assert_success
    assert_output_contains "unknown"
}

# =============================================================================
# adjust_inotify_limits Tests
# =============================================================================

@test "adjust_inotify_limits: skips on non-Linux" {
    # Force non-Linux detection
    OS="macos"
    export OS

    run adjust_inotify_limits
    assert_success
}

# =============================================================================
# load_iptables_modules Tests
# =============================================================================

@test "load_iptables_modules: skips when not using podman" {
    DOCKER_CMD="docker"
    run load_iptables_modules
    assert_success
}

@test "load_iptables_modules: skips on non-Linux with podman" {
    DOCKER_CMD="podman"
    OS="macos"
    run load_iptables_modules
    assert_success
}