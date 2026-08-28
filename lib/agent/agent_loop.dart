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

  static const _maxStructuredPreviewItems = 16;
  static const _truncatedMarkerKey = '__mobile_agent_truncated';
  static const _omittedItemsKey = '__mobile_agent_omitted_items';
  static const _omittedEntriesKey = '__mobile_agent_omitted_entries';

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
    int? toolOutputLimit,
    bool toolOutputLimitInTokens = false,
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    Future<AgentReviewDecision> Function(
      AgentTool tool,
      Map<String, Object?> arguments,
    )?
    review,
    Future<List<AiMessage>?> Function(List<AiMessage> messages)? compactHistory,
    void Function(AgentTool tool)? onRemoteOperationStarted,
    Future<void> Function(String type, Map<String, Object?> payload)? onEvent,
    bool enableTaskPlanning = false,
  }) async {
    final messages = <AiMessage>[
      ...initialMessages,
      AiMessage.user(prompt, attachments: attachments),
    ];
    final stop = cancellation ?? AgentCancellation();
    final availableTools = [
      ...tools,
      if (enableTaskPlanning &&
          !tools.any((tool) => tool.definition.name == 'update_plan'))
        AgentTool(
          definition: const AiToolDefinition(
            name: 'update_plan',
            description:
                'Updates the task plan. Provide an optional explanation and '
                'a list of plan items, each with a step and status. Use '
                'status pending, in_progress, or completed.',
            parameters: {
              'type': 'object',
              'required': ['plan'],
              'properties': {
                'explanation': {'type': 'string'},
                'plan': {
                  'type': 'array',
                  'items': {
                    'type': 'object',
                    'required': ['step', 'status'],
                    'properties': {
                      'step': {'type': 'string'},
                      'status': {
                        'type': 'string',
                        'enum': ['pending', 'in_progress', 'completed'],
                      },
                    },
                  },
                },
              },
            },
          ),
          requiresConfirmation: false,
          call: (arguments) async {
            final plan = _parseTaskPlan(arguments['plan']);
            final explanation = arguments['explanation'];
            await _emit(onEvent, 'task.plan', {
              'plan': plan,
              if (explanation is String && explanation.trim().isNotEmpty)
                'explanation': explanation.trim(),
            });
            return const {'updated': true};
          },
        ),
    ];
    final definitions = availableTools
        .map((tool) => tool.definition)
        .toList(growable: false);
    var steps = 0;
    var toolCallCount = 0;
    var remoteOperationStarted = false;
    var deltaEvents = Future<void>.value();
    final handledToolCallIds = <String>{};
    final outputCharacterLimit = _toolOutputCharacterLimit(
      toolOutputLimit,
      inTokens: toolOutputLimitInTokens,
    );

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
        addToolResult(call, _truncateToolResult(content, outputCharacterLimit));
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
        'model': _model(client),
        'tools': assistantForHistory.toolCalls
            .map(
              (call) =>
                  _findTool(availableTools, call.name)?.definition.name ??
                  call.name,
            )
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
        final tool = _findTool(availableTools, call.name);
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
                  ? Future.value(AgentReviewDecision.failure('未配置自动审查模型'))
                  : review(tool, arguments);
              decision = await Future.any<AgentReviewDecision>([
                reviewFuture,
                stop.whenCancelled.then(
                  (_) => AgentReviewDecision.deny('任务已取消'),
                ),
              ]);
              if (!decision.isFailure) {
                await _emit(onEvent, 'review.completed', {
                  'id': call.id,
                  'call_id': toolResultId(call),
                  'name': tool.definition.name,
                  'decision': decision.decision,
                  'reason': decision.reason,
                });
              }
            } catch (error) {
              decision = AgentReviewDecision.failure('自动审查失败：$error');
            }
            if (decision.isFailure) {
              await _emit(onEvent, 'review.failed', {
                'id': call.id,
                'call_id': toolResultId(call),
                'name': tool.definition.name,
                'error': decision.reason,
                'failure_code': decision.failureCode,
              });
              // Codex Guardian fails closed when the independent review cannot
              // produce a decision. The user can choose the normal confirmation
              // mode explicitly if they need to approve the action themselves.
              allowed = false;
              deniedReason = decision.reason;
            } else if (decision.isAllow) {
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
        var callOperationStarted = false;
        void markOperationStarted() {
          if (callOperationStarted || !tool.writesRemoteState) return;
          callOperationStarted = true;
          remoteOperationStarted = true;
          onRemoteOperationStarted?.call(tool);
        }

        Future<Object?>? pendingTool;
        try {
          final callWithOperationStart = tool.callWithOperationStart;
          if (callWithOperationStart == null) {
            markOperationStarted();
            pendingTool = tool.call(arguments);
          } else {
            pendingTool = callWithOperationStart(
              arguments,
              markOperationStarted,
            );
          }
          final result = await Future.any<Object?>([
            pendingTool,
            stop.whenCancelled.then<Object?>((_) {
              throw StateError(
                callOperationStarted
                    ? 'Task cancelled after remote execution started; result is unknown.'
                    : 'Task cancelled before tool execution completed.',
              );
            }),
          ]);
          final eventResult = _boundedToolResultValue(
            result,
            outputCharacterLimit,
          );
          final serialized = jsonEncode(eventResult);
          await _emit(onEvent, 'tool.completed', {
            'id': call.id,
            'call_id': toolResultId(call),
            'name': tool.definition.name,
            'result': eventResult,
          });
          addToolResult(call, _toolResultContent(serialized));
          if (stop.isCancelled) {
            final isUnknown = remoteOperationStarted;
            final message = isUnknown
                ? 'Task cancelled after remote execution started; result is unknown.'
                : 'Task cancelled during local tool execution.';
            await appendUnresolvedToolResults(
              assistantForHistory.toolCalls,
              message,
            );
            await _emit(
              onEvent,
              isUnknown ? 'task.unknown' : 'task.cancelled',
              {
                'id': call.id,
                'call_id': toolResultId(call),
                'name': call.name,
                'error': message,
              },
            );
            return AgentResult(
              status: isUnknown ? 'unknown' : 'cancelled',
              messages: List.unmodifiable(messages),
              error: isUnknown ? StateError(message) : null,
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
          addToolResult(
            call,
            _truncateToolResult(message, outputCharacterLimit),
          );
          if (stop.isCancelled) {
            final isUnknown = remoteOperationStarted;
            final cancellationMessage = isUnknown
                ? 'Task cancelled after remote execution started; result is unknown.'
                : 'Task cancelled during local tool execution.';
            await appendUnresolvedToolResults(
              assistantForHistory.toolCalls,
              cancellationMessage,
            );
            await _emit(
              onEvent,
              isUnknown ? 'task.unknown' : 'task.cancelled',
              {
                'id': call.id,
                'call_id': toolResultId(call),
                'name': call.name,
                'error': cancellationMessage,
              },
            );
            return AgentResult(
              status: isUnknown ? 'unknown' : 'cancelled',
              messages: List.unmodifiable(messages),
              error: isUnknown ? error : null,
            );
          }
          if (callOperationStarted) {
            const unknownMessage =
                'Remote write tool failed; the final server state is unknown.';
            await appendUnresolvedToolResults(
              assistantForHistory.toolCalls,
              unknownMessage,
            );
            await _emit(onEvent, 'task.unknown', {
              'id': call.id,
              'call_id': toolResultId(call),
              'name': call.name,
              'error': unknownMessage,
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

      if (!stop.isCancelled && compactHistory != null) {
        try {
          final compacted = await compactHistory(messages);
          if (compacted != null) {
            messages
              ..clear()
              ..addAll(compacted);
          }
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

  AgentTool? _findTool(List<AgentTool> availableTools, String name) {
    for (final tool in availableTools) {
      if (tool.definition.name == name ||
          tool.definition.providerName == name) {
        return tool;
      }
    }
    return null;
  }

  static List<Map<String, Object?>> _parseTaskPlan(Object? value) {
    if (value is! List) {
      throw const FormatException('update_plan requires a plan list');
    }
    final plan = <Map<String, Object?>>[];
    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('each plan item must be an object');
      }
      final step = item['step'];
      final status = item['status'];
      if (step is! String || step.trim().isEmpty) {
        throw const FormatException('each plan item needs a step');
      }
      if (status != 'pending' &&
          status != 'in_progress' &&
          status != 'completed') {
        throw const FormatException('plan item status is invalid');
      }
      plan.add({'step': step.trim(), 'status': status});
    }
    return plan;
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

  static int? _toolOutputCharacterLimit(int? limit, {required bool inTokens}) {
    if (limit == null || limit <= 0) return null;
    final characters = inTokens ? limit * 4 : limit;
    return characters > 0 ? characters : null;
  }

  static String _truncateToolResult(String value, int? limit) {
    if (limit == null || _utf8Length(value) <= limit) return value;
    const marker = '\n[…tool output truncated…]\n';
    final markerLength = _utf8Length(marker);
    if (markerLength >= limit) return _utf8Prefix(value, limit);
    final contentLimit = limit - markerLength;
    final headLimit = contentLimit ~/ 2;
    final tailLimit = contentLimit - headLimit;
    return '${_utf8Prefix(value, headLimit)}$marker'
        '${_utf8Suffix(value, tailLimit)}';
  }

  static Object? _boundedToolResultValue(Object? value, int? limit) {
    if (limit == null) return value;
    return _boundToolResultValue(value, limit);
  }

  static Object? _boundToolResultValue(Object? value, int limit) {
    if (value is String) return _truncateToolResult(value, limit);
    if (value is List) {
      final items = [
        for (final item in value)
          if (!_isListTruncationMarker(item)) item,
      ];
      final originalItemCount = _listOriginalItemCount(value);
      final visibleCount = items.length;
      final childLimit = _childToolOutputLimit(
        limit,
        visibleCount <= _maxStructuredPreviewItems
            ? visibleCount
            : _maxStructuredPreviewItems,
      );
      if (visibleCount <= _maxStructuredPreviewItems) {
        return _fitBoundedToolValue([
          for (final item in items) _boundToolResultValue(item, childLimit),
          if (originalItemCount > visibleCount)
            {
              _truncatedMarkerKey: true,
              _omittedItemsKey: originalItemCount - visibleCount,
            },
        ], limit);
      }
      final headCount = _maxStructuredPreviewItems ~/ 2;
      final tailCount = _maxStructuredPreviewItems - headCount;
      return _fitBoundedToolValue([
        for (var index = 0; index < headCount; index++)
          _boundToolResultValue(items[index], childLimit),
        {
          _truncatedMarkerKey: true,
          _omittedItemsKey: originalItemCount - headCount - tailCount,
        },
        for (
          var index = visibleCount - tailCount;
          index < visibleCount;
          index++
        )
          _boundToolResultValue(items[index], childLimit),
      ], limit);
    }
    if (value is Map) {
      final entries = [
        for (final entry in value.entries)
          if (!_isMapTruncationMarkerEntry(entry)) entry,
      ];
      final originalEntryCount = _mapOriginalEntryCount(value);
      final visibleCount = entries.length;
      final childLimit = _childToolOutputLimit(
        limit,
        visibleCount <= _maxStructuredPreviewItems
            ? visibleCount
            : _maxStructuredPreviewItems,
      );
      if (visibleCount <= _maxStructuredPreviewItems) {
        return _fitBoundedToolValue({
          for (final entry in entries)
            '${entry.key}': _boundToolResultValue(entry.value, childLimit),
          if (originalEntryCount > visibleCount) ...{
            _truncatedMarkerKey: true,
            _omittedEntriesKey: originalEntryCount - visibleCount,
          },
        }, limit);
      }
      final headCount = _maxStructuredPreviewItems ~/ 2;
      final tailCount = _maxStructuredPreviewItems - headCount;
      return _fitBoundedToolValue({
        for (var index = 0; index < headCount; index++)
          '${entries[index].key}': _boundToolResultValue(
            entries[index].value,
            childLimit,
          ),
        _truncatedMarkerKey: true,
        _omittedEntriesKey: originalEntryCount - headCount - tailCount,
        for (
          var index = visibleCount - tailCount;
          index < visibleCount;
          index++
        )
          '${entries[index].key}': _boundToolResultValue(
            entries[index].value,
            childLimit,
          ),
      }, limit);
    }
    return value;
  }

  static int _childToolOutputLimit(int limit, int itemCount) {
    if (itemCount <= 0) return limit;
    final share = limit ~/ itemCount;
    return share < 32 ? 32 : share;
  }

  static Object? _fitBoundedToolValue(Object? value, int limit) {
    if (_jsonUtf8Length(value) <= limit) return value;
    if (value is List) {
      final originalItemCount = _listOriginalItemCount(value);
      final entries = value.toList(growable: false);
      var keep = entries.length;
      while (keep > 0) {
        final headCount = keep ~/ 2;
        final tailCount = keep - headCount;
        final childLimit = _childToolOutputLimit(limit, keep);
        final selected = <Object?>[
          for (var index = 0; index < headCount; index++) entries[index],
          for (
            var index = entries.length - tailCount;
            index < entries.length;
            index++
          )
            entries[index],
        ];
        final selectedVisibleItemCount = selected.fold<int>(
          0,
          (sum, item) => sum + (_isListTruncationMarker(item) ? 0 : 1),
        );
        final omitted = originalItemCount - selectedVisibleItemCount;
        final head = <Object?>[];
        final tail = <Object?>[];
        for (final item in selected.take(headCount)) {
          if (!_isListTruncationMarker(item)) {
            head.add(_boundToolResultValue(item, childLimit));
          }
        }
        for (final item in selected.skip(headCount)) {
          if (!_isListTruncationMarker(item)) {
            tail.add(_boundToolResultValue(item, childLimit));
          }
        }
        final candidate = <Object?>[
          ...head,
          if (omitted > 0)
            {_truncatedMarkerKey: true, _omittedItemsKey: omitted},
          ...tail,
        ];
        if (_jsonUtf8Length(candidate) <= limit) return candidate;
        if (keep == 1) break;
        keep = keep ~/ 2;
      }
      if (_jsonUtf8Length({
            _truncatedMarkerKey: true,
            _omittedItemsKey: originalItemCount,
          }) <=
          limit) {
        return [
          {_truncatedMarkerKey: true, _omittedItemsKey: originalItemCount},
        ];
      }
      return [_truncateToolResult(jsonEncode(value), limit)];
    }
    if (value is Map) {
      final entries = [
        for (final entry in value.entries)
          if (!_isMapTruncationMarkerEntry(entry)) entry,
      ];
      final originalEntryCount = _mapOriginalEntryCount(value);
      var keep = entries.length;
      while (keep > 0) {
        final headCount = keep ~/ 2;
        final tailCount = keep - headCount;
        final childLimit = _childToolOutputLimit(limit, keep);
        final omitted = originalEntryCount - keep;
        final candidate = <String, Object?>{};
        for (var index = 0; index < headCount; index++) {
          final entry = entries[index];
          candidate['${entry.key}'] = _boundToolResultValue(
            entry.value,
            childLimit,
          );
        }
        if (omitted > 0) {
          candidate[_truncatedMarkerKey] = true;
          candidate[_omittedEntriesKey] = omitted;
        }
        for (
          var index = entries.length - tailCount;
          index < entries.length;
          index++
        ) {
          final entry = entries[index];
          candidate['${entry.key}'] = _boundToolResultValue(
            entry.value,
            childLimit,
          );
        }
        if (_jsonUtf8Length(candidate) <= limit) return candidate;
        if (keep == 1) break;
        keep = keep ~/ 2;
      }
      final marker = {
        _truncatedMarkerKey: true,
        _omittedEntriesKey: originalEntryCount,
      };
      if (_jsonUtf8Length(marker) <= limit) return marker;
      return _truncateToolResult(jsonEncode(value), limit);
    }
    return _truncateToolResult(jsonEncode(value), limit);
  }

  static bool _isListTruncationMarker(Object? value) {
    if (value is! Map) return false;
    return value[_truncatedMarkerKey] == true &&
        value[_omittedItemsKey] is int &&
        (value[_omittedItemsKey] as int) > 0;
  }

  static int _listItemRepresentationCount(Object? value) {
    if (_isListTruncationMarker(value)) {
      return (value as Map)[_omittedItemsKey] as int;
    }
    return 1;
  }

  static int _listOriginalItemCount(List value) {
    return value.fold<int>(
      0,
      (sum, item) => sum + _listItemRepresentationCount(item),
    );
  }

  static bool _isMapTruncationMarkerEntry(MapEntry<dynamic, dynamic> entry) {
    return entry.key == _truncatedMarkerKey || entry.key == _omittedEntriesKey;
  }

  static int _mapOriginalEntryCount(Map value) {
    final omitted = value[_omittedEntriesKey];
    final omittedCount = omitted is int && omitted > 0 ? omitted : 0;
    final visible = value.keys
        .where((key) => key != _truncatedMarkerKey && key != _omittedEntriesKey)
        .length;
    return visible + omittedCount;
  }

  static int _jsonUtf8Length(Object? value) {
    return utf8.encode(jsonEncode(value)).length;
  }

  static int _utf8Length(String value) => utf8.encode(value).length;

  static String _utf8Prefix(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    final result = StringBuffer();
    var used = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final size = _utf8Length(character);
      if (used + size > maxBytes) break;
      result.write(character);
      used += size;
    }
    return result.toString();
  }

  static String _utf8Suffix(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    final selected = <int>[];
    var used = 0;
    for (final rune in value.runes.toList().reversed) {
      final character = String.fromCharCode(rune);
      final size = _utf8Length(character);
      if (used + size > maxBytes) break;
      selected.add(rune);
      used += size;
    }
    return String.fromCharCodes(selected.reversed);
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

String _model(AiChatClient client) {
  if (client is ChatCompletionsClient) return client.model;
  if (client is OpenAiCompatibleClient) return client.model;
  return '';
}
