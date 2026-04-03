#!/bin/bash

# Phase 7: Workflow Test
# Downloads v1-5-pruned-emaonly.safetensors (~4GB) and runs a minimal
# 1-step 64x64 txt2img workflow to verify end-to-end inference works.

DATA_DIR="${DATA_DIR:-/data/comfyui}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
SERVICE_NAME="comfyui"
SENTINEL_DIR="${SENTINEL_DIR:-/var/lib/illuma}"

TEST_MODEL="v1-5-pruned-emaonly.safetensors"
TEST_MODEL_URL="https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
TEST_MODEL_PATH="${DATA_DIR}/models/checkpoints/${TEST_MODEL}"

function runWorkflowTest() {
    local sentinel="${SENTINEL_DIR}/.workflow-test-done"

    if [[ -f "$sentinel" ]]; then
        print_message "blue" "SKIP: Workflow test already passed"
        return 0
    fi

    _downloadTestModel
    _submitWorkflow
    _verifyOutput

    touch "$sentinel"
    print_message "green" "Workflow test passed — end-to-end inference verified"
}

function _downloadTestModel() {
    if [[ -f "$TEST_MODEL_PATH" ]]; then
        print_message "blue" "Test model already present: $TEST_MODEL"
        return 0
    fi

    print_message "blue" "Downloading test model: $TEST_MODEL (~4GB)..."
    mkdir -p "${DATA_DIR}/models/checkpoints"

    wget --quiet --show-progress \
        -O "$TEST_MODEL_PATH" \
        "$TEST_MODEL_URL" || {
        rm -f "$TEST_MODEL_PATH"
        die "Failed to download test model"
    }

    # Set ownership to match container user (uid=1000:gid=1111)
    chown 1000:1111 "$TEST_MODEL_PATH"
    print_message "green" "Test model downloaded: $TEST_MODEL"
}

function _submitWorkflow() {
    # Minimal txt2img: 1 step, 64x64, seed 42 — enough to verify GPU inference
    local workflow='{"prompt":{"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"v1-5-pruned-emaonly.safetensors"}},"2":{"class_type":"CLIPTextEncode","inputs":{"clip":["1",1],"text":"test"}},"3":{"class_type":"CLIPTextEncode","inputs":{"clip":["1",1],"text":""}},"4":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":64,"batch_size":1}},"5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":42,"steps":1,"cfg":1.0,"sampler_name":"euler","scheduler":"normal","denoise":1.0}},"6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},"7":{"class_type":"SaveImage","inputs":{"images":["6",0],"filename_prefix":"workflow-test"}}}}'

    print_message "blue" "Submitting test workflow..."

    # Call the internal ComfyUI API directly (port 18188 inside the container)
    # to bypass the Caddy auth proxy sitting on port 8188
    local response
    response=$(docker exec "${SERVICE_NAME}" curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$workflow" \
        "http://localhost:18188/prompt" 2>/dev/null) || \
        die "Failed to reach ComfyUI internal API (localhost:18188 inside container)"

    WORKFLOW_PROMPT_ID=$(echo "$response" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['prompt_id'])" 2>/dev/null) || \
        die "ComfyUI did not return a prompt_id — response: $response"

    print_message "blue" "Workflow queued — prompt_id: $WORKFLOW_PROMPT_ID"
}

function _verifyOutput() {
    local prompt_id="$WORKFLOW_PROMPT_ID"
    # Allow up to 10 min — model loads cold on first run
    local max_attempts=60
    local attempt=0
    local start_epoch
    start_epoch=$(date +%s)

    print_message "blue" "Waiting for inference to complete (up to $((max_attempts * 10))s)..."

    until _workflowCompleted "$prompt_id"; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            print_message "red" "ComfyUI container logs (last 30 lines):"
            docker logs "${SERVICE_NAME}" --tail 30 2>&1 || true
            die "Workflow did not complete after $((max_attempts * 10))s — prompt_id: $prompt_id"
        fi
        print_message "blue" "  Inference in progress... attempt $attempt/$max_attempts"
        sleep 10
    done

    local elapsed=$(( $(date +%s) - start_epoch ))
    print_message "green" "Inference completed in ${elapsed}s"

    # Verify output image written to host volume
    local output
    output=$(find "${DATA_DIR}/outputs" -name "workflow-test*.png" 2>/dev/null | sort | tail -1)

    if [[ -n "$output" ]]; then
        print_message "green" "Output image: $output"
    else
        # Fallback: check inside container (in case volume mapping differs)
        output=$(docker exec "${SERVICE_NAME}" \
            find /opt/ComfyUI/output -name "workflow-test*.png" 2>/dev/null | sort | tail -1)
        if [[ -n "$output" ]]; then
            print_message "green" "Output image (inside container): $output"
        else
            print_message "yellow" "Warning: output image not found — inference may have succeeded but output path is unexpected"
        fi
    fi
}

function _workflowCompleted() {
    local prompt_id="$1"
    local history
    history=$(docker exec "${SERVICE_NAME}" curl -sf "http://localhost:18188/history/${prompt_id}" 2>/dev/null) || return 1

    python3 -c "
import sys, json
data = json.loads(sys.argv[1])
entry = data.get('${prompt_id}', {})
completed = entry.get('status', {}).get('completed', False)
sys.exit(0 if completed else 1)
" "$history" 2>/dev/null
}

export -f runWorkflowTest
export -f _downloadTestModel
export -f _submitWorkflow
export -f _verifyOutput
export -f _workflowCompleted
