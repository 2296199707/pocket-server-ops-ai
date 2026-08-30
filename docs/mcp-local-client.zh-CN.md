# 手机本地 MCP 客户端

## 当前实现

Pocket Server Ops 现在可以作为 MCP Client，连接手机上已经运行的 MCP
HTTP 服务。默认地址是：

```text
http://127.0.0.1:8787/mcp
```

设置入口为“设置 → MCP 工具”。保存配置后获取一次工具列表；工具定义会
缓存到 APP 数据库，打开对话不会重复请求。用户点击“刷新工具列表”时才
重新获取。

MCP 工具缓存只保存名称、描述、输入参数 schema 和标准 annotations，不保存
工具返回结果。访问令牌只保存在手机安全存储，不进入配置 JSON，也不会加入
AI 上下文。

## 协议流程

客户端使用 MCP Streamable HTTP 的 POST 方式：

```text
initialize
notifications/initialized
tools/list（支持 nextCursor 分页）
tools/call
```

请求带有：

```text
Accept: application/json, text/event-stream
Content-Type: application/json
MCP-Protocol-Version: 协商后的版本（初始化之后）
Mcp-Session-Id: 服务端返回的会话 ID（服务端提供时）
```

普通 JSON 和 `text/event-stream` 响应都支持。SSE 响应会按 JSON-RPC 请求 ID
匹配结果，避免把进度通知误当成工具结果。

如果 `tools/list` 收到 HTTP 404，客户端会重新初始化会话并重新获取列表。
如果 `tools/call` 收到 HTTP 404，客户端同样重新初始化，但不会自动重放该
工具调用；因为有副作用的调用在网络边界上的执行状态无法确认，错误会返回给
Agent，由 Agent 先确认状态再决定下一步。

## Agent 接入

启用的 MCP 配置中，已缓存的工具会转换为现有 `AgentTool`。工具名使用：

```text
mcp_<mcp-id>__<tool-name>
```

这样不同 MCP 服务的同名工具不会冲突。MCP 工具可以和手机文件、项目、SSH
及子代理工具一起出现在同一个 Agent 会话中。

如果 MCP 服务的工具 annotations 明确给出 `readOnlyHint: true`，该工具沿用
只读工具行为；没有这个标记的工具沿用现有 Agent 的确认和执行状态规则，避免
根据名称猜测它是否会修改数据。

## 真机验证

开发环境不能访问手机自身的 `127.0.0.1`，因此 MT MCP 服务需要在真机 APK
中验证以下项目：

1. `initialize` 是否接受 `2025-06-18` 并返回协商版本；
2. `notifications/initialized` 是否返回 202 或空响应；
3. `tools/list` 的 `Content-Type` 是 JSON 还是 SSE；
4. 工具 schema 是否使用标准 `inputSchema`；
5. 如果回环地址不能跨应用访问，再使用 MT 显示的局域网地址。

若 MT 只提供旧版独立 SSE transport，当前客户端会明确报协议响应错误，暂不
把旧协议静默当作标准 Streamable HTTP。确认真实响应格式后再增加针对性兼容，
避免把两种协议混在一起造成工具调用或会话状态错误。
