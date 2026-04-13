# s-service-install.ps1 - Install ComfyUI as a Windows auto-start service via NSSM
# Run as Admin: iex (irm 'RAW_URL/spaces/s-service-install.ps1')

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\service-install.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma"     -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Logs\illuma\tmp" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Tools\nssm"      -Force | Out-Null

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

$NSSM     = "C:\Tools\nssm\nssm.exe"
$SVC_NAME = "ComfyUI"
$VPY      = "C:\ComfyUI\.venv\Scripts\python.exe"
$MAIN     = "C:\ComfyUI\main.py"
$SVC_LOG  = "C:\Logs\illuma\comfyui-svc.log"

Log "=== ComfyUI Service Install ===" "Cyan"

# ============================================================
# PHASE 1 - NSSM
# ============================================================
Log "" ; Log "--- Phase 1: NSSM ---" "Cyan"

if (Test-Path $NSSM) {
    SKP "NSSM already present at $NSSM"
} else {
    Log "  Downloading NSSM 2.24..." "Blue"
    $zip = "C:\Logs\illuma\tmp\nssm.zip"
    for ($i = 1; $i -le 3; $i++) {
        curl.exe -fsSL --retry 3 -o $zip "https://nssm.cc/release/nssm-2.24.zip"
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -eq 3) { Fail "NSSM download failed after 3 attempts" }
        Log "  Retry $i..." "Yellow"; Start-Sleep ($i * 5)
    }
    Expand-Archive -Path $zip -DestinationPath "C:\Logs\illuma\tmp\nssm-extract" -Force
    Copy-Item "C:\Logs\illuma\tmp\nssm-extract\nssm-2.24\win64\nssm.exe" $NSSM -Force
    OK "NSSM installed at $NSSM"
}

# ============================================================
# PHASE 2 - Pre-flight checks
# ============================================================
Log "" ; Log "--- Phase 2: Pre-flight ---" "Cyan"

if (-not (Test-Path $VPY))  { Fail "venv python not found: $VPY  -- run s-gpu-setup.ps1 first" }
if (-not (Test-Path $MAIN)) { Fail "ComfyUI main.py not found: $MAIN -- run s-gpu-setup.ps1 first" }
OK "venv and ComfyUI found"

# ============================================================
# PHASE 3 - Remove old service if present
# ============================================================
Log "" ; Log "--- Phase 3: Remove existing service ---" "Cyan"

$existing = Get-Service -Name $SVC_NAME -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.Status -eq "Running") {
        Log "  Stopping running service..." "Yellow"
        & $NSSM stop $SVC_NAME confirm
        Start-Sleep 5
    }
    Log "  Removing old service..." "Yellow"
    & $NSSM remove $SVC_NAME confirm
    OK "Old $SVC_NAME service removed"
} else {
    SKP "No existing $SVC_NAME service"
}

# ============================================================
# PHASE 4 - Install service
# ============================================================
Log "" ; Log "--- Phase 4: Install service ---" "Cyan"

& $NSSM install $SVC_NAME $VPY
if ($LASTEXITCODE -ne 0) { Fail "nssm install failed" }

& $NSSM set $SVC_NAME AppParameters "$MAIN --listen 0.0.0.0 --port 8188"
& $NSSM set $SVC_NAME AppDirectory  "C:\ComfyUI"
& $NSSM set $SVC_NAME AppStdout     $SVC_LOG
& $NSSM set $SVC_NAME AppStderr     $SVC_LOG
& $NSSM set $SVC_NAME AppRotateFiles 1
& $NSSM set $SVC_NAME AppRotateBytes 10485760
& $NSSM set $SVC_NAME Start SERVICE_AUTO_START
& $NSSM set $SVC_NAME ObjectName LocalSystem
OK "Service configured: auto-start, logging to $SVC_LOG"

# ============================================================
# PHASE 5 - Start service + verify
# ============================================================
Log "" ; Log "--- Phase 5: Start + verify ---" "Cyan"

& $NSSM start $SVC_NAME
Log "  Waiting 20s for ComfyUI to initialise..." "Blue"
Start-Sleep 20

$svc = Get-Service -Name $SVC_NAME -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "Service status: Running"
} else {
    $st = if ($svc) { $svc.Status } else { "NOT FOUND" }
    Log "[!!] Service status: $st -- check log: $SVC_LOG" "Red"
    Get-Content $SVC_LOG -Tail 30 -ErrorAction SilentlyContinue
}

Log "  HTTP check..." "Blue"
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -UseBasicParsing -TimeoutSec 30
    OK "ComfyUI HTTP $($r.StatusCode) on port 8188"
} catch {
    Log "[!!] HTTP check failed: $_" "Red"
    Log "  ComfyUI may still be loading -- check: Get-Service ComfyUI" "Yellow"
}

# ============================================================
# DONE
# ============================================================
Log ""
Log "=== SERVICE INSTALL COMPLETE ===" "Green"
Log "  Service  : $SVC_NAME  (auto-start on every boot)" "White"
Log "  Log file : $SVC_LOG" "White"
Log ""
Log "  Manage the service:" "Cyan"
Log "    Start   : nssm start ComfyUI   (or: net start ComfyUI)" "White"
Log "    Stop    : nssm stop ComfyUI    (or: net stop ComfyUI)" "White"
Log "    Restart : nssm restart ComfyUI" "White"
Log "    Status  : Get-Service ComfyUI" "White"
Log "    Logs    : $SVC_LOG" "White"
Log ""
Read-Host "Press Enter to close"
