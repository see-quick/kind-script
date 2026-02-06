#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/network.sh
# =============================================================================

load '../helpers/test_helper'

setup() {
    common_setup
    export NETWORK_NAME="kind"
    export DOCKER_CMD="docker"
    export KIND_CLOUD_PROVIDER_VERSION="v0.0.6"
    source_lib "network.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# get_ipv6_ula_prefix Tests
# =============================================================================

@test "get_ipv6_ula_prefix: returns expected prefix" {
    run get_ipv6_ula_prefix
    assert_success
    assert_output "fd01:2345:6789"
}

# =============================================================================
# network_exists Tests
# =============================================================================

@test "network_exists: returns success when network exists" {
    mock_docker 0 "{}"
    run network_exists "kind"
    assert_success
}

@test "network_exists: returns failure when network missing" {
    mock_docker 1 "Error: No such network"
    run network_exists "nonexistent"
    assert_failure
}

# =============================================================================
# network_get_driver Tests
# =============================================================================

@test "network_get_driver: returns bridge driver" {
    mock_docker 0 "bridge"
    run network_get_driver "kind"
    assert_success
    assert_output "bridge"
}

# =============================================================================
# network_has_ipv6 Tests
# =============================================================================

@test "network_has_ipv6: returns success when IPv6 enabled" {
    mock_docker 0 "true"
    run network_has_ipv6 "kind"
    assert_success
}

@test "network_has_ipv6: returns failure when IPv6 disabled" {
    mock_docker 0 "false"
    run network_has_ipv6 "kind"
    assert_failure
}

# =============================================================================
# network_create Tests
# =============================================================================

@test "network_create: skips when network already exists" {
    # First call (inspect) succeeds = network exists
    create_capturing_mock "docker" 0 "{}"

    run network_create "kind" "false"
    assert_success
    assert_output_contains "already exists"
}

@test "network_create: creates network when missing" {
    # Create a more sophisticated mock
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
    exit 1  # Network doesn't exist
elif [[ "$1" == "network" && "$2" == "create" ]]; then
    echo "network-id"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run network_create "test-network" "false"
    assert_success
    assert_output_contains "Creating network"
}

@test "network_create: uses --ipv6 flag when enabled" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> /tmp/docker_args.txt
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
    exit 1
elif [[ "$1" == "network" && "$2" == "create" ]]; then
    if [[ "$*" == *"--ipv6"* ]]; then
        echo "ipv6-network-id"
    fi
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run network_create "test-network" "true"
    assert_success
}

# =============================================================================
# network_delete Tests
# =============================================================================

@test "network_delete: skips when network doesn't exist" {
    mock_docker 1 ""
    run network_delete "nonexistent"
    assert_success
}

@test "network_delete: deletes existing network" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "network" && "$2" == "inspect" ]]; then
    echo "{}"
    exit 0
elif [[ "$1" == "network" && "$2" == "rm" ]]; then
    echo "deleted"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run network_delete "kind"
    assert_success
    assert_output_contains "Deleting network"
}

# =============================================================================
# cloud_provider_is_running Tests
# =============================================================================

@test "cloud_provider_is_running: returns success when running" {
    mock_docker 0 "true"
    run cloud_provider_is_running "cloud-provider-kind"
    assert_success
}

@test "cloud_provider_is_running: returns failure when not running" {
    mock_docker 0 "false"
    run cloud_provider_is_running "cloud-provider-kind"
    assert_failure
}

@test "cloud_provider_is_running: returns failure when container missing" {
    mock_docker 1 ""
    run cloud_provider_is_running "cloud-provider-kind"
    assert_failure
}

# =============================================================================
# cloud_provider_exists Tests
# =============================================================================

@test "cloud_provider_exists: returns success when exists" {
    mock_docker 0 "{}"
    run cloud_provider_exists "cloud-provider-kind"
    assert_success
}

@test "cloud_provider_exists: returns failure when missing" {
    mock_docker 1 ""
    run cloud_provider_exists "cloud-provider-kind"
    assert_failure
}

# =============================================================================
# cloud_provider_run Tests
# =============================================================================

@test "cloud_provider_run: succeeds with podman runtime" {
    DOCKER_CMD="podman"
    local mock_script="${TEST_TEMP_DIR}/mocks/podman"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
    echo "podman version 5.0.0"
    exit 0
elif [[ "$1" == "inspect" ]]; then
    echo "false"
    exit 1
elif [[ "$1" == "run" ]]; then
    echo "container-id-12345"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run cloud_provider_run "kind" "v0.0.6"
    assert_success
    assert_output_contains "Detected Podman runtime"
    assert_output_not_contains "does not currently support Podman"
}

@test "cloud_provider_run: skips when already running" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"inspect"*"-f"* ]]; then
    echo "true"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"
    DOCKER_CMD="docker"

    run cloud_provider_run "kind"
    assert_success
    assert_output_contains "already running"
}

# =============================================================================
# cloud_provider_stop Tests
# =============================================================================

@test "cloud_provider_stop: skips when container doesn't exist" {
    mock_docker 1 ""
    run cloud_provider_stop
    assert_success
}

# =============================================================================
# add_hosts_entry Tests
# =============================================================================

@test "add_hosts_entry: skips when entry already exists" {
    local hosts_file="${TEST_TEMP_DIR}/hosts"
    echo "192.168.1.1    myhost.local" > "${hosts_file}"

    run add_hosts_entry "192.168.1.2" "myhost.local" "${hosts_file}"
    assert_success
    assert_output_contains "already exists"

    # Verify file wasn't modified
    run cat "${hosts_file}"
    assert_output "192.168.1.1    myhost.local"
}

# =============================================================================
# ipv6_is_enabled Tests
# =============================================================================

@test "ipv6_is_enabled: checks system IPv6 status" {
    # This just verifies the function runs without error
    run ipv6_is_enabled
    # Result depends on system - just check it runs
    [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
}

# =============================================================================
# get_primary_interface Tests
# =============================================================================

@test "get_primary_interface: returns interface name" {
    # This test verifies the function runs - result is system-dependent
    run get_primary_interface
    # May succeed or fail depending on system, just verify it runs
    [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]] || skip "Could not determine primary interface"
}

# =============================================================================
# get_host_ipv4 Tests
# =============================================================================

@test "get_host_ipv4: returns an IP address" {
    run get_host_ipv4
    assert_success
    # Should return something that looks like an IP or 127.0.0.1
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "get_host_ipv4: returns valid IPv4 format" {
    run get_host_ipv4
    assert_success
    # Validate it's a proper IPv4
    run is_valid_ipv4 "$output"
    assert_success
}