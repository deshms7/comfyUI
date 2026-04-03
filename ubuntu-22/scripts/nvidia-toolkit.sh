#!/bin/bash

# NVIDIA Container Toolkit Installation for Ubuntu 22
# Enables GPU access inside Docker containers
#
# Handles Blackwell GPUs (RTX 5000 series) which require:
#   - nvidia-driver-*-open (open kernel modules)
#   - NVreg_EnableGpuFirmware=0 (no GSP firmware shipped for Blackwell in 590 driver)

SENTINEL_DIR="${SENTINEL_DIR:-/var/lib/illuma}"

function installNvidiaToolkit() {
    print_message "blue" "Installing NVIDIA Container Toolkit..."

    # Idempotent sentinel (same pattern as system-setup.sh)
    local sentinel="${SENTINEL_DIR}/.nvidia-toolkit-done"
    if [[ -f "$sentinel" ]]; then
        print_message "blue" "SKIP: nvidia-container-toolkit already installed"
        configureDockerNvidiaRuntime
        return 0
    fi

    # Install NVIDIA driver if not present
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null 2>&1; then
        print_message "yellow" "nvidia-smi not found — installing nvidia-driver-590-open..."
        apt-get update -qq
        apt-get install -y --no-install-recommends nvidia-driver-590-open
        print_message "green" "NVIDIA driver installed."
        echo ""
        print_message "yellow" "A reboot is required to load the driver."
        print_message "yellow" "Please reboot the machine and re-run the script:"
        print_message "yellow" "  sudo reboot"
        print_message "yellow" "  sudo bash /tmp/comfyui-setup/install.sh"
        exit 0
    fi
    print_message "green" "GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

    # Blackwell GPUs (RTX 5000 series, PCI ID 2b8x) require open kernel modules and
    # NVreg_EnableGpuFirmware=0 because the 590 driver package does not ship
    # Blackwell GSP firmware (gsp_gb10x.bin). Persist fix across reboots.
    _apply_blackwell_fix_if_needed

    print_message "blue" "Adding NVIDIA container toolkit repository..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit

    configureDockerNvidiaRuntime

    touch "$sentinel"
    print_message "green" "NVIDIA Container Toolkit installed"
}

# Detect Blackwell GPU and apply the GSP firmware workaround if needed.
# Safe to call on non-Blackwell machines — exits immediately if not needed.
function _apply_blackwell_fix_if_needed() {
    # Blackwell GPUs report RmInitAdapter failed when GSP firmware is enabled
    # because the driver does not include gsp_gb10x.bin.
    # Check: does /usr/lib/firmware/nvidia/<ver>/ lack a gb10x firmware file?
    local driver_ver
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    local firmware_dir="/usr/lib/firmware/nvidia/${driver_ver}"
    local fix_file="/etc/modprobe.d/nvidia-blackwell.conf"

    if [[ -f "$fix_file" ]]; then
        print_message "blue" "Blackwell GSP fix already applied"
        return 0
    fi

    if [[ -d "$firmware_dir" ]] && ! ls "$firmware_dir"/gsp_gb*.bin &>/dev/null 2>&1; then
        print_message "yellow" "Blackwell GPU detected without GSP firmware — applying NVreg_EnableGpuFirmware=0 fix"
        echo 'options nvidia NVreg_EnableGpuFirmware=0' > "$fix_file"
        update-initramfs -u -k "$(uname -r)" 2>&1 | tail -2

        # Reload the module with the new flag — only safe if no process holds the device open
        if lsof /dev/nvidia* &>/dev/null 2>&1; then
            print_message "yellow" "GPU device is in use — cannot reload module live. Reboot required for NVreg_EnableGpuFirmware=0 to take effect."
        else
            modprobe -r nvidia_uvm nvidia 2>/dev/null || true
            modprobe nvidia
            print_message "green" "Blackwell GSP fix applied and module reloaded"
        fi
    fi
}

function configureDockerNvidiaRuntime() {
    print_message "blue" "Configuring Docker NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    # GPU smoke test inside Docker
    print_message "blue" "Running GPU smoke test inside Docker..."
    if docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 \
            nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
            | grep -q "."; then
        print_message "green" "GPU accessible inside Docker"
    else
        die "GPU not accessible inside Docker — check NVIDIA runtime configuration"
    fi
}

export -f installNvidiaToolkit
export -f configureDockerNvidiaRuntime
export -f _apply_blackwell_fix_if_needed
