#!/bin/bash
# spaces/download-spaces.sh
#
# Pulls ComfyUI models, custom nodes, and Python venv from DO Spaces
# onto a freshly provisioned Ubuntu machine.
#
# Called from install.sh --from-spaces, or standalone.
#
# What it does:
#   1. Syncs models → /data/comfyui/models/
#   2. Syncs custom_nodes code → /data/comfyui/custom_nodes/
#   3. Restores container venv → docker exec extract into running container
#
# IMPORTANT: Call steps 1+2 BEFORE starting the ComfyUI container (volumes must
# be populated first). Call step 3 AFTER the container is running.
#
# Usage:
#   DO_SPACES_KEY=xxx DO_SPACES_SECRET=xxx bash download-spaces.sh
#   bash download-spaces.sh --key xxx --secret xxx
#   bash download-spaces.sh --skip-site-packages   # models + nodes only
#
# Flags:
#   --skip-models         skip model sync
#   --skip-nodes          skip custom_nodes sync
#   --skip-site-packages  skip container venv restore
#   --container NAME      Docker container name (default: comfyui)
#   --data-dir PATH       ComfyUI data directory (default: /data/comfyui)

set -euo pipefail

BUCKET="pfx-comfyui-assets"
PREFIX="comfy_models_nodes"
REGION="tor1"
CONTAINER="comfyui"
DATA_DIR="/data/comfyui"
LOG="/var/log/illuma/spaces-download.log"
TEMP_DIR="/tmp/illuma-spaces"
SKIP_MODELS=false
SKIP_NODES=false
SKIP_SITE_PACKAGES=false

# ── Parse args ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --key)           DO_SPACES_KEY="$2";    shift 2 ;;
        --secret)        DO_SPACES_SECRET="$2"; shift 2 ;;
        --container)     CONTAINER="$2";        shift 2 ;;
        --data-dir)      DATA_DIR="$2";         shift 2 ;;
        --skip-models)   SKIP_MODELS=true;      shift ;;
        --skip-nodes)    SKIP_NODES=true;       shift ;;
        --skip-site-packages) SKIP_SITE_PACKAGES=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DO_SPACES_KEY="${DO_SPACES_KEY:-}"
DO_SPACES_SECRET="${DO_SPACES_SECRET:-}"

if [[ -z "$DO_SPACES_KEY" || -z "$DO_SPACES_SECRET" ]]; then
    echo "ERROR: credentials required. Set DO_SPACES_KEY / DO_SPACES_SECRET or pass --key / --secret." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG")" "$TEMP_DIR"
mkdir -p "${DATA_DIR}"/{models,custom_nodes,outputs,logs}
chown -R 1000:1111 "$DATA_DIR" 2>/dev/null || true

log() {
    local color="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%H:%M:%S')
    case "$color" in
        green)  echo -e "\033[0;32m[$ts] $msg\033[0m" | tee -a "$LOG" ;;
        yellow) echo -e "\033[0;33m[$ts] $msg\033[0m" | tee -a "$LOG" ;;
        red)    echo -e "\033[0;31m[$ts] $msg\033[0m" | tee -a "$LOG" ;;
        cyan)   echo -e "\033[0;36m[$ts] $msg\033[0m" | tee -a "$LOG" ;;
        *)      echo "[$ts] $msg" | tee -a "$LOG" ;;
    esac
}

# ── Step 1: Install rclone ──────────────────────────────────────────────
if ! command -v rclone &>/dev/null; then
    log cyan "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash
    log green "rclone installed: $(rclone --version | head -1)"
else
    log cyan "rclone: $(rclone --version | head -1)"
fi

# ── Step 2: Configure rclone ────────────────────────────────────────────
RCLONE_CONF="$TEMP_DIR/rclone.conf"
cat > "$RCLONE_CONF" <<EOF
[spaces]
type = s3
provider = DigitalOcean
access_key_id = ${DO_SPACES_KEY}
secret_access_key = ${DO_SPACES_SECRET}
endpoint = ${REGION}.digitaloceanspaces.com
acl = private
EOF

REMOTE="spaces:${BUCKET}/${PREFIX}"

REMOTE_VERSION=$(rclone cat "${REMOTE}/version.txt" --config "$RCLONE_CONF" 2>/dev/null || echo "unknown")
log cyan "=== ComfyUI Spaces Download ==="
log cyan "Remote         : $REMOTE"
log cyan "Remote version : $REMOTE_VERSION"
log cyan "Data dir       : $DATA_DIR"

# ── Step 3: Sync models ─────────────────────────────────────────────────
if [[ "$SKIP_MODELS" == "false" ]]; then
    log cyan "=== Syncing models from Spaces ==="
    # Pre-create standard model subdirs
    for d in diffusion_models clip vae loras checkpoints upscale_models \
              vae_approx controlnet ipadapter clip_vision sams; do
        mkdir -p "${DATA_DIR}/models/${d}"
    done
    mkdir -p "${DATA_DIR}/models/ultralytics/bbox" \
             "${DATA_DIR}/models/ultralytics/segm"

    rclone sync \
        "${REMOTE}/models" "${DATA_DIR}/models" \
        --config "$RCLONE_CONF" \
        --transfers 8 \
        --size-only \
        --progress \
        --log-file "$LOG" --log-level INFO
    # Fix ownership after sync so Docker container (uid 1000) can read
    chown -R 1000:1111 "${DATA_DIR}/models" 2>/dev/null || true
    log green "Models sync complete"
else
    log yellow "SKIP: models (--skip-models)"
fi

# ── Step 4: Sync custom_nodes code ─────────────────────────────────────
if [[ "$SKIP_NODES" == "false" ]]; then
    log cyan "=== Syncing custom_nodes from Spaces ==="
    mkdir -p "${DATA_DIR}/custom_nodes"

    rclone sync \
        "${REMOTE}/custom_nodes" "${DATA_DIR}/custom_nodes" \
        --config "$RCLONE_CONF" \
        --transfers 8 \
        --size-only \
        --progress \
        --log-file "$LOG" --log-level INFO
    chown -R 1000:1111 "${DATA_DIR}/custom_nodes" 2>/dev/null || true
    log green "custom_nodes sync complete"
else
    log yellow "SKIP: custom_nodes (--skip-nodes)"
fi

# ── Step 5: Restore container venv site-packages ────────────────────────
# This step requires the container to be running.
# If the container is not running yet, skip and let the caller run it later
# via: bash download-spaces.sh --skip-models --skip-nodes
if [[ "$SKIP_SITE_PACKAGES" == "false" ]]; then
    log cyan "=== Restoring container venv site-packages ==="

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
        log yellow "Container '$CONTAINER' is not running — skipping site-packages restore"
        log yellow "  After starting the container, re-run:"
        log yellow "  DO_SPACES_KEY=xxx DO_SPACES_SECRET=xxx bash download-spaces.sh --skip-models --skip-nodes"
    else
        TAR_ON_HOST="$TEMP_DIR/linux-comfyui-venv.tar.gz"

        if [[ ! -f "$TAR_ON_HOST" ]]; then
            log cyan "Downloading venv snapshot..."
            rclone copyto \
                "${REMOTE}/site_packages/linux-comfyui-venv.tar.gz" "$TAR_ON_HOST" \
                --config "$RCLONE_CONF" \
                --progress
        else
            log cyan "Venv snapshot already downloaded"
        fi

        # Read the Python version that was snapshotted
        PY_VERSION=$(rclone cat "${REMOTE}/site_packages/linux-py-version.txt" \
            --config "$RCLONE_CONF" 2>/dev/null || echo "python3.11")
        log cyan "Python version in snapshot: $PY_VERSION"

        SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $(stat -c%s "$TAR_ON_HOST") / 1073741824}")
        log cyan "Extracting ${SIZE_GB} GB into container..."

        # Copy tarball into running container, then extract in-place
        docker cp "$TAR_ON_HOST" "${CONTAINER}:/tmp/linux-comfyui-venv.tar.gz"
        docker exec "$CONTAINER" tar -xzf "/tmp/linux-comfyui-venv.tar.gz" \
            -C "/opt/environments/python/comfyui/lib"
        docker exec "$CONTAINER" rm "/tmp/linux-comfyui-venv.tar.gz"
        log green "venv site-packages restored in container"
    fi
else
    log yellow "SKIP: site-packages (--skip-site-packages)"
fi

log green ""
log green "=== DOWNLOAD COMPLETE ==="
log green "Models and custom_nodes ready at $DATA_DIR"
log green "Log: $LOG"
