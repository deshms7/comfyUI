# Phase 4.5: Install Custom Nodes
#
# Installs the exact custom nodes from the PFX snapshot
# (2026-03-26_17-06-15_snapshot.json).
#
# Two groups:
#   git_custom_nodes  -- cloned directly from GitHub (exact URLs from snapshot)
#   cnr_custom_nodes  -- ComfyUI Node Registry nodes, installed via git clone
#                        using their known repo URLs
#
# Each node's requirements.txt (if present) is pip-installed after cloning.
# Failures are logged and skipped -- one bad node does not abort the phase.

$CUSTOM_NODES_DIR = "$COMFYUI_DIR\custom_nodes"

# ---------------------------------------------------------------------------
# Nodes from snapshot git_custom_nodes (exact URLs)
# ---------------------------------------------------------------------------
$GIT_NODES = @(
    "https://github.com/giriss/comfy-image-saver",
    "https://github.com/M1kep/ComfyLiterals",
    "https://github.com/evanspearman/ComfyMath",
    "https://github.com/cnoellert/comfyui-corridorkey.git",
    "https://github.com/DesertPixelAi/ComfyUI-Desert-Pixel-Nodes",
    "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation",
    "https://github.com/huagetai/ComfyUI-Gaffer",
    "https://github.com/spacepxl/ComfyUI-Image-Filters",
    "https://github.com/kijai/ComfyUI-KJNodes",
    "https://github.com/ltdrdata/ComfyUI-Manager",
    "https://github.com/PozzettiAndrea/ComfyUI-SAM3",
    "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler",
    "https://github.com/un-seen/comfyui-tensorops",
    "https://github.com/shiimizu/ComfyUI-TiledDiffusion",
    "https://github.com/jamesWalker55/comfyui-various",
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite",
    "https://github.com/YaserJaradeh/comfyui-yaser-nodes",
    "https://github.com/cubiq/ComfyUI_essentials",
    "https://github.com/smthemex/ComfyUI_SVFR",
    "https://github.com/ssitu/ComfyUI_UltimateSDUpscale",
    "https://github.com/jonstreeter/ComfyUI-Deep-Exemplar-based-Video-Colorization",
    "https://github.com/edenartlab/eden_comfy_pipelines.git",
    "https://github.com/LarryJane491/Image-Captioning-in-ComfyUI",
    "https://github.com/BadCafeCode/masquerade-nodes-comfyui",
    "https://github.com/ClownsharkBatwing/RES4LYF",
    "https://github.com/rgthree/rgthree-comfy"
)

# ---------------------------------------------------------------------------
# Nodes from snapshot cnr_custom_nodes (mapped to their git repos)
# ---------------------------------------------------------------------------
$CNR_NODES = @(
    # name from snapshot                    -> git URL
    "https://github.com/crystian/ComfyUI-Crystools",
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts",
    "https://github.com/kijai/ComfyUI-DepthAnythingV2",
    "https://github.com/yolain/ComfyUI-Easy-Use",
    "https://github.com/kijai/ComfyUI-Florence2",
    "https://github.com/city96/ComfyUI-GGUF",              # ComfyUI-GGUF -- needed for GGUF models
    "https://github.com/huchenlei/ComfyUI-IC-Light",
    "https://github.com/kijai/ComfyUI-IC-Light-native",    # comfyui-ic-light-video
    "https://github.com/ltdrdata/ComfyUI-Inpaint-CropAndStitch",
    "https://github.com/nomaddo/ComfyUI-MelBandRoFormer",
    "https://github.com/pollockjj/ComfyUI-MultiGPU",
    "https://github.com/kijai/ComfyUI-QwenVL",
    "https://github.com/kijai/ComfyUI-WanVideoWrapper",    # ComfyUI-WanVideoWrapper -- critical for Wan
    "https://github.com/kijai/ComfyUI-WanAnimatePreprocess",
    "https://github.com/pythongosssss/ComfyUI-WD14-Tagger",
    "https://github.com/Fannovel16/comfyui_controlnet_aux",
    "https://github.com/chflame163/ComfyUI_LayerStyle",    # covers both layerstyle + advance
    "https://github.com/Derfuu/Derfuu_ComfyUI_ModdedNodes",
    "https://github.com/WASasquatch/was-node-suite-comfyui"
    # NOTE: basic_data_handling, comfyui-ig-nodes, comfyui-supernodes,
    #       comfyui-video-matting, Compare_videos, radiance
    #       -- git URLs not confirmed; install manually via ComfyUI Manager UI
    #       after first launch.
)

# ---------------------------------------------------------------------------
function Invoke-CustomNodesInstall {
    if (Test-Sentinel ".custom-nodes-done") {
        Print-Message "blue" "SKIP: Custom nodes already installed"
        return
    }

    if (-not (Test-Path $CUSTOM_NODES_DIR)) {
        New-Item -ItemType Directory -Path $CUSTOM_NODES_DIR -Force | Out-Null
    }

    # Ensure git is on PATH
    Refresh-Path
    foreach ($gp in @("C:\Program Files\Git\cmd", "C:\MinGit\cmd")) {
        if ((Test-Path $gp) -and ($env:PATH -notlike "*$gp*")) {
            $env:PATH = "$env:PATH;$gp"
        }
    }

    $ok   = 0
    $fail = 0

    $allNodes = $GIT_NODES + $CNR_NODES
    Print-Message "blue" "Installing $($allNodes.Count) custom nodes into $CUSTOM_NODES_DIR..."

    foreach ($repoUrl in $allNodes) {
        $repoUrl = $repoUrl.TrimEnd('/')
        $dirName = ($repoUrl -split '/')[-1] -replace '\.git$', ''
        $destDir = "$CUSTOM_NODES_DIR\$dirName"

        if (Test-Path "$destDir\.git") {
            Print-Message "blue" "SKIP (already cloned): $dirName"
            $ok++
            continue
        }

        Print-Message "blue" "Cloning $dirName ..."
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & git clone --depth 1 $repoUrl $destDir 2>&1 | ForEach-Object { Write-Host "  $_" }
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $savedEAP

        if ($exitCode -ne 0) {
            Print-Message "yellow" "WARN: clone failed for $repoUrl (exit $exitCode) -- skipping"
            $fail++
            continue
        }

        # Install node requirements if present
        $reqFile = "$destDir\requirements.txt"
        if (Test-Path $reqFile) {
            Print-Message "blue" "  pip install requirements for $dirName ..."
            & $PYTHON_VENV -m pip install -r $reqFile --no-warn-script-location --quiet
            if ($LASTEXITCODE -ne 0) {
                Print-Message "yellow" "  WARN: requirements install had errors for $dirName (non-fatal)"
            }
        }

        $ok++
        Print-Message "green" "Installed: $dirName"
    }

    Print-Message "green" "Custom nodes: $ok installed/skipped, $fail failed"

    if ($fail -gt 0) {
        Print-Message "yellow" "Failed nodes can be installed later via ComfyUI Manager UI."
    }

    Print-Message "yellow" "The following CNR nodes have unconfirmed URLs -- install via ComfyUI Manager after first launch:"
    Print-Message "yellow" "  basic_data_handling, comfyui-ig-nodes, comfyui-supernodes,"
    Print-Message "yellow" "  comfyui-video-matting, Compare_videos, radiance"

    # Install websocket_image_save.py (file_custom_node from snapshot)
    $wsFile = "$CUSTOM_NODES_DIR\websocket_image_save.py"
    if (-not (Test-Path $wsFile)) {
        Print-Message "blue" "Downloading websocket_image_save.py..."
        $wsUrl = "https://raw.githubusercontent.com/Djrango/comfyui_snag/main/websocket_image_save.py"
        try {
            Invoke-WebRequest -Uri $wsUrl -OutFile $wsFile -UseBasicParsing -ErrorAction Stop
            Print-Message "green" "websocket_image_save.py installed"
        } catch {
            Print-Message "yellow" "WARN: Could not download websocket_image_save.py -- copy manually if needed"
        }
    } else {
        Print-Message "blue" "SKIP: websocket_image_save.py already present"
    }

    # Re-pin torch to exact customer versions -- some node requirements.txt files
    # (e.g. comfyui-corridorkey) upgrade torch, which breaks cu128 compatibility.
    Print-Message "blue" "Re-pinning torch to customer-specified versions (2.7.1+cu128)..."
    & $PYTHON_VENV -m pip install `
        "torch==2.7.1+cu128" "torchvision==0.22.1+cu128" "torchaudio==2.7.1+cu128" `
        --index-url https://download.pytorch.org/whl/cu128 `
        --no-warn-script-location --quiet
    if ($LASTEXITCODE -ne 0) {
        Print-Message "yellow" "WARN: torch re-pin had errors -- verify torch version after install"
    } else {
        Print-Message "green" "torch 2.7.1+cu128 re-pinned successfully"
    }

    Set-Sentinel ".custom-nodes-done"
    Print-Message "green" "Custom node installation complete"
}
