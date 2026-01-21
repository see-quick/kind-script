#!/usr/bin/env bash
# =============================================================================
# run_tests.sh - Test runner for kind-script
#
# Uses BATS (Bash Automated Testing System) for testing bash scripts
#
# Usage:
#   ./test/run_tests.sh              # Run all tests
#   ./test/run_tests.sh unit         # Run unit tests only
#   ./test/run_tests.sh integration  # Run integration tests only
#   ./test/run_tests.sh --help       # Show help
#
# Author: Maros Orsak
# =============================================================================

set -euo pipefail

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BATS_DIR="${SCRIPT_DIR}/.bats"

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi

# =============================================================================
# Helper Functions
# =============================================================================

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

err() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $* ===${NC}"
    echo ""
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [TEST_TYPE]

Run tests for kind-script using BATS (Bash Automated Testing System).

TEST_TYPE:
  unit          Run unit tests only (default: all)
  integration   Run integration tests only (requires Docker/Podman)
  all           Run all tests

OPTIONS:
  -h, --help        Show this help message
  -v, --verbose     Verbose output (show all test output)
  -t, --tap         Output in TAP format
  -f, --filter      Filter tests by name pattern
  --no-install      Don't install BATS if missing
  --clean           Remove installed BATS and exit

EXAMPLES:
  $(basename "$0")                    # Run all tests
  $(basename "$0") unit               # Run unit tests only
  $(basename "$0") -v unit            # Run unit tests with verbose output
  $(basename "$0") -f "ipv4"          # Run tests matching "ipv4"
  $(basename "$0") --clean            # Remove BATS installation

EOF
    exit 0
}

# =============================================================================
# BATS Installation
# =============================================================================

bats_is_installed() {
    [[ -x "${BATS_DIR}/bats-core/bin/bats" ]]
}

install_bats() {
    section "Installing BATS"

    mkdir -p "${BATS_DIR}"
    cd "${BATS_DIR}"

    # Clone BATS core
    if [[ ! -d "bats-core" ]]; then
        info "Cloning bats-core..."
        git clone --depth 1 https://github.com/bats-core/bats-core.git
    fi

    # Clone BATS support libraries
    if [[ ! -d "bats-support" ]]; then
        info "Cloning bats-support..."
        git clone --depth 1 https://github.com/bats-core/bats-support.git
    fi

    if [[ ! -d "bats-assert" ]]; then
        info "Cloning bats-assert..."
        git clone --depth 1 https://github.com/bats-core/bats-assert.git
    fi

    if [[ ! -d "bats-file" ]]; then
        info "Cloning bats-file..."
        git clone --depth 1 https://github.com/bats-core/bats-file.git
    fi

    cd "${SCRIPT_DIR}"

    info "BATS installed successfully"
}

clean_bats() {
    if [[ -d "${BATS_DIR}" ]]; then
        info "Removing BATS installation..."
        rm -rf "${BATS_DIR}"
        info "BATS removed"
    else
        info "BATS is not installed"
    fi
    exit 0
}

# =============================================================================
# Test Runner
# =============================================================================

run_tests() {
    local test_type="$1"
    local bats_args=("${@:2}")

    local bats="${BATS_DIR}/bats-core/bin/bats"

    # Ensure BATS is installed
    if ! bats_is_installed; then
        if [[ "${NO_INSTALL:-false}" == "true" ]]; then
            err "BATS is not installed. Run without --no-install to install it."
            exit 1
        fi
        install_bats
    fi

    # Export paths for test helpers
    export BATS_SUPPORT="${BATS_DIR}/bats-support"
    export BATS_ASSERT="${BATS_DIR}/bats-assert"
    export BATS_FILE="${BATS_DIR}/bats-file"
    export PROJECT_ROOT

    # Collect test files
    local test_files=()

    case "${test_type}" in
        unit)
            section "Running Unit Tests"
            if [[ -d "${SCRIPT_DIR}/unit" ]]; then
                while IFS= read -r -d '' file; do
                    test_files+=("$file")
                done < <(find "${SCRIPT_DIR}/unit" -name "*.bats" -print0 | sort -z)
            fi
            ;;
        integration)
            section "Running Integration Tests"
            if [[ -d "${SCRIPT_DIR}/integration" ]]; then
                while IFS= read -r -d '' file; do
                    test_files+=("$file")
                done < <(find "${SCRIPT_DIR}/integration" -name "*.bats" -print0 | sort -z)
            fi
            ;;
        all|"")
            section "Running All Tests"
            if [[ -d "${SCRIPT_DIR}/unit" ]]; then
                while IFS= read -r -d '' file; do
                    test_files+=("$file")
                done < <(find "${SCRIPT_DIR}/unit" -name "*.bats" -print0 | sort -z)
            fi
            if [[ -d "${SCRIPT_DIR}/integration" ]]; then
                while IFS= read -r -d '' file; do
                    test_files+=("$file")
                done < <(find "${SCRIPT_DIR}/integration" -name "*.bats" -print0 | sort -z)
            fi
            ;;
        *)
            err "Unknown test type: ${test_type}"
            usage
            ;;
    esac

    if [[ ${#test_files[@]} -eq 0 ]]; then
        warn "No test files found for type: ${test_type:-all}"
        exit 0
    fi

    info "Found ${#test_files[@]} test file(s)"
    echo ""

    # Run BATS
    "${bats}" "${bats_args[@]}" "${test_files[@]}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local test_type=""
    local bats_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--verbose)
                bats_args+=("--verbose-run")
                shift
                ;;
            -t|--tap)
                bats_args+=("--tap")
                shift
                ;;
            -f|--filter)
                bats_args+=("--filter" "$2")
                shift 2
                ;;
            --no-install)
                NO_INSTALL=true
                shift
                ;;
            --clean)
                clean_bats
                ;;
            unit|integration|all)
                test_type="$1"
                shift
                ;;
            *)
                err "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Default to running all tests
    run_tests "${test_type:-all}" "${bats_args[@]}"
}

main "$@"