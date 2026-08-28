import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/ai_protocol.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/platform/android_task_service.dart';
import 'package:mobile_agent/ssh/resumable_file_upload.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/storage/app_database.dart';
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

  test('a task with only a partially persisted nonterminal event is recovered as unknown', () async {
    final database = MemoryAppDatabase();
    final timestamp = DateTime.utc(2026, 8, 24);
    await database.saveTask(
      Task(
        id: 'task-1',
        mode: 'agent',
        serverId: 'server-1',
        providerId: null,
        title: '半写入任务',
        workingDirectory: '/srv/app',
        executionMode: 'confirm',
        status: 'running',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-started',
        taskId: 'task-1',
        sequence: 1,
        type: 'task.started',
        timestamp: timestamp,
        payload: const {'turn_id': 'turn-1'},
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-partial',
        taskId: 'task-1',
        sequence: 2,
        type: 'assistant.completed',
        timestamp: timestamp.add(const Duration(seconds: 1)),
        payload: const {'turn_id': 'turn-1', 'text': '部分回复'},
      ),
    );

    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );

    await controller.load();

    expect(controller.tasks.single.status, 'unknown');
    expect(controller.eventsFor('task-1').single.type, 'task.recovered');
    expect((await database.loadLatestEvent('task-1'))?.type, 'task.recovered');
    controller.dispose();
  });

  test(
    'a late nonterminal event cannot make a terminal event authoritative',
    () async {
      final database = MemoryAppDatabase();
      final timestamp = DateTime.utc(2026, 8, 24);
      await database.saveTask(
        Task(
          id: 'task-1',
          mode: 'agent',
          serverId: 'server-1',
          providerId: null,
          title: '迟到事件',
          workingDirectory: '/srv/app',
          executionMode: 'confirm',
          status: 'running',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'event-completed',
          taskId: 'task-1',
          sequence: 1,
          type: 'task.completed',
          timestamp: timestamp,
          payload: const {'turn_id': 'turn-1'},
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'event-late',
          taskId: 'task-1',
          sequence: 2,
          type: 'assistant.completed',
          timestamp: timestamp.add(const Duration(seconds: 1)),
          payload: const {'turn_id': 'turn-1', 'text': '迟到'},
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
    },
  );

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

  test('sequential turns keep distinct turn ids in durable events', () async {
    final controller = AppController(
      database: MemoryAppDatabase(demoData: true),
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    final task = await controller.createTask(mode: 'chat', title: '连续轮次');

    await controller.runTask(task, prompt: '第一轮');
    await controller.runTask(task, prompt: '第二轮');

    final userEvents = controller
        .eventsFor(task.id)
        .where((event) => event.type == 'user.message')
        .toList();
    expect(userEvents, hasLength(2));
    final firstTurn = userEvents[0].payload['turn_id'];
    final secondTurn = userEvents[1].payload['turn_id'];
    expect(firstTurn, isA<String>());
    expect(secondTurn, isA<String>());
    expect(secondTurn, isNot(firstTurn));

    await controller.updateTaskStatus(
      task.id,
      'failed',
      turnId: firstTurn as String,
    );
    expect(controller.tasks.single.status, 'completed');
    expect(controller.isTaskRunning(task.id), isFalse);
    controller.dispose();
  });

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

  test(
    'a late stopping status cannot overwrite a terminal task status',
    () async {
      final controller = AppController(
        database: MemoryAppDatabase(),
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      final task = await controller.createTask(title: '取消竞态');

      final stopping = controller.updateTaskStatus(task.id, 'stopping');
      final terminal = controller.updateTaskStatus(task.id, 'cancelled');
      await Future.wait([stopping, terminal]);
      expect(controller.tasks.single.status, 'cancelled');

      await controller.updateTaskStatus(task.id, 'stopping');
      expect(controller.tasks.single.status, 'cancelled');
      controller.dispose();
    },
  );

  test('provider model metadata survives save and reload', () async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    await controller.saveProvider(
      name: '元数据供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'secret',
      isDefault: true,
      contextWindowMode: maximumContextWindowMode,
      modelMetadata: const {
        'model-a': ProviderModelMetadata(
          model: 'model-a',
          contextWindowTokens: 128000,
        ),
      },
    );
    controller.dispose();

    final restored = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await restored.load();
    expect(
      restored.providers.single.contextWindowMode,
      maximumContextWindowMode,
    );
    expect(
      restored
          .providers
          .single
          .modelMetadata['model-a']
          ?.resolvedContextWindowTokens,
      128000,
    );
    await restored.saveProvider(
      existing: restored.providers.single,
      name: restored.providers.single.name,
      baseUrl: restored.providers.single.baseUrl,
      model: restored.providers.single.model,
      secret: '',
      isDefault: true,
    );
    expect(
      restored.providers.single.contextWindowMode,
      maximumContextWindowMode,
    );
    restored.dispose();
  });

  test(
    'context usage resolves Codex fallback for id-only provider metadata',
    () async {
      final database = MemoryAppDatabase();
      const provider = ProviderProfile(
        id: 'provider-luna',
        name: 'Luna 供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'gpt-5.6-luna',
        apiKeyRef: 'provider-luna:key',
        isDefault: true,
        modelMetadata: {
          'gpt-5.6-luna': ProviderModelMetadata(
            model: 'gpt-5.6-luna',
            source: 'api',
          ),
        },
      );
      const taskId = 'task-luna-context';
      final now = DateTime.utc(2026, 8, 27);
      await database.saveProvider(provider);
      await database.saveTask(
        Task(
          id: taskId,
          mode: 'chat',
          serverId: null,
          providerId: provider.id,
          title: 'Luna 上下文',
          workingDirectory: null,
          executionMode: 'confirm',
          status: 'completed',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'luna-context-event',
          taskId: taskId,
          sequence: 1,
          type: 'assistant.completed',
          timestamp: now,
          payload: const {
            'provider_id': 'provider-luna',
            'wire_api': 'responses',
            'model': 'gpt-5.6-luna',
            'usage': {
              'input_tokens': 120000,
              'output_tokens': 9200,
              'total_tokens': 129200,
            },
          },
        ),
      );

      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final usage = await controller.loadTaskContextUsage(
        controller.tasks.single,
      );

      expect(usage.rawContextWindow, 272000);
      expect(usage.effectiveContextWindow, 258400);
      expect(usage.autoCompactTokenLimit, 244800);
      expect(usage.remainingPercent, 52);
    },
  );

  test('context usage follows the provider window mode', () async {
    final database = MemoryAppDatabase();
    const provider = ProviderProfile(
      id: 'provider-maximum-window',
      name: '扩展窗口供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'gpt-5.6-luna',
      contextWindowMode: maximumContextWindowMode,
      apiKeyRef: 'provider-maximum-window:key',
      isDefault: true,
    );
    final now = DateTime.utc(2026, 8, 27);
    await database.saveProvider(provider);
    await database.saveTask(
      Task(
        id: 'task-maximum-window',
        mode: 'chat',
        serverId: null,
        providerId: provider.id,
        title: '扩展窗口',
        workingDirectory: null,
        executionMode: 'confirm',
        status: 'completed',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'maximum-window-event',
        taskId: 'task-maximum-window',
        sequence: 1,
        type: 'assistant.completed',
        timestamp: now,
        payload: const {
          'provider_id': 'provider-maximum-window',
          'wire_api': 'responses',
          'model': 'gpt-5.6-luna',
          'usage': {
            'input_tokens': 120000,
            'output_tokens': 9200,
            'total_tokens': 129200,
          },
        },
      ),
    );

    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final usage = await controller.loadTaskContextUsage(
      controller.tasks.single,
    );

    expect(usage.rawContextWindow, 872000);
    expect(usage.effectiveContextWindow, 828400);
    expect(usage.autoCompactTokenLimit, 784800);
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
    expect(
      controller.eventsFor(task.id).last.payload['history_boundary'],
      false,
    );
    controller.dispose();
  });

  test(
    'work mode changes retain history and add a configuration note',
    () async {
      final database = MemoryAppDatabase(demoData: true);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        previewMode: true,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final task = await controller.createTask(
        workMode: 'collaborative',
        projectId: 'project-1',
        serverId: 'demo-server',
        providerId: 'demo-provider',
        title: '协同切换本地',
      );
      await controller.runTask(task, prompt: '先检查服务器和项目状态');

      final updated = await controller.updateTaskConfiguration(
        taskId: task.id,
        mode: 'agent',
        workMode: 'local',
        projectId: task.projectId,
        serverId: task.serverId,
        providerId: task.providerId,
        workingDirectory: task.workingDirectory,
        executionMode: task.executionMode,
      );
      final change = controller.eventsFor(task.id).last;
      expect(change.type, 'task.context_changed');
      expect(change.payload['history_boundary'], false);
      expect(change.payload['reason'], 'configuration_changed');
      expect(change.payload['previous_work_mode'], 'collaborative');
      expect(change.payload['work_mode'], 'local');

      final history = await database.loadModelEvents(task.id);
      expect(
        history.any(
          (event) =>
              event.type == 'user.message' &&
              event.payload['text'] == '先检查服务器和项目状态',
        ),
        isTrue,
      );

      final result = await controller.runTask(updated, prompt: '继续检查本地项目');
      expect(
        result.messages.any(
          (message) =>
              message.role == 'user' && message.content == '先检查服务器和项目状态',
        ),
        isTrue,
      );
      expect(
        result.messages.any(
          (message) =>
              message.role == 'developer' &&
              message.content?.contains('retained transcript') == true,
        ),
        isTrue,
      );
    },
  );

  test('legacy configuration boundary does not discard history', () async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.createTask(title: '旧边界历史');
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'user.message',
      payload: const {'text': '旧对话上下文'},
    );
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'task.context_changed',
      payload: const {
        'history_boundary': true,
        'mode': 'agent',
        'work_mode': 'local',
      },
    );

    final history = await database.loadModelEvents(task.id);
    expect(
      history.any(
        (event) =>
            event.type == 'user.message' && event.payload['text'] == '旧对话上下文',
      ),
      isTrue,
    );
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
      expect(
        controller.eventsFor(updated.id).last.type,
        'task.context_changed',
      );
      expect(
        controller.eventsFor(updated.id).last.payload['history_boundary'],
        false,
      );

      final continued = await controller.createContinuationTask(updated);
      expect(continued.modelOverride, isNull);
      expect(continued.reasoningEffortOverride, 'high');
      controller.dispose();
    },
  );

  test(
    'provider context changes keep the transcript without a history boundary',
    () async {
      final database = MemoryAppDatabase();
      const provider = ProviderProfile(
        id: 'provider-boundary',
        name: '边界供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'model-a',
        reasoningEffort: 'default',
        wireApi: 'responses',
        apiKeyRef: 'provider-boundary:key',
        isDefault: true,
        modelMetadata: {
          'model-a': ProviderModelMetadata(
            model: 'model-a',
            compHash: 'comp-a',
          ),
        },
      );
      await database.saveProvider(provider);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      final task = await controller.createTask(
        providerId: provider.id,
        title: '供应商边界',
      );

      await controller.saveProvider(
        existing: controller.providers.single,
        name: provider.name,
        baseUrl: provider.baseUrl,
        model: provider.model,
        reasoningEffort: 'high',
        wireApi: provider.wireApi,
        secret: '',
        isDefault: true,
      );
      expect(
        controller
            .eventsFor(task.id)
            .where((event) => event.type == 'task.context_changed'),
        isEmpty,
      );

      await controller.saveProvider(
        existing: controller.providers.single,
        name: provider.name,
        baseUrl: provider.baseUrl,
        model: 'model-b',
        reasoningEffort: 'high',
        wireApi: provider.wireApi,
        secret: '',
        isDefault: true,
      );
      await controller.saveProvider(
        existing: controller.providers.single,
        name: provider.name,
        baseUrl: provider.baseUrl,
        model: 'model-b',
        reasoningEffort: 'high',
        wireApi: 'chat-completions',
        secret: '',
        isDefault: true,
      );
      await controller.saveProvider(
        existing: controller.providers.single,
        name: provider.name,
        baseUrl: 'https://provider.example/other',
        model: 'model-b',
        reasoningEffort: 'high',
        wireApi: 'chat-completions',
        secret: '',
        isDefault: true,
      );

      final boundaries = controller
          .eventsFor(task.id)
          .where((event) => event.type == 'task.context_changed')
          .toList();
      expect(boundaries, hasLength(3));
      expect(
        boundaries.every((event) => event.payload['history_boundary'] == false),
        isTrue,
      );
      expect(boundaries[0].payload['history_projection'], 'model');
      expect(boundaries[1].payload['history_projection'], 'provider');
      controller.dispose();
    },
  );

  test(
    'model compaction metadata changes keep the existing task history',
    () async {
      final database = MemoryAppDatabase();
      const provider = ProviderProfile(
        id: 'provider-comp-hash',
        name: '压缩元数据供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'model-a',
        apiKeyRef: 'provider-comp-hash:key',
        isDefault: true,
        modelMetadata: {
          'model-a': ProviderModelMetadata(
            model: 'model-a',
            contextWindowTokens: 128000,
            compHash: 'same',
          ),
        },
      );
      await database.saveProvider(provider);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      final task = await controller.createTask(
        providerId: provider.id,
        title: '压缩元数据变化',
      );

      await controller.saveProvider(
        existing: controller.providers.single,
        name: provider.name,
        baseUrl: provider.baseUrl,
        model: provider.model,
        secret: '',
        isDefault: true,
        modelMetadata: const {
          'model-a': ProviderModelMetadata(
            model: 'model-a',
            contextWindowTokens: 256000,
            compHash: 'same',
          ),
        },
      );

      final change = controller.eventsFor(task.id).last;
      expect(change.type, 'task.context_changed');
      expect(change.payload['history_boundary'], false);
      expect(change.payload['history_projection'], 'model');
      controller.dispose();
    },
  );

  test(
    'switching the default provider keeps an unbound task transcript',
    () async {
      final database = MemoryAppDatabase();
      const first = ProviderProfile(
        id: 'provider-default-a',
        name: '默认供应商 A',
        baseUrl: 'https://a.example/v1',
        model: 'model-a',
        apiKeyRef: 'provider-default-a:key',
        isDefault: true,
      );
      const second = ProviderProfile(
        id: 'provider-default-b',
        name: '默认供应商 B',
        baseUrl: 'https://b.example/v1',
        model: 'model-b',
        apiKeyRef: 'provider-default-b:key',
        isDefault: false,
      );
      await database.saveProvider(first);
      await database.saveProvider(second);
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      final task = await controller.createTask(title: '未固定供应商');

      await controller.saveProvider(
        existing: controller.providers.firstWhere(
          (provider) => provider.id == second.id,
        ),
        name: second.name,
        baseUrl: second.baseUrl,
        model: second.model,
        secret: '',
        isDefault: true,
      );

      final change = controller.eventsFor(task.id).last;
      expect(change.type, 'task.context_changed');
      expect(change.payload['history_boundary'], false);
      expect(change.payload['history_projection'], 'provider');
      expect(
        controller.eventsFor(task.id).last.payload['provider_id'],
        second.id,
      );
      controller.dispose();
    },
  );

  test(
    'failed turn keeps history when switching to another provider protocol',
    () async {
      final requestBodies = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestBodies.add(await utf8.decoder.bind(request).join());
        if (requestBodies.length == 2) {
          request.response.statusCode = 503;
          request.response.write('temporary provider failure');
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/responses')) {
          request.response.write(
            jsonEncode({
              'status': 'completed',
              'output': [
                {
                  'type': 'reasoning',
                  'id': 'reasoning-a',
                  'encrypted_content': 'opaque-a',
                  'summary': <Object?>[],
                },
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': '第一轮回复'},
                  ],
                },
              ],
            }),
          );
        } else {
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': '第三轮回复'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
        }
        await request.response.close();
      });

      final database = MemoryAppDatabase();
      final credentials = MemoryCredentialStore();
      final controller = AppController(
        database: database,
        credentials: credentials,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final baseUrl = 'http://127.0.0.1:${server.port}/v1';
      await controller.saveProvider(
        name: 'Responses 供应商',
        baseUrl: baseUrl,
        model: 'model-a',
        secret: 'key-a',
        isDefault: true,
      );
      final firstProvider = controller.providers.single;
      await controller.saveProvider(
        name: 'Chat 供应商',
        baseUrl: baseUrl,
        model: 'model-b',
        wireApi: 'chat-completions',
        secret: 'key-b',
        isDefault: false,
      );
      final secondProvider = controller.providers.firstWhere(
        (provider) => provider.name == 'Chat 供应商',
      );
      final task = await controller.createTask(
        mode: 'chat',
        providerId: firstProvider.id,
        title: '切换供应商后继续',
      );

      await controller.runTask(task, prompt: '第一轮请求');
      final failed = await controller.runTask(task, prompt: '失败请求');
      expect(failed.status, 'failed');

      final updated = await controller.updateTaskConfiguration(
        taskId: task.id,
        mode: task.mode,
        workMode: task.effectiveWorkMode,
        projectId: task.projectId,
        serverId: task.serverId,
        providerId: secondProvider.id,
        workingDirectory: task.workingDirectory,
        executionMode: task.executionMode,
      );
      final continued = await controller.runTask(updated, prompt: '继续请求');

      expect(continued.status, 'completed');
      expect(requestBodies, hasLength(3));
      final body = jsonDecode(requestBodies[2]) as Map<String, Object?>;
      final messages = (body['messages'] as List).cast<Map>();
      expect(
        messages.any(
          (message) =>
              message['role'] == 'user' && message['content'] == '第一轮请求',
        ),
        isTrue,
      );
      expect(
        messages.any(
          (message) =>
              message['role'] == 'assistant' && message['content'] == '第一轮回复',
        ),
        isTrue,
      );
      expect(
        messages.any(
          (message) =>
              message['role'] == 'user' && message['content'] == '失败请求',
        ),
        isTrue,
      );
      expect(
        messages.any(
          (message) =>
              message['role'] == 'developer' &&
              '${message['content']}'.contains('different AI provider'),
        ),
        isTrue,
      );
      expect(jsonEncode(body), isNot(contains('opaque-a')));
      final contextChange = controller
          .eventsFor(task.id)
          .lastWhere((event) => event.type == 'task.context_changed');
      expect(contextChange.payload['history_boundary'], false);
      expect(contextChange.payload['history_projection'], 'provider');
    },
  );

  test(
    'agent persists its streamed preamble before starting a tool call',
    () async {
      final requestBodies = <Map<String, Object?>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        requestBodies.add(Map<String, Object?>.from(jsonDecode(raw) as Map));
        request.response.headers.contentType = ContentType.json;
        final first = requestBodies.length == 1;
        request.response.write(
          jsonEncode({
            'status': 'completed',
            'output': first
                ? [
                    {
                      'type': 'message',
                      'role': 'assistant',
                      'content': [
                        {'type': 'output_text', 'text': '我先检查当前状态，再继续。'},
                      ],
                    },
                    {
                      'type': 'function_call',
                      'id': 'item-1',
                      'call_id': 'call-1',
                      'name': 'local.list',
                      'arguments': '{"path":"/tmp"}',
                    },
                  ]
                : [
                    {
                      'type': 'message',
                      'role': 'assistant',
                      'content': [
                        {'type': 'output_text', 'text': '检查完成。'},
                      ],
                    },
                  ],
          }),
        );
        await request.response.close();
      });

      final database = MemoryAppDatabase();
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
        taskService: const _NoopAndroidTaskService(),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.saveProvider(
        name: 'Agent 流式测试供应商',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'agent-model',
        secret: 'test-key',
        isDefault: true,
      );
      final provider = controller.providers.single;
      final task = await controller.createTask(
        mode: 'agent',
        workMode: 'local',
        providerId: provider.id,
        executionMode: 'auto',
        title: 'Agent 流式回复',
      );

      var sawStreamingText = false;
      var blankBeforePersistence = false;
      controller.addListener(() {
        final streaming = controller.streamingAssistantText(task.id);
        final preamblePersisted = controller
            .eventsFor(task.id)
            .any(
              (event) =>
                  event.type == 'assistant.completed' &&
                  event.payload['text'] == '我先检查当前状态，再继续。',
            );
        if (streaming.isNotEmpty) sawStreamingText = true;
        if (sawStreamingText && streaming.isEmpty && !preamblePersisted) {
          blankBeforePersistence = true;
        }
      });

      final result = await controller.runTask(task, prompt: '检查状态');

      expect(result.status, 'completed', reason: '${result.error}');
      expect(requestBodies, hasLength(2));
      expect(
        jsonEncode(requestBodies.first),
        contains('Before the first tool call'),
      );
      expect(sawStreamingText, isTrue);
      expect(blankBeforePersistence, isFalse);
      final events = controller.eventsFor(task.id);
      final preambleIndex = events.indexWhere(
        (event) =>
            event.type == 'assistant.completed' &&
            event.payload['text'] == '我先检查当前状态，再继续。',
      );
      final toolIndex = events.indexWhere(
        (event) => event.type == 'tool.started',
      );
      expect(preambleIndex, greaterThanOrEqualTo(0));
      expect(toolIndex, greaterThan(preambleIndex));
    },
  );

  test('cannot delete the fallback provider used by an unbound task', () async {
    final database = MemoryAppDatabase();
    const first = ProviderProfile(
      id: 'provider-fallback-a',
      name: '回退供应商 A',
      baseUrl: 'https://a.example/v1',
      model: 'model-a',
      apiKeyRef: 'provider-fallback-a:key',
      isDefault: false,
    );
    const second = ProviderProfile(
      id: 'provider-fallback-b',
      name: '回退供应商 B',
      baseUrl: 'https://b.example/v1',
      model: 'model-b',
      apiKeyRef: 'provider-fallback-b:key',
      isDefault: false,
    );
    await database.saveProvider(first);
    await database.saveProvider(second);
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    await controller.createTask(title: '使用回退供应商');

    await expectLater(
      controller.deleteProvider(controller.providers.first),
      throwsA(isA<StateError>()),
    );
    expect(controller.providers, hasLength(2));
    controller.dispose();
  });

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

  test('a stale stop request cannot cancel the active turn', () async {
    final database = _BlockingModelHistoryDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    final task = await controller.createTask(title: '停止竞态');
    final run = controller.runTask(task, prompt: '继续执行');

    await database.started.future;
    final activeTurnId = controller.activeTurnIdFor(task.id);
    expect(activeTurnId, isNotNull);
    controller.stopTask(task.id, expectedTurnId: 'stale-turn');
    expect(controller.isTaskRunning(task.id), isTrue);
    database.release.complete();

    expect((await run).status, 'completed');
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
    'context usage reads all assistant events beyond the visible history page',
    () async {
      final database = MemoryAppDatabase();
      const provider = ProviderProfile(
        id: 'provider-context',
        name: '上下文供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'gpt-test',
        apiKeyRef: 'provider-context:key',
        isDefault: true,
        modelMetadata: {
          'gpt-test': ProviderModelMetadata(
            model: 'gpt-test',
            contextWindowTokens: 272000,
          ),
        },
      );
      const taskId = 'task-context';
      final now = DateTime.utc(2026, 8, 26);
      await database.saveProvider(provider);
      await database.saveTask(
        Task(
          id: taskId,
          mode: 'chat',
          serverId: null,
          providerId: provider.id,
          title: '长对话',
          workingDirectory: null,
          status: 'completed',
          executionMode: 'confirm',
          createdAt: now,
          updatedAt: now,
        ),
      );
      for (var index = 0; index < 45; index++) {
        await database.saveEvent(
          TaskEvent(
            eventId: 'context-event-$index',
            taskId: taskId,
            sequence: index + 1,
            type: 'assistant.completed',
            timestamp: now.add(Duration(seconds: index)),
            payload: const {
              'usage': {
                'prompt_tokens': 100,
                'completion_tokens': 20,
                'total_tokens': 120,
              },
            },
          ),
        );
      }

      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      final usage = await controller.loadTaskContextUsage(
        controller.tasks.single,
      );

      expect(controller.eventsFor(taskId), isEmpty);
      expect(usage.last?.totalTokens, 120);
      expect(usage.total?.totalTokens, 45 * 120);
      expect(usage.effectiveContextWindow, 258400);
      expect(usage.remainingPercent, 100);
      controller.dispose();
    },
  );

  test('context usage ignores telemetry from a different model', () async {
    final database = MemoryAppDatabase();
    const provider = ProviderProfile(
      id: 'provider-model-filter',
      name: '模型过滤供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'selected-model',
      apiKeyRef: 'provider-model-filter:key',
      isDefault: true,
      modelMetadata: {
        'selected-model': ProviderModelMetadata(
          model: 'selected-model',
          contextWindowTokens: 128000,
        ),
      },
    );
    final timestamp = DateTime.utc(2026, 8, 26);
    await database.saveProvider(provider);
    await database.saveTask(
      Task(
        id: 'task-model-filter',
        mode: 'chat',
        serverId: null,
        providerId: provider.id,
        title: '模型过滤',
        workingDirectory: null,
        status: 'completed',
        executionMode: 'confirm',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'old-model-usage',
        taskId: 'task-model-filter',
        sequence: 1,
        type: 'assistant.completed',
        timestamp: timestamp,
        payload: const {
          'model': 'old-model',
          'usage': {
            'prompt_tokens': 900,
            'completion_tokens': 100,
            'total_tokens': 1000,
          },
        },
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'selected-model-usage',
        taskId: 'task-model-filter',
        sequence: 2,
        type: 'assistant.completed',
        timestamp: timestamp.add(const Duration(seconds: 1)),
        payload: const {
          'model': 'selected-model',
          'usage': {
            'prompt_tokens': 20,
            'completion_tokens': 5,
            'total_tokens': 25,
          },
        },
      ),
    );

    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    final usage = await controller.loadTaskContextUsage(
      controller.tasks.single,
    );

    expect(usage.last?.totalTokens, 25);
    expect(usage.total?.totalTokens, 1025);
    controller.dispose();
  });

  test('manual Responses compaction stores the Codex local summary', () async {
    final requestBodies = <Map<String, Object?>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requestBodies.add(Map<String, Object?>.from(jsonDecode(raw) as Map));
      request.response.headers.contentType = ContentType.json;
      if (requestBodies.length == 1) {
        request.response.write(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '本地摘要'},
                ],
              },
            ],
          }),
        );
      } else {
        request.response.write(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': '继续完成'},
                ],
              },
            ],
          }),
        );
      }
      await request.response.close();
    });

    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: 'Responses 测试供应商',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final provider = controller.providers.single;
    final task = await controller.createTask(
      mode: 'chat',
      providerId: provider.id,
      title: '主动压缩',
    );
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'user.message',
      payload: const {'text': '第一轮请求'},
    );
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'assistant.completed',
      payload: {
        'text': '旧回复',
        'provider_id': provider.id,
        'wire_api': 'responses',
        'model': 'model-a',
        'responses_output_items': const [
          {
            'type': 'message',
            'id': 'old-output',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': '旧回复'},
            ],
          },
        ],
        'usage': const {
          'input_tokens': 80,
          'output_tokens': 20,
          'total_tokens': 100,
        },
      },
    );

    final usage = await controller.compactTaskContext(task);

    expect(requestBodies, hasLength(1));
    final compactBody = requestBodies.first;
    expect(compactBody['model'], 'model-a');
    expect(compactBody['instructions'], isNotEmpty);
    expect(compactBody['stream'], isTrue);
    expect(compactBody['store'], isFalse);
    expect(compactBody.containsKey('tools'), isFalse);
    final compactInput = compactBody['input'] as List;
    expect(
      compactInput.any((item) => item is Map && item['role'] == 'user'),
      isTrue,
    );
    expect(
      compactInput.any(
        (item) =>
            item is Map &&
            (item['content'] as List).any(
              (content) =>
                  content is Map &&
                  content['text'] is String &&
                  (content['text'] as String).contains(
                    'CONTEXT CHECKPOINT COMPACTION',
                  ),
            ),
      ),
      isTrue,
    );
    final compactEvents = controller
        .eventsFor(task.id)
        .where((event) => event.type == 'context.compacted')
        .toList();
    expect(compactEvents, hasLength(1));
    expect(compactEvents.single.payload['source'], 'manual');
    expect(compactEvents.single.payload['compaction_mode'], 'local');
    expect(compactEvents.single.payload['summary'], contains('本地摘要'));
    expect(compactEvents.single.payload['retained_user_messages'], [
      {'text': '第一轮请求'},
    ]);
    expect(
      compactEvents.single.payload.containsKey('responses_output_items'),
      isFalse,
    );
    expect(usage.last, isNull);
    expect(usage.compactionCount, 1);

    final result = await controller.runTask(task, prompt: '继续');
    expect(result.status, 'completed');
    expect(requestBodies, hasLength(2));
    expect(requestBodies.last['context_management'], [
      {'type': 'compaction', 'compact_threshold': 244800},
    ]);
    final nextInput = requestBodies.last['input'] as List;
    expect(
      nextInput.any(
        (item) =>
            item is Map &&
            (item['content'] as List).any(
              (content) =>
                  content is Map &&
                  content['text'] is String &&
                  (content['text'] as String).contains('本地摘要'),
            ),
      ),
      isTrue,
    );
    expect(
      nextInput.where(
        (item) =>
            item is Map &&
            (item['content'] as List).any(
              (content) => content is Map && content['text'] == '第一轮请求',
            ),
      ),
      hasLength(1),
    );
    expect(
      nextInput.any(
        (item) =>
            item is Map &&
            (item['content'] as List).any(
              (content) => content is Map && content['text'] == '继续',
            ),
      ),
      isTrue,
    );
    expect(
      nextInput.any(
        (item) =>
            item is Map &&
            (item['content'] as List).any(
              (content) => content is Map && content['text'] == '旧回复',
            ),
      ),
      isFalse,
    );
  });

  test('failed manual compaction does not write a context event', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.statusCode = 503;
      request.response.write('temporary failure');
      await request.response.close();
    });
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '失败压缩供应商',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final provider = controller.providers.single;
    final task = await controller.createTask(
      mode: 'chat',
      providerId: provider.id,
      title: '压缩失败',
    );
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'user.message',
      payload: const {'text': '保留历史'},
    );

    await expectLater(
      controller.compactTaskContext(task),
      throwsA(isA<AiProviderHttpException>()),
    );
    expect(
      controller
          .eventsFor(task.id)
          .where((event) => event.type == 'context.compacted'),
      isEmpty,
    );
  });

  test('manual compaction is rejected while a task is running', () async {
    final requestStarted = Completer<void>();
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      if (!requestStarted.isCompleted) requestStarted.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': '完成'},
              ],
            },
          ],
        }),
      );
      await request.response.close();
    });
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '运行中压缩供应商',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final provider = controller.providers.single;
    final task = await controller.createTask(
      mode: 'chat',
      providerId: provider.id,
      title: '运行中',
    );
    final running = controller.runTask(task, prompt: '执行中');
    await requestStarted.future;

    await expectLater(
      controller.compactTaskContext(task),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          contains('任务运行中'),
        ),
      ),
    );
    release.complete();
    expect((await running).status, 'completed');
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
        await controller.loadAttachmentBytes(attachment.id!, taskId: task.id),
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
        await controller.loadAttachmentBytes(
          attachment.id!,
          taskId: 'task-legacy',
        ),
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

  test(
    'loading earlier events keeps an event appended during the load',
    () async {
      final database = _BlockingEventsBeforeDatabase();
      final timestamp = DateTime.utc(2026, 8, 26);
      await database.saveTask(
        Task(
          id: 'task-page-race',
          mode: 'chat',
          serverId: null,
          providerId: null,
          title: '分页竞态',
          workingDirectory: null,
          executionMode: 'confirm',
          status: 'completed',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      for (var sequence = 1; sequence <= 80; sequence++) {
        await database.saveEvent(
          TaskEvent(
            eventId: 'page-event-$sequence',
            taskId: 'task-page-race',
            sequence: sequence,
            type: 'user.message',
            timestamp: timestamp,
            payload: {'text': 'message $sequence'},
          ),
        );
      }
      final controller = AppController(
        database: database,
        credentials: MemoryCredentialStore(),
      );
      await controller.load();
      await controller.ensureTaskEventsLoaded('task-page-race');

      final loading = controller.loadEarlierTaskEvents('task-page-race');
      await database.started.future;
      await controller.appendTaskEvent(
        taskId: 'task-page-race',
        type: 'user.message',
        payload: const {'text': 'new message'},
      );
      database.release.complete();
      await loading;

      expect(controller.eventsFor('task-page-race'), hasLength(81));
      expect(
        controller.eventsFor('task-page-race').last.payload['text'],
        'new message',
      );
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

  test(
    'model history restores the current user after pre-turn compaction',
    () async {
      final database = MemoryAppDatabase();
      final timestamp = DateTime.utc(2026, 8, 26);
      await database.saveEvent(
        TaskEvent(
          eventId: 'current-user-before-compaction',
          taskId: 'task-pre-turn-compaction',
          sequence: 1,
          type: 'user.message',
          timestamp: timestamp,
          payload: const {'turn_id': 'turn-current', 'text': '本轮请求'},
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'task-started-before-compaction',
          taskId: 'task-pre-turn-compaction',
          sequence: 2,
          type: 'task.started',
          timestamp: timestamp,
          payload: const {'turn_id': 'turn-current'},
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'pre-turn-compaction',
          taskId: 'task-pre-turn-compaction',
          sequence: 3,
          type: 'context.compacted',
          timestamp: timestamp,
          payload: const {
            'turn_id': 'turn-current',
            'responses_output_items': [
              {'type': 'compaction', 'encrypted_content': 'summary'},
            ],
          },
        ),
      );
      await database.saveEvent(
        TaskEvent(
          eventId: 'after-compaction',
          taskId: 'task-pre-turn-compaction',
          sequence: 4,
          type: 'assistant.completed',
          timestamp: timestamp,
          payload: const {'text': '完成'},
        ),
      );

      expect(
        (await database.loadModelEvents('task-pre-turn-compaction'))
            .map((event) => event.eventId),
        [
          'pre-turn-compaction',
          'current-user-before-compaction',
          'after-compaction',
        ],
      );
    },
  );

  test('Responses compaction resumes after a provider projection', () async {
    final database = MemoryAppDatabase();
    final timestamp = DateTime.utc(2026, 8, 26);
    await database.saveEvent(
      TaskEvent(
        eventId: 'old-provider-compaction',
        taskId: 'task-provider-compaction',
        sequence: 1,
        type: 'assistant.completed',
        timestamp: timestamp,
        payload: const {
          'provider_id': 'provider-a',
          'wire_api': 'responses',
          'responses_output_items': [
            {'type': 'compaction', 'encrypted_content': 'old-opaque'},
          ],
        },
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'provider-projection',
        taskId: 'task-provider-compaction',
        sequence: 2,
        type: 'task.context_changed',
        timestamp: timestamp,
        payload: const {
          'history_boundary': false,
          'history_projection': 'provider',
        },
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'new-provider-compaction',
        taskId: 'task-provider-compaction',
        sequence: 3,
        type: 'assistant.completed',
        timestamp: timestamp,
        payload: const {
          'provider_id': 'provider-b',
          'wire_api': 'responses',
          'responses_output_items': [
            {'type': 'compaction', 'encrypted_content': 'new-opaque'},
          ],
        },
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'after-new-compaction',
        taskId: 'task-provider-compaction',
        sequence: 4,
        type: 'user.message',
        timestamp: timestamp,
        payload: const {'text': '继续'},
      ),
    );

    expect(
      (await database.loadModelEvents('task-provider-compaction'))
          .map((event) => event.eventId),
      ['new-provider-compaction', 'after-new-compaction'],
    );
  });

  test('attachment ids cannot be reused across conversations', () async {
    final root = await Directory.systemTemp.createTemp(
      'mobile-agent-attachment-scope-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      attachmentStore: AttachmentStore(rootProvider: () async => root),
      previewMode: true,
    );
    await controller.load();
    final owner = await controller.createTask(title: '附件拥有者');
    await controller.runTask(
      owner,
      prompt: '保存附件',
      attachments: const [
        AiAttachment(
          name: 'private.txt',
          mimeType: 'text/plain',
          base64Data: 'c2VjcmV0',
        ),
      ],
    );
    final ownerMessage = controller
        .eventsFor(owner.id)
        .firstWhere((event) => event.type == 'user.message');
    final attachment = AiAttachment.fromJson(
      Map<String, Object?>.from(
        (ownerMessage.payload['attachments'] as List).single as Map,
      ),
    );
    final other = await controller.createTask(title: '其他对话');

    await expectLater(
      controller.loadAttachmentBytes(attachment.id!, taskId: other.id),
      throwsA(isA<StateError>()),
    );
    final result = await controller.runTask(
      other,
      prompt: '复用附件',
      attachments: [attachment],
    );
    expect(result.status, 'failed');
    expect(
      controller
          .eventsFor(other.id)
          .where((event) => event.type == 'task.failed'),
      isNotEmpty,
    );

    final historical = await controller.createTask(title: '历史引用对话');
    await database.saveEvent(
      TaskEvent(
        eventId: 'foreign-history-event',
        taskId: historical.id,
        sequence: 1,
        type: 'user.message',
        timestamp: DateTime.now().toUtc(),
        payload: {
          'text': '历史引用',
          'attachments': [attachment.toJson()],
        },
      ),
    );
    final historicalResult = await controller.runTask(historical, prompt: '继续');
    expect(historicalResult.status, 'failed');
    expect(
      controller
          .eventsFor(historical.id)
          .where((event) => event.type == 'task.failed'),
      isNotEmpty,
    );
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
      await controller.loadAttachmentBytes(attachment.id!, taskId: task.id),
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
        await controller.loadAttachmentBytes(attachment.id!, taskId: task.id),
        utf8.encode('event'),
      );
      controller.dispose();
    },
  );

  test('setup failure still persists the current user message', () async {
    final root = await Directory.systemTemp.createTemp('mobile-agent-setup-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = _FailingModelHistoryDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
      attachmentStore: AttachmentStore(rootProvider: () async => root),
      previewMode: true,
    );
    await controller.load();
    final task = await controller.createTask(title: '初始化失败');

    final result = await controller.runTask(
      task,
      prompt: '保留这条消息',
      attachments: const [
        AiAttachment(
          name: 'setup.png',
          mimeType: 'image/png',
          base64Data: 'c2V0dXA=',
        ),
      ],
    );

    expect(result.status, 'failed');
    final events = await database.loadEvents(task.id);
    expect(events.map((event) => event.type), ['user.message', 'task.failed']);
    final userEvent = events.first;
    expect(userEvent.payload['text'], '保留这条消息');
    expect(jsonEncode(userEvent.payload), isNot(contains('c2V0dXA=')));
    final attachment = AiAttachment.fromJson(
      Map<String, Object?>.from(
        (userEvent.payload['attachments'] as List).single as Map,
      ),
    );
    expect(
      await controller.loadAttachmentBytes(attachment.id!, taskId: task.id),
      utf8.encode('setup'),
    );
    controller.dispose();
  });

  test('storage cleanup removes only unreferenced attachment files', () async {
    final root = await Directory.systemTemp.createTemp('mobile-agent-cleanup-');
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
    final task = await controller.createTask(title: '清理附件');
    await controller.runTask(
      task,
      prompt: '保留',
      attachments: const [
        AiAttachment(
          name: 'keep.png',
          mimeType: 'image/png',
          base64Data: 'a2VlcA==',
        ),
      ],
    );
    final orphan = AttachmentRecord(
      id: 'orphan',
      taskId: task.id,
      name: 'orphan.png',
      mimeType: 'image/png',
      byteLength: 6,
      storagePath: '${task.id}/orphan.png',
      createdAt: DateTime.now().toUtc(),
    );
    await store.write(orphan, Uint8List.fromList(utf8.encode('orphan')));
    await database.saveAttachments([orphan]);

    final result = await controller.cleanupStorage();

    expect(result.removedFiles, 1);
    expect(result.removedBytes, 6);
    expect(await database.loadAttachment('orphan'), isNull);
    final userEvent = controller
        .eventsFor(task.id)
        .firstWhere((event) => event.type == 'user.message');
    final retained = AiAttachment.fromJson(
      Map<String, Object?>.from(
        (userEvent.payload['attachments'] as List).single as Map,
      ),
    );
    expect(
      await controller.loadAttachmentBytes(retained.id!, taskId: task.id),
      utf8.encode('keep'),
    );
    controller.dispose();
  });

  test('deleting a project can clear its bound folder contents', () async {
    final root = await Directory.systemTemp.createTemp('mobile-agent-project-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    final project = await controller.createProject(
      name: '待删除项目',
      localPath: root.path,
    );
    await File('${root.path}/keep.txt').writeAsString('content');

    await controller.deleteProject(project, deleteFiles: true);

    expect(controller.projects, isEmpty);
    expect(await root.exists(), isTrue);
    expect(await root.list().toList(), isEmpty);
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
    expect(
      controller.cachedServerDashboard(controller.servers.single),
      same(dashboard),
    );
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

class _FailingModelHistoryDatabase extends MemoryAppDatabase {
  @override
  Future<List<TaskEvent>> loadModelEvents(
    String taskId, {
    bool useCompactionBoundary = true,
  }) {
    throw StateError('history load failed');
  }
}

class _BlockingEventsBeforeDatabase extends MemoryAppDatabase {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<TaskEventPage> loadEventsBefore(
    String taskId, {
    required int beforeSequence,
    int limit = 40,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.loadEventsBefore(
      taskId,
      beforeSequence: beforeSequence,
      limit: limit,
    );
  }
}

class _BlockingModelHistoryDatabase extends MemoryAppDatabase {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<TaskEvent>> loadModelEvents(
    String taskId, {
    bool useCompactionBoundary = true,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.loadModelEvents(
      taskId,
      useCompactionBoundary: useCompactionBoundary,
    );
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
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = await readFileBytes(remotePath);
    final start = offset.clamp(0, bytes.length).toInt();
    final requested = length ?? bytes.length;
    final end = (start + requested).clamp(start, bytes.length).toInt();
    return SshFileBytesChunk(
      offset: offset,
      nextOffset: end,
      bytes: Uint8List.fromList(bytes.sublist(start, end)),
      eof: end >= bytes.length,
      totalBytes: bytes.length,
    );
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
  Future<SshFileUploadSession> prepareFileUpload(
    String remotePath, {
    required String sourceKey,
    required int totalBytes,
    bool overwrite = true,
  }) => throw UnimplementedError();

  @override
  Future<void> writeFileBytesChunk(
    String remotePath,
    Uint8List contents, {
    required int offset,
  }) => throw UnimplementedError();

  @override
  Future<void> completeFileUpload(SshFileUploadSession session) =>
      throw UnimplementedError();

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

class _NoopAndroidTaskService extends AndroidTaskService {
  const _NoopAndroidTaskService();

  @override
  Future<void> start(
    String taskId, {
    bool overlayEnabled = false,
    double overlayScale = 1.0,
    String? title,
  }) async {}

  @override
  Future<void> stop(String taskId) async {}
}
