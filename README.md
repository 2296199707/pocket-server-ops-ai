# PocketServerOps AI

PocketServerOps AI 是一款面向服务器运维的 Android 手机应用。它将 AI 对话、SSH 连接、终端、远程文件管理和服务器状态查看整合在手机端，无需在目标服务器安装 Agent。

## 功能

- AI 普通对话与服务器运维 Agent
- 通过 SSH 执行命令、运行长任务和交互输入
- 远程文件浏览、读取、编辑、保存和新建文件
- 服务器仪表盘：CPU、内存、磁盘、负载、运行时间和系统信息
- AI 供应商、模型和连接测试设置
- 主机指纹确认、任务历史和任务状态恢复
- 图片/文件附件持久化、长对话历史分页和 Codex 风格 Responses 上下文压缩
- Android 前台服务，支持切换应用后继续运行手机端任务
- 服务器状态脚本一键安装或更新；脚本按需执行，不在服务器常驻运行
- 手机项目网页预览、控制台日志、页面/资源错误反馈和静态资源检查

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
- Agent 命令和写入工具支持执行前确认、自动审查后执行和自由执行三种模式；
  项目外手机文件始终需要用户单独授权。
- 项目文件工具会检查真实路径，项目内符号链接不能绕出项目文件夹。
- 自动审查使用单独选择的 AI 供应商和模型；审查请求失败或返回无法识别的结果时转为人工确认，
  不会自动更换协议或供应商。
- 任务遇到无法确认的远端状态时不会自动重放，用户需要人工检查服务器。

## 手机项目预览

绑定手机项目后，可以从项目文件管理器或对话输入框的“+”菜单打开本地网页预览。
预览服务只监听手机回环地址，只读取当前项目文件夹；它支持 HTML/CSS/JavaScript 和静态媒体，
并收集控制台、未捕获 JavaScript 异常、Promise 异常、资源加载错误和 HTTP 错误。
Agent 可以使用 `preview.start`、`preview.status`、`preview.reload`、`preview.logs`、
`preview.stop` 和 `local.test_web` 查看或检查预览状态。

这不是手机上的 Node、Python、Flutter 或完整浏览器 DevTools；这类运行时和测试仍应交给服务器。

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
