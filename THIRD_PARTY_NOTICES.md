# Third-party notices

PocketServerOps AI 使用以下开源项目。Dart 包版本以 `pubspec.lock` 为准；源码引用的版本单独列出。许可证和版权声明以各上游项目随版本发布的文件为准。本项目原创部分使用 MIT，第三方内容仍受其各自许可证约束。

## OpenAI Codex：源码与提示词参考

- 上游：https://github.com/openai/codex
- 核对快照：`6478a751fde8884b2fdc76486fe23175a8e795d4`；历史参考版本见源码审查记录。
- 版权：Copyright 2025 OpenAI。
- 许可证：Apache License 2.0，完整文本随附于 [assets/licenses/codex/LICENSE](assets/licenses/codex/LICENSE)。
- 上游声明：[assets/licenses/codex/NOTICE](assets/licenses/codex/NOTICE)，保留上游原文。其中 Ratatui 的声明属于 Codex 上游组成说明，不表示本应用引入了 Ratatui。

`lib/agent/openai_compatible_client.dart` 中的 `_codexSummarizationPrompt` 和
`_codexSummaryPrefix` 取自上游 `codex-rs/prompts/templates/compact/prompt.md` 与
`summary_prefix.md`。本项目将 Markdown 文本嵌入 Dart 字符串，处理换行及尾部换行，
并接入手机端上下文压缩流程；上述文本保留 Apache-2.0 归属。

`lib/app_controller.dart` 的近期用户消息保留逻辑参考改编自
`codex-rs/core/src/compact.rs::build_compacted_history_with_limit`；
`lib/agent/context_usage.dart::remainingPercent` 的上下文百分比计算参考改编自
`codex-rs/protocol/src/protocol.rs::TokenUsage::percent_of_context_window_remaining`。
这些对应部分同样保留 OpenAI 版权与 Apache-2.0 声明，修改为本应用的 Dart 数据结构、
空值处理及文本存储/截断逻辑；不将其余原创代码重新许可。

`lib/app_controller.dart::_systemPrompt` 的计划与阶段进度要求参考改写自
`codex-rs/core/gpt_5_1_prompt.md`（历史版本 `f5420174dafba153913a3e697f89002c338dfd7e`），
改为手机/服务器工作范围及可见的 `update_plan` 事件；该提示词改编部分同样保留上述归属。
`update_plan` 的参数结构和 AGENTS.md 查找约定也参考 Codex，具体映射见下面的归属审查。

上下文管理、工具调用、重试及子代理等模块还参考了 Codex 的实现与行为。
具体来源、改编范围和核对边界见 [Codex 归属审查](docs/codex-attribution-audit.zh-CN.md)，
功能逐项记录见 [Codex 源码审查](docs/codex-source-audit-mobile-agent-v1.zh-CN.md)。
这些参考不代表将整个项目改为 Apache-2.0，也不代表 OpenAI 对本项目提供认可或背书。

APK 随附本声明及 Codex 的 LICENSE/NOTICE，可在“设置 → 开源许可”中阅读。

## 直接依赖

| Package | Version | License | Upstream |
| --- | ---: | --- | --- |
| `flutter_secure_storage` | 9.2.4 | BSD-3-Clause | https://github.com/mogol/flutter_secure_storage |
| `dartssh2` | 3.3.1 | MIT | https://github.com/vicajilau/dartssh2 |
| `http` | 1.6.0 | BSD-3-Clause | https://github.com/dart-lang/http |
| `flutter_markdown_plus` | 1.0.12 | BSD-3-Clause | https://github.com/foresightmobile/flutter_markdown_plus |
| `file_picker` | 10.3.10 | MIT | https://github.com/miguelpruivo/flutter_file_picker |
| `path` | 1.9.1 | BSD-3-Clause | https://github.com/dart-lang/core/tree/main/pkgs/path |
| `sqflite` | 2.4.3 | BSD-2-Clause | https://github.com/tekartik/sqflite |
| `xterm` | 4.0.0 | MIT | https://github.com/TerminalStudio/xterm.dart |

## Windows Agent 依赖

| Package | Version | License | Upstream |
| --- | ---: | --- | --- |
| `ws` | 8.21.3 | MIT | https://github.com/websockets/ws |

## 关键传递依赖

| Package | Version | License | Used by |
| --- | ---: | --- | --- |
| `asn1lib` | 1.6.5 | BSD-3-Clause | `dartssh2` |
| `pinenacl` | 0.6.0 | MIT | `dartssh2` |
| `pointycastle` | 4.0.0 | MIT-style | `dartssh2` |
| `zmodem` | 0.0.6 | MIT | `xterm` |
| `equatable` | 2.1.0 | MIT | `xterm` |
| `quiver` | 3.2.2 | Apache-2.0 | `xterm` |
| `markdown` | 7.3.1 | BSD-3-Clause | `flutter_markdown_plus` |
| `dbus` | 0.7.15 | MPL-2.0 | `file_picker` cross-platform dependency |
| `sqflite_common` | 2.5.11 | BSD-2-Clause | `sqflite` |

The remaining Dart and Flutter packages are resolved by Pub and are covered by
the licenses recorded in their upstream package distributions. The Flutter
Android build embeds Flutter's generated notices in `NOTICES.Z` inside the APK.

## Font

`assets/fonts/NotoSansSC-Variable.ttf` is Noto Sans SC and is distributed under
the SIL Open Font License 1.1. The license text is included at
`assets/fonts/OFL.txt`.

For the complete audit, package versions, and upstream references, see
[`docs/open-source-audit.zh-CN.md`](docs/open-source-audit.zh-CN.md).
