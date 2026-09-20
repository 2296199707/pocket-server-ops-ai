import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/app_controller.dart';
import 'package:mobile_agent/credentials/credential_store.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/domain/server_port_traffic.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/storage/memory_app_database.dart';
import 'package:mobile_agent/ui/home_shell.dart';
import 'package:mobile_agent/ui/server_dashboard_page.dart';

void main() {
  testWidgets('settings entry opens dashboard settings and persists switch', (
    tester,
  ) async {
    final database = MemoryAppDatabase();
    final controller = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );
    await tester.scrollUntilVisible(find.text('仪表盘设置'), 500);
    await tester.tap(find.text('仪表盘设置'));
    await tester.pumpAndSettle();

    expect(find.text('流量监控'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(controller.dashboardTrafficEnabled, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(controller.dashboardTrafficEnabled, isTrue);
    final reloaded = AppController(
      database: database,
      credentials: MemoryCredentialStore(),
    );
    await reloaded.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.dashboardTrafficEnabled, isTrue);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('流量监控已开启'), findsOneWidget);
  });

  testWidgets('cached dashboard traffic follows the global switch', (
    tester,
  ) async {
    final controller = _FakeDashboardController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ServerDashboardPage(
          controller: controller,
          server: controller.server,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HY2 代理'), findsNothing);
    expect(find.text('合计'), findsNothing);
    expect(find.text('配置端口'), findsNothing);
    expect(find.text('系统概览'), findsOneWidget);

    await controller.setDashboardTrafficEnabled(true);
    await tester.pumpAndSettle();

    expect(find.text('HY2 代理'), findsOneWidget);
    expect(find.text('合计'), findsOneWidget);
    expect(find.text('配置端口'), findsOneWidget);
    expect(controller.loadCount, greaterThanOrEqualTo(2));

    await controller.setDashboardTrafficEnabled(false);
    await tester.pumpAndSettle();

    expect(find.text('HY2 代理'), findsNothing);
    expect(find.text('合计'), findsNothing);
    expect(find.text('配置端口'), findsNothing);
    expect(find.text('系统概览'), findsOneWidget);
  });
}

class _FakeDashboardController extends AppController {
  _FakeDashboardController()
    : super(
        database: MemoryAppDatabase(),
        credentials: MemoryCredentialStore(),
        previewMode: true,
      );

  final server = const ServerProfile(
    id: 'dashboard-test-server',
    name: '测试服务器',
    host: 'dashboard.test',
    port: 22,
    username: 'tester',
    authType: 'password',
    credentialRef: null,
    credentialPassphraseRef: null,
    hostKey: null,
    hostKeyFingerprint: null,
    defaultWorkingDirectory: null,
  );

  final dashboard = const ServerDashboard(
    hostname: 'dashboard-test-server',
    os: 'Linux',
    kernel: 'Linux 6.1',
    uptime: '1 day',
    load: '0.10 0.12 0.15',
    cpu: '4 cores',
    memory: '20% (1 / 4 GiB)',
    disk: '10G / 50G (20%)',
    statusScriptInstalled: true,
    hy2: ServerHy2Status(
      detected: true,
      status: 'running',
      listen: '443',
      memory: '32 MiB',
    ),
    portTraffic: ServerPortTraffic(
      status: 'ready',
      sshPorts: '22',
      hy2Ports: '443',
      ssh: PortTraffic(receivedBytes: 100, transmittedBytes: 200),
      hy2: PortTraffic(receivedBytes: 300, transmittedBytes: 400),
    ),
  );

  bool trafficEnabled = false;
  int loadCount = 0;

  @override
  bool get dashboardTrafficEnabled => trafficEnabled;

  @override
  Future<void> setDashboardTrafficEnabled(bool enabled) async {
    trafficEnabled = enabled;
    notifyListeners();
  }

  @override
  ServerDashboard? cachedServerDashboard(ServerProfile profile) => dashboard;

  @override
  List<ServerProfile> serversForTask(Task? task) => [server];

  @override
  Future<ServerProfile?> resolveServerForFeature({
    Task? task,
    required String feature,
    String? fallbackServerId,
  }) async => server;

  @override
  Future<ServerDashboard> loadServerDashboard(
    ServerProfile profile, {
    FutureOr<bool> Function(SshHostKey key)? onFirstHostKey,
  }) async {
    loadCount++;
    return dashboard;
  }
}
