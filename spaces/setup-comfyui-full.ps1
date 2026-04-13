# setup-comfyui-full.ps1
# Run from an ADMIN PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\setup\setup-comfyui-full.ps1
# Keep creds.ps1 in C:\setup\

$ErrorActionPreference = "Stop"

#  Credentials - always in C:\setup\creds.ps1 
$credsFile = "C:\setup\creds.ps1"
if (-not (Test-Path $credsFile)) {
    Write-Host "ERROR: creds.ps1 not found at C:\setup\creds.ps1" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
. $credsFile

trap {
    Write-Host ""
    Write-Host "FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  Script line : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Yellow
    Write-Host "  Command     : $($_.InvocationInfo.Line.Trim())" -ForegroundColor Yellow
    Write-Host "  Log         : C:\Logs\illuma\setup.log" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "--- Last 20 lines of log ---" -ForegroundColor Cyan
    Get-Content "C:\Logs\illuma\setup.log" -Tail 20 -ErrorAction SilentlyContinue
    Write-Host "----------------------------" -ForegroundColor Cyan
    Read-Host "Press Enter to close"
    exit 1
}

#  Config 
$COMFYUI    = "C:\ComfyUI"
$VENV       = "$COMFYUI\.venv"
$VENV_LIB   = "$VENV\Lib"
$MODELS     = "$COMFYUI\models"
$NODES      = "$COMFYUI\custom_nodes"
$TOOLS      = "C:\Tools\rclone"
$RC         = "$TOOLS\rclone.exe"
$RC_CONF    = "$TOOLS\rclone.conf"
$LOGDIR     = "C:\Logs\illuma"
$TMPDIR     = "$LOGDIR\tmp"
$LOG        = "$LOGDIR\setup.log"
$SP_TAR     = "$TMPDIR\site_packages.tar.gz"
$CN_TAR     = "$TMPDIR\custom_nodes.tar.gz"
$MDL_LOG    = "$LOGDIR\models-dl.log"
$REMOTE     = "spaces:$DO_BUCKET/$DO_PREFIX"
$PY_VER     = "3.11.9"
$PY_URL     = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
$GIT_URL    = "https://github.com/git-for-windows/git/releases/download/v2.44.0.windows.1/Git-2.44.0-64-bit.exe"
$RC_URL     = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
$COMFY_REPO = "https://github.com/comfyanonymous/ComfyUI.git"
$COMFY_PIN  = "040460495c"

#  Logging 
New-Item -ItemType Directory -Path $LOGDIR -Force | Out-Null
New-Item -ItemType Directory -Path $TMPDIR -Force | Out-Null

function L {
    param([string]$m, [string]$c)
    if (-not $c) { $c = "White" }
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $m" -ForegroundColor $c
    [System.IO.File]::AppendAllText($LOG, "[$ts] $m`n")
}
function Section($t) { L ""; L "=== $t ===" "Cyan" }
function OK($m) { L "  [OK] $m" "Green" }
function SK($m) { L "  [--] $m  (skip)" "DarkGray" }
function ERR($m) { L "  [!!] $m" "Red"; throw $m }

function RefreshPath {
    $mp = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    $up = [System.Environment]::GetEnvironmentVariable("Path","User")
    $env:Path = $mp + ";" + $up
}

function GetExe($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return ""
}

function Fetch($url, $out) {
    L "  Downloading: $url" "Blue"
    for ($i = 1; $i -le 3; $i++) {
        curl.exe -fL --retry 3 -o $out $url
        if ($LASTEXITCODE -eq 0) { return }
        L "  Retry $i ..." "Yellow"
        Start-Sleep -Seconds ($i * 5)
    }
    ERR "Download failed: $url"
}

# =============================================================================
Section "Phase 1 - Python $PY_VER"
# =============================================================================

$pyExe = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
if (-not (Test-Path $pyExe)) {
    $t = GetExe "python"
    if ($t -ne "") { $pyExe = $t }
}

$pyOk = $false
if (Test-Path $pyExe) {
    $v = (& $pyExe --version 2>&1).ToString()
    if ($v -match "3\.11") { $pyOk = $true }
}

if ($pyOk) {
    SK "Python 3.11"
} else {
    $inst = "$TMPDIR\py-setup.exe"
    Fetch $PY_URL $inst
    L "  Installing Python..." "Blue"
    & $inst /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=0
    if ($LASTEXITCODE -ne 0) { ERR "Python install failed: $LASTEXITCODE" }
    RefreshPath
    OK "Python installed"
}

RefreshPath
$t = GetExe "python"
if ($t -ne "") { $pyExe = $t }
if (-not (Test-Path $pyExe)) { ERR "python.exe not found after install" }
L "  python: $pyExe" "DarkGray"

# =============================================================================
Section "Phase 2 - Git"
# =============================================================================

$gitExe = GetExe "git"

if ($gitExe -ne "") {
    SK "Git"
} else {
    $inst = "$TMPDIR\git-setup.exe"
    Fetch $GIT_URL $inst
    & $inst /VERYSILENT /NORESTART /NOCANCEL /SP-
    if ($LASTEXITCODE -ne 0) { ERR "Git install failed: $LASTEXITCODE" }
    RefreshPath
    $gitExe = GetExe "git"
    if ($gitExe -eq "") { $gitExe = "C:\Program Files\Git\bin\git.exe" }
    OK "Git installed"
}

# =============================================================================
Section "Phase 3 - rclone"
# =============================================================================

if (Test-Path $RC) {
    SK "rclone"
} else {
    New-Item -ItemType Directory -Path $TOOLS -Force | Out-Null
    $z = "$TMPDIR\rclone.zip"
    Fetch $RC_URL $z
    Expand-Archive -Path $z -DestinationPath $TMPDIR -Force
    $d = Get-ChildItem "$TMPDIR\rclone-*-windows-amd64" | Select-Object -First 1
    Copy-Item "$($d.FullName)\rclone.exe" $RC -Force
    OK "rclone installed"
}

$ep   = "$DO_REGION.digitaloceanspaces.com"
$conf = "[spaces]" + [char]10
$conf += "type = s3" + [char]10
$conf += "provider = DigitalOcean" + [char]10
$conf += "access_key_id = $DO_KEY" + [char]10
$conf += "secret_access_key = $DO_SECRET" + [char]10
$conf += "endpoint = $ep" + [char]10
$conf += "acl = private" + [char]10
[IO.File]::WriteAllText($RC_CONF, $conf, [System.Text.Encoding]::UTF8)
L "  rclone config written" "DarkGray"

# =============================================================================
Section "Phase 4 - Clone ComfyUI"
# =============================================================================

New-Item -ItemType Directory -Path $COMFYUI -Force | Out-Null

if (Test-Path "$COMFYUI\.git") {
    SK "ComfyUI repo"
} else {
    L "  Cloning ComfyUI..." "Blue"
    & $gitExe clone $COMFY_REPO $COMFYUI
    if ($LASTEXITCODE -ne 0) { ERR "git clone failed" }
    & $gitExe -C $COMFYUI checkout $COMFY_PIN
    OK "ComfyUI cloned @ $COMFY_PIN"
}

# =============================================================================
Section "Phase 5 - Python venv"
# =============================================================================

if (Test-Path "$VENV\Scripts\python.exe") {
    SK "venv"
} else {
    L "  Creating venv..." "Blue"
    & $pyExe -m venv $VENV
    if ($LASTEXITCODE -ne 0) { ERR "venv creation failed" }
    OK "venv created"
}

# =============================================================================
Section "Phase 6 - Parallel downloads"
# =============================================================================

L "  [1] models     (~90 GB)  -> $MODELS" "Blue"
L "  [2] site_pkgs  (~3.8 GB) -> $SP_TAR" "Blue"
L "  [3] custom_nds (~1.5 GB) -> $CN_TAR" "Blue"

New-Item -ItemType Directory -Path $MODELS -Force | Out-Null

# Start model sync as background process (takes 1-2 hrs)
$mArgs = "--config `"$RC_CONF`" sync `"$REMOTE/models`" `"$MODELS`""
$mArgs = $mArgs + " --transfers 8 --size-only --log-file `"$MDL_LOG`" --log-level INFO"
$mProc = Start-Process -FilePath $RC -PassThru -WindowStyle Hidden -ArgumentList $mArgs
L "  Models sync started PID $($mProc.Id)" "DarkGray"

# Tarball download jobs
$spArgs = @($RC, $RC_CONF, "$REMOTE/Python/site_packages.tar.gz", $SP_TAR, "$LOGDIR\dl-sp.log")
$cnArgs = @($RC, $RC_CONF, "$REMOTE/customNodes/custom_nodes.tar.gz", $CN_TAR, "$LOGDIR\dl-cn.log")

$dlBlock = {
    param($exe, $conf, $src, $dst, $log)
    & $exe --config $conf copyto $src $dst --transfers 4 --log-file $log --log-level INFO
}

$job_sp = Start-Job -ScriptBlock $dlBlock -ArgumentList $spArgs
$job_cn = Start-Job -ScriptBlock $dlBlock -ArgumentList $cnArgs

L "  Waiting for tarballs..." "Blue"

$deadline = (Get-Date).AddHours(2)
while ((Get-Date) -lt $deadline) {
    $spDone = ($job_sp.State -ne "Running")
    $cnDone = ($job_cn.State -ne "Running")
    if ($spDone -and $cnDone) { break }
    Start-Sleep -Seconds 30
    $spMB = 0
    $cnMB = 0
    if (Test-Path $SP_TAR) { $spMB = [math]::Round((Get-Item $SP_TAR).Length / 1MB) }
    if (Test-Path $CN_TAR) { $cnMB = [math]::Round((Get-Item $CN_TAR).Length / 1MB) }
    L "  sp: ${spMB}MB  cn: ${cnMB}MB  sp_state:$($job_sp.State) cn_state:$($job_cn.State)" "DarkGray"
}

Receive-Job $job_sp -ErrorAction SilentlyContinue | Out-Null
Receive-Job $job_cn -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job_sp -Force
Remove-Job $job_cn -Force

if (-not (Test-Path $SP_TAR)) { ERR "site_packages.tar.gz missing - check $LOGDIR\dl-sp.log" }
if (-not (Test-Path $CN_TAR)) { ERR "custom_nodes.tar.gz missing - check $LOGDIR\dl-cn.log" }
OK "Tarballs ready"

# =============================================================================
Section "Phase 7 - Extract"
# =============================================================================

$pkgDir = "$VENV_LIB\site-packages"
$pkgCount = 0
if (Test-Path $pkgDir) {
    $pkgCount = (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue).Count
}
if ($pkgCount -gt 100) {
    SK ("site-packages " + $pkgCount + " pkgs")
} else {
    L "  Extracting site-packages into $VENV_LIB ..." "Blue"
    New-Item -ItemType Directory -Path $VENV_LIB -Force | Out-Null
    tar.exe -xzf $SP_TAR -C $VENV_LIB
    if ($LASTEXITCODE -ne 0) { ERR "site-packages extract failed" }
    $pkgCount = (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue).Count
    OK ("site-packages done: " + $pkgCount + " packages")
}

$nodeCount = 0
if (Test-Path $NODES) {
    $nodeCount = (Get-ChildItem $NODES -Directory -ErrorAction SilentlyContinue).Count
}
if ($nodeCount -gt 5) {
    SK ("custom_nodes " + $nodeCount + " nodes")
} else {
    L "  Extracting custom_nodes into $COMFYUI ..." "Blue"
    New-Item -ItemType Directory -Path $NODES -Force | Out-Null
    tar.exe -xzf $CN_TAR -C $COMFYUI
    if ($LASTEXITCODE -ne 0) { ERR "custom_nodes extract failed" }
    $nodeCount = (Get-ChildItem $NODES -Directory -ErrorAction SilentlyContinue).Count
    OK ("custom_nodes done: " + $nodeCount + " nodes")
}

# =============================================================================
Section "Phase 8 - Wait for models"
# =============================================================================

if ($mProc.HasExited) {
    if ($mProc.ExitCode -ne 0) {
        L "  WARNING: models exit $($mProc.ExitCode) - check $MDL_LOG" "Yellow"
    } else {
        OK "Models complete"
    }
} else {
    L "  Models still running (PID $($mProc.Id)) - monitoring..." "Blue"
    L "  Ctrl+C safe - download continues in background" "Yellow"
    $mDeadline = (Get-Date).AddHours(3)
    while (-not $mProc.HasExited -and (Get-Date) -lt $mDeadline) {
        Start-Sleep -Seconds 60
        $tail = Get-Content $MDL_LOG -Tail 1 -ErrorAction SilentlyContinue
        L "  [models] $tail" "DarkGray"
    }
    if ($mProc.HasExited) {
        OK "Models complete (exit $($mProc.ExitCode))"
    } else {
        L "  Models still downloading - check $MDL_LOG for progress" "Yellow"
    }
}

# =============================================================================
Section "Done"
# =============================================================================

$mf = (Get-ChildItem $MODELS -Recurse -File    -ErrorAction SilentlyContinue).Count
$nc = (Get-ChildItem $NODES  -Directory         -ErrorAction SilentlyContinue).Count
$pc = (Get-ChildItem $pkgDir -Directory         -ErrorAction SilentlyContinue).Count

L ""
L "  ComfyUI     : $COMFYUI" "White"
L "  Models      : $mf files" "White"
L "  Custom nodes: $nc" "White"
L "  Py packages : $pc" "White"
L "  Log         : $LOG" "DarkGray"
L ""
L "To start ComfyUI, open a new PowerShell and run:" "Cyan"
L "  cd C:\ComfyUI" "White"
L "  .venv\Scripts\activate" "White"
L "  python main.py --listen 0.0.0.0 --port 8188" "White"

Read-Host "Press Enter to close"
