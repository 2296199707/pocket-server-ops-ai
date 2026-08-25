# WFL 全项目调查与手机 Agent v1 范围

## 1. 调查结论

WFL Codex Desktop 不是单一 SSH 插件，而是完整的服务端 Agent 工作台。它已经包含：

- Codex `app-server` 对话、模型、供应商、审批、命令执行、Thread、Turn、Goal 和后台任务；
- Claude Code 独立运行时；
- 文件管理、代码编辑、Git、Worktree、项目迁移和浏览器预览；
- MCP、Plugins、Skills、Apps 和 Hooks；
- 地图编辑器、图片生成、Flutter Web 预览和 APK 构建；
- Windows Remote、Creator Worker；
- 多用户、角色权限、项目隔离、配额、备份、恢复、日志和健康检查；
- 蓝绿更新、watchdog、救援窗口、持久 SSH 和临时 SSH。

参考源码：

- `/srv/wfl-codex-desktop/README.zh-CN.md`
- `/srv/wfl-codex-desktop/server.mjs`
- `/srv/wfl-codex-desktop/docs/adr/0002-app-server-conversation-authority.zh-CN.md`

后续项目可以把 WFL 作为完整服务端平台参考，不需要继续维护 OpenCode Relay 作为第二套 Agent 执行引擎。

## 2. 当前项目的处理决定

本次不把 WFL 中转服务器、WFL 服务端持久运行和服务器托管 Agent 接入第一版。

第一版单独放在 `apps/mobile-agent-v1`，保留原 `apps/mobile` 不变。v1 只有一种运行模式：

```text
手机 Agent -> 手机保存的 SSH 凭据 -> 目标服务器
                 |
                 +-> 手机保存的 AI 供应商 API Key
```

AgentLoop、模型请求、工具调用、任务事件、SSH 连接和 Android 前台服务全部在手机端运行。
目标服务器不安装 Agent、不运行 Relay、不保存手机端供应商配置，也不承担任务调度。

## 3. v1 保留能力

- AI 供应商设置、模型读取和连接测试；
- 服务器配置、密码或私钥保存、主机指纹确认；
- 普通对话；
- 服务器 Agent 对话；
- `terminal.exec` 短命令；
- `terminal.start`、`terminal.poll`、`terminal.write`、`terminal.stop` 长任务；
- `file.read`、`file.write`、`file.replace` 文件操作；
- 命令和文件操作的确认模式；
- 任务历史、工具事件、失败状态和断开后的未知状态提示；
- Android 前台服务，保持手机 Agent 在切换应用后继续运行；
- 服务器终端页面和抽拉侧屏入口。

密码和私钥只通过手机安全存储交给 SSH 连接层，不进入 AI 消息、工具定义、工具参数或任务事件。服务器主机密码不会作为 Agent 工具暴露。

## 4. v1 删除能力

- RelayProfile 和中转服务器设置；
- Relay SSH 隧道、Relay HTTP API、SSE 任务订阅；
- OpenCode Relay 任务执行；
- 服务器托管 Agent 安装、卸载、授权公钥和 Docker 安装；
- `runtime` 模式选择；
- 任务中的 `relayId`、托管关系和中转 Token；
- 中转 API 端口和配对 Token；
- 产品运行时的预览模式；预览工具使用的 `PREVIEW_MODE=true` 只在构建 Web 演示包时启用内存数据和固定回复，不属于产品执行模式；
- WFL Desktop 的服务端持久任务、Claude、MCP、插件、地图、图片、APK 和 Windows Worker UI。

这些能力不是永久放弃，而是从 v1 的产品和数据模型中移出，避免第一版同时维护三套执行路径。

## 5. 与 WFL 的后续衔接

v1 先验证手机端 Agent 的核心闭环：

```text
配置供应商 -> 配置服务器 -> 首次确认主机指纹 -> 发起任务
    -> AI 读取状态 -> 执行命令/修改文件 -> 验证结果 -> 保存历史
```

以后接入 WFL 时，保留手机 SSH 传输和安全凭据边界，把当前 `RelayTaskClient` 替换为 WFL WebSocket/RPC 客户端。WFL 的 `/ws` 已有 `windowId`、连接代数、RPC、实时通知和审批响应，但当前移动现场协议文档仍是历史调查规范，不能直接当作稳定移动协议。

中转模式与完整远程 Workspace 也要单独设计：现有持久 SSH 只提供远程命令能力，WFL 的文件、Git、Worktree 和预览默认作用于 WFL 所在服务器。

## 6. v1 验收标准

1. 原 `apps/mobile` 可以独立继续构建；
2. `apps/mobile-agent-v1` 不再出现 Relay 配置、托管安装和运行模式选择；
3. 新建一个手机任务时只需要选择 AI 供应商、目标服务器、工作目录和执行确认方式；
4. Agent 能通过手机 SSH 完成命令执行、长任务轮询、文件读取、文件写入和文本替换；
5. 首次连接必须确认主机指纹，之后不改变已保存指纹；
6. 手机密码、私钥和 API Key 不会出现在任务事件正文；
7. Android 任务启动前台服务，停止或结束后释放 SSH 和进程资源；
8. 仅运行 Dart 分析、现有 Agent/SSH/控制器/聊天定向测试和 APK 构建检查，不运行无关的完整测试套件。

## 7. 预览构建边界

`tool/build_preview.sh` 会用 `PREVIEW_MODE=true` 构建一个不访问真实供应商和服务器的 Web 演示包。它使用内存数据库、演示供应商和固定回复，只用于检查页面交互；Android 正式构建不带这个开关，产品运行也没有第三种执行模式。

Android 前台服务只负责在手机进程仍然存活时提高任务存活概率并显示运行通知，不包含 Dart Agent 的独立恢复逻辑。进程被系统终止后，任务保持 `unknown`，用户需要重新检查服务器状态，不会自动重放。

## 8. 稳定性边界

为保持第一版实现小而可控，当前边界固定如下：

- Agent 每轮最多 64 个模型步骤和 128 次工具调用。模型或网络在已执行远端操作后出错，或者达到上限，任务显示 `unknown`，提示人工检查，不自动重放；
- AI 请求严格使用 Responses API，并启用官方 server-side compaction。手机不猜测模型 token 窗口，也不按 1 MiB 或字符数硬截断响应；供应商不支持 `/responses` 或 compaction 参数时直接报错，不自动改走 Chat Completions；
- Responses 返回的 reasoning、function call 和加密 compaction output item 原样保存到任务事件；出现 compaction 后，下一次请求和重启恢复保留最新 compaction item，并按官方建议丢弃它之前的旧输入；手机不自行生成摘要、解密或修改 opaque item；
- `terminal.exec` 最多运行 2 分钟；长命令使用 `terminal.start` 系列工具，并且必须在当前任务结束前完成或停止。任务结束会停止仍由手机托管的进程并释放 SSH；确需持续运行的服务由服务器自身的服务管理器接管；
- 多个手机 Agent 任务可以并发运行，每个任务独立持有模型请求、SSH 连接和取消状态；同一服务器和工作目录的远端写入工具按顺序执行，读操作和不同工作目录仍可并发；逐项确认请求按顺序显示并标明任务名称；Android 前台服务按 `taskId` 跟踪活动任务，最后一个任务结束后才停止；
- `terminal.exec` 和 `terminal.poll` 不再静默丢弃固定大小的 stdout/stderr；长进程继续通过偏移增量读取，任务释放时清理手机端进程缓存；
- `file.read` 使用字节 `offset`/`length` 分页，单页最多 1 MiB，并返回 `next_offset`、`eof` 和可用的总字节数；文件本身没有 4 MiB 硬上限。文件写入先写同目录临时文件，再用 SFTP rename 替换目标，网络中断不会把目标文件截断成半文件；
- 服务器仪表盘默认使用手机 SSH 按需读取基础信息；用户点击后可把 `mobile-agent-status` 安装到自己的 `~/.local/bin`，脚本只在刷新时执行，不安装服务、不形成服务器端持久 Agent；
- 文件管理器通过 SFTP 浏览目录和读写 UTF-8 文本文件，不能把手机保存的 SSH 密码、私钥或 API Key 交给服务器脚本；
- 任务事件不再截断长输出、文件内容、工具参数和 Responses 原始 output item；SQLite 仍受设备剩余存储空间约束；
- Agent 的步骤数和工具调用数仍是任务控制边界，不是供应商协议回退或权限模型。Agent 仍可按工具定义执行服务器命令和文件操作，确认模式由任务设置决定。
