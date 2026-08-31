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

typedef SubagentDiscard = Future<void> Function(SubagentNode node);

typedef SubagentStateChanged = FutureOr<void> Function(SubagentNode node);

class SubagentNode {
  SubagentNode({
    required this.id,
    required this.rootTaskId,
    required this.parentId,
    required this.taskName,
    required this.agentPath,
    required this.depth,
    required this.providerId,
    required this.model,
    required this.reasoningEffort,
    this.role = defaultSubagentRole,
    this.forkTurns = 'all',
    Iterable<String> mailbox = const [],
  }) : mailbox = List<String>.of(mailbox);

  final String id;
  final String rootTaskId;
  final String parentId;
  final String taskName;
  final String agentPath;
  final int depth;
  final String? providerId;
  final String? model;
  final String? reasoningEffort;
  final String role;
  final String forkTurns;
  String status = 'pending';
  String summary = '';
  DateTime updatedAt = DateTime.now().toUtc();
  String? parentTurnId;
  String? activeTurnId;
  String? lastEventType;
  Future<AgentResult>? run;
  Future<void>? observation;
  Completer<void>? startSettled;
  bool cancelRequested = false;
  bool followupPending = false;
  // Set when shutdown could not prove that the underlying run settled. A late
  // result must not make an uncertain lifecycle look completed.
  bool lifecycleUnknown = false;
  Completer<void>? lifecycleChange;
  final List<String> mailbox;

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
    this.lifecycleTimeout = const Duration(seconds: 5),
    this._discard,
    this._onStateChanged,
    Iterable<SubagentNode> restoredNodes = const [],
  }) {
    _nodes[rootTaskId] = SubagentNode(
      id: rootTaskId,
      rootTaskId: rootTaskId,
      parentId: '',
      taskName: 'root',
      agentPath: '/root',
      depth: 0,
      providerId: null,
      model: null,
      reasoningEffort: null,
    )..status = 'running';
    for (final node in restoredNodes) {
      restoreNode(node);
    }
  }

  static const _defaultWaitTimeout = Duration(seconds: 30);
  static const _maxWaitTimeout = Duration(hours: 1);

  final String rootTaskId;
  final Duration lifecycleTimeout;
  SubagentSettings settings;
  SubagentPrepare _prepare;
  SubagentStart _start;
  SubagentEventSink _onEvent;
  SubagentInterrupt _interrupt;
  SubagentDiscard? _discard;
  SubagentStateChanged? _onStateChanged;
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

  /// Restored trees are created before a turn has UI callbacks. The next
  /// active run refreshes these handlers with the current confirmation and
  /// host-key callbacks without replacing the restored nodes.
  void updateHandlers({
    required SubagentPrepare prepare,
    required SubagentStart start,
    required SubagentEventSink onEvent,
    required SubagentInterrupt interrupt,
    SubagentDiscard? discard,
    SubagentStateChanged? onStateChanged,
  }) {
    _prepare = prepare;
    _start = start;
    _onEvent = onEvent;
    _interrupt = interrupt;
    _discard = discard;
    _onStateChanged = onStateChanged;
  }

  void restoreNode(SubagentNode node) {
    if (node.id == rootTaskId || node.rootTaskId != rootTaskId) return;
    _nodes[node.id] = node;
  }

  void setActiveTurn(String agentId, String? turnId) {
    final node = _nodes[agentId];
    if (node == null) return;
    node.activeTurnId = turnId;
  }

  void clearActiveTurn(String agentId, String turnId) {
    final node = _nodes[agentId];
    if (node != null && node.activeTurnId == turnId) {
      node.activeTurnId = null;
    }
  }

  void updateNodeStatus(String agentId, String status) {
    final node = _nodes[agentId];
    if (node == null || !node.isActive) return;
    if (status != 'pending' && status != 'running' && status != 'waiting') {
      return;
    }
    node.status = status;
    node.updatedAt = DateTime.now().toUtc();
  }

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
    final deadline = DateTime.now().add(lifecycleTimeout);
    try {
      while (true) {
        final active = agents.where((node) => node.isActive).toList()
          ..sort((left, right) => right.depth.compareTo(left.depth));
        if (active.isEmpty && _operations.isEmpty) return;
        var remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          _markUnknownForCleanup(agents);
          return;
        }
        for (final node in active) {
          node.cancelRequested = true;
          try {
            await _interrupt(node).timeout(remaining);
          } on TimeoutException {
            _markUnknown(node, '停止请求超时，远程状态未知');
          } catch (_) {
            // Keep cancelling the rest of the tree if one task is already gone.
          }
          remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) break;
        }
        remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          _markUnknownForCleanup(agents);
          return;
        }
        final settled = await _waitForAll(timeout: remaining);
        if (!settled) {
          _markUnknownForCleanup(agents);
          return;
        }
      }
    } finally {
      _cancelling = false;
    }
  }

  Future<void> waitForChildren() async {
    await _waitFor(agents);
  }

  Future<bool> _waitFor(
    Iterable<SubagentNode> nodes, {
    Duration? timeout,
  }) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (true) {
      final pending = <Future<void>>[];
      for (final node in nodes) {
        if (_hasPendingWork(node)) _addNodeWaitFuture(node, pending);
      }
      if (pending.isEmpty) return true;
      if (deadline == null) {
        await Future.wait(pending, eagerError: false);
        continue;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      try {
        await Future.wait(pending, eagerError: false).timeout(remaining);
      } on TimeoutException {
        return false;
      }
    }
  }

  Future<bool> _waitForAll({Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (true) {
      final pending = <Future<void>>[..._operations];
      for (final node in agents) {
        if (_hasPendingWork(node)) _addNodeWaitFuture(node, pending);
      }
      if (pending.isEmpty) return true;
      if (deadline == null) {
        await Future.wait(pending, eagerError: false);
        continue;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      try {
        await Future.wait(pending, eagerError: false).timeout(remaining);
      } on TimeoutException {
        return false;
      }
    }
  }

  static bool _hasPendingWork(SubagentNode node) {
    final startSettled = node.startSettled;
    return node.isActive ||
        node.run != null ||
        node.observation != null ||
        (startSettled != null && !startSettled.isCompleted);
  }

  void _markUnknownForCleanup(Iterable<SubagentNode> nodes) {
    for (final node in nodes) {
      if (_hasPendingWork(node)) _markUnknown(node);
    }
  }

  void _markUnknown(SubagentNode node, [String reason = '停止请求超时，远程状态未知']) {
    if (node.lifecycleUnknown) return;
    node.lifecycleUnknown = true;
    node.cancelRequested = true;
    node.status = 'unknown';
    node.summary = _summary(reason);
    node.updatedAt = DateTime.now().toUtc();
    node.lastEventType = 'subagent.unknown';
    _signalLifecycleChange(node);
    unawaited(
      _emitLifecycleBestEffort(node, 'subagent.unknown', {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'status': node.status,
        'summary': node.summary,
      }),
    );
  }

  static Future<void> _lifecycleChangeFuture(SubagentNode node) {
    final existing = node.lifecycleChange;
    if (existing != null && !existing.isCompleted) return existing.future;
    final created = Completer<void>();
    node.lifecycleChange = created;
    return created.future;
  }

  static void _signalLifecycleChange(SubagentNode node) {
    final change = node.lifecycleChange;
    if (change != null && !change.isCompleted) change.complete();
    node.lifecycleChange = null;
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
              'role': {
                'type': 'string',
                'description': 'Optional role name from the saved subagent role configuration.',
              },
              'fork_turns': {
                'description': 'Optional history fork: none, all, or a positive number of recent turns.',
                'oneOf': [
                  {
                    'type': 'string',
                    'enum': ['none', 'all'],
                  },
                  {'type': 'integer', 'minimum': 1, 'maximum': 64},
                ],
              },
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
        call: (arguments) => _track(_sendMessage(parent, arguments)),
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
        call: (arguments) => _track(_followup(parent, arguments)),
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
                'description': 'Timeout in milliseconds. Defaults to 30000; maximum is 3600000.',
              },
            },
          },
        ),
        call: (arguments) => _wait(parent, arguments),
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'list_agents',
          description: 'List child agents and their current status.',
          parameters: {'type': 'object', 'properties': {}},
        ),
        call: (_) async => {'agents': _agentMaps(parent)},
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
        call: (arguments) => _interruptAgent(parent, arguments),
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'close_agent',
          description:
              'Close a child agent and its descendants while retaining their '
              'history. A closed agent must be resumed before follow-up work.',
          parameters: {
            'type': 'object',
            'required': ['target'],
            'properties': {
              'target': {'type': 'string'},
            },
          },
        ),
        call: (arguments) => _closeAgent(parent, arguments),
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'resume_agent',
          description:
              'Resume a previously closed child agent. This only reopens the '
              'thread; use followup_task to start its next turn.',
          parameters: {
            'type': 'object',
            'required': ['target'],
            'properties': {
              'target': {'type': 'string'},
            },
          },
        ),
        call: (arguments) => _resumeAgent(parent, arguments),
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
    final role = _parseRole(arguments['role']);
    final forkTurns = _parseForkTurns(arguments['fork_turns']);
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
      agentPath: '${parent.agentPath}/$taskName',
      depth: parent.depth + 1,
      providerId: settings.providerId.trim().isEmpty
          ? null
          : settings.providerId.trim(),
      model: settings.model.trim().isEmpty ? null : settings.model.trim(),
      reasoningEffort: settings.reasoningEffort == defaultReasoningEffort
          ? null
          : settings.reasoningEffort,
      role: role,
      forkTurns: forkTurns,
    )..parentTurnId = parent.activeTurnId;
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
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
        });
        if (_closed) throw StateError('子代理树已关闭');
        return _agentMap(node);
      }
      node.status = 'running';
      await _emit(node, 'subagent.started', {
        'agent_id': node.id,
        'agent_path': node.agentPath,
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
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
        });
        if (_closed) throw StateError('子代理树已关闭');
        return _agentMap(node);
      }
      final run = _start(node, message.trim());
      node.run = run;
      final observation = _track(_observe(node, run));
      node.observation = observation;
      unawaited(observation);
      return _agentMap(node);
    } catch (_) {
      if (node.run != null && node.isActive) {
        try {
          await _interrupt(node);
        } catch (_) {}
      }
      try {
        await _discard?.call(node);
      } catch (_) {
        // Keep the original spawn error when cleanup races with deletion.
      }
      _nodes.remove(node.id);
      rethrow;
    } finally {
      if (!startSettled.isCompleted) startSettled.complete();
    }
  }

  Future<Object?> _sendMessage(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    if (_closed) throw StateError('子代理树已关闭');
    final node = _target(caller, arguments['target']);
    final message = _requiredText(arguments, 'message');
    if (message.trim().isEmpty) throw ArgumentError('message is required');
    node.mailbox.add(message.trim());
    node.parentTurnId ??= caller.activeTurnId;
    node.updatedAt = DateTime.now().toUtc();
    await _emit(node, 'subagent.message', {
      'agent_id': node.id,
      'agent_path': node.agentPath,
      'task_name': node.taskName,
      'message_queued': true,
    });
    return {
      'agent_id': node.id,
      'agent_path': node.agentPath,
      'task_name': node.taskName,
      'queued': true,
      'starts_turn': false,
    };
  }

  Future<Object?> _followup(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    if (_closed || _cancelling) throw StateError('子代理树正在关闭或停止');
    final node = _target(caller, arguments['target']);
    final message = _requiredText(arguments, 'message');
    if (message.trim().isEmpty) throw ArgumentError('message is required');
    if (node.lifecycleUnknown && _hasPendingWork(node)) {
      throw StateError('子代理状态未知，底层任务尚未结束，请稍后再继续');
    }
    if (node.status == 'closed') {
      throw StateError('子代理已关闭，请先调用 resume_agent');
    }
    if (node.isActive) {
      node.mailbox.add(message.trim());
      node.followupPending = true;
      node.parentTurnId = caller.activeTurnId ?? node.parentTurnId;
      node.updatedAt = DateTime.now().toUtc();
      await _emit(node, 'subagent.message', {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'message_queued': true,
        'followup': true,
      });
      return {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'queued': true,
        'starts_turn': false,
      };
    }
    final activeCount = _activeChildCount(excluding: node);
    if (activeCount >= settings.maxConcurrentThreads) {
      throw StateError('子代理并发线程已达到 ${settings.maxConcurrentThreads}');
    }
    final queued = List<String>.of(node.mailbox);
    node.mailbox.clear();
    node.followupPending = false;
    final prompt = [...queued, message.trim()].join('\n\n');
    node.parentTurnId = caller.activeTurnId ?? node.parentTurnId;
    final startsTurn = await _beginFollowup(node, prompt, automatic: false);
    if (!startsTurn) {
      return {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'queued': false,
        'starts_turn': false,
        'interrupted': true,
      };
    }
    return {
      'agent_id': node.id,
      'agent_path': node.agentPath,
      'task_name': node.taskName,
      'queued': false,
      'starts_turn': true,
    };
  }

  Future<bool> _beginFollowup(
    SubagentNode node,
    String prompt, {
    required bool automatic,
  }) async {
    final previousStatus = node.status;
    node.cancelRequested = false;
    node.lifecycleUnknown = false;
    node.status = 'pending';
    node.summary = '';
    node.run = null;
    node.observation = null;
    node.updatedAt = DateTime.now().toUtc();
    final startSettled = Completer<void>();
    node.startSettled = startSettled;
    // Keep a follow-up prompt durable while it waits for a slot or task
    // preparation. A process stop in this window must not lose the request.
    if (node.mailbox.isEmpty || node.mailbox.first != prompt) {
      node.mailbox.insert(0, prompt);
    }
    await _persistStateBestEffort(node);
    try {
      if (automatic) await _waitForFollowupCapacity(node);
      if (_closed || _cancelling || node.cancelRequested) {
        _ensurePromptInMailbox(node, prompt);
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        node.lastEventType = 'subagent.interrupted';
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
          'followup': true,
        });
        return false;
      }
      await _prepare(node, followup: true);
      if (_closed || _cancelling || node.cancelRequested) {
        _ensurePromptInMailbox(node, prompt);
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        node.lastEventType = 'subagent.interrupted';
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
          'followup': true,
        });
        return false;
      }
      node.status = 'running';
      if (node.mailbox.isNotEmpty && node.mailbox.first == prompt) {
        node.mailbox.removeAt(0);
      }
      await _persistStateBestEffort(node);
      await _emit(node, 'subagent.started', {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'parent_id': node.parentId,
        'depth': node.depth,
        if (node.providerId != null) 'provider_id': node.providerId,
        if (node.model != null) 'model': node.model,
        if (node.reasoningEffort != null)
          'reasoning_effort': node.reasoningEffort,
        'followup': true,
      });
      if (_closed || _cancelling || node.cancelRequested) {
        _ensurePromptInMailbox(node, prompt);
        await _interrupt(node);
        node.status = 'interrupted';
        node.updatedAt = DateTime.now().toUtc();
        node.lastEventType = 'subagent.interrupted';
        await _emit(node, 'subagent.interrupted', {
          'agent_id': node.id,
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
          'followup': true,
        });
        return false;
      }
      final run = _start(node, prompt);
      node.run = run;
      final observation = _track(_observe(node, run));
      node.observation = observation;
      unawaited(observation);
      return true;
    } catch (error) {
      if (node.run != null && node.isActive) {
        try {
          await _interrupt(node);
        } catch (_) {}
      }
      _ensurePromptInMailbox(node, prompt);
      node.followupPending = false;
      if (automatic) {
        node.status = 'failed';
        node.summary = _summary('后续任务启动失败：$error');
        node.updatedAt = DateTime.now().toUtc();
        node.lastEventType = 'subagent.failed';
        await _emitBestEffort(node, 'subagent.failed', {
          'agent_id': node.id,
          'agent_path': node.agentPath,
          'task_name': node.taskName,
          'status': node.status,
          'summary': node.summary,
          'followup': true,
        });
        return false;
      }
      if (node.isActive) {
        node.status = previousStatus;
        node.updatedAt = DateTime.now().toUtc();
        await _persistStateBestEffort(node);
      }
      rethrow;
    } finally {
      if (!startSettled.isCompleted) startSettled.complete();
      if (identical(node.startSettled, startSettled) &&
          startSettled.isCompleted &&
          node.run == null) {
        node.startSettled = null;
      }
    }
  }

  static void _ensurePromptInMailbox(SubagentNode node, String prompt) {
    if (node.mailbox.isEmpty || node.mailbox.first != prompt) {
      node.mailbox.insert(0, prompt);
    }
  }

  int _activeChildCount({SubagentNode? excluding}) => _nodes.values
      .where(
        (node) => node.id != rootTaskId && node != excluding && node.isActive,
      )
      .length;

  Future<void> _waitForFollowupCapacity(SubagentNode node) async {
    while (!_closed &&
        !_cancelling &&
        _activeChildCount(excluding: node) >= settings.maxConcurrentThreads) {
      final pending = <Future<void>>[];
      for (final other in agents) {
        if (other == node || !other.isActive) continue;
        _addNodeWaitFuture(other, pending);
      }
      if (pending.isEmpty) return;
      // One completed sibling is enough to free a shared execution slot. Do
      // not wait for every other sibling, which could unnecessarily hold a
      // queued follow-up behind an unrelated long-running task.
      await Future.any<void>(pending);
    }
  }

  Future<Object?> _wait(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    final targets = <SubagentNode>[];
    final target = arguments['target'];
    final targetList = arguments['targets'];
    if (target is String && target.trim().isNotEmpty) {
      targets.add(_target(caller, target));
    }
    if (targetList is List) {
      for (final value in targetList) {
        if (value is String && value.trim().isNotEmpty) {
          final node = _target(caller, value);
          if (!targets.contains(node)) targets.add(node);
        }
      }
    }
    if (targets.isEmpty) {
      targets.addAll(agents.where((node) => _isDescendantOf(node, caller)));
    }
    final timeout = _waitDuration(arguments['timeout_ms']);
    var timedOut = false;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final pending = <Future<void>>[];
      final lifecycleChanges = <Future<void>>[];
      for (final node in targets) {
        if (node.isActive) {
          _addNodeWaitFuture(node, pending);
          lifecycleChanges.add(_lifecycleChangeFuture(node));
        }
      }
      if (pending.isEmpty) break;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        timedOut = true;
        break;
      }
      try {
        final allSettled = Future.wait(pending, eagerError: false);
        await Future.any<void>([allSettled, ...lifecycleChanges])
            .timeout(remaining);
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

  Future<Object?> _interruptAgent(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    final node = _target(caller, arguments['target']);
    final previousStatus = node.status;
    if (!node.isActive) {
      return {
        ..._agentMap(node),
        'previous_status': previousStatus,
        'interrupted': false,
      };
    }
    node.cancelRequested = true;
    await _interrupt(node);
    return {
      ..._agentMap(node),
      'previous_status': previousStatus,
      'interrupted': true,
    };
  }

  Future<Object?> _closeAgent(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    if (_closed || _cancelling) throw StateError('子代理树正在关闭或停止');
    final node = _target(caller, arguments['target']);
    final targets = <SubagentNode>[
      node,
      for (final child in agents)
        if (child != node && _isDescendantOf(child, node)) child,
    ]..sort((left, right) => right.depth.compareTo(left.depth));
    final deadline = DateTime.now().add(lifecycleTimeout);
    for (final target in targets) {
      if (!target.isActive) continue;
      target.cancelRequested = true;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        _markUnknown(target);
        continue;
      }
      try {
        await _interrupt(target).timeout(remaining);
      } on TimeoutException {
        _markUnknown(target);
      } catch (_) {
        // A turn may have finished between the lookup and the close request.
      }
    }
    final remaining = deadline.difference(DateTime.now());
    final settled = remaining <= Duration.zero
        ? false
        : await _waitFor(targets, timeout: remaining);
    if (!settled) _markUnknownForCleanup(targets);
    for (final target in targets) {
      target.cancelRequested = false;
      target.followupPending = false;
      if (target.lifecycleUnknown) continue;
      target.status = 'closed';
      target.updatedAt = DateTime.now().toUtc();
      await _emitLifecycleBestEffort(target, 'subagent.closed', {
        'agent_id': target.id,
        'agent_path': target.agentPath,
        'task_name': target.taskName,
        'status': target.status,
      });
    }
    return {
      ..._agentMap(node),
      'closed': true,
      'descendants_closed': targets.length - 1,
    };
  }

  Future<Object?> _resumeAgent(
    SubagentNode caller,
    Map<String, Object?> arguments,
  ) async {
    if (_closed || _cancelling) throw StateError('子代理树正在关闭或停止');
    final node = _target(caller, arguments['target']);
    final wasClosed = node.status == 'closed';
    if (wasClosed) {
      node.status = 'interrupted';
      node.cancelRequested = false;
      node.updatedAt = DateTime.now().toUtc();
      await _emit(node, 'subagent.resumed', {
        'agent_id': node.id,
        'agent_path': node.agentPath,
        'task_name': node.taskName,
        'status': node.status,
      });
    }
    return {..._agentMap(node), 'resumed': wasClosed};
  }

  Future<void> _observe(SubagentNode node, Future<AgentResult> run) async {
    AgentResult? result;
    Object? runError;
    try {
      result = await run;
    } catch (error) {
      runError = error;
    }
    if (node.lifecycleUnknown) {
      _releaseRuntime(node, run);
      return;
    }
    final finalStatus = runError != null
        ? 'failed'
        : switch (result!.status) {
            'completed' => 'completed',
            'cancelled' || 'canceled' => 'interrupted',
            'unknown' => 'unknown',
            _ => 'failed',
          };
    node.status = finalStatus;
    node.summary = runError == null ? _summary(result!.finalText) : '';
    if (node.summary.isEmpty) {
      final resultError = runError ?? result?.error;
      if (resultError != null) node.summary = _summary('$resultError');
    }
    node.updatedAt = DateTime.now().toUtc();
    final eventType = switch (finalStatus) {
      'completed' => 'subagent.completed',
      'interrupted' => 'subagent.interrupted',
      'unknown' => 'subagent.unknown',
      _ => 'subagent.failed',
    };
    node.lastEventType = eventType;
    final completionPayload = <String, Object?>{
      'agent_id': node.id,
      'agent_path': node.agentPath,
      'task_name': node.taskName,
      'status': finalStatus,
      if (node.summary.isNotEmpty) 'summary': node.summary,
    };
    // A late event must not turn a completed child into an unhandled future
    // when the parent is being deleted at the same time. The task result and
    // the in-memory node remain authoritative even if persistence is gone.
    await _emitBestEffort(node, eventType, completionPayload);
    if (node.lifecycleUnknown) {
      _releaseRuntime(node, run);
      return;
    }
    // Re-check after the completion event. An explicit followup_task may be
    // delivered while the event is being persisted; in that case it already
    // consumed the mailbox and started the next turn. Starting from the old
    // snapshot would launch a duplicate (sometimes empty) turn.
    final pendingFollowup =
        node.followupPending &&
        node.mailbox.isNotEmpty &&
        !_closed &&
        !_cancelling &&
        !node.cancelRequested &&
        !node.lifecycleUnknown &&
        finalStatus != 'interrupted';
    if (pendingFollowup) {
      final prompt = node.mailbox.join('\n\n');
      node.mailbox.clear();
      node.followupPending = false;
      node.status = 'waiting';
      node.updatedAt = DateTime.now().toUtc();
      await _beginFollowup(node, prompt, automatic: true);
    }
    if (!pendingFollowup) {
      _releaseRuntime(node, run);
    }
  }

  Future<void> _persistStateBestEffort(SubagentNode node) async {
    try {
      await _onStateChanged?.call(node);
    } catch (_) {
      // State persistence is advisory; the active in-memory tree remains
      // authoritative for the current process.
    }
  }

  void _releaseRuntime(SubagentNode node, Future<AgentResult> run) {
    if (identical(node.run, run)) node.run = null;
    node.observation = null;
    final settled = node.startSettled;
    if (settled == null || settled.isCompleted) node.startSettled = null;
  }

  bool _isDescendantOf(SubagentNode node, SubagentNode ancestor) {
    var current = node;
    final visited = <String>{};
    while (current.parentId.isNotEmpty && visited.add(current.id)) {
      if (current.parentId == ancestor.id) return true;
      final parent = _nodes[current.parentId];
      if (parent == null) return false;
      current = parent;
    }
    return false;
  }

  SubagentNode _target(SubagentNode caller, Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('target is required');
    }
    final target = value.trim();
    if (target == caller.id || target == caller.agentPath) {
      throw StateError('不能操作自己');
    }
    if (target == rootTaskId || target == '/root') {
      throw StateError('不能操作根代理');
    }
    final visible = agents.where((node) => _isDescendantOf(node, caller));
    final exactId = visible.where((node) => node.id == target).toList();
    if (exactId.length == 1) return exactId.single;
    final canonicalPath = target.startsWith('/')
        ? target
        : target.startsWith('root/')
        ? '/$target'
        : '${caller.agentPath}/$target';
    final pathMatches = visible
        .where((node) => node.agentPath == canonicalPath)
        .toList();
    if (pathMatches.length == 1) return pathMatches.single;
    final nameMatches = visible
        .where((node) => node.parentId == caller.id && node.taskName == target)
        .toList();
    if (nameMatches.length == 1) return nameMatches.single;
    final descendantNameMatches = visible
        .where((node) => node.taskName == target)
        .toList();
    if (descendantNameMatches.length > 1) {
      throw StateError('子代理目标不明确，请使用 agent_path：$target');
    }
    if (descendantNameMatches.length == 1) return descendantNameMatches.single;
    throw StateError('找不到当前代理范围内的子代理 $target');
  }

  List<Map<String, Object?>> _agentMaps(SubagentNode caller) => [
    for (final node in agents)
      if (_isDescendantOf(node, caller)) _agentMap(node),
  ];

  Map<String, Object?> _agentMap(SubagentNode node) => {
    'agent_id': node.id,
    'agent_path': node.agentPath,
    'task_name': node.taskName,
    'parent_id': node.parentId,
    'depth': node.depth,
    'role': node.role,
    'fork_turns': node.forkTurns,
    'status': node.status,
    if (node.providerId != null) 'provider_id': node.providerId,
    if (node.summary.isNotEmpty) 'summary': node.summary,
    if (node.lastEventType != null) 'last_event': node.lastEventType,
    if (node.status == 'completed' ||
        node.status == 'failed' ||
        node.status == 'unknown' ||
        node.status == 'interrupted' ||
        node.status == 'closed')
      'completion_notice': node.summary.isEmpty
          ? '子代理已${_statusLabel(node.status)}。'
          : node.summary,
    if (node.mailbox.isNotEmpty) 'mailbox_pending': node.mailbox.length,
  };

  static String _statusLabel(String status) {
    return switch (status) {
      'completed' => '完成',
      'failed' => '失败',
      'unknown' => '结束但状态未知',
      'interrupted' => '中断',
      'closed' => '已关闭',
      _ => status,
    };
  }

  Future<void> _emit(
    SubagentNode node,
    String type,
    Map<String, Object?> payload,
  ) async {
    node.lastEventType = type;
    try {
      await _onStateChanged?.call(node);
    } catch (_) {
      // State persistence is best effort here; the event remains authoritative
      // for the current turn and a later save can repair the task snapshot.
    }
    await _onEvent(node, type, payload);
  }

  Future<void> _emitBestEffort(
    SubagentNode node,
    String type,
    Map<String, Object?> payload,
  ) async {
    try {
      await _emit(node, type, payload);
    } catch (_) {
      // A parent task may have been deleted before a child reports back.
    }
  }

  Future<void> _emitLifecycleBestEffort(
    SubagentNode node,
    String type,
    Map<String, Object?> payload,
  ) async {
    try {
      await _emit(node, type, payload).timeout(lifecycleTimeout);
    } catch (_) {
      // Shutdown must not wait for a database or event sink that is offline.
    }
  }

  String _newId() {
    _idSequence++;
    return 'agent-${DateTime.now().microsecondsSinceEpoch}-$_idSequence';
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String) throw ArgumentError('$key is required');
    return value;
  }

  static String _parseRole(Object? value) {
    if (value == null) return defaultSubagentRole;
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('role must be a non-empty string');
    }
    final role = value.trim();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$').hasMatch(role)) {
      throw ArgumentError(
        'role must use lowercase letters, digits, underscores, or hyphens',
      );
    }
    return role;
  }

  static String _parseForkTurns(Object? value) {
    // Codex MultiAgentV2 uses a full-history fork when fork_turns is omitted.
    if (value == null) return 'all';
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'none' || normalized == 'all') return normalized;
      final count = int.tryParse(normalized);
      if (count != null && count > 0 && count <= 64) return '$count';
    } else if (value is int && value > 0 && value <= 64) {
      return '$value';
    }
    throw ArgumentError(
      'fork_turns must be none, all, or an integer from 1 to 64',
    );
  }

  static Duration _waitDuration(Object? value) {
    if (value == null) return _defaultWaitTimeout;
    if (value is! num) throw ArgumentError('timeout_ms must be an integer');
    final requested = value.toInt();
    if (requested < 0) {
      throw ArgumentError('timeout_ms must be zero or greater');
    }
    final duration = Duration(milliseconds: requested);
    if (duration > _maxWaitTimeout) {
      throw ArgumentError('timeout_ms must not exceed 3600000');
    }
    return duration;
  }

  static String _summary(String text) {
    final value = text.trim();
    if (value.length <= 1200) return value;
    return '${value.substring(0, 1197)}...';
  }
}
