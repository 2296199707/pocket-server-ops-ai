import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';
import 'file_manager_page.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    required this.controller,
    required this.server,
    this.taskId,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;
  final String? taskId;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late ServerProfile _server;
  late final Terminal _terminal = Terminal(maxLines: 10000);
  late final TerminalController _terminalController = TerminalController();

  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  ServerTerminalSession? _session;
  var _terminalWidth = 80;
  var _terminalHeight = 24;
  var _connecting = false;
  var _disconnected = false;
  var _ctrlHeld = false;
  var _altHeld = false;
  var _previewRunning = false;
  var _previewLine = '';
  late String _fileManagerPath;

  bool get _preview => widget.controller.previewMode;
  bool get _connected => _session != null && !_disconnected;
  bool get _inputEnabled => _preview ? !_previewRunning : _connected;

  @override
  void initState() {
    super.initState();
    _server = widget.server;
    _fileManagerPath =
        _server.defaultWorkingDirectory?.trim().isNotEmpty == true
        ? _server.defaultWorkingDirectory!
        : '/';
    _terminal.onOutput = _onTerminalOutput;
    _terminal.onResize = (width, height, _, _) {
      if (width <= 0 || height <= 0) return;
      _terminalWidth = width;
      _terminalHeight = height;
      if (_connected) {
        _session?.stream.resizeTerminal(width, height);
      }
    };
    if (_preview) {
      _terminal.write('\$ ');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_initialize());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_initialize());
      });
    }
  }

  Task? get _boundTask {
    final id = widget.taskId;
    return id == null ? null : widget.controller.taskForId(id);
  }

  List<ServerProfile> get _availableServers =>
      widget.controller.serversForTask(_boundTask);

  Future<void> _initialize() async {
    final initialServerId = _server.id;
    final selected = await widget.controller.resolveServerForFeature(
      task: _boundTask,
      feature: 'terminal',
      fallbackServerId: _server.id,
    );
    if (!mounted) return;
    if (_server.id == initialServerId &&
        selected != null &&
        selected.id != _server.id) {
      setState(() {
        _server = selected;
        _fileManagerPath = _defaultServerPath(selected);
      });
    }
    if (!_preview) await _connect();
  }

  @override
  void dispose() {
    _terminalController.dispose();
    unawaited(_closeSession());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TerminalThemes.defaultTheme.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_server.name} · 终端'),
            Text(
              _statusLabel,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: _statusColor(context)),
            ),
          ],
        ),
        actions: [
          if (_availableServers.length > 1)
            PopupMenuButton<String>(
              tooltip: '切换服务器',
              icon: const Icon(Icons.swap_horiz_rounded),
              onSelected: (id) => unawaited(_switchServer(id)),
              itemBuilder: (context) => [
                for (final server in _availableServers)
                  PopupMenuItem(
                    value: server.id,
                    child: Row(
                      children: [
                        Icon(
                          server.id == _server.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: Text(server.name)),
                      ],
                    ),
                  ),
              ],
            ),
          IconButton(
            tooltip: '文件管理器',
            onPressed: _openFileDrawer,
            icon: const Icon(Icons.folder_open_outlined),
          ),
          if (_connected)
            IconButton(
              tooltip: '发送 Ctrl+C',
              onPressed: () => _sendShortcut('\u0003'),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          IconButton(
            tooltip: '清空终端',
            onPressed: _clearTerminal,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          if (!_preview)
            IconButton(
              tooltip: _connected ? '重新连接' : '连接终端',
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TerminalView(
              _terminal,
              controller: _terminalController,
              theme: TerminalThemes.defaultTheme,
              textStyle: const TerminalStyle(
                fontSize: 13,
                height: 1.2,
                fontFamilyFallback: ['NotoSansSC', 'monospace'],
              ),
              padding: const EdgeInsets.all(8),
              autofocus: false,
              deleteDetection: true,
              keyboardAppearance: Brightness.dark,
            ),
          ),
          SafeArea(
            top: false,
            child: _TerminalShortcutBar(
              enabled: _inputEnabled,
              ctrlHeld: _ctrlHeld,
              altHeld: _altHeld,
              onCtrl: () => setState(() => _ctrlHeld = !_ctrlHeld),
              onAlt: () => setState(() => _altHeld = !_altHeld),
              onShortcut: _sendShortcut,
            ),
          ),
        ],
      ),
    );
  }

  String get _statusLabel {
    if (_previewRunning) return '预览执行中';
    if (_preview) return '预览模式';
    if (_connecting) return '连接中';
    if (_connected) return '已连接 · $_terminalWidth×$_terminalHeight';
    return _disconnected ? '已断开' : '等待连接';
  }

  Color _statusColor(BuildContext context) {
    if (_preview) return Theme.of(context).colorScheme.primary;
    if (_connecting) return Colors.orange;
    if (_connected) return Colors.green;
    return Theme.of(context).colorScheme.error;
  }

  void _onTerminalOutput(String data) {
    final input = _applyModifiers(data);
    if (input.isEmpty) return;
    if (_preview) {
      _handlePreviewInput(input);
    } else {
      _session?.stream.writeText(input);
    }
  }

  String _applyModifiers(String data) {
    var output = data;
    if (_ctrlHeld && data.runes.length == 1) {
      final code = String.fromCharCode(data.runes.single)
          .toUpperCase()
          .codeUnitAt(0);
      if (code >= 0x40 && code <= 0x5f) {
        output = String.fromCharCode(code & 0x1f);
      }
    }
    if (_altHeld) output = '\u001b$output';
    if ((_ctrlHeld || _altHeld) && mounted) {
      setState(() {
        _ctrlHeld = false;
        _altHeld = false;
      });
    }
    return output;
  }

  void _sendShortcut(String data) {
    if (!_inputEnabled) return;
    _onTerminalOutput(data);
  }

  void _handlePreviewInput(String data) {
    if (data == '\r' || data == '\n') {
      final command = _previewLine.trim();
      _previewLine = '';
      _terminal.write('\r\n');
      if (command.isEmpty) {
        _terminal.write('\$ ');
      } else {
        unawaited(_runPreview(command));
      }
      return;
    }
    if (data == '\u0003') {
      _previewLine = '';
      _terminal.write('^C\r\n\$ ');
      return;
    }
    if (data == '\u007f' || data == '\b') {
      if (_previewLine.isEmpty) return;
      final runes = _previewLine.runes.toList()..removeLast();
      _previewLine = String.fromCharCodes(runes);
      _terminal.write('\b \b');
      return;
    }
    if (data.runes.every((code) => code >= 0x20 && code != 0x7f)) {
      _previewLine += data;
      _terminal.write(data);
    }
  }

  Future<void> _connect() async {
    if (_connecting) return;
    await _closeSession();
    if (!mounted) return;
    setState(() {
      _connecting = true;
      _disconnected = false;
    });
    _terminal.write('\r\n[正在连接 ${_server.host}:${_server.port}]\r\n');
    try {
      final session = await widget.controller.openServerTerminal(
        _server,
        width: _terminalWidth,
        height: _terminalHeight,
        onFirstHostKey: _confirmHostKey,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      _session = session;
      _stdout = session.stream.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_writeOutput);
      _stderr = session.stream.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_writeOutput);
      unawaited(
        session.stream.done.then<void>(
          (_) => _markDisconnected(session),
          onError: (Object _, StackTrace _) => _markDisconnected(session),
        ),
      );
      setState(() => _connecting = false);
      session.stream.resizeTerminal(_terminalWidth, _terminalHeight);
      final directory = _server.defaultWorkingDirectory?.trim();
      if (directory != null && directory.isNotEmpty) {
        session.stream.writeText('cd -- ${_quote(directory)}\n');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _disconnected = true;
        });
        _terminal.write('[连接失败] $error\r\n');
      }
    }
  }

  void _writeOutput(String value) {
    if (!mounted || value.isEmpty) return;
    _terminal.write(value);
  }

  void _markDisconnected(ServerTerminalSession session) {
    if (!mounted || _session != session) return;
    setState(() {
      _disconnected = true;
      _connecting = false;
    });
    _terminal.write('\r\n[终端已断开]\r\n');
  }

  Future<void> _closeSession() async {
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    final session = _session;
    _session = null;
    await session?.close();
  }

  Future<void> _runPreview(String command) async {
    if (mounted) setState(() => _previewRunning = true);
    try {
      final result = await widget.controller.runServerCommand(
        _server,
        command,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) _terminal.write(_toTerminalText(result.output));
    } catch (error) {
      if (mounted) _terminal.write(_toTerminalText('[执行失败] $error'));
    } finally {
      if (mounted) setState(() => _previewRunning = false);
      if (mounted) _terminal.write('\r\n\$ ');
    }
  }

  void _clearTerminal() {
    _terminal.buffer.clear();
    _terminal.buffer.setCursor(0, 0);
    if (_preview) {
      _previewLine = '';
      _terminal.write('\$ ');
    }
  }

  Future<void> _openFileDrawer() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final height = MediaQuery.sizeOf(sheetContext).height * .82;
        return SizedBox(
          height: height,
          child: FileManagerPage(
            controller: widget.controller,
            server: _server,
            taskId: widget.taskId,
            initialPath: _fileManagerPath,
            onCdToDirectory: (path) {
              _cdToDirectory(path);
              Navigator.of(sheetContext).pop();
            },
          ),
        );
      },
    );
  }

  void _cdToDirectory(String path) {
    final directory = path.trim();
    if (directory.isEmpty) return;
    _fileManagerPath = directory;
    if (_preview) {
      _terminal.write('cd -- ${_quote(directory)}\r\n\$ ');
      return;
    }
    if (!_connected) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('终端尚未连接，无法切换目录')));
      }
      return;
    }
    _session?.stream.writeText('cd -- ${_quote(directory)}\n');
  }

  String _defaultServerPath(ServerProfile server) {
    final path = server.defaultWorkingDirectory?.trim();
    return path == null || path.isEmpty ? '/' : path;
  }

  Future<void> _switchServer(String id) async {
    if (_connecting || id == _server.id) return;
    ServerProfile? selected;
    for (final server in _availableServers) {
      if (server.id == id) {
        selected = server;
        break;
      }
    }
    if (selected == null) return;
    try {
      await widget.controller.setServerForFeature(
        task: _boundTask,
        feature: 'terminal',
        serverId: selected.id,
      );
      await _closeSession();
      if (!mounted) return;
      setState(() {
        _server = selected!;
        _fileManagerPath =
            _server.defaultWorkingDirectory?.trim().isNotEmpty == true
            ? _server.defaultWorkingDirectory!
            : '/';
        _disconnected = false;
      });
      _terminal.write('\r\n[已切换到 ${_server.name}，正在重新连接]\r\n');
      if (!_preview) unawaited(_connect());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换服务器失败：$error')));
      }
    }
  }

  Future<bool> _confirmHostKey(SshHostKey key) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认主机指纹'),
            content: SelectableText('${key.type}\n${key.fingerprint}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('信任并保存'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

String _toTerminalText(String value) {
  return value.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

class _TerminalShortcutBar extends StatelessWidget {
  const _TerminalShortcutBar({
    required this.enabled,
    required this.ctrlHeld,
    required this.altHeld,
    required this.onCtrl,
    required this.onAlt,
    required this.onShortcut,
  });

  final bool enabled;
  final bool ctrlHeld;
  final bool altHeld;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final ValueChanged<String> onShortcut;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TerminalThemes.defaultTheme.background,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Wrap(
        spacing: 2,
        runSpacing: 4,
        alignment: WrapAlignment.start,
        children: [
          _TerminalKey(
            label: 'Ctrl',
            active: ctrlHeld,
            enabled: enabled,
            onPressed: onCtrl,
          ),
          _TerminalKey(
            label: 'Alt',
            active: altHeld,
            enabled: enabled,
            onPressed: onAlt,
          ),
          _TerminalKey(
            label: 'Esc',
            enabled: enabled,
            onPressed: () => onShortcut('\u001b'),
          ),
          _TerminalKey(
            label: 'Tab',
            enabled: enabled,
            onPressed: () => onShortcut('\t'),
          ),
          _TerminalKey(
            label: 'Enter',
            icon: Icons.keyboard_return,
            enabled: enabled,
            onPressed: () => onShortcut('\r'),
          ),
          _TerminalKey(
            label: 'Back',
            icon: Icons.backspace_outlined,
            enabled: enabled,
            onPressed: () => onShortcut('\u007f'),
          ),
          _TerminalKey(
            label: 'Left',
            icon: Icons.arrow_back,
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[D'),
          ),
          _TerminalKey(
            label: 'Up',
            icon: Icons.arrow_upward,
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[A'),
          ),
          _TerminalKey(
            label: 'Down',
            icon: Icons.arrow_downward,
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[B'),
          ),
          _TerminalKey(
            label: 'Right',
            icon: Icons.arrow_forward,
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[C'),
          ),
          _TerminalKey(
            label: 'Home',
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[H'),
          ),
          _TerminalKey(
            label: 'End',
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[F'),
          ),
          _TerminalKey(
            label: 'PgUp',
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[5~'),
          ),
          _TerminalKey(
            label: 'PgDn',
            enabled: enabled,
            onPressed: () => onShortcut('\u001b[6~'),
          ),
        ],
      ),
    );
  }
}

class _TerminalKey extends StatelessWidget {
  const _TerminalKey({
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.icon,
    this.active = false,
  });

  final String label;
  final bool enabled;
  final bool active;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 38,
      child: OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: active ? Colors.teal.shade700 : Colors.white10,
          side: const BorderSide(color: Colors.white24),
          minimumSize: const Size(48, 38),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        child: icon == null ? Text(label) : Icon(icon, size: 18),
      ),
    );
  }
}
