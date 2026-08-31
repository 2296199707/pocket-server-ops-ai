[CmdletBinding()]
param(
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'

function Find-Node22 {
    param([string]$PreferredPath)

    $candidates = @()
    if ($PreferredPath) { $candidates += $PreferredPath }
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe') }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $version = (& $candidate --version 2>$null | Out-String).Trim()
        if ($version -match '^v22\.') { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw '构建 Windows Agent 需要 Node.js 22。'
}

$nodeExe = Find-Node22 -PreferredPath $NodePath
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nodeDir = Split-Path -Parent $nodeExe
$env:Path = "$nodeDir;$env:Path"
$npmCommand = (Get-Command npm.cmd -ErrorAction Stop).Source

Push-Location $sourceDir
try {
    $env:npm_config_node_gyp = $null
    & $npmCommand ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci 失败，退出码 $LASTEXITCODE" }
    & $npmCommand run build:windows
    if ($LASTEXITCODE -ne 0) { throw "Windows Agent 构建失败，退出码 $LASTEXITCODE" }
} finally {
    Pop-Location
}
