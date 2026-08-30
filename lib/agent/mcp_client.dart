import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'agent_tools.dart';
import 'ai_protocol.dart';

/// MCP protocol version used for a new Streamable HTTP session.
const mcpProtocolVersion = '2025-06-18';

class McpException implements Exception {
  const McpException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message：$cause';
}

class McpHttpException extends McpException {
  const McpHttpException(this.statusCode, String message) : super(message);

  final int statusCode;
}

class McpRpcException extends McpException {
  const McpRpcException({
    required this.code,
    required String message,
    this.data,
  }) : super(message);

  final int code;
  final Object? data;
}

/// The server discarded a session. The client re-initializes it, but does not
/// replay a tool call whose execution state is unknown.
class McpSessionExpiredException extends McpException {
  const McpSessionExpiredException() : super('MCP 会话已失效，已重新连接；请确认状态后再重试工具操作');
}

class McpToolDescriptor {
  const McpToolDescriptor({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.title,
    this.annotations = const {},
  });

  final String name;
  final String description;
  final String? title;
  final Map<String, Object?> inputSchema;
  final Map<String, Object?> annotations;

  factory McpToolDescriptor.fromMap(Map<String, Object?> map) {
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('MCP 工具缺少名称');
    }
    final schema = map['inputSchema'];
    final annotations = map['annotations'];
    return McpToolDescriptor(
      name: name,
      description: map['description'] as String? ?? '',
      title: map['title'] as String?,
      inputSchema: schema is Map
          ? Map<String, Object?>.from(schema)
          : const {'type': 'object', 'properties': {}},
      annotations: annotations is Map
          ? Map<String, Object?>.from(annotations)
          : const {},
    );
  }

  McpToolProfile toProfile() => McpToolProfile(
    name: name,
    description: description,
    title: title,
    inputSchema: inputSchema,
    annotations: annotations,
  );

  bool get isReadOnly => annotations['readOnlyHint'] == true;
}

/// HTTP JSON-RPC client for MCP Streamable HTTP endpoints.
///
/// The client keeps the session in memory. Tool definitions are stored by the
/// controller, so restarting the app does not require an endpoint request just
/// to render or prepare a conversation; the first actual call creates a new
/// session when needed.
class McpClient {
  // The public tokenLoader name keeps credentials injectable without exposing
  // the private field name to callers in another library.
  McpClient({
    required this.url,
    Future<String?> Function()? tokenLoader,
    http.Client? client,
    this.clientName = 'pocket-server-ops-ai',
    this.clientVersion = '1.0.4',
    this.requestTimeout = const Duration(minutes: 2),
  })
    // ignore: prefer_initializing_formals
    : _tokenLoader = tokenLoader,
       _client = client ?? http.Client();

  final String url;
  final String clientName;
  final String clientVersion;
  final Duration requestTimeout;
  final Future<String?> Function()? _tokenLoader;
  final http.Client _client;

  String? _sessionId;
  String? _protocolVersion;
  Future<void>? _initializing;
  var _nextRequestId = 0;
  var _initialized = false;
  var _closed = false;

  String? get sessionId => _sessionId;
  String? get protocolVersion => _protocolVersion;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    _ensureOpen();
    if (_initialized) return;
    final pending = _initializing;
    if (pending != null) return pending;
    late Future<void> current;
    current = _initialize();
    _initializing = current;
    try {
      await current;
    } finally {
      if (identical(_initializing, current)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    _initialized = false;
    _sessionId = null;
    _protocolVersion = null;
    final result = await _request(
      'initialize',
      params: {
        'protocolVersion': mcpProtocolVersion,
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': clientName, 'version': clientVersion},
      },
    );
    if (result is! Map) {
      throw const McpException('MCP initialize 返回格式无效');
    }
    final advertised = result['protocolVersion'];
    _protocolVersion = advertised is String && advertised.trim().isNotEmpty
        ? advertised.trim()
        : mcpProtocolVersion;
    await _notification('notifications/initialized');
    _initialized = true;
  }

  Future<List<McpToolDescriptor>> listTools() async {
    await initialize();
    final descriptors = <McpToolDescriptor>[];
    String? cursor;
    while (true) {
      final params = <String, Object?>{};
      if (cursor != null) params['cursor'] = cursor;
      Object? result;
      try {
        result = await _request('tools/list', params: params);
      } on McpHttpException catch (error) {
        if (error.statusCode != 404) rethrow;
        await _reinitializeAfterSessionLoss();
        result = await _request('tools/list', params: params);
      }
      if (result is! Map) {
        throw const McpException('MCP tools/list 返回格式无效');
      }
      final rawTools = result['tools'];
      if (rawTools is! List) {
        throw const McpException('MCP tools/list 缺少 tools 列表');
      }
      for (final rawTool in rawTools) {
        if (rawTool is! Map) continue;
        descriptors.add(
          McpToolDescriptor.fromMap(Map<String, Object?>.from(rawTool)),
        );
      }
      final next = result['nextCursor'];
      if (next is! String || next.trim().isEmpty || next == cursor) break;
      cursor = next;
    }
    return List.unmodifiable(descriptors);
  }

  Future<Object?> callTool(String name, Map<String, Object?> arguments) async {
    await initialize();
    try {
      return await _request(
        'tools/call',
        params: {'name': name, 'arguments': arguments},
      );
    } on McpHttpException catch (error) {
      if (error.statusCode != 404) rethrow;
      // A 404 means the session is gone. Reinitialize for the next call, but
      // never replay this call because the server's execution state is not
      // knowable at the transport boundary.
      await _reinitializeAfterSessionLoss();
      throw const McpSessionExpiredException();
    }
  }

  Future<void> _reinitializeAfterSessionLoss() async {
    _initialized = false;
    _sessionId = null;
    _protocolVersion = null;
    await initialize();
  }

  Future<Object?> _request(
    String method, {
    required Map<String, Object?> params,
  }) async {
    final id = ++_nextRequestId;
    final response = await _post({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return _decodeRpcResponse(response, id);
  }

  Future<void> _notification(String method) async {
    final response = await _post({'jsonrpc': '2.0', 'method': method});
    // Notifications normally receive 202 with an empty body. A server that
    // returns a JSON acknowledgement is also valid for this client.
    if (response.body.trim().isNotEmpty) {
      _decodeRpcResponse(response, null, allowMissingId: true);
    }
  }

  Future<_McpHttpResponse> _post(Map<String, Object?> body) async {
    _ensureOpen();
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const McpException('MCP 地址必须是 http 或 https URL');
    }
    final headers = <String, String>{
      'Accept': 'application/json, text/event-stream',
      'Content-Type': 'application/json',
    };
    if (_protocolVersion != null) {
      headers['MCP-Protocol-Version'] = _protocolVersion!;
    }
    if (_sessionId != null && _sessionId!.isNotEmpty) {
      headers['Mcp-Session-Id'] = _sessionId!;
    }
    final token = (await _tokenLoader?.call())?.trim();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    late http.Response response;
    try {
      response = await _client
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(requestTimeout);
    } on TimeoutException catch (error) {
      throw McpException('MCP 请求超时', cause: error);
    } on SocketException catch (error) {
      throw McpException('MCP 连接失败', cause: error);
    } on http.ClientException catch (error) {
      throw McpException('MCP HTTP 请求失败', cause: error);
    }
    final session = response.headers['mcp-session-id'];
    if (session != null && session.trim().isNotEmpty) {
      _sessionId = session.trim();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = response.body.trim();
      if (message.length > 4096) message = message.substring(0, 4096);
      if (token != null && token.isNotEmpty) {
        message = message.replaceAll(token, '[redacted]');
      }
      throw McpHttpException(
        response.statusCode,
        message.isEmpty ? 'MCP 服务返回 HTTP ${response.statusCode}' : message,
      );
    }
    return _McpHttpResponse(
      body: response.body,
      contentType: response.headers['content-type'] ?? '',
    );
  }

  Object? _decodeRpcResponse(
    _McpHttpResponse response,
    Object? expectedId, {
    bool allowMissingId = false,
  }) {
    final text = response.body.trim();
    if (text.isEmpty) return null;
    Object? decoded;
    final isSse =
        response.contentType.toLowerCase().contains('text/event-stream') ||
        text.startsWith('data:');
    if (isSse) {
      final messages = _sseMessages(text);
      if (messages.isEmpty) {
        throw const McpException('MCP SSE 响应为空');
      }
      if (expectedId == null) {
        decoded = messages.first;
      } else {
        final matching = messages.where(
          (value) => value is Map && value['id'] == expectedId,
        );
        if (matching.isEmpty) {
          throw const McpException('MCP SSE 响应缺少对应的 JSON-RPC result');
        }
        decoded = matching.first;
      }
    } else {
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (error) {
        throw McpException('MCP 返回了无效 JSON', cause: error);
      }
    }
    if (decoded is! Map) {
      throw const McpException('MCP JSON-RPC 响应格式无效');
    }
    final map = Map<String, Object?>.from(decoded);
    if (expectedId != null && map['id'] != null && map['id'] != expectedId) {
      throw const McpException('MCP JSON-RPC 响应 ID 不匹配');
    }
    if (map['error'] is Map) {
      final error = Map<String, Object?>.from(map['error'] as Map);
      final code = error['code'];
      final message = error['message'];
      throw McpRpcException(
        code: code is int ? code : -32603,
        message: message is String ? message : 'MCP JSON-RPC 调用失败',
        data: error['data'],
      );
    }
    if (!map.containsKey('result')) {
      if (allowMissingId) return null;
      throw const McpException('MCP JSON-RPC 响应缺少 result');
    }
    return map['result'];
  }

  static List<Object?> _sseMessages(String text) {
    final messages = <Object?>[];
    final dataLines = <String>[];

    void flush() {
      if (dataLines.isEmpty) return;
      final data = dataLines.join('\n').trim();
      dataLines.clear();
      if (data.isEmpty || data == '[DONE]') return;
      try {
        messages.add(jsonDecode(data));
      } on FormatException {
        // Ignore non-message SSE events such as a legacy endpoint event.
      }
    }

    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) {
        flush();
      } else if (line.startsWith('data:')) {
        final value = line.substring(5);
        dataLines.add(value.startsWith(' ') ? value.substring(1) : value);
      }
    }
    flush();
    return messages;
  }

  void _ensureOpen() {
    if (_closed) throw const McpException('MCP 客户端已关闭');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class _McpHttpResponse {
  const _McpHttpResponse({required this.body, required this.contentType});

  final String body;
  final String contentType;
}

/// Converts cached MCP definitions into the app's existing AgentTool shape.
class McpAgentTools {
  const McpAgentTools({required this.profile, required this.client});

  final McpServerProfile profile;
  final McpClient client;

  List<AgentTool> get tools => [
    for (final cached in profile.tools)
      _tool(
        McpToolDescriptor(
          name: cached.name,
          description: cached.description,
          title: cached.title,
          inputSchema: cached.inputSchema,
          annotations: cached.annotations,
        ),
      ),
  ];

  AgentTool _tool(McpToolDescriptor descriptor) {
    final description = descriptor.description.trim();
    final title = descriptor.title?.trim();
    final label = title == null || title.isEmpty ? '' : '$title：';
    return AgentTool(
      definition: AiToolDefinition(
        name: mcpAgentToolName(profile.id, descriptor.name),
        description:
            '[MCP ${profile.name}] $label${description.isEmpty ? '调用本地 MCP 工具' : description}',
        parameters: descriptor.inputSchema,
      ),
      call: (arguments) => client.callTool(descriptor.name, arguments),
      // MCP annotations explicitly identify read-only tools. All other tools
      // remain confirmable and are treated as potentially state-changing by
      // the existing AgentLoop cancellation semantics.
      requiresConfirmation: !descriptor.isReadOnly,
      writesRemoteState: !descriptor.isReadOnly,
    );
  }
}

String mcpAgentToolName(String serverId, String toolName) {
  String safe(String value) => value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return 'mcp_${safe(serverId)}__${safe(toolName)}';
}
