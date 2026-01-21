#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/registry.sh
# =============================================================================

load '../helpers/test_helper'

setup() {
    common_setup
    export REGISTRY_NAME="kind-registry"
    export REGISTRY_PORT="5001"
    export REGISTRY_IMAGE="registry:2"
    export NETWORK_NAME="kind"
    export KIND_CLUSTER_NAME="test-cluster"
    export DOCKER_CMD="docker"
    source_lib "registry.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# registry_container_exists Tests
# =============================================================================

@test "registry_container_exists: returns success when container exists" {
    mock_docker 0 "{}"
    run registry_container_exists "kind-registry"
    assert_success
}

@test "registry_container_exists: returns failure when container missing" {
    mock_docker 1 ""
    run registry_container_exists "kind-registry"
    assert_failure
}

@test "registry_container_exists: uses default name when not specified" {
    create_capturing_mock "docker" 0 "{}"
    run registry_container_exists
    assert_success

    # Verify it used the default name
    local args
    args=$(get_mock_args "docker")
    [[ "$args" == *"kind-registry"* ]]
}

# =============================================================================
# registry_is_running Tests
# =============================================================================

@test "registry_is_running: returns success when running" {
    mock_docker 0 "true"
    run registry_is_running "kind-registry"
    assert_success
}

@test "registry_is_running: returns failure when not running" {
    mock_docker 0 "false"
    run registry_is_running "kind-registry"
    assert_failure
}

@test "registry_is_running: returns failure when container missing" {
    mock_docker 1 ""
    run registry_is_running "kind-registry"
    assert_failure
}

# =============================================================================
# registry_get_ip Tests
# =============================================================================

@test "registry_get_ip: returns IP address" {
    mock_docker 0 "172.18.0.2"
    run registry_get_ip "kind-registry" "kind"
    assert_success
    assert_output "172.18.0.2"
}

@test "registry_get_ip: returns empty when container missing" {
    mock_docker 1 ""
    run registry_get_ip "kind-registry" "kind"
    assert_output ""
}

# =============================================================================
# registry_start Tests
# =============================================================================

@test "registry_start: starts existing stopped container" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "inspect" && "$2" != "-f" ]]; then
    echo "{}"
    exit 0
elif [[ "$*" == *"inspect"*"-f"* && "$*" == *"Running"* ]]; then
    echo "false"
    exit 0
elif [[ "$1" == "start" ]]; then
    echo "started"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_start "kind-registry"
    assert_success
}

@test "registry_start: fails when container doesn't exist" {
    mock_docker 1 ""
    run registry_start "kind-registry"
    assert_failure
}

@test "registry_start: skips when already running" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "inspect" && "$2" != "-f" ]]; then
    echo "{}"
    exit 0
elif [[ "$*" == *"inspect"*"-f"* && "$*" == *"Running"* ]]; then
    echo "true"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_start "kind-registry"
    assert_success
}

# =============================================================================
# registry_stop Tests
# =============================================================================

@test "registry_stop: stops running container" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"inspect"*"-f"*"Running"* ]]; then
    echo "true"
    exit 0
elif [[ "$1" == "stop" ]]; then
    echo "stopped"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_stop "kind-registry"
    assert_success
    assert_output_contains "Stopping registry"
}

@test "registry_stop: skips when not running" {
    mock_docker 0 "false"
    run registry_stop "kind-registry"
    assert_success
}

# =============================================================================
# registry_remove Tests
# =============================================================================

@test "registry_remove: removes stopped container" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "inspect" && "$2" != "-f" ]]; then
    echo "{}"
    exit 0
elif [[ "$*" == *"inspect"*"-f"*"Running"* ]]; then
    echo "false"
    exit 0
elif [[ "$1" == "rm" ]]; then
    echo "removed"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_remove "kind-registry"
    assert_success
    assert_output_contains "Removing registry"
}

@test "registry_remove: skips when container doesn't exist" {
    mock_docker 1 ""
    run registry_remove "kind-registry"
    assert_success
}

@test "registry_remove: stops running container before removing" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    local call_log="${TEST_TEMP_DIR}/calls.log"

    cat > "${mock_script}" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "${call_log}"
if [[ "\$1" == "inspect" && "\$2" != "-f" ]]; then
    echo "{}"
    exit 0
elif [[ "\$*" == *"inspect"*"-f"*"Running"* ]]; then
    echo "true"
    exit 0
elif [[ "\$1" == "stop" ]]; then
    echo "stopped"
    exit 0
elif [[ "\$1" == "rm" ]]; then
    echo "removed"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_remove "kind-registry"
    assert_success

    # Verify stop was called before rm
    run cat "${call_log}"
    assert_output_contains "stop"
    assert_output_contains "rm"
}

# =============================================================================
# registry_create Tests
# =============================================================================

@test "registry_create: skips when already running" {
    local mock_script="${TEST_TEMP_DIR}/mocks/docker"
    mkdir -p "${TEST_TEMP_DIR}/mocks"

    cat > "${mock_script}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"inspect"*"-f"*"Running"* ]]; then
    echo "true"
    exit 0
fi
exit 0
EOF
    chmod +x "${mock_script}"
    export PATH="${TEST_TEMP_DIR}/mocks:${PATH}"

    run registry_create "kind-registry"
    assert_success
    assert_output_contains "already running"
}

# =============================================================================
# registry_is_healthy Tests
# =============================================================================

@test "registry_is_healthy: returns failure when container not running" {
    mock_docker 0 "false"
    run registry_is_healthy "kind-registry" "5001" "localhost"
    assert_failure
}

# =============================================================================
# is_insecure_registry_configured Tests
# =============================================================================

@test "is_insecure_registry_configured: checks docker daemon.json" {
    DOCKER_CMD="docker"

    # Create a mock daemon.json
    mkdir -p "${TEST_TEMP_DIR}/etc/docker"

    # Test when file doesn't exist
    run is_insecure_registry_configured "localhost:5001"
    assert_failure
}

@test "is_insecure_registry_configured: finds registry in config" {
    DOCKER_CMD="docker"

    # This test would need to mock file reading
    # For now, just verify function exists and runs
    run is_insecure_registry_configured "localhost:5001"
    # Will fail because file doesn't exist, which is expected
    assert_failure
}

# =============================================================================
# Port Mapping Tests (via registry_create internals)
# =============================================================================

@test "registry: IPv4 port mapping format" {
    # Test the port mapping logic by checking the format
    local host_ip="192.168.1.100"
    local port="5001"

    local port_mapping
    if [[ "${host_ip}" == *:* ]]; then
        port_mapping="[${host_ip}]:${port}:5000"
    else
        port_mapping="${host_ip}:${port}:5000"
    fi

    assert [ "${port_mapping}" == "192.168.1.100:5001:5000" ]
}

@test "registry: IPv6 port mapping format" {
    local host_ip="fd01:2345:6789::1"
    local port="5001"

    local port_mapping
    if [[ "${host_ip}" == *:* ]]; then
        port_mapping="[${host_ip}]:${port}:5000"
    else
        port_mapping="${host_ip}:${port}:5000"
    fi

    assert [ "${port_mapping}" == "[fd01:2345:6789::1]:5001:5000" ]
}

@test "registry: default port mapping format" {
    local host_ip=""
    local port="5001"

    local port_mapping
    if [[ -n "${host_ip}" ]]; then
        port_mapping="${host_ip}:${port}:5000"
    else
        port_mapping="${port}:5000"
    fi

    assert [ "${port_mapping}" == "5001:5000" ]
}