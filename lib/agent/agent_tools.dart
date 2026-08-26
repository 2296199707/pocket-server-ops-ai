import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;

import '../domain/models.dart';
import '../local/local_file_access.dart';
import '../local/local_preview.dart';
import '../local/project_files.dart';
import '../ssh/ssh_connection.dart';
import 'ai_protocol.dart';

class AgentTool {
  const AgentTool({
    required this.definition,
    required this.call,
    this.requiresConfirmation = true,
    this.requiresUserApproval = false,
    this.writesRemoteState = false,
  });

  final AiToolDefinition definition;
  final Future<Object?> Function(Map<String, Object?> arguments) call;
  final bool requiresConfirmation;

  /// Requests that change the app's technical boundary always need the user.
  final bool requiresUserApproval;
  final bool writesRemoteState;
}

class RemoteAgentTools {
  RemoteAgentTools(
    this._connection, {
    this.workingDirectory,
    this.project,
    this.projectFiles,
  });

  final SshConnection _connection;
  final String? workingDirectory;
  final Project? project;
  final ProjectFileStore? projectFiles;
  final Map<String, _ManagedProcess> _processes = {};

  bool get isClosed => _connection.isClosed;

  List<AgentTool> get tools => [
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.exec',
        description:
            'Run a short shell command on the selected server with a '
            'two-minute timeout.',
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
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.start',
        description: 'Start a long-running shell command.',
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
      writesRemoteState: true,
    ),
    if (project != null && projectFiles != null)
      AgentTool(
        definition: const AiToolDefinition(
          name: 'server.download_to_project',
          description:
              'Download one file from the selected server into the current '
              'phone project. The destination path is relative to the '
              'project folder.',
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
        writesRemoteState: true,
      ),
  ];

  Future<Object?> _exec(Map<String, Object?> arguments) async {
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

  Future<Object?> _start(Map<String, Object?> arguments) async {
    final processId = 'process-${DateTime.now().microsecondsSinceEpoch}';
    final process = await _connection.execute(
      _requiredString(arguments, 'command'),
      workingDirectory:
          _optionalString(arguments, 'working_directory') ?? workingDirectory,
      pty: arguments['pty'] == true,
    );
    _processes[processId] = _ManagedProcess(process);
    return {'process_id': processId};
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
    final process = _process(arguments);
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

  Future<Object?> _write(Map<String, Object?> arguments) async {
    final process = _process(arguments);
    process.stream.writeText(_requiredString(arguments, 'input'));
    return {'process_id': _requiredString(arguments, 'process_id')};
  }

  Future<Object?> _stop(Map<String, Object?> arguments) async {
    final process = _process(arguments);
    process.stop();
    return {
      'process_id': _requiredString(arguments, 'process_id'),
      'stopped': true,
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
    final bytes = await _connection.readFileBytes(
      _resolveRemotePath(remotePath),
    );
    await files.writeBytes(targetProject, projectPath, bytes);
    return {
      'remote_path': remotePath,
      'project_path': projectPath,
      'bytes': bytes.length,
      'written': true,
    };
  }

  String _resolveRemotePath(String filePath) {
    if (path_util.posix.isAbsolute(filePath)) return filePath;
    final directory = workingDirectory;
    if (directory == null || directory.isEmpty) return filePath;
    return path_util.posix.join(directory, filePath);
  }

  _ManagedProcess _process(Map<String, Object?> arguments) {
    final id = _requiredString(arguments, 'process_id');
    final process = _processes[id];
    if (process == null) throw StateError('Unknown process: $id');
    return process;
  }

  Future<void> close() async {
    for (final process in _processes.values) {
      await process.close();
    }
    _processes.clear();
  }

  bool get hasRunningProcesses => _processes.values.any((value) => !value.done);

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
  ProjectAgentTools(this._project, this._files, {this._preview});

  final Project _project;
  final ProjectFileStore _files;
  LocalPreviewServer? _preview;

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
      writesRemoteState: true,
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
      writesRemoteState: true,
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
    _stdoutSubscription = stream.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((value) {
          _stdout.add(value);
          _signalChanged();
        });
    _stderrSubscription = stream.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((value) {
          _stderr.add(value);
          _signalChanged();
        });
    final stdoutDone = _stdoutSubscription.asFuture<void>();
    final stderrDone = _stderrSubscription.asFuture<void>();
    unawaited(
      Future.wait<void>([stream.done, stdoutDone, stderrDone]).then<void>(
        (_) => _finish(),
        onError: (Object error, StackTrace stackTrace) => _finish(),
      ),
    );
  }

  final SshCommandStream stream;
  final _TextBuffer _stdout = _TextBuffer();
  final _TextBuffer _stderr = _TextBuffer();
  late final StreamSubscription<String> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  var _changed = Completer<void>();
  bool done = false;

  void _finish() {
    if (done) return;
    done = true;
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

  void stop() {
    stream.stop();
    stream.close();
  }

  Future<void> close() async {
    if (!done) stop();
    _signalChanged();
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    stream.close();
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

class _TextBuffer {
  final StringBuffer _buffer = StringBuffer();

  bool get truncated => false;

  int get length => _buffer.length;

  void add(String value) {
    _buffer.write(value);
  }

  String substring(int start) => _buffer.toString().substring(start);
}
