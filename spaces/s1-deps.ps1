# s1-deps.ps1 - Install Python 3.11, Git, rclone + write rclone config
# Run as Admin: powershell -ExecutionPolicy Bypass -File C:\setup\s1-deps.ps1
# Requires: C:\setup\creds.ps1

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\s1.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Logs\illuma\tmp" -Force | Out-Null

function Log($m, $c) { if (-not $c) { $c = "White" }; $t = "[$(Get-Date -f HH:mm:ss)] $m"; Write-Host $t -ForegroundColor $c; [IO.File]::AppendAllText($LOG, "$t`n") }
function OK($m)  { Log "[OK] $m" "Green" }
function SKP($m) { Log "[--] $m (skip)" "DarkGray" }
function Fail($m){ Log "[!!] $m" "Red"; throw $m }

trap {
    Log "[!!] ERROR at line $($_.InvocationInfo.ScriptLineNumber): $_" "Red"
    Get-Content $LOG -Tail 10 -ErrorAction SilentlyContinue
    Read-Host "Press Enter to close"
    exit 1
}

Log "=== s1: Install dependencies ===" "Cyan"

# Load creds (needed for rclone config)
if (-not (Test-Path "C:\setup\creds.ps1")) { Fail "C:\setup\creds.ps1 not found" }
. "C:\setup\creds.ps1"

# Refresh PATH helper
function RefreshEnv {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Download($url, $out) {
    Log "  Downloading $(Split-Path $url -Leaf)..." "Blue"
    for ($i = 1; $i -le 3; $i++) {
        curl.exe -fL --retry 3 -o $out $url
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds ($i * 5)
    }
    Fail "Download failed: $url"
}

# --- Python 3.11 ---
$STUB = "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"
$PY   = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
if (-not (Test-Path $PY)) { $PY = "C:\Python311\python.exe" }

$pyOk = $false
if ((Test-Path $PY) -and $PY -notlike "*WindowsApps*") {
    $v = (& $PY --version 2>&1).ToString()
    if ($v -match "3\.11") { $pyOk = $true }
}

if ($pyOk) {
    SKP "Python 3.11 ($v)"
} else {
    Log "  Installing Python 3.11.9..." "Blue"
    $inst = "C:\Logs\illuma\tmp\py.exe"
    Download "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" $inst
    & $inst /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=0
    if ($LASTEXITCODE -ne 0) { Fail "Python install failed: $LASTEXITCODE" }
    RefreshEnv
    $PY = "C:\Program Files\Python311\python.exe"
    if (-not (Test-Path $PY)) { $PY = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe" }
    OK "Python 3.11 installed"
}
RefreshEnv

# --- Git ---
$GIT = (Get-Command git -ErrorAction SilentlyContinue)
if ($GIT) {
    SKP "Git"
} else {
    Log "  Installing Git..." "Blue"
    $inst = "C:\Logs\illuma\tmp\git.exe"
    Download "https://github.com/git-for-windows/git/releases/download/v2.44.0.windows.1/Git-2.44.0-64-bit.exe" $inst
    & $inst /VERYSILENT /NORESTART /NOCANCEL /SP-
    if ($LASTEXITCODE -ne 0) { Fail "Git install failed: $LASTEXITCODE" }
    RefreshEnv
    OK "Git installed"
}

# --- rclone ---
$RC      = "C:\Tools\rclone\rclone.exe"
$RC_CONF = "C:\Tools\rclone\rclone.conf"
if (Test-Path $RC) {
    SKP "rclone"
} else {
    New-Item -ItemType Directory -Path "C:\Tools\rclone" -Force | Out-Null
    $z = "C:\Logs\illuma\tmp\rclone.zip"
    Download "https://downloads.rclone.org/rclone-current-windows-amd64.zip" $z
    Expand-Archive -Path $z -DestinationPath "C:\Logs\illuma\tmp" -Force
    $d = Get-ChildItem "C:\Logs\illuma\tmp\rclone-*-windows-amd64" | Select-Object -First 1
    Copy-Item "$($d.FullName)\rclone.exe" $RC -Force
    OK "rclone installed"
}

# --- rclone config ---
$ep   = "$DO_REGION.digitaloceanspaces.com"
$conf = "[spaces]" + [char]10
$conf += "type = s3" + [char]10
$conf += "provider = DigitalOcean" + [char]10
$conf += "access_key_id = $DO_KEY" + [char]10
$conf += "secret_access_key = $DO_SECRET" + [char]10
$conf += "endpoint = $ep" + [char]10
$conf += "acl = private" + [char]10
[IO.File]::WriteAllText($RC_CONF, $conf, [System.Text.Encoding]::UTF8)
OK "rclone config written"

Log ""
Log "=== s1 DONE ===" "Green"
Log "  Python : $PY" "White"
Log "  rclone : $RC" "White"
Log "  Next   : powershell -ExecutionPolicy Bypass -File C:\setup\s2-comfyui.ps1" "Cyan"
Read-Host "Press Enter to close"
