# Phase 3: Install Python 3.13, Git, and NSSM
# Downloads all three in parallel, then installs sequentially.

function Invoke-PythonInstall {
    if (Test-Sentinel ".python-install-done") {
        Print-Message "blue" "SKIP: Python/Git/NSSM already installed"
        return
    }

    # Force TLS 1.2 -- Windows PowerShell 5.1 defaults to TLS 1.0/1.1 which most
    # modern HTTPS servers (python.org, GitHub CDN) reject, causing silent hangs.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Print-Message "blue" "Downloading Python 3.13, Git, and NSSM in parallel..."
    _Download-All-Parallel

    Print-Message "blue" "Installing Python 3.13, Git, and NSSM..."
    _Install-Python
    _Install-Git
    _Install-Nssm

    Refresh-Path

    # Add Git to PATH if not picked up yet
    $gitPath = "C:\Program Files\Git\cmd"
    if ((Test-Path $gitPath) -and ($env:PATH -notlike "*$gitPath*")) {
        $env:PATH = "$env:PATH;$gitPath"
    }

    # Verify
    $pythonExe = Find-Python
    if (-not $pythonExe) { Die "Python not found after install -- PATH refresh failed" }
    $pyVersion = & $pythonExe --version 2>&1
    Print-Message "green" "Python: $pyVersion at $pythonExe"

    $gitVersion = & git --version 2>&1
    Print-Message "green" "Git: $gitVersion"

    $nssmPath = Get-Command nssm -ErrorAction SilentlyContinue
    if (-not $nssmPath) { $nssmPath = "C:\Windows\System32\nssm.exe" }
    if (Test-Path $nssmPath) {
        Print-Message "green" "NSSM: found at $nssmPath"
    } else {
        Die "NSSM not found after install"
    }

    Set-Sentinel ".python-install-done"
    Print-Message "green" "Python/Git/NSSM installation complete"
}

function _Download-All-Parallel {
    # Launch all three downloads simultaneously as background jobs
    $pythonInstaller = "$env:TEMP\python-3.13.3-amd64.exe"
    $gitInstaller    = "$env:TEMP\git-installer.exe"
    $nssmZip         = "$env:TEMP\nssm.zip"

    $jobs = @()

    # Python download
    if (-not (Test-Path $pythonInstaller)) {
        Print-Message "blue" "  Starting Python download..."
        $jobs += Start-Job -Name "dl-python" -ScriptBlock {
            param($dest)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.13.3/python-3.13.3-amd64.exe" `
                -OutFile $dest -UseBasicParsing -ErrorAction Stop
            "OK: python installer $('{0:N1}' -f ((Get-Item $dest).Length/1MB))MB"
        } -ArgumentList $pythonInstaller
    } else {
        Print-Message "blue" "  Python installer already cached"
    }

    # Git download (skip if cached >50MB)
    $gitSize = if (Test-Path $gitInstaller) { (Get-Item $gitInstaller).Length } else { 0 }
    if ($gitSize -lt 50MB) {
        Print-Message "blue" "  Starting Git download..."
        $jobs += Start-Job -Name "dl-git" -ScriptBlock {
            param($dest)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest `
                -Uri "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe" `
                -OutFile $dest -UseBasicParsing -ErrorAction Stop
            "OK: git installer $('{0:N1}' -f ((Get-Item $dest).Length/1MB))MB"
        } -ArgumentList $gitInstaller
    } else {
        Print-Message "blue" "  Git installer already cached ($([math]::Round($gitSize/1MB,1))MB)"
    }

    # NSSM download
    if (-not (Test-Path $nssmZip)) {
        Print-Message "blue" "  Starting NSSM download..."
        $jobs += Start-Job -Name "dl-nssm" -ScriptBlock {
            param($dest)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" `
                -OutFile $dest -UseBasicParsing -ErrorAction Stop
            "OK: nssm zip $('{0:N1}' -f ((Get-Item $dest).Length/1MB))MB"
        } -ArgumentList $nssmZip
    } else {
        Print-Message "blue" "  NSSM zip already cached"
    }

    if ($jobs.Count -eq 0) {
        Print-Message "blue" "  All installers already cached -- skipping downloads"
        return
    }

    Print-Message "blue" "  Waiting for $($jobs.Count) parallel download(s) (max 5 min)..."
    $jobs | Wait-Job -Timeout 300 | Out-Null

    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') {
            $result = Receive-Job $job 2>&1
            Print-Message "green" "  $result"
        } else {
            $err = Receive-Job $job 2>&1
            Print-Message "yellow" "  Download job '$($job.Name)' state=$($job.State): $err"
        }
        Remove-Job $job -Force
    }
}

function _Install-Python {
    $pythonExe = Find-Python
    if ($pythonExe) {
        $ver = & $pythonExe --version 2>&1
        Print-Message "blue" "Python already installed: $ver"
        return
    }

    $installer = "$env:TEMP\python-3.13.3-amd64.exe"
    if (-not (Test-Path $installer)) { Die "Python installer not found at $installer -- download failed" }

    Print-Message "blue" "Installing Python 3.13.3 (system-wide)..."
    $proc = Start-Process $installer `
        -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_doc=0" `
        -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Die "Python installer failed (exit: $($proc.ExitCode))" }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    Print-Message "green" "Python 3.13.3 installed"
}

function _Install-Git {
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($gitExe) {
        Print-Message "blue" "Git already installed: $(& git --version 2>&1)"
        return
    }
    if (Test-Path "C:\Program Files\Git\cmd\git.exe") {
        Print-Message "blue" "Git already installed (found in Program Files)"
        return
    }

    $installer = "$env:TEMP\git-installer.exe"
    if (-not (Test-Path $installer)) { Die "Git installer not found at $installer -- download failed" }

    Print-Message "blue" "Installing Git..."
    $proc = Start-Process $installer `
        -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh" `
        -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Die "Git installer failed (exit: $($proc.ExitCode))" }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    Print-Message "green" "Git 2.47.1 installed"
}

function _Install-Nssm {
    if ((Get-Command nssm -ErrorAction SilentlyContinue) -or (Test-Path "C:\Windows\System32\nssm.exe")) {
        Print-Message "blue" "NSSM already installed"
        return
    }
    Install-NssmManual
}

function Install-NssmManual {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $nssmZip  = "$env:TEMP\nssm.zip"
    $nssmDir  = "$env:TEMP\nssm-extract"
    $nssmDest = "C:\Windows\System32\nssm.exe"

    if (-not (Test-Path $nssmZip)) {
        Print-Message "blue" "Downloading NSSM 2.24..."
        Invoke-WebRequest `
            -Uri "https://nssm.cc/release/nssm-2.24.zip" `
            -OutFile $nssmZip `
            -UseBasicParsing `
            -ErrorAction Stop
    }

    Expand-Archive -Path $nssmZip -DestinationPath $nssmDir -Force

    # Find the 64-bit nssm.exe
    $nssmExe = Get-ChildItem -Path $nssmDir -Recurse -Filter "nssm.exe" |
        Where-Object { $_.FullName -match "win64" } | Select-Object -First 1
    if (-not $nssmExe) {
        $nssmExe = Get-ChildItem -Path $nssmDir -Recurse -Filter "nssm.exe" | Select-Object -First 1
    }
    if (-not $nssmExe) { Die "NSSM binary not found after extraction" }

    Copy-Item $nssmExe.FullName $nssmDest -Force
    Remove-Item $nssmZip, $nssmDir -Recurse -Force -ErrorAction SilentlyContinue
    Print-Message "green" "NSSM installed to $nssmDest"
}
