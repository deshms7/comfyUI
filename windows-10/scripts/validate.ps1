# Phase 6: Validation -- service running, port responding, GPU accessible

function Invoke-Validate {
    Print-Message "blue" "Running validation checks..."
    $passed     = 0
    $maxAttempts = 30   # 30 x 10s = 5 min per check

    # CHECK 1: Windows service running
    Print-Message "blue" "CHECK 1/3: Waiting for $SERVICE_NAME service to start..."
    $attempt = 0
    do {
        $svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { break }
        $attempt++
        if ($attempt -ge $maxAttempts) {
            $logFile = "$LOG_DIR\comfyui.log"
            if (Test-Path $logFile) {
                Print-Message "red" "Last 20 lines of comfyui.log:"
                Get-Content $logFile -Tail 20 | Write-Host
            }
            Die "FAIL CHECK 1: $SERVICE_NAME service not running after $($maxAttempts * 10)s"
        }
        Print-Message "blue" "  Waiting for service... attempt $attempt/$maxAttempts"
        Start-Sleep -Seconds 10
    } while ($true)
    Print-Message "green" "CHECK 1/3: Service running"
    $passed++

    # CHECK 2: HTTP port responding
    Print-Message "blue" "CHECK 2/3: Waiting for port $COMFYUI_PORT to respond..."
    $attempt = 0
    do {
        try {
            Invoke-WebRequest -Uri "http://localhost:$COMFYUI_PORT" `
                -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            break
        } catch {
            $attempt++
            if ($attempt -ge $maxAttempts) {
                Die "FAIL CHECK 2: Port $COMFYUI_PORT not responding after $($maxAttempts * 10)s"
            }
            Print-Message "blue" "  Waiting for port $COMFYUI_PORT... attempt $attempt/$maxAttempts"
            Start-Sleep -Seconds 10
        }
    } while ($true)
    Print-Message "green" "CHECK 2/3: Port $COMFYUI_PORT responding"
    $passed++

    # CHECK 3: GPU visible via PyTorch
    Print-Message "blue" "CHECK 3/3: Verifying GPU via PyTorch..."
    $cudaCheck = & "$COMFYUI_DIR\.venv\Scripts\python.exe" -c @"
import torch, warnings
warnings.filterwarnings('ignore')
if torch.cuda.is_available():
    props = torch.cuda.get_device_properties(0)
    vram  = props.total_memory // (1024**3)
    print(f'CUDA OK -- {torch.cuda.get_device_name(0)} | VRAM: {vram}GB')
else:
    print('CUDA NOT AVAILABLE')
"@ 2>&1
    if ($cudaCheck -match "CUDA OK") {
        Print-Message "green" "CHECK 3/3: $cudaCheck"
        $passed++
    } else {
        Print-Message "yellow" "CHECK 3/3: GPU check inconclusive -- $cudaCheck"
    }

    $hostIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback" } |
        Select-Object -First 1).IPAddress

    Print-Message "green" "=== $passed/3 checks passed ==="
    Print-Message "green" "ComfyUI ready at: http://${hostIP}:$COMFYUI_PORT"
    Write-Host ""
    Print-Message "blue" "Useful commands:"
    Print-Message "blue" "  Service status:  Get-Service $SERVICE_NAME"
    Print-Message "blue" "  Stop service:    nssm stop $SERVICE_NAME"
    Print-Message "blue" "  Start service:   nssm start $SERVICE_NAME"
    Print-Message "blue" "  Restart service: nssm restart $SERVICE_NAME"
    Print-Message "blue" "  Logs:            $LOG_DIR\comfyui.log"
    Print-Message "blue" "  Data dir:        $COMFYUI_DIR"
}
