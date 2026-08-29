import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/providers/provider_usage_client.dart';
import 'package:mobile_agent/providers/provider_connection_tester.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/ui/chat_page.dart';
import 'package:mobile_agent/ui/home_shell.dart';

void main() {
  testWidgets('home opens on chat and sends preview text', (tester) async {
    final controller = AppController(
      database: MemoryAppDatabase(demoData: true),
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(home: HomeShell(controller: controller)),
    );
    expect(
      find.descendant(of: find.byTooltip('切换工作模式'), matching: find.text('对话')),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(find.text('你好'), findsWidgets);
    expect(find.text('这是预览模式的普通对话回复。'), findsOneWidget);

    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData' && call.arguments is Map) {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byTooltip('复制整段消息').last);
    expect(copiedText, '这是预览模式的普通对话回复。');

    expect(find.text('demo-model'), findsOneWidget);
    expect(find.text('智能'), findsOneWidget);
    await tester.tap(find.text('智能'));
    await tester.pumpAndSettle();
    expect(find.text('模型与推理'), findsOneWidget);
    expect(find.text('demo-coder'), findsNothing);

    await tester.tap(find.text('AI 模型'));
    await tester.pumpAndSettle();
    expect(find.text('模型列表'), findsOneWidget);
    expect(find.byTooltip('返回模型与推理'), findsOneWidget);
    expect(find.text('demo-coder'), findsOneWidget);

    await tester.tap(find.byTooltip('返回模型与推理'));
    await tester.pumpAndSettle();
    expect(find.text('模型与推理'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('home restores the last opened conversation', (tester) async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final first = await controller.createTask(title: '较早对话');
    await controller.createTask(title: '较新对话');
    await controller.setLastConversationTask(first.id);

    await tester.pumpWidget(
      MaterialApp(home: HomeShell(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('较早对话'), findsOneWidget);
    expect(find.text('较新对话'), findsNothing);
  });

  testWidgets('compact drawer keeps its labels on a narrow screen', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = MemoryAppDatabase();
    await database.saveProject(
      const Project(
        id: 'drawer-project',
        name: '测试项目',
        localPath: '/tmp/drawer-project',
      ),
    );
    await database.saveTask(
      Task(
        id: 'drawer-task',
        mode: 'chat',
        workMode: 'chat',
        projectId: 'drawer-project',
        serverId: null,
        providerId: null,
        title: '项目对话',
        workingDirectory: null,
        executionMode: 'confirm',
        status: 'completed',
        createdAt: DateTime.utc(2026, 8, 28),
        updatedAt: DateTime.utc(2026, 8, 28),
      ),
    );
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(home: HomeShell(controller: controller)),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('服务器添加'), findsOneWidget);
    expect(find.text('服务器仪表盘'), findsOneWidget);
    expect(find.text('供应商设置'), findsOneWidget);
    await tester.tap(find.text('测试项目'));
    await tester.pumpAndSettle();
    expect(find.text('项目对话'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long user messages stay within a narrow phone layout', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      database: MemoryAppDatabase(demoData: true),
      credentials: MemoryCredentialStore(),
      previewMode: true,
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(home: HomeShell(controller: controller)),
    );

    const message =
        '这是一段足够长的用户消息，用来确认手机屏幕变窄后文字会在对话气泡内换行，'
        '而不会被推出右侧屏幕。';
    await tester.enterText(find.byType(TextField), message);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsWidgets);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('task duration uses the latest run in a conversation', (
    tester,
  ) async {
    final database = MemoryAppDatabase();
    final now = DateTime.now().toUtc();
    const taskId = 'task-duration';
    await database.saveTask(
      Task(
        id: taskId,
        mode: 'chat',
        serverId: null,
        providerId: null,
        title: '多轮任务',
        workingDirectory: null,
        executionMode: 'confirm',
        status: 'completed',
        createdAt: now.subtract(const Duration(hours: 12)),
        updatedAt: now,
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-1',
        taskId: taskId,
        sequence: 1,
        type: 'task.started',
        timestamp: now.subtract(const Duration(hours: 12)),
        payload: const {},
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-2',
        taskId: taskId,
        sequence: 2,
        type: 'task.completed',
        timestamp: now.subtract(const Duration(hours: 11)),
        payload: const {},
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-3',
        taskId: taskId,
        sequence: 3,
        type: 'task.started',
        timestamp: now.subtract(const Duration(minutes: 2)),
        payload: const {},
      ),
    );
    await database.saveEvent(
      TaskEvent(
        eventId: 'event-4',
        taskId: taskId,
        sequence: 4,
        type: 'task.completed',
        timestamp: now,
        payload: const {},
      ),
    );
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: taskId,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, SshHostKey _) async => true,
            onUserInfoRequest: (_, SshUserInfoRequest _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('用时 2 分'), findsOneWidget);
    expect(find.textContaining('用时 12 小时'), findsNothing);
    expect(find.text('已完成'), findsOneWidget);
    expect(tester.getTopLeft(find.text('已完成')).dx, lessThan(200));
    controller.dispose();
  });

  testWidgets('context actions stay right aligned while status stays left', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '布局测试供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final task = await controller.createTask(
      mode: 'chat',
      providerId: controller.providers.single.id,
      title: '顶部布局',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: task.id,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, _) async => true,
            onUserInfoRequest: (_, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.getTopLeft(find.text('普通对话')).dx;
    final provider = tester.getTopLeft(find.text('布局测试供应商')).dx;
    final settings = tester.getTopLeft(find.byTooltip('对话设置')).dx;
    expect(provider, greaterThan(context));
    expect(settings, greaterThan(provider));
  });

  testWidgets('composer keeps attachment on the left and send on the right', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '平板布局供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: null,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, _) async => true,
            onUserInfoRequest: (_, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final attachment = tester.getTopLeft(find.byTooltip('附件、图片和项目文件'));
    final send = tester.getTopLeft(find.byTooltip('发送'));
    expect(attachment.dx, lessThan(100));
    expect(send.dx, greaterThan(700));

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pump();
    final model = tester.getTopLeft(find.text('model-a'));
    final compactSend = tester.getTopLeft(find.byTooltip('发送'));
    expect((model.dy - compactSend.dy).abs(), lessThan(12));
  });

  testWidgets('model picker keeps working when the model catalog fails', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var modelRequests = 0;
    final modelClient = MockClient((_) async {
      modelRequests++;
      return http.Response('{}', 502);
    });
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      providerTester: ProviderConnectionTester(client: modelClient),
      providerUsageClient: ProviderUsageClient(
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(() {
      modelClient.close();
      controller.dispose();
    });
    await controller.load();
    await controller.saveProvider(
      name: '目录异常供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: null,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, _) async => true,
            onUserInfoRequest: (_, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('model-a'));
    await tester.pumpAndSettle();

    expect(find.text('模型与推理'), findsOneWidget);
    expect(modelRequests, 0);
    expect(find.text('模型列表刷新失败，继续使用已保存的模型'), findsNothing);
    await tester.tap(find.byTooltip('刷新推理参数'));
    await tester.pumpAndSettle();
    expect(modelRequests, 1);
    expect(find.text('推理参数刷新失败，继续使用已保存设置'), findsOneWidget);
    await tester.tap(find.text('AI 模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新模型列表'));
    await tester.pumpAndSettle();
    expect(modelRequests, 2);
    expect(find.text('模型列表刷新失败，继续使用已保存的模型'), findsOneWidget);
    expect(find.textContaining('读取模型或推理设置失败'), findsNothing);
  });

  testWidgets(
    'model picker only shows reasoning levels advertised by the model',
    (tester) async {
      tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = AppController(
        database: MemoryAppDatabase(),
        credentials: MemoryCredentialStore(),
        providerUsageClient: ProviderUsageClient(
          client: MockClient((_) async => http.Response('', 404)),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.saveProvider(
        name: '精确推理供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'model-a',
        secret: 'test-key',
        isDefault: true,
        modelMetadata: {
          'model-a': const ProviderModelMetadata(
            model: 'model-a',
            defaultReasoningLevel: 'high',
            supportedReasoningLevels: [
              ProviderReasoningLevel(effort: 'low', description: '轻量'),
              ProviderReasoningLevel(effort: 'high', description: '深度'),
            ],
          ),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              taskId: null,
              onTaskActivated: (_) {},
              onOpenSettings: () {},
              onConfirmTool: (_, _, _) async => true,
              onConfirmHostKey: (_, _) async => true,
              onUserInfoRequest: (_, _) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('model-a'));
      await tester.pumpAndSettle();

      expect(find.text('模型列表'), findsNothing);
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Medium'), findsNothing);
      expect(find.text('Extra High'), findsNothing);
      expect(find.text('供应商目录默认：High'), findsOneWidget);
    },
  );

  testWidgets(
    'model and subagent pickers show configured supplier reasoning values',
    (tester) async {
      tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = AppController(
        database: MemoryAppDatabase(),
        credentials: MemoryCredentialStore(),
        providerUsageClient: ProviderUsageClient(
          client: MockClient((_) async => http.Response('', 404)),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.saveProvider(
        name: '带自定义推理供应商',
        baseUrl: 'https://provider.example/v1',
        model: 'model-a',
        secret: 'test-key',
        isDefault: true,
        customReasoningEfforts: const ['medium'],
        modelMetadata: {
          'model-a': const ProviderModelMetadata(
            model: 'model-a',
            supportedReasoningLevels: [
              ProviderReasoningLevel(effort: 'low'),
              ProviderReasoningLevel(effort: 'high'),
            ],
          ),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPage(
              controller: controller,
              taskId: null,
              onTaskActivated: (_) {},
              onOpenSettings: () {},
              onConfirmTool: (_, _, _) async => true,
              onConfirmHostKey: (_, _) async => true,
              onUserInfoRequest: (_, _) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('model-a'));
      await tester.pumpAndSettle();
      expect(find.text('自定义：medium'), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('子代理模型设置'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      await tester.tap(find.text('子代理模型设置'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('自定义：medium'),
        find.byType(ListView).last,
        const Offset(0, -200),
      );
      expect(find.text('自定义：medium'), findsOneWidget);
      expect(find.byTooltip('删除自定义推理值'), findsNothing);
    },
  );

  testWidgets('Responses context details expose manual compaction', (
    tester,
  ) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      providerUsageClient: ProviderUsageClient(
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '界面测试供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final provider = controller.providers.single;
    final task = await controller.createTask(
      mode: 'chat',
      providerId: provider.id,
      title: '上下文详情',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: task.id,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, _) async => true,
            onUserInfoRequest: (_, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final contextButton = find.byIcon(Icons.data_usage_outlined);
    expect(contextButton, findsOneWidget);
    await tester.tap(contextButton);
    await tester.pumpAndSettle();

    expect(find.text('立即压缩'), findsOneWidget);
    expect(find.byIcon(Icons.compress_outlined), findsOneWidget);
  });

  testWidgets('task plan is a compact overlay that expands upward', (
    tester,
  ) async {
    tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      providerUsageClient: ProviderUsageClient(
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '计划界面供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      secret: 'test-key',
      isDefault: true,
    );
    final task = await controller.createTask(
      mode: 'agent',
      workMode: 'local',
      providerId: controller.providers.single.id,
      title: '计划任务',
    );
    await controller.appendTaskEvent(
      taskId: task.id,
      type: 'task.plan',
      payload: {
        'turn_id': 'turn-plan',
        'plan': [
          {'step': '检查项目', 'status': 'in_progress'},
          {'step': '完成修改', 'status': 'pending'},
          {'step': '部署应用', 'status': 'pending'},
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPage(
            controller: controller,
            taskId: task.id,
            onTaskActivated: (_) {},
            onOpenSettings: () {},
            onConfirmTool: (_, _, _) async => true,
            onConfirmHostKey: (_, _) async => true,
            onUserInfoRequest: (_, SshUserInfoRequest _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0/3 检查项目'), findsOneWidget);
    expect(find.text('部署应用'), findsNothing);
    await tester.tap(find.text('0/3 检查项目'));
    await tester.pumpAndSettle();

    expect(find.text('部署应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
