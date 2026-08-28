import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
import 'package:mobile_agent/domain/models.dart';
import 'package:mobile_agent/local/local_file_access.dart';
import 'package:mobile_agent/local/project_files.dart';
import 'package:mobile_agent/ssh/resumable_file_upload.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';

void main() {
  test('concurrent acquire calls share a replacement connection', () async {
    final pool = TaskSshConnectionPool();
    final initial = _FakeConnection();
    await pool.acquire('task-1', () async => initial);
    initial.closed = true;

    final replacement = _FakeConnection();
    final replacementReady = Future<SshConnection>.value(replacement);
    var connectCalls = 0;

    Future<SshConnection> connect() {
      connectCalls++;
      return replacementReady;
    }

    final first = pool.acquire('task-1', connect);
    final second = pool.acquire('task-1', connect);
    final connections = await Future.wait([first, second]);

    expect(connectCalls, 1);
    expect(connections[0], same(replacement));
    expect(connections[1], same(replacement));
    await pool.close();
  });

  test('closing the pool does not wait for a pending connection', () async {
    final pool = TaskSshConnectionPool();
    final pending = Completer<SshConnection>();
    final connection = _FakeConnection();
    final acquisition = pool.acquire('task-1', () => pending.future);

    await pool.close();
    expect(connection.closed, isFalse);

    pending.complete(connection);
    await expectLater(acquisition, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    expect(connection.closed, isTrue);
  });

  test(
    'file chunk offsets allow large UTF-8 files to be read by pages',
    () async {
      final connection = _FakeConnection(fileContent: '甲乙丙丁');
      final first = await connection.readFileChunk(
        '/tmp/file',
        length: utf8.encode('甲乙').length,
      );
      final second = await connection.readFileChunk(
        '/tmp/file',
        offset: first.nextOffset,
        length: utf8.encode('丙丁').length,
      );

      expect(first.content, '甲乙');
      expect(first.eof, isFalse);
      expect(second.content, '丙丁');
      expect(second.eof, isTrue);
    },
  );

  test('SSH output buffer uses raw UTF-8 byte offsets', () {
    final buffer = SshOutputBuffer(maxCharacters: 10);
    buffer.add('abc');
    buffer.add('12中文de');

    expect(buffer.maxBytes, 10);
    expect(buffer.maxCharacters, 10);
    expect(buffer.length, 13);
    expect(buffer.truncated, isTrue);
    expect(buffer.value, 'abc12\n... 3 bytes omitted ...\n文de');
    expect(buffer.substring(4), '2\n... 3 bytes omitted ...\n文de');
    expect(buffer.substring(6), '\n... 3 bytes omitted ...\n文de');
    // Offsets are raw bytes, so a caller may begin in the middle of a
    // multi-byte character. Lossy decoding preserves the offset instead of
    // silently skipping continuation bytes.
    expect(buffer.substring(9), '��de');
    expect(utf8.decode(utf8.encode(buffer.value)), buffer.value);

    final complete = SshOutputBuffer(maxBytes: 10);
    complete.add('甲乙丙');
    expect(complete.length, 9);
    expect(complete.substring(4), '��丙');

    final rawBoundary = SshOutputBuffer(maxBytes: 4);
    rawBoundary.add('甲乙');
    expect(rawBoundary.value, '�\n... 2 bytes omitted ...\n��');
    expect(rawBoundary.length, 6);
  });

  test('SSH output buffer supports a zero-byte cap', () {
    final buffer = SshOutputBuffer(maxBytes: 0);
    buffer.add('中文');

    expect(buffer.length, 6);
    expect(buffer.truncated, isTrue);
    expect(buffer.value, '\n... 6 bytes omitted ...\n');
    expect(buffer.substring(buffer.length), isEmpty);
  });

  test(
    'SSH output buffer counts raw bytes across chunks and decodes lossily',
    () {
      final buffer = SshOutputBuffer(maxBytes: 10);
      buffer.addBytes([0xe4]);
      buffer.addBytes([0xb8, 0xad, 0xff]);

      expect(buffer.length, 4);
      expect(buffer.value, '中�');
    },
  );

  test('terminate stops after TERM when the session closes', () async {
    final harness = _SessionHarness(closeOnSignal: 'TERM');
    final stream = SshCommandStream(harness.session);

    await stream.terminate(
      termGrace: const Duration(milliseconds: 20),
      killGrace: const Duration(milliseconds: 20),
    );

    expect(harness.signals, ['TERM']);
  });

  test('terminate escalates to KILL after the TERM grace period', () async {
    final harness = _SessionHarness(closeOnSignal: 'KILL');
    final stream = SshCommandStream(harness.session);

    await stream.terminate(
      termGrace: const Duration(milliseconds: 10),
      killGrace: const Duration(milliseconds: 20),
    );

    expect(harness.signals, ['TERM', 'KILL']);
  });

  test('closing a stream wakes an in-flight termination', () async {
    final harness = _SessionHarness();
    final stream = SshCommandStream(harness.session);
    final termination = stream.terminate(
      termGrace: const Duration(seconds: 1),
      killGrace: const Duration(seconds: 1),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    stream.close();
    await termination;

    expect(harness.signals, ['TERM']);
    harness.destroy();
  });

  test(
    'terminal start counts concurrent channel opens in the 64 limit',
    () async {
      final connection = _FakeConnection();
      final tools = RemoteAgentTools(connection);
      final start = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.start',
      );
      final starts = [
        for (var index = 0; index < 64; index++)
          start.call({'command': 'long-running-test'}),
      ];

      await expectLater(
        start.call({'command': 'must-be-rejected'}),
        throwsA(isA<StateError>()),
      );
      expect(connection.pendingExecutes, hasLength(64));

      for (final pending in connection.pendingExecutes) {
        pending.completeError(StateError('test channel open cancelled'));
      }
      await expectLater(
        Future.wait(starts, eagerError: false),
        throwsA(isA<StateError>()),
      );
      await tools.close();
    },
  );

  test('terminal poll exposes an unexpected channel failure', () async {
    final harness = _SessionHarness();
    final connection = _FakeConnection(
      stream: SshCommandStream(harness.session),
    );
    final tools = RemoteAgentTools(connection);
    final start = tools.tools.singleWhere(
      (tool) => tool.definition.name == 'terminal.start',
    );
    final poll = tools.tools.singleWhere(
      (tool) => tool.definition.name == 'terminal.poll',
    );

    final started = await start.call({'command': 'long-running-test'});
    harness.destroy();
    final result = await poll.call({
      'process_id': (started as Map)['process_id'],
      'wait_ms': 1000,
    }) as Map;

    expect(result['done'], isTrue);
    expect(result['failed'], isTrue);
    expect(result['exit_code'], isNull);
    expect(result['error'], contains('without an exit status'));
    await tools.close();
  });

  test('server download to phone preserves binary bytes', () async {
    final root = await Directory.systemTemp.createTemp(
      'mobile-agent-phone-download-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final access = LocalFileAccessStore();
    await access.add(root.path, canWrite: true);
    final connection = _FakeConnection(
      fileBytes: Uint8List.fromList([0, 255, 1, 2, 128, 13, 10]),
    );
    final tools = RemoteAgentTools(connection, localAccess: access);
    final download = tools.tools.singleWhere(
      (tool) => tool.definition.name == 'server.download_to_phone',
    );

    expect(download.requiresUserApproval, isTrue);
    await download.call({
      'remote_path': '/tmp/report.docx',
      'local_path': '${root.path}/report.docx',
    });

    expect(await File('${root.path}/report.docx').readAsBytes(), [
      0,
      255,
      1,
      2,
      128,
      13,
      10,
    ]);
    await tools.close();
  });

  test('free execution downloads directly into the bound project', () async {
    final root = await Directory.systemTemp.createTemp(
      'mobile-agent-project-download-',
    );
    final outside = await Directory.systemTemp.createTemp(
      'mobile-agent-project-download-outside-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final project = Project(
      id: 'project-download',
      name: 'Download project',
      localPath: root.path,
    );
    const files = ProjectFileStore();
    final connection = _FakeConnection(
      fileBytes: Uint8List.fromList([0, 255, 1, 128]),
    );
    final tools = RemoteAgentTools(
      connection,
      project: project,
      projectFiles: files,
      localAccess: LocalFileAccessStore(),
    );
    final download = tools.tools.singleWhere(
      (tool) => tool.definition.name == 'server.download_to_phone',
    );
    final projectArguments = {
      'remote_path': '/tmp/app.bin',
      'local_path': '${root.path}/build/app.bin',
    };

    expect(
      await download.shouldRequestUserApproval(projectArguments, 'auto'),
      isFalse,
    );
    expect(
      await download.shouldRequestUserApproval(projectArguments, 'confirm'),
      isTrue,
    );
    await download.call(projectArguments);
    expect(await File('${root.path}/build/app.bin').readAsBytes(), [
      0,
      255,
      1,
      128,
    ]);
    expect(
      await download.shouldRequestUserApproval({
        'remote_path': '/tmp/app.bin',
        'local_path': '${outside.path}/app.bin',
      }, 'auto'),
      isTrue,
    );
    await Link('${root.path}/escape').create(outside.path);
    expect(
      await download.shouldRequestUserApproval({
        'remote_path': '/tmp/app.bin',
        'local_path': '${root.path}/escape/app.bin',
      }, 'auto'),
      isTrue,
    );
    await expectLater(
      download.call({
        'remote_path': '/tmp/app.bin',
        'local_path': '${root.path}/escape/app.bin',
      }),
      throwsStateError,
    );
    await tools.close();
  });
}

class _SessionHarness {
  _SessionHarness({this.closeOnSignal}) {
    _initialize();
  }

  final String? closeOnSignal;
  final signals = <String>[];
  late final SSHChannelController controller;
  late final SSHSession session;

  void _initialize() {
    controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 32 * 1024,
      localInitialWindowSize: 64 * 1024,
      remoteId: 1,
      remoteMaximumPacketSize: 32 * 1024,
      remoteInitialWindowSize: 64 * 1024,
      sendMessage: (message) {
        if (message is SSH_Message_Channel_Request &&
            message.requestType == SSHChannelRequestType.signal) {
          final signal = message.signalName!;
          signals.add(signal);
          if (signal == closeOnSignal) controller.destroy();
        }
      },
    );
    session = SSHSession(controller.channel);
  }

  void destroy() => controller.destroy();
}

class _FakeConnection implements SshConnection {
  _FakeConnection({this.fileContent = '', this.stream, this.fileBytes});

  final String fileContent;
  final SshCommandStream? stream;
  final Uint8List? fileBytes;
  final pendingExecutes = <Completer<SshCommandStream>>[];

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:test',
  );

  bool closed = false;

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => Future.value();

  @override
  Future<SshCommandStream> execute(
    String command, {
    String? workingDirectory,
    bool pty = false,
  }) async {
    final ready = stream;
    if (ready != null) return ready;
    final pending = Completer<SshCommandStream>();
    pendingExecutes.add(pending);
    return pending.future;
  }

  @override
  Future<SshCommandStream> shell({int width = 80, int height = 24}) async {
    throw UnimplementedError();
  }

  @override
  Future<SshCommandResult> run(
    String command, {
    String? workingDirectory,
    String? input,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) async {
    throw UnimplementedError();
  }

  @override
  Future<String> readFile(String remotePath) async {
    return fileContent;
  }

  @override
  Future<Uint8List> readFileBytes(String remotePath) async {
    return fileBytes ?? Uint8List.fromList(utf8.encode(fileContent));
  }

  @override
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = await readFileBytes(remotePath);
    final start = offset.clamp(0, bytes.length).toInt();
    final requested = length ?? bytes.length;
    final end = (start + requested).clamp(start, bytes.length).toInt();
    return SshFileBytesChunk(
      offset: offset,
      nextOffset: end,
      bytes: Uint8List.fromList(bytes.sublist(start, end)),
      eof: end >= bytes.length,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<SshFileChunk> readFileChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    final bytes = utf8.encode(fileContent);
    final start = offset.clamp(0, bytes.length).toInt();
    final requested = length ?? bytes.length;
    final end = (start + requested).clamp(start, bytes.length).toInt();
    return SshFileChunk(
      offset: offset,
      nextOffset: end,
      content: utf8.decode(bytes.sublist(start, end)),
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
  Future<void> writeFile(String remotePath, Uint8List contents) async {
    throw UnimplementedError();
  }

  @override
  Future<void> replaceText(
    String remotePath,
    String oldText,
    String newText,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
