import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/chat_completions_client.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

void main() {
  test(
    'non-streaming JSON parses text, finish reason, usage, and tool calls',
    () async {
      late http.Request request;
      final client = ChatCompletionsClient(
        baseUrl: 'https://provider.example/v1/',
        apiKey: 'test-key',
        model: 'test-model',
        reasoningEffort: 'high',
        stream: false,
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'id': 'chatcmpl_1',
              'choices': [
                {
                  'index': 0,
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': '我会执行命令。',
                    'tool_calls': [
                      {
                        'id': 'call_1',
                        'type': 'function',
                        'function': {
                          'name': 'terminal_exec',
                          'arguments': '{"command":"pwd"}',
                        },
                      },
                    ],
                  },
                },
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      final response = await client.complete(
        messages: [
          AiMessage.user('执行 pwd'),
          AiMessage.tool(toolCallId: 'call_0', content: '上一次结果'),
        ],
        tools: [
          const AiToolDefinition(
            name: 'terminal.exec',
            description: 'Run a command',
            parameters: {'type': 'object'},
          ),
        ],
      );

      expect(request.url.path, '/v1/chat/completions');
      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['stream'], false);
      expect(body['reasoning_effort'], 'high');
      expect((body['messages'] as List)[1], {
        'role': 'tool',
        'tool_call_id': 'call_0',
        'content': '上一次结果',
      });
      expect((body['tools'] as List).single, {
        'type': 'function',
        'function': {
          'name': 'terminal_exec',
          'description': 'Run a command',
          'parameters': {'type': 'object'},
        },
      });
      expect(response.content, '我会执行命令。');
      expect(response.finishReason, 'tool_calls');
      expect(response.toolCalls.single.id, 'call_1');
      expect(response.toolCalls.single.callId, 'call_1');
      expect(response.toolCalls.single.arguments, '{"command":"pwd"}');
      expect(response.usage?['prompt_tokens'], 10);
    },
  );

  test('SSE streams text and joins incremental tool call arguments', () async {
    final sse = [
      'data: ${jsonEncode({
        'id': 'chatcmpl_2',
        'choices': [
          {
            'index': 0,
            'delta': {
              'role': 'assistant',
              'content': '执行中',
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_stream',
                  'type': 'function',
                  'function': {'name': 'terminal_exec', 'arguments': '{"command":"'},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      })}\n\n',
      'data: ${jsonEncode({
        'choices': [
          {
            'index': 0,
            'delta': {
              'content': 'pwd"}',
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': 'pwd"}'},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      })}\n\n',
      'data: ${jsonEncode({
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
        ],
      })}\n\n',
      'data: [DONE]\n\n',
    ].join();
    final deltas = <String>[];
    final client = ChatCompletionsClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(sse),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);
    expect(client.wireApi, 'chat-completions');

    final response = await client.complete(
      messages: [AiMessage.user('执行')],
      tools: const [],
      onContentDelta: deltas.add,
    );

    expect(deltas, ['执行中', 'pwd"}']);
    expect(response.content, '执行中pwd"}');
    expect(response.finishReason, 'tool_calls');
    expect(response.toolCalls.single.name, 'terminal_exec');
    expect(response.toolCalls.single.callId, 'call_stream');
    expect(response.toolCalls.single.arguments, '{"command":"pwd"}');
  });

  test(
    'assistant tool call history uses Chat Completions wire names',
    () async {
      late http.Request request;
      final client = ChatCompletionsClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: '',
        model: 'test-model',
        stream: false,
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'role': 'assistant', 'content': '完成'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      await client.complete(
        messages: [
          const AiMessage(
            role: 'assistant',
            content: null,
            toolCalls: [
              AiToolCall(
                id: 'call_1',
                name: 'terminal.exec',
                arguments: '{"command":"pwd"}',
                callId: 'call_1',
              ),
            ],
          ),
          AiMessage.tool(toolCallId: 'call_1', content: '工作目录'),
        ],
        tools: const [],
      );

      final messages = (jsonDecode(request.body) as Map)['messages'] as List;
      expect(messages[0], {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': 'terminal_exec',
              'arguments': '{"command":"pwd"}',
            },
          },
        ],
      });
    },
  );

  test(
    'unsupported endpoint fails explicitly without protocol fallback',
    () async {
      var requestCount = 0;
      final client = ChatCompletionsClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'secret-api-key',
        model: 'test-model',
        client: MockClient((request) async {
          requestCount++;
          expect(request.url.path, '/v1/chat/completions');
          return http.Response(
            'endpoint unavailable secret-api-key ' * 200,
            404,
          );
        }),
      );
      addTearDown(client.close);

      Object? error;
      try {
        await client.complete(
          messages: [AiMessage.user('hello')],
          tools: const [],
        );
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<ChatCompletionsUnsupportedException>());
      expect(error.toString(), isNot(contains('secret-api-key')));
      expect(error.toString(), contains('[REDACTED]'));
      expect(error.toString().length, lessThanOrEqualTo(2_000 + 100));
      expect(requestCount, 1);
    },
  );

  test('response size limit applies to streamed responses', () async {
    final client = ChatCompletionsClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      maxResponseBytes: 64,
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'x' * 100},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.complete(messages: [AiMessage.user('hello')], tools: const []),
      throwsA(isA<AiResponseTooLarge>()),
    );
  });

  test(
    'cancellation closes the request and reports AiRequestCancelled',
    () async {
      final requestStarted = Completer<void>();
      final response = Completer<http.Response>();
      final cancellation = Completer<void>();
      final client = ChatCompletionsClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient((_) {
          requestStarted.complete();
          return response.future;
        }),
      );
      addTearDown(client.close);

      final pending = client.complete(
        messages: [AiMessage.user('等待')],
        tools: const [],
        cancellation: cancellation.future,
      );
      await requestStarted.future;
      cancellation.complete();

      await expectLater(pending, throwsA(isA<AiRequestCancelled>()));
    },
  );
}
