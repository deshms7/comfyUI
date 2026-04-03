#!/bin/bash

# Common Functions Script - Shared utilities for ComfyUI Ubuntu 22 setup
# Adapted from scripts/node-setup/autodesk/rocky-linux/scripts/common.sh

# Print colored message
function print_message() {
    local color="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$color" in
        "red")    echo -e "[$timestamp] \033[0;31m[ERROR]\033[0m   $message" ;;
        "green")  echo -e "[$timestamp] \033[0;32m[SUCCESS]\033[0m $message" ;;
        "yellow") echo -e "[$timestamp] \033[1;33m[WARN]\033[0m    $message" ;;
        "blue")   echo -e "[$timestamp] \033[0;34m[INFO]\033[0m    $message" ;;
        *)        echo -e "[$timestamp] $message" ;;
    esac
}

# Setup logging — redirect all output to log file while keeping console output
# (same tee pattern as common.sh:setup_logging)
function setup_logging() {
    local log_dir="/var/log/illuma"
    mkdir -p "$log_dir"

    local log_file="$log_dir/comfyui-setup-$(date +%Y%m%d-%H%M%S).log"

    exec > >(tee -a "$log_file")
    exec 2>&1

    print_message "blue" "Log file: $log_file"
}

# Check disk space — fail if below required threshold
# Args: $1 = required_gb (default 30)
function check_disk_space() {
    local required_gb="${1:-30}"
    local available_gb
    available_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

    if [[ $available_gb -lt $required_gb ]]; then
        print_message "red" "Insufficient disk space — Required: ${required_gb}GB, Available: ${available_gb}GB"
        return 1
    fi

    print_message "green" "Disk space: ${available_gb}GB available"
    return 0
}

# Check system requirements — CPU cores and RAM
# Args: $1 = min_cores (default 4), $2 = min_ram_gb (default 8)
function check_system_requirements() {
    local min_cores="${1:-4}"
    local min_ram_gb="${2:-8}"

    print_message "blue" "Checking system requirements..."

    local cpu_cores
    cpu_cores=$(nproc)
    if [[ $cpu_cores -lt $min_cores ]]; then
        print_message "yellow" "Warning: ${cpu_cores} CPU cores found (${min_cores}+ recommended)"
    else
        print_message "green" "CPU cores: $cpu_cores"
    fi

    local total_ram
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $total_ram -lt $min_ram_gb ]]; then
        print_message "red" "Insufficient RAM — ${total_ram}GB found, ${min_ram_gb}GB required"
        return 1
    fi
    print_message "green" "RAM: ${total_ram}GB"

    check_disk_space

    return 0
}

# Clean up temporary files created during setup
function cleanup_temp_files() {
    print_message "blue" "Cleaning up temporary files..."
    rm -f /tmp/comfyui-setup-*
    apt-get clean -qq 2>/dev/null || true
    print_message "green" "Cleanup complete"
}

# Hard exit with error message
function die() {
    print_message "red" "$*"
    exit 1
}

# Export all functions so they're available in sourcing scripts
export -f print_message
export -f setup_logging
export -f check_disk_space
export -f check_system_requirements
export -f cleanup_temp_files
export -f die
