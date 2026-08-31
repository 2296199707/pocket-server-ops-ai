[CmdletBinding()]
param(
    [string]$RelayUrl,
    [string]$DeviceId,
    [string]$DeviceToken,
    [string]$WorkingDirectory,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PocketServerOps\computer-agent'),
    [string]$TaskName = 'PocketServerOps-ComputerAgent',
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
    throw '未找到 Node.js 22。请先安装 Node.js 22，或使用 -NodePath 指定 node.exe。安装脚本不会自动下载运行时。'
}

function Set-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )

    if ($null -eq $Value -or $Value -eq '') { return }
    $script:Config[$Key] = $Value
}

function Read-JsonMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $map = @{}
    foreach ($property in $parsed.PSObject.Properties) {
        $map[$property.Name] = [string]$property.Value
    }
    return $map
}

$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nodeExe = Find-Node22 -PreferredPath $NodePath
$resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $resolvedInstallDir 'config.json'
$agentPath = Join-Path $resolvedInstallDir 'agent.mjs'
$sourceConfigPath = Join-Path $sourceDir 'config.json'

New-Item -ItemType Directory -Path $resolvedInstallDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir 'agent.mjs') -Destination $agentPath -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'package.json') -Destination (Join-Path $resolvedInstallDir 'package.json') -Force

if (Test-Path -LiteralPath $configPath) {
    $script:Config = Read-JsonMap -Path $configPath
} elseif (Test-Path -LiteralPath $sourceConfigPath) {
    $script:Config = Read-JsonMap -Path $sourceConfigPath
} else {
    $script:Config = @{}
}

Set-ConfigValue -Path $configPath -Key 'relay_url' -Value $RelayUrl
Set-ConfigValue -Path $configPath -Key 'device_id' -Value $DeviceId
Set-ConfigValue -Path $configPath -Key 'device_token' -Value $DeviceToken
Set-ConfigValue -Path $configPath -Key 'working_directory' -Value $WorkingDirectory
if (-not $script:Config['agent_version']) { $script:Config['agent_version'] = '1.0.0-beta.1' }
if (-not $script:Config['protocol_version']) { $script:Config['protocol_version'] = '1' }

$required = @('relay_url', 'device_id', 'device_token', 'working_directory')
foreach ($key in $required) {
    if (-not $script:Config[$key]) {
        throw "配置缺少 $key。首次安装请通过参数提供，或先编辑 config.json。"
    }
}

New-Item -ItemType Directory -Path $script:Config['working_directory'] -Force | Out-Null
$script:Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

$currentUser = "$env:USERDOMAIN\$env:USERNAME"
& icacls.exe $configPath /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null

$argumentLine = '"{0}" --config "{1}"' -f $agentPath, $configPath
$action = New-ScheduledTaskAction -Execute $nodeExe -Argument $argumentLine -WorkingDirectory $resolvedInstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType InteractiveToken -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'PocketServerOps Windows Agent' | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "已安装并启动 $TaskName"
Write-Host "Node.js: $nodeExe"
Write-Host "配置: $configPath"
