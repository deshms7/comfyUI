# s2-comfyui.ps1 - Clone ComfyUI repo and create Python venv
# Run as Admin: powershell -ExecutionPolicy Bypass -File C:\setup\s2-comfyui.ps1

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\s2.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma" -Force | Out-Null

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

Log "=== s2: Setup ComfyUI ===" "Cyan"

$COMFYUI     = "C:\ComfyUI"
$VENV        = "$COMFYUI\.venv"
$COMFY_REPO  = "https://github.com/comfyanonymous/ComfyUI.git"
$COMFY_PIN   = "040460495c"

# Resolve python.exe (skip Windows Store stub)
function FindPython {
    $candidates = @(
        "C:\Program Files\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($p in $candidates) {
        if ((Test-Path $p) -and $p -notlike "*WindowsApps*") {
            $v = (& $p --version 2>&1).ToString()
            if ($v -match "3\.11") { return $p }
        }
    }
    # Last resort: search PATH
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notlike "*WindowsApps*") { return $cmd.Source }
    return ""
}

$PY = FindPython
if ($PY -eq "") { Fail "Python 3.11 not found - run s1-deps.ps1 first" }
Log "  Using python: $PY" "DarkGray"

$GIT = (Get-Command git -ErrorAction SilentlyContinue)
if (-not $GIT) {
    $env:Path += ";C:\Program Files\Git\bin"
    $GIT = (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $GIT) { Fail "Git not found - run s1-deps.ps1 first" }
}

# --- Clone ComfyUI ---
New-Item -ItemType Directory -Path $COMFYUI -Force | Out-Null

if (Test-Path "$COMFYUI\.git") {
    SKP "ComfyUI repo already cloned"
} else {
    Log "  Cloning ComfyUI..." "Blue"
    & git clone $COMFY_REPO $COMFYUI
    if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
    & git -C $COMFYUI checkout $COMFY_PIN
    OK "ComfyUI cloned @ $COMFY_PIN"
}

# --- Create venv ---
if (Test-Path "$VENV\Scripts\python.exe") {
    SKP "venv already exists"
} else {
    Log "  Creating venv at $VENV ..." "Blue"
    & $PY -m venv $VENV
    if ($LASTEXITCODE -ne 0) { Fail "venv creation failed" }
    OK "venv created"
}

Log ""
Log "=== s2 DONE ===" "Green"
Log "  ComfyUI: $COMFYUI" "White"
Log "  venv   : $VENV" "White"
Log "  Next   : powershell -ExecutionPolicy Bypass -File C:\setup\s3-download.ps1" "Cyan"
Read-Host "Press Enter to close"
