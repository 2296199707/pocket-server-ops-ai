import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_loop.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/auto_review.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';
import 'package:mobile_agent/agent/remote_write_queue.dart';
import 'package:mobile_agent/domain/models.dart';

void main() {
  test('cancellation stops an in-flight AI request', () async {
    final cancellation = AgentCancellation();
    final events = <String>[];
    final future = AgentLoop(client: _WaitingClient(), tools: const []).run(
      prompt: '继续',
      cancellation: cancellation,
      onEvent: (type, payload) {
        events.add(type);
        return Future.value();
      },
    );

    cancellation.cancel();
    final result = await future;

    expect(result.status, 'cancelled');
    expect(events, contains('task.cancelled'));
  });

  test('forwards streamed assistant deltas as transient events', () async {
    final events = <String>[];
    final result = await AgentLoop(client: _DeltaClient(), tools: const []).run(
      prompt: '回复',
      onEvent: (type, payload) {
        if (type == 'assistant.delta') {
          events.add(payload['text'] as String);
        }
        return Future.value();
      },
    );

    expect(result.status, 'completed');
    expect(events, ['第一段', '第二段']);
  });

  test('step limit reports an uncertain result after tool execution', () async {
    final events = <String>[];
    final result =
        await AgentLoop(
          client: _RepeatingClient(),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              isRemote: true,
              writesRemoteState: true,
              call: (_) async => const {'ok': true},
            ),
          ],
        ).run(
          prompt: '执行',
          executionMode: 'auto',
          maxSteps: 1,
          onEvent: (type, payload) {
            events.add(type);
            return Future.value();
          },
        );

    expect(result.status, 'unknown');
    expect(events, contains('task.unknown'));
  });

  test('failed tool calls leave a tool message for the next turn', () async {
    final client = _ToolThenTextClient();
    final events = <String>[];
    final result =
        await AgentLoop(
          client: client,
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              call: (_) async => throw StateError('remote result unavailable'),
            ),
          ],
        ).run(
          prompt: '执行',
          executionMode: 'auto',
          onEvent: (type, payload) {
            events.add(type);
            return Future.value();
          },
        );

    expect(result.status, 'completed');
    expect(result.messages.last.content, 'done');
    expect(
      client.messages.any(
        (message) =>
            message.role == 'tool' &&
            message.content!.contains('remote result unavailable'),
      ),
      isTrue,
    );
    expect(events, contains('tool.failed'));
    expect(events, isNot(contains('task.unknown')));
  });

  test(
    'remote write failure stops before requesting the model again',
    () async {
      final client = _ToolThenTextClient(toolName: 'remote.write');
      final result = await AgentLoop(
        client: client,
        tools: [
          AgentTool(
            definition: const AiToolDefinition(
              name: 'remote.write',
              description: 'test',
              parameters: {'type': 'object'},
            ),
            isRemote: true,
            writesRemoteState: true,
            call: (_) async => throw StateError('remote write failed'),
          ),
        ],
      ).run(prompt: '执行', executionMode: 'auto');

      expect(result.status, 'unknown');
      expect(client.calls, 1);
    },
  );

  test(
    'structured tool results keep a bounded head and tail preview',
    () async {
      final events = <Map<String, Object?>>[];
      final result =
          await AgentLoop(
            client: _ToolThenTextClient(),
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                call: (_) async => {
                  'items': [
                    for (var index = 0; index < 100; index++) 'item-$index',
                  ],
                },
              ),
            ],
          ).run(
            prompt: '读取',
            executionMode: 'auto',
            toolOutputLimit: 512,
            onEvent: (type, payload) {
              if (type == 'tool.completed') events.add(payload);
              return Future.value();
            },
          );

      expect(result.status, 'completed');
      final items = (events.single['result'] as Map)['items'] as List;
      expect(items.first, 'item-0');
      expect(items[8], {
        '__mobile_agent_truncated': true,
        '__mobile_agent_omitted_items': 84,
      });
      expect(items.last, 'item-99');
    },
  );

  test('Codex fallback policy bounds results without catalog fields', () async {
    final client = _ToolThenTextClient();
    const metadata = ProviderModelMetadata(model: 'id-only');
    final policy = metadata.resolvedTruncationPolicy;

    final result =
        await AgentLoop(
          client: client,
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              call: (_) async => {'stdout': 'x' * 20000},
            ),
          ],
        ).run(
          prompt: '读取',
          executionMode: 'auto',
          toolOutputLimit: policy.limit,
          toolOutputLimitInTokens: policy.mode == 'tokens',
        );

    expect(result.status, 'completed');
    final toolMessage = client.messages.singleWhere(
      (message) => message.role == 'tool',
    );
    expect(toolMessage.content!.length, lessThanOrEqualTo(policy.limit));
    expect(toolMessage.content, contains('__mobile_agent_truncated'));
  });

  test(
    'rebounded structured tool results accumulate omitted entries',
    () async {
      final events = <Map<String, Object?>>[];
      final result =
          await AgentLoop(
            client: _ToolThenTextClient(),
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                call: (_) async => {
                  'items': [
                    for (var index = 0; index < 20; index++) 'item-$index',
                    {
                      '__mobile_agent_truncated': true,
                      '__mobile_agent_omitted_items': 10,
                    },
                  ],
                  'entries': {
                    for (var index = 0; index < 20; index++)
                      'key-$index': 'value-$index',
                    '__mobile_agent_truncated': true,
                    '__mobile_agent_omitted_entries': 10,
                  },
                },
              ),
            ],
          ).run(
            prompt: '读取',
            executionMode: 'auto',
            toolOutputLimit: 4096,
            onEvent: (type, payload) {
              if (type == 'tool.completed') events.add(payload);
              return Future.value();
            },
          );

      expect(result.status, 'completed');
      final bounded = events.single['result'] as Map;
      final boundedItems = bounded['items'] as List;
      expect(boundedItems.first, 'item-0');
      expect(boundedItems[8], {
        '__mobile_agent_truncated': true,
        '__mobile_agent_omitted_items': 14,
      });
      expect(boundedItems.last, 'item-19');
      final boundedEntries = bounded['entries'] as Map;
      expect(boundedEntries['key-0'], 'value-0');
      expect(boundedEntries['__mobile_agent_truncated'], true);
      expect(boundedEntries['__mobile_agent_omitted_entries'], 14);
      expect(boundedEntries['key-19'], 'value-19');
    },
  );

  test(
    'Responses tool results use call_id rather than output item id',
    () async {
      final client = _ResponsesToolThenTextClient();
      final events = <String, Map<String, Object?>>{};
      final result =
          await AgentLoop(
            client: client,
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                call: (_) async => const {'ok': true},
              ),
            ],
          ).run(
            prompt: '执行',
            executionMode: 'auto',
            onEvent: (type, payload) {
              if (type == 'tool.started' || type == 'tool.completed') {
                events[type] = payload;
              }
              return Future.value();
            },
          );

      expect(result.status, 'completed');
      expect(client.messages.last.toolCallId, 'call_1');
      expect(events['tool.started']!['id'], 'fc_1');
      expect(events['tool.started']!['call_id'], 'call_1');
      expect(events['tool.completed']!['call_id'], 'call_1');
    },
  );

  test(
    'cancellation during tool execution returns an unknown result',
    () async {
      final cancellation = AgentCancellation();
      final toolStarted = Completer<void>();
      final toolResult = Completer<Map<String, Object?>>();
      final events = <String>[];
      final future =
          AgentLoop(
            client: _ToolThenTextClient(),
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                isRemote: true,
                writesRemoteState: true,
                call: (_) {
                  toolStarted.complete();
                  return toolResult.future;
                },
              ),
            ],
          ).run(
            prompt: '执行',
            executionMode: 'auto',
            cancellation: cancellation,
            onEvent: (type, payload) {
              events.add(type);
              return Future.value();
            },
          );

      await toolStarted.future;
      cancellation.cancel();
      toolResult.complete(<String, Object?>{'ok': true});

      final result = await future;

      expect(result.status, 'unknown');
      expect(events, contains('task.unknown'));
      expect(events, isNot(contains('task.cancelled')));
    },
  );

  test('cancellation while confirming never executes the tool', () async {
    final cancellation = AgentCancellation();
    final confirmationStarted = Completer<void>();
    final confirmation = Completer<bool>();
    var executions = 0;
    final future =
        AgentLoop(
          client: _ToolThenTextClient(),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              call: (_) async {
                executions++;
                return const {'ok': true};
              },
            ),
          ],
        ).run(
          prompt: '执行',
          cancellation: cancellation,
          confirm: (_, _) {
            confirmationStarted.complete();
            return confirmation.future;
          },
        );

    await confirmationStarted.future;
    cancellation.cancel();
    final result = await future;
    confirmation.complete(true);

    expect(result.status, 'cancelled');
    expect(executions, 0);
  });

  test(
    'queued remote write is cancelled before its operation starts',
    () async {
      final queue = RemoteWriteQueue();
      final firstCancellation = AgentCancellation();
      final secondCancellation = AgentCancellation();
      final firstFinished = Completer<void>();
      var secondStarted = false;

      final first = queue.run<void>('server:/srv/app', () async {
        await firstFinished.future;
      }, cancellation: firstCancellation);
      final second = queue.run<void>('server:/srv/app', () async {
        secondStarted = true;
      }, cancellation: secondCancellation);

      secondCancellation.cancel();
      firstFinished.complete();
      await first;
      await expectLater(second, throwsA(isA<StateError>()));
      expect(secondStarted, isFalse);
    },
  );

  test(
    'remote writes for one server serialize across working directories',
    () async {
      final queue = RemoteWriteQueue();
      final firstFinished = Completer<void>();
      var secondStarted = false;

      final first = queue.run<void>('server-1', () async {
        await firstFinished.future;
      }, cancellation: AgentCancellation());
      final second = queue.run<void>('server-1', () async {
        secondStarted = true;
      }, cancellation: AgentCancellation());

      await Future<void>.delayed(Duration.zero);
      expect(secondStarted, isFalse);
      firstFinished.complete();
      await Future.wait([first, second]);
      expect(secondStarted, isTrue);
    },
  );

  test('unknown execution modes fall back to confirmation', () async {
    var confirmations = 0;
    var executions = 0;
    final result =
        await AgentLoop(
          client: _ToolThenTextClient(),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              call: (_) async {
                executions++;
                return const {'ok': true};
              },
            ),
          ],
        ).run(
          prompt: '执行',
          executionMode: 'unexpected',
          confirm: (_, _) async {
            confirmations++;
            return false;
          },
        );

    expect(result.status, 'completed');
    expect(confirmations, 1);
    expect(executions, 0);
  });

  test('read-only tools do not require confirmation', () async {
    var confirmations = 0;
    var executions = 0;
    final result =
        await AgentLoop(
          client: _ToolThenTextClient(),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              requiresConfirmation: false,
              call: (_) async {
                executions++;
                return const {'ok': true};
              },
            ),
          ],
        ).run(
          prompt: '读取',
          confirm: (_, _) async {
            confirmations++;
            return false;
          },
        );

    expect(result.status, 'completed');
    expect(executions, 1);
    expect(confirmations, 0);
  });

  test(
    'automatic review can allow a gated tool without user confirmation',
    () async {
      var reviews = 0;
      var confirmations = 0;
      var executions = 0;
      final result =
          await AgentLoop(
            client: _ToolThenTextClient(),
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                call: (_) async {
                  executions++;
                  return const {'ok': true};
                },
              ),
            ],
          ).run(
            prompt: '执行',
            executionMode: 'auto_review',
            review: (_, _) async {
              reviews++;
              return AgentReviewDecision.allow('范围内');
            },
            confirm: (_, _) async {
              confirmations++;
              return false;
            },
          );

      expect(result.status, 'completed');
      expect(reviews, 1);
      expect(confirmations, 0);
      expect(executions, 1);
    },
  );

  test('review failure is surfaced and fails closed', () async {
    final events = <String>[];
    var confirmations = 0;
    var executions = 0;
    final result =
        await AgentLoop(
          client: _ToolThenTextClient(),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'test.tool',
                description: 'test',
                parameters: {'type': 'object'},
              ),
              call: (_) async {
                executions++;
                return const {'ok': true};
              },
            ),
          ],
        ).run(
          prompt: '执行',
          executionMode: 'auto_review',
          review: (_, _) async => AgentReviewDecision.failure('审查服务不可用'),
          confirm: (_, _) async {
            confirmations++;
            return false;
          },
          onEvent: (type, payload) {
            events.add(type);
            return Future.value();
          },
        );

    expect(result.status, 'completed');
    expect(confirmations, 0);
    expect(executions, 0);
    expect(events, contains('review.failed'));
    expect(events, isNot(contains('review.completed')));
  });

  test(
    'local tool failure after cancellation is not marked as remote unknown',
    () async {
      final cancellation = AgentCancellation();
      final started = Completer<void>();
      final pending = Completer<Object?>();
      final events = <String>[];
      final future =
          AgentLoop(
            client: _ToolThenTextClient(toolName: 'local.tool'),
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'local.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                call: (_) {
                  started.complete();
                  return pending.future;
                },
              ),
            ],
          ).run(
            prompt: '执行',
            executionMode: 'auto',
            cancellation: cancellation,
            onEvent: (type, payload) {
              events.add(type);
              return Future.value();
            },
          );
      await started.future;
      cancellation.cancel();
      final result = await future;
      pending.complete(null);

      expect(result.status, 'cancelled');
      expect(events, contains('task.cancelled'));
      expect(events, isNot(contains('task.unknown')));
    },
  );

  test('boundary permission requests always require the user', () async {
    var confirmations = 0;
    var executions = 0;
    final result =
        await AgentLoop(
          client: _ToolThenTextClient(toolName: 'local.request_access'),
          tools: [
            AgentTool(
              definition: const AiToolDefinition(
                name: 'local.request_access',
                description: 'permission',
                parameters: {'type': 'object'},
              ),
              requiresConfirmation: false,
              requiresUserApproval: true,
              call: (_) async {
                executions++;
                return const {'granted': true};
              },
            ),
          ],
        ).run(
          prompt: '请求权限',
          executionMode: 'auto',
          confirm: (_, _) async {
            confirmations++;
            return true;
          },
        );

    expect(result.status, 'completed');
    expect(confirmations, 1);
    expect(executions, 1);
  });

  test('length finish reason is not reported as success', () async {
    final events = <String>[];
    final result = await AgentLoop(client: _LengthClient(), tools: const [])
        .run(
          prompt: '继续',
          onEvent: (type, payload) {
            events.add(type);
            return Future.value();
          },
        );

    expect(result.status, 'failed');
    expect(result.finalText, 'partial');
    expect(events, contains('task.failed'));
    expect(events, isNot(contains('task.completed')));
  });

  test('tool call limit stops additional remote operations', () async {
    var executions = 0;
    final result = await AgentLoop(
      client: _MultipleToolClient(),
      tools: [
        AgentTool(
          definition: const AiToolDefinition(
            name: 'test.tool',
            description: 'test',
            parameters: {'type': 'object'},
          ),
          isRemote: true,
          writesRemoteState: true,
          call: (_) async {
            executions++;
            return const {'ok': true};
          },
        ),
      ],
    ).run(prompt: '执行', executionMode: 'auto', maxToolCalls: 1);

    expect(result.status, 'unknown');
    expect(executions, 1);
  });

  test(
    'context trimming keeps system prompt and the latest complete turn',
    () async {
      final client = _CapturingClient();
      final result = await AgentLoop(client: client, tools: const []).run(
        prompt: 'new request',
        initialMessages: [
          const AiMessage(role: 'system', content: 'system prompt'),
          const AiMessage(role: 'user', content: 'old request'),
          AiMessage(role: 'assistant', content: 'x' * 500),
        ],
        maxContextCharacters: 200,
      );

      expect(result.status, 'completed');
      expect(client.messages.map((message) => message.role), [
        'system',
        'user',
      ]);
      expect(client.messages.last.content, 'new request');
    },
  );

  test(
    'mid-turn compaction replaces history before the next request',
    () async {
      final client = _UsageToolThenTextClient();
      var compactCalls = 0;
      final result =
          await AgentLoop(
            client: client,
            tools: [
              AgentTool(
                definition: const AiToolDefinition(
                  name: 'test.tool',
                  description: 'test',
                  parameters: {'type': 'object'},
                ),
                requiresConfirmation: false,
                call: (_) async => const {'ok': true},
              ),
            ],
          ).run(
            prompt: '执行',
            executionMode: 'auto',
            compactHistory: (messages) async {
              compactCalls++;
              expect(messages.any((message) => message.role == 'tool'), isTrue);
              return const [
                AiMessage(role: 'system', content: 'system'),
                AiMessage(
                  role: 'assistant',
                  responsesOutputItems: [
                    {'type': 'compaction', 'encrypted_content': 'opaque'},
                  ],
                ),
              ];
            },
          );

      expect(result.status, 'completed');
      expect(compactCalls, 1);
      expect(
        client.requests[1]
            .firstWhere((message) => message.responsesOutputItems.isNotEmpty)
            .responsesOutputItems
            .single['type'],
        'compaction',
      );
    },
  );

  test('provider-safe tool names map back to internal tools', () async {
    var executions = 0;
    final result = await AgentLoop(
      client: _ProviderNamedToolClient(),
      tools: [
        AgentTool(
          definition: const AiToolDefinition(
            name: 'terminal.exec',
            description: 'Run a command',
            parameters: {'type': 'object'},
          ),
          requiresConfirmation: false,
          call: (_) async {
            executions++;
            return const {'ok': true};
          },
        ),
      ],
    ).run(prompt: '执行', executionMode: 'auto');

    expect(result.status, 'completed');
    expect(executions, 1);
  });
}

class _WaitingClient implements AiChatClient {
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    await cancellation;
    throw const AiRequestCancelled();
  }
}

class _DeltaClient implements AiChatClient {
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    onContentDelta?.call('第一段');
    onContentDelta?.call('第二段');
    return const AiMessage(role: 'assistant', content: '第一段第二段');
  }
}

class _RepeatingClient implements AiChatClient {
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    return const AiMessage(
      role: 'assistant',
      toolCalls: [
        AiToolCall(
          id: 'fc-1',
          callId: 'call-1',
          name: 'test.tool',
          arguments: '{}',
        ),
      ],
    );
  }
}

class _ToolThenTextClient implements AiChatClient {
  _ToolThenTextClient({this.toolName = 'test.tool'});

  final String toolName;
  var calls = 0;
  List<AiMessage> messages = const [];

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    this.messages = List.unmodifiable(messages);
    if (calls++ == 0) {
      return AiMessage(
        role: 'assistant',
        toolCalls: [
          AiToolCall(
            id: 'fc-1',
            callId: 'call-1',
            name: toolName,
            arguments: '{}',
          ),
        ],
      );
    }
    return const AiMessage(role: 'assistant', content: 'done');
  }
}

class _UsageToolThenTextClient implements AiChatClient {
  final requests = <List<AiMessage>>[];
  var calls = 0;

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    requests.add(List.unmodifiable(messages));
    if (calls++ == 0) {
      return const AiMessage(
        role: 'assistant',
        toolCalls: [
          AiToolCall(
            id: 'fc-1',
            callId: 'call-1',
            name: 'test.tool',
            arguments: '{}',
          ),
        ],
        usage: {'total_tokens': 100},
      );
    }
    return const AiMessage(role: 'assistant', content: 'done');
  }
}

class _ResponsesToolThenTextClient implements AiChatClient {
  var calls = 0;
  List<AiMessage> messages = const [];

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    this.messages = List.unmodifiable(messages);
    if (calls++ == 0) {
      return const AiMessage(
        role: 'assistant',
        toolCalls: [
          AiToolCall(
            id: 'fc_1',
            callId: 'call_1',
            name: 'test.tool',
            arguments: '{}',
          ),
        ],
      );
    }
    return const AiMessage(role: 'assistant', content: 'done');
  }
}

class _MultipleToolClient implements AiChatClient {
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    return const AiMessage(
      role: 'assistant',
      toolCalls: [
        AiToolCall(
          id: 'fc-1',
          callId: 'call-1',
          name: 'test.tool',
          arguments: '{}',
        ),
        AiToolCall(
          id: 'fc-2',
          callId: 'call-2',
          name: 'test.tool',
          arguments: '{}',
        ),
      ],
    );
  }
}

class _LengthClient implements AiChatClient {
  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    return const AiMessage(
      role: 'assistant',
      content: 'partial',
      finishReason: 'length',
    );
  }
}

class _CapturingClient implements AiChatClient {
  List<AiMessage> messages = const [];

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    this.messages = List.unmodifiable(messages);
    return const AiMessage(role: 'assistant', content: 'done');
  }
}

class _ProviderNamedToolClient implements AiChatClient {
  var calls = 0;

  @override
  Future<AiMessage> complete({
    required List<AiMessage> messages,
    required List<AiToolDefinition> tools,
    void Function(String delta)? onContentDelta,
    Future<void>? cancellation,
  }) async {
    if (calls++ == 0) {
      return const AiMessage(
        role: 'assistant',
        toolCalls: [
          AiToolCall(
            id: 'fc_1',
            callId: 'call_1',
            name: 'terminal_exec',
            arguments: '{}',
          ),
        ],
      );
    }
    return const AiMessage(role: 'assistant', content: 'done');
  }
}
