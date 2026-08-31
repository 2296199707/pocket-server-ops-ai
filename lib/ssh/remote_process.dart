import 'dart:async';
import 'dart:convert';

import 'ssh_connection.dart';

typedef RemoteConnectionReconnector = Future<SshConnection> Function();

/// A small remote process record that can be reopened after the SSH channel
/// which created it has gone away. The record lives below the authenticated
/// user's home directory; no server package or resident service is required.
class RemoteProcessHandle {
  RemoteProcessHandle(this.id, {this.directory});

  final String id;
  String? directory;
  bool done = false;
}

class RemoteProcessSnapshot {
  const RemoteProcessSnapshot({
    required this.stdout,
    required this.stderr,
    required this.stdoutOffset,
    required this.stderrOffset,
    required this.stdoutTotalBytes,
    required this.stderrTotalBytes,
    required this.done,
    required this.failed,
    this.exitCode,
    this.error,
  });

  final String stdout;
  final String stderr;
  final int stdoutOffset;
  final int stderrOffset;
  final int? stdoutTotalBytes;
  final int? stderrTotalBytes;
  final bool done;
  final bool failed;
  final int? exitCode;
  final String? error;
}

/// Manages process records created by the server Agent.
///
/// Start is idempotent for a supplied process id. Polling is safe to retry
/// after reconnecting because it only reads the record. Stdin is deliberately
/// not retried after an uncertain write: replaying user input could change the
/// command's meaning.
class RemoteProcessController {
  RemoteProcessController(
    SshConnection connection, {
    this.reconnect,
    this.onConnectionChanged,
  }) : _connection = connection;

  static const maxManagedProcesses = 64;
  static const maxPollWaitMilliseconds = 30 * 1000;
  static const _pollChunkBytes = 64 * 1024;
  static const _stateDirectory = '.cache/pocket-server-ops/processes';

  SshConnection _connection;
  final RemoteConnectionReconnector? reconnect;
  final void Function(SshConnection connection)? onConnectionChanged;
  final Map<String, RemoteProcessHandle> _handles = {};
  final Map<String, _StartingRemoteProcess> _startingById = {};
  Future<SshConnection>? _reconnectFuture;
  var _starting = 0;
  var _sequence = 0;
  var _closing = false;

  SshConnection get connection => _connection;

  bool get hasRunningProcesses => _handles.values.any((handle) => !handle.done);

  bool hasHandle(String processId) => _handles.containsKey(processId);

  void updateConnection(SshConnection connection) {
    _connection = connection;
  }

  Future<RemoteProcessHandle> start({
    required String command,
    String? workingDirectory,
    bool pty = false,
    String initialInput = '',
    String? processId,
  }) async {
    if (_closing) throw StateError('远程进程管理器正在关闭');
    _removeCompletedHandles();
    final id = processId ?? _newProcessId();
    _validateProcessId(id);
    final fingerprint = _fingerprint(
      command,
      workingDirectory,
      pty,
      initialInput,
    );
    final starting = _startingById[id];
    if (starting != null) {
      if (starting.fingerprint != fingerprint) {
        throw StateError('process id already belongs to another command');
      }
      return starting.future;
    }
    if (_handles.length + _starting >= maxManagedProcesses) {
      throw StateError('托管进程数量已达到上限（$maxManagedProcesses）');
    }
    _starting++;
    final future = () async {
      try {
        final directory = await _recoverable((connection) async {
          final result = await connection.run(
            _startCommand(
              id: id,
              command: command,
              workingDirectory: workingDirectory,
              pty: pty,
              initialInput: initialInput,
            ),
            workingDirectory: workingDirectory,
            timeout: _controlTimeout,
          );
          if (result.exitCode != 0) {
            throw StateError(
              '远程进程启动失败：${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
            );
          }
          return _valueFrom(result.stdout, 'process_dir') ??
              (throw StateError('远程进程没有返回目录'));
        });
        final handle = _handles[id] ??= RemoteProcessHandle(
          id,
          directory: directory,
        );
        handle.directory = directory;
        return handle;
      } finally {
        _starting--;
      }
    }();
    _startingById[id] = _StartingRemoteProcess(fingerprint, future);
    try {
      return await future;
    } finally {
      final current = _startingById[id];
      if (current?.future == future) _startingById.remove(id);
    }
  }

  Future<RemoteProcessSnapshot> poll(
    String processId, {
    int? stdoutOffset,
    int? stderrOffset,
    int waitMs = 0,
  }) async {
    if (waitMs < 0 || waitMs > maxPollWaitMilliseconds) {
      throw ArgumentError.value(
        waitMs,
        'waitMs',
        'must be between 0 and $maxPollWaitMilliseconds',
      );
    }
    final handle = _handle(processId);
    final stdoutStart = stdoutOffset ?? 0;
    final stderrStart = stderrOffset ?? 0;
    final directory = await _directory(handle);
    final probe = await _recoverable(
      (connection) => connection.run(
        _probeCommand(
          directory,
          stdoutOffset: stdoutStart,
          stderrOffset: stderrStart,
          waitMs: waitMs,
        ),
        timeout: _pollTimeout(waitMs),
      ),
    );
    if (probe.exitCode != 0) {
      throw StateError(
        '无法读取远程进程状态：${probe.stderr.trim().isEmpty ? probe.stdout.trim() : probe.stderr.trim()}',
      );
    }
    final values = _parseValues(probe.stdout);
    final status = values['status'];
    if (status == null || status == 'missing') {
      throw StateError('找不到远程进程 $processId');
    }
    final stdout = await _readOutput(directory, 'stdout', stdoutStart);
    final stderr = await _readOutput(directory, 'stderr', stderrStart);
    final exitCode = int.tryParse(values['exit_code'] ?? '');
    final done = status != 'running';
    final failed =
        status == 'lost' || (done && (exitCode == null || exitCode != 0));
    final snapshot = RemoteProcessSnapshot(
      stdout: stdout.content,
      stderr: stderr.content,
      stdoutOffset: stdout.nextOffset,
      stderrOffset: stderr.nextOffset,
      stdoutTotalBytes: stdout.totalBytes,
      stderrTotalBytes: stderr.totalBytes,
      done: done,
      failed: failed,
      exitCode: exitCode,
      error: status == 'lost'
          ? '远程进程已退出，但没有留下退出状态'
          : done && exitCode == null
          ? '远程进程完成，但没有退出码'
          : null,
    );
    handle.done = done;
    return snapshot;
  }

  /// Write stdin once. If the channel fails after the write may have reached
  /// the FIFO, the caller receives the failure and must decide what to do.
  Future<void> write(String processId, String input) async {
    final handle = _handle(processId);
    final directory = await _directory(handle);
    final connection = await _ensureConnection();
    final command = _writeCommand(directory, input);
    final result = await connection.run(command, timeout: _controlTimeout);
    if (result.exitCode != 0) {
      throw StateError(
        '远程进程输入失败：${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
  }

  Future<RemoteProcessSnapshot> stop(String processId) async {
    final handle = _handle(processId);
    final directory = await _directory(handle);
    final result = await _recoverable(
      (connection) => connection.run(
        _stopCommand(directory),
        timeout: _controlTimeout,
      ),
    );
    if (result.exitCode != 0) {
      throw StateError(
        '停止远程进程失败：${result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr.trim()}',
      );
    }
    return poll(processId);
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    final active = _handles.values.where((handle) => !handle.done).toList();
    try {
      await Future.wait<void>([
        for (final handle in active)
          stop(handle.id).then<void>((_) {}, onError: (_, _) {}),
      ], eagerError: false).timeout(_shutdownTimeout);
    } on TimeoutException {
      // A stop request can be waiting on a broken SSH connection. Keep the
      // handles unresolved so callers do not mistake shutdown for a clean
      // remote exit; the in-flight stop operations may finish later.
    }
  }

  RemoteProcessHandle _handle(String processId) {
    _validateProcessId(processId);
    final existing = _handles[processId];
    if (existing != null) return existing;
    _removeCompletedHandles();
    if (_handles.length >= maxManagedProcesses) {
      throw StateError('本地托管进程数量已达到上限（$maxManagedProcesses）');
    }
    return _handles[processId] = RemoteProcessHandle(processId);
  }

  Future<String> _directory(RemoteProcessHandle handle) async {
    final existing = handle.directory;
    if (existing != null && existing.isNotEmpty) return existing;
    final directory = await _recoverable((connection) async {
      final result = await connection.run(
        _directoryCommand(handle.id),
        timeout: _controlTimeout,
      );
      if (result.exitCode != 0) {
        throw StateError('无法定位远程进程 ${handle.id}');
      }
      final value = result.stdout.trim();
      if (!value.startsWith('/')) {
        throw StateError('远程进程目录无效');
      }
      return value;
    });
    handle.directory = directory;
    return directory;
  }

  Future<_RemoteOutputChunk> _readOutput(
    String directory,
    String name,
    int offset,
  ) async {
    final chunk = await _recoverable(
      (connection) => connection.readFileBytesChunk(
        '$directory/$name',
        offset: offset,
        length: _pollChunkBytes,
      ).timeout(_controlTimeout),
    );
    return _RemoteOutputChunk(
      content: utf8.decode(chunk.bytes, allowMalformed: true),
      nextOffset: chunk.nextOffset,
      totalBytes: chunk.totalBytes,
    );
  }

  Future<SshConnection> _ensureConnection() async {
    if (!_connection.isClosed) return _connection;
    if (_closing) throw StateError('远程进程管理器正在关闭');
    return _forceReconnect();
  }

  Future<T> _recoverable<T>(
    Future<T> Function(SshConnection connection) operation,
  ) async {
    final connection = await _ensureConnection();
    try {
      return await operation(connection);
    } catch (_) {
      if (reconnect == null || _closing) rethrow;
      final replacement = await _forceReconnect();
      return operation(replacement);
    }
  }

  Future<SshConnection> _forceReconnect() {
    final existing = _reconnectFuture;
    if (existing != null) return existing;
    final reconnectCallback = reconnect;
    if (reconnectCallback == null) {
      return Future<SshConnection>.error(StateError('SSH 连接已断开，当前任务没有可用的重连入口'));
    }
    final old = _connection;
    final future = () async {
      try {
        await old.close();
      } catch (_) {}
      final replacement = await reconnectCallback();
      if (replacement.isClosed) {
        throw StateError('重连后 SSH 连接不可用');
      }
      _connection = replacement;
      onConnectionChanged?.call(replacement);
      return replacement;
    }();
    _reconnectFuture = future;
    return future.whenComplete(() {
      if (identical(_reconnectFuture, future)) _reconnectFuture = null;
    });
  }

  void _removeCompletedHandles() {
    _handles.removeWhere((_, handle) => handle.done);
  }

  String _newProcessId() {
    _sequence++;
    return 'process-${DateTime.now().microsecondsSinceEpoch}-$_sequence';
  }

  static String _startCommand({
    required String id,
    required String command,
    required String? workingDirectory,
    required bool pty,
    required String initialInput,
  }) {
    final idLiteral = _shellQuote(id);
    final fingerprint = _fingerprint(
      command,
      workingDirectory,
      pty,
      initialInput,
    );
    final worker = <String>[
      r'exec 3<> "$dir/stdin"',
      r'if [ -f "$dir/initial_input" ]; then cat "$dir/initial_input" >&3; rm -f "$dir/initial_input"; fi',
      r'write_state() { printf "%s\n" "$2" > "$dir/$1.tmp.$$"; mv "$dir/$1.tmp.$$" "$dir/$1"; }',
      r'if ! cd -- "$working_dir" 2>"$dir/stderr"; then write_state exit_code 126; write_state status done; exit 0; fi',
      'sh -c ${_shellQuote(command)} <&3 >"\$dir/stdout" 2>"\$dir/stderr"',
      r'code=$?',
      r'write_state exit_code "$code"',
      r'write_state status done',
    ].join('\n');
    return [
      'set -eu',
      'root="\${HOME:-/tmp}/$_stateDirectory"',
      'id=$idLiteral',
      'dir="\$root/\$id"',
      'fingerprint=${_shellQuote(fingerprint)}',
      'mkdir -p "\$root"',
      'if [ -f "\$dir/meta" ] || [ -f "\$dir/intent" ]; then',
      '  saved=""',
      '  [ -f "\$dir/meta" ] && saved=\$(cat "\$dir/meta" 2>/dev/null || true)',
      '  [ -n "\$saved" ] || saved=\$(cat "\$dir/intent" 2>/dev/null || true)',
      '  [ "\$saved" = "\$fingerprint" ] || { echo "process id already belongs to another command" >&2; exit 74; }',
      '  i=0',
      '  while [ ! -s "\$dir/pid" ] && [ "\$i" -lt 20 ]; do sleep 0.1; i=\$((i + 1)); done',
      '  [ -s "\$dir/pid" ] || { echo "process start is still in progress" >&2; exit 75; }',
      '  [ -f "\$dir/meta" ] || mv "\$dir/intent" "\$dir/meta"',
      '  printf "process_id=%s\\nprocess_dir=%s\\n" "\$id" "\$dir"',
      '  exit 0',
      'fi',
      'mkdir "\$dir" 2>/dev/null || { echo "process directory is busy" >&2; exit 75; }',
      'umask 077',
      'printf "%s\\n" "\$fingerprint" > "\$dir/intent.tmp.\$\$"',
      'mv "\$dir/intent.tmp.\$\$" "\$dir/intent"',
      ': > "\$dir/stdout"',
      ': > "\$dir/stderr"',
      'mkfifo "\$dir/stdin"',
      'printf "%s\\n" running > "\$dir/status"',
      'printf "%s" ${_shellQuote(initialInput)} > "\$dir/initial_input"',
      'working_dir=\$(pwd)',
      'export dir working_dir',
      'if command -v setsid >/dev/null 2>&1; then',
      '  nohup setsid sh -c ${_shellQuote(worker)} >/dev/null 2>&1 </dev/null &',
      '  group=1',
      'else',
      '  nohup sh -c ${_shellQuote(worker)} >/dev/null 2>&1 </dev/null &',
      '  group=0',
      'fi',
      'pid=\$!',
      'printf "%s\\n" "\$pid" > "\$dir/pid"',
      'printf "%s\\n" "\$group" > "\$dir/group"',
      'mv "\$dir/intent" "\$dir/meta"',
      'printf "process_id=%s\\nprocess_dir=%s\\n" "\$id" "\$dir"',
    ].join('\n');
  }

  static String _directoryCommand(String id) {
    return 'printf "%s" "\${HOME:-/tmp}/$_stateDirectory/$id"';
  }

  static String _probeCommand(
    String directory, {
    required int stdoutOffset,
    required int stderrOffset,
    required int waitMs,
  }) {
    final loops = (waitMs / 200).ceil();
    return [
      'set +e',
      'dir=${_shellQuote(directory)}',
      'i=0',
      'while [ "\$i" -lt $loops ]; do',
      '  status=\$(cat "\$dir/status" 2>/dev/null || printf missing)',
      '  out=\$(wc -c < "\$dir/stdout" 2>/dev/null || printf 0)',
      '  err=\$(wc -c < "\$dir/stderr" 2>/dev/null || printf 0)',
      '  pid=\$(cat "\$dir/pid" 2>/dev/null || true)',
      '  if [ "\$status" != running ] || [ "\$out" -gt $stdoutOffset ] || [ "\$err" -gt $stderrOffset ]; then break; fi',
      '  if [ -n "\$pid" ] && ! kill -0 "\$pid" 2>/dev/null; then break; fi',
      '  sleep 0.2',
      '  i=\$((i + 1))',
      'done',
      'status=\$(cat "\$dir/status" 2>/dev/null || printf missing)',
      'pid=\$(cat "\$dir/pid" 2>/dev/null || true)',
      'if [ "\$status" = running ] && [ -n "\$pid" ] && ! kill -0 "\$pid" 2>/dev/null; then status=lost; fi',
      'printf "status=%s\\n" "\$status"',
      'printf "exit_code=%s\\n" "\$(cat "\$dir/exit_code" 2>/dev/null || true)"',
      'printf "stdout_size=%s\\n" "\$(wc -c < "\$dir/stdout" 2>/dev/null || printf 0)"',
      'printf "stderr_size=%s\\n" "\$(wc -c < "\$dir/stderr" 2>/dev/null || printf 0)"',
    ].join('\n');
  }

  static String _writeCommand(String directory, String input) {
    final inputLiteral = _shellQuote(input);
    final fifo = _shellQuote('$directory/stdin');
    return [
      'set +e',
      'status=\$(cat ${_shellQuote('$directory/status')} 2>/dev/null || printf missing)',
      '[ "\$status" = running ] || exit 75',
      'if command -v timeout >/dev/null 2>&1; then',
      '  timeout 5 sh -c ${_shellQuote('printf "%s" $inputLiteral > $fifo')}',
      'else',
      '  printf "%s" $inputLiteral > $fifo',
      'fi',
    ].join('\n');
  }

  static String _stopCommand(String directory) {
    final dir = _shellQuote(directory);
    return [
      'set +e',
      'dir=$dir',
      'pid=\$(cat "\$dir/pid" 2>/dev/null || true)',
      'group=\$(cat "\$dir/group" 2>/dev/null || printf 0)',
      'if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then',
      '  if [ "\$group" = 1 ]; then kill -TERM -- "-\$pid" 2>/dev/null || kill -TERM "\$pid" 2>/dev/null; else kill -TERM "\$pid" 2>/dev/null; fi',
      '  i=0',
      '  while kill -0 "\$pid" 2>/dev/null && [ "\$i" -lt 20 ]; do sleep 0.1; i=\$((i + 1)); done',
      '  if kill -0 "\$pid" 2>/dev/null; then kill -KILL -- "-\$pid" 2>/dev/null || kill -KILL "\$pid" 2>/dev/null; fi',
      'fi',
      'exit 0',
    ].join('\n');
  }

  static Map<String, String> _parseValues(String output) {
    final values = <String, String>{};
    for (final line in output.split('\n')) {
      final index = line.indexOf('=');
      if (index <= 0) continue;
      values[line.substring(0, index)] = line.substring(index + 1).trim();
    }
    return values;
  }

  static String? _valueFrom(String output, String key) =>
      _parseValues(output)[key]?.trim();

  static String _fingerprint(
    String command,
    String? workingDirectory,
    bool pty,
    String input,
  ) {
    // A short non-secret identity is enough to make a retry idempotent. The
    // command itself is never written to the remote process metadata.
    var hash = 1469598103934665603;
    final bytes = utf8.encode(
      '$command\u0000${workingDirectory ?? ''}\u0000$pty\u0000$input',
    );
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 1099511628211) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static void _validateProcessId(String value) {
    if (!RegExp(r'^process-[a-zA-Z0-9_-]{1,96}$').hasMatch(value)) {
      throw ArgumentError('process_id 无效');
    }
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static Duration _pollTimeout(int waitMs) =>
      Duration(milliseconds: waitMs) + _controlTimeout;
}

class _StartingRemoteProcess {
  const _StartingRemoteProcess(this.fingerprint, this.future);

  final String fingerprint;
  final Future<RemoteProcessHandle> future;
}

class _RemoteOutputChunk {
  const _RemoteOutputChunk({
    required this.content,
    required this.nextOffset,
    required this.totalBytes,
  });

  final String content;
  final int nextOffset;
  final int? totalBytes;
}

const _controlTimeout = Duration(seconds: 15);
const _shutdownTimeout = Duration(seconds: 5);
