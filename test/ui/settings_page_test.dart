import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/ui/home_shell.dart';

void main() {
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
