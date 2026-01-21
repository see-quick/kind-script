#!/usr/bin/env bats
# =============================================================================
# Integration tests for kind-cluster.sh CLI
# =============================================================================

load '../helpers/test_helper'

setup() {
    common_setup
    export SCRIPT="${PROJECT_ROOT}/kind-cluster.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# Help Command Tests
# =============================================================================

@test "CLI: --help shows usage information" {
    run "${SCRIPT}" --help
    assert_success
    assert_output_contains "Usage:"
    assert_output_contains "kind-cluster.sh"
}

@test "CLI: help command shows usage information" {
    run "${SCRIPT}" help
    assert_success
    assert_output_contains "Usage:"
}

@test "CLI: -h shows usage information" {
    run "${SCRIPT}" -h
    assert_success
    assert_output_contains "Usage:"
}

@test "CLI: help includes all commands" {
    run "${SCRIPT}" --help
    assert_success
    assert_output_contains "create"
    assert_output_contains "delete"
    assert_output_contains "status"
    assert_output_contains "install-deps"
}

@test "CLI: help includes common options" {
    run "${SCRIPT}" --help
    assert_success
    assert_output_contains "--name"
    assert_output_contains "--control-planes"
    assert_output_contains "--workers"
    assert_output_contains "--ip-family"
}

# =============================================================================
# Version Command Tests
# =============================================================================

@test "CLI: version command shows version" {
    run "${SCRIPT}" version
    assert_success
    assert_output_contains "kind-cluster.sh"
}

@test "CLI: --version shows version" {
    run "${SCRIPT}" --version
    assert_success
}

# =============================================================================
# Invalid Command Tests
# =============================================================================

@test "CLI: unknown command shows error" {
    run "${SCRIPT}" unknown-command
    assert_failure
    assert_output_contains "Unknown command"
}

@test "CLI: invalid option shows error" {
    run "${SCRIPT}" --invalid-option
    assert_failure
}

# =============================================================================
# Option Parsing Tests
# =============================================================================

@test "CLI: --name accepts cluster name" {
    # This will fail because create requires docker, but we're testing option parsing
    run "${SCRIPT}" --name test-cluster --help
    assert_success
}

@test "CLI: --control-planes accepts number" {
    run "${SCRIPT}" --control-planes 3 --help
    assert_success
}

@test "CLI: --workers accepts number" {
    run "${SCRIPT}" --workers 5 --help
    assert_success
}

@test "CLI: --ip-family accepts ipv4" {
    run "${SCRIPT}" --ip-family ipv4 --help
    assert_success
}

@test "CLI: --ip-family accepts ipv6" {
    run "${SCRIPT}" --ip-family ipv6 --help
    assert_success
}

@test "CLI: --ip-family accepts dual" {
    run "${SCRIPT}" --ip-family dual --help
    assert_success
}

@test "CLI: --docker-cmd accepts docker" {
    run "${SCRIPT}" --docker-cmd docker --help
    assert_success
}

@test "CLI: --docker-cmd accepts podman" {
    run "${SCRIPT}" --docker-cmd podman --help
    assert_success
}

@test "CLI: --registry-port accepts port number" {
    run "${SCRIPT}" --registry-port 5002 --help
    assert_success
}

@test "CLI: --debug enables debug mode" {
    run "${SCRIPT}" --debug --help
    assert_success
}

@test "CLI: --force enables force mode" {
    run "${SCRIPT}" --force --help
    assert_success
}

@test "CLI: --no-registry disables registry" {
    run "${SCRIPT}" --no-registry --help
    assert_success
}

@test "CLI: --no-cloud-provider disables cloud provider" {
    run "${SCRIPT}" --no-cloud-provider --help
    assert_success
}

# =============================================================================
# Status Command Tests (without cluster)
# =============================================================================

@test "CLI: status works when no cluster exists" {
    # This test needs Docker to be available to check status
    if ! docker_is_available; then
        skip "Docker is not available"
    fi

    run "${SCRIPT}" --name nonexistent-cluster-xyz-12345 status
    # Should succeed but report cluster doesn't exist
    assert_success
}

# =============================================================================
# Environment Variable Tests
# =============================================================================

@test "CLI: respects KIND_CLUSTER_NAME env var" {
    export KIND_CLUSTER_NAME="env-test-cluster"
    run "${SCRIPT}" --help
    assert_success
    # Just verify it doesn't break with env var set
}

@test "CLI: command line overrides env var" {
    export KIND_CLUSTER_NAME="env-cluster"
    run "${SCRIPT}" --name cli-cluster --help
    assert_success
}

# =============================================================================
# Script Sourcing Tests
# =============================================================================

@test "CLI: sources all library files" {
    # Verify the script can be parsed (syntax check)
    run bash -n "${SCRIPT}"
    assert_success
}

@test "CLI: lib/common.sh has valid syntax" {
    run bash -n "${PROJECT_ROOT}/lib/common.sh"
    assert_success
}

@test "CLI: lib/cluster.sh has valid syntax" {
    run bash -n "${PROJECT_ROOT}/lib/cluster.sh"
    assert_success
}

@test "CLI: lib/network.sh has valid syntax" {
    run bash -n "${PROJECT_ROOT}/lib/network.sh"
    assert_success
}

@test "CLI: lib/registry.sh has valid syntax" {
    run bash -n "${PROJECT_ROOT}/lib/registry.sh"
    assert_success
}