import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/remote_instructions.dart';
import 'package:mobile_agent/ssh/ssh_connection.dart';

void main() {
  test(
    'loads project instructions from root to cwd with override precedence',
    () async {
      final connection = _InstructionsConnection(
        directories: {
          '/workspace/app': [
            const SshDirectoryEntry(
              name: 'AGENTS.md',
              path: '/workspace/app/AGENTS.md',
              isDirectory: false,
              size: 20,
            ),
            const SshDirectoryEntry(
              name: 'AGENTS.override.md',
              path: '/workspace/app/AGENTS.override.md',
              isDirectory: false,
              size: 28,
            ),
          ],
          '/workspace': [
            const SshDirectoryEntry(
              name: '.git',
              path: '/workspace/.git',
              isDirectory: true,
              size: null,
            ),
            const SshDirectoryEntry(
              name: 'AGENTS.md',
              path: '/workspace/AGENTS.md',
              isDirectory: false,
              size: 12,
            ),
          ],
        },
        files: const {
          '/workspace/AGENTS.md': 'root instructions',
          '/workspace/app/AGENTS.override.md': 'app override',
          '/workspace/app/AGENTS.md': 'app fallback',
        },
      );

      final result = await const RemoteProjectInstructions().load(
        connection,
        '/workspace/app',
      );

      expect(result, 'root instructions\n\napp override');
      expect(connection.readPaths, [
        '/workspace/AGENTS.md',
        '/workspace/app/AGENTS.override.md',
      ]);
    },
  );

  test(
    'without a git marker only the selected directory contributes',
    () async {
      final connection = _InstructionsConnection(
        directories: {
          '/workspace/app': [
            const SshDirectoryEntry(
              name: 'AGENTS.md',
              path: '/workspace/app/AGENTS.md',
              isDirectory: false,
              size: 12,
            ),
          ],
          '/workspace': [
            const SshDirectoryEntry(
              name: 'AGENTS.md',
              path: '/workspace/AGENTS.md',
              isDirectory: false,
              size: 12,
            ),
          ],
        },
        files: const {
          '/workspace/AGENTS.md': 'parent',
          '/workspace/app/AGENTS.md': 'current',
        },
      );

      final result = await const RemoteProjectInstructions().load(
        connection,
        '/workspace/app',
      );

      expect(result, 'current');
      expect(connection.readPaths, ['/workspace/app/AGENTS.md']);
    },
  );

  test('instruction byte budget stops at a UTF-8 boundary', () async {
    final content = '${'a' * (RemoteProjectInstructions.maxBytes - 1)}中后续';
    final connection = _InstructionsConnection(
      directories: {
        '/workspace/app': [
          const SshDirectoryEntry(
            name: 'AGENTS.md',
            path: '/workspace/app/AGENTS.md',
            isDirectory: false,
            size: null,
          ),
        ],
      },
      files: {'/workspace/app/AGENTS.md': content},
    );

    final result = await const RemoteProjectInstructions().load(
      connection,
      '/workspace/app',
    );

    expect(
      utf8.encode(result!),
      hasLength(RemoteProjectInstructions.maxBytes - 1),
    );
  });
}

class _InstructionsConnection implements SshConnection {
  _InstructionsConnection({required this.directories, required this.files});

  final Map<String, List<SshDirectoryEntry>> directories;
  final Map<String, String> files;
  final readPaths = <String>[];

  @override
  final hostKey = const SshHostKey(
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:test',
  );

  @override
  bool get isClosed => false;

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
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) async {
    return directories[remotePath] ?? const [];
  }

  @override
  Future<String> readFile(String remotePath) async => files[remotePath]!;

  @override
  Future<Uint8List> readFileBytes(String remotePath) async =>
      Uint8List.fromList(utf8.encode(files[remotePath]!));

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
    readPaths.add(remotePath);
    final content = files[remotePath]!;
    return SshFileChunk(
      offset: offset,
      nextOffset: utf8.encode(content).length,
      content: content,
      eof: true,
      totalBytes: utf8.encode(content).length,
    );
  }

  @override
  Future<void> writeFile(String remotePath, Uint8List contents) =>
      throw UnimplementedError();

  @override
  Future<void> replaceText(String remotePath, String oldText, String newText) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}
