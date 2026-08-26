import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/storage/attachment_store.dart';

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

  test(
    'attachments are referenced in events and restored after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('mobile-agent-files-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = MemoryAppDatabase();
      final store = AttachmentStore(rootProvider: () async => root);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        attachmentStore: store,
        previewMode: true,
      );
      await controller.load();
      final task = await controller.createTask(title: '图片对话');

      await controller.runTask(
        task,
        prompt: '查看图片',
        attachments: const [
          AiAttachment(
            name: 'screen.png',
            mimeType: 'image/png',
            byteLength: 5,
            base64Data: 'aW1hZ2U=',
          ),
        ],
      );

      final userEvent = controller
          .eventsFor(task.id)
          .firstWhere((event) => event.type == 'user.message');
      final eventJson = jsonEncode(userEvent.payload);
      expect(eventJson, isNot(contains('aW1hZ2U=')));
      final attachment = AiAttachment.fromJson(
        Map<String, Object?>.from(
          (userEvent.payload['attachments'] as List).single as Map,
        ),
      );
      expect(attachment.id, isNotEmpty);
      expect(
        await controller.loadAttachmentBytes(attachment.id!),
        utf8.encode('image'),
      );
      controller.dispose();

      final restored = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        attachmentStore: store,
        previewMode: true,
      );
      await restored.load();
      final result = await restored.runTask(
        restored.tasks.single,
        prompt: '继续',
      );
      expect(result.status, 'completed');
      restored.dispose();
    },
  );

  test(
    'legacy Base64 attachments migrate when a conversation is opened',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mobile-agent-legacy-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = MemoryAppDatabase();
      final timestamp = DateTime.utc(2026, 8, 26);
      await database.saveTask(
        Task(
          id: 'task-legacy',
          mode: 'chat',
          serverId: null,
          providerId: null,
          title: '旧图片',
          workingDirectory: null,
          executionMode: 'confirm',
          status: 'completed',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'event-legacy',
          taskId: 'task-legacy',
          sequence: 1,
          type: 'user.message',
          timestamp: timestamp,
          payload: const {
            'text': '旧附件',
            'attachments': [
              {'name': 'old.png', 'mime_type': 'image/png', 'base64': 'b2xk'},
            ],
          },
        ),
      );
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        attachmentStore: AttachmentStore(rootProvider: () async => root),
      );
      await controller.load();
      await controller.ensureTaskEventsLoaded('task-legacy');

      final migrated = controller.eventsFor('task-legacy').single;
      expect(jsonEncode(migrated.payload), isNot(contains('"base64"')));
      final attachment = AiAttachment.fromJson(
        Map<String, Object?>.from(
          (migrated.payload['attachments'] as List).single as Map,
        ),
      );
      expect(
        await controller.loadAttachmentBytes(attachment.id!),
        utf8.encode('old'),
      );
      controller.dispose();
    },
  );

  test(
    '100 cumulative image messages load from the database in pages',
    () async {
      final database = MemoryAppDatabase();
      final timestamp = DateTime.utc(2026, 8, 26);
      await database.saveTask(
        Task(
          id: 'task-pages',
          mode: 'chat',
          serverId: null,
          providerId: null,
          title: '长对话',
          workingDirectory: null,
          executionMode: 'confirm',
          status: 'completed',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      for (var sequence = 1; sequence <= 100; sequence++) {
        await database.saveEvent(
          TaskEvent(
            eventId: 'event-$sequence',
            taskId: 'task-pages',
            sequence: sequence,
            type: 'user.message',
            timestamp: timestamp,
            payload: {
              'text': 'image $sequence',
              'attachments': [
                {
                  'attachment_id': 'attachment-$sequence',
                  'name': 'image-$sequence.png',
                  'mime_type': 'image/png',
                  'size': 1024,
                },
              ],
            },
          ),
        );
      }
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );

      await controller.load();
      expect(controller.eventsFor('task-pages'), isEmpty);
      await controller.ensureTaskEventsLoaded('task-pages');
      expect(controller.eventsFor('task-pages'), hasLength(40));
      expect(
        controller
            .eventsFor('task-pages')
            .every((event) => !jsonEncode(event.payload).contains('"base64"')),
        isTrue,
      );
      expect(controller.hasEarlierTaskEvents('task-pages'), isTrue);
      await controller.loadEarlierTaskEvents('task-pages');
      expect(controller.eventsFor('task-pages'), hasLength(80));
      await controller.loadEarlierTaskEvents('task-pages');
      expect(controller.eventsFor('task-pages'), hasLength(100));
      expect(controller.hasEarlierTaskEvents('task-pages'), isFalse);
      controller.dispose();
    },
  );

  test('attachments before the latest compaction are not read again', () async {
    final root = await Directory.systemTemp.createTemp('mobile-agent-compact-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = MemoryAppDatabase();
    final timestamp = DateTime.utc(2026, 8, 26);
    await database.saveTask(
      Task(
        id: 'task-compact',
        mode: 'chat',
        serverId: null,
        providerId: null,
        title: '压缩对话',
        workingDirectory: null,
        executionMode: 'confirm',
        status: 'completed',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await database.saveAttachments([
      AttachmentRecord(
        id: 'missing-image',
        taskId: 'task-compact',
        name: 'missing.png',
        mimeType: 'image/png',
        byteLength: 10,
        storagePath: 'task-compact/missing.png',
        createdAt: timestamp,
      ),
    ]);
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-user',
        taskId: 'task-compact',
        sequence: 1,
        type: 'user.message',
        timestamp: timestamp,
        payload: const {
          'text': '旧图片',
          'attachments': [
            {
              'attachment_id': 'missing-image',
              'name': 'missing.png',
              'mime_type': 'image/png',
              'size': 10,
            },
          ],
        },
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-compaction',
        taskId: 'task-compact',
        sequence: 2,
        type: 'assistant.completed',
        timestamp: timestamp,
        payload: const {
          'text': '',
          'responses_output_items': [
            {'type': 'compaction', 'encrypted_content': 'opaque'},
          ],
        },
      ),
    );
    expect(
      (await database.loadModelEvents('task-compact'))
          .map((event) => event.eventId),
      ['event-compaction'],
    );
    expect(
      (await database.loadModelEvents(
        'task-compact',
        useCompactionBoundary: false,
      )).map((event) => event.eventId),
      ['event-user', 'event-compaction'],
    );
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      attachmentStore: AttachmentStore(rootProvider: () async => root),
      previewMode: true,
    );
    await controller.load();

    final result = await controller.runTask(
      controller.tasks.single,
      prompt: '继续',
    );
    expect(result.status, 'completed');
    expect(await database.loadAttachment('missing-image'), isNotNull);
    controller.dispose();
  });

  test('failed task deletion keeps attachment files intact', () async {
    final root = await Directory.systemTemp.createTemp('mobile-agent-delete-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = _FailingDeleteDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      attachmentStore: AttachmentStore(rootProvider: () async => root),
      previewMode: true,
    );
    await controller.load();
    final task = await controller.createTask(title: '保留附件');
    await controller.runTask(
      task,
      prompt: '保存',
      attachments: const [
        AiAttachment(
          name: 'keep.png',
          mimeType: 'image/png',
          base64Data: 'a2VlcA==',
        ),
      ],
    );
    final attachment = AiAttachment.fromJson(
      Map<String, Object?>.from(
        (controller
                        .eventsFor(task.id)
                        .firstWhere((event) => event.type == 'user.message')
                        .payload['attachments']
                    as List)
                .single
            as Map,
      ),
    );

    database.failDelete = true;
    await expectLater(controller.deleteTask(task), throwsStateError);

    expect(
      await controller.loadAttachmentBytes(attachment.id!),
      utf8.encode('keep'),
    );
    controller.dispose();
  });

  test(
    'persisted user event keeps its attachment after task update fails',
    () async {
      final root = await Directory.systemTemp.createTemp('mobile-agent-event-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final database = _FailingTaskSaveDatabase();
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        attachmentStore: AttachmentStore(rootProvider: () async => root),
        previewMode: true,
      );
      await controller.load();
      final task = await controller.createTask(title: '事件附件');

      database.failNextSave = true;
      final result = await controller.runTask(
        task,
        prompt: '保存',
        attachments: const [
          AiAttachment(
            name: 'event.png',
            mimeType: 'image/png',
            base64Data: 'ZXZlbnQ=',
          ),
        ],
      );

      expect(result.status, 'failed');
      final userEvent = (await database.loadEvents(task.id))
          .firstWhere((event) => event.type == 'user.message');
      final attachment = AiAttachment.fromJson(
        Map<String, Object?>.from(
          (userEvent.payload['attachments'] as List).single as Map,
        ),
      );
      expect(
        await controller.loadAttachmentBytes(attachment.id!),
        utf8.encode('event'),
      );
      controller.dispose();
    },
  );

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

class _FailingDeleteDatabase extends MemoryAppDatabase {
  bool failDelete = false;

  @override
  Future<void> deleteTask(String id) {
    if (failDelete) throw StateError('delete failed');
    return super.deleteTask(id);
  }
}

class _FailingTaskSaveDatabase extends MemoryAppDatabase {
  bool failNextSave = false;

  @override
  Future<void> saveTask(Task task) {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('save failed');
    }
    return super.saveTask(task);
  }
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
