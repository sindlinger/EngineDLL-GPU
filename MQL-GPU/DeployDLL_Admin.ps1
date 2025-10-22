# GpuBridge.dll Deployment Script (Requires Admin)
# Run as Administrator: Right-click → Run with PowerShell

$ErrorActionPreference = "Continue"
$SourceDLL = "$PSScriptRoot\gpu\build\Release\GpuBridge.dll"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "GpuBridge.dll Deployment (Admin)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Right-click this script and select 'Run as Administrator'" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

# Check source DLL
if (-not (Test-Path $SourceDLL)) {
    Write-Host "ERROR: Source DLL not found: $SourceDLL" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "Source DLL: $SourceDLL" -ForegroundColor Green
$dllSize = (Get-Item $SourceDLL).Length
Write-Host "Size: $([math]::Round($dllSize/1KB, 2)) KB" -ForegroundColor Green
Write-Host ""

$TotalCopied = 0
$TotalFailed = 0

# Function to copy DLL
function Copy-DLLToAgent {
    param(
        [string]$DestPath,
        [string]$AgentName
    )

    $LibPath = Join-Path $DestPath "MQL5\Libraries"

    if (Test-Path $DestPath) {
        try {
            # Create Libraries folder if not exists
            if (-not (Test-Path $LibPath)) {
                New-Item -Path $LibPath -ItemType Directory -Force | Out-Null
            }

            # Copy DLL
            Copy-Item -Path $SourceDLL -Destination (Join-Path $LibPath "GpuBridge.dll") -Force

            Write-Host "[OK] $AgentName" -ForegroundColor Green
            $script:TotalCopied++
        }
        catch {
            Write-Host "[FAIL] $AgentName - $($_.Exception.Message)" -ForegroundColor Red
            $script:TotalFailed++
        }
    }
}

# Deploy to Dukascopy MT5 Agents
Write-Host "=== Dukascopy MetaTrader 5 ===" -ForegroundColor Cyan
for ($i = 2000; $i -le 2008; $i++) {
    $agentPath = "C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-$i"
    Copy-DLLToAgent -DestPath $agentPath -AgentName "Dukascopy Agent $i"
}

Write-Host ""

# Deploy to Standard MT5 Agents
Write-Host "=== Standard MetaTrader 5 ===" -ForegroundColor Cyan
for ($i = 2000; $i -le 2015; $i++) {
    $agentPath = "C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-$i"
    Copy-DLLToAgent -DestPath $agentPath -AgentName "Standard Agent $i"
}

Write-Host ""

# Deploy to AppData Agents (just in case)
Write-Host "=== AppData Agents (Terminal D0E8209F) ===" -ForegroundColor Cyan
for ($i = 3000; $i -le 3023; $i++) {
    $agentPath = "C:\Users\$env:USERNAME\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-$i"
    Copy-DLLToAgent -DestPath $agentPath -AgentName "Agent D0E8209F $i"
}

Write-Host ""

# Deploy to AppData Agents (Terminal 3CA1B4AB)
Write-Host "=== AppData Agents (Terminal 3CA1B4AB) ===" -ForegroundColor Cyan
for ($i = 3000; $i -le 3001; $i++) {
    $agentPath = "C:\Users\$env:USERNAME\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06\Agent-127.0.0.1-$i"
    Copy-DLLToAgent -DestPath $agentPath -AgentName "Agent 3CA1B4AB $i"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Successfully copied: $TotalCopied" -ForegroundColor Green
Write-Host "Failed: $TotalFailed" -ForegroundColor $(if ($TotalFailed -gt 0) { "Red" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($TotalCopied -gt 0) {
    Write-Host "DLL deployed to $TotalCopied locations!" -ForegroundColor Green
}

if ($TotalFailed -gt 0) {
    Write-Host "Some copies failed. Check error messages above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
