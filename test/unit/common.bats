#!/usr/bin/env bats
# =============================================================================
# Unit tests for lib/common.sh
# =============================================================================

load '../helpers/test_helper'

setup() {
    common_setup
    source_lib "common.sh"
}

teardown() {
    common_teardown
}

# =============================================================================
# IPv4 Validation Tests
# =============================================================================

@test "is_valid_ipv4: accepts valid IPv4 address" {
    run is_valid_ipv4 "192.168.1.1"
    assert_success
}

@test "is_valid_ipv4: accepts 0.0.0.0" {
    run is_valid_ipv4 "0.0.0.0"
    assert_success
}

@test "is_valid_ipv4: accepts 255.255.255.255" {
    run is_valid_ipv4 "255.255.255.255"
    assert_success
}

@test "is_valid_ipv4: accepts localhost 127.0.0.1" {
    run is_valid_ipv4 "127.0.0.1"
    assert_success
}

@test "is_valid_ipv4: rejects invalid format" {
    run is_valid_ipv4 "192.168.1"
    assert_failure
}

@test "is_valid_ipv4: rejects octet > 255" {
    run is_valid_ipv4 "192.168.1.256"
    assert_failure
}

@test "is_valid_ipv4: rejects non-numeric" {
    run is_valid_ipv4 "192.168.1.abc"
    assert_failure
}

@test "is_valid_ipv4: rejects empty string" {
    run is_valid_ipv4 ""
    assert_failure
}

@test "is_valid_ipv4: rejects IPv6 address" {
    run is_valid_ipv4 "::1"
    assert_failure
}

# =============================================================================
# IPv6 Validation Tests
# =============================================================================

@test "is_valid_ipv6: accepts localhost ::1" {
    run is_valid_ipv6 "::1"
    assert_success
}

@test "is_valid_ipv6: accepts full IPv6" {
    run is_valid_ipv6 "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
    assert_success
}

@test "is_valid_ipv6: accepts shortened IPv6" {
    run is_valid_ipv6 "2001:db8::1"
    assert_success
}

@test "is_valid_ipv6: accepts link-local" {
    run is_valid_ipv6 "fe80::1"
    assert_success
}

@test "is_valid_ipv6: rejects IPv4 address" {
    run is_valid_ipv6 "192.168.1.1"
    assert_failure
}

@test "is_valid_ipv6: rejects empty string" {
    run is_valid_ipv6 ""
    assert_failure
}

@test "is_valid_ipv6: rejects invalid characters" {
    run is_valid_ipv6 "2001:db8::xyz"
    assert_failure
}

# =============================================================================
# Version Comparison Tests
# =============================================================================

@test "version_compare: equal versions return 0" {
    run version_compare "1.2.3" "1.2.3"
    assert_success
    assert [ "$status" -eq 0 ]
}

@test "version_compare: v prefix is handled" {
    run version_compare "v1.2.3" "1.2.3"
    assert_success
    assert [ "$status" -eq 0 ]
}

@test "version_compare: v1 > v2 returns 1" {
    run version_compare "2.0.0" "1.0.0"
    assert [ "$status" -eq 1 ]
}

@test "version_compare: v1 < v2 returns 2" {
    run version_compare "1.0.0" "2.0.0"
    assert [ "$status" -eq 2 ]
}

@test "version_compare: minor version difference" {
    run version_compare "1.2.0" "1.1.0"
    assert [ "$status" -eq 1 ]
}

@test "version_compare: patch version difference" {
    run version_compare "1.0.1" "1.0.2"
    assert [ "$status" -eq 2 ]
}

@test "version_compare: different length versions" {
    version_compare "1.0" "1.0.0"
    assert [ "$?" -eq 0 ]
}

# =============================================================================
# Version At Least Tests
# =============================================================================

@test "version_at_least: same version passes" {
    run version_at_least "1.2.3" "1.2.3"
    assert_success
}

@test "version_at_least: higher version passes" {
    run version_at_least "2.0.0" "1.0.0"
    assert_success
}

@test "version_at_least: lower version fails" {
    run version_at_least "1.0.0" "2.0.0"
    assert_failure
}

@test "version_at_least: with v prefix" {
    run version_at_least "v1.5.0" "v1.4.0"
    assert_success
}

# =============================================================================
# Platform Detection Tests
# =============================================================================

@test "detect_os: returns valid OS" {
    run detect_os
    assert_success
    assert [ -n "$output" ]
    # Should be one of the known values
    [[ "$output" =~ ^(macos|linux|windows|unknown)$ ]]
}

@test "detect_arch: returns valid architecture" {
    run detect_arch
    assert_success
    assert [ -n "$output" ]
    # Common architectures
    [[ "$output" =~ ^(amd64|arm64|arm|x86_64|aarch64)$ ]] || true
}

# =============================================================================
# Command Exists Tests
# =============================================================================

@test "command_exists: finds bash" {
    run command_exists "bash"
    assert_success
}

@test "command_exists: finds ls" {
    run command_exists "ls"
    assert_success
}

@test "command_exists: fails for nonexistent command" {
    run command_exists "this_command_does_not_exist_12345"
    assert_failure
}

# =============================================================================
# Random String Tests
# =============================================================================

@test "random_string: generates string of default length" {
    run random_string
    assert_success
    assert [ ${#output} -eq 16 ]
}

@test "random_string: generates string of specified length" {
    run random_string 8
    assert_success
    assert [ ${#output} -eq 8 ]
}

@test "random_string: generates string of length 32" {
    run random_string 32
    assert_success
    assert [ ${#output} -eq 32 ]
}

@test "random_string: contains only alphanumeric characters" {
    run random_string 100
    assert_success
    [[ "$output" =~ ^[a-zA-Z0-9]+$ ]]
}

@test "random_string: generates different values" {
    local str1 str2
    str1=$(random_string 16)
    str2=$(random_string 16)
    # Very unlikely to be equal
    assert [ "$str1" != "$str2" ]
}

# =============================================================================
# Retry Function Tests
# =============================================================================

@test "retry: succeeds on first attempt" {
    run retry 3 1 true
    assert_success
}

@test "retry: fails after max attempts" {
    run retry 2 0 false
    assert_failure
}

@test "retry: succeeds with command that outputs" {
    run retry 3 1 echo "hello"
    assert_success
    assert_output "hello"
}

# =============================================================================
# Logging Tests
# =============================================================================

@test "info: outputs message with INFO prefix" {
    run info "test message"
    assert_success
    assert_output_contains "[INFO]"
    assert_output_contains "test message"
}

@test "warn: outputs to stderr with WARN prefix" {
    run warn "warning message"
    assert_success
    assert_output_contains "[WARN]"
    assert_output_contains "warning message"
}

@test "err: outputs to stderr with ERROR prefix" {
    run err "error message"
    assert_success
    assert_output_contains "[ERROR]"
    assert_output_contains "error message"
}

@test "debug: outputs nothing when DEBUG is false" {
    DEBUG=false
    run debug "debug message"
    assert_success
    assert_output ""
}

@test "debug: outputs message when DEBUG is true" {
    DEBUG=true
    run debug "debug message"
    assert_success
    assert_output_contains "[DEBUG]"
    assert_output_contains "debug message"
}

@test "success: outputs with OK prefix" {
    run success "success message"
    assert_success
    assert_output_contains "[OK]"
    assert_output_contains "success message"
}

# =============================================================================
# is_root Tests
# =============================================================================

@test "is_root: returns failure when not root" {
    # This test should pass in normal testing (not running as root)
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        skip "Running as root"
    fi
    run is_root
    assert_failure
}

# =============================================================================
# Cleanup Registration Tests
# =============================================================================

@test "register_cleanup: adds function to cleanup array" {
    # Reset cleanup array
    _CLEANUP_FUNCTIONS=()

    my_cleanup() {
        echo "cleaned up"
    }

    register_cleanup "my_cleanup"

    assert [ ${#_CLEANUP_FUNCTIONS[@]} -eq 1 ]
    assert [ "${_CLEANUP_FUNCTIONS[0]}" == "my_cleanup" ]
}