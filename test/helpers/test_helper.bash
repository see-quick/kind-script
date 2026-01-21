# =============================================================================
# test_helper.bash - Common test helper functions
# =============================================================================

# Load BATS support libraries
load "${BATS_SUPPORT}/load.bash"
load "${BATS_ASSERT}/load.bash"

# Project root directory
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)}"
export LIB_DIR="${PROJECT_ROOT}/lib"

# =============================================================================
# Setup and Teardown
# =============================================================================

# Common setup for all tests
common_setup() {
    # Create temp directory for test artifacts
    export TEST_TEMP_DIR
    TEST_TEMP_DIR="$(mktemp -d)"

    # Disable colors in tests
    export TERM=dumb

    # Ensure we're not running as root in tests (safety)
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "Tests should not run as root"
    fi
}

# Common teardown for all tests
common_teardown() {
    # Clean up temp directory
    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "${TEST_TEMP_DIR}" ]]; then
        rm -rf "${TEST_TEMP_DIR}"
    fi
}

# =============================================================================
# Mock Functions
# =============================================================================

# Create a mock command that returns specified exit code and output
# Usage: create_mock <name> <exit_code> [output]
create_mock() {
    local name="$1"
    local exit_code="$2"
    local output="${3:-}"

    local mock_path="${TEST_TEMP_DIR}/mocks"
    mkdir -p "${mock_path}"

    cat > "${mock_path}/${name}" <<EOF
#!/usr/bin/env bash
echo "${output}"
exit ${exit_code}
EOF
    chmod +x "${mock_path}/${name}"

    # Add to PATH
    export PATH="${mock_path}:${PATH}"
}

# Create a mock that captures its arguments
# Usage: create_capturing_mock <name> <exit_code>
# Arguments are saved to ${TEST_TEMP_DIR}/mocks/<name>.args
create_capturing_mock() {
    local name="$1"
    local exit_code="${2:-0}"
    local output="${3:-}"

    local mock_path="${TEST_TEMP_DIR}/mocks"
    mkdir -p "${mock_path}"

    cat > "${mock_path}/${name}" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${mock_path}/${name}.args"
echo "${output}"
exit ${exit_code}
EOF
    chmod +x "${mock_path}/${name}"

    export PATH="${mock_path}:${PATH}"
}

# Get captured arguments from a mock
# Usage: get_mock_args <name>
get_mock_args() {
    local name="$1"
    local mock_path="${TEST_TEMP_DIR}/mocks"

    if [[ -f "${mock_path}/${name}.args" ]]; then
        cat "${mock_path}/${name}.args"
    fi
}

# =============================================================================
# Docker/Podman Mocking
# =============================================================================

# Mock Docker/Podman for unit tests
mock_docker() {
    local exit_code="${1:-0}"
    local output="${2:-}"

    create_mock "docker" "${exit_code}" "${output}"
    export DOCKER_CMD="docker"
}

mock_podman() {
    local exit_code="${1:-0}"
    local output="${2:-}"

    create_mock "podman" "${exit_code}" "${output}"
    export DOCKER_CMD="podman"
}

# =============================================================================
# Kind Mocking
# =============================================================================

mock_kind() {
    local exit_code="${1:-0}"
    local output="${2:-}"

    create_mock "kind" "${exit_code}" "${output}"
}

mock_kubectl() {
    local exit_code="${1:-0}"
    local output="${2:-}"

    create_mock "kubectl" "${exit_code}" "${output}"
}

# =============================================================================
# Assertion Helpers
# =============================================================================

# Assert that output contains a string
# Usage: assert_output_contains <substring>
assert_output_contains() {
    local substring="$1"
    if [[ "${output}" != *"${substring}"* ]]; then
        echo "Expected output to contain: ${substring}"
        echo "Actual output: ${output}"
        return 1
    fi
}

# Assert that output does not contain a string
# Usage: assert_output_not_contains <substring>
assert_output_not_contains() {
    local substring="$1"
    if [[ "${output}" == *"${substring}"* ]]; then
        echo "Expected output NOT to contain: ${substring}"
        echo "Actual output: ${output}"
        return 1
    fi
}

# Assert file exists and contains text
# Usage: assert_file_contains <file> <text>
assert_file_contains() {
    local file="$1"
    local text="$2"

    assert [ -f "${file}" ]
    run grep -q "${text}" "${file}"
    assert_success
}

# =============================================================================
# Source Library Helpers
# =============================================================================

# Source a library file with mocked dependencies
# Usage: source_lib <library_name>
source_lib() {
    local lib_name="$1"

    # Reset loaded flags to allow re-sourcing
    unset _COMMON_SH_LOADED
    unset _CLUSTER_SH_LOADED
    unset _NETWORK_SH_LOADED
    unset _REGISTRY_SH_LOADED

    # Set required variables that libraries expect
    export DOCKER_CMD="${DOCKER_CMD:-docker}"
    export DEBUG="${DEBUG:-false}"

    # Source the library
    source "${LIB_DIR}/${lib_name}"
}

# =============================================================================
# Integration Test Helpers
# =============================================================================

# Check if Docker is available
docker_is_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Check if Podman is available
podman_is_available() {
    command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1
}

# Check if Kind is available
kind_is_available() {
    command -v kind >/dev/null 2>&1
}

# Skip test if Docker is not available
require_docker() {
    if ! docker_is_available; then
        skip "Docker is not available"
    fi
}

# Skip test if Kind is not available
require_kind() {
    if ! kind_is_available; then
        skip "Kind is not available"
    fi
}

# Generate unique test cluster name
generate_test_cluster_name() {
    echo "test-cluster-$(date +%s)-$$"
}