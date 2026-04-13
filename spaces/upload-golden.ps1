# spaces/upload-golden.ps1
#
# Uploads the current golden Windows VM state to DO Spaces.
# Run ONCE on the fully provisioned reference machine (104.255.9.187).
#
# What it uploads:
#   C:\ComfyUI\models\              → comfy_models_nodes/models/
#   C:\ComfyUI\custom_nodes\        → comfy_models_nodes/custom_nodes/
#   C:\ComfyUI\.venv\Lib\site-packages\  → comfy_models_nodes/site_packages/windows-venv.tar.gz
#
# Usage:
#   .\upload-golden.ps1 -Key <DO_KEY> -Secret <DO_SECRET>
#   $env:DO_SPACES_KEY="xxx"; $env:DO_SPACES_SECRET="xxx"; .\upload-golden.ps1
#
# Run as Administrator.

param(
    [string]$Key    = $env:DO_SPACES_KEY,
    [string]$Secret = $env:DO_SPACES_SECRET,
    [string]$Bucket = "pfx-comfyui-assets",
    [string]$Prefix = "comfy_models_nodes",
    [string]$Region = "tor1",
    [switch]$SkipModels,
    [switch]$SkipNodes,
    [switch]$SkipSitePackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RCLONE_DIR    = "C:\Tools\rclone"
$RCLONE_EXE    = "$RCLONE_DIR\rclone.exe"
$RCLONE_CONF   = "$RCLONE_DIR\rclone.conf"
$COMFYUI_DIR   = "C:\ComfyUI"
$VENV_DIR      = "$COMFYUI_DIR\.venv"
$LOG           = "C:\Logs\illuma\upload-golden.log"
$TEMP_DIR      = "C:\Logs\illuma\spaces-temp"

function Log {
    param([string]$msg, [string]$color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
    [System.IO.File]::AppendAllText($LOG, "[$ts] $msg`n")
}

# --- Validate ---
if (-not $Key -or -not $Secret) {
    Write-Error "Credentials required. Pass -Key/-Secret or set DO_SPACES_KEY/DO_SPACES_SECRET."
    exit 1
}

New-Item -ItemType Directory -Path (Split-Path $LOG -Parent) -Force | Out-Null
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

Log "=== Upload Golden VM → DO Spaces ===" "Cyan"
Log "Bucket  : $Bucket" "Cyan"
Log "Prefix  : $Prefix" "Cyan"
Log "Region  : $Region" "Cyan"
Log "Endpoint: ${Region}.digitaloceanspaces.com" "Cyan"

# ─────────────────────────────────────────────
# Step 1 — Install rclone (portable, no installer)
# ─────────────────────────────────────────────
if (-not (Test-Path $RCLONE_EXE)) {
    Log "Downloading rclone..." "Blue"
    New-Item -ItemType Directory -Path $RCLONE_DIR -Force | Out-Null
    $zip = "$TEMP_DIR\rclone.zip"
    curl.exe -L --retry 3 -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    Expand-Archive -Path $zip -DestinationPath $TEMP_DIR -Force
    $extracted = Get-ChildItem "$TEMP_DIR\rclone-*-windows-amd64" | Select-Object -First 1
    Copy-Item "$($extracted.FullName)\rclone.exe" $RCLONE_EXE
    Log "rclone installed at $RCLONE_EXE" "Green"
} else {
    Log "rclone already present at $RCLONE_EXE" "Blue"
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
Log "Remote target: $REMOTE" "Blue"

# ─────────────────────────────────────────────
# Step 3 — Sync models (~90 GB)
# rclone sync is idempotent: only uploads new/changed files (by size)
# ─────────────────────────────────────────────
if (-not $SkipModels) {
    Log "=== Syncing models (~90 GB) — progress below ===" "Cyan"
    & $RCLONE_EXE --config $RCLONE_CONF sync `
        "$COMFYUI_DIR\models" "$REMOTE/models" `
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
# Step 4 — Package venv site-packages
# Snapshot C:\ComfyUI\.venv\Lib\site-packages\ (PyTorch + all 38 node deps)
# Extracting this on a new machine (~3 min) replaces 30+ min of pip installs
# ─────────────────────────────────────────────
if (-not $SkipSitePackages) {
    $sitePkgsDir = "$VENV_DIR\Lib\site-packages"
    if (Test-Path $sitePkgsDir) {
        $tarPath = "$TEMP_DIR\windows-venv.tar.gz"
        Log "=== Packaging venv site-packages ===" "Cyan"
        Log "Source: $sitePkgsDir" "Blue"
        Log "This may take 3-5 minutes..." "Blue"

        # tar.exe is built-in on Windows 10 1803+
        tar.exe -czf $tarPath -C "$VENV_DIR\Lib" "site-packages"
        $sizeGB = [math]::Round((Get-Item $tarPath).Length / 1GB, 2)
        Log "Tarball: ${sizeGB} GB at $tarPath" "Blue"

        Log "Uploading site-packages snapshot..." "Blue"
        & $RCLONE_EXE --config $RCLONE_CONF copyto `
            $tarPath "$REMOTE/site_packages/windows-venv.tar.gz" `
            --progress
        if ($LASTEXITCODE -ne 0) { Log "ERROR: site-packages upload failed" "Red"; exit 1 }
        Log "site-packages uploaded" "Green"
    } else {
        Log "WARNING: $sitePkgsDir not found — skipping site-packages snapshot" "Yellow"
        Log "  Expected path: $sitePkgsDir" "Yellow"
    }
} else {
    Log "SKIP: site-packages (-SkipSitePackages)" "Yellow"
}

# ─────────────────────────────────────────────
# Step 5 — Sync custom_nodes code
# Excludes .git dirs — saves ~80% of transfer size
# ─────────────────────────────────────────────
if (-not $SkipNodes) {
    Log "=== Syncing custom_nodes ===" "Cyan"
    & $RCLONE_EXE --config $RCLONE_CONF sync `
        "$COMFYUI_DIR\custom_nodes" "$REMOTE/custom_nodes" `
        --transfers 8 `
        --size-only `
        --exclude ".git/**" `
        --exclude "__pycache__/**" `
        --progress `
        --log-file $LOG --log-level INFO
    if ($LASTEXITCODE -ne 0) { Log "ERROR: custom_nodes sync failed" "Red"; exit 1 }
    Log "custom_nodes sync complete" "Green"
} else {
    Log "SKIP: custom_nodes (-SkipNodes)" "Yellow"
}

# ─────────────────────────────────────────────
# Step 6 — Write version stamp
# download-spaces.ps1 reads this to detect stale local installs
# ─────────────────────────────────────────────
$version = Get-Date -Format "yyyy-MM-dd_HH-mm"
$vFile = "$TEMP_DIR\version.txt"
Set-Content -Path $vFile -Value $version -Encoding UTF8
& $RCLONE_EXE --config $RCLONE_CONF copyto $vFile "$REMOTE/version.txt"
Log "Version stamp: $version" "Blue"

Log "" "White"
Log "=== UPLOAD COMPLETE ===" "Green"
Log "Remote : $REMOTE" "Green"
Log "Run download-spaces.ps1 (Windows) or download-spaces.sh (Linux) on each new machine." "Green"
Log "Log    : $LOG" "Green"
