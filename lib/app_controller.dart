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
import 'agent/subagents.dart';
import 'agent/tool_display.dart';
import 'credentials/credential_store.dart';
import 'domain/models.dart';
import 'local/local_preview.dart';
import 'local/project_files.dart';
import 'local/local_file_access.dart';
import 'platform/android_task_service.dart';
import 'platform/android_storage_access.dart';
import 'platform/app_update_installer.dart';
import 'providers/provider_connection_tester.dart';
import 'providers/image_generation_client.dart';
import 'providers/provider_usage_client.dart';
import 'server_status_script.dart';
import 'ssh/resumable_file_download.dart';
import 'ssh/resumable_file_upload.dart';
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

class _ServerDirectoryProbe {
  const _ServerDirectoryProbe({
    required this.fingerprint,
    required this.unchanged,
    this.entries,
  });

  final String fingerprint;
  final bool unchanged;
  final List<SshDirectoryEntry>? entries;
}

class _CachedServerFileContent {
  const _CachedServerFileContent({
    required this.content,
    required this.size,
    required this.modified,
  });

  final String content;
  final int? size;
  final DateTime? modified;
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
  final AppUpdateInstaller _updateInstaller = const AppUpdateInstaller();
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
  final Map<String, SubagentTree> _subagentTrees = {};
  final Map<String, LocalFileAccessStore> _localAccess = {};
  final Map<String, RemoteAgentTools> _phoneTools = {};
  final Map<String, List<SshDirectoryEntry>> _directoryCache = {};
  final Map<String, ServerDirectoryCacheRecord> _directoryCacheRecords = {};
  final Map<String, Future<List<SshDirectoryEntry>>> _directoryLoads = {};
  final Map<String, _CachedServerFileContent> _serverFileContentCache = {};
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
  final Map<String, StringBuffer> _streamingAssistantBuffers = {};
  final Map<String, ValueNotifier<String>> _streamingAssistantNotifiers = {};
  final Map<String, Timer> _streamingAssistantFlushes = {};
  final Map<String, ProviderUsageSnapshot> _providerUsages = {};
  final Map<String, Future<ProviderUsageSnapshot>> _providerUsageLoads = {};
  final Map<String, String> _imageModels = {};
  final Map<String, TaskContextUsage> _taskContextUsages = {};
  final Map<String, Future<TaskContextUsage>> _taskContextLoads = {};
  final Map<String, Future<TaskContextUsage>> _taskCompactions = {};
  final Map<String, int> _taskContextGenerations = {};
  final Map<String, String> _taskProgressLabels = {};
  final Set<String> _foregroundServiceTasks = {};
  final Map<String, ServerDashboard> _dashboardCache = {};
  final Map<String, bool> _sidebarExpanded = {};
  Future<void> _loadTail = Future<void>.value();
  int _idSequence = 0;

  List<ServerProfile> _servers = const [];
  List<ProviderProfile> _providers = const [];
  List<Project> _projects = const [];
  List<Task> _tasks = const [];
  Map<String, List<TaskEvent>> _events = const {};
  bool _agentAutoExecute = false;
  bool _betaUpdatesEnabled = false;
  bool _floatingCapsuleEnabled = false;
  double _floatingCapsuleScale = 1.0;
  double _floatingCapsuleLengthScale = 1.0;
  bool _documentModuleEnabled = true;
  SubagentSettings _subagentSettings = const SubagentSettings();
  String? _imageProviderId;
  String? _lastDashboardServerId;
  String? _lastConversationTaskId;
  double _fontScale = 1.0;
  bool _loading = true;
  String? _loadError;
  bool _disposed = false;

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  List<ProviderProfile> get providers => List.unmodifiable(_providers);
  List<Project> get projects => List.unmodifiable(_projects);
  List<Task> get tasks =>
      List.unmodifiable(_tasks.where((task) => !task.isSubagent));
  bool get agentAutoExecute => _agentAutoExecute;
  bool get betaUpdatesEnabled => _betaUpdatesEnabled;
  bool get floatingCapsuleEnabled => _floatingCapsuleEnabled;
  double get floatingCapsuleScale => _floatingCapsuleScale;
  double get floatingCapsuleLengthScale => _floatingCapsuleLengthScale;
  bool get documentModuleEnabled => _documentModuleEnabled;
  SubagentSettings get subagentSettings => _subagentSettings;
  String? get lastDashboardServerId => _lastDashboardServerId;
  String? get lastConversationTaskId => _lastConversationTaskId;
  double get fontScale => _fontScale;
  String? get imageProviderId => _imageProviderId;
  String imageModelFor(String providerId) => _imageModels[providerId] ?? '';
  bool get isLoading => _loading;
  String? get loadError => _loadError;

  ServerDashboard? cachedServerDashboard(ServerProfile profile) =>
      _dashboardCache[_dashboardCacheKey(profile)];

  bool sidebarSectionExpanded(String sectionId) =>
      _sidebarExpanded[sectionId] ?? true;

  ProviderUsageSnapshot? providerUsageFor(String providerId) =>
      _providerUsages[providerId];

  ProviderModelMetadata? modelMetadataFor(
    ProviderProfile provider,
    String model,
  ) => resolveProviderModelMetadata(provider, model);

  TaskContextUsage? contextUsageFor(Task task, {ProviderProfile? provider}) {
    final cached = _taskContextUsages[task.id];
    if (cached == null) return null;
    final activeProvider = _contextProviderFor(task, provider);
    return cached.withMetadata(
      _contextMetadataForTask(task, activeProvider),
      selectedModel: _modelForTask(task, activeProvider),
      contextWindowMode:
          activeProvider?.contextWindowMode ?? defaultContextWindowMode,
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
      return cached.withMetadata(
        metadata,
        selectedModel: model,
        contextWindowMode:
            activeProvider?.contextWindowMode ?? defaultContextWindowMode,
      );
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
      activeProvider?.contextWindowMode ?? defaultContextWindowMode,
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

  Task? taskForId(String taskId) {
    for (final task in _tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  bool hasActiveSubagents(String rootTaskId) {
    return _subagentTrees[rootTaskId]?.hasActiveAgents ?? false;
  }

  List<SubagentNode> subagentsFor(String rootTaskId) {
    return List.unmodifiable(_subagentTrees[rootTaskId]?.agents ?? const []);
  }

  bool isTaskCompacting(String taskId) => _taskCompactions.containsKey(taskId);

  String? activeTurnIdFor(String taskId) => _taskRunIds[taskId];

  List<TaskEvent> eventsFor(String taskId) {
    // Event lists are replaced with unmodifiable lists whenever they change.
    // Reusing the same instance lets the chat UI cache its presentation work.
    return _events[taskId] ?? const <TaskEvent>[];
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

  ValueListenable<String> streamingAssistantTextListenable(String taskId) {
    return _streamingAssistantNotifiers.putIfAbsent(
      taskId,
      () => ValueNotifier(_streamingAssistantText[taskId] ?? ''),
    );
  }

  void _appendStreamingAssistantText(String taskId, String delta) {
    if (_disposed || delta.isEmpty) return;
    final buffer = _streamingAssistantBuffers.putIfAbsent(
      taskId,
      () => StringBuffer(_streamingAssistantText[taskId] ?? ''),
    );
    buffer.write(delta);
    if (_streamingAssistantFlushes.containsKey(taskId)) return;
    _streamingAssistantFlushes[taskId] = Timer(
      const Duration(milliseconds: 32),
      () {
        _streamingAssistantFlushes.remove(taskId);
        _flushStreamingAssistantText(taskId);
      },
    );
  }

  void _flushStreamingAssistantText(String taskId) {
    if (_disposed) return;
    final current = _streamingAssistantBuffers[taskId];
    if (current == null) return;
    final text = current.toString();
    if (_streamingAssistantText[taskId] == text) return;
    _streamingAssistantText[taskId] = text;
    final notifier = _streamingAssistantNotifiers[taskId];
    if (notifier != null && notifier.value != text) notifier.value = text;
  }

  void _clearStreamingAssistantText(String taskId) {
    _streamingAssistantFlushes.remove(taskId)?.cancel();
    _flushStreamingAssistantText(taskId);
    _streamingAssistantBuffers.remove(taskId);
    _streamingAssistantText.remove(taskId);
    if (_disposed) return;
    final notifier = _streamingAssistantNotifiers[taskId];
    if (notifier != null && notifier.value.isNotEmpty) notifier.value = '';
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
    final directoryCaches = await _database.loadServerDirectoryCaches();
    _directoryCache.clear();
    _directoryCacheRecords.clear();
    for (final record in directoryCaches) {
      _directoryCache[record.cacheKey] = List<SshDirectoryEntry>.unmodifiable(
        record.entries,
      );
      _directoryCacheRecords[record.cacheKey] = record;
    }
    _providers = await _database.loadProviders();
    _projects = await _database.loadProjects();
    _agentAutoExecute =
        await _database.readSetting(_agentAutoExecuteSetting) == 'true';
    _betaUpdatesEnabled =
        await _database.readSetting(_betaUpdatesSetting) == 'true';
    _floatingCapsuleEnabled =
        await _database.readSetting(_floatingCapsuleSetting) == 'true';
    _floatingCapsuleScale =
        (double.tryParse(
                  await _database.readSetting(_floatingCapsuleScaleSetting) ??
                      '',
                ) ??
                1.0)
            .clamp(0.2, 1.4)
            .toDouble();
    _floatingCapsuleLengthScale =
        (double.tryParse(
                  await _database.readSetting(
                        _floatingCapsuleLengthScaleSetting,
                      ) ??
                      '',
                ) ??
                1.0)
            .clamp(0.2, 1.4)
            .toDouble();
    _documentModuleEnabled =
        (await _database.readSetting(_documentModuleSetting)) != 'false';
    _sidebarExpanded['other'] = await _readSidebarExpandedSetting('other');
    for (final project in _projects) {
      final sectionId = 'project:${project.id}';
      _sidebarExpanded[sectionId] = await _readSidebarExpandedSetting(
        sectionId,
      );
    }
    final savedImageProviderId = await _database.readSetting(
      _imageProviderSetting,
    );
    _imageProviderId = savedImageProviderId?.isEmpty == true
        ? null
        : savedImageProviderId;
    _imageModels.clear();
    for (final provider in _providers) {
      final savedImageModel = await _database.readSetting(
        _imageModelSettingKey(provider.id),
      );
      if (savedImageModel != null && savedImageModel.trim().isNotEmpty) {
        _imageModels[provider.id] = savedImageModel.trim();
      }
    }
    final savedDashboardServerId = await _database.readSetting(
      _lastDashboardServerSetting,
    );
    _lastDashboardServerId = savedDashboardServerId?.isEmpty == true
        ? null
        : savedDashboardServerId;
    final savedConversationTaskId = await _database.readSetting(
      _lastConversationTaskSetting,
    );
    _lastConversationTaskId = savedConversationTaskId?.isEmpty == true
        ? null
        : savedConversationTaskId;
    _fontScale =
        (double.tryParse(
                  await _database.readSetting(_fontScaleSetting) ?? '',
                ) ??
                1.0)
            .clamp(0.85, 1.15)
            .toDouble();
    _subagentSettings = SubagentSettings.fromJson(
      await _database.readSetting(_subagentSettingsSetting),
    );
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
    if (!await AndroidStorageAccess.ensureForPath(canonical)) {
      throw StateError('没有手机共享存储写入权限，无法授权该路径');
    }
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

  /// Enables the optional cross-app status overlay when its system permission
  /// is already available. The UI offers the permission action separately.
  Future<bool> setFloatingCapsuleEnabled(bool enabled) async {
    if (enabled && !await _taskService.canDrawOverlays()) {
      return false;
    }
    await _database.writeSetting(
      _floatingCapsuleSetting,
      enabled ? 'true' : 'false',
    );
    _floatingCapsuleEnabled = enabled;
    if (_runningTasks.isNotEmpty) {
      await _taskService.setOverlayEnabled(enabled);
    }
    _notify();
    return true;
  }

  Future<void> setFloatingCapsuleScale(double scale) async {
    final value = scale.clamp(0.2, 1.4).toDouble();
    await _database.writeSetting(_floatingCapsuleScaleSetting, '$value');
    _floatingCapsuleScale = value;
    if (_runningTasks.isNotEmpty) {
      await _taskService.setOverlayScale(value);
    }
    _notify();
  }

  Future<void> setFloatingCapsuleLengthScale(double scale) async {
    final value = scale.clamp(0.2, 1.4).toDouble();
    await _database.writeSetting(_floatingCapsuleLengthScaleSetting, '$value');
    _floatingCapsuleLengthScale = value;
    if (_runningTasks.isNotEmpty) {
      await _taskService.setOverlayLengthScale(value);
    }
    _notify();
  }

  Future<void> setFloatingCapsuleApproval(
    String taskId, {
    String? label,
    bool allowReadOnly = false,
  }) {
    return _taskService.setOverlayApproval(
      taskId,
      label: label,
      allowReadOnly: allowReadOnly,
    );
  }

  Future<void> setDocumentModuleEnabled(bool enabled) async {
    await _database.writeSetting(
      _documentModuleSetting,
      enabled ? 'true' : 'false',
    );
    _documentModuleEnabled = enabled;
    _notify();
  }

  Future<void> setSidebarSectionExpanded(
    String sectionId,
    bool expanded,
  ) async {
    _sidebarExpanded[sectionId] = expanded;
    await _database.writeSetting(
      _sidebarExpandedSettingKey(sectionId),
      expanded ? 'true' : 'false',
    );
  }

  Future<bool> _readSidebarExpandedSetting(String sectionId) async {
    final value = await _database.readSetting(
      _sidebarExpandedSettingKey(sectionId),
    );
    return value == null || value == 'true';
  }

  Future<bool> canDrawOverlays() => _taskService.canDrawOverlays();

  Future<bool> requestOverlayPermission() =>
      _taskService.requestOverlayPermission();

  Future<bool> canPostNotifications() => _taskService.canPostNotifications();

  Future<bool> requestNotificationPermission() =>
      _taskService.requestNotificationPermission();

  Future<bool> hasExternalStorageAccess() => AndroidStorageAccess.hasAccess();

  Future<bool> requestExternalStorageAccess() =>
      AndroidStorageAccess.requestAccess();

  Future<bool> canInstallPackages() => _updateInstaller.canInstallPackages();

  Future<bool> requestInstallPermission() =>
      _updateInstaller.requestInstallPermission();

  Future<void> setFontScale(double scale) async {
    final value = scale.clamp(0.85, 1.15).toDouble();
    await _database.writeSetting(_fontScaleSetting, '$value');
    _fontScale = value;
    _notify();
  }

  Future<void> setSubagentSettings(SubagentSettings settings) async {
    await _database.writeSetting(_subagentSettingsSetting, settings.toJson());
    _subagentSettings = settings;
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

  Future<void> setImageModel(String providerId, String? model) async {
    if (!_providers.any((provider) => provider.id == providerId)) {
      throw StateError('图片供应商不存在');
    }
    await _saveImageModel(providerId, model);
    _notify();
  }

  Future<void> _saveImageModel(String providerId, String? model) async {
    final value = model?.trim() ?? '';
    await _database.writeSetting(_imageModelSettingKey(providerId), value);
    if (value.isEmpty) {
      _imageModels.remove(providerId);
    } else {
      _imageModels[providerId] = value;
    }
  }

  Future<void> setLastDashboardServer(String? serverId) async {
    final value = serverId?.trim();
    await _database.writeSetting(_lastDashboardServerSetting, value ?? '');
    _lastDashboardServerId = value == null || value.isEmpty ? null : value;
  }

  Future<void> setLastConversationTask(String? taskId) async {
    final value = taskId?.trim();
    await _database.writeSetting(_lastConversationTaskSetting, value ?? '');
    _lastConversationTaskId = value == null || value.isEmpty ? null : value;
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
        : resolveProviderModelMetadata(previousProvider, previousModel);
    final nextMetadata = nextProvider == null
        ? null
        : resolveProviderModelMetadata(nextProvider, nextModel);
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
    final modeChanged = current.mode != normalizedMode;
    final workModeChanged = current.effectiveWorkMode != normalizedWorkMode;
    final targetChanged =
        current.projectId != normalizedProjectId ||
        current.serverId != normalizedServerId ||
        current.workingDirectory != normalizedWorkingDirectory;
    final modelChanged = previousModel != nextModel;
    final configurationChanged =
        modeChanged || workModeChanged || targetChanged;
    final contextChanged =
        configurationChanged || providerContextChanged || modelChanged;
    final remoteTargetChanged =
        current.serverId != normalizedServerId ||
        current.workingDirectory != normalizedWorkingDirectory ||
        workModeUsesServer(current.effectiveWorkMode) !=
            workModeUsesServer(normalizedWorkMode);
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
    if (remoteTargetChanged) {
      try {
        await _releasePhoneTask(taskId);
      } catch (_) {
        // A changed task can reconnect with the new target even if closing
        // the old channel reports an error.
      }
    }
    await _database.saveTask(updated);
    _tasks = [
      for (final task in _tasks) task.id == updated.id ? updated : task,
    ];

    if (contextChanged) {
      if (current.projectId != normalizedProjectId) {
        _localAccess.remove(taskId);
      }
      _invalidateTaskContextUsage(taskId);
      final historyProjection = providerTransportChanged
          ? 'provider'
          : configurationChanged
          ? 'configuration'
          : 'model';
      final reason = configurationChanged
          ? 'configuration_changed'
          : providerContextChanged
          ? 'provider_changed'
          : 'model_changed';
      await appendTaskEvent(
        taskId: taskId,
        type: 'task.context_changed',
        payload: {
          'history_boundary': false,
          'history_projection': historyProjection,
          'reason': reason,
          if (configurationChanged) ...{
            'previous_mode': current.mode,
            'mode': normalizedMode,
            'previous_work_mode': current.effectiveWorkMode,
            'work_mode': normalizedWorkMode,
            'previous_project_id': current.projectId,
            'project_id': normalizedProjectId,
            'previous_server_id': current.serverId,
            'server_id': normalizedServerId,
            'previous_working_directory': current.workingDirectory,
            'working_directory': normalizedWorkingDirectory,
          },
          'previous_provider_id': previousProvider?.id,
          'provider_id': nextProvider?.id,
          'previous_model': previousModel,
          'model': nextModel,
          'wire_api': nextProvider?.wireApi,
          'model_changed': modelChanged,
          'previous_model_override': current.modelOverride,
          'model_override': normalizedModelOverride,
          if (compHashChanged) 'comp_hash_changed': true,
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
    _publishTaskProgress(taskId, _taskProgressForStatus(status));
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
    final progress = _taskProgressForEvent(type, payload);
    if (progress != null) _publishTaskProgress(taskId, progress);
    _notify();
    return event;
  }

  Future<void> deleteTask(Task task) async {
    if (!task.isSubagent) {
      final tree = _subagentTrees[task.id];
      final treeClose = tree?.close();
      final rootRun = _taskRuns[task.id];
      if (rootRun != null) {
        stopTask(task.id);
        try {
          await rootRun;
        } catch (_) {
          // The task is being deleted; its final error is no longer actionable.
        }
      }
      await treeClose;
      final descendants = _tasks
          .where((item) => item.rootTaskId == task.id)
          .toList(growable: false);
      for (final child in descendants) {
        await deleteTask(child);
      }
      _subagentTrees.remove(task.id);
    }
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
    _disposeStreamingAssistantState(task.id);
    await _database.deleteTask(task.id);
    if (_lastConversationTaskId == task.id) {
      await setLastConversationTask(null);
    }
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
      final localAccess = useLocalTools || useServerTools
          ? _localAccess.putIfAbsent(task.id, LocalFileAccessStore.new)
          : null;

      if (task.mode == 'agent') {
        Project? project;
        String? workingDirectory;
        if (useLocalTools) {
          tools.addAll(LocalAgentTools(localAccess!).tools);
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
              documentModuleEnabled: _documentModuleEnabled,
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
              localAccess: localAccess,
            );
            temporaryRemoteTools = remoteTools;
          } else {
            workingDirectory =
                task.workingDirectory ?? server.defaultWorkingDirectory;
            remoteTools.configureContext(
              project: useLocalTools ? project : null,
              projectFiles: useLocalTools ? _projectFiles : null,
              localAccess: localAccess,
            );
          }
          tools.addAll(
            _serializeRemoteWrites(
              remoteTools.tools,
              _remoteWriteLeaseKey(task, server.id, workingDirectory),
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
      if (imageProvider != null &&
          imageModelFor(imageProvider.id).trim().isNotEmpty) {
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
      final modelMetadata = resolveProviderModelMetadata(provider, model);
      client = createAiClient(
        wireApi: provider.wireApi,
        baseUrl: provider.baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort:
            task.reasoningEffortOverride ?? provider.reasoningEffort,
        inputModalities: modelMetadata?.inputModalities,
      );
      final compactionClient = client is AiCompactionClient
          ? client as AiCompactionClient
          : null;
      if (compactionClient == null) {
        throw StateError('当前 Responses 客户端不支持本地压缩');
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
      final summary = await compactionClient.compact(
        messages: messages,
        instructions: systemPrompt,
        cancellation: cancellation.whenCancelled,
      );
      if (summary.trim().isEmpty) throw StateError('Responses 压缩返回了空摘要');
      final retainedUserMessages = _codexRetainedUserMessages(messages);

      await appendTaskEvent(
        taskId: task.id,
        type: 'context.compacted',
        payload: {
          'source': 'manual',
          'provider_id': provider.id,
          'wire_api': provider.wireApi,
          'model': model,
          'compaction_mode': 'local',
          'summary': summary,
          'retained_user_messages': _serializeCodexRetainedUserMessages(
            retainedUserMessages,
          ),
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
    Future<bool> Function(
      Task task,
      AgentTool tool,
      Map<String, Object?> arguments,
    )?
    confirmForTask,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    FutureOr<bool> Function(Task task, SshHostKey key)? onFirstHostKeyForTask,
    SshUserInfoHandler? onUserInfoRequest,
    FutureOr<List<String>?> Function(Task task, SshUserInfoRequest request)?
    onUserInfoRequestForTask,
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
      confirmForTask: confirmForTask,
      onFirstHostKey: onFirstHostKey,
      onFirstHostKeyForTask: onFirstHostKeyForTask,
      onUserInfoRequest: onUserInfoRequest,
      onUserInfoRequestForTask: onUserInfoRequestForTask,
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
    Future<bool> Function(
      Task task,
      AgentTool tool,
      Map<String, Object?> arguments,
    )?
    confirmForTask,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    FutureOr<bool> Function(Task task, SshHostKey key)? onFirstHostKeyForTask,
    SshUserInfoHandler? onUserInfoRequest,
    FutureOr<List<String>?> Function(Task task, SshUserInfoRequest request)?
    onUserInfoRequestForTask,
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
    _clearStreamingAssistantText(task.id);
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
    final confirmForCurrentTask = confirmForTask == null
        ? confirm
        : (tool, arguments) => confirmForTask(task, tool, arguments);
    if (confirmForCurrentTask != null) {
      waitingConfirm = (tool, arguments) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return false;
          return await confirmForCurrentTask(tool, arguments);
        } finally {
          await restoreTaskAfterWaiting();
        }
      };
    }

    FutureOr<bool> Function(SshHostKey)? waitingHostKey;
    final onFirstHostKeyForCurrentTask = onFirstHostKeyForTask == null
        ? onFirstHostKey
        : (key) => onFirstHostKeyForTask(task, key);
    if (onFirstHostKeyForCurrentTask != null) {
      waitingHostKey = (key) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return false;
          return await onFirstHostKeyForCurrentTask(key);
        } finally {
          await restoreTaskAfterWaiting();
        }
      };
    }

    SshUserInfoHandler? waitingUserInfo;
    final onUserInfoRequestForCurrentTask = onUserInfoRequestForTask == null
        ? onUserInfoRequest
        : (request) => onUserInfoRequestForTask(task, request);
    if (onUserInfoRequestForCurrentTask != null) {
      waitingUserInfo = (request) async {
        await markTaskWaiting();
        try {
          if (cancellation.isCancelled) return null;
          return await onUserInfoRequestForCurrentTask(request);
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
      await _taskService.start(
        task.id,
        title: task.title,
        overlayEnabled: _floatingCapsuleEnabled,
        overlayScale: _floatingCapsuleScale,
        overlayLengthScale: _floatingCapsuleLengthScale,
      );
      serviceStarted = true;
      _foregroundServiceTasks.add(task.id);
      _publishTaskProgress(task.id, '分析中');
      await appendTurnEvent('task.started', {'mode': task.mode});

      final activeProvider = provider!;
      final apiKey = await _readCredential(
        activeProvider.apiKeyRef,
        '供应商 API Key 不可用',
      );
      final tools = <AgentTool>[];
      var systemPrompt = _systemPrompt(task);
      final localAccess = useLocalTools || useServerTools
          ? _localAccess.putIfAbsent(task.id, LocalFileAccessStore.new)
          : null;
      if (task.mode == 'agent') {
        Project? project;
        String? workingDirectory;
        if (useLocalTools) {
          localTools = LocalAgentTools(localAccess!);
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
              documentModuleEnabled: _documentModuleEnabled,
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
              project: useLocalTools ? project : null,
              projectFiles: useLocalTools ? _projectFiles : null,
              localAccess: localAccess,
            );
            _phoneTools[task.id] = remoteTools;
          } else {
            remoteTools.configureContext(
              project: useLocalTools ? project : null,
              projectFiles: useLocalTools ? _projectFiles : null,
              localAccess: localAccess,
            );
          }
          tools.addAll(
            _serializeRemoteWrites(
              remoteTools.tools,
              _remoteWriteLeaseKey(task, server.id, workingDirectory),
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
        final rootTaskId = task.rootTaskId ?? task.id;
        final rootTask = _tasks.firstWhere(
          (item) => item.id == rootTaskId,
          orElse: () => task,
        );
        final existingSubagentTree = _subagentTrees[rootTaskId];
        final tree =
            existingSubagentTree ??
            _createSubagentTree(
              rootTask,
              confirm: confirm,
              confirmForTask: confirmForTask,
              onFirstHostKey: onFirstHostKey,
              onFirstHostKeyForTask: onFirstHostKeyForTask,
              onUserInfoRequest: onUserInfoRequest,
              onUserInfoRequestForTask: onUserInfoRequestForTask,
            );
        if (existingSubagentTree != null) {
          tree.updateSettings(_subagentSettings);
        }
        _subagentTrees[rootTaskId] = tree;
        tools.addAll(tree.toolsFor(task.id));
        if (tools.isEmpty) {
          throw StateError('Agent 没有可用的项目或服务器工具');
        }
      }

      final imageProvider = imageProviderFor(task);
      if (imageProvider != null &&
          imageModelFor(imageProvider.id).trim().isNotEmpty) {
        tools.add(
          _imageGenerationTool(
            imageProvider,
            taskProject,
            task.id,
            cancellation: cancellation,
          ),
        );
      }

      final model = task.modelOverride ?? activeProvider.model;
      final modelMetadata = resolveProviderModelMetadata(activeProvider, model);
      client = createAiClient(
        wireApi: activeProvider.wireApi,
        baseUrl: activeProvider.baseUrl,
        apiKey: apiKey,
        model: model,
        reasoningEffort:
            task.reasoningEffortOverride ?? activeProvider.reasoningEffort,
        inputModalities: activeProvider.wireApi == 'responses'
            ? modelMetadata?.inputModalities
            : null,
        autoCompactTokenLimit: activeProvider.wireApi == 'responses'
            ? modelMetadata?.resolveAutoCompactTokenLimit(
                contextWindowMode: activeProvider.contextWindowMode,
              )
            : null,
      );
      final truncationPolicy =
          modelMetadata?.resolvedTruncationPolicy ??
          ProviderTruncationPolicy.codexFallback;
      final loop = AgentLoop(client: client, tools: tools);
      final initialMessages = await _localHistory(
        task.id,
        systemPrompt,
        previousEvents,
        useResponsesCompaction: activeProvider.wireApi == 'responses',
        providerId: activeProvider.id,
      );

      var eventQueue = Future<void>.value();
      final result = await loop.run(
        prompt: prompt,
        attachments: requestAttachments,
        initialMessages: initialMessages,
        executionMode: task.executionMode,
        enableTaskPlanning: task.effectiveWorkMode != 'chat',
        cancellation: cancellation,
        toolOutputLimit: truncationPolicy.limit,
        toolOutputLimitInTokens: truncationPolicy.mode == 'tokens',
        confirm: waitingConfirm,
        review: task.executionMode == 'auto_review'
            ? (tool, arguments) =>
                  _reviewTool(task, tool, arguments, cancellation: cancellation)
            : null,
        onRemoteOperationStarted: (tool) {
          if (tool.writesRemoteState) remoteOperationStarted = true;
        },
        onEvent: (type, payload) {
          if (type == 'assistant.delta') {
            final delta = payload['text'];
            _publishTaskProgress(task.id, '生成回复');
            if (_taskRunIds[task.id] == turnId &&
                delta is String &&
                delta.isNotEmpty) {
              _appendStreamingAssistantText(task.id, delta);
            }
            return Future.value();
          }
          final clearStreamingAfterPersist =
              type == 'assistant.completed' ||
              type == 'task.completed' ||
              type == 'task.failed' ||
              type == 'task.cancelled' ||
              type == 'task.unknown';
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
            // Keep streamed commentary visible until its durable event is in
            // the history. This matters for an assistant message that also
            // contains tool calls: the tools may start immediately after it.
            if (clearStreamingAfterPersist && _taskRunIds[task.id] == turnId) {
              _clearStreamingAssistantText(task.id);
              _notify();
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
        _clearStreamingAssistantText(task.id);
      }
      if (client != null) closeAiClient(client);
      if (task.mode == 'agent') {
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
      }
      if (serviceStarted) {
        try {
          final current = _tasks.firstWhere(
            (item) => item.id == task.id,
            orElse: () => task,
          );
          final status = _isTerminalTaskStatus(current.status)
              ? current.status
              : 'unknown';
          await _taskService.finish(task.id, status);
        } catch (_) {
          // The foreground service may already have been stopped by Android.
        }
        _foregroundServiceTasks.remove(task.id);
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
    _taskProgressLabels.remove(taskId);
    _notify();
  }

  void _disposeStreamingAssistantState(String taskId) {
    _streamingAssistantFlushes.remove(taskId)?.cancel();
    _streamingAssistantBuffers.remove(taskId);
    _streamingAssistantText.remove(taskId);
    _streamingAssistantNotifiers.remove(taskId)?.dispose();
  }

  SubagentTree _createSubagentTree(
    Task rootTask, {
    Future<bool> Function(AgentTool tool, Map<String, Object?> arguments)?
    confirm,
    Future<bool> Function(
      Task task,
      AgentTool tool,
      Map<String, Object?> arguments,
    )?
    confirmForTask,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    FutureOr<bool> Function(Task task, SshHostKey key)? onFirstHostKeyForTask,
    SshUserInfoHandler? onUserInfoRequest,
    FutureOr<List<String>?> Function(Task task, SshUserInfoRequest request)?
    onUserInfoRequestForTask,
  }) {
    final childConfirmForTask =
        confirmForTask ??
        (confirm == null
            ? null
            : (Task task, AgentTool tool, Map<String, Object?> arguments) =>
                  confirm(tool, arguments));
    final childHostKeyForTask =
        onFirstHostKeyForTask ??
        (onFirstHostKey == null
            ? null
            : (Task task, SshHostKey key) => onFirstHostKey(key));
    final childUserInfoForTask =
        onUserInfoRequestForTask ??
        (onUserInfoRequest == null
            ? null
            : (Task task, SshUserInfoRequest request) =>
                  onUserInfoRequest(request));

    return SubagentTree(
      rootTaskId: rootTask.id,
      settings: _subagentSettings,
      prepare: (node, {required followup}) =>
          _prepareSubagentTask(rootTask, node, followup: followup),
      start: (node, prompt) {
        final child = _tasks.firstWhere((task) => task.id == node.id);
        return runTask(
          child,
          prompt: prompt,
          confirmForTask: childConfirmForTask,
          onFirstHostKeyForTask: childHostKeyForTask,
          onUserInfoRequestForTask: childUserInfoForTask,
        );
      },
      onEvent: _recordSubagentEvent,
      interrupt: _interruptSubagentTask,
    );
  }

  Future<void> _interruptSubagentTask(SubagentNode node) async {
    if (_runningTasks.containsKey(node.id)) {
      stopTask(node.id);
      return;
    }
    final task = taskForId(node.id);
    if (task == null || _isTerminalTaskStatus(task.status)) return;
    try {
      await updateTaskStatus(node.id, 'cancelled');
    } catch (_) {
      // The parent may be deleting the task at the same time.
    }
  }

  Future<void> _prepareSubagentTask(
    Task rootTask,
    SubagentNode node, {
    required bool followup,
  }) async {
    final existingIndex = _tasks.indexWhere((task) => task.id == node.id);
    if (followup) {
      if (existingIndex < 0) throw StateError('子代理任务不存在');
      return;
    }
    if (existingIndex >= 0) throw StateError('子代理任务 ID 已存在');
    final parent = _tasks.firstWhere(
      (task) => task.id == node.parentId,
      orElse: () => rootTask,
    );
    final provider = node.providerId == null
        ? _providerForTask(parent)
        : _providerForOptionalId(node.providerId) ??
              (throw StateError('子代理供应商不存在'));
    final inheritsParentModel = node.providerId == null && node.model == null;
    final model =
        node.model ??
        (node.providerId == null
            ? _modelForTask(parent, provider)
            : provider.model);
    if (model.trim().isEmpty) {
      throw StateError('子代理供应商未配置模型，请先选择子代理模型');
    }
    final reasoning =
        node.reasoningEffort ??
        (inheritsParentModel
            ? parent.reasoningEffortOverride ?? provider.reasoningEffort
            : provider.reasoningEffort);
    final normalizedReasoning = reasoning == defaultReasoningEffort
        ? null
        : _normalizeOptionalValue(reasoning);
    ServerProfile? server;
    for (final value in _servers) {
      if (value.id == parent.serverId) {
        server = value;
        break;
      }
    }
    final workingDirectory =
        parent.workingDirectory ?? server?.defaultWorkingDirectory;
    final now = DateTime.now().toUtc();
    final child = Task(
      id: node.id,
      mode: 'agent',
      workMode: parent.effectiveWorkMode,
      projectId: parent.projectId,
      serverId: parent.serverId,
      providerId: provider.id,
      reviewProviderId: parent.reviewProviderId,
      reviewModelOverride: parent.reviewModelOverride,
      modelOverride: model.isEmpty ? null : model,
      reasoningEffortOverride: normalizedReasoning,
      title: '${rootTask.title} · ${node.taskName}',
      workingDirectory: workingDirectory,
      executionMode: parent.executionMode,
      isSubagent: true,
      parentTaskId: node.parentId,
      rootTaskId: node.rootTaskId,
      agentDepth: node.depth,
      agentName: node.taskName,
      status: 'queued',
      createdAt: now,
      updatedAt: now,
    );
    await _database.saveTask(child);
    final parentAccess = _localAccess[parent.id];
    if (parentAccess != null) _localAccess[child.id] = parentAccess;
    _tasks = [child, ..._tasks];
    _events = {..._events, child.id: const <TaskEvent>[]};
    _loadedTaskEvents.add(child.id);
    _hasEarlierTaskEvents[child.id] = false;
    _notify();
  }

  Future<void> _recordSubagentEvent(
    SubagentNode node,
    String type,
    Map<String, Object?> payload,
  ) {
    final parentTurnId = _taskRunIds[node.rootTaskId];
    return appendTaskEvent(
      taskId: node.rootTaskId,
      type: type,
      payload: {
        'agent_id': node.id,
        'parent_task_id': node.parentId,
        'root_task_id': node.rootTaskId,
        'agent_depth': node.depth,
        ...?(parentTurnId == null ? null : {'parent_turn_id': parentTurnId}),
        ...payload,
      },
    ).then<void>((_) {});
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
            userApprovalRequired: tool.userApprovalRequired,
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

  String _remoteWriteLeaseKey(
    Task task,
    String serverId,
    String? workingDirectory,
  ) {
    final projectId = task.projectId?.trim();
    final directory = workingDirectory?.trim() ?? '';
    return [
      'server',
      serverId,
      if (projectId != null && projectId.isNotEmpty) 'project:$projectId',
      'directory:$directory',
    ].join('\u0000');
  }

  void _publishTaskProgress(String taskId, String label) {
    if (!_foregroundServiceTasks.contains(taskId) ||
        label.isEmpty ||
        _taskProgressLabels[taskId] == label) {
      return;
    }
    _taskProgressLabels[taskId] = label;
    unawaited(_taskService.updateProgress(taskId, label));
  }

  static String _taskProgressForStatus(String status) {
    return switch (status) {
      'queued' => '排队中',
      'running' => '分析中',
      'waiting' => '等待确认',
      'stopping' => '正在停止',
      'completed' => '已完成',
      'failed' => '执行失败',
      'cancelled' || 'canceled' => '已停止',
      'unknown' => '状态未知',
      _ => '处理中',
    };
  }

  static String? _taskProgressForEvent(
    String type,
    Map<String, Object?> payload,
  ) {
    switch (type) {
      case 'assistant.completed':
        final calls = payload['tool_calls'];
        return calls is List && calls.isNotEmpty ? '准备执行' : '整理回复';
      case 'tool.started':
      case 'review.started':
        if (type == 'review.started') return '安全审查';
        return _taskProgressForTool(payload['name'], payload['arguments']);
      case 'tool.completed':
      case 'tool.failed':
        return '继续处理';
      case 'task.context_changed':
        return '更新上下文';
      case 'task.plan':
        return '更新计划';
      case 'task.started':
        return '分析中';
      case 'task.completed':
        return '已完成';
      case 'task.failed':
        return '执行失败';
      case 'task.cancelled':
        return '已停止';
      case 'task.unknown':
        return '状态未知';
      default:
        return null;
    }
  }

  static String _taskProgressForTool(Object? name, Object? arguments) =>
      toolActionSummary(name, arguments);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void stopTask(String taskId, {String? expectedTurnId}) {
    final cancellation = _runningTasks[taskId];
    if (cancellation == null) return;
    final turnId = _taskRunIds[taskId];
    if (expectedTurnId != null && turnId != expectedTurnId) return;
    cancellation.cancel();
    Task? task;
    for (final item in _tasks) {
      if (item.id == taskId) {
        task = item;
        break;
      }
    }
    if (task != null && task.rootTaskId == null) {
      final tree = _subagentTrees[taskId];
      if (tree != null) unawaited(tree.cancelAll());
    }
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
      if (cached != null) {
        _touchServerDirectoryCache(profile, path);
        return cached;
      }
    }

    final request = forceRefresh
        ? _refreshServerDirectory(profile, path, onFirstHostKey: onFirstHostKey)
        : _loadAndCacheServerDirectory(
            profile,
            path,
            onFirstHostKey: onFirstHostKey,
          );
    _directoryLoads[cacheKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_directoryLoads[cacheKey], request)) {
        _directoryLoads.remove(cacheKey);
      }
    }
  }

  Future<List<SshDirectoryEntry>> _loadAndCacheServerDirectory(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final entries = await _loadServerDirectory(
      profile,
      remotePath,
      onFirstHostKey: onFirstHostKey,
    );
    final cached = _storeServerDirectoryCache(
      profile,
      remotePath,
      entries,
      fingerprint: null,
      checkedAt: DateTime.now().toUtc(),
    );
    unawaited(
      _preloadChangedServerFiles(
        profile,
        const [],
        cached,
        onFirstHostKey: onFirstHostKey,
      ),
    );
    return cached;
  }

  Future<List<SshDirectoryEntry>> _refreshServerDirectory(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final cacheKey = _directoryCacheKey(profile, remotePath);
    final previous = _directoryCache[cacheKey];
    final record = _directoryCacheRecords[cacheKey];
    if (!previewMode) {
      final probe = await _probeServerDirectory(
        profile,
        remotePath,
        expectedFingerprint: _probeFingerprint(record?.fingerprint),
        onFirstHostKey: onFirstHostKey,
      );
      if (probe != null) {
        if (probe.unchanged && previous != null) {
          _touchServerDirectoryCache(profile, remotePath);
          return previous;
        }
        final entries = probe.entries;
        if (entries != null) {
          final cached = _storeServerDirectoryCache(
            profile,
            remotePath,
            entries,
            fingerprint: 'probe:${probe.fingerprint}',
            checkedAt: DateTime.now().toUtc(),
          );
          unawaited(
            _preloadChangedServerFiles(
              profile,
              previous ?? const [],
              cached,
              onFirstHostKey: onFirstHostKey,
            ),
          );
          return cached;
        }
      }
    }

    final entries = await _loadServerDirectory(
      profile,
      remotePath,
      onFirstHostKey: onFirstHostKey,
    );
    final cached = _storeServerDirectoryCache(
      profile,
      remotePath,
      entries,
      fingerprint: null,
      checkedAt: DateTime.now().toUtc(),
    );
    unawaited(
      _preloadChangedServerFiles(
        profile,
        previous ?? const [],
        cached,
        onFirstHostKey: onFirstHostKey,
      ),
    );
    return cached;
  }

  Future<_ServerDirectoryProbe?> _probeServerDirectory(
    ServerProfile profile,
    String remotePath, {
    String? expectedFingerprint,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    try {
      final result = await _withServerConnection(
        profile,
        (connection) => connection.run(
          _serverDirectoryProbeCommand(remotePath, expectedFingerprint),
          timeout: const Duration(seconds: 15),
        ),
        onFirstHostKey: onFirstHostKey,
      );
      if (result.exitCode != 0) return null;
      return _parseServerDirectoryProbe(result.stdout, remotePath);
    } catch (_) {
      return null;
    }
  }

  _ServerDirectoryProbe? _parseServerDirectoryProbe(
    String output,
    String remotePath,
  ) {
    final values = <String, String>{};
    final entries = <SshDirectoryEntry>[];
    for (final line in output.split('\n')) {
      if (line.startsWith('entry\t')) {
        final parts = line.substring('entry\t'.length).split('\t');
        if (parts.length < 4) return null;
        final itemType = parts[0];
        if (itemType != 'd' && itemType != 'f') return null;
        final size = int.tryParse(parts[1]);
        final seconds = int.tryParse(parts[2]);
        final name = parts.sublist(3).join('\t');
        if (name.isEmpty || size == null || seconds == null) return null;
        entries.add(
          SshDirectoryEntry(
            name: name,
            path: path_util.posix.join(remotePath, name),
            isDirectory: itemType == 'd',
            size: size,
            modified: DateTime.fromMillisecondsSinceEpoch(
              seconds * 1000,
              isUtc: true,
            ),
          ),
        );
        continue;
      }
      final separator = line.indexOf('=');
      if (separator > 0) {
        values[line.substring(0, separator)] = line.substring(separator + 1);
      }
    }
    if (values['probe_version'] != '1') return null;
    final fingerprint = values['fingerprint']?.trim();
    if (fingerprint == null || fingerprint.isEmpty) return null;
    final unchanged = values['unchanged'] == '1';
    if (!unchanged && values['unchanged'] != '0') return null;
    return _ServerDirectoryProbe(
      fingerprint: fingerprint,
      unchanged: unchanged,
      entries: unchanged ? null : entries,
    );
  }

  List<SshDirectoryEntry> _storeServerDirectoryCache(
    ServerProfile profile,
    String remotePath,
    Iterable<SshDirectoryEntry> entries, {
    required String? fingerprint,
    required DateTime checkedAt,
  }) {
    final cacheKey = _directoryCacheKey(profile, remotePath);
    final cachedEntries = List<SshDirectoryEntry>.unmodifiable(entries);
    final now = DateTime.now().toUtc();
    final record = ServerDirectoryCacheRecord(
      cacheKey: cacheKey,
      serverId: profile.id,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      remotePath: _normalizeRemotePath(remotePath),
      fingerprint: fingerprint,
      entries: cachedEntries,
      cachedAt: now,
      checkedAt: checkedAt,
      accessedAt: now,
    );
    _directoryCache[cacheKey] = cachedEntries;
    _directoryCacheRecords[cacheKey] = record;
    _persistServerDirectoryCache(record);
    return cachedEntries;
  }

  void _touchServerDirectoryCache(ServerProfile profile, String remotePath) {
    final cacheKey = _directoryCacheKey(profile, remotePath);
    final current = _directoryCacheRecords[cacheKey];
    if (current == null) return;
    final now = DateTime.now().toUtc();
    final updated = ServerDirectoryCacheRecord(
      cacheKey: current.cacheKey,
      serverId: current.serverId,
      host: current.host,
      port: current.port,
      username: current.username,
      remotePath: current.remotePath,
      fingerprint: current.fingerprint,
      entries: current.entries,
      cachedAt: current.cachedAt,
      checkedAt: now,
      accessedAt: now,
    );
    _directoryCacheRecords[cacheKey] = updated;
    _persistServerDirectoryCache(updated);
  }

  void _persistServerDirectoryCache(ServerDirectoryCacheRecord record) {
    unawaited(_database.saveServerDirectoryCache(record).catchError((_) {}));
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

  Future<void> writeProjectBytes(
    Project project,
    String relativePath,
    Uint8List bytes,
  ) async {
    await _ensureProjectStoragePath(project.localPath);
    await _projectFiles.writeBytes(
      project,
      _normalizeProjectUiPath(relativePath),
      bytes,
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

  String? cachedServerFileContent(
    ServerProfile profile,
    SshDirectoryEntry entry,
  ) {
    return _serverFileContentCache[_serverFileContentCacheKey(
          profile,
          entry.path,
          entry.size,
          entry.modified,
        )]
        ?.content;
  }

  Future<void> _preloadChangedServerFiles(
    ServerProfile profile,
    Iterable<SshDirectoryEntry> previousEntries,
    Iterable<SshDirectoryEntry> currentEntries, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final previousByPath = <String, SshDirectoryEntry>{
      for (final entry in previousEntries) entry.path: entry,
    };
    for (final entry in currentEntries) {
      if (entry.isDirectory || !_isPreloadableServerTextFile(entry.name)) {
        continue;
      }
      final previous = previousByPath[entry.path];
      if (previous != null && _sameDirectoryEntry(previous, entry)) continue;
      if (entry.size == null || entry.size! > _serverTextPreloadLimit) {
        continue;
      }
      final key = _serverFileContentCacheKey(
        profile,
        entry.path,
        entry.size,
        entry.modified,
      );
      if (_serverFileContentCache.containsKey(key)) continue;
      try {
        final content = await readServerFile(
          profile,
          entry.path,
          onFirstHostKey: onFirstHostKey,
        );
        if (utf8.encode(content).length > _serverTextPreloadLimit) continue;
        _serverFileContentCache[key] = _CachedServerFileContent(
          content: content,
          size: entry.size,
          modified: entry.modified,
        );
      } catch (_) {
        // Preloading is an optimization; opening the file still reads it.
      }
    }
  }

  String _serverFileContentCacheKey(
    ServerProfile profile,
    String remotePath,
    int? size,
    DateTime? modified,
  ) {
    return '${profile.id}\u0000${profile.host}\u0000${profile.port}'
        '\u0000${profile.username}\u0000${_normalizeRemotePath(remotePath)}'
        '\u0000${size ?? ''}\u0000${modified?.toUtc().millisecondsSinceEpoch ?? ''}';
  }

  static bool _sameDirectoryEntry(
    SshDirectoryEntry left,
    SshDirectoryEntry right,
  ) {
    return left.name == right.name &&
        left.path == right.path &&
        left.isDirectory == right.isDirectory &&
        left.size == right.size &&
        left.modified == right.modified;
  }

  static bool _isPreloadableServerTextFile(String name) {
    const extensions = <String>{
      '.c',
      '.cc',
      '.cpp',
      '.css',
      '.dart',
      '.go',
      '.h',
      '.hpp',
      '.html',
      '.java',
      '.js',
      '.json',
      '.jsx',
      '.kt',
      '.log',
      '.md',
      '.py',
      '.rs',
      '.sh',
      '.sql',
      '.swift',
      '.ts',
      '.tsx',
      '.txt',
      '.xml',
      '.yaml',
      '.yml',
    };
    return extensions.contains(path_util.extension(name).toLowerCase());
  }

  static const _serverTextPreloadLimit = 1024 * 1024;

  static String? _probeFingerprint(String? fingerprint) {
    if (fingerprint == null || !fingerprint.startsWith('probe:')) return null;
    final value = fingerprint.substring('probe:'.length).trim();
    return value.isEmpty ? null : value;
  }

  static String _serverDirectoryProbeCommand(
    String remotePath,
    String? expectedFingerprint,
  ) {
    final expected = expectedFingerprint == null
        ? ''
        : ' ${_shellQuote(expectedFingerprint)}';
    return '\$HOME/.local/bin/mobile-agent-status directory '
        '${_shellQuote(remotePath)}$expected';
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

  Future<File> downloadServerFileToProject(
    ServerProfile profile,
    Project project,
    String remotePath,
    String projectPath, {
    bool overwrite = false,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    FileDownloadProgress? onProgress,
  }) async {
    final sourcePath = remotePath.trim();
    if (sourcePath.isEmpty) throw ArgumentError('文件路径不能为空');
    final destinationPath = projectPath.trim();
    if (destinationPath.isEmpty) throw ArgumentError('项目文件路径不能为空');
    if (previewMode) throw StateError('预览模式不会下载真实服务器文件');

    await _ensureProjectStoragePath(project.localPath);
    await _projectFiles.ensureRoot(project);
    final target = File(
      await _projectFiles.resolveForIo(project, destinationPath),
    );
    final downloadId = _newId('download');
    final sourceKey =
        '${profile.id}\u0000${profile.host}\u0000${profile.port}\u0000$sourcePath';
    SshConnection? connection;
    var serviceStarted = false;
    var lastProgressLabel = '';

    void publishProgress(int received, int? total) {
      onProgress?.call(received, total);
      final label = total != null && total > 0
          ? '下载 ${(received * 100 / total).round()}%'
          : '下载中';
      if (label == lastProgressLabel) return;
      lastProgressLabel = label;
      unawaited(_taskService.updateProgress(downloadId, label));
    }

    Future<SshFileBytesChunk> readChunk(int offset) async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          if (connection == null || connection!.isClosed) {
            await connection?.close();
            connection = await _connectServer(
              profile,
              onFirstHostKey: onFirstHostKey,
            );
            await _saveObservedHostKey(profile, connection!.hostKey);
          }
          return await connection!.readFileBytesChunk(
            sourcePath,
            offset: offset,
          );
        } catch (_) {
          final failed = connection;
          connection = null;
          try {
            await failed?.close();
          } catch (_) {
            // The connection may already be broken.
          }
          if (attempt == 2) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 250 * (attempt + 1)),
          );
        }
      }
      throw StateError('无法读取远程文件');
    }

    try {
      await _taskService.start(
        downloadId,
        title: '文件下载',
        overlayEnabled: _floatingCapsuleEnabled,
        overlayScale: _floatingCapsuleScale,
        overlayLengthScale: _floatingCapsuleLengthScale,
      );
      serviceStarted = true;
      publishProgress(0, null);
      return await const ResumableFileDownloader().download(
        target: target,
        sourceKey: sourceKey,
        readChunk: readChunk,
        overwrite: overwrite,
        onProgress: publishProgress,
      );
    } finally {
      try {
        await connection?.close();
      } finally {
        if (serviceStarted) await _taskService.stop(downloadId);
      }
    }
  }

  Future<int> uploadFileToServer(
    ServerProfile profile,
    File source,
    String remotePath, {
    bool overwrite = true,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
    FileUploadProgress? onProgress,
  }) async {
    final sourcePath = source.path.trim();
    final destinationPath = remotePath.trim();
    if (sourcePath.isEmpty) throw ArgumentError('手机文件路径不能为空');
    if (destinationPath.isEmpty) throw ArgumentError('服务器文件路径不能为空');
    if (previewMode) return await source.length();

    return _remoteWriteQueue.run<int>(profile.id, () async {
      final totalBytes = await source.length();
      final modified = await source.lastModified();
      final sourceKey =
          '$sourcePath\u0000$totalBytes\u0000${modified.microsecondsSinceEpoch}';
      final uploadId = _newId('upload');
      SshConnection? connection;
      var serviceStarted = false;

      Future<T> withConnection<T>(
        Future<T> Function(SshConnection connection) action,
      ) async {
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            if (connection == null || connection!.isClosed) {
              await connection?.close();
              connection = await _connectServer(
                profile,
                onFirstHostKey: onFirstHostKey,
              );
              await _saveObservedHostKey(profile, connection!.hostKey);
            }
            return await action(connection!);
          } catch (_) {
            final failed = connection;
            connection = null;
            try {
              await failed?.close();
            } catch (_) {
              // The connection may already be broken.
            }
            if (attempt == 2) rethrow;
            await Future<void>.delayed(
              Duration(milliseconds: 250 * (attempt + 1)),
            );
          }
        }
        throw StateError('无法连接服务器');
      }

      void publishProgress(int uploaded, int total) {
        onProgress?.call(uploaded, total);
        final label = total > 0
            ? '上传 ${(uploaded * 100 / total).round()}%'
            : '上传中';
        unawaited(_taskService.updateProgress(uploadId, label));
      }

      final localFile = await source.open();
      try {
        await _taskService.start(
          uploadId,
          title: '文件上传',
          overlayEnabled: _floatingCapsuleEnabled,
          overlayScale: _floatingCapsuleScale,
          overlayLengthScale: _floatingCapsuleLengthScale,
        );
        serviceStarted = true;
        final uploaded = await const ResumableFileUploader().upload(
          totalBytes: totalBytes,
          prepare: () => withConnection(
            (connection) => connection.prepareFileUpload(
              destinationPath,
              sourceKey: sourceKey,
              totalBytes: totalBytes,
              overwrite: overwrite,
            ),
          ),
          readChunk: (offset, length) async {
            await localFile.setPosition(offset);
            return localFile.read(length);
          },
          writeChunk: (session, bytes, offset) => withConnection(
            (connection) => connection.writeFileBytesChunk(
              session.temporaryPath,
              bytes,
              offset: offset,
            ),
          ),
          commit: (session) async {
            final currentLength = await source.length();
            final currentModified = await source.lastModified();
            if (currentLength != totalBytes || currentModified != modified) {
              throw StateError('手机文件在上传期间发生变化，请重新上传');
            }
            await withConnection(
              (connection) => connection.completeFileUpload(session),
            );
          },
          onProgress: publishProgress,
        );
        _invalidateServerDirectoryCache(
          profile,
          paths: [path_util.posix.dirname(destinationPath)],
        );
        return uploaded;
      } finally {
        await localFile.close();
        try {
          await connection?.close();
        } finally {
          if (serviceStarted) await _taskService.stop(uploadId);
        }
      }
    }, cancellation: AgentCancellation());
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
    _invalidateServerDirectoryCache(
      profile,
      paths: [path_util.posix.dirname(remotePath.trim())],
    );
  }

  Future<void> deleteServerFiles(
    ServerProfile profile,
    Iterable<String> remotePaths, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final paths = remotePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) throw ArgumentError('没有选择文件');
    if (previewMode) return;
    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(profile, (connection) async {
        for (final path in paths) {
          await connection.deletePath(path);
        }
      }, onFirstHostKey: onFirstHostKey),
      cancellation: AgentCancellation(),
    );
    _invalidateServerDirectoryCache(
      profile,
      paths: [
        for (final path in paths) ...[path_util.posix.dirname(path), path],
      ],
    );
  }

  Future<SshFileInfo> statServerFile(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final path = remotePath.trim();
    if (path.isEmpty) throw ArgumentError('文件路径不能为空');
    if (previewMode) {
      return SshFileInfo(
        name: path_util.posix.basename(path),
        path: path,
        isDirectory: false,
        isSymbolicLink: false,
        size: null,
        modified: null,
      );
    }
    return _withServerConnection(
      profile,
      (connection) => connection.statPath(path),
      onFirstHostKey: onFirstHostKey,
    );
  }

  Future<void> createServerDirectory(
    ServerProfile profile,
    String remotePath, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final path = remotePath.trim();
    if (path.isEmpty) throw ArgumentError('文件夹路径不能为空');
    if (previewMode) return;
    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(
        profile,
        (connection) => connection.createDirectory(path),
        onFirstHostKey: onFirstHostKey,
      ),
      cancellation: AgentCancellation(),
    );
    _invalidateServerDirectoryCache(
      profile,
      paths: [path_util.posix.dirname(path), path],
    );
  }

  Future<void> copyServerFiles(
    ServerProfile profile,
    Iterable<String> remotePaths,
    String destinationDirectory, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) {
    return _copyOrMoveServerFiles(
      profile,
      remotePaths,
      destinationDirectory,
      move: false,
      onFirstHostKey: onFirstHostKey,
    );
  }

  Future<void> moveServerFiles(
    ServerProfile profile,
    Iterable<String> remotePaths,
    String destinationDirectory, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) {
    return _copyOrMoveServerFiles(
      profile,
      remotePaths,
      destinationDirectory,
      move: true,
      onFirstHostKey: onFirstHostKey,
    );
  }

  Future<void> renameServerFile(
    ServerProfile profile,
    String remotePath,
    String newName, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final source = remotePath.trim();
    final name = newName.trim();
    if (source.isEmpty) throw ArgumentError('文件路径不能为空');
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      throw ArgumentError('文件名无效');
    }
    final destination = path_util.posix.join(
      path_util.posix.dirname(source),
      name,
    );
    if (previewMode) return;
    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(
        profile,
        (connection) => connection.renamePath(source, destination),
        onFirstHostKey: onFirstHostKey,
      ),
      cancellation: AgentCancellation(),
    );
    _invalidateServerDirectoryCache(
      profile,
      paths: [path_util.posix.dirname(source)],
    );
  }

  Future<void> _copyOrMoveServerFiles(
    ServerProfile profile,
    Iterable<String> remotePaths,
    String destinationDirectory, {
    required bool move,
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    final sources = remotePaths
        .map((path) => _normalizeRemotePath(path))
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final destination = _normalizeRemotePath(destinationDirectory);
    if (sources.isEmpty) throw ArgumentError('没有选择文件');
    if (destination.isEmpty) throw ArgumentError('目标文件夹不能为空');

    final operations = <({String source, String destination})>[];
    final targets = <String>{};
    for (final source in sources) {
      final target = path_util.posix.join(
        destination,
        path_util.posix.basename(source),
      );
      if (source == target) throw StateError('目标位置与原位置相同');
      if (!targets.add(target)) {
        throw StateError('选中的文件包含相同名称，无法粘贴到此文件夹');
      }
      operations.add((source: source, destination: target));
    }
    if (previewMode) return;

    await _remoteWriteQueue.run<void>(
      profile.id,
      () => _withServerConnection(profile, (connection) async {
        for (final operation in operations) {
          if (move) {
            await connection.movePath(operation.source, operation.destination);
          } else {
            await connection.copyPath(operation.source, operation.destination);
          }
        }
      }, onFirstHostKey: onFirstHostKey),
      cancellation: AgentCancellation(),
    );
    _invalidateServerDirectoryCache(
      profile,
      paths: [
        destination,
        for (final source in sources) ...[
          path_util.posix.dirname(source),
          source,
        ],
      ],
    );
  }

  String _directoryCacheKey(ServerProfile profile, String remotePath) {
    return '${profile.id}\u0000${profile.host}\u0000${profile.port}'
        '\u0000${profile.username}\u0000${_normalizeRemotePath(remotePath)}';
  }

  void _invalidateServerDirectoryCache(
    ServerProfile profile, {
    Iterable<String>? paths,
  }) {
    if (paths == null) {
      _invalidateServerDirectoryCacheById(profile.id);
      return;
    }
    final identityPrefix =
        '${profile.id}\u0000${profile.host}'
        '\u0000${profile.port}\u0000${profile.username}\u0000';
    final targets = paths.map(_normalizeRemotePath).toSet();
    final keys = _directoryCache.keys
        .where(
          (key) =>
              key.startsWith(identityPrefix) &&
              targets.contains(key.substring(identityPrefix.length)),
        )
        .toList(growable: false);
    for (final key in keys) {
      _directoryCache.remove(key);
      _directoryCacheRecords.remove(key);
      unawaited(_database.deleteServerDirectoryCache(key).catchError((_) {}));
    }
    _serverFileContentCache.removeWhere(
      (key, _) => key.startsWith('${profile.id}\u0000'),
    );
  }

  void _invalidateServerDirectoryCacheById(String serverId) {
    final prefix = '$serverId\u0000';
    final keys = _directoryCache.keys
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      _directoryCache.remove(key);
      _directoryCacheRecords.remove(key);
    }
    _serverFileContentCache.removeWhere((key, _) => key.startsWith(prefix));
    unawaited(
      _database.deleteServerDirectoryCaches(serverId).catchError((_) {}),
    );
  }

  Future<ServerDashboard> loadServerDashboard(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    if (previewMode) {
      const dashboard = ServerDashboard(
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
      _dashboardCache[_dashboardCacheKey(profile)] = dashboard;
      return dashboard;
    }
    final dashboard = await _withServerConnection(profile, (connection) async {
      final result = await connection.run(statusProbeCommand);
      if (result.exitCode != 0) {
        throw StateError('服务器状态脚本执行失败');
      }
      return _parseDashboard(result.stdout);
    }, onFirstHostKey: onFirstHostKey);
    _dashboardCache[_dashboardCacheKey(profile)] = dashboard;
    return dashboard;
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

  Future<ProviderProfile> saveProvider({
    ProviderProfile? existing,
    required String name,
    required String baseUrl,
    required String model,
    String reasoningEffort = 'default',
    String wireApi = 'responses',
    String? contextWindowMode,
    required String secret,
    required bool isDefault,
    Map<String, ProviderModelMetadata>? modelMetadata,
    String? imageModel,
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
      contextWindowMode: normalizeContextWindowMode(
        contextWindowMode ?? existing?.contextWindowMode,
      ),
      apiKeyRef: apiKeyRef,
      isDefault: isDefault,
      modelMetadata: modelMetadata ?? existing?.modelMetadata ?? const {},
    );
    await _database.saveProvider(saved);
    if (imageModel != null) await _saveImageModel(id, imageModel);
    final providers = [
      for (final provider in _providers)
        if (provider.id != id)
          isDefault ? provider.copyWith(isDefault: false) : provider,
      saved,
    ]..sort((left, right) => left.name.compareTo(right.name));
    _providers = providers;
    await _isolateProviderContextChanges(previousProviders, providers);
    _notify();
    return saved;
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
    await _database.writeSetting(_imageModelSettingKey(profile.id), '');
    _imageModels.remove(profile.id);
    if (_subagentSettings.providerId == profile.id) {
      const reset = SubagentSettings();
      await _database.writeSetting(_subagentSettingsSetting, reset.toJson());
      _subagentSettings = reset;
      for (final tree in _subagentTrees.values) {
        tree.updateSettings(reset);
      }
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
            ? resolveProviderModelMetadata(provider, model)?.inputModalities
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
    final metadata = resolveProviderModelMetadata(provider, model);
    return jsonEncode([
      provider.id,
      provider.baseUrl,
      provider.wireApi,
      model,
      metadata?.compHash,
      provider.contextWindowMode,
      metadata?.resolveContextWindowTokens(
        contextWindowMode: provider.contextWindowMode,
      ),
      metadata?.effectiveContextWindowPercent,
      metadata?.resolveAutoCompactTokenLimit(
        contextWindowMode: provider.contextWindowMode,
      ),
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
    return resolveProviderModelMetadata(provider, model);
  }

  Future<TaskContextUsage> _loadTaskContextUsage(
    Task task,
    ProviderModelMetadata? metadata,
    String model,
    int generation,
    String? providerId,
    String contextWindowMode,
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
      rawContextWindow: metadata?.resolveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      effectiveContextWindow: metadata?.resolveEffectiveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      autoCompactTokenLimit: metadata?.resolveAutoCompactTokenLimit(
        contextWindowMode: contextWindowMode,
      ),
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
    final contextWindowMode = provider.contextWindowMode;
    final snapshot = TaskContextUsage(
      last: usage ?? current.last,
      total: usage == null ? current.total : (current.total ?? zero) + usage,
      model: _modelForTask(task, provider),
      rawContextWindow: metadata?.resolveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      effectiveContextWindow: metadata?.resolveEffectiveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      autoCompactTokenLimit: metadata?.resolveAutoCompactTokenLimit(
        contextWindowMode: contextWindowMode,
      ),
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
    if (payload['compaction_mode'] == 'local' &&
        payload['summary'] is String &&
        (payload['summary'] as String).trim().isNotEmpty) {
      return 1;
    }
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
      if (_documentModuleEnabled) {
        scopes.add(
          'The built-in document module is enabled. For a Word deliverable, '
          'write or edit a Markdown, HTML, or UTF-8 text source in the project '
          'and call document.export_docx; it writes a real .docx beside the '
          'source unless output_path is provided.',
        );
      }
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
      final phoneDownloadRule = project == null
          ? 'The phone destination requires user approval.'
          : 'A destination outside the current phone project requires user '
                'approval; in free execution mode, a destination inside that '
                'project does not. Other execution modes keep their existing '
                'approval flow.';
      scopes.add(
        'The selected server working directory is $directory. Use '
        'terminal.exec for short commands; use terminal.start, terminal.poll, '
        'terminal.write, and terminal.stop for long-running commands. Use '
        'file tools for UTF-8 server files. Use server.upload_from_project to '
        'send a phone project file to the server and server.download_to_project '
        'to bring a server file into the project; use '
        'server.download_to_phone to transfer a binary or text file directly '
        'to an absolute phone path such as '
        '/storage/emulated/0/Download/name.docx. These transfers are binary-safe '
        'and can resume after interruption. $phoneDownloadRule Never use '
        'file.read, project.write, or local.write to '
        'copy a binary file.',
      );
    }
    final subagentScope = task.mode == 'agent'
        ? 'You may delegate independent, bounded work with spawn_agent. Each '
              'child has its own history and the same selected work scope. '
              'Use wait_agent when you need a result; do not assume a child '
              'finished just because it was created. Use list_agents for '
              'status and keep the parent response focused on the requested '
              'outcome.'
        : '';
    return 'You are an autonomous coding and operations agent running on a '
        'phone. Work until the request is complete: inspect state, make '
        'changes, and verify the result. Before the first tool call, for any '
        'task requiring multiple actions, call the update_plan tool with a '
        'short list of meaningful steps before the first project or server '
        'tool call, then update the statuses as work progresses. The plan is '
        'shown to the user, so do not put it only in prose. '
        'During multi-step work, send concise, factual progress updates when '
        'a phase finishes or the next action changes; do not stay silent until '
        'all tool calls finish. These updates are commentary, not the final '
        'answer. Do not narrate every trivial command. ${scopes.join(' ')} '
        '$subagentScope '
        'Never claim success without checking the result. A tool call that '
        'writes local or server state may require confirmation. Any '
        'long-running server process still running when this turn ends will '
        'be stopped unless it was deliberately detached.';
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
      payload: {'turn_id': turnId},
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
              reasoningContent: event.payload['reasoning_content'] is String
                  ? event.payload['reasoning_content'] as String
                  : null,
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
          if (event.payload['compaction_mode'] == 'local') {
            messages.addAll(
              _readCodexRetainedUserMessages(
                event.payload['retained_user_messages'],
              ),
            );
            final summary = event.payload['summary'];
            if (summary is String && summary.trim().isNotEmpty) {
              // Codex's local CompactionSummary is a synthetic user item,
              // unlike the opaque output item returned by remote compaction.
              messages.add(AiMessage.user(summary));
            }
          } else {
            final compactedItems = _readResponsesOutputItems(
              event.payload['responses_output_items'],
            );
            if (compactedItems.isEmpty) continue;
            messages.add(
              AiMessage(
                role: 'assistant',
                responsesOutputItems: compactedItems,
              ),
            );
          }
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
              reasoningContent: assistant.reasoningContent,
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
              'The previous tool call was interrupted by a configuration '
              'change. Do not replay it; inspect the current target before '
              'continuing.',
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
        reasoningContent: message.reasoningContent,
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
    // Configuration changes are context notes, never a request to discard the
    // transcript. Compaction has its own boundary and is handled separately.
    return false;
  }

  static bool _requiresProviderProjection(Map<String, Object?> payload) {
    return payload['history_boundary'] == false &&
        payload['history_projection'] == 'provider';
  }

  static String _contextChangeMessage(Map<String, Object?> payload) {
    final reason = payload['reason'];
    final hasConfigurationFields =
        reason == 'configuration_changed' ||
        payload.containsKey('previous_work_mode') ||
        (payload.containsKey('work_mode') &&
            (payload.containsKey('project_id') ||
                payload.containsKey('server_id')));
    if (hasConfigurationFields) {
      String value(Object? item) {
        if (item == null) return 'none';
        if (item is String && item.isEmpty) return 'none';
        return '$item';
      }

      final details = <String>[];
      final previousWorkMode = payload['previous_work_mode'];
      final workMode = payload['work_mode'];
      if (previousWorkMode != null || workMode != null) {
        details.add(
          'Work mode: ${value(previousWorkMode)} -> ${value(workMode)}.',
        );
      }
      final previousProject = payload['previous_project_id'];
      final project = payload['project_id'];
      if (previousProject != null || project != null) {
        details.add('Project: ${value(previousProject)} -> ${value(project)}.');
      }
      final previousServer = payload['previous_server_id'];
      final server = payload['server_id'];
      if (previousServer != null || server != null) {
        details.add('Server: ${value(previousServer)} -> ${value(server)}.');
      }
      final previousDirectory = payload['previous_working_directory'];
      final directory = payload['working_directory'];
      if (previousDirectory != null || directory != null) {
        details.add(
          'Working directory: ${value(previousDirectory)} -> ${value(directory)}.',
        );
      }
      final previousProvider = payload['previous_provider_id'];
      final provider = payload['provider_id'];
      if (previousProvider != provider &&
          (previousProvider != null || provider != null)) {
        details.add(
          'AI provider: ${value(previousProvider)} -> ${value(provider)}.',
        );
      }
      final previousModel = payload['previous_model'];
      final model = payload['model'];
      if (previousModel != model && (previousModel != null || model != null)) {
        details.add('Model: ${value(previousModel)} -> ${value(model)}.');
      }
      return '<configuration_change>\n'
          'The conversation configuration changed. Continue from the retained '
          'transcript; do not restart or discard earlier context.\n'
          '${details.join(' ')}\n'
          'Treat observations from the previous target as historical only. '
          'Do not replay old tool calls. Use only tools available in the '
          'current mode and inspect the current target before acting.\n'
          '</configuration_change>';
    }
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

  static const _codexRetainedUserTokenBudget = 20_000;

  // Codex local compaction keeps recent user text alongside its summary. The
  // text-only representation avoids putting old image/file bytes back into
  // the compacted event; the model has already seen those inputs while
  // producing the summary.
  static List<AiMessage> _codexRetainedUserMessages(List<AiMessage> messages) {
    var remaining = _codexRetainedUserTokenBudget;
    final selected = <AiMessage>[];
    for (final message in messages.reversed) {
      if (message.role != 'user' ||
          OpenAiCompatibleClient.isCodexCompactionSummary(message.content)) {
        continue;
      }
      final text = message.content ?? '';
      if (text.isEmpty) continue;
      final tokens = _codexApproxTokenCount(text);
      if (tokens <= remaining) {
        selected.add(AiMessage.user(text));
        remaining -= tokens;
        continue;
      }
      if (remaining > 0) {
        selected.add(AiMessage.user(_truncateCodexUserText(text, remaining)));
      }
      break;
    }
    return selected.reversed.toList(growable: false);
  }

  static List<Map<String, Object?>> _serializeCodexRetainedUserMessages(
    List<AiMessage> messages,
  ) {
    return [
      for (final message in messages)
        if (message.content != null && message.content!.isNotEmpty)
          {'text': message.content!},
    ];
  }

  static List<AiMessage> _readCodexRetainedUserMessages(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map && item['text'] is String)
          AiMessage.user(item['text'] as String),
    ];
  }

  static int _codexApproxTokenCount(String text) {
    return (utf8.encode(text).length + 3) ~/ 4;
  }

  static String _truncateCodexUserText(String text, int tokenBudget) {
    final maxBytes = tokenBudget * 4;
    final marker = '\n[older user text truncated]\n';
    final markerBytes = utf8.encode(marker).length;
    if (maxBytes <= markerBytes) {
      return _codexPrefixByBytes(text, maxBytes);
    }
    final contentBytes = maxBytes - markerBytes;
    final prefixBytes = contentBytes ~/ 2;
    final suffixBytes = contentBytes - prefixBytes;
    return '${_codexPrefixByBytes(text, prefixBytes)}$marker'
        '${_codexSuffixByBytes(text, suffixBytes)}';
  }

  static String _codexPrefixByBytes(String text, int maxBytes) {
    var used = 0;
    var end = 0;
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      final bytes = utf8.encode(character).length;
      if (used + bytes > maxBytes) break;
      used += bytes;
      end += character.length;
    }
    return text.substring(0, end);
  }

  static String _codexSuffixByBytes(String text, int maxBytes) {
    var used = 0;
    var start = text.length;
    for (final rune in text.runes.toList().reversed) {
      final character = String.fromCharCode(rune);
      final bytes = utf8.encode(character).length;
      if (used + bytes > maxBytes) break;
      used += bytes;
      start -= character.length;
    }
    return text.substring(start);
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
            'Generate one image from a text prompt using the image model '
            'configured for this provider. If a phone project is bound, save '
            'the result there and return its relative path. Do not choose a '
            'model in the tool arguments.',
        parameters: {
          'type': 'object',
          'required': ['prompt'],
          'properties': {
            'prompt': {'type': 'string'},
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
    final model = imageModelFor(provider.id).trim();
    if (model.isEmpty) {
      throw StateError('当前图片供应商未配置图片模型');
    }
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

  static String _dashboardCacheKey(ServerProfile profile) =>
      [profile.id, profile.host, profile.port, profile.username].join('\u0000');

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
      statusScriptInstalled:
          (int.tryParse(values['script_version'] ?? '') ?? 0) >= 1,
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
    for (final timer in _streamingAssistantFlushes.values) {
      timer.cancel();
    }
    for (final notifier in _streamingAssistantNotifiers.values) {
      notifier.dispose();
    }
    _streamingAssistantFlushes.clear();
    _streamingAssistantBuffers.clear();
    _streamingAssistantText.clear();
    _streamingAssistantNotifiers.clear();
    for (final cancellation in _runningTasks.values) {
      cancellation.cancel();
    }
    final runs = List<Future<AgentResult>>.of(_taskRuns.values);
    final trees = List<SubagentTree>.of(_subagentTrees.values);
    unawaited(_disposeAsync(runs, trees));
    super.dispose();
  }

  Future<void> _disposeAsync(
    List<Future<AgentResult>> runs,
    List<SubagentTree> trees,
  ) async {
    await Future.wait([
      for (final tree in trees) tree.close(),
    ], eagerError: false);
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
const _floatingCapsuleSetting = 'floating_capsule_enabled';
const _floatingCapsuleScaleSetting = 'floating_capsule_scale';
const _floatingCapsuleLengthScaleSetting = 'floating_capsule_length_scale';
const _documentModuleSetting = 'document_module_enabled';
const _fontScaleSetting = 'font_scale';
const _subagentSettingsSetting = 'subagent_settings';
const _imageProviderSetting = 'image_provider_id';
const _imageModelSettingPrefix = 'image_model:';
const _lastDashboardServerSetting = 'last_dashboard_server_id';
const _lastConversationTaskSetting = 'last_conversation_task_id';

String _sidebarExpandedSettingKey(String sectionId) =>
    'sidebar_expanded:$sectionId';

String _imageModelSettingKey(String providerId) =>
    '$_imageModelSettingPrefix$providerId';

String _normalizeRemotePath(String value) {
  final path = value.trim();
  if (path.length <= 1) return path;
  return path.replaceFirst(RegExp(r'/+$'), '');
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

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
