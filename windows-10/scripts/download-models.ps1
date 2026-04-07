# Phase 8: Model Downloads (Optional)
#
# Downloads PFX customer models grouped into tiers.
# Tier 1 - Core:  Flux1-dev fp8, SDXL checkpoint, text encoders, VAE, upscalers (~28 GB)
# Tier 2 - Video: Wan2.1/2.2 T2V + I2V models, text encoder (~40 GB)
# Tier 3 - Extra: SeedVR2 upscaler, Flux Fill, IP-Adapter, ControlNet, detection models (~50 GB)
#
# Usage:
#   .\download-models.ps1 -Tier Core
#   .\download-models.ps1 -Tier Video
#   .\download-models.ps1 -Tier Core,Video
#   .\download-models.ps1 -Tier All
#
# HuggingFace gated models (FLUX.1-dev ae.safetensors) need an HF token:
#   $env:HF_TOKEN = "hf_xxxxxxxxxxxx"
# Get one at: https://huggingface.co/settings/tokens
# If no token is set, the public/mirrored version is used instead.

param(
    [string[]]$Tier = @("Core")
)

. "$PSScriptRoot\common.ps1"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$MODELS_BASE  = "$COMFYUI_DIR\models"
$HF_TOKEN     = if ($env:HF_TOKEN) { $env:HF_TOKEN } else { "" }
$HF_BASE      = "https://huggingface.co"

# Expand "All" shorthand
if ($Tier -contains "All") { $Tier = @("Core", "Video", "Extra") }

# ---------------------------------------------------------------------------
# Helper: build HuggingFace URL with optional token header key
# ---------------------------------------------------------------------------
function HF {
    param([string]$Repo, [string]$File, [string]$Branch = "main")
    return "$HF_BASE/$Repo/resolve/$Branch/$File"
}

# ---------------------------------------------------------------------------
# Model catalog
# Each entry: Tier, Dest (relative to $MODELS_BASE), Filename, URL, SizeGB
# SizeGB is used as a loose check -- file is skipped if it already exists
# and is within 5% of expected size.
# ---------------------------------------------------------------------------
$CATALOG = @(

    # ==========================  TIER 1 -- CORE  ===========================
    # Flux1-dev fp8 checkpoint (no HF token needed -- Kijai public repo)
    [PSCustomObject]@{ Tier="Core"; Dest="diffusion_models"; File="flux1-dev-fp8-e4m3fn.safetensors";
        URL=(HF "Kijai/flux-fp8" "flux1-dev-fp8-e4m3fn.safetensors"); SizeGB=11.1 },

    # Flux text encoders
    [PSCustomObject]@{ Tier="Core"; Dest="clip"; File="t5xxl_fp16.safetensors";
        URL=(HF "comfyanonymous/flux_text_encoders" "t5xxl_fp16.safetensors"); SizeGB=9.1 },

    [PSCustomObject]@{ Tier="Core"; Dest="clip"; File="clip_l.safetensors";
        URL=(HF "comfyanonymous/flux_text_encoders" "clip_l.safetensors"); SizeGB=0.25 },

    # Flux VAE -- FLUX.1-schnell ae.safetensors (Apache 2.0, no token needed)
    [PSCustomObject]@{ Tier="Core"; Dest="vae"; File="ae.safetensors";
        URL=(HF "black-forest-labs/FLUX.1-schnell" "ae.safetensors"); SizeGB=0.32 },

    # SDXL checkpoint -- Juggernaut XI
    [PSCustomObject]@{ Tier="Core"; Dest="checkpoints"; File="juggernautXL_juggXIByRundiffusion.safetensors";
        URL=(HF "RunDiffusion/Juggernaut-XI-v11" "juggernautXL_juggXIByRundiffusion.safetensors"); SizeGB=6.6 },

    # Upscalers (small, fast)
    [PSCustomObject]@{ Tier="Core"; Dest="upscale_models"; File="4x-UltraSharp.pth";
        URL=(HF "uwg/upscaler" "ESRGAN/4x-UltraSharp.pth"); SizeGB=0.06 },

    [PSCustomObject]@{ Tier="Core"; Dest="upscale_models"; File="4x_foolhardy_Remacri.pth";
        URL=(HF "FacehuggerTHX/Upscalers" "4x_foolhardy_Remacri.pth"); SizeGB=0.06 },

    [PSCustomObject]@{ Tier="Core"; Dest="upscale_models"; File="4x_NMKD-Siax_200k.pth";
        URL=(HF "uwg/upscaler" "ESRGAN/4x_NMKD-Siax_200k.pth"); SizeGB=0.06 },

    [PSCustomObject]@{ Tier="Core"; Dest="upscale_models"; File="RealESRGAN_x4.pth";
        URL=(HF "ai-forever/Real-ESRGAN" "weights/RealESRGAN_x4.pth"); SizeGB=0.06 },

    [PSCustomObject]@{ Tier="Core"; Dest="upscale_models"; File="RealESRGAN_x2.pth";
        URL=(HF "ai-forever/Real-ESRGAN" "weights/RealESRGAN_x2.pth"); SizeGB=0.06 },

    # TAESD preview decoders (tiny, used by ComfyUI previews)
    [PSCustomObject]@{ Tier="Core"; Dest="vae_approx"; File="taesd_decoder.safetensors";
        URL=(HF "madebyollin/taesd" "taesd_decoder.safetensors"); SizeGB=0.002 },

    [PSCustomObject]@{ Tier="Core"; Dest="vae_approx"; File="taesdxl_decoder.safetensors";
        URL=(HF "madebyollin/taesdxl" "taesdxl_decoder.safetensors"); SizeGB=0.002 },

    [PSCustomObject]@{ Tier="Core"; Dest="vae_approx"; File="taef1_decoder.safetensors";
        URL=(HF "madebyollin/taef1" "taef1_decoder.safetensors"); SizeGB=0.002 },

    # SD 1.5 VAE
    [PSCustomObject]@{ Tier="Core"; Dest="vae"; File="vae-ft-mse-840000-ema-pruned.safetensors";
        URL=(HF "stabilityai/sd-vae-ft-mse-original" "vae-ft-mse-840000-ema-pruned.safetensors"); SizeGB=0.33 },

    # ==========================  TIER 2 -- VIDEO  ==========================
    # Wan2.1 T2V 1.3B (lighter, good for testing)
    [PSCustomObject]@{ Tier="Video"; Dest="diffusion_models"; File="wan2.1_t2v_1.3B_bf16.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "wan2.1_t2v_1.3B_bf16.safetensors"); SizeGB=2.6 },

    # Wan2.1 VAE
    [PSCustomObject]@{ Tier="Video"; Dest="vae"; File="Wan2_1_VAE_bf16.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "Wan2_1_VAE_bf16.safetensors"); SizeGB=0.4 },

    # UMT5 XXL text encoder (required by all Wan models)
    [PSCustomObject]@{ Tier="Video"; Dest="clip"; File="umt5_xxl_fp16.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "umt5_xxl_fp16.safetensors"); SizeGB=10.6 },

    # Wan2.2 T2V 14B (fp8, low-noise variant -- best quality)
    [PSCustomObject]@{ Tier="Video"; Dest="diffusion_models"; File="wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"); SizeGB=13.3 },

    # Wan2.2 I2V 14B (fp8, low-noise variant)
    [PSCustomObject]@{ Tier="Video"; Dest="diffusion_models"; File="wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"); SizeGB=13.3 },

    # Wan2.2 speed LoRAs (4-step distillation, needed for fast generation)
    [PSCustomObject]@{ Tier="Video"; Dest="loras"; File="wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"); SizeGB=1.1 },

    [PSCustomObject]@{ Tier="Video"; Dest="loras"; File="wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"); SizeGB=1.1 },

    # Wan2.1 CausVid LoRA (fast T2V)
    [PSCustomObject]@{ Tier="Video"; Dest="loras"; File="Wan21_CausVid_14B_T2V_lora_rank32.safetensors";
        URL=(HF "Kijai/WanVideo_comfy" "Wan21_CausVid_14B_T2V_lora_rank32.safetensors"); SizeGB=0.16 },

    # ==========================  TIER 3 -- EXTRA  ==========================
    # Flux1-fill-dev (inpainting, 22GB)
    [PSCustomObject]@{ Tier="Extra"; Dest="diffusion_models"; File="flux1-fill-dev.safetensors";
        URL=(HF "black-forest-labs/FLUX.1-Fill-dev" "flux1-fill-dev.safetensors"); SizeGB=22.2 },

    # Flux ControlNet (canny)
    [PSCustomObject]@{ Tier="Extra"; Dest="controlnet"; File="flux-canny-controlnet-v3.safetensors";
        URL=(HF "XLabs-AI/flux-controlnet-canny-v3" "flux-canny-controlnet-v3.safetensors"); SizeGB=1.4 },

    # MistoLine (SDXL line-art ControlNet)
    [PSCustomObject]@{ Tier="Extra"; Dest="controlnet"; File="mistoLine_rank256.safetensors";
        URL=(HF "TheMistoAI/MistoLine" "mistoLine_rank256.safetensors"); SizeGB=0.7 },

    # IP-Adapter SDXL
    [PSCustomObject]@{ Tier="Extra"; Dest="ipadapter"; File="ip-adapter-plus_sdxl_vit-h.safetensors";
        URL=(HF "h94/IP-Adapter" "sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors"); SizeGB=0.8 },

    [PSCustomObject]@{ Tier="Extra"; Dest="ipadapter"; File="ip-adapter-plus-face_sdxl_vit-h.safetensors";
        URL=(HF "h94/IP-Adapter" "sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors"); SizeGB=0.8 },

    # CLIP Vision (used by IP-Adapter)
    [PSCustomObject]@{ Tier="Extra"; Dest="clip_vision"; File="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors";
        URL=(HF "h94/IP-Adapter" "models/image_encoder/model.safetensors"); SizeGB=2.4 },

    # Detection / segmentation models
    [PSCustomObject]@{ Tier="Extra"; Dest="ultralytics\bbox"; File="face_yolov8n.pt";
        URL=(HF "Bingsu/adetailer" "face_yolov8n.pt"); SizeGB=0.005 },

    [PSCustomObject]@{ Tier="Extra"; Dest="ultralytics\bbox"; File="face_yolov8m.pt";
        URL=(HF "Bingsu/adetailer" "face_yolov8m.pt"); SizeGB=0.05 },

    [PSCustomObject]@{ Tier="Extra"; Dest="ultralytics\segm"; File="person_yolov8m-seg.pt";
        URL=(HF "Bingsu/adetailer" "person_yolov8m-seg.pt"); SizeGB=0.05 },

    # SAM (segment anything)
    [PSCustomObject]@{ Tier="Extra"; Dest="sams"; File="sam_vit_b_01ec64.pth";
        URL="https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth"; SizeGB=0.35 },

    [PSCustomObject]@{ Tier="Extra"; Dest="sams"; File="sam_hq_vit_h.pth";
        URL=(HF "lkeab/hq-sam" "sam_hq_vit_h.pth"); SizeGB=2.4 },

    # SeedVR2 video upscaler (fp8 variants)
    [PSCustomObject]@{ Tier="Extra"; Dest="diffusion_models"; File="seedvr2_ema_3b_fp8_e4m3fn.safetensors";
        URL=(HF "Kijai/SeedVR2_comfy" "seedvr2_ema_3b_fp8_e4m3fn.safetensors"); SizeGB=3.2 },

    [PSCustomObject]@{ Tier="Extra"; Dest="diffusion_models"; File="seedvr2_ema_7b_fp8_e4m3fn.safetensors";
        URL=(HF "Kijai/SeedVR2_comfy" "seedvr2_ema_7b_fp8_e4m3fn.safetensors"); SizeGB=7.7 }
)

# ---------------------------------------------------------------------------
# Models that need to be obtained manually (custom/private -- no public URL)
# ---------------------------------------------------------------------------
$MANUAL_MODELS = @(
    "rubini.safetensors              -- Custom LoRA (private, needs transfer from PFX)",
    "rubinilarge1.safetensors        -- Custom LoRA (private, needs transfer from PFX)",
    "rrbbboy.safetensors             -- Custom LoRA (private, needs transfer from PFX)",
    "bouncing-baby-lora.safetensors  -- Custom LoRA (private, needs transfer from PFX)",
    "comfyui_subject_lora16.safetensors -- Custom LoRA (origin unknown)",
    "CorridorKey_v1.0.pth            -- comfyui-corridorkey node model, check node README",
    "GIFUNI_v003_*.safetensors       -- GIFUNI project models (private)",
    "stock_photography_wan22_LOW_v1.safetensors -- Private LoRA",
    "pixel_art_style_z_image_turbo.safetensors  -- Check CivitAI",
    "z_image_turbo_bf16.safetensors  -- Check CivitAI or HuggingFace",
    "flux2-dev.safetensors           -- Flux 2 dev (60GB, skip until official release)",
    "flux2_dev_fp8mixed.safetensors  -- Flux 2 fp8 (33GB, skip until official release)",
    "mistral_3_small_flux2_bf16.safetensors -- Mistral+Flux2 LLM (33GB, skip for now)",
    "wan2.1_fun_control_1.3B_bf16.safetensors -- Check Wan-AI/WanFun HuggingFace repo",
    "wan2.2_animate_14B_bf16.safetensors -- Full bf16 (32GB), use fp8 variant instead"
)

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------
function _Download-File {
    param(
        [string]$Url,
        [string]$Dest,
        [float]$SizeGB,
        [string]$Label
    )

    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Skip if file already exists and is close to expected size
    if (Test-Path $Dest) {
        if ($SizeGB -gt 0) {
            $existingGB = (Get-Item $Dest).Length / 1GB
            $ratio = $existingGB / $SizeGB
            if ($ratio -ge 0.95 -and $ratio -le 1.10) {
                Print-Message "blue" "SKIP: $Label already present ($([math]::Round($existingGB,1))GB)"
                return $true
            }
            Print-Message "yellow" "WARNING: $Label exists but size mismatch (got $([math]::Round($existingGB,2))GB, expected ~${SizeGB}GB) -- re-downloading"
        } else {
            Print-Message "blue" "SKIP: $Label already present"
            return $true
        }
    }

    # Build headers
    $headers = @{}
    if ($HF_TOKEN -and $Url -match "huggingface\.co") {
        $headers["Authorization"] = "Bearer $HF_TOKEN"
    }

    $sizeStr = if ($SizeGB -ge 1) { "$([math]::Round($SizeGB,1))GB" } else { "$([math]::Round($SizeGB*1024))MB" }
    Print-Message "blue" "Downloading $Label ($sizeStr)..."

    try {
        Import-Module BitsTransfer -ErrorAction Stop
        if ($headers.Count -gt 0) {
            # BITS does not support custom headers -- fall through to WebRequest
            throw "BITS: headers not supported"
        }
        Start-BitsTransfer -Source $Url -Destination $Dest -DisplayName $Label
        if (-not (Test-Path $Dest)) { throw "BITS: file not created" }
    } catch {
        Print-Message "yellow" "BITS unavailable or not supported -- using Invoke-WebRequest..."
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -Headers $headers -UseBasicParsing
        } catch {
            Print-Message "red" "FAIL: Could not download $Label -- $_"
            return $false
        }
    }

    if (Test-Path $Dest) {
        $gotGB = [math]::Round((Get-Item $Dest).Length / 1GB, 2)
        Print-Message "green" "Downloaded $Label (${gotGB}GB)"
        return $true
    }
    Print-Message "red" "FAIL: $Label not found after download"
    return $false
}

# ---------------------------------------------------------------------------
# Main download loop
# ---------------------------------------------------------------------------
function Invoke-DownloadModels {
    Print-Message "blue" "=== Model Download Phase ==="
    Print-Message "blue" "Tiers selected: $($Tier -join ', ')"
    if ($HF_TOKEN) {
        Print-Message "green" "HuggingFace token found -- gated models will be accessible"
    } else {
        Print-Message "yellow" "No HF_TOKEN set -- gated models will fail (set `$env:HF_TOKEN)"
    }

    $ok = 0; $fail = 0

    foreach ($m in $CATALOG) {
        if ($Tier -notcontains $m.Tier) { continue }

        $destPath = Join-Path $MODELS_BASE ($m.Dest + "\" + $m.File)
        $result = _Download-File -Url $m.URL -Dest $destPath -SizeGB $m.SizeGB -Label $m.File

        if ($result -eq $true) { $ok++ }
        else { $fail++ }
    }

    Print-Message "green" "=== Download complete: $ok succeeded/skipped, $fail failed ==="

    if ($fail -gt 0) {
        Print-Message "yellow" "Some downloads failed -- check URLs above and re-run the script."
        Print-Message "yellow" "Many HuggingFace repos may have changed filenames since this script was written."
    }

    Print-Message "blue" ""
    Print-Message "blue" "=== Models requiring MANUAL transfer (no public URL) ==="
    foreach ($note in $MANUAL_MODELS) {
        Print-Message "yellow" "  $note"
    }
}

Invoke-DownloadModels
