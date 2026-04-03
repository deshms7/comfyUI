#!/bin/bash

# Docker CE Installation for Ubuntu 22
# Idempotent — skips if Docker daemon already running

function installDocker() {
    print_message "blue" "Installing Docker CE..."

    # Idempotent check (check-before-act pattern from nats-jetstream tasks)
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        print_message "blue" "SKIP: Docker already installed and running ($(docker --version))"
        return 0
    fi

    print_message "blue" "Adding Docker official GPG key and repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    # Dependency verify (from dependencies.sh:missing_count pattern)
    local missing=0
    for bin in docker dockerd containerd; do
        if ! command -v "$bin" &>/dev/null; then
            print_message "red" "Missing binary after install: $bin"
            missing=$((missing + 1))
        fi
    done
    [[ $missing -gt 0 ]] && die "Docker install verification failed ($missing missing binaries)"

    print_message "green" "Docker installed: $(docker --version)"
}

export -f installDocker
