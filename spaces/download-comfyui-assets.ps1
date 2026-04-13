# =============================================================================
# download-comfyui-assets.ps1
#
# Downloads ComfyUI models, custom nodes, and Python venv from DO Spaces
# onto a Windows RTX machine.
#
# Bucket layout expected:
#   pfx-comfyui-assets/comfy_models_nodes/
#     models/          ← synced directly to C:\ComfyUI\models\
#     customNodes/
#       custom_nodes.tar.gz  ← extracted to C:\ComfyUI\
#     Python/
#       site_packages.tar.gz ← extracted to C:\ComfyUI\.venv\Lib\
#
# Prerequisites:
#   - ComfyUI installed at C:\ComfyUI\ with .venv already created
#     (run install.ps1 first, or ensure python -m venv C:\ComfyUI\.venv exists)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File download-comfyui-assets.ps1
# =============================================================================

$ErrorActionPreference = "Stop"

# --- Config ------------------------------------------------------------------
$DO_ACCESS_KEY = "DO801A62JD3LB7EL2PJ8"
$DO_SECRET_KEY = "Gz8MY2CAO8uElVxuQs973bzL+JvOJFHGqxnKOrdb/aE"
$DO_ENDPOINT   = "https://tor1.digitaloceanspaces.com"
$DO_BUCKET     = "pfx-comfyui-assets"
$DO_PREFIX     = "comfy_models_nodes"
$DO_REGION     = "tor1"

$COMFYUI_DIR   = "C:\ComfyUI"
$VENV_LIB      = "$COMFYUI_DIR\.venv\Lib"
$RCLONE_DIR    = "C:\Tools\rclone"
$RCLONE_EXE    = "$RCLONE_DIR\rclone.exe"
$RCLONE_CONF   = "$RCLONE_DIR\rclone.conf"
$LOG_DIR       = "C:\Logs\illuma"
$LOG           = "$LOG_DIR\download-assets.log"
$TEMP_DIR      = "$LOG_DIR\dl-temp"

$REMOTE        = "spaces:$DO_BUCKET/$DO_PREFIX"

# --- Helpers -----------------------------------------------------------------
function Log {
    param([string]$msg, [string]$color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line -ForegroundColor $color
    [System.IO.File]::AppendAllText($LOG, "$line`n")
}

function Die {
    param([string]$msg)
    Log "ERROR: $msg" "Red"
    exit 1
}

# --- Step 1: Install rclone --------------------------------------------------
function Install-Rclone {
    if (Test-Path $RCLONE_EXE) {
        Log "rclone already installed" "Blue"
        return
    }
    Log "Installing rclone..." "Blue"
    New-Item -ItemType Directory -Path $RCLONE_DIR -Force | Out-Null
    New-Item -ItemType Directory -Path $TEMP_DIR   -Force | Out-Null
    $zip = "$TEMP_DIR\rclone.zip"
    curl.exe -L --retry 3 -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    if ($LASTEXITCODE -ne 0) { Die "rclone download failed" }
    Expand-Archive -Path $zip -DestinationPath $TEMP_DIR -Force
    $extracted = Get-ChildItem "$TEMP_DIR\rclone-*-windows-amd64" | Select-Object -First 1
    Copy-Item "$($extracted.FullName)\rclone.exe" $RCLONE_EXE -Force
    Log "rclone installed at $RCLONE_EXE" "Green"
}

# --- Step 2: Write rclone config ---------------------------------------------
function Configure-Rclone {
    Log "Writing rclone config..." "Blue"
    @"
[spaces]
type = s3
provider = DigitalOcean
access_key_id = $DO_ACCESS_KEY
secret_access_key = $DO_SECRET_KEY
endpoint = $DO_REGION.digitaloceanspaces.com
acl = private
"@ | Set-Content -Path $RCLONE_CONF -Encoding UTF8
    Log "rclone config written" "Green"
}

# --- Step 3: Sync models -----------------------------------------------------
function Sync-Models {
    Log "=== Syncing models (~90 GB) ===" "Cyan"
    New-Item -ItemType Directory -Path "$COMFYUI_DIR\models" -Force | Out-Null

    & $RCLONE_EXE --config $RCLONE_CONF copy `
        "$REMOTE/models" "$COMFYUI_DIR\models" `
        --transfers 8 `
        --size-only `
        --progress `
        --log-file $LOG --log-level INFO

    if ($LASTEXITCODE -ne 0) { Die "models sync failed (exit $LASTEXITCODE)" }
    Log "Models sync complete" "Green"
}

# --- Step 4: Download + extract custom_nodes ---------------------------------
function Restore-CustomNodes {
    Log "=== Restoring custom_nodes ===" "Cyan"
    $tarPath = "$TEMP_DIR\custom_nodes.tar.gz"

    if (-not (Test-Path $tarPath)) {
        Log "Downloading custom_nodes.tar.gz..." "Blue"
        & $RCLONE_EXE --config $RCLONE_CONF copyto `
            "$REMOTE/customNodes/custom_nodes.tar.gz" $tarPath `
            --progress
        if ($LASTEXITCODE -ne 0) { Die "custom_nodes download failed" }
    } else {
        Log "custom_nodes.tar.gz already downloaded" "Blue"
    }

    $sizeGB = [math]::Round((Get-Item $tarPath).Length / 1GB, 2)
    Log "Extracting ${sizeGB} GB into $COMFYUI_DIR ..." "Blue"
    tar.exe -xzf $tarPath -C $COMFYUI_DIR
    if ($LASTEXITCODE -ne 0) { Die "custom_nodes extraction failed" }
    Log "custom_nodes restored" "Green"
}

# --- Step 5: Download + extract site-packages --------------------------------
function Restore-SitePackages {
    if (-not (Test-Path "$COMFYUI_DIR\.venv")) {
        Log "WARNING: .venv not found at $COMFYUI_DIR\.venv" "Yellow"
        Log "  Run: python -m venv $COMFYUI_DIR\.venv  then re-run this script" "Yellow"
        return
    }

    Log "=== Restoring Python site-packages ===" "Cyan"
    $tarPath = "$TEMP_DIR\site_packages.tar.gz"

    if (-not (Test-Path $tarPath)) {
        Log "Downloading site_packages.tar.gz (~3.8 GB)..." "Blue"
        & $RCLONE_EXE --config $RCLONE_CONF copyto `
            "$REMOTE/Python/site_packages.tar.gz" $tarPath `
            --progress
        if ($LASTEXITCODE -ne 0) { Die "site_packages download failed" }
    } else {
        Log "site_packages.tar.gz already downloaded" "Blue"
    }

    $sizeGB = [math]::Round((Get-Item $tarPath).Length / 1GB, 2)
    Log "Extracting ${sizeGB} GB into $VENV_LIB ..." "Blue"
    New-Item -ItemType Directory -Path $VENV_LIB -Force | Out-Null
    tar.exe -xzf $tarPath -C $VENV_LIB
    if ($LASTEXITCODE -ne 0) { Die "site_packages extraction failed" }
    Log "site-packages restored" "Green"
}

# --- Step 6: Verify ----------------------------------------------------------
function Verify {
    Log "=== Verification ===" "Cyan"
    $modelCount = (Get-ChildItem "$COMFYUI_DIR\models" -Recurse -File -ErrorAction SilentlyContinue).Count
    $nodeCount  = (Get-ChildItem "$COMFYUI_DIR\custom_nodes" -Directory -ErrorAction SilentlyContinue).Count
    $pkgCount   = (Get-ChildItem "$VENV_LIB\site-packages" -Directory -ErrorAction SilentlyContinue).Count
    Log "Models files   : $modelCount" "White"
    Log "Custom nodes   : $nodeCount dirs" "White"
    Log "Site-packages  : $pkgCount packages" "White"
}

# --- Main --------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ComfyUI Asset Download from DO Spaces" -ForegroundColor Cyan
Write-Host "  Source : $DO_ENDPOINT/$DO_BUCKET/$DO_PREFIX" -ForegroundColor Cyan
Write-Host "  Dest   : $COMFYUI_DIR" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Path $LOG_DIR  -Force | Out-Null
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

Log "=== Starting download ===" "Cyan"

Install-Rclone
Configure-Rclone
Sync-Models
Restore-CustomNodes
Restore-SitePackages
Verify

Write-Host ""
Log "=== ALL DONE ===" "Green"
Log "Log saved to: $LOG" "Green"
Log "Start ComfyUI: cd $COMFYUI_DIR && .venv\Scripts\activate && python main.py --listen" "Green"
