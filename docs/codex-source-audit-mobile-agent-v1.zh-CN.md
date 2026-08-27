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
- 当前 beta：`1.0.3-beta.11`；
- 当前基线 commit：`71a93618ff03620e0082cd61a81f64e3c79059a9`；
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
| CTX-03 | `codex-rs/core/src/context_manager/normalize.rs`；`codex-rs/core/src/context/compaction_summary.rs` | `lib/storage/app_database.dart`、`lib/storage/memory_app_database.dart`、`lib/app_controller.dart` | compaction 前后的历史起点、opaque item 保留范围、供应商切换后新 compaction 是否重新生效 | 需修复已处理（独立 compact 请求；最新窗口替换；有回归测试） |
| CTX-04 | `codex-rs/core/src/context/world_state/model.rs`；`codex-rs/core/src/context/world_state/model_tests.rs` | `lib/domain/models.dart`、`lib/agent/context_usage.dart` | `context_window`、`max_context_window`、有效窗口、自动压缩阈值和未知元数据的处理，不得用字符或字节猜 token | 架构差异（元数据驱动；未知窗口不压缩） |
| CTX-05 | `codex-rs/tui/src/token_usage.rs` | `lib/agent/context_usage.dart`、`lib/ui/chat_page.dart` | 当前轮 usage、累计 usage、压缩后 usage 和 UI 百分比是否混为一谈 | 架构差异（同一计算规则；UI 只显示真实 usage） |
| CTX-06 | `codex-rs/core/src/context/image_resize_notice.rs`；Responses 输入相关源码 | `lib/storage/attachment_store.dart`、`lib/app_controller.dart`、客户端附件转换 | 图片物理独立存储但仍作为上下文输入；模型不支持媒体时的明确处理；累计图片不会把 Base64 永久放入事件 | 架构差异（物理分离但仍恢复到请求） |

### B. 协议、SSE 和错误（P0）

| ID | Codex 源码和测试 | Mobile 对应位置 | 必须核对的行为 | 状态 |
| --- | --- | --- | --- | --- |
| PRO-01 | `codex-rs/codex-api/src/common.rs`；`codex-rs/codex-api/src/endpoint/compact.rs`；`codex-rs/core/src/client.rs` | `lib/agent/openai_compatible_client.dart` | 普通 Responses 与独立 compact 请求的字段边界、历史、工具和 reasoning | 需修复已处理（普通请求不带 context_management） |
| PRO-02 | `codex-rs/codex-api/src/sse/responses.rs`；相关 Responses 测试 | `lib/agent/openai_compatible_client.dart` | `response.completed`、incomplete、failed、cancelled、断流和 multiline SSE 的终止与保存顺序 | 已等价（已覆盖关键事件） |
| PRO-03 | `codex-rs/core/src/responses_retry.rs`；`codex-rs/core/src/responses_retry_tests.rs` | `lib/agent/openai_compatible_client.dart`、`lib/agent/chat_completions_client.dart` | 仅模型请求按明确可重试错误退避；取消立即打断；不得重放远程工具副作用 | 架构差异（客户端不自动重试，工具副作用不会重放） |
| PRO-04 | `codex-rs/core/src/context_manager/normalize.rs`；Responses 请求源码 | `lib/agent/openai_compatible_client.dart`、`lib/agent/chat_completions_client.dart` | Responses 与 Chat Completions 是显式协议；不支持时直接报错，不自动 fallback；跨协议历史转换不伪造 opaque 状态 | 已等价 |
| PRO-05 | 模型元数据和 endpoint 相关测试 | `lib/providers/provider_connection_tester.dart`、`lib/domain/models.dart` | `/models` 只有真实能力字段时才更新元数据；普通模型 ID 响应不能覆盖用户已配置限制 | 已等价（有模型元数据测试） |
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
- 当前 beta 基线为 `1.0.3-beta.11`，commit `71a93618ff03620e0082cd61a81f64e3c79059a9`；
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
  分流是 Mobile 保留终端交互语义的架构差异。修复 commit：当前工作树未提交。

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
- 结论：`需修复`，已处理。修复未提交，当前工作树包含修改。
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
- 结论：`需修复`，已处理。修复未提交，当前工作树包含修改。
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
  修复 commit：当前工作树未提交。
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
  业务缺口。本条只补充旧 turn 状态回归测试。修复 commit：当前工作树未提交。
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
  新 turn 或重放远程操作。修复 commit：当前工作树未提交。
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
- 结论：`需修复`，已处理。修复未提交，当前工作树包含修改。
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

### 2026-08-27：CTX-03 / PRO-01 主动压缩入口

- Codex 文档和源码证据：`/responses/compact` 是无状态请求；返回的完整 `output`
  数组就是下一次 Responses 请求的规范上下文。压缩请求使用独立的 `instructions`，
  不能只保存其中的 compaction item，也不能把返回窗口裁剪成摘要文本。图片等输入在
  压缩请求中仍按完整上下文参与计算。依据：官方 Compaction 指南以及固定 commit 的
  `codex-rs/codex-api/src/endpoint/compact.rs`、
  `codex-rs/core/src/context_manager/compaction_summary.rs`。
- Mobile 实现：`lib/agent/openai_compatible_client.dart` 的
  `AiCompactionClient.compact` 只对 Responses 调用 `/responses/compact`，把 system
  消息转换为独立 `instructions`，保留完整返回 `output`；
  `lib/app_controller.dart:1004-1220` 的 `compactTaskContext` 将完整输出写入
  `context.compacted`，随后刷新上下文统计。压缩期间按任务去重，运行中的任务和设置修改
  被拒绝；没有可压缩历史、空响应或请求失败时不写入压缩事件。已有的持久 SSH 连接会复用，
  临时连接在请求结束后释放。
- UI 入口：`lib/ui/chat_page.dart:544-558,1915-2030` 在上下文详情弹窗提供“立即压缩”；
  仅 Responses 显示该入口，压缩中禁止重复点击和关闭弹窗，失败直接显示错误。
- 定向测试：`test/openai_compatible_client_test.dart` 的
  `Responses compaction uses its dedicated endpoint and replaces history`；
  `test/app_controller_test.dart` 的
  `manual Responses compaction stores the canonical output window`、
  `failed manual compaction does not write a context event`、
  `manual compaction is rejected while a task is running`；
  `test/ui/chat_page_test.dart` 的上下文详情弹窗按钮测试。
- 结论：`需修复已处理`。主动压缩不改变 Chat Completions 路径，也不把兼容协议伪装成
  Codex Responses 压缩；Responses 的完整输出窗口和图片输入边界保持不变。当前按钮是
  用户主动触发，自动压缩仍由 Responses usage、模型窗口元数据和已有 Agent 轮次逻辑决定。
- 修复 commit：当前工作树未提交。

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
  用户事件失败持久化、服务器级写入队列、停止目标校验和分页并发合并。
- 已知但不在本轮扩大范围的项目：steer/mailbox 产品差异、交互式终端与 Agent 的人工
  并发、旧版附件迁移失败后的重试、超大附件估算/清理优化。这些没有被记录为新的 P0/P1。
- 验证封存基线：`flutter analyze` 无问题；`flutter test` 全量 148 项通过；
  `git diff --check` 通过。当前工作树仍未提交，版本号和 APK 未变更。

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
