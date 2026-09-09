# GPT-6 模型与推理参数刷新记录

## 2026-09-08：Sub2API 最新源码核对

研究副本：`https://github.com/Wei-Shaw/sub2api.git`，远端 `main` 当前提交
`270eac6973049fe1b50eb75560a74a029e82884c`。

源码结论：

- `backend/internal/server/routes/gateway.go:71-76` 只要 `/models` 请求带有非空
  `client_version`，就转入 Codex 模型清单路由；不带时走普通 OpenAI 模型列表。
- `backend/internal/handler/openai_codex_models_handler.go:16-22` 明确规定自定义供应商
  使用 `GET {base_url}/models?client_version=...`。
- `backend/internal/service/openai_codex_models_service.go` 会把该版本参数转发到上游，
  并配套发送 `Authorization`、`Accept`、`Originator`、Codex `User-Agent` 和 `Version`。
  APP 访问 Sub2API 时只需提供鉴权和 `client_version`；身份头由 Sub2API 向其上游构造。
- 最新源码的 Codex 版本不是 Sub2API 的软件版本。源码通过手动设置、自动同步官方稳定版、
  内置版本兜底得到当前生效值；代码测试中的当前示例为 `0.200.1`，不能把 Sub2API 的
  `0.2.3` 当作 `client_version`。

## 2026-09-08：真实接口验证

使用用户授权的临时密钥测试 `https://ai-pixel.online/v1`，密钥未写入文件、文档或 Git：

- `GET /models`：HTTP 200，9 个普通模型，含 `gpt-6-astra`，无推理能力字段。
- `GET /models?client_version=0.150.0`：HTTP 200，6 个 Codex 模型，返回
  `default_reasoning_level` 和 `supported_reasoning_levels`，但不含 `gpt-6-astra`。
- `GET /models?client_version=0.200.1`：HTTP 200，7 个 Codex 模型，包含
  `gpt-6-astra`，并返回各模型的推理参数。例如 `gpt-5.6-luna` 返回
  `low/medium/high/xhigh/max`，`gpt-6-astra` 返回 `low/medium/high/xhigh/max/ultra`。
- 仅带 `Authorization`、`Accept` 和非空 `client_version` 即可从该网关得到能力清单；
  `Originator`、Codex `User-Agent`、`Version` 是 Sub2API 代理到上游时生成的身份头，
  不是 APP 获取该网关清单的额外必需条件。

## APP 修复方案

普通目录和 Codex 能力目录不能互相替换：

1. 先请求不带参数的 `/models`，以它作为最终模型集合，保留供应商新增模型。
2. 如果普通条目缺少推理元数据，再请求
   `/models?client_version=0.200.1`。
3. 按精确模型 ID/slug 合并 `default_reasoning_level` 和
   `supported_reasoning_levels` 等能力字段；能力清单中不存在的模型不凭名称推断，
   继续保持未知。
4. 能力请求失败时保留普通目录结果，不能因为能力补充失败而让模型刷新失败。
5. 已经包含完整推理字段的普通目录不重复请求能力目录；打开模型抽屉仍然只使用缓存，
   网络请求只发生在明确的模型/推理刷新流程。

测试覆盖：普通目录包含而旧 Codex 版本目录隐藏的新模型仍保留；能力目录返回的推理字段
按精确 ID 合并；未知供应商模型不被自动添加或猜测。

## 2026-09-09：beta.14 刷新失败复查（仅诊断，尚未修复）

### 发布包含性

- 上次修复提交为 `39c77b89fabcba3eeee0eac398d9415e834a9707`。
- `v1.0.5-beta.14` 的发布提交为
  `49ef077cd0c6b9efe51617cd04a9bddf785bdf4a`，已验证前者是后者的祖先。
- 从上次修复到该发布提交，`lib/providers/provider_connection_tester.dart`
  没有差异，因此不是漏合并或修复被覆盖。
- GitHub Release 已包含 `pocket-server-ops-ai-v1.0.5-beta.14-release.apk`。
  本地同名 APK 的实际包信息为 `versionName=1.0.5-beta.14`、`versionCode=58`。
  这不能代替确认用户手机当前安装的版本。

### 已复现的请求流程缺口

1. `provider_connection_tester.dart:169` 的补充条件要求同一条目同时缺少默认推理值
   和可选列表。如果目录条目都有默认值、但没有可选列表，就完全跳过能力请求。
   MockClient 复现：普通目录只返回 `default_reasoning_level=high`，能力端点准备返回
   `low/high`；实际仅发送一次请求，最终列表仍为 `null`。
2. `provider_connection_tester.dart:177` 的能力请求限时 10 秒；非 2xx、解析异常和
   超时均被捕获并返回 `null`。上层只得到普通模型目录，没有能力请求失败的诊断信息。
   MockClient 分别模拟 HTTP 502 和超时，均复现方法正常返回、推理列表仍为 `null`。
   保留普通模型结果本身有用，但不应把它等同于推理能力刷新成功。

验证：既有 `test/provider_connection_tester_test.dart` 的 8 项测试和 2 项临时诊断测试
全部通过。诊断测试确认上述缺口仍存在，不代表已修好。临时测试位于数据盘
`/www/mobile-agent-tooling/tmp/reasoning-audit-hg4rdE/reasoning_audit_test.dart`，未加入
应用测试目录；使用 `flutter test --no-pub --concurrency=1`，没有构建 APK 或请求真实 API。

### 抽屉与缓存链路

- `chat_page.dart:1366` 的模型刷新、`:1405` 的当前对话推理刷新、`:1436` 的子代理
  推理刷新都调用 `AppController.loadProviderModelMetadata`，并非仍在使用旧请求代码。
- `app_controller.dart:6173` 调用本次核对的 tester，并按精确模型 ID 合并到已保存
  供应商的 `modelMetadata`，写入数据库。抽屉在刷新返回后更新界面；只打开抽屉不请求网络。
- 由于 tester 的能力请求失败不抛出错误，对话推理刷新仍会设置
  `reasoningLoadFailed = false`；界面无法区分“能力请求失败”和“没有能力字段”。
- 获取元数据不等于修改已选择的推理强度。顶部按钮显示用户已保存的推理选择；
  目录的 `defaultReasoningLevel` 在抽屉中作为默认值说明，不自动覆盖用户设置。

### 尚未确认

尚未得到本次手机上的供应商地址、模型、实际版本和刷新入口，不能据以上模拟场景认定
用户遇到的是其中某一种失败，也不能据此归因供应商不支持。特别是先前实测的
`ai-pixel.online` 普通目录只含 ID，不会触发上述“默认值存在却跳过”的条件。
原始接口返回记录见本文件前文，不再重复查询 Sub2API/Codex 源码。

## 2026-09-09：补齐无元数据时的通用预设

根据用户提供的模型抽屉截图，已将供应商只返回模型 ID、没有返回
`supported_reasoning_levels` 时的通用预设从
`Default / Low / High / Max` 补齐为
`Default / Low / Medium / High / Extra High / Max / Ultra`。

这只影响未知能力时的选择器兜底；供应商明确返回能力列表时，仍严格显示返回值，
不会把通用档位混入供应商的精确列表。`xhigh` 在界面显示为 `Extra High`，`ultra`
显示为 `Ultra`。相关实现为 `lib/domain/models.dart`，聊天页和供应商设置页的提示文本
也已同步更新。
