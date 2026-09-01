[CmdletBinding()]
param(
    [ValidateSet('relay', 'direct')][string]$ConnectionMode,
    [string]$RelayUrl,
    [int]$DirectListenPort,
    [string]$DeviceId,
    [string]$DeviceToken,
    [string]$WorkingDirectory,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PocketServerOps\computer-agent'),
    [string]$TaskName = 'PocketServerOps-ComputerAgent',
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'

function Find-CompatibleNode {
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
        if ($version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw '未找到 Node.js 22 或更高版本。请先安装 Node.js，或使用 -NodePath 指定 node.exe。'
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
$nodeExe = Find-CompatibleNode -PreferredPath $NodePath
$resolvedInstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$configPath = Join-Path $resolvedInstallDir 'config.json'
$agentPath = Join-Path $resolvedInstallDir 'agent.mjs'
$sourceConfigPath = Join-Path $sourceDir 'config.json'

New-Item -ItemType Directory -Path $resolvedInstallDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir 'agent.mjs') -Destination $agentPath -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'package.json') -Destination (Join-Path $resolvedInstallDir 'package.json') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'package-lock.json') -Destination (Join-Path $resolvedInstallDir 'package-lock.json') -Force

if (Test-Path -LiteralPath $configPath) {
    $script:Config = Read-JsonMap -Path $configPath
} elseif (Test-Path -LiteralPath $sourceConfigPath) {
    $script:Config = Read-JsonMap -Path $sourceConfigPath
} else {
    $script:Config = @{}
}

Set-ConfigValue -Path $configPath -Key 'connection_mode' -Value $ConnectionMode
Set-ConfigValue -Path $configPath -Key 'relay_url' -Value $RelayUrl
if ($DirectListenPort -gt 0) {
    $script:Config['direct_listen_port'] = [string]$DirectListenPort
}
Set-ConfigValue -Path $configPath -Key 'device_id' -Value $DeviceId
Set-ConfigValue -Path $configPath -Key 'device_token' -Value $DeviceToken
Set-ConfigValue -Path $configPath -Key 'working_directory' -Value $WorkingDirectory
if (-not $script:Config['connection_mode']) { $script:Config['connection_mode'] = 'relay' }
if (-not $script:Config['agent_version']) { $script:Config['agent_version'] = '1.0.0-beta.6' }
if (-not $script:Config['protocol_version']) { $script:Config['protocol_version'] = '1' }

$required = @('device_id', 'device_token', 'working_directory')
if ($script:Config['connection_mode'] -eq 'relay') { $required += 'relay_url' }
foreach ($key in $required) {
    if (-not $script:Config[$key]) {
        throw "配置缺少 $key。首次安装请通过参数提供，或先编辑 config.json。"
    }
}

New-Item -ItemType Directory -Path $script:Config['working_directory'] -Force | Out-Null
$script:Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

$npmCommand = Join-Path (Split-Path -Parent $nodeExe) 'npm.cmd'
if (-not (Test-Path -LiteralPath $npmCommand)) {
    $npmCommand = (Get-Command npm.cmd -ErrorAction Stop).Source
}
Push-Location $resolvedInstallDir
try {
    & $npmCommand ci --omit=dev --ignore-scripts
    if ($LASTEXITCODE -ne 0) { throw "npm ci 失败，退出码 $LASTEXITCODE" }
} finally {
    Pop-Location
}

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
