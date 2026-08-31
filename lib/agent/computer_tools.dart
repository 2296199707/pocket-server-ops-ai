import 'dart:async';

import '../relay/computer_relay_client.dart';
import 'agent_tools.dart';
import 'ai_protocol.dart';

/// Agent tools backed by a paired Windows computer. The command boundary is
/// PowerShell on the computer, so the model is told explicitly not to use
/// POSIX-only shell syntax.
class ComputerAgentTools {
  ComputerAgentTools({
    required this.relay,
    required this.deviceId,
    this.workingDirectory,
    this.cancellation,
  });

  final ComputerRelayClient relay;
  final String deviceId;
  final String? workingDirectory;
  Future<void>? cancellation;
  final Set<String> _runningProcesses = {};
  var _closed = false;

  bool get isClosed => _closed;
  bool get hasRunningProcesses => _runningProcesses.isNotEmpty;

  void updateCancellation(Future<void>? value) {
    cancellation = value;
  }

  List<AgentTool> get tools => [
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.exec',
        description:
            'Run a PowerShell command on the paired Windows computer and '
            'return its output. Use terminal.start for a long-running command.',
        parameters: {
          'type': 'object',
          'required': ['command'],
          'properties': {
            'command': {'type': 'string'},
            'working_directory': {'type': 'string'},
            'input': {'type': 'string'},
            'yield_time_ms': {'type': 'integer', 'minimum': 250},
          },
        },
      ),
      call: _exec,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'terminal.start',
        description:
            'Start a long-running PowerShell command on the paired Windows '
            'computer. Poll the returned process_id before reporting status.',
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
        description: 'Read new output and status from a Windows process.',
        parameters: {
          'type': 'object',
          'required': ['process_id'],
          'properties': {
            'process_id': {'type': 'string'},
            'stdout_offset': {'type': 'integer', 'minimum': 0},
            'stderr_offset': {'type': 'integer', 'minimum': 0},
            'wait_ms': {'type': 'integer', 'minimum': 0},
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
        description: 'Write input to a running Windows PowerShell process.',
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
        description: 'Stop a running Windows PowerShell process.',
        parameters: {
          'type': 'object',
          'required': ['process_id'],
          'properties': {
            'process_id': {'type': 'string'},
          },
        },
      ),
      call: _stop,
      requiresConfirmation: false,
      isRemote: true,
      writesRemoteState: true,
    ),
    AgentTool(
      definition: const AiToolDefinition(
        name: 'file.read',
        description: 'Read a UTF-8 text file from the paired Windows computer.',
        parameters: {
          'type': 'object',
          'required': ['path'],
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 0},
            'length': {'type': 'integer', 'minimum': 1},
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
        description:
            'Write UTF-8 text to a file on the paired Windows computer.',
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
        description: 'Replace exactly one UTF-8 text block in a Windows file.',
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
    AgentTool(
      definition: const AiToolDefinition(
        name: 'server.status',
        description:
            'Read CPU, memory, disk and OS status from the Windows computer.',
        parameters: {'type': 'object'},
      ),
      call: _status,
      requiresConfirmation: false,
      isRemote: true,
    ),
  ];

  Future<Object?> _exec(Map<String, Object?> arguments) => _call(
    'exec',
    _withDirectory({
      'command': _requiredText(arguments, 'command'),
      if (arguments['input'] is String) 'input': arguments['input'],
      if (arguments['yield_time_ms'] is int)
        'timeout_ms': arguments['yield_time_ms'],
    }, arguments),
  );

  Future<Object?> _start(Map<String, Object?> arguments) async {
    final result = await _call(
      'process.start',
      _withDirectory({
        'command': _requiredText(arguments, 'command'),
        'pty': arguments['pty'] == true,
      }, arguments),
    );
    if (result is Map && result['process_id'] is String) {
      _runningProcesses.add(result['process_id'] as String);
    }
    return result;
  }

  Future<Object?> _poll(Map<String, Object?> arguments) async {
    final processId = _requiredText(arguments, 'process_id');
    final result = await _call('process.poll', {
      'process_id': processId,
      if (arguments['stdout_offset'] is int)
        'stdout_offset': arguments['stdout_offset'],
      if (arguments['stderr_offset'] is int)
        'stderr_offset': arguments['stderr_offset'],
      if (arguments['wait_ms'] is int) 'wait_ms': arguments['wait_ms'],
    });
    if (result is Map && result['done'] == true) {
      _runningProcesses.remove(processId);
    }
    return result;
  }

  Future<Object?> _write(Map<String, Object?> arguments) =>
      _call('process.write', {
        'process_id': _requiredText(arguments, 'process_id'),
        'input': _requiredText(arguments, 'input'),
      });

  Future<Object?> _stop(Map<String, Object?> arguments) async {
    final processId = _requiredText(arguments, 'process_id');
    final result = await _call('process.stop', {'process_id': processId});
    _runningProcesses.remove(processId);
    return result;
  }

  Future<Object?> _read(Map<String, Object?> arguments) => _call('file.read', {
    'path': _requiredText(arguments, 'path'),
    if (arguments['offset'] is int) 'offset': arguments['offset'],
    if (arguments['length'] is int) 'length': arguments['length'],
  });

  Future<Object?> _writeFile(Map<String, Object?> arguments) =>
      _call('file.write', {
        'path': _requiredText(arguments, 'path'),
        'content': _requiredText(arguments, 'content'),
      });

  Future<Object?> _replace(Map<String, Object?> arguments) =>
      _call('file.replace', {
        'path': _requiredText(arguments, 'path'),
        'old': _requiredText(arguments, 'old'),
        'new': _requiredText(arguments, 'new'),
      });

  Future<Object?> _status(Map<String, Object?> arguments) =>
      _call('status', const {});

  Future<Object?> _call(String operation, Map<String, Object?> payload) async {
    return relay.call(
      deviceId: deviceId,
      operation: operation,
      payload: payload,
      cancellation: cancellation,
    );
  }

  Map<String, Object?> _withDirectory(
    Map<String, Object?> payload,
    Map<String, Object?> arguments,
  ) {
    final directory = arguments['working_directory'];
    if (directory is String && directory.trim().isNotEmpty) {
      return {...payload, 'working_directory': directory.trim()};
    }
    final fallback = workingDirectory?.trim();
    return fallback == null || fallback.isEmpty
        ? payload
        : {...payload, 'working_directory': fallback};
  }

  static String _requiredText(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('$key is required');
    }
    return value;
  }

  Future<void> close() async {
    _closed = true;
    await relay.close();
  }
}

/// Routes the same Windows tool set to several paired computers without
/// exposing duplicate tool names to the model.
class ComputerAgentToolsGroup {
  ComputerAgentToolsGroup({
    Map<String, ComputerAgentTools> runtimes = const {},
  }) {
    _runtimes.addAll(runtimes);
  }

  final Map<String, ComputerAgentTools> _runtimes = {};
  var _closed = false;

  bool get isClosed => _closed;
  bool get hasRunningProcesses =>
      _runtimes.values.any((runtime) => runtime.hasRunningProcesses);

  Map<String, ComputerAgentTools> get runtimes =>
      Map<String, ComputerAgentTools>.unmodifiable(_runtimes);

  void setRuntime(String serverId, ComputerAgentTools runtime) {
    if (serverId.trim().isEmpty) throw ArgumentError('serverId 不能为空');
    _runtimes[serverId] = runtime;
  }

  void updateCancellation(Future<void>? value) {
    for (final runtime in _runtimes.values) {
      runtime.updateCancellation(value);
    }
  }

  List<AgentTool> get tools {
    if (_runtimes.isEmpty) return const [];
    final ids = _runtimes.keys.toList(growable: false);
    final sample = _runtimes.values.first.tools;
    return [
      for (final tool in sample)
        AgentTool(
          definition: AiToolDefinition(
            name: tool.definition.name,
            description: '${tool.definition.description} 必须通过 server_id 选择电脑。',
            parameters: _withServerId(tool.definition.parameters, ids),
          ),
          call: (arguments) => _call(tool.definition.name, arguments),
          requiresConfirmation: tool.requiresConfirmation,
          requiresUserApproval: tool.requiresUserApproval,
          userApprovalRequired: null,
          isRemote: tool.isRemote,
          writesRemoteState: tool.writesRemoteState,
        ),
    ];
  }

  Future<Object?> _call(String name, Map<String, Object?> arguments) async {
    final serverId = _serverIdFor(name, arguments);
    final runtime = _runtimes[serverId];
    if (runtime == null) throw StateError('电脑未绑定到当前对话');
    final forwarded = _withoutServerId(arguments);
    final encoded = forwarded['process_id'];
    if (_isProcessTool(name) && encoded is String) {
      forwarded['process_id'] = _decodeProcessId(encoded, serverId);
    }
    final result = await runtime.tools
        .firstWhere((tool) => tool.definition.name == name)
        .call(forwarded);
    if (result is! Map) return result;
    final value = <String, Object?>{...Map<String, Object?>.from(result)};
    final processId = value['process_id'];
    if (_isProcessTool(name) && processId is String && processId.isNotEmpty) {
      value['process_id'] = '$serverId\u0000$processId';
    }
    value['server_id'] = serverId;
    return value;
  }

  String _serverIdFor(String name, Map<String, Object?> arguments) {
    final explicit = arguments['server_id'];
    if (explicit is String && _runtimes.containsKey(explicit)) return explicit;
    if (_isProcessTool(name)) {
      final processId = arguments['process_id'];
      if (processId is String) {
        final separator = processId.indexOf('\u0000');
        if (separator > 0) {
          final serverId = processId.substring(0, separator);
          if (_runtimes.containsKey(serverId)) return serverId;
        }
      }
    }
    throw ArgumentError('server_id is required');
  }

  static Map<String, Object?> _withServerId(
    Map<String, Object?> source,
    List<String> ids,
  ) {
    final result = <String, Object?>{...source};
    final properties = source['properties'];
    result['properties'] = {
      if (properties is Map) ...Map<String, Object?>.from(properties),
      'server_id': {'type': 'string', 'enum': ids},
    };
    final required = <Object?>[
      if (source['required'] is List) ...(source['required'] as List),
      if (source['required'] is! List ||
          !(source['required'] as List).contains('server_id'))
        'server_id',
    ];
    result['required'] = required;
    return result;
  }

  static Map<String, Object?> _withoutServerId(Map<String, Object?> arguments) {
    final result = <String, Object?>{...arguments};
    result.remove('server_id');
    return result;
  }

  static bool _isProcessTool(String name) =>
      name == 'terminal.poll' ||
      name == 'terminal.write' ||
      name == 'terminal.stop';

  static String _decodeProcessId(String value, String serverId) {
    final prefix = '$serverId\u0000';
    if (!value.startsWith(prefix)) {
      throw ArgumentError('process_id 与 server_id 不匹配');
    }
    return value.substring(prefix.length);
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait<void>([
      for (final runtime in _runtimes.values) runtime.close(),
    ], eagerError: false);
  }
}
