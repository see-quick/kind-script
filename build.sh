#!/usr/bin/env bash
# =============================================================================
# build.sh - Bundle kind-cluster.sh and lib files into a single distribution
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

OUTPUT_DIR="${SCRIPT_DIR}/dist"
OUTPUT_FILE="${OUTPUT_DIR}/kind-cluster.sh"

# =============================================================================
# Utility Functions
# =============================================================================

info() {
    echo "[INFO] $*" >&2
}

err() {
    echo "[ERROR] $*" >&2
}

# =============================================================================
# Build Logic
# =============================================================================

build_bundle() {
    local main_script="${SCRIPT_DIR}/kind-cluster.sh"
    local lib_dir="${SCRIPT_DIR}/lib"

    # Validate input files exist
    if [[ ! -f "${main_script}" ]]; then
        err "Main script not found: ${main_script}"
        exit 1
    fi

    if [[ ! -d "${lib_dir}" ]]; then
        err "Library directory not found: ${lib_dir}"
        exit 1
    fi

    # Create output directory
    mkdir -p "${OUTPUT_DIR}"

    info "Building bundled script..."
    info "  Input:  ${main_script}"
    info "  Output: ${OUTPUT_FILE}"

    # Start writing to output file
    : > "${OUTPUT_FILE}"  # Truncate/create file

    local in_script_dir_block=false
    local line_num=0

    # Process main script line by line
    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Track SCRIPT_DIR block (assignment + readonly)
        if [[ "${line}" =~ ^SCRIPT_DIR= ]]; then
            in_script_dir_block=true
            continue  # Skip this line
        fi

        if [[ "${in_script_dir_block}" == "true" ]] && [[ "${line}" =~ ^readonly[[:space:]]+SCRIPT_DIR ]]; then
            in_script_dir_block=false
            continue  # Skip this line
        fi

        # Skip shellcheck source directives for lib files
        if [[ "${line}" =~ ^#[[:space:]]*shellcheck[[:space:]]+source=./lib/ ]]; then
            continue
        fi

        # Inline library files when we hit a source line
        if [[ "${line}" =~ ^source[[:space:]]+.*SCRIPT_DIR.*/lib/(.+)\.sh ]]; then
            local lib_file="${BASH_REMATCH[1]}.sh"
            local lib_path="${lib_dir}/${lib_file}"

            if [[ ! -f "${lib_path}" ]]; then
                err "Library file not found: ${lib_path}"
                exit 1
            fi

            info "  Inlining: lib/${lib_file}"

            # Add a comment marker
            echo "" >> "${OUTPUT_FILE}"
            echo "# ==============================================================================" >> "${OUTPUT_FILE}"
            echo "# Inlined from lib/${lib_file}" >> "${OUTPUT_FILE}"
            echo "# ==============================================================================" >> "${OUTPUT_FILE}"

            # Process library file
            local in_lib=false
            while IFS= read -r lib_line; do
                # Skip shebang
                if [[ "${lib_line}" =~ ^#!/ ]]; then
                    continue
                fi

                # Skip sourcing guard (both lines)
                if [[ "${lib_line}" =~ ^\[\[[[:space:]]-n[[:space:]]+.*_LOADED.*return[[:space:]]+0 ]]; then
                    continue
                fi
                if [[ "${lib_line}" =~ ^readonly[[:space:]]+_.*_LOADED=1 ]]; then
                    continue
                fi

                # Skip _*_LIB_DIR assignments
                if [[ "${lib_line}" =~ ^_.*_LIB_DIR= ]]; then
                    continue
                fi

                # Skip shellcheck directives for common.sh
                if [[ "${lib_line}" =~ ^#[[:space:]]*shellcheck[[:space:]]+source=./common.sh ]]; then
                    continue
                fi

                # Skip source lines to common.sh
                if [[ "${lib_line}" =~ ^source[[:space:]]+.*_LIB_DIR.*/common.sh ]]; then
                    continue
                fi

                # Write the line
                echo "${lib_line}" >> "${OUTPUT_FILE}"
            done < "${lib_path}"

            echo "" >> "${OUTPUT_FILE}"
            continue
        fi

        # Write the line from main script
        echo "${line}" >> "${OUTPUT_FILE}"
    done < "${main_script}"

    # Make executable
    chmod +x "${OUTPUT_FILE}"

    # Get file size
    local file_size
    if [[ "$(uname)" == "Darwin" ]]; then
        file_size=$(stat -f%z "${OUTPUT_FILE}")
    else
        file_size=$(stat -c%s "${OUTPUT_FILE}")
    fi

    info "Build complete!"
    info "  Output: ${OUTPUT_FILE}"
    info "  Size:   ${file_size} bytes"
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    build_bundle
}

main "$@"
