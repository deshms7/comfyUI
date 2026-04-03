#!/bin/bash

# Phase 9: Add My Packages
# Installs additional packages on the host machine.
#
# Packages installed:
#   - Google Chrome (stable) — via the official Google apt repository
#
# Also places IllumaComfyUI.html user guide on the desktop of REMOTE_ACCESS_USER.

SENTINEL_DIR="${SENTINEL_DIR:-/var/lib/illuma}"
REMOTE_ACCESS_USER="${REMOTE_ACCESS_USER:-user}"

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function addPackages() {
    local sentinel="${SENTINEL_DIR}/.add-packages-done"

    if [[ -f "$sentinel" ]]; then
        print_message "blue" "SKIP: Add my packages already installed"
        return 0
    fi

    _installChrome

    _validateChrome

    _placeGuideOnDesktop

    touch "$sentinel"
    print_message "green" "Add my packages complete"
}

# ---------------------------------------------------------------------------
# Google Chrome
# ---------------------------------------------------------------------------

function _installChrome() {
    if command -v google-chrome-stable &>/dev/null; then
        print_message "blue" "Google Chrome already installed: $(google-chrome-stable --version)"
        return 0
    fi

    print_message "blue" "Installing Google Chrome (stable)..."

    # Add Google's signing key
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add -

    # Add the Chrome apt repository
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
        | tee /etc/apt/sources.list.d/google-chrome.list

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable || \
        die "Failed to install google-chrome-stable"

    print_message "green" "Google Chrome installed: $(google-chrome-stable --version)"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

function _validateChrome() {
    print_message "blue" "Validating Google Chrome..."

    # Confirm the binary is on PATH
    if ! command -v google-chrome-stable &>/dev/null; then
        die "Validation failed: google-chrome-stable binary not found on PATH"
    fi

    # Confirm it reports a version (catches broken installs)
    local version
    version=$(google-chrome-stable --version 2>/dev/null) || \
        die "Validation failed: google-chrome-stable --version returned non-zero"

    if [[ -z "$version" ]]; then
        die "Validation failed: google-chrome-stable --version returned empty output"
    fi

    print_message "green" "Chrome validation passed: $version"
}

# ---------------------------------------------------------------------------
# Desktop guide
# ---------------------------------------------------------------------------

function _placeGuideOnDesktop() {
    print_message "blue" "Placing IllumaComfyUI.html guide on desktop..."

    local desktop_dir="/home/${REMOTE_ACCESS_USER}/Desktop"
    local guide_src="${SCRIPT_DIR}/IllumaComfyUI.html"
    local guide_dst="${desktop_dir}/IllumaComfyUI.html"

    # Create Desktop directory if it doesn't exist yet
    mkdir -p "$desktop_dir"

    if [[ ! -f "$guide_src" ]]; then
        print_message "yellow" "IllumaComfyUI.html not found at $guide_src — skipping desktop placement"
        return 0
    fi

    cp "$guide_src" "$guide_dst"
    chown "${REMOTE_ACCESS_USER}:${REMOTE_ACCESS_USER}" "$guide_dst"
    chmod 644 "$guide_dst"

    print_message "green" "Guide placed at: $guide_dst"
}

export -f addPackages
export -f _installChrome
export -f _validateChrome
export -f _placeGuideOnDesktop
