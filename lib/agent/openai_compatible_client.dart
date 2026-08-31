import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

abstract class AiCompactionClient {
  /// Compacts history using the local Codex strategy.
  ///
  /// The selected Responses provider receives a normal `/responses` request
  /// with the Codex compaction prompt appended to the input. The returned
  /// assistant text is the durable summary; no provider-specific opaque
  /// compaction item is required.
  Future<String> compact({
    required List<AiMessage> messages,
    required String instructions,
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
  const AiResponseIncomplete({
    this.reason,
    this.retryable = false,
    this.stream = false,
  });

  final String? reason;
  final bool retryable;

  /// Whether this error came from an already-established response stream.
  /// Request and stream retries use separate Codex budgets.
  final bool stream;

  @override
  String toString() => reason == null || reason!.isEmpty
      ? 'AI response ended before completion'
      : 'AI response ended incomplete: $reason';
}

/// The transport ended before a terminal stream event arrived.
///
/// This is different from a provider returning a completed response with an
/// `incomplete` status. The former is safe to retry because no tool call has
/// been handed to [AgentLoop]; the latter is a model/protocol result and must
/// remain visible to the caller.
class AiResponseStreamDisconnected extends AiResponseIncomplete {
  const AiResponseStreamDisconnected([String? reason])
    : super(reason: reason, retryable: true, stream: true);

  @override
  String toString() => reason == null || reason!.isEmpty
      ? 'AI streaming connection ended before completion'
      : 'AI response stream ended incomplete: $reason';
}

/// The HTTP request did not produce a response at all. Codex gives this
/// transport phase its own connection-retry budget, separate from retries of
/// a response stream that has already completed the HTTP handshake.
class AiConnectionFailure implements Exception {
  const AiConnectionFailure(this.cause);

  final Object cause;

  @override
  String toString() => 'AI connection failed: $cause';
}

/// A provider sent a structured error from inside an otherwise valid
/// Responses stream. Codex classifies the error before deciding whether the
/// same logical turn can be retried.
class AiResponseProviderError implements Exception {
  const AiResponseProviderError({
    required this.message,
    this.code,
    required this.retryable,
    this.stream = false,
  });

  final String message;
  final String? code;
  final bool retryable;
  final bool stream;

  @override
  String toString() => message;
}

class AiResponseInvalid implements Exception {
  const AiResponseInvalid(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Retry settings for one model request. A retry always reuses the same
/// logical Agent turn; it does not retry tools or other side effects.
class AiRetryPolicy {
  const AiRetryPolicy({
    // Codex defaults: request_max_retries=4 and stream_max_retries=5.
    // [maxRetries] is retained as a source-compatible override for older
    // callers; when supplied it applies to both finite budgets.
    int? maxRetries,
    this.requestMaxRetries = 4,
    this.streamMaxRetries = 5,
    this.initialDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 5),
    this.unboundedConnectionRetries = false,
    this.connectionInitialDelay = const Duration(seconds: 5),
    this.connectionMaxDelay = const Duration(seconds: 60),
    this.connectionMaxRetries = 5,
  }) : _legacyMaxRetries = maxRetries;

  final int requestMaxRetries;
  final int streamMaxRetries;
  final int? _legacyMaxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final bool unboundedConnectionRetries;
  final Duration connectionInitialDelay;
  final Duration connectionMaxDelay;
  final int connectionMaxRetries;

  int get effectiveRequestMaxRetries => _legacyMaxRetries ?? requestMaxRetries;

  int get effectiveStreamMaxRetries => _legacyMaxRetries ?? streamMaxRetries;

  /// The legacy flag selects a separate connection budget; it never means
  /// that a task may wait forever. A negative value is treated as disabled.
  int get effectiveConnectionMaxRetries =>
      connectionMaxRetries < 0 ? 0 : connectionMaxRetries;

  /// Backwards-compatible alias. New callers should choose the request or
  /// stream budget explicitly.
  @Deprecated('Use requestMaxRetries or streamMaxRetries')
  int get maxRetries => effectiveStreamMaxRetries;

  Duration delayFor(int retryNumber) {
    if (retryNumber <= 0 || initialDelay <= Duration.zero) {
      return Duration.zero;
    }
    var delay = initialDelay;
    for (var index = 1; index < retryNumber; index++) {
      final doubled = delay.inMicroseconds * 2;
      if (doubled >= maxDelay.inMicroseconds) return maxDelay;
      delay = Duration(microseconds: doubled);
    }
    return delay > maxDelay ? maxDelay : delay;
  }

  Duration connectionDelayFor(int retryNumber) {
    if (retryNumber <= 0 || connectionInitialDelay <= Duration.zero) {
      return Duration.zero;
    }
    var delay = connectionInitialDelay;
    for (var index = 1; index < retryNumber; index++) {
      final doubled = delay.inMicroseconds * 2;
      if (doubled >= connectionMaxDelay.inMicroseconds) {
        return connectionMaxDelay;
      }
      delay = Duration(microseconds: doubled);
    }
    return delay > connectionMaxDelay ? connectionMaxDelay : delay;
  }
}

class AiRetryEvent {
  const AiRetryEvent({
    required this.attempt,
    required this.maxRetries,
    required this.delay,
    required this.error,
    this.unbounded = false,
  });

  final int attempt;
  final int maxRetries;
  final Duration delay;
  final Object error;

  /// True when the legacy separate connection budget was selected. Despite the
  /// historical name, that budget is finite and [maxRetries] contains its cap.
  final bool unbounded;
}

typedef AiRetryListener = FutureOr<void> Function(AiRetryEvent event);

/// Matches the narrow retry boundary used by Codex's sampling stream loop.
/// Context, authentication, protocol, and explicit overload errors are not
/// treated as short-lived network failures.
bool isRetryableAiError(Object error) {
  if (error is AiResponseProviderError) return error.retryable;
  if (error is AiResponseIncomplete) return error.retryable;
  if (error is FormatException) return true;
  if (error is AiRequestCancelled ||
      error is AiResponseTooLarge ||
      error is AiResponseInvalid) {
    return false;
  }
  if (error is AiConnectionFailure ||
      error is AiResponseStreamDisconnected ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is IOException) {
    return true;
  }
  if (error is AiProviderHttpException) {
    // Explicitly unsupported/client/auth responses are configuration errors.
    // 408/425/429 and 5xx responses are transient categories in Codex's
    // retryable error model. Unsupported endpoint subclasses are excluded
    // before this branch so protocol mistakes are still visible immediately.
    if (error.statusCode == 408 ||
        error.statusCode == 425 ||
        error.statusCode == 429) {
      final body = error.body.toLowerCase();
      if (body.contains('quota') || body.contains('usage_limit')) {
        return false;
      }
      return true;
    }
    if (error.statusCode < 500 || error.statusCode >= 600) return false;
    // Codex retries HTTP 5xx responses at the request layer. A structured
    // overload response is terminal only after the provider has already
    // started a stream (see isRetryableAiProviderCode(..., stream: true)).
    return true;
  }
  return false;
}

/// Transport failures before an HTTP response is available use the separate
/// connection retry budget in Codex. A stream that already completed the HTTP
/// handshake uses finite stream retries instead.
bool isAiConnectionError(Object error) {
  return error is AiConnectionFailure;
}

bool isAiStreamRetryError(Object error) {
  if (error is AiResponseIncomplete) return error.stream;
  if (error is AiResponseProviderError) return error.stream;
  return false;
}

/// Extracts the common error code shape used by Responses-compatible
/// providers. The provider may return either an error object or a nested
/// `response.error` object.
String? aiProviderErrorCode(Object? value) {
  if (value is! Map) return null;
  for (final key in ['code', 'error_code', 'type']) {
    final candidate = value[key];
    if (candidate is String && candidate.trim().isNotEmpty) {
      return candidate.trim();
    }
  }
  return aiProviderErrorCode(value['error']);
}

String aiProviderErrorMessage(Object? value) {
  if (value is Map) {
    final message = value['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
    final nested = value['error'];
    if (nested != null) return aiProviderErrorMessage(nested);
  }
  return value == null ? 'AI provider stream error' : '$value';
}

bool isRetryableAiProviderCode(String? code, {required bool stream}) {
  final normalized = code?.trim().toLowerCase().replaceAll('-', '_');
  if (normalized == null || normalized.isEmpty) return stream;
  if (normalized.contains('context') ||
      normalized.contains('quota') ||
      normalized.contains('usage_limit') ||
      normalized.contains('invalid') ||
      normalized.contains('unauthor') ||
      normalized.contains('permission') ||
      normalized.contains('overload') ||
      normalized.contains('content_filter')) {
    return false;
  }
  if (normalized.contains('rate_limit') ||
      normalized.contains('server_error') ||
      normalized.contains('internal') ||
      normalized.contains('timeout') ||
      normalized.contains('connection') ||
      normalized.contains('network') ||
      normalized.contains('reset') ||
      normalized.contains('temporar') ||
      normalized.contains('unavailable')) {
    return true;
  }
  return stream;
}

Future<void> waitForAiRetry(Duration delay, Future<void>? cancellation) async {
  if (delay <= Duration.zero) {
    if (cancellation != null) {
      await Future.any<void>([
        Future<void>.value(),
        cancellation.then<void>((_) => throw const AiRequestCancelled()),
      ]);
    }
    return;
  }
  final timer = Future<void>.delayed(delay);
  if (cancellation == null) {
    await timer;
    return;
  }
  await Future.any<void>([
    timer,
    cancellation.then<void>((_) => throw const AiRequestCancelled()),
  ]);
}

class _ProviderHttpError extends AiProviderHttpException {
  const _ProviderHttpError(int statusCode, String body)
    : super(protocol: 'Responses', statusCode: statusCode, body: body);

  @override
  String toString() =>
      'AI provider returned HTTP $statusCode: ${_limitProviderError(body)}';
}

class OpenAiCompatibleClient implements AiChatClient, AiCompactionClient {
  factory OpenAiCompatibleClient({
    required String baseUrl,
    required String apiKey,
    required String model,
    String reasoningEffort = 'default',
    http.Client? client,
    // Match Codex's configurable five-minute stream idle timeout. This is an
    // inactivity limit for the provider transport, not a wall-clock limit for
    // a remote command running behind a completed tool call.
    Duration timeout = const Duration(minutes: 5),
    int? maxResponseBytes,
    List<String>? inputModalities,
    int? autoCompactTokenLimit,
    AiRetryPolicy retryPolicy = const AiRetryPolicy(),
    AiRetryListener? onRetry,
  }) {
    return OpenAiCompatibleClient._(
      baseUrl: baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
      apiKey: apiKey,
      model: model,
      reasoningEffort: reasoningEffort,
      timeout: timeout,
      client: client ?? http.Client(),
      maxResponseBytes: maxResponseBytes,
      inputModalities: inputModalities,
      autoCompactTokenLimit: autoCompactTokenLimit,
      retryPolicy: retryPolicy,
      onRetry: onRetry,
    );
  }

  OpenAiCompatibleClient._({
    required this.baseUrl,
    required this._apiKey,
    required this.model,
    required this.reasoningEffort,
    required this.timeout,
    required this._client,
    required this.maxResponseBytes,
    required this.inputModalities,
    required this.autoCompactTokenLimit,
    required this.retryPolicy,
    required this.onRetry,
  });

  final String baseUrl;
  final String _apiKey;
  final String model;
  final String reasoningEffort;
  final Duration timeout;
  final http.Client _client;
  final int? maxResponseBytes;
  final List<String>? inputModalities;
  final int? autoCompactTokenLimit;
  final AiRetryPolicy retryPolicy;
  final AiRetryListener? onRetry;

  /// Estimates the model-visible items appended after the latest assistant
  /// output for diagnostics and focused tests. The production automatic
  /// compaction trigger is sent as `context_management` and does not use this
  /// estimate.
  ///
  /// This is intentionally the same coarse JSON-byte heuristic used by
  /// Codex's history estimator: serialized item bytes divided by four,
  /// rounded up. Provider-reported usage remains authoritative when available.
  static int estimateResponsesTailTokenCount(
    List<AiMessage> messages, {
    List<String>? inputModalities,
  }) {
    var lastAssistantIndex = -1;
    for (var index = 0; index < messages.length; index++) {
      if (messages[index].role == 'assistant') lastAssistantIndex = index;
    }
    if (lastAssistantIndex < 0 || lastAssistantIndex + 1 >= messages.length) {
      return 0;
    }

    final supportsImages = _supportsModality(inputModalities, 'image');
    final supportsAudio = _supportsModality(inputModalities, 'audio');
    var total = 0;
    for (final message in messages.skip(lastAssistantIndex + 1)) {
      for (final item in _responsesInputItemsForMessage(
        message,
        supportsImages: supportsImages,
        supportsAudio: supportsAudio,
      )) {
        final bytes = utf8.encode(jsonEncode(item)).length;
        total += (bytes + 3) ~/ 4;
      }
    }
    return total;
  }

  /// Identifies the synthetic user item written by Codex local compaction.
  static bool isCodexCompactionSummary(String? content) {
    return content != null && content.startsWith(_codexSummaryPrefix);
  }

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
      allowUnboundedConnectionRetries:
          retryPolicy.unboundedConnectionRetries,
    );
  }

  Future<AiMessage> _completeResponses({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    String? instructions,
    bool useContextManagement = true,
    bool allowUnboundedConnectionRetries = false,
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
      'input': _responsesInput(messages, inputModalities: inputModalities),
      'stream': true,
      // Use stateless input-array chaining. This keeps credentials and the
      // transcript on the phone while the provider processes the request.
      'store': false,
    };
    final compactThreshold = autoCompactTokenLimit;
    if (useContextManagement &&
        compactThreshold != null &&
        compactThreshold > 0) {
      requestBody['context_management'] = [
        {'type': 'compaction', 'compact_threshold': compactThreshold},
      ];
    }
    if (instructions != null && instructions.isNotEmpty) {
      requestBody['instructions'] = instructions;
    }
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
      allowUnboundedConnectionRetries: allowUnboundedConnectionRetries,
    );
  }

  @override
  Future<String> compact({
    required List<AiMessage> messages,
    required String instructions,
    Future<void>? cancellation,
  }) async {
    // Codex uses this ordinary Responses path when the selected provider does
    // not advertise remote compaction. Keep the system prompt separate and
    // make the synthetic compaction request the final user input.
    final response = await _completeResponses(
      messages: [
        for (final message in messages)
          if (message.role != 'system') message,
        AiMessage.user(_codexSummarizationPrompt),
      ],
      tools: const [],
      instructions: instructions,
      useContextManagement: false,
      allowUnboundedConnectionRetries: false,
      cancellation: cancellation,
    );
    final summary = response.content?.trim() ?? '';
    if (summary.isEmpty) {
      throw const AiResponseInvalid('Responses 本地压缩没有返回摘要文本');
    }
    return '$_codexSummaryPrefix\n$summary';
  }

  Future<AiMessage> _send(
    http.Request request, {
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
    bool allowUnboundedConnectionRetries = false,
  }) async {
    var requestRetries = 0;
    var streamRetries = 0;
    var connectionRetries = 0;
    var requestSent = false;
    while (true) {
      final attemptRequest = requestSent ? _retryRequest(request) : request;
      requestSent = true;
      try {
        return await _sendOnce(
          attemptRequest,
          onContentDelta: onContentDelta,
          cancellation: cancellation,
        );
      } catch (error) {
        if (allowUnboundedConnectionRetries &&
            retryPolicy.unboundedConnectionRetries &&
            isAiConnectionError(error)) {
          final maxConnectionRetries =
              retryPolicy.effectiveConnectionMaxRetries;
          if (connectionRetries >= maxConnectionRetries) {
            rethrow;
          }
          connectionRetries++;
          final delay = retryPolicy.connectionDelayFor(connectionRetries);
          try {
            await onRetry?.call(
              AiRetryEvent(
                attempt: connectionRetries,
                maxRetries: maxConnectionRetries,
                delay: delay,
                error: error,
                unbounded: true,
              ),
            );
          } catch (_) {
            // Retry telemetry must not turn a recoverable network failure into
            // a task failure.
          }
          await waitForAiRetry(delay, cancellation);
          continue;
        }
        final isStreamError = isAiStreamRetryError(error);
        final maxRetries = isStreamError
            ? retryPolicy.effectiveStreamMaxRetries
            : retryPolicy.effectiveRequestMaxRetries;
        final retries = isStreamError ? streamRetries : requestRetries;
        if (retries >= maxRetries || !isRetryableAiError(error)) {
          rethrow;
        }
        final attempt = retries + 1;
        if (isStreamError) {
          streamRetries = attempt;
        } else {
          requestRetries = attempt;
        }
        final delay = retryPolicy.delayFor(attempt);
        try {
          await onRetry?.call(
            AiRetryEvent(
              attempt: attempt,
              maxRetries: maxRetries,
              delay: delay,
              error: error,
            ),
          );
        } catch (_) {
          // Retry telemetry must not turn a recoverable provider failure into
          // a task failure.
        }
        await waitForAiRetry(delay, cancellation);
      }
    }
  }

  Future<T> _withTimeout<T>(Future<T> operation) {
    final limit = timeout;
    return limit <= Duration.zero ? operation : operation.timeout(limit);
  }

  Stream<T> _withStreamTimeout<T>(Stream<T> stream) {
    final limit = timeout;
    return limit <= Duration.zero ? stream : stream.timeout(limit);
  }

  Future<AiMessage> _sendOnce(
    http.Request request, {
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    // Do not publish deltas until this attempt has reached a terminal
    // response. If the stream breaks after half a sentence, Codex retries the
    // same logical turn from durable history; buffering the attempt prevents
    // the failed half from being shown a second time after the retry.
    final attemptDeltas = onContentDelta == null ? null : <String>[];
    final attemptDelta = attemptDeltas?.add;
    late http.StreamedResponse response;
    try {
      response = await _awaitCancellation(
        _withTimeout(_client.send(request)),
        cancellation,
      );
    } on AiRequestCancelled {
      rethrow;
    } on TimeoutException catch (error) {
      // A timeout while waiting for package:http to establish the response
      // is the same transport phase as Codex's ConnectionFailed. Keep it on
      // the separate connection-retry budget instead of exhausting the
      // finite stream retry budget immediately.
      throw AiConnectionFailure(error);
    } on Object catch (error) {
      if (error is http.ClientException || error is IOException) {
        throw AiConnectionFailure(error);
      }
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _awaitCancellation(
        _withTimeout(
          _readLimitedText(response.stream, maxBytes: _maxProviderErrorBytes),
        ),
        cancellation,
      );
      throw _ProviderHttpError(
        response.statusCode,
        _redactProviderSecrets(body, _apiKey),
      );
    }
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.toLowerCase().contains('text/event-stream')) {
      late AiMessage result;
      try {
        result = await _awaitCancellation(
          _readSse(response, attemptDelta),
          cancellation,
        );
      } on AiRequestCancelled {
        rethrow;
      } on Object catch (error) {
        if (error is TimeoutException ||
            error is http.ClientException ||
            error is IOException) {
          throw AiResponseStreamDisconnected('$error');
        }
        rethrow;
      }
      _publishAttemptDeltas(attemptDeltas, onContentDelta);
      return result;
    }
    late String body;
    try {
      body = await _awaitCancellation(
        _withTimeout(
          _readLimitedText(response.stream, maxBytes: maxResponseBytes),
        ),
        cancellation,
      );
    } on AiRequestCancelled {
      rethrow;
    } on Object catch (error) {
      if (error is TimeoutException ||
          error is http.ClientException ||
          error is IOException) {
        throw AiResponseStreamDisconnected('$error');
      }
      rethrow;
    }
    final result = _readResponsesJson(body, attemptDelta);
    _publishAttemptDeltas(attemptDeltas, onContentDelta);
    return result;
  }

  static void _publishAttemptDeltas(
    List<String>? deltas,
    void Function(String delta)? onContentDelta,
  ) {
    if (deltas == null || onContentDelta == null) return;
    for (final delta in deltas) {
      onContentDelta(delta);
    }
  }

  static http.Request _retryRequest(http.Request request) {
    final retry = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return retry;
  }

  Future<T> _awaitCancellation<T>(
    Future<T> operation,
    Future<void>? cancellation,
  ) {
    if (cancellation == null) return operation;
    final cancelled = cancellation.then<T>((_) {
      // package:http has no request-level abort primitive. Do not close the
      // whole client here: callers may reuse it for another turn/request.
      // The request future remains observed by Future.any, while the logical
      // Agent turn stops immediately and cancellation is never retried.
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
    var completedEvent = false;
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
      Object? decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        // Codex ignores an invalid event and continues reading the stream so a
        // later valid terminal event can still finish the request.
        return;
      }
      if (decoded is! Map) return;
      final decodedMap = Map<String, Object?>.from(decoded);
      if (decodedMap['error'] != null && decodedMap['type'] == 'error') {
        final errorValue = decodedMap['error'];
        final code =
            aiProviderErrorCode(errorValue) ?? aiProviderErrorCode(decodedMap);
        final message = _limit(
          _redactProviderSecrets(
            'AI provider stream error: ${aiProviderErrorMessage(errorValue)}',
            _apiKey,
          ),
        );
        throw AiResponseProviderError(
          message: message,
          code: code,
          retryable: isRetryableAiProviderCode(code, stream: true),
          stream: true,
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
        if (rawResponse is! Map) {
          throw AiResponseInvalid(
            'AI response terminal event $type is missing response',
          );
        }
        final responseMap = Map<String, Object?>.from(rawResponse);
        final errorValue = responseMap['error'] ?? decodedMap['error'];
        if (type == 'response.failed') {
          if (errorValue == null) {
            throw const AiResponseInvalid(
              'AI response.failed is missing provider error details',
            );
          }
          final code =
              aiProviderErrorCode(errorValue) ??
              aiProviderErrorCode(responseMap);
          final message = _limit(
            _redactProviderSecrets(
              'AI response failed: ${aiProviderErrorMessage(errorValue)}',
              _apiKey,
            ),
          );
          throw AiResponseProviderError(
            message: message,
            code: code,
            retryable: isRetryableAiProviderCode(code, stream: false),
            stream: true,
          );
        }
        if (type == 'response.incomplete') {
          final details =
              responseMap['incomplete_details'] ??
              decodedMap['incomplete_details'];
          final reason = _responseDetailText(details);
          final code =
              aiProviderErrorCode(errorValue) ??
              aiProviderErrorCode(responseMap) ??
              reason;
          throw AiResponseIncomplete(
            reason: reason,
            retryable: isRetryableAiProviderCode(code, stream: false),
            stream: true,
          );
        }
        if (type == 'response.completed') {
          final responseId = responseMap['id'];
          if (responseId is! String || responseId.isEmpty) {
            throw const AiResponseInvalid(
              'AI response.completed is missing response.id',
            );
          }
        }
        responseStatus = responseMap['status'] is String
            ? responseMap['status'] as String
            : type == 'response.completed'
            ? 'completed'
            : type.substring('response.'.length);
        responseError = errorValue == null
            ? null
            : _redactProviderSecrets(
                aiProviderErrorMessage(errorValue),
                _apiKey,
              );
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
        if (type == 'response.completed') {
          // A completed Responses event is the protocol terminal event. Some
          // compatible providers keep the HTTP connection open afterwards;
          // waiting for [DONE] or socket close makes the task look stuck.
          completedEvent = true;
        }
      }
    }

    final lines = _withStreamTimeout(
      _limitedBytes(response.stream, maxBytes: maxResponseBytes)
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()),
    );
    await for (final line in lines) {
      if (line.isEmpty) {
        processEvent();
        if (streamDone || completedEvent) break;
        continue;
      }
      if (line.startsWith('data:')) {
        var data = line.substring(5);
        if (data.startsWith(' ')) data = data.substring(1);
        dataLines.add(data);
      }
    }
    if (!streamDone && !completedEvent) processEvent();

    if (!responseTerminal) throw const AiResponseStreamDisconnected();
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
      final details = decodedMap['incomplete_details'];
      final errorValue = decodedMap['error'];
      final reason = _responseDetailText(details);
      final code =
          aiProviderErrorCode(errorValue) ??
          aiProviderErrorCode(decodedMap) ??
          reason;
      throw AiResponseIncomplete(
        reason: reason,
        retryable: isRetryableAiProviderCode(code, stream: false),
      );
    }
    if (status == 'failed') {
      final errorValue = decodedMap['error'];
      if (errorValue == null) {
        throw const AiResponseInvalid(
          'AI response.failed is missing provider error details',
        );
      }
      final code =
          aiProviderErrorCode(errorValue) ?? aiProviderErrorCode(decodedMap);
      final message = _limit(
        _redactProviderSecrets(
          'AI response failed: ${aiProviderErrorMessage(errorValue)}',
          _apiKey,
        ),
      );
      throw AiResponseProviderError(
        message: message,
        code: code,
        retryable: isRetryableAiProviderCode(code, stream: false),
      );
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

  static List<Map<String, Object?>> _responsesInput(
    List<AiMessage> messages, {
    List<String>? inputModalities,
  }) {
    final input = <Map<String, Object?>>[];
    final supportsImages = _supportsModality(inputModalities, 'image');
    final supportsAudio = _supportsModality(inputModalities, 'audio');
    for (final message in messages) {
      input.addAll(
        _responsesInputItemsForMessage(
          message,
          supportsImages: supportsImages,
          supportsAudio: supportsAudio,
        ),
      );
    }
    return _normalizeResponsesInput(input);
  }

  static List<Map<String, Object?>> _responsesInputItemsForMessage(
    AiMessage message, {
    required bool supportsImages,
    required bool supportsAudio,
  }) {
    if (message.role == 'tool') {
      final callId = message.toolCallId;
      if (callId == null || callId.isEmpty) {
        throw const AiResponseInvalid(
          'AI tool result is missing the real call_id',
        );
      }
      return [
        {
          'type': 'function_call_output',
          'call_id': callId,
          'output': message.content ?? '',
        },
      ];
    }
    if (message.responsesOutputItems.isNotEmpty) {
      // The Responses API requires the provider's output items to be
      // replayed verbatim. This includes reasoning and compaction items.
      _validateResponsesOutputItems(message.responsesOutputItems);
      return List<Map<String, Object?>>.from(message.responsesOutputItems);
    }
    final input = <Map<String, Object?>>[];
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
        if (supportsImages) {
          content.add({'type': 'input_image', 'image_url': attachment.dataUrl});
        } else {
          content.add({
            'type': 'input_text',
            'text': '[Image omitted: this model does not support image input.]',
          });
        }
      } else if (attachment.mimeType.toLowerCase().startsWith('audio/') &&
          !supportsAudio) {
        content.add({
          'type': 'input_text',
          'text': '[Audio omitted: this model does not support audio input.]',
        });
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
    return input;
  }

  static bool _supportsModality(List<String>? modalities, String modality) {
    if (modalities == null || modalities.isEmpty) return true;
    return modalities.any((value) => value.toLowerCase() == modality);
  }

  /// Apply the small set of history invariants used by Codex before a
  /// stateless Responses request. Provider-owned output items, including
  /// compaction and reasoning items, remain unchanged; only missing or
  /// impossible function-call pairings are repaired.
  static List<Map<String, Object?>> _normalizeResponsesInput(
    List<Map<String, Object?>> input,
  ) {
    final functionCallIds = <String>{};
    final functionOutputIds = <String>{};
    for (final item in input) {
      final type = item['type'];
      final callId = item['call_id'];
      if (callId is! String || callId.isEmpty) continue;
      if (type == 'function_call') {
        functionCallIds.add(callId);
      } else if (type == 'function_call_output') {
        functionOutputIds.add(callId);
      }
    }

    final normalized = <Map<String, Object?>>[];
    for (final item in input) {
      final type = item['type'];
      final callId = item['call_id'];
      if (type == 'function_call_output' &&
          callId is String &&
          callId.isNotEmpty &&
          !functionCallIds.contains(callId)) {
        // A response output left behind after its call was compacted or
        // rolled back cannot be sent as a standalone paired output.
        continue;
      }
      normalized.add(item);
      if (type == 'function_call' &&
          callId is String &&
          callId.isNotEmpty &&
          !functionOutputIds.contains(callId)) {
        normalized.add({
          'type': 'function_call_output',
          'call_id': callId,
          'output': 'aborted',
        });
      }
    }
    return normalized;
  }

  static Map<String, Object?>? _responseUsage(Object? value) {
    if (value is! Map) return null;
    return Map<String, Object?>.from(value);
  }

  static String? _responseDetailText(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is Map) {
      for (final key in ['reason', 'code', 'message']) {
        final item = value[key];
        if (item is String && item.trim().isNotEmpty) return item.trim();
      }
    }
    return null;
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

// Kept in sync with the fixed Codex source snapshot used by the project
// audit: codex-rs/prompts/templates/compact/{prompt,summary_prefix}.md.
const _codexSummarizationPrompt =
    'You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff '
    'summary for another LLM that will resume the task.\n\n'
    'Include:\n'
    '- Current progress and key decisions made\n'
    '- Important context, constraints, or user preferences\n'
    '- What remains to be done (clear next steps)\n'
    '- Any critical data, examples, or references needed to continue\n\n'
    'Be concise, structured, and focused on helping the next LLM seamlessly '
    'continue the work.';

const _codexSummaryPrefix =
    'Another language model started to solve this problem and produced a '
    'summary of its thinking process. You also have access to the state of '
    'the tools that were used by that language model. Use this to build on '
    'the work that has already been done and avoid duplicating work. Here is '
    'the summary produced by the other language model, use the information '
    'in this summary to assist with your own analysis:';

class _ResponsesToolCallAccumulator {
  String? id;
  String? callId;
  String name = '';
  StringBuffer arguments = StringBuffer();
  bool argumentsComplete = false;
  bool inProgress = false;
}

const _maxProviderErrorBytes = 64 * 1024;

String _redactProviderSecrets(String value, String apiKey) {
  if (apiKey.isEmpty) return value;
  return value.replaceAll(apiKey, '[REDACTED]');
}

String _limitProviderError(String value) {
  return value.length <= 2_000 ? value : '${value.substring(0, 2_000)}...';
}
