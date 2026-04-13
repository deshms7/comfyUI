# s-download-pfx.ps1 - Download models + customNodes from DO Spaces (pfx-comfyui-assets, tor1)
# Run as Admin: iex (irm 'RAW_URL/spaces/s-download-pfx.ps1')

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\pfx-download.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma"     -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Logs\illuma\tmp" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Tools\rclone"    -Force | Out-Null

function Log($m, $c) { if (-not $c) { $c = "White" }; $t = "[$(Get-Date -f HH:mm:ss)] $m"; Write-Host $t -ForegroundColor $c; [IO.File]::AppendAllText($LOG, "$t`n") }
function OK($m)  { Log "[OK] $m" "Green" }
function SKP($m) { Log "[--] $m (skip)" "DarkGray" }
function Fail($m){ Log "[!!] $m" "Red"; throw $m }

trap {
    Log "[!!] ERROR at line $($_.InvocationInfo.ScriptLineNumber): $_" "Red"
    Get-Content $LOG -Tail 15 -ErrorAction SilentlyContinue
    Read-Host "Press Enter to close"
    exit 1
}

# ── Config ────────────────────────────────────────────────────────────────────
$DO_ACCESS_KEY  = "DO801A62JD3LB7EL2PJ8"
$DO_SECRET_KEY  = "Gz8MY2CAO8uElVxuQs973bzL+JvOJFHGqxnKOrdb/aE"
$DO_ENDPOINT    = "https://tor1.digitaloceanspaces.com"
$DO_BUCKET      = "pfx-comfyui-assets"
$DO_REGION      = "tor1"

$SPACES_MODELS  = "comfy_models_nodes/models"
$SPACES_NODES   = "comfy_models_nodes/customNodes"

$LOCAL_MODELS   = "C:\ComfyUI\models"
$LOCAL_NODES    = "C:\ComfyUI\custom_nodes"

$RC             = "C:\Tools\rclone\rclone.exe"
$RC_CONF        = "C:\Tools\rclone\rclone.conf"
$LOG_MODELS     = "C:\Logs\illuma\dl-models.log"
$LOG_NODES      = "C:\Logs\illuma\dl-nodes.log"

Log "=== PFX ComfyUI Asset Download ===" "Cyan"
Log "  Bucket : $DO_BUCKET  ($DO_REGION)" "DarkGray"
Log "  Models : $SPACES_MODELS  -->  $LOCAL_MODELS" "DarkGray"
Log "  Nodes  : $SPACES_NODES  -->  $LOCAL_NODES" "DarkGray"

# ============================================================
# PHASE 1 - rclone
# ============================================================
Log "" ; Log "--- Phase 1: rclone ---" "Cyan"

if (Test-Path $RC) {
    SKP "rclone already at $RC"
} else {
    Log "  Downloading rclone for Windows..." "Blue"
    $zip = "C:\Logs\illuma\tmp\rclone.zip"
    for ($i = 1; $i -le 3; $i++) {
        curl.exe -fsSL --retry 3 -o $zip "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -eq 3) { Fail "rclone download failed after 3 attempts" }
        Log "  Retry $i..." "Yellow"; Start-Sleep ($i * 5)
    }
    Expand-Archive -Path $zip -DestinationPath "C:\Logs\illuma\tmp\rclone-extract" -Force
    $rcloneExe = Get-ChildItem "C:\Logs\illuma\tmp\rclone-extract" -Recurse -Filter "rclone.exe" | Select-Object -First 1
    Copy-Item $rcloneExe.FullName $RC -Force
    OK "rclone installed: $RC"
}

# ============================================================
# PHASE 2 - rclone config
# ============================================================
Log "" ; Log "--- Phase 2: rclone config ---" "Cyan"

$confContent = @"
[spaces]
type = s3
provider = DigitalOcean
access_key_id = $DO_ACCESS_KEY
secret_access_key = $DO_SECRET_KEY
endpoint = $DO_ENDPOINT
region = $DO_REGION
acl = private
"@
[IO.File]::WriteAllText($RC_CONF, $confContent)
OK "rclone.conf written"

# ============================================================
# PHASE 3 - Create local directories
# ============================================================
Log "" ; Log "--- Phase 3: Directories ---" "Cyan"

New-Item -ItemType Directory -Path $LOCAL_MODELS -Force | Out-Null
New-Item -ItemType Directory -Path $LOCAL_NODES  -Force | Out-Null
OK "Directories ready: $LOCAL_MODELS  |  $LOCAL_NODES"

# ============================================================
# PHASE 4 - Check source sizes
# ============================================================
Log "" ; Log "--- Phase 4: Source sizes ---" "Cyan"

Log "  models..." "Blue"
& $RC --config $RC_CONF size "spaces:$DO_BUCKET/$SPACES_MODELS" --timeout 60s 2>&1 | ForEach-Object { Log "  $_" "DarkGray" }
Log "  customNodes..." "Blue"
& $RC --config $RC_CONF size "spaces:$DO_BUCKET/$SPACES_NODES" --timeout 60s 2>&1 | ForEach-Object { Log "  $_" "DarkGray" }

# ============================================================
# PHASE 5 - Start parallel background downloads
# ============================================================
Log "" ; Log "--- Phase 5: Download (parallel) ---" "Cyan"

$baseArgs = "--config `"$RC_CONF`" sync --transfers 8 --checkers 16 --retries 3 --timeout 300s --size-only --log-level INFO"

$mArgs = "$baseArgs `"spaces:$DO_BUCKET/$SPACES_MODELS`" `"$LOCAL_MODELS`" --log-file `"$LOG_MODELS`""
$nArgs = "$baseArgs `"spaces:$DO_BUCKET/$SPACES_NODES`"  `"$LOCAL_NODES`"  --log-file `"$LOG_NODES`""

$mProc = Start-Process -FilePath $RC -ArgumentList $mArgs -PassThru -WindowStyle Hidden
$nProc = Start-Process -FilePath $RC -ArgumentList $nArgs -PassThru -WindowStyle Hidden

Log "  Models  sync PID : $($mProc.Id)  log: $LOG_MODELS" "Green"
Log "  Nodes   sync PID : $($nProc.Id)  log: $LOG_NODES" "Green"
Log ""
Log "  Polling every 30s — close window anytime, rclone keeps running." "Yellow"

$deadline = (Get-Date).AddHours(4)
while ((Get-Date) -lt $deadline) {
    $mDone = $mProc.HasExited
    $nDone = $nProc.HasExited
    if ($mDone -and $nDone) { break }

    Start-Sleep 30

    $mGB = 0; $nGB = 0
    if (Test-Path $LOCAL_MODELS) { $mGB = [math]::Round((Get-ChildItem $LOCAL_MODELS -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 1) }
    if (Test-Path $LOCAL_NODES)  { $nGB = [math]::Round((Get-ChildItem $LOCAL_NODES  -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 1) }
    $mSt = if ($mDone) { "done" } else { "running" }
    $nSt = if ($nDone) { "done" } else { "running" }
    Log "  models: ${mGB} GB [$mSt]  |  nodes: ${nGB} GB [$nSt]" "DarkGray"
}

# ============================================================
# PHASE 6 - Results
# ============================================================
Log "" ; Log "--- Phase 6: Summary ---" "Cyan"

$mGB = 0; $nGB = 0
if (Test-Path $LOCAL_MODELS) { $mGB = [math]::Round((Get-ChildItem $LOCAL_MODELS -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 2) }
if (Test-Path $LOCAL_NODES)  { $nGB = [math]::Round((Get-ChildItem $LOCAL_NODES  -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 2) }

if (-not $mProc.HasExited) { Log "  Models still downloading (PID $($mProc.Id)) — check $LOG_MODELS" "Yellow" }
else                        { OK  "  Models sync complete  : ${mGB} GB  at $LOCAL_MODELS" }

if (-not $nProc.HasExited)  { Log "  Nodes  still downloading (PID $($nProc.Id)) — check $LOG_NODES" "Yellow" }
else                        { OK  "  Nodes  sync complete  : ${nGB} GB  at $LOCAL_NODES" }

Log ""
Log "=== DOWNLOAD STARTED/COMPLETE ===" "Green"
Log "  Models logs : $LOG_MODELS" "White"
Log "  Nodes  logs : $LOG_NODES" "White"
Log "  Monitor     : Get-Process rclone" "Cyan"
Log ""
Read-Host "Press Enter to close"
