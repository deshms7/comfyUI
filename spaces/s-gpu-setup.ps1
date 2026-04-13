# s-gpu-setup.ps1 - Full ComfyUI + GPU setup (no models/custom-nodes)
# Run as Admin: iex (irm 'RAW_URL/spaces/s-gpu-setup.ps1')
# CUDA 12.x driver must already be installed (check: nvidia-smi)

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\gpu-setup.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma" -Force | Out-Null
New-Item -ItemType Directory -Path "C:\Logs\illuma\tmp" -Force | Out-Null

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

Log "=== ComfyUI GPU Setup ===" "Cyan"
Log "  Log: $LOG" "DarkGray"

function RefreshEnv {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Download($url, $out) {
    Log "  Downloading $(Split-Path $url -Leaf)..." "Blue"
    for ($i = 1; $i -le 3; $i++) {
        curl.exe -fsSL --retry 3 -o $out $url
        if ($LASTEXITCODE -eq 0) { return }
        Log "  Retry $i..." "Yellow"
        Start-Sleep -Seconds ($i * 5)
    }
    Fail "Download failed: $url"
}

function FindPython {
    $paths = @(
        "C:\Program Files\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($p in $paths) {
        if ((Test-Path $p) -and ($p -notlike "*WindowsApps*")) {
            $ver = (& $p --version 2>&1).ToString()
            if ($ver -match "3\.11") { return $p }
        }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and ($cmd.Source -notlike "*WindowsApps*")) { return $cmd.Source }
    return ""
}

# ============================================================
# PHASE 1 - Python 3.11
# ============================================================
Log "" ; Log "--- Phase 1: Python 3.11 ---" "Cyan"

$PY = FindPython
if ($PY -ne "") {
    $v = (& $PY --version 2>&1).ToString()
    SKP ("Python already installed: " + $v + " at " + $PY)
} else {
    Log "  Installing Python 3.11.9..." "Blue"
    $inst = "C:\Logs\illuma\tmp\py311.exe"
    Download "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" $inst
    & $inst /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=0 TargetDir="C:\Python311"
    if ($LASTEXITCODE -ne 0) { Fail "Python install failed exit code: $LASTEXITCODE" }
    RefreshEnv
    $PY = FindPython
    if ($PY -eq "") { Fail "Python not found after install - check installer log" }
    OK ("Python installed: " + $PY)
}
RefreshEnv

# ============================================================
# PHASE 2 - Git
# ============================================================
Log "" ; Log "--- Phase 2: Git ---" "Cyan"

$env:Path += ";C:\Program Files\Git\bin;C:\Program Files\Git\cmd"
$GIT = Get-Command git -ErrorAction SilentlyContinue
if ($GIT) {
    SKP ("Git: " + $GIT.Source)
} else {
    Log "  Installing Git..." "Blue"
    $inst = "C:\Logs\illuma\tmp\git.exe"
    Download "https://github.com/git-for-windows/git/releases/download/v2.44.0.windows.1/Git-2.44.0-64-bit.exe" $inst
    & $inst /VERYSILENT /NORESTART /NOCANCEL /SP- /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"
    if ($LASTEXITCODE -ne 0) { Fail "Git install failed: $LASTEXITCODE" }
    RefreshEnv
    $env:Path += ";C:\Program Files\Git\bin;C:\Program Files\Git\cmd"
    $GIT = Get-Command git -ErrorAction SilentlyContinue
    if (-not $GIT) { Fail "git not found after install" }
    OK ("Git installed: " + $GIT.Source)
}

# ============================================================
# PHASE 3 - Clone ComfyUI
# ============================================================
Log "" ; Log "--- Phase 3: Clone ComfyUI ---" "Cyan"

$COMFYUI = "C:\ComfyUI"
New-Item -ItemType Directory -Path $COMFYUI -Force | Out-Null

if (Test-Path "$COMFYUI\.git") {
    SKP "ComfyUI repo already present"
} else {
    Log "  Cloning ComfyUI (latest main)..." "Blue"
    & git clone https://github.com/comfyanonymous/ComfyUI.git $COMFYUI
    if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
    OK "ComfyUI cloned"
}

# ============================================================
# PHASE 4 - Create venv
# ============================================================
Log "" ; Log "--- Phase 4: Python venv ---" "Cyan"

$VENV = "$COMFYUI\.venv"
if (Test-Path "$VENV\Scripts\python.exe") {
    SKP "venv already exists"
} else {
    Log "  Creating venv..." "Blue"
    & $PY -m venv $VENV
    if ($LASTEXITCODE -ne 0) { Fail "venv creation failed" }
    OK "venv created at $VENV"
}

$VPIP = "$VENV\Scripts\pip.exe"
$VPY  = "$VENV\Scripts\python.exe"

# ============================================================
# PHASE 5 - PyTorch with CUDA 12.4 (works on CUDA 12.6 driver)
# ============================================================
Log "" ; Log "--- Phase 5: PyTorch + CUDA ---" "Cyan"

$torchOk = $false
try {
    $torchVer = (& $VPY -c "import torch; print(torch.__version__)" 2>&1).ToString()
    if ($torchVer -match "^\d") {
        $cudaOk = (& $VPY -c "import torch; print(torch.cuda.is_available())" 2>&1).ToString().Trim()
        SKP ("PyTorch already installed: " + $torchVer + " cuda=" + $cudaOk)
        $torchOk = $true
    }
} catch {}

if (-not $torchOk) {
    Log "  Installing PyTorch 2.5.1 + cu124 (this may take 5-10 min)..." "Blue"
    & $VPIP install --upgrade pip --quiet
    & $VPIP install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
    if ($LASTEXITCODE -ne 0) { Fail "PyTorch install failed" }
    OK "PyTorch installed"
}

# ============================================================
# PHASE 6 - ComfyUI requirements
# ============================================================
Log "" ; Log "--- Phase 6: ComfyUI requirements ---" "Cyan"

Log "  Installing requirements.txt..." "Blue"
& $VPIP install -r "$COMFYUI\requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) { Fail "requirements.txt install failed" }
OK "Requirements installed"

# ============================================================
# PHASE 7 - Verify GPU
# ============================================================
Log "" ; Log "--- Phase 7: GPU verification ---" "Cyan"

$cudaAvail = (& $VPY -c "import torch; print('CUDA:', torch.cuda.is_available(), '| Device:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NONE')" 2>&1).ToString().Trim()
Log "  $cudaAvail" "Yellow"
if ($cudaAvail -notmatch "True") {
    Log "[!!] WARNING: CUDA not available from Python - check driver" "Red"
} else {
    OK "GPU verified: $cudaAvail"
}

# ============================================================
# DONE
# ============================================================
Log ""
Log "=== SETUP COMPLETE ===" "Green"
Log ""
Log "  ComfyUI : $COMFYUI" "White"
Log "  Python  : $VPY" "White"
Log "  GPU     : $cudaAvail" "White"
Log ""
Log "  To start ComfyUI (open new Admin PowerShell):" "Cyan"
Log "    cd C:\ComfyUI" "White"
Log "    .venv\Scripts\activate" "White"
Log "    python main.py --listen 0.0.0.0 --port 8188" "White"
Log ""
Log "  Then open browser: http://91.108.80.252:<RDP_FORWARDED_PORT>" "Cyan"
Log "  (check port forwarding on TensorDock dashboard for port 8188)" "Yellow"
Log ""
Read-Host "Press Enter to close"
