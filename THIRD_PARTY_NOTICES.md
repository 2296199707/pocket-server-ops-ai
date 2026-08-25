# Third-party notices

PocketServerOps AI 使用以下开源项目。版本以 `pubspec.lock` 为准，许可证和版权声明以各上游项目随版本发布的文件为准。

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
