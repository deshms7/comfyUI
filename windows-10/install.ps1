# ComfyUI on Windows 10 -- Main Installation Script
# Native Python install (no Docker), managed as a Windows service via NSSM
#
# Usage (run as Administrator in PowerShell):
#   Set-ExecutionPolicy RemoteSigned -Scope Process -Force
#   .\install.ps1
#
# Override defaults via environment variables before running:
#   $env:COMFYUI_PORT = "8188"                        # default: 8188
#   $env:REEMO_AGENT_TOKEN = "studio_fa413ff7044b"    # PFX Reemo studio key (Phase 8)
#   $env:PARSEC_TEAM_ID    = "<id>"                   # optional
#   $env:PARSEC_TEAM_SECRET= "<sec>"                  # optional

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SCRIPT_DIR = $PSScriptRoot

# Dot-source all phase scripts
. "$SCRIPT_DIR\scripts\common.ps1"
. "$SCRIPT_DIR\scripts\system-setup.ps1"
. "$SCRIPT_DIR\scripts\python-install.ps1"
. "$SCRIPT_DIR\scripts\comfyui-service.ps1"
. "$SCRIPT_DIR\scripts\custom-nodes.ps1"
. "$SCRIPT_DIR\scripts\validate.ps1"
. "$SCRIPT_DIR\scripts\workflow-test.ps1"
. "$SCRIPT_DIR\scripts\remote-access.ps1"

function Main {
    Write-Host "====== ComfyUI Windows 10 Setup ======"

    # Must run as Administrator
    $currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "This script must be run as Administrator." -ForegroundColor Red
        Write-Host "Right-click PowerShell -> Run as Administrator, then re-run."
        exit 1
    }

    # OS gate -- Windows 10 or later
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        Write-Host "Warning: This script is designed for Windows 10+ (detected: $($osVersion))"
        $response = Read-Host "Continue anyway? [y/N]"
        if ($response -notmatch "^[Yy]$") { exit 1 }
    }

    # Pre-flight
    Write-Host ""
    Write-Host "=== Pre-flight Checks ==="
    Check-SystemRequirements -MinCores 16 -MinRamGB 32

    # GPU check
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) { $nvidiaSmi = "C:\Windows\System32\nvidia-smi.exe" }
    if (-not (Test-Path "$nvidiaSmi")) {
        Write-Host "ERROR: nvidia-smi not found -- NVIDIA driver required" -ForegroundColor Red
        exit 1
    }
    $gpuLine = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1 | Select-Object -First 1
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [SUCCESS] GPU: $gpuLine" -ForegroundColor Green

    # Installation plan
    Write-Host ""
    Write-Host "=== Installation Plan ==="
    Write-Host "  Install dir: $COMFYUI_DIR"
    Write-Host "  Port:        $COMFYUI_PORT"
    Write-Host "  Service:     $SERVICE_NAME (NSSM)"
    Write-Host ""
    Write-Host "  1. Pre-flight checks (OS, CPU, RAM, GPU, disk)"
    Write-Host "  2. System baseline (directories, verify NVIDIA driver)"
    Write-Host "  3. Python 3.13 + MinGit + NSSM (direct downloads, parallel)"
    Write-Host "  4. Clone ComfyUI (commit 040460495), create venv, install PyTorch cu128"
    Write-Host "  4.5 Install 25+ custom nodes from PFX snapshot"
    Write-Host "  5. Register and start ComfyUI Windows service (NSSM)"
    Write-Host "  6. Validation (service, port, GPU via PyTorch)"
    Write-Host "  7. Workflow test (download SD1.5 model, run txt2img, verify output)"
    Write-Host "  8. Remote access setup (Parsec host + Reemo agent)"
    Write-Host ""
    $response = Read-Host "Continue? [y/N]"
    if ($response -notmatch "^[Yy]$") { exit 1 }

    Setup-Logging

    # Phase 2
    Print-Message "blue" "=== Phase 2: System Baseline ==="
    Invoke-SystemSetup

    # Phase 3
    Print-Message "blue" "=== Phase 3: Python + Git + NSSM ==="
    Invoke-PythonInstall

    # Phase 4 + 4.5 + 5
    Print-Message "blue" "=== Phase 4+4.5+5: ComfyUI Install + Custom Nodes + Service ==="
    Invoke-ComfyUISetup

    # Phase 6
    Print-Message "blue" "=== Phase 6: Validation ==="
    Invoke-Validate

    # Phase 7
    Print-Message "blue" "=== Phase 7: Workflow Test ==="
    Invoke-WorkflowTest

    # Phase 8
    Print-Message "blue" "=== Phase 8: Remote Access Setup ==="
    if ($env:REEMO_AGENT_TOKEN) {
        Invoke-RemoteAccessSetup
    } else {
        Print-Message "yellow" "SKIP Phase 8: REEMO_AGENT_TOKEN not set"
        Print-Message "yellow" "  To install remote access later, run:"
        Print-Message "yellow" "  `$env:REEMO_AGENT_TOKEN='<key>'; .\install.ps1"
    }

    Stop-Logging
    Print-Message "green" "Installation complete!"
}

Main
