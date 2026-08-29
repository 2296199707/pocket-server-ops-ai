import 'dart:async';

import '../domain/models.dart';
import 'ai_protocol.dart';
import 'agent_loop.dart';
import 'agent_tools.dart';

typedef SubagentPrepare = Future<void> Function(
  SubagentNode node, {
  required bool followup,
});

typedef SubagentStart = Future<AgentResult> Function(
  SubagentNode node,
  String prompt,
);

typedef SubagentEventSink = Future<void> Function(
  SubagentNode node,
  String type,
  Map<String, Object?> payload,
);

typedef SubagentInterrupt = Future<void> Function(SubagentNode node);

class SubagentNode {
  SubagentNode({
    required this.id,
    required this.rootTaskId,
    required this.parentId,
    required this.taskName,
    required this.depth,
    required this.providerId,
    required this.model,
    required this.reasoningEffort,
  });

  final String id;
  final String rootTaskId;
  final String parentId;
  final String taskName;
  final int depth;
  final String? providerId;
  final String? model;
  final String? reasoningEffort;
  String status = 'pending';
  String summary = '';
  DateTime updatedAt = DateTime.now().toUtc();
  Future<AgentResult>? run;
  Future<void>? observation;
  Completer<void>? startSettled;
  bool cancelRequested = false;
  final List<String> mailbox = [];

  bool get isActive =>
      status == 'pending' || status == 'running' || status == 'waiting';

  bool get isTerminal => !isActive;
}

/// Small, root-scoped control plane for the mobile subagent tool set.
///
/// The tree does not know how a task talks to a provider or operates files.
/// Those concerns stay in AppController; this class only owns agent identity,
/// lifecycle, mailbox semantics, and the shared concurrency/depth settings.
class SubagentTree {
  SubagentTree({
    required this.rootTaskId,
    required this.settings,
    required this._prepare,
    required this._start,
    required this._onEvent,
    required this._interrupt,
  }) {
    _nodes[rootTaskId] = SubagentNode(
      id: rootTaskId,
      rootTaskId: rootTaskId,
      parentId: '',
      taskName: 'root',
      depth: 0,
      providerId: null,
      model: null,
      reasoningEffort: null,
    )..status = 'running';
  }

  static const minWaitTimeout = Duration(seconds: 10);
  static const maxWaitTimeout = Duration(hours: 1);
  static const defaultWaitTimeout = Duration(seconds: 30);

  final String rootTaskId;
  SubagentSettings settings;
  final SubagentPrepare _prepare;
  final SubagentStart _start;
  final SubagentEventSink _onEvent;
  final SubagentInterrupt _interrupt;
  final Map<String, SubagentNode> _nodes = {};
  final Set<Future<void>> _operations = {};
  int _idSequence = 0;
  bool _closed = false;
  bool _cancelling = false;
  Future<void>? _cancelAllFuture;

  SubagentNode? nodeFor(String id) => _nodes[id];

  List<SubagentNode> get agents => [
    for (final node in _nodes.values)
      if (node.id != rootTaskId) node,
  ];

  bool get hasActiveAgents => agents.any((node) => node.isActive);

  bool get isClosed => _closed;

  /// Apply settings for the next spawn. Existing active children keep their
  /// current provider/model; a later child uses the latest conversation
  /// settings once the current children are idle.
  void updateSettings(SubagentSettings value) {
    if (!hasActiveAgents) settings = value;
  }

  Future<void> cancelAll({bool close = false}) {
    if (close) _closed = true;
    final existing = _cancelAllFuture;
    if (existing != null) return existing;
    late Future<void> current;
    current = _cancelAll();
    _cancelAllFuture = current;
    unawaited(
      current.whenComplete(() {
        if (identical(_cancelAllFuture, current)) _cancelAllFuture = null;
      }),
    );
    return current;
  }

  Future<void> close() => cancelAll(close: true);

  Future<void> _cancelAll() async {
    _cancelling = true;
    try {
      while (true) {
        final active = agents.where((node) => node.isActive).toList()
          ..sort((left, right) => right.depth.compareTo(left.depth));
        for (final node in active) {
          node.cancelRequested = true;
          try {
            await _interrupt(node);
          } catch (_) {
            // Keep cancelling the rest of the tree if one task is already gone.
          }
        }
        await _waitForAll();
        if (!hasActiveAgents && _operations.isEmpty) return;
      }
    } finally {
      _cancelling = false;
    }
  }

  Future<void> waitForChildren() => _waitFor(agents);

  Future<void> _waitFor(Iterable<SubagentNode> nodes) async {
    while (true) {
      final pending = <Future<void>>[];
      for (final node in nodes) {
        if (node.isActive) _addNodeWaitFuture(node, pending);
      }
      if (pending.isEmpty) return;
      await Future.wait(pending, eagerError: false);
    }
  }

  Future<void> _waitForAll() async {
    while (true) {
      final pending = <Future<void>>[..._operations];
      for (final node in agents) {
        if (node.isActive) _addNodeWaitFuture(node, pending);
      }
      if (pending.isEmpty) return;
      await Future.wait(pending, eagerError: false);
    }
  }

  static void _addNodeWaitFuture(
    SubagentNode node,
    List<Future<void>> pending,
  ) {
    final observation = node.observation;
    if (observation != null) {
      pending.add(observation.catchError((_) {}));
      return;
    }
    final run = node.run;
    if (run != null) {
      pending.add(run.then<void>((_) {}, onError: (_, _) {}));
      return;
    }
    final startSettled = node.startSettled;
    if (startSettled != null && !startSettled.isCompleted) {
      pending.add(startSettled.future);
    }
  }

  List<AgentTool> toolsFor(String parentId) {
    final parent = _nodes[parentId];
    if (parent == null) return const [];
    return [
      AgentTool(
        definition: const AiToolDefinition(
          name: 'spawn_agent',
          description:
              'Create a child agent with an independent history. The child '
              'runs concurrently and returns a short completion summary. '
              'Use task_name with lowercase letters, digits, underscores, or '
              'hyphens. The configured subagent model and reasoning settings '
              'are applied automatically.',
          parameters: {
            'type': 'object',
            'required': ['task_name', 'message'],
            'properties': {
              'task_name': {
                'type': 'string',
                'description':
                    'Lowercase task name, unique among this agent children.',
              },
              'message': {'type': 'string'},
            },
          },
        ),
        call: (arguments) => _track(_spawn(parent, arguments)),
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'send_message',
          description:
              'Send a mailbox message to an existing child agent. This does '
              'not start a new turn; use followup_task when the child should '
              'act on the message.',
          parameters: {
            'type': 'object',
            'required': ['target', 'message'],
            'properties': {
              'target': {'type': 'string'},
              'message': {'type': 'string'},
            },
          },
        ),
        call: _sendMessage,
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'followup_task',
          description:
              'Start a new turn for an existing child agent. A running child '
              'receives the message in its mailbox for a later follow-up.',
          parameters: {
            'type': 'object',
            'required': ['target', 'message'],
            'properties': {
              'target': {'type': 'string'},
              'message': {'type': 'string'},
            },
          },
        ),
        call: (arguments) => _track(_followup(arguments)),
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'wait_agent',
          description:
              'Wait for one or more child agents to finish or for the wait '
              'timeout. Returns statuses and short summaries, never the full '
              'child transcript.',
          parameters: {
            'type': 'object',
            'properties': {
              'target': {'type': 'string'},
              'targets': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'timeout_ms': {
                'type': 'integer',
                'minimum': 0,
                'maximum': 3600000,
              },
            },
          },
        ),
        call: _wait,
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'list_agents',
          description: 'List child agents and their current status.',
          parameters: {'type': 'object', 'properties': {}},
        ),
        call: (_) async => {'agents': _agentMaps()},
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'interrupt_agent',
          description:
              'Interrupt the current turn of a child agent. The child remains '
              'available for a later follow-up task.',
          parameters: {
            'type': 'object',
            'required': ['target'],
            'properties': {
              'target': {'type': 'string'},
            },
          },
        ),
        call: _interruptAgent,
        requiresConfirmation: false,
      ),
    ];
  }

  Future<T> _track<T>(Future<T> operation) {
    final settled = operation.then<void>((_) {}, onError: (_, _) {});
    _operations.add(settled);
    unawaited(
      settled.then<void>((_) {
        _operations.remove(settled);
      }),
    );
    return operation;
  }

  Future<Object?> _spawn(
    SubagentNode parent,
    Map<String, Object?> arguments,
  ) async {
    if (_closed || _cancelling) throw StateError('子代理树正在关闭或停止');
    if (!parent.isActive) throw StateError('父代理当前不可创建子代理');
    final taskName = _requiredText(arguments, 'task_name');
    final message = _requiredText(arguments, 'message');
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$').hasMatch(taskName)) {
      throw ArgumentError(
        'task_name must use lowercase letters, digits, underscores, or hyphens',
      );
    }
    if (message.trim().isEmpty) throw ArgumentError('message is required');
    if (parent.depth >= settings.maxRecursionDepth) {
      throw StateError('已达到子代理递归深度 ${settings.maxRecursionDepth}');
    }
    final activeCount = _nodes.values
        .where((node) => node.id != rootTaskId && node.isActive)
        .length;
    if (activeCount >= settings.maxConcurrentThreads) {
      throw StateError('子代理并发线程已达到 ${settings.maxConcurrentThreads}');
    }
    if (_nodes.values.any(
      (node) => node.parentId == parent.id && node.taskName == taskName,
    )) {
      throw StateError('当前代理下已存在任务 $taskName');
    }

    final node = SubagentNode(
      id: _newId(),
      rootTaskId: rootTaskId,
      parentId: parent.id,
      taskName: taskName,
      depth: parent.depth + 1,
      providerId: settings.providerId.trim().isEmpty
          ? null
          : settings.providerId.trim(),
      model: settings.model.trim().isEmpty ? null : settings.model.trim(),
      reasoningEffort: settings.reasoningEffort == defaultReasoningEffort
          ? null
          : settings.reasoningEffort,
    );
    _nodes[node.id] = node;
    final startSettled = Completer<void>();
    node.startSettled = startSettled;
    try {
      await _prepare(node, followup: false);
      if (_closed || _cancelling || node.cancelRequested) {
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'task_name': node.taskName,
          'status': node.status,
        });
        if (_closed) throw StateError('子代理树已关闭');
        return _agentMap(node);
      }
      node.status = 'running';
      await _emit(node, 'subagent.started', {
        'agent_id': node.id,
        'task_name': node.taskName,
        'parent_id': node.parentId,
        'depth': node.depth,
        if (node.providerId != null) 'provider_id': node.providerId,
        if (node.model != null) 'model': node.model,
        if (node.reasoningEffort != null)
          'reasoning_effort': node.reasoningEffort,
      });
      if (_closed || _cancelling || node.cancelRequested) {
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'task_name': node.taskName,
          'status': node.status,
        });
        if (_closed) throw StateError('子代理树已关闭');
        return _agentMap(node);
      }
      final run = _start(node, message.trim());
      node.run = run;
      final observation = _observe(node, run);
      node.observation = observation;
      unawaited(observation);
      return _agentMap(node);
    } catch (_) {
      if (node.run != null && node.isActive) {
        try {
          await _interrupt(node);
        } catch (_) {}
      }
      _nodes.remove(node.id);
      rethrow;
    } finally {
      if (!startSettled.isCompleted) startSettled.complete();
    }
  }

  Future<Object?> _sendMessage(Map<String, Object?> arguments) async {
    if (_closed) throw StateError('子代理树已关闭');
    final node = _target(arguments['target']);
    final message = _requiredText(arguments, 'message');
    if (message.trim().isEmpty) throw ArgumentError('message is required');
    node.mailbox.add(message.trim());
    node.updatedAt = DateTime.now().toUtc();
    await _emit(node, 'subagent.message', {
      'agent_id': node.id,
      'task_name': node.taskName,
      'message_queued': true,
    });
    return {
      'agent_id': node.id,
      'task_name': node.taskName,
      'queued': true,
      'starts_turn': false,
    };
  }

  Future<Object?> _followup(Map<String, Object?> arguments) async {
    if (_closed || _cancelling) throw StateError('子代理树正在关闭或停止');
    final node = _target(arguments['target']);
    final message = _requiredText(arguments, 'message');
    if (message.trim().isEmpty) throw ArgumentError('message is required');
    if (node.isActive) {
      node.mailbox.add(message.trim());
      return {
        'agent_id': node.id,
        'task_name': node.taskName,
        'queued': true,
        'starts_turn': false,
      };
    }
    final activeCount = _nodes.values
        .where((item) => item.id != rootTaskId && item.isActive)
        .length;
    if (activeCount >= settings.maxConcurrentThreads) {
      throw StateError('子代理并发线程已达到 ${settings.maxConcurrentThreads}');
    }
    final previousStatus = node.status;
    final queued = List<String>.of(node.mailbox);
    node.mailbox.clear();
    final prompt = [...queued, message.trim()].join('\n\n');
    node.cancelRequested = false;
    node.status = 'pending';
    node.run = null;
    node.observation = null;
    node.updatedAt = DateTime.now().toUtc();
    final startSettled = Completer<void>();
    node.startSettled = startSettled;
    try {
      await _prepare(node, followup: true);
      if (_closed || _cancelling || node.cancelRequested) {
        node.mailbox.insertAll(0, [...queued, message.trim()]);
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'task_name': node.taskName,
          'status': node.status,
        });
        return {
          ..._agentMap(node),
          'queued': false,
          'starts_turn': false,
          'interrupted': true,
        };
      }
      node.status = 'running';
      await _emit(node, 'subagent.started', {
        'agent_id': node.id,
        'task_name': node.taskName,
        'parent_id': node.parentId,
        'depth': node.depth,
        if (node.providerId != null) 'provider_id': node.providerId,
        'followup': true,
      });
      if (_closed || _cancelling || node.cancelRequested) {
        node.mailbox.insertAll(0, [...queued, message.trim()]);
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'task_name': node.taskName,
          'status': node.status,
        });
        return {
          ..._agentMap(node),
          'queued': false,
          'starts_turn': false,
          'interrupted': true,
        };
      }
      final run = _start(node, prompt);
      node.run = run;
      final observation = _observe(node, run);
      node.observation = observation;
      unawaited(observation);
      return {
        'agent_id': node.id,
        'task_name': node.taskName,
        'queued': false,
        'starts_turn': true,
      };
    } catch (_) {
      if (node.run != null && node.isActive) {
        try {
          await _interrupt(node);
        } catch (_) {}
      }
      if (node.isActive) {
        node.status = previousStatus;
        node.updatedAt = DateTime.now().toUtc();
      }
      node.mailbox.insertAll(0, [...queued, message.trim()]);
      rethrow;
    } finally {
      if (!startSettled.isCompleted) startSettled.complete();
    }
  }

  Future<Object?> _wait(Map<String, Object?> arguments) async {
    final targets = <SubagentNode>[];
    final target = arguments['target'];
    final targetList = arguments['targets'];
    if (target is String && target.trim().isNotEmpty) {
      targets.add(_target(target));
    }
    if (targetList is List) {
      for (final value in targetList) {
        if (value is String && value.trim().isNotEmpty) {
          final node = _target(value);
          if (!targets.contains(node)) targets.add(node);
        }
      }
    }
    if (targets.isEmpty) targets.addAll(agents);
    final timeout = _waitDuration(arguments['timeout_ms']);
    var timedOut = false;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final pending = <Future<void>>[];
      for (final node in targets) {
        if (node.isActive) _addNodeWaitFuture(node, pending);
      }
      if (pending.isEmpty) break;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        timedOut = true;
        break;
      }
      try {
        await Future.wait(pending, eagerError: false).timeout(remaining);
      } on TimeoutException {
        timedOut = true;
        break;
      }
    }
    return {
      'timed_out': timedOut,
      'agents': [for (final node in targets) _agentMap(node)],
    };
  }

  Future<Object?> _interruptAgent(Map<String, Object?> arguments) async {
    final node = _target(arguments['target']);
    if (!node.isActive) return {..._agentMap(node), 'interrupted': false};
    node.cancelRequested = true;
    await _interrupt(node);
    return {..._agentMap(node), 'interrupted': true};
  }

  Future<void> _observe(SubagentNode node, Future<AgentResult> run) async {
    AgentResult result;
    try {
      result = await run;
    } catch (error) {
      node.status = 'failed';
      node.summary = '$error';
      node.updatedAt = DateTime.now().toUtc();
      await _emit(node, 'subagent.failed', {
        'agent_id': node.id,
        'task_name': node.taskName,
        'status': node.status,
        'summary': node.summary,
      });
      return;
    }
    node.status = switch (result.status) {
      'completed' => 'completed',
      'cancelled' || 'canceled' => 'interrupted',
      'unknown' => 'unknown',
      _ => 'failed',
    };
    node.summary = _summary(result.finalText);
    if (node.summary.isEmpty && result.error != null) {
      node.summary = _summary('${result.error}');
    }
    node.updatedAt = DateTime.now().toUtc();
    final eventType = switch (node.status) {
      'completed' => 'subagent.completed',
      'interrupted' => 'subagent.interrupted',
      'unknown' => 'subagent.unknown',
      _ => 'subagent.failed',
    };
    await _emit(node, eventType, {
      'agent_id': node.id,
      'task_name': node.taskName,
      'status': node.status,
      if (node.summary.isNotEmpty) 'summary': node.summary,
    });
  }

  SubagentNode _target(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('target is required');
    }
    final target = value.trim();
    if (target == rootTaskId) throw StateError('不能操作根代理');
    for (final node in agents) {
      if (node.id == target ||
          node.taskName == target ||
          node.id.endsWith('/$target')) {
        return node;
      }
    }
    throw StateError('找不到子代理 $target');
  }

  List<Map<String, Object?>> _agentMaps() => [
    for (final node in agents) _agentMap(node),
  ];

  Map<String, Object?> _agentMap(SubagentNode node) => {
    'agent_id': node.id,
    'task_name': node.taskName,
    'parent_id': node.parentId,
    'depth': node.depth,
    'status': node.status,
    if (node.providerId != null) 'provider_id': node.providerId,
    if (node.summary.isNotEmpty) 'summary': node.summary,
  };

  Future<void> _emit(
    SubagentNode node,
    String type,
    Map<String, Object?> payload,
  ) => _onEvent(node, type, payload);

  String _newId() {
    _idSequence++;
    return 'agent-${DateTime.now().microsecondsSinceEpoch}-$_idSequence';
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String) throw ArgumentError('$key is required');
    return value;
  }

  static Duration _waitDuration(Object? value) {
    final requested = value is num ? value.toInt() : null;
    if (requested == null) return defaultWaitTimeout;
    final duration = Duration(milliseconds: requested);
    if (duration < minWaitTimeout) return minWaitTimeout;
    if (duration > maxWaitTimeout) return maxWaitTimeout;
    return duration;
  }

  static String _summary(String text) {
    final value = text.trim();
    if (value.length <= 1200) return value;
    return '${value.substring(0, 1197)}...';
  }
}
