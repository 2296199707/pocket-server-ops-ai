import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as path_util;

import 'resumable_file_upload.dart';

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

class SshFileInfo {
  const SshFileInfo({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.isSymbolicLink,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int? size;
  final DateTime? modified;
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

class SshFileBytesChunk {
  const SshFileBytesChunk({
    required this.offset,
    required this.nextOffset,
    required this.bytes,
    required this.eof,
    this.totalBytes,
  });

  final int offset;
  final int nextOffset;
  final Uint8List bytes;
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
  SSHSessionExitSignal? get exitSignal => _session.exitSignal;
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

  Future<SshFileInfo> statPath(String remotePath) async {
    throw UnsupportedError('当前 SSH 连接不支持文件属性读取');
  }

  Future<void> createDirectory(String remotePath) async {
    throw UnsupportedError('当前 SSH 连接不支持创建文件夹');
  }

  /// Copy one remote file or directory to the exact destination path.
  Future<void> copyPath(String sourcePath, String destinationPath) async {
    throw UnsupportedError('当前 SSH 连接不支持文件复制');
  }

  Future<void> movePath(String sourcePath, String destinationPath) async {
    throw UnsupportedError('当前 SSH 连接不支持文件移动');
  }

  Future<void> renamePath(String sourcePath, String destinationPath) async {
    throw UnsupportedError('当前 SSH 连接不支持文件重命名');
  }

  /// Delete a remote file, link, or directory recursively.
  Future<void> deletePath(String remotePath) async {
    throw UnsupportedError('当前 SSH 连接不支持文件删除');
  }

  Future<String> readFile(String remotePath);

  /// Read a remote file as bytes for a direct download. The caller does not
  /// place these bytes in the AI context.
  Future<Uint8List> readFileBytes(String remotePath);

  /// Read a binary page for resumable downloads. Offsets and lengths are
  /// measured in bytes, and the returned page is safe to append to a local
  /// partial file.
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    final requestedLength = length ?? _defaultFileDownloadChunkBytes;
    if (requestedLength <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    final source = await readFileBytes(remotePath);
    final start = offset.clamp(0, source.length).toInt();
    final end = (start + requestedLength).clamp(start, source.length).toInt();
    return SshFileBytesChunk(
      offset: offset,
      nextOffset: end,
      bytes: Uint8List.fromList(source.sublist(start, end)),
      eof: end >= source.length,
      totalBytes: source.length,
    );
  }

  Future<SshFileUploadSession> prepareFileUpload(
    String remotePath, {
    required String sourceKey,
    required int totalBytes,
    bool overwrite = true,
  }) async {
    throw UnsupportedError('当前 SSH 连接不支持分块上传');
  }

  Future<void> writeFileBytesChunk(
    String remotePath,
    Uint8List contents, {
    required int offset,
  }) async {
    throw UnsupportedError('当前 SSH 连接不支持分块上传');
  }

  Future<void> completeFileUpload(SshFileUploadSession session) async {
    throw UnsupportedError('当前 SSH 连接不支持分块上传');
  }

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
            .listen(stdoutBuffer.addBytes)
            .asFuture<void>();
        final stderrDone = stream.stderr
            .listen(stderrBuffer.addBytes)
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
  Future<SshFileInfo> statPath(String remotePath) async {
    final path = remotePath.trim();
    if (path.isEmpty) throw ArgumentError.value(remotePath, 'remotePath');
    return _withSftp((sftp) async {
      final attributes = await sftp.stat(path, followLink: false);
      final modifyTime = attributes.modifyTime;
      final modified = modifyTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifyTime * 1000, isUtc: true);
      return SshFileInfo(
        name: path == '/' ? '/' : path_util.posix.basename(path),
        path: path,
        isDirectory: attributes.isDirectory,
        isSymbolicLink: attributes.isSymbolicLink,
        size: attributes.size,
        modified: modified,
      );
    });
  }

  @override
  Future<void> createDirectory(String remotePath) async {
    final path = remotePath.trim();
    if (path.isEmpty) throw ArgumentError.value(remotePath, 'remotePath');
    await _withSftp<void>((sftp) => sftp.mkdir(path));
  }

  @override
  Future<void> copyPath(String sourcePath, String destinationPath) async {
    final source = sourcePath.trim();
    final destination = destinationPath.trim();
    if (source.isEmpty) throw ArgumentError.value(sourcePath, 'sourcePath');
    if (destination.isEmpty) {
      throw ArgumentError.value(destinationPath, 'destinationPath');
    }
    await _withSftp<void>((sftp) async {
      final attributes = await sftp.stat(source, followLink: false);
      if (attributes.isDirectory && _isRemotePathWithin(destination, source)) {
        throw StateError('不能把文件夹复制到自身内部');
      }
      await _ensureRemotePathAbsent(sftp, destination);
      await _copySftpPath(sftp, source, destination, attributes);
    });
  }

  @override
  Future<void> movePath(String sourcePath, String destinationPath) async {
    await _renameRemotePathWithSftp(sourcePath, destinationPath);
  }

  @override
  Future<void> renamePath(String sourcePath, String destinationPath) async {
    await _renameRemotePathWithSftp(sourcePath, destinationPath);
  }

  @override
  Future<void> deletePath(String remotePath) async {
    await _withSftp<void>((sftp) => _deleteSftpPath(sftp, remotePath));
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
  Future<SshFileBytesChunk> readFileBytesChunk(
    String remotePath, {
    int offset = 0,
    int? length,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    final requestedLength = length ?? _defaultFileDownloadChunkBytes;
    if (requestedLength <= 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    return _withSftp((sftp) async {
      final file = await sftp.open(remotePath);
      try {
        final size = (await file.stat()).size;
        if (size != null && offset >= size) {
          return SshFileBytesChunk(
            offset: offset,
            nextOffset: offset,
            bytes: Uint8List(0),
            eof: true,
            totalBytes: size,
          );
        }
        final bytes = await file.readBytes(
          length: requestedLength,
          offset: offset,
        );
        final nextOffset = offset + bytes.length;
        return SshFileBytesChunk(
          offset: offset,
          nextOffset: nextOffset,
          bytes: bytes,
          eof: size != null
              ? nextOffset >= size
              : bytes.length < requestedLength,
          totalBytes: size,
        );
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<SshFileUploadSession> prepareFileUpload(
    String remotePath, {
    required String sourceKey,
    required int totalBytes,
    bool overwrite = true,
  }) async {
    final requestedPath = remotePath.trim();
    final normalizedSource = sourceKey.trim();
    if (requestedPath.isEmpty) {
      throw ArgumentError.value(remotePath, 'remotePath');
    }
    if (normalizedSource.isEmpty) {
      throw ArgumentError.value(sourceKey, 'sourceKey');
    }
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes');
    }
    return _withSftp((sftp) async {
      var writePath = requestedPath;
      SftpFileMode? existingMode;
      for (var linkDepth = 0; ; linkDepth++) {
        if (linkDepth >= _maxSymlinkDepth) {
          throw StateError('Remote path contains too many symbolic links');
        }
        final attributes = await _tryStat(sftp, writePath, followLink: false);
        if (attributes == null) break;
        if (attributes.isSymbolicLink) {
          writePath = _resolveSymlinkPath(
            writePath,
            await sftp.readlink(writePath),
          );
          continue;
        }
        if (!attributes.isFile) {
          throw StateError('上传目标不是文件：$remotePath');
        }
        if (!overwrite) {
          throw StateError('上传目标文件已存在：$remotePath');
        }
        existingMode = attributes.mode;
        break;
      }

      final temporaryPath = '$writePath.mobile-agent.part';
      final metadataPath = '$temporaryPath.json';
      final metadata = await _readUploadMetadata(sftp, metadataPath);
      final temporaryAttributes = await _tryStat(sftp, temporaryPath);
      if (temporaryAttributes != null && !temporaryAttributes.isFile) {
        throw StateError('上传临时路径不是文件：$temporaryPath');
      }
      final metadataMatches =
          metadata != null &&
          metadata.sourceKey == normalizedSource &&
          metadata.totalBytes == totalBytes;
      if (!metadataMatches) {
        if (temporaryAttributes != null) {
          await _removeFile(sftp, temporaryPath);
        }
        await _removeFile(sftp, metadataPath);
      }

      var offset = metadataMatches ? (temporaryAttributes?.size ?? 0) : 0;
      if (offset > totalBytes) {
        await _removeFile(sftp, temporaryPath);
        await _removeFile(sftp, metadataPath);
        offset = 0;
      }

      final temporaryFile = await sftp.open(
        temporaryPath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );
      await temporaryFile.close();
      await _writeUploadMetadata(
        sftp,
        metadataPath,
        _RemoteUploadMetadata(
          sourceKey: normalizedSource,
          totalBytes: totalBytes,
        ),
      );
      return SshFileUploadSession(
        targetPath: writePath,
        temporaryPath: temporaryPath,
        metadataPath: metadataPath,
        offset: offset,
        totalBytes: totalBytes,
        existingMode: existingMode?.value,
      );
    });
  }

  @override
  Future<void> writeFileBytesChunk(
    String remotePath,
    Uint8List contents, {
    required int offset,
  }) async {
    if (remotePath.trim().isEmpty) {
      throw ArgumentError.value(remotePath, 'remotePath');
    }
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (contents.isEmpty) return;
    await _withSftp<void>((sftp) async {
      final file = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(contents, offset: offset);
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> completeFileUpload(SshFileUploadSession session) async {
    await _withSftp<void>((sftp) async {
      final attributes = await sftp.stat(session.temporaryPath);
      if (!attributes.isFile || attributes.size != session.totalBytes) {
        throw StateError('文件上传未完成');
      }
      final mode = session.existingMode;
      if (mode != null) {
        await sftp.setStat(
          session.temporaryPath,
          SftpFileAttrs(mode: SftpFileMode.value(mode)),
        );
      }
      // Keep the original target untouched until every chunk is present.
      await sftp.rename(session.temporaryPath, session.targetPath);
      try {
        await sftp.remove(session.metadataPath);
      } catch (_) {
        // The target is already complete; stale metadata is harmless.
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
          content: utf8.decode(contents, allowMalformed: true),
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

  static Future<SftpFileAttrs?> _tryStat(
    SftpClient sftp,
    String path, {
    bool followLink = true,
  }) async {
    try {
      return await sftp.stat(path, followLink: followLink);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  static Future<void> _removeFile(SftpClient sftp, String path) async {
    try {
      await sftp.remove(path);
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) rethrow;
    }
  }

  static Future<void> _deleteSftpPath(SftpClient sftp, String path) async {
    final attributes = await sftp.stat(path, followLink: false);
    if (attributes.isDirectory) {
      final children = await sftp.listdir(path);
      for (final child in children) {
        if (child.filename == '.' || child.filename == '..') continue;
        await _deleteSftpPath(sftp, _joinRemotePath(path, child.filename));
      }
      await sftp.rmdir(path);
      return;
    }
    await sftp.remove(path);
  }

  static Future<void> _renameSftpPath(
    SftpClient sftp,
    String sourcePath,
    String destinationPath,
  ) async {
    final source = sourcePath.trim();
    final destination = destinationPath.trim();
    if (source.isEmpty) throw ArgumentError.value(sourcePath, 'sourcePath');
    if (destination.isEmpty) {
      throw ArgumentError.value(destinationPath, 'destinationPath');
    }
    final sourceAttributes = await sftp.stat(source, followLink: false);
    if (sourceAttributes.isDirectory &&
        _isRemotePathWithin(destination, source)) {
      throw StateError('不能把文件夹移动到自身内部');
    }
    await _ensureRemotePathAbsent(sftp, destination);
    await sftp.rename(source, destination);
  }

  Future<void> _renameRemotePathWithSftp(
    String sourcePath,
    String destinationPath,
  ) async {
    await _withSftp<void>(
      (sftp) => _renameSftpPath(sftp, sourcePath, destinationPath),
    );
  }

  static Future<void> _ensureRemotePathAbsent(
    SftpClient sftp,
    String path,
  ) async {
    if (await _tryStat(sftp, path, followLink: false) != null) {
      throw StateError('目标已存在：$path');
    }
  }

  static bool _isRemotePathWithin(String candidate, String root) {
    final normalizedCandidate = path_util.posix.normalize(candidate);
    final normalizedRoot = path_util.posix.normalize(root);
    if (normalizedRoot == '/') return normalizedCandidate.startsWith('/');
    return normalizedCandidate == normalizedRoot ||
        normalizedCandidate.startsWith('$normalizedRoot/');
  }

  static Future<void> _copySftpPath(
    SftpClient sftp,
    String source,
    String destination,
    SftpFileAttrs attributes,
  ) async {
    if (attributes.isSymbolicLink) {
      throw StateError('暂不支持复制符号链接：$source');
    }
    if (attributes.isDirectory) {
      await sftp.mkdir(destination);
      final children = await sftp.listdir(source);
      for (final child in children) {
        if (child.filename == '.' || child.filename == '..') continue;
        final childSource = _joinRemotePath(source, child.filename);
        final childDestination = _joinRemotePath(destination, child.filename);
        final childAttributes = await sftp.stat(childSource, followLink: false);
        await _copySftpPath(
          sftp,
          childSource,
          childDestination,
          childAttributes,
        );
      }
      return;
    }
    if (!attributes.isFile) {
      throw StateError('暂不支持复制此类型的远程路径：$source');
    }

    final sourceFile = await sftp.open(source);
    SftpFile? destinationFile;
    try {
      destinationFile = await sftp.open(
        destination,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive,
      );
      var offset = 0;
      await for (final chunk in sourceFile.read()) {
        await destinationFile.writeBytes(chunk, offset: offset);
        offset += chunk.length;
      }
    } finally {
      await destinationFile?.close();
      await sourceFile.close();
    }
  }

  static Future<_RemoteUploadMetadata?> _readUploadMetadata(
    SftpClient sftp,
    String path,
  ) async {
    try {
      final file = await sftp.open(path);
      try {
        final decoded = jsonDecode(utf8.decode(await file.readBytes()));
        if (decoded is! Map || decoded['source_key'] is! String) return null;
        final totalBytes = decoded['total_bytes'];
        if (totalBytes is! int) return null;
        return _RemoteUploadMetadata(
          sourceKey: decoded['source_key'] as String,
          totalBytes: totalBytes,
        );
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _writeUploadMetadata(
    SftpClient sftp,
    String path,
    _RemoteUploadMetadata metadata,
  ) async {
    final file = await sftp.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'source_key': metadata.sourceKey,
              'total_bytes': metadata.totalBytes,
            }),
          ),
        ),
      );
    } finally {
      await file.close();
    }
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

class _RemoteUploadMetadata {
  const _RemoteUploadMetadata({
    required this.sourceKey,
    required this.totalBytes,
  });

  final String sourceKey;
  final int totalBytes;
}

const _defaultFileChunkBytes = 64 * 1024;
const _defaultFileDownloadChunkBytes = 512 * 1024;
const _maxSymlinkDepth = 16;
const _sftpTimeout = Duration(minutes: 2);

/// Keeps command output bounded while preserving logical offsets for polling.
/// The beginning and end are retained so a long-running command remains
/// useful to the model without keeping an unbounded string in memory. Capacity
/// and offsets are measured in UTF-8 bytes.
class SshOutputBuffer {
  SshOutputBuffer({int? maxBytes, int? maxCharacters})
    : maxBytes = maxBytes ?? maxCharacters ?? 1024 * 1024,
      assert(
        maxBytes == null || maxCharacters == null || maxBytes == maxCharacters,
        'maxBytes and maxCharacters must match when both are provided',
      ),
      assert((maxBytes ?? maxCharacters ?? 1024 * 1024) >= 0);

  final int maxBytes;

  /// Kept as a compatibility alias for callers using the original name.
  int get maxCharacters => maxBytes;

  late final int _headLimit = maxBytes ~/ 2;
  late final int _tailLimit = maxBytes - _headLimit;

  List<int>? _all = <int>[];
  List<int> _head = <int>[];
  List<int> _tail = <int>[];
  var _length = 0;
  var _truncated = false;

  bool get truncated => _truncated;

  /// Total UTF-8 bytes observed, including bytes omitted from the buffer.
  int get length => _length;

  void add(String value) {
    if (value.isEmpty) return;
    addBytes(utf8.encode(value));
  }

  /// Append output before decoding it so byte offsets remain exact.
  void addBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    _length += bytes.length;
    final all = _all;
    if (!_truncated && all != null) {
      if (all.length + bytes.length <= maxBytes) {
        all.addAll(bytes);
        return;
      }
      _head = _headForAppend(all, bytes);
      _tail = _tailForAppend(all, bytes);
      _all = null;
      _truncated = true;
      return;
    }

    _tail = _tailForAppend(_tail, bytes);
  }

  String get value => substring(0);

  String substring(int start) {
    final offset = start.clamp(0, _length).toInt();
    final all = _all;
    if (!_truncated && all != null) {
      return utf8.decode(all.sublist(offset), allowMalformed: true);
    }
    final tailStart = _length - _tail.length;
    final omitted =
        '\n... ${_length - _head.length - _tail.length} bytes omitted ...\n';
    if (offset < _head.length) {
      return '${utf8.decode(_head.sublist(offset), allowMalformed: true)}'
          '$omitted${utf8.decode(_tail, allowMalformed: true)}';
    }
    if (offset < tailStart) {
      return omitted + utf8.decode(_tail, allowMalformed: true);
    }
    return utf8.decode(_tail.sublist(offset - tailStart), allowMalformed: true);
  }

  List<int> _headForAppend(List<int> previous, List<int> incoming) {
    if (previous.length >= _headLimit) {
      return _prefix(previous, _headLimit);
    }
    final head = <int>[...previous];
    head.addAll(_prefix(incoming, _headLimit - head.length));
    return head;
  }

  List<int> _tailForAppend(List<int> previous, List<int> incoming) {
    if (incoming.length >= _tailLimit) {
      return _suffix(incoming, _tailLimit);
    }
    final tail = _suffix(previous, _tailLimit - incoming.length);
    return <int>[...tail, ...incoming];
  }

  static List<int> _prefix(List<int> bytes, int limit) {
    if (limit <= 0) return <int>[];
    final end = bytes.length < limit ? bytes.length : limit;
    return bytes.sublist(0, end);
  }

  static List<int> _suffix(List<int> bytes, int limit) {
    if (limit <= 0) return <int>[];
    if (bytes.length <= limit) return <int>[...bytes];
    final start = bytes.length - limit;
    return bytes.sublist(start);
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
