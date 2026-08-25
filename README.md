# PocketServerOps AI

这是独立的手机端 Agent 第一版。手机保存 AI 供应商配置和 SSH 凭据，AgentLoop、工具调用、任务历史和 Android 前台任务服务都运行在手机上。

GitHub 项目名建议使用 `pocket-server-ops`，应用显示名为 `PocketServerOps AI`。

开源依赖和许可证审查见 [docs/open-source-audit.zh-CN.md](docs/open-source-audit.zh-CN.md)。

## 当前范围

- 普通 AI 对话；
- 手机直接 SSH 连接目标服务器；
- 命令执行、长任务、交互输入和停止；
- UTF-8 文件读取、写入和精确文本替换；
- 远程文件管理器，支持目录浏览、文本编辑保存和新建空文件；
- 服务器仪表盘，支持 CPU、内存、磁盘、负载、运行时间和系统信息刷新；
- 用户目录状态脚本的一键安装/更新，脚本只在刷新仪表盘时执行；
- AI 供应商设置和模型读取；
- 主机指纹确认、任务历史和失败/未知状态恢复；
- Android 前台服务，支持切换应用后保持当前手机任务运行。

## 运行边界

- Agent 每轮最多执行 64 个模型步骤和 128 次工具调用；达到上限或远端操作出现不确定错误时，任务标记为 `unknown`，需要人工检查服务器，不自动重放；
- AI 请求严格使用 Responses API，并在请求中启用官方 server-side compaction；手机不猜测模型 token 窗口，也不把响应按 1 MiB 或字符数硬截断。供应商不支持 `/responses` 或拒绝 compaction 参数时直接报错，不改请求协议；
- Responses 返回的 reasoning、function call 和加密 compaction output item 会原样保存到任务事件；出现 compaction 后，下一次请求保留最新 compaction item，并按官方建议丢弃它之前的旧输入，任务重启也按同一规则恢复，不自行摘要或修改 opaque item；
- `terminal.exec` 最多运行 2 分钟，更长或交互式命令使用 `terminal.start`；任务结束时仍由手机托管的长进程会被停止并释放 SSH，确需脱离当前任务运行的服务应交给服务器自身的服务管理器；
- 命令 stdout/stderr 不再静默丢弃固定大小；长进程通过 `terminal.poll` 的 stdout/stderr 偏移增量读取，任务释放时清理进程缓存；
- `file.read` 按字节 `offset`/`length` 分页（单页最多 1 MiB），通过 `next_offset` 和 `eof` 继续读取，文件本身没有 4 MiB 硬上限；`file.write` 仍先写同目录临时文件，再重命名覆盖目标文件；
- 状态脚本安装在 `~/.local/bin/mobile-agent-status`，不需要 root 权限，不注册 systemd 服务，也不在服务器常驻运行；
- 任务事件不再截断长字符串，以便完整恢复 AI 历史和 opaque output item；SQLite 仍受设备剩余存储空间约束。

多个手机 Agent 任务可以并发运行，每个任务使用独立的 AI 请求、SSH 连接和取消状态；同一服务器和工作目录的远端写入工具按顺序执行，读操作和不同工作目录仍可并发。Android 前台服务会跟踪活动任务数量，最后一个任务结束后才停止。逐项确认模式下，不同任务的确认请求会按顺序显示，并标明发起请求的任务名称。

目标服务器不安装 Agent，不运行中转服务，也不保存手机端 API Key。切换应用时，Android 前台服务帮助手机进程保持运行；如果手机进程被系统终止，正在运行的任务会标记为未知，不会自动重放，也不会只重启一个假通知服务。

密码、私钥、私钥口令和 AI API Key 只写入手机安全存储。它们不会进入 AI 消息、工具参数或任务事件；AI 工具只暴露命令、文件和进程操作。

## 明确不包含

本版本移除了中转服务器、服务器托管 Agent、Relay API、OpenCode 任务和服务器端持久运行能力。原始完整版本仍保留在 `../mobile`，本版本的调查记录在 `docs/wfl-reuse-audit-and-mobile-agent-v1.zh-CN.md`。

## 预览和构建

预览构建只使用内存演示数据，不连接真实服务器或供应商；`PREVIEW_MODE` 仅是构建 Web 演示包的开关，不是产品运行模式：

```bash
./tool/build_preview.sh
python3 -m http.server 4173 -d build/preview/web
```

构建 Android debug APK：

```bash
./tool/build_apk.sh
```

Flutter SDK、Android SDK、Pub 缓存和构建输出继续放在 `/www`，不要移动或清理其他项目。
