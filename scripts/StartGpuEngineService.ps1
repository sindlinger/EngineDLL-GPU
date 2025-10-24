param(
    [switch]$Rebuild,
    [switch]$NoDeploy,
    [string]$CudaRoot = $env:CUDA_PATH
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$bin  = Join-Path $root 'bin'
$releaseBin = Join-Path $bin 'Release'

function Write-Info($msg) { Write-Host "[StartGpuService] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[StartGpuService] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[StartGpuService] $msg" -ForegroundColor Red }

function Print-Header {
@"
============================================================
 StartGpuEngineService.ps1  — GPU Engine Hub
 Base : $root
 Bin  : $bin
 Args : Rebuild=$Rebuild, NoDeploy=$NoDeploy, CudaRoot=$CudaRoot
============================================================
"@ | Write-Host -ForegroundColor Cyan
}

Print-Header

if(-not (Test-Path $bin)) {
    throw "Diretório bin não encontrado: $bin"
}

if($Rebuild) {
    Write-Info "Executando cmake (config/build)"
    & cmake -S $root -B (Join-Path $root 'build') -G "Visual Studio 17 2022"
    & cmake --build (Join-Path $root 'build') --config Release
}

Write-Info "Encerrando instâncias antigas"
try {
    Get-Process GpuEngineService -ErrorAction Stop | Stop-Process -Force -PassThru | Out-Null
    Start-Sleep -Milliseconds 500
} catch { }
Start-Process taskkill -ArgumentList '/IM GpuEngineService.exe /F' -NoNewWindow -Wait -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Milliseconds 200

if(-not $NoDeploy) {
    $artifacts = Get-ChildItem $releaseBin -Filter 'GpuEngine*.*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.dll','.exe','.lib' }
    foreach($file in $artifacts) {
        Write-Info "Promovendo $($file.Name)"
        Copy-Item $file.FullName (Join-Path $bin $file.Name) -Force
    }

    $cudaCandidates = @()
    if($CudaRoot) {
        $cudaCandidates += $CudaRoot
    }
    $cudaCandidates += "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA\v13.0"
    $cudaCandidates += "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA"

    $needed = @{ 
        'cudart64_13.dll' = 'bin\x64';
        'cufft64_12.dll'  = 'bin\x64';
        'cufftw64_12.dll' = 'bin\x64';
    }

    foreach($pair in $needed.GetEnumerator()) {
        $dest = Join-Path $bin $pair.Key
        if(Test-Path $dest) { continue }
        $found = $null
        foreach($basePath in $cudaCandidates) {
            if(-not $basePath) { continue }
            $candidate = Join-Path $basePath $pair.Value
            if(Test-Path $candidate) {
                $match = Get-ChildItem $candidate -Filter $pair.Key -ErrorAction SilentlyContinue | Select-Object -First 1
                if($match) { $found = $match.FullName; break }
            }
        }
        if($found) {
            Write-Info "Copiando $($pair.Key) de $found"
            Copy-Item $found $dest -Force
        } else {
            Write-Warn "Não encontrado: $($pair.Key). Ajuste --CudaRoot ou copie manualmente."
        }
    }

    $devrt = Join-Path $bin 'cudadevrt.lib'
    if(-not (Test-Path $devrt)) {
        $devCandidates = foreach($basePath in $cudaCandidates) {
            if($basePath) { Join-Path $basePath 'lib\x64' }
        }
        foreach($base in $devCandidates) {
            if(-not $base) { continue }
            $match = Get-ChildItem $base -Filter 'cudadevrt.lib' -ErrorAction SilentlyContinue | Select-Object -First 1
            if($match) {
                Copy-Item $match.FullName $devrt -Force
                break
            }
        }
        if(-not (Test-Path $devrt)) {
            Write-Warn "cudadevrt.lib não encontrado."
        }
    }
}

$logDir = Join-Path $bin 'logs'
if(-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$exe = Join-Path $bin 'GpuEngineService.exe'
if(-not (Test-Path $exe)) {
    throw "Executable não encontrado: $exe"
}

Write-Info "Iniciando GpuEngineService.exe"
Start-Process $exe -WorkingDirectory $bin

Write-Info "Serviço iniciado. Logs em: $(Join-Path $logDir 'gpu_service.log')"
