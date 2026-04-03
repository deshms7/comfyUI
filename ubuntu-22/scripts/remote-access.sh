#!/bin/bash

# Phase 8: Remote Access Client Setup — Reemo + Parsec
#
# Installs Reemo agent and Parsec host on the VM so it can be accessed
# remotely as a full GPU-accelerated desktop.
#
# What this phase does:
#   1. Installs a lightweight desktop environment (XFCE) + display manager (LightDM)
#   2. Configures a virtual X11 display driven by the NVIDIA GPU (headless / no monitor)
#   3. Installs and configures the Parsec host
#   4. Installs and registers the Reemo agent
#   5. Opens required firewall ports via ufw
#   6. Enables all remote access client services to start on boot
#
# Required environment variables:
#   REEMO_AGENT_TOKEN     Reemo Personal Key or Studio Key — obtain from the Reemo dashboard
#                         (reemo.io/download → copy your key)
#
# Optional environment variables:
#   PARSEC_TEAM_ID        Parsec Teams ID — for managed/shared host registration
#   PARSEC_TEAM_SECRET    Parsec Teams secret (paired with PARSEC_TEAM_ID)
#   REMOTE_ACCESS_USER    OS user that will own the desktop session (default: comfyui)

SENTINEL_DIR="${SENTINEL_DIR:-/var/lib/illuma}"
REMOTE_ACCESS_USER="${REMOTE_ACCESS_USER:-comfyui}"

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function installRemoteAccess() {
    local sentinel="${SENTINEL_DIR}/.remote-access-done"

    if [[ -f "$sentinel" ]]; then
        print_message "blue" "SKIP: Remote access client setup already installed"
        return 0
    fi

    # REEMO_AGENT_TOKEN is mandatory — fail early with a clear message
    if [[ -z "${REEMO_AGENT_TOKEN:-}" ]]; then
        die "REEMO_AGENT_TOKEN is not set. \
Obtain your Personal Key or Studio Key from reemo.io/download \
and re-run with: REEMO_AGENT_TOKEN=<key> sudo -E bash install.sh"
    fi

    _installDesktop
    _configureNvidiaVirtualDisplay
    _installParsec
    _installReemo
    _configureFirewall
    _enableRemoteAccessServices

    touch "$sentinel"
    print_message "green" "Remote access client setup complete — Reemo and Parsec host are running"
}

# ---------------------------------------------------------------------------
# 1. Desktop environment (XFCE + LightDM, headless-safe)
# ---------------------------------------------------------------------------

function _installDesktop() {
    print_message "blue" "Installing XFCE desktop and LightDM..."

    # xfce4          — lightweight desktop (no extras like office suite)
    # xfce4-goodies  — useful panel plugins, terminal, etc.
    # lightdm        — display manager; lighter than gdm3, works headless
    # lightdm-gtk-greeter — default greeter (avoids the unity-greeter dep)
    # dbus-x11       — required for X11 session bus
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xfce4 \
        xfce4-goodies \
        lightdm \
        lightdm-gtk-greeter \
        dbus-x11 \
        x11-xserver-utils \
        xterm \
        2>/dev/null

    # Set LightDM as the default display manager (avoids interactive prompt)
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>/dev/null || true

    # Auto-login as REMOTE_ACCESS_USER so the desktop is always ready for
    # Parsec/Reemo to connect to without a greeter password step.
    # NOTE: This is intentional for a headless GPU VM — the desktop session
    # itself is not reachable from the network without Parsec/Reemo auth.
    local lightdm_conf="/etc/lightdm/lightdm.conf"
    cat > "$lightdm_conf" <<EOF
[Seat:*]
autologin-user=${REMOTE_ACCESS_USER}
autologin-user-timeout=0
user-session=xfce
EOF

    print_message "green" "XFCE + LightDM installed (auto-login: ${REMOTE_ACCESS_USER})"
}

# ---------------------------------------------------------------------------
# 2. NVIDIA virtual display (headless — no physical monitor required)
# ---------------------------------------------------------------------------

function _configureNvidiaVirtualDisplay() {
    print_message "blue" "Configuring NVIDIA virtual display (headless X11)..."

    # Discover the GPU PCI Bus ID in the format Xorg expects (decimal, colon-separated)
    # lspci output: "01:00.0 VGA compatible controller: NVIDIA ..."
    # Xorg BusID format: "PCI:1:0:0"
    local pci_slot
    pci_slot=$(lspci | grep -i "vga.*nvidia\|nvidia.*vga\|3d.*nvidia\|nvidia.*3d" \
        | head -1 | awk '{print $1}') || true

    if [[ -z "$pci_slot" ]]; then
        die "Cannot detect NVIDIA GPU PCI slot via lspci — is the driver installed?"
    fi

    # Convert "BB:DD.F" → "PCI:BB_dec:DD_dec:F_dec"
    # e.g. "01:00.0" → "PCI:1:0:0"
    local bus dev func
    bus=$(printf "%d" "0x$(echo "$pci_slot" | cut -d: -f1)")
    dev=$(printf "%d" "0x$(echo "$pci_slot" | cut -d: -f2 | cut -d. -f1)")
    func=$(printf "%d" "0x$(echo "$pci_slot" | cut -d. -f2)")
    local xorg_busid="PCI:${bus}:${dev}:${func}"

    print_message "blue" "GPU PCI slot: ${pci_slot} → Xorg BusID: ${xorg_busid}"

    # Write the Xorg config.
    # AllowEmptyInitialConfiguration — required when no monitor is attached.
    # ConnectedMonitor — tricks the driver into treating the GPU as if a
    # monitor is connected (virtual framebuffer driven by the GPU).
    # Virtual resolution 1920x1080 is a safe default; Parsec/Reemo can
    # renegotiate resolution dynamically once connected.
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/20-nvidia-headless.conf <<EOF
Section "ServerLayout"
    Identifier "layout"
    Screen 0 "Screen0"
EndSection

Section "Device"
    Identifier  "GPU0"
    Driver      "nvidia"
    BusID       "${xorg_busid}"
    Option      "AllowEmptyInitialConfiguration" "true"
    Option      "ConnectedMonitor" "DFP-0"
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync   28.0 - 80.0
    VertRefresh 48.0 - 75.0
    Modeline    "1920x1080_60" 172.80 1920 2040 2248 2576 1080 1081 1084 1118 -HSync +Vsync
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "GPU0"
    Monitor    "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth    24
        Modes    "1920x1080_60"
        Virtual  1920 1080
    EndSubSection
EndSection
EOF

    print_message "green" "Xorg virtual display configured (${xorg_busid}, 1920×1080)"
}

# ---------------------------------------------------------------------------
# 3. Parsec host
# ---------------------------------------------------------------------------

function _installParsec() {
    print_message "blue" "Installing Parsec host..."

    # Parsec publishes a Debian package for the Linux client/host.
    # The same binary runs as both client and shared host.
    local parsec_deb="/tmp/parsec-linux.deb"
    wget --quiet --show-progress \
        -O "$parsec_deb" \
        "https://builds.parsec.app/package/parsec-linux.deb" || \
        die "Failed to download Parsec package"

    DEBIAN_FRONTEND=noninteractive apt-get install -y "$parsec_deb" 2>/dev/null || \
        die "Failed to install Parsec"
    rm -f "$parsec_deb"

    # Write a minimal Parsec config for headless hosting.
    # The config file lives in the session user's home directory.
    local parsec_config_dir="/home/${REMOTE_ACCESS_USER}/.parsec"
    mkdir -p "$parsec_config_dir"

    # encoder_h265 = 1 prefers H.265 (HEVC) — more efficient on NVIDIA GPUs.
    # host_virtual_monitors = 1 enables the virtual monitor needed on headless.
    # host_privacy_mode = 0 disables the blanked-screen privacy mode.
    # If PARSEC_TEAM_ID is supplied, include managed-host keys.
    local team_block=""
    if [[ -n "${PARSEC_TEAM_ID:-}" && -n "${PARSEC_TEAM_SECRET:-}" ]]; then
        team_block=$(cat <<EOF
"app_host_team_id": "${PARSEC_TEAM_ID}",
"app_host_team_secret": "${PARSEC_TEAM_SECRET}",
EOF
)
    fi

    cat > "${parsec_config_dir}/config.json" <<EOF
{
    "encoder_h265": 1,
    "host_virtual_monitors": 1,
    "host_privacy_mode": 0,
    "host_windowed": 0,
    ${team_block}
    "app_first_run": 0
}
EOF

    chown -R "${REMOTE_ACCESS_USER}:${REMOTE_ACCESS_USER}" "$parsec_config_dir"

    # Parsec runs as a user-space process, not a system daemon.
    # We create a systemd user service that starts Parsec inside the user session
    # after LightDM has established the XFCE session.
    local systemd_user_dir="/home/${REMOTE_ACCESS_USER}/.config/systemd/user"
    mkdir -p "$systemd_user_dir"

    cat > "${systemd_user_dir}/parsec.service" <<EOF
[Unit]
Description=Parsec Remote Desktop Host
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/parsecd app_daemon=1
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0

[Install]
WantedBy=graphical-session.target
EOF

    chown -R "${REMOTE_ACCESS_USER}:${REMOTE_ACCESS_USER}" \
        "/home/${REMOTE_ACCESS_USER}/.config"

    # Enable lingering so the user's systemd instance starts at boot
    # (without requiring an interactive login).
    loginctl enable-linger "${REMOTE_ACCESS_USER}" 2>/dev/null || true

    print_message "green" "Parsec host installed"
    if [[ -n "${PARSEC_TEAM_ID:-}" ]]; then
        print_message "green" "  Parsec Teams: team ID ${PARSEC_TEAM_ID} configured"
    else
        print_message "yellow" "  No PARSEC_TEAM_ID set — log in manually via the Parsec app after install"
    fi
}

# ---------------------------------------------------------------------------
# 4. Reemo agent
# ---------------------------------------------------------------------------

function _installReemo() {
    print_message "blue" "Installing Reemo agent..."

    # Download Reemo's official setup script for Debian/Ubuntu and run it
    # with --key to register this machine against the provided token.
    # Source: https://reemo.io/download → Linux (Debian/Ubuntu)
    local reemo_setup="/tmp/reemo.x"
    curl -sL -o "$reemo_setup" \
        "https://download.reemo.io/linux/deb/setup.x" || \
        die "Failed to download Reemo setup script from download.reemo.io"

    print_message "blue" "Registering Reemo agent (key: ${REEMO_AGENT_TOKEN:0:8}...)"
    bash "$reemo_setup" --key "${REEMO_AGENT_TOKEN}" || \
        die "Reemo setup failed — check REEMO_AGENT_TOKEN (Personal Key or Studio Key)"

    rm -f "$reemo_setup"

    print_message "green" "Reemo agent installed and registered"
}

# ---------------------------------------------------------------------------
# 5. Firewall (ufw)
# ---------------------------------------------------------------------------

function _configureFirewall() {
    print_message "blue" "Configuring firewall (ufw)..."

    # Install ufw if absent
    if ! command -v ufw &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y ufw 2>/dev/null
    fi

    # Always allow SSH first — prevents locking ourselves out when enabling ufw
    ufw allow 22/tcp comment "SSH"

    # ComfyUI web UI
    ufw allow "${COMFYUI_PORT:-8188}/tcp" comment "ComfyUI"

    # Parsec:
    #   UDP 8000   — primary game-streaming data channel
    #   TCP 443    — authentication and signaling via Parsec cloud (outbound;
    #                ufw allows all outbound by default, listed here for documentation)
    ufw allow 8000/udp comment "Parsec streaming"

    # Reemo:
    #   Reemo uses outbound HTTPS (TCP 443) and WebRTC (UDP 3478 STUN + dynamic
    #   ephemeral UDP for the media channel). Inbound rules are only needed when
    #   the server acts as the WebRTC peer endpoint behind a symmetric NAT.
    #   Most cloud VMs have a direct public IP so no inbound rule is required,
    #   but we open STUN/TURN ports defensively.
    ufw allow 3478/udp  comment "Reemo STUN"
    ufw allow 3478/tcp  comment "Reemo STUN/TURN TCP"
    ufw allow 5349/tcp  comment "Reemo TURN TLS"

    # Enable ufw (non-interactively; --force skips the "may disrupt existing
    # SSH connections" prompt — safe because we already allowed port 22 above)
    ufw --force enable

    ufw status verbose
    print_message "green" "Firewall configured"
}

# ---------------------------------------------------------------------------
# 6. Enable services
# ---------------------------------------------------------------------------

function _enableRemoteAccessServices() {
    print_message "blue" "Enabling remote access client services..."

    # LightDM (display manager → XFCE session)
    systemctl enable lightdm
    systemctl start  lightdm || \
        print_message "yellow" "LightDM did not start cleanly — check: systemctl status lightdm"

    # Reemo agent system service (if registered by the package installer)
    if systemctl list-unit-files reemod.service &>/dev/null; then
        systemctl enable reemo-agent
        systemctl start  reemo-agent || \
            print_message "yellow" "reemo-agent did not start — check: systemctl status reemod"
    fi

    # Parsec runs as a user-space service; instruct systemd to start it
    # once the user session is established.
    # (loginctl enable-linger was already called in _installParsec)
    sudo -u "${REMOTE_ACCESS_USER}" \
        systemctl --user enable parsec.service 2>/dev/null || \
        print_message "yellow" "Could not enable parsec.service for user ${REMOTE_ACCESS_USER} — \
start it manually after first login: systemctl --user start parsec"

    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')

    print_message "green" "Remote access client services enabled"
    echo ""
    print_message "blue" "=== Remote Access Client Setup Summary ==="
    print_message "blue" "  Parsec:   log in at https://parsec.app → Computers → this machine"
    print_message "blue" "  Reemo:    open the Reemo dashboard — this VM should appear as online"
    print_message "blue" "  Desktop:  XFCE session auto-logged-in as '${REMOTE_ACCESS_USER}'"
    print_message "blue" "  Display:  1920×1080 virtual (GPU: headless mode)"
    print_message "blue" "  Host IP:  ${host_ip}"
    echo ""
    print_message "blue" "Useful commands:"
    print_message "blue" "  LightDM status:      systemctl status lightdm"
    print_message "blue" "  Reemo agent status:  systemctl status reemod"
    print_message "blue" "  Parsec status:       sudo -u ${REMOTE_ACCESS_USER} systemctl --user status parsec"
    print_message "blue" "  Firewall rules:      ufw status verbose"
}

export -f installRemoteAccess
export -f _installDesktop
export -f _configureNvidiaVirtualDisplay
export -f _installParsec
export -f _installReemo
export -f _configureFirewall
export -f _enableRemoteAccessServices
