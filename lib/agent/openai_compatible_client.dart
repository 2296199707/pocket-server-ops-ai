import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_protocol.dart';

abstract class AiChatClient {
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  });
}

class AiRequestCancelled implements Exception {
  const AiRequestCancelled();
}

class AiResponseTooLarge implements Exception {
  const AiResponseTooLarge([this.limit]);

  final int? limit;

  @override
  String toString() => limit == null
      ? 'AI response exceeded the configured limit'
      : 'AI response exceeded the $limit byte limit';
}

class AiResponseIncomplete implements Exception {
  const AiResponseIncomplete();

  @override
  String toString() => 'AI streaming response ended before completion';
}

class AiResponseInvalid implements Exception {
  const AiResponseInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ProviderHttpError implements Exception {
  const _ProviderHttpError(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() =>
      'AI provider returned HTTP $statusCode: ${_limitProviderError(body)}';
}

class OpenAiCompatibleClient implements AiChatClient {
  factory OpenAiCompatibleClient({
    required String baseUrl,
    required String apiKey,
    required String model,
    String reasoningEffort = 'default',
    http.Client? client,
    Duration timeout = const Duration(minutes: 5),
    int compactThreshold = 200000,
    int? maxResponseBytes,
  }) {
    if (compactThreshold < 1000) {
      throw ArgumentError.value(
        compactThreshold,
        'compactThreshold',
        'must be at least 1000 tokens',
      );
    }
    return OpenAiCompatibleClient._(
      baseUrl: baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
      apiKey: apiKey,
      model: model,
      reasoningEffort: reasoningEffort,
      timeout: timeout,
      client: client ?? http.Client(),
      compactThreshold: compactThreshold,
      maxResponseBytes: maxResponseBytes,
    );
  }

  OpenAiCompatibleClient._({
    required this.baseUrl,
    required this._apiKey,
    required this.model,
    required this.reasoningEffort,
    required this.timeout,
    required this._client,
    required this.compactThreshold,
    required this.maxResponseBytes,
  });

  final String baseUrl;
  final String _apiKey;
  final String model;
  final String reasoningEffort;
  final Duration timeout;
  final http.Client _client;
  final int compactThreshold;
  final int? maxResponseBytes;

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) {
    // This client deliberately targets the Responses API. A provider that
    // does not expose it must fail visibly instead of silently changing the
    // request protocol and tool/history semantics.
    return _completeResponses(
      messages: messages,
      tools: tools,
      onContentDelta: onContentDelta,
      cancellation: cancellation,
    );
  }

  Future<AiMessage> _completeResponses({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) {
    final request = http.Request('POST', Uri.parse('$baseUrl/responses'));
    request.headers['Accept'] = 'text/event-stream, application/json';
    request.headers['Content-Type'] = 'application/json';
    if (_apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $_apiKey';
    }
    final requestBody = <String, Object?>{
      'model': model,
      'input': _responsesInput(messages),
      'stream': true,
      // Use stateless input-array chaining. This keeps credentials and the
      // transcript on the phone while the provider performs compaction.
      'store': false,
      'context_management': [
        {'type': 'compaction', 'compact_threshold': compactThreshold},
      ],
    };
    if (tools.isNotEmpty) {
      requestBody['tools'] = _responsesTools(tools);
    }
    if (reasoningEffort != 'default') {
      requestBody['reasoning'] = {'effort': reasoningEffort};
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
      throw _ProviderHttpError(
        response.statusCode,
        _redactProviderSecrets(body, _apiKey),
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
    return _readResponsesJson(body, onContentDelta);
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
    final responseToolCalls = <String, _ResponsesToolCallAccumulator>{};
    final responseOutputItems = <Map<String, Object?>>[];
    final content = StringBuffer();
    var responseTerminal = false;
    String? responseStatus;
    String? responseError;
    Map<String, Object?>? responseUsage;
    var streamDone = false;
    final dataLines = <String>[];

    void appendResponseText(String text) {
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
      final decoded = jsonDecode(data);
      if (decoded is! Map) return;
      final decodedMap = Map<String, Object?>.from(decoded);
      if (decodedMap['error'] != null && decodedMap['type'] == 'error') {
        throw StateError(
          'AI provider stream error: ${_limit(_redactProviderSecrets(jsonEncode(decodedMap['error']), _apiKey))}',
        );
      }
      final type = decodedMap['type'];
      if (type is! String) return;
      if (type == 'response.output_text.delta') {
        final delta = decodedMap['delta'];
        if (delta is String) appendResponseText(delta);
      } else if (type == 'response.output_text.done') {
        final text = decodedMap['text'];
        if (content.isEmpty && text is String) appendResponseText(text);
      } else if (type == 'response.function_call_arguments.delta') {
        final key = _responseEventKey(decodedMap);
        final call = responseToolCalls.putIfAbsent(
          key,
          _ResponsesToolCallAccumulator.new,
        );
        final delta = decodedMap['delta'];
        if (delta is String) call.arguments.write(delta);
        if (decodedMap['item_id'] is String) {
          call.id = decodedMap['item_id'] as String;
        }
        if (decodedMap['call_id'] is String) {
          call.callId = decodedMap['call_id'] as String;
        }
      } else if (type == 'response.function_call_arguments.done') {
        final key = _responseEventKey(decodedMap);
        final call = responseToolCalls.putIfAbsent(
          key,
          _ResponsesToolCallAccumulator.new,
        );
        final arguments = decodedMap['arguments'];
        if (arguments is! String) {
          throw const AiResponseInvalid(
            'AI response completed function-call arguments without arguments',
          );
        }
        final itemId = decodedMap['item_id'];
        if (itemId is! String || itemId.isEmpty) {
          throw const AiResponseInvalid(
            'AI function-call completion is missing the real item_id',
          );
        }
        call.id = itemId;
        final callId = decodedMap['call_id'];
        if (callId is String && callId.isNotEmpty) {
          call.callId = callId;
        }
        call.arguments = StringBuffer(arguments);
        call.argumentsComplete = true;
      } else if (type == 'response.output_item.added' ||
          type == 'response.output_item.done') {
        final item = decodedMap['item'];
        _throwIfResponseRefused(item);
        _mergeResponseItem(
          responseToolCalls,
          item,
          completed: type == 'response.output_item.done',
        );
        if (type == 'response.output_item.done') {
          _mergeCompletedResponseItem(responseOutputItems, item);
        }
        if (item is Map) {
          final itemText = _responseItemText(item);
          if (content.isEmpty && itemText.isNotEmpty) {
            appendResponseText(itemText);
          }
        }
      } else if (type == 'response.completed' ||
          type == 'response.incomplete' ||
          type == 'response.failed' ||
          type == 'response.cancelled') {
        responseTerminal = true;
        final rawResponse = decodedMap['response'];
        final responseMap = rawResponse is Map
            ? Map<String, Object?>.from(rawResponse)
            : const <String, Object?>{};
        responseStatus = responseMap['status'] is String
            ? responseMap['status'] as String
            : type == 'response.completed'
            ? 'completed'
            : type.substring('response.'.length);
        responseError = responseMap['error'] is Map
            ? _redactProviderSecrets(jsonEncode(responseMap['error']), _apiKey)
            : decodedMap['error'] is Map
            ? _redactProviderSecrets(jsonEncode(decodedMap['error']), _apiKey)
            : null;
        responseUsage = _responseUsage(responseMap['usage']);
        _throwIfResponseRefused(responseMap['output']);
        final fullText = _responseOutputText(
          responseMap['output'],
          responseMap['output_text'],
        );
        if (content.isEmpty && fullText.isNotEmpty) {
          appendResponseText(fullText);
        }
        _mergeResponseItems(responseToolCalls, responseMap['output']);
        final outputItems = _responseOutputItems(responseMap['output']);
        if (outputItems.isNotEmpty) {
          responseOutputItems
            ..clear()
            ..addAll(outputItems);
        }
      }
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
      if (line.startsWith('data:')) {
        var data = line.substring(5);
        if (data.startsWith(' ')) data = data.substring(1);
        dataLines.add(data);
      }
    }
    if (!streamDone) processEvent();

    if (!responseTerminal) throw const AiResponseIncomplete();
    final status = responseStatus ?? 'completed';
    if (status == 'completed') {
      final calls = _finishResponseToolCalls(responseToolCalls);
      return AiMessage(
        role: 'assistant',
        content: content.toString(),
        toolCalls: calls,
        finishReason: calls.isEmpty ? 'stop' : 'tool_calls',
        responsesOutputItems: List.unmodifiable(responseOutputItems),
        usage: responseUsage,
      );
    }
    if (status == 'incomplete') {
      throw AiResponseIncomplete();
    }
    if (status != 'completed') {
      throw AiResponseInvalid(
        'AI response ended with status $status${responseError == null ? '' : ': $responseError'}',
      );
    }
    throw StateError('unreachable response status: $status');
  }

  AiMessage _readResponsesJson(
    String body,
    void Function(String delta)? onContentDelta,
  ) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('AI response must be an object');
    }
    final decodedMap = Map<String, Object?>.from(decoded);
    final status = decodedMap['status'];
    if (status is! String) throw const AiResponseIncomplete();
    _throwIfResponseRefused(decodedMap['output']);
    final content = _responseOutputText(
      decodedMap['output'],
      decodedMap['output_text'],
    );
    final responseOutputItems = _responseOutputItems(decodedMap['output']);
    final callsByKey = <String, _ResponsesToolCallAccumulator>{};
    _mergeResponseItems(callsByKey, decodedMap['output']);
    if (content.isNotEmpty) onContentDelta?.call(content);
    if (status == 'incomplete') {
      throw const AiResponseIncomplete();
    }
    if (status != 'completed') {
      throw AiResponseInvalid('AI response ended with status $status');
    }
    final calls = _finishResponseToolCalls(callsByKey);
    return AiMessage(
      role: 'assistant',
      content: content,
      toolCalls: calls,
      finishReason: calls.isEmpty ? 'stop' : 'tool_calls',
      responsesOutputItems: responseOutputItems,
      usage: _responseUsage(decodedMap['usage']),
    );
  }

  static List<Map<String, Object?>> _responsesInput(List<AiMessage> messages) {
    final input = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.role == 'tool') {
        final callId = message.toolCallId;
        if (callId == null || callId.isEmpty) {
          throw const AiResponseInvalid(
            'AI tool result is missing the real call_id',
          );
        }
        input.add({
          'type': 'function_call_output',
          'call_id': callId,
          'output': message.content ?? '',
        });
        continue;
      }
      if (message.responsesOutputItems.isNotEmpty) {
        // The Responses API requires the provider's output items to be
        // replayed verbatim. This includes reasoning and compaction items.
        _validateResponsesOutputItems(message.responsesOutputItems);
        input.addAll(message.responsesOutputItems);
        continue;
      }
      final text = message.content;
      final content = <Map<String, Object?>>[];
      if (text != null && text.isNotEmpty) {
        content.add({
          'type': message.role == 'assistant' ? 'output_text' : 'input_text',
          'text': text,
        });
      }
      for (final attachment in message.attachments) {
        if (attachment.isImage) {
          content.add({'type': 'input_image', 'image_url': attachment.dataUrl});
        } else {
          content.add({
            'type': 'input_file',
            'filename': attachment.name,
            'file_data': attachment.dataUrl,
          });
        }
      }
      if (content.isNotEmpty) {
        input.add({'role': message.role, 'content': content});
      }
      for (final call in message.toolCalls) {
        final callId = call.callId;
        if (callId == null || callId.isEmpty) {
          throw const AiResponseInvalid(
            'AI function call history is missing the real call_id',
          );
        }
        input.add({
          'type': 'function_call',
          'call_id': callId,
          'name': providerToolName(call.name),
          'arguments': call.arguments,
        });
      }
    }
    return input;
  }

  static Map<String, Object?>? _responseUsage(Object? value) {
    if (value is! Map) return null;
    return Map<String, Object?>.from(value);
  }

  static List<Map<String, Object?>> _responsesTools(
    List<AiToolDefinition> tools,
  ) {
    return [
      for (final tool in tools)
        {
          'type': 'function',
          'name': tool.providerName,
          'description': tool.description,
          'parameters': tool.parameters,
        },
    ];
  }

  static void _validateResponsesOutputItems(List<Map<String, Object?>> items) {
    for (final item in items) {
      if (item['type'] != 'function_call') continue;
      final callId = item['call_id'];
      if (callId is! String || callId.isEmpty) {
        throw const AiResponseInvalid(
          'AI response history function call is missing the real call_id',
        );
      }
    }
  }

  static String _responseEventKey(Map<String, Object?> event) {
    final itemId = event['item_id'];
    if (itemId is String && itemId.isNotEmpty) return itemId;
    final callId = event['call_id'];
    if (callId is String && callId.isNotEmpty) return callId;
    throw const AiResponseInvalid(
      'AI function-call event is missing the real item_id/call_id',
    );
  }

  static void _mergeResponseItems(
    Map<String, _ResponsesToolCallAccumulator> calls,
    Object? rawItems,
  ) {
    if (rawItems is! List) return;
    for (var index = 0; index < rawItems.length; index++) {
      _mergeResponseItem(
        calls,
        rawItems[index],
        fallbackKey: 'response-item-$index',
        completed: true,
      );
    }
  }

  static void _mergeCompletedResponseItem(
    List<Map<String, Object?>> items,
    Object? rawItem,
  ) {
    if (rawItem is! Map) return;
    final item = Map<String, Object?>.from(rawItem);
    final id = item['id'] is String ? item['id'] as String : null;
    if (id != null) {
      final index = items.indexWhere((value) => value['id'] == id);
      if (index >= 0) {
        items[index] = item;
        return;
      }
    }
    items.add(item);
  }

  static List<Map<String, Object?>> _responseOutputItems(Object? rawItems) {
    if (rawItems is! List) return const [];
    return [
      for (final rawItem in rawItems)
        if (rawItem is Map) Map<String, Object?>.from(rawItem),
    ];
  }

  static void _mergeResponseItem(
    Map<String, _ResponsesToolCallAccumulator> calls,
    Object? rawItem, {
    String? fallbackKey,
    bool completed = false,
  }) {
    if (rawItem is! Map || rawItem['type'] != 'function_call') return;
    final item = Map<String, Object?>.from(rawItem);
    final id = item['id'] is String ? item['id'] as String : null;
    final callId = item['call_id'] is String ? item['call_id'] as String : null;
    final key = id ?? callId ?? fallbackKey ?? 'response-item-${calls.length}';
    final call = calls.putIfAbsent(key, _ResponsesToolCallAccumulator.new);
    if (id != null) call.id = id;
    if (callId != null) call.callId = callId;
    if (item['name'] is String) call.name = item['name'] as String;
    if (item['status'] == 'in_progress') {
      call.inProgress = true;
    } else if (completed || item['status'] == 'completed') {
      call.inProgress = false;
    }
    final arguments = item['arguments'];
    if (arguments is String && arguments.isNotEmpty) {
      call.arguments = StringBuffer(arguments);
      call.argumentsComplete = completed || item['status'] == 'completed';
    } else if (arguments is Map) {
      call.arguments = StringBuffer(jsonEncode(arguments));
      call.argumentsComplete = completed || item['status'] == 'completed';
    } else if (arguments is String && !call.inProgress) {
      call.argumentsComplete = completed || item['status'] == 'completed';
    }
  }

  static List<AiToolCall> _finishResponseToolCalls(
    Map<String, _ResponsesToolCallAccumulator> calls,
  ) {
    if (calls.length > _maxToolCallsPerResponse) {
      throw const FormatException('AI response has too many tool calls');
    }
    final result = <AiToolCall>[];
    for (var index = 0; index < calls.length; index++) {
      final call = calls.values.elementAt(index);
      if (call.name.isEmpty) {
        throw const AiResponseInvalid(
          'AI response finished with a tool call that could not be parsed',
        );
      }
      if (call.callId == null || call.callId!.isEmpty) {
        throw const AiResponseInvalid(
          'AI response function call is missing the real call_id',
        );
      }
      if (call.inProgress || !call.argumentsComplete) {
        throw const AiResponseIncomplete();
      }
      result.add(
        AiToolCall(
          id: call.id ?? call.callId!,
          callId: call.callId,
          name: call.name,
          arguments: call.arguments.toString().isEmpty
              ? '{}'
              : call.arguments.toString(),
        ),
      );
    }
    return result;
  }

  static String _responseOutputText(Object? output, Object? outputText) {
    if (outputText is String && outputText.isNotEmpty) return outputText;
    if (output is! List) return '';
    return output
        .whereType<Map>()
        .where((item) => item['type'] == 'message')
        .map((item) => _content(item['content']))
        .where((text) => text.isNotEmpty)
        .join();
  }

  static String _responseItemText(Map item) {
    if (item['type'] != 'message') return '';
    return _content(item['content']);
  }

  static void _throwIfResponseRefused(Object? output) {
    final items = output is List
        ? output
        : output is Map
        ? [output]
        : const <Object?>[];
    for (final rawItem in items) {
      if (rawItem is! Map || rawItem['type'] != 'message') continue;
      final refusal = rawItem['refusal'];
      if (refusal is String && refusal.isNotEmpty) {
        throw AiResponseInvalid('AI response was refused: ${_limit(refusal)}');
      }
      final parts = rawItem['content'];
      if (parts is! List) continue;
      for (final rawPart in parts) {
        if (rawPart is! Map) continue;
        final partRefusal = rawPart['refusal'];
        if (rawPart['type'] == 'refusal' ||
            (partRefusal is String && partRefusal.isNotEmpty)) {
          throw AiResponseInvalid(
            'AI response was refused: ${_limit(partRefusal is String ? partRefusal : 'provider refusal')}',
          );
        }
      }
    }
  }

  static String _content(Object? value) {
    if (value is String) return value;
    if (value is List) {
      return value
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    return '';
  }

  static String _limit(String value) {
    return value.length <= 2_000 ? value : '${value.substring(0, 2_000)}...';
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

  void close() => _client.close();
}

class _ResponsesToolCallAccumulator {
  String? id;
  String? callId;
  String name = '';
  StringBuffer arguments = StringBuffer();
  bool argumentsComplete = false;
  bool inProgress = false;
}

const _maxToolCallsPerResponse = 128;
const _maxProviderErrorBytes = 64 * 1024;

String _redactProviderSecrets(String value, String apiKey) {
  if (apiKey.isEmpty) return value;
  return value.replaceAll(apiKey, '[REDACTED]');
}

String _limitProviderError(String value) {
  return value.length <= 2_000 ? value : '${value.substring(0, 2_000)}...';
}
