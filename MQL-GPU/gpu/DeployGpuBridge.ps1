#Requires -Version 5.1

param(
    [string]$SourceDll = "$PSScriptRoot\build\Release\GpuBridge.dll"
)

function Assert-File {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "DLL não encontrada em '$Path'. Gere-a primeiro (rebuild_cuda.bat)."
    }
}

function Ensure-Directory {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Copy-DllTo {
    param([string]$Directory)
    Ensure-Directory -Path $Directory
    $target = Join-Path $Directory "GpuBridge.dll"
    Copy-Item -LiteralPath $SourceDll -Destination $target -Force
    return $target
}

function Copy-DllToAgents {
    param(
        [string]$TesterRoot,
        [switch]$RequireAdmin
    )

    if(-not (Test-Path -LiteralPath $TesterRoot -PathType Container)) {
        return @()
    }

    if($RequireAdmin.IsPresent) {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if(-not $isAdmin) {
            Write-Warning "Permissão de administrador necessária para copiar em '$TesterRoot'. Abra o PowerShell como Administrador e execute novamente."
            return @()
        }
    }

    $copied = @()
    Get-ChildItem -LiteralPath $TesterRoot -Directory -Filter "Agent-*" | ForEach-Object {
        $libDir = Join-Path $_.FullName "MQL5\Libraries"
        $copied += Copy-DllTo -Directory $libDir
    }
    return $copied
}

Assert-File -Path $SourceDll

$manualTargets = @(
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU\gpu",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU_copy\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU_copy\gpu",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\VERSIONAMENTO\zeroproxy\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\VERSIONAMENTO\zeroproxy\gpu",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\MQL5\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\X-EA-FFT_v2\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\X-EA-FFT_v2\gpu"
)

$copiedTargets = @()

foreach($dir in $manualTargets) {
    $copiedTargets += Copy-DllTo -Directory $dir
}

$appDataTesterRoots = @(
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075"
)

foreach($root in $appDataTesterRoots) {
    $copiedTargets += Copy-DllToAgents -TesterRoot $root
}

$programFilesTesterRoots = @(
    "C:\Program Files\MetaTrader 5\Tester",
    "C:\Program Files\Dukascopy MetaTrader 5\Tester"
)

foreach($root in $programFilesTesterRoots) {
    $copiedTargets += Copy-DllToAgents -TesterRoot $root -RequireAdmin
}

if($copiedTargets.Count -eq 0) {
    Write-Host "Nenhuma DLL foi copiada." -ForegroundColor Yellow
} else {
    Write-Host "GpuBridge.dll atualizada nos seguintes destinos:" -ForegroundColor Green
    $copiedTargets | Sort-Object -Unique | ForEach-Object { Write-Host " - $_" }
}
