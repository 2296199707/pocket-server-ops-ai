import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path_util;

import '../domain/models.dart';
import '../local/document_export.dart';
import '../local/local_file_access.dart';
import '../local/local_preview.dart';
import '../local/project_files.dart';
import '../ssh/resumable_file_download.dart';
import '../ssh/resumable_file_upload.dart';
import '../ssh/remote_process.dart';
import '../ssh/ssh_connection.dart';
import 'ai_protocol.dart';

class AgentTool {
  const AgentTool({
    required this.definition,
    required this.call,
    this.callWithOperationStart,
    this.userApprovalRequired,
    this.requiresConfirmation = true,
    this.requiresUserApproval = false,
    this.isRemote = false,
    this.writesRemoteState = false,
  });

  final AiToolDefinition definition;
  final Future<Object?> Function(Map<String, Object?> arguments) call;

  /// Optional form used by queued remote writes. The callback must be called
  /// immediately before the operation that can change remote state starts.
  final Future<Object?> Function(
    Map<String, Object?> arguments,
    void Function() onOperationStarted,
  )?
  callWithOperationStart;
  final bool requiresConfirmation;

  /// Requests that change the app's technical boundary always need the user.
  final bool requiresUserApproval;

  /// Optional parameter-aware override for tools whose approval requirement
  /// depends on the requested path or execution mode.
  final FutureOr<bool> Function(
    Map<String, Object?> arguments,
    String executionMode,
  )?
  userApprovalRequired;

  FutureOr<bool> shouldRequestUserApproval(
    Map<String, Object?> arguments,
    String executionMode,
  ) {
    return userApprovalRequired?.call(arguments, executionMode) ??
        requiresUserApproval;
  }

  /// Whether executing this tool contacts or operates on the selected server.
  /// Read-only remote tools use this flag without setting
  /// [writesRemoteState].
  final bool isRemote;
  final bool writesRemoteState;
}

class RemoteAgentTools {
  RemoteAgentTools(
    SshConnection connection, {
    this.workingDirectory,
    this.project,
    this.projectFiles,
    this.localAccess,
    this.reconnect,
    this.remoteTaskRecoveryEnabled = true,
  }) : _connection = connection {
    _processController = RemoteProcessController(
      connection,
      reconnect: reconnect,
      onConnectionChanged: (value) => _connection = value,
    );
  }

  SshConnection _connection;
  final String? workingDirectory;
  Project? project;
  ProjectFileStore? projectFiles;
  LocalFileAccessStore? localAccess;
  final RemoteConnectionReconnector? reconnect;
  bool remoteTaskRecoveryEnabled;
  late final RemoteProcessController _processController;
  final Map<String, _ManagedProcess> _processes = {};
  final List<Future<SshCommandStream>> _startingProcesses = [];
  Future<void>? _closeFuture;
  var _closing = false;

  bool get isClosed => _closing;

  SshConnection get connection => _connection;

  void updateConnection(SshConnection connection) {
    _connection = connection;
    _processController.updateConnection(connection);
  }

  void setRemoteTaskRecoveryEnabled(bool enabled) {
    remoteTaskRecoveryEnabled = enabled;
  }

  void configureContext({
    required Project? project,
    required ProjectFileStore? projectFiles,
    required LocalFileAccessStore? localAccess,
  }) {
    this.project = project;
    this.projectFiles = projectFiles;
    this.localAccess = localAccess;
  }

  List<AgentTool> get tools => [
    AgentTool(
      definition: AiToolDefinition(
        name: 'terminal.exec',
        description: remoteTaskRecoveryEnabled
            ? 'Run a short shell command on the selected server with a '
                  'two-minute timeout. The command is recorded as a remote job '
                  'so a broken SSH channel can be reopened without running it '
                  'twice.'
            : 'Run a short shell command on the selected server with a '
                  'two-minute timeout on the current SSH connection. If the '
                  'connection breaks, do not replay the command.',
        parameters: {
          'type': 'object',
          'required': ['command'],
          'properties': {
            'command': {'type': 'string'},
            'working_directory': {'type': 'string'},
            'input': {'type': 'string'},
          },
        },
      ),
      call: _exec,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: AiToolDefinition(
        name: 'terminal.start',
        description: remoteTaskRecoveryEnabled
            ? 'Start a long-running shell command. Non-PTY jobs keep a remote '
                  'process record and can be polled after reconnecting.'
            : 'Start a long-running shell command on the current SSH '
                  'connection. The process cannot be recovered after a '
                  'connection break.',
        parameters: {
          'type': 'object',
          'required': ['command'],
          'properties': {
            'command': {'type': 'string'},
            'working_directory': {'type': 'string'},
            'pty': {'type': 'boolean'},
          },
        },
      ),
      call: _start,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.poll',
        description:
            'Read output and status of a long-running command. Pass the '
            'returned offsets to receive only new output on the next poll. '
            'Optionally wait up to 30 seconds for new output or completion.',
        parameters: {
          'type': 'object',
          'required': ['process_id'],
          'properties': {
            'process_id': {'type': 'string'},
            'stdout_offset': {'type': 'integer', 'minimum': 0},
            'stderr_offset': {'type': 'integer', 'minimum': 0},
            'wait_ms': {
              'type': 'integer',
              'minimum': 0,
              'maximum': _maxPollWaitMilliseconds,
            },
          },
        },
      ),
      call: _poll,
      requiresConfirmation: false,
      isRemote: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.write',
        description: 'Write stdin to a long-running command.',
        parameters: {
          'type': 'object',
          'required': ['process_id', 'input'],
          'properties': {
            'process_id': {'type': 'string'},
            'input': {'type': 'string'},
          },
        },
      ),
      call: _write,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.stop',
        description: 'Stop a long-running command.',
        parameters: {
          'type': 'object',
          'required': ['process_id'],
          'properties': {
            'process_id': {'type': 'string'},
          },
        },
      ),
      call: _stop,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'file.read',
        description: 'Read a UTF-8 text file from the selected server.',
        parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 0},
            'length': {
              'type': 'integer',
              'minimum': 1,
              'maximum': _maxFileChunkBytes,
            },
          },
        },
      ),
      call: _read,
      requiresConfirmation: false,
      isRemote: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'file.write',
        description: 'Write a UTF-8 text file on the selected server.',
        parameters: {
          'type': 'object',
          'required': ['path', 'content'],
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
        },
      ),
      call: _writeFile,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'file.replace',
        description: 'Replace exactly one text block in a UTF-8 file.',
        parameters: {
          'type': 'object',
          'required': ['path', 'old', 'new'],
          'properties': {
            'path': {'type': 'string'},
            'old': {'type': 'string'},
            'new': {'type': 'string'},
          },
        },
      ),
      call: _replace,
      isRemote: true,
      writesRemoteState: true,
    ),
    if (project != null && projectFiles != null)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'server.download_to_project',
          description:
              'Download one file from the selected server into the current '
              'phone project. This transfer is binary-safe and does not put the '
              'file contents in the AI context. The destination path is '
              'relative to the project folder.',
          parameters: {
            'type': 'object',
            'required': ['remote_path', 'project_path'],
            'properties': {
              'remote_path': {'type': 'string'},
              'project_path': {'type': 'string'},
              'overwrite': {'type': 'boolean'},
            },
          },
        ),
        call: _downloadToProject,
        isRemote: true,
      ),
    if (localAccess != null)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'server.download_to_phone',
          description:
              'Download one binary or text file from the selected server '
              'directly to an absolute phone path. This is a binary-safe '
              'transfer and does not put the file contents in the AI context. '
              'The destination must be inside a user-authorized writable '
              'phone directory, unless it is inside the bound phone project '
              'during free execution. Use /storage/emulated/0/Download for a '
              'normal shared download when the user has approved it. Never '
              'use local.write for binary files.',
          parameters: {
            'type': 'object',
            'required': ['remote_path', 'local_path'],
            'properties': {
              'remote_path': {'type': 'string'},
              'local_path': {
                'type': 'string',
                'description': 'Absolute phone destination path',
              },
              'overwrite': {'type': 'boolean'},
            },
          },
        ),
        call: _downloadToPhone,
        requiresConfirmation: false,
        requiresUserApproval: true,
        userApprovalRequired: _downloadToPhoneNeedsApproval,
        isRemote: true,
      ),
    if (project != null && projectFiles != null)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'server.upload_from_project',
          description:
              'Upload one file from the current phone project to the selected '
              'server. The source path is relative to the phone project '
              'folder. Interrupted uploads can resume on the next attempt.',
          parameters: {
            'type': 'object',
            'required': ['project_path', 'remote_path'],
            'properties': {
              'project_path': {'type': 'string'},
              'remote_path': {'type': 'string'},
              'overwrite': {'type': 'boolean'},
            },
          },
        ),
        call: _uploadFromProject,
        isRemote: true,
        writesRemoteState: true,
      ),
  ];

  Future<Object?> _exec(Map<String, Object?> arguments) async {
    if (!remoteTaskRecoveryEnabled) {
      final result = await _connection.run(
        _requiredString(arguments, 'command'),
        workingDirectory:
            _optionalString(arguments, 'working_directory') ?? workingDirectory,
        input: _optionalString(arguments, 'input'),
      );
      return {
        'exit_code': result.exitCode,
        'stdout_truncated': result.stdoutTruncated,
        'stderr_truncated': result.stderrTruncated,
        'stdout': result.stdout,
        'stderr': result.stderr,
      };
    }
    final process = await _processController.start(
      command: _requiredString(arguments, 'command'),
      workingDirectory:
          _optionalString(arguments, 'working_directory') ?? workingDirectory,
      initialInput: _optionalString(arguments, 'input') ?? '',
    );
    final stdout = SshOutputBuffer();
    final stderr = SshOutputBuffer();
    var stdoutOffset = 0;
    var stderrOffset = 0;
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    RemoteProcessSnapshot? finalSnapshot;
    while (true) {
      final remaining = deadline.difference(DateTime.now()).inMilliseconds;
      if (remaining <= 0) {
        try {
          await _processController.stop(process.id);
        } catch (_) {}
        throw const SshCommandTimeout(Duration(minutes: 2));
      }
      final snapshot = await _processController.poll(
        process.id,
        stdoutOffset: stdoutOffset,
        stderrOffset: stderrOffset,
        waitMs: remaining.clamp(
          0,
          RemoteProcessController.maxPollWaitMilliseconds,
        ),
      );
      stdout.add(snapshot.stdout);
      stderr.add(snapshot.stderr);
      stdoutOffset = snapshot.stdoutOffset;
      stderrOffset = snapshot.stderrOffset;
      finalSnapshot = snapshot;
      final outputComplete =
          snapshot.stdoutTotalBytes == null ||
          stdoutOffset >= snapshot.stdoutTotalBytes!;
      final errorComplete =
          snapshot.stderrTotalBytes == null ||
          stderrOffset >= snapshot.stderrTotalBytes!;
      if (snapshot.done && outputComplete && errorComplete) break;
    }
    final snapshot = finalSnapshot;
    if (snapshot.failed && snapshot.exitCode == null) {
      throw StateError(snapshot.error ?? '远程命令状态未知');
    }
    return {
      'exit_code': snapshot.exitCode,
      'stdout_truncated': stdout.truncated,
      'stderr_truncated': stderr.truncated,
      'stdout': stdout.value,
      'stderr': stderr.value,
    };
  }

  Future<Object?> _start(Map<String, Object?> arguments) async {
    if (!remoteTaskRecoveryEnabled || arguments['pty'] == true) {
      return _startInteractive(arguments);
    }
    final process = await _processController.start(
      command: _requiredString(arguments, 'command'),
      workingDirectory:
          _optionalString(arguments, 'working_directory') ?? workingDirectory,
    );
    return {'process_id': process.id, 'persistent': true};
  }

  Future<Object?> _startInteractive(Map<String, Object?> arguments) async {
    _removeCompletedProcesses();
    if (_closing) throw StateError('远程工具正在关闭');
    if (_processes.length + _startingProcesses.length >=
        RemoteProcessController.maxManagedProcesses) {
      throw StateError('托管进程数量已达到上限（$_maxManagedProcesses），请先停止不再使用的进程');
    }
    final processId = 'process-${DateTime.now().microsecondsSinceEpoch}';
    final pty = arguments['pty'] == true;
    final pending = _connection.execute(
      _requiredString(arguments, 'command'),
      workingDirectory:
          _optionalString(arguments, 'working_directory') ?? workingDirectory,
      pty: pty,
    );
    _startingProcesses.add(pending);
    try {
      final stream = await pending;
      if (_closing) {
        stream.close();
        throw StateError('远程工具正在关闭');
      }
      _processes[processId] = _ManagedProcess(stream);
      return {
        'process_id': processId,
        'persistent': false,
        if (pty) 'pty': true,
      };
    } finally {
      _startingProcesses.remove(pending);
    }
  }

  Future<Object?> _poll(Map<String, Object?> arguments) async {
    final processId = _requiredString(arguments, 'process_id');
    final stdoutOffset = _optionalNonNegativeInt(arguments, 'stdout_offset');
    final stderrOffset = _optionalNonNegativeInt(arguments, 'stderr_offset');
    final waitMs = _optionalNonNegativeInt(arguments, 'wait_ms') ?? 0;
    if (waitMs > _maxPollWaitMilliseconds) {
      throw ArgumentError.value(
        waitMs,
        'wait_ms',
        'must not exceed $_maxPollWaitMilliseconds',
      );
    }
    final process = _processes[processId];
    if (process != null) {
      await process.wait(
        timeout: Duration(milliseconds: waitMs),
        stdoutOffset: stdoutOffset,
        stderrOffset: stderrOffset,
      );
      return {
        'process_id': processId,
        ...process.snapshot(
          stdoutOffset: stdoutOffset,
          stderrOffset: stderrOffset,
        ),
      };
    }
    if (!_canUsePersistentProcess(processId)) {
      throw StateError('服务器任务断线恢复已关闭，当前进程只能在原 SSH 连接中继续使用');
    }
    final snapshot = await _processController.poll(
      processId,
      stdoutOffset: stdoutOffset,
      stderrOffset: stderrOffset,
      waitMs: waitMs,
    );
    return {
      'process_id': processId,
      'stdout_offset': snapshot.stdoutOffset,
      'stderr_offset': snapshot.stderrOffset,
      if (snapshot.stdoutTotalBytes != null)
        'stdout_total_bytes': snapshot.stdoutTotalBytes,
      if (snapshot.stderrTotalBytes != null)
        'stderr_total_bytes': snapshot.stderrTotalBytes,
      'stdout_truncated': false,
      'stderr_truncated': false,
      'done': snapshot.done,
      'failed': snapshot.failed,
      if (snapshot.error != null) 'error': snapshot.error,
      'exit_code': snapshot.exitCode,
      'stdout': snapshot.stdout,
      'stderr': snapshot.stderr,
    };
  }

  Future<Object?> _write(Map<String, Object?> arguments) async {
    final processId = _requiredString(arguments, 'process_id');
    final process = _processes[processId];
    if (process != null) {
      process.stream.writeText(_requiredString(arguments, 'input'));
    } else {
      if (!_canUsePersistentProcess(processId)) {
        throw StateError('服务器任务断线恢复已关闭，当前进程只能在原 SSH 连接中继续使用');
      }
      await _processController.write(
        processId,
        _requiredString(arguments, 'input'),
      );
    }
    return {'process_id': processId};
  }

  Future<Object?> _stop(Map<String, Object?> arguments) async {
    final processId = _requiredString(arguments, 'process_id');
    final process = _processes[processId];
    if (process != null) {
      await process.stop();
      return {
        'process_id': processId,
        'stopped': process.failure == null,
        if (process.failure != null) 'error': process.failureDescription,
      };
    }
    if (!_canUsePersistentProcess(processId)) {
      throw StateError('服务器任务断线恢复已关闭，当前进程只能在原 SSH 连接中继续使用');
    }
    final snapshot = await _processController.stop(processId);
    return {
      'process_id': processId,
      'stopped': snapshot.done && !snapshot.failed,
      if (snapshot.error != null) 'error': snapshot.error,
    };
  }

  Future<Object?> _read(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    final offset = _optionalNonNegativeInt(arguments, 'offset') ?? 0;
    final length = _optionalNonNegativeInt(arguments, 'length');
    if (length == 0) {
      throw ArgumentError.value(length, 'length', 'must be positive');
    }
    if (length != null && length > _maxFileChunkBytes) {
      throw ArgumentError.value(
        length,
        'length',
        'must not exceed $_maxFileChunkBytes bytes',
      );
    }
    final chunk = await _connection.readFileChunk(
      _resolveRemotePath(path),
      offset: offset,
      length: length ?? _maxFileChunkBytes,
    );
    return {
      'path': path,
      'offset': chunk.offset,
      'next_offset': chunk.nextOffset,
      'eof': chunk.eof,
      if (chunk.totalBytes != null) 'total_bytes': chunk.totalBytes,
      'content': chunk.content,
    };
  }

  Future<Object?> _writeFile(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    await _connection.writeFile(
      _resolveRemotePath(path),
      utf8.encode(_requiredText(arguments, 'content')),
    );
    return {'path': path, 'written': true};
  }

  Future<Object?> _replace(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    await _connection.replaceText(
      _resolveRemotePath(path),
      _requiredString(arguments, 'old'),
      _requiredText(arguments, 'new'),
    );
    return {'path': path, 'replaced': true};
  }

  Future<Object?> _downloadToProject(Map<String, Object?> arguments) async {
    final targetProject = project;
    final files = projectFiles;
    if (targetProject == null || files == null) {
      throw StateError('当前对话没有绑定手机项目');
    }
    final remotePath = _requiredString(arguments, 'remote_path');
    final projectPath = _requiredString(arguments, 'project_path');
    final overwrite = arguments['overwrite'] != false;
    if (!overwrite && await files.exists(targetProject, projectPath)) {
      throw StateError('项目目标文件已存在：$projectPath');
    }
    final sourcePath = _resolveRemotePath(remotePath);
    final target = File(await files.resolveForIo(targetProject, projectPath));
    final downloaded = await const ResumableFileDownloader().download(
      target: target,
      sourceKey: sourcePath,
      readChunk: (offset) =>
          _connection.readFileBytesChunk(sourcePath, offset: offset),
      overwrite: overwrite,
    );
    return {
      'remote_path': remotePath,
      'project_path': projectPath,
      'bytes': await downloaded.length(),
      'written': true,
    };
  }

  Future<Object?> _downloadToPhone(Map<String, Object?> arguments) async {
    final remotePath = _requiredString(arguments, 'remote_path');
    final localPath = _requiredString(arguments, 'local_path');
    if (!path_util.posix.isAbsolute(localPath)) {
      throw ArgumentError('local_path must be an absolute phone path');
    }
    final overwrite = arguments['overwrite'] != false;
    final projectTarget = await _resolveProjectDestination(localPath);
    final resolvedPath =
        projectTarget ??
        await (localAccess ?? (throw StateError('当前对话没有手机文件写入授权'))).resolve(
          localPath,
          write: true,
        );
    final target = File(resolvedPath);
    if (!overwrite && await target.exists()) {
      throw StateError('手机目标文件已存在：$localPath');
    }
    final sourcePath = _resolveRemotePath(remotePath);
    final downloaded = await const ResumableFileDownloader().download(
      target: target,
      sourceKey: sourcePath,
      readChunk: (offset) =>
          _connection.readFileBytesChunk(sourcePath, offset: offset),
      overwrite: overwrite,
    );
    return {
      'remote_path': remotePath,
      'local_path': localPath,
      'bytes': await downloaded.length(),
      'written': true,
    };
  }

  Future<bool> _downloadToPhoneNeedsApproval(
    Map<String, Object?> arguments,
    String executionMode,
  ) async {
    if (executionMode != 'auto') return true;
    final localPath = arguments['local_path'];
    if (localPath is! String || !path_util.posix.isAbsolute(localPath)) {
      return true;
    }
    try {
      return await _resolveProjectDestination(localPath) == null;
    } on StateError {
      // A project symlink that leaves the project must not be auto-approved.
      return true;
    }
  }

  Future<String?> _resolveProjectDestination(String localPath) async {
    final targetProject = project;
    final files = projectFiles;
    if (targetProject == null || files == null) return null;
    try {
      return await files.resolveAbsoluteForIo(targetProject, localPath);
    } on ArgumentError {
      return null;
    }
  }

  Future<Object?> _uploadFromProject(Map<String, Object?> arguments) async {
    final sourceProject = project;
    final files = projectFiles;
    if (sourceProject == null || files == null) {
      throw StateError('当前对话没有绑定手机项目');
    }
    final projectPath = _requiredString(arguments, 'project_path');
    final remotePath = _requiredString(arguments, 'remote_path');
    final overwrite = arguments['overwrite'] != false;
    final source = File(await files.resolveForIo(sourceProject, projectPath));
    final totalBytes = await source.length();
    final modified = await source.lastModified();
    final sourceKey =
        '${source.path}\u0000$totalBytes\u0000${modified.microsecondsSinceEpoch}';
    final localFile = await source.open();
    try {
      final uploaded = await const ResumableFileUploader().upload(
        totalBytes: totalBytes,
        prepare: () => _connection.prepareFileUpload(
          _resolveRemotePath(remotePath),
          sourceKey: sourceKey,
          totalBytes: totalBytes,
          overwrite: overwrite,
        ),
        readChunk: (offset, length) async {
          await localFile.setPosition(offset);
          return localFile.read(length);
        },
        writeChunk: (session, bytes, offset) => _connection.writeFileBytesChunk(
          session.temporaryPath,
          bytes,
          offset: offset,
        ),
        commit: (session) async {
          final currentLength = await source.length();
          final currentModified = await source.lastModified();
          if (currentLength != totalBytes || currentModified != modified) {
            throw StateError('手机文件在上传期间发生变化，请重新上传');
          }
          await _connection.completeFileUpload(session);
        },
      );
      return {
        'project_path': projectPath,
        'remote_path': remotePath,
        'bytes': uploaded,
        'written': true,
      };
    } finally {
      await localFile.close();
    }
  }

  String _resolveRemotePath(String filePath) {
    if (path_util.posix.isAbsolute(filePath)) return filePath;
    final directory = workingDirectory;
    if (directory == null || directory.isEmpty) return filePath;
    return path_util.posix.join(directory, filePath);
  }

  bool _canUsePersistentProcess(String processId) =>
      remoteTaskRecoveryEnabled || _processController.hasHandle(processId);

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    final future = _closeAll();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeAll() async {
    final starting = List<Future<SshCommandStream>>.of(_startingProcesses);
    await Future.wait<void>([
      for (final pending in starting) _closeStartingProcess(pending),
    ], eagerError: false);
    await Future.wait<void>([
      for (final process in _processes.values) process.close(),
    ], eagerError: false);
    _processes.clear();
    await _processController.close();
  }

  Future<void> _closeStartingProcess(Future<SshCommandStream> pending) async {
    try {
      final stream = await pending.timeout(_processStartCloseTimeout);
      stream.close();
    } on TimeoutException {
      // The start continuation closes a late stream after it observes
      // [_closing]. Do not block app shutdown on a stuck channel open.
    } catch (_) {
      // A failed channel open has nothing left to close.
    }
  }

  void _removeCompletedProcesses() {
    _processes.removeWhere((_, process) => process.done);
  }

  bool get hasRunningProcesses =>
      _startingProcesses.isNotEmpty ||
      _processes.values.any((value) => !value.done) ||
      _processController.hasRunningProcesses;

  static String _requiredString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value;
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String) throw ArgumentError('$key is required');
    return value;
  }

  static String? _optionalString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static int? _optionalNonNegativeInt(
    Map<String, Object?> arguments,
    String key,
  ) {
    final value = arguments[key];
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw ArgumentError('$key must be a non-negative integer');
    }
    return value;
  }
}

class ProjectAgentTools {
  ProjectAgentTools(
    this._project,
    this._files, {
    this._preview,
    this.documentModuleEnabled = true,
  });

  final Project _project;
  final ProjectFileStore _files;
  LocalPreviewServer? _preview;
  final bool documentModuleEnabled;

  List<AgentTool> get tools => [
    AgentTool(
      definition: const AiToolDefinition(
        name: 'project.list',
        description:
            'List files and folders in the current phone project. Paths are '
            'relative to the project root.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      ),
      call: _list,
      requiresConfirmation: false,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'project.read',
        description:
            'Read a UTF-8 text file from the current phone project in byte '
            'chunks. Do not read the entire project automatically.',
        parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 0},
            'length': {
              'type': 'integer',
              'minimum': 1,
              'maximum': _maxFileChunkBytes,
            },
          },
        },
      ),
      call: _read,
      requiresConfirmation: false,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'project.write',
        description:
            'Write a UTF-8 text file in the current phone project. The path '
            'is relative to the project root.',
        parameters: {
          'type': 'object',
          'required': ['path', 'content'],
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
        },
      ),
      call: _write,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'project.replace',
        description: 'Replace exactly one text block in a UTF-8 project file.',
        parameters: {
          'type': 'object',
          'required': ['path', 'old', 'new'],
          'properties': {
            'path': {'type': 'string'},
            'old': {'type': 'string'},
            'new': {'type': 'string'},
          },
        },
      ),
      call: _replace,
    ),
    if (documentModuleEnabled)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'document.export_docx',
          description:
              'Export a Markdown, HTML, or UTF-8 text file from the current '
              'phone project as a real DOCX file. The source is read as text '
              'and the output is written inside the same project. Supports '
              'headings, paragraphs, lists, tables, basic inline emphasis, '
              'and HTML color spans.',
          parameters: {
            'type': 'object',
            'required': ['source_path'],
            'properties': {
              'source_path': {'type': 'string'},
              'output_path': {
                'type': 'string',
                'description':
                    'Optional project-relative .docx path. Defaults to the '
                    'source name with a .docx extension.',
              },
            },
          },
        ),
        call: _exportDocx,
      ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.test_web',
        description:
            'Check the current phone project web entrypoint and its local '
            'HTML, CSS, image, script, and media references. This is a '
            'static resource check, not a full JavaScript test runner.',
        parameters: {
          'type': 'object',
          'properties': {
            'entrypoint': {'type': 'string'},
          },
        },
      ),
      call: _testWeb,
      requiresConfirmation: false,
    ),
    if (_preview != null) ...[
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.start',
          description:
              'Start a loopback-only local web preview for the current phone '
              'project. The default entrypoint is index.html.',
          parameters: {
            'type': 'object',
            'properties': {
              'entrypoint': {'type': 'string'},
            },
          },
        ),
        call: _startPreview,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.status',
          description:
              'Read the current local web preview status, URL, request count, '
              'and reload marker for the current phone project.',
          parameters: {'type': 'object'},
        ),
        call: _previewStatus,
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.reload',
          description:
              'Request the open local preview page to reload after project '
              'files have changed.',
          parameters: {'type': 'object'},
        ),
        call: _reloadPreview,
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.logs',
          description:
              'Read console, JavaScript error, resource error, HTTP, and '
              'preview server logs. Use after as the last sequence received '
              'to fetch only newer entries.',
          parameters: {
            'type': 'object',
            'properties': {
              'after': {'type': 'integer', 'minimum': 0},
              'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
            },
          },
        ),
        call: _previewLogs,
        requiresConfirmation: false,
      ),
      AgentTool(
        definition: const AiToolDefinition(
          name: 'preview.stop',
          description: 'Stop the local web preview for the current project.',
          parameters: {'type': 'object'},
        ),
        call: _stopPreview,
      ),
    ],
  ];

  Future<Object?> _list(Map<String, Object?> arguments) async {
    final entries = await _files.list(
      _project,
      _optionalString(arguments, 'path') ?? '',
    );
    return {
      'project': _project.name,
      'path': _optionalString(arguments, 'path') ?? '',
      'entries': [
        for (final entry in entries)
          {
            'name': entry.name,
            'path': entry.path,
            'directory': entry.isDirectory,
            if (entry.size != null) 'size': entry.size,
          },
      ],
    };
  }

  Future<Object?> _read(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    final offset = _optionalNonNegativeInt(arguments, 'offset') ?? 0;
    final length =
        _optionalNonNegativeInt(arguments, 'length') ?? _maxFileChunkBytes;
    if (length > _maxFileChunkBytes) {
      throw ArgumentError.value(
        length,
        'length',
        'must not exceed $_maxFileChunkBytes bytes',
      );
    }
    final chunk = await _files.readChunk(
      _project,
      path,
      offset: offset,
      length: length,
    );
    return {
      'path': path,
      'offset': chunk.offset,
      'next_offset': chunk.nextOffset,
      'eof': chunk.eof,
      if (chunk.totalBytes != null) 'total_bytes': chunk.totalBytes,
      'content': chunk.content,
    };
  }

  Future<Object?> _write(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    final content = _requiredText(arguments, 'content');
    await _files.writeText(_project, path, content);
    return {'path': path, 'written': true};
  }

  Future<Object?> _replace(Map<String, Object?> arguments) async {
    final path = _requiredString(arguments, 'path');
    await _files.replaceText(
      _project,
      path,
      _requiredString(arguments, 'old'),
      _requiredText(arguments, 'new'),
    );
    return {'path': path, 'replaced': true};
  }

  Future<Object?> _exportDocx(Map<String, Object?> arguments) async {
    final sourcePath = _requiredString(arguments, 'source_path');
    if (!isDocumentSourceFile(sourcePath)) {
      throw ArgumentError('source_path must be a Markdown, HTML, or text file');
    }
    final outputPath =
        _optionalString(arguments, 'output_path') ??
        _defaultDocxPath(sourcePath);
    if (path_util.posix.extension(outputPath).toLowerCase() != '.docx') {
      throw ArgumentError('output_path must end with .docx');
    }
    final content = await _files.readText(_project, sourcePath);
    final bytes = const DocumentExportService().exportDocx(
      fileName: sourcePath,
      content: content,
    );
    await _files.writeBytes(_project, outputPath, bytes);
    return {
      'source_path': sourcePath,
      'output_path': outputPath,
      'bytes': bytes.length,
      'written': true,
    };
  }

  Future<Object?> _testWeb(Map<String, Object?> arguments) {
    return _previewOrFiles
        .testWeb(
          _project,
          entrypoint: _optionalString(arguments, 'entrypoint') ?? 'index.html',
        )
        .then((result) => result.toJson());
  }

  Future<Object?> _startPreview(Map<String, Object?> arguments) async {
    final preview = _previewOrThrow;
    final status = await preview.start(
      _project,
      entrypoint: _optionalString(arguments, 'entrypoint') ?? 'index.html',
    );
    return status.toJson();
  }

  Future<Object?> _previewStatus(Map<String, Object?> arguments) {
    return Future.value(_previewOrThrow.status(_project).toJson());
  }

  Future<Object?> _reloadPreview(Map<String, Object?> arguments) {
    return Future.value(_previewOrThrow.reload(_project).toJson());
  }

  Future<Object?> _previewLogs(Map<String, Object?> arguments) {
    final after = _optionalNonNegativeInt(arguments, 'after') ?? 0;
    final limit = _optionalNonNegativeInt(arguments, 'limit') ?? 100;
    if (limit <= 0 || limit > 200) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 200');
    }
    final preview = _previewOrThrow;
    return Future.value({
      'project': _project.name,
      'after': after,
      'logs': [
        for (final log in preview.logs(_project, after: after, limit: limit))
          log.toJson(),
      ],
      'next_sequence': preview.status(_project).logSequence,
    });
  }

  Future<Object?> _stopPreview(Map<String, Object?> arguments) async {
    await _previewOrThrow.stop(_project);
    return {'project': _project.name, 'stopped': true};
  }

  LocalPreviewServer get _previewOrThrow {
    return _preview ??= LocalPreviewServer(files: _files);
  }

  LocalPreviewServer get _previewOrFiles => _previewOrThrow;

  static String _requiredString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value;
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String) throw ArgumentError('$key is required');
    return value;
  }

  static String? _optionalString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static String _defaultDocxPath(String sourcePath) {
    final extension = path_util.posix.extension(sourcePath);
    if (extension.isEmpty) return '$sourcePath.docx';
    return '${sourcePath.substring(0, sourcePath.length - extension.length)}.docx';
  }

  static int? _optionalNonNegativeInt(
    Map<String, Object?> arguments,
    String key,
  ) {
    final value = arguments[key];
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw ArgumentError('$key must be a non-negative integer');
    }
    return value;
  }
}

/// Tools for files outside the current project. The grant store is kept in
/// memory by AppController and is never persisted with the conversation.
class LocalAgentTools {
  LocalAgentTools(this._access);

  final LocalFileAccessStore _access;

  List<AgentTool> get tools => [
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.request_access',
        description:
            'Request user permission to access an absolute phone path outside '
            'the current project. The user must approve the exact scope.',
        parameters: {
          'type': 'object',
          'required': ['path', 'reason'],
          'properties': {
            'path': {'type': 'string'},
            'write': {'type': 'boolean'},
            'reason': {'type': 'string'},
          },
        },
      ),
      call: _requestAccess,
      requiresConfirmation: false,
      requiresUserApproval: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.list',
        description:
            'List files and folders under a user-authorized phone path. '
            'Use the absolute path returned by local.request_access.',
        parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
          },
        },
      ),
      call: _list,
      requiresConfirmation: false,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.read',
        description: 'Read a UTF-8 text file under a user-authorized path.',
        parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 0},
            'length': {
              'type': 'integer',
              'minimum': 1,
              'maximum': _maxFileChunkBytes,
            },
          },
        },
      ),
      call: _read,
      requiresConfirmation: false,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.write',
        description: 'Write a UTF-8 text file under a user-authorized path.',
        parameters: {
          'type': 'object',
          'required': ['path', 'content'],
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
        },
      ),
      call: _write,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'local.replace',
        description:
            'Replace exactly one text block in a user-authorized phone file.',
        parameters: {
          'type': 'object',
          'required': ['path', 'old', 'new'],
          'properties': {
            'path': {'type': 'string'},
            'old': {'type': 'string'},
            'new': {'type': 'string'},
          },
        },
      ),
      call: _replace,
    ),
  ];

  Future<Object?> _requestAccess(Map<String, Object?> arguments) async {
    final requestedPath = _requiredString(arguments, 'path');
    final grant = await _access.find(requestedPath);
    if (grant == null) {
      throw StateError('本地文件授权未生效，请等待用户确认后重试');
    }
    return {
      'granted': true,
      'path': requestedPath,
      'scope': grant.rootPath,
      'can_write': grant.canWrite,
      'expires': 'current_conversation',
    };
  }

  Future<Object?> _list(Map<String, Object?> arguments) async {
    final requestedPath = _requiredString(arguments, 'path');
    final resolved = await _access.resolve(requestedPath);
    final directory = Directory(resolved);
    final entries = <Map<String, Object?>>[];
    await for (final entity in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        continue;
      }
      int? size;
      if (type == FileSystemEntityType.file) {
        try {
          size = await File(entity.path).length();
        } on FileSystemException {
          size = null;
        }
      }
      entries.add({
        'name': path_util.basename(entity.path),
        'path': path_util.join(requestedPath, path_util.basename(entity.path)),
        'directory': type == FileSystemEntityType.directory,
        'size': size,
      });
    }
    entries.sort((left, right) {
      final leftDirectory = left['directory'] == true;
      final rightDirectory = right['directory'] == true;
      if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
      return (left['name'] as String).compareTo(right['name'] as String);
    });
    return {'path': requestedPath, 'entries': entries};
  }

  Future<Object?> _read(Map<String, Object?> arguments) async {
    final requestedPath = _requiredString(arguments, 'path');
    final offset = _optionalNonNegativeInt(arguments, 'offset') ?? 0;
    final length =
        _optionalNonNegativeInt(arguments, 'length') ?? _maxFileChunkBytes;
    if (length > _maxFileChunkBytes) {
      throw ArgumentError.value(
        length,
        'length',
        'must not exceed $_maxFileChunkBytes bytes',
      );
    }
    final file = await File(await _access.resolve(requestedPath)).open();
    try {
      final totalBytes = await file.length();
      if (offset >= totalBytes) {
        return {
          'path': requestedPath,
          'offset': offset,
          'next_offset': offset,
          'eof': true,
          'total_bytes': totalBytes,
          'content': '',
        };
      }
      await file.setPosition(offset);
      final bytes = await file.read(length + 3);
      var end = bytes.length;
      while (end > 0) {
        try {
          utf8.decode(bytes.sublist(0, end));
          break;
        } on FormatException {
          end--;
        }
      }
      final nextOffset = offset + end;
      return {
        'path': requestedPath,
        'offset': offset,
        'next_offset': nextOffset,
        'eof': nextOffset >= totalBytes,
        'total_bytes': totalBytes,
        'content': utf8.decode(bytes.sublist(0, end)),
      };
    } finally {
      await file.close();
    }
  }

  Future<Object?> _write(Map<String, Object?> arguments) async {
    final requestedPath = _requiredString(arguments, 'path');
    final resolved = await _access.resolve(requestedPath, write: true);
    final target = File(resolved);
    await target.writeAsString(
      _requiredText(arguments, 'content'),
      flush: true,
    );
    return {'path': requestedPath, 'written': true};
  }

  Future<Object?> _replace(Map<String, Object?> arguments) async {
    final requestedPath = _requiredString(arguments, 'path');
    final resolved = await _access.resolve(requestedPath, write: true);
    final oldText = _requiredString(arguments, 'old');
    final newText = _requiredText(arguments, 'new');
    final target = File(resolved);
    final current = await target.readAsString();
    if (_countOccurrences(current, oldText) != 1) {
      throw StateError('replace requires exactly one matching block');
    }
    await target.writeAsString(
      current.replaceFirst(oldText, newText),
      flush: true,
    );
    return {'path': requestedPath, 'replaced': true};
  }

  static String _requiredString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value.trim();
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String) throw ArgumentError('$key is required');
    return value;
  }

  static int? _optionalNonNegativeInt(
    Map<String, Object?> arguments,
    String key,
  ) {
    final value = arguments[key];
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw ArgumentError('$key must be a non-negative integer');
    }
    return value;
  }

  static int _countOccurrences(String value, String needle) {
    if (needle.isEmpty) throw ArgumentError.value(needle, 'old');
    var count = 0;
    var offset = 0;
    while (true) {
      final index = value.indexOf(needle, offset);
      if (index < 0) return count;
      count++;
      offset = index + needle.length;
    }
  }
}

class _ManagedProcess {
  _ManagedProcess(this.stream) {
    _stdoutSubscription = stream.stdout.listen((value) {
      _stdout.addBytes(value);
      _signalChanged();
    });
    _stderrSubscription = stream.stderr.listen((value) {
      _stderr.addBytes(value);
      _signalChanged();
    });
    final stdoutDone = _observe(_stdoutSubscription.asFuture<void>());
    final stderrDone = _observe(_stderrSubscription.asFuture<void>());
    unawaited(
      Future.wait<void>([_observe(stream.done), stdoutDone, stderrDone])
          .then<void>((_) => _finish()),
    );
  }

  final SshCommandStream stream;
  final SshOutputBuffer _stdout = SshOutputBuffer();
  final SshOutputBuffer _stderr = SshOutputBuffer();
  late final StreamSubscription<Uint8List> _stdoutSubscription;
  late final StreamSubscription<Uint8List> _stderrSubscription;
  var _changed = Completer<void>();
  final _finished = Completer<void>();
  Future<void>? _stopFuture;
  Future<void>? _closeFuture;
  Object? failure;
  bool done = false;

  String? get failureDescription => failure == null ? null : '$failure';

  Future<void> _observe(Future<void> future) async {
    try {
      await future;
    } catch (error) {
      failure ??= error;
    }
  }

  void _finish() {
    if (done) return;
    if (failure == null &&
        stream.exitCode == null &&
        stream.exitSignal == null) {
      failure = StateError(
        'Remote process channel closed without an exit status',
      );
    }
    done = true;
    if (!_finished.isCompleted) _finished.complete();
    _signalChanged();
  }

  Future<void> wait({
    required Duration timeout,
    required int? stdoutOffset,
    required int? stderrOffset,
  }) async {
    if (done ||
        timeout == Duration.zero ||
        _hasNewOutput(stdoutOffset, stderrOffset)) {
      return;
    }
    final changed = _changed.future;
    if (done || _hasNewOutput(stdoutOffset, stderrOffset)) return;
    await Future.any<void>([changed, Future<void>.delayed(timeout)]);
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final future = _stopAndWait();
    _stopFuture = future;
    return future;
  }

  Future<void> _stopAndWait() async {
    if (done) return;
    try {
      await stream.terminate();
    } catch (_) {
      _finish();
      rethrow;
    } finally {
      stream.close();
    }
    try {
      await _finished.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The channel has already been closed; do not keep app shutdown or a
      // new task blocked on a server that never completes its stream.
      _finish();
    }
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final future = _close();
    _closeFuture = future;
    return future;
  }

  Future<void> _close() async {
    try {
      if (!done) await stop();
    } finally {
      stream.close();
      await _stdoutSubscription.cancel();
      await _stderrSubscription.cancel();
    }
  }

  bool _hasNewOutput(int? stdoutOffset, int? stderrOffset) {
    return _stdout.length > _offset(stdoutOffset, _stdout.length) ||
        _stderr.length > _offset(stderrOffset, _stderr.length);
  }

  void _signalChanged() {
    final changed = _changed;
    if (changed.isCompleted) return;
    changed.complete();
    _changed = Completer<void>();
  }

  Map<String, Object?> snapshot({int? stdoutOffset, int? stderrOffset}) {
    final stdoutStart = _offset(stdoutOffset, _stdout.length);
    final stderrStart = _offset(stderrOffset, _stderr.length);
    return {
      'stdout_offset': _stdout.length,
      'stderr_offset': _stderr.length,
      'stdout_truncated': _stdout.truncated,
      'stderr_truncated': _stderr.truncated,
      'done': done,
      'failed': failure != null,
      if (failure != null) 'error': failureDescription,
      'exit_code': stream.exitCode,
      'stdout': _stdout.substring(stdoutStart),
      'stderr': _stderr.substring(stderrStart),
    };
  }

  static int _offset(int? value, int length) {
    if (value == null) return 0;
    return value > length ? length : value;
  }
}

const _maxFileChunkBytes = 1024 * 1024;
const _maxPollWaitMilliseconds = 30 * 1000;
const _maxManagedProcesses = 64;
const _processStartCloseTimeout = Duration(seconds: 2);
