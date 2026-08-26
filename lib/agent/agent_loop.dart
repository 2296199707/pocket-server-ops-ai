import 'dart:async';
import 'dart:convert';

import 'agent_tools.dart';
import 'auto_review.dart';
import 'ai_protocol.dart';
import 'chat_completions_client.dart';
import 'openai_compatible_client.dart';

class AgentCancellation {
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
  }
}

class AgentResult {
  const AgentResult({
    required this.status,
    required this.messages,
    this.finalText = '',
    this.error,
  });

  final String status;
  final List<AiMessage> messages;
  final String finalText;
  final Object? error;
}

class AgentLoop {
  const AgentLoop({required this.client, required this.tools});

  final AiChatClient client;
  final List<AgentTool> tools;

  Future<AgentResult> run({
    required String prompt,
    List<AiAttachment> attachments = const [],
    List<AiMessage> initialMessages = const [],
    String executionMode = 'confirm',
    AgentCancellation? cancellation,
    int maxSteps = 64,
    int maxToolCalls = 128,
    int? maxContextCharacters,
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    Future<AgentReviewDecision> Function(
      AgentTool tool,
      Map<String, Object?> arguments,
    )?
    review,
    Future<void> Function(String type, Map<String, Object?> payload)? onEvent,
  }) async {
    final messages = <AiMessage>[
      ...initialMessages,
      AiMessage.user(prompt, attachments: attachments),
    ];
    final stop = cancellation ?? AgentCancellation();
    final definitions = tools
        .map((tool) => tool.definition)
        .toList(growable: false);
    var steps = 0;
    var toolCallCount = 0;
    var remoteOperationStarted = false;
    var deltaEvents = Future<void>.value();
    final handledToolCallIds = <String>{};

    String toolResultId(AiToolCall call) {
      return _wireApi(client) == 'responses' ? call.effectiveCallId : call.id;
    }

    void addToolResult(AiToolCall call, String content) {
      final callId = toolResultId(call);
      messages.add(AiMessage.tool(toolCallId: callId, content: content));
      handledToolCallIds.add(callId);
    }

    Future<void> appendUnresolvedToolResults(
      List<AiToolCall> calls,
      String content,
    ) async {
      for (final call in calls) {
        final callId = toolResultId(call);
        if (handledToolCallIds.contains(callId)) continue;
        await _emit(onEvent, 'tool.failed', {
          'id': call.id,
          'call_id': callId,
          'name': call.name,
          'error': content,
        });
        addToolResult(call, _toolResultContent(content));
      }
    }

    while (!stop.isCancelled) {
      if (steps++ >= maxSteps) {
        const message = '任务达到步骤上限，请检查当前服务器状态后继续。';
        final type = remoteOperationStarted ? 'task.unknown' : 'task.failed';
        await _emit(onEvent, type, {'error': message});
        return AgentResult(
          status: remoteOperationStarted ? 'unknown' : 'failed',
          messages: List.unmodifiable(messages),
          error: StateError(message),
        );
      }
      AiMessage assistant;
      try {
        // Responses server-side compaction is the normal context policy. A
        // local character budget is retained only as an explicit caller
        // override for tests or deployments that choose one.
        if (maxContextCharacters != null) {
          _trimHistory(messages, maxContextCharacters);
        }
        assistant = await client.complete(
          messages: messages,
          tools: definitions,
          onContentDelta: (delta) {
            deltaEvents = deltaEvents.then(
              (_) => _emit(onEvent, 'assistant.delta', {'text': delta}),
            );
          },
          cancellation: stop.whenCancelled,
        );
        await deltaEvents;
      } catch (error) {
        if (stop.isCancelled) {
          final status = remoteOperationStarted ? 'unknown' : 'cancelled';
          await _emit(
            onEvent,
            status == 'unknown' ? 'task.unknown' : 'task.cancelled',
            {'error': '$error'},
          );
          return AgentResult(
            status: status,
            messages: List.unmodifiable(messages),
            error: error,
          );
        }
        final type = remoteOperationStarted ? 'task.unknown' : 'task.failed';
        await _emit(onEvent, type, {'error': '$error'});
        return AgentResult(
          status: remoteOperationStarted ? 'unknown' : 'failed',
          messages: List.unmodifiable(messages),
          error: error,
        );
      }

      if (stop.isCancelled) {
        final status = remoteOperationStarted ? 'unknown' : 'cancelled';
        await _emit(
          onEvent,
          status == 'unknown' ? 'task.unknown' : 'task.cancelled',
          const {},
        );
        return AgentResult(
          status: status,
          messages: List.unmodifiable(messages),
        );
      }
      final finishReason = assistant.finishReason;
      final isToolResponse =
          finishReason == 'tool_calls' || finishReason == 'function_call';
      final assistantForHistory =
          finishReason != null &&
              !isToolResponse &&
              assistant.toolCalls.isNotEmpty
          ? AiMessage(
              role: assistant.role,
              content: assistant.content,
              toolCallId: assistant.toolCallId,
              name: assistant.name,
              finishReason: finishReason,
              responsesOutputItems: assistant.responsesOutputItems,
              usage: assistant.usage,
            )
          : assistant;
      messages.add(assistantForHistory);
      _dropHistoryBeforeLatestCompaction(messages);
      await _emit(onEvent, 'assistant.completed', {
        'text': assistantForHistory.content ?? '',
        'wire_api': _wireApi(client),
        'tools': assistantForHistory.toolCalls
            .map((call) => _findTool(call.name)?.definition.name ?? call.name)
            .toList(),
        'tool_calls': assistantForHistory.toolCalls
            .map(
              (call) =>
                  call.toEventJson(responses: _wireApi(client) == 'responses'),
            )
            .toList(),
        'finish_reason': finishReason,
        'responses_output_items': assistantForHistory.responsesOutputItems,
        'usage': assistantForHistory.usage,
      });
      if (finishReason == 'length' ||
          finishReason == 'content_filter' ||
          finishReason == 'incomplete') {
        final message = finishReason == 'length'
            ? 'AI 回复达到长度上限，已显示已有内容；请继续任务。'
            : finishReason == 'content_filter'
            ? 'AI 回复被内容过滤器截断，未执行不完整的工具调用。'
            : 'AI 响应未完整结束，未执行不完整的工具调用。';
        final type = remoteOperationStarted ? 'task.unknown' : 'task.failed';
        await _emit(onEvent, type, {'error': message});
        return AgentResult(
          status: remoteOperationStarted ? 'unknown' : 'failed',
          messages: List.unmodifiable(messages),
          finalText: assistantForHistory.content ?? '',
          error: StateError(message),
        );
      }
      if (assistant.toolCalls.isNotEmpty &&
          finishReason != null &&
          !isToolResponse) {
        const message = 'AI 返回了未完成的工具调用，未执行。';
        final type = remoteOperationStarted ? 'task.unknown' : 'task.failed';
        await _emit(onEvent, type, {'error': message});
        return AgentResult(
          status: remoteOperationStarted ? 'unknown' : 'failed',
          messages: List.unmodifiable(messages),
          finalText: assistantForHistory.content ?? '',
          error: StateError(message),
        );
      }
      if (assistantForHistory.toolCalls.isEmpty) {
        await _emit(onEvent, 'task.completed', {
          'text': assistantForHistory.content ?? '',
        });
        return AgentResult(
          status: 'completed',
          messages: List.unmodifiable(messages),
          finalText: assistantForHistory.content ?? '',
        );
      }

      for (final call in assistantForHistory.toolCalls) {
        if (stop.isCancelled) break;
        toolCallCount++;
        if (toolCallCount > maxToolCalls) {
          const message = '任务达到工具调用上限，请检查当前服务器状态后继续。';
          await appendUnresolvedToolResults(
            assistantForHistory.toolCalls,
            message,
          );
          final type = remoteOperationStarted ? 'task.unknown' : 'task.failed';
          await _emit(onEvent, type, {'error': message});
          return AgentResult(
            status: remoteOperationStarted ? 'unknown' : 'failed',
            messages: List.unmodifiable(messages),
            error: StateError(message),
          );
        }
        final tool = _findTool(call.name);
        if (tool == null) {
          final error = 'Unknown tool: ${call.name}';
          await _emit(onEvent, 'tool.failed', {
            'id': call.id,
            'call_id': toolResultId(call),
            'name': call.name,
            'error': error,
          });
          addToolResult(call, error);
          continue;
        }
        Map<String, Object?> arguments;
        try {
          arguments = decodeObject(call.arguments);
        } catch (error) {
          final message = 'Invalid tool arguments: $error';
          await _emit(onEvent, 'tool.failed', {
            'id': call.id,
            'call_id': toolResultId(call),
            'name': call.name,
            'error': message,
          });
          addToolResult(call, message);
          continue;
        }

        await _emit(onEvent, 'tool.started', {
          'id': call.id,
          'call_id': toolResultId(call),
          'name': tool.definition.name,
          'arguments': arguments,
        });
        Future<bool> askUser() {
          return confirm == null
              ? Future.value(false)
              : Future.any<bool>([
                  confirm(tool, arguments),
                  stop.whenCancelled.then((_) => false),
                ]);
        }

        var allowed = true;
        String? deniedReason;
        if (tool.requiresUserApproval) {
          // A permission grant changes the technical boundary. It always
          // requires the person using the app, even in automatic modes.
          allowed = await askUser();
        } else if (tool.requiresConfirmation) {
          if (executionMode == 'auto') {
            allowed = true;
          } else if (executionMode == 'auto_review') {
            AgentReviewDecision decision;
            await _emit(onEvent, 'review.started', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': tool.definition.name,
            });
            try {
              final reviewFuture = review == null
                  ? Future.value(AgentReviewDecision.askUser('未配置自动审查模型'))
                  : review(tool, arguments);
              decision = await Future.any<AgentReviewDecision>([
                reviewFuture,
                stop.whenCancelled.then(
                  (_) => AgentReviewDecision.deny('任务已取消'),
                ),
              ]);
              await _emit(onEvent, 'review.completed', {
                'id': call.id,
                'call_id': toolResultId(call),
                'name': tool.definition.name,
                'decision': decision.decision,
                'reason': decision.reason,
              });
            } catch (error) {
              decision = AgentReviewDecision.askUser('自动审查失败：$error');
              await _emit(onEvent, 'review.failed', {
                'id': call.id,
                'call_id': toolResultId(call),
                'name': tool.definition.name,
                'error': '$error',
              });
            }
            if (decision.isAllow) {
              allowed = true;
            } else if (decision.isAskUser) {
              allowed = await askUser();
              if (!allowed && decision.reason.isNotEmpty) {
                deniedReason = decision.reason;
              }
            } else {
              allowed = false;
              deniedReason = decision.reason;
            }
          } else {
            allowed = await askUser();
          }
        }
        if (tool.requiresConfirmation || tool.requiresUserApproval) {
          if (stop.isCancelled) {
            const message = 'Tool call cancelled before execution.';
            await _emit(onEvent, 'tool.failed', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': call.name,
              'error': message,
            });
            addToolResult(call, message);
            break;
          }
          if (!allowed) {
            final message = deniedReason == null
                ? 'User declined this tool call.'
                : 'Tool call declined: $deniedReason';
            await _emit(onEvent, 'tool.failed', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': call.name,
              'error': message,
            });
            addToolResult(call, message);
            continue;
          }
        }

        if (stop.isCancelled) break;
        remoteOperationStarted = true;
        Future<Object?>? pendingTool;
        try {
          pendingTool = tool.call(arguments);
          final result = await Future.any<Object?>([
            pendingTool,
            stop.whenCancelled.then<Object?>((_) {
              throw StateError(
                'Task cancelled after remote execution started; result is unknown.',
              );
            }),
          ]);
          final serialized = jsonEncode(result);
          await _emit(onEvent, 'tool.completed', {
            'id': call.id,
            'call_id': toolResultId(call),
            'name': tool.definition.name,
            'result': result,
          });
          addToolResult(call, _toolResultContent(serialized));
          if (stop.isCancelled) {
            const message =
                'Task cancelled after remote execution started; result is unknown.';
            await appendUnresolvedToolResults(
              assistantForHistory.toolCalls,
              message,
            );
            await _emit(onEvent, 'task.unknown', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': call.name,
              'error': message,
            });
            return AgentResult(
              status: 'unknown',
              messages: List.unmodifiable(messages),
              error: StateError(message),
            );
          }
        } catch (error) {
          if (stop.isCancelled && pendingTool != null) {
            final future = pendingTool;
            unawaited(
              future.catchError((Object error, StackTrace stack) => null),
            );
          }
          final message = '$error';
          await _emit(onEvent, 'tool.failed', {
            'id': call.id,
            'call_id': toolResultId(call),
            'name': tool.definition.name,
            'error': message,
          });
          addToolResult(call, _toolResultContent(message));
          if (stop.isCancelled) {
            const cancellationMessage =
                'Task cancelled after remote execution started; result is unknown.';
            await appendUnresolvedToolResults(
              assistantForHistory.toolCalls,
              cancellationMessage,
            );
            await _emit(onEvent, 'task.unknown', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': call.name,
              'error': cancellationMessage,
            });
            return AgentResult(
              status: 'unknown',
              messages: List.unmodifiable(messages),
              error: error,
            );
          }
          continue;
        }
      }
      if (stop.isCancelled) {
        await appendUnresolvedToolResults(
          assistantForHistory.toolCalls,
          remoteOperationStarted
              ? 'Task cancelled after remote execution started; result is unknown.'
              : 'Tool call cancelled before execution.',
        );
      }
    }

    final status = remoteOperationStarted ? 'unknown' : 'cancelled';
    await _emit(
      onEvent,
      status == 'unknown' ? 'task.unknown' : 'task.cancelled',
      const {},
    );
    return AgentResult(status: status, messages: List.unmodifiable(messages));
  }

  AgentTool? _findTool(String name) {
    for (final tool in tools) {
      if (tool.definition.name == name ||
          tool.definition.providerName == name) {
        return tool;
      }
    }
    return null;
  }

  static Future<void> _emit(
    Future<void> Function(String type, Map<String, Object?> payload)? sink,
    String type,
    Map<String, Object?> payload,
  ) {
    return sink == null ? Future.value() : sink(type, payload);
  }

  static String _toolResultContent(String value) {
    return value;
  }

  /// A server-side compaction item carries the prior context window. Keep the
  /// system prompt and the compacted response, then let the provider receive
  /// only the new window on the next request.
  static void _dropHistoryBeforeLatestCompaction(List<AiMessage> messages) {
    var compactionIndex = -1;
    for (var index = 0; index < messages.length; index++) {
      if (messages[index].responsesOutputItems.any(
        (item) => item['type'] == 'compaction',
      )) {
        compactionIndex = index;
      }
    }
    if (compactionIndex <= 0) return;
    final retained = <AiMessage>[
      for (final message in messages.take(compactionIndex))
        if (message.role == 'system' || message.role == 'developer') message,
      ...messages.skip(compactionIndex),
    ];
    messages
      ..clear()
      ..addAll(retained);
  }

  static void _trimHistory(List<AiMessage> messages, int maxCharacters) {
    final sizes = messages
        .map((message) => jsonEncode(message.toHistoryJson()).length)
        .toList(growable: false);
    final total = sizes.fold<int>(0, (sum, value) => sum + value);
    if (total <= maxCharacters) return;

    final systemIndex = messages.indexWhere(
      (message) => message.role == 'system',
    );
    final userIndexes = <int>[
      for (var index = 0; index < messages.length; index++)
        if (messages[index].role == 'user') index,
    ];
    if (userIndexes.isEmpty) {
      throw StateError('AI context exceeds the configured limit');
    }

    var start = userIndexes.last;
    var keptSize = sizes
        .sublist(start)
        .fold<int>(0, (sum, value) => sum + value);
    if (systemIndex >= 0 && systemIndex < start) {
      keptSize += sizes[systemIndex];
    }
    if (keptSize > maxCharacters) {
      throw StateError('Current AI turn exceeds the configured context limit');
    }

    for (var index = userIndexes.length - 2; index >= 0; index--) {
      final candidate = userIndexes[index];
      final candidateSize = sizes
          .sublist(candidate, start)
          .fold<int>(0, (sum, value) => sum + value);
      if (keptSize + candidateSize > maxCharacters) break;
      start = candidate;
      keptSize += candidateSize;
    }

    final trimmed = <AiMessage>[
      if (systemIndex >= 0 && systemIndex < start) messages[systemIndex],
      ...messages.sublist(start),
    ];
    messages
      ..clear()
      ..addAll(trimmed);
  }
}

String _wireApi(AiChatClient client) {
  return client is ChatCompletionsClient ? 'chat-completions' : 'responses';
}
