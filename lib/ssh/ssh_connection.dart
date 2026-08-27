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
    unawaited(
      _session.done.then<void>(
        (_) => _sessionDone = true,
        onError: (Object error, StackTrace stackTrace) {
          // A failed channel is no longer usable and must not leave
          // termination waiting for a completion that will never arrive.
          _sessionDone = true;
        },
      ),
    );
  }

  final SSHSession _session;
  var _sessionDone = false;
  var _closed = false;
  Future<void>? _termination;
  final _closedSignal = Completer<void>();

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

  /// Ask the remote command to exit, then force the channel down if it does
  /// not report completion promptly. Closing an SSH channel alone does not
  /// reliably stop a child process on every server.
  Future<void> terminate({
    Duration termGrace = const Duration(seconds: 2),
    Duration killGrace = const Duration(seconds: 1),
  }) {
    final existing = _termination;
    if (existing != null) return existing;
    final future = _terminate(termGrace: termGrace, killGrace: killGrace);
    _termination = future;
    return future;
  }

  Future<void> _terminate({
    required Duration termGrace,
    required Duration killGrace,
  }) async {
    if (_closed || _sessionDone) return;
    stop();
    await _waitForDone(termGrace);
    if (!_sessionDone && !_closed) {
      try {
        _session.kill(SSHSignal.KILL);
      } catch (_) {
        // The session can close between the TERM and KILL signals.
      }
      await _waitForDone(killGrace);
    }
    if (!_sessionDone) close();
  }

  Future<void> _waitForDone(Duration timeout) async {
    if (_sessionDone || _closed) return;
    try {
      await Future.any<void>([_session.done, _closedSignal.future])
          .timeout(timeout);
      if (!_closed) _sessionDone = true;
    } on TimeoutException {
      // The caller will escalate to SIGKILL after the grace period.
    } catch (_) {
      // A failed session is already unusable and must be treated as done.
      _sessionDone = true;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
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

  /// Read a remote file as bytes for a direct download. The caller does not
  /// place these bytes in the AI context.
  Future<Uint8List> readFileBytes(String remotePath);

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
            await stream.terminate();
          } catch (_) {}
          throw SshCommandTimeout(timeout);
        }
        activeStream = stream;
        final stdoutBuffer = SshOutputBuffer();
        final stderrBuffer = SshOutputBuffer();
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
        await activeStream?.terminate();
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
  Future<Uint8List> readFileBytes(String remotePath) async {
    return _withSftp((sftp) async {
      final file = await sftp.open(remotePath);
      try {
        return await file.readBytes();
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
        // Never fall back to truncating the target in place. If this server
        // cannot replace an existing path with rename, fail while the
        // original file is still intact.
        await sftp.rename(temporaryFilePath, writePath);
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

/// Keeps command output bounded while preserving logical offsets for polling.
/// The beginning and end are retained so a long-running command remains
/// useful to the model without keeping an unbounded string in memory.
class SshOutputBuffer {
  SshOutputBuffer({this.maxCharacters = 1024 * 1024})
    : assert(maxCharacters > 0);

  final int maxCharacters;
  late final int _headLimit = maxCharacters ~/ 2;
  late final int _tailLimit = maxCharacters - _headLimit;

  StringBuffer? _all = StringBuffer();
  String _head = '';
  String _tail = '';
  var _length = 0;
  var _truncated = false;

  bool get truncated => _truncated;
  int get length => _length;

  void add(String value) {
    if (value.isEmpty) return;
    _length += value.length;
    final all = _all;
    if (!_truncated && all != null) {
      if (all.length + value.length <= maxCharacters) {
        all.write(value);
        return;
      }
      final existing = all.toString();
      _head = existing.substring(
        0,
        existing.length < _headLimit ? existing.length : _headLimit,
      );
      final tailSource = value.length >= _tailLimit ? value : '$existing$value';
      _tail = _last(tailSource, _tailLimit);
      _all = null;
      _truncated = true;
      return;
    }

    _tail = _last('$_tail$value', _tailLimit);
  }

  String get value => substring(0);

  String substring(int start) {
    final offset = start.clamp(0, _length).toInt();
    final all = _all;
    if (!_truncated && all != null) {
      return all.toString().substring(offset);
    }
    final tailStart = _length - _tail.length;
    const omitted = '\n[…输出中间部分已省略…]\n';
    if (offset < _head.length) {
      return '${_head.substring(offset)}$omitted$_tail';
    }
    if (offset < tailStart) return omitted + _tail;
    return _tail.substring(offset - tailStart);
  }

  static String _last(String value, int length) {
    if (value.length <= length) return value;
    return value.substring(value.length - length);
  }
}

String _joinRemotePath(String directory, String name) {
  if (directory.isEmpty || directory == '.') return name;
  if (directory == '/') return '/$name';
  return '${directory.replaceFirst(RegExp(r'/+$'), '')}/$name';
}

class TaskSshConnectionPool {
  final Map<String, Future<SshConnection>> _connections = {};
  final Set<String> _pendingConnections = {};

  Future<SshConnection> acquire(
    String taskId,
    Future<SshConnection> Function() connect,
  ) async {
    while (true) {
      final existing = _connections[taskId];
      if (existing != null) {
        final connection = await existing;
        if (!identical(_connections[taskId], existing)) {
          if (_connections[taskId] == null) {
            throw StateError('SSH connection acquisition was aborted');
          }
          continue;
        }
        if (!connection.isClosed) return connection;
        _connections.remove(taskId);
      }

      final pending = connect();
      _connections[taskId] = pending;
      _pendingConnections.add(taskId);
      try {
        final connection = await pending;
        _pendingConnections.remove(taskId);
        if (!identical(_connections[taskId], pending)) {
          await connection.close();
          throw StateError('SSH connection acquisition was aborted');
        }
        return connection;
      } catch (_) {
        _pendingConnections.remove(taskId);
        if (identical(_connections[taskId], pending)) {
          _connections.remove(taskId);
        }
        rethrow;
      }
    }
  }

  void abort(String taskId) {
    final pending = _connections.remove(taskId);
    _pendingConnections.remove(taskId);
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
    _pendingConnections.remove(taskId);
    final connection = await pending;
    await connection?.close();
  }

  Future<void> close() async {
    final taskIds = _connections.keys.toList();
    final established = <Future<void>>[];
    for (final taskId in taskIds) {
      final pending = _connections.remove(taskId);
      final isPending = _pendingConnections.remove(taskId);
      if (pending == null) continue;
      final closing = pending.then<void>(
        (connection) => connection.close(),
        onError: (Object error, StackTrace stackTrace) {},
      );
      if (isPending) {
        // A connector may be waiting on a socket timeout. Do not make app
        // shutdown wait for that timeout; close the connection if it ever
        // arrives.
        unawaited(closing);
      } else {
        established.add(closing);
      }
    }
    await Future.wait(established, eagerError: false);
  }
}
