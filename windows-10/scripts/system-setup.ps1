# Phase 2: System Baseline -- directories, admin check, Windows version gate

function Invoke-SystemSetup {
    if (Test-Sentinel ".system-baseline-done") {
        Print-Message "blue" "SKIP: System baseline already applied"
        return
    }

    Print-Message "blue" "Running system baseline setup..."

    # Create required directories
    foreach ($dir in @(
        $SENTINEL_DIR,
        $LOG_DIR,
        "$COMFYUI_DIR\models\checkpoints",
        "$COMFYUI_DIR\models\vae",
        "$COMFYUI_DIR\models\loras",
        "$COMFYUI_DIR\output",
        "$COMFYUI_DIR\custom_nodes"
    )) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Print-Message "blue" "Created: $dir"
        }
    }

    # Verify NVIDIA driver is installed
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        # Try common path
        $nvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
        if (-not (Test-Path $nvidiaSmi)) {
            Die "nvidia-smi not found -- NVIDIA driver must be installed before running this script"
        }
    }
    Print-Message "green" "NVIDIA driver present (nvidia-smi found)"

    Set-Sentinel ".system-baseline-done"
    Print-Message "green" "System baseline complete"
}
