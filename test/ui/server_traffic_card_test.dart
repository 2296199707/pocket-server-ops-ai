import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/domain/server_port_traffic.dart';
import 'package:mobile_agent/ui/server_traffic_card.dart';

void main() {
  testWidgets('compact totals and configuration work at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? configuredSsh;
    String? configuredHy2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ServerTrafficCard(
                traffic: const ServerPortTraffic(
                  status: 'ready',
                  sshPorts: '22',
                  hy2Ports: '443',
                  ssh: PortTraffic(receivedBytes: 100, transmittedBytes: 200),
                  hy2: PortTraffic(receivedBytes: 300, transmittedBytes: 400),
                ),
                busy: false,
                onConfigure: (ssh, hy2) async {
                  configuredSsh = ssh;
                  configuredHy2 = hy2;
                },
                onDisable: () async {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('合计'), findsOneWidget);
    expect(find.text('1000 B'), findsOneWidget);
    expect(find.text('SSH/TCP'), findsOneWidget);
    expect(find.text('HY2/UDP'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('配置端口'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, '22,2222');
    await tester.tap(find.text('安装统计规则'));
    await tester.pumpAndSettle();
    expect(configuredSsh, '22,2222');
    expect(configuredHy2, '443');
    expect(tester.takeException(), isNull);
  });
}
