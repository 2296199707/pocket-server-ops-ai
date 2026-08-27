import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

void main() {
  test(
    'Responses tail token estimate includes local items after model output',
    () {
      const call = {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'terminal_exec',
        'arguments': '{}',
      };
      final toolOutput = 'x' * 41;
      final expectedItems = [
        {
          'type': 'function_call_output',
          'call_id': 'call_1',
          'output': toolOutput,
        },
      ];
      final expectedBytes = utf8
          .encode(jsonEncode(expectedItems.single))
          .length;

      expect(
        OpenAiCompatibleClient.estimateResponsesTailTokenCount([
          const AiMessage(role: 'assistant', responsesOutputItems: [call]),
          AiMessage.tool(toolCallId: 'call_1', content: toolOutput),
        ]),
        (expectedBytes + 3) ~/ 4,
      );
      expect(
        OpenAiCompatibleClient.estimateResponsesTailTokenCount([
          AiMessage.user('没有模型输出边界'),
          AiMessage.tool(toolCallId: 'call_1', content: toolOutput),
        ]),
        0,
      );
    },
  );

  test('Responses input sends selected image and file attachments', () async {
    late http.Request request;
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'vision-model',
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '已收到'},
                ],
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
        AiMessage.user(
          '分析附件',
          attachments: const [
            AiAttachment(
              name: 'screen.png',
              mimeType: 'image/png',
              base64Data: 'aW1hZ2U=',
            ),
            AiAttachment(
              name: 'notes.txt',
              mimeType: 'text/plain',
              base64Data: 'dGV4dA==',
            ),
          ],
        ),
      ],
      tools: const [],
    );

    final body = jsonDecode(request.body) as Map<String, Object?>;
    final input = (body['input'] as List).single as Map;
    final content = input['content'] as List;
    expect(content[0], {'type': 'input_text', 'text': '分析附件'});
    expect(content[1], {
      'type': 'input_image',
      'image_url': 'data:image/png;base64,aW1hZ2U=',
    });
    expect(content[2], {
      'type': 'input_file',
      'filename': 'notes.txt',
      'file_data': 'data:text/plain;base64,dGV4dA==',
    });
  });

  test(
    'Responses JSON parses without embedding compaction configuration',
    () async {
      late http.Request request;
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'gpt-5.6-luna',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'function_call',
                  'id': 'fc_1',
                  'call_id': 'call_1',
                  'name': 'terminal.exec',
                  'arguments': '{"command":"pwd"}',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      final response = await client.complete(
        messages: [AiMessage.user('执行 pwd')],
        tools: [
          const AiToolDefinition(
            name: 'terminal.exec',
            description: 'Run a command',
            parameters: {'type': 'object'},
          ),
        ],
      );

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(request.url.path, '/v1/responses');
      expect(body['store'], false);
      expect(body.containsKey('reasoning'), isFalse);
      expect(body.containsKey('context_management'), isFalse);
      expect((body['tools'] as List).single, {
        'type': 'function',
        'name': 'terminal_exec',
        'description': 'Run a command',
        'parameters': {'type': 'object'},
      });
      expect(response.toolCalls.single.id, 'fc_1');
      expect(response.toolCalls.single.callId, 'call_1');
      expect(response.toolCalls.single.effectiveCallId, 'call_1');
      expect(response.responsesOutputItems.single['type'], 'function_call');
    },
  );

  test(
    'Responses compaction uses its dedicated endpoint and replaces history',
    () async {
      late http.Request request;
      const compactedItem = {
        'type': 'compaction',
        'encrypted_content': 'opaque-summary',
      };
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'gpt-5.6-luna',
        reasoningEffort: 'high',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'output': [compactedItem],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      final output = await client.compact(
        messages: [
          const AiMessage(role: 'system', content: 'base instructions'),
          AiMessage.user('保留这条用户消息'),
        ],
        instructions: 'base instructions',
      );

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(request.url.path, '/v1/responses/compact');
      expect(body['model'], 'gpt-5.6-luna');
      expect(body['instructions'], 'base instructions');
      expect(body.containsKey('parallel_tool_calls'), isFalse);
      expect(body.containsKey('tools'), isFalse);
      expect(body.containsKey('reasoning'), isFalse);
      expect((body['input'] as List).length, 1);
      expect((body['input'] as List).single['role'], 'user');
      expect(body.containsKey('stream'), isFalse);
      expect(body.containsKey('store'), isFalse);
      expect(output, [compactedItem]);
    },
  );

  test('Responses compaction rejects non-object output items', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'output': [
              {'type': 'compaction', 'encrypted_content': 'opaque-summary'},
              'invalid-item',
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.compact(
        messages: [AiMessage.user('压缩历史')],
        instructions: 'instructions',
      ),
      throwsA(
        isA<AiResponseInvalid>().having(
          (error) => error.message,
          'message',
          contains('index 1'),
        ),
      ),
    );
  });

  test(
    'Responses compaction reports an unsupported endpoint clearly',
    () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient((_) async => http.Response('not found', 404)),
      );
      addTearDown(client.close);

      await expectLater(
        client.compact(
          messages: [AiMessage.user('压缩历史')],
          instructions: 'instructions',
        ),
        throwsA(
          isA<AiProviderHttpException>().having(
            (error) => '$error',
            'message',
            contains('未提供 /responses/compact'),
          ),
        ),
      );
    },
  );

  test('Responses compaction identifies an unavailable upstream', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response('upstream unavailable', 503),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.compact(
        messages: [AiMessage.user('压缩历史')],
        instructions: 'instructions',
      ),
      throwsA(
        isA<AiProviderHttpException>().having(
          (error) => '$error',
          'message',
          contains('请稍后重试'),
        ),
      ),
    );
  });

  test(
    'Responses history completes missing calls and drops orphan outputs',
    () async {
      late http.Request request;
      const Map<String, Object?> call = {
        'type': 'function_call',
        'id': 'fc_missing',
        'call_id': 'call_missing',
        'name': 'terminal_exec',
        'arguments': '{}',
      };
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': '已恢复'},
                  ],
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
          const AiMessage(role: 'assistant', responsesOutputItems: [call]),
          const AiMessage(
            role: 'tool',
            toolCallId: 'orphan-call',
            content: 'orphan result',
          ),
        ],
        tools: const [],
      );

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['input'], [
        call,
        {
          'type': 'function_call_output',
          'call_id': 'call_missing',
          'output': 'aborted',
        },
      ]);
    },
  );

  test('Responses omits unsupported image and audio attachments when metadata is known', () async {
    late http.Request request;
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'text-model',
      inputModalities: const ['text'],
      client: MockClient((incoming) async {
        request = incoming;
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '收到'},
                ],
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
        AiMessage.user(
          '检查',
          attachments: const [
            AiAttachment(
              name: 'screen.png',
              mimeType: 'image/png',
              base64Data: 'aW1hZ2U=',
            ),
            AiAttachment(
              name: 'voice.wav',
              mimeType: 'audio/wav',
              base64Data: 'YXVkaW8=',
            ),
          ],
        ),
      ],
      tools: const [],
    );

    final body = jsonDecode(request.body) as Map<String, Object?>;
    final input = (body['input'] as List).single as Map;
    final content = input['content'] as List;
    expect(content, [
      {'type': 'input_text', 'text': '检查'},
      {
        'type': 'input_text',
        'text': '[Image omitted: this model does not support image input.]',
      },
      {
        'type': 'input_text',
        'text': '[Audio omitted: this model does not support audio input.]',
      },
    ]);
  });

  test(
    'Responses omits compaction management when the model window is unknown',
    () async {
      late http.Request request;
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'unknown-model',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': '完成'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      await client.complete(messages: [AiMessage.user('检查')], tools: const []);

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body.containsKey('context_management'), isFalse);
    },
  );

  test(
    'Responses sends the selected official reasoning effort unchanged',
    () async {
      late http.Request request;
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'gpt-5.6-luna',
        reasoningEffort: 'xhigh',
        client: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': '完成'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      await client.complete(messages: [AiMessage.user('检查')], tools: const []);

      final body = jsonDecode(request.body) as Map<String, Object?>;
      expect(body['reasoning'], {'effort': 'xhigh'});
    },
  );

  test(
    'Responses output items, including compaction, are replayed verbatim',
    () async {
      final requests = <http.Request>[];
      const compaction = {
        'type': 'compaction',
        'id': 'cmp_1',
        'encrypted_content': 'opaque-provider-state',
      };
      const reasoning = {
        'type': 'reasoning',
        'id': 'rs_1',
        'encrypted_content': 'opaque-reasoning-state',
        'summary': <Object?>[],
      };
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            return http.Response(
              jsonEncode({
                'status': 'completed',
                'output': [reasoning, compaction],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': '继续完成'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.close);

      final first = await client.complete(
        messages: [AiMessage.user('开始')],
        tools: const [],
      );
      await client.complete(
        messages: [AiMessage.user('开始'), first, AiMessage.user('继续')],
        tools: const [],
      );

      final secondBody = jsonDecode(requests[1].body) as Map<String, Object?>;
      expect(secondBody['input'], [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '开始'},
          ],
        },
        reasoning,
        compaction,
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '继续'},
          ],
        },
      ]);
    },
  );

  test('Responses SSE keeps completed output items', () async {
    const compaction = {
      'type': 'compaction',
      'id': 'cmp_sse',
      'encrypted_content': 'opaque-state',
    };
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response(
          'data: ${jsonEncode({'type': 'response.output_item.done', 'item': compaction})}\n\n'
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {'id': 'resp_sse_compaction', 'status': 'completed'},
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);

    final response = await client.complete(
      messages: [AiMessage.user('继续')],
      tools: const [],
    );

    expect(response.responsesOutputItems, [compaction]);
  });

  test(
    'Responses tool results use call_id rather than output item id',
    () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'function_call',
                  'id': 'fc_1',
                  'call_id': 'call_1',
                  'name': 'terminal.exec',
                  'arguments': '{}',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.close);

      final response = await client.complete(
        messages: [AiMessage.user('执行')],
        tools: const [],
      );

      expect(response.toolCalls.single.callId, 'call_1');
      expect(response.toolCalls.single.id, 'fc_1');
    },
  );

  test(
    'a provider without Responses support fails without protocol fallback',
    () async {
      var requestCount = 0;
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient((request) async {
          requestCount++;
          expect(request.url.path, '/v1/responses');
          return http.Response('Responses endpoint is not available', 404);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.complete(messages: [AiMessage.user('hello')], tools: const []),
        throwsA(isA<Exception>()),
      );
      expect(requestCount, 1);
    },
  );

  test('incomplete Responses SSE responses are rejected', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response(
          'data: {"type":"response.output_text.delta","delta":"partial"}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.complete(messages: [AiMessage.user('hello')], tools: const []),
      throwsA(isA<AiResponseIncomplete>()),
    );
  });

  test('malformed Responses SSE event is skipped before a valid completion', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            'data: {not-json}\n\n'
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': '完成'})}\n\n'
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {'id': 'resp_after_malformed', 'status': 'completed'},
            })}\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);

    final response = await client.complete(
      messages: [AiMessage.user('继续')],
      tools: const [],
    );

    expect(response.content, '完成');
  });

  test('Responses SSE completion without response id is rejected', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      client: MockClient(
        (_) async => http.Response(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {'status': 'completed'},
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.complete(messages: [AiMessage.user('继续')], tools: const []),
      throwsA(isA<AiResponseInvalid>()),
    );
  });

  test(
    'missing call_id is a protocol error instead of a generated id',
    () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'function_call',
                  'id': 'fc_1',
                  'name': 'terminal.exec',
                  'arguments': '{}',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.complete(messages: [AiMessage.user('执行')], tools: const []),
        throwsA(isA<AiResponseInvalid>()),
      );
    },
  );

  test(
    'incomplete JSON Responses are not returned as successful history',
    () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'incomplete',
              'incomplete_details': {'reason': 'max_output_tokens'},
              'output': <Object?>[],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.complete(messages: [AiMessage.user('继续')], tools: const []),
        throwsA(isA<AiResponseIncomplete>()),
      );
    },
  );

  test(
    'Responses refusal is not returned as an empty successful message',
    () async {
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: 'test-key',
        model: 'test-model',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'refusal', 'refusal': 'cannot help'},
                  ],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.close);

      await expectLater(
        client.complete(messages: [AiMessage.user('请求')], tools: const []),
        throwsA(isA<AiResponseInvalid>()),
      );
    },
  );

  test('SSE completion events and multiline data are parsed', () async {
    final sse = [
      'data: ${jsonEncode({
        'type': 'response.output_item.added',
        'item': {'type': 'function_call', 'id': 'fc_1', 'name': 'terminal.exec', 'status': 'in_progress', 'arguments': ''},
      })}\n\n',
      'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'delta': '{"command":'})}\n\n',
      'data: ${jsonEncode({'type': 'response.function_call_arguments.done', 'item_id': 'fc_1', 'call_id': 'call_1', 'arguments': '{"command":"pwd"}'})}\n\n',
      'data: ${jsonEncode({
        'type': 'response.output_item.done',
        'item': {'type': 'function_call', 'id': 'fc_1', 'name': 'terminal.exec', 'status': 'completed', 'arguments': '{"command":"pwd"}'},
      })}\n\n',
      'data: {"type":"response.completed",\n'
          'data: "response":{"id":"resp_multiline","status":"completed"}}\n\n',
    ].join();
    final client = OpenAiCompatibleClient(
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

    final response = await client.complete(
      messages: [AiMessage.user('执行 pwd')],
      tools: const [],
    );

    expect(response.toolCalls.single.callId, 'call_1');
    expect(response.toolCalls.single.arguments, '{"command":"pwd"}');
  });

  test('response.output_text.done supplies text when no delta was sent', () async {
    final sse = [
      'data: ${jsonEncode({'type': 'response.output_text.done', 'text': '完成'})}\n\n',
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {'id': 'resp_text_done', 'status': 'completed'},
      })}\n\n',
    ].join();
    final client = OpenAiCompatibleClient(
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

    final response = await client.complete(
      messages: [AiMessage.user('继续')],
      tools: const [],
    );

    expect(response.content, '完成');
  });

  test(
    'HTTP error body is bounded and redacts the configured API key',
    () async {
      final secret = 'secret-api-key';
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://provider.example/v1',
        apiKey: secret,
        model: 'test-model',
        client: MockClient(
          (_) async => http.Response(
            'provider error $secret',
            500,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(client.close);

      Object? error;
      try {
        await client.complete(
          messages: [AiMessage.user('请求')],
          tools: const [],
        );
      } catch (caught) {
        error = caught;
      }

      expect(error, isNotNull);
      expect(error, isA<AiProviderHttpException>());
      expect(
        (error as AiProviderHttpException).kind,
        AiProviderHttpErrorKind.server,
      );
      expect(error.toString(), isNot(contains(secret)));
      expect(error.toString(), contains('[REDACTED]'));
    },
  );

  test('configured response limit is enforced', () async {
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://provider.example/v1',
      apiKey: 'test-key',
      model: 'test-model',
      maxResponseBytes: 64,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': 'x' * 100},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);

    await expectLater(
      client.complete(messages: [AiMessage.user('hello')], tools: const []),
      throwsA(isA<AiResponseTooLarge>()),
    );
  });
}
