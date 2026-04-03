# Common Functions - Shared utilities for ComfyUI Windows 10 setup

$SENTINEL_DIR  = "C:\ProgramData\Illuma"
$LOG_DIR       = "C:\Logs\illuma"
$COMFYUI_DIR   = "C:\ComfyUI"
$COMFYUI_PORT  = if ($env:COMFYUI_PORT) { $env:COMFYUI_PORT } else { "8188" }
$SERVICE_NAME  = "comfyui"

function Print-Message {
    param(
        [string]$Color,
        [string]$Message
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Color) {
        "red"    { Write-Host "[$ts] [ERROR]   $Message" -ForegroundColor Red }
        "green"  { Write-Host "[$ts] [SUCCESS] $Message" -ForegroundColor Green }
        "yellow" { Write-Host "[$ts] [WARN]    $Message" -ForegroundColor Yellow }
        "blue"   { Write-Host "[$ts] [INFO]    $Message" -ForegroundColor Cyan }
        default  { Write-Host "[$ts] $Message" }
    }
}

function Setup-Logging {
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
    $logFile = Join-Path $LOG_DIR "comfyui-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $logFile -Append | Out-Null
    Print-Message "blue" "Log file: $logFile"
}

function Stop-Logging {
    try { Stop-Transcript | Out-Null } catch {}
}

function Check-DiskSpace {
    param([int]$RequiredGB = 30)
    # Get-CimInstance preferred over deprecated Get-WmiObject
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    if ($freeGB -lt $RequiredGB) {
        Die "Insufficient disk space -- Required: ${RequiredGB}GB, Available: ${freeGB}GB"
    }
    Print-Message "green" "Disk space: ${freeGB}GB available on C:"
}

function Check-SystemRequirements {
    param([int]$MinCores = 4, [int]$MinRamGB = 8)
    Print-Message "blue" "Checking system requirements..."

    $cs = Get-CimInstance Win32_ComputerSystem
    $cores = $cs.NumberOfLogicalProcessors
    if ($cores -lt $MinCores) {
        Print-Message "yellow" "Warning: $cores CPU cores found (min: $MinCores)"
    } else {
        Print-Message "green" "CPU cores: $cores"
    }

    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    if ($ramGB -lt $MinRamGB) {
        Die "Insufficient RAM -- ${ramGB}GB found, ${MinRamGB}GB required"
    }
    Print-Message "green" "RAM: ${ramGB}GB"

    Check-DiskSpace
}

function Test-Sentinel {
    param([string]$Name)
    return Test-Path (Join-Path $SENTINEL_DIR $Name)
}

function Set-Sentinel {
    param([string]$Name)
    if (-not (Test-Path $SENTINEL_DIR)) { New-Item -ItemType Directory -Path $SENTINEL_DIR -Force | Out-Null }
    Set-Content -Path (Join-Path $SENTINEL_DIR $Name) -Value (Get-Date -Format "o")
}

function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH    = "$machinePath;$userPath"
}

function Find-Python {
    foreach ($candidate in @(
        "C:\Program Files\Python313\python.exe",
        "C:\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "C:\Program Files\Python311\python.exe",
        "C:\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "C:\Program Files\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    return $null
}

function Die {
    param([string]$Message)
    Print-Message "red" $Message
    Stop-Logging
    exit 1
}
