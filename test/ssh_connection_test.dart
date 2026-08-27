import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/agent_tools.dart';
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
    'terminal start counts concurrent channel opens in the 32 limit',
    () async {
      final connection = _FakeConnection();
      final tools = RemoteAgentTools(connection);
      final start = tools.tools.singleWhere(
        (tool) => tool.definition.name == 'terminal.start',
      );
      final starts = [
        for (var index = 0; index < 32; index++)
          start.call({'command': 'long-running-test'}),
      ];

      await expectLater(
        start.call({'command': 'must-be-rejected'}),
        throwsA(isA<StateError>()),
      );
      expect(connection.pendingExecutes, hasLength(32));

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
  _FakeConnection({this.fileContent = ''});

  final String fileContent;
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
    return Uint8List.fromList(utf8.encode(fileContent));
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
