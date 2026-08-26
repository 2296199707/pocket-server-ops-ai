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
  Future<List<TaskEvent>> loadAllEvents() async {
    final values = _events.values.toList()
      ..sort((left, right) {
        final taskOrder = left.taskId.compareTo(right.taskId);
        return taskOrder == 0
            ? left.sequence.compareTo(right.sequence)
            : taskOrder;
      });
    return values;
  }
}
