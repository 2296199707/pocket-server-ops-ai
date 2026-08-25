import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';
import 'package:mobile_agent/server_status_script.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('mobile-agent-ssh-');
  Process? sshd;
  StreamSubscription<List<int>>? sshdStderr;
  DartSshConnection? connection;
  try {
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${directory.path}/host_key',
    ]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${directory.path}/client_key',
    ]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${directory.path}/second_key',
    ]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${directory.path}/unauthorized_key',
    ]);
    final publicKey = await File('${directory.path}/client_key.pub')
        .readAsString();
    await File('${directory.path}/authorized_keys').writeAsString(publicKey);
    const sftpServer = '/usr/lib/openssh/sftp-server';
    final config = [
      'Port 22222',
      'ListenAddress 127.0.0.1',
      'HostKey ${directory.path}/host_key',
      'AuthorizedKeysFile ${directory.path}/authorized_keys',
      'PubkeyAuthentication yes',
      'PasswordAuthentication no',
      'PermitRootLogin yes',
      'StrictModes no',
      'UsePAM no',
      'Subsystem sftp $sftpServer',
      'PidFile ${directory.path}/sshd.pid',
      'LogLevel QUIET',
    ].join('\n');
    await File('${directory.path}/sshd_config').writeAsString('$config\n');
    sshd = await Process.start('/usr/sbin/sshd', [
      '-D',
      '-e',
      '-f',
      '${directory.path}/sshd_config',
    ]);
    sshdStderr = sshd.stderr.listen((_) {});
    await _waitForPort(22222);

    final privateKey = await File('${directory.path}/client_key')
        .readAsString();
    final secondPrivateKey = await File('${directory.path}/second_key')
        .readAsString();
    final secondPublicKey = (await File(
      '${directory.path}/second_key.pub',
    ).readAsString()).trim();
    connection = await DartSshConnection.connect(
      SshConnectionConfig(
        host: '127.0.0.1',
        port: 22222,
        username: 'root',
        privateKeyPem: privateKey,
        onFirstHostKey: (_) => true,
      ),
    );
    final command = await connection.run('printf smoke-ok');
    _check(command.stdout == 'smoke-ok', 'SSH command output mismatch');

    final remoteTools = RemoteAgentTools(
      connection,
      workingDirectory: directory.path,
    );
    AgentTool tool(String name) =>
        remoteTools.tools.firstWhere((value) => value.definition.name == name);
    await tool('file.write')
        .call({'path': 'relative.txt', 'content': 'relative-path\n'});
    _check(
      await connection.readFile('${directory.path}/relative.txt') ==
          'relative-path\n',
      'relative file path did not use the working directory',
    );
    final relativeRead = await tool('file.read').call({'path': 'relative.txt'});
    _check(
      (relativeRead as Map)['content'] == 'relative-path\n',
      'relative file read did not use the working directory',
    );
    await tool('file.replace').call({
      'path': 'relative.txt',
      'old': 'relative-path',
      'new': 'replaced-path',
    });
    _check(
      await connection.readFile('${directory.path}/relative.txt') ==
          'replaced-path\n',
      'relative file replace did not use the working directory',
    );
    await tool('file.write').call({
      'path': '${directory.path}/absolute.txt',
      'content': 'absolute-path\n',
    });
    _check(
      await connection.readFile('${directory.path}/absolute.txt') ==
          'absolute-path\n',
      'absolute file path was changed',
    );
    final delayedProcess = await tool('terminal.start')
        .call({'command': 'sleep 0.3; printf poll-ready'});
    final delayedProcessId = (delayedProcess as Map)['process_id'] as String;
    final pollTimer = Stopwatch()..start();
    final pollResult = await tool('terminal.poll')
        .call({'process_id': delayedProcessId, 'wait_ms': 1000});
    pollTimer.stop();
    _check(
      pollTimer.elapsed >= const Duration(milliseconds: 200) &&
          (pollResult as Map)['stdout'] == 'poll-ready',
      'terminal.poll did not wait for delayed output',
    );
    await remoteTools.close();

    final stdinCommand = await connection.run('cat', input: 'stdin-ok');
    _check(stdinCommand.stdout == 'stdin-ok', 'SSH command stdin mismatch');
    var timeoutObserved = false;
    try {
      await connection.run(
        'sleep 2',
        timeout: const Duration(milliseconds: 200),
      );
    } on SshCommandTimeout {
      timeoutObserved = true;
    }
    _check(timeoutObserved, 'SSH command timeout was not enforced');
    final afterTimeout = await connection.run('printf after-timeout');
    _check(
      afterTimeout.stdout == 'after-timeout',
      'SSH connection did not recover after command timeout',
    );
    final remotePath = '${directory.path}/remote.txt';
    await connection.run("printf 'before\n' > '${_quote(remotePath)}'");
    await connection.run("chmod 750 '${_quote(remotePath)}'");
    _check(
      await connection.readFile(remotePath) == 'before\n',
      'SFTP read failed',
    );
    await connection.replaceText(remotePath, 'before', 'after');
    _check(
      await connection.readFile(remotePath) == 'after\n',
      'SFTP replace failed',
    );
    final modeAfterReplace = await connection.run(
      "stat -c '%a' '${_quote(remotePath)}'",
    );
    _check(
      modeAfterReplace.stdout.trim() == '750',
      'SFTP replace did not preserve file mode',
    );
    await connection.writeFile(
      remotePath,
      Uint8List.fromList(utf8.encode('written\n')),
    );
    _check(
      await connection.readFile(remotePath) == 'written\n',
      'SFTP write failed',
    );
    final modeAfterWrite = await connection.run(
      "stat -c '%a' '${_quote(remotePath)}'",
    );
    _check(
      modeAfterWrite.stdout.trim() == '750',
      'SFTP write did not preserve file mode',
    );

    final symlinkTarget = '${directory.path}/symlink-target.txt';
    final symlinkPath = '${directory.path}/symlink.txt';
    await connection.run(
      "cd '${_quote(directory.path)}' && "
      "printf 'link-before\\n' > symlink-target.txt && "
      "chmod 640 symlink-target.txt && "
      "ln -s symlink-target.txt symlink.txt",
    );
    await connection.writeFile(
      symlinkPath,
      Uint8List.fromList(utf8.encode('link-after\n')),
    );
    _check(
      await connection.readFile(symlinkTarget) == 'link-after\n',
      'SFTP write through symlink did not update its target',
    );
    _check(
      (await connection.run("test -L '${_quote(symlinkPath)}'")).exitCode == 0,
      'SFTP write through symlink replaced the link',
    );
    final symlinkMode = await connection.run(
      "stat -c '%a' '${_quote(symlinkTarget)}'",
    );
    _check(
      symlinkMode.stdout.trim() == '640',
      'SFTP write through symlink did not preserve target mode',
    );

    final statusHome = '${directory.path}/status-home';
    final installStatus = await connection.run(
      "HOME='${_quote(statusHome)}'\n$statusScriptInstallCommand",
    );
    _check(
      installStatus.exitCode == 0 && installStatus.stdout.trim() == 'installed',
      'status script install failed',
    );
    final status = await connection.run(
      "HOME='${_quote(statusHome)}'\n$statusProbeCommand",
    );
    _check(
      status.exitCode == 0 && status.stdout.contains('script_version=1'),
      'status script probe failed',
    );

    final authorizationLine = '$secondPublicKey mobile-agent-v1:smoke';
    final authorizedKeysPath = '${directory.path}/authorized_keys';
    final appendResult = await connection.run(
      _appendAuthorizedKeyCommand(authorizedKeysPath, authorizationLine),
    );
    _check(
      appendResult.stdout.trim() == 'added',
      'authorized key append failed',
    );

    final secondConnection = await DartSshConnection.connect(
      SshConnectionConfig(
        host: '127.0.0.1',
        port: 22222,
        username: 'root',
        privateKeyPem: secondPrivateKey,
        expectedFingerprint: connection.hostKey.fingerprint,
      ),
    );
    _check(
      (await secondConnection.run('printf second-authorized')).stdout ==
          'second-authorized',
      'second key connection failed',
    );
    await secondConnection.close();

    final unauthorizedKey = await File('${directory.path}/unauthorized_key')
        .readAsString();
    await _expectFailure(
      DartSshConnection.connect(
        SshConnectionConfig(
          host: '127.0.0.1',
          port: 22222,
          username: 'root',
          privateKeyPem: unauthorizedKey,
          expectedFingerprint: connection.hostKey.fingerprint,
        ),
      ),
    );
    await connection.run(
      _removeAuthorizedKeyCommand(authorizedKeysPath, authorizationLine),
    );
    final removed = await connection.run(
      "grep -Fqx -- '${_quote(authorizationLine)}' '${_quote(authorizedKeysPath)}'",
    );
    _check(removed.exitCode != 0, 'authorization rollback failed');

    final process = await connection.execute('sleep 2');
    process.stop();
    process.close();
    process.stop();
    process.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final fingerprint = connection.hostKey.fingerprint;
    await connection.close();
    await connection.close();
    connection = null;
    await _expectFailure(
      DartSshConnection.connect(
        SshConnectionConfig(
          host: '127.0.0.1',
          port: 22222,
          username: 'root',
          privateKeyPem: privateKey,
          expectedFingerprint: 'SHA256:not-the-real-key',
        ),
      ),
    );
    stdout.writeln('SSH smoke passed: $fingerprint');
  } finally {
    await connection?.close();
    final stderrSubscription = sshdStderr;
    if (stderrSubscription != null) {
      unawaited(stderrSubscription.cancel());
    }
    sshd?.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sshd?.kill(ProcessSignal.sigkill);
    await directory.delete(recursive: true);
  }
  exit(0);
}

Future<String> _run(String command, List<String> arguments) async {
  final result = await Process.run(command, arguments);
  if (result.exitCode != 0) {
    throw StateError('$command failed: ${result.stderr}');
  }
  return '${result.stdout}';
}

Future<void> _waitForPort(int port) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    try {
      final socket = await Socket.connect('127.0.0.1', port);
      await socket.close();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('temporary sshd did not start');
}

Future<void> _expectFailure(Future<Object> future) async {
  try {
    await future;
  } catch (_) {
    return;
  }
  throw StateError('expected SSH connection to fail');
}

String _quote(String value) => value.replaceAll("'", "'\\''");

String _appendAuthorizedKeyCommand(String path, String line) {
  final quotedLine = "'${_quote(line)}'";
  final quotedPath = "'${_quote(path)}'";
  return [
    'set -eu',
    'touch $quotedPath',
    'chmod 600 $quotedPath',
    'if grep -Fqx -- $quotedLine $quotedPath; then printf existing; '
        'else printf "%s\\n" $quotedLine >> $quotedPath; printf added; fi',
  ].join('\n');
}

String _removeAuthorizedKeyCommand(String path, String line) {
  final quotedLine = "'${_quote(line)}'";
  final quotedPath = "'${_quote(path)}'";
  return [
    'set -eu',
    'temp=$quotedPath.mobile-agent.\$\$',
    'grep -Fvx -- $quotedLine $quotedPath > "\$temp" || true',
    'mv "\$temp" $quotedPath',
    'chmod 600 $quotedPath',
  ].join('\n');
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
