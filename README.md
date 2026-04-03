# ComfyUI Node Provisioning

Idempotent, production-ready scripts for spinning up [ComfyUI](https://github.com/comfyanonymous/ComfyUI) on cloud GPU nodes. Covers both Linux and Windows. Safe to re-run — each phase checks state before acting.

---

## Platforms

| Platform | Approach | GPU | README |
|---|---|---|---|
| **Ubuntu 22.04** | Docker + systemd | NVIDIA (CUDA 12.1+, Blackwell-ready) | [ubuntu-22/README.md](ubuntu-22/README.md) |
| **Windows 10** | Native Python + NSSM service | NVIDIA (CUDA 12.6+) | [windows-10/README.md](windows-10/README.md) |

---

## What Each Script Does

Both platforms follow the same phase structure:

| Phase | Description |
|---|---|
| **Pre-flight** | OS check, CPU/RAM/disk/GPU validation |
| **System baseline** | Directories, logging, driver verification |
| **Runtime install** | Python + Git (Windows) or Docker (Ubuntu) |
| **ComfyUI install** | Clone repo, install PyTorch + dependencies |
| **Service** | Register as systemd (Ubuntu) or NSSM (Windows) service, auto-start on boot |
| **Validation** | Service running + port responding + GPU accessible via PyTorch |
| **Workflow test** | Download SD1.5 model, run 1-step txt2img, verify output image |
| **Remote access** | Parsec host + Reemo agent (optional, requires token) |

---

## Quick Start

### Ubuntu 22.04

```bash
# Copy scripts to the target machine
scp -r ubuntu-22/ root@<host>:/tmp/comfyui/

# SSH in and run as root
ssh root@<host> "bash /tmp/comfyui/install.sh"

# With remote access (Reemo + Parsec)
ssh root@<host> "REEMO_AGENT_TOKEN=<token> bash /tmp/comfyui/install.sh"
```

### Windows 10

```powershell
# Copy scripts to the target machine, then on the machine:
Set-ExecutionPolicy RemoteSigned -Scope Process -Force
cd C:\comfyui
.\install.ps1

# With remote access
$env:REEMO_AGENT_TOKEN = "<token>"
.\install.ps1
```

> For TensorDock or other providers where SCP/SFTP is blocked by an SSH banner, use the [paramiko upload helper](windows-10/README.md#file-transfer) documented in the Windows README.

---

## Configuration

All tunables are environment variables — no editing scripts. Key ones:

| Variable | Default | Used by |
|---|---|---|
| `COMFYUI_PORT` | `8188` | Both |
| `REEMO_AGENT_TOKEN` | *(required for remote access phase)* | Both |
| `PARSEC_TEAM_ID` | *(optional)* | Both |
| `PARSEC_TEAM_SECRET` | *(optional)* | Both |
| `COMFYUI_IMAGE` | `ghcr.io/ai-dock/comfyui:...` | Ubuntu only |
| `DATA_DIR` | `/data/comfyui` | Ubuntu only |

---

## Requirements

| | Ubuntu 22.04 | Windows 10 |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Windows 10 (Build 19041+) |
| Privileges | root | Administrator |
| GPU | NVIDIA (driver pre-installed) | NVIDIA (driver pre-installed) |
| CUDA | 12.1+ | 12.6+ |
| RAM | ≥ 8 GB | ≥ 8 GB |
| CPU | ≥ 4 cores | ≥ 4 cores |
| Disk | ≥ 30 GB free | ≥ 30 GB free on C: |

---

## Repo Structure

```
ubuntu-22/
  install.sh              <- entry point
  scripts/
    common.sh
    system-setup.sh
    docker-install.sh
    nvidia-toolkit.sh
    comfyui-service.sh
    validate.sh
    workflow-test.sh
    remote-access.sh
    add-packages.sh
  README.md

windows-10/
  install.ps1             <- entry point
  scripts/
    common.ps1
    system-setup.ps1
    python-install.ps1    <- parallel downloads (Python, Git, NSSM)
    comfyui-service.ps1   <- shallow clone, venv, PyTorch, NSSM service
    validate.ps1
    workflow-test.ps1
    remote-access.ps1
  README.md
```

---

## Idempotency

Every phase writes a sentinel file on success and checks it on the next run. Re-running after a partial failure resumes from where it stopped — no duplicate work.

| Sentinel location | Ubuntu | Windows |
|---|---|---|
| Base dir | `/var/lib/illuma/` | `C:\ProgramData\Illuma\` |

---

## After Install

ComfyUI is accessible at `http://<host-ip>:8188`.

The service starts automatically on reboot. See the platform-specific README for log locations, service management commands, and adding models.
