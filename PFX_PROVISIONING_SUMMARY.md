# PFX + Illuma Cloud — VM Provisioning Status Report
**VM:** `104.255.9.187:16015` (SSH: `user` / `Sushil@illuma99`) | GPU: NVIDIA RTX A6000 48GB  
**Client:** Dennis Engler (IT) + Jonas Englich (AI TD) @ PFX  
**Email date:** Apr 2, 2026 | **Last SSH check:** Apr 11, 2026

---

## ✅ DONE — Confirmed via Live SSH

| Item | Status |
|---|---|
| OS | Windows 10 ✅ |
| Python installed | ✅ (sentinel `.python-install-done`) |
| ComfyUI installed | ✅ (sentinel `.comfyui-install-done`) |
| Custom nodes installed (38 total) | ✅ (sentinel `.custom-nodes-done`) |
| ComfyUI **service running** | ✅ `STATE: 4 RUNNING` |
| System baseline done | ✅ (sentinel `.system-baseline-done`) |
| Models on VM (~90 GB) | ✅ flux1-dev-fp8, Wan2.1-T2V-1.3B, Wan2.2-I2V-A14B HIGH+LOW, clips, vaes, loras, upscalers |

### Custom Nodes Confirmed Installed (38 nodes — all from PFX snapshot ✅)
`comfy-image-saver`, `ComfyLiterals`, `ComfyMath`, `comfyui-corridorkey`, `ComfyUI-Crystools`, `ComfyUI-Custom-Scripts`, `ComfyUI-Deep-Exemplar-based-Video-Colorization`, `ComfyUI-DepthAnythingV2`, `ComfyUI-Desert-Pixel-Nodes`, `ComfyUI-Easy-Use`, `ComfyUI-Florence2`, `ComfyUI-Frame-Interpolation`, `ComfyUI-Gaffer`, `ComfyUI-GGUF`, `ComfyUI-IC-Light`, `ComfyUI-IC-Light-native`, `ComfyUI-Image-Filters`, `ComfyUI-Inpaint-CropAndStitch`, `ComfyUI-KJNodes`, `ComfyUI-Manager`, `ComfyUI-MelBandRoFormer`, `ComfyUI-MultiGPU`, `ComfyUI-QwenVL`, `ComfyUI-SAM3`, `ComfyUI-SeedVR2_VideoUpscaler`, `comfyui-tensorops`, `ComfyUI-TiledDiffusion`, `comfyui-various`, `ComfyUI-VideoHelperSuite`, `comfyui-yaser-nodes`, `ComfyUI_essentials`, `ComfyUI_SVFR`, `ComfyUI_UltimateSDUpscale`, `eden_comfy_pipelines`, `Image-Captioning-in-ComfyUI`, `masquerade-nodes-comfyui`, `RES4LYF`, `rgthree-comfy`

---

## 🔴 PENDING — Critical / Blocking

### 1. Reemo Remote Access — NOT INSTALLED ❌
**Confirmed via SSH:** `sc query ReemoAgentService` → service does not exist.

> Client (Dennis) explicitly requested Reemo and provided the Studio Key:  
> **`studio_fa413ff7044b`**  
> Download: https://reemo.io/download/

**Fix — run on VM:**
```powershell
$env:REEMO_AGENT_TOKEN = "studio_fa413ff7044b"
# Run remote-access phase of install.ps1:
C:\illuma\comfyui\install.ps1
# OR directly:
C:\illuma\comfyui\scripts\remote-access.ps1
```

---

### 2. NVIDIA Driver / nvidia-smi NOT WORKING ⚠️
**Confirmed via SSH:** `nvidia-smi` returns:
> "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running. This can also be happening if non-NVIDIA GPU is running as primary display, and NVIDIA GPU is in WDDM mode."

GPU is visible in TensorDock banner (RTX A6000) but nvidia-smi can't talk to it.  
This means **ComfyUI is likely running on CPU only — no GPU inference!**

**Possible causes:**
- Driver not installed / incompatible version
- GPU in WDDM mode (needs TCC mode for headless/SSH usage)
- Display driver needs reinstall from inside a desktop session

**Fix options:**
1. Log into VM via desktop (RDP/Reemo) and reinstall NVIDIA driver
2. Or via SSH as Administrator:
```powershell
# Check current driver
Get-WmiObject Win32_VideoController | Select-Object Name, DriverVersion
# Switch to TCC mode (headless):
nvidia-smi -dm 1  # requires admin, may need reboot
```

> **This is the most critical issue — fix before handing off to PFX.**

---

### 3. Port 8188 Not Responding on SSH Check ⚠️
`netstat` returned empty for 8188 — service is marked RUNNING but may not be binding to port yet (could be still starting up at time of check, or startup is failing silently due to GPU issue).

**Verify:**
```powershell
# Check if port is actually listening
netstat -an | Select-String "8188"
# Check service logs
Get-Content C:\Logs\illuma\comfyui.log -Tail 50
Get-Content C:\Logs\illuma\comfyui-error.log -Tail 50
```

---

### 4. VPN / Network Drive — WAITING ON CLIENT 🕐
**Client request:** Mount `\\10.0.55.16\PROJECT` via VPN  
**Dennis said:** *"I'll do this myself once new Fortigate + new internet is ready"*

**Action:** Follow up with Dennis on VPN ETA — nothing to do on our end yet.

---

## 🟡 PENDING — Models Gap (Needs Jonas Confirmation)

PFX's full model library = **644 GB**. Dennis said to only add the essentials.  
Our VM has ~90 GB. Key PFX models **we don't have**:

### High-priority (likely needed for Wan2.x workflows):
| Model | Size | Location |
|---|---|---|
| `wan2.2_animate_14B_bf16.safetensors` | ~32 GB | diffusion_models |
| `flux1-fill-dev.safetensors` | ~22 GB | diffusion_models |
| `VACE-Wan2.1-1.3B-Preview.safetensors` | ~6.7 GB | diffusion_models |
| `wan2.1_vace_1.3B_fp16.safetensors` | ~4.1 GB | diffusion_models |

### Checkpoints (if they want to run SD1.5/SDXL workflows):
`epicrealism_naturalSinRC1VAE`, `juggernautXL`, `juggernaut_reborn`, `photon_v1`, `wildcardxXLTURBO`

### Other model types PFX has, we don't:
- **controlnet:** `flux-canny-controlnet-v3`, `mistoline_flux.dev_v1`, `InstantX-FLUX1-Dev-Union`
- **clip_vision:** `CLIP-ViT-bigG-14`, `CLIP-ViT-H-14`, `clip_vision_h`
- **ipadapter:** ip-adapter plus/sdxl variants
- **insightface:** `buffalo_1`
- **liveportrait:** 5 models
- **LLM:** Florence-2-base, Florence-2-large (already on PFX, not on our VM)

> **Action:** Ask Jonas which specific workflows he plans to test in the POC. Download only those.

---

## 📋 NEXT ACTIONS (Priority Order)

| # | Action | Owner | Urgency |
|---|---|---|---|
| 1 | **Fix nvidia-smi / NVIDIA driver** — GPU must work for ComfyUI to be useful | Sushil | 🔴 CRITICAL |
| 2 | **Verify port 8188 is actually serving** — check logs, test via browser | Sushil | 🔴 CRITICAL |
| 3 | **Install Reemo** with token `studio_fa413ff7044b` | Sushil | 🔴 HIGH |
| 4 | **Get model list from Jonas** — which workflows for POC? | Sumit/Sushil | 🟡 HIGH |
| 5 | **Follow up with Dennis on VPN/Fortigate ETA** | Sumit | 🟡 MEDIUM |
| 6 | **Optionally restore PFX snapshot via ComfyUI Manager** — ensures exact custom node versions | Sushil | 🟢 LOW |

---

## ℹ️ Notes
- ComfyUI version PFX uses: commit `040460495c5713b852e4aac29a909aa63b309da7`
- All 38 PFX custom nodes are present — good match
- Phase 7 (workflow test sentinel) is **missing** — workflow end-to-end test was never run/passed

---

## 📁 Model Size Discrepancy (650GB vs 90GB)

The discrepancy between PFX's 644GB model library and the ~90GB provisioned on the VM is intentional, based on a direct instruction from the client.

In the email thread, **Dennis Engler explicitly stated:**
> *"List is attached, though I would probably **only add the ones we really need, not old ones and definitely not all.** Current folder is 644GB big, so I would need to clean this a bit"*

- **644 GB figure:** Represents PFX's entire historical model capability, including years of accumulated legacy SD1.5 checkpoints, redundant variants, old ControlNets, and abandoned experiments.
- **~90 GB figure:** Represents the curated, essential models required for their modern workflows (the modern `Flux` and `Wan2.1/2.2` models, plus necessary CLIPs and VAEs) that were initially provisioned to avoid copying hundreds of gigabytes of legacy bloat.

### Missing Essential Models (To be Confirmed with Jonas)
While we skipped the bloat, the following key models from their snapshot are **not installed** and likely still needed for the POC:
- `wan2.2_animate_14B_bf16.safetensors` (~32 GB)
- `flux1-fill-dev.safetensors` (~22 GB)
- `VACE-Wan2.1-1.3B-Preview.safetensors` (~6.7 GB)
- `wan2.1_vace_1.3B_fp16.safetensors` (~4.1 GB)
- **ControlNets:** `flux-canny-controlnet-v3`, `mistoline_flux.dev_v1`, `InstantX-FLUX1-Dev-Union`
