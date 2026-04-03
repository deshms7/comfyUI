# Phase 8: Remote Access Setup -- Parsec host + Reemo agent for Windows
#
# Required environment variable:
#   REEMO_AGENT_TOKEN   Personal Key or Studio Key from reemo.io/download
#
# Optional environment variables:
#   PARSEC_TEAM_ID      Parsec Teams ID
#   PARSEC_TEAM_SECRET  Parsec Teams secret

function Invoke-RemoteAccessSetup {
    if (Test-Sentinel ".remote-access-done") {
        Print-Message "blue" "SKIP: Remote access setup already installed"
        return
    }

    if (-not $env:REEMO_AGENT_TOKEN) {
        Die "REEMO_AGENT_TOKEN is not set.`nObtain your key from reemo.io/download and re-run with:`n  `$env:REEMO_AGENT_TOKEN='<key>'; .\install.ps1"
    }

    _Install-Parsec
    _Install-Reemo
    _Configure-Firewall

    Set-Sentinel ".remote-access-done"
    Print-Message "green" "Remote access setup complete -- Reemo and Parsec host are running"

    $hostIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback" } |
        Select-Object -First 1).IPAddress

    Write-Host ""
    Print-Message "blue" "=== Remote Access Summary ==="
    Print-Message "blue" "  Parsec:  log in at https://parsec.app -> Computers -> this machine"
    Print-Message "blue" "  Reemo:   open the Reemo dashboard -- this VM should appear as online"
    Print-Message "blue" "  Host IP: $hostIP"
}

function _Install-Parsec {
    Print-Message "blue" "Installing Parsec host (Windows)..."

    # Check if already installed
    $parsecPath = "C:\Program Files\Parsec\parsecd.exe"
    if (Test-Path $parsecPath) {
        Print-Message "blue" "Parsec already installed"
        return
    }

    # Download Parsec Windows installer
    $parsecInstaller = "$env:TEMP\parsec-windows.exe"
    Invoke-WebRequest `
        -Uri "https://builds.parsec.app/package/parsec-windows.exe" `
        -OutFile $parsecInstaller `
        -UseBasicParsing `
        -ErrorAction Stop

    # Silent install
    & $parsecInstaller /silent /norestart 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    Remove-Item $parsecInstaller -Force -ErrorAction SilentlyContinue

    # Write Parsec config for headless hosting
    $parsecConfigDir = "$env:APPDATA\Parsec"
    New-Item -ItemType Directory -Path $parsecConfigDir -Force | Out-Null

    $teamBlock = ""
    if ($env:PARSEC_TEAM_ID -and $env:PARSEC_TEAM_SECRET) {
        $teamBlock = "`"app_host_team_id`": `"$env:PARSEC_TEAM_ID`",`n    `"app_host_team_secret`": `"$env:PARSEC_TEAM_SECRET`","
    }

    Set-Content -Path "$parsecConfigDir\config.json" -Value @"
{
    "encoder_h265": 1,
    "host_virtual_monitors": 1,
    "host_privacy_mode": 0,
    $teamBlock
    "app_first_run": 0
}
"@

    # Start Parsec (it registers itself in startup)
    if (Test-Path $parsecPath) {
        Start-Process $parsecPath -ArgumentList "app_daemon=1" -WindowStyle Hidden
        Print-Message "green" "Parsec host installed and started"
    } else {
        Print-Message "yellow" "Parsec installer ran but binary not found -- may need manual login"
    }
}

function _Install-Reemo {
    Print-Message "blue" "Installing Reemo agent (Windows)..."

    # Download Reemo Windows installer
    $reemoInstaller = "$env:TEMP\ReemoSetup.exe"
    Invoke-WebRequest `
        -Uri "https://download.reemo.io/windows/setup.exe" `
        -OutFile $reemoInstaller `
        -UseBasicParsing `
        -ErrorAction Stop

    $keyPrefix = $env:REEMO_AGENT_TOKEN.Substring(0, [Math]::Min(8, $env:REEMO_AGENT_TOKEN.Length))
    Print-Message "blue" "Registering Reemo agent (key: ${keyPrefix}...)"

    # Silent install with key registration
    & $reemoInstaller /silent /key=$env:REEMO_AGENT_TOKEN 2>&1 | Out-Null
    Start-Sleep -Seconds 10
    Remove-Item $reemoInstaller -Force -ErrorAction SilentlyContinue

    Print-Message "green" "Reemo agent installed and registered"
}

function _Configure-Firewall {
    Print-Message "blue" "Configuring Windows Firewall..."

    # ComfyUI web UI
    New-NetFirewallRule -DisplayName "ComfyUI" `
        -Direction Inbound -Protocol TCP -LocalPort $COMFYUI_PORT `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null

    # Parsec streaming (UDP 8000)
    New-NetFirewallRule -DisplayName "Parsec Streaming" `
        -Direction Inbound -Protocol UDP -LocalPort 8000 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null

    # Reemo STUN/TURN
    New-NetFirewallRule -DisplayName "Reemo STUN UDP" `
        -Direction Inbound -Protocol UDP -LocalPort 3478 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Reemo STUN TCP" `
        -Direction Inbound -Protocol TCP -LocalPort 3478 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Reemo TURN TLS" `
        -Direction Inbound -Protocol TCP -LocalPort 5349 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null

    Print-Message "green" "Firewall rules configured"
    Print-Message "blue" "Active ComfyUI rule:"
    Get-NetFirewallRule -DisplayName "ComfyUI" -ErrorAction SilentlyContinue |
        Format-Table DisplayName, Enabled, Direction, Action -AutoSize | Out-Host
}
