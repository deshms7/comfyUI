# Phase 4 + 5: Clone ComfyUI, install dependencies (PyTorch cu128), register NSSM service

$COMFYUI_REPO  = "https://github.com/comfyanonymous/ComfyUI.git"
$VENV_DIR      = "$COMFYUI_DIR\.venv"
$PYTHON_VENV   = "$VENV_DIR\Scripts\python.exe"
$PIP_VENV      = "$VENV_DIR\Scripts\pip.exe"

function Invoke-ComfyUISetup {
    # ---- Phase 4: Clone + venv + pip install ----
    if (-not (Test-Sentinel ".comfyui-install-done")) {
        _Clone-ComfyUI
        _Create-Venv
        _Install-Dependencies
        Set-Sentinel ".comfyui-install-done"
        Print-Message "green" "ComfyUI installation complete"
    } else {
        Print-Message "blue" "SKIP: ComfyUI already installed"
    }

    # ---- Phase 4.5: Custom nodes (must be BEFORE service starts) ----
    Invoke-CustomNodesInstall

    # ---- Phase 5: Register and start service ----
    _Register-Service
}

function _Clone-ComfyUI {
    Print-Message "blue" "Cloning ComfyUI from GitHub..."

    # Find git -- check both full Git and MinGit installs
    Refresh-Path
    foreach ($gp in @("C:\Program Files\Git\cmd", "C:\MinGit\cmd")) {
        if ((Test-Path $gp) -and ($env:PATH -notlike "*$gp*")) {
            $env:PATH = "$env:PATH;$gp"
        }
    }

    # git writes progress to stderr; temporarily relax ErrorActionPreference so
    # those messages don't trigger a terminating error in PowerShell 5.
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    if (Test-Path "$COMFYUI_DIR\.git") {
        Print-Message "blue" "ComfyUI already cloned -- pulling latest..."
        Push-Location $COMFYUI_DIR
        & git pull --ff-only 2>&1 | ForEach-Object { Write-Host $_ }
        $pullExit = $LASTEXITCODE
        Pop-Location
        if ($pullExit -ne 0) { $ErrorActionPreference = $savedEAP; Die "git pull failed (exit: $pullExit)" }
    } else {
        # Remove pre-created directory (system-setup creates it empty) so git clone can proceed
        if (Test-Path $COMFYUI_DIR) {
            Print-Message "blue" "Removing pre-existing $COMFYUI_DIR before clone..."
            $ErrorActionPreference = $savedEAP
            Remove-Item $COMFYUI_DIR -Recurse -Force
            $ErrorActionPreference = "Continue"
        }
        # Shallow clone (--depth 1) -- much faster, no full history needed
        $parent = Split-Path $COMFYUI_DIR -Parent
        $name   = Split-Path $COMFYUI_DIR -Leaf
        & git clone --depth 1 $COMFYUI_REPO (Join-Path $parent $name) 2>&1 | ForEach-Object { Write-Host $_ }
        $cloneExit = $LASTEXITCODE
        if ($cloneExit -ne 0) { $ErrorActionPreference = $savedEAP; Die "git clone failed (exit: $cloneExit)" }
    }

    # Pin to the exact ComfyUI commit from PFX snapshot
    $COMFYUI_COMMIT = "040460495c5713b852e4aac29a909aa63b309da7"
    Push-Location $COMFYUI_DIR
    & git fetch --depth 1 origin $COMFYUI_COMMIT 2>&1 | ForEach-Object { Write-Host $_ }
    & git checkout $COMFYUI_COMMIT 2>&1 | ForEach-Object { Write-Host $_ }
    $checkoutExit = $LASTEXITCODE
    Pop-Location
    if ($checkoutExit -ne 0) { $ErrorActionPreference = $savedEAP; Die "git checkout $COMFYUI_COMMIT failed" }

    $ErrorActionPreference = $savedEAP
    Print-Message "green" "ComfyUI cloned and pinned to commit $COMFYUI_COMMIT"
}

function _Create-Venv {
    Print-Message "blue" "Creating Python virtual environment..."

    $pythonExe = Find-Python
    if (-not $pythonExe) { Die "Python not found -- run phase 3 (python-install) first" }

    if (-not (Test-Path $PYTHON_VENV)) {
        & $pythonExe -m venv $VENV_DIR 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { Die "Failed to create virtual environment" }
        Print-Message "green" "Virtual environment created at $VENV_DIR"
    } else {
        Print-Message "blue" "Virtual environment already exists"
    }

    # Upgrade pip inside venv
    & $PYTHON_VENV -m pip install --upgrade pip --quiet
}

function _Install-Dependencies {
    Print-Message "blue" "Installing PyTorch (CUDA 12.6) and ComfyUI requirements..."

    # PyTorch cu128 -- matches PFX snapshot (torch==2.7.1+cu128, torchvision==0.22.1+cu128)
    # RTX 6000 Ada (sm_89) fully supported; cu128 wheels require Driver >= 522.06
    Print-Message "blue" "Installing torch 2.7.1+cu128 (this may take several minutes)..."
    & $PIP_VENV install `
        "torch==2.7.1+cu128" "torchvision==0.22.1+cu128" "torchaudio==2.7.1+cu128" `
        --index-url https://download.pytorch.org/whl/cu128 `
        --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { Die "PyTorch installation failed" }
    Print-Message "green" "PyTorch 2.7.1+cu128 installed"

    # ComfyUI requirements
    Print-Message "blue" "Installing ComfyUI requirements..."
    & $PIP_VENV install -r "$COMFYUI_DIR\requirements.txt" --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { Die "ComfyUI requirements installation failed" }
    Print-Message "green" "ComfyUI requirements installed"
}

function _Register-Service {
    Print-Message "blue" "Registering ComfyUI as a Windows service via NSSM..."

    $nssm = Get-Command nssm -ErrorAction SilentlyContinue
    if (-not $nssm) {
        $nssm = "C:\Windows\System32\nssm.exe"
        if (-not (Test-Path $nssm)) { Die "nssm not found -- run phase 3 (python-install) first" }
    }

    # Stop and remove existing service if present
    $existing = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($existing) {
        Print-Message "blue" "Removing existing $SERVICE_NAME service..."
        if ($existing.Status -eq "Running") {
            & nssm stop $SERVICE_NAME confirm 2>&1 | Out-Null
        }
        & nssm remove $SERVICE_NAME confirm 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }

    Print-Message "blue" "Installing $SERVICE_NAME service..."
    & nssm install $SERVICE_NAME $PYTHON_VENV
    if ($LASTEXITCODE -ne 0) { Die "nssm install failed" }

    # Service parameters
    & nssm set $SERVICE_NAME AppParameters   "$COMFYUI_DIR\main.py --listen 0.0.0.0 --port $COMFYUI_PORT"
    & nssm set $SERVICE_NAME AppDirectory    $COMFYUI_DIR
    & nssm set $SERVICE_NAME DisplayName     "ComfyUI"
    & nssm set $SERVICE_NAME Description     "ComfyUI Stable Diffusion UI (Illuma)"
    & nssm set $SERVICE_NAME Start           SERVICE_AUTO_START
    & nssm set $SERVICE_NAME AppStdout       "$LOG_DIR\comfyui.log"
    & nssm set $SERVICE_NAME AppStderr       "$LOG_DIR\comfyui-error.log"
    & nssm set $SERVICE_NAME AppRotateFiles  1
    & nssm set $SERVICE_NAME AppRotateBytes  10485760

    # Start the service
    & nssm start $SERVICE_NAME
    if ($LASTEXITCODE -ne 0) { Die "Failed to start $SERVICE_NAME service" }

    Print-Message "green" "ComfyUI service registered and started"
}
