# PocketServerOps AI 开源依赖审查

审查日期：2026-08-25

许可声明补充：2026-09-21（Codex 来源及分发声明；下方依赖版本表保留原审查日期，本轮未重新审查全部依赖）。

## 结论

原审查针对 `apps/mobile-agent-v1` 的 Flutter/Dart 依赖和随项目分发的字体资源。版本以 `pubspec.lock` 和 `.dart_tool/package_graph.json` 为准，许可证以本地 Pub 缓存中对应版本的 `LICENSE`/`NOTICE` 文件为准。Codex 源码和提示词的补充审查见 [codex-attribution-audit.zh-CN.md](codex-attribution-audit.zh-CN.md)。

- 没有发现 GPL、LGPL 或 AGPL 依赖。
- 直接依赖使用 MIT、BSD-2-Clause、BSD-3-Clause 等宽松许可证。
- `file_picker` 的跨平台依赖链包含 `dbus`，其许可证是 MPL-2.0；当前 Android 构建通常不会使用 Linux 的这部分代码，但发布第三方清单时仍应保留该依赖的许可证和来源。
- `pointycastle` 使用 Bouncy Castle 的 MIT 风格许可证，必须保留版权和许可声明。
- `assets/fonts/NotoSansSC-Variable.ttf` 是 Noto Sans SC，项目已随附 SIL Open Font License 1.1 文本 `assets/fonts/OFL.txt`。
- 项目根目录已有 MIT `LICENSE`（Copyright 2026 kaka229），适用于本项目原创部分。Codex 复用内容保留 Apache-2.0 归属，许可证和上游 NOTICE 随附于 `assets/licenses/codex/`；各第三方许可证不会被项目 MIT 替代。

这是一份工程层面的依赖清单，不构成法律意见。

## 直接依赖

| 包 | 锁定版本 | 许可证 | 上游项目 |
| --- | ---: | --- | --- |
| `flutter_secure_storage` | 9.2.4 | BSD-3-Clause | [mogol/flutter_secure_storage](https://github.com/mogol/flutter_secure_storage) |
| `dartssh2` | 3.3.1 | MIT | [vicajilau/dartssh2](https://github.com/vicajilau/dartssh2) |
| `http` | 1.6.0 | BSD-3-Clause | [dart-lang/http](https://github.com/dart-lang/http) |
| `flutter_markdown_plus` | 1.0.12 | BSD-3-Clause | [foresightmobile/flutter_markdown_plus](https://github.com/foresightmobile/flutter_markdown_plus) |
| `file_picker` | 10.3.10 | MIT | [miguelpruivo/flutter_file_picker](https://github.com/miguelpruivo/flutter_file_picker) |
| `path` | 1.9.1 | BSD-3-Clause | [dart-lang/core](https://github.com/dart-lang/core/tree/main/pkgs/path) |
| `sqflite` | 2.4.3 | BSD-2-Clause | [tekartik/sqflite](https://github.com/tekartik/sqflite) |
| `xterm` | 4.0.0 | MIT | [TerminalStudio/xterm.dart](https://github.com/TerminalStudio/xterm.dart) |

开发依赖 `flutter_lints` 6.0.0 为 BSD-3-Clause；它不会进入应用运行时。

Windows Agent 的直连服务使用 `ws` 8.21.3（MIT）；独立 EXE 会将其打入单文件，
源码安装则通过 `npm ci --omit=dev` 安装。来源为
[websockets/ws](https://github.com/websockets/ws)。

## 关键传递依赖

以下是运行时依赖图中需要重点留意的非 Dart/Flutter 标准包及其许可证：

| 包 | 锁定版本 | 许可证 | 由谁引入 |
| --- | ---: | --- | --- |
| `asn1lib` | 1.6.5 | BSD-3-Clause | `dartssh2` |
| `pinenacl` | 0.6.0 | MIT | `dartssh2` |
| `pointycastle` | 4.0.0 | MIT 风格 | `dartssh2` |
| `zmodem` | 0.0.6 | MIT | `xterm` |
| `equatable` | 2.1.0 | MIT | `xterm` |
| `quiver` | 3.2.2 | Apache-2.0 | `xterm` |
| `markdown` | 7.3.1 | BSD-3-Clause | `flutter_markdown_plus` |
| `dbus` | 0.7.15 | MPL-2.0 | `file_picker`（跨平台依赖） |
| `xml` | 7.0.1 | MIT | `file_picker` 依赖链 |
| `petitparser` | 7.0.2 | MIT | `xml` |
| `sqflite_common` | 2.5.11 | BSD-2-Clause | `sqflite` |
| `sqflite_android` | 2.4.3 | BSD-2-Clause | `sqflite` |
| `sqflite_platform_interface` | 2.4.1 | BSD-2-Clause | `sqflite` |
| `sqflite_darwin` | 2.4.3+1 | BSD-2-Clause | `sqflite` |
| `flutter_secure_storage_*` | 多个 | BSD-3-Clause | `flutter_secure_storage` |
| `path_provider*` | 多个 | BSD-3-Clause | Flutter 插件依赖链 |

其余 Dart/Flutter 运行时包（包括 `async`、`collection`、`convert`、`crypto`、`ffi`、`http_parser`、`meta`、`web`、`win32`、`vector_math` 等）均在当前缓存版本的许可证文件中声明为 BSD-3-Clause 或同等 BSD 条款。`clock`、`fake_async`、`material_color_utilities` 等使用 Apache-2.0。测试专用包只用于开发和测试，不随应用逻辑分发。

Flutter SDK 和其 engine 自带的第三方组件另受 Flutter SDK 的许可证集合约束；正式发布 APK 时应同时保留 Flutter 生成的第三方许可信息，不要删除 SDK 生成的许可资源。

## 发布前需要做的事

1. 已有项目根目录 MIT `LICENSE`；发布时保留第三方内容的独立许可归属。
2. 已有 `THIRD_PARTY_NOTICES.md`，本轮补入 Codex 来源与改编说明；“设置 → 开源许可”展示项目许可、Codex LICENSE/NOTICE 和 Flutter 注册的依赖许可。发布时继续保留 `dbus` 的 MPL-2.0 声明、Bouncy Castle 声明和字体 OFL 文本。
3. 每次升级 `pubspec.lock` 后重新检查依赖图和许可证，避免新依赖悄悄引入强 copyleft 条款。
4. 对外发布 APK 时保留本项目的 `assets/fonts/OFL.txt`，并记录字体来源版本。

## 本次没有发现的问题

- 没有发现项目内复制 GPL/AGPL 源码的目录。
- 没有发现未经说明的 vendored Dart 包；依赖均来自 Pub 缓存并由 `pubspec.lock` 锁定哈希。
- 未修改旧项目 `apps/mobile`。
