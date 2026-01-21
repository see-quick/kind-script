#!/usr/bin/env bats
# =============================================================================
# Integration tests for cluster operations (requires Docker/Kind)
#
# These tests require Docker and Kind to be installed and running.
# They will be skipped if these dependencies are not available.
# =============================================================================

load '../helpers/test_helper'

# Test cluster name - unique per test run
TEST_CLUSTER_NAME=""

setup() {
    common_setup

    # Skip all tests if Docker is not available
    if ! docker_is_available; then
        skip "Docker is not available"
    fi

    # Skip if kind is not available
    if ! kind_is_available; then
        skip "Kind is not available"
    fi

    export SCRIPT="${PROJECT_ROOT}/kind-cluster.sh"
    TEST_CLUSTER_NAME="test-$(date +%s)-$$"
}

teardown() {
    # Clean up test cluster if it exists
    if [[ -n "${TEST_CLUSTER_NAME}" ]] && kind_is_available; then
        kind delete cluster --name "${TEST_CLUSTER_NAME}" 2>/dev/null || true
    fi

    # Clean up test registry if it exists
    if docker_is_available; then
        docker rm -f "${TEST_CLUSTER_NAME}-registry" 2>/dev/null || true
    fi

    common_teardown
}

# =============================================================================
# Cluster Creation Tests
# =============================================================================

@test "INTEGRATION: create minimal cluster" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    assert_success
    assert_output_contains "created successfully"

    # Verify cluster exists
    run kind get clusters
    assert_output_contains "${TEST_CLUSTER_NAME}"
}

@test "INTEGRATION: create cluster with registry" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 1 \
        --no-cloud-provider \
        create

    assert_success

    # Verify registry is running
    run docker ps --filter "name=${TEST_CLUSTER_NAME}-registry" --format "{{.Names}}"
    assert_output_contains "registry"
}

@test "INTEGRATION: create idempotent - second create is no-op" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    # First create
    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create
    assert_success

    # Second create should succeed (idempotent)
    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create
    assert_success
    assert_output_contains "already exists"
}

# =============================================================================
# Cluster Status Tests
# =============================================================================

@test "INTEGRATION: status shows cluster info" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    # Create cluster first
    "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    run "${SCRIPT}" --name "${TEST_CLUSTER_NAME}" status
    assert_success
    assert_output_contains "${TEST_CLUSTER_NAME}"
}

@test "INTEGRATION: status for nonexistent cluster" {
    run "${SCRIPT}" --name "nonexistent-cluster-12345" status
    assert_success
    assert_output_contains "does not exist"
}

# =============================================================================
# Cluster Deletion Tests
# =============================================================================

@test "INTEGRATION: delete removes cluster" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    # Create cluster first
    "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    # Delete it
    run "${SCRIPT}" --name "${TEST_CLUSTER_NAME}" delete
    assert_success
    assert_output_contains "deleted successfully"

    # Verify cluster is gone
    run kind get clusters
    refute_output "${TEST_CLUSTER_NAME}"
}

@test "INTEGRATION: delete nonexistent cluster is no-op" {
    run "${SCRIPT}" --name "nonexistent-cluster-12345" delete
    assert_success
    assert_output_contains "does not exist"
}

# =============================================================================
# Force Recreation Tests
# =============================================================================

@test "INTEGRATION: force recreates cluster" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    # Create cluster first
    "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    # Force recreate
    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 1 \
        --no-registry \
        --no-cloud-provider \
        --force \
        create

    assert_success

    # Verify new worker count
    run kubectl get nodes --context "kind-${TEST_CLUSTER_NAME}" --no-headers
    local node_count
    node_count=$(echo "$output" | wc -l | tr -d ' ')
    assert [ "$node_count" -eq 2 ]
}

# =============================================================================
# Multi-node Cluster Tests
# =============================================================================

@test "INTEGRATION: create multi-control-plane cluster" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 3 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    assert_success

    # Verify control plane count
    run kubectl get nodes --context "kind-${TEST_CLUSTER_NAME}" -l node-role.kubernetes.io/control-plane --no-headers
    local cp_count
    cp_count=$(echo "$output" | wc -l | tr -d ' ')
    assert [ "$cp_count" -eq 3 ]
}

@test "INTEGRATION: create cluster with multiple workers" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    run "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 3 \
        --no-registry \
        --no-cloud-provider \
        create

    assert_success

    # Verify total node count
    run kubectl get nodes --context "kind-${TEST_CLUSTER_NAME}" --no-headers
    local node_count
    node_count=$(echo "$output" | wc -l | tr -d ' ')
    assert [ "$node_count" -eq 4 ]
}

# =============================================================================
# Network Tests
# =============================================================================

@test "INTEGRATION: cluster network is created" {
    skip "Integration test - run manually with: ./test/run_tests.sh integration"

    "${SCRIPT}" \
        --name "${TEST_CLUSTER_NAME}" \
        --control-planes 1 \
        --workers 0 \
        --no-registry \
        --no-cloud-provider \
        create

    # Verify kind network exists
    run docker network ls --filter "name=kind" --format "{{.Name}}"
    assert_output_contains "kind"
}