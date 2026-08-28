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
- 命令和文件操作的执行前确认、自动审查后执行和自由执行模式；
- 手机项目外文件工具：AI 只能先请求用户授权，授权范围仅保存在当前对话内；项目文件和
  已保存的凭据、数据库、应用内部目录分开处理；
- 可选的自动审查：由用户在对话设置中指定独立供应商和模型，审查失败转人工确认；
- 任务历史、工具事件、失败状态和断开后的未知状态提示；
- Android 前台服务，保持手机 Agent 在切换应用后继续运行；
- 服务器终端页面和抽拉侧屏入口。
- 手机项目网页预览：仅在项目文件夹内提供 HTML/CSS/JavaScript/静态媒体预览，收集控制台和页面错误，
  并支持 `local.test_web` 静态资源检查；不提供手机 Node/Python/Flutter 运行时。

密码和私钥只通过手机安全存储交给 SSH 连接层，不进入 AI 消息、工具定义、工具参数或任务事件。服务器主机密码不会作为 Agent 工具暴露。

## 4. v1 删除能力

- RelayProfile 和中转服务器设置；
- Relay SSH 隧道、Relay HTTP API、SSE 任务订阅；
- OpenCode Relay 任务执行；
- 服务器托管 Agent 安装、卸载、授权公钥和 Docker 安装；
- `runtime` 模式选择；
- 任务中的 `relayId`、托管关系和中转 Token；
- 中转 API 端口和配对 Token；
- 产品运行时的演示预览模式；构建工具使用的 `PREVIEW_MODE=true` 只在构建 Web 演示包时启用内存数据和固定回复，
  不属于产品执行模式。手机项目的本地网页预览属于 v1 的实际功能，不依赖这个演示开关；
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
- 供应商协议由用户明确选择 Responses 或 Chat Completions。Responses 按 Codex 规则使用 `context_window`（缺失时取 `max_context_window`）、有效窗口 95% 和自动压缩阈值 90%；当前普通 Responses 请求把该阈值发送为官方 `context_management`，由供应商返回 opaque compaction item，APP 原样保留并裁剪其之前的请求项。手动压缩在独立 endpoint 不可用时才使用同一供应商的普通 `POST /responses`，把 system 指令单独放入 `instructions`，追加 Codex 压缩提示词生成本地摘要；该手动请求会关闭 `context_management`。不会因为供应商不提供 `/responses/compact` 就切换到 Chat Completions。Chat Completions 保持独立协议，只解析其 usage，不伪装成 Responses；
- `/models` 同时兼容 OpenAI 风格的 `data` 列表和 Codex 风格的 `models` 列表。返回的模型元数据按模型保存到供应商配置；只有模型目录给出真实限制时才更新已有值，普通只返回模型 ID 的接口不会覆盖手动元数据；
- 每次模型响应保存 `last_token_usage` 对应的当前用量和 `total_token_usage` 对应的累计用量，并记录 `model_context_window`、`auto_compact_token_limit` 和压缩次数。底部上下文百分比只在窗口和 usage 都真实可用时显示，否则显示 `--`；分页或尚未加载的聊天历史不会影响该统计；
- 手机不猜测模型 token 窗口，不按 Base64 字节数、字符数或固定几 MiB 推断上下文。Responses、Chat Completions 和生图接口的正常响应默认都不设本地字节上限；64 KiB 只用于截取供应商 HTTP 错误正文，不影响正常模型响应和图片；
- Responses 返回的 reasoning、function call 和加密 compaction output item 原样保存到任务事件；当前本地压缩则保存最近用户文本和模型返回的 Codex 摘要为 synthetic user item。旧图片/文件仍保留在附件存储中，但不会在本地压缩事件中重新塞入模型上下文，摘要负责承接其已读信息。压缩事件会成为下一次请求和重启恢复的上下文起点；手机不解密或修改 opaque item，也不会因此删除本地完整事件和附件原文件。对话配置（工作模式、项目、服务器或工作目录）变化只追加 `task.context_changed` 变更提示并保留模型历史，不再创建硬历史边界；
- 每轮上传的图片和文字仍属于同一条用户消息。原始附件保存在应用私有文件目录，SQLite 事件只保存附件 ID、名称、MIME 和大小；构建下一次模型请求时，再把当前有效模型上下文需要的附件恢复成 Responses `input_image`/`input_file` 或 Chat Completions 对应的多模态内容。附件物理独立存储不代表从 AI 上下文移除；
- 应用启动只读取对话任务摘要，不再读取所有任务的完整事件和图片。打开对话时从 SQLite 读取最近 40 条事件，“加载更早记录”继续做数据库分页；这只是 UI 和内存加载策略，不改变发送给模型的有效上下文。历史附件点击后才读取预览，完成 compaction 的旧图片仍保留在本地。新建对话只创建新的空任务，不清除已有对话或历史；
- `terminal.exec` 最多运行 2 分钟；长命令使用 `terminal.start` 系列工具，并且必须在当前任务结束前完成或停止。任务结束会停止仍由手机托管的进程并释放 SSH；确需持续运行的服务由服务器自身的服务管理器接管；
- 多个手机 Agent 任务可以并发运行，每个任务独立持有模型请求、SSH 连接和取消状态；同一服务器和工作目录的远端写入工具按顺序执行，读操作和不同工作目录仍可并发；逐项确认请求按顺序显示并标明任务名称；Android 前台服务按 `taskId` 跟踪活动任务，最后一个任务结束后才停止；
- `terminal.exec` 和 `terminal.poll` 不再静默丢弃固定大小的 stdout/stderr；长进程继续通过偏移增量读取，任务释放时清理手机端进程缓存；
- `file.read` 使用字节 `offset`/`length` 分页，单页最多 1 MiB，并返回 `next_offset`、`eof` 和可用的总字节数；文件本身没有 4 MiB 硬上限。文件写入先写同目录临时文件，再用 SFTP rename 替换目标；支持目标替换的服务器走原子替换路径。若服务器拒绝这种 rename，操作直接失败并尽力清理临时文件，保留原文件，不再退回直接 truncate 写入，因此不承诺所有服务器都支持原子替换；
- 服务器仪表盘默认使用手机 SSH 按需读取基础信息；用户点击后可把 `mobile-agent-status` 安装到自己的 `~/.local/bin`，脚本只在刷新时执行，不安装服务、不形成服务器端持久 Agent；
- 文件管理器通过 SFTP 浏览目录和读写 UTF-8 文本文件，不能把手机保存的 SSH 密码、私钥或 API Key 交给服务器脚本；
- 任务事件不再对普通 assistant 文本、文件内容、工具参数和 Responses 原始 output item 施加全局截断；工具结果若有真实模型 `truncation_policy`，只按该策略生成保留结构和省略标记。AI 生图结果先保存为附件，工具事件只记录引用，不写入完整 `data_url`。SQLite 和附件文件仍受设备剩余存储空间约束；
- Agent 的步骤数和工具调用数仍是任务控制边界，不是供应商协议回退或权限模型。Agent 仍可按工具定义执行服务器命令和文件操作，确认模式由任务设置决定。
- 项目文件读取、写入和下载会解析现有路径中的符号链接；指向项目根外部的链接被拒绝。
- 项目外手机路径必须经过用户确认，读授权和读写授权分开；授权不写入数据库，应用重启、删除对话或切换对话目标后失效。
- `auto_review` 只审查需要审批的工具。审查供应商或模型未配置、协议错误、返回格式错误或请求失败时转人工确认；不会静默切换 Responses 和 Chat Completions。

## 9. 服务器权限与沙盒

第一版不增加一个看起来像“只读”但实际仍能通过任意 Shell 绕过的服务器沙盒开关。手机
SSH 始终使用用户配置的原账号和原权限；非 root 账号不会被伪装成完整运维权限，也不会在
沙盒不可用时静默切回另一种连接方式。

后续如果加入服务器隔离，必须把它作为可检测、独立、可随时切回的运行环境：先确认实际
隔离能力和账号权限，再允许启用；原始 SSH 配置保留，切回时不修改或丢失原权限。当前版本
只实现手机项目边界和项目外文件的人工授权，不把未实现的服务器沙盒展示成已完成能力。

## 10. 2026-08-27 官方 Codex 源码复核（冻结结论）

本节记录本轮审查的最终结论。到此停止继续重复查找；后续按本节的优先级修改和验证，不能再因为上下文、附件或供应商兼容问题反复重新猜测设计。

### 10.1 核实依据

- 官方 Codex 源码快照：`/www/mobile-agent-tooling/openai-codex-research.oZMeyF`，commit `f5420174dafba153913a3e697f89002c338dfd7e`。
- 官方压缩文档：<https://developers.openai.com/api/docs/guides/compaction.md>。
- 重点源码位置：`codex-rs/tui/src/token_usage.rs`、Responses 历史和上下文管理模块、命令输出缓冲模块、进程管理模块以及 Guardian review/session/run 模块。

已确认的官方行为如下：

1. 官方 Responses 文档同时定义普通请求的 `context_management` 服务端压缩和独立的 `POST /responses/compact`；Codex 源码按供应商能力选择路径。Mobile 普通 Responses 请求按当前模型阈值发送 `context_management`，并原样保留服务端返回的 opaque compaction item；独立 endpoint 不可用时，手动压缩使用普通 `/responses` 追加 `SUMMARIZATION_PROMPT`，把模型返回文本写成 `CompactionSummary` 用户项。Chat Completions 不发送该字段，也不自动回退。普通请求中的工具调用和 reasoning 仍属于 `input` 历史项；本地手动压缩请求不提供工具定义，system 指令通过 `instructions` 传入。
2. Codex 会规范化历史：为缺少 output 的 function call 补 `aborted`，清理孤立 output，按模型 `input_modalities` 删除不支持的图片和音频，并对工具输出做语义化截断。
3. 模型能力不是由客户端猜测。官方模型元数据至少涉及 `default_reasoning_level`、`supported_reasoning_levels`、`input_modalities`、`truncation_policy`、`context_window`、`max_context_window`、`auto_compact_token_limit` 和 `effective_context_window_percent`。
4. 有效上下文窗口默认按原窗口的 95% 计算，自动压缩默认在原始上下文窗口约 90% 处触发。界面剩余上下文百分比使用官方 TUI 的 12,000 token baseline，而不是用字符数、Base64 字节数或固定几 MiB 猜算。
5. 官方命令输出采用 head/tail 缓冲，默认量级约 1 MiB；它不是把远程 stdout/stderr 无限写进模型上下文或本地事件库。进程管理还包含进程数量、状态、交互锁、退出监听和清理。
6. Guardian 明确区分 prompt 构建失败、请求失败、解析失败、超时和取消。Responses 只对明确可重试的连接错误、429、5xx 等执行带退避的重试；收到 `response.completed` 后立即结束 SSE 读取，不等待连接关闭或 `[DONE]`。

### 10.2 当前工作树已有的基础

当前 `beta` 分支的基础和本轮工作树修改已经覆盖以下能力；这些能力仍以定向测试和真实供应商协议结果为准：

- Responses 和 Chat Completions 是用户明确选择的两种协议路径；不应把协议不兼容自动降级成另一种协议。
- 历史事件和附件已经有分离存储的结构，附件恢复后仍应作为当前消息上下文的一部分发送给模型。
- 对话界面已经采用最近事件加载和“加载更早记录”的分页思路；这只控制 UI 和手机内存，不应改变 Agent 需要的有效上下文。
- 已有任务步骤数、工具调用数、取消状态、前台服务和 SSH 工具边界，可继续作为任务控制边界。
- 已有模型目录和上下文相关字段，只有真实返回或用户明确配置的模型元数据才会参与请求和 UI 判断。

### 10.3 本轮已完成的对齐

以下项目已在当前工作树实现，并由关键定向测试覆盖：

1. `response.completed` 到达后结束 SSE 读取，并保留 completed output item。
2. Responses 历史保留 reasoning、function call 和 opaque compaction item；缺失的 function call output 补 `aborted`，孤立 output 清理，附件按真实输入模态处理。
3. 模型元数据包含推理等级、输入模态、truncation policy、上下文窗口和压缩阈值；未知能力不会被客户端猜测。
4. 正常模型响应不使用全局 64 KiB 限制；HTTP 错误、工具结果和 SSH 输出分别采用独立策略，结构化工具结果保持 List/Map 顶层形状并标出省略范围。
5. SSH stdout/stderr 使用有界 head/tail 缓冲，长驻进程有数量限制、TERM/KILL 停止和任务结束清理。
6. Guardian 审查失败记录 `review.failed`，不会伪装成通过；只有当前用户明确确认才继续。
7. 任务取消、远程写入排队、事件持久化、附件独立存储和清理空间分页已补齐关键生命周期。
8. 取消任务时只把真正开始的远程写操作标记为未知；本地工具、只读远程工具不会误报远程副作用。
9. 附件 ID 读取、发送和历史恢复都会校验任务归属；同一供应商的模型、Base URL、协议、上下文/压缩元数据或工具输出策略变化，以及未固定供应商任务切换默认供应商，都会记录新的 `task.context_changed` 事件。工作模式、模式、项目、服务器目标或工作目录变化同样只写入 `history_boundary: false`，保留普通文本、文件、图片和工具结果，并追加配置变更提示；不会因为配置切换截断模型历史。跨供应商重建请求时只移除不能跨供应商复用的 reasoning/compaction 等 opaque 状态，并追加 Codex 风格的 model-switch developer 内容。仅推理强度变化不会切断历史。
10. 工具结果进行第二次限制时会保留已有 List/Map 结构和省略标记，并累计真实省略数量；不把普通模型响应统一限制为 64 KiB。
11. 每次手机 Agent 轮次生成独立 `turn_id`，持久化到用户、助手、工具和任务状态事件；
    取消记录、确认等待、流式文本和状态更新都会校验当前轮次，迟到回调不能清理或覆盖新轮次。
12. 服务器 Agent 会按官方顺序查找当前工作目录项目根到工作目录的
    `AGENTS.override.md`/`AGENTS.md`，没有 `.git` 根标记时只读取当前目录；项目指令最多读取
    32768 字节，作为 system prompt 的项目文档片段传入。
13. 已覆盖“首轮 Responses 成功、下一轮返回 503、切换到 Chat Completions 后继续”的回归测试：失败轮次的用户文本和首轮普通回复会进入第三次请求，Responses 的 opaque 状态不会跨供应商发送，且不会因为供应商切换被旧的压缩边界截断。另有回归测试确认切换后新供应商产生的 compaction 会重新成为后续请求的历史起点，不会永久关闭自动压缩。

### 10.4 当前仍需处理的项目

这些项目不属于本轮已完成的核心修复，后续按实际需求处理：

1. 同一运行中的追加输入尚未实现官方 `turn_steer` 队列；当前继续发送会提示任务运行中。
2. 本地编辑、网页检查和部分远程 `readFile`/下载/replace 路径仍可能整文件读入；分页读取工具本身不受此影响。
3. 模型请求尚未加入官方式的有限重试；远程工具不会自动重放。
4. Responses 响应头诊断信息尚未保存，图片响应也尚未由 App 层传入明确的大小策略。

### 10.5 可以排在第一版关键修复之后的问题

以下问题已记录，属于第二批稳定性整理；除非修复过程中触及，不再继续扩大本轮调查：

- 为同一运行中的对话增加官方式 `turn_steer`/追加输入队列；当前轮次隔离和取消目标校验已经完成。
- 区分 active context、auto-compact scope、full context cap 和 prefill，修正当前近似的上下文统计、压缩计数和历史恢复计数。
- 降低附件恢复时重新 Base64 化造成的内存峰值；修复加载更早事件期间新事件被旧快照覆盖的问题。
- 处理项目路径和远程文件路径检查与读写之间的 TOCTOU 问题；补上项目真正解除绑定的路径，避免 `projectId ?? current.projectId` 保留旧绑定。

### 10.6 明确不属于问题的设计差异

- 手机 Agent 直接通过 SSH 运维服务器，与 Codex Desktop 使用服务端 `app-server` 的部署形态不同，这是当前产品目标，不代表缺少 Codex 能力。第一版不要求目标服务器安装 Agent。
- 附件物理上单独保存在手机私有目录、事件只保存附件 ID，并不等于附件被排除在上下文之外；发送请求时必须按模型能力恢复为图片或文件输入。
- 本地数据库可以保存远多于一次模型上下文的历史，但“历史存储量”不等于“单次请求输入量”。有效上下文仍受真实模型窗口限制，超出后按 Codex 压缩策略管理；不能用手机磁盘容量或“几十 GB 历史”冒充模型上下文窗口。
- 95% 有效窗口、约 90% 自动压缩阈值和 12,000 token 显示 baseline 是 Codex 的上下文管理策略，不是把所有模型强行声明为 258,000 token。供应商可以复用同一策略，但必须提供或明确配置真实模型元数据。
- Chat Completions 不支持 Responses 时直接报错符合当前产品决定。协议由供应商设置明确选择；不做隐式 fallback，也不在供应商设置完成后偷偷改变协议。
- 非 root 账号不等于服务器沙盒。服务器沙盒仍未在第一版实现，不能以“只读”开关或自动换账号制造虚假的安全边界。

### 10.7 文档状态说明

第 8 节“稳定性边界”记录当前第一版的实现约束；10.4 列出的项目是明确的后续缺口，不应被界面宣称为已完成能力。后续仍不得新增未经源码或测试验证的限制数字和兼容行为。

## 11. 2026-08-27 定向复核追加确认（本轮收束）

本节是应本轮继续核查官方源码后新增的确认项。依据仍为官方 Codex 快照
`f5420174dafba153913a3e697f89002c338dfd7e`，重点核对了
`codex-rs/core/src/agents_md.rs`、`codex-rs/core/src/responses_retry.rs`、
`codex-rs/codex-api/src/sse/responses.rs`、`codex-rs/core/src/session/turn.rs`、
`codex-rs/core/src/session/input_queue.rs` 和 app-server 的 `turn_steer`/
`turn_interrupt` 处理。以下均已在当前移动端工作树中定位，不是根据界面猜测。

### 11.1 本轮状态与剩余优先项

1. **远程操作状态判断已修复。** `AgentTool.writesRemoteState` 和实际操作开始回调共同决定
   是否进入 `unknown` 状态；本地工具和只读远程工具不会误报远程副作用。

2. **每轮独立 `turn_id` 已补齐。**
   用户、助手、工具和任务状态事件都带有轮次标识，取消目标、状态更新、流式文本和资源清理
   会校验当前轮次；这解决了取消后的迟到回调串到新轮次的问题，但尚未提供官方
   `turn_steer` 的运行中追加输入队列。

3. **SFTP 写入回退已修复。** `writeFile` 现在只使用同目录临时文件和 rename；rename
   被服务器拒绝时直接失败并清理临时文件，不再对目标文件 truncate 后写入。

4. **服务器工作目录的 `AGENTS.md` 指令加载已补齐最小实现。**
   只读取用户选定工作目录及其 `.git` 项目根范围，优先每层的
   `AGENTS.override.md`，否则读取 `AGENTS.md`，并按官方 `32768` 字节总预算合并到 system prompt；
   没有项目标记时不会把父目录说明带入任务。

### 11.2 第二批稳定性与可观测性缺口

5. **生图取消已接通，响应大小策略仍待配置。**
   `lib/providers/image_generation_client.dart` 和 `lib/app_controller.dart` 的
   `generate`/`download` 都传入当前任务的取消信号；App 层尚未为图片响应配置明确大小上限，
   不应擅自用固定数字代替供应商或用户配置。

6. **清理空间已改为数据库侧分页扫描附件引用。** 清理不再为每个任务一次性载入完整事件；
   仍受设备存储空间和附件文件本身大小约束。

7. **本地文件仍有整文件读取路径。**
   `lib/local/project_files.dart:156-195` 的 `readText`/`replaceText`，以及
   `lib/local/local_preview.dart:275-299,350-357,435-436` 的网页和 CSS 检查，会一次性
   读取文件。当前项目读取工具已经分页，但这些路径仍可能因单个大文件造成手机内存峰值；
   后续应只对编辑、预览和静态检查确实需要的路径增加有界处理，不扩大成全局任意截断。

8. **模型请求没有官方式的有限重试。**
   官方配置示例区分 `request_max_retries = 4` 和
   `stream_max_retries = 10`，并只对明确可重试的连接错误、429、5xx/服务端过载等使用
   退避；取消会打断等待，远程工具不会被自动重放。当前
   `lib/agent/openai_compatible_client.dart` 和
   `lib/agent/chat_completions_client.dart` 每次模型请求基本只尝试一次。后续若加入，
   必须把模型请求重试与服务器命令重试分开，并保留用户终止能力，不能照搬固定次数到远程
   工具执行。

9. **Responses 诊断元数据没有保存。**
   官方 SSE 层读取 `openai-model`、`x-request-id`、rate-limit、`x-codex-turn-state`
   和 safety-buffering 等响应头/元数据并向会话状态发送事件。当前客户端只解析响应正文和
   usage，不保留这些信息。它不阻塞普通对话，但会使供应商排障、限额显示和“实际使用的模型”
   诊断不完整，列为可观测性改进而不是上下文压缩规则。

### 11.3 本轮结论

本轮没有再发现需要新增的上下文窗口硬编码、协议自动回退或服务器沙盒能力。上下文压缩的
冻结结论仍以第 10 节为准；上述新增项已经是本轮定向范围内的遗漏清单。后续应按 10.4 和
本节顺序实现并做关键路径定向测试，不再继续无边界重复搜索官方源码。
