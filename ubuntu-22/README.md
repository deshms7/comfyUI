# ComfyUI — Ubuntu 22.04 Provisioning Script

Provisions a fresh Ubuntu 22.04 machine to run the latest [ComfyUI](https://github.com/comfyanonymous/ComfyUI) Docker image with GPU support, managed as a systemd service. Safe to re-run (idempotent). Produces a ready instance at `http://<host>:8188`.

---

## Pre-conditions

The machine must already have:

| Requirement | Detail |
|---|---|
| OS | Ubuntu 22.04 LTS |
| NVIDIA driver | `nvidia-driver-590-open` or newer (open kernel modules required for Blackwell GPUs) |
| Internet access | To pull Docker image and apt packages |
| Root access | Script must run as root |
| Disk | ≥ 30 GB free |
| CPU / RAM | ≥ 4 cores, ≥ 8 GB RAM |

> **Blackwell GPUs (RTX 5000 series / sm_120):** Requires open kernel modules (`nvidia-driver-*-open`) and `NVreg_EnableGpuFirmware=0`. The script detects and applies this automatically.

> **Phase 8 — Remote access client setup:** Requires `REEMO_AGENT_TOKEN` (Personal Key or Studio Key from reemo.io/download). Parsec Teams credentials (`PARSEC_TEAM_ID` / `PARSEC_TEAM_SECRET`) are optional.

---

## Quick Start

```bash
# Copy scripts to the machine
scp -r node-setup/comfyui root@<host>:/tmp/

# SSH in and run
ssh root@<host> "bash /tmp/comfyui/ubuntu-22/install.sh"
```

One-liner alternative:

```bash
ssh root@<host> "bash -s" < node-setup/comfyui/ubuntu-22/install.sh
```

---

## Configuration

All tunables are environment variables. Pass them with `sudo -E` or prefix the command:

| Variable | Default | Description |
|---|---|---|
| `COMFYUI_IMAGE` | `ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04` | Docker image to pull and run |
| `COMFYUI_PORT` | `8188` | Host port to expose ComfyUI on |
| `DATA_DIR` | `/data/comfyui` | Root path for persistent volumes |
| `POLL_MAX_ATTEMPTS` | `30` | Max poll attempts in validation (×10s = 300s) |
| `POLL_SLEEP_SEC` | `10` | Seconds between poll attempts |
| `WEB_USER` | `illuma` | ComfyUI UI login username (fixed across restarts) |
| `WEB_PASSWORD` | `illuma` | ComfyUI UI login password (fixed across restarts) |
| `WEB_TOKEN` | `illumaCloud` | ComfyUI token for direct URL access (fixed across restarts) |
| `REEMO_AGENT_TOKEN` | *(required for Phase 8)* | Reemo Personal Key or Studio Key — from reemo.io/download |
| `PARSEC_TEAM_ID` | *(optional)* | Parsec Teams ID — for managed host registration |
| `PARSEC_TEAM_SECRET` | *(optional)* | Parsec Teams secret (paired with `PARSEC_TEAM_ID`) |
| `REEMO_AGENT_VERSION` | latest | Pin a specific Reemo agent version |
| `REMOTE_ACCESS_USER` | `comfyui` | OS user that owns the desktop session |

Examples:

```bash
# Full install with remote access
REEMO_AGENT_TOKEN=<token> sudo -E bash install.sh

# With Parsec Teams managed host
REEMO_AGENT_TOKEN=<token> PARSEC_TEAM_ID=<id> PARSEC_TEAM_SECRET=<secret> sudo -E bash install.sh

# Custom port
COMFYUI_PORT=8080 sudo -E bash install.sh

# Pin to a specific image digest (recommended for production)
COMFYUI_IMAGE="ghcr.io/ai-dock/comfyui@sha256:<digest>" sudo -E bash install.sh
```

---

## What the Script Does

Six sequential, idempotent phases. Each phase checks state before acting — safe to re-run after partial failure.

### Phase 1 — Pre-flight Checks
- Confirms Ubuntu 22.04
- Confirms running as root
- Checks disk space (≥ 30 GB), CPU (≥ 4 cores), RAM (≥ 8 GB)
- Confirms NVIDIA GPU present via `lspci`

### Phase 2 — System Baseline
- Installs base packages: `ca-certificates curl gnupg lsb-release jq wget unzip pciutils`
- Tunes sysctl: `vm.max_map_count=262144`, `fs.file-max=100000`
- Sets open file limits: 65536
- Creates `comfyui` system user
- Sentinel: `/var/lib/illuma/.system-baseline-done`

### Phase 3 — Docker CE
- Adds Docker's official GPG key and apt repository
- Installs `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`
- Enables and starts the Docker daemon
- Verifies binaries with missing-count check
- Skip condition: `docker info` succeeds (Docker already running)

### Phase 4 — NVIDIA Container Toolkit
- Detects Blackwell GPUs and applies `NVreg_EnableGpuFirmware=0` fix if needed
- Adds NVIDIA container toolkit apt repository
- Installs `nvidia-container-toolkit`
- Configures Docker NVIDIA runtime via `nvidia-ctk`
- Runs a GPU smoke test inside Docker (`nvidia-smi` inside `nvidia/cuda` container)
- Sentinel: `/var/lib/illuma/.nvidia-toolkit-done`

### Phase 4b — PyTorch GPU Compatibility
- Waits for the ComfyUI container to accept `docker exec` commands
- Checks if the bundled PyTorch supports the host GPU's compute capability (via `torch.cuda.get_arch_list()`)
- If incompatible (e.g. RTX 5090 / sm_120 needs cu128): upgrades PyTorch to `2.11.0+cu128`
- Restarts ComfyUI via `supervisorctl restart comfyui` inside the container
- Sentinel: `/var/lib/illuma/.pytorch-cu128-done`

### Phase 5 — ComfyUI Container + Systemd Service
- Creates volume directories at `$DATA_DIR/{models,outputs,custom_nodes,logs}`
- Sets ownership to `uid=1000:gid=1111` (ai-dock image's container user)
- Pulls the ComfyUI Docker image; logs image digest for auditability
- Writes `/etc/systemd/system/comfyui.service` (Restart=always, journald logging, `--gpus all`, `--shm-size=2g`)
- Enables and starts the service

### Phase 6 — Validation
Three checks with polling (30 attempts × 10s = 5 min timeout each):
1. Container running (`docker ps --filter status=running`)
2. Port 8188 responding (`curl -sf http://localhost:8188`)
3. GPU visible inside container (`docker exec comfyui nvidia-smi`)

### Phase 8 — Remote Access Client Setup (Reemo + Parsec)
Installs a full GPU-accelerated remote desktop stack so the VM can be accessed visually.

1. **Desktop environment** — installs XFCE + LightDM; configures auto-login as the `comfyui` user so a desktop session is always running
2. **NVIDIA virtual display** — writes `/etc/X11/xorg.conf.d/20-nvidia-headless.conf`; auto-detects the GPU PCI BusID and configures a 1920×1080 virtual framebuffer driven by the NVIDIA GPU (no physical monitor needed)
3. **Parsec host** — downloads and installs `parsec-linux.deb`; writes `~/.parsec/config.json` (H.265, virtual monitors enabled); registers as a user-space systemd service (`parsec.service`) that starts inside the XFCE session; optionally registers with Parsec Teams if `PARSEC_TEAM_ID` / `PARSEC_TEAM_SECRET` are set
4. **Reemo agent** — downloads and installs the Reemo `.deb`; registers the machine with `reemo-agent register --token $REEMO_AGENT_TOKEN`; enables the `reemo-agent.service` system daemon
5. **Firewall (ufw)** — enables ufw and opens: SSH (22/tcp), ComfyUI (8188/tcp), Parsec streaming (8000/udp), Reemo STUN/TURN (3478 udp+tcp, 5349/tcp)
6. **Service enablement** — starts and enables LightDM, reemo-agent, and the per-user Parsec service

Sentinel: `/var/lib/illuma/.remote-access-done` — skipped on re-runs once passed.

> **Required:** `REEMO_AGENT_TOKEN` must be set or Phase 8 fails immediately with a clear error message.

---

### Phase 9 — Add My Packages
Installs additional host packages and places the user guide on the desktop.

| Package | Method |
|---|---|
| **Google Chrome** (stable) | Official Google apt repository |
| **IllumaComfyUI.html** | Copied to `~/Desktop/` of `REMOTE_ACCESS_USER` |

Steps:
1. Adds Google's signing key via `apt-key add`
2. Writes `/etc/apt/sources.list.d/google-chrome.list`
3. Runs `apt-get update` + installs `google-chrome-stable`
4. Validates: confirms binary is on PATH and `google-chrome-stable --version` returns output
5. Copies `IllumaComfyUI.html` to `/home/<REMOTE_ACCESS_USER>/Desktop/`

Sentinel: `/var/lib/illuma/.add-packages-done` — skipped on re-runs once passed.

---

### Phase 7 — Workflow Test
End-to-end inference smoke test. Verifies the full pipeline: model load → GPU inference → image output.

1. **Download test model** — fetches `v1-5-pruned-emaonly.safetensors` (~4 GB) from HuggingFace into `/data/comfyui/models/checkpoints/` if not already present
2. **Submit workflow** — posts a minimal txt2img prompt (1 step, 64×64, seed 42) to the ComfyUI internal API (`localhost:18188` inside the container, bypassing the Caddy auth proxy on port 8188)
3. **Verify output** — polls `/history/<prompt_id>` for up to 10 minutes; confirms a `workflow-test*.png` image was written to `/data/comfyui/outputs/`

Sentinel: `/var/lib/illuma/.workflow-test-done` — skipped on re-runs once passed.

---

## Volume Layout

Models and outputs persist outside the container. Survives image updates and container restarts.

```
/data/comfyui/
  models/       → /opt/ComfyUI/models       (place checkpoint .safetensors files here)
  outputs/      → /opt/ComfyUI/output        (generated images land here)
  custom_nodes/ → /opt/ComfyUI/custom_nodes  (custom node extensions)
  logs/         → container log output
```

### Adding Models

```bash
# Download a model directly to the volume (no container restart needed for new files;
# ComfyUI rescans on next generation request or after supervisorctl restart comfyui)
wget -O /data/comfyui/models/checkpoints/v1-5-pruned-emaonly.safetensors \
  https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors

# If ComfyUI doesn't pick it up immediately, refresh inside the container:
docker exec comfyui supervisorctl restart comfyui
```

---

## Accessing ComfyUI

Open in browser (from the VM via Reemo, or from any machine with network access):

```
http://<host>:8188/?token=illumaCloud
```

Or use the login screen:

| Field | Value |
|---|---|
| Username | `illuma` |
| Password | `illuma` |
| Token URL | `http://<host>:8188/?token=illumaCloud` |

These credentials are static — they do not change on container or VM restart.
To override them, pass environment variables at install time:
```bash
WEB_PASSWORD=mypassword WEB_TOKEN=mytoken sudo -E bash install.sh
```

---

## Post-Install Operations

```bash
# View live service logs
journalctl -u comfyui -f

# Check service status
systemctl status comfyui

# Stop / start / restart
systemctl stop comfyui
systemctl start comfyui
systemctl restart comfyui

# Container status
docker ps --filter name=comfyui

# Container logs (last 50 lines)
docker logs comfyui --tail 50

# Open a shell inside the running container
docker exec -it comfyui bash

# Restart ComfyUI process without restarting the whole container
docker exec comfyui supervisorctl restart comfyui

# Check GPU inside container
docker exec comfyui nvidia-smi
```

---

## File Structure

```
install.sh                  ← main orchestrator; run this
scripts/
  common.sh                 ← shared utilities: print_message, die, setup_logging,
                               check_disk_space, check_system_requirements
  system-setup.sh           ← Phase 2: setupSystem()
  docker-install.sh         ← Phase 3: installDocker()
  nvidia-toolkit.sh         ← Phase 4: installNvidiaToolkit(), configureDockerNvidiaRuntime(),
                                        _apply_blackwell_fix_if_needed()
  comfyui-service.sh        ← Phase 5: setupComfyUI(), writeSystemdService(),
                                        upgradeContainerPyTorch()
  validate.sh               ← Phase 6: validateComfyUI()
  workflow-test.sh          ← Phase 7: runWorkflowTest(), _downloadTestModel(),
                                        _submitWorkflow(), _verifyOutput()
  remote-access.sh          ← Phase 8: installRemoteAccess(), _installDesktop(),
                                        _configureNvidiaVirtualDisplay(), _installParsec(),
                                        _installReemo(), _configureFirewall(),
                                        _enableRemoteAccessServices()
  add-packages.sh           ← Phase 9: addPackages(), _installChrome(), _validateChrome(),
                                        _placeGuideOnDesktop()
  IllumaComfyUI.html        ← User guide placed on desktop by Phase 9
```

---

## Idempotency

Every install phase checks state before acting:

| Phase | Guard |
|---|---|
| System baseline | Sentinel file `/var/lib/illuma/.system-baseline-done` |
| Docker | `docker info` succeeds |
| NVIDIA toolkit | Sentinel file `/var/lib/illuma/.nvidia-toolkit-done` |
| PyTorch upgrade | Sentinel file `/var/lib/illuma/.pytorch-cu128-done` |
| Volume dirs | `mkdir -p` (no-op if exists) |
| Systemd unit | Always written (idempotent); `enable`/`start` are no-ops if already active |
| Workflow test | Sentinel file `/var/lib/illuma/.workflow-test-done` |
| Remote access | Sentinel file `/var/lib/illuma/.remote-access-done` |
| Add my packages | Sentinel file `/var/lib/illuma/.add-packages-done` |

Re-running the script after a partial failure skips completed phases and resumes from where it stopped.

---

## Logs

Install logs: `/var/log/illuma/comfyui-setup-<timestamp>.log`

Service logs: `journalctl -u comfyui -f`

---

## Known Hardware Notes

### NVIDIA Blackwell (RTX 5000 series, sm_120)

The 590 driver package does not ship GSP firmware for Blackwell (`gsp_gb10x.bin`). The script automatically:
1. Detects missing firmware in `/usr/lib/firmware/nvidia/<ver>/`
2. Writes `options nvidia NVreg_EnableGpuFirmware=0` to `/etc/modprobe.d/nvidia-blackwell.conf`
3. Runs `update-initramfs` and reloads the kernel module

Requires open kernel modules. Install before running this script:
```bash
sudo apt-get install -y nvidia-driver-590-open
sudo reboot
```

### PyTorch + Blackwell

PyTorch cu121/cu126 supports up to sm_90 (Hopper). Blackwell (sm_120) requires cu128 (PyTorch 2.11.0+). Phase 4b detects and upgrades automatically.

---

## Remote Access Client Setup (Phase 8)

After install, connect to the VM using either client:

| Client | How to connect |
|---|---|
| **Parsec** | Log in at parsec.app → Computers → the machine appears automatically |
| **Reemo** | Open the Reemo dashboard → Devices → the machine appears as online |

```bash
# LightDM (display manager / XFCE session)
systemctl status lightdm
systemctl restart lightdm

# Reemo agent
systemctl status reemod
systemctl restart reemod
journalctl -u reemod -f

# Parsec (runs as user-space service inside the desktop session)
sudo -u comfyui systemctl --user status parsec
sudo -u comfyui systemctl --user restart parsec

# Firewall
ufw status verbose
ufw allow <port>/tcp     # open an additional port if needed
ufw deny  <port>/tcp     # close a port

# Virtual display — check Xorg is running on the GPU
systemctl status display-manager
ps aux | grep Xorg
```

---

## What Is NOT in This Script

- NVIDIA driver install — assumed present on provider base image
- Model download — place files in `/data/comfyui/models/checkpoints/` manually or via your pipeline
- TLS / reverse proxy — add nginx or Caddy in front for production
- Firewall rules — handled at provider/network level
- SSH key management — handled by the provisioning layer above this script
