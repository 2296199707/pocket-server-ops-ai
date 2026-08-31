[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PocketServerOps\computer-agent'),
    [string]$TaskName = 'PocketServerOps-ComputerAgent',
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

if ($RemoveFiles) {
    $resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)
    if (Test-Path -LiteralPath $resolvedInstallDir) {
        Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
        Write-Host "已删除安装目录: $resolvedInstallDir"
    }
}

Write-Host "已卸载 $TaskName"
