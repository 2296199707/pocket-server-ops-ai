import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;

import '../domain/models.dart';
import '../local/project_files.dart';
import '../ssh/ssh_connection.dart';
import 'ai_protocol.dart';

class AgentTool {
  const AgentTool({
    required this.definition,
    required this.call,
    this.requiresConfirmation = true,
    this.writesRemoteState = false,
  });

  final AiToolDefinition definition;
  final Future<Object?> Function(Map<String, Object?> arguments) call;
  final bool requiresConfirmation;
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
    if (!overwrite) {
      try {
        await File(resolveProjectPath(targetProject, projectPath)).stat();
        throw StateError('项目目标文件已存在：$projectPath');
      } on FileSystemException {
        // The destination does not exist, so the download can continue.
      }
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

String resolveProjectPath(Project project, String relativePath) {
  return const ProjectFileStore().resolve(project, relativePath);
}

class ProjectAgentTools {
  ProjectAgentTools(this._project, this._files);

  final Project _project;
  final ProjectFileStore _files;

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
