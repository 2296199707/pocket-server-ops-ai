# 手机 Agent 图像工具完善

## 范围与依据

补齐主动查看项目/已授权本地图片、查看已有附件、网页视口截图、生图后回看。继续使用现有附件独立存储，不将图片 base64 写入事件数据库，不改变供应商协议或目录授权。

依据 OpenAI function-calling 官方文档：Responses 的 function_call_output.output 可以是图片与文本对象数组。参考：https://developers.openai.com/api/docs/guides/function-calling/ 。Chat Completions 保留文本工具结果，所有连续工具结果之后再投影图片 user 消息，避免打断工具调用配对；不把该投影写成用户历史。

## 进度

- 已实现 AiToolResult 图片载荷、AgentLoop 事件附件引用、两种请求协议图片序列化、历史工具附件恢复。
- 已接入 image.view 与 preview.screenshot，在正常运行和主动压缩的工具集合中保持一致。项目/本地访问遵守工作模式；附件只可读取当前对话所属内容。
- image.generate 返回真实像素，并按实际文件格式保存，避免将 JPEG 等错误标记为 PNG。
- 原生截图已接入 MainActivity 通道及释放流程。审查发现完全未附着 WebView 的视觉回调不可靠，已改为附着在 Flutter 后层的独立 WebView，待视觉状态就绪后截图。
- 81 项相关测试通过：两种协议序列化、工具调用配对、下一轮像素输入、事件仅保存引用、目录越界与授权、文件格式、截图方法通道及 Agent 既有流程。
- 另 1 项控制器持久化测试通过：工具结果的图片引用在重启后恢复真实图片数据。
- Dart 静态检查通过。Android 首次编译发现 VisualStateCallback 是抽象类、不能直接使用 Kotlin lambda，已改为显式对象实现；Release 构建完成，APK 签名校验通过。构建均使用数据盘现有缓存、单次构建锁和 1 个 Gradle worker，未启动模拟器、未发布。
- 构建产物：`/www/mobile-agent-build/app/outputs/flutter-apk/app-release.apk`（80,858,369 字节）；仍为开发工作树的 `1.0.7-beta.2+61`，没有修改发布版本号。构建结果于 2026-09-16 收尾核实，Gradle 日志 `daemon-2845807.out.log` 显示 2026-09-15 13:31:17 UTC 完成。

## 明确边界

截图是新 WebView 渲染，不是用户当前浏览器或其他 App 的屏幕截图。PNG/JPEG/WebP 保留原图；GIF 工具读取使用首帧。不支持的图片格式明确报错。预览截图需要 Android 环境；未进行真实供应商付费测试，不宣称设备端视觉验证通过。

设备检查没有可用 adb 设备。HTML/CSS 和普通 Canvas 使用 View.draw(Canvas)；WebGL、视频、摄像头等硬件合成内容可能不能完整捕获。截图不保证异步业务已全部完成，需结合 preview.logs/local.test_web。当前截图不提供点击或键盘自动化。

Android 依据：
- https://developer.android.com/reference/android/webkit/WebView#postVisualStateCallback(long,android.webkit.WebView.VisualStateCallback)
- https://developer.android.com/reference/android/webkit/WebSettings#setOffscreenPreRaster(boolean)
- https://developer.android.com/reference/android/view/View#draw(android.graphics.Canvas)

关键代码：lib/agent/phone_image_tools.dart、lib/agent/ai_protocol.dart、lib/agent/agent_loop.dart、lib/app_controller.dart、android/app/src/main/kotlin/com/mobileagent/mobile_agent/PreviewScreenshotCapture.kt。

## 2026-09-18 服务器看图补充

用户确认采用最小方案：截图由 AI 使用现有终端命令及按需准备的浏览器环境完成；APP 补齐 SSH 图片读取到模型视觉输入。不安装常驻截图服务，也不要求绑定手机项目。

- 已添加 `server.view_image(remote_path)`，相对路径沿用服务器工作目录。只读工具复用现有 SSH 身份权限和审批模式；图片保存为当前对话附件，不写入手机共享目录。
- 多服务器沿用 `server_id` 路由，单服务器和多服务器均为图像结果补充来源服务器 ID/名称，保留附件像素。未知服务器或多服务器未指定目标沿用原有错误反馈。
- 已接入单服务器、多服务器及主动压缩时的工具集合；每轮更新模型能力判断，缓存的 SSH 运行时不会沿用旧模型配置。
- 图片验证、格式识别及 GIF 首帧转换与手机看图共用。已明确不支持视觉的模型在下载前返回工具错误；供应商未声明能力时允许尝试，协议保持用户配置。
- 验证完成：39 项测试通过（34 项相关回归、2 项历史恢复/失败后继续运行回归、3 项新增服务器图片测试）。新增测试使用真实 PNG 字节和模拟 SSH，覆盖无手机项目看图、相对/绝对路径、更新运行时回调、多服务器来源及像素保留、无效图片或 SSH 错误时不持久化。主代理已审阅子代理测试。
- Dart 静态检查与 git diff --check 通过；没有进行真实远程服务器截图或付费模型视觉实测。
- 本轮仅调整 Dart 工具与控制器，未改原生截图、未安装服务器浏览器环境、未使用真实供应商 API。前节 APK 是上一轮手机图像能力产物，本轮服务器能力尚未构建或发布。

## 2026-09-20 Beta 发布收尾

- 手机/服务器图像能力和可选流量仪表盘合并进入 `1.0.7-beta.3+62`。
- 2026-09-19 16:49:22 UTC，数据盘 Release 构建完成；本轮续接核实已有产物，没有重启构建。
- APK：`/www/mobile-agent-build/app/outputs/flutter-apk/pocket-server-ops-ai-v1.0.7-beta.3-release.apk`，80,858,365 字节；签名和包名与上一版一致。
- SHA-256：`bcf62a5335f00fac5485e04dc71d8959d0f1e8e866fb36ec7b07eb084325b8ed`。更新清单及 Release 说明同步准备，按用户授权提交至 beta 并创建预发布。
