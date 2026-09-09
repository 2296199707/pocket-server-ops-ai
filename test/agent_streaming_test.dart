import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_agent/agent/agent_loop.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/ai_client_factory.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

void main() {
  for (final wireApi in ['responses', 'chat-completions']) {
    test('$wireApi displays text before the terminal event', () async {
      final stream = StreamController<List<int>>();
      addTearDown(() => unawaited(stream.close()));
      final client = _client(wireApi, (_) async => _response(stream));
      addTearDown(() => closeAiClient(client));
      final firstText = Completer<void>();
      final deltas = <String>[];
      var completed = false;
      final result = client
          .complete(
            messages: [AiMessage.user('hello')],
            tools: const [],
            onContentDelta: (delta) {
              deltas.add(delta);
              if (!firstText.isCompleted) firstText.complete();
            },
          )
          .then((message) {
            completed = true;
            return message;
          });

      stream.add(utf8.encode(_textEvent(wireApi, 'first')));
      await firstText.future.timeout(const Duration(seconds: 2));
      expect(deltas, ['first']);
      expect(completed, isFalse);

      stream.add(utf8.encode(_terminalEvent(wireApi)));
      expect((await result).content, 'first');
    });

    test(
      '$wireApi retries only the draft and never executes partial tools',
      () async {
        final firstStream = StreamController<List<int>>();
        final nextStream = StreamController<List<int>>();
        addTearDown(() {
          unawaited(firstStream.close());
          unawaited(nextStream.close());
        });
        var requests = 0;
        final retried = Completer<void>();
        final firstText = Completer<void>();
        var draft = '';
        final client = _client(
          wireApi,
          (_) async {
            requests++;
            if (requests == 1) return _response(firstStream);
            retried.complete();
            return _response(nextStream);
          },
          retryPolicy: const AiRetryPolicy(
            requestMaxRetries: 0,
            streamMaxRetries: 1,
            initialDelay: Duration.zero,
          ),
          onRetry: (_) => draft = '',
        );
        addTearDown(() => closeAiClient(client));
        var executions = 0;
        final events = <String>[];
        final result =
            AgentLoop(
              client: client,
              tools: [
                AgentTool(
                  definition: const AiToolDefinition(
                    name: 'inspect',
                    description: 'Inspect state',
                    parameters: {'type': 'object'},
                  ),
                  requiresConfirmation: false,
                  call: (_) async {
                    executions++;
                    return 'inspected';
                  },
                ),
              ],
            ).run(
              prompt: 'keep this history',
              onEvent: (type, payload) async {
                events.add(type);
                if (type == 'assistant.delta') {
                  draft += payload['text'] as String;
                  if (!firstText.isCompleted) firstText.complete();
                }
              },
            );
        firstStream.add(utf8.encode(_textEvent(wireApi, 'discarded draft')));
        firstStream.add(utf8.encode(_toolEvent(wireApi)));
        await firstText.future.timeout(const Duration(seconds: 2));
        expect(draft, 'discarded draft');
        expect(executions, 0);
        await firstStream.close();
        await retried.future.timeout(const Duration(seconds: 2));
        expect(draft, isEmpty);

        nextStream.add(utf8.encode(_textEvent(wireApi, 'recovered')));
        nextStream.add(utf8.encode(_terminalEvent(wireApi)));
        final completed = await result;
        expect(completed.status, 'completed');
        expect(draft, 'recovered');
        expect(executions, 0);
        expect(completed.messages.map((message) => message.content), [
          'keep this history',
          'recovered',
        ]);
        expect(
          events.where((type) => type == 'assistant.completed'),
          hasLength(1),
        );
        expect(events, isNot(contains('agent.timing')));
      },
    );

    test('$wireApi ignores late text from a cancelled stream', () async {
      final stream = StreamController<List<int>>();
      addTearDown(() => unawaited(stream.close()));
      final client = _client(wireApi, (_) async => _response(stream));
      addTearDown(() => closeAiClient(client));
      final cancellation = Completer<void>();
      final firstText = Completer<void>();
      final deltas = <String>[];
      final result = client.complete(
        messages: [AiMessage.user('hello')],
        tools: const [],
        cancellation: cancellation.future,
        onContentDelta: (delta) {
          deltas.add(delta);
          if (!firstText.isCompleted) firstText.complete();
        },
      );
      stream.add(utf8.encode(_textEvent(wireApi, 'before cancel')));
      await firstText.future.timeout(const Duration(seconds: 2));
      final cancelled = expectLater(result, throwsA(isA<AiRequestCancelled>()));
      cancellation.complete();
      await cancelled;

      stream.add(utf8.encode(_textEvent(wireApi, 'late text')));
      stream.add(utf8.encode(_terminalEvent(wireApi)));
      await stream.close();
      await Future<void>.delayed(Duration.zero);
      expect(deltas, ['before cancel']);
    });
  }
}

AiChatClient _client(
  String wireApi,
  Future<http.StreamedResponse> Function(http.BaseRequest) handler, {
  AiRetryPolicy retryPolicy = const AiRetryPolicy(maxRetries: 0),
  AiRetryListener? onRetry,
}) => createAiClient(
  wireApi: wireApi,
  baseUrl: 'https://provider.example/v1',
  apiKey: 'test-key',
  model: 'test-model',
  retryPolicy: retryPolicy,
  onRetry: onRetry,
  client: _StreamingClient(handler),
);

http.StreamedResponse _response(StreamController<List<int>> stream) =>
    http.StreamedResponse(
      stream.stream,
      200,
      headers: {'content-type': 'text/event-stream'},
    );

String _event(Map<String, Object?> value) => 'data: ${jsonEncode(value)}\n\n';

String _textEvent(String wireApi, String text) => wireApi == 'responses'
    ? _event({'type': 'response.output_text.delta', 'delta': text})
    : _event({
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      });

String _terminalEvent(String wireApi) => wireApi == 'responses'
    ? _event({
        'type': 'response.completed',
        'response': {'id': 'response-test', 'status': 'completed'},
      })
    : '${_event({
        'choices': [
          {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
      })}data: [DONE]\n\n';

String _toolEvent(String wireApi) => wireApi == 'responses'
    ? _event({
        'type': 'response.output_item.done',
        'item': {
          'type': 'function_call',
          'id': 'item-test',
          'call_id': 'call-test',
          'name': 'inspect',
          'arguments': '{}',
        },
      })
    : _event({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call-test',
                  'type': 'function',
                  'function': {'name': 'inspect', 'arguments': '{}'},
                },
              ],
            },
          },
        ],
      });

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
