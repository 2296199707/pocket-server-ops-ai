# Codex 来源与许可补充审查

日期：2026-09-21。

## 来源与范围

- 本项目：`apps/mobile-agent-v1`；原有项目 `LICENSE` 为 MIT，Copyright 2026 kaka229。
- 上游：<https://github.com/openai/codex>。
- 固定核对版本：`6478a751fde8884b2fdc76486fe23175a8e795d4`。
- 本地证据：`/www/mobile-agent-tooling/openai-codex-source`，用 `git show <commit>:<path>` 读取提交内容，避免依赖稀疏工作区状态。
- 已读取该提交的 `LICENSE`、`NOTICE` 和两份压缩提示词。上游为 Apache License 2.0，Copyright 2025 OpenAI。
- 功能参考的其他历史 commit 保留在 [逐项源码审查](codex-source-audit-mobile-agent-v1.zh-CN.md)，本轮不重复功能审查。

## 确认的复用内容

| 本项目位置 | 上游位置 | 使用及修改 |
| --- | --- | --- |
| `lib/agent/openai_compatible_client.dart::_codexSummarizationPrompt` | `codex-rs/prompts/templates/compact/prompt.md` | 提示词原文嵌入 Dart 字符串；换行转义并省略末尾换行 |
| `lib/agent/openai_compatible_client.dart::_codexSummaryPrefix` | `codex-rs/prompts/templates/compact/summary_prefix.md` | 摘要前缀原文嵌入 Dart 字符串；省略末尾换行 |

这两段内容不是仅参考思路，因此明确保留 Apache-2.0、上游版权和修改说明。
归属注释放在两个常量之前，不将整个 Dart 文件或整个项目重新标为 Apache-2.0。

## 对应逻辑的参考改编

以下两处既有本项目注释又能核对到对应上游实现，本轮一并补入局部归属与修改说明：

| 本项目位置 | 上游位置（上述固定提交） | 对应行为及本地改写 |
| --- | --- | --- |
| `lib/app_controller.dart::_codexRetainedUserMessages` | `codex-rs/core/src/compact.rs::build_compacted_history_with_limit` | 倒序选择近期用户消息、预算内保留、截断边界消息后恢复顺序；改用 Dart AiMessage、文本存储和本应用 UTF-8 截断 |
| `lib/agent/context_usage.dart::remainingPercent` | `codex-rs/protocol/src/protocol.rs::TokenUsage::percent_of_context_window_remaining` | 保留 12,000 token 基线及百分比算法，接入可空用量字段与本地元数据 |

上游历史规范化、请求/流重试、子代理控制等行为参考继续由原有逐项审查文档定位。
不把仅有协议字段名、工具名、参数值或相同功能的部分直接宣称为逐字复制。

## 独立复核补充

本轮由只读子代理复核 `lib`、`test`、`relay`，主代理汇总。除两段压缩提示词外，
未发现新的逐字复制源码或完整复制的上游测试文件。发现以下明确参考关系：

| 本项目位置 | 上游参考 | 核对结论 |
| --- | --- | --- |
| `app_controller.dart::_systemPrompt` | `codex-rs/core/gpt_5_1_prompt.md`，历史提交 `f5420174dafba153913a3e697f89002c338dfd7e`，见已有 2026-08-28 审查 | 计划、阶段进度、commentary 提示要求的改写；补入局部版权/许可注释及手机工作范围、可见规划事件的修改说明 |
| `agent/agent_loop.dart` 的 `update_plan` | `core/src/tools/handlers/plan_spec.rs`、`plan.rs`、`protocol/src/plan_tool.rs`（均位于 `codex-rs/`） | 计划字段和状态枚举的协议适配；本地 Dart 测试不属于复制的 Rust 测试 |
| `agent/remote_instructions.dart` | `codex-rs/core/src/agents_md.rs` 及对应测试 | 文件优先级、项目边界与拼接顺序的行为参考；使用本项目 SSH 读取实现 |
| `agent/subagents.dart` | Codex MultiAgentV2 thread-fork/app-server，具体路径见逐项源码审查的子代理章节 | `fork_turns` 等语义适配，未发现直接复制子代理源码 |
| `agent/openai_compatible_client.dart` | `codex-rs/core/src/responses_retry.rs`、`context_manager/normalize.rs` | 重试分类、历史配对规范化的独立 Dart 实现 |
| `domain/models.dart` | `codex-rs/models-manager/src/model_info.rs` 等 | 上下文元数据与工具输出策略参考 |
| `agent/auto_review.dart`、`agent/agent_loop.dart` | `codex-rs/core/src/guardian/` | 审批失败处理思路参考；供应商调用与脱敏采用本地实现 |
| `agent/agent_tools.dart`、`ssh/ssh_connection.dart` | `codex-rs/core/src/unified_exec/`、`tools/context.rs` | 输出预算、偏移和进程生命周期语义参考 |

`relay/**` 未发现可定位的 Codex 复制证据；通用 exec/file/process 功能相似不足以确认源码来源，
本轮不为其追加没有依据的 Codex 归属。此结论不扩展为对其他第三方依赖的审查。

## 声明与分发

- `THIRD_PARTY_NOTICES.md` 增加 Codex 来源、固定版本、用途和改编说明。
- `README.md` 明确项目原创内容 MIT 与第三方许可的区别。
- `assets/licenses/codex/LICENSE` 和 `NOTICE` 保留核对快照中的完整上游文本。
- 上游 NOTICE 中包含 Ratatui 归属。本项目保留该文件原文；该条说明的是 Codex 上游，不据此宣称本 APP 使用 Ratatui，也不据此引入 Ratatui 依赖。
- `pubspec.yaml` 将项目 LICENSE、第三方声明、Codex LICENSE/NOTICE、字体 OFL 声明列为资源。
- `lib/main.dart` 延迟加载这些资源到 Flutter 的 `LicenseRegistry`；不会在启动时读取大文件或请求网络。
- “设置 → 开源许可”使用 Flutter 自带许可页展示声明，不增加依赖。
- 修正旧依赖审查中“根目录没有 LICENSE”的过时结论；原依赖版本表不冒充本轮重新核查结果。

## 维护与核对边界

后续复制或移植新的 Codex 内容时，在这里登记上游路径/commit、目标文件及修改范围，并在对应源码保留归属。
仅对行为、协议、参数或算法做独立实现，不直接据此把全部实现认定为上游代码。
本记录覆盖本轮找到的明确复用和已有功能参考证据，不声称完成所有历史版本的逐字相似度或全部依赖合规审计。

本轮不调整 Agent 行为、版本号，也不构建发布 APK；资源和许可入口将在下一次正常构建进入安装包。

## 本轮验证

- 与固定上游提交逐字节比较随附 LICENSE、NOTICE：一致。
- Dart 两个压缩常量与上游提示词比较（忽略上游末尾换行）：一致。
- 新增运行时代码静态分析通过；现有设置页 8 项测试通过。
- Flutter 测试构建资源中的项目 LICENSE、第三方声明、Codex LICENSE/NOTICE、字体 OFL 共 5 项与源文件一致；不等同于已经发布新的 APK。
