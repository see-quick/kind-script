#!/usr/bin/env bash
# =============================================================================
# common.sh - Common utility functions for kind-cluster script
# =============================================================================

# Prevent multiple sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
readonly _COMMON_SH_LOADED=1

# =============================================================================
# Color Definitions
# =============================================================================
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[0;37m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly WHITE=''
    readonly BOLD=''
    readonly NC=''
fi

# =============================================================================
# Logging Functions
# =============================================================================

# Get current timestamp
_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Log info message
info() {
    echo -e "${GREEN}[INFO]${NC} $(_timestamp) - $*"
}

# Log warning message
warn() {
    echo -e "${YELLOW}[WARN]${NC} $(_timestamp) - $*" >&2
}

# Log error message
err() {
    echo -e "${RED}[ERROR]${NC} $(_timestamp) - $*" >&2
}

# Log error and exit
err_and_exit() {
    err "$@"
    exit 1
}

# Log debug message (only if DEBUG is set)
debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $(_timestamp) - $*"
    fi
}

# Log a section header
section() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $* ===${NC}"
    echo ""
}

# Log success message
success() {
    echo -e "${GREEN}[OK]${NC} $(_timestamp) - $*"
}

# =============================================================================
# Platform Detection
# =============================================================================

# Detect the current operating system
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Detect system architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "arm"
            ;;
        *)
            echo "${arch}"
            ;;
    esac
}

# Export detected values
OS=$(detect_os)
ARCH=$(detect_arch)
export OS ARCH

# =============================================================================
# Tool Detection and Setup
# =============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Require a command to exist, exit if not found
require_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command_exists "${cmd}"; then
        if [[ -n "${install_hint}" ]]; then
            err_and_exit "Required command '${cmd}' not found. ${install_hint}"
        else
            err_and_exit "Required command '${cmd}' not found."
        fi
    fi
}

# Setup platform-specific tools (especially for macOS)
setup_platform_tools() {
    if [[ "${OS}" == "macos" ]]; then
        # Use GNU tools if available on macOS
        if command_exists gfind; then
            FIND_CMD="gfind"
        else
            FIND_CMD="find"
        fi

        if command_exists gsed; then
            SED_CMD="gsed"
        else
            SED_CMD="sed"
        fi

        if command_exists gawk; then
            AWK_CMD="gawk"
        else
            AWK_CMD="awk"
        fi

        if command_exists gdate; then
            DATE_CMD="gdate"
        else
            DATE_CMD="date"
        fi
    else
        FIND_CMD="find"
        SED_CMD="sed"
        AWK_CMD="awk"
        DATE_CMD="date"
    fi

    export FIND_CMD SED_CMD AWK_CMD DATE_CMD
}

# Initialize platform tools
setup_platform_tools

# =============================================================================
# Utility Functions
# =============================================================================

# Check if running as root
is_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# Run command with sudo if not root
maybe_sudo() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# Retry a command with exponential backoff
# Usage: retry <max_attempts> <delay> <command...>
retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2

    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if "$@"; then
            return 0
        fi

        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "Attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
            sleep "${delay}"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    err "Command failed after ${max_attempts} attempts: $*"
    return 1
}

# Wait for a condition to be true
# Usage: wait_for <timeout_seconds> <check_command...>
wait_for() {
    local timeout="$1"
    local interval="${2:-5}"
    shift 2

    local elapsed=0
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    err "Timeout waiting for condition: $*"
    return 1
}

# Check if a string is a valid IPv4 address
is_valid_ipv4() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ${ip} =~ ${regex} ]]; then
        local IFS='.'
        read -ra octets <<< "${ip}"
        for octet in "${octets[@]}"; do
            if [[ ${octet} -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Check if a string is a valid IPv6 address (simplified check)
is_valid_ipv6() {
    local ip="$1"
    # Simplified check - contains colons and valid hex characters
    [[ ${ip} =~ ^[0-9a-fA-F:]+$ ]] && [[ ${ip} == *:* ]]
}

# Generate a random string
random_string() {
    local length="${1:-16}"
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${length}"
}

# Confirm action with user
# Usage: confirm "Are you sure?" [default: y/n]
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "${default}" == "y" ]]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi

    read -r -p "${prompt}" response
    response="${response:-${default}}"

    [[ "${response}" =~ ^[Yy]$ ]]
}

# =============================================================================
# Cleanup and Signal Handling
# =============================================================================

# Array to hold cleanup functions
declare -a _CLEANUP_FUNCTIONS=()

# Register a cleanup function
register_cleanup() {
    _CLEANUP_FUNCTIONS+=("$1")
}

# Run all registered cleanup functions
run_cleanup() {
    local exit_code=$?
    for func in "${_CLEANUP_FUNCTIONS[@]}"; do
        if declare -F "${func}" >/dev/null; then
            debug "Running cleanup function: ${func}"
            "${func}" || true
        fi
    done
    exit "${exit_code}"
}

# Setup signal handlers
setup_signal_handlers() {
    trap run_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# =============================================================================
# Version Comparison
# =============================================================================

# Compare two semantic versions
# Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
version_compare() {
    local v1="$1"
    local v2="$2"

    # Remove 'v' prefix if present
    v1="${v1#v}"
    v2="${v2#v}"

    if [[ "${v1}" == "${v2}" ]]; then
        return 0
    fi

    local IFS='.'
    read -ra v1_parts <<< "${v1}"
    read -ra v2_parts <<< "${v2}"

    local max_parts=${#v1_parts[@]}
    if [[ ${#v2_parts[@]} -gt ${max_parts} ]]; then
        max_parts=${#v2_parts[@]}
    fi

    for ((i = 0; i < max_parts; i++)); do
        local p1="${v1_parts[i]:-0}"
        local p2="${v2_parts[i]:-0}"

        # Remove any non-numeric suffix
        p1="${p1%%[^0-9]*}"
        p2="${p2%%[^0-9]*}"

        if [[ ${p1} -gt ${p2} ]]; then
            return 1
        elif [[ ${p1} -lt ${p2} ]]; then
            return 2
        fi
    done

    return 0
}

# Check if version is at least minimum required
version_at_least() {
    local version="$1"
    local minimum="$2"

    version_compare "${version}" "${minimum}"
    local result=$?

    [[ ${result} -eq 0 ]] || [[ ${result} -eq 1 ]]
}
