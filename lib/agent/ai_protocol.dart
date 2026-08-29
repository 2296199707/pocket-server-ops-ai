import 'dart:convert';

enum AiProviderHttpErrorKind {
  unauthorized,
  rateLimited,
  client,
  server,
  other,
}

/// Common HTTP error contract for the explicitly selected AI protocol.
///
/// The body is expected to be redacted and bounded by the client that read it.
class AiProviderHttpException implements Exception {
  const AiProviderHttpException({
    required this.protocol,
    required this.statusCode,
    required this.body,
  });

  final String protocol;
  final int statusCode;
  final String body;

  AiProviderHttpErrorKind get kind {
    if (statusCode == 401) return AiProviderHttpErrorKind.unauthorized;
    if (statusCode == 429) return AiProviderHttpErrorKind.rateLimited;
    if (statusCode >= 500) return AiProviderHttpErrorKind.server;
    if (statusCode >= 400) return AiProviderHttpErrorKind.client;
    return AiProviderHttpErrorKind.other;
  }

  @override
  String toString() {
    final suffix = body.isEmpty ? '' : ': $body';
    return '$protocol HTTP error $statusCode$suffix';
  }
}

class AiAttachment {
  const AiAttachment({
    this.id,
    required this.name,
    required this.mimeType,
    this.byteLength,
    this.base64Data,
  });

  final String? id;
  final String name;
  final String mimeType;
  final int? byteLength;

  /// Present only while an attachment is being sent to the provider. Durable
  /// events store [id] and metadata instead of retaining the encoded file.
  final String? base64Data;

  bool get isImage => mimeType.toLowerCase().startsWith('image/');

  String get dataUrl {
    final encoded = base64Data;
    if (encoded == null) throw StateError('附件尚未载入：$name');
    return 'data:$mimeType;base64,$encoded';
  }

  Map<String, Object?> toJson() {
    final attachmentId = id;
    if (attachmentId != null && attachmentId.isNotEmpty) {
      return {
        'attachment_id': attachmentId,
        'name': name,
        'mime_type': mimeType,
        if (byteLength != null) 'size': byteLength,
      };
    }
    return {
      'name': name,
      'mime_type': mimeType,
      if (byteLength != null) 'size': byteLength,
      if (base64Data != null) 'base64': base64Data,
    };
  }

  factory AiAttachment.fromJson(Map<String, Object?> json) {
    final id = json['attachment_id'];
    final name = json['name'];
    final mimeType = json['mime_type'];
    final base64Data = json['base64'];
    final byteLength = json['size'];
    if (name is! String ||
        mimeType is! String ||
        (id is! String && base64Data is! String)) {
      throw const FormatException('附件格式无效');
    }
    return AiAttachment(
      id: id is String ? id : null,
      name: name,
      mimeType: mimeType,
      byteLength: byteLength is int ? byteLength : null,
      base64Data: base64Data is String ? base64Data : null,
    );
  }
}

class AiMessage {
  const AiMessage({
    required this.role,
    this.content,
    this.toolCalls = const [],
    this.toolCallId,
    this.name,
    this.reasoningContent,
    this.finishReason,
    this.responsesOutputItems = const [],
    this.usage,
    this.attachments = const [],
  });

  final String role;
  final String? content;
  final List<AiToolCall> toolCalls;
  final String? toolCallId;
  final String? name;

  /// DeepSeek Chat Completions returns this alongside tool calls and requires
  /// it to be replayed on the next request.
  final String? reasoningContent;

  /// The provider's termination reason. This is kept for AgentLoop decisions
  /// and is intentionally not sent back in the next API request.
  final String? finishReason;

  /// Raw output items returned by the Responses API.
  ///
  /// Responses output is also valid input for the next stateless Responses
  /// request. Keep these items opaque: reasoning and compaction items may
  /// contain provider-encrypted state that cannot be recreated from
  /// [content] or [toolCalls].
  final List<Map<String, Object?>> responsesOutputItems;

  /// Provider-reported usage for this response, when available. This is UI
  /// telemetry only and is intentionally excluded from the next request.
  final Map<String, Object?>? usage;

  final List<AiAttachment> attachments;

  factory AiMessage.user(
    String content, {
    List<AiAttachment> attachments = const [],
  }) {
    return AiMessage(
      role: 'user',
      content: content,
      attachments: List.unmodifiable(attachments),
    );
  }

  factory AiMessage.tool({
    required String toolCallId,
    required String content,
  }) {
    return AiMessage(role: 'tool', content: content, toolCallId: toolCallId);
  }

  Map<String, Object?> toJson() {
    final result = <String, Object?>{'role': role};
    if (content != null) result['content'] = content;
    if (name != null) result['name'] = name;
    if (reasoningContent != null) {
      result['reasoning_content'] = reasoningContent;
    }
    if (toolCallId != null) result['tool_call_id'] = toolCallId;
    if (toolCalls.isNotEmpty) {
      result['tool_calls'] = toolCalls.map((call) => call.toJson()).toList();
    }
    if (attachments.isNotEmpty) {
      result['attachments'] = attachments.map((item) => item.toJson()).toList();
    }
    return result;
  }

  /// Representation used only when estimating a locally configured history
  /// budget. A Responses request sends [responsesOutputItems] directly.
  Map<String, Object?> toHistoryJson() {
    final result = toJson();
    if (responsesOutputItems.isNotEmpty) {
      result['responses_output_items'] = responsesOutputItems;
    }
    return result;
  }
}

class AiToolCall {
  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.callId,
  });

  final String id;
  final String name;
  final String arguments;

  /// Responses API uses a separate call_id from the output item's id.
  final String? callId;

  /// The Responses API requires the provider-issued call_id when returning a
  /// function_call_output. Never substitute the output item id or a local id:
  /// those values identify a different object in the protocol.
  String get effectiveCallId {
    final value = callId;
    if (value == null || value.isEmpty) {
      throw StateError('Responses function call is missing call_id');
    }
    return value;
  }

  /// Chat Completions identifies a tool result with the tool-call id itself;
  /// Responses uses its separate call_id. AgentLoop uses this protocol-neutral
  /// value after the selected client has validated its own wire format.
  String get toolResultId => callId == null || callId!.isEmpty ? id : callId!;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'type': 'function',
      'function': {'name': name, 'arguments': arguments},
    };
  }

  Map<String, Object?> toEventJson({bool responses = true}) {
    return {...toJson(), 'call_id': responses ? effectiveCallId : toolResultId};
  }
}

class AiToolDefinition {
  const AiToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// Responses function names allow only letters, digits, `_`, and `-`.
  /// Keep the dotted internal names used by the app, but use a legal wire
  /// name when talking to the provider.
  String get providerName => providerToolName(name);

  Map<String, Object?> toJson() {
    return {
      'type': 'function',
      'function': {
        'name': providerName,
        'description': description,
        'parameters': parameters,
      },
    };
  }
}

String providerToolName(String name) {
  return name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}

Map<String, Object?> decodeObject(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) {
    throw const FormatException('tool arguments must be an object');
  }
  return Map<String, Object?>.from(decoded);
}
