param(
    [string]$Canonical = "C:\\Users\\pichau\\AppData\\Roaming\\MetaQuotes\\Terminal\\3CA1B4AB7DFED5C81B1C7F1007926D06\\MQL5\\WaveSpecGPU\\bin",
    [switch]$DryRun
)

function Write-Info { param($msg) Write-Host "[junction] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "[junction] $msg" -ForegroundColor Yellow }
function Write-Ok   { param($msg) Write-Host "[junction] $msg" -ForegroundColor Green }
function Write-Err  { param($msg) Write-Host "[junction] $msg" -ForegroundColor Red }

function New-Junction {
    param(
        [string]$Path,
        [string]$CanonicalTarget
    )
    if (-not (Test-Path $CanonicalTarget)) {
        Write-Err "Destino canônico não existe: $CanonicalTarget"
        return
    }
    if (Test-Path $Path) {
        $backup = "$Path`_backup_20251024"
        if (-not (Test-Path $backup)) {
            Write-Info "Renomeando $Path para $backup"
            if (-not $DryRun) { Rename-Item $Path $backup }
        } else {
            Write-Info "Removendo $Path existente"
            if (-not $DryRun) { Remove-Item $Path -Force -Recurse }
        }
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) {
        Write-Info "Criando diretório pai $parent"
        if (-not $DryRun) { New-Item -ItemType Directory -Path $parent | Out-Null }
    }
    Write-Info "Criando junction $Path -> $CanonicalTarget"
    if (-not $DryRun) {
        cmd /c mklink /J "$Path" "$CanonicalTarget" | Out-Null
    }
    Write-Ok "Junction configurada em $Path"
}

$fixedTargets = @(
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\Services",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\MQL5\Libraries",
    "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\MQL5\Services"
)

foreach ($target in $fixedTargets) {
    Write-Info "Aplicando junction em $target"
    New-Junction -Path $target -CanonicalTarget $Canonical
}

$agentBases = @(
    "C:\Program Files\MetaTrader 5\Tester",
    "C:\Program Files\Dukascopy MetaTrader 5\Tester",
    "$env:APPDATA\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06",
    "$env:APPDATA\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075"
)

foreach ($base in $agentBases) {
    if (-not (Test-Path $base)) {
        Write-Warn "Base não encontrada: $base"
        continue
    }
    Get-ChildItem $base -Directory -Filter "Agent-*" | ForEach-Object {
        $agentPath = $_.FullName
        Write-Info "Processando $agentPath"
        New-Junction -Path (Join-Path $agentPath "Libraries")      -CanonicalTarget $Canonical
        New-Junction -Path (Join-Path $agentPath "Services")       -CanonicalTarget $Canonical
        New-Junction -Path (Join-Path $agentPath "MQL5\Libraries") -CanonicalTarget $Canonical
        New-Junction -Path (Join-Path $agentPath "MQL5\Services")  -CanonicalTarget $Canonical
    }
}
