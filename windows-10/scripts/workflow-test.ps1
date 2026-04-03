# Phase 7: Workflow Test
# Downloads a small SD1.5 checkpoint and runs a minimal 1-step 64x64 txt2img
# workflow to verify end-to-end GPU inference.
#
# Model source: stabilityai/stable-diffusion-v1-5 on HuggingFace (public, no auth required)

$TEST_MODEL      = "v1-5-pruned-emaonly.safetensors"
$TEST_MODEL_URL  = "https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"
$TEST_MODEL_PATH = "$COMFYUI_DIR\models\checkpoints\$TEST_MODEL"

function Invoke-WorkflowTest {
    if (Test-Sentinel ".workflow-test-done") {
        Print-Message "blue" "SKIP: Workflow test already passed"
        return
    }

    _Download-TestModel
    $promptId = _Submit-Workflow
    _Verify-Output $promptId

    Set-Sentinel ".workflow-test-done"
    Print-Message "green" "Workflow test passed -- end-to-end inference verified"
}

function _Download-TestModel {
    if (Test-Path $TEST_MODEL_PATH) {
        Print-Message "blue" "Test model already present: $TEST_MODEL"
        return
    }

    Print-Message "blue" "Downloading test model: $TEST_MODEL (~4GB)..."
    New-Item -ItemType Directory -Path (Split-Path $TEST_MODEL_PATH) -Force | Out-Null

    # BITS Transfer is faster for large files and shows progress; fall back to Invoke-WebRequest
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $TEST_MODEL_URL -Destination $TEST_MODEL_PATH
    } catch {
        Print-Message "yellow" "BITS unavailable -- falling back to Invoke-WebRequest..."
        Invoke-WebRequest -Uri $TEST_MODEL_URL -OutFile $TEST_MODEL_PATH -UseBasicParsing
    }

    if (-not (Test-Path $TEST_MODEL_PATH)) { Die "Test model download failed" }
    $sizeGB = [math]::Round((Get-Item $TEST_MODEL_PATH).Length / 1GB, 2)
    Print-Message "green" "Test model downloaded: $TEST_MODEL (${sizeGB}GB)"
}

function _Submit-Workflow {
    # Minimal txt2img: 1 step, 64x64, seed 42 -- enough to verify GPU inference without waiting long
    $workflow = @'
{"prompt":{"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"v1-5-pruned-emaonly.safetensors"}},"2":{"class_type":"CLIPTextEncode","inputs":{"clip":["1",1],"text":"test"}},"3":{"class_type":"CLIPTextEncode","inputs":{"clip":["1",1],"text":""}},"4":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":64,"batch_size":1}},"5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":42,"steps":1,"cfg":1.0,"sampler_name":"euler","scheduler":"normal","denoise":1.0}},"6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}},"7":{"class_type":"SaveImage","inputs":{"images":["6",0],"filename_prefix":"workflow-test"}}}}
'@

    Print-Message "blue" "Submitting test workflow..."
    try {
        $response = Invoke-RestMethod `
            -Uri "http://localhost:$COMFYUI_PORT/prompt" `
            -Method POST `
            -ContentType "application/json" `
            -Body $workflow `
            -ErrorAction Stop
    } catch {
        Die "Failed to reach ComfyUI API at http://localhost:$COMFYUI_PORT/prompt -- $_"
    }

    $promptId = $response.prompt_id
    if (-not $promptId) { Die "ComfyUI did not return a prompt_id -- response: $response" }
    Print-Message "blue" "Workflow queued -- prompt_id: $promptId"
    return $promptId
}

function _Verify-Output {
    param([string]$PromptId)

    $maxAttempts = 60   # 60 x 10s = 10 min max (model loads cold on first run)
    $attempt     = 0
    $startTime   = Get-Date

    Print-Message "blue" "Waiting for inference to complete (up to $($maxAttempts * 10)s)..."

    do {
        Start-Sleep -Seconds 10
        $attempt++
        if ($attempt -ge $maxAttempts) {
            Print-Message "red" "Last 30 lines of comfyui.log:"
            Get-Content "$LOG_DIR\comfyui.log" -Tail 30 -ErrorAction SilentlyContinue | Write-Host
            Die "Workflow did not complete after $($maxAttempts * 10)s -- prompt_id: $PromptId"
        }

        try {
            $history = Invoke-RestMethod `
                -Uri "http://localhost:$COMFYUI_PORT/history/$PromptId" `
                -UseBasicParsing -ErrorAction Stop
        } catch {
            Print-Message "blue" "  Polling history... attempt $attempt/$maxAttempts"
            continue
        }

        $entry = $history.$PromptId
        if ($entry -and $entry.status.completed -eq $true) { break }
        Print-Message "blue" "  Inference in progress... attempt $attempt/$maxAttempts"
    } while ($true)

    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
    Print-Message "green" "Inference completed in ${elapsed}s"

    $output = Get-ChildItem -Path "$COMFYUI_DIR\output" -Filter "workflow-test*.png" `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1

    if ($output) {
        Print-Message "green" "Output image: $($output.FullName)"
    } else {
        Print-Message "yellow" "Warning: output image not found -- inference may have succeeded but output path is unexpected"
    }
}
