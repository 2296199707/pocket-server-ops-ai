import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';

void main() {
  test('a phone task left running is restored as unknown', () async {
    final database = MemoryAppDatabase();
    await database.saveTask(
      Task(
        id: 'task-1',
        mode: 'agent',
        serverId: 'server-1',
        providerId: null,
        title: '恢复任务',
        workingDirectory: '/srv/app',
        executionMode: 'confirm',
        status: 'running',
        createdAt: DateTime.utc(2026, 8, 24),
        updatedAt: DateTime.utc(2026, 8, 24),
      ),
    );
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );

    await controller.load();

    expect(controller.tasks.single.status, 'unknown');
    expect(controller.eventsFor('task-1').single.type, 'task.recovered');
    controller.dispose();
  });

  test('a persisted terminal event wins during task recovery', () async {
    final database = MemoryAppDatabase();
    final timestamp = DateTime.utc(2026, 8, 24);
    await database.saveTask(
      Task(
        id: 'task-1',
        mode: 'agent',
        serverId: 'server-1',
        providerId: null,
        title: '已完成任务',
        workingDirectory: '/srv/app',
        executionMode: 'confirm',
        status: 'running',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-1',
        taskId: 'task-1',
        sequence: 1,
        type: 'task.completed',
        timestamp: timestamp,
        payload: const {'text': '完成'},
      ),
    );
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );

    await controller.load();

    expect(controller.tasks.single.status, 'completed');
    expect(controller.eventsFor('task-1').single.type, 'task.completed');
    controller.dispose();
  });

  test(
    'preview phone Agent remains local and never needs server credentials',
    () async {
      final database = MemoryAppDatabase(demoData: true);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        previewMode: true,
      );

      await controller.load();
      final task = await controller.createTask(
        mode: 'agent',
        serverId: 'demo-server',
        providerId: 'demo-provider',
        title: '检查服务',
      );
      final result = await controller.runTask(task, prompt: '检查服务状态');

      expect(result.status, 'completed');
      expect(result.finalText, contains('手机 Agent'));
      expect(
        controller.eventsFor(task.id).map((event) => event.type),
        contains('assistant.completed'),
      );
      controller.dispose();
    },
  );

  test('Agent default execution mode is persisted', () async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();

    expect(controller.agentAutoExecute, isFalse);
    expect(controller.betaUpdatesEnabled, isFalse);
    await controller.setAgentAutoExecute(true);
    await controller.setBetaUpdatesEnabled(true);
    final task = await controller.createTask(
      mode: 'agent',
      serverId: 'server-1',
      title: '自动任务',
    );

    expect(task.executionMode, 'auto');
    controller.dispose();

    final restored = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await restored.load();
    expect(restored.agentAutoExecute, isTrue);
    expect(restored.betaUpdatesEnabled, isTrue);
    restored.dispose();
  });

  test('explicit work modes are persisted with their task bindings', () async {
    final database = MemoryAppDatabase(demoData: true);
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();

    final collaborative = await controller.createTask(
      workMode: 'collaborative',
      projectId: 'project-1',
      serverId: 'demo-server',
      title: '协同任务',
    );
    final local = await controller.createTask(workMode: 'local', title: '本地任务');
    final server = await controller.createTask(
      workMode: 'server',
      serverId: 'demo-server',
      title: '服务器任务',
    );
    final chat = await controller.createTask(
      workMode: 'chat',
      serverId: 'demo-server',
      title: '对话任务',
    );

    expect(collaborative.mode, 'agent');
    expect(collaborative.effectiveWorkMode, 'collaborative');
    expect(local.mode, 'agent');
    expect(local.serverId, isNull);
    expect(server.effectiveWorkMode, 'server');
    expect(chat.mode, 'chat');
    expect(chat.serverId, isNull);

    final restored = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await restored.load();
    expect(
      restored.tasks.map((task) => task.effectiveWorkMode),
      containsAll(['collaborative', 'local', 'server', 'chat']),
    );
    controller.dispose();
    restored.dispose();
  });

  test('project-only Agent can be created without a server', () async {
    final root = Directory(
      '/www/mobile-agent-test-project-${DateTime.now().microsecondsSinceEpoch}',
    );
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    try {
      await controller.load();
      final project = await controller.createProject(
        name: '本地项目',
        localPath: root.path,
      );
      final task = await controller.createTask(
        mode: 'agent',
        projectId: project.id,
        title: '本地任务',
      );
      final result = await controller.runTask(task, prompt: '检查本地项目');

      expect(result.status, 'completed');
      expect(task.serverId, isNull);
    } finally {
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('task configuration can be changed after a completed turn', () async {
    final database = MemoryAppDatabase(demoData: true);
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    final task = await controller.createTask(
      mode: 'chat',
      providerId: 'demo-provider',
      title: '可编辑配置',
    );
    await controller.runTask(task, prompt: '你好');

    final updated = await controller.updateTaskConfiguration(
      taskId: task.id,
      mode: 'agent',
      serverId: 'demo-server',
      providerId: null,
      workingDirectory: '/srv/example-app',
      executionMode: 'auto',
    );

    expect(updated.mode, 'agent');
    expect(updated.serverId, 'demo-server');
    expect(updated.providerId, isNull);
    expect(updated.executionMode, 'auto');
    expect(controller.eventsFor(task.id).last.type, 'task.context_changed');
    controller.dispose();
  });

  test(
    'task model and reasoning overrides are persisted and continued',
    () async {
      final controller = AppController(
        database: MemoryAppDatabase(demoData: true),
        credentials: MemoryCredentialStore(),
        previewMode: true,
      );
      await controller.load();
      final task = await controller.createTask(
        providerId: 'demo-provider',
        title: '模型设置',
        modelOverride: 'demo-coder',
        reasoningEffortOverride: 'high',
      );

      final updated = await controller.updateTaskConfiguration(
        taskId: task.id,
        mode: task.mode,
        serverId: task.serverId,
        providerId: task.providerId,
        workingDirectory: task.workingDirectory,
        executionMode: task.executionMode,
        modelOverride: '',
      );
      expect(updated.modelOverride, isNull);
      expect(updated.reasoningEffortOverride, 'high');

      final continued = await controller.createContinuationTask(updated);
      expect(continued.modelOverride, isNull);
      expect(continued.reasoningEffortOverride, 'high');
      controller.dispose();
    },
  );

  test('different phone Agent tasks can run concurrently', () async {
    final controller = AppController(
      database: MemoryAppDatabase(demoData: true),
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    final first = await controller.createTask(
      mode: 'agent',
      serverId: 'demo-server',
      providerId: 'demo-provider',
      title: '任务一',
    );
    final second = await controller.createTask(
      mode: 'agent',
      serverId: 'demo-server',
      providerId: 'demo-provider',
      title: '任务二',
    );

    final firstRun = controller.runTask(first, prompt: '检查一');
    final secondRun = controller.runTask(second, prompt: '检查二');

    expect(controller.isTaskRunning(first.id), isTrue);
    expect(controller.isTaskRunning(second.id), isTrue);

    final results = await Future.wait([firstRun, secondRun]);

    expect(results.map((result) => result.status), ['completed', 'completed']);
    controller.dispose();
  });

  test(
    'changing a server endpoint clears its saved host fingerprint',
    () async {
      final database = MemoryAppDatabase();
      final credentials = MemoryCredentialStore();
      await database.saveServer(
        const ServerProfile(
          id: 'server-1',
          name: '应用服务器',
          host: 'old.example.com',
          port: 22,
          username: 'ops',
          authType: 'password',
          credentialRef: 'server-1:ssh',
          credentialPassphraseRef: null,
          hostKey: 'ssh-ed25519',
          hostKeyFingerprint: 'SHA256:old',
          defaultWorkingDirectory: '/srv/app',
        ),
      );
      await credentials.write('server-1:ssh', 'password');
      final controller = AppController(
        database: database,
        credentials: credentials,
      );

      await controller.load();
      await controller.saveServer(
        existing: controller.servers.single,
        name: '应用服务器',
        host: 'new.example.com',
        port: 2222,
        username: 'ops',
        secret: '',
        workingDirectory: '/srv/app',
      );

      final updated = controller.servers.single;
      expect(updated.hostKey, isNull);
      expect(updated.hostKeyFingerprint, isNull);
      controller.dispose();
    },
  );

  test('changing authentication type requires a new credential', () async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    await controller.saveServer(
      name: '应用服务器',
      host: 'server.example.com',
      port: 22,
      username: 'ops',
      secret: 'password',
      workingDirectory: '',
    );

    expect(
      controller.saveServer(
        existing: controller.servers.single,
        name: '应用服务器',
        host: 'server.example.com',
        port: 22,
        username: 'ops',
        secret: '',
        workingDirectory: '',
        authType: 'privateKey',
      ),
      throwsArgumentError,
    );
    expect(controller.servers.single.authType, 'password');
    controller.dispose();
  });

  test('task event text is retained for durable AI history', () async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    final task = await controller.createTask(title: '普通对话');
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'assistant.completed',
      payload: {'text': 'x' * 70_000},
    );

    final text = controller.eventsFor(task.id).single.payload['text'] as String;
    expect(text, 'x' * 70_000);
    controller.dispose();
  });

  test('dashboard and file APIs use the direct SSH connection', () async {
    final database = MemoryAppDatabase();
    final credentials = MemoryCredentialStore();
    final connector = _FakeConnector();
    await database.saveServer(
      const ServerProfile(
        id: 'server-1',
        name: '应用服务器',
        host: 'server.example.com',
        port: 22,
        username: 'ops',
        authType: 'password',
        credentialRef: 'server-1:ssh',
        credentialPassphraseRef: null,
        hostKey: null,
        hostKeyFingerprint: null,
        defaultWorkingDirectory: '/srv/app',
      ),
    );
    await credentials.write('server-1:ssh', 'password');
    final controller = AppController(
      database: database,
      credentials: credentials,
      sshConnector: connector,
    );
    await controller.load();

    final dashboard = await controller.loadServerDashboard(
      controller.servers.single,
    );
    final entries = await controller.listServerDirectory(
      controller.servers.single,
      '/srv/app',
    );
    final cachedEntries = await controller.listServerDirectory(
      controller.servers.single,
      '/srv/app',
    );
    final content = await controller.readServerFile(
      controller.servers.single,
      '/srv/app/README.md',
    );
    await controller.writeServerFile(
      controller.servers.single,
      '/srv/app/new.txt',
      'new content',
    );
    await controller.listServerDirectory(controller.servers.single, '/srv/app');
    await controller.installServerStatusScript(controller.servers.single);

    expect(dashboard.hostname, 'test-server');
    expect(dashboard.cpuUsage, 5);
    expect(dashboard.statusScriptInstalled, isTrue);
    expect(entries.single.name, 'README.md');
    expect(cachedEntries.single.name, 'README.md');
    expect(connector.directoryCalls, ['/srv/app', '/srv/app']);
    expect(content, 'remote content');
    expect(connector.writes.single.path, '/srv/app/new.txt');
    expect(
      connector.commands.any(
        (command) => command.contains('mobile-agent-status'),
      ),
      isTrue,
    );
    controller.dispose();
  });
}

class _FakeConnector implements SshConnector {
  final commands = <String>[];
  final directoryCalls = <String>[];
  final writes = <({String path, Uint8List contents})>[];

  @override
  Future<SshConnection> connect(SshConnectionConfig config) async {
    return _FakeConnection(
      commands: commands,
      directoryCalls: directoryCalls,
      writes: writes,
    );
  }
}

class _FakeConnection implements SshConnection {
  _FakeConnection({
    required this.commands,
    required this.directoryCalls,
    required this.writes,
  });

  final List<String> commands;
  final List<String> directoryCalls;
  final List<({String path, Uint8List contents})> writes;
  bool closed = false;

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:test-server',
  );

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => Future.value();

  @override
  Future<SshCommandStream> execute(
    String command, {
    String? workingDirectory,
    bool pty = false,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SshCommandStream> shell({int width = 80, int height = 24}) async {
    throw UnimplementedError();
  }

  @override
  Future<SshCommandResult> run(
    String command, {
    String? workingDirectory,
    String? input,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    commands.add(command);
    if (command.contains('mobile-agent-status.tmp')) {
      return const SshCommandResult(
        stdout: 'installed\n',
        stderr: '',
        exitCode: 0,
      );
    }
    return const SshCommandResult(
      stdout:
          'script_version=1\n'
          'hostname=test-server\n'
          'os=Test Linux\n'
          'kernel=Linux test\n'
          'uptime=1 hour\n'
          'load=0.1 0.2 0.3\n'
          'cpu=2 cores\n'
          'cpu_usage=5\n'
          'memory=20%\n'
          'disk=2G / 10G (20%)\n',
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) async {
    directoryCalls.add(remotePath);
    return [
      SshDirectoryEntry(
        name: 'README.md',
        path: '$remotePath/README.md',
        isDirectory: false,
        size: 14,
      ),
    ];
  }

  @override
  Future<String> readFile(String remotePath) async => 'remote content';

  @override
  Future<Uint8List> readFileBytes(String remotePath) async {
    return Uint8List.fromList(utf8.encode('remote content'));
  }

  @override
  Future<SshFileChunk> readFileChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final content = 'remote content';
    final start = offset.clamp(0, content.length).toInt();
    final end = length == null
        ? content.length
        : (start + length).clamp(start, content.length).toInt();
    return SshFileChunk(
      offset: offset,
      nextOffset: end,
      content: content.substring(start, end),
      eof: end == content.length,
      totalBytes: content.length,
    );
  }

  @override
  Future<void> writeFile(String remotePath, Uint8List contents) async {
    writes.add((path: remotePath, contents: contents));
  }

  @override
  Future<void> replaceText(
    String remotePath,
    String oldText,
    String newText,
  ) async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}
