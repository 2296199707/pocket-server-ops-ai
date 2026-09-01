# Windows 电脑连接进度

## 目标

Goal：`01a02f79-5a29-7f70-bf38-2ffb76d5f034`

为 PocketServerOps AI 增加第一版 Windows 电脑连接能力：手机从“服务器添加”进入
电脑配置，Windows 端安装后台 Agent 后，可以经中转服务器或 Tailscale 直连执行
PowerShell、读写文件、启动后台任务并读取基础状态。

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
| G8 | 手机生成配对资料、Windows 独立 EXE 首次配置和登录启动 | 已完成（Windows 构建与真机未验证） |
| G9 | 手机选择已绑定 SSH 服务器上传离线包、复制 AI 提示词并保存配置 | 已完成（真实 Windows 端未验证） |
| G10 | Tailscale/局域网直连 Windows Agent，不经过中转服务器 | 已完成（自动化闭环，真机待验证） |

## Tailscale 直连（2026-09-01）

直连采用最小实现，不把 Tailscale SDK 或账号管理集成进 App。用户分别在 Android
和 Windows 安装 Tailscale 并登录同一网络；手机保存电脑的 Tailscale IPv4 地址，
例如 `http://100.64.0.10:8788`。Windows Agent 在 `0.0.0.0:8788` 提供与现有手机
relay 客户端兼容的接口：

```text
GET /v1/health
GET /v1/devices/<device_id>/status
WS  /v1/devices/<device_id>/ws
Authorization: Bearer <device_token>
```

直连继续复用现有 PowerShell、文件、后台进程、状态工具以及手机断线后用原
`request_id` 续接的逻辑。HTTP 明文只用于 Tailscale 或受信局域网，链路加密由
Tailscale 提供；不要把 Agent 端口映射到公网。

手机端没有新增数据库列：Windows `ServerProfile.authType` 保存 `relay` 或
`direct`，旧配置缺省保持 `relay`；`relayUrl` 在直连模式保存电脑地址。中转切到
直连时保留原中转 Token 的安全存储引用，之后切回中转可以继续使用；直连首次创建
没有中转 Token，改为中转时才要求填写。直连鉴权直接读取 Agent Token，中转 API
Token 不参与直连，也不会发送给 AI。

Windows 配对 JSON 在直连模式包含 `connection_mode=direct`、设备 ID、Agent
Token、工作目录、监听地址和端口，不包含 relay 地址。独立 EXE 和源码安装脚本均
支持该格式。第一版不会在直连失败后偷偷改走中转；连接方式由用户明确选择，失败时
返回 Windows Agent 的连接或鉴权错误。

## 简化配对决定（2026-08-31）

旧流程要求 Windows 端安装 Node.js 22、运行 PowerShell 安装脚本，并手动生成
设备 ID 和 Agent Token。新流程由手机 App 在新增 Windows 目标时自动生成设备
ID 和 Agent Token；保存后提供“电脑配对信息”和“复制配置”，复制内容只包含：

```text
relay_url
device_id
device_token
working_directory
```

中转 API Token 仍只保存在手机安全存储，不进入电脑配对 JSON，也不发送给 AI。
已有 Windows 配置仍可编辑，重新生成设备 ID 或 Agent Token 后保存即完成重新配对。
手机保存 Windows 目标时会先用中转 API Token 登记设备；中转暂时不可用时仍保存
本地配置，并在配对信息中提示稍后从电脑菜单重新测试。

电脑端新增 Node.js SEA 单文件构建流程：先用 esbuild 把 ESM Agent 打成 CommonJS
bundle，再用 Node 22 官方 Single Executable Applications 和 postject 注入
Windows x64 Node 运行时。独立 EXE 首次运行支持粘贴手机复制的 JSON，也支持逐项
填写；配置保存在当前用户的 `%LOCALAPPDATA%`，并注册登录启动任务。旧的
`install.ps1` 和 `config.json` 运行方式继续保留。

GitHub Actions 文件为 `.github/workflows/windows-computer-agent.yml`，beta
分支修改电脑端文件时自动构建并上传 30 天 artifact。当前没有 Windows 真机，
所以 EXE 启动向导、任务注册、PowerShell 执行和真实 WSS 连接仍需在 Windows
环境做一次验收。

## 中转服务器安装流程（2026-08-31）

手机端不再通过 SSH 直接执行 relay 安装脚本。用户在“中转服务器设置”中选择一台
已经绑定的 SSH 服务器并确认后，App 只上传内置的二进制离线包：

```text
/tmp/pocket-server-ops-computer-relay.tar.gz
```

上传完成后，App 自动复制一段不包含密码、私钥或 `RELAY_API_TOKEN` 的安装提示词。
用户把提示词交给连接着这台服务器的 AI，由 AI 在当前服务器检查环境、解压安装包、
执行 `deploy.sh` 并返回健康检查结果。提示词明确要求 AI 不连接其他服务器、不执行
`docker compose --remove-orphans`。用户已经选择专属中转服务器并确认上传后，AI
可以检查并最小修改当前服务器的 Caddy/Nginx，为指定公网路径补充 HTTP 与 WebSocket
反向代理。修改前需要备份并校验配置，只能改 relay 路径，不能覆盖其他路由或关闭
现有网站；代理容器化时还要检查其与 relay 的网络可达性，最后验证公网健康检查。

AI 完成安装后，用户点击“我已让 AI 安装，读取配置”。App 再通过已绑定 SSH 连接
优先读取 `/www/pocket-server-ops-computer-relay/.env`，旧版部署才回退读取
`/opt/pocket-server-ops-computer-relay/.env` 中的 `RELAY_API_TOKEN`，并将 Token
写入手机安全凭据存储，同时保存中转服务器 ID 和公网地址。Token 不写入任务、对话、
普通设置或 AI 请求，也不会通过提示词显示给 AI。

如果目标服务器已有中转目录，安装脚本会复用该目录；没有目录时默认使用
`/www/pocket-server-ops-computer-relay`。部署仍使用独立 Compose 项目，默认监听
`127.0.0.1:8787`，不会停止其他 Compose 项目或自动修改现有网站。

公网地址必须由用户确认，因为服务器上的 `.env` 只知道监听端口，不知道域名和现有
Caddy/Nginx 的路径。App 会根据 SSH 主机名建议
`https://主机名/computer-relay`，用户可直接修改。Windows 电脑配置页可以直接使用
读取并保存后的中转配置；已有旧部署仍可手动填写中转地址和 Token。

上传确认框显示唯一目标服务器、`username@host:port`、公网地址和远程包路径，并提醒
供应商可能限制中转服务。用户取消后不会建立上传连接；流程只操作当前选中的一台 SSH
服务器，不会遍历其他已绑定服务器，也不会自动给其他服务器安装 relay。

上传成功后的待安装状态会写入 App 本地设置，只保存目标服务器 ID 和公网地址；设置
抽屉关闭、返回对话页或 App 重启后仍会显示“安装包已上传”和“我已让 AI 安装，读取
配置”入口。提示词根据固定远程路径重新生成，不把 Token 或完整提示词重复写入设置。
读取配置成功后，待安装标记会清除，后续直接使用已保存的中转配置。

## 实际部署排障记录（2026-09-01）

一次真实部署中，Caddy 容器只连接 `beast-public`，relay 只连接自己的 Compose 默认
网络，导致 Caddy 无法解析 `computer-relay`，手机登记和 Windows WebSocket 均返回
502。修复方式是让 relay 同时保留默认网络并加入代理所在的外部网络，不需要覆盖或
重写现有 Caddy 配置。修复后代理容器可以解析并访问 relay，公网
`/computer-relay/v1/health` 返回 200，未带 Token 的登记请求返回预期的 401。

该服务器还同时残留 `/opt` 和 `/www` 两套部署，且 Token 不同；实际运行容器使用
`/www`。旧 `/opt` 目录在确认没有运行容器引用后被改名保留为停用备份，App 的读取
顺序也改为 `/www` 优先、`/opt` 回退。后续安装 AI 必须检查代理容器与 relay 的网络
可达性，并在交付前验证公网健康检查，不能只验证 relay 容器内部健康状态。

公网修复后发现 Windows Agent 已认证，但手机执行“测试连接”会将其显示为离线。
根因是 App 在读取状态前重复调用设备登记，而 relay 的旧登记实现会替换设备对象并
清空 `lastSeen`；已连接的 WebSocket 仍更新旧对象，状态接口因此持续返回离线。App
现已改为测试时只读取状态，登记只在保存或重新配对时执行。relay 的登记接口也改为
幂等：设备 ID 与 Token 相同时只更新名称并保留连接、心跳和能力状态；Token 真正
变化时才关闭旧连接并等待电脑使用新凭据重新认证。修复已同步到内置离线包和实际
部署，电脑 Agent 在 relay 重建后自动重连并恢复在线。

离线包中的 `Dockerfile`、`package.json`、`package-lock.json`、`server.mjs` 和
`compose.yaml` 固定为可读权限，`deploy.sh` 为可执行权限。部署脚本复制到
`/www/pocket-server-ops-computer-relay` 后会再次校正这些非敏感运行文件；`.env`
仍明确保持 `600`，不会为了修复容器读取权限而放宽 Token 文件权限。Dockerfile 内部
也使用 `COPY --chmod=644`，保证镜像以 `node` 用户运行时可以读取 `/app/server.mjs`。

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

- Windows Agent 独立 EXE 使用 Node.js 22 SEA 运行时；源码运行和旧安装脚本仍要求
  Node.js 22。没有 Windows 构建环境时不伪装成已验证的 MSI 或签名安装包。
- App 当前 SSH relay 连接代码不能直接复制到规范项目作为 Windows 通道客户端，
  已改为独立的 WebSocket 协议客户端。
- relay 的生产部署仍是容器内 HTTP；对公网使用时必须由现有反向代理终止 TLS，
  并把手机地址配置为 `https://`、Windows Agent 地址配置为 `wss://`。第一版
  不在 relay 容器内重复实现证书管理。
- 没有 Windows 真机和 WSS 反向代理环境，因此 PowerShell 执行、Windows 磁盘
  查询、登录启动任务和真实断线重连仍需用户环境验证；Node.js 语法、Agent CLI、
  relay 本地 WebSocket 闭环已经验证。
- Tailscale 直连已完成本机 HTTP/WS 自动化闭环，但 Windows 防火墙首次放行、真实
  Tailscale 地址访问和 Android 后台网络切换仍需真机验收。

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
- 2026-08-31：在临时中转机验证实际部署；Docker 默认构建网络无法解析 npm registry，Compose 构建阶段改用 host 网络；relay 健康接口和现有网站均验证通过。
- 2026-08-31：简化 Windows 配对流程；手机自动生成设备 ID/Agent Token，提供不含中转 API Token 的电脑配对 JSON；Windows Agent 增加首次向导、登录启动任务和 Node 22 SEA 单文件构建脚本，保留旧 PowerShell 安装方式。
- 2026-08-31：补齐手机端中转服务器设置；服务器页面可选择已绑定 SSH 服务器一键安装/更新 relay 并自动读取 Token，复用已有 `/opt` 或 `/www` 部署目录，Windows 配置可直接使用已保存中转配置。
- 2026-08-31：中转安装增加安装前确认；确认框显示唯一目标服务器、公网地址并提醒供应商限制，取消后不建立安装 SSH 操作。版本更新为 `1.0.5-beta.4+48`，release APK 使用数据盘构建并核对 manifest；产物位于 `/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.5-beta.4-release.apk`，大小 `80226547` 字节，SHA-256 为 `1c33408bb4439b7613bc4ae142d134bed83efd88c9795167264ae86ae32745ef`。
- 2026-08-31：修复 Windows Agent CI 在 SEA 注入阶段直接执行 `npx.cmd` 导致的 `spawnSync EINVAL`；构建脚本现在直接调用已安装的 `postject` JavaScript 入口，避免 Windows shell shim 问题。
- 2026-08-31：中转安装改为手机上传内置离线包并复制 AI 安装提示词；手机不再直接执行安装脚本，安装完成后再通过 SSH 单独读取 `.env` 中的 Token。版本更新为 `1.0.5-beta.5+49`，控制器整套 59 项测试、静态分析和数据盘 APK 构建通过，APK 内已确认包含离线包资源。
- 2026-08-31：创建并上传 GitHub Pre-release `v1.0.5-beta.5`，同步 `updates/releases.json`，使 App 的 GitHub Raw 和 jsDelivr 更新渠道可以发现该版本。
- 2026-08-31：修复上传安装包后离开设置抽屉导致入口丢失的问题；待安装目标和公网地址持久化，重新打开抽屉可恢复提示词和安装后配置读取入口，并增加重启恢复测试。
- 2026-08-31：修复 relay 运行文件因 `umask 077` 或压缩包权限过严导致 `node` 用户无法读取 `/app/server.mjs`；非敏感文件统一可读，`.env` 继续为 `600`，并重新生成离线包。
- 2026-08-31：修复电脑“测试连接”的错误诊断；relay 返回设备在线状态时，离线设备显示“中转服务器连接成功，但 Windows Agent 未在线”，网络连接失败、HTTP 错误和未完成配对分别显示对应原因及状态码。
- 2026-08-31：版本更新为 `1.0.5-beta.6+50`；主页面左侧 Drawer 的边缘滑动触发区域调整为 72px，并显式开启向右滑动打开侧栏。
- 2026-08-31：中转设置增加“中转已安装，跳过上传并读取配置”入口；换手机后选择已绑定 SSH 服务器即可直接读取 `/opt` 或 `/www` 安装目录中的 Token，不要求重复上传离线包。
- 2026-08-31：版本更新为 `1.0.5-beta.7+51`，发布中转设置的跳过上传入口；原有离线包上传和 AI 安装流程保持不变。
- 2026-09-01：Windows 目标设置页增加中转 SSH 服务器选择；点击 Token 刷新后通过选定服务器读取已安装 relay 的 `.env`，切换服务器后要求重新刷新，避免复用旧 Token。版本为 `1.0.5-beta.8+52`，控制器与设置页相关测试 73 项通过；Release APK 位于 `/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.5-beta.8-release.apk`，大小 `80268121` 字节，SHA-256 为 `633931205cc70b9ff8475aba89839053042656ee61ebc930b098668c5863862d`；GitHub Pre-release 已创建：`https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.5-beta.8`。
- 2026-09-01：版本更新为 `1.0.5-beta.9+53`；修复 Windows Agent 在线状态被手机测试连接重复登记清空的问题，中转安装提示词允许在专属服务器上完成反向代理接入，Token 读取改为 `/www` 优先，并同步更新内置 relay 离线包。控制器与中转客户端相关测试 64 项通过，本次修改文件静态分析无问题；Release APK 位于 `/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.5-beta.9-release.apk`，大小 `80268237` 字节，SHA-256 为 `58d01e28d61c5ef40975961ea1d28e0d816a6887ea45e0bd5548ba45813d3483`；GitHub Pre-release：`https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.5-beta.9`。
- 2026-09-01：Windows Agent 增加 `direct` 连接模式和带 Agent Token 鉴权的本地
  HTTP/WebSocket 服务；手机 Windows 设置增加“中转 / Tailscale 直连”切换，直连
  复用全部电脑工具且不要求中转 API Token。Windows Agent 直连端到端测试覆盖未
  授权拒绝、状态接口、WebSocket 鉴权和一次真实 `status` RPC；相关 Flutter 测试
  84 项通过，单文件 bundle 检查通过。版本更新为 `1.0.5-beta.10+54`；Release APK
  位于 `/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.5-beta.10-release.apk`，
  大小 `80448525` 字节，SHA-256 为
  `d670716101cc957055d04f5d2f94bcb8f9c70ff17ab4b961f3a0399b36d9e912`。
  Windows/Tailscale 真机连接待发布后验证。
- 2026-09-01：修复 Windows Agent relay 调用脱离事件回调后可能产生未处理 Promise、
  心跳定时器异常可能直接退出的问题；异常调用现在关闭当前连接并交给既有重连循环，
  独立 EXE 还会把未处理异常记录到 `%LOCALAPPDATA%\PocketServerOps\computer-agent\agent-error.log`。
  Windows Agent 版本为 `1.0.0-beta.4`；回归测试 2 项和 bundle 检查通过。
- 2026-09-01：修复 Windows Agent 首次 `--setup` 的可选系统配置步骤：
  `schtasks` 无法创建登录启动任务，或 `icacls` 无法收紧配置文件权限时，不再把
  配置失败当成 Agent 启动失败；配置先保存，Agent 会继续运行并明确提示登录启动
  未注册。Windows 命令错误不再直接按 UTF-8 打印系统代码页输出，避免乱码。
  Windows Agent 版本更新为 `1.0.0-beta.5`；配置写入、可选步骤失败和运行时重连
  仍待 Windows 真机确认。
- 2026-09-01：根据 Windows 真机日志修复后台进程 stdin 的 `write after end`：
  `process.write` 现在识别已结束或已完成的 stdin，并把竞态写入失败作为普通工具
  错误返回；后台 stdin 增加错误监听，避免 Node 未捕获流错误导致 EXE 退出。
- 同一日志还确认 `exec` 的空字符串 `input` 会触发一次重复 `stdin.end()`；现在按
  “参数是否存在”而不是字符串真假判断是否保留 stdin，并捕获一次性命令的 stdin
  错误，避免空输入任务再次退出 Agent。
- 该修复版本更新为 Windows Agent `1.0.0-beta.6`；源码回归测试、语法检查和
  bundle 检查通过，Windows 真机仍需用 beta.6 EXE 验证。
- 2026-09-01：开始完善 Windows 电脑客户端；保留 Node Agent 作为连接和执行核心，
  增加轻量原生主界面与托盘入口。主界面显示连接状态、持久运行消息和错误提示，
  支持从界面粘贴手机配对 JSON、打开日志和配置目录；新增 `--setup-stdin
  --configure-only` 供图形界面安全写入配置，不把 Token 放入命令行参数。Windows
  客户端与 Agent 一起打包，协议和手机端工具保持不变，版本更新为 `1.0.0-beta.7`。
- 2026-09-01：首次 Windows CI 因主界面两个控件在辅助方法中初始化却声明为
  `readonly`，触发 C# `CS0191`；已做最小修复并重新推送。Windows CI
  `33510053661` 构建成功，产物已下载到数据盘
  `/www/mobile-agent-tooling/windows-agent-artifacts/v1.0.0-beta.7/`，压缩包内含
  Agent EXE、Client EXE 和 README，ZIP 可正常读取。当前仍未宣称 Windows 真机
  验收完成；登录启动、托盘、PowerShell 执行和真实中转连接需要在用户 Windows
  环境验证。
