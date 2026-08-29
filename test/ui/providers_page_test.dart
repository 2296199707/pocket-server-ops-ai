import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/providers/provider_connection_tester.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/ui/providers_page.dart';

void main() {
  testWidgets('saving a provider refreshes and stores its model catalog', (
    tester,
  ) async {
    var modelRequests = 0;
    final client = MockClient((request) async {
      modelRequests++;
      expect(request.url.path, '/v1/models');
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'saved-model'},
            {'id': 'image-model'},
          ],
        }),
        200,
      );
    });
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      providerTester: ProviderConnectionTester(client: client),
    );
    addTearDown(() {
      client.close();
      controller.dispose();
    });
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(home: ProvidersPage(controller: controller)),
    );
    await tester.tap(find.byTooltip('添加 AI 供应商'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('获取图片模型'), findsNothing);
    expect(find.byTooltip('刷新模型列表'), findsOneWidget);

    Finder input(String label) => find.byWidgetPredicate((widget) {
      return widget is TextField && widget.decoration?.labelText == label;
    });

    await tester.enterText(input('名称'), '测试供应商');
    await tester.enterText(input('Base URL'), 'https://provider.example/v1');
    await tester.enterText(input('默认模型'), 'saved-model');
    await tester.dragUntilVisible(
      find.byTooltip('添加自定义推理值'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byTooltip('添加自定义推理值'));
    await tester.pump();
    await tester.dragUntilVisible(
      input('自定义推理值 1'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.enterText(input('自定义推理值 1'), 'medium');
    await tester.dragUntilVisible(
      find.byTooltip('添加自定义推理值'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byTooltip('添加自定义推理值'));
    await tester.pump();
    await tester.dragUntilVisible(
      input('自定义推理值 2'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.enterText(input('自定义推理值 2'), 'temporary');
    await tester.dragUntilVisible(
      find.byTooltip('删除自定义推理值').last,
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.byTooltip('删除自定义推理值').last);
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(input('API Key'), 'secret');
    await tester.dragUntilVisible(
      find.text('设为默认供应商'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.tap(find.text('设为默认供应商'));
    await tester.pump();
    await tester.ensureVisible(find.text('保存').last);
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(modelRequests, 1);
    expect(controller.providers.single.modelMetadata, contains('saved-model'));
    expect(controller.providers.single.modelMetadata, contains('image-model'));
    expect(controller.providers.single.customReasoningEfforts, ['medium']);
    expect(find.text('图片模型'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('image-model'), findsOneWidget);
    await tester.tap(find.text('image-model').last);
    await tester.pumpAndSettle();
    expect(
      controller.imageModelFor(controller.providers.single.id),
      'image-model',
    );
  });

  testWidgets('editing an older explicit reasoning value keeps the picker valid', (
    tester,
  ) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.saveProvider(
      name: '旧版供应商',
      baseUrl: 'https://provider.example/v1',
      model: 'model-a',
      reasoningEffort: 'medium',
      secret: 'test-key',
      isDefault: true,
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
      MaterialApp(home: ProvidersPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('供应商操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('中'), findsWidgets);
  });
}
