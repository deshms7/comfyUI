#!/bin/bash

# ComfyUI on Ubuntu 22 - Main Installation Script
# Installs ComfyUI via Docker with GPU support, managed as a systemd service
#
# Usage:
#   sudo bash install.sh
#   COMFYUI_IMAGE="ghcr.io/ai-dock/comfyui:latest" sudo -E bash install.sh
#   COMFYUI_PORT=8080 sudo -E bash install.sh

set -euo pipefail

# Script directory — same pattern as autodesk/rocky-linux/install.sh
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source all required scripts (mirrors rocky-linux install.sh source block)
source "$SCRIPT_DIR/scripts/common.sh"
source "$SCRIPT_DIR/scripts/system-setup.sh"
source "$SCRIPT_DIR/scripts/docker-install.sh"
source "$SCRIPT_DIR/scripts/nvidia-toolkit.sh"
source "$SCRIPT_DIR/scripts/comfyui-service.sh"
source "$SCRIPT_DIR/scripts/validate.sh"
source "$SCRIPT_DIR/scripts/workflow-test.sh"
source "$SCRIPT_DIR/scripts/remote-access.sh"
source "$SCRIPT_DIR/scripts/add-packages.sh"

function main() {
    echo "====== ComfyUI Ubuntu 22 Setup ======"

    # Must run as root (same gate as autodesk install.sh)
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Use: sudo bash install.sh"
        exit 1
    fi

    # OS gate
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
            echo "Warning: This script is designed for Ubuntu 22.04 (detected: ${PRETTY_NAME:-unknown})"
            echo -n "Continue anyway? [y/N]: "
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi

    # Pre-flight: system requirements and GPU check
    echo ""
    echo "=== Pre-flight Checks ==="
    check_system_requirements 4 8

    if ! lspci | grep -qi nvidia; then
        die "No NVIDIA GPU detected via lspci"
    fi
    print_message "green" "GPU: NVIDIA device present"

    # Installation plan
    echo ""
    echo "=== Installation Plan ==="
    echo "  Image:    ${COMFYUI_IMAGE:-ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04}"
    echo "  Port:     ${COMFYUI_PORT:-8188}"
    echo "  Data dir: ${DATA_DIR:-/data/comfyui}"
    echo ""
    echo "  1. Pre-flight checks (OS, CPU, RAM, GPU)"
    echo "  2. System baseline (packages, sysctl, comfyui user)"
    echo "  3. Docker CE"
    echo "  4. NVIDIA Container Toolkit"
    echo "  4b. PyTorch GPU compatibility (cu128 upgrade for Blackwell if needed)"
    echo "  5. ComfyUI container + systemd service"
    echo "  6. Validation (container, port, GPU)"
    echo "  7. Workflow test (download SD1.5 model, run txt2img, verify output)"
    echo "  8. Remote access client setup (XFCE desktop, Parsec host, Reemo agent, firewall)"
    echo "  9. Add my packages (Google Chrome, IllumaComfyUI.html desktop guide)"
    echo ""
    echo -n "Continue? [y/N]: "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 1
    fi

    trap cleanup_temp_files EXIT
    setup_logging

    # Phase 2: System baseline
    print_message "blue" "=== Phase 2: System Baseline ==="
    setupSystem

    # Phase 3: Docker
    print_message "blue" "=== Phase 3: Docker CE ==="
    installDocker

    # Phase 4: NVIDIA Container Toolkit
    print_message "blue" "=== Phase 4: NVIDIA Container Toolkit ==="
    installNvidiaToolkit

    # Phase 5: ComfyUI service
    print_message "blue" "=== Phase 5: ComfyUI Service ==="
    setupComfyUI

    # Phase 4b: PyTorch GPU compatibility upgrade
    # Upgrades torch to cu128 inside the container if the GPU requires it (e.g. Blackwell sm_120).
    # Safe no-op on GPUs already supported by the image's bundled torch version.
    print_message "blue" "=== Phase 4b: PyTorch GPU Compatibility ==="
    upgradeContainerPyTorch

    # Phase 6: Validation
    print_message "blue" "=== Phase 6: Validation ==="
    validateComfyUI

    # Phase 7: Workflow test
    print_message "blue" "=== Phase 7: Workflow Test ==="
    runWorkflowTest

    # Phase 8: Remote access client setup (Reemo + Parsec)
    print_message "blue" "=== Phase 8: Remote Access Client Setup ==="
    installRemoteAccess

    # Phase 9: Add my packages
    print_message "blue" "=== Phase 9: Add My Packages ==="
    addPackages

    print_message "green" "Installation complete!"
}

main "$@"
