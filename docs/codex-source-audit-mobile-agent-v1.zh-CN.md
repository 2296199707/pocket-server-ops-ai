# Codex 源码逐项审查：PocketServerOps AI Mobile Agent v1

## 1. 目的和范围

这是一份持续更新的源码审查记录，不是功能规划，也不把“有测试”直接等同于“符合 Codex”。目标是找出手机端 Agent 与 Codex 已验证行为之间的真实差异，只修复会影响稳定性、上下文连续性、远程副作用或数据一致性的差异。

本轮优先审查四个区域：

1. 上下文、历史和压缩；
2. Responses/Chat Completions 协议、SSE 和错误处理；
3. 工具、SSH、命令和文件副作用生命周期；
4. 并发、取消、恢复和事件持久化。

不在本轮重新设计中转服务器、服务器端 Agent、服务器沙盒或 UI；除非这些部分直接造成上述四类问题。

## 2. 固定参考来源

### 2.1 Codex 源码

- 仓库：`/www/mobile-agent-tooling/openai-codex-research.oZMeyF`；
- 固定 commit：`f5420174dafba153913a3e697f89002c338dfd7e`；
- 读取方式：优先使用 `git -C /www/mobile-agent-tooling/openai-codex-research.oZMeyF show <commit>:<path>`；
- 目录状态：当前 checkout 是稀疏/删除状态，不能直接把工作区文件是否存在当作源码证据；先用 `git ls-tree` 核对路径；
- 后续不重复进行无边界搜索。只有当前条目缺少证据时，才读取该条目列出的源码和测试。

### 2.2 当前应用

- canonical app：`/www/server-agent/workspace/apps/mobile-agent-v1`；
- 当前 beta：`1.0.3-beta.20`；
- 当前基线 commit：`526b80c`（版本提交：`923b5d5`）；
- legacy app `/www/server-agent/workspace/apps/mobile` 不属于审查和修改范围；
- 构建、缓存和 APK 继续使用 `/www` 数据盘路径。

## 3. 审查规则

每个条目必须完成以下五步，才可以标记为“已完成”：

1. 从固定 commit 读取列出的源码函数和至少一个相关测试；
2. 写出 Codex 的具体行为不变量，不能只写模块名称；
3. 找到 mobile-agent-v1 对应实现和事件/协议边界；
4. 用最小定向测试复现成功、失败、取消或恢复路径；
5. 记录结论：等价、产品架构差异但可接受、真实缺口或证据不足。

状态含义：

- `待复核`：只有条目和来源，尚未完成本轮证据核对；
- `复核中`：正在读取源码或运行该条目的测试；
- `已等价`：行为不变量已由源码和测试共同证明；
- `架构差异`：实现方式不同，但不违反需要保留的行为；
- `需修复`：发现可复现的行为缺口；
- `证据不足`：不能从固定源码或当前测试得出结论，不得猜测实现。

## 4. 逐项审查清单

### A. 上下文与历史（P0）

| ID | Codex 源码和测试 | Mobile 对应位置 | 必须核对的行为 | 状态 |
| --- | --- | --- | --- | --- |
| CTX-01 | `codex-rs/core/src/context_manager/normalize.rs`；`codex-rs/core/src/context_manager/history_tests.rs` | `lib/app_controller.dart` 的 `_localHistory`；`lib/agent/openai_compatible_client.dart` | function call/output 配对、孤立 output、取消后的未完成调用如何进入下一轮 | 已等价（应用支持的 function 工具子集） |
| CTX-02 | `codex-rs/core/src/context/model_switch_instructions.rs`；`codex-rs/core/src/context/world_state/model.rs` | `lib/app_controller.dart` 的任务配置和 provider projection | 模型切换是否保留线程；切换消息如何加入；哪些状态不能跨供应商复用 | 架构差异（已记录切换消息；opaque 状态按供应商投影清除） |
| CTX-03 | `codex-rs/core/src/context_manager/normalize.rs`；`codex-rs/core/src/context/compaction_summary.rs` | `lib/storage/app_database.dart`、`lib/storage/memory_app_database.dart`、`lib/app_controller.dart` | compaction 前后的历史起点、opaque item 保留范围、供应商切换后新 compaction 是否重新生效 | 需修复已处理（普通 Responses 使用服务端压缩 item；手动压缩保留 Codex 本地摘要边界；有回归测试） |
| CTX-04 | `codex-rs/core/src/context/world_state/model.rs`；`codex-rs/core/src/context/world_state/model_tests.rs` | `lib/domain/models.dart`、`lib/agent/context_usage.dart` | `context_window`、`max_context_window`、有效窗口、自动压缩阈值和未知元数据的处理，不得用字符或字节猜 token | 需修复已处理（ID-only Codex 模型 fallback） |
| CTX-05 | `codex-rs/tui/src/token_usage.rs` | `lib/agent/context_usage.dart`、`lib/ui/chat_page.dart` | 当前轮 usage、累计 usage、压缩后 usage 和 UI 百分比是否混为一谈 | 架构差异（同一计算规则；UI 只显示真实 usage） |
| CTX-06 | `codex-rs/core/src/context/image_resize_notice.rs`；Responses 输入相关源码 | `lib/storage/attachment_store.dart`、`lib/app_controller.dart`、客户端附件转换 | 图片物理独立存储但仍作为上下文输入；模型不支持媒体时的明确处理；累计图片不会把 Base64 永久放入事件 | 架构差异（物理分离但仍恢复到请求） |

### B. 协议、SSE 和错误（P0）

| ID | Codex 源码和测试 | Mobile 对应位置 | 必须核对的行为 | 状态 |
| --- | --- | --- | --- | --- |
| PRO-01 | `codex-rs/codex-api/src/common.rs`；`codex-rs/codex-api/src/endpoint/compact.rs`；`codex-rs/core/src/client.rs` | `lib/agent/openai_compatible_client.dart` | 普通 Responses 与独立 compact 请求的字段边界、历史、工具和 reasoning | 需修复已处理（普通请求按阈值发送 `context_management`；手动兼容路径关闭该字段；不做协议回退） |
| PRO-02 | `codex-rs/codex-api/src/sse/responses.rs`；相关 Responses 测试 | `lib/agent/openai_compatible_client.dart` | `response.completed`、incomplete、failed、cancelled、断流和 multiline SSE 的终止与保存顺序 | 已等价（已覆盖关键事件） |
| PRO-03 | `codex-rs/core/src/responses_retry.rs`；`codex-rs/core/src/responses_retry_tests.rs` | `lib/agent/openai_compatible_client.dart`、`lib/agent/chat_completions_client.dart` | 仅模型请求按明确可重试错误退避；取消立即打断；不得重放远程工具副作用 | 架构差异（客户端不自动重试，工具副作用不会重放） |
| PRO-04 | `codex-rs/core/src/context_manager/normalize.rs`；Responses 请求源码 | `lib/agent/openai_compatible_client.dart`、`lib/agent/chat_completions_client.dart` | Responses 与 Chat Completions 是显式协议；不支持时直接报错，不自动 fallback；跨协议历史转换不伪造 opaque 状态 | 已等价 |
| PRO-05 | 模型元数据和 endpoint 相关测试 | `lib/providers/provider_connection_tester.dart`、`lib/domain/models.dart` | `/models` 只有真实能力字段时才更新元数据；普通模型 ID 响应不能覆盖用户已配置限制 | 需修复已处理（ID-only Codex 模型 fallback） |
| PRO-06 | SSE/请求错误处理源码和测试 | `lib/agent/openai_compatible_client.dart`、`lib/agent/ai_client_factory.dart` | API key 不进入错误事件；HTTP 错误、解析错误、超时和取消对用户/任务状态区分明确 | 已等价（关键路径有定向测试） |

### C. 工具、SSH 和远程副作用（P0/P1）

| ID | Codex 源码和测试 | Mobile 对应位置 | 必须核对的行为 | 状态 |
| --- | --- | --- | --- | --- |
| EXEC-01 | `codex-rs/core/src/unified_exec/head_tail_buffer.rs`；对应 tests | `lib/agent/agent_tools.dart`、`lib/ssh/ssh_connection.dart` | stdout/stderr 采用有界 head/tail；结果结构可读；不能因输出过大拖垮上下文或事件库 | 需修复已处理 |
| EXEC-02 | `codex-rs/core/src/unified_exec/process.rs`、`process_manager.rs`；对应 tests | `lib/agent/agent_tools.dart`、`lib/agent/agent_loop.dart` | 长命令进程数量、状态、写入、轮询、停止和任务结束清理；TERM/KILL 后状态不能误报成功 | 架构差异（已核对） |
| EXEC-03 | `codex-rs/core/src/agent/control/execution.rs`；`codex-rs/core/src/tools/approvals.rs` | `lib/agent/agent_loop.dart`、`lib/agent/auto_review.dart` | 工具开始、等待审批、批准、拒绝、审查失败和取消的顺序；远程副作用未知时必须提示检查 | 架构差异（已核对） |
| EXEC-04 | `codex-rs/core/src/guardian/review.rs`、`review_session.rs`；相关 review tests | `lib/agent/auto_review.dart`、`lib/app_controller.dart` | 自动审查失败不能伪装为 allow；用户确认仍是最终继续条件；审查输入不能夹带凭据 | 架构差异（已核对） |
| EXEC-05 | `codex-rs/core/src/unified_exec/process_manager.rs`；`codex-rs/core/src/session/turn.rs` | `lib/ssh/ssh_connection.dart`、`lib/agent/agent_tools.dart`、`lib/app_controller.dart` | SSH 断开、手机任务取消、应用退出后的连接和远端进程清理；不能自动重放有副作用命令 | 需修复已处理 |
| EXEC-06 | `codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs`；`codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs`；相关 exec tests | `lib/agent/agent_tools.dart`、`lib/ssh/ssh_connection.dart` | 工作目录、环境、命令返回码和输出偏移是否在失败/轮询时保持一致 | 架构差异（已核对） |
| EXEC-07 | Codex 文件工具和项目指令相关源码 | `lib/agent/agent_tools.dart`、`lib/agent/remote_instructions.dart`、`lib/local/project_files.dart`、`lib/local/local_file_access.dart` | 文件读写边界、原子替换、符号链接、项目外授权和 `AGENTS.md` 指令加载不能互相绕过 | 需修复已处理 |

### D. 轮次、并发和持久化（P0/P1）

| ID | Codex 源码和测试 | Mobile 对应位置 | 必须核对的行为 | 状态 |
| --- | --- | --- | --- | --- |
| LIFE-01 | `codex-rs/core/src/session/turn.rs`；`turn_tests.rs` | `lib/agent/agent_loop.dart`、`lib/app_controller.dart` | 一次 turn 的开始、完成、失败、取消和资源释放是单调的；迟到回调不能覆盖下一轮 | 架构差异（已核对） |
| LIFE-02 | `codex-rs/core/src/session/input_queue.rs`；`turn_input_tests.rs` | `lib/app_controller.dart`、`lib/ui/chat_page.dart` | 运行中追加输入、排队和取消的产品差异；没有实现的 `turn_steer` 不得伪装成已支持 | 架构差异（已核对） |
| LIFE-03 | session/rollout reconstruction 相关源码和 tests | `lib/storage/app_database.dart`、`lib/storage/memory_app_database.dart` | 应用重启、半写入事件、运行中任务和未知远端状态恢复方式一致 | 需修复已处理（其余为架构差异） |
| LIFE-04 | `codex-rs/core/src/agents_md.rs`；`agents_md_tests.rs` | `lib/agent/remote_instructions.dart`、`lib/app_controller.dart` | 指令查找顺序、覆盖文件优先级、项目根边界和总读取预算 | 架构差异（已核对） |
| LIFE-05 | event/session/review tests | `lib/storage/app_database.dart`、`lib/app_controller.dart` | 用户事件先落盘还是请求先发出；失败后重试不会重复或丢失用户消息 | 需修复已处理 |
| LIFE-06 | 多任务/turn 状态相关 tests | `lib/app_controller.dart`、`lib/ssh/ssh_connection.dart` | 多任务共享服务器时，写操作排队范围、读操作并发范围和取消目标不能串任务 | 需修复已处理 |
| LIFE-07 | attachment/history 相关源码和 tests | `lib/storage/attachment_store.dart`、`lib/app_controller.dart` | 附件 ID 归属、删除/清理、分页加载和历史恢复不能引用其他对话或把旧快照覆盖新事件 | 需修复已处理（分页）/架构差异（附件） |

## 5. 最小定向测试矩阵

每个条目只保留能证明不变量的测试，不复制完整 Codex 测试套件。优先使用本地假的 OpenAI-compatible HTTP 服务和内存数据库，不使用真实 API key 或真实服务器。

| 场景 | 需要证明的结果 | 关联条目 |
| --- | --- | --- |
| 首轮成功，第二轮 503，切换供应商后继续 | 用户消息、普通回复和可复用工具结果仍在；opaque 状态不跨供应商发送 | CTX-02, CTX-03, PRO-04, LIFE-05 |
| 切换后新 Responses compaction | 新压缩点重新成为后续历史起点，不能永久关闭压缩 | CTX-03 |
| `response.completed` 后连接不关闭 | 立即完成 turn，保存完整 output item | PRO-02, LIFE-01 |
| incomplete/failed/timeout/cancel | 任务状态和历史结果不伪装成功；取消可停止等待 | PRO-03, PRO-06, LIFE-01 |
| 缺失 function output、孤立 output、多个工具调用 | 下一次请求配对合法，未完成调用得到明确 aborted/unknown 语义 | CTX-01, PRO-04 |
| 1 MiB 级命令输出和长驻进程 | head/tail 可读，轮询有偏移，停止后资源释放 | EXEC-01, EXEC-02 |
| 审查 allow/ask/deny/failure | 失败转人工；拒绝不执行；凭据不进入审查消息 | EXEC-03, EXEC-04 |
| 运行中取消后立即发起新轮次 | 旧 turn 的回调、状态和清理不能影响新 turn | LIFE-01, LIFE-06 |
| 应用重启和半完成事件 | 远端结果未知时要求检查，不自动重放；历史可继续 | LIFE-03, LIFE-05 |
| 100 张累计图片、分页历史和压缩 | UI 分页不改变有效上下文；附件按归属恢复，内存不保存完整 Base64 事件 | CTX-05, CTX-06, LIFE-07 |

## 6. 修改和发布边界

- 发现真实缺口后，只修改对应模块；不为“理论上可能”增加全局硬限制；
- 不把供应商不兼容自动变成另一个协议；
- 不把模型窗口、重试次数、输出大小或安全能力凭经验写死；
- 不自动重试远程命令、文件写入或其他有副作用工具；
- 每个修复先更新本文件的条目和证据，再补一个聚焦测试；
- 只有 P0/P1 条目完成、`flutter analyze`、相关定向测试和 `git diff --check` 通过后，才准备新的 beta；
- beta 发布必须记录 commit、版本号、APK 数据盘路径和验证结果。

## 7. 审查记录

### 2026-08-27：建立审查基线

- 已固定 Codex 源码 commit `f5420174dafba153913a3e697f89002c338dfd7e`；
- 已确认源码快照 checkout 不完整，后续使用 Git object 读取，不把工作区缺失误判为源码缺失；
- 当前 beta 基线为 `1.0.3-beta.20`，功能 commit `526b80c`，版本 commit `923b5d5`；
- 上一轮调查中的结论只作为待复核线索，不直接作为本轮最终证据；
- 建立基线时尚未修改业务代码；后续条目按表格顺序更新状态和结论。

### 2026-08-27：EXEC-01 工具输出预算

- Codex 源码证据：固定 commit 的 `codex-rs/core/src/unified_exec/mod.rs:74-77,212-214`
  定义统一执行输出缓存为 1 MiB、最大进程数为 64，并把未指定的执行输出上限解析为
  10,000 tokens；`codex-rs/core/src/unified_exec/process.rs:60-64,119-124`
  使用单个 `HeadTailBuffer` 保存合并输出；`codex-rs/core/src/unified_exec/async_watcher.rs:35-41`
  只限制单个增量事件为 8 KiB。模型上下文并不直接使用 1 MiB：
  `codex-rs/core/src/tools/context.rs:341-535` 会按模型的 `truncation_policy`
  再生成带 head/tail 和省略提示的工具结果；`codex-rs/models-manager/src/model_info.rs:139-176`
  明确规定未知模型 fallback 为 `bytes: 10000`。相关测试为
  `codex-rs/core/src/unified_exec/head_tail_buffer_tests.rs` 的
  `keeps_prefix_and_suffix_when_over_budget`，以及
  `codex-rs/core/src/tools/context_tests.rs` 的执行输出截断测试。
- Mobile 实现：`lib/ssh/ssh_connection.dart:735-838` 的 `SshOutputBuffer` 保留
  UTF-8 字节 head/tail；`lib/agent/agent_tools.dart:1071-1199` 为 stdout、stderr
  各维护一个 1 MiB 缓冲并提供轮询 offset；`lib/agent/agent_loop.dart:634-829`
  已按显式 policy 对事件和模型工具结果做结构化 head/tail 截断。
- 复现输入：供应商 `/models` 只返回模型 id，因此 `ProviderModelMetadata.truncationPolicy`
  为空；工具返回 20,000 个 ASCII 字符。修复前 `lib/app_controller.dart:1387-1389`
  将 null 直接传给 `AgentLoop`，下一轮请求会携带完整工具结果，且 `tool.completed`
  事件也没有模型预算。
- 修复：`ProviderModelMetadata.resolvedTruncationPolicy` 和
  `ProviderTruncationPolicy.codexFallback` 对齐 Codex fallback 的 `bytes: 10000`；
  `AppController` 在没有模型元数据或没有 policy 时使用该值，同时保留供应商明确提供的
  bytes/tokens policy。没有改变 SSH 内部 1 MiB 读取能力，也没有新增更小的远程输出限制。
- 定向测试：`test/domain/models_test.dart` 的
  `missing tool-output metadata uses Codex fallback policy`；
  `test/agent_loop_test.dart` 的
  `Codex fallback policy bounds results without catalog fields`。
- 结论：`需修复`，已处理。修复仅补齐模型-facing 的 Codex fallback，stdout/stderr
  分流是 Mobile 保留终端交互语义的架构差异。修复 commit：`a7cc134`。

### 2026-08-27：EXEC-02 长命令进程生命周期

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/unified_exec/mod.rs:68-77,144-169` 定义最小/最大轮询等待、64
  个托管进程上限和带 `reserved_process_ids` 的进程存储；
  `codex-rs/core/src/unified_exec/process_manager.rs:758-935` 在同一进程上串行化
  写入和轮询，非 TTY 只允许中断，写入后刷新进程状态，退出后从存储移除；
  `:938-996` 用进程实例校验避免旧句柄影响新进程；`:1464-1505` 只在可行时淘汰
  进程，避免在退出事件仍持锁时误杀活跃进程；`:1537-1605` 在任务结束清空并终止
  全部进程，单个终止只有确认成功后才移除。相关测试为
  `codex-rs/core/src/unified_exec/process_manager_tests.rs:482-608` 的退出进程优先、
  LRU 回退和退出事件锁保护测试，以及
  `codex-rs/core/src/unified_exec/process_tests.rs:112-196` 的远端写入失败状态和
  终止确认测试。
- Mobile 实现：`lib/agent/agent_tools.dart:261-353` 将启动中的 channel open 计入
  64 个进程上限，托管进程通过 stdout/stderr 字节缓冲、offset 轮询和
  `_ManagedProcess.stop` 生命周期管理；`:1071-1204` 在输出流、SSH session 和
  `_finished` 均完成后才标记 `done`，停止时调用 `SshCommandStream.terminate`，等待
  结束后再关闭并取消订阅。`lib/ssh/ssh_connection.dart:132-230` 的终止流程按 TERM、
  KILL、channel close 顺序执行；`:435-493` 对短命令超时执行同样的终止流程。
  `lib/app_controller.dart:1235-1249,1468-1497,3464-3487` 在有运行中托管进程时
  保留 task 级 SSH/工具实例供下一轮继续使用，没有运行中进程时释放它们。
- 复现输入：运行
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/ssh_connection_test.dart`，覆盖 TERM 后
  session 关闭、TERM grace 超时后 KILL、关闭 stream 唤醒终止等待、64 个并发启动
  channel 计数，以及连接池关闭时的 pending connection。
- 实际结果：10 项全部通过。停止路径不会在 TERM/KILL 未完成时立即把退出码伪造成成功；
  任务结束会按是否存在运行中托管进程决定保留或释放资源。Mobile 在达到 64 个进程
  时直接报错，而 Codex 会按最近使用/已退出状态尝试淘汰旧进程；这是为了避免手机端
  在用户未明确要求时隐式终止另一个远程命令的架构差异，不是当前可复现的稳定性缺口。
- 期望不变量：单个进程的写入、轮询和终止不能互相覆盖；远程命令结束或停止后状态只
  能进入完成/失败/未知之一；关闭 task 时不遗留本地订阅和 SSH channel；远程写入失败
  或取消后不得自动重放命令。
- 结论：`架构差异`。未发现需要修复的 EXEC-02 行为。定向测试：上述
  `test/ssh_connection_test.dart`，10 项通过。修复 commit：无（本条未改业务代码）。

### 2026-08-27：EXEC-03 工具审批、取消和远程副作用

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/tools/approvals.rs:433-496` 固定审批优先级为 hooks → Guardian/用户，
  将拒绝、超时和取消转换为工具错误，不把它们转换成批准；`:498-605` 区分严格自动审查
  与用户审批；`codex-rs/core/src/agent/control/execution.rs:29-69` 对受限执行在轮次
  开始检查容量并用 guard 在结束时释放。统一执行的远程副作用边界由
  `codex-rs/core/src/unified_exec/process_manager.rs:758-935` 体现：写入/轮询按单进程
  串行化，写入失败刷新状态，退出和未知进程分开返回。相关测试为
  `codex-rs/core/src/agent/control/execution_tests.rs:14-60` 的容量 guard 测试、
  `codex-rs/core/src/unified_exec/process_manager_tests.rs:545-608` 的退出进程锁保护，
  以及工具审批测试模块 `codex-rs/core/src/tools/approvals_tests.rs`。
- Mobile 实现：`lib/agent/agent_loop.dart:258-425` 先发 `tool.started`，再按
  `requiresUserApproval`、`executionMode` 和 `requiresConfirmation` 选择用户确认、自动
  模型审查或自动执行；拒绝/取消只追加工具失败结果，不调用工具。执行前由
  `callWithOperationStart` 标记远程副作用已经开始；`:436-585` 在执行失败、取消、步骤/工具
  上限时把已开始的远程写入标记为 `task.unknown`，未开始的本地操作保持 cancelled/failed。
  `lib/app_controller.dart:1508-1530` 通过 `_serializeRemoteWrites` 把同一服务器和工作
  目录的写操作放入队列，队列在真正调用工具前检查取消状态。
- 复现输入：运行
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/agent_loop_test.dart`，覆盖审批中取消、自动审查放行、远程写入失败、远程工具执行中取消、队列中取消和边界权限必须人工确认；共 23 项通过。
- 实际结果：拒绝不会执行工具；审查失败不会放行；队列等待阶段取消不会启动远程写入；
  远程写入开始后取消或失败返回 `unknown`，要求用户检查服务器状态。Mobile 没有 Codex
  的 hooks、Guardian approval policy 和跨 session 执行容量模型，而是把工具审批放在一个
  AgentLoop 内并按服务器/目录排队，这是产品架构差异；没有发现会把未知副作用误报为成功
  的可复现路径。
- 期望不变量：审批完成前不调用工具；拒绝、审查失败和取消不执行副作用；远程写入开始
  后其最终状态未知时不能继续伪装成普通失败或成功；队列中尚未开始的写操作可被取消。
- 结论：`架构差异`。未发现需要修复的 EXEC-03 行为。定向测试：
  `test/agent_loop_test.dart`，23 项通过。修复 commit：无（本条未改业务代码）。

### 2026-08-27：EXEC-04 自动审查失败闭合与凭据脱敏

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/guardian/review.rs:312-364` 允许快速审查只返回已有决策，普通
  Guardian 审查在 `:482-523` 区分 allow/deny；`:526-645` 将超时作为 timed out、取消作为
  aborted、prompt/session/parse 错误作为 `FailedClosed` 高风险拒绝；最终只有
  `:650-734` 的明确 Allow 才返回 Approved。`codex-rs/core/src/guardian/prompt.rs:96-162`
  和 `:377-513` 把精确 action JSON 与截断后的用户/助手/工具 transcript 分开提供，避免
  把历史内容当指令；`codex-rs/core/src/guardian/approval_request.rs:115-171,194-400`
  只序列化待审查 action，不把会话内部凭据放入 action。
- Mobile 实现：`lib/agent/auto_review.dart:3-83` 对嵌套参数、常见密码/token/secret/api
  key/private key 字段、Bearer 值、命令行 secret 和 sshpass 密码做脱敏，并要求决定是
  `allow`、`ask_user` 或 `deny`；`lib/app_controller.dart:2344-2412` 从任务指定的审查
  供应商和模型创建独立客户端，工具参数以脱敏 JSON 发送且不提供工具。`lib/agent/agent_loop.dart:326-383` 将解析异常、请求异常或缺少审查模型转为
  `review.failed` 并保持不允许执行；`ask_user` 决定才进入人工确认。
- 复现输入：运行
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/auto_review_test.dart test/agent_loop_test.dart`，覆盖嵌套凭据/命令 secret 脱敏、合法/非法决定解析、审查允许、审查服务失败和失败闭合；共 27 项通过。
- 实际结果：审查模型只获得当前工具调用及任务摘要，不获得 SSH 密码、API key 或工具
  执行能力；解析/请求失败不会进入 allow 分支。与 Codex Guardian 相比，Mobile 没有
  Guardian 的完整历史 transcript、固定审查策略、超时分类和内部审查会话，而是使用用户
  选择的独立兼容供应商；因此它能依据命令参数识别高风险删除等动作，但不能像 Codex
  Guardian 一样用完整会话验证用户授权。这是已知产品架构差异，不在本轮猜测性扩大请求
  上下文或把所有命令一律禁止。
- 期望不变量：自动审查失败不能放行；`ask_user` 仍需人工确认；审查请求不能泄露保存的
  连接凭据；审查结果只能影响是否进入工具执行，不能直接执行工具。
- 结论：`架构差异`。未发现需要修复的 EXEC-04 行为。定向测试：上述两个测试文件，
  27 项通过。修复 commit：无（本条未改业务代码）。

### 2026-08-27：EXEC-05 SSH 通道断链时的未知状态

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/unified_exec/process_manager.rs:758-935` 将托管进程的输出读取、
  写入、轮询和终止绑定到同一进程实例；`:938-996` 校验进程实例，避免旧句柄操作新进程；
  `codex-rs/core/src/session/turn.rs` 的轮次清理路径在结束时释放进程管理资源。Codex 的
  关键不变量是：进程没有明确退出状态时，不能把通道关闭当作普通成功；有副作用的远程
  操作不能因为客户端取消或断链而自动重放。相关 process manager/turn 测试覆盖终止、
  资源清理和取消后的单调结束。
- Mobile 实现：`lib/ssh/ssh_connection.dart:132-230` 暴露 SSH session 的
  `exitCode`、`exitSignal` 和 `done`，终止按 TERM、KILL、channel close 顺序进行；
  `lib/agent/agent_tools.dart:1071-1230` 的 `_ManagedProcess` 观察 stdout、stderr 和
  channel 完成错误，只有存在退出码或退出信号时才把无错误关闭视为完成，否则标记
  `failed` 并返回错误；`terminal.stop` 不再在无法确认时返回 `stopped: true`。任务层已有
  `lib/agent/agent_loop.dart` 的远程副作用 `unknown` 语义，不会自动重放命令。
- 复现输入：使用假的 `SshCommandStream` 在 stdout/stderr 尚未给出退出码或退出信号时
  销毁 channel，然后轮询托管进程；另覆盖正常关闭、TERM/KILL 终止和重复 stop。
- 修复前结果：stream 关闭错误被吞掉，轮询可能返回 `done: true, exit_code: null`，模型
  会把远程状态未知误认为普通完成。
- 实际修复：保存 stream、stdout 和 stderr 的失败；无 `exitCode` 且无 `exitSignal` 的
  关闭统一标记为失败；轮询返回 `failed/error`；停止确认失败时返回 `stopped: false`。
  同时以原始 UTF-8 字节接收输出，避免流监听器先解码导致偏移和异常丢失。
- 期望不变量：远端命令只有明确退出状态才可作为完成；断链、停止超时和读取失败不能
  伪装成功；旧任务不能自动重放有副作用命令；任务关闭后本地订阅和 channel 必须释放。
- 结论：`需修复`，已处理。修复 commit：`a7cc134`。
- 定向测试：
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/ssh_connection_test.dart`，11 项通过，
  覆盖 channel 销毁且无退出状态的回归路径。

### 2026-08-27：LIFE-05 初始化失败时的用户输入持久化

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/session/turn.rs:167-223` 在预采样压缩、依赖解析和取消等初始化
  失败分支显式调用 `run_hooks_and_record_inputs`；
  `codex-rs/core/src/session/turn.rs:264-269` 在正常 turn 开始记录输入；
  `codex-rs/core/src/session/mod.rs:4211-4230` 先把用户 prompt 写入会话历史，再发出
  turn item 并物化 rollout。固定 commit 的
  `codex-rs/core/src/session/turn_input_tests.rs:110-152` 验证已接受的用户输入会在
  turn 开始应用到会话状态。
- Mobile 实现：此前 `lib/app_controller.dart:1133-1152` 要等旧附件迁移、供应商查找、
  模型历史读取和本轮附件持久化全部完成后才写 `user.message`；其中任一步失败都会只
  记录 `task.failed`，当前用户文本无法从历史恢复。附件本身由
  `lib/storage/attachment_store.dart` 独立保存，事件只应保存附件 ID。
- 复现输入：使用测试数据库让 `loadModelEvents` 在 turn 初始化阶段失败，并携带一张
  图片附件。
- 实际修复：本轮附件先完成独立存储，再执行旧附件迁移和模型历史读取；初始化失败时，
  若当前 turn 尚未有 `user.message`，先查询数据库避免重复，再补写用户文本和已成功
  存储的附件 ID。补写路径不使用尚未持久化的原始 Base64；若附件写入本身失败，仍
  尽力保留用户文本。若事件写入后任务更新时间保存失败，恢复路径会重新合并已存在的
  用户事件，避免内存历史丢失该事件。
- 期望不变量：初始化失败或取消不能静默丢掉已接受的用户输入；同一 `turn_id` 不重复
  写用户事件；事件日志不保存附件 Base64；未确认的附件写入不伪造为可恢复附件。
- 结论：`需修复`，已处理。修复 commit：`a7cc134`。
- 定向测试：`test/app_controller_test.dart` 的
  `setup failure still persists the current user message`，覆盖历史读取失败、附件
  独立存储、事件无 Base64 和后续按任务读取附件。

### 2026-08-27：EXEC-06 工作目录、返回码和轮询偏移

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs:119-160` 在选定
  environment 后把相对 `workdir` 解析到该 environment 的原生 cwd，并将 cwd、shell、
  env 一起交给 executor；`:637-734` 区分仍运行的 `process_id` 与已退出的 `exit_code`。
  `codex-rs/core/src/tools/handlers/unified_exec/write_stdin.rs:40-76` 通过统一进程管理器
  读取同一聚合输出，退出时移除 process entry；
  `codex-rs/core/src/unified_exec/process_manager.rs:758-935` 对一个进程的写入/读取/状态
  刷新串行化，使用 executor 的序列读取避免重复消费。相关
  `unified_exec_tests.rs` 覆盖 shell/cwd 解析和运行中、完成后的 tool output 语义。
- Mobile 实现：`lib/ssh/ssh_connection.dart:414-423,698-704` 在每个 SSH channel 内将
  `working_directory` 作为同一 shell 命令的前置 `cd`，路径使用单引号并转义单引号；
  `lib/agent/agent_tools.dart:245-309` 将任务默认目录与调用参数传给短命令和长命令，并以
  `_ManagedProcess` 保存独立 stdout/stderr 缓冲。`lib/ssh/ssh_connection.dart:735-838`
  用原始 UTF-8 字节计数，返回逻辑总字节 offset；截断后按 head/tail 返回，不把 offset
  当作当前缓存下标。
- 复现输入：对多字节输出分块追加并在超过缓存后分别读取 offset；验证命令目录含空格、
  单引号和相对任务目录时的 `cd` 组合；验证长命令完成、失败和 channel 断开后的
  `done/failed/exit_code`。
- 实际结果：Mobile 的字节 offset 在截断前后保持单调，传入上一轮返回的 offset 不会
  重复正常输出；工作目录的 shell quoting 保持为一个参数。EXEC-05 已补上长命令无退出
  状态的失败标记。Codex 的 `env`、sandbox cwd、shell snapshot、进程序列读取属于其
  本地/exec-server 执行器契约，SSH 服务器没有相同的可注入环境接口；Mobile 使用登录
  SSH 会话的服务器环境，这是架构差异，不是遗漏的兼容层。
- 期望不变量：同一 Mobile channel 内目录、输出和状态对应同一命令；轮询 offset 只前进
  不回退；正常退出提供退出码或信号，断链进入失败/未知语义；不自动重放命令。
- 结论：`架构差异`。未发现需要修复的 EXEC-06 行为。
- 定向测试：`test/ssh_connection_test.dart` 的 UTF-8 字节 offset、head/tail 截断、零
  容量和 channel 状态测试，11 项通过；Codex 侧使用固定 commit 的
  `unified_exec_tests.rs`、`process_tests.rs` 作为行为证据。修复 commit：无。

### 2026-08-27：EXEC-07 文件边界、符号链接和项目指令

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/agents_md.rs:121-183,185-240` 先按项目根标记确定边界，再从项目根
  到当前目录收集指令；每层优先 `AGENTS.override.md`，找不到才使用 `AGENTS.md`，总预算
  由 `project_doc_max_bytes` 控制并在读取时截断。`codex-rs/core/src/agents_md_tests.rs`
  的 `concatenates_root_and_cwd_docs`、`agents_local_md_preferred`、
  `project_root_markers_are_honored_for_agents_discovery` 和超预算测试覆盖顺序、覆盖文件、
  根边界和预算。`codex-rs/exec-server/src/file_read.rs:18-79,82-120` 用有界文件句柄和
  offset 分块读取，读错时关闭句柄；`codex-rs/exec-server/src/local_file_system.rs:558-632`
  把 canonicalize、跟随/不跟随符号链接和文件读写作为明确文件系统操作；
  `codex-rs/apply-patch/src/file_update.rs:26-45,308-334` 先读取原文、校验 patch 并生成
  新内容，再交给文件系统写入。固定配置中的 `project_doc_max_bytes` 默认是 32 KiB。
- Mobile 实现：`lib/local/project_files.dart:261-289` 逐个检查项目路径中已经存在的组件，
  解析符号链接后拒绝离开项目根；`writeBytes` 使用同目录临时文件、flush 和 rename，失败
  会清理临时文件。`lib/agent/remote_instructions.dart:15-91` 按 `.git` 最近祖先从根到 cwd
  读取两种指令文件，每层只选 override 或默认文件，并使用 32 KiB 总预算；远程服务器工具
  仍按登录 SSH 用户的真实权限工作，没有额外猜测性的项目外硬限制。`LocalFileAccessStore`
  对授权路径和每次读写都做 canonical 路径判断。
- 复现输入：把应用私有目录设为保护根，在旧实现中请求其父目录（例如应用包目录的
  `/data/user/0`）或请求 `/`。旧判断只验证“候选路径在保护根内”，因此父目录和 `/` 可能被
  授权，随后 `local.list/read/write` 可以覆盖应用私有凭据或数据库目录；`/app2` 不能被误判
  为 `/app` 的子路径。
- 实际修复：`LocalFileAccessStore.scopesOverlapCanonical` 同时判断两个规范化范围的正向
  包含关系，并专门处理根目录 `/`；`AppController._isProtectedLocalPath` 改为拒绝保护目录
  本身、其子目录和其父目录。这样没有扩大服务器端能力边界，也没有改变用户已经明确授权的
  手机项目目录读写。
- 期望不变量：项目内路径不能通过符号链接离开项目根；授权范围不能覆盖应用私有根，也
  不能通过 `/` 或父目录间接覆盖它；文件读写不会把未授权路径变成可访问路径；指令文件只
  从项目根到 cwd 合并，override 优先且预算有限。
- 结论：`需修复`，已处理。Codex 的服务器文件系统支持显式 follow-symlinks 和更大分块，
  Mobile 的项目目录采用更严格的符号链接边界，这是本地项目安全边界而不是不兼容回退。
  修复 commit：`a7cc134`。
- 定向测试：
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/local_file_access_test.dart test/project_files_test.dart`，3 项全部通过，覆盖父目录/根目录/相似前缀范围判断、授权符号链接逃逸、项目文件读写和原子替换路径。

### 2026-08-27：LIFE-01 turn 单调性、取消和迟到状态

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/session/turn.rs:155-225,302-395` 为每个 turn 创建独立的
  `TurnContext` 和取消令牌，按一次 turn 的请求视图执行采样与工具；`:396-601` 在工具和
  采样收口后区分正常完成、取消和错误，取消以 `TurnAborted` 返回，不把取消转换成完成。
  `codex-rs/core/src/session/turn.rs:2762-2793` 在清理待执行工具、记录 token 使用后再检查
  取消。`codex-rs/core/src/session/mod.rs:1971-2015` 持久化并发送带 turn id 的事件；
  `codex-rs/core/src/session/tests.rs:10740-10810` 验证正常完成/中断的终止事件在对应
  rollout flush 后交付，`:11032-11078` 验证活动 turn 清空后才进入 thread idle；
  `codex-rs/core/src/agent/control/execution.rs:19-69` 用 guard 在受限执行结束时释放执行
  容量。相关源码测试证明终止事件、持久化和资源释放有明确的先后关系。
- Mobile 实现：`lib/agent/agent_loop.dart:116-180,543-591` 用每次运行独立的
  `AgentCancellation`，在请求、工具审批和工具执行阶段区分 cancelled/unknown，并只在
  没有工具调用时发出 `task.completed`；远程写入开始后取消或失败保持 unknown。`
  lib/app_controller.dart:1040-1170` 为每轮生成唯一 `turnId`，用户事件先入库，再开始
  turn；`:1400-1451` 以任务事件队列和状态队列顺序写入事件/状态；`:1495-1503` 用
  `turnId` 与 Future identity 防止旧运行清理新运行；`:1540-1546` 取消只作用于当前运行。
  `_releasePhoneTask` 在无运行中托管进程时释放 SSH/工具，有运行中进程时保留它供后续轮次
  继续，这是手机端长命令能力的产品差异。
- 复现输入：预览模式对同一任务连续执行两轮，取第一轮 `turn_id`，在第二轮完成后尝试以
  第一轮 id 写入 `failed` 状态；同时覆盖工具执行中取消、审批中取消和远程写入失败。
- 实际结果：旧 turn 的状态更新因 `_taskRunIds[taskId] != turnId` 被忽略；任务事件和状态
  写入按任务串行，第二轮的完成状态不会被第一轮迟到状态覆盖。已有取消测试确认本地工具
  返回 cancelled、远程写入返回 unknown，且不会伪装为成功或自动重放。
- 期望不变量：一个任务同一时间只有一个 turn；terminal 状态单调；取消、失败和未知不能
  变成成功；迟到回调不能覆盖新 turn；终止前等待已入队事件完成；仍运行的托管进程不能被
  无意释放或重放。
- 结论：`架构差异`。Codex 的 session worker、rollout flush 和活动 turn 生命周期比
  Mobile 的 Future/SQLite/SSH 组合更细，但上述稳定性不变量已满足；没有发现需要修改的
  业务缺口。本条只补充旧 turn 状态回归测试。修复 commit：`a7cc134`。
- 定向测试：
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/agent_loop_test.dart test/app_controller_test.dart`，58 项全部通过，覆盖取消、远程未知、事件顺序、连续 turn 和旧 turn 状态隔离。

### 2026-08-27：LIFE-02 活动 turn 输入与排队

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/session/input_queue.rs:65-75,256-275` 将活动 turn 的待处理输入
  与 session 级 mailbox 分开保存；`codex-rs/core/src/session/turn_input_tests.rs:76-108`
  提供 steer-only 提交，`:154-187` 验证 `StartIfIdle` 在活动 turn 存在时返回
  `NotIdle` 且不注入输入，`:189-246` 验证恢复提交同样不能覆盖活动 turn；
  `input_queue.rs:277-280` 只有 turn 消费时才取出待处理输入。也就是说，Codex 的
  “运行中追加输入”是显式 `Steer`/队列协议，不是把第二个普通 start 请求当作新轮次。
- Mobile 实现：`lib/app_controller.dart:992-1024` 以 `_taskRuns` 保护同一任务的
  活动 Future，运行中再次调用 `runTask` 直接抛出“任务正在运行”；
  `lib/ui/chat_page.dart:1175-1260` 在发送期间禁用发送入口，取消通过当前任务的
  cancellation 处理，没有把普通发送伪装成 steer 或静默丢进另一个队列。
- 复现输入：同一任务在第一轮尚未完成时提交第二条普通 prompt，并检查第二条输入是否
  被写入第一轮、是否启动了隐式第二轮，以及取消后是否仍会继续执行。
- 实际结果：第二次 `runTask` 立即得到明确的 `StateError`；当前 UI 不提交第二条消息；
  取消只作用于当前 Future，已存在的远程副作用继续按 `unknown` 语义收口。现有
  `test/app_controller_test.dart` 的并发/重复轮次测试和 `test/agent_loop_test.dart`
  的取消测试覆盖这些路径。
- 期望不变量：未实现 steer/排队协议时，不能声称运行中追加输入已支持；普通 start 不能
  覆盖活动 turn，也不能静默丢失用户输入；取消不应启动或重放另一轮。
- 结论：`架构差异`。Codex 支持显式 steer 和 mailbox，而 Mobile 采用“一个任务一个
  活动 turn，运行中拒绝新发送”的更小产品契约；行为没有把未实现能力伪装成已实现，
  也没有发现需要修复的生命周期缺口。后续若产品要支持 steer，应单独设计协议、事件和
  取消语义，不在本次稳定性审查中猜测添加。
- 定向测试：固定 Codex 的 `turn_input_tests.rs` 作为提交模式证据；Mobile 使用
  `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/agent_loop_test.dart test/app_controller_test.dart`，58 项全部通过。

### 2026-08-27：LIFE-03 重启、半写入事件和未知状态恢复

- Codex 源码证据：固定 commit 的
  `codex-rs/core/src/session/rollout_reconstruction.rs:113-123,155-215,252-270`
  从持久化 rollout 按 turn 边界重建历史；`rollout_reconstruction.rs:321-379`
  再按原始顺序重放 response、compaction 和 rollback，而不是把尾部未完成记录
  猜成成功。`codex-rs/core/src/session/mod.rs:1342-1418` 在恢复时调用同一重建流程，
  如果最后记录的是中断事件则恢复为 `Interrupted`，并把历史/usage 作为下一次显式
  turn 的基础。相关测试为固定 commit 的
  `codex-rs/core/src/session/rollout_reconstruction_tests.rs:487-581`
  （未完成 turn 回滚后不污染历史）和 `:1850-1903`（尾部未完成 turn 仍保留可重建的
  context item）。
- Mobile 实现：`lib/app_controller.dart:275-287` 串行化多次 `load`；
  `lib/app_controller.dart:322-357` 只处理启动时没有内存运行实例的
  `running/waiting/stopping` 任务：最新事件与同一轮终止事件一致时恢复明确 terminal
  状态，否则写入 `task.recovered` 并把任务标为 `unknown`；
  `lib/storage/app_database.dart:540-561` 和
  `lib/storage/memory_app_database.dart:268-285` 都按事件序列读取最新事件/终止事件。
  `lib/app_controller.dart:897-924` 先持久化事件再更新任务时间戳，重启时可识别“事件已
  落盘、任务状态尚未更新”的半写入窗口；`loadModelEvents` 仍从完整持久化历史重建下一
  轮模型输入，不把 UI 最近页当作上下文来源。
- 复现输入：分别恢复 (1) 只有 `running` 状态的任务，(2) 已持久化同一轮终止事件的
  任务，(3) 只有 `task.started`/`assistant.completed` 等非终止事件的半写入任务，
  并验证恢复后是否自动重放远程工具。
- 实际结果：无终止事件的活动任务统一为 `unknown` 并追加一次 `task.recovered`；已持久化
  的 `task.completed` 恢复为 `completed`；非终止半写入事件不会被误报成完成；恢复流程
  不启动 AgentLoop、不会重放 SSH 命令，用户继续对话时才显式发起新 turn。审查还复现了
  “同一 `turn_id` 的 `task.completed` 后出现 `assistant.completed`”会被旧判定错误接受，
  已将终止恢复条件收紧为最新事件同序列，或仅允许同轮的 `task.cancel_requested` 尾部记录。
  事件和附件的完整历史仍可通过分页/模型历史接口读取。
- 期望不变量：持久化尾部不完整时不能伪造成功；远程结果未知时必须要求检查并禁止
  自动重放；已确认的 terminal 结果可以恢复；恢复后的下一轮仍从事件历史而非 UI 缓存
  继续。事件落盘与任务投影不是一个 SQLite transaction，因此恢复判断必须同时检查
  两者，不能只相信任务状态或只相信最后一条非终止事件。
- 结论：`需修复已处理`，其余为`架构差异`。Codex 使用 rollout 文件和 `Interrupted`
  状态继续同一历史，Mobile 还要覆盖 SSH 远程副作用和手机进程退出，所以对活动任务
  采用 `unknown` + 人工检查的更保守产品契约。真实缺口是旧版
  `_terminalEventMatchesLatestEvent` 对任意同轮迟到事件放行，可能把不完整尾部误报为
  terminal；修复后只有同序列终止事件，或同轮取消请求尾部，才能恢复明确状态，不会启动
  新 turn 或重放远程操作。修复 commit：`a7cc134`。
- 定向测试：`test/app_controller_test.dart` 的启动中断恢复、持久化终止事件恢复和
  `a task with only a partially persisted nonterminal event is recovered as unknown`、
  `a late nonterminal event cannot make a terminal event authoritative`；
  使用 `env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/app_controller_test.dart` 验证。

### 2026-08-27：LIFE-04 远程 AGENTS.md 指令发现

- Codex 源码证据：固定 commit 的 `codex-rs/core/src/agents_md.rs:1-16`
  规定从项目根到当前工作目录收集指令且不越过根；`:39-46` 定义
  `AGENTS.override.md`/`AGENTS.md` 的默认优先级；`:65-76,115-181` 使用配置的总字节
  预算并在读取时截断；`:185-265` 以配置的 root marker 找最近项目根、按根到 cwd
  排序并允许符号链接；`:267-281` 支持额外 fallback 文件名。固定 commit 的
  `agents_md_tests.rs:627-705` 覆盖单文件/总预算截断，`:707-737` 覆盖父级标记不可读
  时仍加载 cwd，`codex-rs/core/tests/suite/agents_md.rs:183-228` 覆盖 override 优先，
  `:231-269` 覆盖 fallback 文件。
- Mobile 实现：`lib/agent/remote_instructions.dart:17-18` 使用同样的两个默认文件名和
  32 KiB 默认总预算；`:27-57` 从 cwd 向上查找 `.git`，`:58-96` 按项目根到 cwd 读取
  每级一个优先文件并在 UTF-8 边界截断；`lib/app_controller.dart:1259-1273` 只把找到的
  文档作为当前 server Agent 的可选上下文，不把它混入本地-only 模式。
- 复现输入：服务器目录同时存在根级 `AGENTS.md`、子目录
  `AGENTS.override.md` 和子目录 `AGENTS.md`；没有 `.git` 时再放置父级文档；最后让单个
  文档超过 32 KiB 并包含多字节字符，检查顺序、覆盖和预算。
- 实际结果：根文档先于 cwd 文档，cwd 的 override 替代同级 `AGENTS.md`；没有 `.git` 时
  只使用选定 cwd；总内容不超过 32 KiB 且不切断 UTF-8；目录列表或文件在发现后消失时
  不阻断正常 Agent turn。现有 `test/remote_instructions_test.dart` 的 3 项测试覆盖这些
  路径。
- 期望不变量：项目文档不能越过项目根或把同级 override 与基础文件重复发送；预算是
  总预算而非每个文件预算；文档是可选上下文，不能在服务器临时不可读时破坏正常连接。
- 结论：`架构差异`。默认运行时行为与 Codex 的核心发现规则一致。Codex 还支持配置
  `project_root_markers`、额外 fallback 文件名、多个环境和错误向上传递；Mobile 当前
  是单 SSH 工作目录、固定 `.git` 和固定默认文件名，且把远端指令视为可选上下文。这些
  是尚未暴露的产品配置差异，不会造成当前任务的上下文、连接或副作用生命周期错误，
  本轮不猜测添加配置层。
- 定向测试：`env PUB_CACHE=/www/mobile-agent-tooling/pub-cache /www/mobile-agent-tooling/flutter/bin/flutter test test/remote_instructions_test.dart`，与固定 Codex 的 `agents_md_tests.rs`/`core/tests/suite/agents_md.rs` 对照完成。

### 2026-08-27：LIFE-06 服务器级远程写入队列和停止目标

- Codex 源码证据：固定 commit 的
  `codex-rs/app-server/src/request_processors/turn_processor.rs:1540-1569`
  在处理 `turn_interrupt` 时读取活动 turn，并拒绝与当前 turn ID 不一致的停止请求；
  `codex-rs/core/src/session/turn.rs:155-161,396-601` 让一次 turn 的取消令牌和终止状态
  保持在同一轮次内。Codex 的统一执行器按单个进程串行化写入/轮询，但没有替 Mobile
  服务器范围的全局锁；服务器级锁是本应用为多个 SSH 会话定义的额外一致性规则。
- Mobile 实现：此前 `lib/app_controller.dart:1259` 以“服务器 + 工作目录”作为远程写
  队列键，绝对路径写入或不同目录下的命令可能同时修改同一服务器状态；手动
  `runServerCommand`、文件保存和状态脚本安装也绕过队列。`stopTask` 只按任务 ID 取得
  当前 cancellation，旧界面请求没有 turn 校验。
- 实际修复：服务器 Agent 的远程写入改用 `server.id` 作为队列键；一次性服务器命令、
  服务器文件保存和状态脚本安装也进入同一队列。目录读取、文件读取、仪表盘状态读取
  仍可并发；交互式终端是用户主动持有的独立 SSH shell，不伪装成 Agent 写队列。停止
  接口新增可选 `expectedTurnId`，聊天页面传入按钮生成时的活动 turn，旧请求不会取消
  后来的新 turn。
- 期望不变量：同一服务器的应用写操作按顺序执行；队列中已取消的 Agent 写操作不会
  迟到启动；读取不被无必要的全局串行化；停止请求不能跨 turn 取消。
- 结论：`需修复`，已处理。修复 commit：`a7cc134`。
- 定向测试：`test/app_controller_test.dart` 的
  `a stale stop request cannot cancel the active turn`；
  `test/agent_loop_test.dart` 的
  `remote writes for one server serialize across working directories`，并结合现有
  任务并发和取消测试验证。

### 2026-08-27：LIFE-07 分页快照、附件归属和历史恢复

- Codex 源码证据：固定 commit 的
  `codex-rs/thread-store/src/local/thread_history/segment_paging.rs:44-172,202-272`
  使用带 thread scope 的 cursor 和稳定排序读取历史页，分页不会把不属于当前线程的
  项目或后续增量混入当前结果；固定 commit 的
  `codex-rs/core/src/context/image_resize_notice.rs:35-79` 表明图片仍是上下文的一部分，
  物理存储/准备与模型可见历史是两个层次。
- Mobile 实现：`lib/app_controller.dart:241-258` 先读取旧页再合并到内存历史；如果
  读取期间追加新事件，原实现只合并读取开始时的旧快照，可能暂时覆盖新增事件。附件
  记录带 `taskId`，`loadAttachmentBytes` 和 `_loadAttachmentForTask` 会拒绝跨对话引用；
  事件只保存附件 ID，模型请求时才从独立存储恢复图片字节。
- 实际修复：分页查询完成后重新取当前任务的最新内存事件，再与旧页去重合并，保留加载
  期间追加的事件并按 sequence 排序。未把累计图片从上下文中擅自删除或改成摘要；这与
  Codex 图片仍属于模型上下文的语义一致。旧版本迁移失败仍是可重试的 best-effort 路径，
  不将无法写入的附件伪造为有效 ID；跨任务附件和历史引用已有回归覆盖。
- 期望不变量：分页不会覆盖并发追加的新事件；事件和附件引用属于同一对话；UI 分页
  不改变有效模型历史；图片物理独立保存但在请求需要时仍作为上下文输入。
- 结论：`需修复已处理（分页）`；附件归属和图片上下文是`架构差异/已覆盖`，未发现
  P0。删除失败留下的孤儿文件和一次性加载附件记录属于 P2 清理优化，本轮不扩大修改。
- 定向测试：`test/app_controller_test.dart` 的
  `loading earlier events keeps an event appended during the load`、
  `attachment ids cannot be reused across conversations`、
  `100 cumulative image messages load from the database in pages`。

### 2026-08-27：CTX-05 上下文指示器与 Chat Completions 标注

- Codex 源码证据：固定 commit 的
  `codex-rs/protocol/src/protocol.rs:2281-2325` 使用 12,000 token baseline，
  以 `last_token_usage.total_tokens` 计算当前活动窗口的剩余百分比；
  `codex-rs/tui/src/chatwidget.rs:1154-1177` 明确把当前轮 usage 用于百分比，
  不把 `total_token_usage` 当作当前窗口；相关测试为
  `codex-rs/tui/src/chatwidget/tests/status_and_layout.rs:20-45,176-195`。
- Mobile 实现：`lib/agent/context_usage.dart:164-183` 保持同一计算式，使用有效窗口
  （模型窗口按 Codex 的有效比例预留 headroom）和最新 `last`，`total` 只用于详情中的
  累计用量；`lib/ui/chat_page.dart:451-466,2207-2308` 将图标和百分比放在输入框之后的
  `_ConversationFooter` 最后一行，并支持点击查看详情。
- 修正：`wireApiLabel` 将 Chat Completions 显示为“兼容模式”。该协议仍可正常进行普通
  对话和工具调用，但本应用不把它伪装成 Responses 的 Codex 上下文压缩协议；底部只显示
  `--`，详情显示本次/累计供应商用量，并明确标注有效窗口和自动压缩对兼容模式不适用。
  Responses 模式继续显示真实的当前窗口剩余百分比，窗口或 usage 不存在时显示 `--`，
  不用累计 token 或字符估算补值。
- 定向测试：`test/domain/models_test.dart` 的
  `Chat Completions is labeled as compatibility mode`；已有
  `Codex model metadata resolves effective window and auto compaction` 覆盖 52% 计算。
- 结论：百分比计算与 Codex 源码等价；协议标注和兼容模式 UI 是产品层补充，避免用户把
  Chat Completions 的供应商 usage 误认为 Responses 的自动压缩状态。

### 2026-08-27：CTX-03 / PRO-01 主动压缩路径复核与修复

- 官方文档说明 Responses 同时存在两种能力：普通 `/responses` 请求可以通过
  `context_management` 使用服务端压缩，另有独立的 `/responses/compact` 无状态接口。
  这两者不是每个兼容供应商都实现的同一能力，不能仅凭 `wire_api=responses` 推断。
- 固定 Codex 源码给出了本项目实际需要的分支依据：
  `codex-rs/model-provider/src/provider.rs:341-353` 对自定义供应商返回
  `RemoteCompactionSupport::Unsupported`；`codex-rs/core/src/tasks/compact.rs:60-76`
  因此构造 `SUMMARIZATION_PROMPT` 作为普通用户输入；
  `codex-rs/core/src/compact.rs:257-398` 使用普通 Responses 生成摘要，再保留用户消息并把
  摘要作为 `CompactionSummary` 用户项写回新的历史。只有明确支持远程压缩的供应商才走
  `/responses/compact`。
- 同一供应商的受控真实测试结果：普通 `/responses` 返回 `200`；独立
  `/responses/compact` 返回 `502`；普通 `/responses` 追加 Codex 压缩提示词仍返回 `200`。
  测试只使用临时密钥，密钥没有写入代码、文档、日志或提交。
- 旧 Mobile 实现把所有 Responses 供应商固定送到 `/responses/compact`，所以与 Codex
  使用同一供应商时仍会失败。现已将 `lib/agent/openai_compatible_client.dart` 的
  `AiCompactionClient.compact` 改为普通 `/responses`：移除 system 输入并以
  `instructions` 传入，工具列表为空，最后追加固定 Codex `SUMMARIZATION_PROMPT`，只接受
  模型返回的摘要文本。正常对话仍使用原有 Responses 请求；Chat Completions 路径没有任何
  自动回退或协议切换。
- `lib/app_controller.dart` 的手动和自动压缩现在写入
  `compaction_mode: local` 与 `summary`。摘要按 Codex 的 `CompactionSummary` 作为
  synthetic user item 恢复，而不是伪造 opaque `compaction` output item；
  `lib/storage/app_database.dart` 和 `lib/storage/memory_app_database.dart` 都把该事件识别
  为新的历史边界，仍保留完整显示事件和附件文件。
- 定向测试：`test/openai_compatible_client_test.dart` 的
  `Responses compaction uses the ordinary endpoint and Codex local prompt`、
  `Responses local compaction surfaces an ordinary request error`；
  `test/app_controller_test.dart` 的
  `manual Responses compaction stores the Codex local summary`、
  `failed manual compaction does not write a context event`、
  `manual compaction is rejected while a task is running`。
- 结论：`需修复已处理`。本次修复与 Codex 自定义供应商能力判断一致，解决“Codex 可压缩而
  APP 失败”的真实缺口；压缩仍由同一供应商和同一模型完成，图片/文件仍属于输入上下文，
  但不把物理附件内容复制进事件。
- 修复 commit：`a7cc134`。

### 2026-08-27：CTX-04 / PRO-05 ID-only 模型元数据缺口

- Codex 源码证据：固定 commit 的 `codex-rs/models-manager/models.json` 中
  `gpt-5.6-luna` 明确配置 `context_window: 272000`、
  `max_context_window: 872000`、`effective_context_window_percent: 95`、
  `auto_compact_token_limit: null`；`codex-rs/protocol/src/openai_models.rs`
  的 `resolved_context_window()` 先取 `context_window`，缺失时才取
  `max_context_window`，默认自动压缩阈值为窗口的 90%。
- 复现输入：供应商 `/models` 返回 `{"data":[{"id":"gpt-5.6-luna"}]}`。
  应用把该条目保存为只有模型 ID 的 `ProviderModelMetadata`，随后原有解析逻辑优先
  返回这个空条目，导致上下文窗口、自动压缩阈值和百分比全部显示未知，自动压缩也
  不会触发。
- 修复：`lib/domain/models.dart` 的 `resolveProviderModelMetadata()` 现在把已知
  Codex catalog fallback 与供应商元数据合并；ID-only 条目不能遮蔽 fallback，供应商
  明确返回的窗口、压缩策略和能力字段仍优先。`lib/app_controller.dart` 已统一通过
  该解析结果生成上下文统计、Responses 输入模态和压缩阈值；
  `lib/providers/provider_connection_tester.dart` 的连接测试也使用同一解析结果。
  未知第三方模型使用 Codex 的通用 fallback；这不是对供应商真实窗口的宣称，供应商
  明确返回的元数据仍然覆盖它。
- 结果：`gpt-5.6-luna` 的 raw/effective/auto-compact 值分别为
  `272000 / 258400 / 244800`；百分比继续使用 Codex 的
  `last_token_usage.total_tokens` 和 12000 baseline 计算。
- 同时修复压缩错误提示：`404/405` 明确提示供应商未提供
  `/responses/compact`，`5xx` 明确提示上游暂时不可用并可重试；两者都不会自动切换
  到 Chat Completions。
- 定向测试：`test/domain/models_test.dart` 的
  `id-only provider metadata keeps the known Codex model window`；
  `test/app_controller_test.dart` 的
  `context usage resolves Codex fallback for id-only provider metadata`；
  `test/openai_compatible_client_test.dart` 的两个压缩 HTTP 错误测试。
- 结论：`需修复已处理`。这是上一版审查把“没有覆盖 ID-only 条目”误判为已等价的真实
  缺口；本记录取代该结论，后续不再重复查询同一问题，除非固定 Codex commit、元数据
  解析实现或上述定向测试再次发生变化。
- 修复 commit：`a7cc134`。

### 2026-08-27：CTX-04 通用模型默认窗口

- Codex 源码证据：固定 commit 的 `codex-rs/models-manager/src/model_info.rs`
  `model_info_from_slug()` 为缺少目录条目的模型生成 fallback：
  `context_window: 272000`、`max_context_window: 272000`、
  `effective_context_window_percent: 95`、`auto_compact_token_limit: null`，并使用
  `bytes: 10000` 的工具输出策略；`codex-rs/protocol/src/openai_models.rs` 再按窗口
  的 90% 得出默认自动压缩阈值。
- 调整：`codexFallbackMetadataForModel()` 现在为所有没有明确窗口元数据的模型提供这组
  默认值。已知 Codex 目录模型仍使用自己的目录条目，例如 Luna 的
  `max_context_window: 872000`；供应商明确的 `context_window`、压缩策略和能力字段
  仍优先覆盖 fallback。
- 结果：普通模型不再因为 `/models` 只返回 ID 或没有模型元数据而显示未知；上下文统计
  和自动压缩判断使用 `272000 / 258400 / 244800`。这属于 Codex fallback，不等同于
  对第三方模型真实上下文上限的检测。
- 定向测试：`test/domain/models_test.dart` 的
  `unknown provider models use the Codex fallback window by default`，以及既有的
  ID-only Luna 和上下文控制器测试。
- 结论：`需修复已处理`。后续只有 Codex fallback 规则、供应商明确元数据或对应实现
  发生变化时才重新审查。
- 修复 commit：`a7cc134`。

### 2026-08-27：CTX-04 默认窗口与最大窗口可切换

- Codex 源码证据：固定 commit 的
  `codex-rs/models-manager/models.json` 为 `gpt-5.6-sol`、
  `gpt-5.6-terra` 和 `gpt-5.6-luna` 同时提供
  `context_window: 272000` 与 `max_context_window: 872000`；
  `codex-rs/protocol/src/openai_models.rs` 的
  `resolved_context_window()` 默认优先使用 `context_window`，而
  `model_context_window` 配置允许在模型最大窗口范围内覆盖默认值。
  官方 OpenAI 模型页面（`https://developers.openai.com/api/docs/models/gpt-5.6`）
  显示的是 API 层模型能力，不等同于 Codex 客户端目录的 `max_context_window`；
  官方 compaction 文档（`https://developers.openai.com/api/docs/guides/compaction.md`）
  说明压缩阈值由请求上下文策略驱动，本应用不把两层窗口值混用。
  官方模型页面的 `gpt-5.6` alias 解析到同一 Sol 模型，因此应用也按该目录规则处理
  精确的 `gpt-5.6` alias。
- 复现输入：同一 `gpt-5.6-luna` 元数据分别使用 `default` 和 `maximum` 模式。
  默认模式应解析为 `272000 / 258400 / 244800`（raw/effective/auto）；最大模式
  应解析为 `872000 / 828400 / 784800`。没有大于默认值的
  `max_context_window` 时，最大模式回落到默认窗口。
- 修复：`ProviderProfile.contextWindowMode` 增加持久化的 `default` / `maximum`
  两档选择；数据库从 v10 升级到 v11 时旧供应商默认为 `default`。
  `ProviderModelMetadata` 增加按模式解析窗口、有效窗口和自动压缩阈值的方法。
  `AppController` 在上下文统计、自动压缩判断、缓存失效身份和事件快照中统一使用
  供应商当前模式；供应商设置页提供窗口模式下拉项。未知模型仍使用
  Codex 通用 fallback 的 `272000 / 272000`，不会因选择最大模式伪造更大上限。
- 结论：`需修复已处理`。这是对已封存 CTX-04 的产品配置扩展，不改变 Responses/
  Chat Completions 协议，不发送未经供应商声明的窗口参数，也不改变凭据或远程工具
  边界。切换模式后只重新计算本地上下文百分比和压缩阈值，并保留对话历史。
- 定向测试：`test/domain/models_test.dart` 的
  `Codex model can switch between default and maximum windows`、
  `provider context window mode survives round-trip and invalid values use default`；
  `test/app_controller_test.dart` 的
  `context usage follows the provider window mode` 和供应商保存恢复测试。
- 修复 commit：`a7cc134`。

### 2026-08-28：配置切换保留模型上下文

- 复核发现 Mobile 原先把工作模式、项目、服务器和工作目录变化写成
  `history_boundary: true`，导致下一轮模型只能看到新的 system/developer 内容，虽不删除
  UI 历史，却丢失了可复用的对话上下文。这不是 Codex 压缩要求，而是本项目过度保守的
  配置边界。
- 调整：所有对话配置变化统一写入 `history_boundary: false`，保留普通消息、附件、工具
  结果和可复用的 Responses 历史；同时追加配置变更 developer 提示，要求 AI 把旧目标
  状态当作历史参考、不得重放旧工具调用，并先检查当前目标。跨供应商仍只移除不能复用
  的 provider-owned opaque 状态。
- 兼容：SQLite 和内存数据库不再把旧版本配置事件中的 `history_boundary: true` 当作硬
  边界，因此已有对话不会因升级后继续丢上下文。真正的 compaction 仍按其自身压缩边界
  使用摘要和近期用户消息；新建对话只是创建新的空任务，不清理旧任务。
- 定向测试：`work mode changes retain history and add a configuration note`、
  `legacy configuration boundary does not discard history`，以及原有 app controller
  测试均通过。

## 8. 当前封存快照（2026-08-27）

| 范围 | 条目 | 最终状态 | 入口 |
| --- | --- | --- | --- |
| 上下文与历史 | CTX-01 至 CTX-06 | 已等价/架构差异；真实缺口已处理 | 本文第 4 节 A 表及对应记录 |
| 协议、SSE 和错误 | PRO-01 至 PRO-06 | 已等价/架构差异；真实缺口已处理 | 本文第 4 节 B 表及对应记录 |
| 工具、SSH 和副作用 | EXEC-01 至 EXEC-07 | 已等价/架构差异；真实缺口已处理 | 本文第 4 节 C 表及对应记录 |
| 轮次、并发和持久化 | LIFE-01 至 LIFE-07 | 已等价/架构差异；真实缺口已处理 | 本文第 4 节 D 表及对应记录 |

- 本轮没有 `待复核` 或 `复核中` 的 P0/P1 条目；后续只有固定 Codex commit、对应
  Mobile 实现或定向测试发生变化时才重新打开条目。
- 已处理的真实缺口包括：Responses 压缩和输出 fallback、SSH 断链未知状态、文件边界、
  用户事件失败持久化、服务器级写入队列、停止目标校验、分页并发合并，以及 ID-only
  Codex 模型的上下文元数据 fallback。
- 已知但不在本轮扩大范围的项目：steer/mailbox 产品差异、交互式终端与 Agent 的人工
  并发、旧版附件迁移失败后的重试、超大附件估算/清理优化。这些没有被记录为新的 P0/P1。
- 验证封存基线：`flutter analyze` 无问题；`flutter test` 全量 148 项通过；
  `git diff --check` 通过。该基线对应 beta.11；beta.12 发布记录见下方。当前 ID-only
  fallback 修复尚未发布。

### 2026-08-27：Beta 1.0.3-beta.12 发布记录

- 发布 commit：`b0c7ff4`（`feat: add manual context compaction`）。
- 版本：`1.0.3-beta.12+21`；GitHub 标签：`v1.0.3-beta.12`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.12-release.apk`。
- APK 校验：`76,411,879` bytes；SHA-256
  `9878437aade984fb61c3df5883169939bcc0b955c59a8dc07663529f5e85ae7b`。
- 发布前验证：`flutter analyze` 通过；`flutter test` 全量 149 项通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-27：Beta 1.0.3-beta.13 发布记录

- 发布内容：修复 Responses 主动/自动压缩请求携带不属于 `/responses/compact` 的顶层
  `tools`、`parallel_tool_calls` 和 `reasoning` 字段；补齐 ID-only 模型的 Codex
  上下文元数据 fallback，并支持默认/最大上下文窗口切换。
- 版本：`1.0.3-beta.13+22`；GitHub 标签：`v1.0.3-beta.13`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.13-release.apk`。
- APK 校验：`76,411,879` bytes；SHA-256
  `e970252f071a14b901f5192dc58ab1a6b1127ee2ad4ab0d29ce0751213969c88`。
- 发布前验证：定向测试 88 项通过；`flutter analyze` 通过；`git diff --check`
  通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-27：同一供应商主动压缩复核与修复记录

- 复现结果：使用用户提供的同一兼容供应商和 `gpt-5.6-luna` 发送普通
  `POST /responses`，流式响应返回 `HTTP 200` 和完整摘要；此前失败请求为
  `POST /responses/compact`，不能据此判断供应商不支持 Codex 压缩。
- Codex 源码依据：固定快照中自定义供应商的
  `RemoteCompactionSupport::Unsupported` 分支调用普通 Responses 请求，追加
  `SUMMARIZATION_PROMPT`；OpenAI/Azure 能力分支才调用独立 compact endpoint。
- Mobile 修复：Responses 自动/手动压缩统一走普通 `/responses`；请求继续使用当前供应商、模型、推理强度和 API Key，不切换 Chat Completions。压缩事件保存 Codex 摘要及最近用户文本，重启恢复时不重复注入自动压缩轮次的当前用户。
- 验证：`openai_compatible_client_test.dart` 与 `app_controller_test.dart` 共 68 项通过；真实普通 Responses 请求 `HTTP 200`；未保存用户提供的临时 API Key。

### 2026-08-27：Beta 1.0.3-beta.14 发布记录

- 发布内容：按 Codex 自定义供应商的本地压缩路径修复主动/自动压缩；同一供应商使用普通
  `/responses` 生成摘要，并保留最近用户文本作为下一次请求的历史。
- 版本：`1.0.3-beta.14+23`；GitHub 标签：`v1.0.3-beta.14`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.14-release.apk`。
- APK 校验：`76,493,799` bytes；SHA-256
  `19f49626ba3e33c19236180a6907ad0bd93336fbfd07e2ba5c61d63216341afd`。
- 发布前验证：`flutter test` 全量 156 项通过；`flutter analyze` 通过；`git diff --check`
  通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Beta 1.0.3-beta.15 发布记录

- 发布内容：工作模式、项目、服务器和工作目录切换不再截断对话上下文；追加配置变更
  提示并保留旧对话，兼容旧版本遗留的历史边界事件。新建对话只创建空任务，不清理已有
  对话或历史。
- 功能修复提交：`ccd2d58`；版本提交：`cecb7f4`；GitHub 标签：`v1.0.3-beta.15`。
- 版本：`1.0.3-beta.15+24`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.15-release.apk`。
- APK 校验：`76,493,795` bytes；SHA-256
  `ba6fff6487804617f7e9f7aa291ac36c21a5fef1f48a3171bf068fbaf08478e1`。
- 发布前验证：`flutter analyze` 通过；聚焦测试 46 项通过；`flutter test` 全量通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：源码依据纠正与普通对话模式修复

- `wflcodexdesktop` 仅是网站层的产品实现，不能作为 Codex 协议行为的依据；本轮协议结论
  只引用固定的官方 `openai/codex` 源码快照和 OpenAI 压缩文档。
- 官方源码 `codex-rs/model-provider/src/provider.rs` 明确把自定义供应商标记为
  `RemoteCompactionSupport::Unsupported`；`codex-rs/core/src/tasks/compact.rs` 和
  `codex-rs/core/src/compact.rs` 因此使用普通 `/responses` 加 `SUMMARIZATION_PROMPT`，
  生成 `CompactionSummary` 并保留最近用户消息。当前 APP 已恢复该路径，不会把所有
  Responses 供应商错误地送到 `/responses/compact`。
- 旧数据若同时存在 `mode=chat` 和遗留 Agent `workMode`，加载时归一化为 `workMode=chat`，
  解决普通对话顶部显示“协同”；显式创建或切换 Agent 工作模式的语义不变。
- 定向回归：`flutter test` 相关模型、协议、控制器和聊天页面测试 89 项通过；全量
  `flutter test` 158 项通过，`flutter analyze` 和 `git diff --check` 均通过。

### 2026-08-28：Beta 1.0.3-beta.16 发布记录

- 发布内容：恢复自定义供应商按 Codex 本地压缩路径处理；普通对话不再受遗留 Agent
  工作模式影响；切换工作模式后顶部显示与当前任务同步；保留配置变更后的既有上下文。
- 功能修复提交：`685e1bb`；版本提交：`1f68a0e`。
- 版本：`1.0.3-beta.16+25`；GitHub 标签：`v1.0.3-beta.16`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.16-release.apk`。
- APK 校验：`76,493,795` bytes；SHA-256
  `5de5242ed767ae1b4e6c7dc99364f1c355ef66d84ad78843bc34fd28414b56bb`。
- 发布前验证：`flutter analyze` 通过；`flutter test` 全量 158 项通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：PRO-01 普通 Responses 服务端压缩接入

- 官方 OpenAI 压缩文档明确区分两条路径：普通 `POST /responses` 通过
  `context_management: [{type: "compaction", compact_threshold: N}]` 启用服务端压缩；
  独立 `POST /responses/compact` 用于显式生成新的压缩窗口。服务端压缩会在响应流中返回
  opaque compaction item，后续 stateless 请求要原样追加该 item，并可丢弃它之前的输入。
- 真实复现：用户提供的同一供应商 `gpt-5.6-luna` 对普通 `/v1/responses` 携带
  `context_management` 返回 `HTTP 200`；独立 `/v1/responses/compact` 返回 `HTTP 502`。
  因此此前把独立 endpoint 失败归因于供应商不支持压缩的结论不成立，问题是 APP 选择了
  不适用的请求路径。进一步将阈值设为 `1000` 并发送约 25,000 字符的受控输入，响应
  output 类型包含 `compaction`，确认服务端实际触发了压缩。
- Mobile 修复：`OpenAiCompatibleClient` 增加可选的自动压缩阈值；普通 Responses 请求
  发送官方 `context_management`，阈值由当前模型元数据和默认/扩展窗口模式解析得到。
  `AppController` 不再在请求前或工具轮次后执行本地自动摘要，避免远程压缩和本地摘要重复。
  Chat Completions 不发送该字段，也不自动切换协议。
- 手动压缩仍保留兼容供应商的 Codex 本地摘要路径；该请求显式关闭
  `context_management`，避免手动摘要请求再次触发服务端压缩。普通请求收到的 compaction
  output item 继续由现有 Responses 历史持久化和边界裁剪逻辑处理。
- 定向测试：`test/openai_compatible_client_test.dart` 的
  `Responses sends the configured server-side compaction threshold`；
  `test/app_controller_test.dart` 的 `manual Responses compaction stores the Codex local summary`
  同时验证手动请求不带该字段、后续普通请求带 `244800` 阈值。`flutter test` 全量 160 项、
  `flutter analyze` 均通过；真实请求返回 `HTTP 200`。
- 结论：`需修复已处理`。后续只有官方字段、固定 Codex 源码、供应商协议或上述测试发生变化
  时重新审查，不再重复把 `/responses/compact` 的失败当作普通服务端压缩失败。
- 修复 commit：`a7cc134`。

### 2026-08-28：手动压缩接口再次真实验证

- `/v1/models` 返回 `gpt-5.6-luna`，同一供应商的普通
  `POST /v1/responses` 使用该模型返回 `HTTP 200`，所以模型名和基础鉴权不是
  `/responses/compact` 失败原因。
- 按官方文档和 Codex `CompactionInput` 分别发送了完整 Codex 字段、官方简化
  `input` 数组、字符串 `input`，以及不带 `/v1` 的路由；`POST
  /v1/responses/compact` 均返回 `HTTP 502 upstream_error`。使用
  `previous_response_id` 则返回 `HTTP 400`，提示该字段仅支持 Responses WebSocket v2。
- WFL 供应商真实测试使用普通 `POST /responses` 和最低合法阈值 `1000`，返回
  `HTTP 200` 及两个真实 `compaction` output item。这证明该供应商的服务端自动压缩
  已可用，但不能把它等同于 HTTP standalone compact endpoint 已可用。
- 结论：当前 `OpenAiCompatibleClient.compact` 继续走普通 Responses 请求，关闭
  `context_management` 并追加 Codex `SUMMARIZATION_PROMPT`，由同一 API 模型生成
  手动摘要；这对应 Codex 的 `RemoteCompactionSupport::Unsupported` 分支。只有供应商
  明确可用并通过真实验证后，才应增加独立 `/responses/compact` 路径；不做静默协议切换。
- 本次仅更新审查记录，没有改动代码、没有保存临时 API Key，也没有重新构建发布。

### 2026-08-28：Sub2API `/responses/compact` 路由与实际能力核查

- 研究源码位于 `/www/mobile-agent-tooling/sub2api-research`，固定 commit 为
  `e866ff6ec431816e8b9d4b81dc7b00122ca3f7f8`，与当前 `main` 一致。
- Sub2API 确实开放了 compact 网关入口：
  `backend/internal/server/routes/gateway.go:221-227` 注册 `/v1/responses/*subpath`，
  `:361-362` 注册不带 `/v1` 的 `/responses/*subpath`，`:374-375` 注册
  `/backend-api/codex/responses/*subpath`。`endpoint.go:108` 将 compact 单独归一化，
  不是普通 Responses 根路径的误匹配。
- 这只是网关入口，不代表所有后端账号都能执行。`openai_gateway_handler.go:350-360`
  区分 legacy `/responses/compact` 与 native v2；legacy 路径在 `:524` 设置
  `requireCompact=true`，并在 `:541-570` 要求 Responses 能力且按账号 compact 能力调度。
  `openai_gateway_request_body.go:382-385` 识别 `/compact`，
  `openai_gateway_forward.go:1311-1316` 将该后缀拼到实际上游 Responses URL。
- 账号级 `compact_model_mapping` 只作用于 legacy compact，见
  `account.go:934-955` 与 `openai_gateway_scheduling.go:796-845`。此外，若没有账号级匹配，
  `openai_compact_fallback.go:52-71` 使用进程级配置；`config.go:1002-1004,2373`
  和 `deploy/config.example.yaml:308-312` 的默认值是 `gpt-5.4`。在
  `openai_gateway_forward.go:367-384` 中，这个“fallback”会在 legacy compact 的首次
  转发前直接应用，因此没有覆盖配置时，`gpt-5.6-luna` 可能先被改写成 `gpt-5.4`。
- Sub2API 自带的账号 compact 测试并不测试 legacy `/responses/compact`：
  `account_test_service.go:2026-2083` 构造的是普通流式 `/responses` 加
  `compaction_trigger`，`openai_compact_probe.go:27-30` 也明确注明 legacy unary
  `/responses/compact` 已在其所针对的上游下线。因此“账号被标记支持 compact”可能只代表
  native v2/普通 Responses 压缩链，不等于 standalone endpoint 已可用。
- 真实验证使用同一供应商、同一 `gpt-5.6-luna`：普通 `/v1/responses` 返回 `200`；普通
  `/v1/responses` 携带官方 `context_management` 字段返回 `200`（短输入，仅证明字段被接受，
  不据此宣称已触发压缩）；直接 `/v1/responses/compact` 返回 `502 upstream_error`；
  普通 `/v1/responses` 加 `compaction_trigger` 的 native v2 形态也返回 `502`。
- 结论：用户记得的事实是对的，Sub2API 明确开放了 `/responses/compact` 网关路由；但当前
  真实链路仍不能据此启用 APP 的 standalone compact。502 是入口之后的上游转发/能力或模型映射
  问题，不是“没有路由”。在供应商明确配置并真实验证 standalone 返回合法 compact 输出前，
  APP 手动压缩继续使用普通 `/responses` 的 Codex 本地摘要路径；普通请求的服务端压缩继续使用
  `context_management`。本次没有改代码、没有保存临时 API Key、没有重新构建发布。

### 2026-08-28：Beta 1.0.3-beta.17 发布记录

- 发布内容：侧栏下半部分紧凑化；顶部增加 HTML 预览入口；启动时恢复上次打开的对话；
  Responses 服务端自动压缩与手动压缩兼容路径稳定化。
- 功能修复提交：`a7cc134`；版本提交：`50efe3d`。
- 版本：`1.0.3-beta.17+26`；GitHub 标签：`v1.0.3-beta.17`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.17-release.apk`。
- APK 校验：`76,493,799` bytes；SHA-256
  `11b4eb1dcf45a48bdfac63741a376144f27687d67186de341be123a507da2aff`。
- 发布前验证：`flutter analyze` 通过；`flutter test` 全量 161 项通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Beta 1.0.3-beta.18 发布记录

- 发布内容：更新页支持 APP 内下载 APK、显示进度并调用 Android 系统安装器；保留浏览器打开
  和复制下载链接；已下载 APK 缓存到 APP 私有目录，安装权限不足时可直接重试。平板对话框
  底部操作组右对齐，窄屏模型按钮可收缩或换行；平板侧栏适度放大并扩展为 360dp。
- 功能修复提交：`1f999ba`；版本提交：`fc73378`。
- 版本：`1.0.3-beta.18+27`；GitHub 标签：`v1.0.3-beta.18`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.18-release.apk`。
- APK 校验：`76,511,035` bytes；SHA-256
  `943dfcc08bc890855bcdcffdfb040dd5bfec91e8c50d35c3bdc86c0aa429b39b`。
- 发布前验证：`flutter analyze` 通过；`flutter test` 全量 163 项通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Agent 工具调用前置说明与流式消息时序

- Codex 源码证据：固定 commit `f5420174dafba153913a3e697f89002c338dfd7e` 的
  `codex-rs/core/gpt_5_1_prompt.md:37-49,186-193` 要求长时间工具调用期间持续让用户知道进展，
  并在第一次工具调用前先发送简短计划；`codex-rs/core/src/stream_events_utils.rs` 的
  `realtime_text_for_event` 将模型真实输出作为实时消息交付，`turn.rs` 在输出 item 完成后再
  排队工具执行。Codex 的 `MessagePhase::Commentary` 是供应商/模型返回的阶段信息，不能由
  客户端伪造成 AI 回复。
- Mobile 原问题：`lib/app_controller.dart` 的 Agent system prompt 只要求持续完成任务，
  没有前置计划和阶段进度约定；收到 `assistant.completed` 时先清除临时流式文本，再异步写入
  事件库。模型若直接返回工具调用，用户会看到命令连续执行，前置说明即使真实返回也可能短暂
  消失。
- 复现输入：假 Responses 服务首轮返回一条 assistant 文本“我先检查当前状态，再继续。”和
  一个 `local.list` function call，第二轮返回“检查完成。”；监听控制器通知，检查前置说明、
  `tool.started` 和最终回复的顺序。
- 修复：`lib/app_controller.dart:_systemPrompt` 增加 Codex 同语义的首次计划和阶段进度要求，
  明确这是简短 commentary，不要求叙述每条命令；流式文本在对应 `assistant.completed`、工具
  失败或任务终态事件完成持久化后才清除。没有生成虚假 AI 消息，也没有减少工具能力或改变审批策略。
- 定向测试：`test/app_controller_test.dart` 的
  `agent persists its streamed preamble before starting a tool call`，使用本地假 Responses
  服务覆盖真实请求、首轮工具调用、事件持久化和终态回复；`test/agent_loop_test.dart` 与该
  控制器测试共 71 项通过。
- 结论：此前属于 `需修复`；现已处理。Responses 未暴露 phase 时仍按普通 assistant 文本
  兼容，只有模型真实返回的文本会显示为前置说明；功能修复已提交为 `8cc8e0a`。

### 2026-08-28：Beta 1.0.3-beta.19 发布记录

- 发布内容：修复手机 Agent 在首轮工具调用前没有稳定显示模型进度的问题；保留真实流式
  commentary，先持久化 assistant 事件再清理临时文本，避免命令执行期间前置说明消失。
- 功能修复提交：`8cc8e0a`；版本提交：`96856a8`。
- 版本：`1.0.3-beta.19+28`；GitHub 标签：`v1.0.3-beta.19`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.19-release.apk`。
- APK 校验：`76,511,035` bytes；SHA-256
  `92c45c1f3d41d3e2ff9e5e310deb7b59c6f703296b59f32fa3fa16969298547e`。
- 发布前验证：`flutter analyze` 通过；Agent 控制器和循环定向测试 71 项通过；
  `git diff --check` 通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Beta 1.0.3-beta.20 发布记录

- 发布内容：统一手机端 iOS 视觉风格，调整对话输入区、消息气泡、状态胶囊、侧栏和
  服务器仪表盘的表面层级与间距；接入 WFL `wfl_image_provider` 生成并规范化的服务器
  机架 + AI 星标应用图标。
- 功能提交：`526b80c`；版本提交：`923b5d5`。
- 版本：`1.0.3-beta.20+29`；GitHub 标签：`v1.0.3-beta.20`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.20-release.apk`。
- APK 校验：`77,324,139` bytes；SHA-256
  `6f6250e399b724ba8a6e39b0d098990e5899abb3807ed92ff037e2e4db1cda11`。
- 发布前验证：`flutter analyze` 通过；本轮完整 `flutter test` 164 项通过；
  `git diff --check` 通过；APK 构建和图标资源检查通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Beta 1.0.3-beta.21 发布记录

- 发布内容：为服务器文件下载增加 512KB SFTP 分块读取和 `.part` 续传元数据；文件管理器
  和 `server.download_to_project` 都使用同一套可恢复下载流程，断线后按已写入字节继续，
  完成后才替换正式文件；后台任务增加前台服务进度、部分唤醒锁和可选跨 App 悬浮胶囊。
- 功能提交：`b391f74`；版本提交：`372f8e5`。
- 版本：`1.0.3-beta.21+30`；GitHub 标签：`v1.0.3-beta.21`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.21-release.apk`。
- APK 校验：`77,422,583` bytes；SHA-256
  `f7147e9ec90eca1097780610ff9e0dfef5d094de2055c7db6dc4a97b9c55b734`。
- 发布前验证：`flutter analyze` 通过；续传、SSH、Agent、远程工具和设置页聚焦测试 89 项
  全部通过；`git diff --check` 通过；release APK 构建通过。构建输出和 APK 均位于 `/www` 数据盘。

### 2026-08-28：Beta 1.0.3-beta.22 发布记录

- 发布内容：增加手机文件上传的 512KB 分块续传、服务器临时文件原子提交和断线重连；工具
  卡片及后台悬浮窗显示真实命令或文件路径摘要；悬浮窗显示对话名称、运行时间和当前动作，
  并优化为半透明 iOS 风格玻璃质感；对话顶部增加悬浮窗图标开关。
- 功能提交：`32c314c`；版本提交：`0c59063`。
- 版本：`1.0.3-beta.22+31`；GitHub 标签：`v1.0.3-beta.22`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.22-release.apk`。
- APK 校验：`77,455,419` bytes；SHA-256
  `53ddff8f84491747f197e6b982437a272af2ed4e33a1c8471431278a8e4d4bcf`。
- 发布前验证：`flutter analyze` 通过；控制器、工具摘要、上传续传、SSH 和远程指令定向测试
  65 项全部通过；`git diff --check` 通过；release APK 构建通过。构建输出和 APK 均位于 `/www`
  数据盘。

### 2026-08-28：Agent 任务规划与悬浮计划胶囊

- Codex 源码证据：固定 commit `f5420174dafba153913a3e697f89002c338dfd7e` 的
  `codex-rs/core/src/tools/handlers/plan_spec.rs` 定义 `update_plan` 工具，参数为可选的
  `explanation` 和 `plan[{step,status}]`，状态为 `pending`、`in_progress`、`completed`；
  `codex-rs/core/src/tools/handlers/plan.rs` 将它作为不产生外部副作用的内置控制工具并发出
  计划更新事件；`codex-rs/app-server/README.md` 将对应客户端事件定义为
  `turn/plan/updated`，计划可以在执行过程中反复更新。
- Mobile 原问题：`AgentLoop` 没有暴露 `update_plan`，控制器虽然在 system prompt 中要求
  前置计划，但模型无法产生结构化计划事件，因此用户只能看到连续工具调用。
- 修复：`lib/agent/agent_loop.dart` 在非对话 Agent 任务中加入同名本地控制工具，校验
  Codex 计划格式并发出持久化 `task.plan` 事件；计划工具不请求审批、不连接服务器，普通
  工具调用和旧历史仍按原流程处理。`lib/app_controller.dart` 将计划事件映射到后台任务进度，
  并明确要求多步骤任务在第一次项目/服务器工具前调用并持续更新计划。
- UI：`lib/ui/chat_page.dart` 不把计划渲染成普通消息或命令卡片，而是在状态胶囊右侧显示
  同尺寸半透明计划胶囊；折叠态显示已完成数、总数和当前步骤，点击后向上展开完整清单，
  多次计划更新只取最新清单，计划仍保留在事件历史中。
- 定向测试：`test/agent_loop_test.dart` 验证模型可见 `update_plan`、事件内容和工具结果；
  `test/ui/chat_page_test.dart` 验证计划胶囊和向上展开；本轮定向测试 35 项通过。
- 结论：此前属于 `需修复`；现已处理。修复尚未提交，最终提交前需再次运行全量分析、测试和
  `git diff --check`。

### 2026-08-29：服务器二进制文件下载到手机

- 复现：服务器 Agent 生成或找到 DOCX、ZIP、图片等二进制文件后，模型只能看到
  `local.write` 文本工具；当用户目标是 `/storage/emulated/0/Download/...` 时，模型无法把
  文件字节直接落盘，只能建议用户手工复制。
- 根因：SFTP 和 `server.download_to_project` 已经支持二进制分块及断点续传，但后者只在有
  手机项目时暴露，且没有项目外手机目标工具。`local.write` 明确是 UTF-8 文本写入，不能承担
  二进制复制。
- 修复：`RemoteAgentTools` 新增 `server.download_to_phone`，复用
  `ResumableFileDownloader` 和 `readFileBytesChunk`，结果只返回路径和字节数，不把文件内容
  放进模型上下文。服务器模式和协同模式都暴露该工具；项目目录目标在自由执行模式下复用
  `ProjectFileStore` 的目录边界，不重复请求授权；项目外目标和其他执行模式仍按原流程授权，
  不影响手机保存的 SSH 凭据和应用内部目录保护。模式切换复用连接时同步更新工具上下文。
- UI 与提示：明确区分项目下载和手机路径下载；需要授权时，下载授权弹窗显示服务器源路径、
  手机目标和写入目录；系统提示禁止使用 `file.read`、`project.write` 或 `local.write` 复制二进制。
- 定向测试：`test/ssh_connection_test.dart` 验证包含 `0xff`、`0x80` 等非 UTF-8 字节的文件
  下载后字节完全一致，并验证自由执行时项目内目标不授权、项目外目标仍授权；
  `test/agent_loop_test.dart` 验证 AgentLoop 使用参数感知的授权结果。
- 结论：此前属于 `需修复`；已按现有 SFTP 传输设计补齐 Agent 到手机的二进制桥接。

### 2026-08-29：内置文档模块 Beta 1.0.3-beta.23 发布记录

- 功能提交：`f42c920`；版本提交：`1dc7fb2`；版本：`1.0.3-beta.23+32`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.23-release.apk`。
- APK 大小：`77,685,407` bytes；SHA-256
  `ad68e44aeedf5139e88b06f5f97e3c0fafb68b2a62e5890d732d8286f8c554c1`。
- 发布前验证：全量测试 184 项通过；`flutter analyze --no-pub` 通过；`git diff --check`
  通过；release APK 构建通过。构建输出、Gradle 缓存和 APK 均位于 `/www` 数据盘。
- 内容：内置文档模块支持开关、Markdown/HTML/TXT 预览和真实 OOXML `.docx` 导出，支持标题、
  段落、列表、表格、粗体、斜体、代码及基础字体颜色；关闭模块不影响普通项目文件读写。

### 2026-08-28：图片模型配置与更新渠道 Beta 1.0.3-beta.24

- 功能与版本提交：`6525af3`；版本：`1.0.3-beta.24+33`。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.24-release.apk`。
- APK 大小：`77,832,975` bytes；SHA-256
  `a8d8617d0a9c0f7f60a7650b8f736791436d26c338bdc096d5c58ff12ee202a2`。
- 发布前验证：全量测试 187 项通过；`flutter analyze --no-pub` 通过；`git diff --check`
  通过；release APK 构建通过。Flutter SDK、Gradle 缓存、构建输出和 APK 均位于 `/www`
  数据盘。
- 内容：每个供应商可独立配置图片模型，支持从供应商 `/models` 列表发现图片模型，
  `image.generate` 使用该配置而不接受模型参数；更新检查新增 GitHub Raw 和 jsDelivr CDN
  渠道，同时保留 GitHub API。静态更新清单位于 `updates/releases.json`。
- 发布结果：已创建 GitHub Pre-release `v1.0.3-beta.24`，tag 指向 `beta` 分支提交
  `a8946f0`，并上传上述 APK；未推送 `main`。Release 地址：
  `https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.24`。

### 2026-08-28：本地与服务器文件管理 Beta 1.0.3-beta.25

- 内容：手机文件管理器和服务器文件管理器都支持长按多选、复制、粘贴、移动、删除、重命名、
  属性查看、排序、新建文件夹和文件选择器打开；服务器文件操作复用 SFTP，目录缓存仍先显
  示缓存再刷新；服务器文件打开会以断点续传下载到手机项目后调用系统应用选择器。
- 实现：新增 SFTP 属性读取、目录创建、二进制文件/目录复制、移动、重命名和递归删除；本地
  人工文件操作使用绝对路径，不与 AI 项目文件边界或审批逻辑混用。
- 验证：`flutter analyze --no-pub` 通过；定向测试 86 项通过；debug APK 和 release APK
  均构建通过；`git diff --check` 通过。构建输出、Gradle 缓存和 APK 均位于 `/www` 数据盘。
- 发布结果：已创建 GitHub Pre-release `v1.0.3-beta.25`，tag 指向 `beta` 分支提交
  `d966ca1`，并上传 `pocket-server-ops-ai-v1.0.3-beta.25-release.apk`。APK 大小：
  `78,095,407` bytes；SHA-256 `226695a90f8f52fb28c6bda078d82e759a0840a5ce8ac3833897475550fecd2a`。
  Release 地址：`https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.25`。

### 2026-08-29：服务器目录缓存与状态脚本探测 Beta 1.0.3-beta.26

- 目录列表先从 SQLite 持久缓存恢复，缓存最多保留 256 个最近访问目录；缓存只保存服务器
  标识、远程路径、名称、类型、大小、修改时间、指纹和时间戳，不保存密码、私钥、API Key
  或文件内容。页面显示缓存后再后台检查，指纹未变时不重新读取目录。
- 服务器状态脚本版本升级为 `2`，在原有一键安装入口中增加
  `mobile-agent-status directory <path> [fingerprint]` 子命令。它只检查当前目录直接子项的
  名称、类型、大小和修改时间；指纹未变只返回 `unchanged=1`，变化时才返回轻量元数据列表，
  不运行常驻进程且无需 root。
- 脚本缺失、版本旧、命令失败、工具缺失或输出无法解析时自动回退 SFTP；SFTP 首次列表仍会
  写入缓存。探测到新增或元数据变化的小型文本文件后，手机端按顺序预加载，单文件上限
  `1 MiB`，内容只放内存且不会自动加入 AI 上下文。
- 服务器文件写入、上传、删除、创建、重命名和复制/移动会使受影响目录缓存失效；外部命令
  修改服务器文件则由下一次指纹探测发现。仪表盘和文件管理器继续共用同一个状态脚本安装按钮。
- 功能与版本提交：`3bac2ac`；版本：`1.0.3-beta.26+35`。
- 发布前验证：目录缓存跨控制器重载恢复；指纹变更直接更新目录而不调用 SFTP；脚本协议在本机
  真实目录上验证首次列表和 unchanged 响应；全部 191 项 Flutter 测试通过；
  `flutter analyze --no-pub` 通过；release APK 构建通过。构建输出、APK、Flutter SDK、Gradle
  缓存和 Dart/Flutter 包缓存均位于 `/www` 数据盘。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.26-release.apk`；
  大小 `78,177,327` bytes；SHA-256
  `f293c94a2e96eb334cdeb9c57c7c442b3c0e0c0b20c24f1c1bf3a2f768f08a8e`。
- 发布结果：已创建 GitHub Pre-release `v1.0.3-beta.26`，标签目标为 `beta` 分支提交
  `3bac2ac`，并上传上述 APK。Release 地址：
  `https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.26`。

### 2026-08-29：模型推理强度按供应商目录同步

- Codex 源码依据：固定快照 `f5420174dafba153913a3e697f89002c338dfd7e` 的
  `codex-rs/protocol/src/openai_models.rs` 定义了模型级
  `default_reasoning_level` 和 `supported_reasoning_levels`；推理值还允许模型定义的
  自定义字符串，不能由客户端给所有模型套用固定枚举。快照中的 `models.json` 也以
  `supported_reasoning_levels` 为每个模型单独声明能力。
- 供应商目录依据：本地 sub2api 源码的 `/v1/models` 路由在带
  `client_version` 查询参数时返回 Codex `models` 清单，普通请求只返回 OpenAI 风格的
  `data` 模型 ID；清单中的推理字段由上游模型目录或配置提供。
- 原问题：Mobile 虽然能解析 Codex 清单字段，但模型目录请求没有带
  `client_version`，聊天页和供应商设置页仍使用固定的 `default/none/minimal/low/medium/high/xhigh/max`
  列表，因此会显示供应商没有声明的推理强度。
- 修复：`ProviderConnectionTester.listModelMetadata()` 请求模型目录时协商 Codex 清单；
  若供应商拒绝该查询，再读取普通 `/models` 清单。`ProviderModelMetadata` 同时解析
  `supported_reasoning_levels` 和 sub2api 使用的 `reasoningEfforts`，并保存描述与默认值。
  聊天模型抽屉默认折叠，推理强度默认展开；有供应商列表时只显示该模型明确返回的值，
  没有列表时只显示“智能/模型默认”。旧的显式设置不会被静默删除，会标记为目录未确认。
- 供应商设置页采用同一规则；保存供应商仍只在保存流程请求一次模型目录，聊天抽屉的刷新
  按钮才会再次请求，不会因打开模型选择器自动请求。
- 定向测试：`test/domain/models_test.dart` 验证模型只声明 `low/high` 时不生成
  `medium`；`test/provider_connection_tester_test.dart` 验证 Codex 字段、sub2api
  `reasoningEfforts` 和 `client_version`；`test/ui/chat_page_test.dart` 验证模型折叠和推理
  列表精确显示。当前修复已通过 33 项定向测试和 `flutter analyze --no-pub`。
- 发布结果：功能与版本提交为 `4bc758c`，版本为 `1.0.3-beta.27+36`；已创建 GitHub
  Pre-release `v1.0.3-beta.27`，标签指向 `beta`，并上传
  `pocket-server-ops-ai-v1.0.3-beta.27-release.apk`。APK 大小 `78,275,935` bytes，
  SHA-256 `7cbfc1ae70634dc2f3a43f87926f1e1475e7caf726e9570bd4b9577dba54766b`。
  APK 路径：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.27-release.apk`；
  Release 地址：`https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.27`。

### 2026-08-29：悬浮窗尺寸与供应商模型选择 Beta 1.0.3-beta.28

- 悬浮窗整体大小和长度设置的最小值从 `75%` 调整为 `20%`；Flutter 设置、Android 服务和
  持久化读取统一使用 `20%–140%`，同时移除原生端 `160dp` 的窗口宽度下限，确保设置值真正生效。
- 供应商编辑页增加字段间距和列表行距，避免窄屏上标签、辅助说明和下一行叠加。
- 删除独立的图片模型请求和按名称猜测图片模型的逻辑。一次模型目录请求返回的完整列表同时用于
  选择默认模型和图片模型；图片模型固定保留“无”，由用户明确选择，不由客户端判断模型能力。
- 供应商总设置页的“生图供应商”下增加图片模型选择，可读取该供应商已缓存的统一模型列表。
  已保存但不在新目录中的图片模型会保留为当前选项，避免升级后丢失配置。
- 功能与版本提交：`ba07a04`；版本：`1.0.3-beta.28+37`。
- 发布前验证：供应商、模型目录、图片配置和悬浮窗相关定向测试 63 项通过；
  `flutter analyze --no-pub` 通过；release APK 构建通过；构建输出、Gradle 缓存和 APK 均位于
  `/www` 数据盘。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.3-beta.28-release.apk`；
  大小 `78,275,831` bytes；SHA-256
  `f907d2b0624443ec033265dfc3d1fa9f68bbbfe5126df180e334de8a09a39fb2`。
- 发布结果：已创建 GitHub Pre-release `v1.0.3-beta.28`，标签目标为 `beta` 分支提交
  `ba07a04`，并上传上述 APK。Release 地址：
  `https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.3-beta.28`。

### 2026-08-29：正式版 1.0.4 发布记录

- 正式版基于已验证的 `1.0.3-beta.28` 功能基线发布，未新增功能变更；悬浮窗尺寸设置、供应商模型与图片模型统一选择等修复均保留。
- 功能基线提交：`ba07a04`；版本提交：`4fb6817`；发布清单提交：`b4656bf`。
- 版本：`1.0.4+37`；Android `versionName=1.0.4`，`versionCode=37`。
- 发布前验证：`test/agent_loop_test.dart`、`test/app_controller_test.dart`、`test/ui/chat_page_test.dart`、
  `test/updates_page_test.dart` 共 93 项通过；`flutter analyze --no-pub` 通过；release APK 构建并完成
  manifest 版本校验。构建输出、APK、Flutter SDK、Gradle 缓存和 Dart/Flutter 包缓存均位于 `/www` 数据盘。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.4-release.apk`；
  大小 `78,275,819` bytes；SHA-256
  `07670139dbfa25a8f98dc1e443d33546603ef5373def138ec38e26ec3518516d`。
- 发布结果：已创建 GitHub 正式 Release `v1.0.4`，标签目标为 `b4656bf1dff1702e67f85a508da1d23da4b99f0d`，
  APK 资产状态为 `uploaded`。Release 地址：
  `https://github.com/2296199707/pocket-server-ops-ai/releases/tag/v1.0.4`。

### 2026-08-29：Codex 子代理源码审查（专项）

#### 调查边界和固定证据

- Codex 仓库：`https://github.com/openai/codex`；本地源码快照：
  `/www/mobile-agent-tooling/openai-codex-source`。
- 本专项固定 commit：`6478a751fde8884b2fdc76486fe23175a8e795d4`。
  稀疏 checkout 中缺失的文件使用 `git show <commit>:<path>` 读取，不能把工作区缺失
  当作源码不存在。
- 官方说明：`https://developers.openai.com/codex/agent-configuration/subagents.md`。
  文档说明了角色、默认模型和并发配置；下面的线程、状态、通信和持久化结论以源码和
  测试为准。
- 参考仓库只读，未被修改；本专项随后在 Mobile Agent 中实现了一个明确的首版子集，
  没有运行完整 Rust 测试套件。源码中的相关测试名称继续作为定向复核入口。

#### 结论先行

Codex 的子代理不是“给模型多加一个 prompt”，而是一个由控制平面管理的独立 agent
thread。每个子代理有自己的线程、轮次、历史、状态和工具执行上下文；根线程和所有后代
通过同一个 `AgentControl` 共享代理注册表、执行限制器、预算和部分根级路由状态。父线程
只接收结构化的状态/邮箱通知或完成摘要，不把子代理的完整中间输出自动塞回父线程上下文。

本版 Mobile Agent 没有复制完整的 Codex app-server，而是把上述控制面能力压缩成适合手机端
的首版子集：每个子代理使用独立隐藏 `Task` 和独立 `AgentLoop` 历史；每个根对话维护一棵
内存控制树；父子之间通过协作工具传递短状态和摘要。完整 fork 历史、独立 graph store、
驻留淘汰和重启后拓扑恢复仍明确不属于本版。

#### V1 和 V2 工具面

证据入口：`codex-rs/core/src/tools/handlers/multi_agents_spec.rs`、
`multi_agents_v2.rs`、`multi_agents_v2/*.rs`。

| 能力 | Multi-Agent V1 | Multi-Agent V2 | 必须保留的语义 |
| --- | --- | --- | --- |
| 创建 | `multi_agent_v1.spawn_agent`，返回 thread id 和可选昵称 | `spawn_agent`，必须提供 `task_name` 和 `message`，返回 canonical task path | 创建前预留容量、路径/昵称；失败时释放预留，不留下半个代理 |
| 上下文 | 可使用父线程上下文 fork；支持角色/模型相关选项 | `fork_turns` 为 `none`、`all` 或最近 N 轮 | fork 是独立线程历史快照，不是把子代理结果并入父线程实时消息 |
| 发送消息 | `send_input`，可用 `interrupt=true` 立即改道，否则排队 | `send_message` 只投递邮箱消息，不启动新 turn；`followup_task` 会启动或排队后续 turn | 发送消息和启动轮次不能混成一个 API |
| 等待 | 指定一个或多个 agent id，等待最终状态并返回状态映射 | 等待共享 mailbox、完成通知或 steer；返回简短摘要和超时信息，不返回子代理完整内容 | wait 是等待信号，不是拉取完整 transcript |
| 继续/停止 | `resume_agent` 恢复已关闭代理；`close_agent` 关闭目标及开放后代 | `interrupt_agent` 只中断当前 turn，代理保留以便继续消息/任务；树关闭由控制平面处理 | interrupted、closed、completed 不能混为一个状态 |
| 查询 | 以 agent id 为主 | `list_agents` 可按 canonical task path 前缀过滤 | 查询的是当前根线程树，不是整个进程所有代理 |

V2 的 `wait_agent` 实现位于 `multi_agents_v2/wait.rs`：超时时间按配置的最小/最大值
校正；mailbox 有消息、收到 steer 或超时才结束。`multi_agents_v2` 的通信构造会区分
普通消息和新任务，并用 `trigger_turn` 表示是否启动轮次。相关工具 schema 明确禁止把
V1 的 `items`、`interrupt` 参数带入 V2。

#### 创建、配置继承和上下文 fork

1. `codex-rs/core/src/agent/control/spawn.rs` 的创建流程先计算深度和版本，向共享注册表
   预留代理数量、路径和昵称，再创建新线程或 fork 线程。线程创建后持久化来源/父线程关系、
   发出 thread-created 通知，最后投递初始输入。任何中途失败都依靠 reservation 的释放
   逻辑回收槽位和临时路径。
2. `multi_agents_common.rs` 的 `build_agent_spawn_config()` 和
   `build_agent_shared_config()` 从父线程**当前 turn**重建子代理配置，重新写入当前模型、
   provider、推理强度、developer instructions、cwd、approval policy、permission profile
   和 sandbox 运行时状态；角色级覆盖是在这之后应用。不能直接复制一份旧 config，否则
   父线程刚切换供应商、目录或权限时，子代理会携带过期边界。
3. 模型解析遵循显式 spawn 参数、`[agents]` 默认配置、父线程配置的优先级。没有显式模型
   时继承父模型；模型改变而没有显式推理强度时使用新模型默认强度，并校验该模型声明的
   推理能力。service tier 也按根会话规则重新校验。
4. 完整 fork 前，`spawn_forked_thread()` 会 flush 父 rollout，再读取可证明的模型上下文。
   它按 `all` 或最近 N 轮截取，过滤临时工具项、推理项、实时项和不应继承的代理通信，
   同时处理 compaction replacement history、父/子 developer instructions 和 V2 usage hint。
   最近 N 轮是按 turn 截取，不是按字符随意裁剪。
5. fork 后子代理拥有独立历史；父代理不会因为子代理执行工具就自动获得全部工具输出。V1
   通过完成 watcher 向父线程注入完成通知，V2 通过 inter-agent communication/mailbox
   传回结果。父线程需要时再要求子代理发送摘要或后续任务。

#### 父子关系、持久化和恢复

Codex 将“线程历史”和“父子拓扑”分开保存：

- `codex-rs/agent-graph-store/src/store.rs` 定义了
  `upsert_thread_spawn_edge`、`set_thread_spawn_edge_status`、直接子节点查询和按深度
  breadth-first 的后代查询。一个 child 最多有一个持久化 parent，列表顺序要求稳定。
- `codex-rs/agent-graph-store/src/local.rs` 把上述接口接到 SQLite state runtime；
  `codex-rs/state/migrations/0021_thread_spawn_edges.sql` 创建
  `thread_spawn_edges(parent_thread_id, child_thread_id PRIMARY KEY, status)`，并按
  `(parent_thread_id, status)` 建索引。非 ephemeral 的 thread-spawn 子代理才写入边。
- 子线程自己的 rollout/history 仍由 thread store 保存。图表只记录拓扑和 open/closed
  生命周期，不代替 transcript；因此“能查到父子关系”不等于“内存中仍加载了全部线程”。
- `app-server/README.md` 的 `thread/list` 支持 `parentThreadId` 查询直接子代理和
  `ancestorThreadId` 查询任意后代；`thread/read` 会返回 `parentThreadId`、角色和昵称。
  未加载但可恢复的 thread 状态是 `notLoaded`，不能误报为 idle 或运行中。
- V2 的 `residency.rs` 使用 LRU 管理内存驻留。只有已完成、出错或 interrupted、没有
  active turn 且 mailbox 没有待处理消息的子代理才可淘汰。淘汰前 flush rollout、正常
  shutdown、保存 environment selections，再从内存 thread manager 移除；这是卸载，不是
  删除历史。恢复时从持久化历史重新加载，且遵循已关闭边的状态。

相关状态和恢复结论来自 `control.rs` 的 `persist_thread_spawn_edge_for_source()`、
`live_thread_spawn_children()`、子树遍历和关闭逻辑，以及 `spawn.rs` 的
`resume_agent_from_rollout()`。必须区分：

- `interrupt_agent`：当前轮次停下，代理还可以收消息和继续任务；
- `close_agent`/树关闭：关闭目标及开放后代，后续不能当作普通 live agent 使用；
- residency eviction：释放内存但保留 rollout 和图边；
- 应用/管理器重启：只按持久化状态恢复，不能因为有旧任务记录就重复执行有副作用工具。

#### 并发、限制和状态事件

- `agent/registry.rs` 的 `AgentRegistry` 由同一根线程树的所有 `AgentControl` clone 共享，
  负责子代理总数、canonical path 冲突、昵称和 reservation。它不是每个子代理自己的计数器。
- `agent/control/execution.rs` 的 `AgentExecutionLimiter` 也按根会话共享；V2 子代理每次
  active turn 拿到 RAII `AgentExecutionGuard`，turn 结束或异常释放计数。达到容量时拒绝
  新轮次，而不是静默杀掉另一个正在执行的子代理。
- V1 深度按配置的最大深度校验；V2 的 task path、目标解析和 root/self 约束由工具处理。等待
  超时有上下限，路径冲突、无效目标、不能中断 root 或自己都有定向测试。
- `agent/status.rs` 从事件推导 `PendingInit`、`Running`、`Interrupted`、
  `Completed(Option<String>)`、`Errored(String)`、`Shutdown`、`NotFound`。不要用“最近一次
  工具输出”猜测代理状态。
- `protocol/src/items.rs` 的 `CollabAgentToolCallItem` 携带发送线程、接收线程、模型、
  推理强度和各代理状态；`SubAgentActivityItem` 携带 activity kind、agent thread id 和
  canonical path。V2 activity kind 包括 started、interacted、interrupted、completed。
- `app-server` 公开的 `subAgentActivity` 可能在父 turn 的 `turn/completed` 之后才到达，
  但读取历史时仍归属于发起它的父 turn。UI 不能收到父 turn 完成就把所有子代理活动清掉。
  对 parent-owned V2 child，直接 `turn/start`/`turn/steer` 也可能被拒绝，消息应走父代理
  的协作工具。

#### 对当前 Mobile Agent 的核对

| Codex 要件 | 当前实现证据 | 结论 |
| --- | --- | --- |
| 独立 agent thread 和控制树 | `lib/agent/subagents.dart:SubagentTree` 为每个根任务维护子节点；`AppController._createSubagentTree()` 为每个子节点启动独立 `runTask()` 和独立事件历史 | 首版已实现；未复制 Codex 的 app-server thread manager |
| 根树共享控制器、父子关系和限制 | `SubagentNode` 保存 `parentId`、`rootTaskId`、`depth`；树内统一计算并发和递归限制，子节点只能通过所属树解析 | 首版已实现；没有 Codex canonical agent path |
| 独立持久化历史 | `AppController._prepareSubagentTask()` 创建隐藏 `Task`；子任务的 `TaskEvent` 独立保存，父任务只记录子代理状态/摘要事件 | 首版已实现；创建参数固定为不 fork 父历史 |
| 数据库拓扑 | `lib/domain/models.dart:Task` 和 `lib/storage/app_database.dart:onUpgrade` 增加 `isSubagent`、父/根 ID、深度和名称字段 | 部分实现；没有独立 spawn-edge、mailbox 或 residency 表 |
| 协作通信 | `SubagentTree` 提供 `spawn_agent`、`send_message`、`followup_task`、`wait_agent`、`list_agents`、`interrupt_agent`；等待结果只返回状态和最多 1200 字摘要 | 首版已实现；mailbox 只在内存中存在 |
| 配置继承与凭据边界 | `_prepareSubagentTask()` 从父任务快照继承 provider、模型、推理、工作模式、项目、服务器、目录和审批回调；只保存 provider 引用，不复制 API key、密码或私钥 | 首版已实现；子任务配置变更和独立角色文件暂不支持 |
| 取消、关闭和迟到操作 | `SubagentTree.close()` 先阻止新操作，再取消子树并等待创建/启动操作；`deleteTask()` 和 `dispose()` 使用关闭流程 | 首版已实现；这是对 Codex 关闭/中断语义的轻量实现 |
| 重启、驻留和 UI 活动 | 子任务默认隐藏于侧栏，根任务事件显示子代理活动；数据库启动时会恢复任务状态，但不会重建内存控制树或自动重放子任务 | 明确缺口；不作为本版自动恢复能力 |

#### 本版实现边界（已编码）

为了符合“最小编程、稳定优先”，本版只实现以下控制面，不复制整个 Codex app-server：

1. 模型抽屉增加全局子代理设置：继承/指定模型、推理强度、并发线程和递归深度；设置保存于现有 `settings` 表。
2. 根对话中的 `AgentLoop` 可创建独立隐藏子任务。子任务拥有自己的 provider 请求、工具集合、SSH/本地访问映射和事件历史，不把完整 transcript 注入根任务。
3. 协作工具区分投递消息、启动后续轮次、等待状态和中断当前轮次；同一子代理启动新轮次前使用 `pending` 占位，避免并发 follow-up 覆盖运行句柄。
4. 不同根对话可以并发；同一根树共享并发计数。创建过程、父任务停止、删除和应用退出都有取消收敛路径，pending 创建不会在树关闭后启动。
5. 任务字段迁移同时写入新数据库和 `oldVersion < 13` 的 SQLite 升级路径；旧任务默认作为普通任务读取，子任务由 `isSubagent` 区分。

以下能力留给后续明确需求，不在本版伪装成已支持：完整/最近 N 轮历史 fork、持久化 graph store、mailbox 恢复、residency eviction、子任务独立角色配置、重启后子树自动恢复。

#### 最小验证矩阵和封存规则

本版只覆盖与新增控制面直接相关的不变量，避免把完整 Codex 测试套件搬到手机端：

- 设置序列化、并发上限、递归深度和 sibling task name 冲突；
- `send_message` 不启动 turn，`followup_task` 在 idle 时启动、运行中排队；
- wait 的完成/超时、中断和后续轮次，等待结果不携带完整子代理内容；
- 关闭期间的 pending spawn 不得启动，关闭流程必须等待创建操作收敛；
- `flutter analyze --no-pub` 和 `test/subagents_test.dart`、`test/app_controller_test.dart`、
  `test/ui/chat_page_test.dart` 的聚焦测试。

#### 首版落地验证记录（2026-08-29）

- 实现文件：`lib/agent/subagents.dart`、`lib/domain/models.dart`、
  `lib/storage/app_database.dart`、`lib/app_controller.dart`、`lib/ui/chat_page.dart`、
  `lib/ui/home_shell.dart`。
- 定向测试：`test/subagents_test.dart` 6 项通过；`test/app_controller_test.dart` 和
  `test/ui/chat_page_test.dart` 合计 61 项通过，共 67 项。
- 静态分析：`/www/mobile-agent-tooling/flutter/bin/flutter analyze --no-pub` 通过。
- 关闭竞态修复：`SubagentTree.close()` 会先阻止新创建和 follow-up，再等待 pending
  创建/启动操作与活动轮次收敛；父任务删除和 AppController `dispose()` 都调用该入口。
- 仍未实现的部分以本节“本版实现边界”为准，后续不得把 Codex 的 graph store、fork
  历史或重启恢复误报为当前能力。

Codex 对照测试入口固定为：

- `codex-rs/core/src/tools/handlers/multi_agents_tests.rs`：
  `multi_agent_v2_spawn_requires_task_name`、路径解析、消息/后续任务、wait 不返回完整
  内容、中断不通知完成、关闭/恢复、深度和超时测试；
- `codex-rs/core/src/agent/control_tests.rs`：
  `spawn_agent_creates_thread_and_sends_prompt`、fork 历史清理、
  `spawn_agent_limit_shared_across_clones`、父子完成通知、子树关闭和重启恢复测试；
- `codex-rs/core/src/agent/control/residency_tests.rs`：
  `residency_slot_reservation_unloads_oldest_idle_v2_agent`、
  `interrupted_v2_agent_is_lost_after_residency_eviction`；
- `codex-rs/agent-graph-store/src/local.rs`：直接子节点、状态过滤和 breadth-first 后代
  查询测试。

专项状态：`SA-01` 控制树、`SA-03` 协作工具和基础状态已实现；`SA-02` 仅实现独立历史，
没有历史 fork；`SA-04` 仅实现任务字段持久化，没有独立拓扑表；`SA-05` 已实现运行期状态
和关闭收敛，但没有驻留淘汰或重启后子树恢复。只有 Codex 固定 commit 变化、上述 Mobile
对应实现开始改动、相关定向测试失败，或协议明确改变时，才重新读取同一组源码；普通 UI
改动、模型名称变化和“想再确认一次”不触发重复调查。

## 9. 发现记录模板

每个真实问题按以下格式追加，避免重复查询和重复修复：

```text
ID：
发现日期：
Codex 源码：<commit>:<path>:<symbol 或行号>
Codex 测试：<commit>:<path>:<test>
Mobile 实现：<path>:<symbol 或行号>
复现输入：
实际结果：
期望不变量：
结论：等价 / 架构差异 / 需修复 / 证据不足
修复 commit：
定向测试：
```

## 10. 条目封存与重新开启条件

- 每个条目一旦达到“已等价”“架构差异”或“需修复已处理”，就以本文件记录的
  Codex commit、Mobile 文件和定向测试作为封存基线；后续不重复搜索相同源码。
- 只有以下情况才重新开启已封存条目：固定 Codex commit 变更；条目映射的 Mobile
  实现发生改动；对应定向测试失败；或供应商明确改变了相关协议契约。
- “想再确认一次”、普通模型名称变化或与条目无关的 UI/功能改动，不构成重新开启条件。
- 新问题必须新增 ID 和记录，禁止覆盖旧结论；完成全部条目后追加一次总表快照，并以
  总表作为后续工作的入口。
- 每次新增源码读取都必须先关联到一个未完成或重新开启的 ID；没有关联 ID 时停止扩大搜索。

## 11. 2026-08-29：推理强度兜底与子代理供应商链路复核

- 供应商模型目录明确返回 `supported_reasoning_levels`、`reasoningEfforts` 或
  `reasoning_options` 时，Mobile 只显示该模型声明的值；明确返回空列表仍表示该模型没有
  可调推理档位。
- 供应商只返回模型 ID、没有返回推理能力字段时，模型选择和子代理模型选择统一显示
  `Default / Low / High / Max`。这些是可用性兜底，不会写入模型能力目录；用户选择后才按
  当前协议发送，旧的显式值仍保留并标记为未确认。
- DeepSeek 官方文档（`https://api-docs.deepseek.com/guides/thinking_mode`）说明 Chat
  Completions 格式把思考开关和档位分开：`thinking.type` 控制启用，`reasoning_effort`
  支持 `low/high/max`。因此 Mobile 对已识别的 DeepSeek 模型在选择档位时
  同时发送 `thinking: {type: enabled}` 和 `reasoning_effort`；选择历史兼容值 `none` 时只发送
  `thinking: {type: disabled}`，`default` 不强行覆盖供应商默认值。普通 Chat Completions
  供应商仍只发送标准 `reasoning_effort`，不增加未声明的 `thinking` 字段。
- 子代理设置保存在现有 `settings` 表：空 `providerId` 表示跟随当前对话供应商，非空值引用
  已配置供应商；空模型分别表示继承父模型或使用指定供应商的默认模型。创建子代理时将当前
  供应商、模型、协议、推理强度和凭据引用解析到独立任务，实际请求走该任务的客户端，不把
  API Key 写入子代理设置或历史事件。模型抽屉只使用已缓存模型，刷新按钮才请求模型目录。

本轮修复入口：`lib/domain/models.dart:reasoningEffortValuesForModel`、
`lib/agent/chat_completions_client.dart:ChatCompletionsClient.complete`、
`lib/ui/chat_page.dart:_selectModelAndReasoning`、
`lib/app_controller.dart:_prepareSubagentTask`。

复核测试：`test/domain/models_test.dart` 覆盖无能力目录的四项兜底和明确空列表；
`test/chat_completions_client_test.dart` 覆盖 DeepSeek 开关、档位与
`reasoning_content` 回放；`test/subagents_test.dart` 覆盖指定供应商、并发和递归边界。
本节作为当前结论封存；只有这些实现或对应测试变化时才重新读取同一供应商契约。
