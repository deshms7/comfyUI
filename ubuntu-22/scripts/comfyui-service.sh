#!/bin/bash

# ComfyUI Docker Container + Systemd Service Setup
# Systemd unit structure from ansible/roles/render-cli/templates/illuma-cli.service.j2

DATA_DIR="${DATA_DIR:-/data/comfyui}"
COMFYUI_IMAGE="${COMFYUI_IMAGE:-ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
SERVICE_NAME="comfyui"
SENTINEL_DIR="${SENTINEL_DIR:-/var/lib/illuma}"

# Fixed UI credentials — static across restarts
WEB_USER="${WEB_USER:-illuma}"
WEB_PASSWORD="${WEB_PASSWORD:-illuma}"
WEB_TOKEN="${WEB_TOKEN:-illumaCloud}"

# Name of the committed local image that bakes in the PyTorch upgrade.
# Once committed, this image is used for all future container starts so the
# upgrade is never lost across restarts or VM reboots.
COMFYUI_COMMITTED_IMAGE="illuma-comfyui:cu128"

function setupComfyUI() {
    print_message "blue" "Setting up ComfyUI container and systemd service..."

    # Volume directories — idempotent (mkdir -p)
    # ai-dock image runs ComfyUI as uid=1000, gid=1111 (ai-dock group)
    print_message "blue" "Creating volume directories at $DATA_DIR..."
    mkdir -p "${DATA_DIR}"/{models,outputs,custom_nodes,logs}
    chown -R 1000:1111 "$DATA_DIR"
    chmod -R 775 "$DATA_DIR"

    # Pull image — docker pull is a no-op if digest already matches
    print_message "blue" "Pulling ComfyUI image: $COMFYUI_IMAGE"
    docker pull "$COMFYUI_IMAGE"

    # Log image digest for auditability
    local digest
    digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$COMFYUI_IMAGE" 2>/dev/null \
        || echo "not-available")
    print_message "blue" "Image digest: $digest"

    writeSystemdService
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"

    # Start or restart cleanly
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        print_message "blue" "Restarting existing $SERVICE_NAME service..."
        systemctl restart "${SERVICE_NAME}.service"
    else
        systemctl start "${SERVICE_NAME}.service"
    fi

    print_message "green" "ComfyUI service started"
}

function writeSystemdService() {
    # Use the committed image if it exists (has PyTorch cu128 baked in),
    # otherwise fall back to the upstream base image.
    local image_to_use="$COMFYUI_IMAGE"
    if docker image inspect "$COMFYUI_COMMITTED_IMAGE" &>/dev/null; then
        image_to_use="$COMFYUI_COMMITTED_IMAGE"
        print_message "blue" "Using committed image: $COMFYUI_COMMITTED_IMAGE"
    else
        print_message "blue" "Committed image not found — using base image: $COMFYUI_IMAGE"
    fi

    print_message "blue" "Writing systemd unit: /etc/systemd/system/${SERVICE_NAME}.service"

    # Unit structure mirrors ansible/roles/render-cli/templates/illuma-cli.service.j2:
    # Restart=always, RestartSec=10, NoNewPrivileges=true, StandardOutput=journal
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ComfyUI Docker Service
Documentation=https://github.com/comfyanonymous/ComfyUI
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=300

# Clean up any existing container before starting
ExecStartPre=-/usr/bin/docker stop ${SERVICE_NAME}
ExecStartPre=-/usr/bin/docker rm ${SERVICE_NAME}

ExecStart=/usr/bin/docker run \\
    --name ${SERVICE_NAME} \\
    --gpus all \\
    -p ${COMFYUI_PORT}:8188 \\
    -v ${DATA_DIR}/models:/opt/ComfyUI/models \\
    -v ${DATA_DIR}/outputs:/opt/ComfyUI/output \\
    -v ${DATA_DIR}/custom_nodes:/opt/ComfyUI/custom_nodes \\
    --shm-size=2g \\
    -e WEB_USER=${WEB_USER} \\
    -e WEB_PASSWORD=${WEB_PASSWORD} \\
    -e WEB_TOKEN=${WEB_TOKEN} \\
    -e WEB_ENABLE_AUTH=true \\
    ${image_to_use}

ExecStop=/usr/bin/docker stop ${SERVICE_NAME}

NoNewPrivileges=true
LimitNOFILE=65536

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

# Upgrade PyTorch inside the running container to a version that supports the
# host GPU's compute capability. Required for Blackwell GPUs (sm_120) which need
# torch cu128 (2.11+). Safe no-op on older GPUs that are already compatible.
function upgradeContainerPyTorch() {
    local pip="/opt/environments/python/comfyui/bin/pip"
    local python="/opt/environments/python/comfyui/bin/python"
    local sentinel="${SENTINEL_DIR}/.pytorch-cu128-done"

    # Sentinel is keyed to the running container's image digest.
    # If the container was recreated with a new image, the pip install is gone
    # and we must re-upgrade. Compare stored digest vs current container digest.
    local current_digest
    current_digest=$(docker inspect --format='{{index .RepoDigests 0}}' \
        "$(docker inspect --format='{{.Image}}' "${SERVICE_NAME}" 2>/dev/null)" \
        2>/dev/null || echo "unknown")

    if [[ -f "$sentinel" ]] && grep -qF "$current_digest" "$sentinel" 2>/dev/null; then
        print_message "blue" "SKIP: PyTorch cu128 upgrade already applied for this image"
        return 0
    fi

    # Wait for container to be ready to accept exec commands
    local attempt=0
    until docker exec "${SERVICE_NAME}" echo ok &>/dev/null; do
        attempt=$((attempt + 1))
        [[ $attempt -ge 12 ]] && die "Container not ready for exec after 60s"
        sleep 5
    done

    # Check if current torch already supports the GPU's compute capability
    local compat_check
    compat_check=$(docker exec "${SERVICE_NAME}" "$python" -W ignore -c '
import torch, warnings
warnings.filterwarnings("ignore")
if not torch.cuda.is_available():
    print("no_cuda")
else:
    major, minor = torch.cuda.get_device_capability()
    sm = f"sm_{major}{minor}"
    supported = getattr(torch.cuda, "get_arch_list", lambda: [])()
    print("ok" if any(sm in a for a in supported) else f"upgrade_needed:{sm}")
' 2>/dev/null || echo "check_failed")

    if [[ "$compat_check" == "ok" ]]; then
        print_message "green" "PyTorch already compatible with GPU — no upgrade needed"
        echo "$current_digest" > "$sentinel"
        return 0
    fi

    if [[ "$compat_check" == "check_failed" ]]; then
        print_message "yellow" "PyTorch compatibility check failed — skipping upgrade (CUDA may not be ready yet)"
        return 0
    fi

    print_message "yellow" "PyTorch GPU compatibility: $compat_check — upgrading to cu128..."
    docker exec "${SERVICE_NAME}" "$pip" install --quiet \
        torch==2.7.0+cu128 torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu128

    # Commit the container with the upgraded PyTorch baked in so that
    # every future restart (service restart, VM reboot) uses this image
    # and never loses the upgrade again.
    print_message "blue" "Committing container as ${COMFYUI_COMMITTED_IMAGE}..."
    docker commit \
        --message "PyTorch 2.7.0+cu128 — ${compat_check} GPU support" \
        "${SERVICE_NAME}" \
        "${COMFYUI_COMMITTED_IMAGE}" || \
        die "Failed to commit container as ${COMFYUI_COMMITTED_IMAGE}"
    print_message "green" "Container committed as ${COMFYUI_COMMITTED_IMAGE}"

    # Rewrite the systemd service to use the committed image and restart
    writeSystemdService
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}.service"
    sleep 15

    echo "$current_digest" > "$sentinel"
    print_message "green" "PyTorch upgraded to cu128, committed, and service updated to use ${COMFYUI_COMMITTED_IMAGE}"
}

export -f setupComfyUI
export -f writeSystemdService
export -f upgradeContainerPyTorch
