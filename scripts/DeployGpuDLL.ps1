param(
    [string]$SourceDll = "..\gpu_engine\build\Release\GpuEngine.dll",
    [string]$TargetsFile = "scripts/targets.txt"
)

function Resolve-Source {
    param([string]$Path)
    if(-not (Test-Path $Path)) {
        throw "Source DLL not found: $Path"
    }
    return (Resolve-Path $Path).Path
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

$resolvedSource = Resolve-Source $SourceDll
$targets = Load-Targets $TargetsFile

Write-Host "Deploying $resolvedSource to $($targets.Count) target(s)..."

foreach($target in $targets) {
    if(-not (Test-Path $target)) {
        Write-Warning "Target path not found: $target"
        continue
    }

    $destinations = @(
        Join-Path $target "Libraries",
        Join-Path $target "MQL5\Libraries"
    )

    foreach($dest in $destinations) {
        try {
            Ensure-Directory $dest
            $destFile = Join-Path $dest "GpuEngine.dll"
            Copy-Item -Path $resolvedSource -Destination $destFile -Force
            Write-Host "  -> $destFile" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to copy to $dest : $_"
        }
    }
}

Write-Host "Deployment finished."
