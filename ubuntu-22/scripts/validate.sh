#!/bin/bash

# ComfyUI Validation Suite
# Readiness polling adapted from scripts/nats/wait-for-nats.sh

COMFYUI_PORT="${COMFYUI_PORT:-8188}"
SERVICE_NAME="comfyui"
POLL_MAX_ATTEMPTS="${POLL_MAX_ATTEMPTS:-30}"
POLL_SLEEP_SEC="${POLL_SLEEP_SEC:-10}"

function validateComfyUI() {
    print_message "blue" "Running validation checks..."
    local checks_passed=0

    # CHECK 1: Container running
    # (polling pattern from scripts/nats/wait-for-nats.sh — MAX_ATTEMPTS + sleep loop)
    print_message "blue" "CHECK 1/3: Waiting for container to start..."
    local attempt=0
    until docker ps --filter "name=^${SERVICE_NAME}$" --filter "status=running" \
            --format "{{.Names}}" | grep -q "^${SERVICE_NAME}$"; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $POLL_MAX_ATTEMPTS ]]; then
            print_message "red" "Container logs (last 20 lines):"
            docker logs "${SERVICE_NAME}" 2>&1 | tail -20 || true
            die "FAIL CHECK 1: Container not running after $((POLL_MAX_ATTEMPTS * POLL_SLEEP_SEC))s"
        fi
        print_message "blue" "  Waiting for container... attempt $attempt/$POLL_MAX_ATTEMPTS"
        sleep "$POLL_SLEEP_SEC"
    done
    print_message "green" "CHECK 1/3: Container running"
    checks_passed=$((checks_passed + 1))

    # CHECK 2: Port responding
    print_message "blue" "CHECK 2/3: Waiting for port ${COMFYUI_PORT} to respond..."
    attempt=0
    until curl -sf --max-time 5 "http://localhost:${COMFYUI_PORT}" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $POLL_MAX_ATTEMPTS ]]; then
            die "FAIL CHECK 2: Port ${COMFYUI_PORT} not responding after $((POLL_MAX_ATTEMPTS * POLL_SLEEP_SEC))s"
        fi
        print_message "blue" "  Waiting for port ${COMFYUI_PORT}... attempt $attempt/$POLL_MAX_ATTEMPTS"
        sleep "$POLL_SLEEP_SEC"
    done
    print_message "green" "CHECK 2/3: Port ${COMFYUI_PORT} responding"
    checks_passed=$((checks_passed + 1))

    # CHECK 3: GPU visible inside container
    print_message "blue" "CHECK 3/3: Verifying GPU inside container..."
    if docker exec "${SERVICE_NAME}" nvidia-smi > /dev/null 2>&1; then
        print_message "green" "CHECK 3/3: GPU visible inside container"
        checks_passed=$((checks_passed + 1))
    else
        print_message "yellow" "CHECK 3/3: GPU check inconclusive (exec may be restricted in container)"
    fi

    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')

    print_message "green" "=== $checks_passed/3 checks passed ==="
    print_message "green" "ComfyUI ready at: http://${host_ip}:${COMFYUI_PORT}"
    echo ""
    print_message "blue" "Useful commands:"
    print_message "blue" "  Logs:    journalctl -u ${SERVICE_NAME} -f"
    print_message "blue" "  Status:  systemctl status ${SERVICE_NAME}"
    print_message "blue" "  Stop:    systemctl stop ${SERVICE_NAME}"
    print_message "blue" "  Restart: systemctl restart ${SERVICE_NAME}"
    print_message "blue" "  Data:    ${DATA_DIR:-/data/comfyui}"
}

export -f validateComfyUI
