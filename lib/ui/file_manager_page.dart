import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({
    required this.controller,
    required this.server,
    this.initialPath,
    this.onCdToDirectory,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;
  final String? initialPath;
  final ValueChanged<String>? onCdToDirectory;

  @override
  State<FileManagerPage> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage> {
  late final TextEditingController _path;
  List<SshDirectoryEntry> _entries = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final configuredPath = widget.initialPath?.trim();
    _path = TextEditingController(
      text: configuredPath?.isNotEmpty == true
          ? configuredPath!
          : widget.server.defaultWorkingDirectory?.trim().isNotEmpty == true
          ? widget.server.defaultWorkingDirectory
          : '/',
    );
    final cached = widget.controller.cachedServerDirectory(
      widget.server,
      _path.text,
    );
    if (cached == null) {
      unawaited(_load());
    } else {
      _entries = cached;
      _loading = true;
      unawaited(_refresh(_path.text));
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.server.name} · 文件'),
        actions: [
          IconButton(
            tooltip: '新建文件',
            onPressed: _loading ? null : _createFile,
            icon: const Icon(Icons.note_add_outlined),
          ),
          if (widget.onCdToDirectory != null)
            IconButton(
              tooltip: 'cd 到当前位置',
              onPressed: _loading ? null : _cdToCurrentDirectory,
              icon: const Icon(Icons.subdirectory_arrow_right),
            ),
          IconButton(
            tooltip: '刷新目录',
            onPressed: _loading ? null : _load,
            icon: _loading
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回上级目录',
                  onPressed: _loading ? null : _goParent,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: TextField(
                    controller: _path,
                    enabled: !_loading,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _load(),
                    decoration: const InputDecoration(
                      labelText: '远程目录',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '打开目录',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          if (widget.onCdToDirectory != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 4),
                child: TextButton.icon(
                  onPressed: _loading ? null : _cdToCurrentDirectory,
                  icon: const Icon(Icons.terminal_outlined, size: 18),
                  label: const Text('cd 到当前位置'),
                ),
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(12),
              child: Text(_error!),
            ),
          Expanded(
            child: _loading && _entries.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                ? const Center(child: Text('目录为空'))
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: entry.isDirectory
                            ? const Text('目录')
                            : Text(_formatSize(entry.size)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(entry),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final cached = widget.controller.cachedServerDirectory(widget.server, path);
    if (!forceRefresh && cached != null) {
      if (mounted) {
        setState(() {
          _entries = cached;
          _loading = true;
          _error = null;
        });
      }
      await _refresh(path);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await _refresh(path);
  }

  Future<void> _refresh(String path) async {
    try {
      final entries = await widget.controller.listServerDirectory(
        widget.server,
        path,
        onFirstHostKey: _confirmHostKey,
        forceRefresh: true,
      );
      if (mounted && _path.text.trim() == path) {
        setState(() => _entries = entries);
      }
    } catch (error) {
      if (mounted && _path.text.trim() == path) {
        setState(
          () => _error = _entries.isEmpty
              ? '读取目录失败：$error'
              : '刷新失败，继续显示缓存：$error',
        );
      }
    } finally {
      if (mounted && _path.text.trim() == path) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(SshDirectoryEntry entry) async {
    if (entry.isDirectory) {
      _path.text = entry.path;
      await _load();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemoteFileEditorPage(
          controller: widget.controller,
          server: widget.server,
          path: entry.path,
          name: entry.name,
        ),
      ),
    );
    if (mounted) unawaited(_load(forceRefresh: true));
  }

  void _goParent() {
    final path = _path.text.trim();
    if (path.isEmpty || path == '/') return;
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final separator = clean.lastIndexOf('/');
    _path.text = separator <= 0 ? '/' : clean.substring(0, separator);
    _load();
  }

  Future<void> _createFile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('新建文件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '文件名'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty || name.contains('/')) return;
    final directory = _path.text.trim();
    final path = directory == '/'
        ? '/${name.trim()}'
        : '$directory/${name.trim()}';
    try {
      await widget.controller.writeServerFile(
        widget.server,
        path,
        '',
        onFirstHostKey: _confirmHostKey,
      );
      await _load(forceRefresh: true);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '新建文件失败：$error');
      }
    }
  }

  void _cdToCurrentDirectory() {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    widget.onCdToDirectory?.call(path);
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

class RemoteFileEditorPage extends StatefulWidget {
  const RemoteFileEditorPage({
    required this.controller,
    required this.server,
    required this.path,
    required this.name,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;
  final String path;
  final String name;

  @override
  State<RemoteFileEditorPage> createState() => _RemoteFileEditorPageState();
}

class _RemoteFileEditorPageState extends State<RemoteFileEditorPage> {
  late final TextEditingController _content;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController();
    unawaited(_load());
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '保存文件',
            onPressed: _loading || _saving ? null : _save,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                Expanded(
                  child: TextField(
                    controller: _content,
                    minLines: 20,
                    maxLines: null,
                    expands: false,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: '文件内容',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _load() async {
    try {
      final value = await widget.controller.readServerFile(
        widget.server,
        widget.path,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        _content.text = value;
        setState(() => _loading = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取文件失败：$error';
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.writeServerFile(
        widget.server,
        widget.path,
        _content.text,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('文件已保存')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '保存文件失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
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

String _formatSize(int? size) {
  if (size == null) return '未知大小';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KiB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MiB';
}
