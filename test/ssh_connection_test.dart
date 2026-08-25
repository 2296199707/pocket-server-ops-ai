import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}

class _FakeConnection implements SshConnection {
  _FakeConnection({this.fileContent = ''});

  final String fileContent;

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
    throw UnimplementedError();
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
