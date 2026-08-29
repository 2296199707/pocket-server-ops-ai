import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/ssh/remote_process.dart';
import 'package:mobile_agent/ssh/resumable_file_upload.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';

void main() {
  test('a process can be polled from a new connection', () async {
    final home = await Directory.systemTemp.createTemp('remote-process-');
    addTearDown(() => home.delete(recursive: true));
    final first = _LocalShellConnection(home);
    final controller = RemoteProcessController(first);
    final started = await controller.start(
      command: 'sleep 0.1; printf recovered',
      workingDirectory: home.path,
    );
    await first.close();

    final replacement = _LocalShellConnection(home);
    final replacementController = RemoteProcessController(replacement);
    final snapshot = await replacementController.poll(started.id, waitMs: 1000);

    expect(snapshot.done, isTrue);
    expect(snapshot.failed, isFalse);
    expect(snapshot.exitCode, 0);
    expect(snapshot.stdout, 'recovered');
    await replacementController.close();
  });

  test(
    'retrying the same process start does not run the command twice',
    () async {
      final home = await Directory.systemTemp.createTemp('remote-process-');
      addTearDown(() => home.delete(recursive: true));
      final connection = _LocalShellConnection(home);
      final controller = RemoteProcessController(connection);
      const id = 'process-idempotent-test';
      final command = 'printf x >> marker; sleep 0.1; printf done';

      final started = await Future.wait([
        controller.start(
          processId: id,
          command: command,
          workingDirectory: home.path,
        ),
        controller.start(
          processId: id,
          command: command,
          workingDirectory: home.path,
        ),
      ]);
      final snapshot = await controller.poll(id, waitMs: 1000);

      expect(started[0].id, id);
      expect(started[1].id, id);
      expect(snapshot.stdout, 'done');
      expect(await File('${home.path}/marker').readAsString(), 'x');
      await controller.close();
    },
  );

  test('terminal.exec reconnects without replaying its command', () async {
    final home = await Directory.systemTemp.createTemp('remote-process-');
    addTearDown(() => home.delete(recursive: true));
    final first = _LocalShellConnection(home)..closeAfterNextRun = true;
    final replacement = _LocalShellConnection(home);
    var reconnectCalls = 0;
    final tools = RemoteAgentTools(
      first,
      workingDirectory: home.path,
      reconnect: () async {
        reconnectCalls++;
        return replacement;
      },
    );
    final exec = tools.tools.singleWhere(
      (tool) => tool.definition.name == 'terminal.exec',
    );

    final result = await exec.call({
      'command': 'printf x >> marker; printf command-ok',
    }) as Map;

    expect(result['exit_code'], 0);
    expect(result['stdout'], 'command-ok');
    expect(reconnectCalls, 1);
    expect(await File('${home.path}/marker').readAsString(), 'x');
    await tools.close();
  });

  test(
    'disabling recovery keeps terminal.exec on the current connection',
    () async {
      final home = await Directory.systemTemp.createTemp('remote-process-');
      addTearDown(() => home.delete(recursive: true));
      final first = _LocalShellConnection(home)..closeAfterNextRun = true;
      final replacement = _LocalShellConnection(home);
      var reconnectCalls = 0;
      final tools = RemoteAgentTools(
        first,
        workingDirectory: home.path,
        reconnect: () async {
          reconnectCalls++;
          return replacement;
        },
        remoteTaskRecoveryEnabled: false,
      );
      final exec = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.exec',
      );

      final result =
          await exec.call({'command': 'printf disabled-mode'}) as Map;

      expect(result['exit_code'], 0);
      expect(result['stdout'], 'disabled-mode');
      expect(reconnectCalls, 0);
      expect(
        Directory('${home.path}/.cache/pocket-server-ops/processes')
            .existsSync(),
        isFalse,
      );
      await tools.close();
    },
  );
}

class _LocalShellConnection implements SshConnection {
  _LocalShellConnection(this.home);

  final Directory home;
  bool closed = false;
  bool closeAfterNextRun = false;

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:test',
  );

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => Future.value();

  @override
  Future<SshCommandStream> execute(
    String command, {
    String? workingDirectory,
    bool pty = false,
  }) => throw UnimplementedError();

  @override
  Future<SshCommandStream> shell({int width = 80, int height = 24}) =>
      throw UnimplementedError();

  @override
  Future<SshCommandResult> run(
    String command, {
    String? workingDirectory,
    String? input,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (closed) throw StateError('connection closed');
    final result = await Process.run(
      '/bin/sh',
      ['-c', command],
      workingDirectory: workingDirectory,
      environment: {...Platform.environment, 'HOME': home.path},
    );
    if (closeAfterNextRun) {
      closeAfterNextRun = false;
      closed = true;
    }
    return SshCommandResult(
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
      exitCode: result.exitCode,
    );
  }

  @override
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) =>
      throw UnimplementedError();

  @override
  Future<SshFileInfo> statPath(String remotePath) => throw UnimplementedError();

  @override
  Future<void> createDirectory(String remotePath) => throw UnimplementedError();

  @override
  Future<void> copyPath(String sourcePath, String destinationPath) =>
      throw UnimplementedError();

  @override
  Future<void> movePath(String sourcePath, String destinationPath) =>
      throw UnimplementedError();

  @override
  Future<void> renamePath(String sourcePath, String destinationPath) =>
      throw UnimplementedError();

  @override
  Future<void> deletePath(String remotePath) => throw UnimplementedError();

  @override
  Future<String> readFile(String remotePath) => File(remotePath).readAsString();

  @override
  Future<Uint8List> readFileBytes(String remotePath) =>
      File(remotePath).readAsBytes();

  @override
  Future<SshFileChunk> readFileChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = await readFileBytes(remotePath);
    final start = offset.clamp(0, bytes.length).toInt();
    final end = (start + (length ?? bytes.length))
        .clamp(start, bytes.length)
        .toInt();
    return SshFileChunk(
      offset: offset,
      nextOffset: end,
      content: String.fromCharCodes(bytes.sublist(start, end)),
      eof: end >= bytes.length,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = await readFileBytes(remotePath);
    final start = offset.clamp(0, bytes.length).toInt();
    final end = (start + (length ?? bytes.length))
        .clamp(start, bytes.length)
        .toInt();
    return SshFileBytesChunk(
      offset: offset,
      nextOffset: end,
      bytes: Uint8List.fromList(bytes.sublist(start, end)),
      eof: end >= bytes.length,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<SshFileUploadSession> prepareFileUpload(
    String remotePath, {
    required String sourceKey,
    required int totalBytes,
    bool overwrite = true,
  }) => throw UnimplementedError();

  @override
  Future<void> writeFileBytesChunk(
    String remotePath,
    Uint8List contents, {
    required int offset,
  }) => throw UnimplementedError();

  @override
  Future<void> completeFileUpload(SshFileUploadSession session) =>
      throw UnimplementedError();

  @override
  Future<void> writeFile(String remotePath, Uint8List contents) =>
      throw UnimplementedError();

  @override
  Future<void> replaceText(String remotePath, String oldText, String newText) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
  }
}
