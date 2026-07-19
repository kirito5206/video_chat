# P2P Video Chat - One-Click Launcher (Windows)
#
# What it does:
#   1. Locates a Python 3.11+ interpreter
#   2. Creates a project-local virtualenv (.venv) and installs server deps
#   3. Starts the WebSocket signaling server in its own window
#   4. If Flutter SDK is present, runs `flutter pub get` + `flutter run`
#      Otherwise prints manual instructions and keeps the server running
#
# Usage:
#   Double-click start.bat  (or: powershell -ExecutionPolicy Bypass -File start.ps1)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerDir   = Join-Path $ProjectRoot "server"
$VenvDir     = Join-Path $ProjectRoot ".venv"
$SrvPort     = 8765

function Write-Step($n, $msg) {
    Write-Host "[$n/4] $msg" -ForegroundColor Yellow
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   P2P Video Chat - Startup Launcher" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# --- Step 1: Locate Python ---
Write-Step 1 "Locating Python interpreter..."
$PythonExe = $null
if (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExe = (Get-Command python).Source
} elseif (Test-Path "C:\Users\li\.workbuddy\binaries\python\versions\3.13.12\python.exe") {
    $PythonExe = "C:\Users\li\.workbuddy\binaries\python\versions\3.13.12\python.exe"
}
if (-not $PythonExe) {
    Write-Host "  ERROR: Python 3.11+ not found. Install it and retry." -ForegroundColor Red
    exit 1
}
Write-Host "  Using: $PythonExe" -ForegroundColor Green

# --- Step 2: Create venv + install deps ---
Write-Step 2 "Preparing Python virtual environment..."
if (-not (Test-Path $VenvDir)) {
    & $PythonExe -m venv $VenvDir
}
$PipExe     = Join-Path $VenvDir "Scripts\pip.exe"
$PythonVenv = Join-Path $VenvDir "Scripts\python.exe"
& $PipExe install -q -r (Join-Path $ServerDir "requirements.txt")
Write-Host "  Dependencies ready." -ForegroundColor Green

# --- Step 3: Start signaling server (own window) ---
Write-Step 3 "Starting signaling server on port $SrvPort..."
$ServerPy   = Join-Path $ServerDir "signaling_server.py"
$ServerProc = Start-Process -FilePath $PythonVenv `
    -ArgumentList "$ServerPy --host 0.0.0.0 --port $SrvPort" `
    -PassThru -WindowStyle Normal
Write-Host "  Server launched (PID $($ServerProc.Id))." -ForegroundColor Green
Start-Sleep -Seconds 2

# --- Step 4: Launch Flutter client if available ---
Write-Step 4 "Checking for Flutter SDK..."
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($flutter) {
    Write-Host "  Flutter found. Building & running client..." -ForegroundColor Green
    Set-Location $ProjectRoot
    & flutter pub get
    & flutter run
    Write-Host ""
    Write-Host "Flutter session ended." -ForegroundColor Yellow
    $ans = Read-Host "Stop the signaling server (PID $($ServerProc.Id))? [Y/n]"
    if ($ans -ne "n") {
        Stop-Process -Id $ServerProc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "Server stopped." -ForegroundColor Green
    }
} else {
    Write-Host "  Flutter SDK NOT found on this machine." -ForegroundColor Red
    Write-Host ""
    Write-Host "  The signaling server is now RUNNING at ws://localhost:$SrvPort" -ForegroundColor Green
    Write-Host "  To run the client on a Flutter-enabled machine:" -ForegroundColor White
    Write-Host "    1) Install Flutter SDK: https://docs.flutter.dev/get-started/install" -ForegroundColor White
    Write-Host "    2) cd $ProjectRoot" -ForegroundColor White
    Write-Host "    3) flutter pub get" -ForegroundColor White
    Write-Host "    4) flutter run -d windows   (or: -d android)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Press any key to STOP the server and exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Stop-Process -Id $ServerProc.Id -Force -ErrorAction SilentlyContinue
    Write-Host "Server stopped." -ForegroundColor Green
}
