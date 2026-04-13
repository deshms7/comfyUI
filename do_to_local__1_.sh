#!/bin/bash
# =============================================================================
# do_to_local__1_.sh
# Downloads models + customNodes from DO Spaces (pfx-comfyui-assets, tor1)
# to the local ComfyUI data directory.
#
# Usage: sudo bash do_to_local__1_.sh
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
DO_ACCESS_KEY="DO801A62JD3LB7EL2PJ8"
DO_SECRET_KEY="Gz8MY2CAO8uElVxuQs973bzL+JvOJFHGqxnKOrdb/aE"
DO_ENDPOINT="https://tor1.digitaloceanspaces.com"
DO_BUCKET="pfx-comfyui-assets"
DO_REGION="tor1"

SPACES_MODELS="comfy_models_nodes/models"
SPACES_NODES="comfy_models_nodes/customNodes"

LOCAL_BASE="/data/comfyui"
LOCAL_MODELS="${LOCAL_BASE}/models"
LOCAL_NODES="${LOCAL_BASE}/custom_nodes"

RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf"
LOG_DIR="/var/log/illuma"
LOG_MODELS="${LOG_DIR}/dl-models.log"
LOG_NODES="${LOG_DIR}/dl-nodes.log"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info() { echo -e "${CYAN}[....] ${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Step 1: Install rclone --------------------------------------------------
install_rclone() {
    if command -v rclone &>/dev/null; then
        log "rclone already installed: $(rclone --version | head -1)"
        return
    fi

    log "Installing rclone..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y unzip curl
    elif command -v dnf &>/dev/null; then
        dnf install -y unzip curl
    elif command -v yum &>/dev/null; then
        yum install -y unzip curl
    else
        die "Unsupported package manager — install rclone manually"
    fi

    curl -fsSL https://rclone.org/install.sh | bash
    log "rclone installed: $(rclone --version | head -1)"
}

# --- Step 2: Write rclone config ---------------------------------------------
configure_rclone() {
    log "Writing rclone config for DO Spaces (tor1)..."
    mkdir -p "$(dirname "$RCLONE_CONFIG")"

    cat > "$RCLONE_CONFIG" <<EOF
[spaces]
type = s3
provider = DigitalOcean
access_key_id = ${DO_ACCESS_KEY}
secret_access_key = ${DO_SECRET_KEY}
endpoint = ${DO_ENDPOINT}
region = ${DO_REGION}
acl = private
EOF

    log "rclone config written."
}

# --- Step 3: Prepare local directories ---------------------------------------
prepare_dirs() {
    log "Creating local directories..."
    mkdir -p "${LOCAL_MODELS}"
    mkdir -p "${LOCAL_NODES}"
    mkdir -p "${LOG_DIR}"
    log "  Models  : ${LOCAL_MODELS}"
    log "  Nodes   : ${LOCAL_NODES}"
}

# --- Step 4: Show what will be downloaded ------------------------------------
show_sizes() {
    log "Checking source sizes (this may take a moment)..."
    echo ""
    info "  spaces:${DO_BUCKET}/${SPACES_MODELS}"
    rclone size "spaces:${DO_BUCKET}/${SPACES_MODELS}" --timeout 60s 2>/dev/null || warn "Could not get models size"
    echo ""
    info "  spaces:${DO_BUCKET}/${SPACES_NODES}"
    rclone size "spaces:${DO_BUCKET}/${SPACES_NODES}" --timeout 60s 2>/dev/null || warn "Could not get nodes size"
    echo ""
}

# --- Step 5: Download both directories in parallel ---------------------------
download_all() {
    log "Starting parallel download..."
    log "  Models log : ${LOG_MODELS}"
    log "  Nodes  log : ${LOG_NODES}"
    echo ""

    # Launch models sync in background
    rclone sync \
        "spaces:${DO_BUCKET}/${SPACES_MODELS}" \
        "${LOCAL_MODELS}" \
        --transfers 8 \
        --checkers 16 \
        --retries 3 \
        --timeout 300s \
        --size-only \
        --log-file "${LOG_MODELS}" \
        --log-level INFO &
    MODELS_PID=$!
    log "  Models sync started (PID ${MODELS_PID})"

    # Launch nodes sync in background
    rclone sync \
        "spaces:${DO_BUCKET}/${SPACES_NODES}" \
        "${LOCAL_NODES}" \
        --transfers 8 \
        --checkers 16 \
        --retries 3 \
        --timeout 300s \
        --size-only \
        --log-file "${LOG_NODES}" \
        --log-level INFO &
    NODES_PID=$!
    log "  Nodes  sync started (PID ${NODES_PID})"

    echo ""
    log "Waiting for both downloads to complete..."
    log "  (Ctrl+C to detach — processes continue in background)"
    echo ""

    # Poll progress every 30s
    while kill -0 "$MODELS_PID" 2>/dev/null || kill -0 "$NODES_PID" 2>/dev/null; do
        sleep 30
        MODELS_GB=0; NODES_GB=0
        if [[ -d "${LOCAL_MODELS}" ]]; then
            MODELS_GB=$(du -sb "${LOCAL_MODELS}" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
        fi
        if [[ -d "${LOCAL_NODES}" ]]; then
            NODES_GB=$(du -sb "${LOCAL_NODES}" 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
        fi
        MODELS_ST="running"; NODES_ST="running"
        kill -0 "$MODELS_PID" 2>/dev/null || MODELS_ST="done"
        kill -0 "$NODES_PID"  2>/dev/null || NODES_ST="done"
        info "  models: ${MODELS_GB} GB [${MODELS_ST}]  |  nodes: ${NODES_GB} GB [${NODES_ST}]"
    done

    wait "$MODELS_PID" || die "Models download failed — check ${LOG_MODELS}"
    wait "$NODES_PID"  || die "Nodes download failed  — check ${LOG_NODES}"

    log "Both downloads completed."
}

# --- Step 6: Verify ----------------------------------------------------------
verify_local() {
    echo ""
    log "Local file summary:"
    echo ""
    info "  Models:"
    du -sh "${LOCAL_MODELS}"/*/  2>/dev/null | sed 's/^/    /' || warn "  (no subdirectories)"
    du -sh "${LOCAL_MODELS}"     2>/dev/null | awk '{print "  Total: "$1}'
    echo ""
    info "  Custom nodes:"
    du -sh "${LOCAL_NODES}"/*/   2>/dev/null | sed 's/^/    /' || warn "  (no subdirectories)"
    du -sh "${LOCAL_NODES}"      2>/dev/null | awk '{print "  Total: "$1}'
    echo ""
}

# --- Main --------------------------------------------------------------------
main() {
    echo "============================================================"
    echo "  DO Spaces → Local  |  pfx-comfyui-assets  (tor1)"
    echo "  Bucket  : ${DO_BUCKET}"
    echo "  Models  : ${SPACES_MODELS} → ${LOCAL_MODELS}"
    echo "  Nodes   : ${SPACES_NODES}  → ${LOCAL_NODES}"
    echo "============================================================"
    echo ""

    install_rclone
    configure_rclone
    prepare_dirs
    show_sizes
    download_all
    verify_local

    echo ""
    log "All done!"
    log "  Models      : ${LOCAL_MODELS}"
    log "  CustomNodes : ${LOCAL_NODES}"
}

main "$@"
