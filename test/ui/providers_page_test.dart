import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
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

    Finder input(String label) => find.byWidgetPredicate((widget) {
      return widget is TextField && widget.decoration?.labelText == label;
    });

    await tester.enterText(input('名称'), '测试供应商');
    await tester.enterText(input('Base URL'), 'https://provider.example/v1');
    await tester.enterText(input('默认模型'), 'saved-model');
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(input('API Key'), 'secret');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();

    expect(modelRequests, 1);
    expect(controller.providers.single.modelMetadata, contains('saved-model'));
  });
}
