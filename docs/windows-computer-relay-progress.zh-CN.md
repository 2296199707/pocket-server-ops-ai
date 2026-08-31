# Windows 电脑中转连接进度

## 目标

Goal：`01a02f79-5a29-7f70-bf38-2ffb76d5f034`

为 PocketServerOps AI 增加第一版 Windows 电脑连接能力：手机从“服务器添加”进入电脑配置，Windows 端安装后台 Agent 后主动连接中转服务器，手机可以通过中转通道执行 PowerShell、读写文件、启动后台任务并读取基础状态。

本轮约束：最小实现、稳定优先、不过度限制 AI 能力、不修改旧项目 `/www/server-agent/workspace/apps/mobile`、构建和缓存只放数据盘、测试只覆盖关键路径。

## 已确认的现状

- 规范 App 是 `/www/server-agent/workspace/apps/mobile-agent-v1`，当前分支为 `beta`。
- `ServerProfile` 当前只描述 SSH 目标，`RemoteAgentTools` 直接依赖 `SshConnection`，Linux 命令和 `/proc` 状态脚本不能直接套到 Windows。
- 多服务器工具组已经存在，工具参数通过 `server_id` 路由；新增电脑目标应保持同一层的目标路由，不复制一套 Agent 循环。
- App 已有本地数据库、凭据安全存储、任务事件和 Android 前台任务服务，可复用这些基础设施。
- 旧项目包含可参考的 relay：`assets/relay/relay-bundle.tar.gz`、`lib/relay/relay_connection.dart` 和 `lib/relay/relay_client.dart`。它的实现是手机 SSH 到中转服务器后做本地端口转发，主要服务于中转服务器上的任务，不包含 Windows 主动连接协议。旧项目只读参考，禁止修改。

## 架构决定

```text
手机 App ──持久 SSH/HTTPS 访问──┐
                                ├── 中转服务器
Windows Agent ──主动 WSS/HTTPS──┘
```

- Windows Agent 只建立出站连接，不要求家庭网络端口转发。
- 手机连接中转服务器的凭据与 Windows 配对凭据分离；密码、Token 和私钥不放入 AI 上下文。
- 中转服务器保存设备注册信息和待处理请求的短期状态，不保存电脑文件内容和 AI 密钥。
- 第一版设备能力为 `exec`、`file.read`、`file.write`、`process.start`、`process.poll`、`process.stop`、`status`。
- Windows 命令解释器固定为 PowerShell；不伪装成 POSIX shell。屏幕、鼠标、键盘控制不在第一版范围内。
- 电脑目标与 SSH 服务器共用“目标”展示和对话绑定模型，但连接实现由目标类型分派。

## 实现阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| G0 | 现有 App、旧 relay、Windows 运行方式和数据盘路径盘点 | 已完成 |
| G1 | 增加目标类型和持久化字段，保持旧 SSH 数据可迁移 | 已完成 |
| G2 | 实现轻量 relay 协议和一键部署材料 | 已完成 |
| G3 | 实现 Windows Agent 安装脚本、配对和重连 | 已完成（Windows 真机未验证） |
| G4 | App 内置电脑连接客户端和 AI 工具路由 | 已完成 |
| G5 | “服务器添加”增加电脑入口、测试连接和设备状态 | 已完成 |
| G6 | 命令、文件、后台进程、状态关键路径验证 | 已完成（自动化及本地闭环） |
| G7 | 数据盘构建、文档和 beta 交付检查 | 已完成（Windows 真机未验证） |

## 协议决定（2026-08-31）

已根据 `/srv/wfl-codex-desktop` 的 `windows-device-broker.mjs` 和
`companion/windows-host/src/agent.mjs` 统一为 WebSocket JSON 帧，不再保留
HTTP 长轮询作为设备通道。HTTP 只负责健康检查、设备注册、设备状态查询和
调试用的请求状态查询。

通道分为两条：Windows Agent 主动连接 `/device/ws`，手机通过
`/v1/devices/{device_id}/ws` 连接。两条通道都只承载 JSON 文本；Agent 连接
使用设备 Token，手机连接使用 relay API Token。

```text
device: authenticate -> authenticated
device: heartbeat <-> heartbeatAck
device: capabilities
device: callResult

phone: hello -> authenticated
phone: request -> accepted/result
phone: cancel
```

每个调用使用手机生成的 `request_id`。relay 在内存中保留请求结果一段时间，
设备断线时不自动重放命令，也不立即丢弃仍在执行的请求；Agent 重连后可以用
原 request_id 回传结果。手机侧如果连接在结果返回前断开，本次调用返回连接
错误，不自动重放；后续由用户或 Agent 先查询状态再决定是否继续。手机重连时
可以带上待查询的 request_id，relay 会返回已完成结果。

设备重连认证成功后，relay 会把该设备仍处于 `running` 的调用用原 request ID
重新发送。Agent 的进行中/已完成请求表会把它当作同一次调用并只补挂新连接，
不会重新启动 PowerShell 命令；这覆盖了“命令已经启动但设备 WebSocket 短暂
断开”的情况。relay 进程重启会丢失内存中的请求表，第一版不宣称跨 relay 重启
恢复。

手机客户端的实际行为是：已发送但尚未完成的调用保留在内存中，WebSocket 断开
后在本次调用的超时期限内指数退避重连，并用相同的 `request_id` 重新登记请求。
relay 对已有 request ID 只重新绑定手机连接，不会再次发送设备调用，因此不会
因为网络波动重复执行命令。超时、取消或 App 主动关闭客户端时才移除待处理请求；
取消帧只在当前连接可用时发送，不把取消误当作重试。

手机 WebSocket URL 中的设备 ID 现在必须与 `hello.device_id` 一致。这样一个已
授权的手机连接不能通过修改 hello 帧切换到另一个设备；设备 Token 仍只由
Windows Agent 使用。

Windows Agent 在每次认证后上报当前版本、平台和支持的操作列表，relay 的设备
状态接口可以据此展示能力；能力列表不包含 Token、密码或文件内容。

协议大小约定：HTTP 管理请求体上限为 2 MiB；设备/手机 WebSocket JSON 帧和 RPC
请求体上限为 16 MiB。Windows Agent 的单次文件写入上限为 8 MiB，预留了 JSON
base64 编码后的空间；普通文件读取上限为 1 MiB，后台进程单次轮询输出上限为
256 KiB。超限由 relay 或 Agent 返回明确错误，不截断二进制写入。

设备心跳、设备 epoch 和单设备单调用租约是 WFL Desktop 的浏览器 Host 专用
语义，PocketServerOps 第一版不复制用户账号和插件授权系统；本项目只复用
经源码确认的出站 WebSocket、认证、心跳、结果上下文和退避重连语义。

```json
{
  "type": "request",
  "request_id": "req-123",
  "device_id": "computer-1",
  "operation": "exec",
  "payload": {
    "command": "Get-Location",
    "working_directory": "C:\\work"
  }
}
```

第一版不把任意手机端口暴露到公网，也不允许 relay 代替设备执行命令。命令
是否执行由已配对设备执行；后台任务通过设备端 `process_id` 保持可轮询，
禁止断线自动重放有副作用命令。

## 待验证问题

- Windows Agent 当前 beta 采用 Node.js 22 无第三方运行时依赖，PowerShell
  安装脚本注册登录启动的任务；没有 Windows 构建环境时不伪装成已验证的 MSI。
- App 当前 SSH relay 连接代码不能直接复制到规范项目作为 Windows 通道客户端，
  已改为独立的 WebSocket 协议客户端。
- relay 的生产部署仍是容器内 HTTP；对公网使用时必须由现有反向代理终止 TLS，
  并把手机地址配置为 `https://`、Windows Agent 地址配置为 `wss://`。第一版
  不在 relay 容器内重复实现证书管理。
- 没有 Windows 真机和 WSS 反向代理环境，因此 PowerShell 执行、Windows 磁盘
  查询、登录启动任务和真实断线重连仍需用户环境验证；Node.js 语法、Agent CLI、
  relay 本地 WebSocket 闭环已经验证。

## 测试记录

2026-08-31 最终检查：

- `node --check relay/computer-relay/server.mjs`：通过。
- `node --check relay/computer-agent/agent.mjs`：通过；`--version` 和 `--help` 已通过。
- relay 本地 WebSocket smoke test：设备注册、设备认证、手机认证、请求/结果闭环、
  错误设备路径拒绝、设备断线后同 request ID 恢复均通过。
- `flutter test test/domain/models_test.dart test/computer_tools_test.dart test/app_controller_test.dart`：75 个测试全部通过。
- `flutter analyze`：无新增问题；仅保留既有 `test/mcp_client_test.dart:176:39`
  的 `use_null_aware_elements` info。
- `git diff --check`：通过。
- `flutter build apk --debug`：成功。APK 位于
  `/www/mobile-agent-build/app/outputs/flutter-apk/app-debug.apk`，大小
  `176833032` 字节；`build` 符号链接目标为 `/www/mobile-agent-build`。
- `flutter build apk --release`：成功。APK 位于
  `/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.5-beta.3-release.apk`，
  大小 `80062635` 字节；`versionName=1.0.5-beta.3`、`versionCode=47`；SHA-256 为
  `fd1141154182bf81fea77e192a02e5a533494e99b15e4a2ba31bbed0b53bd0aa`。

上下文压缩后先读取本文件，不重复调查已确认的架构和旧项目边界。

## 变更日志

- 2026-08-31：创建 goal，完成规范 App、旧 relay 和 Windows 兼容性盘点；确定 Windows 主动连接、中转 RPC、PowerShell 专用能力的第一版边界。
- 2026-08-31：完成协议统一决定；删除 HTTP 长轮询设备通道设计，采用手机/设备双 WebSocket 通道，保留 HTTP 管理接口。
- 2026-08-31：完成 G1-G6 实现；App 数据库升级到 18，加入 Windows 目标、relay 客户端、AI 工具路由、状态仪表盘和服务器添加入口；完成 Node.js 语法检查、Agent CLI 检查、relay 本地 WebSocket 闭环及 75 个 Flutter 关键测试。
- 2026-08-31：修复协议收尾问题：WebSocket 帧上限统一为 16 MiB 以覆盖 8 MiB 文件写入；手机断线在调用期限内用原 request ID 续接；校验手机 URL 设备 ID 与 hello 一致；恢复 Windows 独立仪表盘入口。
- 2026-08-31：版本更新为 `1.0.5-beta.3+47`，release APK 使用数据盘构建并通过 manifest 与 SHA-256 校验；GitHub Pre-release 已创建并上传 APK，更新清单已同步。
- 2026-08-31：补齐 relay 一键安装入口；部署脚本复制 `package-lock.json`，默认仅监听 `127.0.0.1:8787`，使用独立 Compose 项目且不执行 `--remove-orphans`，不会主动修改现有网站或其他 Compose 项目。真实服务器部署尚未在本轮执行。
