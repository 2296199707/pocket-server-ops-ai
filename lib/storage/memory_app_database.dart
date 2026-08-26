import '../domain/models.dart';
import 'app_database.dart';

class MemoryAppDatabase extends AppDatabase {
  MemoryAppDatabase({this.demoData = false}) {
    if (demoData) _seedDemoData();
  }

  final bool demoData;
  final Map<String, ServerProfile> _servers = {};
  final Map<String, ProviderProfile> _providers = {};
  final Map<String, Project> _projects = {};
  final Map<String, Task> _tasks = {};
  final Map<String, TaskEvent> _events = {};
  final Map<String, AttachmentRecord> _attachments = {};
  final Map<String, String> _settings = {};

  void _seedDemoData() {
    const server = ServerProfile(
      id: 'demo-server',
      name: '演示应用服务器',
      host: 'app.demo.invalid',
      port: 22,
      username: 'deploy',
      authType: 'privateKey',
      credentialRef: 'demo-server-key',
      credentialPassphraseRef: null,
      hostKey: 'ssh-ed25519',
      hostKeyFingerprint: 'SHA256:demo-server',
      defaultWorkingDirectory: '/srv/example-app',
    );
    _servers[server.id] = server;
    _providers['demo-provider'] = const ProviderProfile(
      id: 'demo-provider',
      name: '演示 OpenAI Compatible',
      baseUrl: 'https://provider.demo.invalid/v1',
      model: 'demo-model',
      reasoningEffort: 'default',
      wireApi: 'responses',
      apiKeyRef: 'demo-provider-key',
      isDefault: true,
    );
  }

  @override
  Future<List<ServerProfile>> loadServers() async {
    final values = _servers.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    return values;
  }

  @override
  Future<void> saveServer(ServerProfile profile) async {
    _servers[profile.id] = profile;
  }

  @override
  Future<void> deleteServer(String id) async {
    _servers.remove(id);
  }

  @override
  Future<List<ProviderProfile>> loadProviders() async {
    final values = _providers.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    return values;
  }

  @override
  Future<void> clearProviderDefaults() async {
    for (final entry in _providers.entries.toList()) {
      final profile = entry.value;
      _providers[entry.key] = ProviderProfile(
        id: profile.id,
        name: profile.name,
        baseUrl: profile.baseUrl,
        model: profile.model,
        reasoningEffort: profile.reasoningEffort,
        wireApi: profile.wireApi,
        apiKeyRef: profile.apiKeyRef,
        isDefault: false,
      );
    }
  }

  @override
  Future<void> saveProvider(ProviderProfile profile) async {
    _providers[profile.id] = profile;
  }

  @override
  Future<void> deleteProvider(String id) async {
    _providers.remove(id);
  }

  @override
  Future<List<Project>> loadProjects() async {
    final values = _projects.values.toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    return values;
  }

  @override
  Future<void> saveProject(Project project) async {
    _projects[project.id] = project;
  }

  @override
  Future<void> deleteProject(String id) async {
    _projects.remove(id);
  }

  @override
  Future<String?> readSetting(String key) async => _settings[key];

  @override
  Future<void> writeSetting(String key, String value) async {
    _settings[key] = value;
  }

  @override
  Future<void> saveTask(Task task) async {
    _tasks[task.id] = task;
  }

  @override
  Future<List<Task>> loadTasks() async {
    final values = _tasks.values.toList()
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return values;
  }

  @override
  Future<void> deleteTask(String id) async {
    _tasks.remove(id);
    _events.removeWhere((_, event) => event.taskId == id);
    _attachments.removeWhere((_, item) => item.taskId == id);
  }

  @override
  Future<void> saveEvent(TaskEvent event) async {
    _events[event.eventId] = event;
  }

  @override
  Future<List<TaskEvent>> loadEvents(String taskId) async {
    final values =
        _events.values.where((event) => event.taskId == taskId).toList()
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    return values;
  }

  @override
  Future<List<TaskEvent>> loadModelEvents(
    String taskId, {
    bool useCompactionBoundary = true,
  }) async {
    final values = await loadEvents(taskId);
    var startSequence = 0;
    for (final event in values) {
      if (event.type == 'task.context_changed') {
        startSequence = event.sequence;
      }
      final items = event.payload['responses_output_items'];
      if (useCompactionBoundary &&
          event.sequence >= startSequence &&
          items is List &&
          items.any((item) => item is Map && item['type'] == 'compaction')) {
        startSequence = event.sequence;
      }
    }
    return values
        .where((event) => event.sequence >= startSequence)
        .toList(growable: false);
  }

  @override
  Future<TaskEventPage> loadRecentEvents(
    String taskId, {
    int limit = 40,
  }) async {
    final values = await loadEvents(taskId);
    final start = values.length > limit ? values.length - limit : 0;
    return TaskEventPage(events: values.sublist(start), hasEarlier: start > 0);
  }

  @override
  Future<TaskEventPage> loadEventsBefore(
    String taskId, {
    required int beforeSequence,
    int limit = 40,
  }) async {
    final values = (await loadEvents(taskId))
        .where((event) => event.sequence < beforeSequence)
        .toList();
    final start = values.length > limit ? values.length - limit : 0;
    return TaskEventPage(events: values.sublist(start), hasEarlier: start > 0);
  }

  @override
  Future<TaskEvent?> loadLatestEvent(String taskId) async {
    final values = await loadEvents(taskId);
    return values.isEmpty ? null : values.last;
  }

  @override
  Future<TaskEvent?> loadLatestTerminalEvent(String taskId) async {
    final values = await loadEvents(taskId);
    for (final event in values.reversed) {
      if (event.type == 'task.completed' ||
          event.type == 'task.failed' ||
          event.type == 'task.cancelled' ||
          event.type == 'task.unknown') {
        return event;
      }
    }
    return null;
  }

  @override
  Future<int> nextEventSequence(String taskId) async {
    final latest = await loadLatestEvent(taskId);
    return (latest?.sequence ?? 0) + 1;
  }

  @override
  Future<void> saveAttachments(List<AttachmentRecord> records) async {
    for (final record in records) {
      _attachments[record.id] = record;
    }
  }

  @override
  Future<AttachmentRecord?> loadAttachment(String id) async => _attachments[id];

  @override
  Future<List<TaskEvent>> loadLegacyAttachmentEvents(String taskId) async {
    return (await loadEvents(taskId))
        .where(
          (event) =>
              (event.type == 'user.message' &&
                  event.payload['attachments'] is List &&
                  (event.payload['attachments'] as List).any(
                    (item) => item is Map && item['base64'] is String,
                  )) ||
              (event.type == 'tool.completed' &&
                  event.payload['result'] is Map &&
                  (event.payload['result'] as Map)['data_url'] is String),
        )
        .toList(growable: false);
  }

  @override
  Future<void> replaceEventAttachments(
    TaskEvent event,
    List<AttachmentRecord> records,
  ) async {
    await saveAttachments(records);
    _events[event.eventId] = event;
  }
}
