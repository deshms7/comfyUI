#!/bin/bash
# spaces/upload-golden.sh
#
# Uploads the golden Ubuntu/Docker ComfyUI state to DO Spaces.
# Run ONCE on a fully provisioned Ubuntu reference machine.
#
# What it uploads:
#   /data/comfyui/models/          → comfy_models_nodes/models/
#   /data/comfyui/custom_nodes/    → comfy_models_nodes/custom_nodes/
#   container Python venv          → comfy_models_nodes/site_packages/linux-comfyui-venv.tar.gz
#
# Usage:
#   DO_SPACES_KEY=xxx DO_SPACES_SECRET=xxx bash upload-golden.sh
#   bash upload-golden.sh --key xxx --secret xxx
#
# Flags:
#   --skip-models         skip model sync
#   --skip-nodes          skip custom_nodes sync
#   --skip-site-packages  skip container venv snapshot
#   --container NAME      Docker container name (default: comfyui)

set -euo pipefail

BUCKET="pfx-comfyui-assets"
PREFIX="comfy_models_nodes"
REGION="tor1"
CONTAINER="comfyui"
DATA_DIR="/data/comfyui"
LOG="/var/log/illuma/upload-golden.log"
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
    log cyan "rclone already present: $(rclone --version | head -1)"
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
log cyan "=== Upload Golden Ubuntu → DO Spaces ==="
log cyan "Remote: $REMOTE"

# ── Step 3: Sync models ─────────────────────────────────────────────────
if [[ "$SKIP_MODELS" == "false" ]]; then
    log cyan "=== Syncing models (~90 GB) ==="
    rclone sync \
        "${DATA_DIR}/models" "${REMOTE}/models" \
        --config "$RCLONE_CONF" \
        --transfers 8 \
        --size-only \
        --progress \
        --log-file "$LOG" --log-level INFO
    log green "Models sync complete"
else
    log yellow "SKIP: models (--skip-models)"
fi

# ── Step 4: Package container venv site-packages ────────────────────────
# Snapshots /opt/environments/python/comfyui/lib/python*/site-packages inside
# the running Docker container. Restoring this on a new machine replaces
# all pip installs for 38 custom nodes.
if [[ "$SKIP_SITE_PACKAGES" == "false" ]]; then
    log cyan "=== Packaging container venv site-packages ==="

    # Find the Python version inside the container
    PY_VERSION=$(docker exec "$CONTAINER" \
        ls /opt/environments/python/comfyui/lib/ 2>/dev/null | grep '^python' | head -1)

    if [[ -z "$PY_VERSION" ]]; then
        log yellow "WARNING: could not detect Python version inside container $CONTAINER"
        log yellow "  Is the container running? (docker ps)"
        log yellow "  Skipping site-packages snapshot"
    else
        SITE_PKG_PATH="/opt/environments/python/comfyui/lib/${PY_VERSION}/site-packages"
        TAR_IN_CONTAINER="/tmp/linux-comfyui-venv.tar.gz"
        TAR_ON_HOST="$TEMP_DIR/linux-comfyui-venv.tar.gz"

        log cyan "Tarballing $SITE_PKG_PATH inside container (may take 3-5 min)..."
        docker exec "$CONTAINER" tar -czf "$TAR_IN_CONTAINER" \
            -C "/opt/environments/python/comfyui/lib" "${PY_VERSION}/site-packages"

        log cyan "Copying tarball from container to host..."
        docker cp "${CONTAINER}:${TAR_IN_CONTAINER}" "$TAR_ON_HOST"

        SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $(stat -c%s "$TAR_ON_HOST") / 1073741824}")
        log cyan "Tarball: ${SIZE_GB} GB"

        log cyan "Uploading site-packages snapshot..."
        rclone copyto \
            "$TAR_ON_HOST" "${REMOTE}/site_packages/linux-comfyui-venv.tar.gz" \
            --config "$RCLONE_CONF" \
            --progress
        log green "site-packages uploaded"

        # Store Python version alongside so download script knows what to restore
        echo "$PY_VERSION" > "$TEMP_DIR/linux-py-version.txt"
        rclone copyto "$TEMP_DIR/linux-py-version.txt" \
            "${REMOTE}/site_packages/linux-py-version.txt" \
            --config "$RCLONE_CONF"
    fi
else
    log yellow "SKIP: site-packages (--skip-site-packages)"
fi

# ── Step 5: Sync custom_nodes code ─────────────────────────────────────
if [[ "$SKIP_NODES" == "false" ]]; then
    log cyan "=== Syncing custom_nodes ==="
    rclone sync \
        "${DATA_DIR}/custom_nodes" "${REMOTE}/custom_nodes" \
        --config "$RCLONE_CONF" \
        --transfers 8 \
        --size-only \
        --exclude ".git/**" \
        --exclude "__pycache__/**" \
        --progress \
        --log-file "$LOG" --log-level INFO
    log green "custom_nodes sync complete"
else
    log yellow "SKIP: custom_nodes (--skip-nodes)"
fi

# ── Step 6: Version stamp ───────────────────────────────────────────────
VERSION=$(date '+%Y-%m-%d_%H-%M')
echo "$VERSION" > "$TEMP_DIR/version.txt"
rclone copyto "$TEMP_DIR/version.txt" "${REMOTE}/version.txt" --config "$RCLONE_CONF"
log cyan "Version stamp: $VERSION"

log green ""
log green "=== UPLOAD COMPLETE ==="
log green "Remote : $REMOTE"
log green "Run download-spaces.sh on each new Linux machine."
log green "Log    : $LOG"
