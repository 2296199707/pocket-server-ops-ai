import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path_util;

class SshHostKey {
  const SshHostKey({required this.type, required this.fingerprint});

  final String type;
  final String fingerprint;
}

class SshUserInfoPrompt {
  const SshUserInfoPrompt({required this.text, required this.echo});

  final String text;
  final bool echo;
}

class SshUserInfoRequest {
  const SshUserInfoRequest({
    required this.name,
    required this.instruction,
    required this.prompts,
  });

  final String name;
  final String instruction;
  final List<SshUserInfoPrompt> prompts;
}

typedef SshUserInfoHandler = FutureOr<List<String>?> Function(
  SshUserInfoRequest request,
);

class SshConnectionConfig {
  const SshConnectionConfig({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
    this.privateKeyPassphrase,
    this.expectedFingerprint,
    this.onFirstHostKey,
    this.onUserInfoRequest,
    this.timeout = const Duration(seconds: 15),
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;
  final String? expectedFingerprint;
  final FutureOr<bool> Function(SshHostKey key)? onFirstHostKey;
  final SshUserInfoHandler? onUserInfoRequest;
  final Duration timeout;
}

class SshCommandResult {
  const SshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  String get output => '$stdout$stderr';
}

class SshCommandTimeout implements Exception {
  const SshCommandTimeout(this.timeout);

  final Duration timeout;

  @override
  String toString() =>
      'SSH command timed out after ${timeout.inSeconds} seconds';
}

class SshOperationTimeout implements Exception {
  const SshOperationTimeout(this.timeout);

  final Duration timeout;

  @override
  String toString() =>
      'SSH operation timed out after ${timeout.inSeconds} seconds';
}

class SshDirectoryEntry {
  const SshDirectoryEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
}

class SshFileChunk {
  const SshFileChunk({
    required this.offset,
    required this.nextOffset,
    required this.content,
    required this.eof,
    this.totalBytes,
  });

  final int offset;
  final int nextOffset;
  final String content;
  final bool eof;
  final int? totalBytes;
}

class SshCommandStream {
  SshCommandStream(this._session) {
    unawaited(_session.done.then((_) => _sessionDone = true));
  }

  final SSHSession _session;
  var _sessionDone = false;
  var _closed = false;

  Stream<Uint8List> get stdout => _session.stdout;
  Stream<Uint8List> get stderr => _session.stderr;
  int? get exitCode => _session.exitCode;
  Future<void> get done => _session.done;

  void write(Uint8List data) => _session.write(data);

  void writeText(String value) {
    write(Uint8List.fromList(utf8.encode(value)));
  }

  Future<void> closeInput() => _session.stdin.close();

  void resizeTerminal(int width, int height) {
    _session.resizeTerminal(width, height);
  }

  void stop() {
    if (_closed || _sessionDone) return;
    try {
      _session.kill(SSHSignal.TERM);
    } catch (_) {
      // The process may have closed between the state check and the signal.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _session.close();
    } catch (_) {
      // Closing an already finished session is safe for the caller.
    }
  }
}

abstract class SshConnection {
  SshHostKey get hostKey;
  bool get isClosed;
  Future<void> get done;

  Future<SshCommandStream> execute(
    String command, {
    String? workingDirectory,
    bool pty = false,
  });

  Future<SshCommandStream> shell({int width = 80, int height = 24});

  Future<SshCommandResult> run(
    String command, {
    String? workingDirectory,
    String? input,
    Duration timeout = const Duration(minutes: 2),
  });

  Future<List<SshDirectoryEntry>> listDirectory(String remotePath);

  Future<String> readFile(String remotePath);

  /// Read a UTF-8 page. Offsets and lengths are bytes, so callers can fetch
  /// arbitrarily large files without putting the whole file in one tool
  /// result. The default implementation reads through [readFile], while the
  /// SFTP connection overrides it with byte-range reads.
  Future<SshFileChunk> readFileChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    final requestedLength = length ?? _defaultFileChunkBytes;
    if (requestedLength <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    final source = Uint8List.fromList(utf8.encode(await readFile(remotePath)));
    final start = offset < source.length ? offset : source.length;
    var end = (start + requestedLength).clamp(start, source.length).toInt();
    while (end > start) {
      try {
        utf8.decode(source.sublist(start, end));
        break;
      } on FormatException {
        end--;
      }
    }
    return SshFileChunk(
      offset: offset,
      nextOffset: end,
      content: utf8.decode(source.sublist(start, end)),
      eof: end >= source.length,
      totalBytes: source.length,
    );
  }

  Future<void> writeFile(String remotePath, Uint8List contents);

  Future<void> replaceText(String remotePath, String oldText, String newText);

  Future<void> close();
}

abstract class SshConnector {
  Future<SshConnection> connect(SshConnectionConfig config);
}

class DartSshConnector implements SshConnector {
  @override
  Future<SshConnection> connect(SshConnectionConfig config) {
    return DartSshConnection.connect(config);
  }
}

class DartSshConnection implements SshConnection {
  DartSshConnection._(this._client, this.hostKey);

  final SSHClient _client;
  Future<void>? _closeFuture;

  @override
  final SshHostKey hostKey;

  static Future<DartSshConnection> connect(SshConnectionConfig config) async {
    final socket = await SSHSocket.connect(
      config.host,
      config.port,
      timeout: config.timeout,
    );
    SSHClient? client;
    SshHostKey? observedHostKey;
    try {
      final identities = config.privateKeyPem == null
          ? null
          : SSHKeyPair.fromPem(
              config.privateKeyPem!,
              config.privateKeyPassphrase,
            );
      client = SSHClient(
        socket,
        username: config.username,
        identities: identities,
        onPasswordRequest: config.password == null
            ? null
            : () => config.password,
        onUserInfoRequest:
            config.onUserInfoRequest == null && config.password == null
            ? null
            : (request) async {
                final handler = config.onUserInfoRequest;
                if (handler != null) {
                  return handler(
                    SshUserInfoRequest(
                      name: request.name,
                      instruction: request.instruction,
                      prompts: [
                        for (final prompt in request.prompts)
                          SshUserInfoPrompt(
                            text: prompt.promptText,
                            echo: prompt.echo,
                          ),
                      ],
                    ),
                  );
                }
                if (config.password != null && request.prompts.length == 1) {
                  return [config.password!];
                }
                return null;
              },
        onVerifyHostKey: (type, fingerprint) async {
          final key = SshHostKey(
            type: type,
            fingerprint: utf8.decode(fingerprint),
          );
          observedHostKey = key;
          final expected = config.expectedFingerprint;
          if (expected != null) {
            return key.fingerprint == expected;
          }
          final trust = config.onFirstHostKey;
          return trust != null ? await trust(key) : false;
        },
        handshakeTimeout: config.timeout,
        authTimeout: config.timeout,
      );
      await client.authenticated;
      final key = observedHostKey;
      if (key == null) {
        await client.close();
        throw StateError('SSH server did not provide a host key');
      }
      return DartSshConnection._(client, key);
    } catch (_) {
      try {
        await client?.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        socket.destroy();
      }
      socket.destroy();
      rethrow;
    }
  }

  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<void> get done => _client.done;

  @override
  Future<SshCommandStream> execute(
    String command, {
    String? workingDirectory,
    bool pty = false,
  }) async {
    final fullCommand = _withWorkingDirectory(command, workingDirectory);
    final session = await _client.execute(
      fullCommand,
      pty: pty ? const SSHPtyConfig() : null,
    );
    return SshCommandStream(session);
  }

  @override
  Future<SshCommandStream> shell({int width = 80, int height = 24}) async {
    final session = await _client.shell(
      pty: SSHPtyConfig(width: width, height: height),
    );
    return SshCommandStream(session);
  }

  @override
  Future<SshCommandResult> run(
    String command, {
    String? workingDirectory,
    String? input,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    SshCommandStream? activeStream;
    var timedOut = false;
    try {
      return await (() async {
        final stream = await execute(
          command,
          workingDirectory: workingDirectory,
        );
        if (timedOut) {
          try {
            stream.stop();
          } catch (_) {}
          stream.close();
          throw SshCommandTimeout(timeout);
        }
        activeStream = stream;
        final stdoutBuffer = _TextBuffer();
        final stderrBuffer = _TextBuffer();
        final stdoutDone = stream.stdout
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(stdoutBuffer.add)
            .asFuture<void>();
        final stderrDone = stream.stderr
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(stderrBuffer.add)
            .asFuture<void>();
        if (input != null) stream.writeText(input);
        await stream.closeInput();
        await Future.wait([stdoutDone, stderrDone]);
        await stream.done;
        return SshCommandResult(
          stdout: stdoutBuffer.value,
          stderr: stderrBuffer.value,
          exitCode: stream.exitCode,
          stdoutTruncated: stdoutBuffer.truncated,
          stderrTruncated: stderrBuffer.truncated,
        );
      }()).timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        activeStream?.stop();
      } catch (_) {}
      try {
        activeStream?.close();
      } catch (_) {}
      if (activeStream == null) unawaited(close());
      throw SshCommandTimeout(timeout);
    } catch (_) {
      activeStream?.close();
      rethrow;
    }
  }

  @override
  Future<List<SshDirectoryEntry>> listDirectory(String remotePath) async {
    return _withSftp((sftp) async {
      final entries = await sftp.listdir(remotePath);
      final result = [
        for (final entry in entries)
          if (entry.filename != '.' && entry.filename != '..')
            SshDirectoryEntry(
              name: entry.filename,
              path: _joinRemotePath(remotePath, entry.filename),
              isDirectory: entry.attr.isDirectory,
              size: entry.attr.size,
            ),
      ];
      result.sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.compareTo(right.name);
      });
      return result;
    });
  }

  @override
  Future<String> readFile(String remotePath) async {
    return _withSftp((sftp) async {
      final file = await sftp.open(remotePath);
      try {
        final contents = await file.readBytes();
        return utf8.decode(contents);
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<SshFileChunk> readFileChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    final requestedLength = length ?? _defaultFileChunkBytes;
    if (requestedLength <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    return _withSftp((sftp) async {
      final file = await sftp.open(remotePath);
      try {
        final size = (await file.stat()).size;
        if (size != null && offset >= size) {
          return SshFileChunk(
            offset: offset,
            nextOffset: offset,
            content: '',
            eof: true,
            totalBytes: size,
          );
        }
        // Read a few extra bytes so a UTF-8 code point split at the page
        // boundary is returned whole. The next offset advances past them.
        final contents = await file.readBytes(
          length: requestedLength + 3,
          offset: offset,
        );
        final nextOffset = offset + contents.length;
        return SshFileChunk(
          offset: offset,
          nextOffset: nextOffset,
          content: utf8.decode(contents),
          eof: size != null
              ? nextOffset >= size
              : contents.length < requestedLength + 3,
          totalBytes: size,
        );
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> writeFile(String remotePath, Uint8List contents) async {
    await _withSftp<void>((sftp) async {
      String? temporaryPath;
      var committed = false;
      var writePath = remotePath;
      SftpFileMode? existingMode;
      try {
        for (var linkDepth = 0; ; linkDepth++) {
          if (linkDepth >= _maxSymlinkDepth) {
            throw StateError('Remote path contains too many symbolic links');
          }
          SftpFileAttrs attributes;
          try {
            attributes = await sftp.stat(writePath, followLink: false);
          } on SftpStatusError catch (error) {
            if (error.code != SftpStatusCode.noSuchFile) rethrow;
            break;
          }
          if (!attributes.isSymbolicLink) {
            existingMode = attributes.mode;
            break;
          }
          writePath = _resolveSymlinkPath(
            writePath,
            await sftp.readlink(writePath),
          );
        }
        final temporaryFilePath =
            '$writePath.mobile-agent-${DateTime.now().microsecondsSinceEpoch}.tmp';
        temporaryPath = temporaryFilePath;
        final file = await sftp.open(
          temporaryFilePath,
          mode:
              SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        try {
          await file.writeBytes(contents);
        } finally {
          await file.close();
        }
        if (existingMode != null) {
          await sftp.setStat(
            temporaryFilePath,
            SftpFileAttrs(mode: existingMode),
          );
        }
        try {
          await sftp.rename(temporaryFilePath, writePath);
        } on SftpStatusError {
          // Some SFTP servers do not support replacing an existing path with
          // the standard rename operation. The resolved target is safe to
          // update directly and still preserves symbolic-link semantics.
          final directFile = await sftp.open(
            writePath,
            mode: SftpFileOpenMode.write | SftpFileOpenMode.truncate,
          );
          try {
            await directFile.writeBytes(contents);
          } finally {
            await directFile.close();
          }
          await sftp.remove(temporaryFilePath);
        }
        committed = true;
      } finally {
        if (!committed && temporaryPath != null) {
          try {
            await sftp.remove(temporaryPath);
          } catch (_) {
            // The temporary file may not have been created.
          }
        }
      }
    });
  }

  @override
  Future<void> replaceText(
    String remotePath,
    String oldText,
    String newText,
  ) async {
    if (oldText.isEmpty) {
      throw ArgumentError.value(oldText, 'oldText', 'must not be empty');
    }
    final current = await readFile(remotePath);
    if (_countOccurrences(current, oldText) != 1) {
      throw StateError('replaceText requires exactly one matching block');
    }
    await writeFile(
      remotePath,
      Uint8List.fromList(utf8.encode(current.replaceFirst(oldText, newText))),
    );
  }

  @override
  Future<void> close() => _closeFuture ??= _client.close();

  Future<T> _withSftp<T>(Future<T> Function(SftpClient sftp) operation) async {
    SftpClient? sftp;
    try {
      sftp = await _client.sftp().timeout(_sftpTimeout);
      return await operation(sftp).timeout(_sftpTimeout);
    } on TimeoutException {
      if (sftp == null) {
        unawaited(close());
      }
      throw SshOperationTimeout(_sftpTimeout);
    } finally {
      final activeSftp = sftp;
      if (activeSftp != null) {
        try {
          await activeSftp.close().timeout(const Duration(seconds: 2));
        } catch (_) {
          // The SSH connection may already be closing after a timeout.
        }
      }
    }
  }

  static String _withWorkingDirectory(String command, String? directory) {
    if (directory == null || directory.isEmpty) return command;
    return 'cd ${_quote(directory)} && $command';
  }

  static String _quote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static int _countOccurrences(String value, String needle) {
    var count = 0;
    var offset = 0;
    while (true) {
      final index = value.indexOf(needle, offset);
      if (index < 0) return count;
      count++;
      offset = index + needle.length;
    }
  }

  static String _resolveSymlinkPath(String linkPath, String target) {
    if (path_util.posix.isAbsolute(target)) {
      return path_util.posix.normalize(target);
    }
    return path_util.posix.normalize(
      path_util.posix.join(path_util.posix.dirname(linkPath), target),
    );
  }
}

const _defaultFileChunkBytes = 64 * 1024;
const _maxSymlinkDepth = 16;
const _sftpTimeout = Duration(minutes: 2);

class _TextBuffer {
  final StringBuffer _buffer = StringBuffer();

  bool get truncated => false;

  void add(String value) {
    _buffer.write(value);
  }

  String get value => _buffer.toString();
}

String _joinRemotePath(String directory, String name) {
  if (directory.isEmpty || directory == '.') return name;
  if (directory == '/') return '/$name';
  return '${directory.replaceFirst(RegExp(r'/+$'), '')}/$name';
}

class TaskSshConnectionPool {
  final Map<String, Future<SshConnection>> _connections = {};

  Future<SshConnection> acquire(
    String taskId,
    Future<SshConnection> Function() connect,
  ) async {
    while (true) {
      final existing = _connections[taskId];
      if (existing != null) {
        final connection = await existing;
        if (!connection.isClosed) return connection;
        if (!identical(_connections[taskId], existing)) continue;
        _connections.remove(taskId);
      }

      final pending = connect();
      _connections[taskId] = pending;
      try {
        return await pending;
      } catch (_) {
        if (identical(_connections[taskId], pending)) {
          _connections.remove(taskId);
        }
        rethrow;
      }
    }
  }

  void abort(String taskId) {
    final pending = _connections.remove(taskId);
    if (pending == null) return;
    unawaited(
      pending.then<void>(
        (connection) => connection.close(),
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
  }

  Future<void> release(String taskId) async {
    final pending = _connections.remove(taskId);
    final connection = await pending;
    await connection?.close();
  }

  Future<void> close() async {
    final taskIds = _connections.keys.toList();
    for (final taskId in taskIds) {
      await release(taskId);
    }
  }
}
