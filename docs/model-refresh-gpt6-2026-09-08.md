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
