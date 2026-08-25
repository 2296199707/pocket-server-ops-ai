# PocketServerOps AI

PocketServerOps AI 是一款面向服务器运维的 Android 手机应用。它将 AI 对话、SSH 连接、终端、远程文件管理和服务器状态查看整合在手机端，无需在目标服务器安装 Agent。

## 功能

- AI 普通对话与服务器运维 Agent
- 通过 SSH 执行命令、运行长任务和交互输入
- 远程文件浏览、读取、编辑、保存和新建文件
- 服务器仪表盘：CPU、内存、磁盘、负载、运行时间和系统信息
- AI 供应商、模型和连接测试设置
- 主机指纹确认、任务历史和任务状态恢复
- Android 前台服务，支持切换应用后继续运行手机端任务
- 服务器状态脚本一键安装或更新；脚本按需执行，不在服务器常驻运行

## 工作方式

```text
手机 App ── AI API
    │
    └──── SSH ──── 目标服务器
```

Agent、AI 请求、工具调用、任务历史和 SSH 连接均运行在手机端。目标服务器不需要安装 PocketServerOps AI，也不会保存手机端的 AI API Key。

## 安全性

- SSH 密码、私钥、私钥口令和 AI API Key 保存在手机安全存储中。
- 这些凭据不会写入 AI 消息、工具参数或任务历史事件。
- 首次连接需要确认服务器主机指纹。
- 命令执行支持自动执行和执行前确认两种模式。
- 任务遇到无法确认的远端状态时不会自动重放，用户需要人工检查服务器。

## 构建

需要 Flutter SDK、Android SDK 和 JDK。安装依赖后执行：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

构建 Web 预览：

```bash
flutter build web --release --dart-define=PREVIEW_MODE=true
python3 -m http.server 4173 -d build/web
```

预览使用内存演示数据，不连接真实 AI 供应商或服务器。

## 文档

- [开源依赖与许可证审查](docs/open-source-audit.zh-CN.md)
- [第三方许可索引](THIRD_PARTY_NOTICES.md)
- [架构与复用调查](docs/wfl-reuse-audit-and-mobile-agent-v1.zh-CN.md)

## 许可证

本项目使用 [MIT License](LICENSE)。字体资源 Noto Sans SC 使用 SIL Open Font License 1.1，详见 [assets/fonts/OFL.txt](assets/fonts/OFL.txt)。
