# s4-extract.ps1 - Extract site-packages + custom_nodes, wait for models, launch ComfyUI
# Run as Admin: powershell -ExecutionPolicy Bypass -File C:\setup\s4-extract.ps1

$ErrorActionPreference = "Stop"
$LOG = "C:\Logs\illuma\s4.log"
New-Item -ItemType Directory -Path "C:\Logs\illuma" -Force | Out-Null

function Log($m, $c) { if (-not $c) { $c = "White" }; $t = "[$(Get-Date -f HH:mm:ss)] $m"; Write-Host $t -ForegroundColor $c; [IO.File]::AppendAllText($LOG, "$t`n") }
function OK($m)  { Log "[OK] $m" "Green" }
function SKP($m) { Log "[--] $m (skip)" "DarkGray" }
function Fail($m){ Log "[!!] $m" "Red"; throw $m }

trap {
    Log "[!!] ERROR at line $($_.InvocationInfo.ScriptLineNumber): $_" "Red"
    Get-Content $LOG -Tail 10 -ErrorAction SilentlyContinue
    Read-Host "Press Enter to close"
    exit 1
}

Log "=== s4: Extract assets ===" "Cyan"

$COMFYUI = "C:\ComfyUI"
$VENV    = "$COMFYUI\.venv"
$NODES   = "$COMFYUI\custom_nodes"
$MODELS  = "$COMFYUI\models"
$SP_TAR  = "C:\Logs\illuma\tmp\site_packages.tar.gz"
$CN_TAR  = "C:\Logs\illuma\tmp\custom_nodes.tar.gz"
$MDL_LOG = "C:\Logs\illuma\models-dl.log"

if (-not (Test-Path $SP_TAR)) { Fail "site_packages.tar.gz not found - run s3-download.ps1 first" }
if (-not (Test-Path $CN_TAR)) { Fail "custom_nodes.tar.gz not found - run s3-download.ps1 first" }
if (-not (Test-Path "$VENV\Scripts\python.exe")) { Fail "venv not found - run s2-comfyui.ps1 first" }

# --- Extract site-packages ---
$pkgDir   = "$VENV\Lib\site-packages"
$pkgCount = 0
if (Test-Path $pkgDir) {
    $pkgCount = (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue).Count
}
if ($pkgCount -gt 100) {
    SKP ("site-packages already extracted: " + $pkgCount + " packages")
} else {
    Log "  Extracting site_packages.tar.gz -> $VENV\Lib ..." "Blue"
    New-Item -ItemType Directory -Path "$VENV\Lib" -Force | Out-Null
    tar.exe -xzf $SP_TAR -C "$VENV\Lib"
    if ($LASTEXITCODE -ne 0) { Fail "site-packages extraction failed" }
    $pkgCount = (Get-ChildItem $pkgDir -Directory -ErrorAction SilentlyContinue).Count
    OK ("site-packages extracted: " + $pkgCount + " packages")
}

# --- Extract custom_nodes ---
$nodeCount = 0
if (Test-Path $NODES) {
    $nodeCount = (Get-ChildItem $NODES -Directory -ErrorAction SilentlyContinue).Count
}
if ($nodeCount -gt 5) {
    SKP ("custom_nodes already extracted: " + $nodeCount + " nodes")
} else {
    Log "  Extracting custom_nodes.tar.gz -> $COMFYUI ..." "Blue"
    New-Item -ItemType Directory -Path $NODES -Force | Out-Null
    tar.exe -xzf $CN_TAR -C $COMFYUI
    if ($LASTEXITCODE -ne 0) { Fail "custom_nodes extraction failed" }
    $nodeCount = (Get-ChildItem $NODES -Directory -ErrorAction SilentlyContinue).Count
    OK ("custom_nodes extracted: " + $nodeCount + " nodes")
}

# --- Models status ---
$modelFiles = (Get-ChildItem $MODELS -Recurse -File -ErrorAction SilentlyContinue).Count
Log "  Models files so far: $modelFiles (rclone may still be running)" "DarkGray"
Log "  Check models progress: Get-Content $MDL_LOG -Tail 5" "DarkGray"

Log ""
Log "=== s4 DONE - Setup complete ===" "Green"
Log ""
Log "  ComfyUI    : $COMFYUI" "White"
Log "  Models     : $modelFiles files in $MODELS" "White"
Log "  CustomNodes: $nodeCount nodes" "White"
Log "  Packages   : $pkgCount packages" "White"
Log ""
Log "To start ComfyUI (open a new PowerShell):" "Cyan"
Log "  cd C:\ComfyUI" "White"
Log "  .venv\Scripts\activate" "White"
Log "  python main.py --listen 0.0.0.0 --port 8188" "White"
Log ""
Log "Then open browser: http://localhost:8188" "Cyan"
Read-Host "Press Enter to close"
