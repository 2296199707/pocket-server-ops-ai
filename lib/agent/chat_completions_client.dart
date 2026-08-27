import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_protocol.dart';
import 'openai_compatible_client.dart';

const int _maxProviderErrorBytes = 64 * 1024;
const int _maxProviderErrorCharacters = 2_000;

/// A bounded provider HTTP error. [body] is already redacted before it is
/// stored in the exception.
class ChatCompletionsHttpException extends AiProviderHttpException {
  const ChatCompletionsHttpException({
    required super.statusCode,
    required super.body,
  }) : super(protocol: 'Chat Completions');

  @override
  String toString() {
    final suffix = body.isEmpty ? '' : ': $body';
    return 'Chat Completions HTTP error $statusCode$suffix';
  }
}

/// Raised when the selected endpoint clearly does not expose Chat
/// Completions. The client never silently changes to another protocol.
class ChatCompletionsUnsupportedException extends ChatCompletionsHttpException {
  const ChatCompletionsUnsupportedException({
    required super.statusCode,
    required super.body,
  });

  @override
  String toString() {
    final suffix = body.isEmpty ? '' : ': $body';
    return 'Chat Completions protocol is not supported (HTTP $statusCode)$suffix';
  }
}

/// Explicit OpenAI-compatible Chat Completions implementation.
///
/// Set [stream] to false for a regular JSON response. The default uses the
/// provider's SSE response and reports text chunks through [onContentDelta].
class ChatCompletionsClient implements AiChatClient {
  factory ChatCompletionsClient({
    required String baseUrl,
    required String apiKey,
    required String model,
    String reasoningEffort = 'default',
    bool stream = true,
    http.Client? client,
    Duration timeout = const Duration(minutes: 5),
    int? maxResponseBytes,
  }) {
    final normalizedBaseUrl = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalizedBaseUrl.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must not be empty');
    }
    if (maxResponseBytes != null && maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'must be greater than zero',
      );
    }
    return ChatCompletionsClient._(
      baseUrl: normalizedBaseUrl,
      apiKey: apiKey,
      model: model,
      reasoningEffort: reasoningEffort,
      stream: stream,
      client: client ?? http.Client(),
      timeout: timeout,
      maxResponseBytes: maxResponseBytes,
    );
  }

  ChatCompletionsClient._({
    required this.baseUrl,
    required this._apiKey,
    required this.model,
    required this.reasoningEffort,
    required this.stream,
    required this._client,
    required this.timeout,
    required this.maxResponseBytes,
  });

  final String baseUrl;
  final String _apiKey;
  final String model;
  final String reasoningEffort;
  final bool stream;
  final Duration timeout;
  final int? maxResponseBytes;
  final http.Client _client;

  String get wireApi => 'chat-completions';

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) {
    final request = http.Request(
      'POST',
      Uri.parse('$baseUrl/chat/completions'),
    );
    request.headers['Accept'] = stream
        ? 'text/event-stream, application/json'
        : 'application/json';
    request.headers['Content-Type'] = 'application/json';
    if (_apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $_apiKey';
    }

    final requestBody = <String, Object?>{
      'model': model,
      'messages': _messages(messages),
      'stream': stream,
    };
    if (reasoningEffort != 'default') {
      requestBody['reasoning_effort'] = reasoningEffort;
    }
    if (tools.isNotEmpty) {
      requestBody['tools'] = [for (final tool in tools) tool.toJson()];
    }
    request.body = jsonEncode(requestBody);

    return _send(
      request,
      onContentDelta: onContentDelta,
      cancellation: cancellation,
    );
  }

  Future<AiMessage> _send(
    http.Request request, {
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    final response = await _awaitCancellation(
      _client.send(request).timeout(timeout),
      cancellation,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _awaitCancellation(
        _readLimitedText(
          response.stream,
          maxBytes: _maxProviderErrorBytes,
        ).timeout(timeout),
        cancellation,
      );
      final safeBody = _sanitizeProviderError(body, _apiKey);
      if (_unsupportedStatusCodes.contains(response.statusCode)) {
        throw ChatCompletionsUnsupportedException(
          statusCode: response.statusCode,
          body: safeBody,
        );
      }
      throw ChatCompletionsHttpException(
        statusCode: response.statusCode,
        body: safeBody,
      );
    }

    final contentType = response.headers['content-type'] ?? '';
    if (contentType.toLowerCase().contains('text/event-stream')) {
      return _awaitCancellation(
        _readSse(response, onContentDelta),
        cancellation,
      );
    }
    final body = await _awaitCancellation(
      _readLimitedText(
        response.stream,
        maxBytes: maxResponseBytes,
      ).timeout(timeout),
      cancellation,
    );
    return _readJson(body, onContentDelta);
  }

  Future<T> _awaitCancellation<T>(
    Future<T> operation,
    Future<void>? cancellation,
  ) {
    if (cancellation == null) return operation;
    final cancelled = cancellation.then<T>((_) {
      close();
      throw const AiRequestCancelled();
    });
    return Future.any<T>([operation, cancelled]);
  }

  Future<AiMessage> _readSse(
    http.StreamedResponse response,
    void Function(String delta)? onContentDelta,
  ) async {
    final content = StringBuffer();
    final toolCalls = <int, _ChatToolCallAccumulator>{};
    final dataLines = <String>[];
    String? finishReason;
    Map<String, Object?>? usage;
    var streamDone = false;

    void appendText(String text) {
      if (text.isEmpty) return;
      content.write(text);
      onContentDelta?.call(text);
    }

    void processEvent() {
      if (dataLines.isEmpty) return;
      final data = dataLines.join('\n');
      dataLines.clear();
      if (data.trim().isEmpty) return;
      if (data.trim() == '[DONE]') {
        streamDone = true;
        return;
      }

      final decoded = _decodeJsonObject(data, stream: true);
      final error = decoded['error'];
      if (error != null) {
        throw AiResponseInvalid(
          'Chat Completions stream error: '
          '${_sanitizeProviderError(jsonEncode(error), _apiKey)}',
        );
      }
      final rawUsage = decoded['usage'];
      if (rawUsage is Map) {
        usage = Map<String, Object?>.from(rawUsage);
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return;
      final choice = _firstChoice(choices);
      if (choice == null) return;
      final rawFinishReason = choice['finish_reason'];
      if (rawFinishReason != null) {
        if (rawFinishReason is! String) {
          throw const AiResponseInvalid(
            'Chat Completions finish_reason must be a string or null',
          );
        }
        finishReason = rawFinishReason;
      }

      final delta = choice['delta'];
      if (delta is! Map) return;
      final deltaMap = Map<String, Object?>.from(delta);
      final text = deltaMap['content'];
      if (text is String) appendText(text);
      _mergeStreamToolCalls(toolCalls, deltaMap['tool_calls']);
    }

    await for (final line
        in _limitedBytes(response.stream, maxBytes: maxResponseBytes)
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (line.isEmpty) {
        processEvent();
        if (streamDone) break;
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        var data = line.substring(5);
        if (data.startsWith(' ')) data = data.substring(1);
        dataLines.add(data);
      }
    }
    if (!streamDone) processEvent();

    if (!streamDone && finishReason == null) {
      throw const AiResponseIncomplete();
    }
    final effectiveFinishReason = finishReason == null || finishReason!.isEmpty
        ? toolCalls.isEmpty
              ? 'stop'
              : 'tool_calls'
        : finishReason!;
    final calls = _finishToolCalls(toolCalls);
    if (effectiveFinishReason == 'tool_calls' && calls.isEmpty) {
      throw const AiResponseInvalid(
        'Chat Completions finished with tool_calls but returned no tool calls',
      );
    }
    return AiMessage(
      role: 'assistant',
      content: content.isEmpty ? null : content.toString(),
      toolCalls: calls,
      finishReason: effectiveFinishReason,
      usage: usage,
    );
  }

  AiMessage _readJson(
    String body,
    void Function(String delta)? onContentDelta,
  ) {
    final decoded = _decodeJsonObject(body);
    final error = decoded['error'];
    if (error != null) {
      throw AiResponseInvalid(
        'Chat Completions response error: '
        '${_sanitizeProviderError(jsonEncode(error), _apiKey)}',
      );
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiResponseInvalid(
        'Chat Completions response is missing choices',
      );
    }
    final choice = _firstChoice(choices);
    if (choice == null) {
      throw const AiResponseInvalid(
        'Chat Completions response contains no valid choice',
      );
    }
    final message = choice['message'];
    if (message is! Map) {
      throw const AiResponseInvalid(
        'Chat Completions response is missing message',
      );
    }
    final messageMap = Map<String, Object?>.from(message);
    final content = _readContent(messageMap['content']);
    final calls = _readToolCalls(messageMap['tool_calls']);
    final rawFinishReason = choice['finish_reason'];
    if (rawFinishReason != null && rawFinishReason is! String) {
      throw const AiResponseInvalid(
        'Chat Completions finish_reason must be a string or null',
      );
    }
    final finishReason =
        rawFinishReason as String? ?? (calls.isEmpty ? 'stop' : 'tool_calls');
    if (finishReason == 'tool_calls' && calls.isEmpty) {
      throw const AiResponseInvalid(
        'Chat Completions finished with tool_calls but returned no tool calls',
      );
    }
    if (content != null && content.isNotEmpty) {
      onContentDelta?.call(content);
    }
    final role = messageMap['role'];
    return AiMessage(
      role: role is String && role.isNotEmpty ? role : 'assistant',
      content: content,
      toolCalls: calls,
      finishReason: finishReason,
      usage: _readUsage(decoded['usage']),
    );
  }

  static List<Map<String, Object?>> _messages(List<AiMessage> messages) {
    return [for (final message in messages) _message(message)];
  }

  static Map<String, Object?> _message(AiMessage message) {
    final result = <String, Object?>{'role': message.role};
    if (message.name != null) result['name'] = message.name;

    if (message.responsesOutputItems.isNotEmpty) {
      throw const AiResponseInvalid(
        'Chat Completions cannot send Responses output items as history',
      );
    }

    if (message.role == 'tool') {
      final callId = message.toolCallId;
      if (callId == null || callId.isEmpty) {
        throw const AiResponseInvalid(
          'Chat Completions tool result is missing tool_call_id',
        );
      }
      result['tool_call_id'] = callId;
      result['content'] = message.content ?? '';
      return result;
    }

    final content = _requestContent(message);
    if (content != null) result['content'] = content;
    if (message.toolCalls.isNotEmpty) {
      result['tool_calls'] = [
        for (final call in message.toolCalls) _requestToolCall(call),
      ];
    }
    return result;
  }

  static Object? _requestContent(AiMessage message) {
    if (message.attachments.isEmpty) return message.content;
    final parts = <Map<String, Object?>>[];
    final text = message.content;
    if (text != null && text.isNotEmpty) {
      parts.add({'type': 'text', 'text': text});
    }
    for (final attachment in message.attachments) {
      if (attachment.isImage) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': attachment.dataUrl},
        });
      } else {
        parts.add({
          'type': 'file',
          'file': {
            'filename': attachment.name,
            'file_data': attachment.dataUrl,
          },
        });
      }
    }
    return parts;
  }

  static Map<String, Object?> _requestToolCall(AiToolCall call) {
    if (call.id.isEmpty) {
      throw const AiResponseInvalid(
        'Chat Completions assistant tool call is missing id',
      );
    }
    return {
      'id': call.id,
      'type': 'function',
      'function': {
        'name': providerToolName(call.name),
        'arguments': call.arguments,
      },
    };
  }

  static List<AiToolCall> _readToolCalls(Object? rawValue) {
    if (rawValue == null) return const [];
    if (rawValue is! List) {
      throw const AiResponseInvalid(
        'Chat Completions tool_calls must be an array',
      );
    }
    final calls = <AiToolCall>[];
    for (final rawCall in rawValue) {
      if (rawCall is! Map) {
        throw const AiResponseInvalid('Chat Completions tool call is invalid');
      }
      final call = Map<String, Object?>.from(rawCall);
      final id = call['id'];
      final function = call['function'];
      if (id is! String || id.isEmpty || function is! Map) {
        throw const AiResponseInvalid(
          'Chat Completions tool call is missing id or function',
        );
      }
      final functionMap = Map<String, Object?>.from(function);
      final name = functionMap['name'];
      final arguments = _toolArguments(functionMap['arguments']);
      if (name is! String || name.isEmpty) {
        throw const AiResponseInvalid(
          'Chat Completions tool call is missing function name',
        );
      }
      calls.add(
        AiToolCall(
          id: id,
          callId: id,
          name: name,
          arguments: arguments.isEmpty ? '{}' : arguments,
        ),
      );
    }
    return calls;
  }

  static String _toolArguments(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is Map) return jsonEncode(value);
    throw const AiResponseInvalid(
      'Chat Completions tool call arguments must be a string',
    );
  }

  static void _mergeStreamToolCalls(
    Map<int, _ChatToolCallAccumulator> calls,
    Object? rawValue,
  ) {
    if (rawValue == null) return;
    if (rawValue is! List) {
      throw const AiResponseInvalid(
        'Chat Completions streamed tool_calls must be an array',
      );
    }
    for (final rawCall in rawValue) {
      if (rawCall is! Map) {
        throw const AiResponseInvalid(
          'Chat Completions streamed tool call is invalid',
        );
      }
      final callMap = Map<String, Object?>.from(rawCall);
      final rawIndex = callMap['index'];
      final index = rawIndex is int ? rawIndex : 0;
      final call = calls.putIfAbsent(index, _ChatToolCallAccumulator.new);

      final id = callMap['id'];
      if (id is String && id.isNotEmpty && call.id == null) {
        call.id = id;
      }
      final function = callMap['function'];
      if (function is! Map) continue;
      final functionMap = Map<String, Object?>.from(function);
      final name = functionMap['name'];
      if (name is String && name.isNotEmpty) {
        call.name.write(name);
      }
      final arguments = functionMap['arguments'];
      if (arguments is String) {
        call.arguments.write(arguments);
      } else if (arguments is Map) {
        call.arguments.write(jsonEncode(arguments));
      } else if (arguments != null) {
        throw const AiResponseInvalid(
          'Chat Completions streamed tool arguments must be a string',
        );
      }
    }
  }

  static List<AiToolCall> _finishToolCalls(
    Map<int, _ChatToolCallAccumulator> calls,
  ) {
    final indexes = calls.keys.toList()..sort();
    return [for (final index in indexes) _finishToolCall(index, calls[index]!)];
  }

  static AiToolCall _finishToolCall(int index, _ChatToolCallAccumulator call) {
    final id = call.id;
    if (id == null || id.isEmpty) {
      throw AiResponseInvalid(
        'Chat Completions streamed tool call $index is missing id',
      );
    }
    final name = call.name.toString();
    if (name.isEmpty) {
      throw AiResponseInvalid(
        'Chat Completions streamed tool call $index is missing function name',
      );
    }
    final arguments = call.arguments.toString();
    return AiToolCall(
      id: id,
      callId: id,
      name: name,
      arguments: arguments.isEmpty ? '{}' : arguments,
    );
  }

  static Map<String, Object?>? _readUsage(Object? value) {
    if (value is! Map) return null;
    return Map<String, Object?>.from(value);
  }

  static String? _readContent(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is! List) {
      throw const AiResponseInvalid(
        'Chat Completions message content is invalid',
      );
    }
    final content = StringBuffer();
    for (final part in value) {
      if (part is Map && part['text'] is String) {
        content.write(part['text']);
      }
    }
    return content.toString();
  }

  static Map<String, Object?>? _firstChoice(List choices) {
    for (final rawChoice in choices) {
      if (rawChoice is! Map) continue;
      final choice = Map<String, Object?>.from(rawChoice);
      final index = choice['index'];
      if (index == null || index == 0) return choice;
    }
    return null;
  }

  static Map<String, Object?> _decodeJsonObject(
    String value, {
    bool stream = false,
  }) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw AiResponseInvalid(
        stream
            ? 'Chat Completions SSE event must be a JSON object'
            : 'Chat Completions response must be a JSON object',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  static Future<String> _readLimitedText(
    Stream<List<int>> stream, {
    int? maxBytes,
  }) async {
    final result = StringBuffer();
    await for (final chunk in _limitedBytes(
      stream,
      maxBytes: maxBytes,
    ).transform(const Utf8Decoder(allowMalformed: true))) {
      result.write(chunk);
    }
    return result.toString();
  }

  static Stream<List<int>> _limitedBytes(
    Stream<List<int>> stream, {
    int? maxBytes,
  }) async* {
    var received = 0;
    await for (final chunk in stream) {
      received += chunk.length;
      if (maxBytes != null && received > maxBytes) {
        throw AiResponseTooLarge(maxBytes);
      }
      yield chunk;
    }
  }

  static String _sanitizeProviderError(String value, String apiKey) {
    var safe = value;
    if (apiKey.isNotEmpty) {
      safe = safe.replaceAll(apiKey, '[REDACTED]');
    }
    safe = safe.replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    return safe.length <= _maxProviderErrorCharacters
        ? safe
        : '${safe.substring(0, _maxProviderErrorCharacters)}...';
  }

  void close() => _client.close();
}

class _ChatToolCallAccumulator {
  String? id;
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
}

const _unsupportedStatusCodes = <int>{404, 405, 415, 501};
