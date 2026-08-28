import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/platform/android_task_service.dart';
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

  test('floating capsule size and sidebar sections are persisted', () async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    await controller.setFloatingCapsuleScale(1.25);
    await controller.setFloatingCapsuleLengthScale(1.35);
    await controller.setSidebarSectionExpanded('other', false);

    final reloaded = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await reloaded.load();

    expect(reloaded.floatingCapsuleScale, 1.25);
    expect(reloaded.floatingCapsuleLengthScale, 1.35);
    expect(reloaded.sidebarSectionExpanded('other'), isFalse);
    controller.dispose();
    reloaded.dispose();
  });

  test('document module is enabled by default and can be disabled', () async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    expect(controller.documentModuleEnabled, isTrue);

    await controller.setDocumentModuleEnabled(false);
    final reloaded = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await reloaded.load();

    expect(reloaded.documentModuleEnabled, isFalse);
    controller.dispose();
    reloaded.dispose();
  });

  testWidgets('permissions page exposes the app permissions', (tester) async {
    final controller = AppController(
      database: MemoryAppDatabase(),
      credentials: MemoryCredentialStore(),
      taskService: const _AllowAllTaskService(),
    );
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: AppPermissionsPage(controller: controller)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('悬浮窗'), findsOneWidget);
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('文件访问'), findsOneWidget);
    expect(find.text('安装更新'), findsOneWidget);
  });
}

class _AllowAllTaskService extends AndroidTaskService {
  const _AllowAllTaskService();

  @override
  Future<bool> canDrawOverlays() async => true;

  @override
  Future<bool> canPostNotifications() async => true;

  @override
  Future<bool> requestOverlayPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;
}
