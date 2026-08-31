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
    'terminal.exec yields a running process after the Codex wait window',
    () async {
      final home = await Directory.systemTemp.createTemp('remote-process-');
      addTearDown(() => home.delete(recursive: true));
      final tools = RemoteAgentTools(
        _LocalShellConnection(home),
        workingDirectory: home.path,
      );
      final exec = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.exec',
      );

      final first = await exec.call({
        'command': 'sleep 1; printf later',
        'yield_time_ms': 250,
      }) as Map;

      expect(first['done'], isFalse);
      expect(first['process_id'], isA<String>());
      final processId = first['process_id'] as String;
      final poll = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.poll',
      );
      final result =
          await poll.call({'process_id': processId, 'wait_ms': 2000}) as Map;

      expect(result['done'], isTrue);
      expect(result['exit_code'], 0);
      expect(result['stdout'], 'later');
      await tools.close();
    },
  );

  test(
    'a failed initial SSH connection can be retried by a later tool call',
    () async {
      final home = await Directory.systemTemp.createTemp('remote-process-');
      addTearDown(() => home.delete(recursive: true));
      var attempts = 0;
      final tools = RemoteAgentTools(
        null,
        workingDirectory: home.path,
        connectionFactory: () async {
          attempts++;
          if (attempts == 1) throw StateError('initial connection failed');
          return _LocalShellConnection(home);
        },
      );
      final exec = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.exec',
      );

      await expectLater(
        exec.call({'command': 'printf first'}),
        throwsA(isA<StateError>()),
      );
      final result = await exec.call({'command': 'printf second'}) as Map;

      expect(result['stdout'], 'second');
      expect(attempts, 2);
      await tools.close();
    },
  );

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

  test('multi-server tools route commands and process ids by server', () async {
    final firstHome = await Directory.systemTemp.createTemp('multi-server-a-');
    final secondHome = await Directory.systemTemp.createTemp('multi-server-b-');
    addTearDown(() => firstHome.delete(recursive: true));
    addTearDown(() => secondHome.delete(recursive: true));
    final group = RemoteAgentToolsGroup(
      runtimes: {
        'server-a': RemoteAgentTools(
          _LocalShellConnection(firstHome),
          workingDirectory: firstHome.path,
        ),
        'server-b': RemoteAgentTools(
          _LocalShellConnection(secondHome),
          workingDirectory: secondHome.path,
        ),
      },
      serverNames: const {'server-a': '构建机', 'server-b': '发布机'},
    );
    addTearDown(group.close);

    final exec = group.tools.singleWhere(
      (tool) => tool.definition.name == 'terminal.exec',
    );
    final required = exec.definition.parameters['required'] as List;
    expect(required, contains('server_id'));
    expect(
      await exec.call({'server_id': 'server-a', 'command': 'printf build'}),
      isA<Map>(),
    );

    final start =
        await group.tools
                .singleWhere((tool) => tool.definition.name == 'terminal.start')
                .call({
                  'server_id': 'server-b',
                  'command': 'sleep 0.05; printf release',
                })
            as Map;
    final processId = start['process_id'] as String;
    expect(processId, startsWith('multi:'));
    final poll =
        await group.tools
                .singleWhere((tool) => tool.definition.name == 'terminal.poll')
                .call({
                  'server_id': 'server-b',
                  'process_id': processId,
                  'wait_ms': 1000,
                })
            as Map;
    expect(poll['server_id'], 'server-b');
    expect(poll['stdout'], 'release');

    await expectLater(
      exec.call({'command': 'printf missing-target'}),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'multi-server transfer streams bytes without using text results',
    () async {
      final source = _TransferConnection(
        files: {
          '/srv/source.bin': [0, 1, 2, 255, 254, 253],
        },
      );
      final destination = _TransferConnection();
      final group = RemoteAgentToolsGroup(
        runtimes: {
          'source': RemoteAgentTools(source, workingDirectory: '/srv'),
          'destination': RemoteAgentTools(
            destination,
            workingDirectory: '/srv',
          ),
        },
      );
      addTearDown(group.close);

      final transfer = group.tools.singleWhere(
        (tool) => tool.definition.name == 'server.transfer',
      );
      final result = await transfer.call({
        'source_server_id': 'source',
        'source_path': 'source.bin',
        'destination_server_id': 'destination',
        'destination_path': 'copy.bin',
      }) as Map;

      expect(result['bytes'], 6);
      expect(destination.files['/srv/copy.bin'], [0, 1, 2, 255, 254, 253]);
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

class _TransferConnection implements SshConnection {
  _TransferConnection({Map<String, List<int>>? files})
    : files = files ?? <String, List<int>>{};

  final Map<String, List<int>> files;
  final _modified = DateTime.utc(2026, 8, 29);
  bool closed = false;

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:transfer',
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
  }) => throw UnimplementedError();

  @override
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) =>
      throw UnimplementedError();

  @override
  Future<SshFileInfo> statPath(String remotePath) async {
    final contents = files[remotePath];
    if (contents == null) throw StateError('missing file: $remotePath');
    return SshFileInfo(
      name: remotePath.split('/').last,
      path: remotePath,
      isDirectory: false,
      isSymbolicLink: false,
      size: contents.length,
      modified: _modified,
    );
  }

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
  Future<String> readFile(String remotePath) async =>
      String.fromCharCodes(await readFileBytes(remotePath));

  @override
  Future<Uint8List> readFileBytes(String remotePath) async {
    final contents = files[remotePath];
    if (contents == null) throw StateError('missing file: $remotePath');
    return Uint8List.fromList(contents);
  }

  @override
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final contents = await readFileBytes(remotePath);
    final start = offset.clamp(0, contents.length).toInt();
    final end = (start + (length ?? contents.length))
        .clamp(start, contents.length)
        .toInt();
    return SshFileBytesChunk(
      offset: offset,
      nextOffset: end,
      bytes: Uint8List.fromList(contents.sublist(start, end)),
      eof: end >= contents.length,
      totalBytes: contents.length,
    );
  }

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
  Future<SshFileUploadSession> prepareFileUpload(
    String remotePath, {
    required String sourceKey,
    required int totalBytes,
    bool overwrite = true,
  }) async {
    final temporaryPath = '$remotePath.part';
    final contents = files.putIfAbsent(temporaryPath, () => <int>[]);
    if (overwrite && files.containsKey(remotePath)) files.remove(remotePath);
    return SshFileUploadSession(
      targetPath: remotePath,
      temporaryPath: temporaryPath,
      metadataPath: '$temporaryPath.meta',
      offset: contents.length,
      totalBytes: totalBytes,
    );
  }

  @override
  Future<void> writeFileBytesChunk(
    String remotePath,
    Uint8List contents, {
    required int offset,
  }) async {
    final target = files.putIfAbsent(remotePath, () => <int>[]);
    while (target.length < offset) {
      target.add(0);
    }
    for (var index = 0; index < contents.length; index++) {
      final targetIndex = offset + index;
      if (targetIndex == target.length) {
        target.add(contents[index]);
      } else {
        target[targetIndex] = contents[index];
      }
    }
  }

  @override
  Future<void> completeFileUpload(SshFileUploadSession session) async {
    final contents = files[session.temporaryPath];
    if (contents == null) throw StateError('missing upload');
    files[session.targetPath] = List<int>.from(contents);
    files.remove(session.temporaryPath);
  }

  @override
  Future<void> writeFile(String remotePath, Uint8List contents) async {
    files[remotePath] = List<int>.from(contents);
  }

  @override
  Future<void> replaceText(String remotePath, String oldText, String newText) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
  }
}
