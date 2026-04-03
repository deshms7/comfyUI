#!/bin/bash

# System Baseline Setup for ComfyUI on Ubuntu 22
# Adapted from scripts/node-setup/autodesk/rocky-linux-cpu/scripts/system-setup.sh

SENTINEL_DIR="/var/lib/illuma"

function setupSystem() {
    print_message "blue" "Running system baseline setup..."

    # Idempotent sentinel — skip if already done
    # (check-before-act pattern from ansible/roles/nats-jetstream/tasks/main.yml)
    local sentinel="${SENTINEL_DIR}/.system-baseline-done"
    if [[ -f "$sentinel" ]]; then
        print_message "blue" "SKIP: System baseline already applied"
        return 0
    fi

    mkdir -p "$SENTINEL_DIR"

    print_message "blue" "Updating apt cache..."
    apt-get update -qq

    print_message "blue" "Installing base packages..."
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        jq \
        wget \
        unzip \
        pciutils

    # System limits (from system-setup.sh:setupSystem)
    print_message "blue" "Applying system limits..."
    if ! grep -q "# ComfyUI setup" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<'EOF'
# ComfyUI setup
* soft nofile 65536
* hard nofile 65536
EOF
    fi

    # Sysctl tuning (from system-setup.sh:setupSystem)
    cat > /etc/sysctl.d/99-comfyui.conf <<'EOF'
vm.max_map_count=262144
fs.file-max=100000
EOF
    sysctl -p /etc/sysctl.d/99-comfyui.conf

    # Dedicated system user (from ansible/roles/render-cli/tasks/main.yml pattern)
    if ! id comfyui &>/dev/null; then
        print_message "blue" "Creating system user: comfyui"
        useradd --system --no-create-home --shell /usr/sbin/nologin comfyui
    else
        print_message "blue" "User comfyui already exists"
    fi

    touch "$sentinel"
    print_message "green" "System baseline complete"
}

export -f setupSystem
