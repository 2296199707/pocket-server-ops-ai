import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'agent/agent_loop.dart';
import 'agent/agent_tools.dart';
import 'agent/ai_client_factory.dart';
import 'agent/context_usage.dart';
import 'agent/ai_protocol.dart';
import 'agent/auto_review.dart';
import 'agent/openai_compatible_client.dart';
import 'agent/remote_instructions.dart';
import 'agent/remote_write_queue.dart';
import 'credentials/credential_store.dart';
import 'domain/models.dart';
import 'local/local_preview.dart';
import 'local/project_files.dart';
import 'local/local_file_access.dart';
import 'platform/android_task_service.dart';
import 'platform/android_storage_access.dart';
import 'providers/provider_connection_tester.dart';
import 'providers/image_generation_client.dart';
import 'providers/provider_usage_client.dart';
import 'server_status_script.dart';
import 'ssh/ssh_connection.dart';
import 'storage/app_database.dart';
import 'storage/attachment_store.dart';

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
    ProviderUsageClient? providerUsageClient,
    SshConnector? sshConnector,
    AndroidTaskService? taskService,
    AttachmentStore? attachmentStore,
    this.previewMode = false,
  }) : _database = database ?? AppDatabase(),
       // Keep the public parameter name; a private named initializing formal
       // cannot be used by callers from another library.
       // ignore: prefer_initializing_formals
       _credentials = credentials,
       _providerTester = providerTester ?? ProviderConnectionTester(),
       _providerUsageClient = providerUsageClient ?? ProviderUsageClient(),
       _sshConnector = sshConnector ?? DartSshConnector(),
       _taskService = taskService ?? const AndroidTaskService(),
       _attachmentStore = attachmentStore ?? AttachmentStore();

  final AppDatabase _database;
  final CredentialStore _credentials;
  final ProviderConnectionTester _providerTester;
  final ProviderUsageClient _providerUsageClient;
  final SshConnector _sshConnector;
  final AndroidTaskService _taskService;
  final AttachmentStore _attachmentStore;
  final bool previewMode;
  final ProjectFileStore _projectFiles = const ProjectFileStore();
  final RemoteProjectInstructions _remoteInstructions =
      const RemoteProjectInstructions();
  final LocalPreviewServer _localPreview = LocalPreviewServer();
  final TaskSshConnectionPool _sshPool = TaskSshConnectionPool();
  final Map<String, AgentCancellation> _runningTasks = {};
  final Map<String, Future<AgentResult>> _taskRuns = {};
  final Map<String, String> _taskRunIds = {};
  final Map<String, LocalFileAccessStore> _localAccess = {};
  final Map<String, RemoteAgentTools> _phoneTools = {};
  final Map<String, List<SshDirectoryEntry>> _directoryCache = {};
  final Map<String, Future<List<SshDirectoryEntry>>> _directoryLoads = {};
  final Map<String, List<ProjectFileEntry>> _projectDirectoryCache = {};
  final Map<String, Future<List<ProjectFileEntry>>> _projectDirectoryLoads = {};
  final RemoteWriteQueue _remoteWriteQueue = RemoteWriteQueue();
  final Map<String, Future<void>> _taskEventTails = {};
  final Map<String, Future<void>> _taskStatusTails = {};
  final Map<String, Future<void>> _eventLoads = {};
  final Map<String, Future<void>> _attachmentMigrations = {};
  final Set<String> _loadedTaskEvents = {};
  final Map<String, bool> _hasEarlierTaskEvents = {};
  final Map<String, String> _streamingAssistantText = {};
  final Map<String, ProviderUsageSnapshot> _providerUsages = {};
  final Map<String, Future<ProviderUsageSnapshot>> _providerUsageLoads = {};
  final Map<String, TaskContextUsage> _taskContextUsages = {};
  final Map<String, Future<TaskContextUsage>> _taskContextLoads = {};
  final Map<String, Future<TaskContextUsage>> _taskCompactions = {};
  final Map<String, int> _taskContextGenerations = {};
  Future<void> _loadTail = Future<void>.value();
  int _idSequence = 0;

  List<ServerProfile> _servers = const [];
  List<ProviderProfile> _providers = const [];
  List<Project> _projects = const [];
  List<Task> _tasks = const [];
  Map<String, List<TaskEvent>> _events = const {};
  bool _agentAutoExecute = false;
  bool _betaUpdatesEnabled = false;
  String? _imageProviderId;
  String? _lastDashboardServerId;
  double _fontScale = 1.0;
  bool _loading = true;
  String? _loadError;
  bool _disposed = false;

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  List<ProviderProfile> get providers => List.unmodifiable(_providers);
  List<Project> get projects => List.unmodifiable(_projects);
  List<Task> get tasks => List.unmodifiable(_tasks);
  bool get agentAutoExecute => _agentAutoExecute;
  bool get betaUpdatesEnabled => _betaUpdatesEnabled;
  String? get lastDashboardServerId => _lastDashboardServerId;
  double get fontScale => _fontScale;
  String? get imageProviderId => _imageProviderId;
  bool get isLoading => _loading;
  String? get loadError => _loadError;

  ProviderUsageSnapshot? providerUsageFor(String providerId) =>
      _providerUsages[providerId];

  ProviderModelMetadata? modelMetadataFor(
    ProviderProfile provider,
    String model,
  ) => provider.modelMetadata[model];

  TaskContextUsage? contextUsageFor(Task task, {ProviderProfile? provider}) {
    final cached = _taskContextUsages[task.id];
    if (cached == null) return null;
    final activeProvider = _contextProviderFor(task, provider);
    return cached.withMetadata(
      _contextMetadataForTask(task, activeProvider),
      selectedModel: _modelForTask(task, activeProvider),
    );
  }

  Future<TaskContextUsage> loadTaskContextUsage(
    Task task, {
    ProviderProfile? provider,
  }) async {
    final activeProvider = _contextProviderFor(task, provider);
    final metadata = _contextMetadataForTask(task, activeProvider);
    final model = _modelForTask(task, activeProvider);
    final cached = _taskContextUsages[task.id];
    if (cached != null) {
      return cached.withMetadata(metadata, selectedModel: model);
    }
    final pending = _taskContextLoads[task.id];
    if (pending != null) return pending;
    final generation = _taskContextGenerations[task.id] ?? 0;
    final load = _loadTaskContextUsage(
      task,
      metadata,
      model,
      generation,
      activeProvider?.id,
    );
    _taskContextLoads[task.id] = load;
    try {
      return await load;
    } finally {
      if (identical(_taskContextLoads[task.id], load)) {
        _taskContextLoads.remove(task.id);
      }
    }
  }

  ProviderProfile? imageProviderFor(Task task) {
    final selectedId = _imageProviderId ?? task.providerId;
    if (selectedId != null) {
      for (final provider in _providers) {
        if (provider.id == selectedId) return provider;
      }
    }
    for (final provider in _providers) {
      if (provider.isDefault) return provider;
    }
    return _providers.isEmpty ? null : _providers.first;
  }

  bool isTaskRunning(String taskId) => _runningTasks.containsKey(taskId);

  bool isTaskCompacting(String taskId) => _taskCompactions.containsKey(taskId);

  String? activeTurnIdFor(String taskId) => _taskRunIds[taskId];

  List<TaskEvent> eventsFor(String taskId) {
    return List.unmodifiable(_events[taskId] ?? const <TaskEvent>[]);
  }

  bool taskEventsLoaded(String taskId) => _loadedTaskEvents.contains(taskId);

  bool hasEarlierTaskEvents(String taskId) =>
      _hasEarlierTaskEvents[taskId] ?? false;

  Future<Uint8List> loadAttachmentBytes(
    String attachmentId, {
    required String taskId,
  }) async {
    final record = await _database.loadAttachment(attachmentId);
    if (record == null) throw StateError('附件记录不存在');
    if (record.taskId != taskId) {
      throw StateError('附件不属于当前对话');
    }
    return _attachmentStore.read(record);
  }

  Future<void> ensureTaskEventsLoaded(String taskId) {
    if (_loadedTaskEvents.contains(taskId)) return Future.value();
    final pending = _eventLoads[taskId];
    if (pending != null) return pending;
    final load = _loadRecentTaskEvents(taskId);
    _eventLoads[taskId] = load;
    return load.whenComplete(() {
      if (identical(_eventLoads[taskId], load)) _eventLoads.remove(taskId);
    });
  }

  Future<void> _loadRecentTaskEvents(String taskId) async {
    await _migrateLegacyAttachments(taskId);
    final page = await _database.loadRecentEvents(taskId);
    if (!_tasks.any((task) => task.id == taskId)) return;
    _events = {
      ..._events,
      taskId: List.unmodifiable(_mergeEvents(page.events, eventsFor(taskId))),
    };
    _hasEarlierTaskEvents[taskId] = page.hasEarlier;
    _loadedTaskEvents.add(taskId);
    _notify();
  }

  Future<void> loadEarlierTaskEvents(String taskId) async {
    await ensureTaskEventsLoaded(taskId);
    final current = eventsFor(taskId);
    if (current.isEmpty || !hasEarlierTaskEvents(taskId)) return;
    final page = await _database.loadEventsBefore(
      taskId,
      beforeSequence: current.first.sequence,
    );
    if (!_tasks.any((task) => task.id == taskId)) return;
    final latest = eventsFor(taskId);
    _events = {
      ..._events,
      taskId: List.unmodifiable(_mergeEvents(page.events, latest)),
    };
    _hasEarlierTaskEvents[taskId] = page.hasEarlier;
    _notify();
  }

  static List<TaskEvent> _mergeEvents(
    List<TaskEvent> earlier,
    List<TaskEvent> later,
  ) {
    final byId = <String, TaskEvent>{
      for (final event in earlier) event.eventId: event,
      for (final event in later) event.eventId: event,
    };
    final events = byId.values.toList()
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    return events;
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
    _projects = await _database.loadProjects();
    _agentAutoExecute =
        await _database.readSetting(_agentAutoExecuteSetting) == 'true';
    _betaUpdatesEnabled =
        await _database.readSetting(_betaUpdatesSetting) == 'true';
    final savedImageProviderId = await _database.readSetting(
      _imageProviderSetting,
    );
    _imageProviderId = savedImageProviderId?.isEmpty == true
        ? null
        : savedImageProviderId;
    final savedDashboardServerId = await _database.readSetting(
      _lastDashboardServerSetting,
    );
    _lastDashboardServerId = savedDashboardServerId?.isEmpty == true
        ? null
        : savedDashboardServerId;
    _fontScale =
        (double.tryParse(
                  await _database.readSetting(_fontScaleSetting) ?? '',
                ) ??
                1.0)
            .clamp(0.85, 1.15)
            .toDouble();
    final storedTasks = await _database.loadTasks();
    final eventsByTask = <String, List<TaskEvent>>{};

    final recoveredTasks = <Task>[];
    for (final task in storedTasks) {
      if ((task.status == 'running' ||
              task.status == 'waiting' ||
              task.status == 'stopping') &&
          !_runningTasks.containsKey(task.id)) {
        final latestEvent = await _database.loadLatestEvent(task.id);
        final terminalEvent = await _database.loadLatestTerminalEvent(task.id);
        final terminalStatus =
            terminalEvent != null &&
                _terminalEventMatchesLatestEvent(terminalEvent, latestEvent)
            ? _statusForTerminalEvent(terminalEvent.type)
            : null;
        if (terminalStatus != null) {
          final recovered = task.copyWith(status: terminalStatus);
          await _database.saveTask(recovered);
          eventsByTask[task.id] = [terminalEvent!];
          recoveredTasks.add(recovered);
        } else {
          final recovered = task.copyWith(status: 'unknown');
          await _database.saveTask(recovered);
          final recovery = TaskEvent(
            eventId: _newId('event'),
            taskId: task.id,
            sequence: await _database.nextEventSequence(task.id),
            type: 'task.recovered',
            timestamp: DateTime.now().toUtc(),
            payload: {'previousStatus': task.status},
          );
          await _database.saveEvent(recovery);
          eventsByTask[task.id] = [recovery];
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
    _loadedTaskEvents.clear();
    _hasEarlierTaskEvents.clear();
    _loading = false;
    _notify();
  }

  Project? projectFor(String? projectId) {
    if (projectId == null) return null;
    for (final project in _projects) {
      if (project.id == projectId) return project;
    }
    return null;
  }

  int localAccessCount(String taskId) =>
      _localAccess[taskId]?.grants.length ?? 0;

  Future<bool> hasLocalAccess(
    String taskId,
    String path, {
    bool write = false,
  }) async {
    return await _localAccess[taskId]?.hasAccess(path, write: write) ?? false;
  }

  Future<LocalFileGrant> grantLocalAccess(
    String taskId,
    String path, {
    required bool canWrite,
  }) async {
    final canonical = await LocalFileAccessStore.canonicalExistingPath(path);
    if (await _isProtectedLocalPath(canonical)) {
      throw StateError('应用凭据和内部数据不能授权给 AI');
    }
    await AndroidStorageAccess.ensureForPath(canonical);
    final store = _localAccess.putIfAbsent(taskId, LocalFileAccessStore.new);
    final grant = await store.add(canonical, canWrite: canWrite);
    _notify();
    return grant;
  }

  void revokeLocalAccess(String taskId) {
    _localAccess.remove(taskId);
    _notify();
  }

  Future<bool> _isProtectedLocalPath(String candidate) async {
    final roots = <String>[];
    try {
      final databases = await getDatabasesPath();
      roots.add(path_util.posix.dirname(databases));
    } on Object {
      // Some unit-test and desktop hosts do not expose an app database path.
    }
    try {
      roots.add((await getApplicationSupportDirectory()).path);
    } on Object {
      // The secure credential store remains inaccessible through file tools.
    }
    try {
      roots.add((await getApplicationDocumentsDirectory()).path);
    } on Object {
      // Some unit-test and desktop hosts do not expose an app documents path.
    }
    try {
      roots.add((await getTemporaryDirectory()).path);
    } on Object {
      // Temporary app data is not a user-selected project scope.
    }
    // If the platform cannot identify any app-private root, do not grant a
    // path that might contain the secure-storage integration's files.
    if (roots.isEmpty) return true;
    return roots.any((root) {
      return LocalFileAccessStore.scopesOverlapCanonical(candidate, root);
    });
  }

  Future<Project> createProject({
    required String name,
    String? localPath,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) throw ArgumentError('项目名称不能为空');
    final id = _newId('project');
    final path =
        _normalizeOptionalValue(localPath) ??
        await ProjectFileStore.defaultProjectPath(id);
    await _ensureProjectStoragePath(path);
    final project = Project(id: id, name: normalizedName, localPath: path);
    await _projectFiles.ensureRoot(project);
    await _database.saveProject(project);
    _projects = [..._projects, project]
      ..sort((left, right) => left.name.compareTo(right.name));
    _notify();
    return project;
  }

  Future<Project> updateProject({
    required Project project,
    required String name,
    required String localPath,
  }) async {
    final normalizedName = name.trim();
    final normalizedPath = localPath.trim();
    if (normalizedName.isEmpty) throw ArgumentError('项目名称不能为空');
    if (normalizedPath.isEmpty) throw ArgumentError('项目文件夹不能为空');
    if (project.localPath != normalizedPath) {
      await _localPreview.stop(project);
    }
    await _ensureProjectStoragePath(normalizedPath);
    final updated = project.copyWith(
      name: normalizedName,
      localPath: normalizedPath,
    );
    await _projectFiles.ensureRoot(updated);
    await _database.saveProject(updated);
    _invalidateProjectDirectoryCache(project.id);
    _projects = [..._projects]
      ..removeWhere((item) => item.id == updated.id)
      ..add(updated)
      ..sort((left, right) => left.name.compareTo(right.name));
    _notify();
    return updated;
  }

  Future<void> deleteProject(
    Project project, {
    bool deleteFiles = false,
  }) async {
    if (_tasks.any((task) => task.projectId == project.id)) {
      throw StateError('项目仍有对话，不能删除');
    }
    await _localPreview.stop(project);
    await _database.deleteProject(project.id);
    _invalidateProjectDirectoryCache(project.id);
    _projects = [
      for (final item in _projects)
        if (item.id != project.id) item,
    ];
    _notify();
    if (deleteFiles) {
      try {
        await _projectFiles.deleteContents(project);
      } catch (error) {
        throw StateError('项目配置已删除，但绑定文件夹内容未能完全清理：$error');
      }
    }
  }

  Future<Task> createTask({
    String mode = 'chat',
    String? workMode,
    String? projectId,
    String? serverId,
    String? providerId,
    String? reviewProviderId,
    String? reviewModelOverride,
    required String title,
    String? workingDirectory,
    String? executionMode,
    String? modelOverride,
    String? reasoningEffortOverride,
  }) async {
    if (mode != 'chat' && mode != 'agent') {
      throw ArgumentError('不支持的任务模式：$mode');
    }
    final normalizedWorkMode = resolveWorkMode(
      workMode: workMode,
      mode: mode,
      projectId: projectId,
      serverId: serverId,
    );
    final normalizedMode = taskModeForWorkMode(normalizedWorkMode);
    if (workModeUsesServer(normalizedWorkMode) &&
        (serverId == null || serverId.isEmpty)) {
      throw ArgumentError('服务器工作模式需要选择目标服务器');
    }
    final requestedExecutionMode =
        executionMode ??
        (normalizedMode == 'agent' && _agentAutoExecute ? 'auto' : 'confirm');
    final normalizedExecutionMode = _normalizeExecutionMode(
      requestedExecutionMode,
    );
    final now = DateTime.now().toUtc();
    final task = Task(
      id: _newId('task'),
      mode: normalizedMode,
      workMode: normalizedWorkMode,
      projectId: projectId,
      serverId: normalizedMode == 'agent' ? serverId : null,
      providerId: providerId,
      reviewProviderId: normalizedMode == 'agent'
          ? _normalizeOptionalValue(reviewProviderId)
          : null,
      reviewModelOverride: normalizedMode == 'agent'
          ? _normalizeOptionalValue(reviewModelOverride)
          : null,
      modelOverride: _normalizeOptionalValue(modelOverride),
      reasoningEffortOverride: _normalizeOptionalValue(reasoningEffortOverride),
      title: title,
      workingDirectory: normalizedMode == 'agent' ? workingDirectory : null,
      executionMode: normalizedExecutionMode,
      status: 'queued',
      createdAt: now,
      updatedAt: now,
    );
    await _database.saveTask(task);
    _tasks = [task, ..._tasks];
    _events = {..._events, task.id: const <TaskEvent>[]};
    _loadedTaskEvents.add(task.id);
    _hasEarlierTaskEvents[task.id] = false;
    _notify();
    return task;
  }

  Future<Task> createContinuationTask(Task source) {
    return createTask(
      mode: source.mode,
      workMode: source.effectiveWorkMode,
      projectId: source.projectId,
      serverId: source.serverId,
      providerId: source.providerId,
      reviewProviderId: source.reviewProviderId,
      reviewModelOverride: source.reviewModelOverride,
      modelOverride: source.modelOverride,
      reasoningEffortOverride: source.reasoningEffortOverride,
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

  Future<void> setFontScale(double scale) async {
    final value = scale.clamp(0.85, 1.15).toDouble();
    await _database.writeSetting(_fontScaleSetting, '$value');
    _fontScale = value;
    _notify();
  }

  Future<void> setImageProviderId(String? providerId) async {
    final value = providerId?.trim();
    if (value != null &&
        value.isNotEmpty &&
        !_providers.any((provider) => provider.id == value)) {
      throw StateError('图片供应商不存在');
    }
    await _database.writeSetting(_imageProviderSetting, value ?? '');
    _imageProviderId = value == null || value.isEmpty ? null : value;
    _notify();
  }

  Future<void> setLastDashboardServer(String? serverId) async {
    final value = serverId?.trim();
    await _database.writeSetting(_lastDashboardServerSetting, value ?? '');
    _lastDashboardServerId = value == null || value.isEmpty ? null : value;
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
    String? workMode,
    String? projectId,
    required String? serverId,
    required String? providerId,
    String? reviewProviderId,
    String? reviewModelOverride,
    required String? workingDirectory,
    required String executionMode,
    String? modelOverride,
    String? reasoningEffortOverride,
  }) async {
    if (mode != 'chat' && mode != 'agent') {
      throw ArgumentError('不支持的任务模式：$mode');
    }
    if (_taskRuns.containsKey(taskId)) {
      throw StateError('任务正在运行，不能修改对话设置');
    }
    if (_taskCompactions.containsKey(taskId)) {
      throw StateError('上下文正在压缩，不能修改对话设置');
    }

    final current = _tasks.firstWhere((task) => task.id == taskId);
    final normalizedProjectId = projectId ?? current.projectId;
    // Keep the explicit work mode when the caller is only updating fields.
    // Older callers only know about `mode`; when that value changes, infer a
    // compatible work mode from the new bindings instead.
    final requestedWorkMode =
        workMode ?? (mode == current.mode ? current.workMode : null);
    final normalizedWorkMode = resolveWorkMode(
      workMode: requestedWorkMode,
      mode: mode,
      projectId: normalizedProjectId,
      serverId: serverId,
    );
    final normalizedMode = taskModeForWorkMode(normalizedWorkMode);
    if (workModeUsesServer(normalizedWorkMode) &&
        (serverId == null || serverId.isEmpty)) {
      throw ArgumentError('服务器工作模式需要选择目标服务器');
    }
    final normalizedExecutionMode = _normalizeExecutionMode(executionMode);
    final normalizedServerId = normalizedMode == 'agent' ? serverId : null;
    final normalizedWorkingDirectory = normalizedMode == 'agent'
        ? workingDirectory
        : null;
    final normalizedReviewProviderId = normalizedMode == 'agent'
        ? reviewProviderId == null
              ? current.reviewProviderId
              : _normalizeOptionalValue(reviewProviderId)
        : null;
    final normalizedReviewModelOverride = normalizedMode == 'agent'
        ? reviewModelOverride == null
              ? current.reviewModelOverride
              : _normalizeOptionalValue(reviewModelOverride)
        : null;
    final normalizedModelOverride = modelOverride == null
        ? current.modelOverride
        : _normalizeOptionalValue(modelOverride);
    final normalizedReasoningEffortOverride = reasoningEffortOverride == null
        ? current.reasoningEffortOverride
        : _normalizeOptionalValue(reasoningEffortOverride);
    final previousProvider = _contextProviderFor(current, null);
    final nextProvider = _providerForOptionalId(providerId);
    final previousModel = _modelForTask(current, previousProvider);
    final nextModel = normalizedModelOverride ?? nextProvider?.model ?? '';
    final previousMetadata = previousProvider == null
        ? null
        : previousProvider.modelMetadata[previousModel];
    final nextMetadata = nextProvider == null
        ? null
        : nextProvider.modelMetadata[nextModel];
    final providerContextChanged =
        _providerContextIdentity(
          providerId: current.providerId,
          modelOverride: current.modelOverride,
          providers: _providers,
        ) !=
        _providerContextIdentity(
          providerId: providerId,
          modelOverride: normalizedModelOverride,
          providers: _providers,
        );
    final providerTransportChanged =
        _providerTransportIdentity(previousProvider) !=
        _providerTransportIdentity(nextProvider);
    final compHashChanged =
        previousMetadata?.compHash != nextMetadata?.compHash;
    final historyBoundaryChanged =
        current.mode != normalizedMode ||
        current.effectiveWorkMode != normalizedWorkMode ||
        current.projectId != normalizedProjectId ||
        current.serverId != normalizedServerId ||
        current.workingDirectory != normalizedWorkingDirectory;
    final modelChanged = previousModel != nextModel;
    final now = DateTime.now().toUtc();
    final updated = Task(
      id: current.id,
      mode: normalizedMode,
      workMode: normalizedWorkMode,
      projectId: normalizedProjectId,
      serverId: normalizedServerId,
      providerId: providerId,
      reviewProviderId: normalizedReviewProviderId,
      reviewModelOverride: normalizedReviewModelOverride,
      modelOverride: normalizedModelOverride,
      reasoningEffortOverride: normalizedReasoningEffortOverride,
      title: current.title,
      workingDirectory: normalizedWorkingDirectory,
      executionMode: normalizedExecutionMode,
      status: current.status,
      createdAt: current.createdAt,
      updatedAt: now,
    );
    if (historyBoundaryChanged) {
      try {
        await _releasePhoneTask(taskId);
      } catch (_) {
        // A changed task can reconnect with the new boundary even if closing
        // the old channel reports an error.
      }
    }
    await _database.saveTask(updated);
    _tasks = [
      for (final task in _tasks) task.id == updated.id ? updated : task,
    ];

    if (historyBoundaryChanged) {
      _localAccess.remove(taskId);
      _invalidateTaskContextUsage(taskId);
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.context_changed',
        payload: {
          'history_boundary': true,
          'mode': normalizedMode,
          'work_mode': normalizedWorkMode,
          'project_id': normalizedProjectId,
          'server_id': normalizedServerId,
          'provider_id': providerId,
          'model_override': normalizedModelOverride,
          'previous_provider_id': previousProvider?.id,
          'previous_model': previousModel,
          if (compHashChanged) 'comp_hash_changed': true,
        },
      );
    } else if (providerContextChanged || modelChanged) {
      // Codex keeps the transcript when the model changes and appends a
      // model-switch context item. A provider/transport switch uses the same
      // boundary-free event, but history reconstruction drops opaque provider
      // state before the next request.
      _invalidateTaskContextUsage(taskId);
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.context_changed',
        payload: {
          'history_boundary': false,
          'history_projection': providerTransportChanged ? 'provider' : 'model',
          'reason': providerTransportChanged
              ? 'provider_changed'
              : 'model_changed',
          'previous_provider_id': previousProvider?.id,
          'provider_id': nextProvider?.id,
          'previous_model': previousModel,
          'model': nextModel,
          'wire_api': nextProvider?.wireApi,
          'model_changed': modelChanged,
          'previous_model_override': current.modelOverride,
          'model_override': normalizedModelOverride,
        },
      );
    }
    _notify();
    return _tasks.firstWhere((task) => task.id == taskId);
  }

  Future<void> updateTaskStatus(
    String taskId,
    String status, {
    String? turnId,
  }) {
    final previous = _taskStatusTails[taskId] ?? Future<void>.value();
    late Future<void> current;
    current = previous.then<void>(
      (_) => _updateTaskStatusNow(taskId, status, turnId: turnId),
    );
    final settled = current.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _taskStatusTails[taskId] = settled;
    unawaited(
      settled.then<void>((_) {
        if (identical(_taskStatusTails[taskId], settled)) {
          _taskStatusTails.remove(taskId);
        }
      }),
    );
    return current;
  }

  Future<void> _updateTaskStatusNow(
    String taskId,
    String status, {
    String? turnId,
  }) async {
    if (turnId != null && _taskRunIds[taskId] != turnId) return;
    final current = _tasks.firstWhere((task) => task.id == taskId);
    if (status == 'stopping' && _isTerminalTaskStatus(current.status)) {
      return;
    }
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
    final statusTail = _taskStatusTails[taskId];
    if (statusTail != null) await statusTail;
    final event = TaskEvent(
      eventId: _newId('event'),
      taskId: taskId,
      sequence: await _database.nextEventSequence(taskId),
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
    }
    await _releasePhoneTask(task.id);
    final eventTail = _taskEventTails[task.id];
    if (eventTail != null) await eventTail;
    final eventLoad = _eventLoads[task.id];
    if (eventLoad != null) await eventLoad;
    final migration = _attachmentMigrations[task.id];
    if (migration != null) await migration;
    _localAccess.remove(task.id);
    final statusTail = _taskStatusTails[task.id];
    if (statusTail != null) await statusTail;
    _invalidateTaskContextUsage(task.id);
    _streamingAssistantText.remove(task.id);
    await _database.deleteTask(task.id);
    try {
      await _attachmentStore.deleteTask(task.id);
    } catch (_) {
      // A private orphan is safer than deleting files before the database
      // transaction succeeds.
    }
    _tasks = [
      for (final item in _tasks)
        if (item.id != task.id) item,
    ];
    _events = {
      for (final entry in _events.entries)
        if (entry.key != task.id) entry.key: entry.value,
    };
    _loadedTaskEvents.remove(task.id);
    _hasEarlierTaskEvents.remove(task.id);
    _eventLoads.remove(task.id);
    _attachmentMigrations.remove(task.id);
    _notify();
  }

  Future<AttachmentCleanupResult> cleanupStorage() async {
    if (_runningTasks.isNotEmpty) {
      throw StateError('任务运行中，完成或停止任务后再清理空间');
    }
    if (_attachmentMigrations.isNotEmpty) {
      await Future.wait(_attachmentMigrations.values);
    }
    final records = await _database.loadAttachments();
    final referencedIds = await _database.loadReferencedAttachmentIds();
    final retainedPaths = {
      for (final record in records)
        if (referencedIds.contains(record.id)) record.storagePath,
    };
    await _database.deleteAttachments([
      for (final record in records)
        if (!referencedIds.contains(record.id)) record.id,
    ]);
    final result = await _attachmentStore.removeExcept(retainedPaths);
    return result;
  }

  /// Compact the current Responses history without creating a user-visible
  /// turn. The standalone endpoint returns the complete next context window;
  /// keep that output intact as the durable history boundary.
  Future<TaskContextUsage> compactTaskContext(
    Task task, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    final pending = _taskCompactions[task.id];
    if (pending != null) return pending;
    if (_taskRuns.containsKey(task.id) || _runningTasks.containsKey(task.id)) {
      throw StateError('任务运行中，不能主动压缩');
    }
    final future = _compactTaskContext(
      task,
      onFirstHostKey: onFirstHostKey,
      onUserInfoRequest: onUserInfoRequest,
    );
    _taskCompactions[task.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_taskCompactions[task.id], future)) {
        _taskCompactions.remove(task.id);
      }
    }
  }

  Future<TaskContextUsage> _compactTaskContext(
    Task task, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    if (previewMode) throw StateError('预览模式不支持主动压缩');
    final provider = _providerForTask(task);
    if (provider.wireApi != 'responses') {
      throw StateError('当前供应商未使用 Responses，无法主动压缩');
    }
    final apiKey = await _readCredential(provider.apiKeyRef, '供应商 API Key 不可用');
    final cancellation = AgentCancellation();
    final tools = <AgentTool>[];
    Project? taskProject;
    SshConnection? temporaryConnection;
    RemoteAgentTools? temporaryRemoteTools;
    AiChatClient? client;

    try {
      final events = await _database.loadModelEvents(
        task.id,
        useCompactionBoundary: true,
      );
      var systemPrompt = _systemPrompt(task);
      final workMode = task.effectiveWorkMode;
      final useLocalTools = workModeUsesLocal(workMode);
      final useServerTools = workModeUsesServer(workMode);

      if (task.mode == 'agent') {
        Project? project;
        String? workingDirectory;
        if (useLocalTools) {
          final access = _localAccess.putIfAbsent(
            task.id,
            LocalFileAccessStore.new,
          );
          tools.addAll(LocalAgentTools(access).tools);
          project = projectFor(task.projectId);
          taskProject = project;
          if (task.projectId != null && project == null) {
            throw StateError('对话绑定的项目不存在');
          }
          if (project != null) {
            await _ensureProjectStoragePath(project.localPath);
            await _projectFiles.ensureRoot(project);
            final projectTools = ProjectAgentTools(
              project,
              _projectFiles,
              preview: _localPreview,
            );
            tools.addAll(
              _serializeRemoteWrites(
                projectTools.tools,
                'project\u0000${project.id}',
                cancellation: cancellation,
              ),
            );
          }
        }

        final serverId = task.serverId;
        if (useServerTools && (serverId == null || serverId.isEmpty)) {
          throw StateError('服务器工作模式没有目标服务器');
        }
        if (useServerTools) {
          final server = _servers.firstWhere((value) => value.id == serverId);
          var remoteTools = _phoneTools[task.id];
          if (remoteTools != null && remoteTools.isClosed) {
            _phoneTools.remove(task.id);
            await remoteTools.close();
            remoteTools = null;
          }
          if (remoteTools == null) {
            temporaryConnection = await _connectServer(
              server,
              onFirstHostKey: onFirstHostKey,
              onUserInfoRequest: onUserInfoRequest,
            );
            await _saveObservedHostKey(server, temporaryConnection.hostKey);
            workingDirectory =
                task.workingDirectory ?? server.defaultWorkingDirectory;
            remoteTools = RemoteAgentTools(
              temporaryConnection,
              workingDirectory: workingDirectory,
              project: useLocalTools ? project : null,
              projectFiles: useLocalTools ? _projectFiles : null,
            );
            temporaryRemoteTools = remoteTools;
          } else {
            workingDirectory =
                task.workingDirectory ?? server.defaultWorkingDirectory;
          }
          tools.addAll(
            _serializeRemoteWrites(
              remoteTools.tools,
              server.id,
              cancellation: cancellation,
            ),
          );
          systemPrompt = _systemPrompt(
            task,
            project: useLocalTools ? project : null,
            workingDirectory: workingDirectory,
          );
          final instructions = await _remoteInstructions.load(
            remoteTools.connection,
            workingDirectory,
          );
          if (instructions != null) {
            systemPrompt =
                '$systemPrompt\n\n--- project-doc ---\n\n$instructions';
          }
        } else {
          systemPrompt = _systemPrompt(
            task,
            project: useLocalTools ? project : null,
          );
        }
        if (tools.isEmpty) throw StateError('Agent 没有可用的项目或服务器工具');
      }

      final imageProvider = imageProviderFor(task);
      if (imageProvider != null) {
        tools.add(
          _imageGenerationTool(
            imageProvider,
            taskProject,
            task.id,
            cancellation: cancellation,
          ),
        );
      }

      final model = task.modelOverride ?? provider.model;
      client = createAiClient(
        wireApi: provider.wireApi,
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort:
            task.reasoningEffortOverride ?? provider.reasoningEffort,
        inputModalities: provider.modelMetadata[model]?.inputModalities,
      );
      final compactionClient = client is AiCompactionClient
          ? client as AiCompactionClient
          : null;
      if (compactionClient == null) {
        throw StateError('当前 Responses 供应商不支持 /responses/compact');
      }
      final messages = await _localHistory(
        task.id,
        systemPrompt,
        events,
        useResponsesCompaction: true,
        providerId: provider.id,
      );
      final hasConversation = messages.any(
        (message) =>
            message.role == 'user' ||
            message.role == 'assistant' ||
            message.role == 'tool',
      );
      if (!hasConversation) throw StateError('当前没有可压缩的对话内容');
      final outputItems = await compactionClient.compact(
        messages: messages,
        instructions: systemPrompt,
        tools: [for (final tool in tools) tool.definition],
        cancellation: cancellation.whenCancelled,
      );
      if (outputItems.isEmpty) throw StateError('Responses 压缩返回了空历史');

      await appendTaskEvent(
        taskId: task.id,
        type: 'context.compacted',
        payload: {
          'source': 'manual',
          'provider_id': provider.id,
          'wire_api': provider.wireApi,
          'model': model,
          'responses_output_items': outputItems,
        },
      );
      _invalidateTaskContextUsage(task.id);
      return await loadTaskContextUsage(task, provider: provider);
    } finally {
      if (client != null) closeAiClient(client);
      if (temporaryRemoteTools != null) {
        try {
          await temporaryRemoteTools.close();
        } catch (_) {}
      }
      if (temporaryConnection != null) {
        try {
          await temporaryConnection.close();
        } catch (_) {}
      }
    }
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
    if (_taskCompactions.containsKey(task.id)) {
      throw StateError('上下文正在压缩');
    }
    final turnId = _newId('turn');
    _taskRunIds[task.id] = turnId;
    final future = _runTask(
      task,
      turnId: turnId,
      prompt: prompt,
      attachments: attachments,
      confirm: confirm,
      onFirstHostKey: onFirstHostKey,
      onUserInfoRequest: onUserInfoRequest,
    );
    _taskRuns[task.id] = future;
    unawaited(
      future.then<void>(
        (_) => _finishTask(task.id, turnId, future),
        onError: (Object error, StackTrace stackTrace) {
          _finishTask(task.id, turnId, future);
        },
      ),
    );
    return future;
  }

  Future<AgentResult> _runTask(
    Task task, {
    required String turnId,
    required String prompt,
    required List<AiAttachment> attachments,
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    SshUserInfoHandler? onUserInfoRequest,
  }) async {
    Future<TaskEvent> appendTurnEvent(
      String type,
      Map<String, Object?> payload,
    ) {
      return appendTaskEvent(
        taskId: task.id,
        type: type,
        payload: {'turn_id': turnId, ...payload},
      );
    }

    if (task.mode != 'chat' && task.mode != 'agent') {
      final error = UnsupportedError('不支持的任务模式：${task.mode}');
      try {
        await appendTurnEvent('task.failed', {'error': '$error'});
        await updateTaskStatus(task.id, 'failed', turnId: turnId);
      } catch (_) {
        // Keep the original invalid-task error when old data is incomplete.
      }
      return AgentResult(status: 'failed', messages: const [], error: error);
    }
    final cancellation = AgentCancellation();
    _runningTasks[task.id] = cancellation;
    _streamingAssistantText.remove(task.id);
    _notify();
    var previousEvents = const <TaskEvent>[];
    var requestAttachments = attachments;
    SshConnection? connection;
    RemoteAgentTools? remoteTools;
    ProjectAgentTools? projectTools;
    LocalAgentTools? localTools;
    Project? taskProject;
    ProviderProfile? provider;
    AiChatClient? client;
    var remoteOperationStarted = false;
    var serviceStarted = false;
    var userMessageRecorded = false;
    var durableAttachments = const <AiAttachment>[];
    final workMode = task.effectiveWorkMode;
    final useLocalTools = workModeUsesLocal(workMode);
    final useServerTools = workModeUsesServer(workMode);

    Future<void> appendUserMessage(
      List<AiAttachment> messageAttachments,
    ) async {
      await appendTaskEvent(
        taskId: task.id,
        type: 'user.message',
        payload: {
          'turn_id': turnId,
          'text': prompt,
          if (messageAttachments.isNotEmpty)
            'attachments': messageAttachments
                .map((item) => item.toJson())
                .toList(),
        },
      );
      userMessageRecorded = true;
    }

    Future<void> markTaskWaiting() async {
      if (cancellation.isCancelled) return;
      final current = _tasks.firstWhere((value) => value.id == task.id);
      if (current.status != 'waiting') {
        await updateTaskStatus(task.id, 'waiting', turnId: turnId);
      }
    }

    Future<void> restoreTaskAfterWaiting() async {
      if (cancellation.isCancelled) return;
      final current = _tasks.firstWhere((value) => value.id == task.id);
      if (current.status == 'waiting') {
        await updateTaskStatus(task.id, 'running', turnId: turnId);
      }
    }

    Future<bool> Function(AgentTool, Map<String, Object?>)? waitingConfirm;
    if (confirm != null) {
      waitingConfirm = (tool, arguments) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return false;
          return await confirm(tool, arguments);
        } finally {
          await restoreTaskAfterWaiting();
        }
      };
    }

    FutureOr<bool> Function(SshHostKey)? waitingHostKey;
    if (onFirstHostKey != null) {
      waitingHostKey = (key) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return false;
          return await onFirstHostKey(key);
        } finally {
          await restoreTaskAfterWaiting();
        }
      };
    }

    SshUserInfoHandler? waitingUserInfo;
    if (onUserInfoRequest != null) {
      waitingUserInfo = (request) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return null;
          return await onUserInfoRequest(request);
        } finally {
          await restoreTaskAfterWaiting();
        }
      };
    }

    try {
      requestAttachments = await _persistAttachments(task.id, attachments);
      durableAttachments = requestAttachments;
      await _migrateLegacyAttachments(task.id);
      provider = previewMode ? null : _providerForTask(task);
      final useResponsesHistory = provider?.wireApi != 'chat-completions';
      previousEvents = await _database.loadModelEvents(
        task.id,
        useCompactionBoundary: useResponsesHistory,
      );
      await appendUserMessage(requestAttachments);
      if (previewMode) {
        return await _runPreviewTask(
          task,
          prompt: prompt,
          attachments: requestAttachments,
          initialHistory: await _localHistory(
            task.id,
            _systemPrompt(task),
            previousEvents,
            useResponsesCompaction: true,
          ),
          cancellation: cancellation,
          turnId: turnId,
        );
      }
      await updateTaskStatus(task.id, 'running', turnId: turnId);
      await appendTurnEvent('task.started', {'mode': task.mode});
      if (task.mode == 'agent') {
        await _taskService.start(task.id);
        serviceStarted = true;
      }

      final activeProvider = provider!;
      final apiKey = await _readCredential(
        activeProvider.apiKeyRef,
        '供应商 API Key 不可用',
      );
      final tools = <AgentTool>[];
      var systemPrompt = _systemPrompt(task);
      if (task.mode == 'agent') {
        Project? project;
        String? workingDirectory;
        if (useLocalTools) {
          final access = _localAccess.putIfAbsent(
            task.id,
            LocalFileAccessStore.new,
          );
          localTools = LocalAgentTools(access);
          tools.addAll(localTools.tools);
          project = projectFor(task.projectId);
          taskProject = project;
          if (task.projectId != null && project == null) {
            throw StateError('对话绑定的项目不存在');
          }
          if (project != null) {
            await _ensureProjectStoragePath(project.localPath);
            await _projectFiles.ensureRoot(project);
            projectTools = ProjectAgentTools(
              project,
              _projectFiles,
              preview: _localPreview,
            );
            tools.addAll(
              _serializeRemoteWrites(
                projectTools.tools,
                'project\u0000${project.id}',
                cancellation: cancellation,
              ),
            );
          }
        }
        final serverId = task.serverId;
        if (useServerTools && serverId != null && serverId.isNotEmpty) {
          final server = _servers.firstWhere((value) => value.id == serverId);
          final pendingConnection = _sshPool.acquire(
            task.id,
            () => _connectServer(
              server,
              onFirstHostKey: waitingHostKey,
              onUserInfoRequest: waitingUserInfo,
            ),
          );
          connection = await Future.any<SshConnection>([
            pendingConnection,
            cancellation.whenCancelled.then<SshConnection>(
              (_) => throw StateError('SSH connection cancelled'),
            ),
          ]);
          await _saveObservedHostKey(server, connection.hostKey);
          workingDirectory =
              task.workingDirectory ?? server.defaultWorkingDirectory;
          remoteTools = _phoneTools[task.id];
          if (remoteTools == null || remoteTools.isClosed) {
            await remoteTools?.close();
            remoteTools = RemoteAgentTools(
              connection,
              workingDirectory: workingDirectory,
              // Server-only mode must not expose a local project download
              // tool even when the conversation still carries a project
              // binding for its sidebar placement.
              project: useLocalTools ? project : null,
              projectFiles: useLocalTools ? _projectFiles : null,
            );
            _phoneTools[task.id] = remoteTools;
          }
          tools.addAll(
            _serializeRemoteWrites(
              remoteTools.tools,
              server.id,
              cancellation: cancellation,
            ),
          );
        }
        if (useServerTools && (serverId == null || serverId.isEmpty)) {
          throw StateError('服务器工作模式没有目标服务器');
        }
        systemPrompt = _systemPrompt(
          task,
          project: useLocalTools ? project : null,
          workingDirectory: useServerTools ? workingDirectory : null,
        );
        if (useServerTools && connection != null) {
          final instructions = await _remoteInstructions.load(
            connection,
            workingDirectory,
          );
          if (instructions != null) {
            systemPrompt =
                '$systemPrompt\n\n--- project-doc ---\n\n$instructions';
          }
        }
        if (tools.isEmpty) {
          throw StateError('Agent 没有可用的项目或服务器工具');
        }
      }

      final imageProvider = imageProviderFor(task);
      if (imageProvider != null) {
        tools.add(
          _imageGenerationTool(
            imageProvider,
            taskProject,
            task.id,
            cancellation: cancellation,
          ),
        );
      }

      client = createAiClient(
        wireApi: activeProvider.wireApi,
        baseUrl: activeProvider.baseUrl,
        apiKey: apiKey,
        model: task.modelOverride ?? activeProvider.model,
        reasoningEffort:
            task.reasoningEffortOverride ?? activeProvider.reasoningEffort,
        inputModalities: activeProvider.wireApi == 'responses'
            ? activeProvider
                  .modelMetadata[task.modelOverride ?? activeProvider.model]
                  ?.inputModalities
            : null,
      );
      final modelMetadata = activeProvider
          .modelMetadata[task.modelOverride ?? activeProvider.model];
      final truncationPolicy =
          modelMetadata?.resolvedTruncationPolicy ??
          ProviderTruncationPolicy.codexFallback;
      final loop = AgentLoop(client: client, tools: tools);
      var initialMessages = await _localHistory(
        task.id,
        systemPrompt,
        previousEvents,
        useResponsesCompaction: activeProvider.wireApi == 'responses',
        providerId: activeProvider.id,
      );
      final compactedItems = await _compactResponsesHistoryIfNeeded(
        task: task,
        provider: activeProvider,
        client: client,
        messages: initialMessages,
        tools: tools,
        instructions: systemPrompt,
        cancellation: cancellation.whenCancelled,
        additionalTokenCount:
            OpenAiCompatibleClient.estimateResponsesTailTokenCount(
              initialMessages,
              inputModalities: modelMetadata?.inputModalities,
            ),
      );
      if (compactedItems != null) {
        initialMessages = [
          AiMessage(role: 'system', content: systemPrompt),
          AiMessage(role: 'assistant', responsesOutputItems: compactedItems),
        ];
        await appendTurnEvent('context.compacted', {
          'provider_id': activeProvider.id,
          'wire_api': activeProvider.wireApi,
          'model': task.modelOverride ?? activeProvider.model,
          'responses_output_items': compactedItems,
        });
        _invalidateTaskContextUsage(task.id);
      }
      Future<List<AiMessage>?> compactHistory(List<AiMessage> messages) async {
        if (activeProvider.wireApi != 'responses') return null;
        TokenUsageSnapshot? latestUsage;
        for (final message in messages.reversed) {
          final rawUsage = message.usage;
          if (rawUsage == null) continue;
          latestUsage = TokenUsageSnapshot.fromProviderUsage(rawUsage);
          if (latestUsage != null) break;
        }
        final compactedItems = await _compactResponsesHistoryIfNeeded(
          task: task,
          provider: activeProvider,
          client: client!,
          messages: messages,
          tools: tools,
          instructions: systemPrompt,
          cancellation: cancellation.whenCancelled,
          activeTokenCount: latestUsage?.totalTokens,
          additionalTokenCount:
              OpenAiCompatibleClient.estimateResponsesTailTokenCount(
                messages,
                inputModalities: modelMetadata?.inputModalities,
              ),
        );
        if (compactedItems == null) return null;
        await appendTurnEvent('context.compacted', {
          'provider_id': activeProvider.id,
          'wire_api': activeProvider.wireApi,
          'model': task.modelOverride ?? activeProvider.model,
          'responses_output_items': compactedItems,
        });
        _invalidateTaskContextUsage(task.id);
        return [
          AiMessage(role: 'system', content: systemPrompt),
          AiMessage(role: 'assistant', responsesOutputItems: compactedItems),
        ];
      }

      var eventQueue = Future<void>.value();
      final result = await loop.run(
        prompt: prompt,
        attachments: requestAttachments,
        initialMessages: initialMessages,
        executionMode: task.executionMode,
        cancellation: cancellation,
        toolOutputLimit: truncationPolicy.limit,
        toolOutputLimitInTokens: truncationPolicy.mode == 'tokens',
        confirm: waitingConfirm,
        review: task.executionMode == 'auto_review'
            ? (tool, arguments) =>
                  _reviewTool(task, tool, arguments, cancellation: cancellation)
            : null,
        compactHistory: compactHistory,
        onRemoteOperationStarted: (tool) {
          if (tool.writesRemoteState) remoteOperationStarted = true;
        },
        onEvent: (type, payload) {
          if (type == 'assistant.delta') {
            final delta = payload['text'];
            if (_taskRunIds[task.id] == turnId &&
                delta is String &&
                delta.isNotEmpty) {
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
            if (_taskRunIds[task.id] == turnId) {
              _streamingAssistantText.remove(task.id);
              _notify();
            }
          }
          if (type == 'task.unknown') remoteOperationStarted = true;
          eventQueue = eventQueue.then((_) async {
            var eventPayload = payload;
            _ContextUsageEvent? contextUsageEvent;
            if (type == 'assistant.completed') {
              try {
                contextUsageEvent = await _appendContextUsage(
                  task,
                  activeProvider,
                  payload,
                );
                eventPayload = contextUsageEvent.payload;
              } catch (_) {
                // Usage is telemetry. Keep the assistant event durable even
                // if its optional usage summary cannot be rebuilt.
              }
              eventPayload = {
                ...eventPayload,
                'provider_id': activeProvider.id,
              };
            }
            await appendTurnEvent(type, eventPayload);
            if (contextUsageEvent != null && _taskRunIds[task.id] == turnId) {
              _taskContextUsages[task.id] = contextUsageEvent.usage;
            }
          });
          return eventQueue;
        },
      );
      await updateTaskStatus(task.id, result.status, turnId: turnId);
      return result;
    } catch (error) {
      // A setup or persistence failure may happen before AgentLoop can return
      // its complete message list. Codex records accepted input on the
      // equivalent aborted setup paths; do the same without retaining raw
      // attachment data in the event log.
      if (!userMessageRecorded) {
        try {
          final persistedEvents = await _database.loadEvents(task.id);
          TaskEvent? persistedUserMessage;
          for (final event in persistedEvents.reversed) {
            if (event.type == 'user.message' &&
                event.payload['turn_id'] == turnId) {
              persistedUserMessage = event;
              break;
            }
          }
          if (persistedUserMessage != null) {
            _mergeLoadedEvent(persistedUserMessage);
            userMessageRecorded = true;
          } else {
            await appendUserMessage(durableAttachments);
          }
        } catch (_) {
          // Preserve the original setup error if the storage layer is also
          // unavailable; the normal failure event below remains best effort.
        }
      }
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
      await appendTurnEvent(eventType, {'error': '$error'});
      await updateTaskStatus(task.id, status, turnId: turnId);
      return AgentResult(status: status, messages: const [], error: error);
    } finally {
      if (_taskRunIds[task.id] == turnId) {
        _streamingAssistantText.remove(task.id);
      }
      if (client != null) closeAiClient(client);
      if (task.mode == 'agent' && serviceStarted) {
        final keepRemoteTools = remoteTools?.hasRunningProcesses ?? false;
        if (connection == null && cancellation.isCancelled) {
          _sshPool.abort(task.id);
        }
        if (!keepRemoteTools) {
          try {
            await _releasePhoneTask(task.id);
          } catch (_) {
            // Cleanup must not replace a task result.
          }
        }
        try {
          await _taskService.stop(task.id);
        } catch (_) {
          // The foreground service may already have been stopped by Android.
        }
      }
    }
  }

  void _finishTask(String taskId, String turnId, Future<AgentResult> future) {
    if (_taskRunIds[taskId] != turnId ||
        !identical(_taskRuns[taskId], future)) {
      return;
    }
    _taskRuns.remove(taskId);
    _taskRunIds.remove(taskId);
    _runningTasks.remove(taskId);
    _notify();
  }

  List<AgentTool> _serializeRemoteWrites(
    List<AgentTool> tools,
    String leaseKey, {
    required AgentCancellation cancellation,
  }) {
    return [
      for (final tool in tools)
        if (!tool.writesRemoteState)
          tool
        else
          AgentTool(
            definition: tool.definition,
            requiresConfirmation: tool.requiresConfirmation,
            requiresUserApproval: tool.requiresUserApproval,
            isRemote: tool.isRemote,
            writesRemoteState: tool.writesRemoteState,
            call: (arguments) => _remoteWriteQueue.run(
              leaseKey,
              () => tool.call(arguments),
              cancellation: cancellation,
            ),
            callWithOperationStart: (arguments, onOperationStarted) =>
                _remoteWriteQueue.run(leaseKey, () {
                  onOperationStarted();
                  return tool.call(arguments);
                }, cancellation: cancellation),
          ),
    ];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void stopTask(String taskId, {String? expectedTurnId}) {
    final cancellation = _runningTasks[taskId];
    if (cancellation == null) return;
    final turnId = _taskRunIds[taskId];
    if (expectedTurnId != null && turnId != expectedTurnId) return;
    cancellation.cancel();
    unawaited(updateTaskStatus(taskId, 'stopping', turnId: turnId));
    unawaited(_recordCancellationRequest(taskId, turnId));
    _notify();
  }

  Future<void> _recordCancellationRequest(String taskId, String? turnId) async {
    if (turnId == null || _taskRunIds[taskId] != turnId) return;
    try {
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.cancel_requested',
        payload: {'turn_id': turnId},
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
    return _remoteWriteQueue.run(
      profile.id,
      () => _withServerConnection(
        profile,
        (connection) => connection.run(
          command,
          workingDirectory: profile.defaultWorkingDirectory,
        ),
        onFirstHostKey: onFirstHostKey,
      ),
      cancellation: AgentCancellation(),
    );
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

  Future<List<ProjectFileEntry>> listProjectDirectory(
    Project project,
    String relativePath, {
    bool forceRefresh = false,
  }) async {
    final path = _normalizeProjectUiPath(relativePath);
    final cacheKey = _projectDirectoryCacheKey(project, path);
    final pending = _projectDirectoryLoads[cacheKey];
    if (pending != null) return pending;
    if (!forceRefresh) {
      final cached = _projectDirectoryCache[cacheKey];
      if (cached != null) return cached;
    }
    final request = _listProjectDirectory(project, path);
    _projectDirectoryLoads[cacheKey] = request;
    try {
      final entries = List<ProjectFileEntry>.unmodifiable(await request);
      _projectDirectoryCache[cacheKey] = entries;
      return entries;
    } finally {
      if (identical(_projectDirectoryLoads[cacheKey], request)) {
        _projectDirectoryLoads.remove(cacheKey);
      }
    }
  }

  Future<List<ProjectFileEntry>> _listProjectDirectory(
    Project project,
    String relativePath,
  ) async {
    await _ensureProjectStoragePath(project.localPath);
    return _projectFiles.list(project, relativePath);
  }

  List<ProjectFileEntry>? cachedProjectDirectory(
    Project project,
    String relativePath,
  ) {
    final path = _normalizeProjectUiPath(relativePath);
    return _projectDirectoryCache[_projectDirectoryCacheKey(project, path)];
  }

  Future<String> readProjectFile(Project project, String relativePath) {
    return _readProjectFile(project, _normalizeProjectUiPath(relativePath));
  }

  Future<String> _readProjectFile(Project project, String relativePath) async {
    await _ensureProjectStoragePath(project.localPath);
    return _projectFiles.readText(project, relativePath);
  }

  Future<void> writeProjectFile(
    Project project,
    String relativePath,
    String content,
  ) async {
    await _ensureProjectStoragePath(project.localPath);
    await _projectFiles.writeText(
      project,
      _normalizeProjectUiPath(relativePath),
      content,
    );
    _invalidateProjectDirectoryCache(project.id);
  }

  Future<void> createProjectFile(Project project, String relativePath) async {
    await _ensureProjectStoragePath(project.localPath);
    await _projectFiles.createFile(
      project,
      _normalizeProjectUiPath(relativePath),
    );
    _invalidateProjectDirectoryCache(project.id);
  }

  Future<void> createProjectDirectory(
    Project project,
    String relativePath,
  ) async {
    await _ensureProjectStoragePath(project.localPath);
    await _projectFiles.createDirectory(
      project,
      _normalizeProjectUiPath(relativePath),
    );
    _invalidateProjectDirectoryCache(project.id);
  }

  LocalPreviewStatus localPreviewStatus(Project project) {
    return _localPreview.status(project);
  }

  List<LocalPreviewLog> localPreviewLogs(
    Project project, {
    int after = 0,
    int limit = 100,
  }) {
    return _localPreview.logs(project, after: after, limit: limit);
  }

  Future<LocalPreviewStatus> startLocalPreview(
    Project project, {
    String entrypoint = 'index.html',
  }) async {
    await _ensureProjectStoragePath(project.localPath);
    final status = await _localPreview.start(project, entrypoint: entrypoint);
    _notify();
    return status;
  }

  LocalPreviewStatus reloadLocalPreview(Project project) {
    final status = _localPreview.reload(project);
    _notify();
    return status;
  }

  Future<void> stopLocalPreview(Project project) async {
    await _localPreview.stop(project);
    _notify();
  }

  void clearLocalPreviewLogs(Project project) {
    _localPreview.clearLogs(project);
    _notify();
  }

  void recordLocalPreviewLog(
    Project project, {
    required String level,
    required String source,
    required String message,
    String? url,
  }) {
    _localPreview.recordLog(
      project,
      level: level,
      source: source,
      message: message,
      url: url,
    );
    _notify();
  }

  Future<LocalWebTestResult> testLocalWeb(
    Project project, {
    String entrypoint = 'index.html',
  }) async {
    return _localPreview.testWeb(project, entrypoint: entrypoint);
  }

  Future<void> _ensureProjectStoragePath(String path) async {
    if (await AndroidStorageAccess.ensureForPath(path)) return;
    throw StateError('手机共享存储目录没有写入权限，请授予文件访问权限后重试');
  }

  String _projectDirectoryCacheKey(Project project, String relativePath) {
    return '${project.id}\u0000${project.localPath}\u0000$relativePath';
  }

  void _invalidateProjectDirectoryCache(String projectId) {
    final prefix = '$projectId\u0000';
    _projectDirectoryCache.removeWhere((key, _) => key.startsWith(prefix));
  }

  static String _normalizeProjectUiPath(String value) {
    final path = value.trim();
    return path == '/' || path == '.' ? '' : path;
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
    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(
        profile,
        (connection) => connection.writeFile(
          remotePath.trim(),
          Uint8List.fromList(utf8.encode(content)),
        ),
        onFirstHostKey: onFirstHostKey,
      ),
      cancellation: AgentCancellation(),
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
        cpuUsage: 5,
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
    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(profile, (connection) async {
        final result = await connection.run(statusScriptInstallCommand);
        if (result.exitCode != 0) {
          throw StateError('状态脚本安装失败：${result.stderr}');
        }
      }, onFirstHostKey: onFirstHostKey),
      cancellation: AgentCancellation(),
    );
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
    final defaultWorkingDirectory = workingDirectory.isEmpty
        ? null
        : workingDirectory;
    final connectionSettingsChanged =
        existing != null &&
        (endpointChanged ||
            existing.username != username ||
            authTypeChanged ||
            secret.isNotEmpty ||
            (authType == 'privateKey' &&
                (passphrase.isNotEmpty || clearPassphrase)) ||
            (authType != 'privateKey' &&
                existing.credentialPassphraseRef != null) ||
            existing.defaultWorkingDirectory != defaultWorkingDirectory);
    final credentialRef = existing?.credentialRef ?? 'server:$id:ssh';
    final passphraseRef = authType == 'privateKey'
        ? (existing?.credentialPassphraseRef ?? 'server:$id:passphrase')
        : null;
    if (secret.isEmpty && (existing == null || authTypeChanged)) {
      throw ArgumentError('首次保存服务器时必须填写密码或私钥');
    }
    if (connectionSettingsChanged) {
      if (_tasks.any(
        (task) => task.serverId == id && _taskRuns.containsKey(task.id),
      )) {
        throw StateError('服务器任务正在运行，不能修改连接设置');
      }
      await Future.wait([
        for (final task in _tasks)
          if (task.serverId == id) _releasePhoneTask(task.id),
      ]);
    }
    if (secret.isNotEmpty) {
      await _credentials.write(credentialRef, secret);
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
        defaultWorkingDirectory: defaultWorkingDirectory,
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
        defaultWorkingDirectory: defaultWorkingDirectory,
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
    if (_lastDashboardServerId == profile.id) {
      await setLastDashboardServer(null);
    }
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
    String reasoningEffort = 'default',
    String wireApi = 'responses',
    required String secret,
    required bool isDefault,
    Map<String, ProviderModelMetadata>? modelMetadata,
  }) async {
    final previousProviders = List<ProviderProfile>.unmodifiable(_providers);
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
      reasoningEffort: reasoningEffort,
      wireApi: wireApi,
      apiKeyRef: apiKeyRef,
      isDefault: isDefault,
      modelMetadata: modelMetadata ?? existing?.modelMetadata ?? const {},
    );
    await _database.saveProvider(saved);
    final providers = [
      for (final provider in _providers)
        if (provider.id != id)
          isDefault ? provider.copyWith(isDefault: false) : provider,
      saved,
    ]..sort((left, right) => left.name.compareTo(right.name));
    _providers = providers;
    await _isolateProviderContextChanges(previousProviders, providers);
    _notify();
  }

  Future<void> deleteProvider(ProviderProfile profile) async {
    final implicitProvider = _providerForTaskFrom(null, _providers);
    if (_tasks.any(
      (task) =>
          task.providerId == profile.id ||
          (task.providerId == null && implicitProvider?.id == profile.id),
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
    if (_imageProviderId == profile.id) {
      await _database.writeSetting(_imageProviderSetting, '');
      _imageProviderId = null;
    }
    _notify();
  }

  Future<void> testProvider(ProviderProfile profile) async {
    if (previewMode) throw StateError('预览模式不会发送真实供应商请求');
    final apiKey = await _readCredential(profile.apiKeyRef, 'API Key 不可用');
    await _providerTester.test(profile, apiKey);
  }

  Future<ProviderUsageSnapshot> loadProviderUsage(
    ProviderProfile profile, {
    bool force = false,
  }) async {
    final cached = _providerUsages[profile.id];
    if (!force &&
        cached?.updatedAt != null &&
        DateTime.now().toUtc().difference(cached!.updatedAt!).inSeconds < 60) {
      return cached;
    }
    final existing = _providerUsageLoads[profile.id];
    if (existing != null) return existing;
    if (previewMode) {
      const snapshot = ProviderUsageSnapshot(
        providerId: 'preview',
        status: 'ok',
        planName: '预览',
      );
      _providerUsages[profile.id] = snapshot;
      return snapshot;
    }
    final load = () async {
      try {
        final apiKey = await _readCredential(
          profile.apiKeyRef,
          '供应商 API Key 不可用',
        );
        final snapshot = await _providerUsageClient.fetch(profile, apiKey);
        final withTime = ProviderUsageSnapshot(
          providerId: snapshot.providerId,
          status: snapshot.status,
          balance: snapshot.balance,
          windows: snapshot.windows,
          planName: snapshot.planName,
          mode: snapshot.mode,
          todayRequests: snapshot.todayRequests,
          todayCost: snapshot.todayCost,
          message: snapshot.message,
          updatedAt: DateTime.now().toUtc(),
        );
        _providerUsages[profile.id] = withTime;
        _notify();
        return withTime;
      } catch (error) {
        final snapshot = ProviderUsageSnapshot(
          providerId: profile.id,
          status: 'error',
          message: '$error',
          updatedAt: DateTime.now().toUtc(),
        );
        _providerUsages[profile.id] = snapshot;
        _notify();
        return snapshot;
      } finally {
        _providerUsageLoads.remove(profile.id);
      }
    }();
    _providerUsageLoads[profile.id] = load;
    return load;
  }

  Future<List<String>> loadProviderModels(
    ProviderProfile profile, {
    String? secret,
  }) async {
    if (previewMode) return const ['demo-model', 'demo-coder'];
    final models = await loadProviderModelMetadata(profile, secret: secret);
    return [for (final model in models) model.model];
  }

  Future<List<ProviderModelMetadata>> loadProviderModelMetadata(
    ProviderProfile profile, {
    String? secret,
  }) async {
    if (previewMode) return const [];
    final apiKey =
        secret ?? await _readCredential(profile.apiKeyRef, 'API Key 不可用');
    final models = await _providerTester.listModelMetadata(profile, apiKey);
    await _mergeProviderModelMetadata(profile.id, models);
    return models;
  }

  Future<void> _mergeProviderModelMetadata(
    String providerId,
    List<ProviderModelMetadata> metadata,
  ) async {
    if (metadata.isEmpty) return;
    ProviderProfile? current;
    for (final provider in _providers) {
      if (provider.id == providerId) {
        current = provider;
        break;
      }
    }
    if (current == null) return;
    final previousProviders = List<ProviderProfile>.unmodifiable(_providers);
    final merged = <String, ProviderModelMetadata>{...current.modelMetadata};
    for (final item in metadata) {
      final previous = merged[item.model];
      merged[item.model] = previous == null ? item : previous.mergedWith(item);
    }
    final updated = current.copyWith(modelMetadata: merged);
    await _database.saveProvider(updated);
    _providers = [
      for (final provider in _providers)
        provider.id == providerId ? updated : provider,
    ];
    await _isolateProviderContextChanges(previousProviders, _providers);
    _notify();
  }

  Future<void> _isolateProviderContextChanges(
    List<ProviderProfile> previousProviders,
    List<ProviderProfile> nextProviders,
  ) async {
    for (final task in _tasks) {
      final previousIdentity = _providerContextIdentity(
        providerId: task.providerId,
        modelOverride: task.modelOverride,
        providers: previousProviders,
      );
      final nextIdentity = _providerContextIdentity(
        providerId: task.providerId,
        modelOverride: task.modelOverride,
        providers: nextProviders,
      );
      if (previousIdentity == nextIdentity) continue;

      _invalidateTaskContextUsage(task.id);
      final previousProvider = _providerForTaskFrom(
        task.providerId,
        previousProviders,
      );
      final provider = _providerForTaskFrom(task.providerId, nextProviders);
      final previousModel = _modelForTask(task, previousProvider);
      final nextModel = _modelForTask(task, provider);
      final transportChanged =
          _providerTransportIdentity(previousProvider) !=
          _providerTransportIdentity(provider);
      await appendTaskEvent(
        taskId: task.id,
        type: 'task.context_changed',
        payload: {
          'history_boundary': false,
          'history_projection': transportChanged ? 'provider' : 'model',
          'reason': 'provider_configuration_changed',
          'previous_provider_id': previousProvider?.id,
          'provider_id': provider?.id,
          'previous_model': previousModel,
          'wire_api': provider?.wireApi,
          'model': nextModel,
        },
      );
    }
  }

  Future<AgentReviewDecision> _reviewTool(
    Task task,
    AgentTool tool,
    Map<String, Object?> arguments, {
    required AgentCancellation cancellation,
  }) async {
    final reviewProviderId = task.reviewProviderId;
    if (reviewProviderId == null || reviewProviderId.isEmpty) {
      return AgentReviewDecision.failure('未配置审查供应商');
    }
    ProviderProfile? provider;
    for (final value in _providers) {
      if (value.id == reviewProviderId) {
        provider = value;
        break;
      }
    }
    if (provider == null) {
      return AgentReviewDecision.failure('审查供应商不存在');
    }
    final model = task.reviewModelOverride ?? provider.model;
    if (model.trim().isEmpty) {
      return AgentReviewDecision.failure('未配置审查模型');
    }

    AiChatClient? client;
    try {
      final apiKey = await _readCredential(
        provider.apiKeyRef,
        '审查供应商 API Key 不可用',
      );
      client = createAiClient(
        wireApi: provider.wireApi,
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort: provider.reasoningEffort,
        inputModalities: provider.wireApi == 'responses'
            ? provider.modelMetadata[model]?.inputModalities
            : null,
      );
      final request = jsonEncode({
        'conversation': task.title,
        'work_mode': task.effectiveWorkMode,
        'tool': tool.definition.name,
        'tool_description': tool.definition.description,
        'arguments': redactReviewInput(arguments),
        'server_id': task.serverId,
        'working_directory': task.workingDirectory,
      });
      final response = await client.complete(
        messages: [
          const AiMessage(
            role: 'system',
            content:
                'You are an independent security reviewer. Review only the '
                'exact tool call in the user message. Return JSON only with '
                'decision equal to allow, ask_user, or deny, plus a concise '
                'reason. Do not execute tools. Do not invent permissions. '
                'Allow routine scoped work, ask for ambiguous or high-impact '
                'actions, and deny credential theft or policy bypass.',
          ),
          AiMessage.user(request),
        ],
        tools: const [],
        cancellation: cancellation.whenCancelled,
      );
      return parseAgentReviewDecision(response.content ?? '');
    } catch (error) {
      return AgentReviewDecision.failure('审查请求失败：$error');
    } finally {
      if (client != null) closeAiClient(client);
    }
  }

  ProviderProfile _providerForTask(Task task) {
    if (_providers.isEmpty) throw StateError('请先配置 AI 供应商');
    return _providerForTaskFrom(task.providerId, _providers) ??
        (throw StateError('请先配置 AI 供应商'));
  }

  ProviderProfile? _providerForOptionalId(String? providerId) {
    return _providerForTaskFrom(providerId, _providers);
  }

  static ProviderProfile? _providerForTaskFrom(
    String? providerId,
    List<ProviderProfile> providers,
  ) {
    if (providerId != null) {
      for (final provider in providers) {
        if (provider.id == providerId) return provider;
      }
      return null;
    }
    for (final provider in providers) {
      if (provider.isDefault) return provider;
    }
    return providers.isEmpty ? null : providers.first;
  }

  static String _providerContextIdentity({
    required String? providerId,
    required String? modelOverride,
    required List<ProviderProfile> providers,
  }) {
    final provider = _providerForTaskFrom(providerId, providers);
    if (provider == null) return jsonEncode(const [null]);
    final model = modelOverride ?? provider.model;
    final metadata = provider.modelMetadata[model];
    return jsonEncode([
      provider.id,
      provider.baseUrl,
      provider.wireApi,
      model,
      metadata?.compHash,
      metadata?.resolvedContextWindowTokens,
      metadata?.effectiveContextWindowPercent,
      metadata?.resolvedAutoCompactTokenLimit,
      metadata?.compactionMode,
      metadata?.inputModalities,
      metadata?.truncationPolicy?.toMap(),
    ]);
  }

  static String _providerTransportIdentity(ProviderProfile? provider) {
    if (provider == null) return jsonEncode(const [null]);
    return jsonEncode([provider.id, provider.baseUrl, provider.wireApi]);
  }

  String _modelForTask(Task task, ProviderProfile? provider) {
    return task.modelOverride ?? provider?.model ?? '';
  }

  ProviderProfile? _contextProviderFor(Task task, ProviderProfile? provider) {
    if (provider != null) return provider;
    return _providerForTaskFrom(task.providerId, _providers);
  }

  ProviderModelMetadata? _contextMetadataForTask(
    Task task,
    ProviderProfile? provider,
  ) {
    final model = _modelForTask(task, provider);
    if (provider == null || model.isEmpty) return null;
    return provider.modelMetadata[model];
  }

  Future<List<Map<String, Object?>>?> _compactResponsesHistoryIfNeeded({
    required Task task,
    required ProviderProfile provider,
    required AiChatClient client,
    required List<AiMessage> messages,
    required List<AgentTool> tools,
    required String instructions,
    required Future<void> cancellation,
    int? activeTokenCount,
    int additionalTokenCount = 0,
  }) async {
    if (provider.wireApi != 'responses') return null;
    final metadata = _contextMetadataForTask(task, provider);
    final threshold = metadata?.resolvedAutoCompactTokenLimit;
    if (threshold == null) return null;
    final baseTokens =
        activeTokenCount ??
        (await loadTaskContextUsage(
          task,
          provider: provider,
        )).last?.totalTokens;
    final activeTokens = baseTokens == null
        ? additionalTokenCount > 0
              ? additionalTokenCount
              : null
        : baseTokens + additionalTokenCount;
    if (activeTokens == null || activeTokens < threshold) return null;
    final compactionClient = client is AiCompactionClient
        ? client as AiCompactionClient
        : null;
    if (compactionClient == null) {
      throw StateError('当前 Responses 供应商不支持 /responses/compact');
    }
    final outputItems = await compactionClient.compact(
      messages: messages,
      instructions: instructions,
      tools: [for (final tool in tools) tool.definition],
      cancellation: cancellation,
    );
    if (outputItems.isEmpty) {
      throw StateError('Responses 压缩返回了空历史');
    }
    return outputItems;
  }

  Future<TaskContextUsage> _loadTaskContextUsage(
    Task task,
    ProviderModelMetadata? metadata,
    String model,
    int generation,
    String? providerId,
  ) async {
    TokenUsageSnapshot? last;
    TokenUsageSnapshot? total;
    String? lastModel;
    var compactionCount = 0;
    final payloads = await _database.loadAssistantUsagePayloads(task.id);
    for (final payload in payloads) {
      final eventProviderId = payload['provider_id'];
      if (providerId != null &&
          eventProviderId is String &&
          eventProviderId.isNotEmpty &&
          eventProviderId != providerId) {
        continue;
      }
      final hasCompaction = _compactionCountInPayload(payload) > 0;
      if (hasCompaction) {
        // A compacted history is a new active context. Keep cumulative totals,
        // but do not use the pre-compaction request to trigger another compact.
        last = null;
        lastModel = null;
      }
      final stored = payload['context_usage'];
      if (stored is Map) {
        final snapshot = TaskContextUsage.fromMap(
          Map<String, Object?>.from(stored),
        );
        final eventModel = _eventModel(payload, snapshot.model);
        if (snapshot.last != null) {
          last = snapshot.last;
          lastModel = eventModel;
        }
        if (snapshot.total != null) total = snapshot.total;
        compactionCount = math.max(compactionCount, snapshot.compactionCount);
      } else {
        final rawUsage = payload['usage'];
        final usage = rawUsage is Map
            ? TokenUsageSnapshot.fromProviderUsage(
                Map<String, Object?>.from(rawUsage),
              )
            : null;
        if (usage != null) {
          last = usage;
          lastModel = _eventModel(payload);
          total =
              (total ??
                  const TokenUsageSnapshot(
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: 0,
                  )) +
              usage;
        }
        compactionCount += _compactionCountInPayload(payload);
      }
    }
    // A model switch keeps the session total, but a previous model's latest
    // request must not be displayed as the current model's context usage.
    if (_isDifferentModel(lastModel, model)) last = null;
    final result = TaskContextUsage(
      last: last,
      total: total,
      model: model.isEmpty ? null : model,
      rawContextWindow: metadata?.resolvedContextWindowTokens,
      effectiveContextWindow: metadata?.effectiveContextWindowTokens,
      autoCompactTokenLimit: metadata?.resolvedAutoCompactTokenLimit,
      compactionCount: compactionCount,
      metadataSource: metadata?.source,
    );
    if ((_taskContextGenerations[task.id] ?? 0) == generation) {
      _taskContextUsages[task.id] = result;
    }
    return result;
  }

  Future<_ContextUsageEvent> _appendContextUsage(
    Task task,
    ProviderProfile provider,
    Map<String, Object?> payload,
  ) async {
    final current =
        _taskContextUsages[task.id] ??
        await loadTaskContextUsage(task, provider: provider);
    final rawUsage = payload['usage'];
    final usage = rawUsage is Map
        ? TokenUsageSnapshot.fromProviderUsage(
            Map<String, Object?>.from(rawUsage),
          )
        : null;
    const zero = TokenUsageSnapshot(
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      totalTokens: 0,
    );
    final metadata = _contextMetadataForTask(task, provider);
    final snapshot = TaskContextUsage(
      last: usage ?? current.last,
      total: usage == null ? current.total : (current.total ?? zero) + usage,
      model: _modelForTask(task, provider),
      rawContextWindow: metadata?.resolvedContextWindowTokens,
      effectiveContextWindow: metadata?.effectiveContextWindowTokens,
      autoCompactTokenLimit: metadata?.resolvedAutoCompactTokenLimit,
      compactionCount:
          current.compactionCount + _compactionCountInPayload(payload),
      metadataSource: metadata?.source,
    );
    return _ContextUsageEvent(
      payload: {...payload, 'context_usage': snapshot.toMap()},
      usage: snapshot,
    );
  }

  void _invalidateTaskContextUsage(String taskId) {
    _taskContextGenerations[taskId] =
        (_taskContextGenerations[taskId] ?? 0) + 1;
    _taskContextUsages.remove(taskId);
    // An in-flight read cannot be cancelled. Removing it lets the next UI
    // request start a read for the new model/boundary; the generation check
    // prevents the old read from repopulating the cache.
    _taskContextLoads.remove(taskId);
  }

  static String? _eventModel(Map<String, Object?> payload, [String? fallback]) {
    final value = payload['model'];
    return value is String && value.isNotEmpty ? value : fallback;
  }

  static bool _isDifferentModel(String? eventModel, String selectedModel) {
    return selectedModel.isNotEmpty &&
        eventModel != null &&
        eventModel.isNotEmpty &&
        eventModel != selectedModel;
  }

  static int _compactionCountInPayload(Map<String, Object?> payload) {
    final items = payload['responses_output_items'];
    if (items is! List) return 0;
    return items
        .where((item) => item is Map && item['type'] == 'compaction')
        .length;
  }

  String _systemPrompt(
    Task task, {
    Project? project,
    String? workingDirectory,
  }) {
    final workMode = task.effectiveWorkMode;
    if (workMode == 'chat') {
      return 'You are a helpful conversational assistant. Do not claim to have '
          'access to a server, terminal, or files. When the user asks for an '
          'image, use the provided image.generate tool instead of claiming '
          'that an image was created without calling it.';
    }
    final scopes = <String>[];
    if (project != null) {
      scopes.add(
        'The phone project is "${project.name}". Use project.list and '
        'project.read before reading files; project paths are relative to the '
        'project root. For web projects, use local.test_web to check local '
        'HTML/CSS/media references, preview.start to open a loopback-only '
        'preview, preview.status to inspect it, and preview.logs to read '
        'console or JavaScript errors. A preview is only for web assets; it '
        'does not run Node, Python, Flutter, or other phone runtimes.',
      );
    }
    if (workModeUsesLocal(workMode)) {
      scopes.add(
        'Phone local files outside the project are not available by default. '
        'If needed, call local.request_access with the absolute path and reason '
        'and wait for the user. After approval use local.list, local.read, '
        'local.write, or local.replace only inside the granted scope. Never '
        'request or expose SSH passwords, API keys, or app credentials.',
      );
    }
    if (workModeUsesServer(workMode)) {
      final directory = workingDirectory ?? task.workingDirectory ?? 'not set';
      scopes.add(
        'The selected server working directory is $directory. Use '
        'terminal.exec for short commands; use terminal.start, terminal.poll, '
        'terminal.write, and terminal.stop for long-running commands. Use '
        'file tools for UTF-8 server files.',
      );
    }
    return 'You are an autonomous coding and operations agent running on a '
        'phone. Work until the request is complete: inspect state, make '
        'changes, and verify the result. ${scopes.join(' ')} Never claim '
        'success without checking the result. A tool call that writes local '
        'or server state may require confirmation. Any long-running server '
        'process still running when this turn ends will be stopped unless it '
        'was deliberately detached.';
  }

  Future<AgentResult> _runPreviewTask(
    Task task, {
    required String turnId,
    required String prompt,
    required List<AiAttachment> attachments,
    required List<AiMessage> initialHistory,
    required AgentCancellation cancellation,
  }) async {
    await updateTaskStatus(task.id, 'running', turnId: turnId);
    await appendTaskEvent(
      taskId: task.id,
      type: 'task.started',
      payload: {'turn_id': turnId, 'mode': task.mode},
    );
    if (cancellation.isCancelled) {
      await appendTaskEvent(
        taskId: task.id,
        type: 'task.cancelled',
        payload: {'turn_id': turnId},
      );
      await updateTaskStatus(task.id, 'cancelled', turnId: turnId);
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
    await appendTaskEvent(
      taskId: task.id,
      type: 'assistant.completed',
      payload: {'turn_id': turnId, 'text': text},
    );
    await appendTaskEvent(
      taskId: task.id,
      type: 'task.completed',
      payload: {'turn_id': turnId, 'text': text},
    );
    await updateTaskStatus(task.id, 'completed', turnId: turnId);
    return AgentResult(
      status: 'completed',
      messages: List.unmodifiable(messages),
      finalText: text,
    );
  }

  Future<List<AiMessage>> _localHistory(
    String taskId,
    String systemPrompt,
    List<TaskEvent> events, {
    required bool useResponsesCompaction,
    String? providerId,
  }) async {
    final messages = <AiMessage>[
      AiMessage(role: 'system', content: systemPrompt),
    ];
    int? assistantIndex;
    // Responses uses the output item id for the assistant call and a
    // separate call_id for the function_call_output.
    var activeToolCallIds = <String, String>{};
    int? latestProviderProjectionSequence;
    for (final event in events) {
      if (event.type == 'task.context_changed' &&
          _requiresProviderProjection(event.payload) &&
          (latestProviderProjectionSequence == null ||
              event.sequence > latestProviderProjectionSequence)) {
        latestProviderProjectionSequence = event.sequence;
      }
    }
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
          final isChatCompletions =
              event.payload['wire_api'] == 'chat-completions';
          final eventProviderId = event.payload['provider_id'];
          final isCurrentProvider =
              providerId == null ||
              eventProviderId is! String ||
              eventProviderId.isEmpty ||
              eventProviderId == providerId;
          final preserveResponsesOutputItems =
              useResponsesCompaction &&
              !isChatCompletions &&
              isCurrentProvider &&
              (latestProviderProjectionSequence == null ||
                  event.sequence > latestProviderProjectionSequence);
          final calls = _readToolCalls(
            event.payload['tool_calls'],
            requireCallId: !isChatCompletions && preserveResponsesOutputItems,
          );
          final normalizedCalls = [
            for (final call in calls)
              AiToolCall(
                id: call.id,
                name: call.name,
                arguments: call.arguments,
                callId: useResponsesCompaction
                    ? call.callId ?? call.id
                    : call.id,
              ),
          ];
          final text = event.payload['text'];
          messages.add(
            AiMessage(
              role: 'assistant',
              content: text is String ? text : '',
              toolCalls: normalizedCalls,
              finishReason: event.payload['finish_reason'] is String
                  ? event.payload['finish_reason'] as String
                  : null,
              responsesOutputItems:
                  preserveResponsesOutputItems && !isChatCompletions
                  ? _readResponsesOutputItems(
                      event.payload['responses_output_items'],
                    )
                  : const [],
            ),
          );
          assistantIndex = messages.length - 1;
          activeToolCallIds = {
            for (final call in normalizedCalls) call.id: call.toolResultId,
          };
        case 'context.compacted':
          if (!useResponsesCompaction) continue;
          final compactedProviderId = event.payload['provider_id'];
          if (providerId != null &&
              compactedProviderId is String &&
              compactedProviderId.isNotEmpty &&
              compactedProviderId != providerId) {
            continue;
          }
          final compactedItems = _readResponsesOutputItems(
            event.payload['responses_output_items'],
          );
          if (compactedItems.isEmpty) continue;
          messages.add(
            AiMessage(role: 'assistant', responsesOutputItems: compactedItems),
          );
          assistantIndex = null;
          activeToolCallIds = <String, String>{};
        case 'tool.started':
          final id = event.payload['id'];
          final name = event.payload['name'];
          final callId = event.payload['call_id'];
          final index = assistantIndex;
          final resolvedCallId = id is String
              ? activeToolCallIds[id] ??
                    (useResponsesCompaction
                        ? callId is String && callId.isNotEmpty
                              ? callId
                              : id
                        : id)
              : null;
          if (id is String &&
              name is String &&
              resolvedCallId != null &&
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
                  callId: useResponsesCompaction ? resolvedCallId : id,
                ),
              ],
              responsesOutputItems: assistant.responsesOutputItems,
            );
            activeToolCallIds[id] = resolvedCallId;
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
          final resolvedCallId = activeToolCallIds[id];
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
          if (_isHistoryBoundary(event.payload)) {
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
          } else {
            _appendPendingToolResults(
              messages,
              activeToolCallIds,
              'The previous AI context was interrupted during a provider '
              'change. Inspect the current state before continuing.',
            );
            messages.add(
              AiMessage(
                role: 'developer',
                content: _contextChangeMessage(event.payload),
              ),
            );
            assistantIndex = null;
            activeToolCallIds = <String, String>{};
          }
      }
    }
    if (useResponsesCompaction) {
      _dropHistoryBeforeLatestCompaction(messages);
    }
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (message.attachments.isEmpty) continue;
      final resolved = <AiAttachment>[];
      for (final attachment in message.attachments) {
        resolved.add(await _resolveAttachment(taskId, attachment));
      }
      messages[index] = AiMessage(
        role: message.role,
        content: message.content,
        toolCalls: message.toolCalls,
        toolCallId: message.toolCallId,
        name: message.name,
        finishReason: message.finishReason,
        responsesOutputItems: message.responsesOutputItems,
        usage: message.usage,
        attachments: resolved,
      );
    }
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

  static List<AiToolCall> _readToolCalls(
    Object? value, {
    bool requireCallId = true,
  }) {
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
      if (requireCallId && (callId is! String || callId.isEmpty)) {
        throw StateError('Stored Responses function call is missing call_id');
      }
      calls.add(
        AiToolCall(
          id: id,
          name: name,
          arguments: _validToolArguments(arguments),
          callId: callId is String && callId.isNotEmpty ? callId : null,
        ),
      );
    }
    return calls;
  }

  static bool _isHistoryBoundary(Map<String, Object?> payload) {
    // Missing history_boundary is treated as a boundary for events written by
    // older app versions.
    return payload['history_boundary'] != false;
  }

  static bool _requiresProviderProjection(Map<String, Object?> payload) {
    return payload['history_boundary'] == false &&
        payload['history_projection'] == 'provider';
  }

  static String _contextChangeMessage(Map<String, Object?> payload) {
    if (payload['history_projection'] == 'provider') {
      return '<model_switch>\n'
          'The conversation is continuing with a different AI provider. '
          'Continue from the retained transcript, but do not rely on hidden '
          'reasoning or provider-specific response state.\n'
          '</model_switch>';
    }
    final previousModel = payload['previous_model'];
    final model = payload['model'];
    final modelDescription =
        previousModel is String &&
            previousModel.isNotEmpty &&
            model is String &&
            model.isNotEmpty
        ? ' The active model changed from $previousModel to $model.'
        : '';
    return '<model_switch>\n'
        'The user was previously using a different model. Please continue '
        'the conversation according to the current model capabilities.'
        '$modelDescription\n'
        '</model_switch>';
  }

  static List<AiAttachment> _readAttachments(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map) AiAttachment.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  Future<List<AiAttachment>> _persistAttachments(
    String taskId,
    List<AiAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return const [];
    final records = <AttachmentRecord>[];
    final persisted = <AiAttachment>[];
    try {
      for (final attachment in attachments) {
        if (attachment.id != null) {
          final record = await _loadAttachmentForTask(taskId, attachment.id!);
          final bytes = await _attachmentStore.read(record);
          persisted.add(
            AiAttachment(
              id: record.id,
              name: record.name,
              mimeType: record.mimeType,
              byteLength: record.byteLength,
              base64Data: base64Encode(bytes),
            ),
          );
          continue;
        }
        final stored = await _writeAttachment(taskId, attachment);
        records.add(stored.$1);
        persisted.add(stored.$2);
      }
      await _database.saveAttachments(records);
      return List.unmodifiable(persisted);
    } catch (_) {
      for (final record in records) {
        await _attachmentStore.delete(record);
      }
      rethrow;
    }
  }

  Future<(AttachmentRecord, AiAttachment)> _writeAttachment(
    String taskId,
    AiAttachment attachment,
  ) async {
    final encoded = attachment.base64Data;
    if (encoded == null) throw StateError('附件内容不可用：${attachment.name}');
    final bytes = Uint8List.fromList(base64Decode(encoded));
    return _writeAttachmentBytes(
      taskId,
      name: attachment.name,
      mimeType: attachment.mimeType,
      bytes: bytes,
      base64Data: encoded,
    );
  }

  Future<(AttachmentRecord, AiAttachment)> _writeAttachmentBytes(
    String taskId, {
    required String name,
    required String mimeType,
    required Uint8List bytes,
    String? base64Data,
  }) async {
    final id = _newId('attachment');
    final extension = path_util.extension(name);
    final safeExtension = RegExp(r'^\.[A-Za-z0-9]{1,10}$').hasMatch(extension)
        ? extension.toLowerCase()
        : '';
    final record = AttachmentRecord(
      id: id,
      taskId: taskId,
      name: name,
      mimeType: mimeType,
      byteLength: bytes.length,
      storagePath: path_util.join(taskId, '$id$safeExtension'),
      createdAt: DateTime.now().toUtc(),
    );
    await _attachmentStore.write(record, bytes);
    return (
      record,
      AiAttachment(
        id: id,
        name: name,
        mimeType: mimeType,
        byteLength: bytes.length,
        base64Data: base64Data,
      ),
    );
  }

  Future<AiAttachment> _persistAttachmentBytes(
    String taskId, {
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final stored = await _writeAttachmentBytes(
      taskId,
      name: name,
      mimeType: mimeType,
      bytes: bytes,
    );
    try {
      await _database.saveAttachments([stored.$1]);
      return stored.$2;
    } catch (_) {
      await _attachmentStore.delete(stored.$1);
      rethrow;
    }
  }

  Future<AttachmentRecord> _loadAttachmentForTask(
    String taskId,
    String attachmentId,
  ) async {
    final record = await _database.loadAttachment(attachmentId);
    if (record == null) throw StateError('附件记录不存在');
    if (record.taskId != taskId) {
      throw StateError('附件不属于当前对话');
    }
    return record;
  }

  Future<AiAttachment> _resolveAttachment(
    String taskId,
    AiAttachment attachment,
  ) async {
    final id = attachment.id;
    if (id == null || id.isEmpty) {
      if (attachment.base64Data != null) return attachment;
      throw StateError('附件引用无效：${attachment.name}');
    }
    final record = await _loadAttachmentForTask(taskId, id);
    try {
      final bytes = await _attachmentStore.read(record);
      return AiAttachment(
        id: record.id,
        name: record.name,
        mimeType: record.mimeType,
        byteLength: record.byteLength,
        base64Data: base64Encode(bytes),
      );
    } on FileSystemException {
      throw StateError('附件文件不可用：${attachment.name}');
    }
  }

  Future<void> _migrateLegacyAttachments(String taskId) {
    final pending = _attachmentMigrations[taskId];
    if (pending != null) return pending;
    final migration = _migrateLegacyAttachmentsNow(taskId);
    _attachmentMigrations[taskId] = migration;
    return migration.whenComplete(() {
      if (identical(_attachmentMigrations[taskId], migration)) {
        _attachmentMigrations.remove(taskId);
      }
    });
  }

  Future<void> _migrateLegacyAttachmentsNow(String taskId) async {
    final events = await _database.loadLegacyAttachmentEvents(taskId);
    for (final event in events) {
      if (event.type == 'tool.completed') {
        await _migrateLegacyGeneratedImage(event);
        continue;
      }
      final source = event.payload['attachments'];
      if (source is! List) continue;
      final records = <AttachmentRecord>[];
      final migrated = <Map<String, Object?>>[];
      try {
        for (final value in source) {
          if (value is! Map) continue;
          final attachment = AiAttachment.fromJson(
            Map<String, Object?>.from(value),
          );
          if (attachment.id != null) {
            migrated.add(attachment.toJson());
            continue;
          }
          final stored = await _writeAttachment(taskId, attachment);
          records.add(stored.$1);
          migrated.add(stored.$2.toJson());
        }
        final replacement = TaskEvent(
          eventId: event.eventId,
          taskId: event.taskId,
          sequence: event.sequence,
          type: event.type,
          timestamp: event.timestamp,
          payload: {...event.payload, 'attachments': migrated},
        );
        await _database.replaceEventAttachments(replacement, records);
        _replaceLoadedEvent(replacement);
      } catch (_) {
        for (final record in records) {
          await _attachmentStore.delete(record);
        }
      }
    }
  }

  Future<void> _migrateLegacyGeneratedImage(TaskEvent event) async {
    final value = event.payload['result'];
    if (value is! Map || value['data_url'] is! String) return;
    final dataUrl = value['data_url'] as String;
    final separator = dataUrl.indexOf(',');
    final marker = dataUrl.indexOf(';base64');
    if (!dataUrl.startsWith('data:image/') ||
        marker <= 5 ||
        separator <= marker) {
      return;
    }
    final mimeType = dataUrl.substring(5, marker);
    final extension = switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'png',
    };
    final records = <AttachmentRecord>[];
    try {
      final stored = await _writeAttachment(
        event.taskId,
        AiAttachment(
          name: 'generated-${event.sequence}.$extension',
          mimeType: mimeType,
          base64Data: dataUrl.substring(separator + 1),
        ),
      );
      records.add(stored.$1);
      final result = Map<String, Object?>.from(value)..remove('data_url');
      result.addAll({
        'attachment_id': stored.$2.id,
        'name': stored.$2.name,
        'mime_type': stored.$2.mimeType,
        'bytes': stored.$2.byteLength,
      });
      final replacement = TaskEvent(
        eventId: event.eventId,
        taskId: event.taskId,
        sequence: event.sequence,
        type: event.type,
        timestamp: event.timestamp,
        payload: {...event.payload, 'result': result},
      );
      await _database.replaceEventAttachments(replacement, records);
      _replaceLoadedEvent(replacement);
    } catch (_) {
      for (final record in records) {
        await _attachmentStore.delete(record);
      }
    }
  }

  void _replaceLoadedEvent(TaskEvent replacement) {
    final loaded = _events[replacement.taskId];
    if (loaded == null) return;
    _events = {
      ..._events,
      replacement.taskId: List.unmodifiable([
        for (final item in loaded)
          if (item.eventId == replacement.eventId) replacement else item,
      ]),
    };
  }

  void _mergeLoadedEvent(TaskEvent event) {
    _events = {
      ..._events,
      event.taskId: List.unmodifiable(
        _mergeEvents(eventsFor(event.taskId), [event]),
      ),
    };
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

  AgentTool _imageGenerationTool(
    ProviderProfile provider,
    Project? project,
    String taskId, {
    required AgentCancellation cancellation,
  }) {
    return AgentTool(
      definition: const AiToolDefinition(
        name: 'image.generate',
        description:
            'Generate one image from a text prompt. If a phone project is '
            'bound, save the result there and return its relative path.',
        parameters: {
          'type': 'object',
          'required': ['prompt'],
          'properties': {
            'prompt': {'type': 'string'},
            'model': {'type': 'string'},
            'size': {
              'type': 'string',
              'description': 'Provider-supported size, for example 1024x1024',
            },
            'filename': {'type': 'string'},
          },
        },
      ),
      requiresConfirmation: true,
      call: (arguments) => _generateImage(
        provider,
        project,
        taskId,
        arguments,
        cancellation: cancellation,
      ),
    );
  }

  Future<Object?> _generateImage(
    ProviderProfile provider,
    Project? project,
    String taskId,
    Map<String, Object?> arguments, {
    required AgentCancellation cancellation,
  }) async {
    final prompt = arguments['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      throw ArgumentError('prompt is required');
    }
    final model =
        arguments['model'] is String &&
            (arguments['model'] as String).trim().isNotEmpty
        ? (arguments['model'] as String).trim()
        : provider.model;
    final size =
        arguments['size'] is String &&
            (arguments['size'] as String).trim().isNotEmpty
        ? (arguments['size'] as String).trim()
        : '1024x1024';
    final apiKey = await _readCredential(
      provider.apiKeyRef,
      '图片供应商 API Key 不可用',
    );
    final client = ImageGenerationClient(
      baseUrl: provider.baseUrl,
      apiKey: apiKey,
    );
    try {
      final generated = await client.generate(
        prompt: prompt.trim(),
        model: model,
        size: size,
        responseFormat: 'b64_json',
        cancellation: cancellation.whenCancelled,
      );
      Uint8List bytes;
      String mimeType;
      final encoded = generated.b64Json;
      if (encoded != null) {
        bytes = Uint8List.fromList(base64Decode(encoded));
        mimeType = 'image/png';
      } else if (generated.url != null) {
        final downloaded = await client.download(
          generated.url!,
          cancellation: cancellation.whenCancelled,
        );
        bytes = downloaded.bytes;
        mimeType = downloaded.mimeType;
      } else {
        throw const ImageGenerationInvalidResponseException('图片供应商没有返回图片');
      }

      final relativePath = _generatedImagePath(arguments['filename'], mimeType);
      final attachment = await _persistAttachmentBytes(
        taskId,
        name: path_util.basename(relativePath),
        mimeType: mimeType,
        bytes: bytes,
      );
      if (project != null) {
        await _projectFiles.writeBytes(project, relativePath, bytes);
        _invalidateProjectDirectoryCache(project.id);
      }
      return {
        'generated': true,
        'attachment_id': attachment.id,
        'name': attachment.name,
        'mime_type': mimeType,
        'bytes': bytes.length,
        if (project != null) 'project_path': relativePath,
        if (generated.revisedPrompt != null)
          'revised_prompt': generated.revisedPrompt,
      };
    } finally {
      client.close();
    }
  }

  static String _generatedImagePath(Object? value, String mimeType) {
    final raw = value is String ? value.trim() : '';
    final safe = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceFirst(RegExp(r'^\.+'), '');
    final extension = switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'png',
    };
    final baseName = safe.isEmpty
        ? 'generated-${DateTime.now().millisecondsSinceEpoch}'
        : path_util.basenameWithoutExtension(safe);
    return 'generated/$baseName.$extension';
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
      cpuUsage: int.tryParse(values['cpu_usage']?.trim() ?? ''),
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
    await Future.wait(
      List<Future<void>>.of(_taskStatusTails.values),
      eagerError: false,
    );
    await _localPreview.close();
    _providerUsageClient.close();
    _localAccess.clear();
    await _database.close();
  }
}

class _ContextUsageEvent {
  const _ContextUsageEvent({required this.payload, required this.usage});

  final Map<String, Object?> payload;
  final TaskContextUsage usage;
}

const _agentAutoExecuteSetting = 'agent_auto_execute';
const _betaUpdatesSetting = 'beta_updates_enabled';
const _fontScaleSetting = 'font_scale';
const _imageProviderSetting = 'image_provider_id';
const _lastDashboardServerSetting = 'last_dashboard_server_id';

String _normalizeRemotePath(String value) {
  final path = value.trim();
  if (path.length <= 1) return path;
  return path.replaceFirst(RegExp(r'/+$'), '');
}

String? _normalizeOptionalValue(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _normalizeExecutionMode(String value) {
  switch (value) {
    case 'auto':
      return 'auto';
    case 'auto_review':
      return 'auto_review';
    default:
      return 'confirm';
  }
}

bool _isTerminalTaskStatus(String status) => const {
  'completed',
  'failed',
  'cancelled',
  'canceled',
  'unknown',
}.contains(status);

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

bool _terminalEventMatchesLatestEvent(TaskEvent terminal, TaskEvent? latest) {
  if (latest == null) return false;
  if (terminal.sequence == latest.sequence) return true;
  final terminalTurnId = terminal.payload['turn_id'];
  final latestTurnId = latest.payload['turn_id'];
  return latest.type == 'task.cancel_requested' &&
      terminalTurnId is String &&
      terminalTurnId.isNotEmpty &&
      latestTurnId == terminalTurnId;
}
