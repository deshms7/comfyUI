# ComfyUI — Windows 10 Provisioning Script

Provisions a fresh Windows 10 machine to run the latest [ComfyUI](https://github.com/comfyanonymous/ComfyUI) natively (no Docker), managed as a Windows service via [NSSM](https://nssm.cc/). Safe to re-run (idempotent). Produces a ready instance at `http://<host>:8188`.

---

## Pre-conditions

The machine must already have:

| Requirement | Detail |
|---|---|
| OS | Windows 10 (Build 19041+) |
| NVIDIA driver | 560+ with CUDA 12.6 support |
| Internet access | To download Python, Git, PyTorch, ComfyUI |
| Administrator | Script must run as Administrator |
| Disk | ≥ 30 GB free on C: |
| CPU / RAM | ≥ 4 cores, ≥ 8 GB RAM |

> **Phase 8 — Remote access:** Requires `REEMO_AGENT_TOKEN` (Personal Key or Studio Key from reemo.io/download). Parsec Teams credentials (`PARSEC_TEAM_ID` / `PARSEC_TEAM_SECRET`) are optional.

---

## Quick Start

**Option A — Copy scripts then run:**
```powershell
# On the Windows machine, open PowerShell as Administrator:
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
cd C:\illuma\comfyui
.\install.ps1
```

**Option B — Transfer via SSH then run:**
```bash
# From Linux (use paramiko -- TensorDock SSH banner blocks scp/sftp):
python3 upload_scripts.py  # base64-encode and exec via paramiko
```

---

## Configuration

All tunables are environment variables. Set them before running `install.ps1`:

| Variable | Default | Description |
|---|---|---|
| `COMFYUI_PORT` | `8188` | Port ComfyUI listens on |
| `REEMO_AGENT_TOKEN` | *(required for Phase 8)* | Reemo Personal Key or Studio Key |
| `PARSEC_TEAM_ID` | *(optional)* | Parsec Teams ID |
| `PARSEC_TEAM_SECRET` | *(optional)* | Parsec Teams secret |

Examples:
```powershell
# Full install with remote access
$env:REEMO_AGENT_TOKEN = "<key>"
.\install.ps1

# Custom port
$env:COMFYUI_PORT = "8080"
.\install.ps1
```

---

## What the Script Does

Eight sequential, idempotent phases. Each phase checks a sentinel file before acting — safe to re-run after partial failure.

### Phase 2 — System Baseline
- Creates directory structure: `C:\ComfyUI\models\{checkpoints,vae,loras}`, `C:\ComfyUI\output`, `C:\ComfyUI\custom_nodes`
- Creates log and sentinel directories: `C:\Logs\illuma`, `C:\ProgramData\Illuma`
- Verifies NVIDIA driver present (`nvidia-smi`)
- Sentinel: `C:\ProgramData\Illuma\.system-baseline-done`

### Phase 3 — Python + Git + NSSM
- **Downloads all three installers in parallel** (Python 3.11.9, MinGit 2.47.1, NSSM 2.24) using `Start-Job`
- Installs Python 3.11.9 system-wide with `PrependPath=1`
- Installs MinGit (zip extract to `C:\MinGit` — no installer, no hanging)
- Extracts NSSM 2.24 64-bit binary to `C:\Windows\System32\nssm.exe`
- Sentinel: `C:\ProgramData\Illuma\.python-install-done`

> **Why MinGit instead of full Git?** The full Git for Windows installer (~80 MB) hangs silently on fresh Windows images for 5+ minutes. MinGit is a 45 MB zip with no installer — extract and use immediately.

### Phase 4 — Clone ComfyUI + Install Dependencies
- Shallow clones ComfyUI (`--depth 1`) from GitHub to `C:\ComfyUI` (~faster than full clone)
- Creates Python venv at `C:\ComfyUI\.venv`
- Installs PyTorch cu126 from `https://download.pytorch.org/whl/cu126`
- Installs ComfyUI `requirements.txt`
- Sentinel: `C:\ProgramData\Illuma\.comfyui-install-done`

### Phase 5 — Register Windows Service
- Registers `comfyui` service via NSSM
- Runs: `C:\ComfyUI\.venv\Scripts\python.exe main.py --listen 0.0.0.0 --port 8188`
- Logs: `C:\Logs\illuma\comfyui.log` and `comfyui-error.log` (10 MB rotation)
- Auto-start on boot, restart on failure

### Phase 6 — Validation
Three checks with polling (30 attempts × 10s = 5 min timeout each):
1. Service running (`Get-Service comfyui`)
2. Port 8188 responding (`Invoke-WebRequest http://localhost:8188`)
3. GPU visible via PyTorch (`torch.cuda.is_available()` + `get_device_name(0)`)

### Phase 7 — Workflow Test
End-to-end inference smoke test:
1. Downloads `v1-5-pruned-emaonly.safetensors` (~4 GB) via BITS Transfer (falls back to `Invoke-WebRequest`)
2. Submits a minimal txt2img workflow: 1 step, 64×64, seed 42
3. Polls `/history/<prompt_id>` until complete (max 10 min)
4. Verifies `C:\ComfyUI\output\workflow-test*.png` was created
- Sentinel: `C:\ProgramData\Illuma\.workflow-test-done`

### Phase 8 — Remote Access (optional)
- **Parsec:** Downloads and installs Parsec host; writes `%APPDATA%\Parsec\config.json` (H.265, virtual monitors)
- **Reemo:** Downloads and installs Reemo agent; registers with `REEMO_AGENT_TOKEN`
- **Firewall:** Opens inbound rules for ComfyUI (TCP 8188), Parsec (UDP 8000), Reemo STUN/TURN (3478/5349)
- Sentinel: `C:\ProgramData\Illuma\.remote-access-done`

---

## Accessing ComfyUI

```
http://<host-ip>:8188
```

The service starts automatically on boot. There is no login screen by default — access is IP-restricted at the network/firewall level.

---

## Post-Install Operations

```powershell
# Service status
Get-Service comfyui

# Stop / start / restart
nssm stop comfyui
nssm start comfyui
nssm restart comfyui

# View live logs
Get-Content C:\Logs\illuma\comfyui.log -Wait -Tail 50

# View error log
Get-Content C:\Logs\illuma\comfyui-error.log -Tail 50

# Check GPU
nvidia-smi

# Verify PyTorch CUDA
C:\ComfyUI\.venv\Scripts\python.exe -c "import torch; print(torch.cuda.get_device_name(0))"
```

---

## Adding Models

```powershell
# Download a model to the checkpoints directory
Invoke-WebRequest -Uri "<huggingface-url>" `
    -OutFile "C:\ComfyUI\models\checkpoints\model.safetensors" `
    -UseBasicParsing

# ComfyUI rescans on next request -- no restart needed
```

---

## File Structure

```
install.ps1                     <- main orchestrator; run this
scripts/
  common.ps1                    <- Print-Message, Die, Setup-Logging, Test/Set-Sentinel,
                                   Refresh-Path, Find-Python, Check-SystemRequirements
  system-setup.ps1              <- Phase 2: Invoke-SystemSetup
  python-install.ps1            <- Phase 3: Invoke-PythonInstall, _Download-All-Parallel,
                                   _Install-Python, _Install-Git, _Install-Nssm
  comfyui-service.ps1           <- Phase 4+5: Invoke-ComfyUISetup, _Clone-ComfyUI,
                                   _Create-Venv, _Install-Dependencies, _Register-Service
  validate.ps1                  <- Phase 6: Invoke-Validate
  workflow-test.ps1             <- Phase 7: Invoke-WorkflowTest
  remote-access.ps1             <- Phase 8: Invoke-RemoteAccessSetup, _Install-Parsec,
                                   _Install-Reemo, _Configure-Firewall
```

---

## Idempotency

Every phase checks state before acting:

| Phase | Guard |
|---|---|
| System baseline | `C:\ProgramData\Illuma\.system-baseline-done` |
| Python/Git/NSSM | `C:\ProgramData\Illuma\.python-install-done` |
| ComfyUI install | `C:\ProgramData\Illuma\.comfyui-install-done` |
| Workflow test | `C:\ProgramData\Illuma\.workflow-test-done` |
| Remote access | `C:\ProgramData\Illuma\.remote-access-done` |

Re-running after a partial failure skips completed phases and resumes from where it stopped.

---

## Logs

Install transcript: `C:\Logs\illuma\comfyui-setup-<timestamp>.log`

Service stdout: `C:\Logs\illuma\comfyui.log`

Service stderr: `C:\Logs\illuma\comfyui-error.log`

---

## Known Issues and Fixes

### Git Installer Hangs on Fresh Windows Images
The full Git for Windows installer (`Git-2.47.1-64-bit.exe`) hangs silently for 5+ minutes on TensorDock Windows images. Fixed by using **MinGit** — a minimal zip distribution with no installer required.

### `ErrorActionPreference=Stop` + git stderr
PowerShell 5.1 treats native command stderr output as a terminating error when `ErrorActionPreference=Stop`. Git writes progress messages to stderr (`Cloning into...`, `Receiving objects...`). Fixed by temporarily setting `$ErrorActionPreference = "Continue"` around git calls and checking `$LASTEXITCODE` manually.

### winget Source Cache Corruption
Fresh TensorDock Windows images have a corrupted winget SQLite source cache. Fixed by switching to direct downloads from authoritative sources (python.org, GitHub releases, nssm.cc) instead of winget.

### TensorDock SSH Banner Blocks SCP/SFTP
TensorDock prepends a banner to every SSH connection that breaks `scp` and `sftp`. Fixed by using paramiko `exec_command` with base64-encoded content and PowerShell `-EncodedCommand` (UTF-16LE) for all file transfers.

---

## What Is NOT in This Script

- NVIDIA driver install — assumed present on provider base image
- Model downloads beyond the workflow test model — place files in `C:\ComfyUI\models\checkpoints\` manually
- TLS / reverse proxy — add nginx or Caddy in front for production
- Windows Firewall inbound rules beyond Phase 8 — handled at provider/network level
