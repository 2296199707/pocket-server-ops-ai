[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$agentDir = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $agentDir 'client\Program.cs'
$distDir = Join-Path $agentDir 'dist'
$package = Get-Content -LiteralPath (Join-Path $agentDir 'package.json') -Raw | ConvertFrom-Json
$outputPath = Join-Path $distDir ("PocketServerOps-Computer-Client-v{0}-win-x64.exe" -f $package.version)

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) {
    throw '未找到 Windows .NET Framework C# 编译器。'
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu /codepage:65001 `
    /out:$outputPath `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Windows.Forms.dll `
    $sourcePath
if ($LASTEXITCODE -ne 0) { throw "Windows 主界面构建失败，退出码 $LASTEXITCODE" }

Write-Host "Windows 主界面: $outputPath"
