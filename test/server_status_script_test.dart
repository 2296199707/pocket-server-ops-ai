import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/server_status_script.dart';

void main() {
  test('disabled dashboard skips an old installed HY2 probe without reinstall', () async {
    final root = await Directory.systemTemp.createTemp('status-optional-');
    addTearDown(() => root.delete(recursive: true));
    final installed = File('${root.path}/installed-status');
    final marker = File('${root.path}/invoked');
    await installed.writeAsString(
      '#!/bin/sh\nprintf ran > "${marker.path}"\nprintf "script_version=4\\nhy2_status=running\\ncpu_usage=5\\ncpu_core_usage=cpu0:5\\n"\n',
    );
    expect((await Process.run('chmod', ['700', installed.path])).exitCode, 0);
    final command = statusProbeCommand.replaceAll(
      r'$HOME/.local/bin/mobile-agent-status',
      installed.path,
    );
    final disabled = await Process.run(
      'sh',
      ['-c', command],
      environment: {'PSO_TRAFFIC_MONITORING': '0'},
    );
    expect(disabled.exitCode, 0, reason: '${disabled.stderr}');
    expect(await marker.exists(), isFalse);
    expect(disabled.stdout, contains('script_version=1'));
    expect(disabled.stdout, contains('cpu_usage='));
    expect(disabled.stdout, isNot(contains('hy2_status=')));
    final enabled = await Process.run(
      'sh',
      ['-c', command],
      environment: {'PSO_TRAFFIC_MONITORING': '1'},
    );
    expect(enabled.exitCode, 0, reason: '${enabled.stderr}');
    expect(await marker.exists(), isTrue);
    expect(enabled.stdout, contains('hy2_status=running'));
  }, skip: !Platform.isLinux);

  test('new status script skips HY2 detection by default', () async {
    final root = await Directory.systemTemp.createTemp('status-default-');
    addTearDown(() => root.delete(recursive: true));
    final marker = File('${root.path}/invoked');
    for (final command in ['pgrep', 'ss', 'curl']) {
      final file = File('${root.path}/$command');
      await file.writeAsString(
        '#!/bin/sh\nprintf called >> "${marker.path}"\n',
      );
      expect((await Process.run('chmod', ['700', file.path])).exitCode, 0);
    }
    final result = await Process.run(
      'sh',
      ['-c', statusScriptBody],
      environment: {
        'PATH': '${root.path}:/usr/bin:/bin',
        'PSO_TRAFFIC_MONITORING': '0',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(await marker.exists(), isFalse);
    expect(result.stdout, contains('script_version=5'));
    expect(result.stdout, contains('cpu_usage='));
    expect(result.stdout, isNot(contains('hy2_status=')));
  }, skip: !Platform.isLinux);
}
