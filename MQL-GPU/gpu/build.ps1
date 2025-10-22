Write-Host "========================================"  -ForegroundColor Cyan
Write-Host "Building GpuBridge.dll with IFFT"  -ForegroundColor Cyan
Write-Host "========================================"  -ForegroundColor Cyan

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

# Find cmake
$cmakePaths = @(
    "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "C:\Program Files\CMake\bin\cmake.exe",
    "C:\Program Files (x86)\CMake\bin\cmake.exe"
)

$cmake = $null
foreach ($path in $cmakePaths) {
    if (Test-Path $path) {
        $cmake = $path
        break
    }
}

if ($null -eq $cmake) {
    # Try to find in PATH
    $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
}

if ($null -eq $cmake) {
    Write-Host "ERROR: CMake not found!" -ForegroundColor Red
    Write-Host "Please install CMake or Visual Studio 2022 with C++ workload" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Using CMake: $cmake" -ForegroundColor Green
Write-Host ""

# Create build directory
if (!(Test-Path "build")) {
    New-Item -ItemType Directory -Path "build" | Out-Null
}

Set-Location build

# Configure
Write-Host "Configuring..." -ForegroundColor Yellow
& $cmake -G "Visual Studio 17 2022" -A x64 ..
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Red
    Write-Host "Configuration FAILED!" -ForegroundColor Red
    Write-Host "====================================" -ForegroundColor Red
    Set-Location ..
    Read-Host "Press Enter to exit"
    exit 1
}

# Build
Write-Host ""
Write-Host "Building..." -ForegroundColor Yellow
& $cmake --build . --config Release
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Red
    Write-Host "Build FAILED!" -ForegroundColor Red
    Write-Host "====================================" -ForegroundColor Red
    Set-Location ..
    Read-Host "Press Enter to exit"
    exit 1
}

# Copy DLL
Write-Host ""
Write-Host "====================================" -ForegroundColor Green
Write-Host "Build SUCCESS!" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green

$dllSource = "Release\GpuBridge.dll"
$dllDest = "..\..\Libraries\GpuBridge.dll"

if (Test-Path $dllSource) {
    Copy-Item $dllSource $dllDest -Force
    Write-Host "DLL copied to Libraries folder" -ForegroundColor Green

    $dllInfo = Get-Item $dllDest
    Write-Host "DLL size: $($dllInfo.Length / 1KB) KB" -ForegroundColor Cyan
    Write-Host "DLL timestamp: $($dllInfo.LastWriteTime)" -ForegroundColor Cyan
} else {
    Write-Host "WARNING: DLL not found at $dllSource" -ForegroundColor Yellow
}

Set-Location ..
Write-Host ""
Read-Host "Press Enter to exit"
