import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/ui/home_shell.dart';

void main() {
  testWidgets('settings exposes storage cleanup', (tester) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    expect(find.text('清理空间'), findsOneWidget);
    expect(find.textContaining('未被对话引用'), findsOneWidget);
  });

  testWidgets('settings exposes the cross-app floating capsule switch', (
    tester,
  ) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    expect(find.text('后台悬浮胶囊'), findsOneWidget);
    expect(find.textContaining('其他 App'), findsOneWidget);
    expect(controller.floatingCapsuleEnabled, isFalse);
  });

  testWidgets('developer beta update switch can be changed', (tester) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DeveloperSettingsPage(controller: controller)),
    );

    expect(controller.betaUpdatesEnabled, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(controller.betaUpdatesEnabled, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
