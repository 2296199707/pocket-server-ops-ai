import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_loop.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/agent/openai_compatible_client.dart';

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
            id: 'fc-1',
            callId: 'call-1',
            name: 'test.tool',
            arguments: '{}',
          ),
        ],
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
