import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'agent/agent_loop.dart';
import 'agent/agent_tools.dart';
import 'agent/ai_protocol.dart';
import 'agent/openai_compatible_client.dart';
import 'credentials/credential_store.dart';
import 'domain/models.dart';
import 'platform/android_task_service.dart';
import 'providers/provider_connection_tester.dart';
import 'server_status_script.dart';
import 'ssh/ssh_connection.dart';
import 'storage/app_database.dart';

class ServerTerminalSession {
  ServerTerminalSession(this.connection, this.stream);

  final SshConnection connection;
  final SshCommandStream stream;

  Future<void> close() async {
    stream.close();
    await connection.close();
  }
}

class AppController extends ChangeNotifier {
  AppController({
    AppDatabase? database,
    required CredentialStore credentials,
    ProviderConnectionTester? providerTester,
    SshConnector? sshConnector,
    AndroidTaskService? taskService,
    this.previewMode = false,
  }) : _database = database ?? AppDatabase(),
       // Keep the public parameter name; a private named initializing formal
       // cannot be used by callers from another library.
       // ignore: prefer_initializing_formals
       _credentials = credentials,
       _providerTester = providerTester ?? ProviderConnectionTester(),
       _sshConnector = sshConnector ?? DartSshConnector(),
       _taskService = taskService ?? const AndroidTaskService();

  final AppDatabase _database;
  final CredentialStore _credentials;
  final ProviderConnectionTester _providerTester;
  final SshConnector _sshConnector;
  final AndroidTaskService _taskService;
  final bool previewMode;
  final TaskSshConnectionPool _sshPool = TaskSshConnectionPool();
  final Map<String, AgentCancellation> _runningTasks = {};
  final Map<String, Future<AgentResult>> _taskRuns = {};
  final Map<String, List<AiMessage>> _taskHistories = {};
  final Map<String, RemoteAgentTools> _phoneTools = {};
  final Map<String, List<SshDirectoryEntry>> _directoryCache = {};
  final Map<String, Future<List<SshDirectoryEntry>>> _directoryLoads = {};
  final Map<String, Future<void>> _remoteWriteTails = {};
  final Map<String, Future<void>> _taskEventTails = {};
  final Map<String, String> _streamingAssistantText = {};
  Future<void> _loadTail = Future<void>.value();
  int _idSequence = 0;

  List<ServerProfile> _servers = const [];
  List<ProviderProfile> _providers = const [];
  List<Task> _tasks = const [];
  Map<String, List<TaskEvent>> _events = const {};
  bool _agentAutoExecute = false;
  bool _betaUpdatesEnabled = false;
  bool _loading = true;
  String? _loadError;
  bool _disposed = false;

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  List<ProviderProfile> get providers => List.unmodifiable(_providers);
  List<Task> get tasks => List.unmodifiable(_tasks);
  bool get agentAutoExecute => _agentAutoExecute;
  bool get betaUpdatesEnabled => _betaUpdatesEnabled;
  bool get isLoading => _loading;
  String? get loadError => _loadError;

  bool isTaskRunning(String taskId) => _runningTasks.containsKey(taskId);

  List<TaskEvent> eventsFor(String taskId) {
    return List.unmodifiable(_events[taskId] ?? const <TaskEvent>[]);
  }

  String streamingAssistantText(String taskId) {
    return _streamingAssistantText[taskId] ?? '';
  }

  Future<void> load() {
    final next = _loadTail.then((_) => _loadFromDatabase());
    final handled = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _loading = false;
        _loadError = '$error';
        _notify();
      },
    );
    _loadTail = handled;
    return handled;
  }

  Future<void> _loadFromDatabase() async {
    _loading = true;
    _loadError = null;
    _notify();
    _servers = await _database.loadServers();
    _providers = await _database.loadProviders();
    _agentAutoExecute =
        await _database.readSetting(_agentAutoExecuteSetting) == 'true';
    _betaUpdatesEnabled =
        await _database.readSetting(_betaUpdatesSetting) == 'true';
    final storedTasks = await _database.loadTasks();
    final storedEvents = await _database.loadAllEvents();
    final eventsByTask = <String, List<TaskEvent>>{};
    for (final event in storedEvents) {
      eventsByTask.putIfAbsent(event.taskId, () => <TaskEvent>[]).add(event);
    }

    final recoveredTasks = <Task>[];
    for (final task in storedTasks) {
      if (task.status == 'running' && !_runningTasks.containsKey(task.id)) {
        final previous = eventsByTask[task.id] ?? const <TaskEvent>[];
        String? terminalStatus;
        for (final event in previous.reversed) {
          terminalStatus = _statusForTerminalEvent(event.type);
          if (terminalStatus != null) break;
        }
        if (terminalStatus != null) {
          final recovered = task.copyWith(status: terminalStatus);
          await _database.saveTask(recovered);
          recoveredTasks.add(recovered);
        } else {
          final recovered = task.copyWith(status: 'unknown');
          await _database.saveTask(recovered);
          final recovery = TaskEvent(
            eventId: _newId('event'),
            taskId: task.id,
            sequence: previous.isEmpty ? 1 : previous.last.sequence + 1,
            type: 'task.recovered',
            timestamp: DateTime.now().toUtc(),
            payload: const {'previousStatus': 'running'},
          );
          await _database.saveEvent(recovery);
          eventsByTask.putIfAbsent(task.id, () => <TaskEvent>[]).add(recovery);
          recoveredTasks.add(recovered);
        }
      } else {
        recoveredTasks.add(task);
      }
    }

    _tasks = recoveredTasks;
    _events = eventsByTask.map(
      (taskId, values) =>
          MapEntry(taskId, List<TaskEvent>.unmodifiable(values)),
    );
    _loading = false;
    _notify();
  }

  Future<Task> createTask({
    String mode = 'chat',
    String? serverId,
    String? providerId,
    required String title,
    String? workingDirectory,
    String? executionMode,
  }) async {
    if (mode != 'chat' && mode != 'agent') {
      throw ArgumentError('不支持的任务模式：$mode');
    }
    if (mode == 'agent' && (serverId == null || serverId.isEmpty)) {
      throw ArgumentError('手机 Agent 需要选择目标服务器');
    }
    final requestedExecutionMode =
        executionMode ??
        (mode == 'agent' && _agentAutoExecute ? 'auto' : 'confirm');
    final normalizedExecutionMode = requestedExecutionMode == 'auto'
        ? 'auto'
        : 'confirm';
    final now = DateTime.now().toUtc();
    final task = Task(
      id: _newId('task'),
      mode: mode,
      serverId: mode == 'agent' ? serverId : null,
      providerId: providerId,
      title: title,
      workingDirectory: workingDirectory,
      executionMode: normalizedExecutionMode,
      status: 'queued',
      createdAt: now,
      updatedAt: now,
    );
    await _database.saveTask(task);
    _tasks = [task, ..._tasks];
    _notify();
    return task;
  }

  Future<Task> createContinuationTask(Task source) {
    return createTask(
      mode: source.mode,
      serverId: source.serverId,
      providerId: source.providerId,
      title: '${source.title}（继续）',
      workingDirectory: source.workingDirectory,
      executionMode: source.executionMode,
    );
  }

  Future<void> setAgentAutoExecute(bool enabled) async {
    await _database.writeSetting(
      _agentAutoExecuteSetting,
      enabled ? 'true' : 'false',
    );
    _agentAutoExecute = enabled;
    _notify();
  }

  Future<void> setBetaUpdatesEnabled(bool enabled) async {
    await _database.writeSetting(
      _betaUpdatesSetting,
      enabled ? 'true' : 'false',
    );
    _betaUpdatesEnabled = enabled;
    _notify();
  }

  Future<void> renameTask(Task task, String title) async {
    final value = title.trim();
    if (value.isEmpty) throw ArgumentError('任务名称不能为空');
    final current = _tasks.firstWhere((value) => value.id == task.id);
    final updated = current.copyWith(title: value);
    await _database.saveTask(updated);
    _tasks = [
      for (final item in _tasks) item.id == updated.id ? updated : item,
    ];
    _notify();
  }

  Future<Task> updateTaskConfiguration({
    required String taskId,
    required String mode,
    required String? serverId,
    required String? providerId,
    required String? workingDirectory,
    required String executionMode,
  }) async {
    if (mode != 'chat' && mode != 'agent') {
      throw ArgumentError('不支持的任务模式：$mode');
    }
    if (mode == 'agent' && (serverId == null || serverId.isEmpty)) {
      throw ArgumentError('手机 Agent 需要选择目标服务器');
    }
    if (_taskRuns.containsKey(taskId)) {
      throw StateError('任务正在运行，不能修改对话设置');
    }

    final current = _tasks.firstWhere((task) => task.id == taskId);
    final normalizedExecutionMode = executionMode == 'auto'
        ? 'auto'
        : 'confirm';
    final normalizedServerId = mode == 'agent' ? serverId : null;
    final normalizedWorkingDirectory = mode == 'agent'
        ? workingDirectory
        : null;
    final contextChanged =
        current.mode != mode ||
        current.serverId != normalizedServerId ||
        current.providerId != providerId;
    final now = DateTime.now().toUtc();
    final updated = Task(
      id: current.id,
      mode: mode,
      serverId: normalizedServerId,
      providerId: providerId,
      title: current.title,
      workingDirectory: normalizedWorkingDirectory,
      executionMode: normalizedExecutionMode,
      status: current.status,
      createdAt: current.createdAt,
      updatedAt: now,
    );
    await _database.saveTask(updated);
    _tasks = [
      for (final task in _tasks) task.id == updated.id ? updated : task,
    ];

    if (contextChanged) {
      _taskHistories.remove(taskId);
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.context_changed',
        payload: {
          'history_boundary': true,
          'mode': mode,
          'server_id': normalizedServerId,
          'provider_id': providerId,
        },
      );
    }
    _notify();
    return _tasks.firstWhere((task) => task.id == taskId);
  }

  Future<void> updateTaskStatus(String taskId, String status) async {
    final current = _tasks.firstWhere((task) => task.id == taskId);
    final updated = current.copyWith(
      status: status,
      updatedAt: DateTime.now().toUtc(),
    );
    await _database.saveTask(updated);
    _tasks = [
      for (final item in _tasks) item.id == updated.id ? updated : item,
    ];
    _notify();
  }

  Future<TaskEvent> appendTaskEvent({
    required String taskId,
    required String type,
    required Map<String, Object?> payload,
  }) {
    final previous = _taskEventTails[taskId] ?? Future<void>.value();
    late Future<TaskEvent> current;
    current = previous.then<TaskEvent>(
      (_) => _appendTaskEventNow(taskId: taskId, type: type, payload: payload),
    );
    final settled = current.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _taskEventTails[taskId] = settled;
    unawaited(
      settled.then<void>((_) {
        if (identical(_taskEventTails[taskId], settled)) {
          _taskEventTails.remove(taskId);
        }
      }),
    );
    return current;
  }

  Future<TaskEvent> _appendTaskEventNow({
    required String taskId,
    required String type,
    required Map<String, Object?> payload,
  }) async {
    final previous = eventsFor(taskId);
    final event = TaskEvent(
      eventId: _newId('event'),
      taskId: taskId,
      sequence: previous.isEmpty ? 1 : previous.last.sequence + 1,
      type: type,
      timestamp: DateTime.now().toUtc(),
      payload: _eventPayload(payload),
    );
    await _database.saveEvent(event);
    final task = _tasks.firstWhere((value) => value.id == taskId);
    final updatedTask = task.copyWith(updatedAt: event.timestamp);
    await _database.saveTask(updatedTask);
    _events = {
      ..._events,
      taskId: List.unmodifiable([...eventsFor(taskId), event]),
    };
    _tasks = [
      for (final item in _tasks) item.id == updatedTask.id ? updatedTask : item,
    ];
    _notify();
    return event;
  }

  Future<void> deleteTask(Task task) async {
    final run = _taskRuns[task.id];
    if (run != null) {
      stopTask(task.id);
      try {
        await run;
      } catch (_) {
        // The task is being deleted; its final error is no longer actionable.
      }
    } else {
      await _releasePhoneTask(task.id);
    }
    final eventTail = _taskEventTails[task.id];
    if (eventTail != null) await eventTail;
    _taskHistories.remove(task.id);
    _streamingAssistantText.remove(task.id);
    await _database.deleteTask(task.id);
    _tasks = [
      for (final item in _tasks)
        if (item.id != task.id) item,
    ];
    _events = {
      for (final entry in _events.entries)
        if (entry.key != task.id) entry.key: entry.value,
    };
    _notify();
  }

  Future<AgentResult> runTask(
    Task task, {
    required String prompt,
    List<AiAttachment> attachments = const [],
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    if (_taskRuns.containsKey(task.id)) {
      throw StateError('任务正在运行');
    }
    final future = _runTask(
      task,
      prompt: prompt,
      attachments: attachments,
      confirm: confirm,
      onFirstHostKey: onFirstHostKey,
      onUserInfoRequest: onUserInfoRequest,
    );
    _taskRuns[task.id] = future;
    unawaited(
      future.then<void>(
        (_) => _finishTask(task.id),
        onError: (Object error, StackTrace stackTrace) {
          _finishTask(task.id);
        },
      ),
    );
    return future;
  }

  Future<AgentResult> _runTask(
    Task task, {
    required String prompt,
    required List<AiAttachment> attachments,
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    if (task.mode != 'chat' && task.mode != 'agent') {
      final error = UnsupportedError('不支持的任务模式：${task.mode}');
      try {
        await appendTaskEvent(
          taskId: task.id,
          type: 'task.failed',
          payload: {'error': '$error'},
        );
        await updateTaskStatus(task.id, 'failed');
      } catch (_) {
        // Keep the original invalid-task error when old data is incomplete.
      }
      return AgentResult(
        status: 'failed',
        messages: _taskHistories[task.id] ?? const [],
        error: error,
      );
    }
    final cancellation = AgentCancellation();
    _runningTasks[task.id] = cancellation;
    _streamingAssistantText.remove(task.id);
    _notify();
    final previousEvents = eventsFor(task.id);
    SshConnection? connection;
    RemoteAgentTools? remoteTools;
    OpenAiCompatibleClient? client;
    var remoteOperationStarted = false;
    var serviceStarted = false;
    try {
      await appendTaskEvent(
        taskId: task.id,
        type: 'user.message',
        payload: {
          'text': prompt,
          if (attachments.isNotEmpty)
            'attachments': attachments.map((item) => item.toJson()).toList(),
        },
      );
      if (previewMode) {
        return await _runPreviewTask(
          task,
          prompt: prompt,
          attachments: attachments,
          initialHistory:
              _taskHistories[task.id] ??
              _localHistory(_systemPrompt(task), previousEvents),
          cancellation: cancellation,
        );
      }
      await updateTaskStatus(task.id, 'running');
      await appendTaskEvent(
        taskId: task.id,
        type: 'task.started',
        payload: {'mode': task.mode},
      );
      if (task.mode == 'agent') {
        await _taskService.start(task.id);
        serviceStarted = true;
      }

      final provider = _providerForTask(task);
      final apiKey = await _readCredential(
        provider.apiKeyRef,
        '供应商 API Key 不可用',
      );
      List<AgentTool> tools = const [];
      var systemPrompt = _systemPrompt(task);
      if (task.mode == 'agent') {
        final serverId = task.serverId;
        if (serverId == null) throw StateError('任务没有目标服务器');
        final server = _servers.firstWhere((value) => value.id == serverId);
        final pendingConnection = _sshPool.acquire(
          task.id,
          () => _connectServer(
            server,
            onFirstHostKey: onFirstHostKey,
            onUserInfoRequest: onUserInfoRequest,
          ),
        );
        connection = await Future.any<SshConnection>([
          pendingConnection,
          cancellation.whenCancelled.then<SshConnection>(
            (_) => throw StateError('SSH connection cancelled'),
          ),
        ]);
        await _saveObservedHostKey(server, connection.hostKey);
        final workingDirectory =
            task.workingDirectory ?? server.defaultWorkingDirectory;
        remoteTools = _phoneTools[task.id];
        if (remoteTools == null || remoteTools.isClosed) {
          await remoteTools?.close();
          remoteTools = RemoteAgentTools(
            connection,
            workingDirectory: workingDirectory,
          );
          _phoneTools[task.id] = remoteTools;
        }
        tools = _serializeRemoteWrites(
          remoteTools.tools,
          '${server.id}\u0000$workingDirectory',
        );
        systemPrompt = _systemPrompt(task, workingDirectory: workingDirectory);
      }

      client = OpenAiCompatibleClient(
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: provider.model,
      );
      final loop = AgentLoop(client: client, tools: tools);
      final history = _taskHistories[task.id];
      final initialMessages =
          history ?? _localHistory(systemPrompt, previousEvents);
      var eventQueue = Future<void>.value();
      final result = await loop.run(
        prompt: prompt,
        attachments: attachments,
        initialMessages: initialMessages,
        executionMode: task.executionMode,
        cancellation: cancellation,
        confirm: confirm,
        onEvent: (type, payload) {
          if (type == 'assistant.delta') {
            final delta = payload['text'];
            if (delta is String && delta.isNotEmpty) {
              _streamingAssistantText[task.id] =
                  '${_streamingAssistantText[task.id] ?? ''}$delta';
              _notify();
            }
            return Future.value();
          }
          if (type == 'assistant.completed' ||
              type == 'task.completed' ||
              type == 'task.failed' ||
              type == 'task.cancelled' ||
              type == 'task.unknown') {
            _streamingAssistantText.remove(task.id);
            _notify();
          }
          if (type == 'tool.completed' || type == 'task.unknown') {
            remoteOperationStarted = true;
          }
          eventQueue = eventQueue.then(
            (_) =>
                appendTaskEvent(taskId: task.id, type: type, payload: payload),
          );
          return eventQueue;
        },
      );
      _taskHistories[task.id] = result.messages;
      await updateTaskStatus(task.id, result.status);
      return result;
    } catch (error) {
      // A setup or persistence failure may happen before AgentLoop can return
      // its complete message list. Rebuild from durable events on retry.
      _taskHistories.remove(task.id);
      final status = remoteOperationStarted
          ? 'unknown'
          : cancellation.isCancelled
          ? 'cancelled'
          : 'failed';
      final eventType = status == 'cancelled'
          ? 'task.cancelled'
          : status == 'unknown'
          ? 'task.unknown'
          : 'task.failed';
      await appendTaskEvent(
        taskId: task.id,
        type: eventType,
        payload: {'error': '$error'},
      );
      await updateTaskStatus(task.id, status);
      return AgentResult(
        status: status,
        messages: _taskHistories[task.id] ?? const [],
        error: error,
      );
    } finally {
      _streamingAssistantText.remove(task.id);
      client?.close();
      if (task.mode == 'agent' && serviceStarted) {
        if (connection == null && cancellation.isCancelled) {
          _sshPool.abort(task.id);
        }
        try {
          await _releasePhoneTask(task.id);
        } catch (_) {
          // Cleanup must not replace a task result.
        }
        try {
          await _taskService.stop(task.id);
        } catch (_) {
          // The foreground service may already have been stopped by Android.
        }
      }
    }
  }

  void _finishTask(String taskId) {
    _taskRuns.remove(taskId);
    _runningTasks.remove(taskId);
    _notify();
  }

  List<AgentTool> _serializeRemoteWrites(
    List<AgentTool> tools,
    String leaseKey,
  ) {
    return [
      for (final tool in tools)
        if (!tool.writesRemoteState)
          tool
        else
          AgentTool(
            definition: tool.definition,
            requiresConfirmation: tool.requiresConfirmation,
            writesRemoteState: true,
            call: (arguments) =>
                _withRemoteWriteLease(leaseKey, () => tool.call(arguments)),
          ),
    ];
  }

  Future<Object?> _withRemoteWriteLease(
    String leaseKey,
    Future<Object?> Function() operation,
  ) {
    final previous = _remoteWriteTails[leaseKey] ?? Future<void>.value();
    late Future<Object?> current;
    current = previous.then<Object?>((_) => operation());
    final settled = current.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _remoteWriteTails[leaseKey] = settled;
    unawaited(
      settled.then<void>((_) {
        if (identical(_remoteWriteTails[leaseKey], settled)) {
          _remoteWriteTails.remove(leaseKey);
        }
      }),
    );
    return current;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void stopTask(String taskId) {
    final cancellation = _runningTasks[taskId];
    if (cancellation == null) return;
    cancellation.cancel();
    unawaited(_recordCancellationRequest(taskId));
    _notify();
  }

  Future<void> _recordCancellationRequest(String taskId) async {
    if (!_taskRuns.containsKey(taskId)) return;
    try {
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.cancel_requested',
        payload: const {},
      );
    } catch (_) {
      // The task result records the terminal state; this marker is only for
      // recovery if the process exits during cancellation.
    }
  }

  Future<SshHostKey> testServer(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) throw StateError('预览模式不会连接服务器');
    final connection = await _connectServer(
      profile,
      onFirstHostKey: onFirstHostKey,
    );
    try {
      final result = await connection.run('printf connected');
      if (result.exitCode != 0) throw StateError('SSH 测试命令失败');
      await _saveObservedHostKey(profile, connection.hostKey);
      return connection.hostKey;
    } finally {
      await connection.close();
    }
  }

  Future<SshCommandResult> runServerCommand(
    ServerProfile profile,
    String command, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (command.trim().isEmpty) throw ArgumentError('命令不能为空');
    if (previewMode) {
      return const SshCommandResult(
        stdout: '预览模式：未连接真实服务器。',
        stderr: '',
        exitCode: 0,
      );
    }
    final connection = await _connectServer(
      profile,
      onFirstHostKey: onFirstHostKey,
    );
    try {
      await _saveObservedHostKey(profile, connection.hostKey);
      return await connection.run(
        command,
        workingDirectory: profile.defaultWorkingDirectory,
      );
    } finally {
      await connection.close();
    }
  }

  Future<ServerTerminalSession> openServerTerminal(
    ServerProfile profile, {
    int width = 100,
    int height = 30,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) throw StateError('预览模式不会连接服务器');
    final connection = await _connectServer(
      profile,
      onFirstHostKey: onFirstHostKey,
    );
    try {
      await _saveObservedHostKey(profile, connection.hostKey);
      final stream = await connection.shell(width: width, height: height);
      final session = ServerTerminalSession(connection, stream);
      unawaited(
        stream.done.then<void>((_) async {
          if (!connection.isClosed) await connection.close();
        }),
      );
      return session;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  Future<List<SshDirectoryEntry>> listServerDirectory(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    bool forceRefresh = false,
  }) async {
    final path = remotePath.trim();
    if (path.isEmpty) throw ArgumentError('目录路径不能为空');
    final cacheKey = _directoryCacheKey(profile, path);
    final pending = _directoryLoads[cacheKey];
    if (pending != null) return pending;
    if (!forceRefresh) {
      final cached = _directoryCache[cacheKey];
      if (cached != null) return cached;
    }

    final request = _loadServerDirectory(
      profile,
      path,
      onFirstHostKey: onFirstHostKey,
    );
    _directoryLoads[cacheKey] = request;
    try {
      final entries = await request;
      final cachedEntries = List<SshDirectoryEntry>.unmodifiable(entries);
      _directoryCache[cacheKey] = cachedEntries;
      return cachedEntries;
    } finally {
      if (identical(_directoryLoads[cacheKey], request)) {
        _directoryLoads.remove(cacheKey);
      }
    }
  }

  List<SshDirectoryEntry>? cachedServerDirectory(
    ServerProfile profile,
    String remotePath,
  ) {
    final path = remotePath.trim();
    if (path.isEmpty) return null;
    return _directoryCache[_directoryCacheKey(profile, path)];
  }

  Future<List<SshDirectoryEntry>> _loadServerDirectory(
    ServerProfile profile,
    String path, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) {
      final base = path == '/' ? '/' : path;
      return [
        SshDirectoryEntry(
          name: 'app',
          path: base == '/' ? '/app' : '$base/app',
          isDirectory: true,
          size: null,
        ),
        SshDirectoryEntry(
          name: 'README.md',
          path: base == '/' ? '/README.md' : '$base/README.md',
          isDirectory: false,
          size: 2048,
        ),
      ];
    }
    return _withServerConnection(
      profile,
      (connection) => connection.listDirectory(path),
      onFirstHostKey: onFirstHostKey,
    );
  }

  Future<String> readServerFile(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (remotePath.trim().isEmpty) throw ArgumentError('文件路径不能为空');
    if (previewMode) {
      return '# PocketServerOps AI preview\n\nThis file is not on a real server.\n';
    }
    return _withServerConnection(
      profile,
      (connection) => connection.readFile(remotePath.trim()),
      onFirstHostKey: onFirstHostKey,
    );
  }

  Future<void> writeServerFile(
    ServerProfile profile,
    String remotePath,
    String content, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (remotePath.trim().isEmpty) throw ArgumentError('文件路径不能为空');
    if (previewMode) return;
    await _withServerConnection(
      profile,
      (connection) => connection.writeFile(
        remotePath.trim(),
        Uint8List.fromList(utf8.encode(content)),
      ),
      onFirstHostKey: onFirstHostKey,
    );
    _invalidateServerDirectoryCache(profile);
  }

  String _directoryCacheKey(ServerProfile profile, String remotePath) {
    return '${profile.id}\u0000${profile.host}\u0000${profile.port}'
        '\u0000${profile.username}\u0000${_normalizeRemotePath(remotePath)}';
  }

  void _invalidateServerDirectoryCache(ServerProfile profile) {
    _invalidateServerDirectoryCacheById(profile.id);
  }

  void _invalidateServerDirectoryCacheById(String serverId) {
    final prefix = '$serverId\u0000';
    _directoryCache.removeWhere((key, _) => key.startsWith(prefix));
  }

  Future<ServerDashboard> loadServerDashboard(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) {
      return const ServerDashboard(
        hostname: 'preview-server',
        os: 'Preview Linux',
        kernel: 'Linux 6.x',
        uptime: '2 days, 4 hours',
        load: '0.18 0.22 0.20',
        cpu: '4 cores',
        memory: '38% (1.5 / 4 GiB)',
        disk: '12G / 50G (24%)',
        statusScriptInstalled: true,
        disks: [
          ServerDisk(
            mount: '/',
            total: '50G',
            used: '12G',
            available: '38G',
            usedPercent: 24,
          ),
          ServerDisk(
            mount: '/www',
            total: '100G',
            used: '28G',
            available: '72G',
            usedPercent: 28,
          ),
        ],
        network: ServerNetwork(
          interfaceName: 'eth0',
          receivedBytes: 2_200_000_000,
          transmittedBytes: 1_300_000_000,
        ),
        processCount: 42,
      );
    }
    return _withServerConnection(profile, (connection) async {
      final result = await connection.run(statusProbeCommand);
      if (result.exitCode != 0) {
        throw StateError('服务器状态脚本执行失败');
      }
      return _parseDashboard(result.stdout);
    }, onFirstHostKey: onFirstHostKey);
  }

  Future<void> installServerStatusScript(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) return;
    await _withServerConnection(profile, (connection) async {
      final result = await connection.run(statusScriptInstallCommand);
      if (result.exitCode != 0) {
        throw StateError('状态脚本安装失败：${result.stderr}');
      }
    }, onFirstHostKey: onFirstHostKey);
  }

  Future<void> saveServer({
    ServerProfile? existing,
    required String name,
    required String host,
    required int port,
    required String username,
    required String secret,
    required String workingDirectory,
    String authType = 'password',
    String passphrase = '',
    bool clearPassphrase = false,
  }) async {
    final id = existing?.id ?? _newId('server');
    if (authType != 'password' && authType != 'privateKey') {
      throw ArgumentError('不支持的服务器认证方式');
    }
    final authTypeChanged = existing != null && existing.authType != authType;
    final endpointChanged =
        existing != null && (existing.host != host || existing.port != port);
    final credentialRef = existing?.credentialRef ?? 'server:$id:ssh';
    final passphraseRef = authType == 'privateKey'
        ? (existing?.credentialPassphraseRef ?? 'server:$id:passphrase')
        : null;
    if (secret.isNotEmpty) {
      await _credentials.write(credentialRef, secret);
    } else if (existing == null || authTypeChanged) {
      throw ArgumentError('首次保存服务器时必须填写密码或私钥');
    }
    await _database.saveServer(
      ServerProfile(
        id: id,
        name: name,
        host: host,
        port: port,
        username: username,
        authType: authType,
        credentialRef: credentialRef,
        credentialPassphraseRef: passphraseRef,
        hostKey: endpointChanged ? null : existing?.hostKey,
        hostKeyFingerprint: endpointChanged
            ? null
            : existing?.hostKeyFingerprint,
        defaultWorkingDirectory: workingDirectory.isEmpty
            ? null
            : workingDirectory,
      ),
    );
    if (authType == 'privateKey' && passphrase.isNotEmpty) {
      await _credentials.write(passphraseRef!, passphrase);
    } else if (authType == 'privateKey' &&
        clearPassphrase &&
        existing?.credentialPassphraseRef != null) {
      await _credentials.delete(existing!.credentialPassphraseRef!);
    } else if (authType != 'privateKey' &&
        existing?.credentialPassphraseRef != null) {
      await _credentials.delete(existing!.credentialPassphraseRef!);
    }
    _servers = [
      for (final profile in _servers)
        if (profile.id != id) profile,
      ServerProfile(
        id: id,
        name: name,
        host: host,
        port: port,
        username: username,
        authType: authType,
        credentialRef: credentialRef,
        credentialPassphraseRef: passphraseRef,
        hostKey: endpointChanged ? null : existing?.hostKey,
        hostKeyFingerprint: endpointChanged
            ? null
            : existing?.hostKeyFingerprint,
        defaultWorkingDirectory: workingDirectory.isEmpty
            ? null
            : workingDirectory,
      ),
    ]..sort((left, right) => left.name.compareTo(right.name));
    _invalidateServerDirectoryCacheById(id);
    _notify();
  }

  Future<void> deleteServer(ServerProfile profile) async {
    if (_tasks.any((task) => task.serverId == profile.id)) {
      throw StateError('服务器仍被历史任务使用，请先删除相关任务');
    }
    await _database.deleteServer(profile.id);
    if (profile.credentialRef != null) {
      await _credentials.delete(profile.credentialRef!);
    }
    if (profile.credentialPassphraseRef != null) {
      await _credentials.delete(profile.credentialPassphraseRef!);
    }
    _servers = [
      for (final item in _servers)
        if (item.id != profile.id) item,
    ];
    _invalidateServerDirectoryCache(profile);
    _notify();
  }

  Future<void> saveProvider({
    ProviderProfile? existing,
    required String name,
    required String baseUrl,
    required String model,
    required String secret,
    required bool isDefault,
  }) async {
    final id = existing?.id ?? _newId('provider');
    final apiKeyRef = existing?.apiKeyRef ?? 'provider:$id:api';
    if (secret.isNotEmpty) {
      await _credentials.write(apiKeyRef, secret);
    } else if (existing == null) {
      throw ArgumentError('首次保存供应商时必须填写 API Key');
    }
    if (isDefault) await _database.clearProviderDefaults();
    final saved = ProviderProfile(
      id: id,
      name: name,
      baseUrl: baseUrl,
      model: model,
      apiKeyRef: apiKeyRef,
      isDefault: isDefault,
    );
    await _database.saveProvider(saved);
    final providers = [
      for (final provider in _providers)
        if (provider.id != id)
          isDefault
              ? ProviderProfile(
                  id: provider.id,
                  name: provider.name,
                  baseUrl: provider.baseUrl,
                  model: provider.model,
                  apiKeyRef: provider.apiKeyRef,
                  isDefault: false,
                )
              : provider,
      saved,
    ]..sort((left, right) => left.name.compareTo(right.name));
    _providers = providers;
    _notify();
  }

  Future<void> deleteProvider(ProviderProfile profile) async {
    if (_tasks.any(
      (task) =>
          task.providerId == profile.id ||
          (task.providerId == null && profile.isDefault),
    )) {
      throw StateError('AI 供应商仍被历史任务使用，请先删除相关任务');
    }
    await _database.deleteProvider(profile.id);
    if (profile.apiKeyRef != null) {
      await _credentials.delete(profile.apiKeyRef!);
    }
    _providers = [
      for (final item in _providers)
        if (item.id != profile.id) item,
    ];
    _notify();
  }

  Future<void> testProvider(ProviderProfile profile) async {
    if (previewMode) throw StateError('预览模式不会发送真实供应商请求');
    final apiKey = await _readCredential(profile.apiKeyRef, 'API Key 不可用');
    await _providerTester.test(profile, apiKey);
  }

  Future<List<String>> loadProviderModels(
    ProviderProfile profile, {
    String? secret,
  }) async {
    if (previewMode) return const ['demo-model', 'demo-coder'];
    final apiKey =
        secret ?? await _readCredential(profile.apiKeyRef, 'API Key 不可用');
    return _providerTester.listModels(profile, apiKey);
  }

  ProviderProfile _providerForTask(Task task) {
    if (_providers.isEmpty) throw StateError('请先配置 AI 供应商');
    if (task.providerId != null) {
      return _providers.firstWhere((value) => value.id == task.providerId);
    }
    for (final provider in _providers) {
      if (provider.isDefault) return provider;
    }
    return _providers.first;
  }

  String _systemPrompt(Task task, {String? workingDirectory}) {
    if (task.mode == 'chat') {
      return 'You are a helpful conversational assistant. Do not claim to have '
          'access to a server, terminal, files, or tools.';
    }
    final directory = workingDirectory ?? task.workingDirectory ?? 'not set';
    return 'You are an autonomous server coding and operations agent running '
        'on a phone with SSH tools for the selected server. Work until the '
        'request is complete: inspect state, make changes, and verify the '
        'result. Use terminal.exec for short commands; use terminal.start, '
        'terminal.poll, terminal.write, and terminal.stop for long-running or '
        'interactive commands. Use file tools for UTF-8 text files. Never '
        'claim success without checking the result. The default working '
        'directory is $directory. Any terminal.start process still running '
        'when this turn ends will be stopped. Use a server service manager or '
        'a deliberately detached command only when a process must outlive the '
        'turn.';
  }

  Future<AgentResult> _runPreviewTask(
    Task task, {
    required String prompt,
    required List<AiAttachment> attachments,
    required List<AiMessage> initialHistory,
    required AgentCancellation cancellation,
  }) async {
    await updateTaskStatus(task.id, 'running');
    await appendTaskEvent(
      taskId: task.id,
      type: 'task.started',
      payload: {'mode': task.mode},
    );
    if (cancellation.isCancelled) {
      await appendTaskEvent(
        taskId: task.id,
        type: 'task.cancelled',
        payload: const {},
      );
      await updateTaskStatus(task.id, 'cancelled');
      return const AgentResult(status: 'cancelled', messages: []);
    }
    final text = task.mode == 'chat'
        ? '这是预览模式的普通对话回复。'
        : '这是预览模式的手机 Agent 回复，未连接真实服务器。';
    final messages = <AiMessage>[
      ...initialHistory,
      AiMessage.user(prompt, attachments: attachments),
      AiMessage(role: 'assistant', content: text),
    ];
    _taskHistories[task.id] = messages;
    await appendTaskEvent(
      taskId: task.id,
      type: 'assistant.completed',
      payload: {'text': text},
    );
    await appendTaskEvent(
      taskId: task.id,
      type: 'task.completed',
      payload: {'text': text},
    );
    await updateTaskStatus(task.id, 'completed');
    return AgentResult(
      status: 'completed',
      messages: List.unmodifiable(messages),
      finalText: text,
    );
  }

  List<AiMessage> _localHistory(String systemPrompt, List<TaskEvent> events) {
    final messages = <AiMessage>[
      AiMessage(role: 'system', content: systemPrompt),
    ];
    int? assistantIndex;
    // Responses uses the output item id for the assistant call and a
    // separate call_id for the function_call_output.
    var activeToolCallIds = <String, String>{};
    for (final event in events) {
      switch (event.type) {
        case 'user.message':
          final text = event.payload['text'];
          final attachments = _readAttachments(event.payload['attachments']);
          if ((text is String && text.isNotEmpty) || attachments.isNotEmpty) {
            messages.add(
              AiMessage.user(
                text is String ? text : '',
                attachments: attachments,
              ),
            );
          }
          assistantIndex = null;
          activeToolCallIds = <String, String>{};
        case 'assistant.completed':
          final calls = _readToolCalls(event.payload['tool_calls']);
          final text = event.payload['text'];
          messages.add(
            AiMessage(
              role: 'assistant',
              content: text is String ? text : '',
              toolCalls: calls,
              finishReason: event.payload['finish_reason'] is String
                  ? event.payload['finish_reason'] as String
                  : null,
              responsesOutputItems: _readResponsesOutputItems(
                event.payload['responses_output_items'],
              ),
            ),
          );
          assistantIndex = messages.length - 1;
          activeToolCallIds = {
            for (final call in calls) call.id: call.effectiveCallId,
          };
        case 'tool.started':
          final id = event.payload['id'];
          final name = event.payload['name'];
          final callId = event.payload['call_id'];
          final index = assistantIndex;
          if (id is String &&
              name is String &&
              callId is String &&
              callId.isNotEmpty &&
              index != null &&
              !activeToolCallIds.containsKey(id)) {
            final assistant = messages[index];
            messages[index] = AiMessage(
              role: assistant.role,
              content: assistant.content,
              toolCalls: [
                ...assistant.toolCalls,
                AiToolCall(
                  id: id,
                  name: name,
                  arguments: jsonEncode(
                    event.payload['arguments'] ?? const <String, Object?>{},
                  ),
                  callId: callId,
                ),
              ],
              responsesOutputItems: assistant.responsesOutputItems,
            );
            activeToolCallIds[id] = callId;
          } else if (id is String &&
              name is String &&
              index != null &&
              !activeToolCallIds.containsKey(id)) {
            throw StateError(
              'Stored Responses tool.started event is missing call_id',
            );
          }
        case 'tool.completed':
        case 'tool.failed':
          final id = event.payload['id'];
          if (id is! String || !activeToolCallIds.containsKey(id)) continue;
          final content = event.type == 'tool.completed'
              ? jsonEncode(event.payload['result'])
              : '${event.payload['error'] ?? 'Tool call failed'}';
          final callId = event.payload['call_id'];
          final resolvedCallId = callId is String && callId.isNotEmpty
              ? callId
              : activeToolCallIds[id];
          if (resolvedCallId == null || resolvedCallId.isEmpty) {
            throw StateError('Stored Responses tool result is missing call_id');
          }
          messages.add(
            AiMessage.tool(
              toolCallId: resolvedCallId,
              content: _toolResultContent(content),
            ),
          );
          activeToolCallIds.remove(id);
        case 'task.recovered':
          _appendPendingToolResults(
            messages,
            activeToolCallIds,
            'The previous mobile task was interrupted. Inspect the server '
            'before continuing.',
          );
        case 'task.cancelled':
          _appendPendingToolResults(
            messages,
            activeToolCallIds,
            'The tool call was cancelled. The remote result is unknown; '
            'inspect the server before continuing.',
          );
        case 'task.unknown':
          final error = event.payload['error'];
          _appendPendingToolResults(
            messages,
            activeToolCallIds,
            error is String && error.isNotEmpty
                ? error
                : 'The remote tool result is unknown; inspect the server '
                      'before continuing.',
          );
        case 'task.failed':
          _appendPendingToolResults(
            messages,
            activeToolCallIds,
            'The task failed before the tool result was recorded.',
          );
        case 'task.context_changed':
          if (event.payload['history_boundary'] == true) {
            messages
              ..clear()
              ..add(AiMessage(role: 'system', content: systemPrompt))
              ..add(
                const AiMessage(
                  role: 'developer',
                  content:
                      'The conversation target or AI provider changed. '
                      'Treat the earlier transcript as display history only. '
                      'Inspect the newly selected server before acting.',
                ),
              );
            assistantIndex = null;
            activeToolCallIds = <String, String>{};
          }
      }
    }
    _dropHistoryBeforeLatestCompaction(messages);
    return messages;
  }

  static void _appendPendingToolResults(
    List<AiMessage> messages,
    Map<String, String> toolCallIds,
    String content,
  ) {
    for (final callId in toolCallIds.values) {
      messages.add(
        AiMessage.tool(
          toolCallId: callId,
          content: _toolResultContent(content),
        ),
      );
    }
    toolCallIds.clear();
  }

  static List<AiToolCall> _readToolCalls(Object? value) {
    if (value is! List) return const [];
    final calls = <AiToolCall>[];
    for (final item in value) {
      if (item is! Map) continue;
      final id = item['id'];
      final function = item['function'];
      if (id is! String || function is! Map) continue;
      final name = function['name'];
      final arguments = function['arguments'];
      final callId = item['call_id'];
      if (name is! String || arguments is! String) continue;
      if (callId is! String || callId.isEmpty) {
        throw StateError('Stored Responses function call is missing call_id');
      }
      calls.add(
        AiToolCall(
          id: id,
          name: name,
          arguments: _validToolArguments(arguments),
          callId: callId,
        ),
      );
    }
    return calls;
  }

  static List<AiAttachment> _readAttachments(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map) AiAttachment.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  static List<Map<String, Object?>> _readResponsesOutputItems(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map) Map<String, Object?>.from(item),
    ];
  }

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

  static String _validToolArguments(String arguments) {
    try {
      decodeObject(arguments);
      return arguments;
    } catch (_) {
      return '{"history_unavailable":true}';
    }
  }

  Future<void> _saveObservedHostKey(
    ServerProfile profile,
    SshHostKey key,
  ) async {
    ServerProfile? current;
    for (final server in _servers) {
      if (server.id == profile.id) {
        current = server;
        break;
      }
    }
    if (current == null ||
        current.host != profile.host ||
        current.port != profile.port ||
        current.username != profile.username) {
      return;
    }
    if (current.hostKeyFingerprint == key.fingerprint) return;
    final updated = current.copyWith(
      hostKey: key.type,
      hostKeyFingerprint: key.fingerprint,
    );
    await _database.saveServer(updated);
    _servers = [
      for (final server in _servers) server.id == updated.id ? updated : server,
    ];
    _notify();
  }

  Future<void> _releasePhoneTask(String taskId) async {
    final tools = _phoneTools.remove(taskId);
    try {
      await tools?.close();
    } finally {
      await _sshPool.release(taskId);
    }
  }

  Future<void> _closePhoneTasks() async {
    for (final taskId in _phoneTools.keys.toList()) {
      try {
        await _releasePhoneTask(taskId);
      } catch (_) {
        // Continue closing the remaining task connections.
      }
    }
    try {
      await _sshPool.close();
    } catch (_) {
      // Resource cleanup is best effort during app shutdown.
    }
  }

  Future<String> _readCredential(String? ref, String message) async {
    if (ref == null) throw StateError(message);
    final value = await _credentials.read(ref);
    if (value == null || value.isEmpty) throw StateError(message);
    return value;
  }

  Future<SshConnection> _connectServer(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    final current = _servers.firstWhere(
      (value) => value.id == profile.id,
      orElse: () => throw StateError('服务器配置已删除'),
    );
    final secret = await _readCredential(current.credentialRef, '服务器认证凭据不可用');
    final passphrase = current.credentialPassphraseRef == null
        ? null
        : await _credentials.read(current.credentialPassphraseRef!);
    return _sshConnector.connect(
      SshConnectionConfig(
        host: current.host,
        port: current.port,
        username: current.username,
        password: current.authType == 'password' ? secret : null,
        privateKeyPem: current.authType == 'privateKey' ? secret : null,
        privateKeyPassphrase: passphrase,
        expectedFingerprint: current.hostKeyFingerprint,
        onFirstHostKey: onFirstHostKey,
        onUserInfoRequest: onUserInfoRequest,
      ),
    );
  }

  Future<T> _withServerConnection<T>(
    ServerProfile profile,
    Future<T> Function(SshConnection connection) action, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final connection = await _connectServer(
      profile,
      onFirstHostKey: onFirstHostKey,
    );
    try {
      await _saveObservedHostKey(profile, connection.hostKey);
      return await action(connection);
    } finally {
      await connection.close();
    }
  }

  static ServerDashboard _parseDashboard(String output) {
    final values = <String, String>{};
    for (final line in output.split('\n')) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.substring(0, separator)] = line.substring(separator + 1);
    }
    return ServerDashboard(
      hostname: values['hostname'] ?? 'unknown',
      os: values['os'] ?? 'unknown',
      kernel: values['kernel'] ?? 'unknown',
      uptime: values['uptime'] ?? 'unknown',
      load: values['load'] ?? 'unknown',
      cpu: values['cpu'] ?? 'unknown',
      memory: values['memory'] ?? 'unknown',
      disk: values['disk'] ?? 'unknown',
      statusScriptInstalled: values['script_version'] == '1',
      disks: _parseDisks(values['disk_details']),
      network: _parseNetwork(values['network']),
      processCount: int.tryParse(values['processes'] ?? ''),
    );
  }

  static List<ServerDisk> _parseDisks(String? value) {
    if (value == null || value.isEmpty) return const [];
    final disks = <ServerDisk>[];
    for (final item in value.split(';')) {
      final parts = item.split('|');
      if (parts.length < 5) continue;
      disks.add(
        ServerDisk(
          mount: parts[0],
          total: parts[1],
          used: parts[2],
          available: parts[3],
          usedPercent: int.tryParse(parts[4]),
        ),
      );
    }
    return disks;
  }

  static ServerNetwork? _parseNetwork(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('|');
    if (parts.length < 3) return null;
    final receivedBytes = int.tryParse(parts[1]);
    final transmittedBytes = int.tryParse(parts[2]);
    if (receivedBytes == null || transmittedBytes == null) return null;
    return ServerNetwork(
      interfaceName: parts[0],
      receivedBytes: receivedBytes,
      transmittedBytes: transmittedBytes,
    );
  }

  static Map<String, Object?> _eventPayload(Map<String, Object?> payload) {
    // Responses output items can contain an opaque compaction payload up to
    // the provider's documented item size. Do not truncate event payloads;
    // they are the durable source used to rebuild the next AI request.
    return payload;
  }

  static String _toolResultContent(String value) {
    return value;
  }

  String _newId(String prefix) {
    _idSequence++;
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$_idSequence';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final cancellation in _runningTasks.values) {
      cancellation.cancel();
    }
    final runs = List<Future<AgentResult>>.of(_taskRuns.values);
    unawaited(_disposeAsync(runs));
    super.dispose();
  }

  Future<void> _disposeAsync(List<Future<AgentResult>> runs) async {
    await _closePhoneTasks();
    try {
      await Future.wait(runs, eagerError: false);
    } catch (_) {
      // Continue closing resources after a task failure.
    }
    await Future.wait(
      List<Future<void>>.of(_taskEventTails.values),
      eagerError: false,
    );
    await _database.close();
  }
}

const _agentAutoExecuteSetting = 'agent_auto_execute';
const _betaUpdatesSetting = 'beta_updates_enabled';

String _normalizeRemotePath(String value) {
  final path = value.trim();
  if (path.length <= 1) return path;
  return path.replaceFirst(RegExp(r'/+$'), '');
}

String? _statusForTerminalEvent(String type) {
  switch (type) {
    case 'task.completed':
      return 'completed';
    case 'task.failed':
      return 'failed';
    case 'task.cancelled':
      return 'cancelled';
    case 'task.unknown':
      return 'unknown';
    default:
      return null;
  }
}
