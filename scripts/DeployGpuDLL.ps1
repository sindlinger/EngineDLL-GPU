param(
    [string]$SourceDir = "..\bin\Release",
    [string]$TargetsFile = "targets.txt"
)

function Resolve-SourceDir {
    param([string]$Path)
    if(Test-Path $Path) {
        return (Resolve-Path $Path).Path
    }
    $fallback = Split-Path $Path -Parent
    $fallbackResolved = Resolve-Path $fallback -ErrorAction SilentlyContinue
    if($null -ne $fallbackResolved) {
        Write-Warning "Source directory $Path não encontrado. Usando $($fallbackResolved.Path) como origem."
        return $fallbackResolved.Path
    }
    throw "Source directory not found: $Path (fallback ..\bin também indisponível)"
}

function Load-Targets {
    param([string]$File)
    if(-not (Test-Path $File)) {
        throw "Targets file not found: $File"
    }
    $content = Get-Content $File | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not ($_.StartsWith('#')) }
    return $content
}

function Ensure-Directory {
    param([string]$Path)
    if(-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$scriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$resolvedSource = Resolve-SourceDir (Join-Path $scriptRoot $SourceDir)
$targets = Load-Targets (Join-Path $scriptRoot $TargetsFile)

$filesToCopy = @(
    "GpuEngine.dll",
    "GpuEngineClient.dll",
    "GpuEngineService.exe"
)

Write-Host "Deploying assets from $resolvedSource to $($targets.Count) target(s)..."

foreach($target in $targets) {
    if(-not (Test-Path $target)) {
        Write-Warning "Target path not found: $target"
        continue
    }

    $binPath = Join-Path $target "MQL5\WaveSpecGPU\bin"
    Ensure-Directory $binPath

    foreach($file in $filesToCopy) {
        $sourceFile = Join-Path $resolvedSource $file
        if(-not (Test-Path $sourceFile)) {
            Write-Warning "Source file not found: $sourceFile"
            continue
        }
        $destination = Join-Path $binPath $file
        try {
            Copy-Item -Path $sourceFile -Destination $destination -Force
            Write-Host "  -> $destination" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to copy to $destination : $_"
        }
    }
}

Write-Host "Deployment finished."
