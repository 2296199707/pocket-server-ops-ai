import 'dart:io';

import 'package:mobile_agent/server_status_script.dart';

Future<void> main() async {
  await _checkShell('status script', statusScriptBody);
  await _checkShell('status probe', statusProbeCommand);
  await _checkShell('install command', statusScriptInstallCommand);
  stdout.writeln('Status script shell syntax passed');
}

Future<void> _checkShell(String name, String script) async {
  final process = await Process.start('sh', ['-n']);
  process.stdin.write(script);
  await process.stdin.close();
  final error = await process.stderr.transform(systemEncoding.decoder).join();
  final exitCode = await process.exitCode;
  if (exitCode != 0) throw StateError('$name syntax failed: $error');
}
