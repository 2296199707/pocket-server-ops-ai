import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
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

    await tester.enterText(find.byType(TextField), '你好');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(find.text('你好'), findsWidgets);
    expect(find.text('这是预览模式的普通对话回复。'), findsOneWidget);

    await tester.tap(find.text('demo-model default'));
    await tester.pumpAndSettle();
    expect(find.text('模型与推理强度'), findsOneWidget);
    expect(find.text('demo-coder'), findsNothing);

    await tester.tap(find.text('AI 模型'));
    await tester.pumpAndSettle();
    expect(find.text('demo-coder'), findsOneWidget);

    controller.dispose();
  });
}
