# PocketServerOps Windows Agent beta

这是 PocketServerOps 的 Windows 电脑端后台 Agent。它使用 Node.js 22
自带的全局 `WebSocket`，由 Windows 主动连接中转服务器，不需要在中转服务器
上反向连接 Windows。

推荐使用独立 EXE。电脑首次运行 EXE 时会进入配对向导，粘贴手机 App 的“电脑
配对信息”即可；EXE 自带 Node.js 运行时，不需要另外安装 Node.js。当前仓库的
GitHub Actions 会在 beta 分支更新后构建 Windows x64 压缩包，构建完成后可从
Actions 的 artifact 下载。

## 要求

- Windows 10/11；
- 独立 EXE 不需要安装 Node.js；
- 源码运行或使用旧安装脚本时需要 Node.js 22；
- 中转服务器提供 `wss://.../device/ws`；
- 设备已经在 PocketServerOps 中完成配对，并取得 `device_id` 和
  `device_token`。

Agent 运行时不引入 npm 依赖。构建工具只用于生成独立 EXE。`device_token` 保存在当前用户安装目录的
`config.json` 中，安装脚本会移除继承权限并只授予当前用户访问。

## 独立 EXE 首次配置

从 beta 构建 artifact 下载并解压 `PocketServerOps-Computer-windows-x64.zip`，
在 PowerShell 中运行 EXE：

```powershell
.\PocketServerOps-Computer-v1.0.0-beta.2-win-x64.exe
```

当前构建未使用商业代码签名证书，Windows 首次运行可能显示 SmartScreen 提示；
确认文件来自本项目后再允许运行即可。

在手机 App 的 Windows 电脑目标中保存配置后，打开“电脑配对信息”，点击“复制
配置”，把得到的一行 JSON 粘贴到 EXE。程序会保存配置并注册当前用户登录时自动
启动的任务。Windows Agent 只接收 `relay_url`、`device_id`、`device_token` 和
`working_directory`，不会接收中转 API Token。

以后需要重新配置时运行：

```powershell
.\PocketServerOps-Computer-v1.0.0-beta.2-win-x64.exe --setup
```

卸载登录启动任务：

```powershell
.\PocketServerOps-Computer-v1.0.0-beta.2-win-x64.exe --uninstall
```

## 源码运行或旧脚本安装

在本目录打开 PowerShell，使用当前用户安装：

```powershell
.\\install.ps1 `
  -RelayUrl 'wss://relay.example.com' `
  -DeviceId 'windows-device-001' `
  -DeviceToken 'device-token' `
  -WorkingDirectory 'C:\\Users\\Public\\PocketServerOps'
```

安装脚本会优先寻找已有的 Node.js 22，复制 Agent 到
`%LOCALAPPDATA%\\PocketServerOps\\computer-agent`，然后注册当前用户登录时
启动的 Scheduled Task。脚本不会自动下载 Node.js；找不到 Node.js 22 时会直接
报错。

也可以先复制 `config.example.json` 为本目录的 `config.json`，填好配置后运行：

```powershell
.\\install.ps1
```

手动运行：

```powershell
node .\\agent.mjs --config .\\config.json
```

卸载任务但保留文件：

```powershell
.\\uninstall.ps1
```

同时删除安装目录：

```powershell
.\\uninstall.ps1 -RemoveFiles
```

## 配置

配置文件至少包含：

```json
{
  "relay_url": "wss://relay.example.com",
  "device_id": "windows-device-001",
  "device_token": "device-token",
  "agent_version": "1.0.0-beta.1",
  "protocol_version": "1",
  "working_directory": "C:\\Users\\Public\\PocketServerOps"
}
```

`relay_url` 必须是 `wss://`。如果没有写 `/device/ws`，Agent 会自动追加；完整
地址也可以直接填写。

`working_directory` 是命令默认工作目录，也是相对文件路径的基准目录。Windows
端 beta 没有把它伪装成 Linux shell：命令固定由 `powershell.exe` 执行，文件路径
使用 Windows 语义。文件工具允许绝对路径，因此需要把设备 Token 和电脑权限当作
完整的本机操作权限来管理。

## WebSocket 协议

连接地址为 `wss://<relay>/device/ws`。连接成功后首帧严格为：

```json
{
  "type": "authenticate",
  "device_id": "windows-device-001",
  "device_token": "device-token",
  "agent_version": "1.0.0-beta.1",
  "protocol_version": "1"
}
```

服务端返回：

```json
{
  "type": "authenticated",
  "device_id": "windows-device-001",
  "heartbeat_interval_ms": 30000
}
```

之后 Agent 发送：

```json
{ "type": "heartbeat", "device_id": "windows-device-001" }
```

服务端应返回 `{"type":"heartbeat_ack"}`。服务端调用格式：

```json
{
  "type": "call",
  "request_id": "request-001",
  "operation": "status",
  "payload": {}
}
```

Agent 返回：

```json
{
  "type": "result",
  "request_id": "request-001",
  "ok": true,
  "result": {}
}
```

失败时 `ok` 为 `false`，`error` 为 `{ "code": "...", "message": "..." }`。
服务端可以发送 `{ "type": "cancel", "request_id": "request-001" }` 取消
正在等待的调用。

## 操作

支持以下 operation：

- `exec`：使用固定 `powershell.exe` 执行一次命令，支持 `command`、可选
  `working_directory`、`input`、`timeout_ms`；
- `process.start`：启动后台 PowerShell，返回 `process_id`；不提供 PTY；
- `process.poll`：按 `stdout_offset`、`stderr_offset` 读取增量输出，可用
  `wait_ms` 等待新输出或进程结束；
- `process.write`：向后台进程 stdin 写入 UTF-8 文本；
- `process.stop`：停止后台进程树；
- `file.read`：按字节 `offset`/`length` 读取 UTF-8 文本，或指定
  `encoding: "base64"` 读取二进制；
- `file.write`：写入 UTF-8 `content` 或 base64 `content_base64`，支持分块
  `offset`；
- `file.replace`：只在 `old` 文本恰好出现一次时替换；
- `status`：返回 CPU 总体和每核心使用率、内存、磁盘、系统和 Agent 状态。

## 长任务和断线行为

`process_id` 只在 Agent 进程存活期间有效。网络断开时 Agent 保留正在运行的
PowerShell 进程和本地输出文件，重连采用 1、2、4 秒递增退避，最大 30 秒；重连
成功后服务端可以继续调用 `process.poll`、`process.write` 或 `process.stop`。

Agent 不会因为断线自动重放任何调用，尤其不会自动重放 `exec`、文件写入或进程
启动。相同 `request_id` 在本次 Agent 进程内会返回已缓存结果，避免 relay 重复
投递时再次执行副作用操作。缓存和后台进程都在 Agent 退出后失效。

## beta 限制

- 单次命令和 stdin 最大 1 MiB；
- `exec` 每个 stdout/stderr 最多保存 2 MiB；
- 每个后台进程 stdout/stderr 最多保存 16 MiB，`poll` 每个通道最多返回
  256 KiB；
- 单次文件读取最多 1 MiB，写入最多 8 MiB，文本替换文件最多 16 MiB；
- 断线重投结果缓存最多 32 MiB，单个结果最多 8 MiB，缓存只在 Agent 进程存活
  期间有效；
- 最多 32 个运行中的后台进程，最多保留 64 个进程记录；
- 不支持 PTY、桌面画面、鼠标键盘控制和端口转发；
- Agent 进程被系统终止后，后台进程和 `process_id` 不会恢复。

## 未包含的服务端部分

本目录只提供 Windows Agent。中转服务器仍需实现同一 WebSocket 协议的
`/device/ws` 端点、设备认证、调用队列和结果转发；Agent 不会兼容旧的 HTTP
轮询接口。
