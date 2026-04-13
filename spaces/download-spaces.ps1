# spaces/download-spaces.ps1
#
# Pulls ComfyUI models, custom nodes, and Python venv from DO Spaces
# onto a freshly provisioned Windows machine.
#
# Called from install.ps1 -FromSpaces, or standalone after ComfyUI is installed.
#
# What it does:
#   1. Syncs models  ← spaces/comfy_models_nodes/models/
#   2. Restores venv ← spaces/comfy_models_nodes/site_packages/windows-venv.tar.gz
#   3. Syncs custom_nodes code ← spaces/comfy_models_nodes/custom_nodes/
#
# Usage:
#   .\download-spaces.ps1 -Key <DO_KEY> -Secret <DO_SECRET>
#   $env:DO_SPACES_KEY="xxx"; $env:DO_SPACES_SECRET="xxx"; .\download-spaces.ps1
#
# Flags:
#   -SkipModels         skip model sync
#   -SkipSitePackages   skip venv restore (pip install will run instead)
#   -SkipCustomNodes    skip custom_nodes sync

param(
    [string]$Key              = $env:DO_SPACES_KEY,
    [string]$Secret           = $env:DO_SPACES_SECRET,
    [string]$Bucket           = "pfx-comfyui-assets",
    [string]$Prefix           = "comfy_models_nodes",
    [string]$Region           = "tor1",
    [switch]$SkipModels,
    [switch]$SkipSitePackages,
    [switch]$SkipCustomNodes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RCLONE_DIR  = "C:\Tools\rclone"
$RCLONE_EXE  = "$RCLONE_DIR\rclone.exe"
$RCLONE_CONF = "$RCLONE_DIR\rclone.conf"
$COMFYUI_DIR = "C:\ComfyUI"
$VENV_DIR    = "$COMFYUI_DIR\.venv"
$LOG         = "C:\Logs\illuma\spaces-download.log"
$TEMP_DIR    = "C:\Logs\illuma\spaces-temp"

function Log {
    param([string]$msg, [string]$color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
    [System.IO.File]::AppendAllText($LOG, "[$ts] $msg`n")
}

if (-not $Key -or -not $Secret) {
    Write-Error "Credentials required. Pass -Key/-Secret or set DO_SPACES_KEY/DO_SPACES_SECRET."
    exit 1
}

New-Item -ItemType Directory -Path (Split-Path $LOG -Parent) -Force | Out-Null
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

Log "=== ComfyUI Spaces Download ===" "Cyan"

# ─────────────────────────────────────────────
# Step 1 — Install rclone
# ─────────────────────────────────────────────
if (-not (Test-Path $RCLONE_EXE)) {
    Log "Installing rclone..." "Blue"
    New-Item -ItemType Directory -Path $RCLONE_DIR -Force | Out-Null
    $zip = "$TEMP_DIR\rclone.zip"
    curl.exe -L --retry 3 -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    Expand-Archive -Path $zip -DestinationPath $TEMP_DIR -Force
    $extracted = Get-ChildItem "$TEMP_DIR\rclone-*-windows-amd64" | Select-Object -First 1
    Copy-Item "$($extracted.FullName)\rclone.exe" $RCLONE_EXE
    Log "rclone installed" "Green"
} else {
    Log "rclone already present" "Blue"
}

# ─────────────────────────────────────────────
# Step 2 — Write rclone config
# ─────────────────────────────────────────────
@"
[spaces]
type = s3
provider = DigitalOcean
access_key_id = $Key
secret_access_key = $Secret
endpoint = ${Region}.digitaloceanspaces.com
acl = private
"@ | Set-Content -Path $RCLONE_CONF -Encoding UTF8

$REMOTE = "spaces:$Bucket/$Prefix"

# Show what's in Spaces for visibility
$remoteVersion = (& $RCLONE_EXE --config $RCLONE_CONF cat "$REMOTE/version.txt" 2>$null)
Log "Remote version: $remoteVersion" "Blue"
Log "Remote        : $REMOTE" "Blue"

# ─────────────────────────────────────────────
# Step 3 — Sync models
# --size-only: skips files already present with matching size (resume-safe)
# ─────────────────────────────────────────────
if (-not $SkipModels) {
    Log "=== Syncing models from Spaces ===" "Cyan"

    # Pre-create all model subdirs so rclone doesn't error on empty dirs
    foreach ($d in @("diffusion_models","clip","vae","loras","checkpoints",
                     "upscale_models","vae_approx","controlnet","ipadapter",
                     "clip_vision","ultralytics\bbox","ultralytics\segm","sams")) {
        New-Item -ItemType Directory -Path "$COMFYUI_DIR\models\$d" -Force | Out-Null
    }

    & $RCLONE_EXE --config $RCLONE_CONF sync `
        "$REMOTE/models" "$COMFYUI_DIR\models" `
        --transfers 8 `
        --size-only `
        --progress `
        --log-file $LOG --log-level INFO
    if ($LASTEXITCODE -ne 0) { Log "ERROR: models sync failed (exit $LASTEXITCODE)" "Red"; exit 1 }
    Log "Models sync complete" "Green"
} else {
    Log "SKIP: models (-SkipModels)" "Yellow"
}

# ─────────────────────────────────────────────
# Step 4 — Restore venv site-packages
# Extracts into .venv\Lib\ — replaces 30+ min of pip install with ~3 min extract
# Requires the .venv dir to already exist (created by ComfyUI setup phase)
# ─────────────────────────────────────────────
if (-not $SkipSitePackages) {
    $venvLib = "$VENV_DIR\Lib"
    if (Test-Path $VENV_DIR) {
        Log "=== Restoring venv site-packages ===" "Cyan"
        $tarPath = "$TEMP_DIR\windows-venv.tar.gz"

        if (-not (Test-Path $tarPath)) {
            Log "Downloading venv snapshot..." "Blue"
            & $RCLONE_EXE --config $RCLONE_CONF copyto `
                "$REMOTE/site_packages/windows-venv.tar.gz" $tarPath `
                --progress
            if ($LASTEXITCODE -ne 0) { Log "ERROR: venv snapshot download failed" "Red"; exit 1 }
        } else {
            Log "Venv snapshot already downloaded" "Blue"
        }

        $sizeGB = [math]::Round((Get-Item $tarPath).Length / 1GB, 2)
        Log "Extracting ${sizeGB} GB into $venvLib ..." "Blue"
        New-Item -ItemType Directory -Path $venvLib -Force | Out-Null
        tar.exe -xzf $tarPath -C $venvLib
        if ($LASTEXITCODE -ne 0) { Log "ERROR: venv extraction failed" "Red"; exit 1 }
        Log "venv site-packages restored" "Green"
    } else {
        Log "WARNING: .venv not found at $VENV_DIR" "Yellow"
        Log "  Run ComfyUI setup phase first (install.ps1 creates the venv)" "Yellow"
        Log "  Skipping site-packages restore" "Yellow"
    }
} else {
    Log "SKIP: site-packages (-SkipSitePackages)" "Yellow"
}

# ─────────────────────────────────────────────
# Step 5 — Sync custom_nodes code
# ─────────────────────────────────────────────
if (-not $SkipCustomNodes) {
    Log "=== Syncing custom_nodes from Spaces ===" "Cyan"
    New-Item -ItemType Directory -Path "$COMFYUI_DIR\custom_nodes" -Force | Out-Null

    & $RCLONE_EXE --config $RCLONE_CONF sync `
        "$REMOTE/custom_nodes" "$COMFYUI_DIR\custom_nodes" `
        --transfers 8 `
        --size-only `
        --progress `
        --log-file $LOG --log-level INFO
    if ($LASTEXITCODE -ne 0) { Log "ERROR: custom_nodes sync failed" "Red"; exit 1 }
    Log "custom_nodes sync complete" "Green"
} else {
    Log "SKIP: custom_nodes (-SkipCustomNodes)" "Yellow"
}

Log "" "White"
Log "=== DOWNLOAD COMPLETE ===" "Green"
Log "Models, venv, and custom_nodes are ready at $COMFYUI_DIR" "Green"
Log "Log: $LOG" "Green"
