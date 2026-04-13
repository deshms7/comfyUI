# s3-download.ps1 - Download models, site-packages, custom_nodes from DO Spaces
# Run as Admin: powershell -ExecutionPolicy Bypass -File C:\setup\s3-download.ps1
# Requires: C:\setup\creds.ps1 and rclone at C:\Tools\rclone\rclone.exe

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\s3.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Logs\illuma\tmp" -Force | Out-Null

function Log($m, $c) { if (-not $c) { $c = "White" }; $t = "[$(Get-Date -f HH:mm:ss)] $m"; Write-Host $t -ForegroundColor $c; [IO.File]::AppendAllText($LOG, "$t`n") }
function OK($m)  { Log "[OK] $m" "Green" }
function Fail($m){ Log "[!!] $m" "Red"; throw $m }

trap {
    Log "[!!] ERROR at line $($_.InvocationInfo.ScriptLineNumber): $_" "Red"
    Get-Content $LOG -Tail 10 -ErrorAction SilentlyContinue
    Read-Host "Press Enter to close"
    exit 1
}

Log "=== s3: Download from DO Spaces ===" "Cyan"

if (-not (Test-Path "C:\setup\creds.ps1")) { Fail "C:\setup\creds.ps1 not found" }
iex (Get-Content "C:\setup\creds.ps1" -Raw)

$RC      = "C:\Tools\rclone\rclone.exe"
$RC_CONF = "C:\Tools\rclone\rclone.conf"
$REMOTE  = "spaces:$DO_BUCKET/$DO_PREFIX"
$MODELS  = "C:\ComfyUI\models"
$SP_TAR  = "C:\Logs\illuma\tmp\site_packages.tar.gz"
$CN_TAR  = "C:\Logs\illuma\tmp\custom_nodes.tar.gz"
$MDL_LOG = "C:\Logs\illuma\models-dl.log"

if (-not (Test-Path $RC))      { Fail "rclone not found at $RC - run s1-deps.ps1 first" }
if (-not (Test-Path $RC_CONF)) { Fail "rclone.conf not found - run s1-deps.ps1 first" }

New-Item -ItemType Directory -Path $MODELS -Force | Out-Null

Log "  [1] models     (~90 GB)  -> $MODELS" "Blue"
Log "  [2] site_pkgs  (~3.8 GB) -> $SP_TAR" "Blue"
Log "  [3] custom_nds (~1.5 GB) -> $CN_TAR" "Blue"

# Start model sync as detached background process (huge, 1-2 hrs)
$mArgs  = "--config `"$RC_CONF`" sync `"$REMOTE/models`" `"$MODELS`""
$mArgs += " --transfers 8 --size-only --log-file `"$MDL_LOG`" --log-level INFO"
$mProc  = Start-Process -FilePath $RC -PassThru -WindowStyle Hidden -ArgumentList $mArgs
Log "  Models sync started (PID $($mProc.Id)) - runs in background" "DarkGray"

# Download tarballs via background jobs
$dlBlock = {
    param($exe, $conf, $src, $dst, $log)
    & $exe --config $conf copyto $src $dst --transfers 4 --log-file $log --log-level INFO
}

$job_sp = Start-Job -ScriptBlock $dlBlock -ArgumentList $RC, $RC_CONF, "$REMOTE/Python/site_packages.tar.gz",   $SP_TAR, "C:\Logs\illuma\dl-sp.log"
$job_cn = Start-Job -ScriptBlock $dlBlock -ArgumentList $RC, $RC_CONF, "$REMOTE/customNodes/custom_nodes.tar.gz", $CN_TAR, "C:\Logs\illuma\dl-cn.log"

Log "  Waiting for tarballs (this window polls every 30s)..." "Blue"
Log "  You can leave this running - close anytime, models continue in background." "Yellow"

$deadline = (Get-Date).AddHours(2)
while ((Get-Date) -lt $deadline) {
    $spDone = ($job_sp.State -ne "Running")
    $cnDone = ($job_cn.State -ne "Running")
    if ($spDone -and $cnDone) { break }
    Start-Sleep -Seconds 30
    $spMB = 0; $cnMB = 0
    if (Test-Path $SP_TAR) { $spMB = [math]::Round((Get-Item $SP_TAR).Length / 1MB) }
    if (Test-Path $CN_TAR) { $cnMB = [math]::Round((Get-Item $CN_TAR).Length / 1MB) }
    Log "  sp: ${spMB} MB  |  cn: ${cnMB} MB  |  sp: $($job_sp.State)  cn: $($job_cn.State)" "DarkGray"
}

Receive-Job $job_sp -ErrorAction SilentlyContinue | Out-Null
Receive-Job $job_cn -ErrorAction SilentlyContinue | Out-Null
Remove-Job  $job_sp -Force
Remove-Job  $job_cn -Force

if (-not (Test-Path $SP_TAR)) { Fail "site_packages.tar.gz not downloaded - check C:\Logs\illuma\dl-sp.log" }
if (-not (Test-Path $CN_TAR)) { Fail "custom_nodes.tar.gz not downloaded - check C:\Logs\illuma\dl-cn.log" }

$spMB = [math]::Round((Get-Item $SP_TAR).Length / 1MB)
$cnMB = [math]::Round((Get-Item $CN_TAR).Length / 1MB)

Log ""
Log "=== s3 DONE ===" "Green"
Log "  site_packages.tar.gz : ${spMB} MB" "White"
Log "  custom_nodes.tar.gz  : ${cnMB} MB" "White"
Log "  models sync PID      : $($mProc.Id) (still running in background)" "White"
Log "  Models log           : $MDL_LOG" "DarkGray"
Log "  Next: powershell -ExecutionPolicy Bypass -File C:\setup\s4-extract.ps1" "Cyan"
Read-Host "Press Enter to close"
